const std = @import("std");
const linux_io_uring = @import("../linux_io_uring.zig");
const storage_api = @import("storage.zig");

const File = std.Io.File;
const max_engine_lanes = 4;

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

const EnginePool = struct {
    engines: [max_engine_lanes]linux_io_uring.Engine = undefined,
    count: usize,

    fn init(fd: std.os.linux.fd_t) !EnginePool {
        var pool: EnginePool = .{ .count = 0 };
        pool.engines[0] = try .init(fd);
        pool.count = 1;
        while (pool.count < pool.engines.len) {
            pool.engines[pool.count] = linux_io_uring.Engine.init(fd) catch break;
            pool.count += 1;
        }
        return pool;
    }

    fn initialized(self: *EnginePool) []linux_io_uring.Engine {
        return self.engines[0..self.count];
    }

    fn deinit(self: *EnginePool) void {
        for (self.initialized()) |*engine| engine.deinit();
        self.* = undefined;
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    file: File,
    capacity_bytes: u64,
    identity: Identity,
    writable: bool,
    engine_pool: ?EnginePool,
    read_lane: std.atomic.Value(u64) = .init(0),
    mutex: std.Io.RwLock = .init,
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
        .engine_pool = switch (mode) {
            .posix => null,
            .io_uring => try .init(file.handle),
            .auto => EnginePool.init(file.handle) catch |err|
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
    context.mutex.lockShared(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlockShared(io);
    try validateRange(context, offset, buffer.len);
    return context.file.readPositionalAll(io, buffer, offset) catch |err| return mapOperationError(err);
}

fn readManyAt(
    context_ptr: *anyopaque,
    io: std.Io,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (reads.len != results.len) return error.InvalidReadBatch;
    for (reads) |read| try validateRange(context, read.offset, read.buffer.len);

    if (context.engine_pool != null and reads.len > 1) {
        context.mutex.lockShared(io) catch |err| return mapOperationError(err);
        defer context.mutex.unlockShared(io);
        const pool = &context.engine_pool.?;
        const lane = nextReadLane(&context.read_lane, pool.count);
        const engine = &pool.engines[lane];
        engine.readManyAt(io, reads, results) catch |err| return mapOperationError(err);
        for (results) |*result| {
            if (result.failure) |err| result.failure = mapOperationError(err);
        }
        return;
    }
    context.mutex.lockShared(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlockShared(io);
    for (results) |*result| result.* = .{};
    for (reads, results) |read, *result| {
        result.amount = context.file.readPositionalAll(io, read.buffer, read.offset) catch |err| {
            result.failure = mapOperationError(err);
            continue;
        };
    }
}

fn writeAllAt(context_ptr: *anyopaque, io: std.Io, bytes: []const u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lock(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlock(io);
    try validateRange(context, offset, bytes.len);
    if (!context.writable) return error.ReadOnlyStorage;

    if (context.engine_pool) |*pool|
        pool.engines[0].writeAllAt(io, bytes, offset) catch |err| return mapOperationError(err)
    else
        context.file.writePositionalAll(io, bytes, offset) catch |err| return mapOperationError(err);
}

fn writeAllManyAt(context_ptr: *anyopaque, io: std.Io, writes: []const storage_api.Write) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lock(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlock(io);
    if (!context.writable) return error.ReadOnlyStorage;
    for (writes) |write| try validateRange(context, write.offset, write.bytes.len);

    if (context.engine_pool) |*pool|
        pool.engines[0].writeAllManyAt(io, writes) catch |err| return mapOperationError(err)
    else for (writes) |write|
        context.file.writePositionalAll(io, write.bytes, write.offset) catch |err|
            return mapOperationError(err);
}

fn syncData(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lock(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlock(io);

    if (context.engine_pool) |*pool|
        pool.engines[0].sync(io, .data) catch |err| return mapOperationError(err)
    else
        std.posix.fdatasync(context.file.handle) catch |err| return mapOperationError(err);
}

fn sync(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lock(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlock(io);

    if (context.engine_pool) |*pool|
        pool.engines[0].sync(io, .full) catch |err| return mapOperationError(err)
    else
        context.file.sync(io) catch |err| return mapOperationError(err);
}

fn transportKind(context_ptr: *anyopaque) storage_api.TransportKind {
    const context: *const Context = @ptrCast(@alignCast(context_ptr));
    return if (context.engine_pool != null) .io_uring else .posix;
}

fn transportStats(context_ptr: *anyopaque, io: std.Io) storage_api.TransportStats {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lockUncancelable(io);
    defer context.mutex.unlock(io);
    const pool = if (context.engine_pool) |*value| value else return .{};
    var total: storage_api.TransportStats = .{};
    for (pool.initialized()) |*engine| addTransportStats(&total, engine.getStats(io));
    return total;
}

fn resetTransportStats(context_ptr: *anyopaque, io: std.Io) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lockUncancelable(io);
    defer context.mutex.unlock(io);
    if (context.engine_pool) |*pool|
        for (pool.initialized()) |*engine| engine.resetStats(io);
}

fn close(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lockUncancelable(io);
    if (context.engine_pool) |*pool| pool.deinit();
    context.file.close(io);
    const allocator = context.allocator;
    context.mutex.unlock(io);
    allocator.destroy(context);
}

fn nextReadLane(sequence: *std.atomic.Value(u64), lane_count: usize) usize {
    std.debug.assert(lane_count > 0 and lane_count <= max_engine_lanes);
    return @intCast(sequence.fetchAdd(1, .monotonic) % lane_count);
}

fn addTransportStats(total: *storage_api.TransportStats, stats: linux_io_uring.Stats) void {
    total.queue_capacity +|= stats.queue_capacity;
    total.submitted_sqes +|= stats.submitted_sqes;
    total.submit_calls +|= stats.submit_calls;
    total.completions +|= stats.completions;
    total.current_inflight +|= stats.current_inflight;
    total.max_inflight +|= stats.max_inflight;
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

test "raw io_uring read lanes round robin across counter overflow" {
    var sequence: std.atomic.Value(u64) = .init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 1));
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 1));

    sequence.store(std.math.maxInt(u64) - 1, .monotonic);
    try std.testing.expectEqual(@as(usize, 2), nextReadLane(&sequence, 4));
    try std.testing.expectEqual(@as(usize, 3), nextReadLane(&sequence, 4));
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 4));
    try std.testing.expectEqual(@as(usize, 1), nextReadLane(&sequence, 4));

    sequence.store(std.math.maxInt(u64) - 1, .monotonic);
    try std.testing.expectEqual(@as(usize, 2), nextReadLane(&sequence, 3));
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 3));
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 3));
    try std.testing.expectEqual(@as(usize, 1), nextReadLane(&sequence, 3));
}

test "raw io_uring transport stats aggregate with saturation" {
    var total: storage_api.TransportStats = .{ .submitted_sqes = std.math.maxInt(u64) - 1 };
    addTransportStats(&total, .{
        .queue_capacity = 7,
        .submitted_sqes = 3,
        .submit_calls = 5,
        .completions = 4,
        .current_inflight = 2,
        .max_inflight = 6,
    });
    try std.testing.expectEqual(@as(u64, 7), total.queue_capacity);
    try std.testing.expectEqual(std.math.maxInt(u64), total.submitted_sqes);
    try std.testing.expectEqual(@as(u64, 5), total.submit_calls);
    try std.testing.expectEqual(@as(u64, 4), total.completions);
    try std.testing.expectEqual(@as(u64, 2), total.current_inflight);
    try std.testing.expectEqual(@as(u64, 6), total.max_inflight);
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

test "forced io_uring raw storage uses positional singleton reads and engine batches" {
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
    var first: [4]u8 = undefined;
    var second: [4]u8 = undefined;
    const reads = [_]storage_api.Read{
        .{ .buffer = &first, .offset = 512 },
        .{ .buffer = &second, .offset = 516 },
    };
    var results: [reads.len]storage_api.ReadResult = undefined;
    try storage.readManyAt(std.testing.io, &reads, &results);
    try std.testing.expectEqualStrings(expected[0..4], &first);
    try std.testing.expectEqualStrings(expected[4..8], &second);
    for (results) |result| try std.testing.expectEqual(@as(usize, 4), result.amount);
    try std.testing.expectEqual(storage_api.TransportKind.io_uring, storage.transportKind());
    const stats = storage.transportStats(std.testing.io);
    try std.testing.expect(stats.queue_capacity >= linux_io_uring.queue_entries);
    try std.testing.expect(stats.queue_capacity <= max_engine_lanes * linux_io_uring.queue_entries);
    try std.testing.expectEqual(@as(u64, 0), stats.queue_capacity % linux_io_uring.queue_entries);
    try std.testing.expectEqual(@as(u64, 4), stats.submitted_sqes);
    try std.testing.expectEqual(stats.submitted_sqes, stats.completions);
    try std.testing.expect(stats.max_inflight >= 1);
    storage.resetTransportStats(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), storage.transportStats(std.testing.io).submitted_sqes);

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
