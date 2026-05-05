//! Scale manager – monitors cluster metrics and spawns/kills processes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
fn List(comptime T: type) type {
    return std.array_list.AlignedManaged(T, null);
}

const Config = @import("config.zig").Config;
const proto = @import("proto.zig");

pub const NodeMetrics = struct {
    node_id: []const u8,
    cpu_usage: f32,
    mem_usage: f32,
    last_seen_ns: i128,
};

pub const ScaleManager = struct {
    allocator: Allocator,
    io: Io,
    cfg: *const Config,

    last_scale_ns: i128 = 0,

    // Callbacks provided by GossipNode
    is_leader_fn: *const fn () bool,
    metrics_fn: *const fn (Allocator) []NodeMetrics,
    service_count_fn: *const fn ([]const u8) usize,
    broadcast_fn: *const fn (proto.ScaleSignal) void,

    pub fn init(
        allocator: Allocator,
        io: Io,
        cfg: *const Config,
        is_leader_fn: *const fn () bool,
        metrics_fn: *const fn (Allocator) []NodeMetrics,
        service_count_fn: *const fn ([]const u8) usize,
        broadcast_fn: *const fn (proto.ScaleSignal) void,
    ) Allocator.Error!*ScaleManager {
        const s = try allocator.create(ScaleManager);
        s.* = .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .is_leader_fn = is_leader_fn,
            .metrics_fn = metrics_fn,
            .service_count_fn = service_count_fn,
            .broadcast_fn = broadcast_fn,
        };
        return s;
    }

    pub fn deinit(s: *ScaleManager) void {
        s.allocator.destroy(s);
    }

    /// Start the scale loop as a concurrent task in the given group.
    pub fn start(s: *ScaleManager, group: *Io.Group) !void {
        if (s.cfg.scale_command.len == 0) {
            std.log.info("scale: disabled (no ORCH_SCALE_CMD)", .{});
            return;
        }
        try group.concurrent(s.io, scaleLoop, .{s});
    }

    fn scaleLoop(s: *ScaleManager) error{Canceled}!void {
        const interval_ns = s.cfg.scale_interval_ms * std.time.ns_per_ms;
        while (true) {
            try s.io.sleep(.{ .raw = interval_ns }, .monotonic);
            if (!s.is_leader_fn()) continue;

            const now = std.time.nanoTimestamp();
            if (now - s.last_scale_ns < @as(i128, @intCast(interval_ns))) continue;

            s.evaluate() catch {};
        }
    }

    fn evaluate(s: *ScaleManager) !void {
        const target_svc = if (s.cfg.scale_service.len > 0)
            s.cfg.scale_service
        else
            s.cfg.service;

        // Desired-count check first
        if (s.cfg.desired_count > 0) {
            const current = s.service_count_fn(target_svc);
            if (current < s.cfg.desired_count) {
                std.log.info("scale: service '{s}' {}/{}  → scale OUT", .{
                    target_svc, current, s.cfg.desired_count,
                });
                const signal = proto.ScaleSignal{
                    .direction = .out,
                    .service = target_svc,
                    .delta = s.cfg.scale_delta,
                    .reason = "desired_count",
                };
                s.broadcast_fn(signal);
                try s.launchProcess();
                s.last_scale_ns = std.time.nanoTimestamp();
                return;
            }
        }

        // Metrics-based scaling
        var arena = std.heap.ArenaAllocator.init(s.allocator);
        defer arena.deinit();
        const metrics = s.metrics_fn(arena.allocator());
        if (metrics.len == 0) return;

        var avg_cpu: f32 = 0;
        var avg_mem: f32 = 0;
        for (metrics) |m| {
            avg_cpu += m.cpu_usage;
            avg_mem += m.mem_usage;
        }
        avg_cpu /= @floatFromInt(metrics.len);
        avg_mem /= @floatFromInt(metrics.len);

        var reason_buf: [64]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "cpu={d:.2} mem={d:.2}", .{ avg_cpu, avg_mem }) catch "metrics";

        if (avg_cpu >= s.cfg.scale_cpu_threshold or avg_mem >= s.cfg.scale_mem_threshold) {
            std.log.info("scale: OUT  cpu={d:.2} mem={d:.2}", .{ avg_cpu, avg_mem });
            s.broadcast_fn(.{ .direction = .out, .service = target_svc, .delta = s.cfg.scale_delta, .reason = reason });
            try s.launchProcess();
            s.last_scale_ns = std.time.nanoTimestamp();
        } else if (avg_cpu <= s.cfg.scale_cpu_threshold / 2 and avg_mem <= s.cfg.scale_mem_threshold / 2 and metrics.len > 1) {
            if (s.cfg.desired_count == 0 or s.service_count_fn(target_svc) > s.cfg.desired_count) {
                std.log.info("scale: IN  cpu={d:.2} mem={d:.2}", .{ avg_cpu, avg_mem });
                s.broadcast_fn(.{ .direction = .in, .service = target_svc, .delta = s.cfg.scale_delta, .reason = reason });
                s.last_scale_ns = std.time.nanoTimestamp();
            }
        }
    }

    fn launchProcess(s: *ScaleManager) !void {
        const cmd_str = s.cfg.scale_command;
        if (cmd_str.len == 0) return;

        // Simple word splitting (no quoting)
        var parts = List([]const u8).init(s.allocator);
        defer parts.deinit();
        var it = std.mem.tokenizeScalar(u8, cmd_str, ' ');
        while (it.next()) |tok| try parts.append(tok);
        if (parts.items.len == 0) return;

        // Replace env-var-style placeholders
        var processed = List([]const u8).init(s.allocator);
        defer {
            for (processed.items) |p| s.allocator.free(p);
            processed.deinit();
        }
        var token_buf: [32]u8 = undefined;
        for (parts.items) |part| {
            if (std.mem.eql(u8, part, "$ORCH_ADDR")) {
                try processed.append(try s.allocator.dupe(u8, s.cfg.addr));
            } else if (std.mem.eql(u8, part, "$ORCH_SERVICE")) {
                try processed.append(try s.allocator.dupe(u8, s.cfg.service));
            } else if (std.mem.eql(u8, part, "$ORCH_CLUSTER_TOKEN")) {
                const t = std.fmt.bufPrint(&token_buf, "{}", .{s.cfg.cluster_token}) catch "0";
                try processed.append(try s.allocator.dupe(u8, t));
            } else {
                try processed.append(try s.allocator.dupe(u8, part));
            }
        }

        std.log.info("scale: launching '{s}'", .{processed.items[0]});

        // Use std.process.spawn via the Io interface
        const spawn_args: std.process.SpawnOptions = .{
            .argv = processed.items,
            .io = .{
                .stdin = .{ .close = {} },
                .stdout = .{ .inherit = {} },
                .stderr = .{ .inherit = {} },
            },
        };
        const child = std.process.spawn(s.io, spawn_args) catch |err| {
            std.log.err("scale: spawn failed: {}", .{err});
            return;
        };
        _ = child; // fire-and-forget; child inherits stdio
    }
};
