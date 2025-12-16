/// Multi-Process Streaming Proxy
///
/// Streaming proxy with automatic failover for single-threaded workers.
const std = @import("std");
const log = std.log.scoped(.mp);

const zzz = @import("zzz");
const http = zzz.HTTP;

const types = @import("../core/types.zig");
const UltraSock = @import("../http/ultra_sock.zig").UltraSock;
const http_utils = @import("../http/http_utils.zig");
const simd_parse = @import("../internal/simd_parse.zig");
const metrics = @import("../utils/metrics.zig");
const WorkerState = @import("worker_state.zig").WorkerState;
const connection_reuse = @import("connection_reuse.zig");

pub const ProxyError = error{
    ConnectionFailed,
    BackendUnavailable,
    SendFailed,
    ReadFailed,
    Timeout,
    EmptyResponse,
    InvalidResponse,
};

/// Generate handler with health-aware load balancing
pub fn generateHandler(comptime strategy: types.LoadBalancerStrategy) fn (*const http.Context, *WorkerState) anyerror!http.Respond {
    return struct {
        pub fn handle(ctx: *const http.Context, state: *WorkerState) !http.Respond {
            if (state.backends.items.len == 0) {
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends configured" });
            }

            // Note: selectBackend manages its own counter for round-robin
            const backend_idx = state.selectBackend(strategy) orelse {
                return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "No backends available" });
            };

            return proxyWithFailover(ctx, backend_idx, state);
        }
    }.handle;
}

/// Proxy with automatic failover
fn proxyWithFailover(ctx: *const http.Context, primary_idx: usize, state: *WorkerState) !http.Respond {
    const backends = state.backends;

    if (streamingProxy(ctx, &backends.items[primary_idx], primary_idx, state)) |response| {
        state.recordSuccess(primary_idx);
        return response;
    } else |err| {
        state.recordFailure(primary_idx);
        log.warn("Backend {d} failed: {s}", .{ primary_idx + 1, @errorName(err) });

        if (state.findHealthyBackend(primary_idx)) |failover_idx| {
            log.debug("Failing over to backend {d}", .{failover_idx + 1});

            if (streamingProxy(ctx, &backends.items[failover_idx], failover_idx, state)) |response| {
                state.recordSuccess(failover_idx);
                return response;
            } else |failover_err| {
                state.recordFailure(failover_idx);
                log.warn("Failover to backend {d} failed: {s}", .{ failover_idx + 1, @errorName(failover_err) });
            }
        }

        return ctx.response.apply(.{ .status = .@"Service Unavailable", .mime = http.Mime.TEXT, .body = "All backends unavailable" });
    }
}

/// Streaming proxy implementation
fn streamingProxy(ctx: *const http.Context, backend: *const types.BackendServer, backend_idx: usize, state: *WorkerState) ProxyError!http.Respond {
    const start_time = std.time.milliTimestamp();
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var return_to_pool = true;

    // Get or create connection
    var sock = state.connection_pool.getConnection(backend_idx) orelse blk: {
        var ultra_sock = UltraSock.fromBackendServer(alloc, backend) catch return ProxyError.ConnectionFailed;
        ultra_sock.connect(ctx.runtime) catch {
            ultra_sock.close_blocking();
            return ProxyError.BackendUnavailable;
        };
        break :blk ultra_sock;
    };

    if (sock.socket == null or !sock.connected) {
        return_to_pool = false;
        sock = UltraSock.fromBackendServer(alloc, backend) catch return ProxyError.ConnectionFailed;
        sock.connect(ctx.runtime) catch {
            sock.close_blocking();
            return ProxyError.BackendUnavailable;
        };
        return_to_pool = true;
    }

    defer {
        if (return_to_pool) state.connection_pool.returnConnection(backend_idx, sock) else sock.close_blocking();
    }

    // Send request
    const request_data = std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: keep-alive\r\n\r\n{s}", .{
        @tagName(ctx.request.method orelse .GET),
        ctx.request.uri orelse "/",
        backend.getFullHost(),
        backend.port,
        ctx.request.body orelse "",
    }) catch return ProxyError.ConnectionFailed;

    _ = sock.send_all(ctx.runtime, request_data) catch {
        return_to_pool = false;
        return ProxyError.SendFailed;
    };

    // Read headers
    var header_buffer = std.ArrayList(u8).initCapacity(alloc, 4096) catch return ProxyError.ConnectionFailed;
    var recv_buffer: [32768]u8 = undefined;
    const start_recv = std.time.milliTimestamp();
    var header_end: usize = 0;

    while (header_end == 0) {
        if (std.time.milliTimestamp() - start_recv > 3000) {
            return_to_pool = false;
            return ProxyError.Timeout;
        }
        const n = sock.recv(ctx.runtime, &recv_buffer) catch {
            return_to_pool = false;
            return ProxyError.ReadFailed;
        };
        if (n == 0) {
            return_to_pool = false;
            return ProxyError.EmptyResponse;
        }
        header_buffer.appendSlice(alloc, recv_buffer[0..n]) catch return ProxyError.ConnectionFailed;
        if (simd_parse.findHeaderEnd(header_buffer.items)) |pos| header_end = pos + 4;
    }

    // Parse status
    const headers = header_buffer.items[0..header_end];
    const line_end = simd_parse.findLineEnd(headers) orelse return ProxyError.InvalidResponse;
    const space = std.mem.indexOf(u8, headers[0..line_end], " ") orelse return ProxyError.InvalidResponse;
    const status_code = std.fmt.parseInt(u16, headers[space + 1 ..][0..3], 10) catch 200;
    const msg_len = http_utils.determineMessageLength("GET", status_code, headers, false);

    // Check if headers allow connection reuse
    if (!connection_reuse.checkHeadersForReuse(headers).canReuse()) return_to_pool = false;

    // Build response
    var resp = std.ArrayList(u8).initCapacity(alloc, 512) catch return ProxyError.ConnectionFailed;
    var w = resp.writer(alloc);
    const status: http.Status = @enumFromInt(status_code);
    w.print("HTTP/1.1 {d} {s}\r\nServer: zzz-lb-mp\r\nConnection: keep-alive\r\n", .{ status_code, @tagName(status) }) catch return ProxyError.ConnectionFailed;

    // Forward headers (skip hop-by-hop)
    const skip = std.StaticStringMap(void).initComptime(.{
        .{ "connection", {} },
        .{ "keep-alive", {} },
        .{ "transfer-encoding", {} },
        .{ "server", {} },
    });

    var pos: usize = line_end + 2;
    while (pos < header_end - 2) {
        const end = std.mem.indexOfPos(u8, headers, pos, "\r\n") orelse break;
        const line = headers[pos..end];
        if (std.mem.indexOf(u8, line, ":")) |c| {
            var lb: [64]u8 = undefined;
            const len = @min(line[0..c].len, 64);
            for (line[0..len], 0..) |ch, i| lb[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
            if (skip.get(lb[0..len]) == null) w.print("{s}\r\n", .{line}) catch {};
        }
        pos = end + 2;
    }

    if (msg_len.type == .content_length) w.print("Content-Length: {d}\r\n", .{msg_len.length}) catch {};
    w.writeAll("\r\n") catch {};
    if (header_buffer.items.len > header_end) resp.appendSlice(alloc, header_buffer.items[header_end..]) catch {};

    _ = ctx.socket.send_all(ctx.runtime, resp.items) catch return ProxyError.SendFailed;
    var bytes_received = header_buffer.items.len - header_end;
    var body_had_error = false;
    var chunked_complete = false;

    // Stream body
    if (msg_len.type == .content_length) {
        while (bytes_received < msg_len.length) {
            const n = sock.recv(ctx.runtime, &recv_buffer) catch {
                body_had_error = true;
                break;
            };
            if (n == 0) {
                body_had_error = true;
                break;
            }
            _ = ctx.socket.send(ctx.runtime, recv_buffer[0..n]) catch break;
            bytes_received += n;
        }
    } else if (msg_len.type == .chunked or msg_len.type == .close_delimited) {
        while (true) {
            const n = sock.recv(ctx.runtime, &recv_buffer) catch {
                body_had_error = true;
                break;
            };
            if (n == 0) {
                body_had_error = true;
                break;
            }
            _ = ctx.socket.send(ctx.runtime, recv_buffer[0..n]) catch break;
            bytes_received += n;
            if (msg_len.type == .chunked and simd_parse.findChunkEnd(recv_buffer[0..n]) != null) {
                chunked_complete = true;
                break;
            }
        }
    }

    // Check if body transfer allows connection reuse
    const body_error = body_had_error or (msg_len.type == .chunked and !chunked_complete);
    if (return_to_pool and !connection_reuse.checkBodyForReuse(msg_len.type, msg_len.length, bytes_received, body_error).canReuse()) {
        return_to_pool = false;
    }

    metrics.global_metrics.recordRequest(std.time.milliTimestamp() - start_time, status_code);
    return .responded;
}
