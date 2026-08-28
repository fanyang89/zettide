const std = @import("std");

pub fn createNameProfileCrossTest(
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

pub fn createCoreModule(
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

pub fn addCrc32c(
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

pub fn configureSpdk(
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
    spdk_translate.addIncludePath(b.path("src"));
    spdk_translate.addIncludePath(b.path("test"));
    return spdk_translate.createModule();
}

pub fn createLinuxBlockProbe(
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

pub fn createSpdkStorageTest(
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

pub fn createSpdkNvmfExportTest(
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

pub fn createSpdkVhostExportTest(
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
        .file = b.path("test/fs_probe.c"),
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
    probe.root_module.addIncludePath(b.path("test/external"));
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
        .file = b.path("test/durability_probe.c"),
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
        .file = b.path("test/signal_mask_exec.c"),
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
        .file = b.path("test/posix_probe.c"),
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
    probe.root_module.addIncludePath(b.path("test/external"));
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
        .file = b.path("test/conformance/permission_probe.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    return probe;
}
