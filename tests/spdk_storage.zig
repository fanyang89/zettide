const std = @import("std");
const storage_engine = @import("zettide_storage");
const data_node = @import("zettide_data_node");

const c = @import("spdk_c");

const malloc_bdev_config =
    \\{"subsystems":[{"subsystem":"bdev","config":[
    \\{"method":"bdev_set_options","params":{"bdev_io_pool_size":4096,"bdev_io_cache_size":64}},
    \\{"method":"bdev_malloc_create","params":{"name":"ZettideStorage0","num_blocks":4096,"block_size":4096}},
    \\{"method":"bdev_malloc_create","params":{"name":"ZettideStorage1","num_blocks":4096,"block_size":4096}},
    \\{"method":"bdev_malloc_create","params":{"name":"ZettideStorage2","num_blocks":4096,"block_size":4096}}
    \\]}]}
;

const TestContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
};

const AsyncReadState = struct {
    io: std.Io,
    event: std.Io.Event = .unset,
    failure: ?anyerror = null,
    completed: bool = false,

    fn complete(context_ptr: *anyopaque, failure: ?anyerror) void {
        const self: *@This() = @ptrCast(@alignCast(context_ptr));
        self.failure = failure;
        self.completed = true;
        self.event.set(self.io);
    }
};

pub export fn zettide_spdk_storage_test_main() c_int {
    runMain() catch |err| {
        std.debug.print("SPDK storage test failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runMain() !void {
    var invalid_options: c.struct_zettide_spdk_runtime_opts = undefined;
    c.zettide_spdk_runtime_opts_init(&invalid_options, @sizeOf(@TypeOf(invalid_options)));
    var invalid_runtime: ?*c.struct_zettide_spdk_runtime = null;
    if (c.zettide_spdk_runtime_start(&invalid_options, &invalid_runtime) != -c.EINVAL or
        invalid_runtime != null)
        return error.InvalidRuntimeOptionsAccepted;

    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var context: TestContext = .{
        .io = threaded.io(),
        .allocator = std.heap.c_allocator,
    };
    var reactor_mask_buffer: [32]u8 = undefined;
    var reactor_count: usize = 4;
    while (true) {
        const mask_status = c.zettide_spdk_test_reactor_mask_count(
            &reactor_mask_buffer,
            reactor_mask_buffer.len,
            reactor_count,
        );
        if (mask_status == 0) break;
        if (mask_status != -c.ENODEV or reactor_count == 1) try runtimeStatus(mask_status);
        reactor_count -= 1;
    }
    const reactor_mask = std.mem.sliceTo(&reactor_mask_buffer, 0);
    const runtime_options: data_node.spdk_runtime.Runtime.Options = .{
        .name = "zettide_spdk_storage_test",
        .reactor_mask = reactor_mask,
        .json_data = malloc_bdev_config,
        .mem_size_mb = 512,
        .no_pci = true,
        .no_huge = true,
        .disable_cpumask_locks = true,
    };
    var runtime = try data_node.spdk_runtime.Runtime.start(context.allocator, runtime_options);
    defer runtime.deinit();
    if (reactor_count > 1)
        try runtimeStatus(c.zettide_spdk_test_dispatcher_owner_round_robin(
            @ptrCast(runtime.handle.?),
            reactor_count,
        ));
    second_runtime: {
        var unexpected = data_node.spdk_runtime.Runtime.start(context.allocator, runtime_options) catch |err| {
            if (err != error.RuntimeBusy) return err;
            break :second_runtime;
        };
        unexpected.deinit();
        return error.SecondRuntimeStarted;
    }
    try runControllerTest(&context, &runtime);
    try runStorageTest(&context, &runtime);
    try runtime.stop();
    runtime.deinit();
}

fn runControllerTest(context: *TestContext, runtime: *data_node.spdk_runtime.Runtime) !void {
    const base_options: data_node.spdk_nvme_controller.Controller.Options = .{
        .name = "ZettideRemote",
        .transport_address = "127.0.0.1",
        .transport_service_id = "44219",
        .subsystem_nqn = "nqn.2026-07.io.zettide:test",
        .connect_timeout_us = std.time.us_per_s,
    };
    invalid_options: {
        var unexpected = data_node.spdk_nvme_controller.Controller.attach(
            context.allocator,
            runtime,
            .{
                .name = "",
                .transport_address = base_options.transport_address,
                .transport_service_id = base_options.transport_service_id,
                .subsystem_nqn = base_options.subsystem_nqn,
            },
        ) catch |err| {
            if (err != error.InvalidControllerOptions) return err;
            break :invalid_options;
        };
        unexpected.deinit();
        return error.InvalidControllerOptionsAccepted;
    }
    missing_subsystem: {
        var unexpected = data_node.spdk_nvme_controller.Controller.attach(
            context.allocator,
            runtime,
            .{
                .name = "ZettideMissing",
                .transport_address = base_options.transport_address,
                .transport_service_id = base_options.transport_service_id,
                .subsystem_nqn = "nqn.2026-07.io.zettide:missing",
                .connect_timeout_us = base_options.connect_timeout_us,
            },
        ) catch break :missing_subsystem;
        unexpected.deinit();
        return error.MissingSubsystemAttached;
    }

    var controller = try data_node.spdk_nvme_controller.Controller.attach(
        context.allocator,
        runtime,
        base_options,
    );
    defer controller.deinit();
    if (controller.namespaceCount() != 2 or controller.namespaceNamesTruncated())
        return error.UnexpectedNamespaceCount;
    const namespace_name = try controller.namespaceName(0);
    if (!std.mem.eql(u8, namespace_name, "ZettideRemoten1"))
        return error.UnexpectedNamespaceName;
    if (!std.mem.eql(u8, try controller.namespaceName(1), "ZettideRemoten2"))
        return error.UnexpectedNamespaceName;
    if (controller.namespaceName(2)) |_| {
        return error.NamespaceIndexAccepted;
    } else |err| if (err != error.NamespaceIndexOutOfBounds) {
        return err;
    }
    busy_stop: {
        runtime.stop() catch |err| {
            if (err != error.RuntimeBusy) return err;
            break :busy_stop;
        };
        return error.RuntimeStoppedWithAttachedController;
    }

    var storage = try runtime.openStorage(context.allocator, namespace_name, true);
    try storage.close(context.io);
    try controller.detach();

    var truncated = try data_node.spdk_nvme_controller.Controller.attach(
        context.allocator,
        runtime,
        .{
            .name = "ZettideTruncated",
            .transport_address = base_options.transport_address,
            .transport_service_id = base_options.transport_service_id,
            .subsystem_nqn = base_options.subsystem_nqn,
            .connect_timeout_us = base_options.connect_timeout_us,
            .namespace_name_capacity = 1,
        },
    );
    defer truncated.deinit();
    if (truncated.namespaceCount() != 1 or !truncated.namespaceNamesTruncated())
        return error.NamespaceNamesNotTruncated;
    try truncated.detach();
}

fn runStorageTest(context: *TestContext, runtime: *data_node.spdk_runtime.Runtime) !void {
    const names = [_][]const u8{ "ZettideStorage0", "ZettideStorage1", "ZettideStorage2" };
    try testAsyncReadClose(context, runtime, names[0]);
    var duplicate_storages: [3]storage_engine.v3.storage.Storage = undefined;
    var duplicate_count: usize = 0;
    errdefer storage_engine.v3.storage.closeAll(duplicate_storages[0..duplicate_count], context.io) catch {};
    for (&duplicate_storages) |*storage| {
        storage.* = try runtime.openStorage(context.allocator, names[0], true);
        duplicate_count += 1;
    }
    busy_stop: {
        runtime.stop() catch |err| {
            if (err != error.RuntimeBusy) return err;
            break :busy_stop;
        };
        return error.RuntimeStoppedWithOpenStorage;
    }
    if (!duplicate_storages[0].sameIdentity(&duplicate_storages[1]))
        return error.UnstableStorageIdentity;
    // Provisioning owns both descriptors after this point, including on error.
    duplicate_count = 0;
    duplicate_check: {
        const outcome = storage_engine.v3.pool_provision.create(
            context.io,
            context.allocator,
            &duplicate_storages,
            .{ .protection = .unprotected },
        ) catch |err| {
            if (err != error.DuplicateStorage) return err;
            break :duplicate_check;
        };
        switch (outcome) {
            .complete => |value| {
                var provisioned = value;
                provisioned.deinit();
            },
            .partial => {},
        }
        return error.DuplicateStorageAccepted;
    }

    var storages: [names.len]storage_engine.v3.storage.Storage = undefined;
    var opened_count: usize = 0;
    errdefer for (storages[0..opened_count]) |*storage| storage.close(context.io) catch {};
    for (names, 0..) |name, index| {
        storages[index] = try runtime.openStorage(context.allocator, name, true);
        opened_count += 1;
    }
    try testAsyncReadMany(context, &storages[0]);

    // Provisioning consumes every supplied storage on both success and failure.
    opened_count = 0;
    const outcome = try storage_engine.v3.pool_provision.create(context.io, context.allocator, &storages, .{
        .data_mode = .blob,
    });
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => |partial| return partial.cause,
    };
    defer provisioned.deinit();
    var filesystem = try data_node.filesystem_target.formatProvisionedBlobPool(
        context.allocator,
        context.io,
        &provisioned,
        .legacy_raw,
        .{},
    );
    const inode = try filesystem.createFile(context.io, 1, "payload", 0o644, 0, 0);
    if (try filesystem.write(context.io, inode, "SPDK", 0) != 4) return error.ShortWrite;
    try filesystem.close(context.io);

    for (names, 0..) |name, index| {
        storages[index] = try runtime.openStorage(context.allocator, name, true);
        opened_count += 1;
    }
    // PoolMemberSet likewise owns every storage once scanning starts.
    opened_count = 0;
    var set = try storage_engine.v3.pool_member_set.PoolMemberSet.openStorages(
        context.io,
        context.allocator,
        &storages,
        .writable,
    );
    filesystem = try data_node.filesystem_target.openBlobPoolFilesystem(
        context.allocator,
        context.io,
        &set,
        true,
    );
    defer filesystem.close(context.io) catch {};
    const reopened_inode = try filesystem.resolvePath(context.io, "/payload");
    var payload: [4]u8 = undefined;
    if (try filesystem.read(context.io, reopened_inode, &payload, 0) != payload.len)
        return error.ShortRead;
    if (!std.mem.eql(u8, &payload, "SPDK")) return error.DataMismatch;
}

fn testAsyncReadMany(context: *TestContext, storage: *storage_engine.v3.storage.Storage) !void {
    var expected: [2][4096]u8 = undefined;
    for (&expected, 0..) |*block, block_index| {
        for (block, 0..) |*byte, byte_index| byte.* = @truncate(block_index * 67 + byte_index * 29);
    }
    try storage.writeAllAt(context.io, &expected[0], 0);
    try storage.writeAllAt(context.io, &expected[1], 4096);

    var actual: [2][4096]u8 = @splat(@splat(0));
    const reads = [_]storage_engine.v3.storage.Read{
        .{ .buffer = &actual[0], .offset = 0 },
        .{ .buffer = &actual[1], .offset = 4096 },
    };
    var results: [reads.len]storage_engine.v3.storage.ReadResult = undefined;
    var state: AsyncReadState = .{ .io = context.io };
    if (try storage.submitReadManyAt(
        context.io,
        &reads,
        &results,
        .{ .context = &state, .complete = AsyncReadState.complete },
    ) != .submitted) return error.AsyncReadUnsupported;
    state.event.waitUncancelable(context.io);
    if (state.failure) |err| return err;
    for (expected, actual, results) |expected_block, actual_block, result| {
        if (result.failure) |err| return err;
        if (result.amount != actual_block.len or !std.mem.eql(u8, &expected_block, &actual_block))
            return error.AsyncReadMismatch;
    }
    const stats = storage.transportStats(context.io);
    if (stats.async_submissions != 1 or stats.async_completions != 1 or
        stats.read_direct_batches != 0 or stats.read_direct_bytes != 0 or
        stats.read_bounce_batches != 1 or stats.read_bounce_bytes != 2 * 4096)
        return error.AsyncReadStatsMismatch;
}

fn testAsyncReadClose(
    context: *TestContext,
    runtime: *data_node.spdk_runtime.Runtime,
    name: []const u8,
) !void {
    var storage = try runtime.openStorage(context.allocator, name, true);
    var owned = true;
    defer if (owned) storage.close(context.io) catch {};

    var buffer: [4096]u8 = undefined;
    const reads = [_]storage_engine.v3.storage.Read{.{ .buffer = &buffer, .offset = 0 }};
    var results: [1]storage_engine.v3.storage.ReadResult = undefined;
    var state: AsyncReadState = .{ .io = context.io };
    if (try storage.submitReadManyAt(
        context.io,
        &reads,
        &results,
        .{ .context = &state, .complete = AsyncReadState.complete },
    ) != .submitted) return error.AsyncReadUnsupported;
    owned = false;
    try storage.close(context.io);
    if (!state.completed) return error.AsyncReadCloseReturnedEarly;
    if (state.failure) |err| return err;
    if (results[0].failure) |err| return err;
    if (results[0].amount != buffer.len) return error.AsyncReadMismatch;
}

fn runtimeStatus(status: c_int) !void {
    if (status != 0) return error.TestRuntimeSetupFailed;
}
