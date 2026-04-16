# Orch Protocol Specification v0.2

Container-less Distributed Microservices Execution Environment.

## Overview

This specification defines a lightweight protocol for a distributed microservices execution environment that operates without Kubernetes or container runtimes. Each service binary includes built-in orchestration capabilities, allowing a cluster to self-organize simply by launching the binary.

### Design Principles

1.  **Container-less**: Go binaries run directly as OS processes.
2.  **Self-organizing**: Cluster joining is completed solely by launching the binary.
3.  **Language Agnostic**: Any language (e.g., Rust) can participate by implementing the protocol.
4.  **Minimal Resources**: Overheads for small-scale starts are minimized.
5.  **Gradual Scaling**: The same code operates from a single process to hundreds of nodes.

### Resource Comparison with Kubernetes

|                      | K8s (Minimum)                           | ORCH                           |
| -------------------- | --------------------------------------- | ------------------------------ |
| Control Plane        | etcd + APIServer + scheduler (~1GB RAM) | Zero (Distributed in binaries) |
| Container Runtime    | containerd, etc. (Always running)       | Zero                           |
| Per-service overhead | Pod overhead (tens of MBs)              | Go binary start (~10MB)        |
| Minimum Config       | 3 nodes recommended                     | From 1 process                 |

## Architecture Overview

```
┌─────────────────────────────────────────┐
│           Inside Each Binary            │
│                                         │
│  ┌─────────────┐   ┌─────────────────┐  │
│  │  Raft Layer  │   │  Gossip Layer   │  │
│  │             │   │                 │  │
│  │ - Leader    │◀──│ - DEAD Detection│  │
│  │   Election  │   │ - Node State    │  │
│  │ - Log       │   │   Propagation   │  │
│  │   Replication│──▶│ - Broadcast     │  │
│  │ - Scale Cmds │   │   Leader Info   │  │
│  └─────────────┘   └─────────────────┘  │
│         │                    │           │
│         ▼                    ▼           │
│  ┌─────────────┐   ┌─────────────────┐  │
│  │ Scale Exec  │   │ Transport Layer │  │
│  │ Layer       │   │                 │  │
│  │ - Start/Stop│   │ TCP (Raft/Mgmt) │  │
│  │   Processes │   │ UDP (Heartbeat) │  │
│  │ - Resource  │   │                 │  │
│  │   Monitoring│   │                 │  │
│  └─────────────┘   └─────────────────┘  │
└─────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer           | Responsibility                                       | Protocol  |
| --------------- | ---------------------------------------------------- | --------- |
| Transport       | Framing, Checksum, Connection Management             | TCP / UDP |
| Gossip          | Node State Propagation, Failure Detection, Discovery | UDP + TCP |
| Raft            | Leader Election, Log Replication, Strong Consistency | TCP (Orch Port + 1) |
| Scale Execution | Process Start/Stop, Resource Monitoring              | Local     |

### Port Allocation Notice

The protocol uses two separate communication channels. In the standard implementation, the Raft port is automatically derived from the Gossip/Orch port.

- **Orch Port (Default: 7946)**: Gossip, TCP Management, UDP Heartbeats.
- **Raft Port (Orch Port + 1)**: Raft consensus traffic.

**Dynamic Allocation (Port 0)**:
The protocol supports binding to port `:0` (OS-assigned). When the Orch port is 0, the Raft port is also assigned dynamically. Nodes participating with dynamic ports MUST advertise their actual bound addresses via the HELLO/Gossip layer.

**Crucial**: When running multiple nodes on a single host with static ports, ensure at least a 2-port gap between nodes.

## Serialization

### Protocol Buffers v3

- Schema flexibility (backward compatible field additions).
- Mature libraries exist for both Go and Rust.
- Does not use gRPC (see below).

### Why not gRPC?

Since gRPC runs on top of HTTP/2, it is not ideal for the high-frequency, small messages typical of gossip protocols. Furthermore, gossip is a peer-to-peer communication model where every node is equal, which structurally conflicts with gRPC's client/server model.

```
gRPC:     A → B  (A connects to B)
Gossip:   A ↔ B ↔ C ↔ A  (Symmetric; everyone is both server and client)
```

The internal protocol uses custom TCP/UDP + Protobuf, while gRPC is reserved for management interfaces only.

## Framing Specification

### TCP Frame

Used for management and Raft messages.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
├───────────────────────────────────────────────────────────────┤
│                    Magic (4 bytes) = 0x4F524348  ("ORCH")     │
├───────────────────────────────────────────────────────────────┤
│  Version (1 byte)  │  MsgType (1 byte)  │   Flags (2 bytes)  │
├───────────────────────────────────────────────────────────────┤
│                     Payload Length (4 bytes)                  │
├───────────────────────────────────────────────────────────────┤
│                     Sequence No. (8 bytes)                    │
├───────────────────────────────────────────────────────────────┤
│                  Checksum (4 bytes, CRC32C)                   │
├───────────────────────────────────────────────────────────────┤
│                  Payload (Protobuf, N bytes)                  │
└───────────────────────────────────────────────────────────────┘

Total Header: 24 bytes
```

| Field          | Size    | Description                                                      |
| -------------- | ------- | ---------------------------------------------------------------- |
| Magic          | 4 bytes | `0x4F524348` ("ORCH") for immediate detection of misconnections. |
| Version        | 1 byte  | Currently `0x01`. Increment on breaking changes.                 |
| MsgType        | 1 byte  | Message type identifier (see below).                             |
| Flags          | 2 bytes | Various flags (see below).                                       |
| Payload Length | 4 bytes | Byte length of the payload.                                      |
| Sequence No.   | 8 bytes | Monotonically increasing for replay protection and ordering.     |
| Checksum       | 4 bytes | CRC32C calculated over header + payload.                         |
| Payload        | N bytes | Protobuf serialized message.                                     |

### UDP Packet

Used for heartbeats. Lightweight since loss is acceptable.

```
├─────────────────────────────────┤
│  Magic (4 bytes)  0x4F524348   │
├─────────────────────────────────┤
│ Version │ MsgType │ Flags       │
├─────────────────────────────────┤
│      Payload Length (4 bytes)  │
├─────────────────────────────────┤
│   Payload (Protobuf, N bytes)  │
└─────────────────────────────────┘

Total Header: 12 bytes
```

### MsgType Definitions

```
// Node Join & Management
0x01  HELLO              Node join notification
0x02  HELLO_ACK          Join response (includes cluster_view)

// Failure Detection (UDP)
0x03  HEARTBEAT          Liveness check
0x04  HEARTBEAT_ACK      Liveness response

// Indirect Detection (SWIM Protocol Extension)
0x05  PING               Direct check
0x06  PING_REQ           Indirect check request
0x07  PING_ACK           Direct check response
0x08  PING_REQ_ACK       Indirect check result

// Gossip Events (TCP/UDP)
0x10  NODE_JOIN          Node join event propagation
0x11  NODE_LEAVE         Normal departure
0x12  NODE_DEAD          Failure detected and declared
0x13  NODE_SUSPECT       Suspicious state propagation

// Orchestration Commands (TCP, Leader only)
0x20  SCALE_OUT          Scale-out instruction
0x21  SCALE_IN           Scale-in instruction

// Service Info
0x30  SERVICE_INFO       Service metadata synchronization

// Raft (TCP)
0x40  RAFT_REQUEST_VOTE
0x41  RAFT_REQUEST_VOTE_REPLY
0x42  RAFT_APPEND_ENTRIES
0x43  RAFT_APPEND_ENTRIES_REPLY

// Error
0xFF  ERROR              Error response
```

### Flags Definitions

```
bit 0: COMPRESSED    Payload is zstd compressed
bit 1: ENCRYPTED     Payload is encrypted (Reserved for future use)
bit 2: REQUIRES_ACK  This message requires an ACK
bit 3-15: Reserved
```

## Protobuf Schema

```protobuf
syntax = "proto3";
package orch.v1;

// Node Identifier (Common to all messages)
message NodeId {
  string id        = 1;  // UUID v7 recommended (time-sortable)
  string addr      = 2;  // "192.168.1.1:7946"
  string service   = 3;  // "payment-service"
  string version   = 4;  // "1.2.0"
  bool   is_leader = 5;  // Raft leader flag
  uint64 term      = 6;  // Raft term (to detect stale info)
}

// Node Joining
message Hello {
  NodeId            node          = 1;
  uint64            cluster_token = 2;  // Cluster identifier (prevents mis-joining)
  repeated string   known_peers   = 3;  // List of known node addresses
}

message HelloAck {
  NodeId            node         = 1;
  repeated NodeId   cluster_view = 2;  // Current full cluster view
}

// Failure Detection (UDP)
message Heartbeat {
  NodeId node        = 1;
  uint64 timestamp   = 2;  // Unix nanosec
  float  cpu_usage   = 3;  // 0.0-1.0 (Measured via /proc/stat etc.)
  float  mem_usage   = 4;  // 0.0-1.0 (Measured via /proc/meminfo etc.)
  uint32 goroutines  = 5;  // Thread count for non-Go implementations
}

// Direct Confirmation
message Ping {
  uint64 request_id = 1;
  NodeId helper     = 2;  // Self node info
}

message PingAck {
  uint64 request_id = 1;
  NodeId helper     = 2;  // Responding node info
}

// Indirect Confirmation (SWIM Protocol)
message PingReq {
  uint64 request_id = 1;
  NodeId target     = 2;  // Target node to check
}

message PingReqAck {
  uint64 request_id = 1;
  NodeId target     = 2;
  bool   alive      = 3;  // Check result
}

// Gossip Event Propagation Wrapper
message GossipEnvelope {
  uint32 ttl     = 1;  // Remaining hops (Initial: ceil(log2(N)) * 2)
  uint64 msg_id  = 2;  // ID for deduplication
  bytes  payload = 3;  // Nested Protobuf message (e.g., NodeEvent)
}

// Node Event
message NodeEvent {
  enum EventType {
    JOIN    = 0;
    LEAVE   = 1;
    DEAD    = 2;
    SUSPECT = 3;
  }
  EventType type  = 1;
  NodeId    node  = 2;
  uint64    term  = 3;  // Event ordering guarantee
}

// Scale Signal (Leader only)
message ScaleSignal {
  enum Direction {
    OUT = 0;
    IN  = 1;
  }
  Direction direction = 1;
  string    service   = 2;
  uint32    delta     = 3;  // Magnitude of change
  string    reason    = 4;  // e.g., "cpu_threshold_exceeded"
}

// Raft Messages
message RequestVote {
  uint64 term           = 1;
  string candidate_id   = 2;
  uint64 last_log_index = 3;
  uint64 last_log_term  = 4;
}

message RequestVoteReply {
  uint64 term         = 1;
  bool   vote_granted = 2;
}

message AppendEntries {
  uint64            term            = 1;
  string            leader_id       = 2;
  uint64            prev_log_index  = 3;
  uint64            prev_log_term   = 4;
  repeated LogEntry entries         = 5;  // Heartbeat if empty
  uint64            leader_commit   = 6;
}

message AppendEntriesReply {
  uint64 term    = 1;
  bool   success = 2;
}

message LogEntry {
  uint64 index   = 1;
  uint64 term    = 2;
  bytes  command = 3;  // Nested Protobuf (e.g., ScaleSignal)
}

// Error Response
message ErrorResponse {
  uint32 code    = 1;
  string message = 2;
}
```

## Cluster Joining Algorithm

### Seed Nodes

Specified at startup via environment variables or configuration files.

```
ORCH_SEEDS=192.168.1.10:7946,192.168.1.11:7946
```

Seed nodes are not special; they are simply the initial contact points. The cluster remains functional even if seeds are down, as long as other nodes are alive.

### Startup Flow

```
Startup
 │
 ├─ SEEDS Empty ──▶ I am the Bootstrap Node
 │                  Create new cluster (term=0)
 │
 └─ SEEDS Present ──▶ Send HELLO
                      │
                      ├─ Response Received ──▶ Receive HELLO_ACK
                      │                        Get cluster_view
                      │                        Send HELLO to all nodes
                      │                        Start Gossip loop
                      │                        Start Raft loop
                      │
                      └─ No Seed Responds  ──▶ Retry with exponential backoff
                                               Reach limit -> Become Bootstrap Node
```

### Joining Sequence

```
New Node(A)          Seed Node(B)         Existing Nodes(C,D,E)
    │                     │                      │
    │── TCP HELLO ────────▶│                      │
    │                     │  Validate Token      │
    │◀── HELLO_ACK ────────│  (With cluster_view) │
    │                     │                      │
    │                     │── GossipEnvelope ───▶│
    │                     │   (NODE_JOIN: A)      │
    │                     │                      │
    │◀── TCP HELLO ─────────────────────────────  │
    │    (C,D,E connect to A directly)            │
    │── HELLO_ACK ──────────────────────────────▶ │
```

## Gossip Protocol

### Fanout Calculation

```
fanout = ceil(log2(N))

N=1    → fanout=0    (No propagation needed for single node)
N=2    → fanout=1
N=10   → fanout=4
N=100  → fanout=7
N=1000 → fanout=10
```

In each gossip round, random `fanout` nodes are selected for forwarding. Messages propagate to the entire cluster in logarithmic time.

### GossipEnvelope Processing

```
Upon receipt:
  1. msg_id is known  → Discard (Duplicate)
  2. ttl == 0         → Process but do not forward
  3. ttl > 0          → Process and forward with ttl-1 (Send to 'fanout' random nodes)

Initial TTL: ceil(log2(N)) * 2
```

### Deduplication Cache

```
Implementation: Ring Buffer
Size: 1024 entries (as chosen in implementation)

Note: While the spec draft mentioned max(1000 items, 60s),
      the implementation uses a fixed 1024-capacity buffer
      to reduce complexity while remaining practical.
```

## Failure Detection (SWIM-based)

### Node State Transitions

```
ALIVE ──── Heartbeat missed (HeartbeatTimeout) ────▶ SUSPECT
              │
              │ All indirect checks fail + SUSPECT_TIMEOUT elapsed
              ▼
            DEAD ──── Propagated to all nodes via Gossip
              
SUSPECT ──── Rebuttal received from node ────▶ ALIVE
```

### Indirect Detection

To avoid false positives due to local network issues, indirect checks are performed.

```
Procedure:
1. A misses B's heartbeat for HeartbeatTimeout.
2. A marks B as 'Investigating' and selects random helper nodes C, D, E.
3. A → C,D,E: PING_REQ ("Please check B for me").
4. C,D,E → B: PING.
5. If help responses indicate B is unresponsive -> A marks B as SUSPECT locally.
6. A initiates its own `SuspectTimeout` timer and propagates SUSPECT state via Gossip.

**Stability Rule (Local Timers)**:
To prevent cascading cluster collapse (Rumor Storms), a node MUST NOT transition a node from SUSPECT to DEAD based solely on a received gossip rumor. Each node MUST initialize its own local `SuspectTimeout` timer upon first learning of a suspicion. A node is only considered DEAD by the local observer if its local timer expires without receiving a rebuttal (Heartbeat) from the suspect.

Timer Defaults (Configurable):
  HEARTBEAT_INTERVAL   = 1000ms
  HEARTBEAT_TIMEOUT    = 3000ms   (3 missed beats)
  SUSPECT_TIMEOUT      = 5000ms   (Local rebuttal window)
  INDIRECT_PING_COUNT  = 3        (Number of helpers)
```

## Leader Election via Raft

### Division of Responsibilities

```
Raft Scope (Minimal):
  - Leader Election
  - ScaleSignal Action Logs
  - Cluster Configuration (e.g., total node count)

Gossip Scope (Unchanged):
  - Heartbeats / Liveness Monitoring
  - Node State Propagation
  - Service Metadata Sync
```

The Raft scope is intentionally kept small to minimize implementation complexity.

### Node State Transitions

```
Follower ─── ElectionTimeout elapsed ───▶ Candidate
    ▲                                      │
    │                                      │ Receives majority votes
    │                                      ▼
    └─────────────────────────────────── Leader
    
Candidate ─── Higher term received ──▶ Follower
Leader    ─── Higher term received ──▶ Follower
```

### Timer Defaults

```
ELECTION_TIMEOUT   = 150ms ~ 300ms  (Randomized to prevent split votes)
HEARTBEAT_INTERVAL = 50ms           (Leader -> Follower AppendEntries)
```

### Election Sequence

```
Follower(A)         Follower(B)        Follower(C)
    │                    │                  │
    │ Timeout            │                  │
    │ term++ → Candidate │                  │
    │                    │                  │
    │── RequestVote ────▶│                  │
    │── RequestVote ──────────────────────▶ │
    │                    │                  │
    │◀── VoteGranted ────│                  │
    │◀── VoteGranted ──────────────────────  │
    │                    │                  │
    │  Majority → Leader │                  │
    │── AppendEntries(Ø) ▶│                 │  (Serves as heartbeat)
    │── AppendEntries(Ø) ──────────────────▶│
```

### Gossip and Raft Coordination

```
Gossip → Raft:
  - SUSPECT: Do not notify (Handle within Gossip).
  - DEAD:    Notify (Leader considers re-election if self is DEAD).

Raft → Gossip:
  - Election Done: Propagate NodeId.is_leader=true, NodeId.term=N via Gossip.
```

### Split Brain Handling

```
Scenario: [A(Leader), B, C] | [D, E] (Original 5 nodes)

[A,B,C] side: Quorum=3 (Majority) -> Continues operation.
[D,E] side:   Quorum=2 (Less than majority)
                -> Attempts election but fails to gather votes.
                -> Enters No Leader state.
```

---

## Scale Execution Layer

### Scale-out (SCALE_OUT) Trigger

The Leader periodically monitors the average resource usage of the cluster.

```
Scaling Logic (Pseudo-code):
  // Monitor resource usage of the cluster (self or delegated service)
  target_service = ORCH_SCALE_SERVICE || self.service
  current_count = gossip.ServiceCount(target_service)
  
  // 1. Maintain Minimum Count (Self-Healing)
  if (current_count < ORCH_DESIRED_COUNT) {
    launch_nodes(ORCH_DESIRED_COUNT - current_count)
  }

  // 2. Resource-based Scaling
  if (avg_cpu >= CPU_THRESHOLD or avg_mem >= MEM_THRESHOLD) {
    ScaleSignal {
      direction: OUT
      service: target_service
      delta: 1
      reason: "cpu=0.85"
    }
  }
```

### Scale-in (SCALE_IN) Trigger

```
if (avg_cpu <= CPU_THRESHOLD/2 and avg_mem <= MEM_THRESHOLD/2 and cluster_size > 1) {
  ScaleSignal {
    direction: IN
    service: self.service
    delta: 1
    reason: "cpu=0.30 mem=0.25"
  }
  -> Stops the most recently started process via signal.
}
```

### Configuration Values

```
ORCH_SCALE_INTERVAL      = 60s       // Evaluation cycle
ORCH_SCALE_CPU_THRESHOLD = 0.8       // Scale out if > 80%
ORCH_SCALE_MEM_THRESHOLD = 0.8       // Scale out if > 80%
ORCH_SCALE_DELTA          = 1        // Processes to add/remove per cycle
ORCH_SCALE_CMD            = "..."    // Command to execute for scaling
```

### Scale Command Implementation

```bash
# Example: Using Systemd
ORCH_SCALE_CMD="systemctl start orch-worker-$ORCH_CLUSTER_TOKEN"

# Example: Starting a Docker container (outside protocol scope)
ORCH_SCALE_CMD="docker run -e ORCH_SEEDS=$ORCH_ADDR orch:latest"
```

Environment Variable Substitutions:
- `$ORCH_ADDR`: Current binary address
- `$ORCH_SERVICE`: Service name
- `$ORCH_CLUSTER_TOKEN`: Cluster token

## Metrics Measurement

### CPU Usage

```
Linux: Calculated from /proc/stat
  - Fetch user, nice, system, idle, iowait times.
  - cpu_usage = (user + system) / (user + nice + system + idle + iowait)

Go: Dummy values generated via math/rand for testing.
  - cpu_usage = rand.Float32()
```

### Memory Usage

```
Linux: Calculated from /proc/meminfo and /proc/self/status
  - mem_usage = resident_set_size / total_memory

Go: Derived from runtime.MemStats
  - mem_usage = alloc / total_alloc_limit (Estimated)
```

### Goroutine Count (Go-specific)

```
Fetched via runtime.NumGoroutine()
```

## Environment Variable Reference

| Variable                    | Default        | Description                               |
| --------------------------- | -------------- | ----------------------------------------- |
| `ORCH_NODE_ID`              | Auto-generated | Node ID (UUID v7 recommended)             |
| `ORCH_ADDR`                 | `0.0.0.0:7946` | Listen address                            |
| `ORCH_SERVICE`              | (None)         | Service name (e.g., `payment-service`)    |
| `ORCH_VERSION`              | `0.0.1`        | Version string                            |
| `ORCH_CLUSTER_TOKEN`        | (Required)     | Cluster identifier (64-bit int)           |
| `ORCH_SEEDS`                | (None)         | Seed node addresses (comma-separated)     |
| `ORCH_HEARTBEAT_INTERVAL`   | `1000ms`       | Interval for sending heartbeats           |
| `ORCH_HEARTBEAT_TIMEOUT`    | `3000ms`       | Threshold for heartbeat failure           |
| `ORCH_SUSPECT_TIMEOUT`      | `5000ms`       | Duration of the SUSPECT state             |
| `ORCH_INDIRECT_PING_COUNT`  | `3`            | Number of helper nodes for indirect check |
| `ORCH_ELECTION_TIMEOUT_MIN` | `150ms`        | Min Raft election timeout                 |
| `ORCH_ELECTION_TIMEOUT_MAX` | `300ms`        | Max Raft election timeout                 |
| `ORCH_SCALE_CMD`            | (None)         | Command to run for scaling                |
| `ORCH_SCALE_INTERVAL`       | `60s`          | Scale evaluation cycle                    |
| `ORCH_SCALE_CPU_THRESHOLD`  | `0.8`          | CPU usage threshold (0.0-1.0)             |
| `ORCH_SCALE_MEM_THRESHOLD`  | `0.8`          | Memory usage threshold (0.0-1.0)          |
| `ORCH_SCALE_DELTA`          | `1`            | Processes to add/remove per scale event   |
| `ORCH_SCALE_SERVICE`        | (Self)         | Target service name to monitor/scale      |
| `ORCH_DESIRED_COUNT`        | `0`            | Target node count to maintain (Healing)   |

## Security Notes

### Authentication & Encryption (Planned for v0.3+)

The following features are NOT implemented in v0.2:

- TLS/SSL communication
- Node authentication
- Scale command verification

Recommendations for production environments:
- Protect communication via VPN/IPsec.
- Use verifiable signatures for scale commands.
- Generate cluster tokens with sufficient entropy.

## Version History

### v0.1 (Initial Draft)
- Basic protocol definitions.
- Outlines of Gossip, Raft, and Scale Execution layers.

### v0.2 (This Version)
- Refinements based on implementation experience.
- Specified metrics measurement methods.
- Detailed SWIM indirect detection.
- Unified DedupCache to capacity-based sizing.
- Added detailed specifications for Scale Execution layer.
- Implemented **Cross-Service Monitoring** (Scale one service based on another's load).
- Added **Self-Healing** support via DesiredCount maintenance.
- Stabilized failure detection with **Local Suspect Timers** and **Investigation Phase**.
- Completed Environment Variable Reference.

## Implementation Guidelines

### Recommended Order

1.  **Transport Layer** (TCP/UDP Framing)
2.  **Membership Management** (Node tracking)
3.  **Gossip Layer** (State propagation)
4.  **Failure Detection Layer** (SWIM/SuspectDetection)
5.  **Raft Integration** (Leader election)
6.  **Scale Execution Layer** (Process management)

### Test Checklist

- [x] Cluster join and convergence with 3+ nodes.
- [x] Transition from heartbeat failure to SUSPECT → DEAD.
- [x] Logarithmic time propagation of gossip messages.
- [x] Behavior during Split Brain scenarios.
- [x] Scale signals from Leader.
- [ ] Auto scale-out on CPU/Memory spike.

For a ready-to-use demonstration of these features, refer to the [multi-machine example](./examples/loadbalancer_multi/).

### Go Public API

In the Go implementation, `internal/` packages are hidden, and `github.com/orch-protocol/orch` provides the public API.

```go
import "github.com/orch-protocol/orch"

// Create configuration
config := &orch.Config{
    ClusterToken: 12345,
    Addr:         "127.0.0.1:7946",
    Service:      "my-service",
}

// Initialize and start node
node, err := orch.NewNode(config)
// ...
```

Public API Interface:

```go
// NodeInfo contains information about a node in the cluster.
type NodeInfo struct {
    ID      string
    Addr    string
    Service string
}

type Node interface {
    Start(ctx context.Context) error
    Shutdown()
    IsLeader() bool
    ClusterSize() int
    AliveNodes() []string
    AliveNodesInfo() []NodeInfo
}
```

Refer to [USAGE.md](./USAGE.md) for detailed examples.

## FAQ

**Q1: Can I optimize heartbeat calculations?**

A: The default `HeartbeatInterval` is 1s, but it can be lowered to 100ms in low-latency environments. It is lightweight (~12 bytes UDP header + ~100 bytes payload).

**Q2: Does it scale beyond 1000 nodes?**

A: Due to the fanout calculation, messages propagate in O(log N). However, CPU benchmarks have not been conducted at that scale. Consider adaptive gossip intervals or batching for very large clusters.

**Q3: Connection refused during local testing?**

A: Ensure you bind to `127.0.0.1` explicitly if you're testing on macOS or Linux with IPv6 enabled. Some clients default to IPv4 when connecting to `127.0.0.1` but the server might only be listening on IPv6 if using `""` or `0.0.0.0`.

**Q4: Port conflict on startup?**

A: Orch uses `Port+1` for Raft. If Node A is on 7946 (Raft: 7947), Node B cannot be on 7947. Use non-sequential ports for local clusters.

**Q3: How to ensure compatibility between different language implementations?**

A: Strictly follow the Protocol Buffers IDL and framing specification. Test procedure:
1. Generate Protobuf code for the target language.
2. Send/receive TCP frames using a test binary.
3. Verify Magic, Version, and Checksum.

**Q4: Security measures for private networks?**

A: Minimum requirements:
- Set `ORCH_CLUSTER_TOKEN` to an unpredictable value.
- Restrict ports via firewall.
- Distribute seed addresses through trusted channels.

## References

- SWIM Protocol: Scalable Weakly-consistent Infection-style Process Group Membership Protocol
  - A. Das, I. Gupta, A. Motivala (2002)
- Raft Consensus Algorithm: In Search of an Understandable Consensus Algorithm
  - D. Ongaro, J. Ousterhout (2014)

## License

The Orch Protocol is public domain.