const std = @import("std");
const cawfs = @import("zettide_cawfs");

const Anchor = cawfs.store.Anchor;
const ModelStore = cawfs.model_store.ModelStore;
const ObjectRef = cawfs.store.ObjectRef;
const PublishFault = cawfs.model_store.PublishFault;
const PublishResult = cawfs.store.PublishResult;
const TransactionId = cawfs.store.TransactionId;

const txn_a: TransactionId = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const txn_b: TransactionId = .{ 0xb2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
const txn_c: TransactionId = .{ 0xc3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 };

const Published = struct {
    head: ObjectRef,
    result: PublishResult,
};

fn initialAnchor() Anchor {
    return cawfs.anchor.encode(.{
        .revision = 0,
        .generation = 0,
        .transaction_id = @splat(0),
        .head = null,
        .mode = .active,
        .mode_epoch = 1,
    });
}

fn publishCommit(
    model: *ModelStore,
    transaction_id: TransactionId,
    generation: u64,
    parent: ?ObjectRef,
    fault: PublishFault,
) !Published {
    const store = model.conditionalStore();
    var previous = try store.readAnchor(std.testing.allocator);
    defer previous.deinit();
    var batch = try store.beginBatch(
        std.testing.allocator,
        transaction_id,
        previous.version.bytes,
    );
    defer batch.deinit();
    const encoded = cawfs.commit.encode(.{
        .generation = generation,
        .transaction_id = transaction_id,
        .parent = parent,
        .root = patternedRef(@truncate(generation)),
    });
    const head = try batch.putImmutable(&encoded);
    try batch.prepare();
    model.injectNextPublishFault(fault);
    const previous_state = try cawfs.anchor.decode(&previous.anchor);
    const next = cawfs.anchor.encode(.{
        .revision = @max(previous_state.revision + 1, generation),
        .generation = generation,
        .transaction_id = transaction_id,
        .head = head,
        .mode = .active,
        .mode_epoch = previous_state.mode_epoch,
    });
    const result = try batch.publish(previous.version.bytes, &next);
    if (result == .committed) try batch.stabilize();
    return .{ .head = head, .result = result };
}

test "resolution recognizes an indeterminate current publication" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const published = try publishCommit(&model, txn_a, 1, null, .indeterminate_after);
    try std.testing.expectEqual(PublishResult.indeterminate, published.result);

    try std.testing.expectEqual(
        cawfs.resolution.Resolution.committed,
        try cawfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
}

test "resolution finds a publication below a newer head" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const first = try publishCommit(&model, txn_a, 1, null, .indeterminate_after);
    try std.testing.expectEqual(PublishResult.indeterminate, first.result);
    const second = try publishCommit(&model, txn_b, 2, first.head, .none);
    try std.testing.expectEqual(PublishResult.committed, second.result);

    try std.testing.expectEqual(
        cawfs.resolution.Resolution.committed,
        try cawfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
}

test "resolution remains pending while the base anchor is current" {
    var unchanged = ModelStore.init(std.testing.allocator, initialAnchor());
    defer unchanged.deinit();
    const uncertain = try publishCommit(&unchanged, txn_a, 1, null, .indeterminate_before);
    try std.testing.expectEqual(PublishResult.indeterminate, uncertain.result);
    try std.testing.expectEqual(
        cawfs.resolution.Resolution.pending,
        try cawfs.resolution.resolve(
            unchanged.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
}

test "resolution rejects impossible revision and mode epoch successors" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    _ = try publishCommit(&model, txn_a, 1, null, .none);

    try std.testing.expectError(
        error.InvalidAnchorState,
        cawfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 5, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
    try std.testing.expectError(
        error.RevisionOverflow,
        cawfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = std.math.maxInt(u64), .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
    try std.testing.expectError(
        error.ModeEpochRegression,
        cawfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 2, .transaction_id = txn_a },
            .{},
        ),
    );
}

test "resolution distinguishes a publication replaced by another writer" {
    var replaced = ModelStore.init(std.testing.allocator, initialAnchor());
    defer replaced.deinit();
    _ = try publishCommit(&replaced, txn_b, 1, null, .none);
    try std.testing.expectEqual(
        cawfs.resolution.Resolution.not_committed,
        try cawfs.resolution.resolve(
            replaced.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
}

test "resolution rejects broken and excessively deep ancestry" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    _ = try publishCommit(&model, txn_c, 2, null, .none);

    try std.testing.expectError(
        error.AncestryTooDeep,
        cawfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{ .max_depth = 1 },
        ),
    );
    try std.testing.expectError(
        error.BrokenAncestry,
        cawfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
}

test "resolution rejects a malformed commit object" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var previous = try store.readAnchor(std.testing.allocator);
    defer previous.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_b, previous.version.bytes);
    defer batch.deinit();
    const head = try batch.putImmutable("not-a-commit");
    try batch.prepare();
    const next = cawfs.anchor.encode(.{
        .revision = 2,
        .generation = 2,
        .transaction_id = txn_b,
        .head = head,
        .mode = .active,
        .mode_epoch = 1,
    });
    try std.testing.expectEqual(
        PublishResult.committed,
        try batch.publish(previous.version.bytes, &next),
    );
    try batch.stabilize();

    try std.testing.expectError(
        error.InvalidSize,
        cawfs.resolution.resolve(
            store,
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
}

test "resolution validates the current anchor against its commit" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var previous = try store.readAnchor(std.testing.allocator);
    defer previous.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_b, previous.version.bytes);
    defer batch.deinit();
    const encoded = cawfs.commit.encode(.{
        .generation = 1,
        .transaction_id = txn_c,
        .parent = null,
        .root = patternedRef(1),
    });
    const head = try batch.putImmutable(&encoded);
    try batch.prepare();
    const next = cawfs.anchor.encode(.{
        .revision = 1,
        .generation = 1,
        .transaction_id = txn_b,
        .head = head,
        .mode = .active,
        .mode_epoch = 1,
    });
    try std.testing.expectEqual(
        PublishResult.committed,
        try batch.publish(previous.version.bytes, &next),
    );
    try batch.stabilize();

    try std.testing.expectError(
        error.AnchorCommitMismatch,
        cawfs.resolution.resolve(
            store,
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_b },
            .{},
        ),
    );
}

test "resolution rejects a transaction at the wrong generation" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const first = try publishCommit(&model, txn_b, 1, null, .none);
    _ = try publishCommit(&model, txn_a, 2, first.head, .none);

    try std.testing.expectError(
        error.TransactionGenerationMismatch,
        cawfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
}

fn patternedRef(seed: u8) ObjectRef {
    var result: ObjectRef = .{};
    for (&result.bytes, 0..) |*byte, index| byte.* = seed +% @as(u8, @truncate(index * 11));
    return result;
}
