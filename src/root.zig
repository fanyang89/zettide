pub const block_device = @import("block_device.zig");
pub const container = @import("container.zig");
pub const metadata = @import("metadata.zig");
pub const object_format = @import("object_format.zig");
pub const object_store = @import("object_store.zig");
pub const size = @import("size.zig");
pub const spdk_nvme_controller = if (@import("builtin").os.tag == .linux) @import("spdk/nvme_controller.zig") else struct {};
pub const spdk_runtime = if (@import("builtin").os.tag == .linux) @import("spdk/runtime.zig") else struct {};
pub const spdk_storage = if (@import("builtin").os.tag == .linux) @import("spdk/storage.zig") else struct {};
pub const volume = @import("volume.zig");
pub const v3 = @import("v3/root.zig");
pub const linux_fuse = if (@import("builtin").os.tag == .linux) @import("linux_fuse.zig") else struct {};
pub const windows_winfsp = if (@import("builtin").os.tag == .windows) @import("windows_winfsp.zig") else struct {};

test {
    _ = block_device;
    _ = container;
    _ = metadata;
    _ = object_format;
    _ = object_store;
    _ = size;
    _ = spdk_nvme_controller;
    _ = spdk_runtime;
    _ = spdk_storage;
    _ = volume;
    _ = v3;
}
