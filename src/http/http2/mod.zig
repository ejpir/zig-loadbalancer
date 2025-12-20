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

// Re-export commonly used types
pub const FrameType = frame.FrameType;
pub const FrameHeader = frame.FrameHeader;
pub const Frame = frame.Frame;
pub const Hpack = hpack.Hpack;
pub const Client = client.Http2Client;

// Protocol constants (RFC 7540)
pub const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const FRAME_HEADER_SIZE: usize = 9;
pub const MAX_FRAME_SIZE_DEFAULT: u32 = 16384;
pub const MAX_FRAME_SIZE_MAX: u32 = 16777215;
pub const INITIAL_WINDOW_SIZE: u32 = 65535;
pub const MAX_WINDOW_SIZE: u32 = 2147483647;

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
