const std = @import("std");
const zettide = @import("zettide");

const ReplicaEndpoint = zettide.v3.replica_endpoint.ReplicaEndpoint;
const pool_blob_schedule = zettide.v3.pool_blob_schedule;
const scheduled_device = zettide.v3.pool_scheduled_data_device;
const storage_api = zettide.v3.storage;

const stripe_size = 1024 * 1024;
const member_count = 6;
const member_stripe_count = 32 * 1024;
const executor_lane_count = 4;
const queue_capacity = 256;
const max_reads = scheduled_device.max_read_count;

fn uninitialized(comptime T: type) T {
    // Skip ReleaseSafe poisoning when callers initialize every consumed element.
    @setRuntimeSafety(false);
    return undefined;
}

const AsyncReadTask = struct {
    reads: [max_reads]storage_api.Read = undefined,
    read_count: usize,
    results: []storage_api.ReadResult,
    data_length: u64,
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
    stats: *AsyncStats,
    fill_reads: bool,
    slots: [queue_capacity]AsyncSlot,
    enqueue_position: std.atomic.Value(usize) = .init(0),
    dequeue_position: usize = 0,
    wake: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: std.Thread,

    fn init(self: *AsyncLane, io: std.Io, stats: *AsyncStats, fill_reads: bool) !void {
        self.io = io;
        self.stats = stats;
        self.fill_reads = fill_reads;
        self.resetQueue();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn resetQueue(self: *AsyncLane) void {
        for (&self.slots, 0..) |*slot, index| slot.* = .{ .sequence = .init(index) };
        self.enqueue_position = .init(0);
        self.dequeue_position = 0;
        self.wake = .unset;
        self.stopping = .init(false);
    }

    fn stop(self: *AsyncLane) void {
        self.stopping.store(true, .release);
        self.wake.set(self.io);
        self.thread.join();
    }

    fn submit(self: *AsyncLane, task: AsyncReadTask) bool {
        var position = self.enqueue_position.load(.monotonic);
        while (true) {
            const slot = &self.slots[position % queue_capacity];
            const difference: isize = @bitCast(slot.sequence.load(.acquire) -% position);
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

    fn dequeue(self: *AsyncLane, task: *AsyncReadTask) bool {
        const position = self.dequeue_position;
        const slot = &self.slots[position % queue_capacity];
        if (slot.sequence.load(.acquire) != position +% 1) return false;
        task.* = slot.task;
        self.dequeue_position = position +% 1;
        slot.sequence.store(position +% queue_capacity, .release);
        return true;
    }

    fn run(self: *AsyncLane) void {
        var task = uninitialized(AsyncReadTask);
        while (true) {
            if (self.dequeue(&task)) {
                self.execute(task);
                continue;
            }
            self.wake.reset();
            if (self.dequeue(&task)) {
                self.execute(task);
                continue;
            }
            if (self.stopping.load(.acquire)) return;
            self.wake.waitUncancelable(self.io);
        }
    }

    fn execute(self: *AsyncLane, task: AsyncReadTask) void {
        var failure: ?anyerror = null;
        completeReads(
            task.reads[0..task.read_count],
            task.results,
            task.data_length,
            self.fill_reads,
        ) catch |err| {
            failure = err;
        };
        _ = self.stats.completions.fetchAdd(1, .monotonic);
        task.completion.complete(task.completion.context, failure);
    }
};

const AsyncReadExecutor = struct {
    lanes: [executor_lane_count]AsyncLane = undefined,
    count: usize = 0,
    next_lane: std.atomic.Value(u64) = .init(0),
    accepting: std.atomic.Value(bool) = .init(false),
    stats: AsyncStats = .{},

    fn init(self: *AsyncReadExecutor, io: std.Io, fill_reads: bool) !void {
        self.count = 0;
        self.next_lane = .init(0);
        self.accepting = .init(false);
        self.stats = .{};
        errdefer while (self.count != 0) {
            self.count -= 1;
            self.lanes[self.count].stop();
        };
        while (self.count < self.lanes.len) : (self.count += 1)
            try self.lanes[self.count].init(io, &self.stats, fill_reads);
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
        data_length: u64,
        completion: storage_api.AsyncReadCompletion,
    ) storage_api.AsyncReadSubmit {
        if (!self.accepting.load(.acquire) or reads.len > max_reads) return .unsupported;
        var task: AsyncReadTask = .{
            .read_count = reads.len,
            .results = results,
            .data_length = data_length,
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

    fn transportStats(self: *const AsyncReadExecutor) storage_api.TransportStats {
        return .{
            .queue_capacity = executor_lane_count * queue_capacity,
            .async_submissions = self.stats.submissions.load(.monotonic),
            .async_completions = self.stats.completions.load(.monotonic),
            .async_queue_full = self.stats.queue_full.load(.monotonic),
        };
    }

    fn resetStats(self: *AsyncReadExecutor) void {
        self.stats.submissions.store(0, .monotonic);
        self.stats.completions.store(0, .monotonic);
        self.stats.queue_full.store(0, .monotonic);
    }
};

const EndpointContext = struct {
    executor: *AsyncReadExecutor,
    data_length: u64,
    fill_reads: bool,

    fn endpoint(self: *EndpointContext) ReplicaEndpoint {
        return .init(
            self,
            .{ .logical_capacity = self.data_length, .data_length = self.data_length },
            &endpoint_vtable,
        );
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    executor: AsyncReadExecutor,
    endpoints: [member_count]EndpointContext,
    device: scheduled_device.Device,
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    read_policy: scheduled_device.ReadPolicy,
    read_path_metrics: ?*scheduled_device.ReadPathMetrics,
    fill_first_available_reads: bool,
) !storage_api.Storage {
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = undefined;
    context.allocator = allocator;
    context.executor = .{};
    const fill_reads = read_policy == .quorum or fill_first_available_reads;
    try context.executor.init(io, fill_reads);
    errdefer context.executor.stop();

    var geometries: [member_count]pool_blob_schedule.Geometry = undefined;
    for (&geometries, 0..) |*geometry, index| geometry.* = .{
        .slot = @intCast(index + 1),
        .available_stripes = member_stripe_count,
    };
    const plan = try pool_blob_schedule.build(stripe_size, &geometries, 17);
    var endpoints: [member_count]scheduled_device.MemberEndpoint = undefined;
    for (plan.memberSlice(), &context.endpoints, &endpoints) |entry, *endpoint_context, *endpoint| {
        const data_length = try std.math.mul(u64, entry.assigned_stripes, plan.stripe_size);
        endpoint_context.* = .{
            .executor = &context.executor,
            .data_length = data_length,
            .fill_reads = fill_reads,
        };
        endpoint.* = .{ .slot = entry.slot, .endpoint = endpoint_context.endpoint() };
    }
    context.device = try .initOptions(allocator, io, &endpoints, plan, .{
        .read_policy = read_policy,
        .read_path_metrics = read_path_metrics,
    });
    return .initBackend(
        context,
        &storage_vtable,
        context.device.capacity(),
        .pool_data,
        scheduled_device.minimum_io_size,
    );
}

fn completeReads(
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
    data_length: u64,
    fill_reads: bool,
) !void {
    if (reads.len != results.len) return error.InvalidReadBatch;
    for (results) |*result| result.* = .{};
    for (reads, results) |read, *result| {
        if (read.offset > data_length or read.buffer.len > data_length - read.offset) {
            result.failure = error.OutOfBounds;
            continue;
        }
        if (fill_reads) @memset(read.buffer, 0);
        result.amount = read.buffer.len;
    }
}

fn endpointReadMetadata(_: *anyopaque, _: u64, _: []u8) !void {
    return error.UnsupportedSyntheticOperation;
}

fn endpointReadData(context_raw: *anyopaque, offset: u64, buffer: []u8) !void {
    const context: *EndpointContext = @ptrCast(@alignCast(context_raw));
    var result: [1]storage_api.ReadResult = undefined;
    try completeReads(
        &.{.{ .buffer = buffer, .offset = offset }},
        &result,
        context.data_length,
        context.fill_reads,
    );
    if (result[0].failure) |err| return err;
}

fn endpointReadDataMany(
    context_raw: *anyopaque,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
) !void {
    const context: *EndpointContext = @ptrCast(@alignCast(context_raw));
    return completeReads(reads, results, context.data_length, context.fill_reads);
}

fn endpointSubmitReadDataMany(
    context_raw: *anyopaque,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
    completion: storage_api.AsyncReadCompletion,
) !storage_api.AsyncReadSubmit {
    const context: *EndpointContext = @ptrCast(@alignCast(context_raw));
    if (reads.len != results.len) return error.InvalidReadBatch;
    return context.executor.submit(reads, results, context.data_length, completion);
}

fn endpointWriteData(_: *anyopaque, _: u64, _: []const u8) !void {
    return error.ReadOnlyPoolData;
}

fn endpointWriteDataMany(_: *anyopaque, _: []const storage_api.Write) !void {
    return error.ReadOnlyPoolData;
}

fn endpointWriteMetadataDurable(_: *anyopaque, _: u64, _: []const u8) !void {
    return error.ReadOnlyPoolData;
}

fn endpointSync(_: *anyopaque) !void {}

const endpoint_vtable: ReplicaEndpoint.VTable = .{
    .read_metadata = endpointReadMetadata,
    .read_data = endpointReadData,
    .read_data_many = endpointReadDataMany,
    .submit_read_data_many = endpointSubmitReadDataMany,
    .write_data = endpointWriteData,
    .write_data_many = endpointWriteDataMany,
    .write_metadata_durable = endpointWriteMetadataDurable,
    .sync = endpointSync,
};

fn contextFromOpaque(context_raw: *anyopaque) *Context {
    return @ptrCast(@alignCast(context_raw));
}

fn storageSameIdentity(context_raw: *anyopaque, other_raw: *anyopaque) bool {
    return context_raw == other_raw;
}

fn storageReadAt(context_raw: *anyopaque, _: std.Io, buffer: []u8, offset: u64) !usize {
    const context = contextFromOpaque(context_raw);
    var result: [1]storage_api.ReadResult = undefined;
    try context.device.readManyAt(&.{.{ .buffer = buffer, .offset = offset }}, &result);
    if (result[0].failure) |err| return err;
    return result[0].amount;
}

fn storageReadManyAt(
    context_raw: *anyopaque,
    _: std.Io,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
) !void {
    return contextFromOpaque(context_raw).device.readManyAt(reads, results);
}

fn storageWriteAllAt(_: *anyopaque, _: std.Io, _: []const u8, _: u64) !void {
    return error.ReadOnlyPoolData;
}

fn storageWriteAllManyAt(_: *anyopaque, _: std.Io, _: []const storage_api.Write) !void {
    return error.ReadOnlyPoolData;
}

fn storageSync(context_raw: *anyopaque, _: std.Io) !void {
    return contextFromOpaque(context_raw).device.sync();
}

fn storageClose(context_raw: *anyopaque, _: std.Io) !void {
    const context = contextFromOpaque(context_raw);
    context.executor.stop();
    const allocator = context.allocator;
    allocator.destroy(context);
}

fn storageTransportKind(_: *anyopaque) storage_api.TransportKind {
    return .custom;
}

fn storageTransportStats(context_raw: *anyopaque, _: std.Io) storage_api.TransportStats {
    return contextFromOpaque(context_raw).executor.transportStats();
}

fn storageResetTransportStats(context_raw: *anyopaque, _: std.Io) void {
    contextFromOpaque(context_raw).executor.resetStats();
}

const storage_vtable: storage_api.Storage.VTable = .{
    .same_identity = storageSameIdentity,
    .read_at = storageReadAt,
    .read_many_at = storageReadManyAt,
    .write_all_at = storageWriteAllAt,
    .write_all_many_at = storageWriteAllManyAt,
    .sync_data = storageSync,
    .sync = storageSync,
    .close = storageClose,
    .transport_kind = storageTransportKind,
    .transport_stats = storageTransportStats,
    .reset_transport_stats = storageResetTransportStats,
};

test "synthetic executor completes on another thread" {
    const Completion = struct {
        io: std.Io,
        done: std.Io.Event = .unset,
        callback_thread: @TypeOf(std.Thread.getCurrentId()) = undefined,
        failure: ?anyerror = null,

        fn complete(context_raw: *anyopaque, failure: ?anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(context_raw));
            self.callback_thread = std.Thread.getCurrentId();
            self.failure = failure;
            self.done.set(self.io);
        }
    };

    var executor: AsyncReadExecutor = .{};
    try executor.init(std.testing.io, false);
    defer executor.stop();
    var buffer: [4096]u8 = undefined;
    const reads = [_]storage_api.Read{.{ .buffer = &buffer, .offset = 0 }};
    var results: [1]storage_api.ReadResult = undefined;
    var completion: Completion = .{ .io = std.testing.io };
    try std.testing.expectEqual(
        storage_api.AsyncReadSubmit.submitted,
        executor.submit(&reads, &results, buffer.len, .{
            .context = &completion,
            .complete = Completion.complete,
        }),
    );
    completion.done.waitUncancelable(std.testing.io);
    try std.testing.expect(completion.callback_thread != std.Thread.getCurrentId());
    try std.testing.expectEqual(@as(?anyerror, null), completion.failure);
    try std.testing.expectEqual(@as(usize, buffer.len), results[0].amount);
}

test "synthetic lane rejects a full queue and reuses every slot" {
    const Completion = struct {
        fn complete(_: *anyopaque, _: ?anyerror) void {}
    };

    var stats: AsyncStats = .{};
    var lane: AsyncLane = undefined;
    lane.io = std.testing.io;
    lane.stats = &stats;
    lane.fill_reads = false;
    lane.resetQueue();
    var completion_context: u8 = 0;
    var results: [0]storage_api.ReadResult = .{};
    var task = uninitialized(AsyncReadTask);

    for (0..2) |round| {
        for (0..queue_capacity) |index| {
            try std.testing.expect(lane.submit(.{
                .read_count = 0,
                .results = &results,
                .data_length = round * queue_capacity + index,
                .completion = .{
                    .context = &completion_context,
                    .complete = Completion.complete,
                },
            }));
        }
        try std.testing.expect(!lane.submit(.{
            .read_count = 0,
            .results = &results,
            .data_length = 0,
            .completion = .{
                .context = &completion_context,
                .complete = Completion.complete,
            },
        }));
        for (0..queue_capacity) |index| {
            if (!lane.dequeue(&task)) return error.MissingQueuedTask;
            try std.testing.expectEqual(
                @as(u64, @intCast(round * queue_capacity + index)),
                task.data_length,
            );
        }
        try std.testing.expect(!lane.dequeue(&task));
    }
}

test "synthetic executor handles concurrent producers and slot reuse" {
    const producer_count = 8;
    const requests_per_producer = 512;
    const request_count = producer_count * requests_per_producer;
    const Completion = struct {
        io: std.Io,
        remaining: std.atomic.Value(usize),
        failures: std.atomic.Value(usize) = .init(0),
        done: std.Io.Event = .unset,

        fn complete(context_raw: *anyopaque, failure: ?anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(context_raw));
            if (failure != null) _ = self.failures.fetchAdd(1, .monotonic);
            const previous = self.remaining.fetchSub(1, .acq_rel);
            std.debug.assert(previous != 0);
            if (previous == 1) self.done.set(self.io);
        }
    };
    const Producer = struct {
        executor: *AsyncReadExecutor,
        completion: *Completion,
        results: []storage_api.ReadResult,
        buffer: []u8,

        fn run(self: *@This()) void {
            const reads = [_]storage_api.Read{.{ .buffer = self.buffer, .offset = 0 }};
            for (0..self.results.len) |index| while (true) {
                switch (self.executor.submit(
                    &reads,
                    self.results[index..][0..1],
                    self.buffer.len,
                    .{ .context = self.completion, .complete = Completion.complete },
                )) {
                    .submitted => break,
                    .unsupported => std.Thread.yield() catch {},
                }
            };
        }
    };

    var executor: AsyncReadExecutor = .{};
    try executor.init(std.testing.io, false);
    defer executor.stop();
    var buffer: [1]u8 = .{0};
    var results: [request_count]storage_api.ReadResult = undefined;
    var completion: Completion = .{
        .io = std.testing.io,
        .remaining = .init(request_count),
    };
    var producers: [producer_count]Producer = undefined;
    for (&producers, 0..) |*producer, index| producer.* = .{
        .executor = &executor,
        .completion = &completion,
        .results = results[index * requests_per_producer ..][0..requests_per_producer],
        .buffer = &buffer,
    };
    var threads: [producer_count]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&threads, &producers) |*thread, *producer| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
        started += 1;
    }
    for (threads) |thread| thread.join();
    completion.done.waitUncancelable(std.testing.io);

    try std.testing.expectEqual(@as(usize, 0), completion.failures.load(.monotonic));
    for (results) |result| {
        try std.testing.expectEqual(@as(usize, buffer.len), result.amount);
        try std.testing.expectEqual(@as(?anyerror, null), result.failure);
    }
    const stats_snapshot = executor.transportStats();
    try std.testing.expectEqual(@as(u64, request_count), stats_snapshot.async_submissions);
    try std.testing.expectEqual(stats_snapshot.async_submissions, stats_snapshot.async_completions);
}

test "synthetic scheduled storage completes reads without touching buffers" {
    var metrics: scheduled_device.ReadPathMetrics = .{};
    var storage = try create(std.testing.allocator, std.testing.io, .first_available, &metrics, false);
    defer storage.close(std.testing.io) catch unreachable;

    var buffer: [4096]u8 = @splat(0x5a);
    var result: [1]storage_api.ReadResult = undefined;
    try storage.readManyAt(
        std.testing.io,
        &.{.{ .buffer = &buffer, .offset = 0 }},
        &result,
    );
    try std.testing.expectEqual(@as(usize, buffer.len), result[0].amount);
    try std.testing.expectEqual(@as(?anyerror, null), result[0].failure);
    try std.testing.expect(std.mem.allEqual(u8, &buffer, 0x5a));
    const transport_stats = storage.transportStats(std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), transport_stats.async_submissions);
    try std.testing.expectEqual(transport_stats.async_submissions, transport_stats.async_completions);
    try std.testing.expectEqual(@as(u64, 0), transport_stats.async_queue_full);
    try std.testing.expectEqual(@as(u64, 1), metrics.snapshot().async_submitted);
}

test "synthetic scheduled storage can fill first-available reads" {
    var storage = try create(std.testing.allocator, std.testing.io, .first_available, null, true);
    defer storage.close(std.testing.io) catch unreachable;

    var buffer: [4096]u8 = @splat(0x5a);
    var result: [1]storage_api.ReadResult = undefined;
    try storage.readManyAt(
        std.testing.io,
        &.{.{ .buffer = &buffer, .offset = 0 }},
        &result,
    );
    try std.testing.expectEqual(@as(usize, buffer.len), result[0].amount);
    try std.testing.expectEqual(@as(?anyerror, null), result[0].failure);
    try std.testing.expect(std.mem.allEqual(u8, &buffer, 0));
}

test "synthetic scheduled storage supplies matching quorum data" {
    var storage = try create(std.testing.allocator, std.testing.io, .quorum, null, false);
    defer storage.close(std.testing.io) catch unreachable;

    var buffer: [4096]u8 = @splat(0x5a);
    var result: [1]storage_api.ReadResult = undefined;
    try storage.readManyAt(
        std.testing.io,
        &.{.{ .buffer = &buffer, .offset = 0 }},
        &result,
    );
    try std.testing.expectEqual(@as(usize, buffer.len), result[0].amount);
    try std.testing.expectEqual(@as(?anyerror, null), result[0].failure);
    try std.testing.expect(std.mem.allEqual(u8, &buffer, 0));
    const transport_stats = storage.transportStats(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), transport_stats.async_submissions);
    try std.testing.expectEqual(transport_stats.async_submissions, transport_stats.async_completions);
}
