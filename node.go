// Package orch provides a public API for the ORCH Protocol.
// ORCH Protocol is a container-less distributed microservice execution environment
// where each binary embeds orchestration capabilities and clusters self-organize.
package orch

import (
	"context"
	"errors"
	"os"
	"strings"
	"time"

	"github.com/orch-protocol/orch/internal/config"
	"github.com/orch-protocol/orch/internal/gossip"
)

// NodeInfo contains information about a node in the cluster.
type NodeInfo struct {
	ID      string
	Addr    string
	Service string
}

// Node represents an ORCH protocol node that can join a cluster,
// participate in gossip protocol, and execute scaling commands.
type Node interface {
	// Start begins the node's operation including joining the cluster,
	// starting gossip loops, and failure detection.
	Start(ctx context.Context) error

	// Shutdown gracefully stops the node and leaves the cluster.
	Shutdown()

	// IsLeader returns true if this node is currently the Raft leader.
	IsLeader() bool

	// ClusterSize returns the current number of nodes in the cluster.
	ClusterSize() int

	// AliveNodes returns the list of currently alive node IDs.
	AliveNodes() []string

	// AliveNodesInfo returns the list of currently alive nodes with their metadata.
	AliveNodesInfo() []NodeInfo
}

// node is the internal implementation of the Node interface.
type node struct {
	gossipNode *gossip.GossipNode
	config     *Config
}

// NewNode creates a new ORCH node with the given configuration.
// The node is not started until Start() is called.
//
// Example:
//
//	config := &orch.Config{
//	    ClusterToken: 12345,
//	    Addr:         "0.0.0.0:7946",
//	    Service:      "my-service",
//	}
//	node, err := orch.NewNode(config)
//	if err != nil {
//	    log.Fatal(err)
//	}
//	if err := node.Start(context.Background()); err != nil {
//	    log.Fatal(err)
//	}
func NewNode(cfg *Config) (Node, error) {
	if cfg == nil {
		return nil, errors.New("config is required")
	}

	// Validate required fields
	if cfg.ClusterToken == 0 {
		return nil, errors.New("cluster token is required")
	}
	if cfg.Addr == "" {
		cfg.Addr = "0.0.0.0:7946"
	}
	if cfg.BindAddr == "" {
		cfg.BindAddr = cfg.Addr
	}

	// Convert public Config to internal config
	internalCfg := &config.Config{
		NodeID:             cfg.NodeID,
		Addr:               cfg.Addr,
		BindAddr:           cfg.BindAddr,
		Seeds:              cfg.Seeds,
		ClusterToken:       cfg.ClusterToken,
		Service:            cfg.Service,
		Version:            cfg.Version,
		HeartbeatInterval:  cfg.HeartbeatInterval,
		HeartbeatTimeout:   cfg.HeartbeatTimeout,
		SuspectTimeout:     cfg.SuspectTimeout,
		IndirectPingCount:  cfg.IndirectPingCount,
		ElectionTimeoutMin: cfg.ElectionTimeoutMin,
		ElectionTimeoutMax: cfg.ElectionTimeoutMax,
		ScaleCommand:       cfg.ScaleCommand,
		ScaleInterval:      cfg.ScaleInterval,
		ScaleCPUThreshold:  cfg.ScaleCPUThreshold,
		ScaleMemThreshold:  cfg.ScaleMemThreshold,
		ScaleDelta:         cfg.ScaleDelta,
		DesiredCount:       cfg.DesiredCount,
		LogLevel:           cfg.LogLevel,
		ScaleService:       cfg.ScaleService,
	}

	// Apply defaults for zero values - Respect environment variables if they exist
	if internalCfg.HeartbeatInterval == 0 {
		internalCfg.HeartbeatInterval = config.ParseDurationEnv("ORCH_HEARTBEAT_INTERVAL", 1000*time.Millisecond)
	}
	if internalCfg.HeartbeatTimeout == 0 {
		internalCfg.HeartbeatTimeout = config.ParseDurationEnv("ORCH_HEARTBEAT_TIMEOUT", 3000*time.Millisecond)
	}
	if internalCfg.SuspectTimeout == 0 {
		internalCfg.SuspectTimeout = config.ParseDurationEnv("ORCH_SUSPECT_TIMEOUT", 5000*time.Millisecond)
	}
	if internalCfg.IndirectPingCount == 0 {
		internalCfg.IndirectPingCount = config.ParseIntEnv("ORCH_INDIRECT_PING_COUNT", 3)
	}
	if internalCfg.ElectionTimeoutMin == 0 {
		internalCfg.ElectionTimeoutMin = config.ParseDurationEnv("ORCH_ELECTION_TIMEOUT_MIN", 150*time.Millisecond)
	}
	if internalCfg.ElectionTimeoutMax == 0 {
		internalCfg.ElectionTimeoutMax = config.ParseDurationEnv("ORCH_ELECTION_TIMEOUT_MAX", 300*time.Millisecond)
	}
	if internalCfg.ScaleInterval == 0 {
		internalCfg.ScaleInterval = config.ParseDurationEnv("ORCH_SCALE_INTERVAL", 60*time.Second)
	}
	if internalCfg.ScaleCPUThreshold == 0 {
		internalCfg.ScaleCPUThreshold = float32(config.ParseFloatEnv("ORCH_SCALE_CPU_THRESHOLD", 0.8))
	}
	if internalCfg.ScaleMemThreshold == 0 {
		internalCfg.ScaleMemThreshold = float32(config.ParseFloatEnv("ORCH_SCALE_MEM_THRESHOLD", 0.8))
	}
	if internalCfg.ScaleDelta == 0 {
		internalCfg.ScaleDelta = uint32(config.ParseIntEnv("ORCH_SCALE_DELTA", 1))
	}
	if internalCfg.DesiredCount == 0 {
		internalCfg.DesiredCount = uint32(config.ParseIntEnv("ORCH_DESIRED_COUNT", 0))
	}
	if internalCfg.ScaleCommand == "" {
		internalCfg.ScaleCommand = strings.TrimSpace(os.Getenv("ORCH_SCALE_CMD"))
	}
	if internalCfg.ScaleService == "" {
		internalCfg.ScaleService = os.Getenv("ORCH_SCALE_SERVICE")
	}
	if internalCfg.LogLevel == "" {
		internalCfg.LogLevel = os.Getenv("ORCH_LOG_LEVEL")
	}
	if internalCfg.Version == "" {
		internalCfg.Version = "0.0.1"
	}

	gossipNode, err := gossip.NewGossipNode(internalCfg)
	if err != nil {
		return nil, err
	}

	return &node{
		gossipNode: gossipNode,
		config:     cfg,
	}, nil
}

// Start begins the node's operation.
func (n *node) Start(ctx context.Context) error {
	return n.gossipNode.Start(ctx)
}

// Shutdown gracefully stops the node.
func (n *node) Shutdown() {
	n.gossipNode.Shutdown()
}

// IsLeader returns true if this node is the current Raft leader.
func (n *node) IsLeader() bool {
	// Access the raft node through gossip node
	// This requires adding a method to gossip.GossipNode
	return n.gossipNode.IsLeader()
}

// ClusterSize returns the number of nodes known to this node.
func (n *node) ClusterSize() int {
	return n.gossipNode.ClusterSize()
}

// AliveNodes returns the IDs of currently alive nodes (excluding self).
func (n *node) AliveNodes() []string {
	return n.gossipNode.AliveNodeIDs()
}

// AliveNodesInfo returns the information of currently alive nodes (including self).
func (n *node) AliveNodesInfo() []NodeInfo {
	nodes := n.gossipNode.AliveNodes()
	result := make([]NodeInfo, 0, len(nodes))
	for _, node := range nodes {
		if node == nil {
			continue
		}
		result = append(result, NodeInfo{
			ID:      node.Id,
			Addr:    node.Addr,
			Service: node.Service,
		})
	}
	return result
}
