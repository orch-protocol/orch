const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const orch_mod = b.addModule("orch", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Example: simple
    const simple_mod = b.createModule(.{
        .root_source_file = b.path("examples/simple/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "orch", .module = orch_mod }},
    });
    const simple = b.addExecutable(.{
        .name = "simple",
        .root_module = simple_mod,
    });
    b.installArtifact(simple);

    const run_simple = b.addRunArtifact(simple);
    run_simple.step.dependOn(b.getInstallStep());
    const run_simple_step = b.step("run-simple", "Run the simple example");
    run_simple_step.dependOn(&run_simple.step);

    // Example: loadbalancer server (HTTP backend)
    const lb_server_mod = b.createModule(.{
        .root_source_file = b.path("examples/loadbalancer/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "orch", .module = orch_mod }},
    });
    const lb_server = b.addExecutable(.{
        .name = "lb-server",
        .root_module = lb_server_mod,
    });
    b.installArtifact(lb_server);

    // Example: loadbalancer (proxy + ORCH discovery)
    const lb_mod = b.createModule(.{
        .root_source_file = b.path("examples/loadbalancer/lb/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "orch", .module = orch_mod }},
    });
    const lb = b.addExecutable(.{
        .name = "lb",
        .root_module = lb_mod,
    });
    b.installArtifact(lb);

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
