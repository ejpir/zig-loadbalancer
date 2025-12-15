# secsock 

This is an implementation of `SecureSocket`, a wrapper for the Tardy `Socket` type that provides TLS functionality.

## Supported TLS Backends
- [BearSSL](https://bearssl.org/gitweb/?p=BearSSL;a=summary): An implementation of the SSL/TLS protocol (RFC 5346) written in C.
- [s2n-tls](https://github.com/aws/s2n-tls): An implementation of SSL/TLS protocols by AWS. (Experimental)

## Architecture

### Virtual Tables (vtables)

SecureSocket uses a vtable pattern to implement polymorphic behavior, allowing different TLS backends to share a common interface. This architecture enables seamless switching between different TLS implementations like BearSSL and s2n-tls.

#### How Vtables Work in SecureSocket

1. **Common Interface Definition**: The `SecureSocket` type defines a standard interface with operations like `connect`, `recv`, `send`, and `deinit`.

2. **Implementation-Specific Context**: Each backend defines its own context type (e.g., `VtableContext` in BearSSL) that holds implementation-specific data.

3. **Function Pointers**: The vtable contains function pointers to implementation-specific functions.

Here's a simplified example of the vtable pattern:

```zig
// The common interface used by clients
const SecureSocket = struct {
    socket: Socket,
    vtable: *const VTable,
    
    // Common methods that delegate to the vtable
    pub fn connect(self: *SecureSocket, runtime: *Runtime) !void {
        return self.vtable.connect(self.socket, runtime, self.vtable.inner);
    }
    
    // Other methods...
};

// The vtable structure with function pointers
const VTable = struct {
    inner: *anyopaque,  // Backend-specific context
    deinit: fn (*anyopaque) void,
    connect: fn (Socket, *Runtime, *anyopaque) anyerror!void,
    recv: fn (Socket, *Runtime, *anyopaque, []u8) anyerror!usize,
    send: fn (Socket, *Runtime, *anyopaque, []const u8) anyerror!usize,
};
```

#### Benefits of the Vtable Pattern

1. **Interface Separation**: Provides a consistent API regardless of the TLS backend used.
2. **Implementation Hiding**: Users of `SecureSocket` don't need to know which backend is being used.
3. **Runtime Polymorphism**: Different TLS backends can be used interchangeably.
4. **Resource Management**: The vtable's `deinit` function ensures proper cleanup of backend-specific resources.
5. **Modularity**: New TLS backends can be added without changing the public API.

#### Debugging VtableContext

The BearSSL implementation includes a comprehensive debug utility that can be used to inspect the internal state of the TLS connection. This is particularly useful for troubleshooting and understanding how the vtable pattern works with BearSSL.

Example debug output before a TLS handshake:

```
debug(bearssl/client): --- VtableContext Debug: Before TLS handshake ---
debug(bearssl/client): IO Buffer: 33178 bytes @ u8@100be0000
debug(bearssl/client): X.509 Context Details:
debug(bearssl/client):   - error: 0
debug(bearssl/client):   - trust_anchors: cimport.br_x509_trust_anchor@100b80080
debug(bearssl/client):   - trust_anchors_num: 1
debug(bearssl/client):   - days: 0
debug(bearssl/client):   - seconds: 0
debug(bearssl/client):   - cert_length: 0
debug(bearssl/client):   - num_certs: 0
debug(bearssl/client):   - pkey.key_type: 0
debug(bearssl/client):   - cert_signer_key_type: 0
debug(bearssl/client): SSL Engine Details:
debug(bearssl/client):   - err: 0
debug(bearssl/client):   - state: 6
debug(bearssl/client):   - version_in: 0x0000
debug(bearssl/client):   - version_min: 0x0301
debug(bearssl/client):   - version_max: 0x0303
debug(bearssl/client):   - shutdown_recv: 0
debug(bearssl/client):   - iomode: 3
debug(bearssl/client):   - ibuf: u8@100be0000 (16709 bytes)
debug(bearssl/client):   - obuf: u8@100be4055 (16469 bytes)
debug(bearssl/client):   - server_name: localhost
debug(bearssl/client):   - max_frag_len: 16384
debug(bearssl/client):   - log_max_frag_len: 14
debug(bearssl/client):   - record_type_in: 0
debug(bearssl/client):   - record_type_out: 22
debug(bearssl/client): Trust Anchors: 1 (from trust store), 2 (hardcoded)
```

This output shows:
- The X.509 context with trust anchors loaded from PEM files
- The SSL engine state, including protocol versions and buffer information
- The SNI (Server Name Indication) setting
- Current state of both hardcoded and PEM-loaded trust anchors

The debug output can be triggered at different points in the connection process to see how the state changes during the TLS handshake.

##### Implementation Details

The debugging functionality is implemented in the `VtableContext` struct as a set of methods:

```zig
// Main debug function that calls the specialized dumpers
pub fn debugPrint(ctx: *const @This(), title: []const u8) void {
    log.debug("--- VtableContext Debug: {s} ---", .{title});
    // ... call specialized dumper functions ...
}

// Helper function to dump X.509 context details
fn dumpX509Context(x509: *const c.br_x509_minimal_context) void {
    // ...print X.509 state...
}

// Helper function to dump SSL engine context details
fn dumpEngineContext(engine: *const c.br_ssl_engine_context) void {
    // ...print SSL engine state...
}
```

This modular approach allows for detailed debugging of the low-level BearSSL state while maintaining a clean interface. The debug methods are called at key points in the connection process:

1. After initialization with trust anchors
2. Before starting the TLS handshake
3. After the TLS handshake completes

To use this debugging in your own code with the BearSSL backend:

```zig
// Get the inner context from the vtable
const ctx = @ptrCast(*VtableContext, @alignCast(@alignOf(VtableContext), secure.vtable.inner));

// Call the debug print function
ctx.debugPrint("Custom debug point");
```

Note that this requires access to the `VtableContext` type, which is internal to the BearSSL implementation.

## PEM Trust Anchor Support

The BearSSL backend now supports loading trust anchors (certificates) from PEM files instead of using hardcoded certificates. This makes it much easier to use different trusted certificates without recompiling.

### Usage

To use a PEM certificate file as a trust anchor:

```zig
// Initialize BearSSL
var bearssl = secsock.BearSSL.init(allocator);
defer bearssl.deinit();

// Load the PEM file containing the certificate
const cert_bytes = @embedFile("path/to/cert.pem");
// Or read from file
// const cert_bytes = try std.fs.cwd().readFileAlloc(allocator, "path/to/cert.pem", max_size);
// defer allocator.free(cert_bytes);

// Add the certificate as a trusted anchor
try bearssl.add_trusted_cert(
    "CERTIFICATE", // Section name in the PEM file (usually "CERTIFICATE")
    cert_bytes,    // The raw PEM data
);

// Create and use the secure socket as usual
const secure = try bearssl.to_secure_socket(socket, .client);
defer secure.deinit();
```

### Implementation Details

The PEM trust anchor implementation:

1. Decodes PEM data to extract the DER-encoded certificate data
2. Parses the certificate to extract the Distinguished Name (DN) and public key
3. Creates a trust anchor with this information
4. Automatically uses the loaded trust anchors during TLS connections
5. Properly manages memory for all allocated resources

This implementation follows the same approach as BearSSL's `brssl` tool.

#### Memory Management

The implementation carefully manages memory to prevent leaks:

- All certificate data (DN and key material) is deep-copied into memory owned by the TrustAnchorStore
- Resources are properly freed when the BearSSL instance is deinitialized
- Error handling with errdefer ensures no leaks on failure paths
- All allocations use the allocator provided during initialization

## TLS Configuration Options

The BearSSL backend now supports customizable TLS configuration options, allowing you to specify server name, protocol versions, cipher suites, and more.

### Usage

```zig
// Initialize BearSSL
var bearssl = secsock.BearSSL.init(allocator);
defer bearssl.deinit();

// Create a TLS configuration
const tls_config = .{
    // Set SNI (Server Name Indication)
    .server_name = "example.com",
    
    // Use TLS 1.2 only (no TLS 1.0 or 1.1)
    .min_version = c.BR_TLS12,
    .max_version = c.BR_TLS12,
    
    // Customize cipher suites
    .cipher_suites = .{
        .aes_cbc = true,
        .aes_gcm = true,
        .chacha_poly = true,
        .des_cbc = false, // Disable 3DES (less secure)
    },
    
    // Customize crypto algorithms
    .crypto_algos = .{
        .rsa_verify = true,
        .ecdsa = true,
        .ec = true,
        .rsa_pub = true,
    },
};

// Set the configuration
bearssl.setTlsConfig(&tls_config);

// Load certificates and create the secure socket as usual
// ...

// Create and use the secure socket
const secure = try bearssl.to_secure_socket(socket, .client);
defer secure.deinit();
```

### Available Configuration Options

- `server_name`: The server name to use for SNI (Server Name Indication)
- `min_version` and `max_version`: Control which TLS protocol versions are supported
- `cipher_suites`: Enable/disable specific encryption suites
- `crypto_algos`: Enable/disable specific cryptographic algorithms
- `prf_algos`: Enable/disable specific PRF (Pseudo-Random Function) implementations

### Current Limitations

- Multi-Certificate Chains: Currently only supports single certificate trust anchors. For multi-certificate chains, you would need to add each certificate separately.

## Installing
Compatible Zig Version: `0.14.0`

Compatible [tardy](https://github.com/tardy-org/tardy) Version: `v0.3.0`

Latest Release: `0.1.0`
```
zig fetch --save git+https://github.com/tardy-org/secsock#v0.1.0
```

You can then add the dependency in your `build.zig` file:
```zig
const secsock = b.dependency("secsock", .{
    .target = target,
    .optimize = optimize,
}).module("secsock");

exe.root_module.addImport(secsock);
```

## Contribution
We use Nix Flakes for managing the development environment. Nix Flakes provide a reproducible, declarative approach to managing dependencies and development tools.

### Prerequisites
 - Install [Nix](https://nixos.org/download/)
```bash 
sh <(curl -L https://nixos.org/nix/install) --daemon
```
 - Enable [Flake support](https://nixos.wiki/wiki/Flakes) in your Nix config (`~/.config/nix/nix.conf`): `experimental-features = nix-command flakes`

### Getting Started
1. Clone this repository:
```bash
git clone https://github.com/tardy-org/secsock.git
cd secsock
```

2. Enter the development environment:
```bash
nix develop
```

This will provide you with a shell that contains all of the necessary tools and dependencies for development.

Once you are inside of the development shell, you can update the development dependencies by:
1. Modifying the `flake.nix`
2. Running `nix flake update`
3. Committing both the `flake.nix` and the `flake.lock`

### License
Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in secsock by you, shall be licensed as MPL2.0, without any additional terms or conditions.

