const std = @import("std");
const file_io_api = @import("file_io_api.zig");
const linux_io_uring = @import("linux_io_uring.zig");

const Io = std.Io;
const File = Io.File;

const Context = struct {
    allocator: std.mem.Allocator,
    writeback: linux_io_uring.Engine,
};

pub fn init(allocator: std.mem.Allocator, file: File) !file_io_api.FileIo {
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .writeback = try .init(file.handle),
    };
    return .{
        .file = file,
        .context = context,
        .vtable = &vtable,
        .kind = .io_uring,
    };
}

fn readAllAt(raw: ?*anyopaque, file: File, io: Io, lane: file_io_api.Lane, buffer: []u8, offset: u64) !void {
    if (lane == .foreground) {
        const amount = try file.readPositionalAll(io, buffer, offset);
        if (amount != buffer.len) return error.UnexpectedEndOfFile;
        return;
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try context.writeback.readAllAt(io, buffer, offset);
}

fn writeAllAt(raw: ?*anyopaque, file: File, io: Io, lane: file_io_api.Lane, bytes: []const u8, offset: u64) !void {
    if (lane == .foreground) return file.writePositionalAll(io, bytes, offset);
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try context.writeback.writeAllAt(io, bytes, offset);
}

fn writeAllManyAt(raw: ?*anyopaque, file: File, io: Io, lane: file_io_api.Lane, writes: []const file_io_api.Write) !void {
    if (lane == .foreground) {
        for (writes) |write| try file.writePositionalAll(io, write.bytes, write.offset);
        return;
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try context.writeback.writeAllManyAt(io, writes);
}

fn sync(
    raw: ?*anyopaque,
    file: File,
    io: Io,
    lane: file_io_api.Lane,
    mode: file_io_api.SyncMode,
) !void {
    if (lane == .foreground) {
        if (mode == .data)
            try std.posix.fdatasync(file.handle)
        else
            try file.sync(io);
        return;
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try context.writeback.sync(io, @enumFromInt(@intFromEnum(mode)));
}

fn deinit(raw: ?*anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.writeback.deinit();
    const allocator = context.allocator;
    allocator.destroy(context);
}

fn stats(raw: ?*anyopaque, io: Io) file_io_api.Stats {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const writeback = context.writeback.getStats(io);
    return .{ .writeback = .{
        .submitted_sqes = writeback.submitted_sqes,
        .submit_calls = writeback.submit_calls,
        .completions = writeback.completions,
        .max_inflight = writeback.max_inflight,
    } };
}

fn resetStats(raw: ?*anyopaque, io: Io) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.writeback.resetStats(io);
}

const vtable: file_io_api.FileIo.VTable = .{
    .read_all_at = readAllAt,
    .write_all_at = writeAllAt,
    .write_all_many_at = writeAllManyAt,
    .sync = sync,
    .stats = stats,
    .reset_stats = resetStats,
    .deinit = deinit,
};

test "Linux file IO uses POSIX foreground and shared io_uring writeback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "uring-file-io", .{ .read = true });
    defer file.close(std.testing.io);
    try file.setLength(std.testing.io, 4096);

    var backend = init(std.testing.allocator, file) catch |err| switch (err) {
        error.ArgumentsInvalid,
        error.PermissionDenied,
        error.SystemOutdated,
        error.UnsupportedIoUringOperations,
        => return error.SkipZigTest,
        else => return err,
    };
    defer backend.deinit();
    try std.testing.expectEqual(file_io_api.Kind.io_uring, backend.kind);
    try backend.writeAllAt(std.testing.io, .foreground, "io_uring", 512);
    var write_bytes: [linux_io_uring.queue_entries * 2 + 1][1]u8 = undefined;
    var writes: [write_bytes.len]file_io_api.Write = undefined;
    for (&write_bytes, &writes, 0..) |*bytes, *write, index| {
        bytes.* = .{@intCast(index)};
        write.* = .{ .bytes = bytes, .offset = 1024 + index * 16 };
    }
    try backend.writeAllManyAt(std.testing.io, .writeback, &writes);
    const write_stats = backend.stats(std.testing.io).writeback;
    try std.testing.expectEqual(@as(u64, write_bytes.len), write_stats.submitted_sqes);
    try std.testing.expectEqual(@as(u64, write_bytes.len), write_stats.completions);
    try std.testing.expectEqual(@as(u64, linux_io_uring.queue_entries), write_stats.max_inflight);
    try std.testing.expectError(
        error.OffsetOverflow,
        backend.writeAllManyAt(std.testing.io, .writeback, &.{.{
            .bytes = "overflow",
            .offset = std.math.maxInt(u64),
        }}),
    );
    try backend.writeAllAt(std.testing.io, .foreground, "still-active", 3072);
    try backend.sync(std.testing.io, .writeback, .data);
    var actual: [8]u8 = undefined;
    try backend.readAllAt(std.testing.io, .foreground, &actual, 512);
    try std.testing.expectEqualStrings("io_uring", &actual);
    var batched: [1]u8 = undefined;
    try backend.readAllAt(
        std.testing.io,
        .foreground,
        &batched,
        1024 + (write_bytes.len - 1) * 16,
    );
    try std.testing.expectEqual(@as(u8, write_bytes.len - 1), batched[0]);
    var still_active: [12]u8 = undefined;
    try backend.readAllAt(std.testing.io, .foreground, &still_active, 3072);
    try std.testing.expectEqualStrings("still-active", &still_active);
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        backend.readAllAt(std.testing.io, .foreground, &actual, 4095),
    );
}
