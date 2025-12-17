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

    // Backend 1
    const backend1_mod = b.createModule(.{
        .root_source_file = b.path("backend1.zig"),
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
        .root_source_file = b.path("backend2.zig"),
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

    // Load balancer multi-process (nginx-style)
    const load_balancer_mp_mod = b.createModule(.{
        .root_source_file = b.path("main_multiprocess.zig"),
        .target = target,
        .optimize = optimize,
    });
    load_balancer_mp_mod.addImport("zzz", zzz_module);
    const load_balancer_mp = b.addExecutable(.{
        .name = "load_balancer_mp",
        .root_module = load_balancer_mp_mod,
    });
    const build_load_balancer_mp = b.addInstallArtifact(load_balancer_mp, .{});
    const run_load_balancer_mp_cmd = b.addRunArtifact(load_balancer_mp);

    // Load balancer single-process (uses std.Io thread pool)
    const load_balancer_sp_mod = b.createModule(.{
        .root_source_file = b.path("main_singleprocess.zig"),
        .target = target,
        .optimize = optimize,
    });
    load_balancer_sp_mod.addImport("zzz", zzz_module);
    const load_balancer_sp = b.addExecutable(.{
        .name = "load_balancer_sp",
        .root_module = load_balancer_sp_mod,
    });
    const build_load_balancer_sp = b.addInstallArtifact(load_balancer_sp, .{});
    const run_load_balancer_sp_cmd = b.addRunArtifact(load_balancer_sp);

    // Unit tests
    const unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/test_load_balancer.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests_mod.addImport("zzz", zzz_module);
    const unit_tests = b.addTest(.{
        .name = "unit_tests",
        .root_module = unit_tests_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Steps
    const build_all = b.step("build-all", "Build backends and load balancer");
    build_all.dependOn(&build_backend1.step);
    build_all.dependOn(&build_backend2.step);
    build_all.dependOn(&build_load_balancer_mp.step);
    build_all.dependOn(&build_load_balancer_sp.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_lb_mp_step = b.step("run-lb-mp", "Run load balancer (multi-process, nginx-style)");
    run_lb_mp_step.dependOn(&run_load_balancer_mp_cmd.step);

    const run_lb_sp_step = b.step("run-lb-sp", "Run load balancer (single-process, threaded)");
    run_lb_sp_step.dependOn(&run_load_balancer_sp_cmd.step);

    const run_backend1_step = b.step("run-backend1", "Run backend server 1");
    run_backend1_step.dependOn(&run_backend1.step);

    const run_backend2_step = b.step("run-backend2", "Run backend server 2");
    run_backend2_step.dependOn(&run_backend2.step);

    // Set default step to build all executables
    b.default_step = build_all;
}
