# BearSSL Implementation Guide for Zig

This guide covers the implementation details, challenges, and solutions for using BearSSL in Zig applications. It is based on practical experience and addresses specific issues that are likely to be encountered.

## Table of Contents

1. [Memory Alignment Requirements](#memory-alignment-requirements)
2. [Certificate Validation](#certificate-validation)
3. [TLS Handshake Process](#tls-handshake-process)
4. [Debug and Trace Functionality](#debug-and-trace-functionality)
5. [Error Handling](#error-handling)
6. [Connection Lifecycle Management](#connection-lifecycle-management)
7. [Common Pitfalls](#common-pitfalls)
8. [Best Practices](#best-practices)

## Memory Alignment Requirements

BearSSL is highly sensitive to memory alignment. Inappropriate alignment causes segmentation faults (SIGSEGV) or undefined behavior.

### Critical Alignment Issues:

1. **BearSSL Structures**
   ```zig
   // INCORRECT - will likely crash
   var client_ctx: c.br_ssl_client_context = undefined;
   
   // CORRECT - properly aligned
   var client_ctx: c.br_ssl_client_context align(8) = undefined;
   ```

2. **All Key Structures Must Be Aligned**
   ```zig
   // Always align these structures
   var client_ctx: c.br_ssl_client_context align(8) = undefined;
   var x509_ctx: c.br_x509_minimal_context align(8) = undefined;
   var iobuf: [c.BR_SSL_BUFSIZE_BIDI]u8 align(8) = undefined;
   var ioc: c.br_sslio_context align(8) = undefined;
   ```

3. **IO Buffer Allocation**
   ```zig
   // INCORRECT - standard allocation
   const io_buf = try allocator.alloc(u8, c.BR_SSL_BUFSIZE_BIDI);
   
   // CORRECT - page-aligned allocation
   const io_buf = try std.heap.page_allocator.alignedAlloc(u8, 8, c.BR_SSL_BUFSIZE_BIDI);
   ```

4. **Structure Definition in VTable Context**
   ```zig
   // Define context with proper alignment
   const VtableContext = struct {
       allocator: std.mem.Allocator,
       io_buf: []align(8) u8,
       client_ctx: c.br_ssl_client_context align(8),
       x509_ctx: c.br_x509_minimal_context align(8),
       sslio_ctx: c.br_sslio_context align(8),
       // Other fields...
   };
   ```

### Alignment Testing:

If you encounter crashes, verify alignment with:
```zig
log.debug("client_ctx alignment: {d}", .{@alignOf(@TypeOf(client_ctx))});
log.debug("client_ctx address: {*}", .{&client_ctx});
```

## Certificate Validation

BearSSL requires proper certificate validation setup to establish secure connections.

### Trust Anchor Implementation

1. **Hardcoded Trust Anchor (Recommended)**
   ```zig
   // Define trust anchor data
   const TA0_DN = [_]u8{
       // Distinguished Name bytes
   };

   const TA0_RSA_N = [_]u8{
       // RSA modulus bytes
   };

   const TA0_RSA_E = [_]u8{
       // RSA exponent bytes (usually 0x01, 0x00, 0x01)
   };

   // Create trust anchor structure
   const HARDCODED_TAs = [_]c.br_x509_trust_anchor{
       c.br_x509_trust_anchor{
           .dn = .{
               .data = @constCast(&TA0_DN),
               .len = TA0_DN.len,
           },
           .flags = 0,
           .pkey = .{
               .key_type = c.BR_KEYTYPE_RSA,
               .key = .{
                   .rsa = .{
                       .n = @constCast(&TA0_RSA_N),
                       .nlen = TA0_RSA_N.len,
                       .e = @constCast(&TA0_RSA_E),
                       .elen = TA0_RSA_E.len,
                   },
               },
           },
       },
   };
   ```

2. **X.509 Context Initialization**
   ```zig
   // Initialize X.509 context with trust anchors
   c.br_x509_minimal_init(&x509_ctx, &c.br_sha256_vtable, &HARDCODED_TAs, HARDCODED_TAs.len);
   
   // Set up verification algorithms
   c.br_x509_minimal_set_rsa(&x509_ctx, c.br_ssl_engine_get_rsavrfy(&client_ctx.eng));
   c.br_x509_minimal_set_ecdsa(&x509_ctx, 
                             c.br_ssl_engine_get_ec(&client_ctx.eng), 
                             c.br_ssl_engine_get_ecdsa(&client_ctx.eng));
   
   // Set up hash implementations
   c.br_x509_minimal_set_hash(&x509_ctx, c.br_md5_ID, &c.br_md5_vtable);
   c.br_x509_minimal_set_hash(&x509_ctx, c.br_sha1_ID, &c.br_sha1_vtable);
   c.br_x509_minimal_set_hash(&x509_ctx, c.br_sha256_ID, &c.br_sha256_vtable);
   ```

3. **SSL Client Initialization**
   ```zig
   // Initialize client with X.509 context and trust anchors
   c.br_ssl_client_init_full(&client_ctx, &x509_ctx, &HARDCODED_TAs, HARDCODED_TAs.len);
   ```

### Avoiding Runtime Certificate Loading

Runtime certificate loading can be error-prone. Instead, extract trust anchor data from certificates during development:

1. Extract from a PEM file
2. Convert to hardcoded byte arrays
3. Embed directly in your code

This approach is more reliable and efficient.

## TLS Handshake Process

Proper initialization sequence is crucial for successful TLS handshakes.

### Recommended Sequence:

1. **Create and Initialize Structures**
   ```zig
   var client_ctx: c.br_ssl_client_context align(8) = undefined;
   var x509_ctx: c.br_x509_minimal_context align(8) = undefined;
   var iobuf: [c.BR_SSL_BUFSIZE_BIDI]u8 align(8) = undefined;
   var ioc: c.br_sslio_context align(8) = undefined;
   ```

2. **Setup Trust Anchor**
   ```zig
   c.br_x509_minimal_init(&x509_ctx, &c.br_sha256_vtable, &HARDCODED_TAs, HARDCODED_TAs.len);
   ```

3. **Initialize Client Context**
   ```zig
   c.br_ssl_client_init_full(&client_ctx, &x509_ctx, &HARDCODED_TAs, HARDCODED_TAs.len);
   ```

4. **Set Crypto Algorithms AFTER Context Initialization**
   ```zig
   // Set crypto algorithms
   c.br_ssl_engine_set_default_rsavrfy(&client_ctx.eng);
   c.br_ssl_engine_set_default_ecdsa(&client_ctx.eng);
   c.br_ssl_engine_set_default_ec(&client_ctx.eng);
   c.br_ssl_client_set_default_rsapub(&client_ctx);
   
   // Update X.509 validation with engine-specific functions
   c.br_x509_minimal_set_rsa(&x509_ctx, c.br_ssl_engine_get_rsavrfy(&client_ctx.eng));
   c.br_x509_minimal_set_ecdsa(&x509_ctx, 
                               c.br_ssl_engine_get_ec(&client_ctx.eng), 
                               c.br_ssl_engine_get_ecdsa(&client_ctx.eng));
   ```

5. **Setup Cipher Suites**
   ```zig
   c.br_ssl_engine_set_default_aes_cbc(&client_ctx.eng);
   c.br_ssl_engine_set_default_aes_gcm(&client_ctx.eng);
   c.br_ssl_engine_set_default_chapol(&client_ctx.eng);
   c.br_ssl_engine_set_default_des_cbc(&client_ctx.eng);
   ```

6. **Set Buffer and Reset Context**
   ```zig
   c.br_ssl_engine_set_buffer(&client_ctx.eng, &iobuf, iobuf.len, 1);
   const sni_result = c.br_ssl_client_reset(&client_ctx, "localhost", 0);
   if (sni_result == 0) {
       return error.ClientResetFailed;
   }
   ```

7. **Initialize I/O Context After Socket Connection**
   ```zig
   // After socket connection is established:
   c.br_sslio_init(&ioc, &client_ctx.eng, recv_callback, ctx, send_callback, ctx);
   ```

8. **Perform Handshake**
   ```zig
   // Start TLS handshake by writing zero bytes
   const write_result = c.br_sslio_write(&ioc, "", 0);
   if (write_result < 0) {
       // Handle error
   }
   
   // Flush to complete handshake
   const flush_result = c.br_sslio_flush(&ioc);
   if (flush_result < 0) {
       // Handle error
   }
   ```

## Debug and Trace Functionality

BearSSL provides limited debugging facilities in its C API. To get detailed visibility into TLS handshake messages and data flow, you can implement custom tracing in your Zig code.

### Implementing Custom Tracing

1. **Create a Trace-Enabled Callback Context**
   ```zig
   const CallbackContext = struct {
       socket: Socket,
       runtime: ?*Runtime,
       trace_enabled: bool = false,
       
       // Helper function to dump bytes for debugging
       fn dump_blob(ctx: *const @This(), direction: []const u8, data: []const u8) void {
           if (!ctx.trace_enabled) return;
           
           log.debug("BearSSL {s} ({d} bytes):", .{direction, data.len});
           
           var i: usize = 0;
           while (i < data.len) {
               // Print offset at the beginning of each line
               var line_buf: [128]u8 = undefined;
               var line_fbs = std.io.fixedBufferStream(&line_buf);
               var line_writer = line_fbs.writer();
               
               // Print offset
               line_writer.print("{X:0>8}  ", .{i}) catch {};
               
               // Print hex bytes (up to 16 per line)
               var j: usize = 0;
               while (j < 16 and i + j < data.len) : (j += 1) {
                   // Add extra space in the middle for readability
                   if (j == 8) line_writer.writeByte(' ') catch {};
                   line_writer.print(" {X:0>2}", .{data[i + j]}) catch {};
               }
               
               // Print ASCII representation
               // Pad with spaces if we didn't have 16 bytes
               var pad = 16 - j;
               while (pad > 0) : (pad -= 1) {
                   line_writer.writeAll("   ") catch {};
               }
               line_writer.writeAll("  |") catch {};
               
               j = 0;
               while (j < 16 and i + j < data.len) : (j += 1) {
                   const byte_val = data[i + j];
                   // Print ASCII if printable, dot otherwise
                   if (byte_val >= 32 and byte_val < 127) {
                       line_writer.writeByte(byte_val) catch {};
                   } else {
                       line_writer.writeByte('.') catch {};
                   }
               }
               line_writer.writeAll("|") catch {};
               
               // Log the line
               log.debug("{s}", .{line_fbs.getWritten()});
               
               i += j;
           }
       }
   };
   ```

2. **Enable Tracing in Your Context**
   ```zig
   // During context initialization
   cb_ctx.trace_enabled = true;
   ```

3. **Hook Tracing Into I/O Callbacks**
   ```zig
   c.br_sslio_init(&ctx.sslio_ctx, &ctx.client_ctx.eng, struct {
       fn recv_cb(i_ctx: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) c_int {
           const cb_context: *CallbackContext = @ptrCast(@alignCast(i_ctx.?));
           const received = cb_context.socket.recv(cb_context.runtime.?, buf[0..len]) catch |e| {
               log.err("Socket read failed: {s}", .{@errorName(e)});
               return -1;
           };
           
           // Trace the received bytes for debugging
           if (cb_context.trace_enabled and received > 0) {
               cb_context.dump_blob("RECEIVED", buf[0..@intCast(received)]);
           }
           
           return @intCast(received);
       }
   }.recv_cb, ctx.cb_ctx, struct {
       fn send_cb(i_ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
           const cb_context: *CallbackContext = @ptrCast(@alignCast(i_ctx.?));
           
           // Trace the bytes to be sent for debugging
           if (cb_context.trace_enabled) {
               cb_context.dump_blob("SENDING", buf[0..len]);
           }
           
           const sent = cb_context.socket.send(cb_context.runtime.?, buf[0..len]) catch |e| {
               log.err("Socket write failed: {s}", .{@errorName(e)});
               return -1;
           };
           return @intCast(sent);
       }
   }.send_cb, ctx.cb_ctx);
   ```

### Benefits of Custom Tracing

1. **TLS Record Visibility**: See all TLS records sent and received, with full binary data
2. **Protocol Analysis**: Inspect handshake messages, alerts, and application data
3. **Debugging**: Identify protocol mismatches, certificate issues, and handshake failures
4. **SSL/TLS Learning**: Understand the TLS protocol by seeing it in action

### Additional Debugging Features

You can also implement custom debug functions for showing the state of the BearSSL context:

```zig
// Example of a debug function for X.509 context
fn dumpX509Context(x509: *const c.br_x509_minimal_context) void {
    log.debug("  - error: {d}", .{x509.err});
    // Trust anchors info
    if (x509.trust_anchors != null) {
        log.debug("  - trust_anchors: {*}", .{x509.trust_anchors});
        log.debug("  - trust_anchors_num: {d}", .{x509.trust_anchors_num});
    } else {
        log.debug("  - trust_anchors: null", .{});
    }
    
    // Certificate validation constraints
    log.debug("  - days: {d}", .{x509.days});
    log.debug("  - seconds: {d}", .{x509.seconds});
    
    // Certificate processing state
    log.debug("  - cert_length: {d}", .{x509.cert_length});
    log.debug("  - num_certs: {d}", .{x509.num_certs});
    
    // Certificate public key info
    const pkey = &x509.pkey;
    log.debug("  - pkey.key_type: {d}", .{pkey.key_type});
    
    // Certificate signer key type
    log.debug("  - cert_signer_key_type: {d}", .{x509.cert_signer_key_type});
}
```

## Error Handling

Proper error handling is essential for diagnosing and recovering from TLS issues.

### Common BearSSL Error Codes:

- **62** (`BR_ERR_X509_NOT_TRUSTED`): Certificate validation failed
- **25** (`BR_ERR_BAD_MAC`): Handshake integrity check failed
- **47** (`BR_ERR_UNEXPECTED_MESSAGE`): Protocol state machine error
- **90** (`BR_ERR_BAD_SIGNATURE`): Signature verification failed

### Recommended Error Handling Pattern:

```zig
if (flush_result < 0) {
    const error_code = c.br_ssl_engine_last_error(&client_ctx.eng);
    log.err("Handshake flush failed with error code: {d}", .{error_code});

    // Enhanced error reporting for common TLS errors
    switch (error_code) {
        62 => { // BR_ERR_X509_NOT_TRUSTED
            log.err("Certificate validation failed - certificate not trusted", .{});
            log.err("This usually means the server's certificate wasn't in our trust store", .{});

            const server_name = c.br_ssl_engine_get_server_name(&client_ctx.eng);
            if (server_name != null) {
                log.info("Server name from SNI: {s}", .{std.mem.span(server_name)});
            }

            log.info("Trust anchors available: {d} (hardcoded)", .{HARDCODED_TAs.len});
        },
        25 => log.err("Bad MAC - handshake integrity check failed", .{}),
        47 => log.err("Unexpected message - protocol state machine error", .{}),
        90 => log.err("Bad signature - server's signature verification failed", .{}),
        else => log.err("Unknown error code: {d}", .{error_code}),
    }

    return error.TlsHandshakeFailed;
}
```

### Gracefully Handling Connection Closure:

```zig
// In read function
if (result < 0) {
    const error_code = c.br_ssl_engine_last_error(&client_ctx.eng);
    
    // If error code is 0 after EOF, it's a graceful close
    if (error_code == 0) {
        log.info("Server closed connection gracefully", .{});
        return 0; // Return 0 bytes to indicate EOF
    }
    
    // Handle other errors
}

// In write/flush function
if (flush_result < 0) {
    const error_code = c.br_ssl_engine_last_error(&client_ctx.eng);
    
    // If error code is 0, it's a graceful close
    if (error_code == 0) {
        log.info("Server closed connection during flush", .{});
        return @as(usize, @intCast(@max(0, write_result))); 
    }
    
    // Handle other errors
}
```

## Connection Lifecycle Management

Proper connection lifecycle management prevents resource leaks and crashes.

### Socket Handling:

1. **Avoid Double-Closing Sockets**
   ```zig
   // INCORRECT - multiple places closing the same socket
   const socket = try Socket.init(...);
   defer socket.close_blocking(); // First close point
   
   // ...
   
   socket.close_blocking(); // Second close point - will crash if server already closed
   
   // CORRECT - single responsibility for closing
   const socket = try Socket.init(...);
   // No defer here
   
   const secure = try bearssl.to_secure_socket(socket, .client);
   defer secure.deinit(); // Let this handle socket cleanup
   ```

2. **Checking State Before Operations**
   ```zig
   // Check state before initializing I/O context
   const state = c.br_ssl_engine_current_state(&client_ctx.eng);
   if (state == c.BR_SSL_CLOSED) {
       log.warn("SSL engine already closed", .{});
       return error.SslEngineClosed;
   }
   ```

3. **Proper Resource Cleanup**
   ```zig
   // Free resources in correct order
   allocator.destroy(cb_ctx);
   std.heap.page_allocator.free(io_buf);
   allocator.destroy(context);
   ```

## Common Pitfalls

### 1. Memory Alignment Issues
- **Symptom**: SIGSEGV, address boundary errors
- **Solution**: Ensure all BearSSL structures use `align(8)` and IO buffers are properly aligned

### 2. Missing Crypto Algorithm Setup
- **Symptom**: Handshake failures, "bad signature" or "bad MAC" errors
- **Solution**: Ensure all crypto algorithms are properly set up after engine initialization

### 3. Double Socket Closure
- **Symptom**: "unreachable code" panic when closing socket
- **Solution**: Implement single responsibility for socket closure, handle graceful closures

### 4. Race Conditions with Socket States
- **Symptom**: Unexpected errors during handshakes or data transfer
- **Solution**: Implement proper state checks before operations

### 5. Incorrect Trust Anchor Setup
- **Symptom**: Certificate validation failures (error code 62)
- **Solution**: Use hardcoded trust anchors with correct data extracted from certificates

### 6. Initialization Order Issues
- **Symptom**: Handshake failures, protocol errors
- **Solution**: Follow the exact initialization sequence outlined in this guide

## Best Practices

1. **Use Hardcoded Trust Anchors**
   - Extract certificate data during development
   - Hardcode the trust anchor bytes in your application
   - Avoid runtime PEM parsing for improved reliability

2. **Implement Proper Memory Alignment**
   - Use `align(8)` for all BearSSL structures
   - Use aligned memory allocation for buffers
   - Check alignment for debugging purposes

3. **Follow Precise Initialization Order**
   - Initialize X.509 context before client context
   - Set crypto algorithms after context initialization
   - Set up cipher suites after crypto algorithms

4. **Implement Comprehensive Error Handling**
   - Handle all BearSSL error codes
   - Implement graceful connection closure handling
   - Provide detailed error messages for debugging

5. **Manage Socket Lifecycle Carefully**
   - Avoid double-closing sockets
   - Check socket state before operations
   - Implement proper resource cleanup

6. **Enable Detailed Tracing for Debugging**
   - Implement custom tracing in I/O callbacks
   - Capture and log all TLS records
   - Dump connection state at critical points 

7. **Thorough Testing**
   - Test with various certificate types (RSA, ECDSA)
   - Test connection closure scenarios
   - Test against servers with different TLS configurations

By following these guidelines, you can successfully implement BearSSL in Zig applications while avoiding common pitfalls and ensuring robust TLS connectivity.