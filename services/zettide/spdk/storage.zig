const std = @import("std");
const storage_api = @import("../v3/storage.zig");

const c = @import("spdk_c");

const Context = struct {
    allocator: std.mem.Allocator,
    dispatcher: *c.struct_zettide_spdk_bdev_dispatcher,
    geometry: c.struct_zettide_spdk_bdev_geometry,
    canonical_name: [*:0]u8,
    async_submissions: std.atomic.Value(u64) = .init(0),
    async_completions: std.atomic.Value(u64) = .init(0),
    read_direct_batches: std.atomic.Value(u64) = .init(0),
    read_direct_bytes: std.atomic.Value(u64) = .init(0),
    read_bounce_batches: std.atomic.Value(u64) = .init(0),
    read_bounce_bytes: std.atomic.Value(u64) = .init(0),
    async_state: std.atomic.Value(u64) = .init(0),
    async_drained: std.Io.Event = .unset,
    // Recycling AsyncReadTask avoids the ReleaseSafe undefined-fill poison that
    // std.mem.Allocator applies on every create/destroy in the hot read path.
    task_pool: [task_pool_capacity]*AsyncReadTask = undefined,
    task_pool_count: usize = 0,
    task_pool_locked: std.atomic.Value(bool) = .init(false),
};

fn taskPoolLock(context: *Context) void {
    while (context.task_pool_locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
        std.atomic.spinLoopHint();
}

fn taskPoolUnlock(context: *Context) void {
    context.task_pool_locked.store(false, .release);
}

const max_async_reads = 32;
const async_closing: u64 = 1 << 63;
const async_count_mask = async_closing - 1;
const task_pool_capacity = 1024;

const AsyncReadTask = struct {
    context: *Context,
    io: std.Io,
    results: []storage_api.ReadResult,
    completion: storage_api.AsyncReadCompletion,
    submitted_count: usize = 0,
    total_bytes: u64 = 0,
    descriptors: [max_async_reads]c.struct_zettide_spdk_bdev_dispatcher_read = undefined,
    statuses: [max_async_reads]c_int = undefined,
    result_indexes: [max_async_reads]u8 = undefined,
};

pub fn open(
    allocator: std.mem.Allocator,
    runtime: *c.struct_zettide_spdk_runtime,
    name: []const u8,
    writable: bool,
) !storage_api.Storage {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);

    var dispatcher: ?*c.struct_zettide_spdk_bdev_dispatcher = null;
    try statusError(c.zettide_spdk_bdev_dispatcher_open(runtime, name_z.ptr, writable, &dispatcher));
    const opened = dispatcher orelse return error.UnexpectedSpdkStatus;
    errdefer statusError(c.zettide_spdk_bdev_dispatcher_close(opened)) catch {};

    var geometry: c.struct_zettide_spdk_bdev_geometry = undefined;
    try statusError(c.zettide_spdk_bdev_dispatcher_get_geometry(opened, &geometry));
    var canonical_name: [*c]u8 = null;
    try statusError(c.zettide_spdk_bdev_dispatcher_get_name(opened, &canonical_name));
    if (canonical_name == null) return error.UnexpectedSpdkStatus;
    errdefer c.free(canonical_name);
    const minimum_io_size = try validateGeometry(geometry, writable);
    const context = try allocator.create(Context);
    context.* = .{
        .allocator = allocator,
        .dispatcher = opened,
        .geometry = geometry,
        .canonical_name = @ptrCast(canonical_name),
    };
    return storage_api.Storage.initBackend(
        context,
        &storage_vtable,
        geometry.capacity_bytes,
        .spdk_bdev,
        minimum_io_size,
    );
}

fn sameIdentity(context_ptr: *anyopaque, other_context_ptr: *anyopaque) bool {
    const context: *const Context = @ptrCast(@alignCast(context_ptr));
    const other: *const Context = @ptrCast(@alignCast(other_context_ptr));
    return std.mem.eql(u8, std.mem.span(context.canonical_name), std.mem.span(other.canonical_name));
}

fn validateGeometry(geometry: c.struct_zettide_spdk_bdev_geometry, writable: bool) !u32 {
    if (geometry.capacity_bytes == 0 or geometry.logical_block_size == 0 or
        geometry.write_unit_blocks == 0 or geometry.buffer_alignment == 0 or
        geometry.capacity_bytes % geometry.logical_block_size != 0)
        return error.InvalidStorageGeometry;
    const write_unit_size = std.math.mul(
        u32,
        geometry.logical_block_size,
        geometry.write_unit_blocks,
    ) catch return error.InvalidStorageGeometry;
    const minimum_io_size = if (writable)
        @max(geometry.logical_block_size, write_unit_size)
    else
        geometry.logical_block_size;
    if (!std.math.isPowerOfTwo(minimum_io_size) or minimum_io_size > 4096 or
        4096 % minimum_io_size != 0)
        return error.UnsupportedStorageAlignment;
    if (writable and (geometry.flags & c.ZETTIDE_SPDK_BDEV_WRITABLE) == 0)
        return error.ReadOnlyStorage;
    if (writable and (geometry.flags & c.ZETTIDE_SPDK_BDEV_WRITE_CACHE) != 0 and
        (geometry.flags & c.ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED) == 0)
        return error.DurabilityUnavailable;
    return minimum_io_size;
}

fn readAt(context_ptr: *anyopaque, _: std.Io, buffer: []u8, offset: u64) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (buffer.len == 0) return 0;
    try validateIo(context, offset, buffer.len, context.geometry.logical_block_size);
    const dma_buffer = c.zettide_spdk_dma_malloc(buffer.len, context.geometry.buffer_alignment) orelse
        return error.OutOfMemory;
    defer c.zettide_spdk_dma_free(dma_buffer);
    try statusError(c.zettide_spdk_bdev_dispatcher_read(
        context.dispatcher,
        dma_buffer,
        offset,
        buffer.len,
    ));
    const dma_bytes: [*]const u8 = @ptrCast(dma_buffer);
    @memcpy(buffer, dma_bytes[0..buffer.len]);
    return buffer.len;
}

fn allocTask(context: *Context) !*AsyncReadTask {
    taskPoolLock(context);
    if (context.task_pool_count > 0) {
        context.task_pool_count -= 1;
        const task = context.task_pool[context.task_pool_count];
        taskPoolUnlock(context);
        return task;
    }
    taskPoolUnlock(context);
    return std.heap.c_allocator.create(AsyncReadTask);
}

fn freeTask(context: *Context, task: *AsyncReadTask) void {
    taskPoolLock(context);
    if (context.task_pool_count < task_pool_capacity) {
        context.task_pool[context.task_pool_count] = task;
        context.task_pool_count += 1;
        taskPoolUnlock(context);
        return;
    }
    taskPoolUnlock(context);
    std.heap.c_allocator.destroy(task);
}

fn submitReadManyAt(
    context_ptr: *anyopaque,
    io: std.Io,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
    completion: storage_api.AsyncReadCompletion,
) !storage_api.AsyncReadSubmit {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (reads.len != results.len) return error.InvalidReadBatch;
    if (reads.len > max_async_reads) return .unsupported;
    if (!acquireAsync(context)) return .unsupported;
    var completion_ref_owned = true;
    defer {
        releaseAsync(context, io);
        if (completion_ref_owned) releaseAsync(context, io);
    }
    for (results) |*result| result.* = .{};
    for (reads) |read| {
        if (read.buffer.len != 0)
            try validateIo(context, read.offset, read.buffer.len, context.geometry.logical_block_size);
    }

    const task = try allocTask(context);
    errdefer freeTask(context, task);
    task.* = .{
        .context = context,
        .io = io,
        .results = results,
        .completion = completion,
    };
    for (reads, 0..) |read, result_index| {
        if (read.buffer.len == 0) continue;
        const index = task.submitted_count;
        task.total_bytes +|= @intCast(read.buffer.len);
        task.result_indexes[index] = @intCast(result_index);
        task.descriptors[index] = .{
            .buffer = @ptrCast(read.buffer.ptr),
            .offset = read.offset,
            .length = read.buffer.len,
        };
        task.submitted_count += 1;
    }
    if (task.submitted_count == 0) {
        const callback = task.completion;
        freeTask(context, task);
        _ = context.async_submissions.fetchAdd(1, .monotonic);
        _ = context.async_completions.fetchAdd(1, .monotonic);
        callback.complete(callback.context, null);
        return .submitted;
    }

    _ = context.async_submissions.fetchAdd(1, .monotonic);
    const status = c.zettide_spdk_bdev_dispatcher_submit_read_many(
        context.dispatcher,
        &task.descriptors,
        task.submitted_count,
        &task.statuses,
        asyncReadComplete,
        task,
    );
    if (status != 0) {
        _ = context.async_submissions.fetchSub(1, .monotonic);
        try statusError(status);
    }
    completion_ref_owned = false;
    return .submitted;
}

fn asyncReadComplete(context_ptr: ?*anyopaque, direct: bool) callconv(.c) void {
    const task: *AsyncReadTask = @ptrCast(@alignCast(context_ptr.?));
    const context = task.context;
    const io = task.io;
    const completion = task.completion;
    for (
        task.statuses[0..task.submitted_count],
        task.descriptors[0..task.submitted_count],
        task.result_indexes[0..task.submitted_count],
    ) |status, descriptor, result_index| {
        const result = &task.results[result_index];
        if (status == 0) {
            result.amount = @intCast(descriptor.length);
        } else {
            result.failure = statusErrorValue(status);
        }
    }
    if (direct) {
        _ = context.read_direct_batches.fetchAdd(1, .monotonic);
        _ = context.read_direct_bytes.fetchAdd(task.total_bytes, .monotonic);
    } else {
        _ = context.read_bounce_batches.fetchAdd(1, .monotonic);
        _ = context.read_bounce_bytes.fetchAdd(task.total_bytes, .monotonic);
    }
    freeTask(context, task);
    _ = context.async_completions.fetchAdd(1, .monotonic);
    completion.complete(completion.context, null);
    releaseAsync(context, io);
}

fn writeAllAt(context_ptr: *anyopaque, _: std.Io, bytes: []const u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (bytes.len == 0) return;
    const write_unit_size = std.math.mul(
        u32,
        context.geometry.logical_block_size,
        context.geometry.write_unit_blocks,
    ) catch return error.InvalidStorageGeometry;
    try validateIo(context, offset, bytes.len, write_unit_size);
    const dma_buffer = c.zettide_spdk_dma_malloc(bytes.len, context.geometry.buffer_alignment) orelse
        return error.OutOfMemory;
    defer c.zettide_spdk_dma_free(dma_buffer);
    const dma_bytes: [*]u8 = @ptrCast(dma_buffer);
    @memcpy(dma_bytes[0..bytes.len], bytes);
    try statusError(c.zettide_spdk_bdev_dispatcher_write(
        context.dispatcher,
        dma_buffer,
        offset,
        bytes.len,
    ));
}

fn sync(context_ptr: *anyopaque, _: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if ((context.geometry.flags & c.ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED) == 0) return;
    try statusError(c.zettide_spdk_bdev_dispatcher_flush(
        context.dispatcher,
        0,
        context.geometry.capacity_bytes,
    ));
}

fn close(context_ptr: *anyopaque, io: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    const active = context.async_state.fetchOr(async_closing, .acq_rel) & async_count_mask;
    if (active != 0) {
        context.async_drained.waitUncancelable(io);
        while (context.async_state.load(.acquire) & async_count_mask != 0)
            std.atomic.spinLoopHint();
    }
    const close_error = statusError(c.zettide_spdk_bdev_dispatcher_close(context.dispatcher));
    taskPoolLock(context);
    const pooled = context.task_pool_count;
    context.task_pool_count = 0;
    taskPoolUnlock(context);
    for (context.task_pool[0..pooled]) |task| std.heap.c_allocator.destroy(task);
    c.free(context.canonical_name);
    const allocator = context.allocator;
    allocator.destroy(context);
    close_error catch |err| {
        // A failed C close cannot be retried through a safely owned Zig context. The
        // dispatcher and its runtime references are intentionally abandoned here.
        return err;
    };
}

fn acquireAsync(context: *Context) bool {
    var state = context.async_state.load(.monotonic);
    while (state & async_closing == 0) {
        if (state & async_count_mask > async_count_mask - 2) return false;
        if (context.async_state.cmpxchgWeak(state, state + 2, .acquire, .monotonic)) |observed| {
            state = observed;
        } else return true;
    }
    return false;
}

fn releaseAsync(context: *Context, io: std.Io) void {
    var state = context.async_state.load(.monotonic);
    while (true) {
        std.debug.assert(state & async_count_mask != 0);
        if (state == async_closing | 1) {
            // Complete the wake before publishing zero so close cannot destroy the event early.
            context.async_drained.set(io);
            context.async_state.store(async_closing, .release);
            return;
        }
        if (context.async_state.cmpxchgWeak(state, state - 1, .release, .monotonic)) |observed| {
            state = observed;
        } else return;
    }
}

fn transportStats(context_ptr: *anyopaque, _: std.Io) storage_api.TransportStats {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    return .{
        .async_submissions = context.async_submissions.load(.monotonic),
        .async_completions = context.async_completions.load(.monotonic),
        .read_direct_batches = context.read_direct_batches.load(.monotonic),
        .read_direct_bytes = context.read_direct_bytes.load(.monotonic),
        .read_bounce_batches = context.read_bounce_batches.load(.monotonic),
        .read_bounce_bytes = context.read_bounce_bytes.load(.monotonic),
    };
}

fn resetTransportStats(context_ptr: *anyopaque, _: std.Io) void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.async_submissions.store(0, .monotonic);
    context.async_completions.store(0, .monotonic);
    context.read_direct_batches.store(0, .monotonic);
    context.read_direct_bytes.store(0, .monotonic);
    context.read_bounce_batches.store(0, .monotonic);
    context.read_bounce_bytes.store(0, .monotonic);
}

fn validateIo(context: *const Context, offset: u64, len: usize, alignment: u32) !void {
    const length = std.math.cast(u64, len) orelse return error.StorageOutOfBounds;
    if (offset > context.geometry.capacity_bytes or
        length > context.geometry.capacity_bytes - offset)
        return error.StorageOutOfBounds;
    if (offset % alignment != 0 or length % alignment != 0)
        return error.UnalignedStorageIo;
}

fn statusError(status: c_int) !void {
    if (status == 0) return;
    return switch (-status) {
        c.ENODEV => error.StorageRemoved,
        c.EPERM => error.StorageBusy,
        c.EOVERFLOW => error.InvalidStorageGeometry,
        c.ERANGE => error.StorageOutOfBounds,
        c.EINVAL => error.UnalignedStorageIo,
        c.EBADF => error.ReadOnlyStorage,
        c.ENOTSUP => error.UnsupportedStorageOperation,
        c.ENOMEM => error.OutOfMemory,
        c.EDEADLK => error.SpdkThreadViolation,
        c.EBUSY => error.StorageOperationsActive,
        c.ESHUTDOWN => error.RuntimeStopped,
        c.EIO => error.StorageIo,
        else => error.UnexpectedSpdkStatus,
    };
}

fn statusErrorValue(status: c_int) anyerror {
    statusError(status) catch |err| return err;
    return error.UnexpectedSpdkStatus;
}

const storage_vtable: storage_api.Storage.VTable = .{
    .same_identity = sameIdentity,
    .read_at = readAt,
    .submit_read_many_at = submitReadManyAt,
    .write_all_at = writeAllAt,
    .sync = sync,
    .close = close,
    .transport_stats = transportStats,
    .reset_transport_stats = resetTransportStats,
};
