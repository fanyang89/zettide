const std = @import("std");
const builtin = @import("builtin");
const storage_api = @import("storage.zig");

const linux_file_storage = if (builtin.os.tag == .linux) @import("linux_file_storage.zig") else struct {};

pub const Mode = enum {
    auto,
    posix,
    io_uring,

    pub fn parse(value: []const u8) !Mode {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "posix")) return .posix;
        if (std.mem.eql(u8, value, "io_uring")) return .io_uring;
        return error.InvalidFileStorageMode;
    }
};

pub fn createFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    capacity_bytes: u64,
    mode: Mode,
) !storage_api.Storage {
    const file = try parent.createFile(io, basename, .{
        .read = true,
        .exclusive = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    errdefer {
        file.unlock(io);
        file.close(io);
    }
    try file.setLength(io, capacity_bytes);
    return initOwned(allocator, file, capacity_bytes, true, true, mode);
}

pub fn openFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    writable: bool,
    mode: Mode,
) !storage_api.Storage {
    const file = try parent.openFile(io, basename, .{
        .mode = if (writable) .read_write else .read_only,
        .lock = if (writable) .exclusive else .shared,
        .lock_nonblocking = true,
    });
    errdefer {
        file.unlock(io);
        file.close(io);
    }
    return initOwned(allocator, file, try file.length(io), writable, true, mode);
}

pub fn initOwned(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    capacity_bytes: u64,
    writable: bool,
    unlock_on_close: bool,
    mode: Mode,
) !storage_api.Storage {
    return switch (mode) {
        .posix => storage_api.Storage.initOwned(file, capacity_bytes, .regular_file, 1, unlock_on_close),
        .io_uring => if (builtin.os.tag == .linux)
            linux_file_storage.initOwned(allocator, file, capacity_bytes, writable, unlock_on_close)
        else
            error.UnsupportedIoBackend,
        .auto => if (builtin.os.tag == .linux)
            linux_file_storage.initOwned(allocator, file, capacity_bytes, writable, unlock_on_close) catch |err|
                if (fallbackAllowed(err))
                    storage_api.Storage.initOwned(file, capacity_bytes, .regular_file, 1, unlock_on_close)
                else
                    return err
        else
            storage_api.Storage.initOwned(file, capacity_bytes, .regular_file, 1, unlock_on_close),
    };
}

fn fallbackAllowed(err: anyerror) bool {
    return switch (err) {
        error.ArgumentsInvalid,
        error.PermissionDenied,
        error.SystemOutdated,
        error.UnsupportedIoUringOperations,
        => true,
        else => false,
    };
}

test "regular file storage mode parsing and fallback policy" {
    try std.testing.expectEqual(Mode.auto, try Mode.parse("auto"));
    try std.testing.expectEqual(Mode.posix, try Mode.parse("posix"));
    try std.testing.expectEqual(Mode.io_uring, try Mode.parse("io_uring"));
    try std.testing.expectError(error.InvalidFileStorageMode, Mode.parse("other"));
    try std.testing.expect(fallbackAllowed(error.PermissionDenied));
    try std.testing.expect(fallbackAllowed(error.SystemOutdated));
    try std.testing.expect(!fallbackAllowed(error.SystemResources));
    try std.testing.expect(!fallbackAllowed(error.IoUringFailed));
}

test "forced POSIX regular file storage preserves native backend" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "posix-storage", .{ .read = true });
    try file.setLength(std.testing.io, 4096);
    var storage = try initOwned(std.testing.allocator, file, 4096, true, false, .posix);
    defer storage.close(std.testing.io) catch {};
    try std.testing.expectEqual(storage_api.TransportKind.posix, storage.transportKind());
}

test {
    if (builtin.os.tag == .linux) _ = linux_file_storage;
}
