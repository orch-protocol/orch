package scale

import (
	"context"
	"testing"
	"time"

	"github.com/orch-protocol/orch/internal/config"
	orchpb "github.com/orch-protocol/orch/internal/pb"
)

type testProvider struct {
	metrics []NodeMetrics
	counts  map[string]int
}

func (p *testProvider) AliveNodeMetrics() []NodeMetrics {
	return p.metrics
}

func (p *testProvider) ServiceCount(service string) int {
	if p.counts == nil {
		return 0
	}
	return p.counts[service]
}

func TestScaleManagerTriggersScaleOut(t *testing.T) {
	cfg := &config.Config{
		ScaleCommand:      "echo scale-out",
		ScaleInterval:     10 * time.Millisecond,
		ScaleCPUThreshold: 0.5,
		ScaleMemThreshold: 0.5,
		ScaleDelta:        1,
	}
	self := &orchpb.NodeId{Id: "leader", Service: "svc", IsLeader: true}
	provider := &testProvider{metrics: []NodeMetrics{{NodeID: "peer1", CpuUsage: 0.75, MemUsage: 0.1, Goroutines: 10}}}
	var received *orchpb.ScaleSignal
	mgr := NewScaleManager(cfg, func() *orchpb.NodeId { return self }, provider, func(signal *orchpb.ScaleSignal) {
		received = signal
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	mgr.Start(ctx)
	time.Sleep(200 * time.Millisecond)
	if received == nil {
		t.Fatal("expected scale signal callback to be invoked")
	}
	if received.Direction != orchpb.ScaleSignal_OUT {
		t.Fatalf("expected scale out signal, got %v", received.Direction)
	}
}

func TestScaleManagerTriggersScaleIn(t *testing.T) {
	cfg := &config.Config{
		ScaleCommand:      "sleep 30", // Long running to test stop
		ScaleInterval:     10 * time.Millisecond,
		ScaleCPUThreshold: 0.5,
		ScaleMemThreshold: 0.5,
		ScaleDelta:        1,
	}
	self := &orchpb.NodeId{Id: "leader", Service: "svc", IsLeader: true}
	provider := &testProvider{metrics: []NodeMetrics{
		{NodeID: "peer1", CpuUsage: 0.1, MemUsage: 0.1, Goroutines: 10},
		{NodeID: "peer2", CpuUsage: 0.1, MemUsage: 0.1, Goroutines: 10},
	}}
	var received *orchpb.ScaleSignal
	mgr := NewScaleManager(cfg, func() *orchpb.NodeId { return self }, provider, func(signal *orchpb.ScaleSignal) {
		received = signal
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	mgr.Start(ctx)
	time.Sleep(200 * time.Millisecond)
	if received == nil {
		t.Fatal("expected scale signal callback to be invoked")
	}
	if received.Direction != orchpb.ScaleSignal_IN {
		t.Fatalf("expected scale in signal, got %v", received.Direction)
	}
}
