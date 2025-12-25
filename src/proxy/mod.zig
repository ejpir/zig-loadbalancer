/// Proxy Module - HTTP Request Proxying
///
/// This module handles proxying HTTP requests from clients to backend servers.
/// Components:
/// - handler: Main proxy request handler
/// - connection: Backend connection management (HTTP/1.1)
/// - connection_reuse: HTTP/1.1 connection reuse logic
/// - request: Request parsing and forwarding
/// - io: Low-level I/O operations
///
/// The proxy integrates with health checking and load balancing to route
/// requests to healthy backends with automatic failover.

pub const handler = @import("handler.zig");
pub const generateHandler = handler.generateHandler;
pub const ProxyError = handler.ProxyError;

pub const connection = @import("connection.zig");
pub const ProxyConnection = connection.ProxyConnection;

pub const connection_reuse = @import("connection_reuse.zig");

pub const request = @import("request.zig");
pub const ProxyRequest = request.ProxyRequest;

pub const io = @import("io.zig");
