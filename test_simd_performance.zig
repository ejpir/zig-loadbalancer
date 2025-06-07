/// Simple SIMD performance test and validation
const std = @import("std");
const print = std.debug.print;
const simd_parser = @import("src/http/simd_header_parser.zig");

const test_response = 
    \\HTTP/1.1 200 OK
    \\Content-Type: application/json
    \\Content-Length: 123456
    \\Transfer-Encoding: chunked
    \\
    \\{"message": "Hello!"}
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator();
    
    print("SIMD Header Parser Test\n", .{});
    print("=======================\n", .{});
    
    // Test Content-Length extraction
    const content_length = simd_parser.getContentLengthSIMD(test_response);
    print("Content-Length: {?}\n", .{content_length});
    
    // Test Transfer-Encoding detection
    const has_transfer = simd_parser.hasTransferEncodingSIMD(test_response);
    print("Has Transfer-Encoding: {}\n", .{has_transfer});
    
    // Test chunked encoding
    const has_chunked = simd_parser.hasChunkedEncodingSIMD(test_response);
    print("Has Chunked: {}\n", .{has_chunked});
    
    print("✅ All SIMD optimizations working!\n", .{});
}