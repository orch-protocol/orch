//! Deduplication cache for gossip message IDs.
//! A bounded ring-buffer of seen message IDs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = struct {
    m: std.atomic.Mutex = .unlocked,
    pub fn lock(s: *Mutex) void { while (!s.m.tryLock()) std.atomic.spinLoopHint(); }
    pub fn unlock(s: *Mutex) void { s.m.unlock(); }
};

pub const DedupCache = struct {
    mu: Mutex = .{},
    ring: []u64,
    head: usize = 0,
    set: std.AutoHashMapUnmanaged(u64, void) = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) Allocator.Error!DedupCache {
        const ring = try allocator.alloc(u64, capacity);
        @memset(ring, 0);
        return .{ .ring = ring, .allocator = allocator };
    }

    pub fn deinit(dc: *DedupCache) void {
        dc.set.deinit(dc.allocator);
        dc.allocator.free(dc.ring);
    }

    /// Returns true if msg_id was NOT seen before (i.e. should be processed).
    pub fn add(dc: *DedupCache, msg_id: u64) bool {
        if (msg_id == 0) return true;
        dc.mu.lock();
        defer dc.mu.unlock();
        if (dc.set.contains(msg_id)) return false;
        // Evict the oldest entry if the ring is full
        const old = dc.ring[dc.head];
        if (old != 0) _ = dc.set.remove(old);
        dc.ring[dc.head] = msg_id;
        dc.head = (dc.head + 1) % dc.ring.len;
        dc.set.put(dc.allocator, msg_id, {}) catch {}; // best-effort
        return true;
    }
};
