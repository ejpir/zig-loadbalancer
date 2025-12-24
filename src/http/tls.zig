//! TLS Configuration and Utilities
//!
//! Provides TLS configuration options, CA bundle management, and handshake helpers.
//! Extracted from ultra_sock.zig for modularity.
//!
//! TigerBeetle style:
//! - Explicit configuration via TlsOptions presets
//! - Global CA bundle loaded once (no per-connection allocation)
//! - Threadlocal buffers for handshake (no allocation)

const std = @import("std");
const log = std.log.scoped(.tls);

const Io = std.Io;
pub const tls_lib = @import("tls");

const config_mod = @import("../core/config.zig");

// ============================================================================
// TLS Buffer Management
// ============================================================================

/// Threadlocal TLS buffers - avoid allocation during handshake
/// Each thread gets its own buffers for non-concurrent use.
/// For concurrent connections (HTTP/2 multiplexing), use per-connection buffers.
pub threadlocal var input_buffer: [tls_lib.input_buffer_len]u8 = undefined;
pub threadlocal var output_buffer: [tls_lib.output_buffer_len]u8 = undefined;

/// Buffer sizes for per-connection allocation (HTTP/2 multiplexing)
pub const INPUT_BUFFER_LEN: usize = tls_lib.input_buffer_len;
pub const OUTPUT_BUFFER_LEN: usize = tls_lib.output_buffer_len;

// ============================================================================
// Global CA Bundle
// ============================================================================

/// Global CA bundle (loaded once at startup)
var global_ca_bundle: ?tls_lib.config.cert.Bundle = null;
var ca_bundle_loaded: bool = false;

/// Ensure CA bundle is loaded (only once per process)
pub fn ensureCaBundleLoaded(io: Io, ca_mode: TlsOptions.CaVerification) !void {
    if (ca_mode == .system and !ca_bundle_loaded) {
        global_ca_bundle =
            tls_lib.config.cert.fromSystem(std.heap.page_allocator, io) catch |err| {
            log.err("Failed to load system CA bundle: {}", .{err});
            return error.CaBundleLoadFailed;
        };
        ca_bundle_loaded = true;
        const cert_count = global_ca_bundle.?.map.count();
        log.info("Loaded {} certificates from system trust store", .{cert_count});
    }
}

/// Get the global CA bundle (must be loaded first)
pub fn getGlobalCaBundle() ?tls_lib.config.cert.Bundle {
    return global_ca_bundle;
}

// ============================================================================
// TLS Options
// ============================================================================

/// TLS configuration options
pub const TlsOptions = struct {
    /// Certificate authority verification mode
    pub const CaVerification = union(enum) {
        /// No CA verification - INSECURE, for local dev only
        none,
        /// Use system trust store (default when DEFAULT_TLS_VERIFY_CA = true)
        system,
        /// Use custom certificate bundle
        custom: tls_lib.config.cert.Bundle,
    };

    /// Host verification mode
    pub const HostVerification = union(enum) {
        /// No hostname verification - INSECURE
        none,
        /// Verify against connection host (default when DEFAULT_TLS_VERIFY_HOST = true)
        from_connection,
        /// Verify against explicit hostname
        explicit: []const u8,
    };

    ca: CaVerification = .system,
    host: HostVerification = .from_connection,
    /// ALPN protocols to negotiate (e.g., "h2", "http/1.1")
    /// First protocol in list is preferred.
    alpn_protocols: []const []const u8 = &.{},

    /// Create TlsOptions from config.zig defaults
    /// Uses DEFAULT_TLS_VERIFY_CA and DEFAULT_TLS_VERIFY_HOST
    pub fn fromDefaults() TlsOptions {
        return .{
            .ca = if (config_mod.DEFAULT_TLS_VERIFY_CA) .system else .none,
            .host = if (config_mod.DEFAULT_TLS_VERIFY_HOST) .from_connection else .none,
        };
    }

    /// Get TLS options based on runtime config
    /// Returns insecure() if --insecure flag was used, otherwise production()
    pub fn fromRuntime() TlsOptions {
        return if (config_mod.isInsecureTls()) insecure() else production();
    }

    /// Production preset: full verification with system trust store
    pub fn production() TlsOptions {
        return .{
            .ca = .system,
            .host = .from_connection,
        };
    }

    /// Insecure preset: skip all verification (local dev only)
    /// Still sends SNI (required for virtual hosts/CDNs), just doesn't verify certificate hostname
    pub fn insecure() TlsOptions {
        return .{
            .ca = .none,
            .host = .from_connection, // Send SNI for routing, skip verification via ca = .none
        };
    }

    /// Check if this config skips verification (inlined - called during connection setup)
    pub inline fn isInsecure(self: TlsOptions) bool {
        return self.ca == .none;
    }

    /// Production preset with HTTP/2 ALPN negotiation
    pub fn productionWithHttp2() TlsOptions {
        return .{
            .ca = .system,
            .host = .from_connection,
            .alpn_protocols = &.{ "h2", "http/1.1" },
        };
    }

    /// Insecure preset with HTTP/2 ALPN (local dev only)
    /// Still sends SNI (required for virtual hosts/CDNs), just doesn't verify certificate hostname
    pub fn insecureWithHttp2() TlsOptions {
        return .{
            .ca = .none,
            .host = .from_connection, // Send SNI for routing, skip verification via ca = .none
            .alpn_protocols = &.{ "h2", "http/1.1" },
        };
    }

    /// Get TLS options with HTTP/2 based on runtime config
    pub fn fromRuntimeWithHttp2() TlsOptions {
        return if (config_mod.isInsecureTls()) insecureWithHttp2() else productionWithHttp2();
    }
};

// ============================================================================
// TLS Client Configuration Builder
// ============================================================================

/// Build TLS client options from verification settings
pub fn buildClientOptions(
    tls_options: TlsOptions,
    host: []const u8,
    now: Io.Timestamp,
    diagnostic: ?*tls_lib.config.Client.Diagnostic,
) !tls_lib.config.Client {
    return tls_lib.config.Client{
        .host = switch (tls_options.host) {
            .none => "",
            .from_connection => host,
            .explicit => |h| h,
        },
        .root_ca = switch (tls_options.ca) {
            .none => .{},
            .system => global_ca_bundle.?,
            .custom => |bundle| bundle,
        },
        .insecure_skip_verify = tls_options.ca == .none,
        .now = now,
        .alpn_protocols = tls_options.alpn_protocols,
        .diagnostic = diagnostic,
    };
}

// ============================================================================
// Re-exports for convenience
// ============================================================================

/// TLS Connection type
pub const Connection = tls_lib.Connection;

/// TLS client constructor
pub const client = tls_lib.client;
