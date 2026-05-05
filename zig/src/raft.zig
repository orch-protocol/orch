//! Simplified Raft consensus for leader election.
//! Implements RequestVote and AppendEntries (heartbeat-only, no log replication).
//! Uses TCP framing on gossip_port+1 for RPC transport.
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

const proto = @import("proto.zig");
const transport = @import("transport.zig");

fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub const Config = @import("config.zig").Config;

pub const Role = enum { follower, candidate, leader };

pub const RaftNode = struct {
    allocator: Allocator,
    io: Io,
    cfg: *const Config,

    // Identity
    self_id: []const u8,
    raft_addr: net.IpAddress,

    // Raft persistent state (protected by mu)
    mu: Mutex = .{},
    current_term: u64 = 0,
    voted_for: [128]u8 = undefined,
    voted_for_len: usize = 0,
    role: Role = .follower,
    leader_id: [128]u8 = undefined,
    leader_id_len: usize = 0,

    // Volatile state
    last_heartbeat_ns: i128 = 0,
    votes_received: u32 = 0,
    election_timeout_ns: u64,

    // TCP listener
    server: ?net.Server = null,

    // Peers callback (returns alive non-self NodeIds)
    peers_fn: *const fn (*RaftNode) []const proto.NodeId,
    peers_fn_ctx: *GossipContext,

    // Leadership change callback
    on_leader_change: *const fn (bool, u64) void,

    // Background group (shared with caller)
    group: *Io.Group,

    // ---------------------------------------------------------------------------
    // Init / Deinit
    // ---------------------------------------------------------------------------

    pub fn init(
        allocator: Allocator,
        io: Io,
        cfg: *const Config,
        self_id: []const u8,
        gossip_addr: net.IpAddress,
        peers_fn: *const fn (*RaftNode) []const proto.NodeId,
        peers_fn_ctx: *GossipContext,
        on_leader_change: *const fn (bool, u64) void,
        group: *Io.Group,
    ) Allocator.Error!*RaftNode {
        var seed: u64 = @intCast(nanoTimestamp() & 0xffffffffffffffff);
        seed ^= @intCast(@intFromPtr(self_id.ptr));
        var prng = std.Random.Xoshiro256.init(seed);
        const rand = prng.random();

        const min_ns = cfg.election_timeout_min_ms * std.time.ns_per_ms;
        const max_ns = cfg.election_timeout_max_ms * std.time.ns_per_ms;
        const election_timeout_ns = min_ns + rand.uintLessThan(u64, max_ns - min_ns);

        const node = try allocator.create(RaftNode);
        node.* = .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .self_id = self_id,
            .raft_addr = transport.raftAddr(gossip_addr),
            .election_timeout_ns = election_timeout_ns,
            .peers_fn = peers_fn,
            .peers_fn_ctx = peers_fn_ctx,
            .on_leader_change = on_leader_change,
            .group = group,
        };
        node.last_heartbeat_ns = nanoTimestamp();
        return node;
    }

    pub fn deinit(r: *RaftNode) void {
        if (r.server) |*s| s.deinit(r.io);
        r.allocator.destroy(r);
    }

    // ---------------------------------------------------------------------------
    // Start
    // ---------------------------------------------------------------------------

    pub fn start(r: *RaftNode) !void {
        r.server = try r.raft_addr.listen(r.io, .{});
        std.log.info("raft: TCP listener on port {}", .{r.raft_addr.getPort()});
        try r.group.concurrent(r.io, acceptLoop, .{r});
        try r.group.concurrent(r.io, electionLoop, .{r});
        try r.group.concurrent(r.io, leaderHeartbeatLoop, .{r});
    }

    // ---------------------------------------------------------------------------
    // Background loops
    // ---------------------------------------------------------------------------

    fn acceptLoop(r: *RaftNode) error{Canceled}!void {
        while (true) {
            const stream = r.server.?.accept(r.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            r.group.concurrent(r.io, handleRpcConn, .{ r, stream }) catch {
                stream.close(r.io);
            };
        }
    }

    fn handleRpcConn(r: *RaftNode, stream: net.Stream) error{Canceled}!void {
        defer stream.close(r.io);
        var rb: [4096]u8 = undefined;
        var wb: [4096]u8 = undefined;
        var reader = stream.reader(r.io, &rb);
        var writer = stream.writer(r.io, &wb);

        const result = transport.readTcpFrame(&reader.interface, r.allocator) catch return;
        defer r.allocator.free(result.buf);
        r.handleRpcFrame(result.frame, &writer.interface) catch {};
    }

    fn handleRpcFrame(r: *RaftNode, frame: transport.Frame, writer: *Io.Writer) !void {
        switch (frame.msg_type) {
            transport.MsgRaftRequestVote => {
                const req = try proto.decodeRequestVote(frame.payload);
                const reply = r.handleRequestVote(req);
                const payload = try proto.encode(proto.encodeRequestVoteReply, reply, r.allocator);
                defer r.allocator.free(payload);
                try transport.writeTcpFrame(writer, .{
                    .msg_type = transport.MsgRaftRequestVoteAck,
                    .flags = 0,
                    .seq_no = 0,
                    .payload = payload,
                }, r.allocator);
            },
            transport.MsgRaftAppendEntries => {
                const req = try proto.decodeAppendEntries(frame.payload);
                const reply = r.handleAppendEntries(req);
                const payload = try proto.encode(proto.encodeAppendEntriesReply, reply, r.allocator);
                defer r.allocator.free(payload);
                try transport.writeTcpFrame(writer, .{
                    .msg_type = transport.MsgRaftAppendEntriesAck,
                    .flags = 0,
                    .seq_no = 0,
                    .payload = payload,
                }, r.allocator);
            },
            else => {},
        }
    }

    fn electionLoop(r: *RaftNode) error{Canceled}!void {
        while (true) {
            // Check every ~10ms
            try r.io.sleep(.{ .nanoseconds = @as(i96, 10 * std.time.ns_per_ms) }, .awake);
            const now = nanoTimestamp();
            r.mu.lock();
            const role = r.role;
            const elapsed_ns: u64 = @intCast(now - r.last_heartbeat_ns);
            r.mu.unlock();

            if (role == .leader) continue;
            if (elapsed_ns < r.election_timeout_ns) continue;

            // Start election
            r.startElection() catch {};
        }
    }

    fn leaderHeartbeatLoop(r: *RaftNode) error{Canceled}!void {
        while (true) {
            try r.io.sleep(.{ .nanoseconds = @as(i96, 50 * std.time.ns_per_ms) }, .awake);
            r.mu.lock();
            const is_leader = r.role == .leader;
            const term = r.current_term;
            r.mu.unlock();
            if (!is_leader) continue;

            // Send AppendEntries (heartbeat) to all peers
            r.sendHeartbeats(term) catch {};
        }
    }

    // ---------------------------------------------------------------------------
    // Election
    // ---------------------------------------------------------------------------

    fn startElection(r: *RaftNode) !void {
        r.mu.lock();
        r.current_term += 1;
        const term = r.current_term;
        r.role = .candidate;
        r.votes_received = 1; // vote for self
        const self_id_copy = r.self_id;
        r.setVotedFor(self_id_copy);
        r.last_heartbeat_ns = nanoTimestamp();
        r.mu.unlock();

        std.log.info("raft: starting election, term={}", .{term});

        // Send RequestVote to all peers
        const peers = r.alivePeers();
        if (peers.len == 0) {
            // No peers → become leader immediately
            r.becomeLeader(term);
            return;
        }

        var votes: u32 = 1; // already voted for self
        const needed: u32 = @intCast(peers.len / 2 + 1);

        for (peers) |peer| {
            const granted = r.sendRequestVote(peer, term) catch false;
            if (granted) {
                votes += 1;
                if (votes >= needed + 1) break; // have quorum
            }
        }

        r.mu.lock();
        // Check if we're still a candidate for this term
        if (r.role == .candidate and r.current_term == term) {
            if (votes >= needed + 1 or votes >= 1 and peers.len == 0) {
                r.mu.unlock();
                r.becomeLeader(term);
                return;
            }
            r.role = .follower;
        }
        r.mu.unlock();
    }

    fn becomeLeader(r: *RaftNode, term: u64) void {
        r.mu.lock();
        r.role = .leader;
        @memcpy(r.leader_id[0..r.self_id.len], r.self_id);
        r.leader_id_len = r.self_id.len;
        r.mu.unlock();
        std.log.info("raft: became leader, term={}", .{term});
        r.on_leader_change(true, term);
    }

    fn sendRequestVote(r: *RaftNode, peer: proto.NodeId, term: u64) !bool {
        const peer_raft = transport.raftAddr(transport.parseAddr(peer.addr) catch return false);
        const stream = peer_raft.connect(r.io, .{ .mode = .stream }) catch return false;
        defer stream.close(r.io);

        var rb: [1024]u8 = undefined;
        var wb: [1024]u8 = undefined;
        var reader = stream.reader(r.io, &rb);
        var writer = stream.writer(r.io, &wb);

        const payload = try proto.encode(proto.encodeRequestVote, proto.RequestVote{
            .term = term,
            .candidate_id = r.self_id,
            .last_log_index = 0,
            .last_log_term = 0,
        }, r.allocator);
        defer r.allocator.free(payload);

        transport.writeTcpFrame(&writer.interface, .{
            .msg_type = transport.MsgRaftRequestVote,
            .flags = 0,
            .seq_no = 0,
            .payload = payload,
        }, r.allocator) catch return false;

        const result = transport.readTcpFrame(&reader.interface, r.allocator) catch return false;
        defer r.allocator.free(result.buf);

        if (result.frame.msg_type != transport.MsgRaftRequestVoteAck) return false;
        const reply = proto.decodeRequestVoteReply(result.frame.payload) catch return false;
        if (reply.term > term) {
            r.stepDown(reply.term);
            return false;
        }
        return reply.vote_granted;
    }

    fn sendHeartbeats(r: *RaftNode, term: u64) !void {
        const peers = r.alivePeers();
        for (peers) |peer| {
            r.sendAppendEntries(peer, term) catch {};
        }
    }

    fn sendAppendEntries(r: *RaftNode, peer: proto.NodeId, term: u64) !void {
        const peer_raft = transport.raftAddr(transport.parseAddr(peer.addr) catch return);
        const stream = peer_raft.connect(r.io, .{ .mode = .stream }) catch return;
        defer stream.close(r.io);

        var rb: [1024]u8 = undefined;
        var wb: [1024]u8 = undefined;
        var reader = stream.reader(r.io, &rb);
        var writer = stream.writer(r.io, &wb);

        const payload = try proto.encode(proto.encodeAppendEntries, proto.AppendEntries{
            .term = term,
            .leader_id = r.self_id,
        }, r.allocator);
        defer r.allocator.free(payload);

        try transport.writeTcpFrame(&writer.interface, .{
            .msg_type = transport.MsgRaftAppendEntries,
            .flags = 0,
            .seq_no = 0,
            .payload = payload,
        }, r.allocator);

        const result = transport.readTcpFrame(&reader.interface, r.allocator) catch return;
        defer r.allocator.free(result.buf);

        if (result.frame.msg_type != transport.MsgRaftAppendEntriesAck) return;
        const reply = proto.decodeAppendEntriesReply(result.frame.payload) catch return;
        if (reply.term > term) r.stepDown(reply.term);
    }

    // ---------------------------------------------------------------------------
    // RPC handlers
    // ---------------------------------------------------------------------------

    fn handleRequestVote(r: *RaftNode, req: proto.RequestVote) proto.RequestVoteReply {
        r.mu.lock();
        defer r.mu.unlock();

        if (req.term < r.current_term) {
            return .{ .term = r.current_term, .vote_granted = false };
        }
        if (req.term > r.current_term) {
            r.current_term = req.term;
            r.role = .follower;
            r.voted_for_len = 0;
        }
        // Grant vote if not yet voted or already voted for this candidate
        const already_voted_for = r.voted_for_len > 0 and
            std.mem.eql(u8, r.voted_for[0..r.voted_for_len], req.candidate_id);
        const can_vote = r.voted_for_len == 0 or already_voted_for;
        if (can_vote) {
            r.setVotedFor(req.candidate_id);
            r.last_heartbeat_ns = nanoTimestamp(); // reset timer
            return .{ .term = r.current_term, .vote_granted = true };
        }
        return .{ .term = r.current_term, .vote_granted = false };
    }

    fn handleAppendEntries(r: *RaftNode, req: proto.AppendEntries) proto.AppendEntriesReply {
        r.mu.lock();
        defer r.mu.unlock();

        if (req.term < r.current_term) {
            return .{ .term = r.current_term, .success = false };
        }
        if (req.term > r.current_term) {
            r.current_term = req.term;
        }
        r.role = .follower;
        r.last_heartbeat_ns = nanoTimestamp();

        // Record leader
        const lid = req.leader_id;
        if (lid.len <= r.leader_id.len) {
            @memcpy(r.leader_id[0..lid.len], lid);
            r.leader_id_len = lid.len;
        }
        // Notify if leadership has changed
        // (callback is intentionally called with mu held—keep it fast)
        r.on_leader_change(false, req.term);

        return .{ .term = r.current_term, .success = true };
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    fn stepDown(r: *RaftNode, new_term: u64) void {
        r.mu.lock();
        defer r.mu.unlock();
        if (new_term > r.current_term) {
            r.current_term = new_term;
            const was_leader = r.role == .leader;
            r.role = .follower;
            r.voted_for_len = 0;
            r.last_heartbeat_ns = nanoTimestamp();
            if (was_leader) r.on_leader_change(false, new_term);
        }
    }

    fn setVotedFor(r: *RaftNode, id: []const u8) void {
        const n = @min(id.len, r.voted_for.len);
        @memcpy(r.voted_for[0..n], id[0..n]);
        r.voted_for_len = n;
    }

    fn alivePeers(r: *RaftNode) []const proto.NodeId {
        return r.peers_fn(r);
    }

    pub fn isLeader(r: *RaftNode) bool {
        r.mu.lock();
        defer r.mu.unlock();
        return r.role == .leader;
    }

    pub fn currentTerm(r: *RaftNode) u64 {
        r.mu.lock();
        defer r.mu.unlock();
        return r.current_term;
    }

    /// Dynamic peer list injected by GossipNode. Must be set before start().
    pub const GossipContext = struct {
        gossip: *anyopaque, // *gossip.GossipNode – type-erased to avoid circular imports
        get_peers: *const fn (*anyopaque, Allocator) []proto.NodeId,
        get_peers_buf: []proto.NodeId = &.{},
        get_peers_mu: Mutex = .{},
    };
};
