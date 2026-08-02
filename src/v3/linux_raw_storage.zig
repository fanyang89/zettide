const std = @import("std");
const linux_io_uring = @import("../linux_io_uring.zig");
const storage_api = @import("storage.zig");

const File = std.Io.File;

pub const Mode = enum {
    auto,
    posix,
    io_uring,
};

pub const Identity = struct {
    major: u32,
    minor: u32,
    disk_sequence: u64,
};

const Context = struct {
    allocator: std.mem.Allocator,
    file: File,
    capacity_bytes: u64,
    identity: Identity,
    writable: bool,
    engine: ?linux_io_uring.Engine,
    mutex: std.Io.Mutex = .init,
};

pub fn initOwned(
    allocator: std.mem.Allocator,
    file: File,
    capacity_bytes: u64,
    minimum_io_size: u32,
    identity: Identity,
    writable: bool,
    mode: Mode,
) !storage_api.Storage {
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .file = file,
        .capacity_bytes = capacity_bytes,
        .identity = identity,
        .writable = writable,
        .engine = switch (mode) {
            .posix => null,
            .io_uring => try .init(file.handle),
            .auto => linux_io_uring.Engine.init(file.handle) catch |err|
                if (shouldFallback(mode, err)) null else return err,
        },
    };
    return storage_api.Storage.initBackend(
        context,
        &storage_vtable,
        capacity_bytes,
        .linux_block_device,
        minimum_io_size,
    );
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

fn shouldFallback(mode: Mode, err: anyerror) bool {
    return mode == .auto and fallbackAllowed(err);
}

fn sameIdentity(context_ptr: *anyopaque, other_context_ptr: *anyopaque) bool {
    const context: *const Context = @ptrCast(@alignCast(context_ptr));
    const other: *const Context = @ptrCast(@alignCast(other_context_ptr));
    return context.identity.major == other.identity.major and
        context.identity.minor == other.identity.minor and
        context.identity.disk_sequence == other.identity.disk_sequence;
}

fn readAt(context_ptr: *anyopaque, io: std.Io, buffer: []u8, offset: u64) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lock(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlock(io);
    try validateRange(context, offset, buffer.len);

    return if (context.engine) |*engine|
        engine.readAt(io, buffer, offset) catch |err| return mapOperationError(err)
    else
        context.file.readPositionalAll(io, buffer, offset) catch |err| return mapOperationError(err);
}

fn writeAllAt(context_ptr: *anyopaque, io: std.Io, bytes: []const u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lock(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlock(io);
    try validateRange(context, offset, bytes.len);
    if (!context.writable) return error.ReadOnlyStorage;

    if (context.engine) |*engine|
        engine.writeAllAt(io, bytes, offset) catch |err| return mapOperationError(err)
    else
        context.file.writePositionalAll(io, bytes, offset) catch |err| return mapOperationError(err);
}

fn sync(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lock(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlock(io);

    if (context.engine) |*engine|
        engine.sync(io, .full) catch |err| return mapOperationError(err)
    else
        context.file.sync(io) catch |err| return mapOperationError(err);
}

fn close(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lockUncancelable(io);
    if (context.engine) |*engine| engine.deinit();
    context.file.close(io);
    const allocator = context.allocator;
    context.mutex.unlock(io);
    allocator.destroy(context);
}

fn validateRange(context: *const Context, offset: u64, len: usize) !void {
    const length = std.math.cast(u64, len) orelse return error.StorageOutOfBounds;
    if (offset > context.capacity_bytes or length > context.capacity_bytes - offset)
        return error.StorageOutOfBounds;
}

fn mapOperationError(err: anyerror) anyerror {
    return switch (err) {
        error.ReadOnlyFileSystem, error.AccessDenied, error.PermissionDenied, error.NotOpenForWriting => error.ReadOnlyStorage,
        error.FileClosed, error.NotOpenForReading => error.StorageClosed,
        error.NoSpaceLeft, error.FileTooBig, error.DiskQuota => error.StorageFull,
        error.DeviceUnavailable, error.NoDevice => error.StorageRemoved,
        error.OperationCanceled, error.Canceled => error.StorageOperationCanceled,
        error.OperationInterrupted => error.StorageOperationInterrupted,
        error.InvalidIo, error.Unseekable, error.IsDir => error.InvalidStorageIo,
        error.InvalidIoUringCompletion => error.InvalidStorageCompletion,
        error.WouldBlock => error.SystemResources,
        error.InputOutput,
        error.Unexpected,
        error.DeviceBusy,
        error.BrokenPipe,
        error.LockViolation,
        error.FileBusy,
        error.IoUringCompletion,
        error.IoUringFailed,
        error.IncompleteIoUringSubmission,
        => error.StorageIo,
        else => err,
    };
}

const storage_vtable: storage_api.Storage.VTable = .{
    .same_identity = sameIdentity,
    .read_at = readAt,
    .write_all_at = writeAllAt,
    .sync = sync,
    .close = close,
};

test "automatic raw transport only falls back when io_uring is unavailable" {
    try std.testing.expect(shouldFallback(.auto, error.PermissionDenied));
    try std.testing.expect(shouldFallback(.auto, error.SystemOutdated));
    try std.testing.expect(shouldFallback(.auto, error.UnsupportedIoUringOperations));
    try std.testing.expect(shouldFallback(.auto, error.ArgumentsInvalid));
    try std.testing.expect(!shouldFallback(.io_uring, error.PermissionDenied));
    try std.testing.expect(!shouldFallback(.posix, error.PermissionDenied));
    try std.testing.expect(!shouldFallback(.auto, error.SystemResources));
    try std.testing.expect(!shouldFallback(.auto, error.ProcessFdQuotaExceeded));
    try std.testing.expect(!shouldFallback(.auto, error.StorageIo));
    try std.testing.expect(!shouldFallback(.auto, error.InvalidStorageCompletion));
}

test "forced POSIX raw storage preserves identity and bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "posix-raw-storage", .{ .read = true });
    var storage_owns_file = false;
    defer if (!storage_owns_file) file.close(std.testing.io);
    try file.setLength(std.testing.io, 4096);

    const identity: Identity = .{ .major = 1, .minor = 2, .disk_sequence = 3 };
    var storage = try initOwned(std.testing.allocator, file, 4096, 512, identity, true, .posix);
    storage_owns_file = true;
    var storage_open = true;
    defer if (storage_open) storage.close(std.testing.io) catch {};

    const alias_file = try tmp.dir.openFile(std.testing.io, "posix-raw-storage", .{ .mode = .read_only });
    var alias_owns_file = false;
    defer if (!alias_owns_file) alias_file.close(std.testing.io);
    var alias = try initOwned(std.testing.allocator, alias_file, 4096, 512, identity, false, .posix);
    alias_owns_file = true;
    defer alias.close(std.testing.io) catch {};
    try std.testing.expect(storage.sameIdentity(&alias));
    try std.testing.expectEqual(storage_api.Kind.linux_block_device, storage.kind);
    try std.testing.expectError(error.ReadOnlyStorage, alias.writeAllAt(std.testing.io, "denied", 0));

    const expected = "POSIX raw storage";
    try storage.writeAllAt(std.testing.io, expected, 512);
    try storage.sync(std.testing.io);
    var actual: [expected.len]u8 = undefined;
    try std.testing.expectEqual(actual.len, try storage.readAt(std.testing.io, &actual, 512));
    try std.testing.expectEqualStrings(expected, &actual);
    try std.testing.expectError(error.StorageOutOfBounds, storage.readAt(std.testing.io, &actual, 4096));
    try std.testing.expectError(error.StorageOutOfBounds, storage.writeAllAt(std.testing.io, expected, 4096));
    try storage.writeAllAt(std.testing.io, "", 4096);

    try storage.close(std.testing.io);
    storage_open = false;
}

test "forced io_uring raw storage uses shared engine when available" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "uring-raw-storage", .{ .read = true });
    var storage_owns_file = false;
    defer if (!storage_owns_file) file.close(std.testing.io);
    try file.setLength(std.testing.io, 4096);

    var storage = initOwned(
        std.testing.allocator,
        file,
        4096,
        512,
        .{ .major = 1, .minor = 2, .disk_sequence = 3 },
        true,
        .io_uring,
    ) catch |err| switch (err) {
        error.ArgumentsInvalid,
        error.PermissionDenied,
        error.SystemOutdated,
        error.UnsupportedIoUringOperations,
        => return error.SkipZigTest,
        else => return err,
    };
    storage_owns_file = true;
    var storage_open = true;
    defer if (storage_open) storage.close(std.testing.io) catch {};

    const expected = "io_uring raw storage";
    try storage.writeAllAt(std.testing.io, expected, 512);
    try storage.sync(std.testing.io);
    var actual: [expected.len]u8 = undefined;
    try std.testing.expectEqual(actual.len, try storage.readAt(std.testing.io, &actual, 512));
    try std.testing.expectEqualStrings(expected, &actual);

    try storage.close(std.testing.io);
    storage_open = false;
    const reopened = try tmp.dir.openFile(std.testing.io, "uring-raw-storage", .{ .mode = .read_only });
    defer reopened.close(std.testing.io);
    @memset(&actual, 0);
    try std.testing.expectEqual(actual.len, try reopened.readPositionalAll(std.testing.io, &actual, 512));
    try std.testing.expectEqualStrings(expected, &actual);
}

test "raw storage maps shared engine errors" {
    try std.testing.expectEqual(error.ReadOnlyStorage, mapOperationError(error.ReadOnlyFileSystem));
    try std.testing.expectEqual(error.ReadOnlyStorage, mapOperationError(error.NotOpenForWriting));
    try std.testing.expectEqual(error.StorageClosed, mapOperationError(error.FileClosed));
    try std.testing.expectEqual(error.StorageFull, mapOperationError(error.NoSpaceLeft));
    try std.testing.expectEqual(error.StorageRemoved, mapOperationError(error.DeviceUnavailable));
    try std.testing.expectEqual(error.StorageOperationCanceled, mapOperationError(error.OperationCanceled));
    try std.testing.expectEqual(error.StorageOperationInterrupted, mapOperationError(error.OperationInterrupted));
    try std.testing.expectEqual(error.InvalidStorageIo, mapOperationError(error.InvalidIo));
    try std.testing.expectEqual(error.InvalidStorageCompletion, mapOperationError(error.InvalidIoUringCompletion));
    try std.testing.expectEqual(error.StorageIo, mapOperationError(error.IoUringCompletion));
}
