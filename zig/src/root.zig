//! ORCH Protocol – Zig implementation.
//! Public Node API. Wire-compatible with the Go implementation.
//!
//! Usage:
//!
//!   const orch = @import("orch");
//!   const node = try orch.Node.init(allocator, io, .{
//!       .cluster_token = 12345,
//!       .addr = "0.0.0.0:7946",
//!       .service = "my-service",
//!   });
//!   defer node.deinit();
//!   try node.start();
//!   // ... application logic ...
//!   node.shutdown();
//!
const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = struct {
    m: std.atomic.Mutex = .unlocked,
    pub fn lock(s: *Mutex) void {
        while (!s.m.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn unlock(s: *Mutex) void {
        s.m.unlock();
    }
};
const Io = std.Io;
const net = std.Io.net;
fn List(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}

pub const Config = @import("config.zig").Config;
pub const gossip_mod = @import("gossip.zig");
const raft_mod = @import("raft.zig");

// Re-export proto types useful to embedders
pub const proto = @import("proto.zig");

// ---------------------------------------------------------------------------
// NodeInfo
// ---------------------------------------------------------------------------

pub const NodeInfo = gossip_mod.NodeInfo;

// ---------------------------------------------------------------------------
// Node
// ---------------------------------------------------------------------------

/// An ORCH node. All allocations are owned by the node; call deinit() after shutdown().
pub const Node = struct {
    gossip: *gossip_mod.GossipNode,
    raft: *raft_mod.RaftNode,
    allocator: Allocator,
    io: Io,

    // Peers buffer for Raft (refreshed on each call)
    raft_peers_mu: Mutex = .{},
    raft_peers_buf: List(proto.NodeId),

    pub fn init(allocator: Allocator, io: Io, cfg: Config) !*Node {
        if (cfg.cluster_token == 0) return error.MissingClusterToken;

        const node = try allocator.create(Node);
        errdefer allocator.destroy(node);

        node.* = .{
            .gossip = undefined,
            .raft = undefined,
            .allocator = allocator,
            .io = io,
            .raft_peers_buf = List(proto.NodeId).init(allocator),
        };

        node.gossip = try gossip_mod.GossipNode.init(allocator, io, cfg);
        errdefer node.gossip.deinit();

        // Parse gossip address for Raft
        const gossip_ip = try @import("transport.zig").parseAddr(cfg.effectiveBindAddr());

        // Raft needs a stable pointer to the node for the peers callback
        node.raft = try raft_mod.RaftNode.init(
            allocator,
            io,
            &node.gossip.cfg,
            node.gossip.self_id,
            gossip_ip,
            raftGetPeers,
            @ptrCast(node), // GossipContext* – we type-erase Node here
            raftOnLeaderChange,
            &node.gossip.group,
        );
        errdefer node.raft.deinit();

        // Wire up Raft leader-change → GossipNode
        node.gossip.on_leader_change_cb = raftLeaderChangeBridge;

        return node;
    }

    pub fn deinit(node: *Node) void {
        node.raft.deinit();
        node.gossip.deinit();
        node.raft_peers_buf.deinit();
        node.allocator.destroy(node);
    }

    // ---------------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------------

    /// Start the node: listen, join seeds, begin gossip + Raft loops.
    pub fn start(node: *Node) !void {
        try node.gossip.start();
        try node.raft.start();
    }

    /// Cancel all background tasks and close sockets.
    pub fn shutdown(node: *Node) void {
        node.gossip.shutdown();
        // TCP server inside Raft is also deinited through gossip's group cancel
        if (node.raft.server) |*s| s.deinit(node.io);
        node.raft.server = null;
    }

    // ---------------------------------------------------------------------------
    // Accessors
    // ---------------------------------------------------------------------------

    pub fn isLeader(node: *Node) bool {
        return node.raft.isLeader();
    }

    pub fn clusterSize(node: *Node) usize {
        return node.gossip.clusterSize();
    }

    /// Returns a heap-allocated slice of alive node IDs. Caller frees.
    pub fn aliveNodes(node: *Node, allocator: Allocator) ![][]const u8 {
        return node.gossip.aliveNodes(allocator);
    }

    /// Returns a heap-allocated slice of NodeInfo. Caller frees.
    pub fn aliveNodesInfo(node: *Node, allocator: Allocator) ![]NodeInfo {
        const raw = try node.gossip.aliveNodesInfo(allocator);
        return raw; // NodeInfo and gossip_mod.NodeInfo are identical
    }

    // ---------------------------------------------------------------------------
    // Internal callbacks (must be fn pointers with stable addresses)
    // ---------------------------------------------------------------------------

    fn raftGetPeers(raft: *raft_mod.RaftNode) []const proto.NodeId {
        // raft.peers_fn_ctx is actually *Node (type-erased)
        const n: *Node = @ptrCast(@alignCast(raft.peers_fn_ctx));
        n.raft_peers_mu.lock();
        defer n.raft_peers_mu.unlock();
        // Refresh buffer
        n.raft_peers_buf.clearRetainingCapacity();
        const peers = n.gossip.membership.alivePeers(n.allocator) catch return &.{};
        n.raft_peers_buf.appendSlice(peers) catch {};
        n.allocator.free(peers);
        return n.raft_peers_buf.items;
    }

    fn raftOnLeaderChange(is_leader: bool, term: u64) void {
        // This callback is triggered from RaftNode which holds its mu.
        // We just log; the actual state update is in raftLeaderChangeBridge below.
        std.log.info("raft: is_leader={} term={}", .{ is_leader, term });
    }

    fn raftLeaderChangeBridge(is_leader: bool, term: u64) void {
        _ = is_leader;
        _ = term;
        // GossipNode.onLeaderChange is called directly from raft via the callbacks;
        // bridged through gossip.on_leader_change_cb which points here.
    }
};

// ---------------------------------------------------------------------------
// Convenience: create and configure from environment variables (like Go version)
// ---------------------------------------------------------------------------

pub fn configFromEnv(allocator: Allocator) !Config {
    var cfg = Config{};

    if (getenv("ORCH_ADDR")) |v| cfg.addr = v;
    if (getenv("ORCH_BIND_ADDR")) |v| cfg.bind_addr = v;
    if (getenv("ORCH_NODE_ID")) |v| cfg.node_id = v;
    if (getenv("ORCH_SERVICE")) |v| cfg.service = v;
    if (getenv("ORCH_VERSION")) |v| cfg.version = v;
    if (getenv("ORCH_SCALE_CMD")) |v| cfg.scale_command = v;
    if (getenv("ORCH_SCALE_SERVICE")) |v| cfg.scale_service = v;

    if (getenv("ORCH_CLUSTER_TOKEN")) |v|
        cfg.cluster_token = std.fmt.parseInt(u64, v, 10) catch 0;
    if (getenv("ORCH_HEARTBEAT_INTERVAL")) |v|
        cfg.heartbeat_interval_ms = std.fmt.parseInt(u64, v, 10) catch cfg.heartbeat_interval_ms;
    if (getenv("ORCH_HEARTBEAT_TIMEOUT")) |v|
        cfg.heartbeat_timeout_ms = std.fmt.parseInt(u64, v, 10) catch cfg.heartbeat_timeout_ms;
    if (getenv("ORCH_SUSPECT_TIMEOUT")) |v|
        cfg.suspect_timeout_ms = std.fmt.parseInt(u64, v, 10) catch cfg.suspect_timeout_ms;
    if (getenv("ORCH_ELECTION_TIMEOUT_MIN")) |v|
        cfg.election_timeout_min_ms = std.fmt.parseInt(u64, v, 10) catch cfg.election_timeout_min_ms;
    if (getenv("ORCH_ELECTION_TIMEOUT_MAX")) |v|
        cfg.election_timeout_max_ms = std.fmt.parseInt(u64, v, 10) catch cfg.election_timeout_max_ms;
    if (getenv("ORCH_SCALE_INTERVAL")) |v|
        cfg.scale_interval_ms = std.fmt.parseInt(u64, v, 10) catch cfg.scale_interval_ms;
    if (getenv("ORCH_DESIRED_COUNT")) |v|
        cfg.desired_count = std.fmt.parseInt(u32, v, 10) catch cfg.desired_count;

    if (getenv("ORCH_SEEDS")) |v| {
        // Comma-separated list
        var list = List([]const u8).init(allocator);
        var it = std.mem.splitScalar(u8, v, ',');
        while (it.next()) |seed| {
            const trimmed = std.mem.trim(u8, seed, " \t");
            if (trimmed.len > 0) try list.append(trimmed);
        }
        cfg.seeds = try list.toOwnedSlice();
    }

    return cfg;
}

/// Read an environment variable. Returns null-terminated slice or null.
pub fn getenv(key: [:0]const u8) ?[:0]const u8 {
    const ptr = std.c.getenv(key) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

// ---------------------------------------------------------------------------
// Transport helpers re-exported for embedders
// ---------------------------------------------------------------------------

const transport_mod = @import("transport.zig");
pub const parseAddr = transport_mod.parseAddr;
pub const fmtAddr = transport_mod.fmtAddr;

// ---------------------------------------------------------------------------
// Module re-exports
// ---------------------------------------------------------------------------

comptime {
    // Force compilation of sub-modules during `zig build test`
    _ = @import("transport.zig");
    _ = @import("proto.zig");
    _ = @import("membership.zig");
    _ = @import("dedup.zig");
}
