const std = @import("std");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    data_node_module: *std.Build.Module,
    unit_step: *std.Build.Step,
) *std.Build.Step.Compile {
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
            .{ .name = "zettide_storage", .module = storage_engine },
            .{ .name = "zettide_data_node", .module = data_node_module },
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
                .{ .name = "zettide_storage", .module = storage_engine },
                .{ .name = "zettide_data_node", .module = data_node_module },
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
        .imports = &.{ .{ .name = "zettide_storage", .module = storage_engine }, .{ .name = "zettide_data_node", .module = data_node_module } },
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
        .imports = &.{ .{ .name = "zettide_storage", .module = storage_engine }, .{ .name = "zettide_data_node", .module = data_node_module } },
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
        .imports = &.{ .{ .name = "zettide_storage", .module = storage_engine }, .{ .name = "zettide_data_node", .module = data_node_module } },
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
        .imports = &.{ .{ .name = "zettide_storage", .module = storage_engine }, .{ .name = "zettide_data_node", .module = data_node_module } },
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

    return fs_ops_benchmark;
}
