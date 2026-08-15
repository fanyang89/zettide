const std = @import("std");
const linux_io_uring = @import("../linux_io_uring.zig");
const storage_api = @import("storage.zig");

const File = std.Io.File;
const max_engine_lanes = 2;
const async_queue_capacity = 128;
const async_max_reads = linux_io_uring.queue_entries;

pub const Mode = enum {
    auto,
    posix,
    io_uring,
    io_uring_iopoll,
    io_uring_iopoll_sqpoll,

    pub fn parse(value: []const u8) !Mode {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "posix")) return .posix;
        if (std.mem.eql(u8, value, "io_uring")) return .io_uring;
        if (std.mem.eql(u8, value, "io_uring_iopoll")) return .io_uring_iopoll;
        if (std.mem.eql(u8, value, "io_uring_iopoll_sqpoll")) return .io_uring_iopoll_sqpoll;
        return error.InvalidRawStorageMode;
    }
};

pub const Identity = struct {
    major: u32,
    minor: u32,
    disk_sequence: u64,
};

const EnginePool = struct {
    engines: [max_engine_lanes]linux_io_uring.Engine = undefined,
    count: usize,

    fn init(fd: std.os.linux.fd_t, options: linux_io_uring.Options) !EnginePool {
        var pool: EnginePool = .{ .count = 0 };
        var lane_options = options;
        pool.engines[0] = try .initOptions(fd, lane_options);
        pool.count = 1;
        while (pool.count < pool.engines.len) {
            if (options.sq_thread_cpu) |base_cpu|
                lane_options.sq_thread_cpu = std.math.add(u32, base_cpu, @intCast(pool.count)) catch break;
            pool.engines[pool.count] = linux_io_uring.Engine.initOptions(fd, lane_options) catch break;
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

const AsyncReadTask = struct {
    reads: [async_max_reads]storage_api.Read = undefined,
    read_count: usize,
    results: []storage_api.ReadResult,
    completion: storage_api.AsyncReadCompletion,
};

const AsyncSlot = struct {
    sequence: std.atomic.Value(usize),
    task: AsyncReadTask = undefined,
};

const AsyncStats = struct {
    submissions: std.atomic.Value(u64) = .init(0),
    completions: std.atomic.Value(u64) = .init(0),
    queue_full: std.atomic.Value(u64) = .init(0),
};

const AsyncLane = struct {
    io: std.Io,
    engine: *linux_io_uring.Engine,
    stats: *AsyncStats,
    slots: [async_queue_capacity]AsyncSlot,
    enqueue_position: std.atomic.Value(usize) = .init(0),
    dequeue_position: usize = 0,
    wake: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: std.Thread,

    fn init(self: *AsyncLane, io: std.Io, engine: *linux_io_uring.Engine, stats: *AsyncStats) !void {
        self.io = io;
        self.engine = engine;
        self.stats = stats;
        for (&self.slots, 0..) |*slot, index| slot.* = .{ .sequence = .init(index) };
        self.enqueue_position = .init(0);
        self.dequeue_position = 0;
        self.wake = .unset;
        self.stopping = .init(false);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *AsyncLane) void {
        self.stopping.store(true, .release);
        self.wake.set(self.io);
        self.thread.join();
    }

    fn submit(self: *AsyncLane, task: AsyncReadTask) bool {
        var position = self.enqueue_position.load(.monotonic);
        while (true) {
            const slot = &self.slots[position % async_queue_capacity];
            const sequence = slot.sequence.load(.acquire);
            const difference = sequenceDifference(sequence, position);
            if (difference == 0) {
                if (self.enqueue_position.cmpxchgWeak(
                    position,
                    position +% 1,
                    .monotonic,
                    .monotonic,
                )) |observed| {
                    position = observed;
                    continue;
                }
                slot.task = task;
                slot.sequence.store(position +% 1, .release);
                self.wake.set(self.io);
                return true;
            }
            if (difference < 0) return false;
            position = self.enqueue_position.load(.monotonic);
        }
    }

    fn dequeue(self: *AsyncLane) ?AsyncReadTask {
        const position = self.dequeue_position;
        const slot = &self.slots[position % async_queue_capacity];
        if (slot.sequence.load(.acquire) != position +% 1) return null;
        const task = slot.task;
        self.dequeue_position = position +% 1;
        slot.sequence.store(position +% async_queue_capacity, .release);
        return task;
    }

    fn run(self: *AsyncLane) void {
        while (true) {
            if (self.dequeue()) |task| {
                self.execute(task);
                continue;
            }
            self.wake.reset();
            if (self.dequeue()) |task| {
                self.execute(task);
                continue;
            }
            if (self.stopping.load(.acquire)) return;
            self.wake.waitUncancelable(self.io);
        }
    }

    fn execute(self: *AsyncLane, task: AsyncReadTask) void {
        var failure: ?anyerror = null;
        for (task.results) |*result| result.* = .{};
        self.engine.readManyAt(
            self.io,
            task.reads[0..task.read_count],
            task.results,
        ) catch |err| {
            failure = mapOperationError(err);
        };
        for (task.results) |*result| {
            if (result.failure) |err| result.failure = mapOperationError(err);
        }
        _ = self.stats.completions.fetchAdd(1, .monotonic);
        task.completion.complete(task.completion.context, failure);
    }
};

fn sequenceDifference(sequence: usize, position: usize) isize {
    return @bitCast(sequence -% position);
}

const AsyncReadExecutor = struct {
    lanes: [max_engine_lanes]AsyncLane = undefined,
    count: usize = 0,
    next_lane: std.atomic.Value(u64) = .init(0),
    accepting: std.atomic.Value(bool) = .init(false),
    stats: AsyncStats = .{},

    fn init(self: *AsyncReadExecutor, io: std.Io, pool: *EnginePool) !void {
        self.count = 0;
        self.next_lane = .init(0);
        self.accepting = .init(false);
        self.stats = .{};
        errdefer while (self.count != 0) {
            self.count -= 1;
            self.lanes[self.count].stop();
        };
        while (self.count < pool.count) : (self.count += 1)
            try self.lanes[self.count].init(io, &pool.engines[self.count], &self.stats);
        self.accepting.store(true, .release);
    }

    fn stop(self: *AsyncReadExecutor) void {
        self.accepting.store(false, .release);
        for (self.lanes[0..self.count]) |*lane| lane.stop();
        self.count = 0;
    }

    fn submit(
        self: *AsyncReadExecutor,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
        completion: storage_api.AsyncReadCompletion,
    ) storage_api.AsyncReadSubmit {
        if (!self.accepting.load(.acquire) or reads.len > async_max_reads) return .unsupported;
        var task: AsyncReadTask = .{
            .read_count = reads.len,
            .results = results,
            .completion = completion,
        };
        @memcpy(task.reads[0..reads.len], reads);
        const first: usize = @intCast(self.next_lane.fetchAdd(1, .monotonic) % self.count);
        for (0..self.count) |attempt| {
            if (self.lanes[(first + attempt) % self.count].submit(task)) {
                _ = self.stats.submissions.fetchAdd(1, .monotonic);
                return .submitted;
            }
        }
        _ = self.stats.queue_full.fetchAdd(1, .monotonic);
        return .unsupported;
    }

    fn addStats(self: *const AsyncReadExecutor, result: *storage_api.TransportStats) void {
        result.async_submissions +|= self.stats.submissions.load(.monotonic);
        result.async_completions +|= self.stats.completions.load(.monotonic);
        result.async_queue_full +|= self.stats.queue_full.load(.monotonic);
    }

    fn resetStats(self: *AsyncReadExecutor) void {
        self.stats.submissions.store(0, .monotonic);
        self.stats.completions.store(0, .monotonic);
        self.stats.queue_full.store(0, .monotonic);
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    file: File,
    capacity_bytes: u64,
    identity: Identity,
    writable: bool,
    polling: bool,
    engine_pool: ?EnginePool,
    async_executor: AsyncReadExecutor = .{},
    async_executor_active: bool = false,
    read_lane: std.atomic.Value(u64) = .init(0),
    mutex: std.Io.RwLock = .init,
};

pub fn initOwned(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: File,
    capacity_bytes: u64,
    minimum_io_size: u32,
    identity: Identity,
    writable: bool,
    mode: Mode,
) !storage_api.Storage {
    return initOwnedOptions(
        allocator,
        io,
        file,
        capacity_bytes,
        minimum_io_size,
        identity,
        writable,
        .{ .mode = mode },
    );
}

pub const InitOptions = struct {
    mode: Mode = .auto,
    sq_thread_cpu_base: ?u32 = null,
};

pub fn initOwnedOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: File,
    capacity_bytes: u64,
    minimum_io_size: u32,
    identity: Identity,
    writable: bool,
    options: InitOptions,
) !storage_api.Storage {
    const mode = options.mode;
    const polling = mode == .io_uring_iopoll or mode == .io_uring_iopoll_sqpoll;
    if (polling and writable) return error.PollModeRequiresReadOnly;
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .file = file,
        .capacity_bytes = capacity_bytes,
        .identity = identity,
        .writable = writable,
        .polling = polling,
        .engine_pool = switch (mode) {
            .posix => null,
            .io_uring => try .init(file.handle, .{}),
            .io_uring_iopoll => try .init(file.handle, .{ .io_poll = true }),
            .io_uring_iopoll_sqpoll => try .init(file.handle, .{
                .io_poll = true,
                .sq_poll = true,
                .sq_thread_cpu = options.sq_thread_cpu_base,
                .completion_spin_count = 1024,
            }),
            .auto => EnginePool.init(file.handle, .{}) catch |err|
                if (shouldFallback(mode, err)) null else return err,
        },
    };
    errdefer if (context.engine_pool) |*pool| pool.deinit();
    if (context.engine_pool != null and !writable) {
        try context.async_executor.init(io, &context.engine_pool.?);
        context.async_executor_active = true;
    }
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
    if (context.polling) {
        const pool = &context.engine_pool.?;
        return pool.engines[0].readAt(io, buffer, offset) catch |err| return mapOperationError(err);
    }
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

    if (context.engine_pool != null and (context.polling or reads.len > 1)) {
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

fn submitReadManyAt(
    context_ptr: *anyopaque,
    _: std.Io,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
    completion: storage_api.AsyncReadCompletion,
) !storage_api.AsyncReadSubmit {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (reads.len != results.len) return error.InvalidReadBatch;
    for (reads) |read| try validateRange(context, read.offset, read.buffer.len);
    if (!context.async_executor_active) return .unsupported;
    return context.async_executor.submit(reads, results, completion);
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
    if (context.polling) return;
    context.mutex.lock(io) catch |err| return mapOperationError(err);
    defer context.mutex.unlock(io);

    if (context.engine_pool) |*pool|
        pool.engines[0].sync(io, .data) catch |err| return mapOperationError(err)
    else
        std.posix.fdatasync(context.file.handle) catch |err| return mapOperationError(err);
}

fn sync(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (context.polling) return;
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
    if (context.async_executor_active) context.async_executor.addStats(&total);
    return total;
}

fn resetTransportStats(context_ptr: *anyopaque, io: std.Io) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.mutex.lockUncancelable(io);
    defer context.mutex.unlock(io);
    if (context.engine_pool) |*pool|
        for (pool.initialized()) |*engine| engine.resetStats(io);
    if (context.async_executor_active) context.async_executor.resetStats();
}

fn close(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (context.async_executor_active) {
        context.async_executor.stop();
        context.async_executor_active = false;
    }
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
    .submit_read_many_at = submitReadManyAt,
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

test "raw storage mode parsing is strict" {
    try std.testing.expectEqual(Mode.auto, try Mode.parse("auto"));
    try std.testing.expectEqual(Mode.posix, try Mode.parse("posix"));
    try std.testing.expectEqual(Mode.io_uring, try Mode.parse("io_uring"));
    try std.testing.expectEqual(Mode.io_uring_iopoll, try Mode.parse("io_uring_iopoll"));
    try std.testing.expectEqual(Mode.io_uring_iopoll_sqpoll, try Mode.parse("io_uring_iopoll_sqpoll"));
    try std.testing.expectError(error.InvalidRawStorageMode, Mode.parse("poll"));
}

test "polling raw storage is read only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "polling-read-only", .{ .read = true });
    defer file.close(std.testing.io);
    try std.testing.expectError(
        error.PollModeRequiresReadOnly,
        initOwned(
            std.testing.allocator,
            std.testing.io,
            file,
            4096,
            512,
            .{ .major = 1, .minor = 2, .disk_sequence = 3 },
            true,
            .io_uring_iopoll,
        ),
    );
}

test "raw io_uring read lanes round robin across counter overflow" {
    var sequence: std.atomic.Value(u64) = .init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 1));
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 1));

    sequence.store(std.math.maxInt(u64) - 1, .monotonic);
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 2));
    try std.testing.expectEqual(@as(usize, 1), nextReadLane(&sequence, 2));
    try std.testing.expectEqual(@as(usize, 0), nextReadLane(&sequence, 2));
    try std.testing.expectEqual(@as(usize, 1), nextReadLane(&sequence, 2));
}

test "async queue sequence comparison handles counter overflow" {
    try std.testing.expectEqual(@as(isize, 0), sequenceDifference(0, 0));
    try std.testing.expect(sequenceDifference(std.math.maxInt(usize), 0) < 0);
    try std.testing.expect(sequenceDifference(0, std.math.maxInt(usize)) > 0);
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
    var storage = try initOwned(std.testing.allocator, std.testing.io, file, 4096, 512, identity, true, .posix);
    storage_owns_file = true;
    var storage_open = true;
    defer if (storage_open) storage.close(std.testing.io) catch {};

    const alias_file = try tmp.dir.openFile(std.testing.io, "posix-raw-storage", .{ .mode = .read_only });
    var alias_owns_file = false;
    defer if (!alias_owns_file) alias_file.close(std.testing.io);
    var alias = try initOwned(std.testing.allocator, std.testing.io, alias_file, 4096, 512, identity, false, .posix);
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
        std.testing.io,
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

test "read-only io_uring raw storage completes submitted batches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const expected = "asynchronous raw storage";
    const writable = try tmp.dir.createFile(std.testing.io, "async-uring-raw-storage", .{ .read = true });
    try writable.setLength(std.testing.io, 4096);
    try writable.writePositionalAll(std.testing.io, expected, 512);
    writable.close(std.testing.io);
    const file = try tmp.dir.openFile(std.testing.io, "async-uring-raw-storage", .{ .mode = .read_only });
    var storage_owns_file = false;
    defer if (!storage_owns_file) file.close(std.testing.io);
    var storage = initOwned(
        std.testing.allocator,
        std.testing.io,
        file,
        4096,
        512,
        .{ .major = 1, .minor = 2, .disk_sequence = 3 },
        false,
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
    defer storage.close(std.testing.io) catch {};

    const Completion = struct {
        io: std.Io,
        event: std.Io.Event = .unset,
        failure: ?anyerror = null,

        fn complete(context: *anyopaque, failure: ?anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.failure = failure;
            self.event.set(self.io);
        }
    };
    var actual: [expected.len]u8 = undefined;
    const reads = [_]storage_api.Read{.{ .buffer = &actual, .offset = 512 }};
    var results: [1]storage_api.ReadResult = undefined;
    var completion: Completion = .{ .io = std.testing.io };
    try std.testing.expectEqual(
        storage_api.AsyncReadSubmit.submitted,
        try storage.submitReadManyAt(
            std.testing.io,
            &reads,
            &results,
            .{ .context = &completion, .complete = Completion.complete },
        ),
    );
    completion.event.waitUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(?anyerror, null), completion.failure);
    try std.testing.expectEqual(@as(?anyerror, null), results[0].failure);
    try std.testing.expectEqual(expected.len, results[0].amount);
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
