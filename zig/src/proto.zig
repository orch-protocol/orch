//! Hand-coded protobuf encode/decode for ORCH protocol messages.
//! Wire-compatible with the proto3 schema in proto/orch.proto.
const std = @import("std");
const Allocator = std.mem.Allocator;
fn List(comptime T: type) type { return std.array_list.AlignedManaged(T, null); }

// ---------------------------------------------------------------------------
// Message types (borrow string slices from the decode buffer)
// ---------------------------------------------------------------------------

pub const NodeId = struct {
    id: []const u8 = "",
    addr: []const u8 = "",
    service: []const u8 = "",
    version: []const u8 = "",
    is_leader: bool = false,
    term: u64 = 0,
};

pub const Hello = struct {
    node: ?NodeId = null,
    cluster_token: u64 = 0,
    known_peers: []const []const u8 = &.{},
};

pub const HelloAck = struct {
    node: ?NodeId = null,
    cluster_view: []const NodeId = &.{},
};

pub const Heartbeat = struct {
    node: ?NodeId = null,
    timestamp: u64 = 0,
    cpu_usage: f32 = 0,
    mem_usage: f32 = 0,
    goroutines: u32 = 0,
};

pub const Ping = struct {
    request_id: u64 = 0,
    helper: ?NodeId = null,
};

pub const PingReq = struct {
    request_id: u64 = 0,
    target: ?NodeId = null,
};

pub const PingAck = struct {
    request_id: u64 = 0,
    helper: ?NodeId = null,
};

pub const PingReqAck = struct {
    request_id: u64 = 0,
    target: ?NodeId = null,
    alive: bool = false,
};

pub const GossipEnvelope = struct {
    ttl: u32 = 0,
    msg_id: u64 = 0,
    payload: []const u8 = &.{},
};

pub const NodeEventType = enum(u32) { join = 0, leave = 1, dead = 2, suspect = 3, _ };
pub const NodeEvent = struct {
    event_type: NodeEventType = .join,
    node: ?NodeId = null,
    term: u64 = 0,
};

pub const ScaleDirection = enum(u32) { out = 0, in = 1, _ };
pub const ScaleSignal = struct {
    direction: ScaleDirection = .out,
    service: []const u8 = "",
    delta: u32 = 0,
    reason: []const u8 = "",
};

pub const RequestVote = struct {
    term: u64 = 0,
    candidate_id: []const u8 = "",
    last_log_index: u64 = 0,
    last_log_term: u64 = 0,
};

pub const RequestVoteReply = struct {
    term: u64 = 0,
    vote_granted: bool = false,
};

pub const AppendEntries = struct {
    term: u64 = 0,
    leader_id: []const u8 = "",
    prev_log_index: u64 = 0,
    prev_log_term: u64 = 0,
    leader_commit: u64 = 0,
};

pub const AppendEntriesReply = struct {
    term: u64 = 0,
    success: bool = false,
};

// ---------------------------------------------------------------------------
// Encoder (writes to std.ArrayList(u8))
// ---------------------------------------------------------------------------

const Buf = std.array_list.AlignedManaged(u8, null);

fn writeVarint(buf: *Buf, value: u64) Allocator.Error!void {
    var v = value;
    while (v >= 0x80) {
        try buf.append(@truncate((v & 0x7F) | 0x80));
        v >>= 7;
    }
    try buf.append(@truncate(v));
}

fn writeTag(buf: *Buf, field: u32, wire: u32) Allocator.Error!void {
    try writeVarint(buf, (@as(u64, field) << 3) | wire);
}

fn writeU64(buf: *Buf, field: u32, v: u64) Allocator.Error!void {
    if (v == 0) return;
    try writeTag(buf, field, 0);
    try writeVarint(buf, v);
}

fn writeU32(buf: *Buf, field: u32, v: u32) Allocator.Error!void {
    if (v == 0) return;
    try writeTag(buf, field, 0);
    try writeVarint(buf, v);
}

fn writeBool(buf: *Buf, field: u32, v: bool) Allocator.Error!void {
    if (!v) return;
    try writeTag(buf, field, 0);
    try buf.append(1);
}

fn writeBytes(buf: *Buf, field: u32, data: []const u8) Allocator.Error!void {
    if (data.len == 0) return;
    try writeTag(buf, field, 2);
    try writeVarint(buf, data.len);
    try buf.appendSlice(data);
}

fn writeFloat(buf: *Buf, field: u32, v: f32) Allocator.Error!void {
    if (v == 0) return;
    try writeTag(buf, field, 5);
    const raw: u32 = @bitCast(v);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, raw, .little);
    try buf.appendSlice(&bytes);
}

fn writeEnum(buf: *Buf, field: u32, v: u32) Allocator.Error!void {
    try writeU32(buf, field, v);
}

fn writeNodeIdMsg(buf: *Buf, node: NodeId) Allocator.Error!void {
    try writeBytes(buf, 1, node.id);
    try writeBytes(buf, 2, node.addr);
    try writeBytes(buf, 3, node.service);
    try writeBytes(buf, 4, node.version);
    try writeBool(buf, 5, node.is_leader);
    try writeU64(buf, 6, node.term);
}

fn writeSubMsg(buf: *Buf, field: u32, enc: anytype, value: anytype) Allocator.Error!void {
    var inner = Buf.init(buf.allocator);
    defer inner.deinit();
    try enc(&inner, value);
    if (inner.items.len == 0) return;
    try writeTag(buf, field, 2);
    try writeVarint(buf, inner.items.len);
    try buf.appendSlice(inner.items);
}

pub fn encodeNodeId(buf: *Buf, node: NodeId) Allocator.Error!void {
    try writeNodeIdMsg(buf, node);
}

pub fn encodeHello(buf: *Buf, msg: Hello) Allocator.Error!void {
    if (msg.node) |n| try writeSubMsg(buf, 1, writeNodeIdMsg, n);
    try writeU64(buf, 2, msg.cluster_token);
    for (msg.known_peers) |peer| try writeBytes(buf, 3, peer);
}

pub fn encodeHelloAck(buf: *Buf, msg: HelloAck) Allocator.Error!void {
    if (msg.node) |n| try writeSubMsg(buf, 1, writeNodeIdMsg, n);
    for (msg.cluster_view) |n| try writeSubMsg(buf, 2, writeNodeIdMsg, n);
}

pub fn encodeHeartbeat(buf: *Buf, msg: Heartbeat) Allocator.Error!void {
    if (msg.node) |n| try writeSubMsg(buf, 1, writeNodeIdMsg, n);
    try writeU64(buf, 2, msg.timestamp);
    try writeFloat(buf, 3, msg.cpu_usage);
    try writeFloat(buf, 4, msg.mem_usage);
    try writeU32(buf, 5, msg.goroutines);
}

pub fn encodePing(buf: *Buf, msg: Ping) Allocator.Error!void {
    try writeU64(buf, 1, msg.request_id);
    if (msg.helper) |n| try writeSubMsg(buf, 2, writeNodeIdMsg, n);
}

pub fn encodePingReq(buf: *Buf, msg: PingReq) Allocator.Error!void {
    try writeU64(buf, 1, msg.request_id);
    if (msg.target) |n| try writeSubMsg(buf, 2, writeNodeIdMsg, n);
}

pub fn encodePingAck(buf: *Buf, msg: PingAck) Allocator.Error!void {
    try writeU64(buf, 1, msg.request_id);
    if (msg.helper) |n| try writeSubMsg(buf, 2, writeNodeIdMsg, n);
}

pub fn encodePingReqAck(buf: *Buf, msg: PingReqAck) Allocator.Error!void {
    try writeU64(buf, 1, msg.request_id);
    if (msg.target) |n| try writeSubMsg(buf, 2, writeNodeIdMsg, n);
    try writeBool(buf, 3, msg.alive);
}

pub fn encodeGossipEnvelope(buf: *Buf, msg: GossipEnvelope) Allocator.Error!void {
    try writeU32(buf, 1, msg.ttl);
    try writeU64(buf, 2, msg.msg_id);
    try writeBytes(buf, 3, msg.payload);
}

pub fn encodeNodeEvent(buf: *Buf, msg: NodeEvent) Allocator.Error!void {
    try writeEnum(buf, 1, @intFromEnum(msg.event_type));
    if (msg.node) |n| try writeSubMsg(buf, 2, writeNodeIdMsg, n);
    try writeU64(buf, 3, msg.term);
}

pub fn encodeScaleSignal(buf: *Buf, msg: ScaleSignal) Allocator.Error!void {
    try writeEnum(buf, 1, @intFromEnum(msg.direction));
    try writeBytes(buf, 2, msg.service);
    try writeU32(buf, 3, msg.delta);
    try writeBytes(buf, 4, msg.reason);
}

pub fn encodeRequestVote(buf: *Buf, msg: RequestVote) Allocator.Error!void {
    try writeU64(buf, 1, msg.term);
    try writeBytes(buf, 2, msg.candidate_id);
    try writeU64(buf, 3, msg.last_log_index);
    try writeU64(buf, 4, msg.last_log_term);
}

pub fn encodeRequestVoteReply(buf: *Buf, msg: RequestVoteReply) Allocator.Error!void {
    try writeU64(buf, 1, msg.term);
    try writeBool(buf, 2, msg.vote_granted);
}

pub fn encodeAppendEntries(buf: *Buf, msg: AppendEntries) Allocator.Error!void {
    try writeU64(buf, 1, msg.term);
    try writeBytes(buf, 2, msg.leader_id);
    try writeU64(buf, 3, msg.prev_log_index);
    try writeU64(buf, 4, msg.prev_log_term);
    try writeU64(buf, 6, msg.leader_commit);
}

pub fn encodeAppendEntriesReply(buf: *Buf, msg: AppendEntriesReply) Allocator.Error!void {
    try writeU64(buf, 1, msg.term);
    try writeBool(buf, 2, msg.success);
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

pub const DecodeError = error{
    UnexpectedEof,
    VarintOverflow,
    UnknownWireType,
    OutOfMemory,
};

const Decoder = struct {
    data: []const u8,
    pos: usize = 0,

    fn readVarint(d: *Decoder) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (d.pos < d.data.len) {
            const byte = d.data[d.pos];
            d.pos += 1;
            result |= @as(u64, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) return result;
            shift += 7;
            if (shift >= 64) return error.VarintOverflow;
        }
        return error.UnexpectedEof;
    }

    fn readTag(d: *Decoder) DecodeError!struct { field: u32, wire: u3 } {
        const tag = try d.readVarint();
        return .{ .field = @truncate(tag >> 3), .wire = @truncate(tag & 0x7) };
    }

    fn readLengthDelim(d: *Decoder) DecodeError![]const u8 {
        const len: usize = @intCast(try d.readVarint());
        if (d.pos + len > d.data.len) return error.UnexpectedEof;
        const slice = d.data[d.pos .. d.pos + len];
        d.pos += len;
        return slice;
    }

    fn readFixed32(d: *Decoder) DecodeError!u32 {
        if (d.pos + 4 > d.data.len) return error.UnexpectedEof;
        const v = std.mem.readInt(u32, d.data[d.pos..][0..4], .little);
        d.pos += 4;
        return v;
    }

    fn skip(d: *Decoder, wire: u3) DecodeError!void {
        switch (wire) {
            0 => _ = try d.readVarint(),
            1 => { // 64-bit
                if (d.pos + 8 > d.data.len) return error.UnexpectedEof;
                d.pos += 8;
            },
            2 => _ = try d.readLengthDelim(),
            5 => { // 32-bit
                if (d.pos + 4 > d.data.len) return error.UnexpectedEof;
                d.pos += 4;
            },
            else => return error.UnknownWireType,
        }
    }

    fn atEnd(d: *const Decoder) bool {
        return d.pos >= d.data.len;
    }
};

pub fn decodeNodeId(data: []const u8) DecodeError!NodeId {
    var d = Decoder{ .data = data };
    var out = NodeId{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.id = try d.readLengthDelim(),
            2 => out.addr = try d.readLengthDelim(),
            3 => out.service = try d.readLengthDelim(),
            4 => out.version = try d.readLengthDelim(),
            5 => out.is_leader = (try d.readVarint()) != 0,
            6 => out.term = try d.readVarint(),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodeHello(data: []const u8, arena: Allocator) DecodeError!Hello {
    var d = Decoder{ .data = data };
    var out = Hello{};
    var peers = List([]const u8).init(arena);
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.node = try decodeNodeId(try d.readLengthDelim()),
            2 => out.cluster_token = try d.readVarint(),
            3 => try peers.append(try d.readLengthDelim()),
            else => try d.skip(tag.wire),
        }
    }
    out.known_peers = peers.items;
    return out;
}

pub fn decodeHelloAck(data: []const u8, arena: Allocator) DecodeError!HelloAck {
    var d = Decoder{ .data = data };
    var out = HelloAck{};
    var views = List(NodeId).init(arena);
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.node = try decodeNodeId(try d.readLengthDelim()),
            2 => try views.append(try decodeNodeId(try d.readLengthDelim())),
            else => try d.skip(tag.wire),
        }
    }
    out.cluster_view = views.items;
    return out;
}

pub fn decodeHeartbeat(data: []const u8) DecodeError!Heartbeat {
    var d = Decoder{ .data = data };
    var out = Heartbeat{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.node = try decodeNodeId(try d.readLengthDelim()),
            2 => out.timestamp = try d.readVarint(),
            3 => out.cpu_usage = @bitCast(try d.readFixed32()),
            4 => out.mem_usage = @bitCast(try d.readFixed32()),
            5 => out.goroutines = @truncate(try d.readVarint()),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodePing(data: []const u8) DecodeError!Ping {
    var d = Decoder{ .data = data };
    var out = Ping{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.request_id = try d.readVarint(),
            2 => out.helper = try decodeNodeId(try d.readLengthDelim()),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodePingReq(data: []const u8) DecodeError!PingReq {
    var d = Decoder{ .data = data };
    var out = PingReq{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.request_id = try d.readVarint(),
            2 => out.target = try decodeNodeId(try d.readLengthDelim()),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodePingAck(data: []const u8) DecodeError!PingAck {
    var d = Decoder{ .data = data };
    var out = PingAck{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.request_id = try d.readVarint(),
            2 => out.helper = try decodeNodeId(try d.readLengthDelim()),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodePingReqAck(data: []const u8) DecodeError!PingReqAck {
    var d = Decoder{ .data = data };
    var out = PingReqAck{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.request_id = try d.readVarint(),
            2 => out.target = try decodeNodeId(try d.readLengthDelim()),
            3 => out.alive = (try d.readVarint()) != 0,
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodeGossipEnvelope(data: []const u8) DecodeError!GossipEnvelope {
    var d = Decoder{ .data = data };
    var out = GossipEnvelope{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.ttl = @truncate(try d.readVarint()),
            2 => out.msg_id = try d.readVarint(),
            3 => out.payload = try d.readLengthDelim(),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodeNodeEvent(data: []const u8) DecodeError!NodeEvent {
    var d = Decoder{ .data = data };
    var out = NodeEvent{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.event_type = @enumFromInt(@as(u32, @truncate(try d.readVarint()))),
            2 => out.node = try decodeNodeId(try d.readLengthDelim()),
            3 => out.term = try d.readVarint(),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodeScaleSignal(data: []const u8) DecodeError!ScaleSignal {
    var d = Decoder{ .data = data };
    var out = ScaleSignal{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.direction = @enumFromInt(@as(u32, @truncate(try d.readVarint()))),
            2 => out.service = try d.readLengthDelim(),
            3 => out.delta = @truncate(try d.readVarint()),
            4 => out.reason = try d.readLengthDelim(),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodeRequestVote(data: []const u8) DecodeError!RequestVote {
    var d = Decoder{ .data = data };
    var out = RequestVote{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.term = try d.readVarint(),
            2 => out.candidate_id = try d.readLengthDelim(),
            3 => out.last_log_index = try d.readVarint(),
            4 => out.last_log_term = try d.readVarint(),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodeRequestVoteReply(data: []const u8) DecodeError!RequestVoteReply {
    var d = Decoder{ .data = data };
    var out = RequestVoteReply{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.term = try d.readVarint(),
            2 => out.vote_granted = (try d.readVarint()) != 0,
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodeAppendEntries(data: []const u8) DecodeError!AppendEntries {
    var d = Decoder{ .data = data };
    var out = AppendEntries{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.term = try d.readVarint(),
            2 => out.leader_id = try d.readLengthDelim(),
            3 => out.prev_log_index = try d.readVarint(),
            4 => out.prev_log_term = try d.readVarint(),
            6 => out.leader_commit = try d.readVarint(),
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

pub fn decodeAppendEntriesReply(data: []const u8) DecodeError!AppendEntriesReply {
    var d = Decoder{ .data = data };
    var out = AppendEntriesReply{};
    while (!d.atEnd()) {
        const tag = try d.readTag();
        switch (tag.field) {
            1 => out.term = try d.readVarint(),
            2 => out.success = (try d.readVarint()) != 0,
            else => try d.skip(tag.wire),
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Convenience: encode to owned []u8
// ---------------------------------------------------------------------------

pub fn encode(comptime encodeFn: anytype, msg: anytype, allocator: Allocator) Allocator.Error![]u8 {
    var buf = Buf.init(allocator);
    errdefer buf.deinit();
    try encodeFn(&buf, msg);
    return try buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "NodeId round-trip" {
    const allocator = std.testing.allocator;
    const original = NodeId{
        .id = "node-1",
        .addr = "127.0.0.1:7946",
        .service = "svc",
        .is_leader = true,
        .term = 42,
    };
    const bytes = try encode(encodeNodeId, original, allocator);
    defer allocator.free(bytes);
    const decoded = try decodeNodeId(bytes);
    try std.testing.expectEqualStrings(original.id, decoded.id);
    try std.testing.expectEqualStrings(original.addr, decoded.addr);
    try std.testing.expectEqual(original.is_leader, decoded.is_leader);
    try std.testing.expectEqual(original.term, decoded.term);
}
