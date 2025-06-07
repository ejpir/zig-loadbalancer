/// Command Line Interface and Argument Parsing
/// 
/// Robust CLI with comprehensive options for load balancer configuration.
/// Uses clap library for type-safe argument parsing and validation.
const std = @import("std");
const clap = @import("clap");
const types = @import("../core/types.zig");
const config_module = @import("../config/config.zig");

const BackendServer = types.BackendServer;
const BackendsList = types.BackendsList;
const parseBackendAddress = config_module.parseBackendAddress;
const parseYamlConfig = config_module.parseYamlConfig;
const Config = config_module.Config;

pub fn parseArgs(allocator: std.mem.Allocator) !Config {
    // Parse command line arguments
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help            Display this help and exit.") catch unreachable,
        clap.parseParam("-H, --host <str>      Host address to bind to (default: 0.0.0.0).") catch unreachable,
        clap.parseParam("-p, --port <u16>      Port to listen on (default: 9000).") catch unreachable,
        clap.parseParam("-c, --config <str>    YAML config file for backend servers.") catch unreachable,
        clap.parseParam("-s, --strategy <str>  Load balancer strategy: 'round-robin', 'weighted-round-robin', 'random', or 'sticky' (default: random).") catch unreachable,
        clap.parseParam("--cookie-name <str>   Cookie name for sticky sessions (default: ZZZ_BACKEND_ID).") catch unreachable,
        clap.parseParam("--log-file <str>      Log file path (default: logs/lb-<timestamp>.log).") catch unreachable,
        clap.parseParam("-w, --watch           Watch config file for changes and reload backends automatically.") catch unreachable,
        clap.parseParam("-i, --interval <u32>  Config file watch interval in milliseconds (default: 2000).") catch unreachable,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // Show help if requested
    if (res.args.help != 0) {
        try clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        std.process.exit(0);
    }

    // Set defaults for host and port
    const host: []const u8 = try allocator.dupe(u8, res.args.host orelse "0.0.0.0");
    errdefer allocator.free(host);
    const port: u16 = res.args.port orelse 9000;

    // Initialize backends list
    var backends = BackendsList.init(allocator);
    errdefer backends.deinit();

    // Store the config file path for watching
    var config_file_path: ?[]const u8 = null;
    var watch_config = res.args.watch != 0;
    const watch_interval_ms: u32 = res.args.interval orelse 2000;

    // If config file is provided, parse backends from YAML
    if (res.args.config) |config_path| {
        std.log.info("Using YAML config file: {s}", .{config_path});
        config_file_path = try allocator.dupe(u8, config_path);
        errdefer if (config_file_path) |path| allocator.free(path);

        // Parse YAML config
        backends = parseYamlConfig(allocator, config_path) catch |err| {
            std.log.err("Failed to parse YAML config: {s}", .{@errorName(err)});
            return err;
        };

        // The backend info is already logged by parseYamlConfig
    }

    // If watch is enabled but no config file was provided, show a warning
    if (watch_config and config_file_path == null) {
        std.log.warn("Config file watching enabled, but no config file was provided. Disabling watch.", .{});
        watch_config = false;
    }

    // Parse load balancer strategy
    var strategy = types.LoadBalancerStrategy.random; // Default
    if (res.args.strategy) |strat_str| {
        strategy = types.LoadBalancerStrategy.fromString(strat_str) catch {
            std.log.err("Invalid strategy: {s}, using default 'random' instead", .{strat_str});
            @panic("Invalid strategy");
        };
    }
    
    // Get custom cookie name if provided
    const cookie_name: []const u8 = try allocator.dupe(u8, res.args.@"cookie-name" orelse "ZZZ_BACKEND_ID");
    errdefer allocator.free(cookie_name);
    
    // Get custom log file path if provided
    const log_file_path = if (res.args.@"log-file") |path|
        try allocator.dupe(u8, path)
    else
        null;
    errdefer if (log_file_path) |path| allocator.free(path);
    
    std.log.info("Using load balancer strategy: {s}", .{@tagName(strategy)});
    if (strategy == .sticky) {
        std.log.info("Using sticky session cookie name: {s}", .{cookie_name});
    }
    
    if (log_file_path) |path| {
        std.log.info("Using custom log file path: {s}", .{path});
    }
    
    if (watch_config) {
        std.log.info("Config file watching enabled:", .{});
        std.log.info("  - File: {s}", .{config_file_path.?});
        std.log.info("  - Check interval: {d}ms", .{watch_interval_ms});
    }
    
    return Config{
        .host = host,
        .port = port,
        .backends = backends,
        .strategy = strategy,
        .sticky_session_cookie_name = cookie_name,
        .log_file = log_file_path,
        .config_file_path = config_file_path,
        .watch_config = watch_config,
        .watch_interval_ms = watch_interval_ms,
    };
}
