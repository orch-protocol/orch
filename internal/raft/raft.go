package raftpkg

import (
	"context"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"strconv"
	"strings"
	"time"

	hashiraft "github.com/hashicorp/raft"
	"github.com/orch-protocol/orch/internal/config"
	orchpb "github.com/orch-protocol/orch/internal/pb"
)

type RaftNode struct {
	cfg            *config.Config
	self           *orchpb.NodeId
	peers          func() []*orchpb.NodeId
	onLeaderChange func(bool, uint64)
	raftAddr       string
	raftBindAddr   string
	stream         *StreamLayer
	transport      *hashiraft.NetworkTransport
	raft           *hashiraft.Raft
	logStore       *hashiraft.InmemStore
	stableStore    *hashiraft.InmemStore
	snapshotStore  *hashiraft.InmemSnapshotStore
}

func NewRaftNode(cfg *config.Config, self *orchpb.NodeId, peers func() []*orchpb.NodeId, onLeaderChange func(bool, uint64)) (*RaftNode, error) {
	if cfg == nil {
		return nil, fmt.Errorf("config is required")
	}
	if self == nil {
		return nil, fmt.Errorf("self node is required")
	}

	if cfg.BindAddr == "" {
		cfg.BindAddr = cfg.Addr
	}

	raftAddr, err := deriveRaftAddr(cfg.Addr)
	if err != nil {
		return nil, err
	}
	raftBindAddr, err := deriveRaftAddr(cfg.BindAddr)
	if err != nil {
		return nil, err
	}
	return &RaftNode{
		cfg:            cfg,
		self:           self,
		peers:          peers,
		onLeaderChange: onLeaderChange,
		raftAddr:       raftAddr,
		raftBindAddr:   raftBindAddr,
	}, nil
}

func (r *RaftNode) Start(ctx context.Context) (string, error) {
	stream, err := NewStreamLayer(r.raftBindAddr)
	if err != nil {
		return "", fmt.Errorf("raft stream listen failed on %s: %w", r.raftBindAddr, err)
	}
	r.stream = stream
	actualAddr := stream.Addr().String()

	r.transport = hashiraft.NewNetworkTransport(stream, 3, 10*time.Second, nil)
	// ... rest of start logic same but return actualAddr ...

	r.logStore = hashiraft.NewInmemStore()
	r.stableStore = hashiraft.NewInmemStore()
	r.snapshotStore = hashiraft.NewInmemSnapshotStore()

	raftConfig := hashiraft.DefaultConfig()
	raftConfig.LocalID = hashiraft.ServerID(r.self.Id)
	raftConfig.HeartbeatTimeout = 50 * time.Millisecond
	raftConfig.LeaderLeaseTimeout = 30 * time.Millisecond
	raftConfig.ElectionTimeout = r.randomElectionTimeout()

	// Default raft log level to WARN to avoid excessive heartbeat error noise in console
	if r.cfg.LogLevel != "" {
		raftConfig.LogLevel = strings.ToUpper(r.cfg.LogLevel)
	} else {
		raftConfig.LogLevel = "WARN"
	}

	r.raft, err = hashiraft.NewRaft(raftConfig, &fsm{}, r.logStore, r.stableStore, r.snapshotStore, r.transport)
	if err != nil {
		return "", fmt.Errorf("raft startup failed: %w", err)
	}

	if len(r.remotePeers()) == 0 {
		configuration := hashiraft.Configuration{Servers: []hashiraft.Server{{ID: hashiraft.ServerID(r.self.Id), Address: hashiraft.ServerAddress(r.raftAddr)}}}
		future := r.raft.BootstrapCluster(configuration)
		if err := future.Error(); err != nil {
			return "", fmt.Errorf("raft bootstrap failed: %w", err)
		}
	}

	go r.monitorLeadership(ctx)
	go r.joinCluster(ctx)
	return actualAddr, nil
}

func (r *RaftNode) Shutdown() error {
	if r.raft != nil {
		_ = r.raft.Shutdown().Error()
	}
	var err error
	if r.transport != nil {
		err = r.transport.Close()
	}
	if r.stream != nil {
		if closeErr := r.stream.Close(); closeErr != nil && err == nil {
			err = closeErr
		}
	}
	return err
}

func (r *RaftNode) randomElectionTimeout() time.Duration {
	min := r.cfg.ElectionTimeoutMin
	max := r.cfg.ElectionTimeoutMax
	if min <= 0 {
		min = 150 * time.Millisecond
	}
	if max <= min {
		max = min + 100*time.Millisecond
	}
	return min + time.Duration(rand.Int63n(int64(max-min)))
}

func (r *RaftNode) monitorLeadership(ctx context.Context) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	lastLeader := ""
	lastTerm := uint64(0)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			leader := string(r.raft.Leader())
			term := uint64(r.raft.CurrentTerm())
			if leader != lastLeader || term != lastTerm {
				lastLeader = leader
				lastTerm = term
				if r.onLeaderChange != nil {
					r.onLeaderChange(r.raft.State() == hashiraft.Leader, term)
				}
			}
		}
	}
}

func (r *RaftNode) joinCluster(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// If we are leader, check if there are any new peers to add to raft
			if r.IsLeader() {
				r.addNewPeersDirectly()
			}
		}
	}
}

func (r *RaftNode) addNewPeersDirectly() {
	configFuture := r.raft.GetConfiguration()
	if err := configFuture.Error(); err != nil {
		return
	}

	existingServers := make(map[hashiraft.ServerID]bool)
	for _, srv := range configFuture.Configuration().Servers {
		existingServers[srv.ID] = true
	}

	for _, peer := range r.peers() {
		// Only consider peers that are currently known to be alive
		// Wait, peer *orchpb.NodeId doesn't have State.
		// AliveNodes() already filters for StateAlive/StateSuspect.
		// To be even safer, we can check if it's currently suspect but Gossip filters it.
		if peer == nil || peer.Id == r.self.Id {
			continue
		}
		if _, ok := existingServers[hashiraft.ServerID(peer.Id)]; !ok {
			peerRaftAddr, _ := deriveRaftAddr(peer.Addr)
			log.Printf("Raft leader adding new voter: %s at %s", peer.Id, peerRaftAddr)
			r.raft.AddVoter(hashiraft.ServerID(peer.Id), hashiraft.ServerAddress(peerRaftAddr), 0, 0)
		}
	}
}

func (r *RaftNode) remotePeers() []hashiraft.ServerAddress {
	result := make([]hashiraft.ServerAddress, 0)
	for _, node := range r.peers() {
		if node == nil || node.Id == r.self.Id {
			continue
		}
		raftAddr, err := deriveRaftAddr(node.Addr)
		if err != nil {
			continue
		}
		result = append(result, hashiraft.ServerAddress(raftAddr))
	}
	return result
}

func deriveRaftAddr(baseAddr string) (string, error) {
	host, portStr, err := net.SplitHostPort(baseAddr)
	if err != nil {
		return "", fmt.Errorf("invalid base addr: %w", err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return "", fmt.Errorf("invalid base port: %w", err)
	}

	// In Orch Protocol, port 0 is used for dynamic OS-assigned ports.
	if port == 0 {
		return net.JoinHostPort(host, "0"), nil
	}
	
	return net.JoinHostPort(host, strconv.Itoa(port+1)), nil
}

type fsm struct{}

func (f *fsm) Apply(log *hashiraft.Log) interface{} {
	return nil
}

func (f *fsm) Snapshot() (hashiraft.FSMSnapshot, error) {
	return &fsmSnapshot{}, nil
}

func (f *fsm) Restore(rc io.ReadCloser) error {
	return nil
}

type fsmSnapshot struct{}

func (s *fsmSnapshot) Persist(sink hashiraft.SnapshotSink) error {
	if _, err := sink.Write([]byte{}); err != nil {
		_ = sink.Cancel()
		return err
	}
	return sink.Close()
}

func (s *fsmSnapshot) Release() {}

// IsLeader returns true if this node is currently the Raft leader.
func (r *RaftNode) IsLeader() bool {
	if r.raft == nil {
		return false
	}
	return r.raft.State() == hashiraft.Leader
}

func (r *RaftNode) UpdateAddr(addr string) {
	r.raftAddr = addr
	r.raftBindAddr = addr
}

func (r *RaftNode) HandleNodeEvent(eventType orchpb.NodeEvent_EventType, node *orchpb.NodeId) {
	if eventType == orchpb.NodeEvent_DEAD {
		_ = r.IsLeader()
		// DISABLED: Automatic removal from Raft is too aggressive and can lead to quorum loss
		// during cluster churn. Gossip-level DEAD state is sufficient for traffic routing.
		/*
			if isLeader {
				go func(id string) {
					log.Printf("Raft leader attempting to remove dead node: %s", id)
					future := r.raft.RemoveServer(hashiraft.ServerID(id), 0, 0)
					if err := future.Error(); err != nil {
						log.Printf("failed to remove server %s from raft: %v", id, err)
					} else {
						log.Printf("successfully removed dead node %s from raft cluster", id)
					}
				}(node.Id)
			}
		*/
	}
}
