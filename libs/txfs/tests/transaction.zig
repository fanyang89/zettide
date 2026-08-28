const std = @import("std");
const txfs = @import("zettide_txfs");

const ModelStore = txfs.model_store.ModelStore;
const ObjectRef = txfs.store.ObjectRef;
const Transaction = txfs.transaction.Transaction;
const TransactionId = txfs.store.TransactionId;

const txn_a: TransactionId = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const txn_b: TransactionId = .{ 0xb2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };

fn initialAnchor() txfs.store.Anchor {
    return txfs.anchor.encode(.{
        .revision = 0,
        .generation = 0,
        .transaction_id = @splat(0),
        .head = null,
        .mode = .active,
        .mode_epoch = 1,
    });
}

test "transaction publishes and stabilizes an immutable root" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();

    const root = try transaction.putImmutable("root-a");
    try std.testing.expectEqual(
        txfs.transaction.Outcome.committed,
        try transaction.commit(root),
    );
    try std.testing.expectEqual(txfs.transaction.Status.committed, transaction.status());

    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    const current = try txfs.anchor.decode(&snapshot.anchor);
    try std.testing.expectEqual(@as(u64, 1), current.revision);
    try std.testing.expectEqual(@as(u64, 1), current.generation);
    try std.testing.expectEqual(txn_a, current.transaction_id);
    try std.testing.expect(txfs.store.ObjectRef.eql(transaction.candidateCommitRef().?, current.head.?));

    var record_bytes = try store.loadImmutable(current.head.?, std.testing.allocator);
    defer record_bytes.deinit();
    const record = try txfs.commit.decode(record_bytes.bytes);
    try std.testing.expectEqual(@as(?ObjectRef, null), record.parent);
    try std.testing.expect(txfs.store.ObjectRef.eql(root, record.root));
}

test "transactions publishing the same base have one winner" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var first = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer first.deinit();
    var second = try Transaction.begin(store, std.testing.allocator, txn_b);
    defer second.deinit();
    const first_root = try first.putImmutable("root-a");
    const second_root = try second.putImmutable("root-b");

    try std.testing.expectEqual(txfs.transaction.Outcome.committed, try first.commit(first_root));
    try std.testing.expectEqual(txfs.transaction.Outcome.conflict, try second.commit(second_root));
    try std.testing.expectEqual(txfs.transaction.Status.committed, first.status());
    try std.testing.expectEqual(txfs.transaction.Status.conflict, second.status());
}

test "transaction resolves an indeterminate applied publication" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    const root = try transaction.putImmutable("root-a");
    model.injectNextPublishFault(.indeterminate_after);

    try std.testing.expectEqual(
        txfs.transaction.Outcome.indeterminate,
        try transaction.commit(root),
    );
    try std.testing.expectEqual(txfs.transaction.Status.indeterminate, transaction.status());
    try std.testing.expectEqual(
        txfs.resolution.Resolution.committed,
        try transaction.resolve(.{}),
    );
    try std.testing.expectEqual(txfs.transaction.Status.published, transaction.status());
    try transaction.stabilize();
    try std.testing.expectEqual(txfs.transaction.Status.committed, transaction.status());

    model.crash();
    var recovered = try store.readAnchor(std.testing.allocator);
    defer recovered.deinit();
    const current = try txfs.anchor.decode(&recovered.anchor);
    try std.testing.expectEqual(txn_a, current.transaction_id);
}

test "transaction remains pending until another writer wins" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var uncertain = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer uncertain.deinit();
    const uncertain_root = try uncertain.putImmutable("root-a");
    model.injectNextPublishFault(.indeterminate_before);
    try std.testing.expectEqual(
        txfs.transaction.Outcome.indeterminate,
        try uncertain.commit(uncertain_root),
    );
    try std.testing.expectEqual(txfs.resolution.Resolution.pending, try uncertain.resolve(.{}));

    var winner = try Transaction.begin(store, std.testing.allocator, txn_b);
    defer winner.deinit();
    const winner_root = try winner.putImmutable("root-b");
    try std.testing.expectEqual(txfs.transaction.Outcome.committed, try winner.commit(winner_root));

    try std.testing.expectEqual(
        txfs.resolution.Resolution.not_committed,
        try uncertain.resolve(.{}),
    );
    try std.testing.expectEqual(txfs.transaction.Status.not_committed, uncertain.status());
}

test "reset terminates an indeterminate publication that did not run" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    var transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        txn_a,
    );
    defer transaction.deinit();
    const root = try transaction.putImmutable("root-a");
    model.injectNextPublishFault(.indeterminate_before);
    try std.testing.expectEqual(
        txfs.transaction.Outcome.indeterminate,
        try transaction.commit(root),
    );

    model.crash();
    try std.testing.expectEqual(
        txfs.resolution.Resolution.not_committed,
        try transaction.resolve(.{}),
    );
}

test "transaction retries stabilization without republishing" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    var transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        txn_a,
    );
    defer transaction.deinit();
    const root = try transaction.putImmutable("root-a");
    model.injectNextStabilizeFailure();

    try std.testing.expectError(error.InjectedStabilizeFailure, transaction.commit(root));
    try std.testing.expectEqual(txfs.transaction.Status.published, transaction.status());
    try transaction.stabilize();
    try std.testing.expectEqual(txfs.transaction.Status.committed, transaction.status());
    var snapshot = try model.conditionalStore().readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 1), (try txfs.anchor.decode(&snapshot.anchor)).generation);
}

test "transaction resolves a publication rolled back after stabilization failure" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    var transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        txn_a,
    );
    defer transaction.deinit();
    const root = try transaction.putImmutable("root-a");
    model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, transaction.commit(root));

    model.crash();
    try std.testing.expectEqual(
        txfs.resolution.Resolution.not_committed,
        try transaction.resolve(.{}),
    );
    try std.testing.expectEqual(txfs.transaction.Status.not_committed, transaction.status());
}

test "transaction resolves rollback before its unstable base" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var first = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer first.deinit();
    const first_root = try first.putImmutable("root-a");
    model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, first.commit(first_root));

    var second = try Transaction.begin(store, std.testing.allocator, txn_b);
    defer second.deinit();
    const second_root = try second.putImmutable("root-b");
    model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, second.commit(second_root));

    model.crash();
    try std.testing.expectEqual(
        txfs.resolution.Resolution.not_committed,
        try second.resolve(.{}),
    );
    try std.testing.expectEqual(txfs.transaction.Status.not_committed, second.status());
}

test "transaction rejects an unavailable root" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    var transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        txn_a,
    );
    defer transaction.deinit();

    try std.testing.expectError(error.ObjectNotFound, transaction.commit(.{}));
    try std.testing.expectEqual(txfs.transaction.Status.staging, transaction.status());
    try std.testing.expectEqual(@as(?ObjectRef, null), transaction.candidateCommitRef());
}

test "transaction rejects invalid anchor semantics and terminal reuse" {
    const invalid = txfs.anchor.encode(.{
        .revision = 1,
        .generation = 1,
        .transaction_id = txn_a,
        .head = null,
        .mode = .active,
        .mode_epoch = 1,
    });
    var invalid_model = ModelStore.init(std.testing.allocator, invalid);
    defer invalid_model.deinit();
    try std.testing.expectError(
        error.InvalidGenerationState,
        Transaction.begin(invalid_model.conditionalStore(), std.testing.allocator, txn_b),
    );

    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    var transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        txn_a,
    );
    defer transaction.deinit();
    const root = try transaction.putImmutable("root-a");
    _ = try transaction.commit(root);
    try std.testing.expectError(error.InvalidState, transaction.putImmutable("late"));
    try std.testing.expectError(error.InvalidState, transaction.commit(root));
    try std.testing.expectError(error.InvalidState, transaction.stabilize());
    try std.testing.expectError(error.InvalidState, transaction.resolve(.{}));
}

test "transaction validates the current head commit" {
    const missing = txfs.anchor.encode(.{
        .revision = 1,
        .generation = 1,
        .transaction_id = txn_a,
        .head = .{},
        .mode = .active,
        .mode_epoch = 1,
    });
    var model = ModelStore.init(std.testing.allocator, missing);
    defer model.deinit();

    try std.testing.expectError(
        error.ObjectNotFound,
        Transaction.begin(model.conditionalStore(), std.testing.allocator, txn_b),
    );
}

test "transaction rejects a head with an impossible parent" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var previous = try store.readAnchor(std.testing.allocator);
    defer previous.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, previous.version.bytes);
    defer batch.deinit();
    const root = try batch.putImmutable("root-a");
    const encoded = txfs.commit.encode(.{
        .generation = 2,
        .transaction_id = txn_a,
        .parent = null,
        .root = root,
    });
    const head = try batch.putImmutable(&encoded);
    try batch.prepare();
    const invalid = txfs.anchor.encode(.{
        .revision = 2,
        .generation = 2,
        .transaction_id = txn_a,
        .head = head,
        .mode = .active,
        .mode_epoch = 1,
    });
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch.publish(previous.version.bytes, &invalid),
    );
    try batch.stabilize();

    try std.testing.expectError(
        error.InvalidAnchorState,
        Transaction.begin(store, std.testing.allocator, txn_b),
    );
}

test "maintenance revision fences old publications and blocks transactions" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var previous = try store.readAnchor(std.testing.allocator);
    defer previous.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, previous.version.bytes);
    defer batch.deinit();
    const control = try batch.putImmutable("maintenance intent");
    try batch.prepare();
    const quiescing = txfs.anchor.encode(.{
        .revision = 1,
        .generation = 0,
        .transaction_id = @splat(0),
        .head = null,
        .mode = .quiescing,
        .mode_epoch = 2,
        .control_operation_id = txn_a,
        .control_ref = control,
    });
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch.publish(previous.version.bytes, &quiescing),
    );
    try batch.stabilize();

    try std.testing.expectError(
        error.VolumeNotActive,
        Transaction.begin(store, std.testing.allocator, txn_b),
    );
    try std.testing.expectEqual(
        txfs.resolution.Resolution.not_committed,
        try txfs.resolution.resolve(
            store,
            std.testing.allocator,
            .{ .base_revision = 0, .base_generation = 0, .base_mode_epoch = 1, .transaction_id = txn_b },
            .{},
        ),
    );
}

test "normal transaction preserves control ancestry" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    for ([_]txfs.anchor.Mode{ .quiescing, .maintenance, .active }) |mode| {
        var transition = try txfs.maintenance.Transition.begin(
            store,
            std.testing.allocator,
            txn_a,
            mode,
        );
        defer transition.deinit();
        try std.testing.expectEqual(
            txfs.maintenance.Outcome.committed,
            try transition.commit(),
        );
    }
    var previous = try store.readAnchor(std.testing.allocator);
    defer previous.deinit();
    const control = (try txfs.anchor.decode(&previous.anchor)).control_ref.?;

    var transaction = try Transaction.begin(store, std.testing.allocator, txn_b);
    defer transaction.deinit();
    const root = try transaction.putImmutable("root after maintenance");
    try std.testing.expectEqual(txfs.transaction.Outcome.committed, try transaction.commit(root));

    var current = try store.readAnchor(std.testing.allocator);
    defer current.deinit();
    const state = try txfs.anchor.decode(&current.anchor);
    try std.testing.expect(txfs.store.ObjectRef.eql(control, state.control_ref.?));
}
