const std = @import("std");
const cawfs = @import("zettide_cawfs");

const filesystem = cawfs.filesystem;
const format = cawfs.filesystem_format;
const ModelStore = cawfs.model_store.ModelStore;
const Snapshot = filesystem.Snapshot;
const Transaction = cawfs.transaction.Transaction;
const TransactionId = cawfs.store.TransactionId;

const txn_format: TransactionId = .{ 0xf0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const txn_a: TransactionId = .{ 0xfa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
const txn_b: TransactionId = .{ 0xfb, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 };
const txn_c: TransactionId = .{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4 };
const txn_d: TransactionId = .{ 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5 };
const txn_e: TransactionId = .{ 0xfe, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6 };
const txn_f: TransactionId = .{ 0xf1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7 };
const txn_g: TransactionId = .{ 0xf2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8 };

const format_options = filesystem.FormatOptions{
    .mode = 0o40755,
    .uid = 1000,
    .gid = 1001,
    .now_ns = 1_000_000,
};

const file_options = filesystem.CreateFileOptions{
    .mode = 0o100640,
    .uid = 2000,
    .gid = 2001,
    .now_ns = 2_000_000,
};

fn initialAnchor() cawfs.store.Anchor {
    return cawfs.anchor.encode(.{
        .generation = 0,
        .transaction_id = @splat(0),
        .head = null,
    });
}

fn formatStore(model: *ModelStore) !Snapshot {
    const store = model.conditionalStore();
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_format);
    defer transaction.deinit();
    const root = try filesystem.format(&transaction, format_options);
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root));
    return filesystem.open(store, std.testing.allocator);
}

fn stageEmptyFile(
    transaction: *Transaction,
    snapshot: Snapshot,
    name: []const u8,
) !cawfs.store.ObjectRef {
    var mutator = try filesystem.Mutator.init(transaction, snapshot);
    defer mutator.deinit();
    _ = try mutator.createEmptyFile(format.root_inode_id, name, file_options);
    return mutator.finish();
}

fn expectName(snapshot: Snapshot, name: []const u8, present: bool) !void {
    const entry = try snapshot.lookup(std.testing.allocator, format.root_inode_id, name);
    try std.testing.expectEqual(present, entry != null);
}

test "format commit and open establish root invariants" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    try std.testing.expectError(error.Unformatted, filesystem.open(store, std.testing.allocator));

    const snapshot = try formatStore(&model);
    try std.testing.expectEqual(@as(u64, 1), snapshot.generation);
    try std.testing.expectEqual(format.root_inode_id, snapshot.root.root_inode_id);
    try std.testing.expectEqual(@as(format.InodeId, 2), snapshot.root.next_inode_id);
    try std.testing.expectEqual(format.Kind.directory, snapshot.root_inode.kind);
    try std.testing.expectEqual(@as(u64, 2), snapshot.root_inode.link_count);
    try std.testing.expectEqual(format_options.mode, snapshot.root_inode.mode);
    try std.testing.expectEqual(format_options.uid, snapshot.root_inode.uid);
    try std.testing.expectEqual(format_options.gid, snapshot.root_inode.gid);
    try std.testing.expectEqual(format_options.now_ns, snapshot.root_inode.birthtime_ns);
    try std.testing.expect(!try snapshot.hasExtentMappings(std.testing.allocator, format.root_inode_id));

    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    try std.testing.expectError(
        error.AlreadyFormatted,
        filesystem.format(&transaction, format_options),
    );
}

test "empty file survives commit crash and reopen" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    const initial = try formatStore(&model);

    var transaction = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    var mutator = try filesystem.Mutator.init(&transaction, initial);
    defer mutator.deinit();
    const inode_id = try mutator.createEmptyFile(format.root_inode_id, "alpha", file_options);
    try std.testing.expectError(
        error.AlreadyExists,
        mutator.createEmptyFile(format.root_inode_id, "alpha", file_options),
    );
    try std.testing.expectError(
        error.NotDirectory,
        mutator.createEmptyFile(inode_id, "child", file_options),
    );
    try std.testing.expectError(
        error.ParentNotFound,
        mutator.createEmptyFile(999, "missing", file_options),
    );
    const root = try mutator.finish();
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root));

    model.crash();
    const reopened = try filesystem.open(store, std.testing.allocator);
    const entry = (try reopened.lookup(std.testing.allocator, format.root_inode_id, "alpha")).?;
    const inode = (try reopened.getInode(std.testing.allocator, entry.child_inode_id)).?;
    try std.testing.expectEqual(format.Kind.file, inode.kind);
    try std.testing.expectEqual(@as(u64, 0), inode.logical_size);
    try std.testing.expectEqual(@as(u64, 0), inode.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 1), inode.link_count);
    try std.testing.expectEqual(file_options.mode, inode.mode);
    try std.testing.expectEqual(file_options.uid, inode.uid);
    try std.testing.expectEqual(file_options.gid, inode.gid);
    try std.testing.expectEqual(file_options.now_ns, inode.atime_ns);
    try std.testing.expectEqual(file_options.now_ns, inode.mtime_ns);
    try std.testing.expectEqual(file_options.now_ns, inode.ctime_ns);
    try std.testing.expectEqual(file_options.now_ns, inode.birthtime_ns);
    try std.testing.expect(!try reopened.hasExtentMappings(std.testing.allocator, inode.inode_id));
}

test "stale transaction conflicts and replays from winner snapshot" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    const initial = try formatStore(&model);

    var first = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer first.deinit();
    var second = try Transaction.begin(store, std.testing.allocator, txn_b);
    defer second.deinit();
    const first_root = try stageEmptyFile(&first, initial, "alpha");
    const second_root = try stageEmptyFile(&second, initial, "beta");
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try first.commit(first_root));

    const winner = try filesystem.open(store, std.testing.allocator);
    try std.testing.expectError(error.StaleSnapshot, filesystem.Mutator.init(&second, winner));
    try std.testing.expectEqual(cawfs.transaction.Outcome.conflict, try second.commit(second_root));

    var replay = try Transaction.begin(store, std.testing.allocator, txn_c);
    defer replay.deinit();
    const replay_root = try stageEmptyFile(&replay, winner, "beta");
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try replay.commit(replay_root));

    const final = try filesystem.open(store, std.testing.allocator);
    try expectName(final, "alpha", true);
    try expectName(final, "beta", true);
}

test "filesystem mutator rejects an equivalent snapshot from another backend" {
    var first_model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer first_model.deinit();
    var second_model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer second_model.deinit();
    const first_snapshot = try formatStore(&first_model);
    const second_snapshot = try formatStore(&second_model);
    try std.testing.expect(cawfs.store.ObjectRef.eql(
        first_snapshot.commit_ref,
        second_snapshot.commit_ref,
    ));

    var transaction = try Transaction.begin(
        first_model.conditionalStore(),
        std.testing.allocator,
        txn_a,
    );
    defer transaction.deinit();
    try std.testing.expectError(
        error.StaleSnapshot,
        filesystem.Mutator.init(&transaction, second_snapshot),
    );
}

test "empty file creation rejects a colliding next inode without staging" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    const initial = try formatStore(&model);

    var create = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer create.deinit();
    const create_root = try stageEmptyFile(&create, initial, "alpha");
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try create.commit(create_root));

    const current = try filesystem.open(store, std.testing.allocator);
    const entry = (try current.lookup(std.testing.allocator, format.root_inode_id, "alpha")).?;
    var collision = current;
    collision.root.next_inode_id = entry.child_inode_id;
    var transaction = try Transaction.begin(store, std.testing.allocator, txn_f);
    defer transaction.deinit();
    var mutator = try filesystem.Mutator.init(&transaction, collision);
    defer mutator.deinit();
    const staged_before = transaction.staged.items.len;
    try std.testing.expectError(
        error.InodeIdCollision,
        mutator.createEmptyFile(format.root_inode_id, "beta", file_options),
    );
    try std.testing.expectEqual(staged_before, transaction.staged.items.len);
    try std.testing.expectEqual(
        file_options.mode,
        (try current.getInode(std.testing.allocator, entry.child_inode_id)).?.mode,
    );
}

test "extent scan rejects a malformed key at the inode prefix" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    const initial = try formatStore(&model);

    var transaction = try Transaction.begin(store, std.testing.allocator, txn_g);
    defer transaction.deinit();
    var trees = cawfs.tree.Mutator.init(&transaction);
    defer trees.deinit();
    const malformed_key = try format.encodeInodeKey(format.root_inode_id);
    const mapping = try format.encodeExtentMapping(.{
        .inode_id = format.root_inode_id,
        .logical_offset = 0,
        .byte_length = 1,
        .extent_index = 0,
        .extent_offset = 0,
        .claim_epoch = 1,
        .claim_id = @splat(1),
    });
    var root = initial.root;
    root.extent_tree_root = try trees.put(root.extent_tree_root, &malformed_key, &mapping);
    const encoded_root = try format.encodeFilesystemRoot(root);
    const root_ref = try transaction.putImmutable(&encoded_root);
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root_ref));

    const malformed = try filesystem.open(store, std.testing.allocator);
    try std.testing.expectError(
        error.InvalidSize,
        malformed.hasExtentMappings(std.testing.allocator, format.root_inode_id),
    );
}

test "indeterminate applied filesystem commit resolves and survives crash" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    const initial = try formatStore(&model);

    var transaction = try Transaction.begin(store, std.testing.allocator, txn_d);
    defer transaction.deinit();
    const root = try stageEmptyFile(&transaction, initial, "applied");
    model.injectNextPublishFault(.indeterminate_after);
    try std.testing.expectEqual(cawfs.transaction.Outcome.indeterminate, try transaction.commit(root));
    try std.testing.expectEqual(
        cawfs.resolution.Resolution.committed,
        try transaction.resolve(.{}),
    );
    try transaction.stabilize();

    model.crash();
    const reopened = try filesystem.open(store, std.testing.allocator);
    try expectName(reopened, "applied", true);
}

test "indeterminate unapplied filesystem commit remains pending then is absent" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    const initial = try formatStore(&model);

    var transaction = try Transaction.begin(store, std.testing.allocator, txn_e);
    defer transaction.deinit();
    const root = try stageEmptyFile(&transaction, initial, "unapplied");
    model.injectNextPublishFault(.indeterminate_before);
    try std.testing.expectEqual(cawfs.transaction.Outcome.indeterminate, try transaction.commit(root));
    try std.testing.expectEqual(cawfs.resolution.Resolution.pending, try transaction.resolve(.{}));

    model.crash();
    try std.testing.expectEqual(
        cawfs.resolution.Resolution.not_committed,
        try transaction.resolve(.{}),
    );
    const reopened = try filesystem.open(store, std.testing.allocator);
    try expectName(reopened, "unapplied", false);
}

test "filesystem commit retries stabilization without republishing" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    const initial = try formatStore(&model);

    var transaction = try Transaction.begin(store, std.testing.allocator, txn_c);
    defer transaction.deinit();
    const root = try stageEmptyFile(&transaction, initial, "stable");
    model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, transaction.commit(root));
    try std.testing.expectEqual(cawfs.transaction.Status.published, transaction.status());
    try transaction.stabilize();

    model.crash();
    const reopened = try filesystem.open(store, std.testing.allocator);
    try expectName(reopened, "stable", true);
}
