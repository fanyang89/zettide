const std = @import("std");
const cawfs = @import("zettide_cawfs");

const ModelStore = cawfs.model_store.ModelStore;
const ObjectRef = cawfs.store.ObjectRef;
const Anchor = cawfs.store.Anchor;

const txn_a: [16]u8 = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const txn_b: [16]u8 = .{ 0xb2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };

fn makeAnchor(generation: u64, label: []const u8) Anchor {
    std.debug.assert(label.len <= cawfs.store.anchor_size - 8);
    var anchor: Anchor = @splat(0);
    std.mem.writeInt(u64, anchor[0..8], generation, .big);
    @memcpy(anchor[8 .. 8 + label.len], label);
    return anchor;
}

const initial_anchor = makeAnchor(1, "anchor-0");

fn beginCurrentBatch(
    store: cawfs.store.ConditionalStore,
    allocator: std.mem.Allocator,
    transaction_id: cawfs.store.TransactionId,
) !cawfs.store.WriteBatch {
    var snapshot = try store.readAnchor(allocator);
    defer snapshot.deinit();
    return store.beginBatch(allocator, transaction_id, snapshot.version.bytes);
}

test "model store stages immutable objects before publication" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var batch = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer batch.deinit();
    const object_ref = try batch.putImmutable("page-a");

    try std.testing.expectError(
        error.ObjectNotFound,
        store.loadImmutable(object_ref, std.testing.allocator),
    );

    try batch.prepare();
    var object = try store.loadImmutable(object_ref, std.testing.allocator);
    defer object.deinit();
    try std.testing.expectEqualStrings("page-a", object.bytes);
}

test "only one publisher can replace an anchor version" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var initial = try store.readAnchor(std.testing.allocator);
    defer initial.deinit();

    var first = try store.beginBatch(std.testing.allocator, txn_a, initial.version.bytes);
    defer first.deinit();
    _ = try first.putImmutable("first-page");
    try first.prepare();

    var second = try store.beginBatch(std.testing.allocator, txn_b, initial.version.bytes);
    defer second.deinit();
    _ = try second.putImmutable("second-page");
    try second.prepare();

    const first_anchor = makeAnchor(2, "anchor-1");
    try std.testing.expectEqual(
        cawfs.store.PublishResult.committed,
        try first.publish(initial.version.bytes, &first_anchor),
    );
    try first.stabilize();
    try std.testing.expectEqual(
        cawfs.store.PublishResult.conflict,
        try second.publish(initial.version.bytes, &makeAnchor(2, "anchor-2")),
    );
    try std.testing.expectError(
        error.InvalidState,
        second.publish(initial.version.bytes, &makeAnchor(3, "anchor-3")),
    );

    var current = try store.readAnchor(std.testing.allocator);
    defer current.deinit();
    try std.testing.expectEqualSlices(u8, &first_anchor, &current.anchor);
}

test "stabilized publication survives a crash" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var initial = try store.readAnchor(std.testing.allocator);
    defer initial.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, initial.version.bytes);
    defer batch.deinit();
    try batch.prepare();
    const next_anchor = makeAnchor(2, "anchor-1");
    try std.testing.expectEqual(
        cawfs.store.PublishResult.committed,
        try batch.publish(initial.version.bytes, &next_anchor),
    );
    try batch.stabilize();

    model.crash();
    var recovered = try store.readAnchor(std.testing.allocator);
    defer recovered.deinit();
    try std.testing.expectEqualSlices(u8, &next_anchor, &recovered.anchor);
}

test "indeterminate publication can occur before or after replacement" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var initial = try store.readAnchor(std.testing.allocator);
    defer initial.deinit();
    var before = try store.beginBatch(std.testing.allocator, txn_a, initial.version.bytes);
    defer before.deinit();
    try before.prepare();
    model.injectNextPublishFault(.indeterminate_before);
    try std.testing.expectEqual(
        cawfs.store.PublishResult.indeterminate,
        try before.publish(initial.version.bytes, &makeAnchor(2, "anchor-before")),
    );
    var unchanged = try store.readAnchor(std.testing.allocator);
    defer unchanged.deinit();
    try std.testing.expectEqualSlices(u8, &initial_anchor, &unchanged.anchor);

    var after = try store.beginBatch(std.testing.allocator, txn_b, unchanged.version.bytes);
    defer after.deinit();
    try after.prepare();
    model.injectNextPublishFault(.indeterminate_after);
    const after_anchor = makeAnchor(2, "anchor-after");
    try std.testing.expectEqual(
        cawfs.store.PublishResult.indeterminate,
        try after.publish(unchanged.version.bytes, &after_anchor),
    );
    var visible = try store.readAnchor(std.testing.allocator);
    defer visible.deinit();
    try std.testing.expectEqualSlices(u8, &after_anchor, &visible.anchor);

    model.crash();
    var recovered = try store.readAnchor(std.testing.allocator);
    defer recovered.deinit();
    try std.testing.expectEqualSlices(u8, &initial_anchor, &recovered.anchor);
}

test "object references are opaque and content-specific" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var batch = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer batch.deinit();
    const first = try batch.putImmutable("first");
    const second = try batch.putImmutable("second");
    try std.testing.expect(!ObjectRef.eql(first, second));
}

test "crash invalidates batches created in the previous process epoch" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var batch = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer batch.deinit();
    _ = try batch.putImmutable("unprepared");

    model.crash();
    try std.testing.expectError(error.InvalidState, batch.prepare());
}

test "publishing an identical physical anchor is rejected" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var initial = try store.readAnchor(std.testing.allocator);
    defer initial.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, initial.version.bytes);
    defer batch.deinit();
    try batch.prepare();

    try std.testing.expectError(
        error.NoOpAnchor,
        batch.publish(initial.version.bytes, &initial_anchor),
    );
}

test "prepared immutable objects survive a crash" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var batch = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer batch.deinit();
    const object_ref = try batch.putImmutable("durable-page");
    try batch.prepare();

    model.crash();
    var object = try store.loadImmutable(object_ref, std.testing.allocator);
    defer object.deinit();
    try std.testing.expectEqualStrings("durable-page", object.bytes);
}

test "an indeterminate applied publication can be stabilized" {
    var model = ModelStore.init(std.testing.allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();

    var initial = try store.readAnchor(std.testing.allocator);
    defer initial.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, initial.version.bytes);
    defer batch.deinit();
    try batch.prepare();

    const next_anchor = makeAnchor(2, "anchor-1");
    model.injectNextPublishFault(.indeterminate_after);
    try std.testing.expectEqual(
        cawfs.store.PublishResult.indeterminate,
        try batch.publish(initial.version.bytes, &next_anchor),
    );
    try batch.stabilize();

    model.crash();
    var recovered = try store.readAnchor(std.testing.allocator);
    defer recovered.deinit();
    try std.testing.expectEqualSlices(u8, &next_anchor, &recovered.anchor);
}

test "concurrent publishers have exactly one winner" {
    const Worker = struct {
        store: cawfs.store.ConditionalStore,
        version: []const u8,
        transaction_id: [16]u8,
        anchor: Anchor,
        result: ?cawfs.store.PublishResult = null,

        fn run(self: *@This()) void {
            self.runFallible() catch |err| {
                std.debug.panic("concurrent publisher failed: {s}", .{@errorName(err)});
            };
        }

        fn runFallible(self: *@This()) !void {
            var batch = try self.store.beginBatch(
                std.heap.page_allocator,
                self.transaction_id,
                self.version,
            );
            defer batch.deinit();
            try batch.prepare();
            self.result = try batch.publish(self.version, &self.anchor);
            if (self.result == .committed) try batch.stabilize();
        }
    };

    var model = ModelStore.init(std.heap.page_allocator, initial_anchor);
    defer model.deinit();
    const store = model.conditionalStore();
    var initial = try store.readAnchor(std.testing.allocator);
    defer initial.deinit();

    var first: Worker = .{
        .store = store,
        .version = initial.version.bytes,
        .transaction_id = txn_a,
        .anchor = makeAnchor(2, "anchor-a"),
    };
    var second: Worker = .{
        .store = store,
        .version = initial.version.bytes,
        .transaction_id = txn_b,
        .anchor = makeAnchor(2, "anchor-b"),
    };

    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();

    const committed = @intFromBool(first.result == .committed) +
        @intFromBool(second.result == .committed);
    const conflicted = @intFromBool(first.result == .conflict) +
        @intFromBool(second.result == .conflict);
    try std.testing.expectEqual(@as(u2, 1), committed);
    try std.testing.expectEqual(@as(u2, 1), conflicted);
}
