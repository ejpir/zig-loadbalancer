/// Multi-Process Load Balancer Module (Compatibility Layer)
///
/// This module provides backward compatibility by re-exporting components
/// from their new locations after Phase 5 reorganization.
///
/// Components have been reorganized into logical modules:
/// - health/: Health state, circuit breaker, probing
/// - proxy/: Request proxying and connection management
/// - lb/: Load balancing strategies and worker state
///
/// This file will be deprecated once all imports are updated to use
/// the new module structure directly.

// Re-export from new locations
pub const proxy = @import("../proxy/handler.zig");
pub const health = @import("../health/probe.zig");
pub const circuit_breaker = @import("../health/circuit_breaker.zig");
pub const backend_selector = @import("../lb/selector.zig");
pub const worker_state = @import("../lb/worker.zig");
pub const connection_reuse = @import("../proxy/connection_reuse.zig");

const shared_region = @import("../memory/shared_region.zig");

// Primary exports
pub const WorkerState = worker_state.WorkerState;
pub const WorkerConfig = worker_state.Config;
pub const SharedHealthState = shared_region.SharedHealthState;
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const BackendSelector = backend_selector.BackendSelector;
pub const MAX_BACKENDS = shared_region.MAX_BACKENDS;

pub const generateHandler = proxy.generateHandler;
pub const ProxyError = proxy.ProxyError;

pub const HealthProbeContext = health.ProbeContext;
pub const healthProbeTask = health.probeTask;
