const std = @import("std");
const benchmarks = @import("build/benchmarks.zig");
const cawfs_build = @import("libs/cawfs/build.zig");
const control_build = @import("services/control/build.zig");
const support = @import("build/support.zig");
const tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_spdk = b.option(bool, "spdk", "Link the Linux endpoint daemon with SPDK") orelse false;
    const enable_benchmark_cpu_profiler = b.option(
        bool,
        "benchmark-cpu-profiler",
        "Link the gperftools CPU profiler into the scheduled Pool benchmark",
    ) orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer for cawfs tests");
    const crc32c_dependency = b.dependency("crc32c", .{});
    if (enable_spdk and target.result.os.tag != .linux) @panic("SPDK support requires Linux");
    if (enable_benchmark_cpu_profiler and !enable_spdk) {
        @panic("benchmark CPU profiling requires SPDK support");
    }

    const portable_core = support.createCoreModule(b, target, optimize, false, crc32c_dependency);
    const app_core = support.createCoreModule(b, target, optimize, target.result.os.tag == .linux, crc32c_dependency);
    if (enable_spdk) _ = support.configureSpdk(b, app_core, target, optimize);
    const exe = support.createExecutable(b, "zettide", target, optimize, app_core, enable_spdk);
    b.installArtifact(exe);
    const dev_step = b.step("dev", "Build the primary Zettide executable for watch mode");
    dev_step.dependOn(&exe.step);

    const pool_data_benchmark_core = support.createCoreModule(
        b,
        target,
        .ReleaseSafe,
        false,
        crc32c_dependency,
    );
    const pool_data_nvmf_args_test_module = b.createModule(.{
        .root_source_file = b.path("tests/spdk_pool_data_nvmf_args.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const pool_data_nvmf_args_tests = b.addTest(.{
        .root_module = pool_data_nvmf_args_test_module,
    });
    const run_pool_data_nvmf_args_tests = b.addRunArtifact(pool_data_nvmf_args_tests);
    const pool_data_synthetic_storage_test_module = b.createModule(.{
        .root_source_file = b.path("tests/spdk_pool_data_synthetic_storage.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .imports = &.{.{ .name = "zettide", .module = pool_data_benchmark_core }},
    });
    const pool_data_synthetic_storage_tests = b.addTest(.{
        .root_module = pool_data_synthetic_storage_test_module,
    });
    const run_pool_data_synthetic_storage_tests = b.addRunArtifact(pool_data_synthetic_storage_tests);

    if (enable_spdk) {
        const catalog_nvmf_benchmark_module = b.createModule(.{
            .root_source_file = b.path("tests/spdk_catalog_nvmf_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zettide", .module = portable_core },
                .{ .name = "spdk_c", .module = support.createSpdkCModule(b, target, optimize, true) },
            },
        });
        catalog_nvmf_benchmark_module.addIncludePath(b.path("tests"));
        const catalog_nvmf_benchmark = b.addLibrary(.{
            .name = "zettide-spdk-catalog-nvmf-benchmark",
            .linkage = .static,
            .root_module = catalog_nvmf_benchmark_module,
        });
        catalog_nvmf_benchmark.bundle_compiler_rt = true;
        const install_catalog_nvmf_benchmark = b.addInstallArtifact(catalog_nvmf_benchmark, .{});
        const catalog_nvmf_benchmark_step = b.step(
            "build-nvmf-catalog-benchmark",
            "Build the Catalog NVMe-oF benchmark target",
        );
        catalog_nvmf_benchmark_step.dependOn(&install_catalog_nvmf_benchmark.step);

        const pool_data_nvmf_benchmark_module = b.createModule(.{
            .root_source_file = b.path("tests/spdk_pool_data_nvmf_benchmark.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zettide", .module = pool_data_benchmark_core },
                .{ .name = "spdk_c", .module = support.createSpdkCModule(b, target, .ReleaseSafe, true) },
            },
        });
        pool_data_nvmf_benchmark_module.addIncludePath(b.path("services/zettide"));
        pool_data_nvmf_benchmark_module.addIncludePath(b.path("tests"));
        const benchmark_cpu_profiler = if (enable_benchmark_cpu_profiler) blk: {
            const gperftools_dependency = b.lazyDependency("gperftools", .{}) orelse return;
            pool_data_benchmark_core.omit_frame_pointer = false;
            pool_data_nvmf_benchmark_module.omit_frame_pointer = false;
            break :blk support.addBenchmarkCpuProfiler(b, gperftools_dependency.path(""), target);
        } else null;
        const pool_data_nvmf_benchmark = b.addLibrary(.{
            .name = "zettide-spdk-pool-data-nvmf-benchmark",
            .linkage = .static,
            .root_module = pool_data_nvmf_benchmark_module,
        });
        pool_data_nvmf_benchmark.bundle_compiler_rt = true;
        const install_pool_data_nvmf_benchmark = b.addInstallArtifact(pool_data_nvmf_benchmark, .{});
        const pool_data_nvmf_benchmark_step = b.step(
            "build-nvmf-pool-data-benchmark",
            "Build the ReleaseSafe scheduled Pool data NVMe-oF benchmark target",
        );
        pool_data_nvmf_benchmark_step.dependOn(&install_pool_data_nvmf_benchmark.step);
        if (benchmark_cpu_profiler) |profiler| {
            const install_profiler_archive = b.addInstallFileWithDir(
                profiler.archive,
                .lib,
                "libzettide-benchmark-cpu-profiler.a",
            );
            const install_profiler_force_link = b.addInstallFileWithDir(
                profiler.force_link,
                .lib,
                "zettide-benchmark-cpu-profiler-force-link.o",
            );
            pool_data_nvmf_benchmark_step.dependOn(&install_profiler_archive.step);
            pool_data_nvmf_benchmark_step.dependOn(&install_profiler_force_link.step);
        }

        const pool_data_nvmf_benchmark_test_step = b.step(
            "test-nvmf-pool-data-benchmark",
            "Test scheduled Pool data NVMe-oF benchmark support",
        );
        pool_data_nvmf_benchmark_test_step.dependOn(&install_pool_data_nvmf_benchmark.step);
        pool_data_nvmf_benchmark_test_step.dependOn(&run_pool_data_nvmf_args_tests.step);
        pool_data_nvmf_benchmark_test_step.dependOn(&run_pool_data_synthetic_storage_tests.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zettide");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{ .root_module = portable_core });
    const run_core_tests = b.addRunArtifact(core_tests);
    const unit_step = b.step("test-unit", "Run deterministic unit tests");
    unit_step.dependOn(&run_core_tests.step);
    unit_step.dependOn(&run_pool_data_nvmf_args_tests.step);
    unit_step.dependOn(&run_pool_data_synthetic_storage_tests.step);

    if (target.result.os.tag == .linux) {
        const nfs_backend_module = b.createModule(.{
            .root_source_file = b.path("services/zettide/nfs_backend.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .link_libc = true,
            .link_libcpp = true,
            .imports = &.{.{ .name = "zettide", .module = portable_core }},
        });
        const nfs_backend_library = b.addLibrary(.{
            .name = "zettide-nfs-backend",
            .linkage = .static,
            .root_module = nfs_backend_module,
        });
        nfs_backend_library.bundle_compiler_rt = true;
        b.installArtifact(nfs_backend_library);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(
            b.path("services/zettide/nfs_backend.h"),
            "zettide/nfs_backend.h",
        ).step);
        const nfs_backend_tests = b.addTest(.{ .root_module = nfs_backend_module });
        const run_nfs_backend_tests = b.addRunArtifact(nfs_backend_tests);
        const nfs_backend_c_test = b.addExecutable(.{
            .name = "zettide-nfs-backend-abi-test",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        nfs_backend_c_test.root_module.addIncludePath(b.path("services/zettide"));
        nfs_backend_c_test.root_module.addCSourceFile(.{
            .file = b.path("tests/nfs_backend_abi.c"),
            .flags = &.{"-std=c11"},
        });
        nfs_backend_c_test.root_module.linkLibrary(nfs_backend_library);
        const run_nfs_backend_c_test = b.addRunArtifact(nfs_backend_c_test);
        const nfs_backend_step = b.step("test-nfs-backend", "Run direct NFS backend ABI tests");
        nfs_backend_step.dependOn(&run_nfs_backend_tests.step);
        nfs_backend_step.dependOn(&run_nfs_backend_c_test.step);
        unit_step.dependOn(&run_nfs_backend_tests.step);
        unit_step.dependOn(&run_nfs_backend_c_test.step);
    }

    const fs_ops_benchmark = benchmarks.add(b, target, optimize, portable_core, unit_step);

    const test_suites = tests.add(b, target, optimize, portable_core, exe, crc32c_dependency);

    const control_test_step = control_build.addComponent(b, target, optimize, "services/control", .{
        .generate = "gen-control-proto",
        .run = "run-control",
        .tests = "test-control",
    });
    const cawfs_test_step = cawfs_build.addComponent(
        b,
        target,
        optimize,
        sanitize_thread,
        "libs/cawfs",
        "test-cawfs",
    );

    const test_step = b.step("test", "Run unit, CLI, control, and cawfs tests");
    test_step.dependOn(unit_step);
    test_step.dependOn(test_suites.cli);
    test_step.dependOn(control_test_step);
    test_step.dependOn(cawfs_test_step);

    const fmt = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "build",
            "services/zettide",
            "tests",
            "benchmarks",
            "services/control/build.zig",
            "services/control/build.zig.zon",
            "services/control/src",
            "libs/cawfs/build.zig",
            "libs/cawfs/build.zig.zon",
            "libs/cawfs/src",
            "libs/cawfs/tests",
            "libs/node-protocol/build.zig",
            "libs/node-protocol/build.zig.zon",
            "libs/node-protocol/src",
        },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check all Zig formatting");
    fmt_step.dependOn(&fmt.step);
    const cawfs_fmt_step = b.step("fmt-check-cawfs", "Check cawfs Zig formatting");
    cawfs_fmt_step.dependOn(fmt_step);

    const ci_step = b.step("ci", "Run formatting, default tests, and cross-compilation checks");
    ci_step.dependOn(fmt_step);
    ci_step.dependOn(test_step);
    ci_step.dependOn(test_suites.cross);
    ci_step.dependOn(&fs_ops_benchmark.step);
}
