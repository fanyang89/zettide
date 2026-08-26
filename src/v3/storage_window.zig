const std = @import("std");
const storage_api = @import("storage.zig");

const max_batch_size = 128;

const Context = struct {
    allocator: std.mem.Allocator,
    backing: *storage_api.Storage,
    base_offset: u64,
    length: u64,
};

/// Creates an owned logical view over a borrowed backing Storage. The caller
/// must keep the backing open until every window has been closed.
pub fn create(
    allocator: std.mem.Allocator,
    backing: *storage_api.Storage,
    base_offset: u64,
    length: u64,
) !storage_api.Storage {
    if (length == 0 or base_offset > backing.capacity() or length > backing.capacity() - base_offset)
        return error.InvalidStorageWindow;
    if (base_offset % backing.minimum_io_size != 0 or length % backing.minimum_io_size != 0)
        return error.InvalidStorageWindow;
    const context = try allocator.create(Context);
    context.* = .{
        .allocator = allocator,
        .backing = backing,
        .base_offset = base_offset,
        .length = length,
    };
    return .initBackend(
        context,
        &vtable,
        length,
        backing.kind,
        backing.minimum_io_size,
    );
}

fn sameIdentity(context_raw: *anyopaque, other_raw: *anyopaque) bool {
    const context: *const Context = @ptrCast(@alignCast(context_raw));
    const other: *const Context = @ptrCast(@alignCast(other_raw));
    return context.base_offset == other.base_offset and
        context.length == other.length and
        context.backing.sameIdentity(other.backing);
}

fn readAt(context_raw: *anyopaque, io: std.Io, buffer: []u8, offset: u64) !usize {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    return context.backing.readAt(io, buffer, try translate(context, offset, buffer.len));
}

fn readManyAt(
    context_raw: *anyopaque,
    io: std.Io,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
) !void {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    if (reads.len != results.len) return error.InvalidReadBatch;
    for (reads) |read| _ = try translate(context, read.offset, read.buffer.len);
    var first: usize = 0;
    while (first < reads.len) {
        const count = @min(max_batch_size, reads.len - first);
        var translated: [max_batch_size]storage_api.Read = undefined;
        for (reads[first..][0..count], translated[0..count]) |read, *output| {
            output.* = .{
                .buffer = read.buffer,
                .offset = try translate(context, read.offset, read.buffer.len),
            };
        }
        try context.backing.readManyAt(io, translated[0..count], results[first..][0..count]);
        first += count;
    }
}

fn submitReadManyAt(
    context_raw: *anyopaque,
    io: std.Io,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
    completion: storage_api.AsyncReadCompletion,
) !storage_api.AsyncReadSubmit {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    if (reads.len != results.len) return error.InvalidReadBatch;
    if (reads.len > max_batch_size) return .unsupported;
    var translated: [max_batch_size]storage_api.Read = undefined;
    for (reads, translated[0..reads.len]) |read, *output| output.* = .{
        .buffer = read.buffer,
        .offset = try translate(context, read.offset, read.buffer.len),
    };
    return context.backing.submitReadManyAt(io, translated[0..reads.len], results, completion);
}

fn resolveAsyncReadTarget(
    context_raw: *anyopaque,
    io: std.Io,
) !?storage_api.AsyncReadTarget {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    const target = try context.backing.asyncReadTarget(io) orelse return null;
    return try target.view(context.base_offset, context.length);
}

fn writeAllAt(context_raw: *anyopaque, io: std.Io, bytes: []const u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    try context.backing.writeAllAt(io, bytes, try translate(context, offset, bytes.len));
}

fn writeAllManyAt(context_raw: *anyopaque, io: std.Io, writes: []const storage_api.Write) !void {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    for (writes) |write| _ = try translate(context, write.offset, write.bytes.len);
    var first: usize = 0;
    while (first < writes.len) {
        const count = @min(max_batch_size, writes.len - first);
        var translated: [max_batch_size]storage_api.Write = undefined;
        for (writes[first..][0..count], translated[0..count]) |write, *output| {
            output.* = .{
                .bytes = write.bytes,
                .offset = try translate(context, write.offset, write.bytes.len),
            };
        }
        try context.backing.writeAllManyAt(io, translated[0..count]);
        first += count;
    }
}

fn syncData(context_raw: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    try context.backing.syncData(io);
}

fn sync(context_raw: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    try context.backing.sync(io);
}

fn close(context_raw: *anyopaque, _: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_raw));
    context.allocator.destroy(context);
}

fn transportKind(context_raw: *anyopaque) storage_api.TransportKind {
    const context: *const Context = @ptrCast(@alignCast(context_raw));
    return context.backing.transportKind();
}

fn translate(context: *const Context, offset: u64, size: usize) !u64 {
    const length = std.math.cast(u64, size) orelse return error.StorageOutOfBounds;
    if (offset > context.length or length > context.length - offset)
        return error.StorageOutOfBounds;
    return std.math.add(u64, context.base_offset, offset) catch error.StorageOutOfBounds;
}

const vtable: storage_api.Storage.VTable = .{
    .same_identity = sameIdentity,
    .read_at = readAt,
    .read_many_at = readManyAt,
    .submit_read_many_at = submitReadManyAt,
    .resolve_async_read_target = resolveAsyncReadTarget,
    .write_all_at = writeAllAt,
    .write_all_many_at = writeAllManyAt,
    .sync_data = syncData,
    .sync = sync,
    .close = close,
    .transport_kind = transportKind,
};

test "windows translate batched I/O and preserve logical identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backing = try storage_api.Storage.createFile(std.testing.io, tmp.dir, "backing", 4096);
    defer backing.close(std.testing.io) catch {};
    var first = try create(std.testing.allocator, &backing, 1024, 1024);
    defer first.close(std.testing.io) catch {};
    var same = try create(std.testing.allocator, &backing, 1024, 1024);
    defer same.close(std.testing.io) catch {};
    var second = try create(std.testing.allocator, &backing, 2048, 1024);
    defer second.close(std.testing.io) catch {};

    try std.testing.expect(first.sameIdentity(&same));
    try std.testing.expect(!first.sameIdentity(&second));
    try first.writeAllManyAt(std.testing.io, &.{
        .{ .bytes = "abcd", .offset = 0 },
        .{ .bytes = "wxyz", .offset = 512 },
    });
    var first_bytes: [4]u8 = undefined;
    var second_bytes: [4]u8 = undefined;
    var results: [2]storage_api.ReadResult = undefined;
    try first.readManyAt(std.testing.io, &.{
        .{ .buffer = &first_bytes, .offset = 0 },
        .{ .buffer = &second_bytes, .offset = 512 },
    }, &results);
    try std.testing.expectEqualStrings("abcd", &first_bytes);
    try std.testing.expectEqualStrings("wxyz", &second_bytes);
    try std.testing.expectEqual(@as(usize, 4), results[0].amount);
    try std.testing.expectEqual(@as(usize, 4), results[1].amount);
    try std.testing.expectError(error.StorageOutOfBounds, first.readAt(std.testing.io, &first_bytes, 1021));
}

test "nested windows resolve translated views of one async backing" {
    const Backend = struct {
        bytes: [8192]u8 = @splat(0),
        submit_calls: usize = 0,

        fn sameIdentity(context: *anyopaque, other: *anyopaque) bool {
            return context == other;
        }

        fn readAt(context: *anyopaque, _: std.Io, buffer: []u8, offset: u64) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            const start = std.math.cast(usize, offset) orelse return error.StorageOutOfBounds;
            if (start > self.bytes.len or buffer.len > self.bytes.len - start)
                return error.StorageOutOfBounds;
            @memcpy(buffer, self.bytes[start..][0..buffer.len]);
            return buffer.len;
        }

        fn submitReadManyAt(
            context: *anyopaque,
            _: std.Io,
            reads: []const storage_api.Read,
            results: []storage_api.ReadResult,
            completion: storage_api.AsyncReadCompletion,
        ) !storage_api.AsyncReadSubmit {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.submit_calls += 1;
            for (results) |*result| result.* = .{};
            for (reads, results) |read, *result| {
                result.amount = try @This().readAt(context, std.testing.io, read.buffer, read.offset);
            }
            completion.complete(completion.context, null);
            return .submitted;
        }

        fn writeAllAt(_: *anyopaque, _: std.Io, _: []const u8, _: u64) !void {}
        fn sync(_: *anyopaque, _: std.Io) !void {}
        fn close(_: *anyopaque, _: std.Io) !void {}

        const vtable: storage_api.Storage.VTable = .{
            .same_identity = @This().sameIdentity,
            .read_at = @This().readAt,
            .submit_read_many_at = @This().submitReadManyAt,
            .max_async_read_count = 32,
            .write_all_at = @This().writeAllAt,
            .sync = @This().sync,
            .close = @This().close,
        };
    };
    const Completion = struct {
        called: bool = false,

        fn complete(context: *anyopaque, failure: ?anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(failure == null);
            self.called = true;
        }
    };

    var backend: Backend = .{};
    @memset(backend.bytes[1664..1672], 0x5a);
    var backing = storage_api.Storage.initBackend(
        &backend,
        &Backend.vtable,
        backend.bytes.len,
        .spdk_bdev,
        1,
    );
    defer backing.close(std.testing.io) catch {};
    var outer = try create(std.testing.allocator, &backing, 1024, 4096);
    defer outer.close(std.testing.io) catch {};
    var inner = try create(std.testing.allocator, &outer, 512, 2048);
    defer inner.close(std.testing.io) catch {};

    const outer_target = (try outer.asyncReadTarget(std.testing.io)).?;
    const inner_target = (try inner.asyncReadTarget(std.testing.io)).?;
    try std.testing.expect(outer_target.sameBacking(inner_target));
    var output: [8]u8 = undefined;
    const translated = try inner_target.translate(.{ .buffer = &output, .offset = 128 });
    try std.testing.expectEqual(@as(u64, 1664), translated.offset);
    var results: [1]storage_api.ReadResult = undefined;
    var completion: Completion = .{};
    try std.testing.expectEqual(
        storage_api.AsyncReadSubmit.submitted,
        try inner_target.submitReadManyAt(
            &.{translated},
            &results,
            .{ .context = &completion, .complete = Completion.complete },
        ),
    );
    try std.testing.expect(completion.called);
    try std.testing.expectEqual(@as(usize, 1), backend.submit_calls);
    try std.testing.expectEqual(@as(usize, output.len), results[0].amount);
    try std.testing.expect(std.mem.allEqual(u8, &output, 0x5a));
}
