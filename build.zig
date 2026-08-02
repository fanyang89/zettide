const std = @import("std");

const FuseTestMode = enum { off, auto, required };
const Smb3TestMode = enum { off, auto, required };
const ExternalTestMode = enum { off, auto, required };
const PrivilegedTestMode = enum { off, auto, required };
const BlockTestMode = enum { off, auto, required };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuse_test_mode = b.option(FuseTestMode, "fuse-tests", "FUSE tests: off, auto, or required") orelse .auto;
    const smb3_test_mode = b.option(Smb3TestMode, "smb3-tests", "Linux SMB3 tests: off, auto, or required") orelse .auto;
    const external_test_mode = b.option(ExternalTestMode, "external-tests", "External tests: off, auto, or required") orelse .auto;
    const privileged_test_mode = b.option(PrivilegedTestMode, "privileged-tests", "Privileged tests: off, auto, or required") orelse .auto;
    const block_test_mode = b.option(BlockTestMode, "block-tests", "Linux block device tests: off, auto, or required") orelse .off;
    const enable_spdk = b.option(bool, "spdk", "Link the Linux endpoint daemon with SPDK") orelse false;
    if (enable_spdk and target.result.os.tag != .linux) @panic("SPDK support requires Linux");

    const portable_core = createCoreModule(b, target, optimize, false);
    const app_core = createCoreModule(b, target, optimize, target.result.os.tag == .linux);
    if (enable_spdk) configureSpdk(app_core);
    const exe = createExecutable(b, "zettide", target, optimize, app_core, enable_spdk);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zettide");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{ .root_module = portable_core });
    const run_core_tests = b.addRunArtifact(core_tests);
    const unit_step = b.step("test-unit", "Run deterministic unit tests");
    unit_step.dependOn(&run_core_tests.step);

    const image_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/image.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zettide", .module = portable_core }},
        }),
    });
    const run_image_tests = b.addRunArtifact(image_tests);
    const image_step = b.step("test-image", "Run littlefs image integration tests");
    image_step.dependOn(&run_image_tests.step);

    const fault_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fault.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zettide", .module = portable_core }},
        }),
    });
    const run_fault_tests = b.addRunArtifact(fault_tests);
    const fault_step = b.step("test-fault", "Run deterministic block fault tests");
    fault_step.dependOn(&run_fault_tests.step);

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
    const spdk_storage_cmd = b.addSystemCommand(&.{ "bash", "test/spdk-storage.sh" });
    spdk_storage_cmd.addArtifactArg(spdk_storage_test);
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
    posix_nightly_step.dependOn(fault_step);

    const cross_step = b.step("test-cross", "Compile portable core and CLI for Windows");
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_core = createCoreModule(b, windows_target, optimize, false);
    const windows_exe = createExecutable(b, "zettide-windows-check", windows_target, optimize, windows_core, false);
    cross_step.dependOn(&windows_exe.step);

    const test_step = b.step("test", "Run unit, image, and CLI tests");
    test_step.dependOn(unit_step);
    test_step.dependOn(image_step);
    test_step.dependOn(cli_step);

    const ci_step = b.step("ci", "Run default tests and cross-compilation checks");
    ci_step.dependOn(test_step);
    ci_step.dependOn(fault_step);
    ci_step.dependOn(cross_step);
}

fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    with_fuse: bool,
) *std.Build.Module {
    const core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.addIncludePath(b.path("vendor/littlefs"));
    core.addIncludePath(b.path("src"));
    core.addCMacro("LFS_THREADSAFE", "1");
    core.addCSourceFiles(.{
        .files = &.{
            "vendor/littlefs/lfs.c",
            "vendor/littlefs/lfs_util.c",
        },
        .flags = &.{ "-std=c99", "-DLFS_THREADSAFE" },
    });
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

fn configureSpdk(module: *std.Build.Module) void {
    module.addCSourceFiles(.{
        .files = &.{
            "src/spdk/runtime.c",
            "src/spdk/bdev_provider.c",
            "src/spdk/vhost_blk_controller.c",
        },
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    for ([_][]const u8{
        "spdk_event",
        "spdk_event_bdev",
        "spdk_event_vhost_blk",
        "spdk_bdev_modules",
        "spdk_env_dpdk",
        "spdk_sock_modules",
        "spdk_syslibs",
    }) |library| module.linkSystemLibrary(library, .{ .needed = true, .use_pkg_config = .force });
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
        .imports = &.{.{ .name = "zettide", .module = core }},
    });
    module.addIncludePath(b.path("src"));
    module.addIncludePath(b.path("test"));
    return b.addLibrary(.{
        .name = "zettide-spdk-storage-test",
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
