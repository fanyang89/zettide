const std = @import("std");
const volume = @import("volume.zig");

/// WinFsp integration boundary. The portable container and littlefs core already
/// cross-compile for Windows; the native dispatcher will be implemented here.
pub fn mount(vol: *volume.Volume, mountpoint: []const u8) !void {
    _ = vol;
    _ = mountpoint;
    return error.WinFspAdapterNotImplemented;
}

pub fn unmount(allocator: std.mem.Allocator, io: std.Io, mountpoint: []const u8) !void {
    _ = allocator;
    _ = io;
    _ = mountpoint;
    return error.WinFspAdapterNotImplemented;
}
