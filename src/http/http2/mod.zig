//! HTTP/2 Protocol Implementation for Load Balancer
//!
//! Provides HTTP/2 client functionality for connecting to backend servers.
//! Integrates with UltraSock for transport.
//!
//! RFC 7540 compliant framing and HPACK header compression.

const std = @import("std");

pub const frame = @import("frame.zig");
pub const hpack = @import("hpack.zig");
pub const client = @import("client.zig");
pub const connection = @import("connection.zig");
pub const pool = @import("pool.zig");

// Re-export commonly used types
pub const FrameType = frame.FrameType;
pub const FrameHeader = frame.FrameHeader;
pub const Frame = frame.Frame;
pub const Hpack = hpack.Hpack;
pub const Client = client.Http2Client;
pub const H2Connection = connection.H2Connection;
pub const H2ConnectionPool = pool.H2ConnectionPool;

/// Binary connection state: either ready or dead. No middle ground.
/// TigerBeetle style: explicit state machine with only valid transitions.
pub const ConnectionState = enum {
    ready,
    dead,
};

// Protocol constants (RFC 7540)
pub const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const FRAME_HEADER_SIZE: usize = 9;
pub const MAX_FRAME_SIZE_DEFAULT: u32 = 16384;
pub const MAX_FRAME_SIZE_MAX: u32 = 16777215;
pub const INITIAL_WINDOW_SIZE: u32 = 65535;
pub const MAX_WINDOW_SIZE: u32 = 2147483647;

// TLS buffer sizes - MUST match vendor/tls library exactly
// These values are dictated by the TLS implementation and must not be changed
// without coordinating with the underlying TLS vendor library.
pub const TLS_INPUT_BUFFER_LEN: usize = 16645;
pub const TLS_OUTPUT_BUFFER_LEN: usize = 16469;

// Settings identifiers (RFC 7540 Section 6.5.2)
pub const Settings = struct {
    pub const HEADER_TABLE_SIZE: u16 = 0x1;
    pub const ENABLE_PUSH: u16 = 0x2;
    pub const MAX_CONCURRENT_STREAMS: u16 = 0x3;
    pub const INITIAL_WINDOW_SIZE: u16 = 0x4;
    pub const MAX_FRAME_SIZE: u16 = 0x5;
    pub const MAX_HEADER_LIST_SIZE: u16 = 0x6;
};

test {
    std.testing.refAllDecls(@This());
}
