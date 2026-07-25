pub const block_device = @import("block_device.zig");
pub const container = @import("container.zig");
pub const metadata = @import("metadata.zig");
pub const size = @import("size.zig");
pub const volume = @import("volume.zig");
pub const linux_fuse = if (@import("builtin").os.tag == .linux) @import("linux_fuse.zig") else struct {};
pub const windows_winfsp = if (@import("builtin").os.tag == .windows) @import("windows_winfsp.zig") else struct {};

test {
    _ = block_device;
    _ = container;
    _ = metadata;
    _ = size;
    _ = volume;
}
