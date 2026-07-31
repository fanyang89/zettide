const std = @import("std");
const zettide = @import("zettide");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("spdk/runtime.h");
    @cInclude("spdk_runtime.h");
});

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
    try runtimeStatus(c.zettide_spdk_test_reactor_mask(&reactor_mask_buffer, reactor_mask_buffer.len));
    const reactor_mask = std.mem.sliceTo(&reactor_mask_buffer, 0);
    const runtime_options: zettide.spdk_runtime.Runtime.Options = .{
        .name = "zettide_spdk_storage_test",
        .reactor_mask = reactor_mask,
        .json_data = malloc_bdev_config,
        .mem_size_mb = 512,
        .no_pci = true,
        .no_huge = true,
        .disable_cpumask_locks = true,
    };
    var runtime = try zettide.spdk_runtime.Runtime.start(context.allocator, runtime_options);
    defer runtime.deinit();
    second_runtime: {
        var unexpected = zettide.spdk_runtime.Runtime.start(context.allocator, runtime_options) catch |err| {
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

fn runControllerTest(context: *TestContext, runtime: *zettide.spdk_runtime.Runtime) !void {
    const base_options: zettide.spdk_nvme_controller.Controller.Options = .{
        .name = "ZettideRemote",
        .transport_address = "127.0.0.1",
        .transport_service_id = "44219",
        .subsystem_nqn = "nqn.2026-07.io.zettide:test",
        .connect_timeout_us = std.time.us_per_s,
    };
    invalid_options: {
        var unexpected = zettide.spdk_nvme_controller.Controller.attach(
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
        var unexpected = zettide.spdk_nvme_controller.Controller.attach(
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

    var controller = try zettide.spdk_nvme_controller.Controller.attach(
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

    var truncated = try zettide.spdk_nvme_controller.Controller.attach(
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

fn runStorageTest(context: *TestContext, runtime: *zettide.spdk_runtime.Runtime) !void {
    const names = [_][]const u8{ "ZettideStorage0", "ZettideStorage1", "ZettideStorage2" };
    var duplicate_storages: [3]zettide.v3.storage.Storage = undefined;
    var duplicate_count: usize = 0;
    errdefer zettide.v3.storage.closeAll(duplicate_storages[0..duplicate_count], context.io) catch {};
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
        const outcome = zettide.v3.pool_provision.create(
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

    var storages: [names.len]zettide.v3.storage.Storage = undefined;
    var opened_count: usize = 0;
    errdefer for (storages[0..opened_count]) |*storage| storage.close(context.io) catch {};
    for (names, 0..) |name, index| {
        storages[index] = try runtime.openStorage(context.allocator, name, true);
        opened_count += 1;
    }

    // Provisioning consumes every supplied storage on both success and failure.
    opened_count = 0;
    const outcome = try zettide.v3.pool_provision.create(context.io, context.allocator, &storages, .{});
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => |partial| return partial.cause,
    };
    defer provisioned.deinit();
    try zettide.volume.Volume.initializePool(context.io, &provisioned, "SPDK Pool");
    try provisioned.close();

    for (names, 0..) |name, index| {
        storages[index] = try runtime.openStorage(context.allocator, name, true);
        opened_count += 1;
    }
    // PoolMemberSet likewise owns every storage once scanning starts.
    opened_count = 0;
    var set = try zettide.v3.pool_member_set.PoolMemberSet.openStorages(
        context.io,
        context.allocator,
        &storages,
        .writable,
    );
    var volume = try zettide.volume.Volume.openPool(context.io, context.allocator, &set, true);
    defer volume.deinit();
    try volume.mount();
    if (try volume.usedBlocks() == 0) return error.EmptyFilesystem;
    try volume.sync();
    try volume.close();
}

fn runtimeStatus(status: c_int) !void {
    if (status != 0) return error.TestRuntimeSetupFailed;
}
