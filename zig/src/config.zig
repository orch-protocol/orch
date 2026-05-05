//! ORCH Protocol Configuration
const std = @import("std");

pub const Config = struct {
    /// Unique node ID. Empty = auto-generate UUID.
    node_id: []const u8 = "",
    /// Advertised address (host:port). Default: "0.0.0.0:7946"
    addr: []const u8 = "0.0.0.0:7946",
    /// Bind address. Empty = use addr.
    bind_addr: []const u8 = "",
    /// Seed node addresses to join.
    seeds: []const []const u8 = &.{},
    /// Required cluster token. All nodes must share the same value.
    cluster_token: u64 = 0,
    /// Service name, e.g. "payment-service".
    service: []const u8 = "",
    /// Service version string.
    version: []const u8 = "0.0.1",
    /// Heartbeat send interval (ms). Default: 1000
    heartbeat_interval_ms: u64 = 1000,
    /// Heartbeat failure-detection timeout (ms). Default: 3000
    heartbeat_timeout_ms: u64 = 3000,
    /// Suspect-state timeout before declaring DEAD (ms). Default: 5000
    suspect_timeout_ms: u64 = 5000,
    /// Number of indirect helpers for SWIM probe. Default: 3
    indirect_ping_count: u32 = 3,
    /// Raft election timeout minimum (ms). Default: 150
    election_timeout_min_ms: u64 = 150,
    /// Raft election timeout maximum (ms). Default: 300
    election_timeout_max_ms: u64 = 300,
    /// Shell command for scale-out/in. Empty = disabled.
    scale_command: []const u8 = "",
    /// Scale evaluation interval (ms). Default: 60000
    scale_interval_ms: u64 = 60_000,
    /// CPU usage threshold for scale-out [0,1]. Default: 0.8
    scale_cpu_threshold: f32 = 0.8,
    /// Memory usage threshold for scale-out [0,1]. Default: 0.8
    scale_mem_threshold: f32 = 0.8,
    /// Number of processes per scale step. Default: 1
    scale_delta: u32 = 1,
    /// Desired cluster size. 0 = disabled.
    desired_count: u32 = 0,
    /// Service to monitor for scaling. Empty = self.service.
    scale_service: []const u8 = "",

    /// Derive effective bind address.
    pub fn effectiveBindAddr(self: *const Config) []const u8 {
        if (self.bind_addr.len > 0) return self.bind_addr;
        return self.addr;
    }
};
