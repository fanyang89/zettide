const std = @import("std");

pub fn createBlockFormatCrossTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/block-format-cross.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zettide_storage", .module = storage_engine }},
        }),
    });
}

pub fn createDataNodeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    crc32c: *std.Build.Module,
) *std.Build.Module {
    const module = b.addModule("zettide_data_node", .{
        .root_source_file = b.path("services/data-node/data_node_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("zettide_storage", storage_engine);
    module.addImport("crc32c", crc32c);
    module.addImport("spdk_c", createSpdkCModule(b, target, optimize, false));
    module.addIncludePath(b.path("services/data-node"));
    return module;
}

pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    crc32c: *std.Build.Module,
) *std.Build.Module {
    const core = b.createModule(.{
        .root_source_file = b.path("services/data-node/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.addImport("spdk_c", createSpdkCModule(b, target, optimize, false));
    core.addImport("zettide_storage", storage_engine);
    core.addImport("crc32c", crc32c);
    core.addIncludePath(b.path("services/data-node"));
    return core;
}

pub fn createExecutable(
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
        .root_source_file = b.path("services/data-node/main.zig"),
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

pub fn configureSpdk(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    module.addCSourceFiles(.{
        .files = &.{
            "services/data-node/spdk/runtime.c",
            "services/data-node/spdk/bdev_provider.c",
            "services/data-node/spdk/iscsi_export.c",
            "services/data-node/spdk/nvmf_tcp_export.c",
            "services/data-node/spdk/vhost_blk_controller.c",
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

pub fn createSpdkCModule(
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
    spdk_translate.addIncludePath(b.path("services/data-node"));
    spdk_translate.addIncludePath(b.path("tests"));
    return spdk_translate.createModule();
}

pub fn createLinuxBlockProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    data_node_module: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "zettide-linux-block-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linux_block.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zettide_storage", .module = storage_engine },
                .{ .name = "zettide_data_node", .module = data_node_module },
            },
        }),
    });
}

pub fn createSpdkStorageTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    data_node_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("tests/spdk_storage.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zettide_storage", .module = storage_engine },
            .{ .name = "zettide_data_node", .module = data_node_module },
            .{ .name = "spdk_c", .module = createSpdkCModule(b, target, optimize, true) },
        },
    });
    module.addIncludePath(b.path("services/data-node"));
    module.addIncludePath(b.path("tests"));
    return b.addLibrary(.{
        .name = "zettide-spdk-storage-test",
        .root_module = module,
    });
}

pub fn createSpdkNvmfExportTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    data_node_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("tests/spdk_nvmf_export.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zettide_storage", .module = storage_engine },
            .{ .name = "zettide_data_node", .module = data_node_module },
        },
    });
    module.addIncludePath(b.path("services/data-node"));
    return b.addLibrary(.{
        .name = "zettide-spdk-nvmf-export-test",
        .root_module = module,
    });
}

pub fn createSpdkVhostExportTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    data_node_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("tests/spdk_vhost_export.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zettide_storage", .module = storage_engine },
            .{ .name = "zettide_data_node", .module = data_node_module },
        },
    });
    module.addIncludePath(b.path("services/data-node"));
    return b.addLibrary(.{
        .name = "zettide-spdk-vhost-export-test",
        .root_module = module,
    });
}
