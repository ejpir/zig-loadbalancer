/// TLS Implementation Tests
///
/// Unit tests run with: zig test src/http/tls_test.zig
/// Integration test requires running the load balancer with an HTTPS backend.
const std = @import("std");
const ultra_sock = @import("ultra_sock.zig");
const UltraSock = ultra_sock.UltraSock;
const TlsOptions = ultra_sock.TlsOptions;
const Protocol = ultra_sock.Protocol;

// ============================================================================
// Unit Tests (run without network)
// ============================================================================

test "TlsOptions.production returns system CA with host verification" {
    const opts = TlsOptions.production();
    try std.testing.expect(opts.ca == .system);
    try std.testing.expect(opts.host == .from_connection);
    try std.testing.expect(!opts.isInsecure());
}

test "TlsOptions.insecure skips all verification" {
    const opts = TlsOptions.insecure();
    try std.testing.expect(opts.ca == .none);
    try std.testing.expect(opts.host == .none);
    try std.testing.expect(opts.isInsecure());
}

test "UltraSock.init defaults to production TLS" {
    var sock = try UltraSock.init(std.testing.allocator, .https, "example.com", 443);
    defer sock.deinit();

    try std.testing.expect(sock.protocol == .https);
    try std.testing.expectEqualStrings("example.com", sock.host);
    try std.testing.expect(sock.port == 443);
    try std.testing.expect(sock.tls_options.ca == .system);
    try std.testing.expect(sock.tls_options.host == .from_connection);
}

test "UltraSock.initWithTls accepts custom options" {
    var sock = try UltraSock.initWithTls(
        std.testing.allocator,
        .https,
        "localhost",
        8443,
        TlsOptions.insecure(),
    );
    defer sock.deinit();

    try std.testing.expect(sock.protocol == .https);
    try std.testing.expect(sock.tls_options.ca == .none);
    try std.testing.expect(sock.tls_options.host == .none);
}

test "UltraSock HTTP mode has no TLS client" {
    var sock = try UltraSock.init(std.testing.allocator, .http, "example.com", 80);
    defer sock.deinit();

    try std.testing.expect(sock.protocol == .http);
    try std.testing.expect(sock.tls_client == null);
    try std.testing.expect(!sock.isTls());
}

test "UltraSock.isTls returns false before connect" {
    var sock = try UltraSock.init(std.testing.allocator, .https, "example.com", 443);
    defer sock.deinit();

    // Before connect, tls_client is null even for HTTPS
    try std.testing.expect(!sock.isTls());
    try std.testing.expect(sock.tls_client == null);
}

test "TlsOptions explicit host verification" {
    const opts = TlsOptions{
        .ca = .system,
        .host = .{ .explicit = "api.example.com" },
    };

    try std.testing.expect(!opts.isInsecure());
    try std.testing.expectEqualStrings("api.example.com", opts.host.explicit);
}

test "UltraSock deinit cleans up without connect" {
    var sock = try UltraSock.init(std.testing.allocator, .https, "example.com", 443);
    // Should not leak or crash
    sock.deinit();
}

test "UltraSock fromBackendConfig detects HTTPS by port 443" {
    const Backend = struct {
        host: []const u8,
        port: u16,
    };

    const backend = Backend{ .host = "api.example.com", .port = 443 };
    var sock = try UltraSock.fromBackendConfig(std.testing.allocator, backend);
    defer sock.deinit();

    try std.testing.expect(sock.protocol == .https);
}

test "UltraSock fromBackendConfig detects HTTPS by URL prefix" {
    const Backend = struct {
        host: []const u8,
        port: u16,
    };

    const backend = Backend{ .host = "https://api.example.com", .port = 8080 };
    var sock = try UltraSock.fromBackendConfig(std.testing.allocator, backend);
    defer sock.deinit();

    try std.testing.expect(sock.protocol == .https);
    try std.testing.expectEqualStrings("api.example.com", sock.host);
}
