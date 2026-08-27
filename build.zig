const std = @import("std");

const FuseTestMode = enum { off, auto, required };
const Smb3TestMode = enum { off, auto, required };
const NfsGaneshaTestMode = enum { off, auto, required };
const ExternalTestMode = enum { off, auto, required };
const PrivilegedTestMode = enum { off, auto, required };
const BlockTestMode = enum { off, auto, required };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuse_test_mode = b.option(FuseTestMode, "fuse-tests", "FUSE tests: off, auto, or required") orelse .auto;
    const smb3_test_mode = b.option(Smb3TestMode, "smb3-tests", "Linux SMB3 tests: off, auto, or required") orelse .auto;
    const nfs_ganesha_test_mode = b.option(NfsGaneshaTestMode, "nfs-ganesha-tests", "NFS-Ganesha tests: off, auto, or required") orelse .auto;
    const ganesha_build_dir = b.option([]const u8, "ganesha-build-dir", "Configured NFS-Ganesha V13 build directory");
    const external_test_mode = b.option(ExternalTestMode, "external-tests", "External tests: off, auto, or required") orelse .auto;
    const privileged_test_mode = b.option(PrivilegedTestMode, "privileged-tests", "Privileged tests: off, auto, or required") orelse .auto;
    const block_test_mode = b.option(BlockTestMode, "block-tests", "Linux block device tests: off, auto, or required") orelse .off;
    const enable_spdk = b.option(bool, "spdk", "Link the Linux endpoint daemon with SPDK") orelse false;
    const enable_benchmark_cpu_profiler = b.option(
        bool,
        "benchmark-cpu-profiler",
        "Link the gperftools CPU profiler into the scheduled Pool benchmark",
    ) orelse false;
    const crc32c_dependency = b.dependency("crc32c", .{});
    if (enable_spdk and target.result.os.tag != .linux) @panic("SPDK support requires Linux");
    if (enable_benchmark_cpu_profiler and !enable_spdk) {
        @panic("benchmark CPU profiling requires SPDK support");
    }

    const portable_core = createCoreModule(b, target, optimize, false, crc32c_dependency);
    const app_core = createCoreModule(b, target, optimize, target.result.os.tag == .linux, crc32c_dependency);
    if (enable_spdk) _ = configureSpdk(b, app_core, target, optimize);
    const exe = createExecutable(b, "zettide", target, optimize, app_core, enable_spdk);
    b.installArtifact(exe);

    const pool_data_benchmark_core = createCoreModule(
        b,
        target,
        .ReleaseSafe,
        false,
        crc32c_dependency,
    );
    const pool_data_nvmf_args_test_module = b.createModule(.{
        .root_source_file = b.path("test/spdk_pool_data_nvmf_args.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const pool_data_nvmf_args_tests = b.addTest(.{
        .root_module = pool_data_nvmf_args_test_module,
    });
    const run_pool_data_nvmf_args_tests = b.addRunArtifact(pool_data_nvmf_args_tests);
    const pool_data_synthetic_storage_test_module = b.createModule(.{
        .root_source_file = b.path("test/spdk_pool_data_synthetic_storage.zig"),
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
            .root_source_file = b.path("test/spdk_catalog_nvmf_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zettide", .module = portable_core },
                .{ .name = "spdk_c", .module = createSpdkCModule(b, target, optimize, true) },
            },
        });
        catalog_nvmf_benchmark_module.addIncludePath(b.path("test"));
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
            .root_source_file = b.path("test/spdk_pool_data_nvmf_benchmark.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zettide", .module = pool_data_benchmark_core },
                .{ .name = "spdk_c", .module = createSpdkCModule(b, target, .ReleaseSafe, true) },
            },
        });
        pool_data_nvmf_benchmark_module.addIncludePath(b.path("src"));
        pool_data_nvmf_benchmark_module.addIncludePath(b.path("test"));
        const benchmark_cpu_profiler = if (enable_benchmark_cpu_profiler) blk: {
            const gperftools_dependency = b.lazyDependency("gperftools", .{}) orelse return;
            pool_data_benchmark_core.omit_frame_pointer = false;
            pool_data_nvmf_benchmark_module.omit_frame_pointer = false;
            break :blk addBenchmarkCpuProfiler(b, gperftools_dependency.path(""), target);
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
            .root_source_file = b.path("src/nfs_backend.zig"),
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
            b.path("src/nfs_backend.h"),
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
        nfs_backend_c_test.root_module.addIncludePath(b.path("src"));
        nfs_backend_c_test.root_module.addCSourceFile(.{
            .file = b.path("test/nfs_backend_abi.c"),
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

    const zbench_dependency = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });
    const zbench_module = b.createModule(.{
        .root_source_file = zbench_dependency.path("src/zbench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fs_ops_benchmark_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/fs_ops.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zettide", .module = portable_core },
            .{ .name = "zbench", .module = zbench_module },
        },
    });
    const fs_ops_benchmark = b.addExecutable(.{
        .name = "zettide-fs-ops-benchmark",
        .root_module = fs_ops_benchmark_module,
    });
    const run_fs_ops_benchmark = b.addRunArtifact(fs_ops_benchmark);
    if (b.args) |args| run_fs_ops_benchmark.addArgs(args);
    const fs_ops_benchmark_step = b.step("bench-fs-ops", "Benchmark direct Blob filesystem operations");
    fs_ops_benchmark_step.dependOn(&run_fs_ops_benchmark.step);
    const install_fs_ops_benchmark = b.addInstallArtifact(fs_ops_benchmark, .{});
    const build_fs_ops_benchmark_step = b.step("build-bench-fs-ops", "Build the filesystem operations benchmark");
    build_fs_ops_benchmark_step.dependOn(&install_fs_ops_benchmark.step);

    const fs_ops_benchmark_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/fs_ops.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zettide", .module = portable_core },
                .{ .name = "zbench", .module = zbench_module },
            },
        }),
    });
    const run_fs_ops_benchmark_tests = b.addRunArtifact(fs_ops_benchmark_tests);
    unit_step.dependOn(&run_fs_ops_benchmark_tests.step);

    const blob_device_benchmark_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/blob_device.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zettide", .module = portable_core }},
    });
    const blob_device_benchmark = b.addExecutable(.{
        .name = "zettide-blob-device-benchmark",
        .root_module = blob_device_benchmark_module,
    });
    const run_blob_device_benchmark = b.addRunArtifact(blob_device_benchmark);
    if (b.args) |args| run_blob_device_benchmark.addArgs(args);
    const blob_device_benchmark_step = b.step("bench-blob-device", "Benchmark sequential BlobDevice IO");
    blob_device_benchmark_step.dependOn(&run_blob_device_benchmark.step);
    const install_blob_device_benchmark = b.addInstallArtifact(blob_device_benchmark, .{});
    const build_blob_device_benchmark_step = b.step("build-bench-blob-device", "Build the BlobDevice benchmark");
    build_blob_device_benchmark_step.dependOn(&install_blob_device_benchmark.step);

    const blob_device_benchmark_tests = b.addTest(.{ .root_module = blob_device_benchmark_module });
    const run_blob_device_benchmark_tests = b.addRunArtifact(blob_device_benchmark_tests);
    unit_step.dependOn(&run_blob_device_benchmark_tests.step);

    const blob_store_benchmark_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/blob_store.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zettide", .module = portable_core }},
    });
    const blob_store_benchmark = b.addExecutable(.{
        .name = "zettide-blob-store-benchmark",
        .root_module = blob_store_benchmark_module,
    });
    const run_blob_store_benchmark = b.addRunArtifact(blob_store_benchmark);
    if (b.args) |args| run_blob_store_benchmark.addArgs(args);
    const blob_store_benchmark_step = b.step("bench-blob-store", "Benchmark immutable BlobStore IO");
    blob_store_benchmark_step.dependOn(&run_blob_store_benchmark.step);
    const install_blob_store_benchmark = b.addInstallArtifact(blob_store_benchmark, .{});
    const build_blob_store_benchmark_step = b.step("build-bench-blob-store", "Build the BlobStore benchmark");
    build_blob_store_benchmark_step.dependOn(&install_blob_store_benchmark.step);

    const blob_store_benchmark_tests = b.addTest(.{ .root_module = blob_store_benchmark_module });
    const run_blob_store_benchmark_tests = b.addRunArtifact(blob_store_benchmark_tests);
    unit_step.dependOn(&run_blob_store_benchmark_tests.step);

    const blob_metadata_map_benchmark_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/blob_metadata_map.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zettide", .module = portable_core }},
    });
    const blob_metadata_map_benchmark = b.addExecutable(.{
        .name = "zettide-blob-metadata-map-benchmark",
        .root_module = blob_metadata_map_benchmark_module,
    });
    const run_blob_metadata_map_benchmark = b.addRunArtifact(blob_metadata_map_benchmark);
    if (b.args) |args| run_blob_metadata_map_benchmark.addArgs(args);
    const blob_metadata_map_benchmark_step = b.step(
        "bench-blob-metadata-map",
        "Benchmark incremental Blob metadata updates",
    );
    blob_metadata_map_benchmark_step.dependOn(&run_blob_metadata_map_benchmark.step);
    const install_blob_metadata_map_benchmark = b.addInstallArtifact(blob_metadata_map_benchmark, .{});
    const build_blob_metadata_map_benchmark_step = b.step(
        "build-bench-blob-metadata-map",
        "Build the Blob metadata map benchmark",
    );
    build_blob_metadata_map_benchmark_step.dependOn(&install_blob_metadata_map_benchmark.step);

    const blob_metadata_map_benchmark_tests = b.addTest(.{ .root_module = blob_metadata_map_benchmark_module });
    const run_blob_metadata_map_benchmark_tests = b.addRunArtifact(blob_metadata_map_benchmark_tests);
    unit_step.dependOn(&run_blob_metadata_map_benchmark_tests.step);

    const blob_object_benchmark_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/blob_object.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zettide", .module = portable_core }},
    });
    const blob_object_benchmark = b.addExecutable(.{
        .name = "zettide-blob-object-benchmark",
        .root_module = blob_object_benchmark_module,
    });
    const run_blob_object_benchmark = b.addRunArtifact(blob_object_benchmark);
    if (b.args) |args| run_blob_object_benchmark.addArgs(args);
    const blob_object_benchmark_step = b.step("bench-blob-object", "Benchmark sequential BlobObject IO");
    blob_object_benchmark_step.dependOn(&run_blob_object_benchmark.step);
    const install_blob_object_benchmark = b.addInstallArtifact(blob_object_benchmark, .{});
    const build_blob_object_benchmark_step = b.step("build-bench-blob-object", "Build the BlobObject benchmark");
    build_blob_object_benchmark_step.dependOn(&install_blob_object_benchmark.step);

    const blob_object_benchmark_tests = b.addTest(.{ .root_module = blob_object_benchmark_module });
    const run_blob_object_benchmark_tests = b.addRunArtifact(blob_object_benchmark_tests);
    unit_step.dependOn(&run_blob_object_benchmark_tests.step);

    const cli_test_cmd = b.addSystemCommand(&.{ "bash", "test/cli.sh" });
    cli_test_cmd.addArtifactArg(exe);
    const cli_step = b.step("test-cli", "Run CLI process integration tests");
    cli_step.dependOn(&cli_test_cmd.step);

    const linux_block_probe = if (target.result.os.tag == .linux)
        createLinuxBlockProbe(b, target, optimize, portable_core)
    else
        null;
    const linux_block_test_cmd = b.addSystemCommand(&.{ "bash", "test/linux-block.sh" });
    linux_block_test_cmd.addArg(@tagName(block_test_mode));
    if (linux_block_probe) |artifact| {
        linux_block_test_cmd.addArtifactArg(artifact);
        linux_block_test_cmd.addArtifactArg(exe);
    }
    const linux_block_step = b.step("test-linux-block", "Run Linux loop block device tests");
    linux_block_step.dependOn(&linux_block_test_cmd.step);

    const spdk_link_cmd = b.addSystemCommand(&.{ "bash", "test/spdk-link.sh" });
    const spdk_link_step = b.step("test-spdk-link", "Run the Linux SPDK link check");
    spdk_link_step.dependOn(&spdk_link_cmd.step);

    const spdk_endpoint_cmd = b.addSystemCommand(&.{ "bash", "test/spdk-endpoint.sh" });
    const spdk_endpoint_step = b.step("test-spdk-endpoint", "Run the Linux SPDK bdev endpoint test");
    spdk_endpoint_step.dependOn(&spdk_endpoint_cmd.step);

    const spdk_dispatcher_cmd = b.addSystemCommand(&.{ "bash", "test/spdk-dispatcher.sh" });
    const spdk_dispatcher_step = b.step("test-spdk-dispatcher", "Run the Linux SPDK dispatcher test");
    spdk_dispatcher_step.dependOn(&spdk_dispatcher_cmd.step);

    const spdk_provider_cmd = b.addSystemCommand(&.{ "bash", "test/spdk-provider.sh" });
    const spdk_provider_step = b.step("test-spdk-provider", "Run the asynchronous SPDK bdev provider test");
    spdk_provider_step.dependOn(&spdk_provider_cmd.step);

    const spdk_vhost_export_test = createSpdkVhostExportTest(b, target, optimize, portable_core);
    const spdk_vhost_cmd = b.addSystemCommand(&.{ "bash", "test/spdk-vhost-blk-controller.sh" });
    spdk_vhost_cmd.addArtifactArg(spdk_vhost_export_test);
    const spdk_vhost_step = b.step("test-spdk-vhost-blk-controller", "Run the SPDK vhost-blk controller test");
    spdk_vhost_step.dependOn(&spdk_vhost_cmd.step);

    const spdk_daemon_cmd = b.addSystemCommand(&.{ "bash", "test/spdk-daemon.sh" });
    spdk_daemon_cmd.addArtifactArg(exe);
    const spdk_daemon_step = b.step("test-spdk-daemon", "Run the SPDK endpoint daemon lifecycle test");
    spdk_daemon_step.dependOn(&spdk_daemon_cmd.step);

    const spdk_storage_test = createSpdkStorageTest(b, target, optimize, portable_core);
    const spdk_nvmf_export_test = createSpdkNvmfExportTest(b, target, optimize, portable_core);
    const spdk_storage_cmd = b.addSystemCommand(&.{ "bash", "test/spdk-storage.sh" });
    spdk_storage_cmd.addArtifactArg(spdk_storage_test);
    spdk_storage_cmd.addArtifactArg(spdk_nvmf_export_test);
    const spdk_storage_step = b.step("test-spdk-storage", "Run the Linux SPDK storage integration test");
    spdk_storage_step.dependOn(&spdk_storage_cmd.step);

    const probe = if (target.result.os.tag == .linux) createFsProbe(b, target, optimize) else null;
    const durability_probe = if (target.result.os.tag == .linux) createDurabilityProbe(b, target, optimize) else null;
    const fuse_test_cmd = b.addSystemCommand(&.{ "bash", "test/fuse.sh" });
    fuse_test_cmd.addArg(@tagName(fuse_test_mode));
    fuse_test_cmd.addArtifactArg(exe);
    if (probe) |artifact| fuse_test_cmd.addArtifactArg(artifact);
    if (durability_probe) |artifact| fuse_test_cmd.addArtifactArg(artifact);
    const fuse_step = b.step("test-fuse", "Run real Linux FUSE syscall tests");
    fuse_step.dependOn(&fuse_test_cmd.step);

    const dufs_test_cmd = b.addSystemCommand(&.{ "bash", "test/dufs.sh" });
    dufs_test_cmd.addArg(@tagName(fuse_test_mode));
    dufs_test_cmd.addArtifactArg(exe);
    if (target.result.os.tag == .linux) dufs_test_cmd.addArtifactArg(createSignalMaskExec(b, target, optimize));
    const dufs_step = b.step("test-dufs", "Run the managed dufs integration test");
    dufs_step.dependOn(&dufs_test_cmd.step);

    const host_target = b.graph.host.result;
    const smb3_native_target = target.result.os.tag == .linux and
        host_target.os.tag == .linux and
        target.result.cpu.arch == host_target.cpu.arch and
        target.result.abi == host_target.abi;
    const smb3_test_cmd = b.addSystemCommand(&.{ "bash", "test/smb3-linux.sh" });
    smb3_test_cmd.addArg(@tagName(smb3_test_mode));
    if (smb3_native_target) {
        smb3_test_cmd.addArtifactArg(exe);
        smb3_test_cmd.addArg("native");
    } else {
        smb3_test_cmd.addArg("-");
        smb3_test_cmd.addArg("cross");
    }
    const smb3_step = b.step("test-smb3-linux", "Run the Linux FUSE-to-Samba SMB3 feasibility gate");
    smb3_step.dependOn(&smb3_test_cmd.step);

    const nfs_ganesha_test_cmd = b.addSystemCommand(&.{ "bash", "test/nfs-ganesha.sh" });
    nfs_ganesha_test_cmd.addArg(@tagName(nfs_ganesha_test_mode));
    nfs_ganesha_test_cmd.addArtifactArg(exe);
    nfs_ganesha_test_cmd.addArg(if (smb3_native_target) "native" else "cross");
    nfs_ganesha_test_cmd.addArg(ganesha_build_dir orelse "-");
    nfs_ganesha_test_cmd.step.dependOn(b.getInstallStep());
    const nfs_ganesha_step = b.step("test-nfs-ganesha", "Run the NFSv3 Ganesha RPC integration test");
    nfs_ganesha_step.dependOn(&nfs_ganesha_test_cmd.step);

    const posix_probe = if (target.result.os.tag == .linux) createPosixProbe(b, target, optimize) else null;
    const posix_test_cmd = b.addSystemCommand(&.{ "bash", "test/posix.sh" });
    posix_test_cmd.addArg(@tagName(fuse_test_mode));
    posix_test_cmd.addArtifactArg(exe);
    if (posix_probe) |artifact| posix_test_cmd.addArtifactArg(artifact);
    const posix_step = b.step("test-posix-baseline", "Run the POSIX filesystem baseline");
    posix_step.dependOn(&posix_test_cmd.step);

    const libfuse_probe = if (target.result.os.tag == .linux) createLibfuseProbe(b, target, optimize) else null;
    const libfuse_test_cmd = b.addSystemCommand(&.{ "bash", "test/external/libfuse.sh" });
    libfuse_test_cmd.addArg(@tagName(external_test_mode));
    libfuse_test_cmd.addArtifactArg(exe);
    if (libfuse_probe) |artifact| libfuse_test_cmd.addArtifactArg(artifact);
    const libfuse_step = b.step("test-libfuse", "Run vendored libfuse syscall tests");
    libfuse_step.dependOn(&libfuse_test_cmd.step);

    const fsx_probe = if (target.result.os.tag == .linux) createFsxProbe(b, target, optimize) else null;
    const fsx_test_cmd = b.addSystemCommand(&.{ "bash", "test/external/fsx.sh" });
    fsx_test_cmd.addArg(@tagName(external_test_mode));
    fsx_test_cmd.addArtifactArg(exe);
    if (fsx_probe) |artifact| fsx_test_cmd.addArtifactArg(artifact);
    const fsx_step = b.step("test-fsx", "Run vendored fsx with deterministic seeds");
    fsx_step.dependOn(&fsx_test_cmd.step);

    const fio_test_cmd = b.addSystemCommand(&.{ "bash", "test/external/fio-verify.sh" });
    fio_test_cmd.addArg(@tagName(external_test_mode));
    fio_test_cmd.addArtifactArg(exe);
    const fio_step = b.step("test-fio", "Verify file data before and after a clean remount with fio");
    fio_step.dependOn(&fio_test_cmd.step);

    const fio_throughput_cmd = b.addSystemCommand(&.{ "bash", "test/external/fio-throughput.sh" });
    fio_throughput_cmd.addArg(@tagName(external_test_mode));
    fio_throughput_cmd.addArtifactArg(exe);
    const fio_throughput_step = b.step("test-fio-throughput", "Measure host and Zettide sequential throughput");
    fio_throughput_step.dependOn(&fio_throughput_cmd.step);

    const external_step = b.step("test-external", "Run vendored external filesystem tests");
    external_step.dependOn(libfuse_step);
    external_step.dependOn(fsx_step);

    const permission_probe = if (target.result.os.tag == .linux) createPermissionProbe(b, target, optimize) else null;
    const permission_test_cmd = b.addSystemCommand(&.{ "bash", "test/conformance/permissions.sh" });
    permission_test_cmd.addArg(@tagName(privileged_test_mode));
    permission_test_cmd.addArtifactArg(exe);
    if (permission_probe) |artifact| permission_test_cmd.addArtifactArg(artifact);
    const permission_step = b.step("test-permissions", "Run the privileged permission matrix");
    permission_step.dependOn(&permission_test_cmd.step);

    const pjdfstest_cmd = b.addSystemCommand(&.{ "bash", "test/external/pjdfstest.sh" });
    pjdfstest_cmd.addArg(@tagName(privileged_test_mode));
    pjdfstest_cmd.addArtifactArg(exe);
    const pjdfstest_step = b.step("test-pjdfstest", "Run selected pjdfstest POSIX cases");
    pjdfstest_step.dependOn(&pjdfstest_cmd.step);

    const xfstests_cmd = b.addSystemCommand(&.{ "bash", "test/external/xfstests.sh" });
    xfstests_cmd.addArg(@tagName(external_test_mode));
    xfstests_cmd.addArtifactArg(exe);
    const xfstests_step = b.step("test-xfstests", "Run selected xfstests mmap and lock cases");
    xfstests_step.dependOn(&xfstests_cmd.step);

    const ltp_cmd = b.addSystemCommand(&.{ "bash", "test/external/ltp-open-posix.sh" });
    ltp_cmd.addArg(@tagName(external_test_mode));
    ltp_cmd.addArtifactArg(exe);
    const ltp_step = b.step("test-ltp-open-posix", "Run selected LTP Open POSIX cases");
    ltp_step.dependOn(&ltp_cmd.step);

    const posix_quick_step = b.step("test-posix-quick", "Run the required POSIX filesystem quick gate");
    posix_quick_step.dependOn(fuse_step);
    posix_quick_step.dependOn(posix_step);
    posix_quick_step.dependOn(libfuse_step);
    posix_quick_step.dependOn(fsx_step);

    const posix_privileged_step = b.step("test-posix-privileged", "Run privileged POSIX permission gates");
    posix_privileged_step.dependOn(permission_step);
    posix_privileged_step.dependOn(pjdfstest_step);

    const posix_nightly_step = b.step("test-posix-nightly", "Run the POSIX nightly conformance gates");
    posix_nightly_step.dependOn(posix_quick_step);
    posix_nightly_step.dependOn(posix_privileged_step);
    posix_nightly_step.dependOn(xfstests_step);
    posix_nightly_step.dependOn(ltp_step);
    posix_nightly_step.dependOn(fio_step);

    const cross_step = b.step("test-cross", "Compile portable boundaries for Windows and macOS");
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_core = createCoreModule(b, windows_target, optimize, false, crc32c_dependency);
    const windows_exe = createExecutable(b, "zettide-windows-check", windows_target, optimize, windows_core, false);
    const windows_name_tests = createNameProfileCrossTest(b, windows_target, optimize, windows_core);
    const macos_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const macos_core = createCoreModule(b, macos_target, optimize, false, crc32c_dependency);
    const macos_name_tests = createNameProfileCrossTest(b, macos_target, optimize, macos_core);
    cross_step.dependOn(&windows_exe.step);
    cross_step.dependOn(&windows_name_tests.step);
    cross_step.dependOn(&macos_name_tests.step);

    const test_step = b.step("test", "Run unit and CLI tests");
    test_step.dependOn(unit_step);
    test_step.dependOn(cli_step);

    const ci_step = b.step("ci", "Run default tests and cross-compilation checks");
    ci_step.dependOn(test_step);
    ci_step.dependOn(cross_step);
    ci_step.dependOn(&fs_ops_benchmark.step);
}

fn createNameProfileCrossTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/name-profile-cross.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zettide", .module = core }},
        }),
    });
}

fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    with_fuse: bool,
    crc32c_dependency: *std.Build.Dependency,
) *std.Build.Module {
    const core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unavailable_c_source = b.addWriteFiles().add("unavailable_c.zig", "");
    const unavailable_c = b.createModule(.{
        .root_source_file = unavailable_c_source,
        .target = target,
        .optimize = optimize,
    });
    core.addImport("linux_c", unavailable_c);
    core.addImport("spdk_c", createSpdkCModule(b, target, optimize, false));
    core.addIncludePath(b.path("vendor/utf8proc"));
    core.addIncludePath(b.path("src"));
    core.addCMacro("UTF8PROC_STATIC", "1");
    core.addCSourceFiles(.{
        .files = &.{"vendor/utf8proc/utf8proc.c"},
        .flags = &.{ "-std=c99", "-DUTF8PROC_STATIC" },
    });
    const utf8proc_header = b.addWriteFiles().add("utf8proc_c.h",
        \\#include <stdlib.h>
        \\#include <utf8proc.h>
    );
    const utf8proc_translate = b.addTranslateC(.{
        .root_source_file = utf8proc_header,
        .target = target,
        .optimize = optimize,
    });
    utf8proc_translate.addIncludePath(b.path("vendor/utf8proc"));
    utf8proc_translate.defineCMacro("UTF8PROC_STATIC", "1");
    core.addImport("utf8proc_c", utf8proc_translate.createModule());
    const crc32c = b.createModule(.{
        .root_source_file = b.path("src/crc32c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const crc32c_config = addCrc32c(crc32c, crc32c_dependency, target);
    const crc32c_translate = b.addTranslateC(.{
        .root_source_file = crc32c_dependency.path("include/crc32c/crc32c.h"),
        .target = target,
        .optimize = optimize,
    });
    crc32c_translate.addConfigHeader(crc32c_config);
    crc32c_translate.addIncludePath(crc32c_dependency.path("include"));
    crc32c_translate.addIncludePath(crc32c_dependency.path("src"));
    crc32c.addImport("crc32c_c", crc32c_translate.createModule());
    crc32c.link_libcpp = true;
    core.addImport("crc32c", crc32c);
    if (target.result.os.tag == .linux) {
        const linux_header = b.addWriteFiles().add("linux_c.h",
            \\#include <errno.h>
            \\#include <fcntl.h>
            \\#include <signal.h>
            \\#include <sys/signalfd.h>
            \\#include <unistd.h>
            \\#include <fuse_shim.h>
        );
        const linux_translate = b.addTranslateC(.{
            .root_source_file = linux_header,
            .target = target,
            .optimize = optimize,
        });
        linux_translate.addIncludePath(b.path("src"));
        linux_translate.defineCMacro("_FORTIFY_SOURCE", "0");
        linux_translate.defineCMacro("FUSE_USE_VERSION", "35");
        linux_translate.linkSystemLibrary("fuse3", .{});
        core.addImport("linux_c", linux_translate.createModule());
    }
    if (with_fuse) {
        core.addCMacro("FUSE_USE_VERSION", "35");
        core.linkSystemLibrary("fuse3", .{});
        core.addCSourceFiles(.{
            .files = &.{"src/fuse_shim.c"},
            .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L", "-DFUSE_USE_VERSION=35" },
        });
    }
    return core;
}

fn addCrc32c(
    module: *std.Build.Module,
    dependency: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.ConfigHeader {
    const b = module.owner;
    const arch = target.result.cpu.arch;
    const is_x86 = arch == .x86 or arch == .x86_64;
    const is_aarch64 = arch == .aarch64 or arch == .aarch64_be;
    const config_header = b.addConfigHeader(.{
        .style = .{ .cmake = dependency.path("src/crc32c_config.h.in") },
        .include_path = "crc32c/crc32c_config.h",
    }, .{
        .BYTE_ORDER_BIG_ENDIAN = arch.endian() == .big,
        .HAVE_BUILTIN_PREFETCH = true,
        .HAVE_MM_PREFETCH = is_x86,
        .HAVE_SSE42 = is_x86,
        .HAVE_ARM64_CRC32C = is_aarch64,
        .HAVE_STRONG_GETAUXVAL = is_aarch64 and target.result.os.tag == .linux,
        .HAVE_WEAK_GETAUXVAL = false,
        .CRC32C_TESTS_BUILT_WITH_GLOG = false,
    });
    module.addConfigHeader(config_header);
    module.addIncludePath(dependency.path("include"));
    module.addIncludePath(dependency.path("src"));
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &.{
            "src/crc32c.cc",
            "src/crc32c_portable.cc",
        },
        .flags = &.{ "-fno-exceptions", "-fno-rtti" },
    });
    if (is_x86) {
        module.addCSourceFile(.{
            .file = dependency.path("src/crc32c_sse42.cc"),
            .flags = &.{
                "-fno-exceptions",
                "-fno-rtti",
                "-Xclang",
                "-target-feature",
                "-Xclang",
                "+sse4.2",
                "-Xclang",
                "-target-feature",
                "-Xclang",
                "+crc32",
            },
        });
    }
    if (is_aarch64) {
        module.addCSourceFile(.{
            .file = dependency.path("src/crc32c_arm64.cc"),
            .flags = &.{
                "-fno-exceptions",
                "-fno-rtti",
                "-Xclang",
                "-target-feature",
                "-Xclang",
                "+crc",
                "-Xclang",
                "-target-feature",
                "-Xclang",
                "+aes",
            },
        });
    }
    return config_header;
}

const BenchmarkCpuProfiler = struct {
    archive: std.Build.LazyPath,
    force_link: std.Build.LazyPath,
};

fn addBenchmarkCpuProfiler(
    b: *std.Build,
    source_dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
) BenchmarkCpuProfiler {
    const target_triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const run = b.addSystemCommand(&.{"bash"});
    run.addFileArg(b.path("vendor/grpc-lite/tools/build_native.sh"));
    run.addArg("gperftools");
    run.addDirectoryArg(source_dir);
    const output = run.addOutputDirectoryArg("gperftools");
    run.addArgs(&.{
        "RelWithDebInfo",
        "cc",
        "c++",
        b.graph.zig_exe,
        target_triple,
    });
    run.addFileArg(b.path("vendor/grpc-lite/tools/gperftools_force_link.c"));
    run.addFileArg(b.path("vendor/grpc-lite/tools/mbedtls_user_config.h"));
    run.addArgs(&.{ "false", "false", "true", "false" });
    return .{
        .archive = output.path(b, "libgrpc_lite_gperftools.a"),
        .force_link = output.path(b, "gperftools_force_link.o"),
    };
}

fn createExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    enable_spdk: bool,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "spdk", enable_spdk);
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zettide", .module = core }},
    });
    module.addOptions("build_options", options);
    return b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
}

fn configureSpdk(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    module.addCSourceFiles(.{
        .files = &.{
            "src/spdk/runtime.c",
            "src/spdk/bdev_provider.c",
            "src/spdk/iscsi_export.c",
            "src/spdk/nvmf_tcp_export.c",
            "src/spdk/vhost_blk_controller.c",
        },
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    const libraries = [_][]const u8{
        "spdk_event",
        "spdk_event_bdev",
        "spdk_event_scsi",
        "spdk_event_iscsi",
        "spdk_event_nvmf",
        "spdk_event_vhost_blk",
        "spdk_bdev_modules",
        "spdk_env_dpdk",
        "spdk_nvmf",
        "spdk_scsi",
        "spdk_iscsi",
        "spdk_sock_modules",
        "spdk_syslibs",
    };
    for (libraries) |library| module.linkSystemLibrary(library, .{ .needed = true, .use_pkg_config = .force });
    const spdk_c = createSpdkCModule(b, target, optimize, true);
    module.addImport("spdk_c", spdk_c);
    return spdk_c;
}

fn createSpdkCModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    include_test_api: bool,
) *std.Build.Module {
    const portable_header =
        \\#include <errno.h>
        \\#include <stdlib.h>
        \\#include <spdk/runtime.h>
        \\#include <spdk/bdev_dispatcher.h>
        \\#include <spdk/nvme_controller.h>
        \\#include <spdk/bdev_provider.h>
        \\#include <spdk/iscsi_export.h>
        \\#include <spdk/nvmf_tcp_export.h>
        \\#include <spdk/vhost_blk_controller.h>
    ;
    const test_header =
        \\#include <pthread.h>
        \\#include <signal.h>
        \\#include <spdk_runtime.h>
    ;
    const spdk_header = b.addWriteFiles().add(
        "spdk_c.h",
        if (include_test_api) portable_header ++ "\n" ++ test_header else portable_header,
    );
    const spdk_translate = b.addTranslateC(.{
        .root_source_file = spdk_header,
        .target = target,
        .optimize = optimize,
    });
    spdk_translate.addIncludePath(b.path("src"));
    spdk_translate.addIncludePath(b.path("test"));
    return spdk_translate.createModule();
}

fn createLinuxBlockProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "zettide-linux-block-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/linux_block.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zettide", .module = core }},
        }),
    });
}

fn createSpdkStorageTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("test/spdk_storage.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zettide", .module = core },
            .{ .name = "spdk_c", .module = createSpdkCModule(b, target, optimize, true) },
        },
    });
    module.addIncludePath(b.path("src"));
    module.addIncludePath(b.path("test"));
    return b.addLibrary(.{
        .name = "zettide-spdk-storage-test",
        .root_module = module,
    });
}

fn createSpdkNvmfExportTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("test/spdk_nvmf_export.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zettide", .module = core }},
    });
    module.addIncludePath(b.path("src"));
    return b.addLibrary(.{
        .name = "zettide-spdk-nvmf-export-test",
        .root_module = module,
    });
}

fn createSpdkVhostExportTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("test/spdk_vhost_export.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zettide", .module = core }},
    });
    module.addIncludePath(b.path("src"));
    return b.addLibrary(.{
        .name = "zettide-spdk-vhost-export-test",
        .root_module = module,
    });
}

fn createFsProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const probe = b.addExecutable(.{
        .name = "fs-probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    probe.root_module.addCSourceFile(.{
        .file = b.path("test/fs_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}

fn createLibfuseProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const probe = b.addExecutable(.{
        .name = "libfuse-test-syscalls",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    probe.root_module.addIncludePath(b.path("test/external"));
    probe.root_module.addCSourceFile(.{
        .file = b.path("vendor/libfuse-tests/test_syscalls.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}

fn createDurabilityProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const probe = b.addExecutable(.{
        .name = "durability-probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    probe.root_module.addCSourceFile(.{
        .file = b.path("test/durability_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}

fn createSignalMaskExec(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{
        .name = "signal-mask-exec",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    executable.root_module.addCSourceFile(.{
        .file = b.path("test/signal_mask_exec.c"),
        .flags = &.{"-std=c11"},
    });
    return executable;
}

fn createPosixProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const probe = b.addExecutable(.{
        .name = "posix-probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    probe.root_module.addCSourceFile(.{
        .file = b.path("test/posix_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}

fn createFsxProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const probe = b.addExecutable(.{
        .name = "xfstests-fsx",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    probe.root_module.addIncludePath(b.path("test/external"));
    probe.root_module.addIncludePath(b.path("vendor/xfstests/src"));
    probe.root_module.addCSourceFile(.{
        .file = b.path("vendor/xfstests/ltp/fsx.c"),
        .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE" },
    });
    return probe;
}

fn createPermissionProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const probe = b.addExecutable(.{
        .name = "permission-probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    probe.root_module.addCSourceFile(.{
        .file = b.path("test/conformance/permission_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}
