const std = @import("std");
const linux_io_uring = @import("../linux_io_uring.zig");
const storage_api = @import("storage.zig");

const File = std.Io.File;

const Context = struct {
    allocator: std.mem.Allocator,
    file: File,
    writable: bool,
    unlock_on_close: bool,
    engine: linux_io_uring.Engine,
    mutex: std.Io.Mutex = .init,
};

pub fn initOwned(
    allocator: std.mem.Allocator,
    file: File,
    capacity_bytes: u64,
    writable: bool,
    unlock_on_close: bool,
) !storage_api.Storage {
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .file = file,
        .writable = writable,
        .unlock_on_close = unlock_on_close,
        .engine = try .init(file.handle),
    };
    return storage_api.Storage.initBackend(context, &storage_vtable, capacity_bytes, .regular_file, 1);
}

fn sameIdentity(context_ptr: *anyopaque, other_context_ptr: *anyopaque) bool {
    return context_ptr == other_context_ptr;
}

fn readAt(context_ptr: *anyopaque, io: std.Io, buffer: []u8, offset: u64) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    return context.engine.readAt(io, buffer, offset);
}

fn readManyAt(
    context_ptr: *anyopaque,
    io: std.Io,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    try context.engine.readManyAt(io, reads, results);
}

fn writeAllAt(context_ptr: *anyopaque, io: std.Io, bytes: []const u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    if (!context.writable) return error.NotOpenForWriting;
    try context.engine.writeAllAt(io, bytes, offset);
}

fn writeAllManyAt(context_ptr: *anyopaque, io: std.Io, writes: []const storage_api.Write) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    if (!context.writable) return error.NotOpenForWriting;
    try context.engine.writeAllManyAt(io, writes);
}

fn syncData(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    try context.engine.sync(io, .data);
}

fn sync(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    try context.engine.sync(io, .full);
}

fn transportKind(_: *anyopaque) storage_api.TransportKind {
    return .io_uring;
}

fn transportStats(context_ptr: *anyopaque, io: std.Io) storage_api.TransportStats {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const stats = context.engine.getStats(io);
    return .{
        .queue_capacity = stats.queue_capacity,
        .submitted_sqes = stats.submitted_sqes,
        .submit_calls = stats.submit_calls,
        .completions = stats.completions,
        .current_inflight = stats.current_inflight,
        .max_inflight = stats.max_inflight,
    };
}

fn resetTransportStats(context_ptr: *anyopaque, io: std.Io) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.engine.resetStats(io);
}

fn close(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lockUncancelable(io);
    context.engine.deinit();
    if (context.unlock_on_close) context.file.unlock(io);
    context.file.close(io);
    const allocator = context.allocator;
    context.mutex.unlock(io);
    allocator.destroy(context);
}

const storage_vtable: storage_api.Storage.VTable = .{
    .same_identity = sameIdentity,
    .read_at = readAt,
    .read_many_at = readManyAt,
    .write_all_at = writeAllAt,
    .write_all_many_at = writeAllManyAt,
    .sync_data = syncData,
    .sync = sync,
    .close = close,
    .transport_kind = transportKind,
    .transport_stats = transportStats,
    .reset_transport_stats = resetTransportStats,
};

test "regular file io_uring storage batches reads and writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "uring-storage", .{ .read = true });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    try file.setLength(std.testing.io, 256 * 1024);
    var storage = initOwned(std.testing.allocator, file, 256 * 1024, true, false) catch |err| switch (err) {
        error.ArgumentsInvalid,
        error.PermissionDenied,
        error.SystemOutdated,
        error.UnsupportedIoUringOperations,
        => return error.SkipZigTest,
        else => return err,
    };
    file_open = false;
    defer storage.close(std.testing.io) catch {};

    var bytes: [linux_io_uring.queue_entries][4096]u8 align(4096) = undefined;
    var writes: [bytes.len]storage_api.Write = undefined;
    for (&bytes, &writes, 0..) |*buffer, *write, index| {
        @memset(buffer, @intCast(index));
        write.* = .{ .bytes = buffer, .offset = index * 4096 };
    }
    storage.resetTransportStats(std.testing.io);
    try storage.writeAllManyAt(std.testing.io, &writes);
    const write_stats = storage.transportStats(std.testing.io);
    try std.testing.expectEqual(storage_api.TransportKind.io_uring, storage.transportKind());
    try std.testing.expect(write_stats.submitted_sqes == 1 or
        write_stats.submitted_sqes == linux_io_uring.queue_entries or
        write_stats.submitted_sqes == linux_io_uring.queue_entries + 1);
    const expected_write_inflight: u64 = if (write_stats.submitted_sqes == linux_io_uring.queue_entries)
        linux_io_uring.queue_entries
    else
        1;
    try std.testing.expectEqual(expected_write_inflight, write_stats.max_inflight);
    try std.testing.expectEqual(write_stats.submitted_sqes, write_stats.completions);
    try std.testing.expectEqual(@as(u64, 0), write_stats.current_inflight);
    try storage.syncData(std.testing.io);

    var actual: [linux_io_uring.queue_entries][4096]u8 align(4096) = undefined;
    var reads: [actual.len]storage_api.Read = undefined;
    var results: [actual.len]storage_api.ReadResult = undefined;
    for (&actual, &reads, 0..) |*buffer, *read, index|
        read.* = .{ .buffer = buffer, .offset = index * 4096 };
    storage.resetTransportStats(std.testing.io);
    try storage.readManyAt(std.testing.io, &reads, &results);
    const read_stats = storage.transportStats(std.testing.io);
    try std.testing.expectEqual(@as(u64, linux_io_uring.queue_entries), read_stats.max_inflight);
    try std.testing.expectEqual(read_stats.submitted_sqes, read_stats.completions);
    for (&actual, results, 0..) |*buffer, result, index| {
        try std.testing.expectEqual(@as(usize, 4096), result.amount);
        try std.testing.expectEqual(@as(?anyerror, null), result.failure);
        try std.testing.expect(std.mem.allEqual(u8, buffer, @intCast(index)));
    }
}
