/// Health Module - Backend Health Tracking and Probing
///
/// This module provides health management for backend servers including:
/// - Shared health state (bitmap-based health tracking)
/// - Circuit breaker (threshold-based health transitions)
/// - Health probing (periodic availability checks)
///
/// All components work together to maintain a unified view of backend health
/// across multiple worker processes.

// Core health state
pub const state = @import("state.zig");
pub const SharedHealthState = state.SharedHealthState;
pub const MAX_BACKENDS = state.MAX_BACKENDS;

// Circuit breaker for threshold-based health transitions
pub const circuit_breaker = @import("circuit_breaker.zig");
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const CircuitBreakerConfig = circuit_breaker.Config;

// Health probing
pub const probe = @import("probe.zig");
pub const startHealthProbes = probe.startHealthProbes;
pub const ProbeContext = probe.ProbeContext;
pub const probeTask = probe.probeTask;
