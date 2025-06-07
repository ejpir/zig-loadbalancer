const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Set install directory to local zig-out
    b.install_prefix = "./zig-out";

    // Get access to zzz module
    const zzz_module = b.addModule("zzz", .{
        .root_source_file = b.path("../../src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies
    const tardy = b.dependency("tardy", .{
        .target = target,
        .optimize = optimize,
    }).module("tardy");
    zzz_module.addImport("tardy", tardy);

    const secsock = b.dependency("secsock", .{
        .target = target,
        .optimize = optimize,
    }).module("secsock");
    zzz_module.addImport("secsock", secsock);

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    }).module("clap");

    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    }).module("yaml");

    // Backend 1
    const backend1 = b.addExecutable(.{
        .name = "backend1",
        .root_source_file = b.path("backend1.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend1.root_module.addImport("zzz", zzz_module);
    const build_backend1 = b.addInstallArtifact(backend1, .{});
    const run_backend1 = b.addRunArtifact(backend1);
    
    // Backend 2
    const backend2 = b.addExecutable(.{
        .name = "backend2",
        .root_source_file = b.path("backend2.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend2.root_module.addImport("zzz", zzz_module);
    const build_backend2 = b.addInstallArtifact(backend2, .{});
    const run_backend2 = b.addRunArtifact(backend2);

    // Load balancer executable
    const load_balancer = b.addExecutable(.{
        .name = "load_balancer",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    load_balancer.root_module.addImport("zzz", zzz_module);
    load_balancer.root_module.addImport("clap", clap);
    load_balancer.root_module.addImport("yaml", yaml);
    const build_load_balancer = b.addInstallArtifact(load_balancer, .{});
    const run_load_balancer_cmd = b.addRunArtifact(load_balancer);

    // Unit tests
    const unit_tests = b.addTest(.{
        .name = "unit_tests",
        .root_source_file = b.path("src/test_load_balancer.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("zzz", zzz_module);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Steps
    const build_all = b.step("build-all", "Build both backends and load balancer");
    build_all.dependOn(&build_backend1.step);
    build_all.dependOn(&build_backend2.step);
    build_all.dependOn(&build_load_balancer.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_lb_step = b.step("run-lb", "Run load balancer");
    run_lb_step.dependOn(&run_load_balancer_cmd.step);

    const run_backend1_step = b.step("run-backend1", "Run backend server 1");
    run_backend1_step.dependOn(&run_backend1.step);

    const run_backend2_step = b.step("run-backend2", "Run backend server 2");
    run_backend2_step.dependOn(&run_backend2.step);

    // Set default step to build all executables
    b.default_step = build_all;
}