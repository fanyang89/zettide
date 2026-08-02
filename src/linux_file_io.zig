const std = @import("std");
const file_io_api = @import("file_io_api.zig");

const Io = std.Io;
const File = Io.File;
const IoUring = std.os.linux.IoUring;
const linux = std.os.linux;

const queue_entries = 8;
const max_request_len = std.math.maxInt(u32);

const Lane = struct {
    ring: IoUring,
    mutex: Io.Mutex = .init,
    next_token: u64 = 1,
    active: bool = true,
    file_registered: bool = true,
};

const Context = struct {
    allocator: std.mem.Allocator,
    data: Lane,
    sync: Lane,
};

pub fn init(allocator: std.mem.Allocator, file: File) !file_io_api.FileIo {
    var data_ring = try IoUring.init(queue_entries, 0);
    errdefer data_ring.deinit();
    const probe = try data_ring.get_probe();
    if (!probe.is_supported(.READ) or
        !probe.is_supported(.WRITE) or
        !probe.is_supported(.FSYNC))
        return error.UnsupportedIoUringOperations;

    var sync_ring = try IoUring.init(queue_entries, 0);
    errdefer sync_ring.deinit();
    var files = [_]linux.fd_t{file.handle};
    try data_ring.register_files(&files);
    errdefer data_ring.unregister_files() catch {};
    try sync_ring.register_files(&files);
    errdefer sync_ring.unregister_files() catch {};
    const context = try allocator.create(Context);
    context.* = .{
        .allocator = allocator,
        .data = .{ .ring = data_ring },
        .sync = .{ .ring = sync_ring },
    };
    return .{
        .file = file,
        .context = context,
        .vtable = &vtable,
        .kind = .io_uring,
    };
}

fn readAllAt(raw: ?*anyopaque, _: File, io: Io, buffer: []u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try context.data.mutex.lock(io);
    defer context.data.mutex.unlock(io);

    var index: usize = 0;
    while (index < buffer.len) {
        try requireActive(&context.data);
        const request_len = @min(buffer.len - index, max_request_len);
        const token = nextToken(&context.data);
        const sqe = context.data.ring.read(
            token,
            0,
            .{ .buffer = buffer[index..][0..request_len] },
            offset + index,
        ) catch |err| {
            failLane(&context.data);
            return err;
        };
        sqe.flags |= linux.IOSQE_FIXED_FILE;
        const amount = complete(&context.data, token) catch |err| switch (err) {
            error.OperationInterrupted => continue,
            else => return err,
        };
        if (amount == 0) return error.UnexpectedEndOfFile;
        if (amount > request_len) return invalidCompletion(&context.data);
        index += amount;
    }
}

fn writeAllAt(raw: ?*anyopaque, _: File, io: Io, bytes: []const u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try context.data.mutex.lock(io);
    defer context.data.mutex.unlock(io);

    var index: usize = 0;
    while (index < bytes.len) {
        try requireActive(&context.data);
        const request_len = @min(bytes.len - index, max_request_len);
        const token = nextToken(&context.data);
        const sqe = context.data.ring.write(
            token,
            0,
            bytes[index..][0..request_len],
            offset + index,
        ) catch |err| {
            failLane(&context.data);
            return err;
        };
        sqe.flags |= linux.IOSQE_FIXED_FILE;
        const amount = complete(&context.data, token) catch |err| switch (err) {
            error.OperationInterrupted => continue,
            else => return err,
        };
        if (amount == 0 or amount > request_len) return invalidCompletion(&context.data);
        index += amount;
    }
}

fn writeAllManyAt(raw: ?*anyopaque, _: File, io: Io, writes: []const file_io_api.Write) !void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    for (writes) |write| {
        if (write.bytes.len > max_request_len) return error.RequestTooLarge;
        _ = std.math.add(u64, write.offset, write.bytes.len) catch return error.OffsetOverflow;
    }
    try context.data.mutex.lock(io);
    defer context.data.mutex.unlock(io);

    var index: usize = 0;
    while (index < writes.len) {
        var tokens: [queue_entries]u64 = undefined;
        var lengths: [queue_entries]usize = undefined;
        var amounts: [queue_entries]usize = @splat(0);
        var seen: [queue_entries]bool = @splat(false);
        var count: usize = 0;
        while (index + count < writes.len and count < queue_entries) : (count += 1) {
            const write = writes[index + count];
            try requireActive(&context.data);
            const token = nextToken(&context.data);
            const sqe = context.data.ring.write(token, 0, write.bytes, write.offset) catch |err| {
                failLane(&context.data);
                return err;
            };
            sqe.flags |= linux.IOSQE_FIXED_FILE;
            tokens[count] = token;
            lengths[count] = write.bytes.len;
        }
        try submitBatch(&context.data, count);
        var first_error: ?anyerror = null;
        for (0..count) |_| {
            const completion = copyCompletion(&context.data) catch |err| {
                failLane(&context.data);
                return err;
            };
            const completion_index = for (tokens[0..count], 0..) |token, token_index| {
                if (token == completion.user_data) break token_index;
            } else return invalidCompletion(&context.data);
            if (seen[completion_index]) return invalidCompletion(&context.data);
            seen[completion_index] = true;
            if (completion.res < 0) {
                if (first_error == null) first_error = completionError(@enumFromInt(-completion.res));
            } else {
                const amount: usize = @intCast(completion.res);
                if (amount > lengths[completion_index]) return invalidCompletion(&context.data);
                amounts[completion_index] = amount;
            }
        }
        if (first_error) |err| return err;
        for (writes[index..][0..count], amounts[0..count]) |write, amount| {
            if (amount < write.bytes.len)
                try writeAllLocked(&context.data, write.bytes[amount..], write.offset + amount);
        }
        index += count;
    }
}

fn dataSync(raw: ?*anyopaque, _: File, io: Io) !void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    try context.sync.mutex.lock(io);
    defer context.sync.mutex.unlock(io);

    while (true) {
        try requireActive(&context.sync);
        const token = nextToken(&context.sync);
        const sqe = context.sync.ring.fsync(token, 0, linux.IORING_FSYNC_DATASYNC) catch |err| {
            failLane(&context.sync);
            return err;
        };
        sqe.flags |= linux.IOSQE_FIXED_FILE;
        const result = complete(&context.sync, token) catch |err| switch (err) {
            error.OperationInterrupted => continue,
            else => return err,
        };
        if (result != 0) return invalidCompletion(&context.sync);
        return;
    }
}

fn deinit(raw: ?*anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    failLane(&context.data);
    failLane(&context.sync);
    const allocator = context.allocator;
    allocator.destroy(context);
}

fn nextToken(lane: *Lane) u64 {
    const token = lane.next_token;
    lane.next_token +%= 1;
    if (lane.next_token == 0) lane.next_token = 1;
    return token;
}

fn requireActive(lane: *const Lane) !void {
    if (!lane.active) return error.IoUringFailed;
}

fn failLane(lane: *Lane) void {
    if (!lane.active) return;
    if (lane.file_registered) {
        lane.ring.unregister_files() catch {};
        lane.file_registered = false;
    }
    lane.ring.deinit();
    lane.active = false;
}

fn invalidCompletion(lane: *Lane) error{InvalidIoUringCompletion} {
    failLane(lane);
    return error.InvalidIoUringCompletion;
}

fn complete(lane: *Lane, token: u64) !usize {
    try submitBatch(lane, 1);
    const completion = copyCompletion(lane) catch |err| {
        failLane(lane);
        return err;
    };
    if (completion.user_data != token) return invalidCompletion(lane);
    if (completion.res < 0) return completionError(@enumFromInt(-completion.res));
    return @intCast(completion.res);
}

fn submitBatch(lane: *Lane, count: usize) !void {
    var submitted: u32 = 0;
    const expected: u32 = @intCast(count);
    while (submitted < expected) {
        const amount = (if (submitted == 0)
            lane.ring.submit()
        else
            lane.ring.enter(expected - submitted, 0, 0)) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => {
                failLane(lane);
                return err;
            },
        };
        if (amount == 0 or amount > expected - submitted) {
            failLane(lane);
            return error.IncompleteIoUringSubmission;
        }
        submitted += amount;
    }
}

fn copyCompletion(lane: *Lane) !linux.io_uring_cqe {
    while (true) {
        return lane.ring.copy_cqe() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
    }
}

fn writeAllLocked(lane: *Lane, bytes: []const u8, offset: u64) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        try requireActive(lane);
        const request_len = @min(bytes.len - index, max_request_len);
        const token = nextToken(lane);
        const sqe = try lane.ring.write(token, 0, bytes[index..][0..request_len], offset + index);
        sqe.flags |= linux.IOSQE_FIXED_FILE;
        const amount = complete(lane, token) catch |err| switch (err) {
            error.OperationInterrupted => continue,
            else => return err,
        };
        if (amount == 0 or amount > request_len) return invalidCompletion(lane);
        index += amount;
    }
}

fn completionError(err: linux.E) anyerror {
    return switch (err) {
        .ACCES, .PERM, .ROFS => error.ReadOnlyFileSystem,
        .BADF => error.FileClosed,
        .DQUOT, .FBIG, .NOSPC => error.NoSpaceLeft,
        .NODEV, .NXIO => error.DeviceUnavailable,
        .NOMEM, .NOBUFS, .AGAIN => error.SystemResources,
        .CANCELED => error.OperationCanceled,
        .INTR => error.OperationInterrupted,
        .INVAL => error.InvalidIo,
        else => error.IoUringCompletion,
    };
}

const vtable: file_io_api.FileIo.VTable = .{
    .read_all_at = readAllAt,
    .write_all_at = writeAllAt,
    .write_all_many_at = writeAllManyAt,
    .data_sync = dataSync,
    .deinit = deinit,
};

test "Linux file IO uses io_uring for borrowed file operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "uring-file-io", .{ .read = true });
    defer file.close(std.testing.io);
    try file.setLength(std.testing.io, 4096);

    var backend = init(std.testing.allocator, file) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer backend.deinit();
    try std.testing.expectEqual(file_io_api.Kind.io_uring, backend.kind);
    try backend.writeAllAt(std.testing.io, "io_uring", 512);
    var write_bytes: [10][1]u8 = undefined;
    var writes: [write_bytes.len]file_io_api.Write = undefined;
    for (&write_bytes, &writes, 0..) |*bytes, *write, index| {
        bytes.* = .{@intCast(index)};
        write.* = .{ .bytes = bytes, .offset = 1024 + index * 16 };
    }
    try backend.writeAllManyAt(std.testing.io, &writes);
    try std.testing.expectError(
        error.OffsetOverflow,
        backend.writeAllManyAt(std.testing.io, &.{.{
            .bytes = "overflow",
            .offset = std.math.maxInt(u64),
        }}),
    );
    try backend.writeAllAt(std.testing.io, "still-active", 3072);
    try backend.dataSync(std.testing.io);
    var actual: [8]u8 = undefined;
    try backend.readAllAt(std.testing.io, &actual, 512);
    try std.testing.expectEqualStrings("io_uring", &actual);
    var batched: [1]u8 = undefined;
    try backend.readAllAt(std.testing.io, &batched, 1024 + 9 * 16);
    try std.testing.expectEqual(@as(u8, 9), batched[0]);
    var still_active: [12]u8 = undefined;
    try backend.readAllAt(std.testing.io, &still_active, 3072);
    try std.testing.expectEqualStrings("still-active", &still_active);
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        backend.readAllAt(std.testing.io, &actual, 4095),
    );
}
