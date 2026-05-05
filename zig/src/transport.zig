//! ORCH wire framing (TCP + UDP).
//!
//! TCP Frame layout (24-byte header):
//!   [0..4]  Magic    = 0x4F524348
//!   [4]     Version  = 0x01
//!   [5]     MsgType
//!   [6..8]  Flags
//!   [8..12] PayloadLen (u32 BE)
//!   [12..20] SeqNo   (u64 BE)
//!   [20..24] CRC32C  (over entire frame, checksum field zeroed)
//!   [24..]  Payload
//!
//! UDP Frame layout (12-byte header):
//!   [0..4]  Magic
//!   [4]     Version
//!   [5]     MsgType
//!   [6..8]  Flags
//!   [8..12] PayloadLen
//!   [12..]  Payload
const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const Io = std.Io;

pub const MAGIC: u32 = 0x4F524348;
pub const VERSION: u8 = 0x01;
pub const TCP_HEADER_LEN: usize = 24;
pub const UDP_HEADER_LEN: usize = 12;
pub const MAX_PAYLOAD_LEN: u32 = 4 * 1024 * 1024;

// Message type constants (match Go transport package)
pub const MsgHello: u8 = 0x01;
pub const MsgHelloAck: u8 = 0x02;
pub const MsgHeartbeat: u8 = 0x03;
pub const MsgHeartbeatAck: u8 = 0x04;
pub const MsgPing: u8 = 0x05;
pub const MsgPingReq: u8 = 0x06;
pub const MsgPingAck: u8 = 0x07;
pub const MsgPingReqAck: u8 = 0x08;
pub const MsgNodeJoin: u8 = 0x10;
pub const MsgNodeLeave: u8 = 0x11;
pub const MsgNodeDead: u8 = 0x12;
pub const MsgNodeSuspect: u8 = 0x13;
pub const MsgScaleOut: u8 = 0x20;
pub const MsgScaleIn: u8 = 0x21;
pub const MsgRaftRequestVote: u8 = 0x40;
pub const MsgRaftRequestVoteAck: u8 = 0x41;
pub const MsgRaftAppendEntries: u8 = 0x42;
pub const MsgRaftAppendEntriesAck: u8 = 0x43;
pub const MsgError: u8 = 0xFF;

pub const Frame = struct {
    msg_type: u8,
    flags: u16,
    seq_no: u64,
    payload: []const u8,
};

pub const UdpFrame = struct {
    msg_type: u8,
    flags: u16,
    payload: []const u8,
};

pub const FrameError = error{
    InvalidMagic,
    VersionMismatch,
    PayloadTooLarge,
    ChecksumMismatch,
    FrameTooSmall,
};

fn crc32c(data: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(data);
}

pub fn marshalTcp(frame: Frame, allocator: Allocator) (Allocator.Error || FrameError)![]u8 {
    if (frame.payload.len > MAX_PAYLOAD_LEN) return error.PayloadTooLarge;
    const total = TCP_HEADER_LEN + frame.payload.len;
    const buf = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], MAGIC, .big);
    buf[4] = VERSION;
    buf[5] = frame.msg_type;
    std.mem.writeInt(u16, buf[6..8], frame.flags, .big);
    std.mem.writeInt(u32, buf[8..12], @intCast(frame.payload.len), .big);
    std.mem.writeInt(u64, buf[12..20], frame.seq_no, .big);
    std.mem.writeInt(u32, buf[20..24], 0, .big); // checksum placeholder
    @memcpy(buf[TCP_HEADER_LEN..], frame.payload);
    const csum = crc32c(buf);
    std.mem.writeInt(u32, buf[20..24], csum, .big);
    return buf;
}

pub fn unmarshalTcp(data: []u8) FrameError!Frame {
    if (data.len < TCP_HEADER_LEN) return error.FrameTooSmall;
    if (std.mem.readInt(u32, data[0..4], .big) != MAGIC) return error.InvalidMagic;
    if (data[4] != VERSION) return error.VersionMismatch;
    const payload_len = std.mem.readInt(u32, data[8..12], .big);
    if (payload_len > MAX_PAYLOAD_LEN) return error.PayloadTooLarge;
    if (data.len != TCP_HEADER_LEN + payload_len) return error.FrameTooSmall;
    const expected = std.mem.readInt(u32, data[20..24], .big);
    std.mem.writeInt(u32, data[20..24], 0, .big);
    const actual = crc32c(data);
    std.mem.writeInt(u32, data[20..24], expected, .big);
    if (actual != expected) return error.ChecksumMismatch;
    return .{
        .msg_type = data[5],
        .flags = std.mem.readInt(u16, data[6..8], .big),
        .seq_no = std.mem.readInt(u64, data[12..20], .big),
        .payload = data[TCP_HEADER_LEN..],
    };
}

/// Read one framed TCP message. Returns an allocated buffer; caller frees.
pub fn readTcpFrame(
    reader: *Io.Reader,
    allocator: Allocator,
) (FrameError || Io.Reader.Error || Allocator.Error)!struct { frame: Frame, buf: []u8 } {
    // Read the fixed header first
    var header: [TCP_HEADER_LEN]u8 = undefined;
    var hiovs = [1][]u8{&header};
    try reader.readVecAll(&hiovs);

    const payload_len = std.mem.readInt(u32, header[8..12], .big);
    if (payload_len > MAX_PAYLOAD_LEN) return error.PayloadTooLarge;

    // Allocate full frame buffer
    const total = TCP_HEADER_LEN + payload_len;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    @memcpy(buf[0..TCP_HEADER_LEN], &header);

    if (payload_len > 0) {
        var piovs = [1][]u8{buf[TCP_HEADER_LEN..]};
        try reader.readVecAll(&piovs);
    }

    const frame = try unmarshalTcp(buf);
    return .{ .frame = frame, .buf = buf };
}

/// Write one framed TCP message.
pub fn writeTcpFrame(
    writer: *Io.Writer,
    frame: Frame,
    allocator: Allocator,
) (FrameError || Io.Writer.Error || Allocator.Error)!void {
    const buf = try marshalTcp(frame, allocator);
    defer allocator.free(buf);
    try writer.writeAll(buf);
    try writer.flush();
}

pub fn marshalUdp(frame: UdpFrame, allocator: Allocator) (Allocator.Error || FrameError)![]u8 {
    if (frame.payload.len > MAX_PAYLOAD_LEN) return error.PayloadTooLarge;
    const total = UDP_HEADER_LEN + frame.payload.len;
    const buf = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], MAGIC, .big);
    buf[4] = VERSION;
    buf[5] = frame.msg_type;
    std.mem.writeInt(u16, buf[6..8], frame.flags, .big);
    std.mem.writeInt(u32, buf[8..12], @intCast(frame.payload.len), .big);
    @memcpy(buf[UDP_HEADER_LEN..], frame.payload);
    return buf;
}

pub fn unmarshalUdp(data: []const u8) FrameError!UdpFrame {
    if (data.len < UDP_HEADER_LEN) return error.FrameTooSmall;
    if (std.mem.readInt(u32, data[0..4], .big) != MAGIC) return error.InvalidMagic;
    if (data[4] != VERSION) return error.VersionMismatch;
    const payload_len = std.mem.readInt(u32, data[8..12], .big);
    if (payload_len > MAX_PAYLOAD_LEN) return error.PayloadTooLarge;
    if (data.len < UDP_HEADER_LEN + payload_len) return error.FrameTooSmall;
    return .{
        .msg_type = data[5],
        .flags = std.mem.readInt(u16, data[6..8], .big),
        .payload = data[UDP_HEADER_LEN .. UDP_HEADER_LEN + payload_len],
    };
}

// ---------------------------------------------------------------------------
// Address helpers
// ---------------------------------------------------------------------------

/// Parse "host:port" → IpAddress.
pub fn parseAddr(addr_str: []const u8) !net.IpAddress {
    return net.IpAddress.parseLiteral(addr_str);
}

/// Format an IpAddress to "host:port" in buf. Returns the written slice.
pub fn fmtAddr(addr: net.IpAddress, buf: []u8) []const u8 {
    return switch (addr) {
        .ip4 => |a| std.fmt.bufPrint(
            buf,
            "{d}.{d}.{d}.{d}:{d}",
            .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3], a.port },
        ) catch buf[0..0],
        .ip6 => |a| std.fmt.bufPrint(buf, "[...]:{d}", .{a.port}) catch buf[0..0],
    };
}

/// Derive the Raft address by incrementing the gossip port by 1.
pub fn raftAddr(gossip_addr: net.IpAddress) net.IpAddress {
    var ra = gossip_addr;
    ra.setPort(gossip_addr.getPort() + 1);
    return ra;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TCP frame round-trip" {
    const allocator = std.testing.allocator;
    const payload = "hello world";
    const frame = Frame{
        .msg_type = MsgHello,
        .flags = 0,
        .seq_no = 1,
        .payload = payload,
    };
    const buf = try marshalTcp(frame, allocator);
    defer allocator.free(buf);
    const decoded = try unmarshalTcp(buf);
    try std.testing.expectEqual(frame.msg_type, decoded.msg_type);
    try std.testing.expectEqualStrings(payload, decoded.payload);
}

test "UDP frame round-trip" {
    const allocator = std.testing.allocator;
    const payload = "ping";
    const frame = UdpFrame{ .msg_type = MsgPing, .flags = 0, .payload = payload };
    const buf = try marshalUdp(frame, allocator);
    defer allocator.free(buf);
    const decoded = try unmarshalUdp(buf);
    try std.testing.expectEqual(frame.msg_type, decoded.msg_type);
    try std.testing.expectEqualStrings(payload, decoded.payload);
}
