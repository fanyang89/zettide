const std = @import("std");
const cawfs = @import("zettide_cawfs");

const ModelStore = cawfs.model_store.ModelStore;
const ObjectRef = cawfs.store.ObjectRef;
const Transaction = cawfs.transaction.Transaction;
const TransactionId = cawfs.store.TransactionId;

const txn_a: TransactionId = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const txn_b: TransactionId = .{ 0xb2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
const txn_c: TransactionId = .{ 0xc3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 };

fn initialAnchor() cawfs.store.Anchor {
    return cawfs.anchor.encode(.{
        .generation = 0,
        .transaction_id = @splat(0),
        .head = null,
    });
}

fn currentRoot(store: cawfs.store.ConditionalStore) !ObjectRef {
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    const state = try cawfs.anchor.decode(&snapshot.anchor);
    var bytes = try store.loadImmutable(state.head.?, std.testing.allocator);
    defer bytes.deinit();
    return (try cawfs.commit.decode(bytes.bytes)).root;
}

fn expectValue(
    store: cawfs.store.ConditionalStore,
    root: ObjectRef,
    key: []const u8,
    expected: ?[]const u8,
) !void {
    var actual = try cawfs.tree.get(store, std.testing.allocator, root, key);
    defer if (actual) |*value| value.deinit();
    if (expected) |value| {
        try std.testing.expectEqualStrings(value, actual.?.bytes);
    } else {
        try std.testing.expectEqual(@as(?cawfs.store.OwnedBytes, null), actual);
    }
}

test "tree inserts replaces and publishes a root" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    var mutator = cawfs.tree.Mutator.init(&transaction);
    defer mutator.deinit();

    var root = try mutator.createEmpty();
    try std.testing.expectEqual(@as(?cawfs.store.OwnedBytes, null), try mutator.get(root, "missing"));
    root = try mutator.put(root, "beta", "two");
    root = try mutator.put(root, "alpha", "one");
    const historical_root = root;
    root = try mutator.put(root, "delta", "three");
    root = try mutator.put(root, "beta", "updated");
    var speculative = (try mutator.get(root, "beta")).?;
    defer speculative.deinit();
    try std.testing.expectEqualStrings("updated", speculative.bytes);
    var historical = (try mutator.get(historical_root, "beta")).?;
    defer historical.deinit();
    try std.testing.expectEqualStrings("two", historical.bytes);
    try std.testing.expectEqual(
        @as(?cawfs.store.OwnedBytes, null),
        try mutator.get(historical_root, "delta"),
    );

    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root));
    try expectValue(store, root, "alpha", "one");
    try expectValue(store, root, "beta", "updated");
    try expectValue(store, root, "charlie", null);
}

test "tree splits leaves and internal pages" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    var mutator = cawfs.tree.Mutator.init(&transaction);
    defer mutator.deinit();
    var root = try mutator.createEmpty();
    const value = "v" ** 900;
    var key_buffer: [16]u8 = undefined;
    for (0..240) |index| {
        const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>4}", .{index});
        root = try mutator.put(root, key, value);
    }

    var first = (try mutator.get(root, "k0000")).?;
    defer first.deinit();
    try std.testing.expectEqualStrings(value, first.bytes);
    var middle = (try mutator.get(root, "k0119")).?;
    defer middle.deinit();
    try std.testing.expectEqualStrings(value, middle.bytes);
    var last = (try mutator.get(root, "k0239")).?;
    defer last.deinit();
    try std.testing.expectEqualStrings(value, last.bytes);

    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root));
    var root_bytes = try store.loadImmutable(root, std.testing.allocator);
    defer root_bytes.deinit();
    const root_page = try cawfs.page.decode(root_bytes.bytes);
    try std.testing.expectEqual(cawfs.page.Kind.internal, root_page.kind);
    try std.testing.expect(root_page.level >= 2);
    try expectValue(store, root, "k0119", value);
}

test "tree matches a randomized replacement model" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    var mutator = cawfs.tree.Mutator.init(&transaction);
    defer mutator.deinit();
    var root = try mutator.createEmpty();

    var expected: [80]?u32 = @splat(null);
    var random = std.Random.DefaultPrng.init(0x5eed_ca7f);
    var key_buffer: [16]u8 = undefined;
    var value_buffer: [16]u8 = undefined;
    for (0..500) |operation| {
        const key_index = random.random().intRangeLessThan(usize, 0, expected.len);
        expected[key_index] = @intCast(operation);
        const key = try std.fmt.bufPrint(&key_buffer, "key-{d:0>3}", .{key_index});
        const value = try std.fmt.bufPrint(&value_buffer, "value-{d}", .{operation});
        root = try mutator.put(root, key, value);
    }
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root));

    for (expected, 0..) |operation, key_index| {
        const key = try std.fmt.bufPrint(&key_buffer, "key-{d:0>3}", .{key_index});
        if (operation) |value_index| {
            const value = try std.fmt.bufPrint(&value_buffer, "value-{d}", .{value_index});
            try expectValue(store, root, key, value);
        } else {
            try expectValue(store, root, key, null);
        }
    }
}

test "tree splits correctly under randomized insertion order" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    var mutator = cawfs.tree.Mutator.init(&transaction);
    defer mutator.deinit();
    var root = try mutator.createEmpty();

    var order: [180]u16 = undefined;
    for (&order, 0..) |*item, index| item.* = @intCast(index);
    var random = std.Random.DefaultPrng.init(0x71_7d_ba5e);
    random.random().shuffle(u16, &order);
    const value = "r" ** 900;
    var key_buffer: [16]u8 = undefined;
    for (order) |key_index| {
        const key = try std.fmt.bufPrint(&key_buffer, "r{d:0>4}", .{key_index});
        root = try mutator.put(root, key, value);
    }
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root));

    for (0..order.len) |key_index| {
        const key = try std.fmt.bufPrint(&key_buffer, "r{d:0>4}", .{key_index});
        try expectValue(store, root, key, value);
    }
}

test "tree conflict is replayed from the winning root" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();

    var initial_transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer initial_transaction.deinit();
    var initial_mutator = cawfs.tree.Mutator.init(&initial_transaction);
    defer initial_mutator.deinit();
    const empty = try initial_mutator.createEmpty();
    try std.testing.expectEqual(
        cawfs.transaction.Outcome.committed,
        try initial_transaction.commit(empty),
    );

    var first = try Transaction.begin(store, std.testing.allocator, txn_b);
    defer first.deinit();
    var first_mutator = cawfs.tree.Mutator.init(&first);
    defer first_mutator.deinit();
    const first_root = try first_mutator.put(empty, "alpha", "one");

    var loser = try Transaction.begin(store, std.testing.allocator, txn_c);
    defer loser.deinit();
    var loser_mutator = cawfs.tree.Mutator.init(&loser);
    defer loser_mutator.deinit();
    const losing_root = try loser_mutator.put(empty, "beta", "two");

    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try first.commit(first_root));
    try std.testing.expectEqual(cawfs.transaction.Outcome.conflict, try loser.commit(losing_root));

    var replay = try Transaction.begin(
        store,
        std.testing.allocator,
        .{ 0xd4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4 },
    );
    defer replay.deinit();
    var replay_mutator = cawfs.tree.Mutator.init(&replay);
    defer replay_mutator.deinit();
    const replayed_root = try replay_mutator.put(try currentRoot(store), "beta", "two");
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try replay.commit(replayed_root));

    try expectValue(store, replayed_root, "alpha", "one");
    try expectValue(store, replayed_root, "beta", "two");
}

test "tree enforces key and inline entry limits" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    var transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        txn_a,
    );
    defer transaction.deinit();
    var mutator = cawfs.tree.Mutator.init(&transaction);
    defer mutator.deinit();
    const root = try mutator.createEmpty();

    try std.testing.expectError(
        error.KeyTooLarge,
        mutator.put(root, "k" ** (cawfs.tree.max_key_size + 1), "value"),
    );
    try std.testing.expectError(
        error.EntryTooLarge,
        mutator.put(root, "key", "v" ** cawfs.tree.max_entry_payload),
    );
}

test "tree enforces the speculative page budget" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    var transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        txn_a,
    );
    defer transaction.deinit();
    var mutator = cawfs.tree.Mutator.initOptions(&transaction, .{ .max_staged_pages = 1 });
    defer mutator.deinit();
    const root = try mutator.createEmpty();

    try std.testing.expectError(error.StagedPageLimit, mutator.put(root, "key", "value"));
}

test "tree rejects inconsistent and excessive levels" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    var mutator = cawfs.tree.Mutator.init(&transaction);
    defer mutator.deinit();
    const leaf = try mutator.createEmpty();
    const inconsistent_page = try cawfs.page.encodeInternal(2, leaf, &.{.{
        .key = "m",
        .child = leaf,
    }});
    const inconsistent = try transaction.putImmutable(&inconsistent_page);
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(inconsistent));
    try std.testing.expectError(
        error.LevelMismatch,
        cawfs.tree.get(store, std.testing.allocator, inconsistent, "a"),
    );

    var second = try Transaction.begin(store, std.testing.allocator, txn_b);
    defer second.deinit();
    const excessive_page = try cawfs.page.encodeInternal(cawfs.tree.max_height + 1, leaf, &.{.{
        .key = "m",
        .child = leaf,
    }});
    const excessive = try second.putImmutable(&excessive_page);
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try second.commit(excessive));
    try std.testing.expectError(
        error.TreeTooDeep,
        cawfs.tree.get(store, std.testing.allocator, excessive, "a"),
    );
}
