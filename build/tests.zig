const std = @import("std");
const storage_engine_build = @import("../libs/storage-engine/build.zig");
const support = @import("support.zig");

const FuseTestMode = enum { off, auto, required };
const Smb3TestMode = enum { off, auto, required };
const NfsGaneshaTestMode = enum { off, auto, required };
const ExternalTestMode = enum { off, auto, required };
const PrivilegedTestMode = enum { off, auto, required };
const BlockTestMode = enum { off, auto, required };

pub const Result = struct {
    cli: *std.Build.Step,
    cross: *std.Build.Step,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    storage_engine: *std.Build.Module,
    data_node_module: *std.Build.Module,
    exe: *std.Build.Step.Compile,
) Result {
    const fuse_test_mode = b.option(FuseTestMode, "fuse-tests", "FUSE tests: off, auto, or required") orelse .auto;
    const smb3_test_mode = b.option(Smb3TestMode, "smb3-tests", "Linux SMB3 tests: off, auto, or required") orelse .auto;
    const nfs_ganesha_test_mode = b.option(NfsGaneshaTestMode, "nfs-ganesha-tests", "NFS-Ganesha tests: off, auto, or required") orelse .auto;
    const ganesha_build_dir = b.option([]const u8, "ganesha-build-dir", "Configured NFS-Ganesha V13 build directory");
    const external_test_mode = b.option(ExternalTestMode, "external-tests", "External tests: off, auto, or required") orelse .auto;
    const privileged_test_mode = b.option(PrivilegedTestMode, "privileged-tests", "Privileged tests: off, auto, or required") orelse .auto;
    const block_test_mode = b.option(BlockTestMode, "block-tests", "Linux block device tests: off, auto, or required") orelse .off;

    const cli_test_cmd = b.addSystemCommand(&.{ "bash", "tests/cli.sh" });
    cli_test_cmd.addArtifactArg(exe);
    const cli_step = b.step("test-cli", "Run CLI process integration tests");
    cli_step.dependOn(&cli_test_cmd.step);

    const linux_block_probe = if (target.result.os.tag == .linux)
        support.createLinuxBlockProbe(b, target, optimize, storage_engine, data_node_module)
    else
        null;
    const linux_block_test_cmd = b.addSystemCommand(&.{ "bash", "tests/linux-block.sh" });
    linux_block_test_cmd.addArg(@tagName(block_test_mode));
    if (linux_block_probe) |artifact| {
        linux_block_test_cmd.addArtifactArg(artifact);
        linux_block_test_cmd.addArtifactArg(exe);
    }
    const linux_block_step = b.step("test-linux-block", "Run Linux loop block device tests");
    linux_block_step.dependOn(&linux_block_test_cmd.step);

    const spdk_link_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-link.sh" });
    const spdk_link_step = b.step("test-spdk-link", "Run the Linux SPDK link check");
    spdk_link_step.dependOn(&spdk_link_cmd.step);

    const spdk_endpoint_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-endpoint.sh" });
    const spdk_endpoint_step = b.step("test-spdk-endpoint", "Run the Linux SPDK bdev endpoint test");
    spdk_endpoint_step.dependOn(&spdk_endpoint_cmd.step);

    const spdk_dispatcher_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-dispatcher.sh" });
    const spdk_dispatcher_step = b.step("test-spdk-dispatcher", "Run the Linux SPDK dispatcher test");
    spdk_dispatcher_step.dependOn(&spdk_dispatcher_cmd.step);

    const spdk_provider_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-provider.sh" });
    const spdk_provider_step = b.step("test-spdk-provider", "Run the asynchronous SPDK bdev provider test");
    spdk_provider_step.dependOn(&spdk_provider_cmd.step);

    const spdk_vhost_export_test = support.createSpdkVhostExportTest(b, target, optimize, storage_engine, data_node_module);
    const spdk_vhost_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-vhost-blk-controller.sh" });
    spdk_vhost_cmd.addArtifactArg(spdk_vhost_export_test);
    const spdk_vhost_step = b.step("test-spdk-vhost-blk-controller", "Run the SPDK vhost-blk controller test");
    spdk_vhost_step.dependOn(&spdk_vhost_cmd.step);

    const spdk_daemon_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-daemon.sh" });
    spdk_daemon_cmd.addArtifactArg(exe);
    const spdk_daemon_step = b.step("test-spdk-daemon", "Run the SPDK endpoint daemon lifecycle test");
    spdk_daemon_step.dependOn(&spdk_daemon_cmd.step);

    const spdk_storage_test = support.createSpdkStorageTest(b, target, optimize, storage_engine, data_node_module);
    const spdk_nvmf_export_test = support.createSpdkNvmfExportTest(b, target, optimize, storage_engine, data_node_module);
    const spdk_storage_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-storage.sh" });
    spdk_storage_cmd.addArtifactArg(spdk_storage_test);
    spdk_storage_cmd.addArtifactArg(spdk_nvmf_export_test);
    const spdk_storage_step = b.step("test-spdk-storage", "Run the Linux SPDK storage integration test");
    spdk_storage_step.dependOn(&spdk_storage_cmd.step);

    const probe = if (target.result.os.tag == .linux) support.createFsProbe(b, target, optimize) else null;
    const durability_probe = if (target.result.os.tag == .linux) support.createDurabilityProbe(b, target, optimize) else null;
    const fuse_test_cmd = b.addSystemCommand(&.{ "bash", "tests/fuse.sh" });
    fuse_test_cmd.addArg(@tagName(fuse_test_mode));
    fuse_test_cmd.addArtifactArg(exe);
    if (probe) |artifact| fuse_test_cmd.addArtifactArg(artifact);
    if (durability_probe) |artifact| fuse_test_cmd.addArtifactArg(artifact);
    const fuse_step = b.step("test-fuse", "Run real Linux FUSE syscall tests");
    fuse_step.dependOn(&fuse_test_cmd.step);

    const dufs_test_cmd = b.addSystemCommand(&.{ "bash", "tests/dufs.sh" });
    dufs_test_cmd.addArg(@tagName(fuse_test_mode));
    dufs_test_cmd.addArtifactArg(exe);
    if (target.result.os.tag == .linux) dufs_test_cmd.addArtifactArg(support.createSignalMaskExec(b, target, optimize));
    const dufs_step = b.step("test-dufs", "Run the managed dufs integration test");
    dufs_step.dependOn(&dufs_test_cmd.step);

    const host_target = b.graph.host.result;
    const smb3_native_target = target.result.os.tag == .linux and
        host_target.os.tag == .linux and
        target.result.cpu.arch == host_target.cpu.arch and
        target.result.abi == host_target.abi;
    const smb3_test_cmd = b.addSystemCommand(&.{ "bash", "tests/smb3-linux.sh" });
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

    const nfs_ganesha_test_cmd = b.addSystemCommand(&.{ "bash", "tests/nfs-ganesha.sh" });
    nfs_ganesha_test_cmd.addArg(@tagName(nfs_ganesha_test_mode));
    nfs_ganesha_test_cmd.addArtifactArg(exe);
    nfs_ganesha_test_cmd.addArg(if (smb3_native_target) "native" else "cross");
    nfs_ganesha_test_cmd.addArg(ganesha_build_dir orelse "-");
    nfs_ganesha_test_cmd.step.dependOn(b.getInstallStep());
    const nfs_ganesha_step = b.step("test-nfs-ganesha", "Run the NFSv3 Ganesha RPC integration test");
    nfs_ganesha_step.dependOn(&nfs_ganesha_test_cmd.step);

    const posix_probe = if (target.result.os.tag == .linux) support.createPosixProbe(b, target, optimize) else null;
    const posix_test_cmd = b.addSystemCommand(&.{ "bash", "tests/posix.sh" });
    posix_test_cmd.addArg(@tagName(fuse_test_mode));
    posix_test_cmd.addArtifactArg(exe);
    if (posix_probe) |artifact| posix_test_cmd.addArtifactArg(artifact);
    const posix_step = b.step("test-posix-baseline", "Run the POSIX filesystem baseline");
    posix_step.dependOn(&posix_test_cmd.step);

    const libfuse_probe = if (target.result.os.tag == .linux) support.createLibfuseProbe(b, target, optimize) else null;
    const libfuse_test_cmd = b.addSystemCommand(&.{ "bash", "tests/external/libfuse.sh" });
    libfuse_test_cmd.addArg(@tagName(external_test_mode));
    libfuse_test_cmd.addArtifactArg(exe);
    if (libfuse_probe) |artifact| libfuse_test_cmd.addArtifactArg(artifact);
    const libfuse_step = b.step("test-libfuse", "Run vendored libfuse syscall tests");
    libfuse_step.dependOn(&libfuse_test_cmd.step);

    const fsx_probe = if (target.result.os.tag == .linux) support.createFsxProbe(b, target, optimize) else null;
    const fsx_test_cmd = b.addSystemCommand(&.{ "bash", "tests/external/fsx.sh" });
    fsx_test_cmd.addArg(@tagName(external_test_mode));
    fsx_test_cmd.addArtifactArg(exe);
    if (fsx_probe) |artifact| fsx_test_cmd.addArtifactArg(artifact);
    const fsx_step = b.step("test-fsx", "Run vendored fsx with deterministic seeds");
    fsx_step.dependOn(&fsx_test_cmd.step);

    const fio_test_cmd = b.addSystemCommand(&.{ "bash", "tests/external/fio-verify.sh" });
    fio_test_cmd.addArg(@tagName(external_test_mode));
    fio_test_cmd.addArtifactArg(exe);
    const fio_step = b.step("test-fio", "Verify file data before and after a clean remount with fio");
    fio_step.dependOn(&fio_test_cmd.step);

    const fio_throughput_cmd = b.addSystemCommand(&.{ "bash", "tests/external/fio-throughput.sh" });
    fio_throughput_cmd.addArg(@tagName(external_test_mode));
    fio_throughput_cmd.addArtifactArg(exe);
    const fio_throughput_step = b.step("test-fio-throughput", "Measure host and Zettide sequential throughput");
    fio_throughput_step.dependOn(&fio_throughput_cmd.step);

    const external_step = b.step("test-external", "Run vendored external filesystem tests");
    external_step.dependOn(libfuse_step);
    external_step.dependOn(fsx_step);

    const permission_probe = if (target.result.os.tag == .linux) support.createPermissionProbe(b, target, optimize) else null;
    const permission_test_cmd = b.addSystemCommand(&.{ "bash", "tests/conformance/permissions.sh" });
    permission_test_cmd.addArg(@tagName(privileged_test_mode));
    permission_test_cmd.addArtifactArg(exe);
    if (permission_probe) |artifact| permission_test_cmd.addArtifactArg(artifact);
    const permission_step = b.step("test-permissions", "Run the privileged permission matrix");
    permission_step.dependOn(&permission_test_cmd.step);

    const pjdfstest_cmd = b.addSystemCommand(&.{ "bash", "tests/external/pjdfstest.sh" });
    pjdfstest_cmd.addArg(@tagName(privileged_test_mode));
    pjdfstest_cmd.addArtifactArg(exe);
    const pjdfstest_step = b.step("test-pjdfstest", "Run selected pjdfstest POSIX cases");
    pjdfstest_step.dependOn(&pjdfstest_cmd.step);

    const xfstests_cmd = b.addSystemCommand(&.{ "bash", "tests/external/xfstests.sh" });
    xfstests_cmd.addArg(@tagName(external_test_mode));
    xfstests_cmd.addArtifactArg(exe);
    const xfstests_step = b.step("test-xfstests", "Run selected xfstests mmap and lock cases");
    xfstests_step.dependOn(&xfstests_cmd.step);

    const ltp_cmd = b.addSystemCommand(&.{ "bash", "tests/external/ltp-open-posix.sh" });
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
    const windows_storage_modules = storage_engine_build.createPrivateModules(
        b,
        windows_target,
        optimize,
        "libs/storage-engine",
        "vendor/utf8proc",
    );
    const windows_storage = windows_storage_modules.storage;
    const windows_core = support.createCoreModule(
        b,
        windows_target,
        optimize,
        false,
        windows_storage,
        windows_storage_modules.crc32c,
    );
    const windows_exe = support.createExecutable(b, "zettide-windows-check", windows_target, optimize, windows_core, false);
    const windows_name_tests = support.createNameProfileCrossTest(b, windows_target, optimize, windows_storage);
    const macos_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const macos_storage_modules = storage_engine_build.createPrivateModules(
        b,
        macos_target,
        optimize,
        "libs/storage-engine",
        "vendor/utf8proc",
    );
    const macos_storage = macos_storage_modules.storage;
    const macos_name_tests = support.createNameProfileCrossTest(b, macos_target, optimize, macos_storage);
    cross_step.dependOn(&windows_exe.step);
    cross_step.dependOn(&windows_name_tests.step);
    cross_step.dependOn(&macos_name_tests.step);

    return .{
        .cli = cli_step,
        .cross = cross_step,
    };
}
