package orch

import "time"

// Config holds the configuration for an ORCH node.
// All fields are optional except ClusterToken which is required.
type Config struct {
	// NodeID is a unique identifier for this node. If empty, a UUID will be generated.
	NodeID string

	// Addr is the address to advertise to other nodes (e.g., "node-1.internal:7946").
	// Other nodes will use this address to connect to this node.
	Addr string

	// BindAddr is the address to bind to (e.g., "0.0.0.0:7946").
	// If empty, Addr will be used for binding.
	BindAddr string

	// Seeds is a list of seed node addresses to join (e.g., ["192.168.1.1:7946"]).
	// If empty, this node will bootstrap a new cluster.
	Seeds []string

	// ClusterToken is a required cluster identifier. All nodes must use the same token.
	ClusterToken uint64

	// Service is the service name (e.g., "payment-service").
	Service string

	// Version is the version string. Default: "0.0.1"
	Version string

	// HeartbeatInterval is the interval between heartbeats. Default: 1s
	HeartbeatInterval time.Duration

	// HeartbeatTimeout is the timeout for heartbeat failure detection. Default: 3s
	HeartbeatTimeout time.Duration

	// SuspectTimeout is the timeout for suspect state before declaring dead. Default: 5s
	SuspectTimeout time.Duration

	// IndirectPingCount is the number of indirect pings for failure detection. Default: 3
	IndirectPingCount int

	// ElectionTimeoutMin is the minimum Raft election timeout. Default: 150ms
	ElectionTimeoutMin time.Duration

	// ElectionTimeoutMax is the maximum Raft election timeout. Default: 300ms
	ElectionTimeoutMax time.Duration

	// ScaleCommand is the command to execute for scaling operations.
	ScaleCommand string

	// ScaleInterval is the interval for scale evaluation. Default: 60s
	ScaleInterval time.Duration

	// ScaleCPUThreshold is the CPU threshold for scale-out (0.0-1.0). Default: 0.8
	ScaleCPUThreshold float32

	// ScaleMemThreshold is the memory threshold for scale-out (0.0-1.0). Default: 0.8
	ScaleMemThreshold float32

	// ScaleDelta is the number of processes to add/remove per scale operation. Default: 1
	ScaleDelta uint32

	// DesiredCount is the desired number of nodes for this service.
	// If set, the leader will attempt to maintain this count.
	DesiredCount uint32

	// LogLevel is the log level for internal and Raft logs (DEBUG, INFO, WARN, ERROR).
	// Default: "INFO" (Gossip), "WARN" (Raft)
	LogLevel string

	// ScaleService is the service name this node should monitor and scale.
	// If empty, the node's own Service name is used.
	ScaleService string
}
