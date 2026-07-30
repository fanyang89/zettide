const std = @import("std");
const storage_api = @import("storage.zig");

const File = std.Io.File;
const IoUring = std.os.linux.IoUring;
const linux = std.os.linux;

const queue_entries = 8;
const max_request_len = std.math.maxInt(u32);

pub const Identity = struct {
    major: u32,
    minor: u32,
    disk_sequence: u64,
};

const Context = struct {
    allocator: std.mem.Allocator,
    file: File,
    ring: IoUring,
    capacity_bytes: u64,
    identity: Identity,
    mutex: std.Io.Mutex = .init,
    next_token: u64 = 1,
    ring_active: bool = true,
};

pub fn initOwned(
    allocator: std.mem.Allocator,
    file: File,
    capacity_bytes: u64,
    minimum_io_size: u32,
    identity: Identity,
) !storage_api.Storage {
    var ring = try IoUring.init(queue_entries, 0);
    errdefer ring.deinit();

    const context = try allocator.create(Context);
    context.* = .{
        .allocator = allocator,
        .file = file,
        .ring = ring,
        .capacity_bytes = capacity_bytes,
        .identity = identity,
    };
    return storage_api.Storage.initBackend(
        context,
        &storage_vtable,
        capacity_bytes,
        .linux_block_device,
        minimum_io_size,
    );
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
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);

    try validateRange(context, offset, buffer.len);
    var index: usize = 0;
    while (index < buffer.len) {
        try requireActive(context);
        const token = nextToken(context);
        const request_len = @min(buffer.len - index, max_request_len);
        _ = context.ring.read(
            token,
            context.file.handle,
            .{ .buffer = buffer[index..][0..request_len] },
            offset + index,
        ) catch |err| {
            failRing(context);
            return err;
        };
        const amount = complete(context, token) catch |err| switch (err) {
            error.StorageOperationInterrupted => continue,
            else => return err,
        };
        if (amount == 0) break;
        if (amount > request_len) return invalidCompletion(context);
        index += amount;
    }
    return index;
}

fn writeAllAt(context_ptr: *anyopaque, io: std.Io, bytes: []const u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);

    try validateRange(context, offset, bytes.len);
    var index: usize = 0;
    while (index < bytes.len) {
        try requireActive(context);
        const token = nextToken(context);
        const request_len = @min(bytes.len - index, max_request_len);
        _ = context.ring.write(
            token,
            context.file.handle,
            bytes[index..][0..request_len],
            offset + index,
        ) catch |err| {
            failRing(context);
            return err;
        };
        const amount = complete(context, token) catch |err| switch (err) {
            error.StorageOperationInterrupted => continue,
            else => return err,
        };
        if (amount == 0 or amount > request_len) return invalidCompletion(context);
        index += amount;
    }
}

fn sync(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);

    while (true) {
        try requireActive(context);
        const token = nextToken(context);
        _ = context.ring.fsync(token, context.file.handle, 0) catch |err| {
            failRing(context);
            return err;
        };
        const result = complete(context, token) catch |err| switch (err) {
            error.StorageOperationInterrupted => continue,
            else => return err,
        };
        if (result != 0) return invalidCompletion(context);
        return;
    }
}

fn close(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lockUncancelable(io);

    if (context.ring_active) context.ring.deinit();
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

fn nextToken(context: *Context) u64 {
    const token = context.next_token;
    context.next_token +%= 1;
    if (context.next_token == 0) context.next_token = 1;
    return token;
}

fn requireActive(context: *const Context) !void {
    if (!context.ring_active) return error.StorageIo;
}

fn failRing(context: *Context) void {
    if (!context.ring_active) return;
    context.ring.deinit();
    context.ring_active = false;
}

fn invalidCompletion(context: *Context) error{InvalidStorageCompletion} {
    failRing(context);
    return error.InvalidStorageCompletion;
}

fn complete(context: *Context, token: u64) !usize {
    while (true) {
        _ = context.ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => {
                failRing(context);
                return err;
            },
        };
        break;
    }
    const completion = while (true) {
        break context.ring.copy_cqe() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => {
                failRing(context);
                return err;
            },
        };
    };
    if (completion.user_data != token) return invalidCompletion(context);
    if (completion.res < 0) return completionError(@enumFromInt(-completion.res));
    return @intCast(completion.res);
}

fn completionError(err: linux.E) anyerror {
    return switch (err) {
        .ACCES, .PERM, .ROFS => error.ReadOnlyStorage,
        .BADF => error.StorageClosed,
        .DQUOT, .FBIG, .NOSPC => error.StorageFull,
        .NODEV, .NXIO => error.StorageRemoved,
        .NOMEM, .NOBUFS, .AGAIN => error.SystemResources,
        .CANCELED => error.StorageOperationCanceled,
        .INTR => error.StorageOperationInterrupted,
        .INVAL => error.InvalidStorageIo,
        else => error.StorageIo,
    };
}

const storage_vtable: storage_api.Storage.VTable = .{
    .same_identity = sameIdentity,
    .read_at = readAt,
    .write_all_at = writeAllAt,
    .sync = sync,
    .close = close,
};

test "io_uring storage writes syncs and reads positional data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "uring-storage", .{ .read = true });
    var storage_owns_file = false;
    defer if (!storage_owns_file) file.close(std.testing.io);
    try file.setLength(std.testing.io, 4096);

    var storage = initOwned(
        std.testing.allocator,
        file,
        4096,
        512,
        .{ .major = 1, .minor = 2, .disk_sequence = 3 },
    ) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    storage_owns_file = true;
    var storage_open = true;
    defer if (storage_open) storage.close(std.testing.io) catch {};

    const expected = "io_uring storage";
    try storage.writeAllAt(std.testing.io, expected, 512);
    try storage.sync(std.testing.io);
    var actual: [expected.len]u8 = undefined;
    try std.testing.expectEqual(actual.len, try storage.readAt(std.testing.io, &actual, 512));
    try std.testing.expectEqualStrings(expected, &actual);
    try std.testing.expectError(
        error.StorageOutOfBounds,
        storage.readAt(std.testing.io, &actual, 4096),
    );
    try std.testing.expectError(
        error.StorageOutOfBounds,
        storage.writeAllAt(std.testing.io, expected, 4096),
    );
    try storage.writeAllAt(std.testing.io, "", 4096);

    try storage.close(std.testing.io);
    storage_open = false;
    const reopened = try tmp.dir.openFile(std.testing.io, "uring-storage", .{ .mode = .read_only });
    defer reopened.close(std.testing.io);
    @memset(&actual, 0);
    try std.testing.expectEqual(actual.len, try reopened.readPositionalAll(std.testing.io, &actual, 512));
    try std.testing.expectEqualStrings(expected, &actual);
}

test "io_uring storage maps completion errors" {
    try std.testing.expectEqual(error.ReadOnlyStorage, completionError(.ROFS));
    try std.testing.expectEqual(error.StorageClosed, completionError(.BADF));
    try std.testing.expectEqual(error.StorageFull, completionError(.NOSPC));
    try std.testing.expectEqual(error.StorageRemoved, completionError(.NODEV));
    try std.testing.expectEqual(error.SystemResources, completionError(.NOMEM));
    try std.testing.expectEqual(error.StorageOperationCanceled, completionError(.CANCELED));
    try std.testing.expectEqual(error.StorageOperationInterrupted, completionError(.INTR));
    try std.testing.expectEqual(error.InvalidStorageIo, completionError(.INVAL));
    try std.testing.expectEqual(error.StorageIo, completionError(.IO));
}
