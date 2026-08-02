const std = @import("std");
const builtin = @import("builtin");
const file_io_api = @import("file_io_api.zig");

const linux_file_io = if (builtin.os.tag == .linux) @import("linux_file_io.zig") else struct {};

pub const FileIo = file_io_api.FileIo;
pub const BorrowedFileIo = file_io_api.BorrowedFileIo;
pub const Kind = file_io_api.Kind;
pub const Write = file_io_api.Write;

pub const Mode = enum {
    auto,
    posix,
    io_uring,
};

pub fn init(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    mode: Mode,
) !FileIo {
    return switch (mode) {
        .posix => FileIo.posix(file),
        .io_uring => if (builtin.os.tag == .linux)
            linux_file_io.init(allocator, file)
        else
            error.UnsupportedIoBackend,
        .auto => if (builtin.os.tag == .linux)
            linux_file_io.init(allocator, file) catch |err|
                if (fallbackAllowed(err)) FileIo.posix(file) else return err
        else
            FileIo.posix(file),
    };
}

fn fallbackAllowed(err: anyerror) bool {
    return switch (err) {
        error.PermissionDenied,
        error.SystemOutdated,
        error.UnsupportedIoUringOperations,
        => true,
        else => false,
    };
}

test {
    _ = file_io_api;
    if (builtin.os.tag == .linux) _ = linux_file_io;
}

test "automatic file IO only falls back for unavailable io_uring" {
    try std.testing.expect(fallbackAllowed(error.PermissionDenied));
    try std.testing.expect(fallbackAllowed(error.SystemOutdated));
    try std.testing.expect(fallbackAllowed(error.UnsupportedIoUringOperations));
    try std.testing.expect(!fallbackAllowed(error.SystemResources));
    try std.testing.expect(!fallbackAllowed(error.ProcessFdQuotaExceeded));
}
