/// Multi-Process Load Balancer Module
///
/// Health-aware load balancing for single-threaded worker processes.
/// No atomics needed - each worker is independent.
///
/// Components:
/// - health_state: Bitmap-based health tracking
/// - circuit_breaker: Threshold-based state transitions
/// - backend_selector: Load balancing strategies
/// - worker_state: Composite state for request handling
///
/// Features:
/// - Circuit breaker: marks backends unhealthy after N failures
/// - Failover: automatically tries healthy backend on failure
/// - Async health probes: non-blocking checks via tardy event loop

pub const config = @import("config.zig");
pub const proxy = @import("proxy.zig");
pub const health = @import("health.zig");
pub const health_state = @import("health_state.zig");
pub const circuit_breaker = @import("circuit_breaker.zig");
pub const backend_selector = @import("backend_selector.zig");
pub const worker_state = @import("worker_state.zig");
pub const connection_reuse = @import("connection_reuse.zig");

// Primary exports
pub const WorkerState = worker_state.WorkerState;
pub const Config = worker_state.Config;
pub const HealthState = health_state.HealthState;
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const BackendSelector = backend_selector.BackendSelector;
pub const MAX_BACKENDS = health_state.MAX_BACKENDS;

pub const generateHandler = proxy.generateHandler;
pub const ProxyError = proxy.ProxyError;

pub const HealthProbeContext = health.ProbeContext;
pub const healthProbeTask = health.probeTask;
