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

fn createCommittedEmptyFile(
    model: *ModelStore,
    snapshot: Snapshot,
    transaction_id: TransactionId,
    name: []const u8,
) !Snapshot {
    var transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        transaction_id,
    );
    defer transaction.deinit();
    const root = try stageEmptyFile(&transaction, snapshot, name);
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root));
    return filesystem.open(model.conditionalStore(), std.testing.allocator);
}

fn inodeForName(snapshot: Snapshot, name: []const u8) !format.Inode {
    const entry = (try snapshot.lookup(std.testing.allocator, format.root_inode_id, name)).?;
    return (try snapshot.getInode(std.testing.allocator, entry.child_inode_id)).?;
}

fn stageInode(
    trees: *cawfs.tree.Mutator,
    root: *format.FilesystemRoot,
    inode: format.Inode,
) !void {
    const key = try format.encodeInodeKey(inode.inode_id);
    const encoded = try format.encodeInode(inode);
    root.inode_tree_root = try trees.put(root.inode_tree_root, &key, &encoded);
}

fn stageMapping(
    trees: *cawfs.tree.Mutator,
    root: *format.FilesystemRoot,
    key: []const u8,
    mapping: format.ExtentMapping,
) !void {
    const encoded = try format.encodeExtentMapping(mapping);
    root.extent_tree_root = try trees.put(root.extent_tree_root, key, &encoded);
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
    var data = try reopened.readWholeFile(std.testing.allocator, inode.inode_id);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 0), data.bytes.len);
    try std.testing.expectError(
        error.NotFile,
        reopened.readWholeFile(std.testing.allocator, format.root_inode_id),
    );
    try std.testing.expectError(
        error.InodeNotFound,
        reopened.readWholeFile(std.testing.allocator, 999),
    );
}

test "whole-file write commits reopens and preserves inode metadata" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const formatted = try formatStore(&model);
    const empty = try createCommittedEmptyFile(&model, formatted, txn_a, "alpha");
    const before = try inodeForName(empty, "alpha");

    var transaction = try Transaction.begin(model.conditionalStore(), std.testing.allocator, txn_b);
    defer transaction.deinit();
    var mutator = try filesystem.Mutator.init(&transaction, empty);
    defer mutator.deinit();
    try mutator.writeWholeFileOnce(before.inode_id, "immutable contents", .{ .now_ns = 3_000_000 });
    const root = try mutator.finish();
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try transaction.commit(root));

    model.crash();
    const reopened = try filesystem.open(model.conditionalStore(), std.testing.allocator);
    var data = try reopened.readWholeFile(std.testing.allocator, before.inode_id);
    defer data.deinit();
    try std.testing.expectEqualStrings("immutable contents", data.bytes);
    const after = (try reopened.getInode(std.testing.allocator, before.inode_id)).?;
    try std.testing.expectEqual(@as(u64, "immutable contents".len), after.logical_size);
    try std.testing.expectEqual(after.logical_size, after.allocated_bytes);
    try std.testing.expectEqual(@as(u64, 3_000_000), after.mtime_ns);
    try std.testing.expectEqual(@as(u64, 3_000_000), after.ctime_ns);
    try std.testing.expectEqual(before.atime_ns, after.atime_ns);
    try std.testing.expectEqual(before.birthtime_ns, after.birthtime_ns);
    try std.testing.expectEqual(before.mode, after.mode);
    try std.testing.expectEqual(before.uid, after.uid);
    try std.testing.expectEqual(before.gid, after.gid);
    try std.testing.expectEqual(before.link_count, after.link_count);
}

test "whole-file write validation does not mutate the candidate root" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const formatted = try formatStore(&model);
    const empty = try createCommittedEmptyFile(&model, formatted, txn_a, "alpha");
    const inode = try inodeForName(empty, "alpha");

    var transaction = try Transaction.begin(model.conditionalStore(), std.testing.allocator, txn_b);
    defer transaction.deinit();
    var mutator = try filesystem.Mutator.init(&transaction, empty);
    defer mutator.deinit();
    const original_root = mutator.root;
    const original_staged = transaction.staged.items.len;
    try std.testing.expectError(
        error.EmptyWrite,
        mutator.writeWholeFileOnce(inode.inode_id, "", .{ .now_ns = 3 }),
    );
    try std.testing.expectError(
        error.NotFile,
        mutator.writeWholeFileOnce(format.root_inode_id, "x", .{ .now_ns = 3 }),
    );
    try std.testing.expectEqual(original_staged, transaction.staged.items.len);
    try std.testing.expect(std.meta.eql(original_root, mutator.root));

    try mutator.writeWholeFileOnce(inode.inode_id, "first", .{ .now_ns = 3 });
    const written_root = mutator.root;
    const written_staged = transaction.staged.items.len;
    try std.testing.expectError(
        error.FileNotEmpty,
        mutator.writeWholeFileOnce(inode.inode_id, "second", .{ .now_ns = 4 }),
    );
    try std.testing.expectEqual(written_staged, transaction.staged.items.len);
    try std.testing.expect(std.meta.eql(written_root, mutator.root));

    var existing_transaction = try Transaction.begin(
        model.conditionalStore(),
        std.testing.allocator,
        txn_c,
    );
    defer existing_transaction.deinit();
    var existing = try filesystem.Mutator.init(&existing_transaction, empty);
    defer existing.deinit();
    const key = try format.encodeExtentKey(inode.inode_id, 0);
    const mapping = try format.encodeExtentMapping(.{
        .inode_id = inode.inode_id,
        .logical_offset = 0,
        .byte_length = 1,
        .data_ref = .{},
    });
    existing.root.extent_tree_root = try existing.trees.put(
        existing.root.extent_tree_root,
        &key,
        &mapping,
    );
    const existing_root = existing.root;
    const existing_staged = existing_transaction.staged.items.len;
    try std.testing.expectError(
        error.UnexpectedExtentMapping,
        existing.writeWholeFileOnce(inode.inode_id, "x", .{ .now_ns = 3 }),
    );
    try std.testing.expectEqual(existing_staged, existing_transaction.staged.items.len);
    try std.testing.expect(std.meta.eql(existing_root, existing.root));
}

test "competing whole-file writers preserve the winner and reject replay" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const formatted = try formatStore(&model);
    const empty = try createCommittedEmptyFile(&model, formatted, txn_a, "alpha");
    const inode = try inodeForName(empty, "alpha");

    var first = try Transaction.begin(model.conditionalStore(), std.testing.allocator, txn_b);
    defer first.deinit();
    var first_mutator = try filesystem.Mutator.init(&first, empty);
    defer first_mutator.deinit();
    try first_mutator.writeWholeFileOnce(inode.inode_id, "winner", .{ .now_ns = 3 });
    const first_root = try first_mutator.finish();

    var second = try Transaction.begin(model.conditionalStore(), std.testing.allocator, txn_c);
    defer second.deinit();
    var second_mutator = try filesystem.Mutator.init(&second, empty);
    defer second_mutator.deinit();
    try second_mutator.writeWholeFileOnce(inode.inode_id, "loser", .{ .now_ns = 4 });
    const second_root = try second_mutator.finish();

    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try first.commit(first_root));
    try std.testing.expectEqual(cawfs.transaction.Outcome.conflict, try second.commit(second_root));
    const winner = try filesystem.open(model.conditionalStore(), std.testing.allocator);
    var winner_data = try winner.readWholeFile(std.testing.allocator, inode.inode_id);
    defer winner_data.deinit();
    try std.testing.expectEqualStrings("winner", winner_data.bytes);

    var replay = try Transaction.begin(model.conditionalStore(), std.testing.allocator, txn_d);
    defer replay.deinit();
    var replay_mutator = try filesystem.Mutator.init(&replay, winner);
    defer replay_mutator.deinit();
    try std.testing.expectError(
        error.FileNotEmpty,
        replay_mutator.writeWholeFileOnce(inode.inode_id, "loser", .{ .now_ns = 5 }),
    );
}

test "indeterminate whole-file commit resolves stabilizes and preserves payload" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const formatted = try formatStore(&model);
    const empty = try createCommittedEmptyFile(&model, formatted, txn_a, "alpha");
    const inode = try inodeForName(empty, "alpha");

    var transaction = try Transaction.begin(model.conditionalStore(), std.testing.allocator, txn_b);
    defer transaction.deinit();
    var mutator = try filesystem.Mutator.init(&transaction, empty);
    defer mutator.deinit();
    try mutator.writeWholeFileOnce(inode.inode_id, "resolved payload", .{ .now_ns = 3 });
    const root = try mutator.finish();
    model.injectNextPublishFault(.indeterminate_after);
    try std.testing.expectEqual(cawfs.transaction.Outcome.indeterminate, try transaction.commit(root));
    try std.testing.expectEqual(cawfs.resolution.Resolution.committed, try transaction.resolve(.{}));
    try transaction.stabilize();

    model.crash();
    const reopened = try filesystem.open(model.conditionalStore(), std.testing.allocator);
    var data = try reopened.readWholeFile(std.testing.allocator, inode.inode_id);
    defer data.deinit();
    try std.testing.expectEqualStrings("resolved payload", data.bytes);
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
        .data_ref = .{},
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

test "whole-file reads reject malformed mapping layouts and lengths" {
    var model = ModelStore.init(std.testing.allocator, initialAnchor());
    defer model.deinit();
    const store = model.conditionalStore();
    const formatted = try formatStore(&model);

    const names = [_][]const u8{
        "short-key",
        "wrong-offset",
        "wrong-length",
        "second-mapping",
        "missing-mapping",
        "wrong-payload",
        "allocated-mismatch",
        "unexpected-mapping",
        "identity-mismatch",
        "missing-object",
    };
    var inode_ids: [names.len]format.InodeId = undefined;
    var create = try Transaction.begin(store, std.testing.allocator, txn_a);
    defer create.deinit();
    var create_mutator = try filesystem.Mutator.init(&create, formatted);
    defer create_mutator.deinit();
    for (names, 0..) |name, index| {
        inode_ids[index] = try create_mutator.createEmptyFile(
            format.root_inode_id,
            name,
            file_options,
        );
    }
    const create_root = try create_mutator.finish();
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try create.commit(create_root));
    const empty = try filesystem.open(store, std.testing.allocator);

    var corrupt = try Transaction.begin(store, std.testing.allocator, txn_b);
    defer corrupt.deinit();
    var trees = cawfs.tree.Mutator.init(&corrupt);
    defer trees.deinit();
    var root = empty.root;
    const data_ref = try corrupt.putImmutable("data");
    const short_key = try format.encodeInodeKey(inode_ids[0]);
    try stageMapping(&trees, &root, &short_key, .{
        .inode_id = inode_ids[0],
        .logical_offset = 0,
        .byte_length = 4,
        .data_ref = data_ref,
    });

    const offset_key = try format.encodeExtentKey(inode_ids[1], 1);
    try stageMapping(&trees, &root, &offset_key, .{
        .inode_id = inode_ids[1],
        .logical_offset = 1,
        .byte_length = 4,
        .data_ref = data_ref,
    });

    const length_key = try format.encodeExtentKey(inode_ids[2], 0);
    try stageMapping(&trees, &root, &length_key, .{
        .inode_id = inode_ids[2],
        .logical_offset = 0,
        .byte_length = 3,
        .data_ref = data_ref,
    });

    const first_key = try format.encodeExtentKey(inode_ids[3], 0);
    try stageMapping(&trees, &root, &first_key, .{
        .inode_id = inode_ids[3],
        .logical_offset = 0,
        .byte_length = 4,
        .data_ref = data_ref,
    });
    const second_key = try format.encodeExtentKey(inode_ids[3], 4);
    try stageMapping(&trees, &root, &second_key, .{
        .inode_id = inode_ids[3],
        .logical_offset = 4,
        .byte_length = 1,
        .data_ref = data_ref,
    });

    const short_payload_ref = try corrupt.putImmutable("bad");
    const payload_key = try format.encodeExtentKey(inode_ids[5], 0);
    try stageMapping(&trees, &root, &payload_key, .{
        .inode_id = inode_ids[5],
        .logical_offset = 0,
        .byte_length = 4,
        .data_ref = short_payload_ref,
    });

    const unexpected_key = try format.encodeExtentKey(inode_ids[7], 0);
    try stageMapping(&trees, &root, &unexpected_key, .{
        .inode_id = inode_ids[7],
        .logical_offset = 0,
        .byte_length = 4,
        .data_ref = data_ref,
    });

    const identity_key = try format.encodeExtentKey(inode_ids[8], 0);
    try stageMapping(&trees, &root, &identity_key, .{
        .inode_id = inode_ids[8],
        .logical_offset = 1,
        .byte_length = 4,
        .data_ref = data_ref,
    });

    const missing_object_key = try format.encodeExtentKey(inode_ids[9], 0);
    try stageMapping(&trees, &root, &missing_object_key, .{
        .inode_id = inode_ids[9],
        .logical_offset = 0,
        .byte_length = 4,
        .data_ref = .{},
    });

    for (inode_ids[0..6]) |inode_id| {
        var inode = (try empty.getInode(std.testing.allocator, inode_id)).?;
        inode.logical_size = 4;
        inode.allocated_bytes = 4;
        try stageInode(&trees, &root, inode);
    }
    var allocated_mismatch = (try empty.getInode(std.testing.allocator, inode_ids[6])).?;
    allocated_mismatch.logical_size = 4;
    allocated_mismatch.allocated_bytes = 3;
    try stageInode(&trees, &root, allocated_mismatch);
    for (inode_ids[8..10]) |inode_id| {
        var inode = (try empty.getInode(std.testing.allocator, inode_id)).?;
        inode.logical_size = 4;
        inode.allocated_bytes = 4;
        try stageInode(&trees, &root, inode);
    }

    const encoded_root = try format.encodeFilesystemRoot(root);
    const root_ref = try corrupt.putImmutable(&encoded_root);
    try std.testing.expectEqual(cawfs.transaction.Outcome.committed, try corrupt.commit(root_ref));
    const malformed = try filesystem.open(store, std.testing.allocator);

    try std.testing.expectError(
        error.InvalidSize,
        malformed.readWholeFile(std.testing.allocator, inode_ids[0]),
    );
    try std.testing.expectError(
        error.UnsupportedExtentLayout,
        malformed.readWholeFile(std.testing.allocator, inode_ids[1]),
    );
    try std.testing.expectError(
        error.MappingLengthMismatch,
        malformed.readWholeFile(std.testing.allocator, inode_ids[2]),
    );
    try std.testing.expectError(
        error.UnsupportedExtentLayout,
        malformed.readWholeFile(std.testing.allocator, inode_ids[3]),
    );
    try std.testing.expectError(
        error.MissingExtentMapping,
        malformed.readWholeFile(std.testing.allocator, inode_ids[4]),
    );
    try std.testing.expectError(
        error.DataLengthMismatch,
        malformed.readWholeFile(std.testing.allocator, inode_ids[5]),
    );
    try std.testing.expectError(
        error.AllocatedSizeMismatch,
        malformed.readWholeFile(std.testing.allocator, inode_ids[6]),
    );
    try std.testing.expectError(
        error.UnexpectedExtentMapping,
        malformed.readWholeFile(std.testing.allocator, inode_ids[7]),
    );
    try std.testing.expectError(
        error.KeyValueMismatch,
        malformed.readWholeFile(std.testing.allocator, inode_ids[8]),
    );
    try std.testing.expectError(
        error.ObjectNotFound,
        malformed.readWholeFile(std.testing.allocator, inode_ids[9]),
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
