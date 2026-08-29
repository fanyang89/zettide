const std = @import("std");

pub fn createNameProfileCrossTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/name-profile-cross.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zettide_storage", .module = storage_engine }},
        }),
    });
}

pub fn createNodePrivateModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    crc32c: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("services/node/node_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("zettide_storage", storage_engine);
    module.addImport("crc32c", crc32c);
    module.addImport("spdk_c", createSpdkCModule(b, target, optimize, false));
    module.addIncludePath(b.path("services/node"));
    return module;
}

pub fn createNodeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    crc32c: *std.Build.Module,
) *std.Build.Module {
    const module = b.addModule("zettide_node", .{
        .root_source_file = b.path("services/node/node_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("zettide_storage", storage_engine);
    module.addImport("crc32c", crc32c);
    module.addImport("spdk_c", createSpdkCModule(b, target, optimize, false));
    module.addIncludePath(b.path("services/node"));
    return module;
}

pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    with_fuse: bool,
    storage_engine: *std.Build.Module,
    crc32c: *std.Build.Module,
) *std.Build.Module {
    const core = b.createModule(.{
        .root_source_file = b.path("services/node/root.zig"),
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
    core.addImport("zettide_storage", storage_engine);
    core.addImport("crc32c", crc32c);
    core.addIncludePath(b.path("services/node"));
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
        linux_translate.addIncludePath(b.path("services/node"));
        linux_translate.defineCMacro("_FORTIFY_SOURCE", "0");
        linux_translate.defineCMacro("FUSE_USE_VERSION", "35");
        linux_translate.linkSystemLibrary("fuse3", .{});
        core.addImport("linux_c", linux_translate.createModule());
    }
    if (with_fuse) {
        core.addCMacro("FUSE_USE_VERSION", "35");
        core.linkSystemLibrary("fuse3", .{});
        core.addCSourceFiles(.{
            .files = &.{"services/node/fuse_shim.c"},
            .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L", "-DFUSE_USE_VERSION=35" },
        });
    }
    return core;
}

const BenchmarkCpuProfiler = struct {
    archive: std.Build.LazyPath,
    force_link: std.Build.LazyPath,
};

pub fn addBenchmarkCpuProfiler(
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
        .root_source_file = b.path("services/node/main.zig"),
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
            "services/node/spdk/runtime.c",
            "services/node/spdk/bdev_provider.c",
            "services/node/spdk/iscsi_export.c",
            "services/node/spdk/nvmf_tcp_export.c",
            "services/node/spdk/vhost_blk_controller.c",
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
    spdk_translate.addIncludePath(b.path("services/node"));
    spdk_translate.addIncludePath(b.path("tests"));
    return spdk_translate.createModule();
}

pub fn createLinuxBlockProbe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    node_module: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "zettide-linux-block-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/linux_block.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zettide_storage", .module = storage_engine },
                .{ .name = "zettide_node", .module = node_module },
            },
        }),
    });
}

pub fn createSpdkStorageTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    node_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("tests/spdk_storage.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zettide_storage", .module = storage_engine },
            .{ .name = "zettide_node", .module = node_module },
            .{ .name = "spdk_c", .module = createSpdkCModule(b, target, optimize, true) },
        },
    });
    module.addIncludePath(b.path("services/node"));
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
    node_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("tests/spdk_nvmf_export.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zettide_storage", .module = storage_engine },
            .{ .name = "zettide_node", .module = node_module },
        },
    });
    module.addIncludePath(b.path("services/node"));
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
    node_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("tests/spdk_vhost_export.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zettide_storage", .module = storage_engine },
            .{ .name = "zettide_node", .module = node_module },
        },
    });
    module.addIncludePath(b.path("services/node"));
    return b.addLibrary(.{
        .name = "zettide-spdk-vhost-export-test",
        .root_module = module,
    });
}

pub fn createFsProbe(
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
        .file = b.path("tests/fs_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}

pub fn createLibfuseProbe(
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
    probe.root_module.addIncludePath(b.path("tests/external"));
    probe.root_module.addCSourceFile(.{
        .file = b.path("vendor/libfuse-tests/test_syscalls.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}

pub fn createDurabilityProbe(
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
        .file = b.path("tests/durability_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}

pub fn createSignalMaskExec(
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
        .file = b.path("tests/signal_mask_exec.c"),
        .flags = &.{"-std=c11"},
    });
    return executable;
}

pub fn createPosixProbe(
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
        .file = b.path("tests/posix_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}

pub fn createFsxProbe(
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
    probe.root_module.addIncludePath(b.path("tests/external"));
    probe.root_module.addIncludePath(b.path("vendor/xfstests/src"));
    probe.root_module.addCSourceFile(.{
        .file = b.path("vendor/xfstests/ltp/fsx.c"),
        .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE" },
    });
    return probe;
}

pub fn createPermissionProbe(
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
        .file = b.path("tests/conformance/permission_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}
