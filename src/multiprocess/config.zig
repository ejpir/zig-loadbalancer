/// Multi-Process Configuration
///
/// Module exports for the multiprocess subsystem.

pub const worker_state = @import("worker_state.zig");
pub const health_state = @import("health_state.zig");
pub const circuit_breaker = @import("circuit_breaker.zig");
pub const backend_selector = @import("backend_selector.zig");

pub const WorkerState = worker_state.WorkerState;
pub const Config = worker_state.Config;
pub const HealthState = health_state.HealthState;
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const BackendSelector = backend_selector.BackendSelector;
pub const MAX_BACKENDS = health_state.MAX_BACKENDS;
