const std = @import("std");
const txfs = @import("zettide_txfs");

const ModelStore = txfs.model_store.ModelStore;
const Transition = txfs.maintenance.Transition;

const operation_a: [16]u8 = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const operation_b: [16]u8 = .{ 0xb2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };

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

fn commitTransition(
    store: txfs.store.ConditionalStore,
    operation_id: txfs.store.TransactionId,
    mode: txfs.anchor.Mode,
) !void {
    var transition = try Transition.begin(store, std.testing.allocator, operation_id, mode);
    defer transition.deinit();
    try std.testing.expectEqual(txfs.maintenance.Outcome.committed, try transition.commit());
    try std.testing.expectEqual(txfs.maintenance.Status.committed, transition.status());
}

test "maintenance coordinator completes a full service-mode cycle" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();

    try commitTransition(store, operation_a, .quiescing);
    try commitTransition(store, operation_a, .maintenance);
    try commitTransition(store, operation_a, .active);

    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    const state = try txfs.anchor.decode(&snapshot.anchor);
    try std.testing.expectEqual(@as(u64, 3), state.revision);
    try std.testing.expectEqual(@as(u64, 0), state.generation);
    try std.testing.expectEqual(txfs.anchor.Mode.active, state.mode);
    try std.testing.expectEqual(@as(u64, 2), state.mode_epoch);
    try std.testing.expectEqual(@as(txfs.store.TransactionId, @splat(0)), state.control_operation_id);

    var active_bytes = try store.loadImmutable(state.control_ref.?, std.testing.allocator);
    defer active_bytes.deinit();
    const active = try txfs.maintenance.decode(active_bytes.bytes);
    try std.testing.expectEqual(txfs.anchor.Mode.maintenance, active.previous_mode);
    try std.testing.expectEqual(txfs.anchor.Mode.active, active.mode);
    var maintenance_bytes = try store.loadImmutable(active.parent.?, std.testing.allocator);
    defer maintenance_bytes.deinit();
    const maintenance = try txfs.maintenance.decode(maintenance_bytes.bytes);
    try std.testing.expectEqual(txfs.anchor.Mode.quiescing, maintenance.previous_mode);
    try std.testing.expectEqual(txfs.anchor.Mode.maintenance, maintenance.mode);
}

test "maintenance coordinator rejects invalid transitions and operation changes" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();

    try std.testing.expectError(
        error.InvalidTransition,
        Transition.begin(store, std.testing.allocator, operation_a, .maintenance),
    );
    try std.testing.expectError(
        error.InvalidOperationId,
        Transition.begin(store, std.testing.allocator, @splat(0), .quiescing),
    );
    try commitTransition(store, operation_a, .quiescing);
    try std.testing.expectError(
        error.InvalidOperationId,
        Transition.begin(store, std.testing.allocator, operation_b, .maintenance),
    );
    try commitTransition(store, operation_a, .blocked);
    try std.testing.expectError(
        error.InvalidTransition,
        Transition.begin(store, std.testing.allocator, operation_a, .active),
    );
}

test "maintenance coordinator rejects a missing control tip" {
    const missing_ref = txfs.store.ObjectRef{ .bytes = @splat(0x51) };
    const invalid = txfs.anchor.encode(.{
        .revision = 1,
        .generation = 0,
        .transaction_id = @splat(0),
        .head = null,
        .mode = .quiescing,
        .mode_epoch = 2,
        .control_operation_id = operation_a,
        .control_ref = missing_ref,
    });
    var model = ModelStore.init(std.testing.allocator, invalid);
    defer model.deinit();

    try std.testing.expectError(
        error.ObjectNotFound,
        Transition.begin(
            model.conditionalStore(),
            std.testing.allocator,
            operation_a,
            .maintenance,
        ),
    );
}

test "concurrent maintenance operations have one winner" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var first = try Transition.begin(store, std.testing.allocator, operation_a, .quiescing);
    defer first.deinit();
    var second = try Transition.begin(store, std.testing.allocator, operation_b, .quiescing);
    defer second.deinit();

    try std.testing.expectEqual(txfs.maintenance.Outcome.committed, try first.commit());
    try std.testing.expectEqual(txfs.maintenance.Outcome.conflict, try second.commit());
    try std.testing.expectEqual(txfs.maintenance.Status.conflict, second.status());
}

test "maintenance resolution distinguishes pending rollback and commit" {
    var before_model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer before_model.deinit();
    const before_store = before_model.conditionalStore();
    var before = try Transition.begin(
        before_store,
        std.testing.allocator,
        operation_a,
        .quiescing,
    );
    defer before.deinit();
    before_model.injectNextPublishFault(.indeterminate_before);
    try std.testing.expectEqual(txfs.maintenance.Outcome.indeterminate, try before.commit());
    try std.testing.expectEqual(
        txfs.maintenance.Resolution.pending,
        try before.resolve(.{}),
    );
    before_model.crash();
    try std.testing.expectEqual(
        txfs.maintenance.Resolution.not_committed,
        try before.resolve(.{}),
    );

    var after_model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer after_model.deinit();
    const after_store = after_model.conditionalStore();
    var after = try Transition.begin(
        after_store,
        std.testing.allocator,
        operation_a,
        .quiescing,
    );
    defer after.deinit();
    after_model.injectNextPublishFault(.indeterminate_after);
    try std.testing.expectEqual(txfs.maintenance.Outcome.indeterminate, try after.commit());
    try std.testing.expectEqual(
        txfs.maintenance.Resolution.committed,
        try after.resolve(.{}),
    );
    try after.stabilize();
    try std.testing.expectEqual(txfs.maintenance.Status.committed, after.status());
}

test "maintenance resolution finds a transition below a descendant" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var quiescing = try Transition.begin(store, std.testing.allocator, operation_a, .quiescing);
    defer quiescing.deinit();
    model.injectNextPublishFault(.indeterminate_after);
    try std.testing.expectEqual(txfs.maintenance.Outcome.indeterminate, try quiescing.commit());

    try commitTransition(store, operation_a, .maintenance);
    model.crash();
    try std.testing.expectEqual(
        txfs.maintenance.Resolution.committed,
        try quiescing.resolve(.{}),
    );
    try quiescing.stabilize();
}

test "terminal maintenance resolution handles a rolled-back base" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var quiescing = try Transition.begin(store, std.testing.allocator, operation_a, .quiescing);
    defer quiescing.deinit();
    model.injectNextPublishFault(.indeterminate_after);
    try std.testing.expectEqual(txfs.maintenance.Outcome.indeterminate, try quiescing.commit());

    var maintenance = try Transition.begin(store, std.testing.allocator, operation_a, .maintenance);
    defer maintenance.deinit();
    model.injectNextPublishFault(.indeterminate_before);
    try std.testing.expectEqual(txfs.maintenance.Outcome.indeterminate, try maintenance.commit());
    model.crash();

    try std.testing.expectEqual(
        txfs.maintenance.Resolution.not_committed,
        try maintenance.resolve(.{}),
    );
}
