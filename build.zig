const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Set install directory to local zig-out
    b.install_prefix = "./zig-out";

    // Get access to zzz module (zzz.io - uses Zig 0.16 native async I/O)
    const zzz_module = b.dependency("zzz", .{
        .target = target,
        .optimize = optimize,
    }).module("zzz");

    // TLS module (ianic/tls.zig - better TLS implementation than std)
    const tls_module = b.addModule("tls", .{
        .root_source_file = b.path("vendor/tls/src/root.zig"),
    });

    // OpenTelemetry SDK module (zig-o11y/opentelemetry-sdk - distributed tracing)
    const otel_module = b.dependency("opentelemetry", .{
        .target = target,
        .optimize = optimize,
    }).module("sdk");

    // Backend 1
    const backend1_mod = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/backend1.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend1_mod.addImport("zzz", zzz_module);
    const backend1 = b.addExecutable(.{
        .name = "backend1",
        .root_module = backend1_mod,
    });
    const build_backend1 = b.addInstallArtifact(backend1, .{});
    const run_backend1 = b.addRunArtifact(backend1);

    // Backend 2
    const backend2_mod = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/backend2.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend2_mod.addImport("zzz", zzz_module);
    const backend2 = b.addExecutable(.{
        .name = "backend2",
        .root_module = backend2_mod,
    });
    const build_backend2 = b.addInstallArtifact(backend2, .{});
    const run_backend2 = b.addRunArtifact(backend2);

    // Backend proxy (proxies to backend2 - measures raw zzz overhead)
    const backend_proxy_mod = b.createModule(.{
        .root_source_file = b.path("backend_proxy.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_proxy_mod.addImport("zzz", zzz_module);
    const backend_proxy = b.addExecutable(.{
        .name = "backend_proxy",
        .root_module = backend_proxy_mod,
    });
    const build_backend_proxy = b.addInstallArtifact(backend_proxy, .{});

    // Test backend echo (echoes request details for integration tests)
    const test_backend_echo_mod = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/test_backend_echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_backend_echo_mod.addImport("zzz", zzz_module);
    const test_backend_echo = b.addExecutable(.{
        .name = "test_backend_echo",
        .root_module = test_backend_echo_mod,
    });
    const build_test_backend_echo = b.addInstallArtifact(test_backend_echo, .{});

    // Sanitizer option for debugging
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable Thread Sanitizer") orelse false;

    // Unified Load Balancer (main entry point)
    const load_balancer_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // Required for DNS resolution (getaddrinfo)
        .sanitize_thread = sanitize_thread,
    });
    load_balancer_mod.addImport("zzz", zzz_module);
    load_balancer_mod.addImport("tls", tls_module);
    load_balancer_mod.addImport("opentelemetry", otel_module);
    const load_balancer = b.addExecutable(.{
        .name = "load_balancer",
        .root_module = load_balancer_mod,
    });
    const build_load_balancer = b.addInstallArtifact(load_balancer, .{});
    const run_load_balancer_cmd = b.addRunArtifact(load_balancer);

    // Unit tests
    const unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/test_load_balancer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // Required for DNS resolution (getaddrinfo)
    });
    unit_tests_mod.addImport("zzz", zzz_module);
    unit_tests_mod.addImport("tls", tls_module);
    const unit_tests = b.addTest(.{
        .name = "unit_tests",
        .root_module = unit_tests_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // E2E Integration tests
    const integration_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Add integration test as executable (for better output)
    const integration_exe = b.addExecutable(.{
        .name = "integration_tests",
        .root_module = integration_tests_mod,
    });
    const run_integration_exe = b.addRunArtifact(integration_exe);
    run_integration_exe.step.dependOn(&build_test_backend_echo.step);
    run_integration_exe.step.dependOn(&build_load_balancer.step);

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_exe.step);

    // Steps
    const build_all = b.step("build-all", "Build backends and load balancer");
    build_all.dependOn(&build_backend1.step);
    build_all.dependOn(&build_backend2.step);
    build_all.dependOn(&build_backend_proxy.step);
    build_all.dependOn(&build_test_backend_echo.step);
    build_all.dependOn(&build_load_balancer.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_lb_step = b.step("run", "Run load balancer (use --mode mp|sp)");
    run_lb_step.dependOn(&run_load_balancer_cmd.step);

    const run_backend1_step = b.step("run-backend1", "Run backend server 1");
    run_backend1_step.dependOn(&run_backend1.step);

    const run_backend2_step = b.step("run-backend2", "Run backend server 2");
    run_backend2_step.dependOn(&run_backend2.step);

    // Set default step to build all executables
    b.default_step = build_all;
}
