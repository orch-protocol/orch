//! HTTP load balancer using ORCH for service discovery.
//! Equivalent to Go examples/loadbalancer/lb/main.go
//!
//! Env vars:
//!   PORT              – HTTP listen port for incoming requests (default 8080)
//!   ORCH_ADDR         – gossip address (default 0.0.0.0:7950)
//!   ORCH_SEEDS        – comma-separated gossip seeds
//!   ORCH_CLUSTER_TOKEN – required
//!   ORCH_SERVICE      – service name to discover (default "http-backend")
//!   ORCH_LB_SERVICE   – service name of the LB itself (default "lb")
const std = @import("std");
const orch = @import("orch");
const net = std.Io.net;
const getenv = orch.getenv;

const transport = orch;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port_str = getenv("PORT") orelse "8080";
    const http_port = std.fmt.parseInt(u16, port_str, 10) catch 8080;

    const target_service = getenv("ORCH_SERVICE") orelse "http-backend";

    var cfg = try orch.configFromEnv(allocator);
    if (cfg.cluster_token == 0) {
        std.log.err("ORCH_CLUSTER_TOKEN must be set", .{});
        std.process.exit(1);
    }
    if (cfg.addr.len == 0) cfg.addr = "0.0.0.0:7950";
    if (cfg.service.len == 0) {
        cfg.service = getenv("ORCH_LB_SERVICE") orelse "lb";
    }

    const node = try orch.Node.init(allocator, io, cfg);
    defer node.deinit();
    try node.start();
    std.log.info("lb: ORCH started  addr={s}", .{cfg.addr});

    // HTTP listener
    var http_buf: [32]u8 = undefined;
    const http_addr_str = try std.fmt.bufPrint(&http_buf, "0.0.0.0:{}", .{http_port});
    const http_ip = try orch.parseAddr(http_addr_str);
    var http_srv = try http_ip.listen(io, .{});
    defer http_srv.deinit(io);
    std.log.info("lb: listening on :{}", .{http_port});

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

    // Round-robin index
    var rr_index = std.atomic.Value(u64).init(0);

    var group: std.Io.Group = .init;
    try group.concurrent(io, acceptLoop, .{
        &http_srv, io, allocator, node, target_service, &rr_index, &shutdown,
    });

    while (!shutdown.load(.acquire)) {
        io.sleep(.{ .nanoseconds = @as(i96, std.time.ns_per_s) }, .awake) catch break;
    }

    group.cancel(io);
    group.await(io) catch {};

    std.log.info("lb: shutdown", .{});
    node.shutdown();
}

fn acceptLoop(
    srv: *net.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    node: *orch.Node,
    target_service: []const u8,
    rr_index: *std.atomic.Value(u64),
    shutdown: *const std.atomic.Value(bool),
) error{Canceled}!void {
    var conn_group: std.Io.Group = .init;
    defer conn_group.await(io) catch {};

    while (!shutdown.load(.acquire)) {
        const stream = srv.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        conn_group.concurrent(io, handleProxy, .{
            stream, io, allocator, node, target_service, rr_index,
        }) catch {
            stream.close(io);
        };
    }
}

fn handleProxy(
    client: net.Stream,
    io: std.Io,
    allocator: std.mem.Allocator,
    node: *orch.Node,
    target_service: []const u8,
    rr_index: *std.atomic.Value(u64),
) error{Canceled}!void {
    defer client.close(io);

    // Pick a backend via round-robin
    const backends = node.aliveNodesInfo(allocator) catch return;
    defer allocator.free(backends);

    // Filter to target service
    var targets = std.array_list.AlignedManaged(orch.NodeInfo, null).init(allocator);
    defer targets.deinit();
    for (backends) |b| {
        if (std.mem.eql(u8, b.service, target_service)) targets.append(b) catch return;
    }
    if (targets.items.len == 0) {
        sendError(client, io, allocator, 503, "No backends available") catch {};
        return;
    }

    const idx = rr_index.fetchAdd(1, .monotonic) % @as(u64, @intCast(targets.items.len));
    const backend = targets.items[@intCast(idx)];

    std.log.debug("lb: → {s} ({s})", .{ backend.addr, backend.id });

    // Read client request
    var client_rb: [8192]u8 = undefined;
    var client_wb: [8192]u8 = undefined;
    var client_reader = client.reader(io, &client_rb);
    var client_writer = client.writer(io, &client_wb);

    // Read raw request bytes until double-CRLF
    var req_buf = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer req_buf.deinit();
    {
        var tmp: [1]u8 = undefined;
        var header_end: u8 = 0; // tracks CRLFCRLF state machine
        while (req_buf.items.len < 65536) {
            var iov2 = [1][]u8{&tmp};
            client_reader.interface.readVecAll(&iov2) catch break;
            req_buf.append(tmp[0]) catch return;
            // Detect end of headers
            if (tmp[0] == '\n') {
                header_end += 1;
                if (header_end >= 2) break;
            } else if (tmp[0] != '\r') {
                header_end = 0;
            }
        }
    }

    // Connect to backend and forward
    const backend_ip = transport.parseAddr(backend.addr) catch {
        sendError(client, io, allocator, 502, "Bad Gateway") catch {};
        return;
    };
    const up = backend_ip.connect(io, .{ .mode = .stream }) catch {
        sendError(client, io, allocator, 502, "Backend unreachable") catch {};
        return;
    };
    defer up.close(io);

    var up_rb: [65536]u8 = undefined;
    var up_wb: [8192]u8 = undefined;
    var up_reader = up.reader(io, &up_rb);
    var up_writer = up.writer(io, &up_wb);

    // Forward request to backend
    up_writer.interface.writeAll(req_buf.items) catch return;
    up_writer.interface.flush() catch return;

    // Stream response back to client
    var resp_buf: [65536]u8 = undefined;
    while (true) {
        var vecs = [1][]u8{&resp_buf};
        const n = up_reader.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        client_writer.interface.writeAll(resp_buf[0..n]) catch break;
        client_writer.interface.flush() catch break;
    }
}

fn sendError(stream: net.Stream, io: std.Io, allocator: std.mem.Allocator, code: u16, msg: []const u8) !void {
    var wb: [512]u8 = undefined;
    var writer = stream.writer(io, &wb);
    const resp = std.fmt.allocPrint(allocator, "HTTP/1.1 {} {s}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}", .{
        code, msg, msg.len, msg,
    }) catch return;
    defer allocator.free(resp);
    writer.interface.writeAll(resp) catch {};
    writer.interface.flush() catch {};
}
