//! OpenTelemetry Tracing for Load Balancer
//!
//! Provides distributed tracing for request lifecycle using the zig-o11y SDK.
//!
//! Usage:
//!   // Initialize at startup with OTLP endpoint
//!   try telemetry.init(allocator, "localhost:4318");
//!   defer telemetry.deinit();
//!
//!   // Create root span for request
//!   var root_span = telemetry.startServerSpan("proxy_request");
//!   defer root_span.end();
//!   root_span.setStringAttribute("http.method", "GET");
//!
//!   // Create child spans for sub-operations
//!   var child = telemetry.startChildSpan(&root_span, "backend_connection", .Client);
//!   defer child.end();
//!   child.setStringAttribute("backend.host", "127.0.0.1");

const std = @import("std");
const otel = @import("opentelemetry");
const context = otel.api.context;

const log = std.log.scoped(.telemetry);

/// Global telemetry state
var global_state: ?*TelemetryState = null;

const TelemetryState = struct {
    allocator: std.mem.Allocator,
    config: *otel.otlp.ConfigOptions,
    exporter: *otel.trace.OTLPExporter,
    processor: otel.trace.SimpleProcessor,
    provider: *otel.trace.TracerProvider,
    tracer: *otel.api.trace.TracerImpl,
    prng: *std.Random.DefaultPrng, // Keep PRNG alive on heap
};

/// Initialize the telemetry system with an OTLP endpoint.
/// Endpoint should be in "host:port" format (e.g., "localhost:4318").
pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !void {
    if (global_state != null) {
        log.warn("Telemetry already initialized", .{});
        return;
    }

    const state = try allocator.create(TelemetryState);
    errdefer allocator.destroy(state);

    // Create OTLP config
    const config = try otel.otlp.ConfigOptions.init(allocator);
    errdefer config.deinit();
    config.endpoint = endpoint;
    config.scheme = .http; // Jaeger OTLP uses HTTP by default
    config.protocol = .http_protobuf; // OTLP uses protobuf over HTTP

    // Create OTLP exporter with service name
    const exporter = try otel.trace.OTLPExporter.initWithServiceName(allocator, config, "zzz-load-balancer");
    errdefer exporter.deinit();

    // Create random ID generator with heap-allocated PRNG for persistent state
    const nanos: i128 = otel.compat.nanoTimestamp();
    const seed: u64 = @intFromPtr(state) ^ @as(u64, @truncate(@intFromPtr(&allocator))) ^ @as(u64, @truncate(@as(u128, @bitCast(nanos))));
    const prng = try allocator.create(std.Random.DefaultPrng);
    errdefer allocator.destroy(prng);
    prng.* = std.Random.DefaultPrng.init(seed);
    const random_gen = otel.trace.RandomIDGenerator.init(prng.random());
    const id_gen = otel.trace.IDGenerator{ .Random = random_gen };

    // Create tracer provider
    const provider = try otel.trace.TracerProvider.init(allocator, id_gen);
    errdefer provider.shutdown();

    // Create simple processor - exports spans immediately (synchronously)
    // Store it in state FIRST so the pointer is stable
    state.processor = otel.trace.SimpleProcessor.init(allocator, exporter.asSpanExporter());

    // Add the processor to the provider - use pointer to state.processor, not a stack copy
    try provider.addSpanProcessor(state.processor.asSpanProcessor());

    // Get a tracer for the load balancer
    const tracer = try provider.getTracer(.{
        .name = "zzz-load-balancer",
        .version = "0.1.0",
    });

    // Set remaining state fields (processor already set above)
    state.allocator = allocator;
    state.config = config;
    state.exporter = exporter;
    state.provider = provider;
    state.tracer = tracer;
    state.prng = prng;

    global_state = state;

    log.info("Telemetry initialized with endpoint: {s}", .{endpoint});
}

/// Shutdown the telemetry system
pub fn deinit() void {
    const state = global_state orelse return;
    const allocator = state.allocator;

    // Shutdown provider (which shuts down processors and exports pending spans)
    state.provider.shutdown();

    // Clean up config and exporter
    state.exporter.deinit();
    state.config.deinit();

    // Clean up PRNG
    allocator.destroy(state.prng);

    allocator.destroy(state);
    global_state = null;

    log.info("Telemetry shutdown complete", .{});
}

/// Check if telemetry is enabled
pub fn isEnabled() bool {
    return global_state != null;
}

/// Span kind for creating spans
pub const SpanKind = enum {
    Server,
    Client,
    Internal,
};

/// Span wrapper for easier use with parent-child relationships
pub const Span = struct {
    inner: ?otel.api.trace.Span,
    tracer: ?*otel.api.trace.TracerImpl,
    allocator: std.mem.Allocator,
    parent_ctx: ?context.Context,

    const Self = @This();

    /// Set a string attribute on the span
    pub fn setStringAttribute(self: *Self, key: []const u8, value: []const u8) void {
        if (self.inner) |*span| {
            span.setAttribute(key, .{ .string = value }) catch {};
        }
    }

    /// Set an integer attribute on the span
    pub fn setIntAttribute(self: *Self, key: []const u8, value: i64) void {
        if (self.inner) |*span| {
            span.setAttribute(key, .{ .int = value }) catch {};
        }
    }

    /// Set a boolean attribute on the span
    pub fn setBoolAttribute(self: *Self, key: []const u8, value: bool) void {
        if (self.inner) |*span| {
            span.setAttribute(key, .{ .bool = value }) catch {};
        }
    }

    /// Add an event to the span
    pub fn addEvent(self: *Self, name: []const u8) void {
        if (self.inner) |*span| {
            span.addEvent(name, null, null) catch {};
        }
    }

    /// Set the span status to error with a message
    pub fn setError(self: *Self, message: []const u8) void {
        if (self.inner) |*span| {
            span.setStatus(.{ .code = .Error, .description = message });
        }
    }

    /// Set the span status to OK
    pub fn setOk(self: *Self) void {
        if (self.inner) |*span| {
            span.setStatus(.{ .code = .Ok, .description = "" });
        }
    }

    /// Get this span's context for creating child spans
    pub fn getContext(self: *Self) ?context.Context {
        if (self.inner) |*span| {
            const span_context = span.getContext();
            return otel.api.trace.insertSpanContext(self.allocator, span_context) catch null;
        }
        return null;
    }

    /// End the span and clean up context
    pub fn end(self: *Self) void {
        if (self.inner) |*span| {
            if (self.tracer) |tracer| {
                tracer.endSpan(span);
            }
            span.deinit();
        }
        // Clean up parent context if we created one
        if (self.parent_ctx) |*ctx| {
            otel.api.trace.freeSerializedSpanContext(self.allocator, ctx.*);
            ctx.deinit();
        }
        self.inner = null;
        self.parent_ctx = null;
    }
};

/// Start a new server span (for incoming requests)
pub fn startServerSpan(name: []const u8) Span {
    const state = global_state orelse return Span{ .inner = null, .tracer = null, .allocator = undefined, .parent_ctx = null };

    const span = state.tracer.startSpan(state.allocator, name, .{
        .kind = .Server,
    }) catch |err| {
        log.debug("Failed to start span: {}", .{err});
        return Span{ .inner = null, .tracer = null, .allocator = state.allocator, .parent_ctx = null };
    };

    return Span{
        .inner = span,
        .tracer = state.tracer,
        .allocator = state.allocator,
        .parent_ctx = null,
    };
}

/// Start a new client span (for outgoing requests to backends)
pub fn startClientSpan(name: []const u8) Span {
    const state = global_state orelse return Span{ .inner = null, .tracer = null, .allocator = undefined, .parent_ctx = null };

    const span = state.tracer.startSpan(state.allocator, name, .{
        .kind = .Client,
    }) catch |err| {
        log.debug("Failed to start span: {}", .{err});
        return Span{ .inner = null, .tracer = null, .allocator = state.allocator, .parent_ctx = null };
    };

    return Span{
        .inner = span,
        .tracer = state.tracer,
        .allocator = state.allocator,
        .parent_ctx = null,
    };
}

/// Start a new internal span
pub fn startInternalSpan(name: []const u8) Span {
    const state = global_state orelse return Span{ .inner = null, .tracer = null, .allocator = undefined, .parent_ctx = null };

    const span = state.tracer.startSpan(state.allocator, name, .{
        .kind = .Internal,
    }) catch |err| {
        log.debug("Failed to start span: {}", .{err});
        return Span{ .inner = null, .tracer = null, .allocator = state.allocator, .parent_ctx = null };
    };

    return Span{
        .inner = span,
        .tracer = state.tracer,
        .allocator = state.allocator,
        .parent_ctx = null,
    };
}

/// Start a child span with a parent span
pub fn startChildSpan(parent: *Span, name: []const u8, kind: SpanKind) Span {
    const state = global_state orelse return Span{ .inner = null, .tracer = null, .allocator = undefined, .parent_ctx = null };

    // Get parent context
    const parent_ctx = parent.getContext() orelse {
        // If no parent context, create a standalone span
        return switch (kind) {
            .Server => startServerSpan(name),
            .Client => startClientSpan(name),
            .Internal => startInternalSpan(name),
        };
    };

    const otel_kind: otel.api.trace.SpanKind = switch (kind) {
        .Server => .Server,
        .Client => .Client,
        .Internal => .Internal,
    };

    const span = state.tracer.startSpan(state.allocator, name, .{
        .kind = otel_kind,
        .parent_context = parent_ctx,
    }) catch |err| {
        log.debug("Failed to start child span: {}", .{err});
        // Clean up parent context on failure
        var ctx_copy = parent_ctx;
        otel.api.trace.freeSerializedSpanContext(state.allocator, ctx_copy);
        ctx_copy.deinit();
        return Span{ .inner = null, .tracer = null, .allocator = state.allocator, .parent_ctx = null };
    };

    return Span{
        .inner = span,
        .tracer = state.tracer,
        .allocator = state.allocator,
        .parent_ctx = parent_ctx,
    };
}
