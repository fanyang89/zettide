const std = @import("std");
const zettide = @import("zettide");
const args = @import("spdk_pool_data_nvmf_args.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("pthread.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("spdk/bdev_provider.h");
    @cInclude("spdk_runtime.h");
});

const block_size = 4096;
const max_batch_requests = 32;
const max_batch_bytes = 1024 * 1024;
const max_concurrent_groups = 4;
const queue_capacity = 1024;
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
        slot: *Slot,
        position: usize,
    };

    const ReadGroup = struct {
        queued: [max_batch_requests]Queued = undefined,
        count: usize = 0,
    };

    io: std.Io,
    storage: *zettide.v3.storage.Storage,
    slots: [queue_capacity]Slot,
    enqueue_position: std.atomic.Value(usize) = .init(0),
    dequeue_position: usize = 0,
    wake: std.Io.Event = .unset,
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

    fn create(io: std.Io, storage: *zettide.v3.storage.Storage) !*Worker {
        const self = try std.heap.c_allocator.create(Worker);
        errdefer std.heap.c_allocator.destroy(self);
        self.* = undefined;
        self.io = io;
        self.storage = storage;
        for (&self.slots, 0..) |*slot, index| slot.* = .{ .sequence = .init(index) };
        self.enqueue_position = .init(0);
        self.dequeue_position = 0;
        self.wake = .unset;
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
                self.wake.set(self.io);
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
        self.dequeue_position = position + 1;
        return .{ .slot = slot, .position = position };
    }

    fn release(queued: Queued) void {
        queued.slot.sequence.store(queued.position + queue_capacity, .release);
    }

    fn next(self: *Worker) ?Queued {
        while (true) {
            if (self.dequeue()) |queued| return queued;
            self.wake.reset();
            if (self.dequeue()) |queued| return queued;
            if (self.stopping.load(.acquire)) return null;
            self.wake.waitUncancelable(self.io);
        }
    }

    fn run(self: *Worker) void {
        var groups: std.Io.Group = .init;
        var permits: std.Io.Semaphore = .{ .permits = max_concurrent_groups };
        var pending: ?Queued = null;
        while (pending orelse self.next()) |queued| {
            pending = null;
            if (queued.slot.request.operation != c.ZETTIDE_SPDK_BDEV_PROVIDER_READ) {
                groups.await(self.io) catch unreachable;
                self.completeQueued(queued, 0);
                continue;
            }

            var batch: ReadGroup = .{};
            batch.queued[0] = queued;
            batch.count = 1;
            var total_bytes = queued.slot.request.length;
            while (batch.count < max_batch_requests) {
                const candidate = self.dequeue() orelse break;
                const request = candidate.slot.request;
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
            permits.waitUncancelable(self.io);
            groups.concurrent(self.io, executeReadGroup, .{ self, &permits, batch }) catch {
                executeReadGroup(self, &permits, batch) catch {};
            };
        }
        groups.await(self.io) catch unreachable;
    }

    fn executeReadGroup(
        self: *Worker,
        permits: *std.Io.Semaphore,
        batch: ReadGroup,
    ) std.Io.Cancelable!void {
        defer permits.post(self.io);
        var reads: [max_batch_requests]zettide.v3.storage.Read = undefined;
        var results: [max_batch_requests]zettide.v3.storage.ReadResult = undefined;
        for (batch.queued[0..batch.count], reads[0..batch.count]) |queued, *read| {
            const request = queued.slot.request;
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
            for (batch.queued[0..batch.count]) |queued| self.completeQueued(queued, status);
            return;
        };
        for (batch.queued[0..batch.count], results[0..batch.count]) |queued, result| {
            const status = if (result.failure) |err|
                errorStatus(err)
            else if (result.amount != queued.slot.request.length)
                -c.EIO
            else
                0;
            self.completeQueued(queued, status);
        }
    }

    fn completeQueued(self: *Worker, queued: Queued, status: c_int) void {
        const request = queued.slot.request;
        request.complete.?(request.complete_context, status);
        _ = self.current_occupancy.fetchSub(1, .monotonic);
        _ = self.completed_requests.fetchAdd(1, .monotonic);
        release(queued);
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
    if (device_count == 0 or device_count > zettide.v3.pool_member_set.max_member_count)
        return error.InvalidDeviceCount;
    const read_policy: zettide.v3.pool_scheduled_data_device.ReadPolicy = switch (try args.parseReadPolicy(read_policy_raw)) {
        .first_available => .first_available,
        .quorum => .quorum,
    };
    const expected_pool_id = try args.parsePoolId(expected_pool_id_text);
    const transport_text = if (c.getenv("ZETTIDE_NVMF_TRANSPORT")) |value| std.mem.span(value) else "tcp";
    const transport: zettide.spdk_nvmf_tcp_export.Transport = if (std.mem.eql(u8, transport_text, "tcp"))
        .tcp
    else if (std.mem.eql(u8, transport_text, "rdma"))
        .rdma
    else
        return error.InvalidNvmfTransport;
    const traddr = if (c.getenv("ZETTIDE_NVMF_TARGET_ADDR")) |value| std.mem.span(value) else "127.0.0.1";
    const trsvcid = if (c.getenv("ZETTIDE_NVMF_TARGET_PORT")) |value| std.mem.span(value) else "44220";
    const reactor_count = try args.parseReactorCount(if (c.getenv("ZETTIDE_NVMF_REACTOR_COUNT")) |value|
        std.mem.span(value)
    else
        null);

    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var storages: [zettide.v3.pool_member_set.max_member_count]zettide.v3.storage.Storage = undefined;
    var opened_count: usize = 0;
    errdefer zettide.v3.storage.closeAll(storages[0..opened_count], io) catch {};
    for (device_paths[0..device_count], storages[0..device_count]) |device_path_z, *storage| {
        const opened = try zettide.v3.linux_block_device.openStorageOptions(
            io,
            allocator,
            std.mem.span(device_path_z),
            false,
            true,
        );
        storage.* = opened.storage;
        opened_count += 1;
    }
    const storage_slice = storages[0..opened_count];
    opened_count = 0;
    var set = try zettide.v3.pool_member_set.PoolMemberSet.openStorages(
        io,
        allocator,
        storage_slice,
        .read_only,
    );
    errdefer set.deinit();
    const authority = set.authority() orelse return error.MissingAuthority;
    if (!std.mem.eql(u8, &authority.topology.set_id, &expected_pool_id))
        return error.UnexpectedPoolId;
    if (try set.dataMode() != .blob or authority.layout.scheduled_blob == null)
        return error.ScheduledBlobPoolRequired;

    var pool_storage = try zettide.v3.pool_data_storage.createOptions(
        allocator,
        io,
        &set,
        false,
        .{ .read_policy = read_policy },
    );
    defer pool_storage.close(io) catch @panic("failed to close Pool data storage");
    if (pool_storage.capacity() == 0 or pool_storage.capacity() % block_size != 0)
        return error.InvalidPoolDataCapacity;

    var reactor_mask_buffer: [128]u8 = undefined;
    if (c.zettide_spdk_test_reactor_mask_count(
        &reactor_mask_buffer,
        reactor_mask_buffer.len,
        reactor_count,
    ) != 0)
        return error.ReactorMaskUnavailable;
    const reactor_mask = std.mem.sliceTo(&reactor_mask_buffer, 0);
    var signals: c.sigset_t = undefined;
    if (c.sigemptyset(&signals) != 0 or
        c.sigaddset(&signals, c.SIGINT) != 0 or
        c.sigaddset(&signals, c.SIGTERM) != 0 or
        c.pthread_sigmask(c.SIG_BLOCK, &signals, null) != 0)
        return error.SignalSetupFailed;

    std.debug.print("target-stage runtime start reactor_mask={s}\n", .{reactor_mask});
    var runtime = try zettide.spdk_runtime.Runtime.start(allocator, .{
        .name = "zettide_spdk_pool_data_nvmf_benchmark",
        .reactor_mask = reactor_mask,
        .json_data = if (transport == .rdma) rdma_runtime_config else runtime_config,
        .mem_size_mb = 512,
        .no_pci = true,
        .no_huge = true,
        .disable_cpumask_locks = true,
    });
    defer runtime.deinit();
    const runtime_handle: *anyopaque = @ptrCast(runtime.handle orelse return error.RuntimeStopped);
    std.debug.print("target-stage runtime ready\n", .{});
    std.debug.print("target-stage worker start\n", .{});
    const worker = try Worker.create(io, &pool_storage);
    defer worker.close();
    std.debug.print("target-stage worker ready\n", .{});
    std.debug.print("target-stage provider start\n", .{});
    var provider = try zettide.spdk_provider_bdev.ProviderBdev.create(
        allocator,
        runtime_handle,
        .{
            .context = worker,
            .submit = submit_callback,
            .block_count = pool_storage.capacity() / block_size,
            .max_io_blocks = max_batch_bytes / block_size,
        },
        "ZettideScheduledPoolData0",
    );
    defer provider.close() catch @panic("failed to unregister Pool data provider bdev");
    std.debug.print("target-stage provider ready\n", .{});
    std.debug.print("target-stage export start transport={s} traddr={s} trsvcid={s}\n", .{ transport_text, traddr, trsvcid });
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
            .transport = transport,
        },
    );
    defer export_handle.close() catch @panic("failed to close Pool data NVMe-oF export");
    std.debug.print("target-stage export ready\n", .{});

    std.debug.print("target-stage ready publish path={s}\n", .{ready_path});
    const ready = try std.Io.Dir.createFileAbsolute(io, ready_path, .{ .exclusive = true });
    ready.close(io);
    std.debug.print("target-stage ready published\n", .{});
    var signal_number: c_int = undefined;
    if (c.sigwait(&signals, &signal_number) != 0) return error.SignalWaitFailed;
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
