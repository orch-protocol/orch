//! Cluster membership table with SWIM state tracking.
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
const proto = @import("proto.zig");
fn List(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}
fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub const NodeState = enum { alive, suspect, dead };

pub const Member = struct {
    // Owned strings
    id: []u8,
    addr: []u8,
    service: []u8,
    version: []u8,
    is_leader: bool = false,
    term: u64 = 0,

    state: NodeState = .alive,
    last_seen_ns: i128 = 0,
    missed_heartbeats: u32 = 0,
    suspect_since_ns: i128 = 0,
    cpu_usage: f32 = 0,
    mem_usage: f32 = 0,
    goroutines: u32 = 0,
    is_self: bool = false,
    investigating: bool = false,

    fn deinit(m: *Member, allocator: Allocator) void {
        allocator.free(m.id);
        allocator.free(m.addr);
        allocator.free(m.service);
        allocator.free(m.version);
    }

    pub fn toProto(m: *const Member) proto.NodeId {
        return .{
            .id = m.id,
            .addr = m.addr,
            .service = m.service,
            .version = m.version,
            .is_leader = m.is_leader,
            .term = m.term,
        };
    }
};

pub const Membership = struct {
    mu: Mutex = .{},
    nodes: std.StringHashMapUnmanaged(*Member) = .{},
    self_id: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, self_node: proto.NodeId) Allocator.Error!Membership {
        var m = Membership{
            .self_id = self_node.id,
            .allocator = allocator,
        };
        _ = try m.addOrUpdateLocked(self_node, true);
        return m;
    }

    pub fn deinit(m: *Membership) void {
        var it = m.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(m.allocator);
            m.allocator.destroy(entry.value_ptr.*);
        }
        m.nodes.deinit(m.allocator);
    }

    fn dupStr(m: *Membership, s: []const u8) Allocator.Error![]u8 {
        return m.allocator.dupe(u8, s);
    }

    fn addOrUpdateLocked(m: *Membership, node: proto.NodeId, is_self: bool) Allocator.Error!bool {
        if (m.nodes.get(node.id)) |existing| {
            // Don't revive dead nodes via regular updates
            if (existing.state == .dead and !is_self) return false;
            // Update mutable fields
            const old_addr = existing.addr;
            const old_svc = existing.service;
            const old_ver = existing.version;
            existing.addr = try m.dupStr(node.addr);
            existing.service = try m.dupStr(node.service);
            existing.version = try m.dupStr(node.version);
            existing.is_leader = node.is_leader;
            existing.term = node.term;
            existing.state = .alive;
            existing.last_seen_ns = nanoTimestamp();
            existing.missed_heartbeats = 0;
            existing.suspect_since_ns = 0;
            m.allocator.free(old_addr);
            m.allocator.free(old_svc);
            m.allocator.free(old_ver);
            return false;
        }
        // New member
        const mem_ptr = try m.allocator.create(Member);
        mem_ptr.* = .{
            .id = try m.dupStr(node.id),
            .addr = try m.dupStr(node.addr),
            .service = try m.dupStr(node.service),
            .version = try m.dupStr(node.version),
            .is_leader = node.is_leader,
            .term = node.term,
            .last_seen_ns = nanoTimestamp(),
            .is_self = is_self,
        };
        // Key is the member's own id slice (stable for its lifetime)
        try m.nodes.put(m.allocator, mem_ptr.id, mem_ptr);
        return true;
    }

    /// Add or update a node. Returns true if the node is new.
    pub fn addOrUpdate(m: *Membership, node: proto.NodeId) bool {
        m.mu.lock();
        defer m.mu.unlock();
        return m.addOrUpdateLocked(node, node.id.len > 0 and std.mem.eql(u8, node.id, m.self_id)) catch false;
    }

    /// Add or update, allowing reviving dead nodes (used on HELLO handshake).
    pub fn addOrRevive(m: *Membership, node: proto.NodeId) bool {
        m.mu.lock();
        defer m.mu.unlock();
        if (m.nodes.get(node.id)) |existing| {
            const is_self = existing.is_self or std.mem.eql(u8, node.id, m.self_id);
            const old_addr = existing.addr;
            const old_svc = existing.service;
            const old_ver = existing.version;
            existing.addr = m.dupStr(node.addr) catch existing.addr;
            existing.service = m.dupStr(node.service) catch existing.service;
            existing.version = m.dupStr(node.version) catch existing.version;
            existing.is_leader = node.is_leader;
            existing.term = node.term;
            existing.state = .alive;
            existing.last_seen_ns = nanoTimestamp();
            existing.missed_heartbeats = 0;
            existing.suspect_since_ns = 0;
            existing.is_self = is_self;
            if (old_addr.ptr != existing.addr.ptr) m.allocator.free(old_addr);
            if (old_svc.ptr != existing.service.ptr) m.allocator.free(old_svc);
            if (old_ver.ptr != existing.version.ptr) m.allocator.free(old_ver);
            return false;
        }
        return m.addOrUpdateLocked(node, std.mem.eql(u8, node.id, m.self_id)) catch false;
    }

    pub fn recordHeartbeat(m: *Membership, node: proto.NodeId, cpu: f32, mem_f: f32, goroutines: u32) void {
        m.mu.lock();
        defer m.mu.unlock();
        if (m.nodes.get(node.id)) |existing| {
            if (existing.state == .dead) return;
            existing.state = .alive;
            existing.last_seen_ns = nanoTimestamp();
            existing.missed_heartbeats = 0;
            existing.suspect_since_ns = 0;
            existing.is_leader = node.is_leader;
            existing.term = node.term;
            existing.cpu_usage = cpu;
            existing.mem_usage = mem_f;
            existing.goroutines = goroutines;
        } else {
            _ = m.addOrUpdateLocked(node, false) catch {};
            if (m.nodes.get(node.id)) |new_mem| {
                new_mem.cpu_usage = cpu;
                new_mem.mem_usage = mem_f;
                new_mem.goroutines = goroutines;
            }
        }
    }

    pub fn markSuspect(m: *Membership, id: []const u8) bool {
        m.mu.lock();
        defer m.mu.unlock();
        const member = m.nodes.get(id) orelse return false;
        if (member.state == .alive) {
            member.state = .suspect;
            member.suspect_since_ns = nanoTimestamp();
            member.missed_heartbeats = 0;
            return true;
        }
        return false;
    }

    pub fn markDead(m: *Membership, id: []const u8) bool {
        m.mu.lock();
        defer m.mu.unlock();
        const member = m.nodes.get(id) orelse return false;
        if (member.state != .dead) {
            member.state = .dead;
            return true;
        }
        return false;
    }

    pub fn markState(m: *Membership, id: []const u8, state: NodeState) void {
        m.mu.lock();
        defer m.mu.unlock();
        if (m.nodes.get(id)) |member| member.state = state;
    }

    pub fn setInvestigating(m: *Membership, id: []const u8, v: bool) void {
        m.mu.lock();
        defer m.mu.unlock();
        if (m.nodes.get(id)) |member| member.investigating = v;
    }

    pub fn updateSelf(m: *Membership, is_leader: bool, term: u64) void {
        m.mu.lock();
        defer m.mu.unlock();
        if (m.nodes.get(m.self_id)) |s| {
            s.is_leader = is_leader;
            s.term = term;
        }
    }

    /// Returns a snapshot of all members (allocated; caller frees slice).
    pub fn snapshot(m: *Membership, allocator: Allocator) Allocator.Error![]Member {
        m.mu.lock();
        defer m.mu.unlock();
        var list = try List(Member).initCapacity(allocator, m.nodes.count());
        var it = m.nodes.iterator();
        while (it.next()) |entry| {
            // Shallow copy – string slices remain valid while Membership is alive
            list.appendAssumeCapacity(entry.value_ptr.*.*);
        }
        return list.toOwnedSlice();
    }

    /// Returns slice of alive non-self peer NodeId (borrows from internal storage).
    /// Caller must hold mu.lock() during use OR make a deep copy.
    pub fn alivePeers(m: *Membership, allocator: Allocator) Allocator.Error![]proto.NodeId {
        m.mu.lock();
        defer m.mu.unlock();
        var list = List(proto.NodeId).init(allocator);
        var it = m.nodes.iterator();
        while (it.next()) |entry| {
            const mem = entry.value_ptr.*;
            if (mem.is_self) continue;
            if (mem.state == .dead) continue;
            try list.append(mem.toProto());
        }
        return list.toOwnedSlice();
    }

    /// Returns all known non-self peer addresses (alive or suspect).
    pub fn knownPeerAddrs(m: *Membership, allocator: Allocator) Allocator.Error![][]const u8 {
        m.mu.lock();
        defer m.mu.unlock();
        var list = List([]const u8).init(allocator);
        var it = m.nodes.iterator();
        while (it.next()) |entry| {
            const mem = entry.value_ptr.*;
            if (mem.is_self) continue;
            if (mem.state == .dead) continue;
            try list.append(mem.addr);
        }
        return list.toOwnedSlice();
    }

    /// Total non-dead node count (including self).
    pub fn count(m: *Membership) usize {
        m.mu.lock();
        defer m.mu.unlock();
        var n: usize = 0;
        var it = m.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.state != .dead) n += 1;
        }
        return n;
    }

    /// Count alive nodes for a given service name.
    pub fn serviceCount(m: *Membership, service: []const u8) usize {
        m.mu.lock();
        defer m.mu.unlock();
        var n: usize = 0;
        var it = m.nodes.iterator();
        while (it.next()) |entry| {
            const mem = entry.value_ptr.*;
            if (mem.state == .dead) continue;
            if (std.mem.eql(u8, mem.service, service)) n += 1;
        }
        return n;
    }

    /// Cluster view: all non-dead nodes including self.
    pub fn clusterView(m: *Membership, allocator: Allocator) Allocator.Error![]proto.NodeId {
        m.mu.lock();
        defer m.mu.unlock();
        var list = List(proto.NodeId).init(allocator);
        var it2 = m.nodes.iterator();
        while (it2.next()) |entry| {
            const mem = entry.value_ptr.*;
            if (mem.state == .dead) continue;
            try list.append(mem.toProto());
        }
        return list.toOwnedSlice();
    }

    pub fn selfId(m: *const Membership) []const u8 {
        return m.self_id;
    }

    /// Returns a copy of the self NodeId.
    pub fn selfNode(m: *Membership) proto.NodeId {
        m.mu.lock();
        defer m.mu.unlock();
        if (m.nodes.get(m.self_id)) |s| return s.toProto();
        return .{};
    }
};
