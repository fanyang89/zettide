const std = @import("std");
const txfs = @import("zettide_txfs");

const Anchor = txfs.store.Anchor;
const ModelStore = txfs.model_store.ModelStore;
const ObjectRef = txfs.store.ObjectRef;
const PublishFault = txfs.model_store.PublishFault;
const PublishResult = txfs.store.PublishResult;
const TransactionId = txfs.store.TransactionId;

const txn_a: TransactionId = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const txn_b: TransactionId = .{ 0xb2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
const txn_c: TransactionId = .{ 0xc3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 };

const Published = struct {
    head: ObjectRef,
    result: PublishResult,
};

fn initialAnchor() Anchor {
    return txfs.anchor.encode(.{
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
    const encoded = txfs.commit.encode(.{
        .generation = generation,
        .transaction_id = transaction_id,
        .parent = parent,
        .root = patternedRef(@truncate(generation)),
    });
    const head = try batch.putImmutable(&encoded);
    try batch.prepare();
    model.injectNextPublishFault(fault);
    const previous_state = try txfs.anchor.decode(&previous.anchor);
    const next = txfs.anchor.encode(.{
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
        txfs.resolution.Resolution.committed,
        try txfs.resolution.resolve(
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
        txfs.resolution.Resolution.committed,
        try txfs.resolution.resolve(
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
        txfs.resolution.Resolution.pending,
        try txfs.resolution.resolve(
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
        txfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 5, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
    try std.testing.expectError(
        error.RevisionOverflow,
        txfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = std.math.maxInt(u64), .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{},
        ),
    );
    try std.testing.expectError(
        error.ModeEpochRegression,
        txfs.resolution.resolve(
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
        txfs.resolution.Resolution.not_committed,
        try txfs.resolution.resolve(
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
        txfs.resolution.resolve(
            model.conditionalStore(),
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_a },
            .{ .max_depth = 1 },
        ),
    );
    try std.testing.expectError(
        error.BrokenAncestry,
        txfs.resolution.resolve(
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
    const next = txfs.anchor.encode(.{
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
        txfs.resolution.resolve(
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
    const encoded = txfs.commit.encode(.{
        .generation = 1,
        .transaction_id = txn_c,
        .parent = null,
        .root = patternedRef(1),
    });
    const head = try batch.putImmutable(&encoded);
    try batch.prepare();
    const next = txfs.anchor.encode(.{
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
        txfs.resolution.resolve(
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
        txfs.resolution.resolve(
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
