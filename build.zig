const std = @import("std");
const benchmarks = @import("build/benchmarks.zig");
const storage_engine_build = @import("libs/storage-engine/build.zig");
const txfs_build = @import("libs/txfs/build.zig");
const controller_build = @import("services/controller/build.zig");
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
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer for TxFS tests");
    const storage_component = storage_engine_build.addComponent(
        b,
        target,
        optimize,
        "libs/storage-engine",
        "vendor/utf8proc",
        "test-storage-engine",
    );
    const storage_engine = storage_component.modules.storage;
    const module_roots_crc32c = storage_component.modules.crc32c;
    const node_module = support.createNodeModule(b, target, optimize, storage_engine, module_roots_crc32c);
    const module_roots_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/module_roots.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zettide_storage", .module = storage_engine },
                .{ .name = "zettide_node", .module = node_module },
            },
        }),
    });
    const run_module_roots_tests = b.addRunArtifact(module_roots_tests);
    if (enable_spdk and target.result.os.tag != .linux) @panic("SPDK support requires Linux");
    if (enable_benchmark_cpu_profiler and !enable_spdk) {
        @panic("benchmark CPU profiling requires SPDK support");
    }

    const portable_core = support.createCoreModule(b, target, optimize, false, storage_engine, module_roots_crc32c);
    const app_core = support.createCoreModule(
        b,
        target,
        optimize,
        target.result.os.tag == .linux,
        storage_engine,
        module_roots_crc32c,
    );
    if (enable_spdk) _ = support.configureSpdk(b, app_core, target, optimize);
    const exe = support.createExecutable(b, "zettide", target, optimize, app_core, enable_spdk);
    b.installArtifact(exe);
    const dev_step = b.step("dev", "Build the primary Zettide executable for watch mode");
    dev_step.dependOn(&exe.step);

    const pool_data_benchmark_modules = storage_engine_build.createPrivateModules(
        b,
        target,
        .ReleaseSafe,
        "libs/storage-engine",
        "vendor/utf8proc",
    );
    const pool_data_benchmark_storage = pool_data_benchmark_modules.storage;
    const pool_data_benchmark_crc32c = pool_data_benchmark_modules.crc32c;
    const pool_data_benchmark_node = support.createNodePrivateModule(
        b,
        target,
        .ReleaseSafe,
        pool_data_benchmark_storage,
        pool_data_benchmark_crc32c,
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
        .imports = &.{.{ .name = "zettide_storage", .module = pool_data_benchmark_storage }},
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
                .{ .name = "zettide_storage", .module = storage_engine },
                .{ .name = "zettide_node", .module = node_module },
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
                .{ .name = "zettide_storage", .module = pool_data_benchmark_storage },
                .{ .name = "zettide_node", .module = pool_data_benchmark_node },
                .{ .name = "spdk_c", .module = support.createSpdkCModule(b, target, .ReleaseSafe, true) },
            },
        });
        pool_data_nvmf_benchmark_module.addIncludePath(b.path("services/node"));
        pool_data_nvmf_benchmark_module.addIncludePath(b.path("tests"));
        const benchmark_cpu_profiler = if (enable_benchmark_cpu_profiler) blk: {
            const gperftools_dependency = b.lazyDependency("gperftools", .{}) orelse return;
            pool_data_benchmark_storage.omit_frame_pointer = false;
            pool_data_benchmark_node.omit_frame_pointer = false;
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

    const compatibility_tests = b.addTest(.{ .root_module = portable_core });
    const run_compatibility_tests = b.addRunArtifact(compatibility_tests);
    const compatibility_step = b.step("test-compatibility", "Run legacy CLI/frontend compatibility unit tests");
    compatibility_step.dependOn(&run_compatibility_tests.step);

    const node_tests = b.addTest(.{ .root_module = node_module });
    const run_node_tests = b.addRunArtifact(node_tests);
    const node_step = b.step("test-node", "Run node composition and adapter unit tests");
    node_step.dependOn(&run_node_tests.step);

    const unit_step = b.step("test-unit", "Run deterministic unit tests by component boundary");
    unit_step.dependOn(storage_component.tests);
    unit_step.dependOn(compatibility_step);
    unit_step.dependOn(node_step);
    unit_step.dependOn(&run_module_roots_tests.step);
    const module_roots_step = b.step("test-module-roots", "Check storage and node module boundaries");
    module_roots_step.dependOn(&run_module_roots_tests.step);
    unit_step.dependOn(&run_pool_data_nvmf_args_tests.step);
    unit_step.dependOn(&run_pool_data_synthetic_storage_tests.step);

    if (target.result.os.tag == .linux) {
        const nfs_backend_module = b.createModule(.{
            .root_source_file = b.path("services/node/nfs_backend.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .link_libc = true,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "zettide_storage", .module = storage_engine },
                .{ .name = "crc32c", .module = module_roots_crc32c },
            },
        });
        const nfs_backend_library = b.addLibrary(.{
            .name = "zettide-nfs-backend",
            .linkage = .static,
            .root_module = nfs_backend_module,
        });
        nfs_backend_library.bundle_compiler_rt = true;
        b.installArtifact(nfs_backend_library);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(
            b.path("services/node/nfs_backend.h"),
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
        nfs_backend_c_test.root_module.addIncludePath(b.path("services/node"));
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

    const fs_ops_benchmark = benchmarks.add(b, target, optimize, storage_engine, node_module, unit_step);

    const test_suites = tests.add(b, target, optimize, storage_engine, node_module, exe);

    const controller_test_step = controller_build.addComponent(b, target, optimize, "services/controller", .{
        .generate = "gen-controller-proto",
        .run = "run-controller",
        .tests = "test-controller",
    });
    const txfs_test_step = txfs_build.addComponent(
        b,
        target,
        optimize,
        sanitize_thread,
        "libs/txfs",
        "test-txfs",
    );

    const test_step = b.step("test", "Run unit, CLI, controller, and TxFS tests");
    test_step.dependOn(unit_step);
    test_step.dependOn(test_suites.cli);
    test_step.dependOn(controller_test_step);
    test_step.dependOn(txfs_test_step);

    const fmt = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "build",
            "services/node",
            "tests",
            "benchmarks",
            "services/controller/build.zig",
            "services/controller/build.zig.zon",
            "services/controller/src",
            "libs/storage-engine/build.zig",
            "libs/storage-engine/build.zig.zon",
            "libs/storage-engine/src",
            "libs/txfs/build.zig",
            "libs/txfs/build.zig.zon",
            "libs/txfs/src",
            "libs/txfs/tests",
            "libs/data-service-contracts/build.zig",
            "libs/data-service-contracts/build.zig.zon",
            "libs/data-service-contracts/src",
        },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check all Zig formatting");
    fmt_step.dependOn(&fmt.step);
    const txfs_fmt_step = b.step("fmt-check-txfs", "Check TxFS Zig formatting");
    txfs_fmt_step.dependOn(fmt_step);

    const ci_step = b.step("ci", "Run formatting, default tests, and cross-compilation checks");
    ci_step.dependOn(fmt_step);
    ci_step.dependOn(test_step);
    ci_step.dependOn(test_suites.cross);
    ci_step.dependOn(&fs_ops_benchmark.step);
}
