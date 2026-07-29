const std = @import("std");
const zettide = @import("zettide");

const c = @cImport({
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
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var context: TestContext = .{
        .io = threaded.io(),
        .allocator = std.heap.c_allocator,
    };
    return c.zettide_spdk_test_run(
        "zettide_spdk_storage_test",
        malloc_bdev_config.ptr,
        malloc_bdev_config.len,
        runTest,
        &context,
    );
}

fn runTest(owner: ?*c.struct_spdk_thread, context_ptr: ?*anyopaque) callconv(.c) c_int {
    const context: *TestContext = @ptrCast(@alignCast(context_ptr orelse return 1));
    const spdk_owner: *zettide.spdk_storage.Owner = @ptrCast(owner orelse return 1);
    runStorageTest(context, spdk_owner) catch |err| {
        std.debug.print("SPDK storage test failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runStorageTest(context: *TestContext, owner: *zettide.spdk_storage.Owner) !void {
    const names = [_][]const u8{ "ZettideStorage0", "ZettideStorage1", "ZettideStorage2" };
    var duplicate_storages: [2]zettide.v3.storage.Storage = undefined;
    var duplicate_count: usize = 0;
    errdefer zettide.v3.storage.closeAll(duplicate_storages[0..duplicate_count], context.io) catch {};
    for (&duplicate_storages) |*storage| {
        storage.* = try zettide.spdk_storage.open(context.allocator, owner, names[0], true);
        duplicate_count += 1;
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
        storages[index] = try zettide.spdk_storage.open(context.allocator, owner, name, true);
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
        storages[index] = try zettide.spdk_storage.open(context.allocator, owner, name, true);
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
