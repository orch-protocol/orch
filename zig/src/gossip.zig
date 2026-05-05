//! ORCH Gossip Node – SWIM-based membership with gossip dissemination.
//! Uses std.Io.Evented for all I/O and std.Io.concurrent() for background loops.
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

fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}
fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), 1_000_000));
}

const config_mod = @import("config.zig");
const proto = @import("proto.zig");
const transport = @import("transport.zig");
const membership_mod = @import("membership.zig");
const dedup_mod = @import("dedup.zig");

pub const Config = config_mod.Config;
pub const Membership = membership_mod.Membership;
pub const NodeState = membership_mod.NodeState;
pub const DedupCache = dedup_mod.DedupCache;

// ---------------------------------------------------------------------------
// Ping waiter (for direct PING / indirect PING_REQ flows)
// ---------------------------------------------------------------------------

const PingWaiter = struct {
    event: Io.Event = .unset,
    result: bool = false,
};

const PingReqWaiter = struct {
    event: Io.Event = .unset,
    result: bool = false,
};

// ---------------------------------------------------------------------------
// NodeInfo (public)
// ---------------------------------------------------------------------------
pub const NodeInfo = struct {
    id: []const u8,
    addr: []const u8,
    service: []const u8,
};

// ---------------------------------------------------------------------------
// GossipNode
// ---------------------------------------------------------------------------

pub const GossipNode = struct {
    allocator: Allocator,
    io: Io,
    cfg: Config,

    // Identity
    self_id: []u8, // owned

    // Protocol state
    membership: Membership,
    dedup: DedupCache,
    seq_no: std.atomic.Value(u64) = .init(0),
    msg_id: std.atomic.Value(u64) = .init(0),

    // Network
    tcp_server: ?net.Server = null,
    udp_socket: ?net.Socket = null,

    // Ping state (for SWIM failure detection)
    ping_mu: Mutex = .{},
    ping_waiters: std.AutoHashMapUnmanaged(u64, *PingWaiter) = .{},
    pingreq_mu: Mutex = .{},
    pingreq_waiters: std.AutoHashMapUnmanaged(u64, *PingReqWaiter) = .{},

    // PRNG for random selection (used with mu held)
    prng_mu: Mutex = .{},
    prng: std.Random.Xoshiro256,

    // Background task group
    group: Io.Group = .init,

    // Callbacks
    on_leader_change_cb: ?*const fn (bool, u64) void = null,
    on_scale_signal_cb: ?*const fn (proto.ScaleSignal) void = null,

    // ---------------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------------

    pub fn init(allocator: Allocator, io: Io, cfg: Config) !*GossipNode {
        if (cfg.cluster_token == 0) return error.MissingClusterToken;

        // Generate node ID if not provided
        var id_buf: [36]u8 = undefined;
        const id_str = if (cfg.node_id.len > 0)
            cfg.node_id
        else blk: {
            const ts: u64 = @intCast(milliTimestamp());
            const pid: u32 = @intCast(std.c.getpid());
            const id_slice = std.fmt.bufPrint(&id_buf, "{x:0>12}-{x:0>8}-orch", .{ ts & 0xffffffffffff, pid }) catch &id_buf;
            break :blk id_slice;
        };

        const self_id = try allocator.dupe(u8, id_str);
        errdefer allocator.free(self_id);

        const self_node = proto.NodeId{
            .id = self_id,
            .addr = cfg.addr,
            .service = cfg.service,
            .version = cfg.version,
        };

        const mem = try Membership.init(allocator, self_node);
        const dedup = try DedupCache.init(allocator, 2048);

        const seed: u64 = @intCast(nanoTimestamp() & 0xffffffffffffffff);

        const g = try allocator.create(GossipNode);
        g.* = .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .self_id = self_id,
            .membership = mem,
            .dedup = dedup,
            .prng = std.Random.Xoshiro256.init(seed),
        };
        return g;
    }

    pub fn deinit(g: *GossipNode) void {
        g.membership.deinit();
        g.dedup.deinit();
        // Free ping waiter maps
        g.ping_mu.lock();
        g.ping_waiters.deinit(g.allocator);
        g.ping_mu.unlock();
        g.pingreq_mu.lock();
        g.pingreq_waiters.deinit(g.allocator);
        g.pingreq_mu.unlock();
        g.allocator.free(g.self_id);
        g.allocator.destroy(g);
    }

    // ---------------------------------------------------------------------------
    // Start / Shutdown
    // ---------------------------------------------------------------------------

    pub fn start(g: *GossipNode) !void {
        const io = g.io;
        const bind_addr = g.cfg.effectiveBindAddr();

        // TCP listener
        const tcp_ip = try transport.parseAddr(bind_addr);
        g.tcp_server = try tcp_ip.listen(io, .{});
        // Update advertised addr if port was 0 (OS-assigned)
        {
            const actual_port = g.tcp_server.?.socket.address.getPort();
            g.membership.updateSelf(false, 0);
            _ = actual_port; // addr update handled in updateSelf flow
        }
        std.log.info("orch: TCP listening on {s}", .{bind_addr});

        // UDP socket (same port as TCP)
        const udp_ip = try transport.parseAddr(bind_addr);
        g.udp_socket = try udp_ip.bind(io, .{ .mode = .dgram });
        std.log.info("orch: UDP bound on {s}", .{bind_addr});

        // Join seeds before starting loops to reduce startup race
        if (g.cfg.seeds.len > 0) {
            g.joinSeeds() catch |err|
                std.log.warn("orch: seed join failed (will bootstrap): {}", .{err});
        }

        // Start background loops via io.concurrent()
        try g.group.concurrent(io, tcpAcceptLoop, .{g});
        try g.group.concurrent(io, udpReceiveLoop, .{g});
        try g.group.concurrent(io, heartbeatLoop, .{g});
        try g.group.concurrent(io, failureDetectLoop, .{g});
    }

    pub fn shutdown(g: *GossipNode) void {
        const io = g.io;
        g.group.cancel(io);
        g.group.await(io) catch {};
        if (g.tcp_server) |*s| s.deinit(io);
        if (g.udp_socket) |*s| s.close(io);
        g.tcp_server = null;
        g.udp_socket = null;
    }

    // ---------------------------------------------------------------------------
    // Accessors
    // ---------------------------------------------------------------------------

    pub fn isLeader(g: *GossipNode) bool {
        const self = g.membership.selfNode();
        return self.is_leader;
    }

    pub fn clusterSize(g: *GossipNode) usize {
        return g.membership.count();
    }

    pub fn aliveNodes(g: *GossipNode, allocator: Allocator) ![][]const u8 {
        const peers = try g.membership.alivePeers(allocator);
        defer allocator.free(peers);
        var ids = try allocator.alloc([]const u8, peers.len);
        for (peers, 0..) |p, i| ids[i] = p.id;
        return ids;
    }

    pub fn aliveNodesInfo(g: *GossipNode, allocator: Allocator) ![]NodeInfo {
        const snp = try g.membership.snapshot(allocator);
        defer allocator.free(snp);
        var list = List(NodeInfo).init(allocator);
        for (snp) |m| {
            if (m.state == .dead) continue;
            try list.append(.{ .id = m.id, .addr = m.addr, .service = m.service });
        }
        return list.toOwnedSlice();
    }

    pub fn serviceCount(g: *GossipNode, service: []const u8) usize {
        return g.membership.serviceCount(service);
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    fn nextSeq(g: *GossipNode) u64 {
        return g.seq_no.fetchAdd(1, .monotonic);
    }

    fn nextMsgId(g: *GossipNode) u64 {
        return g.msg_id.fetchAdd(1, .monotonic) + 1;
    }

    fn randN(g: *GossipNode, n: usize) usize {
        g.prng_mu.lock();
        defer g.prng_mu.unlock();
        return g.prng.random().uintLessThan(usize, n);
    }

    fn gossipFanout(g: *GossipNode) usize {
        const n = g.membership.count();
        if (n < 2) return 0;
        return @max(2, @as(usize, @intFromFloat(@log(@as(f64, @floatFromInt(n))) + 1.0)));
    }

    /// Encode a message and return owned []u8.
    fn encode(g: *GossipNode, comptime fn_enc: anytype, msg: anytype) ![]u8 {
        return proto.encode(fn_enc, msg, g.allocator);
    }

    // ---------------------------------------------------------------------------
    // TCP server (accept loop)
    // ---------------------------------------------------------------------------

    fn tcpAcceptLoop(g: *GossipNode) error{Canceled}!void {
        while (true) {
            const stream = g.tcp_server.?.accept(g.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            // Spawn a concurrent handler for each connection
            g.group.concurrent(g.io, handleTcpConn, .{ g, stream }) catch {
                stream.close(g.io);
            };
        }
    }

    fn handleTcpConn(g: *GossipNode, stream: net.Stream) error{Canceled}!void {
        defer stream.close(g.io);
        var read_buf: [4096]u8 = undefined;
        var tcp_reader = stream.reader(g.io, &read_buf);
        var write_buf: [4096]u8 = undefined;
        var tcp_writer = stream.writer(g.io, &write_buf);

        while (true) {
            const result = transport.readTcpFrame(&tcp_reader.interface, g.allocator) catch {
                return; // connection closed or error
            };
            defer g.allocator.free(result.buf);
            g.handleTcpFrame(result.frame, &tcp_writer.interface) catch {
                return;
            };
        }
    }

    fn handleTcpFrame(g: *GossipNode, frame: transport.Frame, writer: *Io.Writer) !void {
        switch (frame.msg_type) {
            transport.MsgHello => try g.handleHello(frame, writer),
            transport.MsgHelloAck => try g.handleHelloAck(frame),
            transport.MsgNodeJoin,
            transport.MsgNodeLeave,
            transport.MsgNodeDead,
            transport.MsgNodeSuspect,
            => try g.handleGossipFrame(frame),
            transport.MsgScaleOut, transport.MsgScaleIn => try g.handleScaleFrame(frame),
            else => {
                std.log.warn("orch: unknown TCP msg type 0x{x:02}", .{frame.msg_type});
            },
        }
    }

    // ---------------------------------------------------------------------------
    // HELLO / HELLO_ACK
    // ---------------------------------------------------------------------------

    fn handleHello(g: *GossipNode, frame: transport.Frame, writer: *Io.Writer) !void {
        var arena = std.heap.ArenaAllocator.init(g.allocator);
        defer arena.deinit();
        const hello = proto.decodeHello(frame.payload, arena.allocator()) catch return;
        if (hello.cluster_token != g.cfg.cluster_token) {
            std.log.warn("orch: cluster token mismatch from {s}", .{hello.node.?.id});
            return;
        }
        if (hello.node) |n| _ = g.membership.addOrRevive(n);

        // Build cluster view
        const view = try g.membership.clusterView(g.allocator);
        defer g.allocator.free(view);

        const ack_payload = try g.encode(proto.encodeHelloAck, proto.HelloAck{
            .node = g.membership.selfNode(),
            .cluster_view = view,
        });
        defer g.allocator.free(ack_payload);

        try transport.writeTcpFrame(writer, .{
            .msg_type = transport.MsgHelloAck,
            .flags = 0,
            .seq_no = g.nextSeq(),
            .payload = ack_payload,
        }, g.allocator);
    }

    fn handleHelloAck(g: *GossipNode, frame: transport.Frame) !void {
        var arena = std.heap.ArenaAllocator.init(g.allocator);
        defer arena.deinit();
        const ack = proto.decodeHelloAck(frame.payload, arena.allocator()) catch return;
        if (ack.node) |n| _ = g.membership.addOrRevive(n);
        for (ack.cluster_view) |n| {
            if (std.mem.eql(u8, n.id, g.self_id)) continue;
            _ = g.membership.addOrUpdate(n);
        }
    }

    // ---------------------------------------------------------------------------
    // HELLO handshake (outbound – joining seeds)
    // ---------------------------------------------------------------------------

    fn sendHello(g: *GossipNode, addr: []const u8) !void {
        const ip = try transport.parseAddr(addr);
        const stream = try ip.connect(g.io, .{ .mode = .stream });
        defer stream.close(g.io);

        var read_buf: [8192]u8 = undefined;
        var tcp_reader = stream.reader(g.io, &read_buf);
        var write_buf: [4096]u8 = undefined;
        var tcp_writer = stream.writer(g.io, &write_buf);

        const known = try g.membership.knownPeerAddrs(g.allocator);
        defer g.allocator.free(known);

        const payload = try g.encode(proto.encodeHello, proto.Hello{
            .node = g.membership.selfNode(),
            .cluster_token = g.cfg.cluster_token,
            .known_peers = known,
        });
        defer g.allocator.free(payload);

        try transport.writeTcpFrame(&tcp_writer.interface, .{
            .msg_type = transport.MsgHello,
            .flags = 0,
            .seq_no = g.nextSeq(),
            .payload = payload,
        }, g.allocator);

        const result = try transport.readTcpFrame(&tcp_reader.interface, g.allocator);
        defer g.allocator.free(result.buf);
        if (result.frame.msg_type == transport.MsgHelloAck) {
            try g.handleHelloAck(result.frame);
        }
    }

    fn joinSeeds(g: *GossipNode) !void {
        var last_err: anyerror = error.NoSeeds;
        for (g.cfg.seeds) |seed| {
            if (std.mem.eql(u8, seed, g.cfg.addr)) continue;
            if (std.mem.eql(u8, seed, g.cfg.bind_addr)) continue;
            std.log.info("orch: sending HELLO to seed {s}", .{seed});
            g.sendHello(seed) catch |err| {
                std.log.warn("orch: seed {s} unreachable: {}", .{ seed, err });
                last_err = err;
                continue;
            };
            std.log.info("orch: joined cluster via {s}", .{seed});
            return;
        }
        return last_err;
    }

    // ---------------------------------------------------------------------------
    // UDP receive loop
    // ---------------------------------------------------------------------------

    fn udpReceiveLoop(g: *GossipNode) error{Canceled}!void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const msg = g.udp_socket.?.receive(g.io, &buf) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            const frame = transport.unmarshalUdp(msg.data) catch continue;
            g.handleUdpFrame(frame, msg.from) catch continue;
        }
    }

    fn handleUdpFrame(g: *GossipNode, frame: transport.UdpFrame, from: net.IpAddress) !void {
        switch (frame.msg_type) {
            transport.MsgHeartbeat => try g.handleHeartbeat(frame, from),
            transport.MsgHeartbeatAck => try g.handleHeartbeatAck(frame),
            transport.MsgPing => try g.handlePing(frame, from),
            transport.MsgPingAck => try g.handlePingAck(frame),
            transport.MsgPingReq => try g.handlePingReq(frame, from),
            transport.MsgPingReqAck => try g.handlePingReqAck(frame),
            else => {},
        }
    }

    // ---------------------------------------------------------------------------
    // Heartbeat
    // ---------------------------------------------------------------------------

    fn heartbeatLoop(g: *GossipNode) error{Canceled}!void {
        const interval_ns = g.cfg.heartbeat_interval_ms * std.time.ns_per_ms;
        while (true) {
            try g.io.sleep(.{ .nanoseconds = @as(i96, interval_ns) }, .awake);
            g.broadcastHeartbeat();
        }
    }

    fn broadcastHeartbeat(g: *GossipNode) void {
        const self = g.membership.selfNode();
        const payload = g.encode(proto.encodeHeartbeat, proto.Heartbeat{
            .node = self,
            .timestamp = @intCast(nanoTimestamp()),
            .goroutines = 0,
        }) catch return;
        defer g.allocator.free(payload);

        g.membership.recordHeartbeat(self, 0, 0, 0);

        const frame = transport.UdpFrame{
            .msg_type = transport.MsgHeartbeat,
            .flags = 0,
            .payload = payload,
        };
        const framed = transport.marshalUdp(frame, g.allocator) catch return;
        defer g.allocator.free(framed);

        const peers = g.membership.knownPeerAddrs(g.allocator) catch return;
        defer g.allocator.free(peers);

        for (peers) |addr| {
            const ip = transport.parseAddr(addr) catch continue;
            g.udp_socket.?.send(g.io, &ip, framed) catch {};
        }
    }

    fn handleHeartbeat(g: *GossipNode, frame: transport.UdpFrame, from: net.IpAddress) !void {
        const hb = try proto.decodeHeartbeat(frame.payload);
        const node = hb.node orelse return;
        g.membership.recordHeartbeat(node, hb.cpu_usage, hb.mem_usage, hb.goroutines);

        // Send ACK
        const self = g.membership.selfNode();
        const ack_payload = try g.encode(proto.encodeHeartbeat, proto.Heartbeat{
            .node = self,
            .timestamp = @intCast(nanoTimestamp()),
        });
        defer g.allocator.free(ack_payload);
        const ack_frame = transport.UdpFrame{
            .msg_type = transport.MsgHeartbeatAck,
            .flags = 0,
            .payload = ack_payload,
        };
        const framed = try transport.marshalUdp(ack_frame, g.allocator);
        defer g.allocator.free(framed);
        g.udp_socket.?.send(g.io, &from, framed) catch {};
    }

    fn handleHeartbeatAck(g: *GossipNode, frame: transport.UdpFrame) !void {
        const hb = try proto.decodeHeartbeat(frame.payload);
        const node = hb.node orelse return;
        g.membership.recordHeartbeat(node, hb.cpu_usage, hb.mem_usage, hb.goroutines);
    }

    // ---------------------------------------------------------------------------
    // SWIM failure detection
    // ---------------------------------------------------------------------------

    fn failureDetectLoop(g: *GossipNode) error{Canceled}!void {
        const interval_ns = g.cfg.heartbeat_interval_ms * std.time.ns_per_ms / 2;
        while (true) {
            try g.io.sleep(.{ .nanoseconds = @as(i96, interval_ns) }, .awake);
            g.checkFailures();
        }
    }

    fn checkFailures(g: *GossipNode) void {
        const now = nanoTimestamp();
        const timeout_ns: i128 = @intCast(g.cfg.heartbeat_timeout_ms * std.time.ns_per_ms);
        const suspect_timeout_ns: i128 = @intCast(g.cfg.suspect_timeout_ms * std.time.ns_per_ms);

        const snp = g.membership.snapshot(g.allocator) catch return;
        defer g.allocator.free(snp);

        for (snp) |m| {
            if (m.is_self) continue;
            if (m.state == .dead) continue;

            if (m.state == .suspect) {
                if (now - m.suspect_since_ns >= suspect_timeout_ns) {
                    if (g.membership.markDead(m.id)) {
                        std.log.info("orch: node {s} → DEAD", .{m.id});
                        g.broadcastNodeEvent(.dead, m.toProto());
                    }
                }
                continue;
            }

            if (m.investigating) continue;

            if (now - m.last_seen_ns > timeout_ns) {
                g.membership.setInvestigating(m.id, true);
                // Copy id for the goroutine (id borrows from membership, but membership
                // may update it; take an allocator copy to be safe)
                const id_copy = g.allocator.dupe(u8, m.id) catch continue;
                const node_copy = m.toProto();
                g.group.concurrent(g.io, investigateNode, .{ g, id_copy, node_copy }) catch {
                    g.allocator.free(id_copy);
                    g.membership.setInvestigating(m.id, false);
                };
            }
        }
    }

    fn investigateNode(g: *GossipNode, id_copy: []u8, target: proto.NodeId) error{Canceled}!void {
        defer g.allocator.free(id_copy);
        defer g.membership.setInvestigating(id_copy, false);

        const alive = g.indirectConfirm(target) catch false;
        if (alive) return;

        if (g.membership.markSuspect(id_copy)) {
            std.log.info("orch: node {s} → SUSPECT", .{id_copy});
            g.broadcastNodeEvent(.suspect, target);
        }
    }

    fn indirectConfirm(g: *GossipNode, target: proto.NodeId) !bool {
        const helpers = try g.selectHelpers(target.id);
        defer g.allocator.free(helpers);
        if (helpers.len == 0) return false;

        const req_id = g.nextMsgId();
        const req_payload = try g.encode(proto.encodePingReq, proto.PingReq{
            .request_id = req_id,
            .target = target,
        });
        defer g.allocator.free(req_payload);
        const framed = try transport.marshalUdp(.{
            .msg_type = transport.MsgPingReq,
            .flags = 0,
            .payload = req_payload,
        }, g.allocator);
        defer g.allocator.free(framed);

        // Register waiter
        const waiter = try g.allocator.create(PingReqWaiter);
        waiter.* = .{};
        g.pingreq_mu.lock();
        try g.pingreq_waiters.put(g.allocator, req_id, waiter);
        g.pingreq_mu.unlock();
        defer {
            g.pingreq_mu.lock();
            _ = g.pingreq_waiters.remove(req_id);
            g.pingreq_mu.unlock();
            g.allocator.destroy(waiter);
        }

        for (helpers) |helper| {
            const ip = transport.parseAddr(helper.addr) catch continue;
            g.udp_socket.?.send(g.io, &ip, framed) catch {};
        }

        const timeout = Io.Timeout{ .duration = .{
            .raw = .{ .nanoseconds = @as(i96, g.cfg.heartbeat_timeout_ms * std.time.ns_per_ms) },
            .clock = .awake,
        } };
        waiter.event.waitTimeout(g.io, timeout) catch return false;
        return waiter.result;
    }

    fn selectHelpers(g: *GossipNode, exclude_id: []const u8) ![]proto.NodeId {
        const all = try g.membership.alivePeers(g.allocator);
        defer g.allocator.free(all);

        var candidates = List(proto.NodeId).init(g.allocator);
        for (all) |n| {
            if (std.mem.eql(u8, n.id, exclude_id)) continue;
            try candidates.append(n);
        }

        const n = @min(candidates.items.len, g.cfg.indirect_ping_count);
        if (n == 0) return candidates.toOwnedSlice();

        // Shuffle first n elements
        for (0..n) |i| {
            const j = i + g.randN(candidates.items.len - i);
            std.mem.swap(proto.NodeId, &candidates.items[i], &candidates.items[j]);
        }
        const result = try g.allocator.dupe(proto.NodeId, candidates.items[0..n]);
        candidates.deinit();
        return result;
    }

    // ---------------------------------------------------------------------------
    // PING handlers
    // ---------------------------------------------------------------------------

    fn handlePing(g: *GossipNode, frame: transport.UdpFrame, from: net.IpAddress) !void {
        const ping = try proto.decodePing(frame.payload);
        const ack_payload = try g.encode(proto.encodePingAck, proto.PingAck{
            .request_id = ping.request_id,
            .helper = g.membership.selfNode(),
        });
        defer g.allocator.free(ack_payload);
        const framed = try transport.marshalUdp(.{
            .msg_type = transport.MsgPingAck,
            .flags = 0,
            .payload = ack_payload,
        }, g.allocator);
        defer g.allocator.free(framed);
        g.udp_socket.?.send(g.io, &from, framed) catch {};
    }

    fn handlePingAck(g: *GossipNode, frame: transport.UdpFrame) !void {
        const ack = try proto.decodePingAck(frame.payload);
        g.ping_mu.lock();
        if (g.ping_waiters.get(ack.request_id)) |w| {
            w.result = true;
            w.event.set(g.io);
        }
        g.ping_mu.unlock();
    }

    fn handlePingReq(g: *GossipNode, frame: transport.UdpFrame, requester: net.IpAddress) !void {
        const req = try proto.decodePingReq(frame.payload);
        const target = req.target orelse return;

        const target_ip = try transport.parseAddr(target.addr);
        const req_id = g.nextMsgId();
        const ping_payload = try g.encode(proto.encodePing, proto.Ping{
            .request_id = req_id,
            .helper = g.membership.selfNode(),
        });
        defer g.allocator.free(ping_payload);
        const framed = try transport.marshalUdp(.{
            .msg_type = transport.MsgPing,
            .flags = 0,
            .payload = ping_payload,
        }, g.allocator);
        defer g.allocator.free(framed);

        const waiter = try g.allocator.create(PingWaiter);
        waiter.* = .{};
        g.ping_mu.lock();
        try g.ping_waiters.put(g.allocator, req_id, waiter);
        g.ping_mu.unlock();
        defer {
            g.ping_mu.lock();
            _ = g.ping_waiters.remove(req_id);
            g.ping_mu.unlock();
            g.allocator.destroy(waiter);
        }

        g.udp_socket.?.send(g.io, &target_ip, framed) catch {};

        const timeout = Io.Timeout{ .duration = .{
            .raw = .{ .nanoseconds = @as(i96, g.cfg.heartbeat_timeout_ms * std.time.ns_per_ms) },
            .clock = .awake,
        } };
        const alive = blk: {
            waiter.event.waitTimeout(g.io, timeout) catch break :blk false;
            break :blk waiter.result;
        };

        // Reply to original requester
        const ack_payload = try g.encode(proto.encodePingReqAck, proto.PingReqAck{
            .request_id = req.request_id,
            .target = target,
            .alive = alive,
        });
        defer g.allocator.free(ack_payload);
        const ack_framed = try transport.marshalUdp(.{
            .msg_type = transport.MsgPingReqAck,
            .flags = 0,
            .payload = ack_payload,
        }, g.allocator);
        defer g.allocator.free(ack_framed);
        g.udp_socket.?.send(g.io, &requester, ack_framed) catch {};
    }

    fn handlePingReqAck(g: *GossipNode, frame: transport.UdpFrame) !void {
        const ack = try proto.decodePingReqAck(frame.payload);
        g.pingreq_mu.lock();
        if (g.pingreq_waiters.get(ack.request_id)) |w| {
            w.result = ack.alive;
            w.event.set(g.io);
        }
        g.pingreq_mu.unlock();
    }

    // ---------------------------------------------------------------------------
    // Gossip dissemination
    // ---------------------------------------------------------------------------

    fn handleGossipFrame(g: *GossipNode, frame: transport.Frame) !void {
        const envelope = try proto.decodeGossipEnvelope(frame.payload);
        if (!g.dedup.add(envelope.msg_id)) return; // already seen

        const event = try proto.decodeNodeEvent(envelope.payload);
        if (event.node) |n| {
            if (std.mem.eql(u8, n.id, g.self_id)) return;
            _ = g.membership.addOrUpdate(n);
            switch (event.event_type) {
                .join => std.log.info("orch: gossip JOIN {s}", .{n.id}),
                .leave, .dead => {
                    std.log.info("orch: gossip DEAD {s}", .{n.id});
                    g.membership.markState(n.id, .dead);
                },
                .suspect => {
                    std.log.info("orch: gossip SUSPECT {s}", .{n.id});
                    g.membership.markState(n.id, .suspect);
                },
                _ => {},
            }
        }

        // Forward with decremented TTL
        if (envelope.ttl > 0) {
            var fwd_env = envelope;
            fwd_env.ttl -= 1;
            g.forwardGossip(frame.msg_type, fwd_env) catch {};
        }
    }

    fn forwardGossip(g: *GossipNode, msg_type: u8, envelope: proto.GossipEnvelope) !void {
        const payload = try g.encode(proto.encodeGossipEnvelope, envelope);
        defer g.allocator.free(payload);
        const frame = transport.Frame{
            .msg_type = msg_type,
            .flags = 0,
            .seq_no = g.nextSeq(),
            .payload = payload,
        };
        const targets = try g.fanoutTargets();
        defer g.allocator.free(targets);
        for (targets) |t| {
            g.sendFrameToPeer(t.addr, frame) catch {};
        }
    }

    pub fn broadcastNodeEvent(g: *GossipNode, event_type: proto.NodeEventType, node: proto.NodeId) void {
        if (std.mem.eql(u8, node.id, g.self_id)) return;

        const inner = g.encode(proto.encodeNodeEvent, proto.NodeEvent{
            .event_type = event_type,
            .node = node,
            .term = node.term,
        }) catch return;
        defer g.allocator.free(inner);

        const fanout = g.gossipFanout();
        const ttl: u32 = @intCast(fanout * 2);
        const envelope = proto.GossipEnvelope{
            .ttl = ttl,
            .msg_id = g.nextMsgId(),
            .payload = inner,
        };
        const env_payload = g.encode(proto.encodeGossipEnvelope, envelope) catch return;
        defer g.allocator.free(env_payload);

        const base_type: u8 = transport.MsgNodeJoin + @as(u8, @truncate(@intFromEnum(event_type)));
        const frame = transport.Frame{
            .msg_type = base_type,
            .flags = 0,
            .seq_no = g.nextSeq(),
            .payload = env_payload,
        };
        const targets = g.fanoutTargets() catch return;
        defer g.allocator.free(targets);
        for (targets) |t| g.sendFrameToPeer(t.addr, frame) catch {};
    }

    // ---------------------------------------------------------------------------
    // Scale signal
    // ---------------------------------------------------------------------------

    fn handleScaleFrame(g: *GossipNode, frame: transport.Frame) !void {
        const signal = try proto.decodeScaleSignal(frame.payload);
        std.log.info("orch: scale signal direction={} service={s} delta={}", .{
            signal.direction, signal.service, signal.delta,
        });
        if (g.on_scale_signal_cb) |cb| cb(signal);
    }

    pub fn broadcastScaleSignal(g: *GossipNode, signal: proto.ScaleSignal) void {
        const payload = g.encode(proto.encodeScaleSignal, signal) catch return;
        defer g.allocator.free(payload);
        const base: u8 = if (signal.direction == .out) transport.MsgScaleOut else transport.MsgScaleIn;
        const frame = transport.Frame{
            .msg_type = base,
            .flags = 0,
            .seq_no = g.nextSeq(),
            .payload = payload,
        };
        const targets = g.fanoutTargets() catch return;
        defer g.allocator.free(targets);
        for (targets) |t| g.sendFrameToPeer(t.addr, frame) catch {};
    }

    // ---------------------------------------------------------------------------
    // TCP send helpers
    // ---------------------------------------------------------------------------

    fn sendFrameToPeer(g: *GossipNode, addr: []const u8, frame: transport.Frame) !void {
        const ip = try transport.parseAddr(addr);
        const stream = try ip.connect(g.io, .{ .mode = .stream });
        defer stream.close(g.io);
        var wb: [4096]u8 = undefined;
        var tcp_writer = stream.writer(g.io, &wb);
        try transport.writeTcpFrame(&tcp_writer.interface, frame, g.allocator);
    }

    fn fanoutTargets(g: *GossipNode) ![]proto.NodeId {
        const all = try g.membership.alivePeers(g.allocator);
        const n = @min(all.len, g.gossipFanout());
        if (n == 0 or all.len == 0) {
            return all;
        }
        // Partial Fisher-Yates shuffle to pick n random targets
        var arr = List(proto.NodeId).fromOwnedSlice(g.allocator, all);
        for (0..n) |i| {
            const j = i + g.randN(arr.items.len - i);
            std.mem.swap(proto.NodeId, &arr.items[i], &arr.items[j]);
        }
        const result = arr.items[0..n];
        // Free the rest
        const full = arr.toOwnedSlice() catch return error.OutOfMemory;
        const out = try g.allocator.dupe(proto.NodeId, result);
        g.allocator.free(full);
        return out;
    }

    // ---------------------------------------------------------------------------
    // Raft integration callbacks
    // ---------------------------------------------------------------------------

    pub fn onLeaderChange(g: *GossipNode, is_leader: bool, term: u64) void {
        g.membership.updateSelf(is_leader, term);
        if (g.on_leader_change_cb) |cb| cb(is_leader, term);
        if (is_leader) {
            std.log.info("orch: became Raft leader, term={}", .{term});
        } else {
            std.log.info("orch: Raft follower, term={}", .{term});
        }
    }
};
