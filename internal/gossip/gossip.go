package gossip

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/orch-protocol/orch/internal/config"
	orchpb "github.com/orch-protocol/orch/internal/pb"
	raftpkg "github.com/orch-protocol/orch/internal/raft"
	"github.com/orch-protocol/orch/internal/scale"
	"github.com/orch-protocol/orch/internal/transport"
	"google.golang.org/protobuf/proto"
)

type GossipNode struct {
	cfg            *config.Config
	self           *orchpb.NodeId
	selfMu         sync.RWMutex
	membership     *Membership
	dedup          *DedupCache
	seqNo          atomic.Uint64
	msgID          atomic.Uint64
	tcpListener    net.Listener
	udpConn        *net.UDPConn
	rand           *rand.Rand
	pingLock       sync.Mutex
	pingRequests   map[uint64]*pingRequestState
	pingReqLock    sync.Mutex
	pingReqWaiters map[uint64]chan bool
	raftNode       *raftpkg.RaftNode
	scaleMgr       *scale.ScaleManager
	onNodeEvent    func(orchpb.NodeEvent_EventType, *orchpb.NodeId)
}

func NewGossipNode(cfg *config.Config) (*GossipNode, error) {
	if cfg == nil {
		return nil, errors.New("config is required")
	}

	nodeID := cfg.NodeID
	if strings.TrimSpace(nodeID) == "" {
		nodeID = uuid.NewString()
	}

	self := &orchpb.NodeId{
		Id:      nodeID,
		Addr:    cfg.Addr,
		Service: cfg.Service,
		Version: cfg.Version,
		Term:    0,
	}

	g := &GossipNode{
		cfg:            cfg,
		self:           self,
		membership:     NewMembership(self),
		dedup:          NewDedupCache(1024),
		rand:           rand.New(rand.NewSource(time.Now().UnixNano())),
		pingRequests:   make(map[uint64]*pingRequestState),
		pingReqWaiters: make(map[uint64]chan bool),
	}

	raftNode, err := raftpkg.NewRaftNode(cfg, self, g.alivePeerNodes, g.onLeaderChange)
	if err != nil {
		return nil, err
	}
	g.raftNode = raftNode
	g.SetOnNodeEvent(raftNode.HandleNodeEvent)
	g.scaleMgr = scale.NewScaleManager(cfg, g.getSelfNode, g, g.onScaleDecision)

	return g, nil
}

func (g *GossipNode) getSelfNode() *orchpb.NodeId {
	g.selfMu.RLock()
	defer g.selfMu.RUnlock()
	return proto.Clone(g.self).(*orchpb.NodeId)
}

func (g *GossipNode) setSelfLeaderTerm(isLeader bool, term uint64) {
	g.selfMu.Lock()
	g.self.IsLeader = isLeader
	g.self.Term = term
	g.selfMu.Unlock()
}

func (g *GossipNode) alivePeerNodes() []*orchpb.NodeId {
	return g.membership.AliveNodes()
}

func (g *GossipNode) AliveNodeMetrics() []scale.NodeMetrics {
	members := g.membership.Members()
	metrics := make([]scale.NodeMetrics, 0, len(members))
	for _, member := range members {
		if member.Node.Id == g.self.Id {
			continue
		}
		if member.State == StateDead {
			continue
		}
		metrics = append(metrics, scale.NodeMetrics{
			NodeID:     member.Node.Id,
			CpuUsage:   member.CpuUsage,
			MemUsage:   member.MemUsage,
			Goroutines: member.Goroutines,
			LastSeen:   member.LastSeen,
		})
	}
	return metrics
}

func (g *GossipNode) onScaleDecision(signal *orchpb.ScaleSignal) {
	if signal == nil {
		return
	}
	log.Printf("scale decision: direction=%s service=%s delta=%d reason=%s", signal.Direction.String(), signal.Service, signal.Delta, signal.Reason)
	g.broadcastScaleSignal(signal)
}

func (g *GossipNode) onLeaderChange(isLeader bool, term uint64) {
	g.setSelfLeaderTerm(isLeader, term)
	if isLeader {
		log.Printf("raft: became leader, term=%d", term)
	} else {
		log.Printf("raft: leader changed, term=%d", term)
	}
}

func (g *GossipNode) Start(ctx context.Context) error {
	if err := g.listenTCP(); err != nil {
		return err
	}
	if err := g.listenUDP(); err != nil {
		return err
	}
	log.Printf("Listening on TCP/UDP %s (advertised as %s)", g.cfg.BindAddr, g.cfg.Addr)

	// Start processing loops before joining seeds to avoid deadlocks
	go g.acceptTCP(ctx)
	go g.serveUDP(ctx)

	if len(g.cfg.Seeds) > 0 {
		log.Printf("attempting to join seeds: %v", g.cfg.Seeds)
		if err := g.joinSeeds(ctx); err != nil {
			log.Printf("seed join failed, bootstrapping cluster: %v", err)
		} else {
			log.Printf("successfully joined cluster via seeds")
		}
	} else {
		log.Printf("no seeds configured, bootstrapping cluster")
	}

	if g.raftNode != nil {
		// If we discovered a dynamic port, we should update the Raft bind addr too
		_, portStr, _ := net.SplitHostPort(g.cfg.Addr)
		port, _ := strconv.Atoi(portStr)
		if port > 0 {
			// Update internal raft bind/advertise addresses
			host, _, _ := net.SplitHostPort(g.cfg.BindAddr)
			g.raftNode.UpdateAddr(net.JoinHostPort(host, strconv.Itoa(port+1)))
		}

		log.Printf("starting raft node")
		if _, err := g.raftNode.Start(ctx); err != nil {
			return err
		}
		log.Printf("raft node started")
	}
	if g.scaleMgr != nil {
		g.scaleMgr.Start(ctx)
	}

	go g.heartbeatLoop(ctx)
	go g.failureLoop(ctx)

	return nil
}

func (g *GossipNode) Shutdown() {
	if g.tcpListener != nil {
		g.tcpListener.Close()
	}
	if g.udpConn != nil {
		g.udpConn.Close()
	}
	if g.raftNode != nil {
		_ = g.raftNode.Shutdown()
	}
}

func (g *GossipNode) listenTCP() error {
	listener, err := net.Listen("tcp4", g.cfg.BindAddr)
	if err != nil {
		return fmt.Errorf("tcp listen failed on %s: %w", g.cfg.BindAddr, err)
	}
	g.tcpListener = listener

	// Update advertised address to the actual port bound (especially important if BindAddr was :0)
	actualAddr := listener.Addr().String()
	_, actualPort, _ := net.SplitHostPort(actualAddr)
	_, advPort, _ := net.SplitHostPort(g.cfg.Addr)

	if advPort == "0" || advPort == "" {
		host, _, _ := net.SplitHostPort(g.cfg.Addr)
		if host == "" {
			host = "127.0.0.1"
		}
		g.cfg.Addr = net.JoinHostPort(host, actualPort)
		g.self.Addr = g.cfg.Addr
		
		// CRITICAL: Update the member entry so heartbeats use the correct address
		g.membership.AddOrUpdate(g.self)
		log.Printf("GossipNode: dynamic port discovery updated address to %s", g.cfg.Addr)
	}

	return nil
}

func (g *GossipNode) acceptTCP(ctx context.Context) {
	for {
		conn, err := g.tcpListener.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return
			default:
				if strings.Contains(err.Error(), "use of closed network connection") {
					return
				}
				log.Printf("tcp accept error: %v", err)
				continue
			}
		}
		go g.handleTCPConn(conn)
	}
}

func (g *GossipNode) listenUDP() error {
	udpAddr, err := net.ResolveUDPAddr("udp4", g.cfg.BindAddr)
	if err != nil {
		return fmt.Errorf("udp resolve failed: %w", err)
	}
	conn, err := net.ListenUDP("udp4", udpAddr)
	if err != nil {
		return fmt.Errorf("udp listen failed: %w", err)
	}
	g.udpConn = conn
	return nil
}

func (g *GossipNode) serveUDP(ctx context.Context) {
	for {
		frame, addr, err := transport.ReadUDPPacket(g.udpConn)
		if err != nil {
			select {
			case <-ctx.Done():
				return
			default:
				if strings.Contains(err.Error(), "use of closed network connection") {
					return
				}
				log.Printf("udp read error: %v", err)
				continue
			}
		}
		g.handleUDPFrame(frame, addr)
	}
}

func (g *GossipNode) heartbeatLoop(ctx context.Context) {
	ticker := time.NewTicker(g.cfg.HeartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			g.broadcastHeartbeat()
		}
	}
}

func (g *GossipNode) joinSeeds(_ context.Context) error {
	// Filter out self-address from seeds
	remoteSeeds := make([]string, 0)
	for _, addr := range g.cfg.Seeds {
		addr = strings.TrimSpace(addr)
		if addr == "" || addr == g.cfg.Addr {
			continue
		}
		remoteSeeds = append(remoteSeeds, addr)
	}

	if len(remoteSeeds) == 0 {
		log.Printf("no remote seeds to join, bootstrapping as the first node")
		return nil
	}

	var lastErr error
	backoff := 500 * time.Millisecond
	for attempt := 0; attempt < 3; attempt++ {
		for _, addr := range remoteSeeds {
			log.Printf("sending HELLO to seed %s (attempt %d/3)", addr, attempt+1)
			if err := g.sendHello(addr); err == nil {
				log.Printf("received HELLO_ACK from seed %s", addr)
				return nil
			} else {
				lastErr = err
				log.Printf("seed %s unreachable: %v", addr, err)
			}
		}
		time.Sleep(backoff)
		backoff *= 2
	}
	return fmt.Errorf("all seeds unreachable: %w", lastErr)
}

func (g *GossipNode) sendHello(addr string) error {
	conn, err := net.DialTimeout("tcp4", addr, 2*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()

	// Set deadlines for the handshake to avoid hangs
	conn.SetDeadline(time.Now().Add(5 * time.Second))

	hello := &orchpb.Hello{
		Node:         g.getSelfNode(),
		ClusterToken: g.cfg.ClusterToken,
		KnownPeers:   g.membership.KnownPeerAddrs(),
	}
	payload, err := proto.Marshal(hello)
	if err != nil {
		return err
	}
	if err := transport.WriteTCPFrame(conn, transport.Frame{MsgType: transport.MsgTypeHello, Flags: 0, SeqNo: g.nextSeq(), Payload: payload}); err != nil {
		return err
	}

	frame, err := transport.ReadTCPFrame(conn)
	if err != nil {
		return err
	}
	if frame.MsgType != transport.MsgTypeHelloAck {
		return fmt.Errorf("unexpected tcp response type: %02x", frame.MsgType)
	}

	var ack orchpb.HelloAck
	if err := proto.Unmarshal(frame.Payload, &ack); err != nil {
		return err
	}

	g.membership.AddOrUpdate(ack.Node)
	for _, node := range ack.ClusterView {
		if node.Id == g.self.Id {
			continue
		}
		g.membership.AddOrUpdate(node)
	}

	return nil
}

func (g *GossipNode) handleTCPConn(conn net.Conn) {
	defer conn.Close()
	for {
		frame, err := transport.ReadTCPFrame(conn)
		if err != nil {
			if err != io.EOF {
				log.Printf("tcp read error: %v", err)
			}
			return
		}
		if err := g.handleFrame(frame, conn); err != nil {
			log.Printf("handle frame failed: %v", err)
			return
		}
	}
}

func (g *GossipNode) handleFrame(frame transport.Frame, conn net.Conn) error {
	switch frame.MsgType {
	case transport.MsgTypeHello:
		return g.handleHello(frame, conn)
	case transport.MsgTypeHelloAck:
		return g.handleHelloAck(frame)
	case transport.MsgTypeNodeJoin, transport.MsgTypeNodeLeave, transport.MsgTypeNodeDead, transport.MsgTypeNodeSuspect:
		return g.handleGossipFrame(frame)
	case transport.MsgTypeScaleOut, transport.MsgTypeScaleIn:
		return g.handleScaleFrame(frame)
	default:
		return fmt.Errorf("unsupported tcp msg type: %02x", frame.MsgType)
	}
}

func (g *GossipNode) handleHello(frame transport.Frame, conn net.Conn) error {
	var hello orchpb.Hello
	if err := proto.Unmarshal(frame.Payload, &hello); err != nil {
		return err
	}
	if hello.ClusterToken != g.cfg.ClusterToken {
		return fmt.Errorf("cluster token mismatch for node %s", hello.Node.Id)
	}
	g.membership.AddOrRevive(hello.Node)

	ack := &orchpb.HelloAck{
		Node:        g.getSelfNode(),
		ClusterView: g.membership.ClusterView(),
	}
	payload, err := proto.Marshal(ack)
	if err != nil {
		return err
	}
	if err := transport.WriteTCPFrame(conn, transport.Frame{MsgType: transport.MsgTypeHelloAck, Flags: 0, SeqNo: g.nextSeq(), Payload: payload}); err != nil {
		return err
	}

	g.broadcastNodeEvent(orchpb.NodeEvent_JOIN, hello.Node)
	return nil
}

func (g *GossipNode) handleHelloAck(frame transport.Frame) error {
	var ack orchpb.HelloAck
	if err := proto.Unmarshal(frame.Payload, &ack); err != nil {
		return err
	}
	g.membership.AddOrRevive(ack.Node)
	for _, node := range ack.ClusterView {
		if node.Id == g.self.Id {
			continue
		}
		if g.membership.AddOrUpdate(node) {
			log.Printf("added cluster peer %s", node.Addr)
		}
	}
	return nil
}

func (g *GossipNode) handleGossipFrame(frame transport.Frame) error {
	var envelope orchpb.GossipEnvelope
	if err := proto.Unmarshal(frame.Payload, &envelope); err != nil {
		return err
	}
	if envelope.Ttl == 0 {
		return g.processGossipEnvelope(&envelope)
	}
	if !g.dedup.Add(envelope.MsgId) {
		return nil
	}
	if err := g.processGossipEnvelope(&envelope); err != nil {
		return err
	}
	envelope.Ttl--
	return g.forwardGossipEnvelope(frame.MsgType, &envelope)
}

func (g *GossipNode) processGossipEnvelope(envelope *orchpb.GossipEnvelope) error {
	var event orchpb.NodeEvent
	if err := proto.Unmarshal(envelope.Payload, &event); err != nil {
		return err
	}

	if event.Node == nil {
		return errors.New("node event missing node payload")
	}
	if event.Node.Id == g.self.Id {
		return nil
	}

	g.membership.AddOrUpdate(event.Node)
	switch event.Type {
	case orchpb.NodeEvent_JOIN:
		log.Printf("gossip: node join %s", event.Node.Id)
	case orchpb.NodeEvent_LEAVE:
		log.Printf("gossip: node leave %s", event.Node.Id)
		g.membership.MarkState(event.Node.Id, StateDead)
	case orchpb.NodeEvent_DEAD:
		log.Printf("gossip: node dead %s", event.Node.Id)
		g.membership.MarkState(event.Node.Id, StateDead)
	case orchpb.NodeEvent_SUSPECT:
		log.Printf("gossip: node suspect %s", event.Node.Id)
		g.membership.MarkState(event.Node.Id, StateSuspect)
	}
	return nil
}

func (g *GossipNode) forwardGossipEnvelope(msgType byte, envelope *orchpb.GossipEnvelope) error {
	payload, err := proto.Marshal(envelope)
	if err != nil {
		return err
	}
	frame := transport.Frame{MsgType: msgType, Flags: 0, SeqNo: g.nextSeq(), Payload: payload}
	targets := g.fanoutTargets()
	for _, peer := range targets {
		_ = g.sendFrameToPeer(peer.Addr, frame)
	}
	return nil
}

func (g *GossipNode) SetOnNodeEvent(cb func(orchpb.NodeEvent_EventType, *orchpb.NodeId)) {
	g.onNodeEvent = cb
}

func (g *GossipNode) broadcastNodeEvent(eventType orchpb.NodeEvent_EventType, node *orchpb.NodeId) {
	if node == nil || node.Id == g.self.Id {
		return
	}

	if g.onNodeEvent != nil {
		g.onNodeEvent(eventType, node)
	}

	inner, err := proto.Marshal(&orchpb.NodeEvent{Type: eventType, Node: node, Term: node.Term})
	if err != nil {
		log.Printf("failed marshal node event: %v", err)
		return
	}
	fanout := g.gossipFanout()
	envelope := &orchpb.GossipEnvelope{
		Ttl:     uint32(fanout * 2),
		MsgId:   g.nextMsgID(),
		Payload: inner,
	}
	payload, err := proto.Marshal(envelope)
	if err != nil {
		log.Printf("failed marshal gossip envelope: %v", err)
		return
	}
	msgType := transport.MsgTypeNodeJoin + byte(eventType)
	frame := transport.Frame{MsgType: msgType, Flags: 0, SeqNo: g.nextSeq(), Payload: payload}
	for _, peer := range g.fanoutTargets() {
		_ = g.sendFrameToPeer(peer.Addr, frame)
	}
}

func (g *GossipNode) broadcastScaleSignal(signal *orchpb.ScaleSignal) {
	if signal == nil {
		return
	}

	payload, err := proto.Marshal(signal)
	if err != nil {
		log.Printf("failed marshal scale signal: %v", err)
		return
	}
	msgType := transport.MsgTypeScaleOut + byte(signal.Direction)
	frame := transport.Frame{MsgType: msgType, Flags: 0, SeqNo: g.nextSeq(), Payload: payload}
	for _, peer := range g.fanoutTargets() {
		_ = g.sendFrameToPeer(peer.Addr, frame)
	}
}

func (g *GossipNode) handleScaleFrame(frame transport.Frame) error {
	var signal orchpb.ScaleSignal
	if err := proto.Unmarshal(frame.Payload, &signal); err != nil {
		return err
	}
	log.Printf("received scale signal from peer: direction=%s service=%s delta=%d reason=%s", signal.Direction.String(), signal.Service, signal.Delta, signal.Reason)
	return nil
}

func (g *GossipNode) fanoutTargets() []*orchpb.NodeId {
	candidates := make([]*orchpb.NodeId, 0)
	for _, node := range g.membership.AliveNodes() {
		if node.Id == g.self.Id {
			continue
		}
		candidates = append(candidates, node)
	}
	if len(candidates) == 0 {
		return nil
	}
	count := g.gossipFanout()
	if count >= len(candidates) {
		return candidates
	}
	perm := g.rand.Perm(len(candidates))
	selected := make([]*orchpb.NodeId, 0, count)
	for i := 0; i < count; i++ {
		selected = append(selected, candidates[perm[i]])
	}
	return selected
}

func (g *GossipNode) gossipFanout() int {
	count := g.membership.Count()
	if count < 2 {
		return 1
	}
	return int(math.Ceil(math.Log2(float64(count))))
}

func (g *GossipNode) sendFrameToPeer(addr string, frame transport.Frame) error {
	conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	return transport.WriteTCPFrame(conn, frame)
}

func (g *GossipNode) nextSeq() uint64 {
	return g.seqNo.Add(1)
}

func (g *GossipNode) nextMsgID() uint64 {
	return g.msgID.Add(1)
}

// IsLeader returns true if this node is currently the Raft leader.
func (g *GossipNode) IsLeader() bool {
	if g.raftNode == nil {
		return false
	}
	return g.raftNode.IsLeader()
}

// ClusterSize returns the number of nodes in the cluster (including self).
func (g *GossipNode) ClusterSize() int {
	return g.membership.Count()
}

// AliveNodes returns all alive nodes in the cluster (including self).
func (g *GossipNode) AliveNodes() []*orchpb.NodeId {
	return g.membership.AliveNodes()
}

// AliveNodeIDs returns the IDs of alive peer nodes (excluding self).
func (g *GossipNode) AliveNodeIDs() []string {
	nodes := g.membership.AliveNodes()
	ids := make([]string, 0, len(nodes))
	for _, n := range nodes {
		if n.Id != g.self.Id {
			ids = append(ids, n.Id)
		}
	}
	return ids
}

// ServiceCount returns the number of alive nodes for a specific service.
func (g *GossipNode) ServiceCount(service string) int {
	members := g.membership.Members()
	count := 0
	for _, m := range members {
		// Count StateAlive AND StateSuspect. Only exclude StateDead.
		// This avoids over-scaling during temporary network lag.
		if m.Node.Service == service && m.State != StateDead {
			count++
		}
	}
	return count
}
