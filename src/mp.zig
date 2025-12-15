/// Multi-Process Load Balancer Module
///
/// Health-aware load balancing for single-threaded worker processes.
/// No atomics needed - each worker is independent.
///
/// Features:
/// - Circuit breaker: marks backends unhealthy after N failures
/// - Failover: automatically tries healthy backend on failure
/// - Async health probes: non-blocking checks via tardy event loop

pub const config = @import("mp/config.zig");
pub const proxy = @import("mp/proxy.zig");
pub const health = @import("mp/health.zig");

// Re-exports for convenience
pub const Config = config.Config;
pub const HealthConfig = config.HealthConfig;
pub const MAX_BACKENDS = config.MAX_BACKENDS;

pub const generateHandler = proxy.generateHandler;
pub const ProxyError = proxy.ProxyError;

pub const HealthProbeContext = health.ProbeContext;
pub const healthProbeTask = health.probeTask;
