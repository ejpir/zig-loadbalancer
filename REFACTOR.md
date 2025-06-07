# Load Balancer Refactoring Plan

## Goal
Simplify code readability while preserving all performance optimizations. Make the codebase approachable for new contributors while maintaining 28K+ req/s throughput.

## Philosophy: Hide Complexity, Keep Performance

**Principle**: Fast code should look simple. Optimizations should be invisible unless you're specifically looking for them.

## Phase 1: Request Context Abstraction (Small Win)

### Problem
Memory management complexity scattered throughout request handling:

```zig
// Current: Exposed complexity in proxy.zig
var arena = std.heap.ArenaAllocator.init(ctx.allocator);
defer arena.deinit();
const arena_allocator = arena.allocator();
var buffer_pool = RequestBufferPool.init(arena_allocator);
defer buffer_pool.deinit();
```

### Solution: RequestContext Wrapper

**File**: `src/request_context.zig`
```zig
/// High-performance request context with hidden memory optimizations
pub const RequestContext = struct {
    arena: std.heap.ArenaAllocator,
    buffer_pool: RequestBufferPool,
    
    pub fn init(base_allocator: std.mem.Allocator) RequestContext {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        const arena_alloc = arena.allocator();
        return .{
            .arena = arena,
            .buffer_pool = RequestBufferPool.init(arena_alloc),
        };
    }
    
    pub fn deinit(self: *RequestContext) void {
        self.buffer_pool.deinit();
        self.arena.deinit();
    }
    
    /// Get allocator for this request (optimized arena-based)
    pub fn allocator(self: *RequestContext) std.mem.Allocator {
        return self.arena.allocator();
    }
    
    /// Get optimized buffer for HTTP processing
    pub fn getBuffer(self: *RequestContext, size: usize) ![]u8 {
        return self.buffer_pool.getBuffer(size);
    }
    
    pub fn returnBuffer(self: *RequestContext, buffer: []u8) void {
        self.buffer_pool.returnBuffer(buffer);
    }
};
```

### Refactor proxy.zig

**Before** (Complex):
```zig
var arena = std.heap.ArenaAllocator.init(ctx.allocator);
defer arena.deinit();
const arena_allocator = arena.allocator();
var buffer_pool = RequestBufferPool.init(arena_allocator);
defer buffer_pool.deinit();
var response_buffer = std.ArrayList(u8).init(arena_allocator);
```

**After** (Simple):
```zig
var req_ctx = RequestContext.init(ctx.allocator);
defer req_ctx.deinit();
var response_buffer = std.ArrayList(u8).init(req_ctx.allocator());
```

### Validation
- **Performance**: No change (same underlying implementation)
- **Readability**: 5 lines → 2 lines
- **Maintainability**: Memory management centralized

## Phase 2: Simplify Strategy Dispatch (Medium Win)

### Problem
Complex comptime strategy generation obscures simple business logic:

```zig
// Current: Hard to understand
const specialized_handler = proxy.generateSpecializedHandler(strategy);
const SpecializedSelector = load_balancer.generateSpecializedSelector(strategy);
```

### Solution: Simple Runtime Dispatch with Hidden Optimizations

**File**: `src/load_balancer.zig` (new, replaces load_balancer/strategy.zig)
```zig
/// Load balancer with clean API and hidden optimizations
const round_robin = @import("strategies/round_robin.zig");
const weighted = @import("strategies/weighted.zig");
const random = @import("strategies/random.zig");
const sticky = @import("strategies/sticky.zig");

pub fn selectBackend(
    strategy: LoadBalancerStrategy, 
    ctx: *const Context, 
    backends: *const BackendsList
) LoadBalancerError!usize {
    // Simple dispatch - optimizations hidden in strategy implementations
    return switch (strategy) {
        .round_robin => round_robin.select(ctx, backends),
        .weighted_round_robin => weighted.select(ctx, backends),
        .random => random.select(ctx, backends),
        .sticky => sticky.select(ctx, backends),
    };
}
```

### Refactor strategy files

**Move**: `src/load_balancer/` → `src/strategies/`

**File**: `src/strategies/round_robin.zig`
```zig
/// Round-robin selection with hidden SIMD optimizations
const optimizations = @import("../internal/simd_backend_ops.zig");

pub fn select(ctx: *const Context, backends: *const BackendsList) LoadBalancerError!usize {
    try optimizations.validateBackends(backends); // SIMD validation hidden
    
    const counter = global_counter.fetchAdd(1, .seq_cst);
    return optimizations.selectRoundRobin(counter, backends); // Size-based optimization hidden
}
```

### Validation
- **Performance**: Identical (same optimizations, hidden)
- **Readability**: Strategy dispatch becomes obvious
- **API**: Clean, discoverable functions

## Phase 3: Hide Optimization Implementation Details

### Problem
Optimization complexity leaks into business logic files.

### Solution: Internal Optimizations Module

**File**: `src/internal/simd_backend_ops.zig`
```zig
/// SIMD and size-optimized backend operations (internal use only)
const std = @import("std");
const types = @import("../types.zig");

pub fn validateBackends(backends: *const types.BackendsList) types.LoadBalancerError!void {
    // Move all SIMD validation logic here
    if (backends.items.len == 0) return error.NoBackendsAvailable;
    
    // SIMD health counting hidden here
    const healthy_count = countHealthyBackends(backends);
    if (healthy_count == 0) return error.NoHealthyBackends;
}

pub fn selectRoundRobin(counter: usize, backends: *const types.BackendsList) usize {
    const backend_count = backends.items.len;
    
    // Size-based optimization hidden here
    if (backend_count <= 4) {
        return selectRoundRobinSmall(counter, backends);
    } else if (backend_count <= 16) {
        return selectRoundRobinMedium(counter, backends);
    } else {
        return selectRoundRobinLarge(counter, backends);
    }
}

// All the complex SIMD implementations moved here...
fn selectRoundRobinSmall(counter: usize, backends: *const types.BackendsList) usize { /* ... */ }
fn selectRoundRobinMedium(counter: usize, backends: *const types.BackendsList) usize { /* ... */ }
fn selectRoundRobinLarge(counter: usize, backends: *const types.BackendsList) usize { /* ... */ }
```

### New Directory Structure
```
src/
├── main.zig                 # Clean entry point
├── server.zig              # Simple server setup
├── proxy.zig               # Clean proxy logic
├── load_balancer.zig       # Simple strategy dispatch
├── request_context.zig     # Memory management abstraction
├── health_check.zig        # Simple health check API
├── strategies/             # Clean strategy implementations
│   ├── round_robin.zig
│   ├── weighted.zig
│   ├── random.zig
│   └── sticky.zig
├── internal/               # Hidden optimization details
│   ├── simd_backend_ops.zig
│   ├── connection_pool_impl.zig
│   └── hazard_pointers.zig
├── config.zig
├── types.zig
└── tests/
```

## Phase 4: Simplify Main Proxy Logic

### Target: Clean proxy.zig

**Goal**: Make the main request flow obvious:

```zig
pub fn handleRequest(ctx: *const Context, config: *const ProxyConfig) !Respond {
    // 1. Set up request context (hides memory optimizations)
    var req_ctx = RequestContext.init(ctx.allocator);
    defer req_ctx.deinit();
    
    // 2. Select backend (hides strategy complexity)
    const backend_idx = try load_balancer.selectBackend(config.strategy, ctx, config.backends);
    const backend = &config.backends.items[backend_idx];
    
    // 3. Forward request (hides connection pooling complexity)
    return forwardRequest(ctx, backend, &req_ctx);
}

fn forwardRequest(ctx: *const Context, backend: *const BackendServer, req_ctx: *RequestContext) !Respond {
    // Connection pooling optimizations hidden in implementation
    // HTTP processing optimizations hidden in implementation
    // All the complex logic moved to internal functions
}
```

## Implementation Strategy

### Step 1: Measure Current Performance
```bash
hey -n 100000 http://localhost:9000  # Baseline: 28,538 req/s
```

### Step 2: Implement Phase 1 (RequestContext)
- Create `src/request_context.zig`
- Refactor proxy.zig to use RequestContext
- **Validate**: Performance unchanged, code simpler

### Step 3: Quick Feedback Loop
```bash
hey -n 100000 http://localhost:9000  # Should be same performance
```

### Step 4: If Step 2 successful, continue to Phase 2
- Create `src/load_balancer.zig`
- Move strategies to `src/strategies/`
- **Validate**: Performance unchanged, dispatch simpler

### Step 5: Repeat feedback loop pattern
- Small change → measure → validate → next change

## Success Metrics

### Performance (Must Not Regress)
- **Throughput**: Maintain 28K+ req/s
- **Latency**: P95 < 2.5ms, P99 < 5ms
- **Success Rate**: 100% under load

### Readability (Should Improve)
- **Main flow**: Understandable in 5 minutes
- **Strategy logic**: Obvious what each strategy does
- **Optimization complexity**: Hidden unless needed

### Maintainability (Should Improve)
- **API surface**: Smaller, cleaner public interfaces
- **Testing**: Easier to unit test strategies
- **Documentation**: Business logic separate from optimization details

## Rollback Plan

If any phase degrades performance:
1. **Immediate**: Revert the specific change
2. **Analyze**: Profile what caused the regression
3. **Adjust**: Modify approach to preserve performance
4. **Retry**: Implement with performance-preserving approach

## Notes

- **All optimizations preserved**: Lock-free algorithms, SIMD, comptime specialization, hazard pointers
- **Zero performance cost**: Abstractions compile to identical assembly
- **Incremental approach**: Each phase can be validated independently
- **Backward compatibility**: Old interfaces can coexist during transition