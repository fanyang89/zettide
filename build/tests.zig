const std = @import("std");
const storage_engine_build = @import("../libs/storage-engine/build.zig");
const support = @import("support.zig");

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
    const block_test_mode = b.option(BlockTestMode, "block-tests", "Linux block device tests: off, auto, or required") orelse .off;
    const cli_test_cmd = b.addSystemCommand(&.{ "bash", "tests/cli.sh" });
    cli_test_cmd.addArtifactArg(exe);
    const cli_step = b.step("test-cli", "Run local block CLI process tests");
    cli_step.dependOn(&cli_test_cmd.step);

    const linux_block_test_cmd = b.addSystemCommand(&.{ "bash", "tests/linux-block.sh" });
    linux_block_test_cmd.addArg(@tagName(block_test_mode));
    if (target.result.os.tag == .linux) {
        linux_block_test_cmd.addArtifactArg(support.createLinuxBlockProbe(b, target, optimize, storage_engine, data_node_module));
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

    const spdk_vhost_test = support.createSpdkVhostExportTest(b, target, optimize, storage_engine, data_node_module);
    const spdk_vhost_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-vhost-blk-controller.sh" });
    spdk_vhost_cmd.addArtifactArg(spdk_vhost_test);
    const spdk_vhost_step = b.step("test-spdk-vhost-blk-controller", "Run the SPDK vhost-blk controller test");
    spdk_vhost_step.dependOn(&spdk_vhost_cmd.step);

    const spdk_daemon_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-daemon.sh" });
    spdk_daemon_cmd.addArtifactArg(exe);
    const spdk_daemon_step = b.step("test-spdk-daemon", "Run the SPDK endpoint daemon lifecycle test");
    spdk_daemon_step.dependOn(&spdk_daemon_cmd.step);

    const spdk_storage_test = support.createSpdkStorageTest(b, target, optimize, storage_engine, data_node_module);
    const spdk_nvmf_test = support.createSpdkNvmfExportTest(b, target, optimize, storage_engine, data_node_module);
    const spdk_storage_cmd = b.addSystemCommand(&.{ "bash", "tests/spdk-storage.sh" });
    spdk_storage_cmd.addArtifactArg(spdk_storage_test);
    spdk_storage_cmd.addArtifactArg(spdk_nvmf_test);
    const spdk_storage_step = b.step("test-spdk-storage", "Run the Linux SPDK storage integration test");
    spdk_storage_step.dependOn(&spdk_storage_cmd.step);

    const spdk_compile_step = b.step("build-spdk-tests", "Compile SPDK adapter test libraries without a runtime");
    spdk_compile_step.dependOn(&spdk_storage_test.step);
    spdk_compile_step.dependOn(&spdk_nvmf_test.step);
    spdk_compile_step.dependOn(&spdk_vhost_test.step);

    const cross_step = b.step("test-cross", "Compile portable block boundaries for Windows and macOS");
    const windows_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const windows_modules = storage_engine_build.createPrivateModules(b, windows_target, optimize, "libs/storage-engine");
    const windows_core = support.createCoreModule(b, windows_target, optimize, windows_modules.storage, windows_modules.crc32c);
    cross_step.dependOn(&support.createExecutable(b, "zettide-windows-check", windows_target, optimize, windows_core, false).step);
    cross_step.dependOn(&support.createBlockFormatCrossTest(b, windows_target, optimize, windows_modules.storage).step);
    const macos_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const macos_modules = storage_engine_build.createPrivateModules(b, macos_target, optimize, "libs/storage-engine");
    cross_step.dependOn(&support.createBlockFormatCrossTest(b, macos_target, optimize, macos_modules.storage).step);

    return .{ .cli = cli_step, .cross = cross_step };
}
