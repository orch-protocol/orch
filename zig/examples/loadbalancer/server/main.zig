//! Load-balancer backend HTTP server with ORCH membership.
//! Equivalent to Go examples/loadbalancer/server/main.go
//!
//! Env vars:
//!   PORT          – HTTP listen port (default 8080)
//!   ORCH_ADDR     – advertised gossip address (e.g. "0.0.0.0:7946")
//!   ORCH_SEEDS    – comma-separated seed addresses
//!   ORCH_CLUSTER_TOKEN – required cluster token
//!   ORCH_SERVICE  – service name (default "http-backend")
const std = @import("std");
const orch = @import("orch");
const net = std.Io.net;
const getenv = orch.getenv;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // HTTP port
    const port_str = getenv("PORT") orelse "8080";
    const http_port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    // ORCH config
    var cfg = try orch.configFromEnv(allocator);
    if (cfg.cluster_token == 0) {
        std.log.err("ORCH_CLUSTER_TOKEN must be set", .{});
        std.process.exit(1);
    }
    if (cfg.addr.len == 0) {
        cfg.addr = std.fmt.allocPrint(allocator, "0.0.0.0:{}", .{http_port + 1000}) catch return;
    }
    if (cfg.service.len == 0) cfg.service = "http-backend";

    // Start ORCH node
    const node = try orch.Node.init(allocator, io, cfg);
    defer node.deinit();
    try node.start();
    std.log.info("server: ORCH started  addr={s}  http=:{}", .{ cfg.addr, http_port });

    // HTTP listener (raw TCP – simple text/plain response)
    var http_buf: [32]u8 = undefined;
    const http_addr_str = try std.fmt.bufPrint(&http_buf, "0.0.0.0:{}", .{http_port});
    const http_ip = try orch.parseAddr(http_addr_str);
    var http_srv = try http_ip.listen(io, .{});
    defer http_srv.deinit(io);
    std.log.info("server: HTTP listening on :{}", .{http_port});

    // Signal handling
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

    // Shared request counter
    var req_count = std.atomic.Value(u64).init(0);

    // Accept HTTP connections in a group
    var http_group: std.Io.Group = .init;
    try http_group.concurrent(io, acceptHttpLoop, .{ &http_srv, io, allocator, node, &req_count, &shutdown });

    // Main wait loop
    while (!shutdown.load(.acquire)) {
        io.sleep(.{ .nanoseconds = @as(i96, std.time.ns_per_s) }, .awake) catch break;
    }

    http_group.cancel(io);
    http_group.await(io) catch {};

    std.log.info("server: shutdown. served {} requests", .{req_count.load(.acquire)});
    node.shutdown();
}

fn acceptHttpLoop(
    srv: *net.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    node: *orch.Node,
    req_count: *std.atomic.Value(u64),
    shutdown: *const std.atomic.Value(bool),
) error{Canceled}!void {
    var group: std.Io.Group = .init;
    defer group.await(io) catch {};

    while (!shutdown.load(.acquire)) {
        const stream = srv.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        group.concurrent(io, handleHttpConn, .{ stream, io, allocator, node, req_count }) catch {
            stream.close(io);
        };
    }
}

fn handleHttpConn(
    stream: net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    node: *orch.Node,
    req_count: *std.atomic.Value(u64),
) error{Canceled}!void {
    defer stream.close(io);

    var rb: [4096]u8 = undefined;
    var wb: [8192]u8 = undefined;
    var reader = stream.reader(io, &rb);
    var writer = stream.writer(io, &wb);

    // Read request line (we don't need to parse headers for this demo)
    var line_buf: [1024]u8 = undefined;
    var line_len: usize = 0;
    {
        var prev: u8 = 0;
        while (line_len < line_buf.len - 1) {
            var ch_buf: [1]u8 = undefined;
            var iov = [1][]u8{&ch_buf};
            reader.interface.readVecAll(&iov) catch break;
            if (prev == '\r' and ch_buf[0] == '\n') break;
            if (ch_buf[0] != '\r') line_buf[line_len] = ch_buf[0];
            line_len += 1;
            prev = ch_buf[0];
        }
    }
    const request_line = line_buf[0..line_len];

    _ = req_count.fetchAdd(1, .monotonic);
    const total = req_count.load(.acquire);

    const is_leader = node.isLeader();
    const cluster_size = node.clusterSize();

    const body = std.fmt.allocPrint(allocator, "node={s} requests={} leader={} cluster_size={} path={s}\n", .{
        node.gossip.self_id, total, is_leader, cluster_size, request_line,
    }) catch return;
    defer allocator.free(body);

    const response = std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    ) catch return;
    defer allocator.free(response);

    writer.interface.writeAll(response) catch {};
    writer.interface.flush() catch {};
}
