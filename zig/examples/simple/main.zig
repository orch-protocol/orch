//! Simple ORCH cluster node – equivalent to Go examples/simple/main.go
//! Reads configuration from environment variables, starts a cluster node,
//! and prints membership changes until SIGINT.
const std = @import("std");
const orch = @import("orch");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Threaded I/O (supports networking + fiber concurrency on all platforms)
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Load config from environment
    var cfg = try orch.configFromEnv(allocator);
    if (cfg.cluster_token == 0) {
        std.log.err("ORCH_CLUSTER_TOKEN must be set (non-zero u64)", .{});
        std.process.exit(1);
    }
    if (cfg.addr.len == 0) cfg.addr = "0.0.0.0:7946";
    if (cfg.service.len == 0) cfg.service = "simple";

    std.log.info("orch-simple: starting addr={s} service={s}", .{ cfg.addr, cfg.service });

    const node = try orch.Node.init(allocator, io, cfg);
    defer node.deinit();

    try node.start();
    std.log.info("orch-simple: node started, id={s}", .{node.gossip.self_id});

    // Install SIGINT/SIGTERM handler via std.posix
    var shutdown = std.atomic.Value(bool).init(false);
    const SigHandler = struct {
        var flag: *std.atomic.Value(bool) = undefined;
        fn handle(_: std.c.SIG) callconv(.c) void {
            flag.store(true, .release);
        }
    };
    SigHandler.flag = &shutdown;
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = SigHandler.handle },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

    // Print cluster status every 5 seconds
    var last_size: usize = 0;
    while (!shutdown.load(.acquire)) {
        io.sleep(.{ .nanoseconds = @as(i96, 5 * std.time.ns_per_s) }, .awake) catch break;

        const size = node.clusterSize();
        const is_leader = node.isLeader();

        if (size != last_size) {
            std.log.info("cluster size={} leader={}", .{ size, is_leader });
            last_size = size;

            const nodes = node.aliveNodesInfo(allocator) catch continue;
            defer allocator.free(nodes);
            for (nodes) |n| {
                std.log.info("  peer  id={s}  addr={s}  service={s}", .{ n.id, n.addr, n.service });
            }
        }
    }

    std.log.info("orch-simple: shutting down", .{});
    node.shutdown();
}
