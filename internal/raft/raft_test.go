package raftpkg

import (
	"context"
	"testing"
	"time"

	"github.com/orch-protocol/orch/internal/config"
	orchpb "github.com/orch-protocol/orch/internal/pb"
)

func TestDeriveRaftAddr(t *testing.T) {
	addr, err := deriveRaftAddr("127.0.0.1:7946")
	if err != nil {
		t.Fatalf("deriveRaftAddr failed: %v", err)
	}
	if addr != "127.0.0.1:7947" {
		t.Fatalf("expected 127.0.0.1:7947, got %q", addr)
	}
}

func TestRaftNodeBootstrapLeader(t *testing.T) {
	cfg := &config.Config{Addr: "127.0.0.1:9050", ClusterToken: 42, Service: "svc", Version: "1.0", HeartbeatInterval: time.Second, HeartbeatTimeout: time.Second, ElectionTimeoutMin: 150 * time.Millisecond, ElectionTimeoutMax: 200 * time.Millisecond}
	self := &orchpb.NodeId{Id: "node-1", Addr: cfg.Addr, Service: cfg.Service, Version: cfg.Version}

	raftNode, err := NewRaftNode(cfg, self, func() []*orchpb.NodeId { return []*orchpb.NodeId{self} }, func(isLeader bool, term uint64) {})
	if err != nil {
		t.Fatalf("failed create raft node: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if _, err := raftNode.Start(ctx); err != nil {
		t.Fatalf("failed start raft node: %v", err)
	}
	defer raftNode.Shutdown()

	deadline := time.After(2 * time.Second)
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-deadline:
			t.Fatal("raft node did not become leader in time")
		case <-tick.C:
			if string(raftNode.raft.Leader()) == raftNode.raftAddr {
				return
			}
		}
	}
}
