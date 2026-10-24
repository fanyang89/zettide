pub const storage = @import("zettide_storage");

pub const endpoint_registry = @import("endpoint_registry.zig");
pub const endpoint_control = if (@import("builtin").os.tag == .linux) @import("endpoint_control.zig") else struct {};
pub const endpoint_daemon = if (@import("builtin").os.tag == .linux) @import("endpoint_daemon.zig") else struct {};

pub const size = @import("size.zig");
pub const file_storage = @import("v3/file_storage.zig");
pub const linux_block_device = if (@import("builtin").os.tag == .linux) @import("v3/linux_block_device.zig") else struct {};

pub const spdk_catalog_endpoint_backend = if (@import("builtin").os.tag == .linux) @import("spdk/catalog_endpoint_backend.zig") else struct {};
pub const spdk_catalog_nvmf_export = if (@import("builtin").os.tag == .linux) @import("spdk/catalog_nvmf_export.zig") else struct {};
pub const spdk_catalog_volume_backend = if (@import("builtin").os.tag == .linux) @import("spdk/catalog_volume_backend.zig") else struct {};
pub const spdk_nvme_controller = if (@import("builtin").os.tag == .linux) @import("spdk/nvme_controller.zig") else struct {};
pub const spdk_nvmf_tcp_export = if (@import("builtin").os.tag == .linux) @import("spdk/nvmf_tcp_export.zig") else struct {};
pub const spdk_provider_bdev = if (@import("builtin").os.tag == .linux) @import("spdk/provider_bdev.zig") else struct {};
pub const spdk_runtime = if (@import("builtin").os.tag == .linux) @import("spdk/runtime.zig") else struct {};
pub const spdk_storage = if (@import("builtin").os.tag == .linux) @import("spdk/storage.zig") else struct {};

test {
    _ = endpoint_registry;
    _ = endpoint_control;
    _ = endpoint_daemon;
    _ = size;
    _ = file_storage;
    _ = linux_block_device;
    _ = spdk_catalog_endpoint_backend;
    _ = spdk_catalog_nvmf_export;
    _ = spdk_catalog_volume_backend;
    _ = spdk_nvme_controller;
    _ = spdk_nvmf_tcp_export;
    _ = spdk_provider_bdev;
    _ = spdk_storage;
}
