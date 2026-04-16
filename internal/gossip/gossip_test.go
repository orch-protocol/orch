package gossip

import (
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/orch-protocol/orch/internal/config"
	"github.com/orch-protocol/orch/internal/transport"
	orchpb "github.com/orch-protocol/orch/internal/pb"
	"google.golang.org/protobuf/proto"
)

func TestMembershipAddOrUpdateAndState(t *testing.T) {
	self := &orchpb.NodeId{Id: "self", Addr: "127.0.0.1:7946"}
	m := NewMembership(self)

	if m.Count() != 1 {
		t.Fatalf("expected count 1, got %d", m.Count())
	}

	node := &orchpb.NodeId{Id: "peer", Addr: "127.0.0.1:7947"}
	added := m.AddOrUpdate(node)
	if !added {
		t.Fatal("expected new node to be added")
	}
	if m.Count() != 2 {
		t.Fatalf("expected count 2 after add, got %d", m.Count())
	}

	member, ok := m.Get("peer")
	if !ok || member.Node.Addr != "127.0.0.1:7947" {
		t.Fatalf("expected peer entry present, got %+v", member)
	}

	m.MarkState("peer", StateDead)
	if member.State != StateDead {
		t.Fatalf("expected peer state DEAD, got %v", member.State)
	}

	addrs := m.KnownPeerAddrs()
	if len(addrs) != 0 {
		t.Fatalf("expected no known peer addrs when peer is dead, got %v", addrs)
	}
}

func TestDedupCacheAdd(t *testing.T) {
	d := NewDedupCache(2)
	if !d.Add(1) {
		t.Fatal("expected first add to return true")
	}
	if d.Add(1) {
		t.Fatal("expected duplicate add to return false")
	}
	if !d.Add(2) {
		t.Fatal("expected second unique add to return true")
	}
	if !d.Add(3) {
		t.Fatal("expected new id after eviction to return true")
	}
	if !d.Add(1) {
		t.Fatal("expected evicted id to be treatable as new after rotation")
	}
}

func TestMembershipRecordHeartbeat(t *testing.T) {
	self := &orchpb.NodeId{Id: "self", Addr: "127.0.0.1:7946"}
	m := NewMembership(self)
	peer := &orchpb.NodeId{Id: "peer", Addr: "127.0.0.1:7947"}
	m.RecordHeartbeat(peer, 0.42, 0.23, 10)

	member, ok := m.Get("peer")
	if !ok {
		t.Fatal("expected peer in membership")
	}
	if member.State != StateAlive {
		t.Fatalf("expected peer alive, got %v", member.State)
	}
	if member.LastSeen == 0 {
		t.Fatal("expected last seen timestamp to be set")
	}
	if member.CpuUsage != 0.42 {
		t.Fatalf("expected cpu usage 0.42, got %v", member.CpuUsage)
	}
	if member.MemUsage != 0.23 {
		t.Fatalf("expected mem usage 0.23, got %v", member.MemUsage)
	}
	if member.Goroutines != 10 {
		t.Fatalf("expected goroutines 10, got %d", member.Goroutines)
	}
}

func TestFailureStatesSuspectAndDead(t *testing.T) {
	cfg := &config.Config{Addr: "127.0.0.1:7946", ClusterToken: 42, Service: "svc", Version: "1.0", HeartbeatInterval: time.Second, HeartbeatTimeout: 1 * time.Millisecond, SuspectTimeout: 1 * time.Millisecond}
	node, err := NewGossipNode(cfg)
	if err != nil {
		t.Fatalf("failed create gossip node: %v", err)
	}

	peer := &orchpb.NodeId{Id: "peer1", Addr: "127.0.0.1:7947"}
	node.membership.RecordHeartbeat(peer, 0.33, 0.44, 5)
	member, ok := node.membership.Get("peer1")
	if !ok {
		t.Fatal("expected peer1 in membership")
	}
	member.LastSeen = time.Now().Add(-10 * time.Millisecond).UnixNano()

	// Manually mark suspect to bypass asynchronous investigation in checkFailureStates
	node.membership.MarkSuspect(peer.Id, 0)
	if member.State != StateSuspect {
		t.Fatalf("expected peer1 suspect, got %v", member.State)
	}
	
	// Now manually force SuspectSince to the past to trigger DEAD in next check
	node.membership.mu.Lock()
	member.SuspectSince = time.Now().Add(-10 * time.Millisecond).UnixNano()
	node.membership.mu.Unlock()
	
	node.checkFailureStates()
	if member.State != StateDead {
		t.Fatalf("expected peer1 dead, got %v", member.State)
	}
}

func TestGossipNodeHandleHello(t *testing.T) {
	cfg := &config.Config{Addr: "127.0.0.1:7946", ClusterToken: 42, Service: "svc", Version: "1.0", HeartbeatInterval: time.Second}
	node, err := NewGossipNode(cfg)
	if err != nil {
		t.Fatalf("failed create gossip node: %v", err)
	}

	peer := &orchpb.NodeId{Id: "peer1", Addr: "127.0.0.1:7947", Service: "svc", Version: "1.0", Term: 0}
	hello := &orchpb.Hello{Node: peer, ClusterToken: 42, KnownPeers: []string{"127.0.0.1:7948"}}
	data, err := proto.Marshal(hello)
	if err != nil {
		t.Fatalf("marshal hello failed: %v", err)
	}

	frame := transport.Frame{MsgType: transport.MsgTypeHello, Flags: 0, SeqNo: 1, Payload: data}
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	done := make(chan error, 1)
	go func() {
		done <- node.handleHello(frame, server)
	}()

	resp, err := transport.ReadTCPFrame(client)
	if err != nil {
		t.Fatalf("read hello ack failed: %v", err)
	}
	if resp.MsgType != transport.MsgTypeHelloAck {
		t.Fatalf("expected HELLO_ACK, got %02x", resp.MsgType)
	}
	var ack orchpb.HelloAck
	if err := proto.Unmarshal(resp.Payload, &ack); err != nil {
		t.Fatalf("unmarshal hello ack failed: %v", err)
	}
	if ack.Node.Id != node.self.Id {
		t.Fatalf("expected ack from self node, got %s", ack.Node.Id)
	}

	if err := <-done; err != nil {
		t.Fatalf("handleHello returned error: %v", err)
	}
}

func TestGossipNodeHandleGossipFrame(t *testing.T) {
	cfg := &config.Config{Addr: "127.0.0.1:7946", ClusterToken: 42, Service: "svc", Version: "1.0", HeartbeatInterval: time.Second}
	node, err := NewGossipNode(cfg)
	if err != nil {
		t.Fatalf("failed create gossip node: %v", err)
	}

	node.membership.AddOrUpdate(&orchpb.NodeId{Id: "peer1", Addr: "127.0.0.1:7947"})
	event := &orchpb.NodeEvent{Type: orchpb.NodeEvent_DEAD, Node: &orchpb.NodeId{Id: "peer1", Addr: "127.0.0.1:7947"}, Term: 1}
	payload, err := proto.Marshal(event)
	if err != nil {
		t.Fatalf("marshal node event failed: %v", err)
	}
	envelope := &orchpb.GossipEnvelope{Ttl: 0, MsgId: 1, Payload: payload}
	data, err := proto.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal envelope failed: %v", err)
	}
	frame := transport.Frame{MsgType: transport.MsgTypeNodeDead, Flags: 0, SeqNo: 1, Payload: data}

	if err := node.handleGossipFrame(frame); err != nil {
		t.Fatalf("handleGossipFrame failed: %v", err)
	}

	member, ok := node.membership.Get("peer1")
	if !ok {
		t.Fatal("expected peer1 in membership")
	}
	if member.State != StateDead {
		t.Fatalf("expected peer1 DEAD state, got %v", member.State)
	}
}

func TestGossipNodeFanoutTargets(t *testing.T) {
	cfg := &config.Config{Addr: "127.0.0.1:7946", ClusterToken: 42, Service: "svc", Version: "1.0", HeartbeatInterval: time.Second}
	node, err := NewGossipNode(cfg)
	if err != nil {
		t.Fatalf("failed create gossip node: %v", err)
	}

	for i := 1; i <= 5; i++ {
		id := fmt.Sprintf("peer%d", i)
		addr := fmt.Sprintf("127.0.0.1:79%d", i)
		node.membership.AddOrUpdate(&orchpb.NodeId{Id: id, Addr: addr})
	}

	targets := node.fanoutTargets()
	if len(targets) == 0 {
		t.Fatal("expected fanout target list to be non-empty")
	}
	if len(targets) > 5 {
		t.Fatalf("fanout targets too large: %d", len(targets))
	}
}
