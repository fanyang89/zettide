const std = @import("std");
const zettide = @import("zettide");
const args = @import("spdk_pool_data_nvmf_args.zig");
const synthetic_storage = @import("spdk_pool_data_synthetic_storage.zig");

const c = @import("spdk_c");

fn uninitialized(comptime T: type) T {
    // Skip ReleaseSafe poisoning when callers initialize every consumed element.
    @setRuntimeSafety(false);
    return undefined;
}

const block_size = 4096;
const max_batch_requests = 32;
const max_batch_bytes = 1024 * 1024;
const queue_capacity = 2048;
const Frontend = enum { nvmf, vhost };
const runtime_config =
    \\{"subsystems":[
    \\{"subsystem":"bdev","config":[
    \\{"method":"bdev_set_options","params":{"bdev_io_pool_size":16384,"bdev_io_cache_size":256}}]},
    \\{"subsystem":"nvmf","config":[
    \\{"method":"nvmf_create_transport","params":{"trtype":"TCP","max_queue_depth":256,"max_io_size":1048576}}]}]}
;
const rdma_runtime_config =
    \\{"subsystems":[
    \\{"subsystem":"iobuf","config":[
    \\{"method":"iobuf_set_options","params":{"small_pool_count":4096,"large_pool_count":1024}}]},
    \\{"subsystem":"bdev","config":[
    \\{"method":"bdev_set_options","params":{"bdev_io_pool_size":4096,"bdev_io_cache_size":128}}]},
    \\{"subsystem":"nvmf","config":[
    \\{"method":"nvmf_create_transport","params":{"trtype":"RDMA","max_queue_depth":128,"max_io_size":131072,"max_srq_depth":1024,"iobuf_small_cache_size":128,"iobuf_large_cache_size":32}}]}]}
;

fn pcieRuntimeConfig(
    allocator: std.mem.Allocator,
    namespaces: []const args.PcieNamespace,
) ![]u8 {
    if (namespaces.len != 2) return error.PcieRequiresTwoNamespaces;
    if (namespaces[0].nsid != 1 or namespaces[1].nsid != 1)
        return error.UnsupportedPcieNamespaceId;
    if (std.mem.eql(u8, namespaces[0].bdf, namespaces[1].bdf))
        return error.DuplicatePcieController;
    return std.fmt.allocPrint(allocator,
        \\{{"subsystems":[
        \\{{"subsystem":"bdev","config":[
        \\{{"method":"bdev_set_options","params":{{"bdev_io_pool_size":16384,"bdev_io_cache_size":256}}}},
        \\{{"method":"bdev_nvme_attach_controller","params":{{"name":"ZettidePhysical0","trtype":"PCIe","traddr":"{s}"}}}},
        \\{{"method":"bdev_nvme_attach_controller","params":{{"name":"ZettidePhysical1","trtype":"PCIe","traddr":"{s}"}}}}]}},
        \\{{"subsystem":"nvmf","config":[
        \\{{"method":"nvmf_create_transport","params":{{"trtype":"TCP","max_queue_depth":256,"max_io_size":1048576}}}}]}}]}}
    , .{ namespaces[0].bdf, namespaces[1].bdf });
}

const Worker = struct {
    const Request = struct {
        operation: c.enum_zettide_spdk_bdev_provider_operation = undefined,
        offset: u64 = 0,
        buffer: ?*anyopaque = null,
        length: usize = 0,
        complete: c.zettide_spdk_bdev_provider_complete = null,
        complete_context: ?*anyopaque = null,
    };

    const Slot = struct {
        sequence: std.atomic.Value(usize),
        request: Request = .{},
    };

    const Queued = struct {
        request: Request,
    };

    const ReadGroup = struct {
        queued: [max_batch_requests]Queued = undefined,
        count: usize = 0,
    };

    // DispatchSlot carries everything an in-flight read group needs so the
    // group can be submitted asynchronously and completed from the storage
    // completion callback without any thread handoff.
    const DispatchSlot = struct {
        worker: *Worker,
        batch: ReadGroup = undefined,
        reads: [max_batch_requests]zettide.v3.storage.Read = undefined,
        results: [max_batch_requests]zettide.v3.storage.ReadResult = undefined,
        in_use: std.atomic.Value(bool) = .init(false),
    };

    io: std.Io,
    storage: *zettide.v3.storage.Storage,
    concurrent_group_count: usize,
    inline_batches: bool,
    slots: [queue_capacity]Slot,
    read_slots: []DispatchSlot,
    async_submit: bool = true,
    inflight: std.atomic.Value(usize) = .init(0),
    slot_free: std.Io.Event = .unset,
    slot_waiting: std.atomic.Value(bool) = .init(false),
    enqueue_position: std.atomic.Value(usize) = .init(0),
    dequeue_position: usize = 0,
    wake: std.Io.Event = .unset,
    waiting: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    submit_attempts: std.atomic.Value(u64) = .init(0),
    accepted: std.atomic.Value(u64) = .init(0),
    queue_full_rejects: std.atomic.Value(u64) = .init(0),
    current_occupancy: std.atomic.Value(usize) = .init(0),
    high_water: std.atomic.Value(usize) = .init(0),
    read_group_count: std.atomic.Value(u64) = .init(0),
    grouped_request_count: std.atomic.Value(u64) = .init(0),
    grouped_bytes: std.atomic.Value(u64) = .init(0),
    completed_requests: std.atomic.Value(u64) = .init(0),
    thread: std.Thread,

    fn create(
        io: std.Io,
        storage: *zettide.v3.storage.Storage,
        concurrent_group_count: usize,
        inline_batches: bool,
    ) !*Worker {
        const self = try std.heap.c_allocator.create(Worker);
        errdefer std.heap.c_allocator.destroy(self);
        self.* = undefined;
        self.io = io;
        self.storage = storage;
        self.concurrent_group_count = concurrent_group_count;
        self.inline_batches = inline_batches;
        self.read_slots = try std.heap.c_allocator.alloc(
            DispatchSlot,
            @max(concurrent_group_count, 64),
        );
        errdefer std.heap.c_allocator.free(self.read_slots);
        for (self.read_slots) |*slot| slot.* = .{ .worker = self };
        for (&self.slots, 0..) |*slot, index| slot.* = .{ .sequence = .init(index) };
        self.enqueue_position = .init(0);
        self.dequeue_position = 0;
        self.wake = .unset;
        self.waiting = .init(false);
        self.stopping = .init(false);
        self.submit_attempts = .init(0);
        self.accepted = .init(0);
        self.queue_full_rejects = .init(0);
        self.current_occupancy = .init(0);
        self.high_water = .init(0);
        self.read_group_count = .init(0);
        self.grouped_request_count = .init(0);
        self.grouped_bytes = .init(0);
        self.completed_requests = .init(0);
        self.thread = try std.Thread.spawn(.{}, Worker.run, .{self});
        return self;
    }

    /// Call only after the provider has been unregistered.
    fn close(self: *Worker) void {
        self.stopping.store(true, .release);
        self.wake.set(self.io);
        self.thread.join();
        std.debug.print(
            "provider_worker_metrics submit_attempts={d} accepted={d} queue_full_rejects={d} current_occupancy={d} high_water={d} read_group_count={d} grouped_request_count={d} grouped_bytes={d} completed_requests={d}\n",
            .{
                self.submit_attempts.load(.monotonic),
                self.accepted.load(.monotonic),
                self.queue_full_rejects.load(.monotonic),
                self.current_occupancy.load(.monotonic),
                self.high_water.load(.monotonic),
                self.read_group_count.load(.monotonic),
                self.grouped_request_count.load(.monotonic),
                self.grouped_bytes.load(.monotonic),
                self.completed_requests.load(.monotonic),
            },
        );
        std.heap.c_allocator.free(self.read_slots);
        std.heap.c_allocator.destroy(self);
    }

    fn submit(
        context_raw: ?*anyopaque,
        operation: c.enum_zettide_spdk_bdev_provider_operation,
        offset: u64,
        buffer: ?*anyopaque,
        length_raw: u64,
        complete: c.zettide_spdk_bdev_provider_complete,
        complete_context: ?*anyopaque,
    ) callconv(.c) c_int {
        const context = context_raw orelse return -c.EINVAL;
        const self: *Worker = @ptrCast(@alignCast(context));
        _ = self.submit_attempts.fetchAdd(1, .monotonic);
        if (complete == null) return -c.EINVAL;
        if (operation == c.ZETTIDE_SPDK_BDEV_PROVIDER_WRITE) return -c.EROFS;
        if (operation != c.ZETTIDE_SPDK_BDEV_PROVIDER_READ and
            operation != c.ZETTIDE_SPDK_BDEV_PROVIDER_FLUSH and
            operation != c.ZETTIDE_SPDK_BDEV_PROVIDER_RESET) return -c.EINVAL;
        const length = std.math.cast(usize, length_raw) orelse return -c.EOVERFLOW;
        if (operation == c.ZETTIDE_SPDK_BDEV_PROVIDER_READ and
            ((length != 0 and buffer == null) or length > max_batch_bytes or
                offset > self.storage.capacity() or length > self.storage.capacity() - offset))
            return -c.ERANGE;
        if (self.stopping.load(.acquire)) return -c.ESHUTDOWN;

        var position = self.enqueue_position.load(.monotonic);
        while (true) {
            const slot = &self.slots[position % queue_capacity];
            const sequence = slot.sequence.load(.acquire);
            if (sequence == position) {
                if (self.enqueue_position.cmpxchgWeak(
                    position,
                    position + 1,
                    .monotonic,
                    .monotonic,
                )) |observed| {
                    position = observed;
                    continue;
                }
                slot.request = .{
                    .operation = operation,
                    .offset = offset,
                    .buffer = buffer,
                    .length = length,
                    .complete = complete,
                    .complete_context = complete_context,
                };
                self.recordAccepted();
                slot.sequence.store(position + 1, .release);
                // Signal only when the worker is actually blocked in next();
                // steady-state submits skip the futex wake entirely.
                if (self.waiting.swap(false, .seq_cst)) self.wake.set(self.io);
                return 0;
            }
            if (sequence < position) {
                _ = self.queue_full_rejects.fetchAdd(1, .monotonic);
                return -c.EAGAIN;
            }
            position = self.enqueue_position.load(.monotonic);
        }
    }

    fn recordAccepted(self: *Worker) void {
        _ = self.accepted.fetchAdd(1, .monotonic);
        const occupancy = self.current_occupancy.fetchAdd(1, .monotonic) + 1;
        var high_water = self.high_water.load(.monotonic);
        while (occupancy > high_water) {
            if (self.high_water.cmpxchgWeak(
                high_water,
                occupancy,
                .monotonic,
                .monotonic,
            )) |observed| {
                high_water = observed;
            } else break;
        }
    }

    fn dequeue(self: *Worker) ?Queued {
        const position = self.dequeue_position;
        const slot = &self.slots[position % queue_capacity];
        if (slot.sequence.load(.acquire) != position + 1) return null;
        const request = slot.request;
        self.dequeue_position = position + 1;
        slot.sequence.store(position + queue_capacity, .release);
        return .{ .request = request };
    }

    fn next(self: *Worker) ?Queued {
        while (true) {
            if (self.dequeue()) |queued| return queued;
            self.wake.reset();
            if (self.dequeue()) |queued| return queued;
            if (self.stopping.load(.acquire)) return null;
            // Announce the wait before the final dequeue check. Submit publishes
            // the slot before swapping this flag (both seq_cst), so a missed
            // dequeue implies the submitter observed the flag and will set wake.
            self.waiting.store(true, .seq_cst);
            if (self.dequeue()) |queued| {
                _ = self.waiting.swap(false, .seq_cst);
                return queued;
            }
            self.wake.waitUncancelable(self.io);
            _ = self.waiting.swap(false, .seq_cst);
        }
    }

    fn run(self: *Worker) void {
        var pending: ?Queued = null;
        while (pending orelse self.next()) |queued| {
            pending = null;
            if (queued.request.operation != c.ZETTIDE_SPDK_BDEV_PROVIDER_READ) {
                self.drainInflight();
                self.completeQueued(queued, 0);
                continue;
            }

            var batch: ReadGroup = .{
                .queued = uninitialized([max_batch_requests]Queued),
            };
            batch.queued[0] = queued;
            batch.count = 1;
            var total_bytes = queued.request.length;
            while (batch.count < max_batch_requests) {
                const candidate = self.dequeue() orelse break;
                const request = candidate.request;
                if (request.operation != c.ZETTIDE_SPDK_BDEV_PROVIDER_READ or
                    total_bytes + request.length > max_batch_bytes)
                {
                    pending = candidate;
                    break;
                }
                batch.queued[batch.count] = candidate;
                batch.count += 1;
                total_bytes += request.length;
            }
            _ = self.read_group_count.fetchAdd(1, .monotonic);
            _ = self.grouped_request_count.fetchAdd(batch.count, .monotonic);
            _ = self.grouped_bytes.fetchAdd(total_bytes, .monotonic);
            if (!self.async_submit) {
                self.executeReadBatch(&batch);
                continue;
            }
            self.submitReadBatchAsync(batch);
        }
        self.drainInflight();
    }

    fn acquireDispatchSlot(self: *Worker) *DispatchSlot {
        while (true) {
            if (self.tryAcquireDispatchSlot()) |slot| return slot;
            self.slot_free.reset();
            if (self.tryAcquireDispatchSlot()) |slot| return slot;
            // Same announcement protocol as next(): the releasing callback
            // stores in_use=false before swapping this flag (both seq_cst), so
            // a missed rescan implies the releaser observed the flag.
            self.slot_waiting.store(true, .seq_cst);
            if (self.tryAcquireDispatchSlot()) |slot| {
                _ = self.slot_waiting.swap(false, .seq_cst);
                return slot;
            }
            self.slot_free.waitUncancelable(self.io);
            _ = self.slot_waiting.swap(false, .seq_cst);
        }
    }

    fn tryAcquireDispatchSlot(self: *Worker) ?*DispatchSlot {
        for (self.read_slots) |*slot| {
            if (!slot.in_use.load(.acquire) and
                slot.in_use.cmpxchgStrong(false, true, .acq_rel, .acquire) == null)
                return slot;
        }
        return null;
    }

    fn releaseDispatchSlot(self: *Worker, slot: *DispatchSlot) void {
        slot.in_use.store(false, .release);
        if (self.slot_waiting.swap(false, .seq_cst)) self.slot_free.set(self.io);
    }

    fn drainInflight(self: *Worker) void {
        while (self.inflight.load(.acquire) != 0) {
            self.slot_free.reset();
            if (self.inflight.load(.acquire) == 0) break;
            self.slot_waiting.store(true, .seq_cst);
            if (self.inflight.load(.acquire) == 0) {
                _ = self.slot_waiting.swap(false, .seq_cst);
                break;
            }
            self.slot_free.waitUncancelable(self.io);
            _ = self.slot_waiting.swap(false, .seq_cst);
        }
    }

    fn submitReadBatchAsync(self: *Worker, batch: ReadGroup) void {
        const slot = self.acquireDispatchSlot();
        slot.batch = batch;
        const count = batch.count;
        for (slot.batch.queued[0..count], slot.reads[0..count]) |queued, *read| {
            const request = queued.request;
            read.* = .{
                .buffer = if (request.length == 0)
                    @as([]u8, &.{})
                else
                    @as([*]u8, @ptrCast(request.buffer.?))[0..request.length],
                .offset = request.offset,
            };
        }
        _ = self.inflight.fetchAdd(1, .monotonic);
        const submitted = self.storage.submitReadManyAt(
            self.io,
            slot.reads[0..count],
            slot.results[0..count],
            .{ .context = slot, .complete = readGroupComplete },
        ) catch |err| {
            _ = self.inflight.fetchSub(1, .monotonic);
            const status = errorStatus(err);
            var statuses = uninitialized([max_batch_requests]c_int);
            @memset(statuses[0..count], status);
            self.completeReadBatch(&slot.batch, statuses[0..count]);
            self.releaseDispatchSlot(slot);
            return;
        };
        switch (submitted) {
            .submitted => {},
            .unsupported => {
                // Storage without an async path (e.g. synthetic): fall back to
                // the blocking executor for this and all later groups.
                _ = self.inflight.fetchSub(1, .monotonic);
                slot.in_use.store(false, .release);
                self.async_submit = false;
                self.executeReadBatch(&batch);
            },
        }
    }

    fn readGroupComplete(context: *anyopaque, failure: ?anyerror) void {
        const slot: *DispatchSlot = @ptrCast(@alignCast(context));
        const self = slot.worker;
        const count = slot.batch.count;
        var statuses = uninitialized([max_batch_requests]c_int);
        for (slot.batch.queued[0..count], slot.results[0..count], statuses[0..count]) |queued, result, *status| {
            status.* = if (failure) |err|
                errorStatus(err)
            else if (result.failure) |err|
                errorStatus(err)
            else if (result.amount != queued.request.length)
                -c.EIO
            else
                0;
        }
        self.completeReadBatch(&slot.batch, statuses[0..count]);
        _ = self.inflight.fetchSub(1, .monotonic);
        self.releaseDispatchSlot(slot);
    }

    fn executeReadBatch(self: *Worker, batch: *const ReadGroup) void {
        var reads = uninitialized([max_batch_requests]zettide.v3.storage.Read);
        var results = uninitialized([max_batch_requests]zettide.v3.storage.ReadResult);
        var statuses = uninitialized([max_batch_requests]c_int);
        for (batch.queued[0..batch.count], reads[0..batch.count]) |queued, *read| {
            const request = queued.request;
            read.* = .{
                .buffer = if (request.length == 0)
                    @as([]u8, &.{})
                else
                    @as([*]u8, @ptrCast(request.buffer.?))[0..request.length],
                .offset = request.offset,
            };
        }
        self.storage.readManyAt(self.io, reads[0..batch.count], results[0..batch.count]) catch |err| {
            const status = errorStatus(err);
            @memset(statuses[0..batch.count], status);
            self.completeReadBatch(batch, statuses[0..batch.count]);
            return;
        };
        for (batch.queued[0..batch.count], results[0..batch.count], statuses[0..batch.count]) |queued, result, *status| {
            status.* = if (result.failure) |err|
                errorStatus(err)
            else if (result.amount != queued.request.length)
                -c.EIO
            else
                0;
        }
        self.completeReadBatch(batch, statuses[0..batch.count]);
    }

    fn completeReadBatch(self: *Worker, batch: *const ReadGroup, statuses: []const c_int) void {
        var completions: [max_batch_requests]c.struct_zettide_spdk_bdev_provider_completion = undefined;
        for (batch.queued[0..batch.count], statuses, completions[0..batch.count]) |queued, status, *completion| {
            completion.* = .{
                .context = queued.request.complete_context,
                .status = status,
            };
        }
        c.zettide_spdk_bdev_provider_complete_batch(&completions, batch.count);
        _ = self.current_occupancy.fetchSub(batch.count, .monotonic);
        _ = self.completed_requests.fetchAdd(batch.count, .monotonic);
    }

    fn completeQueued(self: *Worker, queued: Queued, status: c_int) void {
        queued.request.complete.?(queued.request.complete_context, status);
        _ = self.current_occupancy.fetchSub(1, .monotonic);
        _ = self.completed_requests.fetchAdd(1, .monotonic);
    }
};

const submit_callback: c.zettide_spdk_bdev_provider_submit = Worker.submit;

pub export fn zettide_spdk_pool_data_nvmf_benchmark(
    ready_path_z: [*:0]const u8,
    expected_pool_id_z: [*:0]const u8,
    read_policy_raw: c_int,
    device_count_raw: c_int,
    device_paths: [*]const [*:0]const u8,
) c_int {
    run(
        std.mem.span(ready_path_z),
        std.mem.span(expected_pool_id_z),
        read_policy_raw,
        device_count_raw,
        device_paths,
    ) catch |err| {
        std.debug.print("Scheduled Pool data NVMe-oF benchmark failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(
    ready_path: []const u8,
    expected_pool_id_text: []const u8,
    read_policy_raw: c_int,
    device_count_raw: c_int,
    device_paths: [*]const [*:0]const u8,
) !void {
    const allocator = std.heap.c_allocator;
    const device_count = std.math.cast(usize, device_count_raw) orelse return error.InvalidDeviceCount;
    if (device_count > zettide.v3.pool_member_set.max_member_count)
        return error.InvalidDeviceCount;
    const read_policy: zettide.v3.pool_scheduled_data_device.ReadPolicy = switch (try args.parseReadPolicy(read_policy_raw)) {
        .first_available => .first_available,
        .quorum => .quorum,
    };
    const expected_pool_id = try args.parsePoolId(expected_pool_id_text);
    const benchmark_mode = try args.parseBenchmarkMode(
        if (c.getenv("ZETTIDE_POOL_DATA_BENCHMARK_MODE")) |value| std.mem.span(value) else null,
    );
    const storage_transport = try args.parseStorageTransport(
        if (c.getenv("ZETTIDE_POOL_DATA_STORAGE_TRANSPORT")) |value| std.mem.span(value) else null,
    );
    if (storage_transport == .synthetic) {
        if (device_count != 0) return error.InvalidSyntheticStorageConfiguration;
    } else if (device_count == 0) {
        return error.InvalidDeviceCount;
    }
    const frontend_text = if (c.getenv("ZETTIDE_POOL_DATA_FRONTEND")) |value| std.mem.span(value) else "nvmf";
    const frontend: Frontend = if (std.mem.eql(u8, frontend_text, "nvmf"))
        .nvmf
    else if (std.mem.eql(u8, frontend_text, "vhost"))
        .vhost
    else
        return error.InvalidPoolDataFrontend;
    const vhost_socket_directory: ?[]const u8 = if (frontend == .vhost)
        if (c.getenv("ZETTIDE_VHOST_SOCKET_DIR")) |value| std.mem.span(value) else return error.MissingVhostSocketDirectory
    else
        null;
    const transport_text = if (c.getenv("ZETTIDE_NVMF_TRANSPORT")) |value| std.mem.span(value) else "tcp";
    const transport: ?zettide.spdk_nvmf_tcp_export.Transport = if (frontend == .nvmf)
        if (std.mem.eql(u8, transport_text, "tcp"))
            .tcp
        else if (std.mem.eql(u8, transport_text, "rdma"))
            .rdma
        else
            return error.InvalidNvmfTransport
    else
        null;
    const traddr = if (c.getenv("ZETTIDE_NVMF_TARGET_ADDR")) |value| std.mem.span(value) else "127.0.0.1";
    const trsvcid = if (c.getenv("ZETTIDE_NVMF_TARGET_PORT")) |value| std.mem.span(value) else "44220";
    const reactor_count = try args.parseReactorCount(if (c.getenv("ZETTIDE_NVMF_REACTOR_COUNT")) |value|
        std.mem.span(value)
    else
        null);
    const vhost_controller_count = if (frontend == .vhost)
        try args.parseVhostControllerCount(if (c.getenv("ZETTIDE_VHOST_CONTROLLER_COUNT")) |value|
            std.mem.span(value)
        else
            null, reactor_count)
    else
        0;
    const vhost_worker_count = if (frontend == .vhost and benchmark_mode == .pool)
        try args.parseVhostWorkerCount(
            if (c.getenv("ZETTIDE_VHOST_WORKER_COUNT")) |value| std.mem.span(value) else null,
            vhost_controller_count,
        )
    else
        1;
    const concurrent_group_count = try args.parseConcurrentGroupCount(
        if (c.getenv("ZETTIDE_POOL_DATA_CONCURRENT_GROUPS")) |value| std.mem.span(value) else null,
    );
    const preparation_mode = try args.parsePreparationMode(
        if (c.getenv("ZETTIDE_POOL_DATA_PREPARATION_MODE")) |value| std.mem.span(value) else null,
    );
    const raw_storage_mode = try zettide.v3.linux_block_device.TransportMode.parse(
        if (c.getenv("ZETTIDE_POOL_DATA_RAW_TRANSPORT")) |value| std.mem.span(value) else "auto",
    );
    const sqpoll_cpu_base = try args.parseOptionalCpuBase(
        if (c.getenv("ZETTIDE_POOL_DATA_SQPOLL_CPU_BASE")) |value| std.mem.span(value) else null,
    );
    const threaded_concurrency = try args.parseThreadedConcurrency(
        if (c.getenv("ZETTIDE_POOL_DATA_THREADED_CONCURRENCY")) |value| std.mem.span(value) else null,
    );
    const vhost_inline_batches = (try args.parseOptionalFlag(
        if (c.getenv("ZETTIDE_VHOST_INLINE_BATCHES")) |value| std.mem.span(value) else null,
    )) orelse (vhost_worker_count > 1);
    const vhost_coalescing = if (frontend == .vhost)
        try args.parseVhostCoalescing(
            if (c.getenv("ZETTIDE_VHOST_COALESCING_DELAY_BASE_US")) |value| std.mem.span(value) else null,
            if (c.getenv("ZETTIDE_VHOST_COALESCING_IOPS_THRESHOLD")) |value| std.mem.span(value) else null,
        )
    else
        null;
    const pcie_probe = (try args.parseOptionalFlag(
        if (c.getenv("ZETTIDE_POOL_DATA_PCIE_PROBE")) |value| std.mem.span(value) else null,
    )) orelse false;
    if (pcie_probe and storage_transport != .spdk_nvme_pcie)
        return error.InvalidPcieProbeConfiguration;
    var window_specs_buffer: [zettide.v3.pool_member_set.max_member_count]args.WindowSpec = undefined;
    const window_specs = try args.parseWindowSpecs(
        if (c.getenv("ZETTIDE_POOL_DATA_MEMBER_WINDOWS")) |value| std.mem.span(value) else null,
        &window_specs_buffer,
    );
    try validateWindowSpecs(window_specs, device_count);
    if (storage_transport == .synthetic and
        (benchmark_mode != .pool or preparation_mode != .none or pcie_probe or
            window_specs.len != 0 or raw_storage_mode != .auto or sqpoll_cpu_base != null or
            !std.mem.allEqual(u8, &expected_pool_id, 0)))
        return error.InvalidSyntheticStorageConfiguration;
    if (benchmark_mode == .raw_nvme and
        (frontend != .vhost or storage_transport != .spdk_nvme_pcie or
            preparation_mode != .none or pcie_probe or window_specs.len != 0 or
            device_count != 2 or vhost_controller_count != 2))
        return error.InvalidRawNvmeConfiguration;
    if (preparation_mode != .none) {
        if (storage_transport != .spdk_nvme_pcie or device_count != 2 or
            window_specs.len != 6 or pcie_probe)
            return error.InvalidPreparationConfiguration;
        const expected_is_zero = std.mem.allEqual(u8, &expected_pool_id, 0);
        if ((preparation_mode == .create) != expected_is_zero)
            return error.InvalidPreparationPoolId;
        try validatePreparationWindowSpecs(window_specs);
    }
    var pcie_namespaces: [2]args.PcieNamespace = undefined;
    if (storage_transport == .spdk_nvme_pcie) {
        if ((preparation_mode == .none and frontend != .vhost) or device_count != pcie_namespaces.len or
            (!pcie_probe and window_specs.len == 0 and benchmark_mode != .raw_nvme))
            return error.InvalidPcieStorageConfiguration;
        if (raw_storage_mode != .auto or sqpoll_cpu_base != null)
            return error.PcieStorageRejectsLinuxTransportOptions;
        for (device_paths[0..device_count], &pcie_namespaces) |device_path_z, *namespace|
            namespace.* = try args.parsePcieNamespace(std.mem.span(device_path_z));
        if (preparation_mode != .none and
            (pcie_namespaces[0].nsid != 1 or pcie_namespaces[1].nsid != 1))
            return error.InvalidPreparationNamespace;
    }

    var threaded: std.Io.Threaded = .init(allocator, .{
        .environ = .empty,
        .concurrent_limit = if (threaded_concurrency) |count| .limited(count) else .unlimited,
    });
    defer threaded.deinit();
    const io = threaded.io();
    var reactor_mask_buffer: [128]u8 = undefined;
    if (c.zettide_spdk_test_reactor_mask_count(
        &reactor_mask_buffer,
        reactor_mask_buffer.len,
        reactor_count,
    ) != 0)
        return error.ReactorMaskUnavailable;
    const reactor_mask = std.mem.sliceTo(&reactor_mask_buffer, 0);
    var signals: c.sigset_t = undefined;
    if (!pcie_probe and preparation_mode == .none) {
        if (c.sigemptyset(&signals) != 0 or
            c.sigaddset(&signals, c.SIGINT) != 0 or
            c.sigaddset(&signals, c.SIGTERM) != 0 or
            c.pthread_sigmask(c.SIG_BLOCK, &signals, null) != 0)
            return error.SignalSetupFailed;
    }
    const owned_runtime_config = if (storage_transport == .spdk_nvme_pcie)
        try pcieRuntimeConfig(allocator, &pcie_namespaces)
    else
        null;
    defer if (owned_runtime_config) |config| allocator.free(config);
    const selected_runtime_config = owned_runtime_config orelse
        if (transport == .rdma) rdma_runtime_config else runtime_config;
    std.debug.print("target-stage runtime start mode={s} frontend={s} storage_transport={s} socket={s} reactor_mask={s} vhost_controllers={d} vhost_workers={d} inline_batches={} coalescing_delay_base_us={?d} coalescing_iops_threshold={?d} concurrent_groups={d} raw_transport={s} sqpoll_cpu_base={?d} threaded_concurrency={?d}\n", .{
        @tagName(benchmark_mode),
        frontend_text,
        @tagName(storage_transport),
        vhost_socket_directory orelse "none",
        reactor_mask,
        vhost_controller_count,
        vhost_worker_count,
        vhost_inline_batches,
        if (vhost_coalescing) |coalescing| coalescing.delay_base_us else null,
        if (vhost_coalescing) |coalescing| coalescing.iops_threshold else null,
        concurrent_group_count,
        @tagName(raw_storage_mode),
        sqpoll_cpu_base,
        threaded_concurrency,
    });
    var runtime = try zettide.spdk_runtime.Runtime.start(allocator, .{
        .name = "zettide_spdk_pool_data_nvmf_benchmark",
        .reactor_mask = reactor_mask,
        .json_data = selected_runtime_config,
        .mem_size_mb = 512,
        .no_pci = storage_transport != .spdk_nvme_pcie,
        .no_huge = storage_transport != .spdk_nvme_pcie,
        .disable_cpumask_locks = true,
        .vhost_socket_path = vhost_socket_directory,
    });
    defer runtime.deinit();
    const runtime_handle: *anyopaque = @ptrCast(runtime.handle orelse return error.RuntimeStopped);
    std.debug.print("target-stage runtime ready\n", .{});
    if (benchmark_mode == .raw_nvme) {
        var controllers: [2]?*c.struct_zettide_spdk_vhost_blk_controller = @splat(null);
        var controller_count: usize = 0;
        defer while (controller_count > 0) {
            controller_count -= 1;
            closeRawVhostController(io, &controllers[controller_count]);
        };
        std.debug.print("target-stage raw NVMe export start controllers={d}\n", .{controllers.len});
        for (&controllers, 0..) |*controller, index| {
            var bdev_name_buffer: [32]u8 = undefined;
            const bdev_name = try std.fmt.bufPrintZ(&bdev_name_buffer, "ZettidePhysical{d}n1", .{index});
            var controller_name_buffer: [64]u8 = undefined;
            const controller_name = try std.fmt.bufPrintZ(
                &controller_name_buffer,
                "zettide-scheduled-pool-data-{d}",
                .{index},
            );
            var selected_mask_buffer: [32]u8 = undefined;
            const selected_mask = try args.reactorMaskAt(reactor_mask, index, &selected_mask_buffer);
            var controller_mask_buffer: [32]u8 = undefined;
            const controller_mask = try std.fmt.bufPrintZ(&controller_mask_buffer, "{s}", .{selected_mask});
            var options: c.struct_zettide_spdk_vhost_blk_controller_opts = undefined;
            c.zettide_spdk_vhost_blk_controller_opts_init(&options, @sizeOf(@TypeOf(options)));
            options.name = controller_name.ptr;
            options.bdev_name = bdev_name.ptr;
            options.cpumask = controller_mask.ptr;
            options.readonly = true;
            const status = c.zettide_spdk_vhost_blk_controller_create(
                @ptrCast(runtime_handle),
                &options,
                controller,
            );
            if (status != 0) return error.RawNvmeVhostControllerCreateFailed;
            controller_count += 1;
            const handle = controller.* orelse return error.UnexpectedControllerStatus;
            if (vhost_coalescing) |coalescing| {
                if (c.zettide_spdk_vhost_blk_controller_set_coalescing(
                    handle,
                    coalescing.delay_base_us,
                    coalescing.iops_threshold,
                ) != 0) return error.VhostCoalescingConfigurationFailed;
            }
            for (0..1000) |_| {
                if (c.zettide_spdk_vhost_blk_controller_is_ready(handle)) break;
                io.sleep(.fromMilliseconds(10), .awake) catch return error.VhostControllerReadyWaitFailed;
            } else return error.RawNvmeVhostControllerNotReady;
            const socket_path = std.mem.span(
                c.zettide_spdk_vhost_blk_controller_get_socket_path(handle) orelse
                    return error.RawNvmeVhostSocketUnavailable,
            );
            std.debug.print(
                "target-stage raw NVMe export ready index={d} bdev={s} cpumask={s} readonly=true socket={s}\n",
                .{ index, bdev_name, controller_mask, socket_path },
            );
        }
        try publishReadyAndWait(io, ready_path, &signals);
        return;
    }
    var physical_storages: [zettide.v3.pool_member_set.max_member_count]zettide.v3.storage.Storage = undefined;
    var physical_count: usize = 0;
    defer zettide.v3.storage.closeAll(physical_storages[0..physical_count], io) catch @panic("failed to close physical Pool storage");
    var member_storages: [zettide.v3.pool_member_set.max_member_count]zettide.v3.storage.Storage = undefined;
    var member_count: usize = 0;
    errdefer zettide.v3.storage.closeAll(member_storages[0..member_count], io) catch {};
    var read_path_metrics: zettide.v3.pool_scheduled_data_device.ReadPathMetrics = .{};
    var pool_storage: zettide.v3.storage.Storage = undefined;
    if (storage_transport == .synthetic) {
        pool_storage = try synthetic_storage.create(
            allocator,
            io,
            read_policy,
            &read_path_metrics,
            frontend == .nvmf,
        );
    } else {
        if (pcie_probe) {
            for (physical_storages[0..device_count], 0..) |*storage, index| {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "ZettidePhysical{d}n1", .{index});
                storage.* = try runtime.openStorage(allocator, name, false);
                physical_count += 1;
            }
            std.debug.print("target-stage PCIe probe ready namespaces={d}\n", .{physical_count});
            return;
        }
        if (window_specs.len == 0) {
            for (device_paths[0..device_count], member_storages[0..device_count], 0..) |device_path_z, *storage, index| {
                const opened = try zettide.v3.linux_block_device.openStorageOptionsModeAffinity(
                    io,
                    allocator,
                    std.mem.span(device_path_z),
                    false,
                    true,
                    raw_storage_mode,
                    if (sqpoll_cpu_base) |base| try std.math.add(u32, base, try std.math.mul(u32, @intCast(index), 2)) else null,
                );
                storage.* = opened.storage;
                member_count += 1;
            }
        } else {
            for (device_paths[0..device_count], physical_storages[0..device_count], 0..) |device_path_z, *storage, index| {
                storage.* = switch (storage_transport) {
                    .linux => (try zettide.v3.linux_block_device.openStorageOptionsModeAffinity(
                        io,
                        allocator,
                        std.mem.span(device_path_z),
                        false,
                        true,
                        raw_storage_mode,
                        if (sqpoll_cpu_base) |base| try std.math.add(u32, base, try std.math.mul(u32, @intCast(index), 2)) else null,
                    )).storage,
                    .spdk_nvme_pcie => open: {
                        var name_buffer: [32]u8 = undefined;
                        const name = try std.fmt.bufPrint(&name_buffer, "ZettidePhysical{d}n1", .{index});
                        break :open try runtime.openStorage(allocator, name, preparation_mode == .create);
                    },
                    .synthetic => unreachable,
                };
                physical_count += 1;
            }
            for (window_specs, member_storages[0..window_specs.len]) |spec, *storage| {
                storage.* = try zettide.v3.storage_window.create(
                    allocator,
                    &physical_storages[spec.device_index],
                    spec.offset,
                    spec.length,
                );
                member_count += 1;
            }
        }
        const transferring_count = member_count;
        member_count = 0;
        if (preparation_mode != .none) {
            const pool_id = try preparePool(
                io,
                allocator,
                member_storages[0..transferring_count],
                preparation_mode,
                expected_pool_id,
            );
            try publishPreparedPoolId(io, ready_path, pool_id);
            return;
        }
        var set = try zettide.v3.pool_member_set.PoolMemberSet.openStorages(
            io,
            allocator,
            member_storages[0..transferring_count],
            .read_only,
        );
        errdefer set.deinit();
        const authority = set.authority() orelse return error.MissingAuthority;
        if (!std.mem.eql(u8, &authority.topology.set_id, &expected_pool_id))
            return error.UnexpectedPoolId;
        if (try set.dataMode() != .blob or authority.layout.scheduled_blob == null)
            return error.ScheduledBlobPoolRequired;

        pool_storage = try zettide.v3.pool_data_storage.createOptions(
            allocator,
            io,
            &set,
            false,
            .{
                .read_policy = read_policy,
                .read_path_metrics = &read_path_metrics,
            },
        );
    }
    defer pool_storage.close(io) catch @panic("failed to close Pool data storage");
    defer {
        const metrics = read_path_metrics.snapshot();
        std.debug.print(
            "pool_read_path_metrics single_operation_batches={d} single_operation_items={d} multi_operation_batches={d} multi_operation_count={d} multi_operation_items={d} async_submit_attempts={d} async_submitted={d} async_fallbacks={d} async_submit_errors={d}\n",
            .{
                metrics.single_operation_batches,
                metrics.single_operation_items,
                metrics.multi_operation_batches,
                metrics.multi_operation_count,
                metrics.multi_operation_items,
                metrics.async_submit_attempts,
                metrics.async_submitted,
                metrics.async_fallbacks,
                metrics.async_submit_errors,
            },
        );
    }
    defer {
        var submissions: u64 = 0;
        var completions: u64 = 0;
        var queue_full: u64 = 0;
        var direct_batches: u64 = 0;
        var direct_bytes: u64 = 0;
        var bounce_batches: u64 = 0;
        var bounce_bytes: u64 = 0;
        if (storage_transport == .synthetic) {
            const stats = pool_storage.transportStats(io);
            submissions +|= stats.async_submissions;
            completions +|= stats.async_completions;
            queue_full +|= stats.async_queue_full;
            direct_batches +|= stats.read_direct_batches;
            direct_bytes +|= stats.read_direct_bytes;
            bounce_batches +|= stats.read_bounce_batches;
            bounce_bytes +|= stats.read_bounce_bytes;
        } else {
            for (physical_storages[0..physical_count]) |*storage| {
                const stats = storage.transportStats(io);
                submissions +|= stats.async_submissions;
                completions +|= stats.async_completions;
                queue_full +|= stats.async_queue_full;
                direct_batches +|= stats.read_direct_batches;
                direct_bytes +|= stats.read_direct_bytes;
                bounce_batches +|= stats.read_bounce_batches;
                bounce_bytes +|= stats.read_bounce_bytes;
            }
        }
        std.debug.print(
            "pool_async_metrics submissions={d} completions={d} queue_full={d} direct_batches={d} direct_bytes={d} bounce_batches={d} bounce_bytes={d}\n",
            .{ submissions, completions, queue_full, direct_batches, direct_bytes, bounce_batches, bounce_bytes },
        );
    }
    if (pool_storage.capacity() == 0 or pool_storage.capacity() % block_size != 0)
        return error.InvalidPoolDataCapacity;

    switch (frontend) {
        .nvmf => {
            std.debug.print("target-stage worker start\n", .{});
            const worker = try Worker.create(io, &pool_storage, concurrent_group_count, false);
            defer worker.close();
            const backend: zettide.spdk_vhost_block_export.Backend = .{
                .context = worker,
                .submit = submit_callback,
                .block_count = pool_storage.capacity() / block_size,
                .max_io_blocks = max_batch_bytes / block_size,
            };
            std.debug.print("target-stage worker ready\n", .{});
            std.debug.print("target-stage provider start\n", .{});
            var provider = try zettide.spdk_provider_bdev.ProviderBdev.create(
                allocator,
                runtime_handle,
                backend,
                "ZettideScheduledPoolData0",
            );
            defer provider.close() catch @panic("failed to unregister Pool data provider bdev");
            std.debug.print("target-stage provider ready\n", .{});
            std.debug.print("target-stage export start frontend=nvmf transport={s} traddr={s} trsvcid={s}\n", .{ transport_text, traddr, trsvcid });
            var export_handle = try zettide.spdk_nvmf_tcp_export.NvmfTcpExport.create(
                allocator,
                runtime_handle,
                .{
                    .bdev_name = "ZettideScheduledPoolData0",
                    .nqn = "nqn.2026-08.io.zettide:benchmark",
                    .serial_number = "ZETTIDEBENCH000001",
                    .model_number = "Zettide Scheduled Pool Data",
                    .traddr = traddr,
                    .trsvcid = trsvcid,
                    .allow_any_host = true,
                    .transport = transport.?,
                },
            );
            defer export_handle.close() catch @panic("failed to close Pool data NVMe-oF export");
            std.debug.print("target-stage export ready frontend=nvmf socket=none\n", .{});
            try publishReadyAndWait(io, ready_path, &signals);
        },
        .vhost => {
            var workers: [args.max_vhost_controller_count]*Worker = undefined;
            var worker_count: usize = 0;
            defer while (worker_count > 0) {
                worker_count -= 1;
                workers[worker_count].close();
            };
            while (worker_count < vhost_worker_count) : (worker_count += 1)
                workers[worker_count] = try Worker.create(io, &pool_storage, concurrent_group_count, vhost_inline_batches);
            var exports: [args.max_vhost_controller_count]zettide.spdk_vhost_block_export.VhostBlockExport = undefined;
            var export_count: usize = 0;
            defer while (export_count > 0) {
                export_count -= 1;
                closeVhostExport(io, &exports[export_count]);
            };
            std.debug.print("target-stage export start frontend=vhost socket_directory={s} controllers={d}\n", .{ vhost_socket_directory.?, vhost_controller_count });
            for (0..vhost_controller_count) |index| {
                const backend: zettide.spdk_vhost_block_export.Backend = .{
                    .context = workers[index % worker_count],
                    .submit = submit_callback,
                    .block_count = pool_storage.capacity() / block_size,
                    .max_io_blocks = max_batch_bytes / block_size,
                    .read_buffers_unchanged = storage_transport == .synthetic and read_policy == .first_available,
                };
                var bdev_name_buffer: [64]u8 = undefined;
                const bdev_name = try std.fmt.bufPrint(&bdev_name_buffer, "ZettideScheduledPoolData{d}", .{index});
                var controller_name_buffer: [64]u8 = undefined;
                const controller_name = try std.fmt.bufPrint(&controller_name_buffer, "zettide-scheduled-pool-data-{d}", .{index});
                var controller_mask_buffer: [32]u8 = undefined;
                const controller_mask = try args.reactorMaskAt(reactor_mask, index, &controller_mask_buffer);
                exports[index] = try zettide.spdk_vhost_block_export.VhostBlockExport.create(
                    allocator,
                    runtime_handle,
                    backend,
                    .{
                        .bdev_name = bdev_name,
                        .controller_name = controller_name,
                        .cpumask = controller_mask,
                        .readonly = true,
                    },
                );
                export_count += 1;
                if (vhost_coalescing) |coalescing| {
                    try exports[index].setCoalescing(
                        coalescing.delay_base_us,
                        coalescing.iops_threshold,
                    );
                }
                std.debug.print("target-stage export ready frontend=vhost index={d} cpumask={s} socket={s}\n", .{ index, controller_mask, exports[index].socketPath() });
            }
            try publishReadyAndWait(io, ready_path, &signals);
        },
    }
}

fn preparePool(
    io: std.Io,
    allocator: std.mem.Allocator,
    storages: []zettide.v3.storage.Storage,
    mode: args.PreparationMode,
    expected_pool_id: [16]u8,
) ![16]u8 {
    const set = try allocator.create(zettide.v3.pool_member_set.PoolMemberSet);
    defer allocator.destroy(set);
    switch (mode) {
        .none => unreachable,
        .create => {
            const outcome = try zettide.v3.pool_provision.create(io, allocator, storages, .{
                .protection = .replicated,
                .data_mode = .blob,
                .scheduled_blob = true,
                .label = "synthetic-dual-device-scheduled-nvmf",
            });
            var provisioned = switch (outcome) {
                .complete => |value| value,
                .partial => |partial| {
                    std.debug.print(
                        "Partial Pool creation id={x} completed_members={d} failed_member={d} cause={s}\n",
                        .{ partial.set_id, partial.completed_member_count, partial.failed_member_index, @errorName(partial.cause) },
                    );
                    return error.PartialPoolCreation;
                },
            };
            defer provisioned.deinit();
            set.* = try provisioned.intoMemberSet();
        },
        .validate => try zettide.v3.pool_member_set.PoolMemberSet.openStoragesInto(
            set,
            io,
            allocator,
            storages,
            .read_only,
        ),
    }
    defer set.deinit();
    if (set.suppliedCount() != 6) return error.IncompletePreparedPool;
    for (0..set.suppliedCount()) |index| {
        if (try set.memberAt(index) == null) return error.IncompletePreparedPool;
        switch (try set.statusAt(index)) {
            .authority, .active_voter => {},
            else => return error.IncompletePreparedPool,
        }
    }
    const authority = set.authority() orelse return error.MissingAuthority;
    if (authority.topology.member_count != 6 or authority.layout.kind != .replicated or
        authority.layout.scheduled_blob == null or authority.layout.scheduled_blob.?.member_count != 6 or
        try set.dataMode() != .blob)
        return error.InvalidPreparedPool;
    if (set.dataAccess() != .read_write) return error.PreparedPoolNotWritable;
    if (mode == .validate and !std.mem.eql(u8, &authority.topology.set_id, &expected_pool_id))
        return error.UnexpectedPoolId;
    return authority.topology.set_id;
}

fn publishPreparedPoolId(io: std.Io, ready_path: []const u8, pool_id: [16]u8) !void {
    const hex = "0123456789abcdef";
    var contents: [33]u8 = undefined;
    for (pool_id, 0..) |byte, index| {
        contents[index * 2] = hex[byte >> 4];
        contents[index * 2 + 1] = hex[byte & 0xf];
    }
    contents[32] = '\n';
    const ready = try std.Io.Dir.createFileAbsolute(io, ready_path, .{ .exclusive = true });
    defer ready.close(io);
    try ready.writeStreamingAll(io, &contents);
}

fn validateWindowSpecs(specs: []const args.WindowSpec, device_count: usize) !void {
    for (specs, 0..) |spec, index| {
        if (spec.device_index >= device_count) return error.InvalidStorageWindow;
        const end = std.math.add(u64, spec.offset, spec.length) catch return error.InvalidStorageWindow;
        for (specs[0..index]) |previous| {
            if (previous.device_index != spec.device_index) continue;
            const previous_end = std.math.add(u64, previous.offset, previous.length) catch return error.InvalidStorageWindow;
            if (spec.offset < previous_end and previous.offset < end)
                return error.OverlappingStorageWindows;
        }
    }
}

fn validatePreparationWindowSpecs(specs: []const args.WindowSpec) !void {
    if (specs.len != 6 or specs[0].length == 0 or specs[0].length % (1024 * 1024) != 0)
        return error.InvalidPreparationWindows;
    const length = specs[0].length;
    const expected_devices = [_]usize{ 0, 1, 1, 0, 0, 1 };
    const expected_slices = [_]u64{ 0, 0, 1, 1, 2, 2 };
    for (specs, expected_devices, expected_slices) |spec, device_index, slice_index| {
        if (spec.device_index != device_index or spec.length != length or
            spec.offset != (std.math.mul(u64, length, slice_index) catch return error.InvalidPreparationWindows))
            return error.InvalidPreparationWindows;
    }
}

fn closeVhostExport(io: std.Io, export_handle: *zettide.spdk_vhost_block_export.VhostBlockExport) void {
    for (0..1000) |_| {
        export_handle.close() catch |err| switch (err) {
            error.ExportBusy => {
                io.sleep(.fromMilliseconds(10), .awake) catch @panic("failed to wait for vhost export shutdown");
                continue;
            },
            else => @panic("failed to close Pool data vhost export"),
        };
        return;
    }
    @panic("timed out closing Pool data vhost export");
}

fn closeRawVhostController(
    io: std.Io,
    controller: *?*c.struct_zettide_spdk_vhost_blk_controller,
) void {
    const handle = controller.* orelse return;
    for (0..1000) |_| {
        const status = c.zettide_spdk_vhost_blk_controller_remove(handle);
        if (status == 0) {
            controller.* = null;
            return;
        }
        if (status != -c.EBUSY) @panic("failed to remove raw NVMe vhost controller");
        io.sleep(.fromMilliseconds(10), .awake) catch
            @panic("failed to wait for raw NVMe vhost controller shutdown");
    }
    @panic("timed out removing raw NVMe vhost controller");
}

fn publishReadyAndWait(io: std.Io, ready_path: []const u8, signals: *const c.sigset_t) !void {
    std.debug.print("target-stage ready publish path={s}\n", .{ready_path});
    const ready = try std.Io.Dir.createFileAbsolute(io, ready_path, .{ .exclusive = true });
    ready.close(io);
    std.debug.print("target-stage ready published\n", .{});
    var signal_number: c_int = undefined;
    if (c.sigwait(signals, &signal_number) != 0) return error.SignalWaitFailed;
}

fn errorStatus(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -c.ENOMEM,
        error.OutOfBounds, error.InvalidPoolDataIo => -c.ERANGE,
        error.ReadOnlyPoolData => -c.EROFS,
        error.PoolAuthorityChanged => -c.ESTALE,
        error.DataReadUnavailable, error.DataMemberUnavailable => -c.ENODEV,
        else => -c.EIO,
    };
}
