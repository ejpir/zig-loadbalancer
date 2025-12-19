/// Load Balancer Module - Core Load Balancing Logic
///
/// This module provides the core load balancing functionality:
/// - selector: Backend selection strategies (round-robin, weighted, etc.)
/// - worker: Worker state management for request handling
///
/// The load balancer integrates with health checking to route requests
/// only to healthy backends.

pub const selector = @import("selector.zig");
pub const BackendSelector = selector.BackendSelector;
pub const SelectionStrategy = selector.SelectionStrategy;

pub const worker = @import("worker.zig");
pub const WorkerState = worker.WorkerState;
pub const WorkerConfig = worker.Config;
