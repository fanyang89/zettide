const std = @import("std");
const txfs = @import("zettide_txfs");

const txn_a: [16]u8 = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const txn_b: [16]u8 = .{ 0xb2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
const txn_c: [16]u8 = .{ 0xc3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 };
const txn_d: [16]u8 = .{ 0xd4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4 };

const filesystem_format_options = txfs.filesystem.FormatOptions{
    .mode = 0o40755,
    .uid = 1000,
    .gid = 1001,
    .now_ns = 1,
};

const filesystem_file_options = txfs.filesystem.CreateFileOptions{
    .mode = 0o100640,
    .uid = 2000,
    .gid = 2001,
    .now_ns = 2,
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    model: *txfs.model_block_device.ModelBlockDevice,
    header: txfs.volume_format.Header,
    extent_allocator: txfs.extent_allocator.ExtentAllocator,
    backend: *txfs.scsi_store.ScsiStore,

    fn init(allocator: std.mem.Allocator, block_size: u32) !Fixture {
        const geometry = txfs.conditional_block.Geometry{
            .logical_block_size = block_size,
            .block_count = 1024,
        };
        const model = try allocator.create(txfs.model_block_device.ModelBlockDevice);
        errdefer allocator.destroy(model);
        model.* = try txfs.model_block_device.ModelBlockDevice.init(allocator, geometry);
        errdefer model.deinit();
        const header = try txfs.volume_format.Header.init(
            patternedId(0x40),
            123,
            geometry,
            8192,
        );
        const extents = try txfs.extent_allocator.ExtentAllocator.init(
            allocator,
            model.conditionalTransport(),
            header,
            .{},
        );
        _ = try extents.format();
        const backend = try allocator.create(txfs.scsi_store.ScsiStore);
        errdefer allocator.destroy(backend);
        backend.* = try txfs.scsi_store.ScsiStore.init(
            extents,
            model.dataTransport(),
            model.conditionalTransport(),
            header,
            .{
                .owner_id = patternedId(0x10),
                .owner_incarnation = patternedId(0x20),
                .owner_epoch = 1,
            },
        );
        const initial = initialAnchor();
        try std.testing.expectEqual(
            txfs.scsi_store.AnchorFormatResult.formatted,
            try backend.formatAnchor(&initial),
        );
        return .{
            .allocator = allocator,
            .model = model,
            .header = header,
            .extent_allocator = extents,
            .backend = backend,
        };
    }

    fn deinit(self: *Fixture) void {
        self.allocator.destroy(self.backend);
        self.model.deinit();
        self.allocator.destroy(self.model);
        self.* = undefined;
    }

    fn reopened(self: *Fixture) !txfs.scsi_store.ScsiStore {
        const extents = try txfs.extent_allocator.ExtentAllocator.init(
            self.allocator,
            self.model.conditionalTransport(),
            self.header,
            .{},
        );
        return txfs.scsi_store.ScsiStore.init(
            extents,
            self.model.dataTransport(),
            self.model.conditionalTransport(),
            self.header,
            .{
                .owner_id = patternedId(0x10),
                .owner_incarnation = patternedId(0x20),
                .owner_epoch = 1,
            },
        );
    }
};

fn patternedId(seed: u8) [16]u8 {
    var result: [16]u8 = undefined;
    for (&result, seed..) |*byte, value| byte.* = @intCast(value);
    return result;
}

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

fn nextAnchor(
    transaction_id: txfs.store.TransactionId,
    head: txfs.store.ObjectRef,
) txfs.store.Anchor {
    return txfs.anchor.encode(.{
        .revision = 1,
        .generation = 1,
        .transaction_id = transaction_id,
        .head = head,
        .mode = .active,
        .mode_epoch = 1,
    });
}

fn beginCurrentBatch(
    store: txfs.store.ConditionalStore,
    allocator: std.mem.Allocator,
    transaction_id: txfs.store.TransactionId,
) !txfs.store.WriteBatch {
    var snapshot = try store.readAnchor(allocator);
    defer snapshot.deinit();
    return store.beginBatch(allocator, transaction_id, snapshot.version.bytes);
}

fn formatFilesystem(store: txfs.store.ConditionalStore) !txfs.filesystem.Snapshot {
    var transaction = try txfs.transaction.Transaction.begin(store, std.testing.allocator, txn_a);
    defer transaction.deinit();
    const root = try txfs.filesystem.format(&transaction, filesystem_format_options);
    try std.testing.expectEqual(txfs.transaction.Outcome.committed, try transaction.commit(root));
    return txfs.filesystem.open(store, std.testing.allocator);
}

fn createFilesystemFile(
    store: txfs.store.ConditionalStore,
    snapshot: txfs.filesystem.Snapshot,
) !struct { snapshot: txfs.filesystem.Snapshot, inode_id: txfs.filesystem_format.InodeId } {
    var transaction = try txfs.transaction.Transaction.begin(store, std.testing.allocator, txn_b);
    defer transaction.deinit();
    var mutator = try txfs.filesystem.Mutator.init(&transaction, snapshot);
    defer mutator.deinit();
    const inode_id = try mutator.createEmptyFile(
        txfs.filesystem_format.root_inode_id,
        "alpha",
        filesystem_file_options,
    );
    const root = try mutator.finish();
    try std.testing.expectEqual(txfs.transaction.Outcome.committed, try transaction.commit(root));
    return .{
        .snapshot = try txfs.filesystem.open(store, std.testing.allocator),
        .inode_id = inode_id,
    };
}

test "SCSI extent store prepares and loads objects at 512 and 4096" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        var fixture = try Fixture.init(std.testing.allocator, block_size);
        defer fixture.deinit();
        const store = fixture.backend.conditionalStore();
        var batch = try beginCurrentBatch(store, std.testing.allocator, txn_a);
        defer batch.deinit();
        const reference = try batch.putImmutable("prepared object");
        try std.testing.expectError(
            error.ObjectNotFound,
            store.loadImmutable(reference, std.testing.allocator),
        );
        try batch.prepare();
        var loaded = try store.loadImmutable(reference, std.testing.allocator);
        defer loaded.deinit();
        try std.testing.expectEqualStrings("prepared object", loaded.bytes);

        fixture.model.crash();
        var durable = try store.loadImmutable(reference, std.testing.allocator);
        defer durable.deinit();
        try std.testing.expectEqualStrings("prepared object", durable.bytes);
    }
}

test "filesystem whole-file data reopens through SCSI at 512 and 4096" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        var fixture = try Fixture.init(std.testing.allocator, block_size);
        defer fixture.deinit();
        const store = fixture.backend.conditionalStore();
        const formatted = try formatFilesystem(store);
        const empty = try createFilesystemFile(store, formatted);

        var transaction = try txfs.transaction.Transaction.begin(
            store,
            std.testing.allocator,
            txn_c,
        );
        defer transaction.deinit();
        var mutator = try txfs.filesystem.Mutator.init(&transaction, empty.snapshot);
        defer mutator.deinit();
        const payload = "whole-file payload across SCSI";
        try mutator.writeWholeFileOnce(empty.inode_id, payload, .{ .now_ns = 3 });
        const root = try mutator.finish();
        try std.testing.expectEqual(
            txfs.transaction.Outcome.committed,
            try transaction.commit(root),
        );

        fixture.model.crash();
        var reopened = try fixture.reopened();
        const reopened_store = reopened.conditionalStore();
        const snapshot = try txfs.filesystem.open(reopened_store, std.testing.allocator);
        var data = try snapshot.readWholeFile(std.testing.allocator, empty.inode_id);
        defer data.deinit();
        try std.testing.expectEqualStrings(payload, data.bytes);

        const key = try txfs.filesystem_format.encodeExtentKey(empty.inode_id, 0);
        var encoded_mapping = (try txfs.tree.get(
            reopened_store,
            std.testing.allocator,
            snapshot.root.extent_tree_root,
            &key,
        )).?;
        defer encoded_mapping.deinit();
        const mapping = try txfs.filesystem_format.decodeExtentMapping(encoded_mapping.bytes);
        try txfs.filesystem_format.validateExtentKeyValue(&key, mapping);
        const identity = try txfs.immutable_extent.decodeObjectRef(mapping.data_ref);
        const entry = try fixture.extent_allocator.readEntry(identity.extent_index);
        try std.testing.expectEqual(txfs.allocation_format.State.live, entry.state);
        try std.testing.expectEqual(txfs.allocation_format.Kind.immutable, entry.kind);
        try std.testing.expectEqual(identity.claim_epoch, entry.claim_epoch);
        try std.testing.expectEqual(identity.claim_id, entry.claim_id);

        var wrong_identity = mapping.data_ref;
        wrong_identity.bytes[16] ^= 1;
        try std.testing.expectError(
            error.ObjectNotFound,
            reopened_store.loadImmutable(wrong_identity, std.testing.allocator),
        );
    }
}

test "indeterminate filesystem data write leaves old metadata and retains claim" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    const formatted = try formatFilesystem(store);
    const empty = try createFilesystemFile(store, formatted);
    var anchor_before = try store.readAnchor(std.testing.allocator);
    defer anchor_before.deinit();
    const generation_before = (try txfs.anchor.decode(&anchor_before.anchor)).generation;

    var poisoned_identity: txfs.immutable_extent.Identity = undefined;
    {
        var transaction = try txfs.transaction.Transaction.begin(
            store,
            std.testing.allocator,
            txn_c,
        );
        defer transaction.deinit();
        var mutator = try txfs.filesystem.Mutator.init(&transaction, empty.snapshot);
        defer mutator.deinit();
        try mutator.writeWholeFileOnce(empty.inode_id, "uncertain payload", .{ .now_ns = 3 });
        poisoned_identity = try txfs.immutable_extent.decodeObjectRef(transaction.staged.items[0]);
        const root = try mutator.finish();
        fixture.model.injectNextDataFault(.indeterminate_after_write);
        try std.testing.expectError(error.DataWriteIndeterminate, transaction.commit(root));
    }

    const poisoned_entry = try fixture.extent_allocator.readEntry(poisoned_identity.extent_index);
    try std.testing.expectEqual(txfs.allocation_format.State.claimed, poisoned_entry.state);
    var anchor_after = try store.readAnchor(std.testing.allocator);
    defer anchor_after.deinit();
    try std.testing.expectEqual(
        generation_before,
        (try txfs.anchor.decode(&anchor_after.anchor)).generation,
    );
    var authoritative = try empty.snapshot.readWholeFile(std.testing.allocator, empty.inode_id);
    defer authoritative.deinit();
    try std.testing.expectEqual(@as(usize, 0), authoritative.bytes.len);

    {
        var retry = try txfs.transaction.Transaction.begin(store, std.testing.allocator, txn_d);
        defer retry.deinit();
        var retry_mutator = try txfs.filesystem.Mutator.init(&retry, empty.snapshot);
        defer retry_mutator.deinit();
        try retry_mutator.writeWholeFileOnce(empty.inode_id, "replacement", .{ .now_ns = 4 });
        const replacement = try txfs.immutable_extent.decodeObjectRef(retry.staged.items[0]);
        try std.testing.expect(replacement.extent_index != poisoned_identity.extent_index);
    }
    try std.testing.expectEqual(
        txfs.allocation_format.State.claimed,
        (try fixture.extent_allocator.readEntry(poisoned_identity.extent_index)).state,
    );

    fixture.model.crash();
    var reopened = try fixture.reopened();
    const recovered = try txfs.filesystem.open(reopened.conditionalStore(), std.testing.allocator);
    var recovered_data = try recovered.readWholeFile(std.testing.allocator, empty.inode_id);
    defer recovered_data.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovered_data.bytes.len);
}

test "indeterminate ordinary write poisons the batch and retains its claim" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var batch = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer batch.deinit();
    const reference = try batch.putImmutable("uncertain object");
    fixture.model.injectNextDataFault(.indeterminate_after_write);
    try std.testing.expectError(error.DataWriteIndeterminate, batch.prepare());
    try std.testing.expectError(error.InvalidState, batch.prepare());

    const identity = try txfs.immutable_extent.decodeObjectRef(reference);
    const entry = try fixture.extent_allocator.readEntry(identity.extent_index);
    try std.testing.expectEqual(txfs.allocation_format.State.claimed, entry.state);
    try std.testing.expectError(
        error.ObjectNotFound,
        store.loadImmutable(reference, std.testing.allocator),
    );
}

test "prepare retries only its failed durability barrier" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var batch = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer batch.deinit();
    const reference = try batch.putImmutable("barrier retry");
    fixture.model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, batch.prepare());
    try batch.prepare();
    var loaded = try store.loadImmutable(reference, std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("barrier retry", loaded.bytes);
}

test "concurrent anchor publishers have one winner and one CAW each" {
    const Worker = struct {
        batch: *txfs.store.WriteBatch,
        version: []const u8,
        anchor: txfs.store.Anchor,
        result: ?txfs.store.PublishResult = null,

        fn run(self: *@This()) void {
            self.result = self.batch.publish(self.version, &self.anchor) catch |err|
                std.debug.panic("publish failed: {s}", .{@errorName(err)});
        }
    };

    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    var first = try store.beginBatch(std.heap.page_allocator, txn_a, snapshot.version.bytes);
    defer first.deinit();
    const first_head = try first.putImmutable("first");
    try first.prepare();
    var second = try store.beginBatch(std.heap.page_allocator, txn_b, snapshot.version.bytes);
    defer second.deinit();
    const second_head = try second.putImmutable("second");
    try second.prepare();
    var first_worker = Worker{
        .batch = &first,
        .version = snapshot.version.bytes,
        .anchor = nextAnchor(txn_a, first_head),
    };
    var second_worker = Worker{
        .batch = &second,
        .version = snapshot.version.bytes,
        .anchor = nextAnchor(txn_b, second_head),
    };
    const before = fixture.model.cawCount();
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first_worker});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second_worker});
    first_thread.join();
    second_thread.join();

    const committed = @intFromBool(first_worker.result == .committed) +
        @intFromBool(second_worker.result == .committed);
    const conflicted = @intFromBool(first_worker.result == .conflict) +
        @intFromBool(second_worker.result == .conflict);
    try std.testing.expectEqual(@as(u2, 1), committed);
    try std.testing.expectEqual(@as(u2, 1), conflicted);
    try std.testing.expectEqual(before + 2, fixture.model.cawCount());
}

test "anchor indeterminate outcomes are not retried inside publish" {
    for ([_]txfs.model_block_device.CawFault{
        .indeterminate_no_write,
        .indeterminate_after_write,
    }) |fault| {
        var fixture = try Fixture.init(std.testing.allocator, 4096);
        defer fixture.deinit();
        const store = fixture.backend.conditionalStore();
        var snapshot = try store.readAnchor(std.testing.allocator);
        defer snapshot.deinit();
        var batch = try store.beginBatch(std.testing.allocator, txn_a, snapshot.version.bytes);
        defer batch.deinit();
        const head = try batch.putImmutable("anchor candidate");
        try batch.prepare();
        fixture.model.injectNextCawFault(fault);
        const before = fixture.model.cawCount();
        const next = nextAnchor(txn_a, head);
        try std.testing.expectEqual(
            txfs.store.PublishResult.indeterminate,
            try batch.publish(snapshot.version.bytes, &next),
        );
        try std.testing.expectEqual(before + 1, fixture.model.cawCount());

        var observed = try store.readAnchor(std.testing.allocator);
        defer observed.deinit();
        const state = try txfs.anchor.decode(&observed.anchor);
        try std.testing.expectEqual(
            @as(u64, if (fault == .indeterminate_after_write) 1 else 0),
            state.generation,
        );
    }
}

test "non-applied indeterminate publication cannot stabilize" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, snapshot.version.bytes);
    defer batch.deinit();
    const head = try batch.putImmutable("not published");
    try batch.prepare();
    const next = nextAnchor(txn_a, head);
    fixture.model.injectNextCawFault(.indeterminate_no_write);
    try std.testing.expectEqual(
        txfs.store.PublishResult.indeterminate,
        try batch.publish(snapshot.version.bytes, &next),
    );
    try std.testing.expectError(error.PublicationRequiresResolution, batch.stabilize());
}

test "publish rejects noncanonical anchor state before CAW" {
    var fixture = try Fixture.init(std.testing.allocator, 4096);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, snapshot.version.bytes);
    defer batch.deinit();
    const head = try batch.putImmutable("validated anchor");
    try batch.prepare();
    const before = fixture.model.cawCount();

    snapshot.version.bytes[txfs.store.anchor_size] = 1;
    const canonical = nextAnchor(txn_a, head);
    try std.testing.expectError(
        error.BatchBaseVersionMismatch,
        batch.publish(snapshot.version.bytes, &canonical),
    );
    snapshot.version.bytes[txfs.store.anchor_size] = 0;
    const wrong_generation = txfs.anchor.encode(.{
        .revision = 2,
        .generation = 2,
        .transaction_id = txn_a,
        .head = head,
        .mode = .active,
        .mode_epoch = 1,
    });
    try std.testing.expectError(
        error.InvalidAnchorGeneration,
        batch.publish(snapshot.version.bytes, &wrong_generation),
    );
    const wrong_transaction = nextAnchor(txn_b, head);
    try std.testing.expectError(
        error.InvalidAnchorTransaction,
        batch.publish(snapshot.version.bytes, &wrong_transaction),
    );
    const wrong_revision = txfs.anchor.encode(.{
        .revision = 2,
        .generation = 1,
        .transaction_id = txn_a,
        .head = head,
        .mode = .active,
        .mode_epoch = 1,
    });
    try std.testing.expectError(
        error.InvalidAnchorRevision,
        batch.publish(snapshot.version.bytes, &wrong_revision),
    );
    const wrong_mode = txfs.anchor.encode(.{
        .revision = 2,
        .generation = 1,
        .transaction_id = txn_a,
        .head = head,
        .mode = .quiescing,
        .mode_epoch = 2,
        .control_operation_id = txn_a,
        .control_ref = head,
    });
    try std.testing.expectError(
        error.InvalidAnchorMode,
        batch.publish(snapshot.version.bytes, &wrong_mode),
    );
    try std.testing.expectEqual(before, fixture.model.cawCount());
}

test "data barrier failure followed by reset cannot activate lost data" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var batch = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer batch.deinit();
    const reference = try batch.putImmutable("lost before reset");
    fixture.model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, batch.prepare());

    fixture.model.crash();
    try std.testing.expectError(error.DeviceReset, batch.prepare());
    const identity = try txfs.immutable_extent.decodeObjectRef(reference);
    const entry = try fixture.extent_allocator.readEntry(identity.extent_index);
    try std.testing.expectEqual(txfs.allocation_format.State.claimed, entry.state);
    try std.testing.expectError(
        error.ObjectNotFound,
        store.loadImmutable(reference, std.testing.allocator),
    );
}

test "publication reset requires commit resolution instead of false stabilization" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, snapshot.version.bytes);
    defer batch.deinit();
    const head = try batch.putImmutable("rolled back publication");
    try batch.prepare();
    const next = nextAnchor(txn_a, head);
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch.publish(snapshot.version.bytes, &next),
    );
    fixture.model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, batch.stabilize());

    fixture.model.crash();
    try std.testing.expect(batch.publicationTerminated());
    try std.testing.expectError(error.DeviceReset, batch.stabilize());
    var recovered = try store.readAnchor(std.testing.allocator);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u64, 0), (try txfs.anchor.decode(&recovered.anchor)).generation);
}

test "publication reset racing its barrier cannot stabilize" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, snapshot.version.bytes);
    defer batch.deinit();
    const head = try batch.putImmutable("reset publication");
    try batch.prepare();
    const next = nextAnchor(txn_a, head);
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch.publish(snapshot.version.bytes, &next),
    );

    fixture.model.injectResetBeforeNextStabilize();
    try std.testing.expectError(error.DeviceReset, batch.stabilize());
    var recovered = try store.readAnchor(std.testing.allocator);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u64, 0), (try txfs.anchor.decode(&recovered.anchor)).generation);
}

test "publish can retry a known pre-dispatch transport error" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, snapshot.version.bytes);
    defer batch.deinit();
    const head = try batch.putImmutable("retry publication");
    try batch.prepare();
    const next = nextAnchor(txn_a, head);
    fixture.model.injectNextCawFault(.error_before_dispatch);
    try std.testing.expectError(
        error.InjectedCawFailure,
        batch.publish(snapshot.version.bytes, &next),
    );
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch.publish(snapshot.version.bytes, &next),
    );
    try batch.stabilize();
}

test "claim identity separates payloads from a reused transaction id" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var first = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer first.deinit();
    var second = try beginCurrentBatch(store, std.testing.allocator, txn_a);
    defer second.deinit();
    const first_ref = try first.putImmutable("first payload");
    const second_ref = try second.putImmutable("second payload");
    try first.prepare();
    try second.prepare();
    const first_identity = try txfs.immutable_extent.decodeObjectRef(first_ref);
    const second_identity = try txfs.immutable_extent.decodeObjectRef(second_ref);
    try std.testing.expect(first_identity.extent_index != second_identity.extent_index);
    var first_bytes = try store.loadImmutable(first_ref, std.testing.allocator);
    defer first_bytes.deinit();
    var second_bytes = try store.loadImmutable(second_ref, std.testing.allocator);
    defer second_bytes.deinit();
    try std.testing.expectEqualStrings("first payload", first_bytes.bytes);
    try std.testing.expectEqualStrings("second payload", second_bytes.bytes);
}

test "second generation objects retain allocator publication generations" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    {
        var first = try txfs.transaction.Transaction.begin(store, std.testing.allocator, txn_a);
        defer first.deinit();
        const root = try first.putImmutable("first root");
        _ = try first.commit(root);
    }
    var second = try txfs.transaction.Transaction.begin(store, std.testing.allocator, txn_b);
    defer second.deinit();
    const root = try second.putImmutable("second root");
    _ = try second.commit(root);
    const identity = try txfs.immutable_extent.decodeObjectRef(root);
    const entry = try fixture.extent_allocator.readEntry(identity.extent_index);
    try std.testing.expectEqual(@as(u64, 1), entry.base_generation);
    try std.testing.expectEqual(@as(u64, 2), entry.transition_generation);
}

test "physical anchors are bound to one volume" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    var other_header = fixture.header;
    other_header.volume_id = patternedId(0x90);
    const other_allocator = try txfs.extent_allocator.ExtentAllocator.init(
        std.testing.allocator,
        fixture.model.conditionalTransport(),
        other_header,
        .{},
    );
    var other = try txfs.scsi_store.ScsiStore.init(
        other_allocator,
        fixture.model.dataTransport(),
        fixture.model.conditionalTransport(),
        other_header,
        .{
            .owner_id = patternedId(0x10),
            .owner_incarnation = patternedId(0x20),
            .owner_epoch = 1,
        },
    );
    try std.testing.expectError(
        error.AnchorVolumeMismatch,
        other.conditionalStore().readAnchor(std.testing.allocator),
    );
}

test "anchor formatting verifies replacement after reset races its barrier" {
    const geometry = txfs.conditional_block.Geometry{
        .logical_block_size = 512,
        .block_count = 1024,
    };
    var model = try txfs.model_block_device.ModelBlockDevice.init(
        std.testing.allocator,
        geometry,
    );
    defer model.deinit();
    const header = try txfs.volume_format.Header.init(
        patternedId(0x40),
        123,
        geometry,
        8192,
    );
    const extents = try txfs.extent_allocator.ExtentAllocator.init(
        std.testing.allocator,
        model.conditionalTransport(),
        header,
        .{},
    );
    _ = try extents.format();
    var backend = try txfs.scsi_store.ScsiStore.init(
        extents,
        model.dataTransport(),
        model.conditionalTransport(),
        header,
        .{
            .owner_id = patternedId(0x10),
            .owner_incarnation = patternedId(0x20),
            .owner_epoch = 1,
        },
    );
    const initial = initialAnchor();
    model.injectResetBeforeNextStabilize();
    try std.testing.expectEqual(
        txfs.scsi_store.AnchorFormatResult.indeterminate,
        try backend.formatAnchor(&initial),
    );
    try std.testing.expectEqual(
        txfs.scsi_store.AnchorFormatResult.formatted,
        try backend.formatAnchor(&initial),
    );
}

test "publication durability barrier can be retried without another CAW" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    var batch = try store.beginBatch(std.testing.allocator, txn_a, snapshot.version.bytes);
    defer batch.deinit();
    const head = try batch.putImmutable("published");
    try batch.prepare();
    const next = nextAnchor(txn_a, head);
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch.publish(snapshot.version.bytes, &next),
    );
    const after_publish = fixture.model.cawCount();
    fixture.model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, batch.stabilize());
    try batch.stabilize();
    try std.testing.expectEqual(after_publish, fixture.model.cawCount());
    fixture.model.crash();
    var reopened = try fixture.reopened();
    var recovered = try reopened.conditionalStore().readAnchor(std.testing.allocator);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u64, 1), (try txfs.anchor.decode(&recovered.anchor)).generation);
}

test "an earlier publication stabilizes through a durable descendant" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();

    var snapshot_a = try store.readAnchor(std.testing.allocator);
    defer snapshot_a.deinit();
    var batch_a = try store.beginBatch(std.testing.allocator, txn_a, snapshot_a.version.bytes);
    defer batch_a.deinit();
    const root_a = try batch_a.putImmutable("root A");
    const record_a = txfs.commit.encode(.{
        .generation = 1,
        .transaction_id = txn_a,
        .parent = null,
        .root = root_a,
    });
    const commit_a = try batch_a.putImmutable(&record_a);
    try batch_a.prepare();
    const anchor_a = nextAnchor(txn_a, commit_a);
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch_a.publish(snapshot_a.version.bytes, &anchor_a),
    );
    fixture.model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, batch_a.stabilize());

    var snapshot_b = try store.readAnchor(std.testing.allocator);
    defer snapshot_b.deinit();
    var batch_b = try store.beginBatch(std.testing.allocator, txn_b, snapshot_b.version.bytes);
    defer batch_b.deinit();
    const root_b = try batch_b.putImmutable("root B");
    const record_b = txfs.commit.encode(.{
        .generation = 2,
        .transaction_id = txn_b,
        .parent = commit_a,
        .root = root_b,
    });
    const commit_b = try batch_b.putImmutable(&record_b);
    try batch_b.prepare();
    const anchor_b = txfs.anchor.encode(.{
        .revision = 2,
        .generation = 2,
        .transaction_id = txn_b,
        .head = commit_b,
        .mode = .active,
        .mode_epoch = 1,
    });
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch_b.publish(snapshot_b.version.bytes, &anchor_b),
    );
    try batch_b.stabilize();
    try batch_a.stabilize();

    fixture.model.crash();
    var reopened = try fixture.reopened();
    var recovered = try reopened.conditionalStore().readAnchor(std.testing.allocator);
    defer recovered.deinit();
    const recovered_state = try txfs.anchor.decode(&recovered.anchor);
    try std.testing.expectEqual(@as(u64, 2), recovered_state.generation);
    try std.testing.expectEqual(txn_b, recovered_state.transaction_id);
    try std.testing.expect(txfs.store.ObjectRef.eql(commit_b, recovered_state.head.?));
}

test "stabilization rejects malformed descendant ancestry" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();

    var snapshot_a = try store.readAnchor(std.testing.allocator);
    defer snapshot_a.deinit();
    var batch_a = try store.beginBatch(std.testing.allocator, txn_a, snapshot_a.version.bytes);
    defer batch_a.deinit();
    const root_a = try batch_a.putImmutable("root A");
    const record_a = txfs.commit.encode(.{
        .generation = 1,
        .transaction_id = txn_a,
        .parent = null,
        .root = root_a,
    });
    const commit_a = try batch_a.putImmutable(&record_a);
    try batch_a.prepare();
    const anchor_a = nextAnchor(txn_a, commit_a);
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch_a.publish(snapshot_a.version.bytes, &anchor_a),
    );

    var snapshot_b = try store.readAnchor(std.testing.allocator);
    defer snapshot_b.deinit();
    var batch_b = try store.beginBatch(std.testing.allocator, txn_b, snapshot_b.version.bytes);
    defer batch_b.deinit();
    const root_b = try batch_b.putImmutable("root B");
    const malformed_record_b = txfs.commit.encode(.{
        .generation = 3,
        .transaction_id = txn_b,
        .parent = commit_a,
        .root = root_b,
    });
    const commit_b = try batch_b.putImmutable(&malformed_record_b);
    try batch_b.prepare();
    const anchor_b = txfs.anchor.encode(.{
        .revision = 2,
        .generation = 2,
        .transaction_id = txn_b,
        .head = commit_b,
        .mode = .active,
        .mode_epoch = 1,
    });
    try std.testing.expectEqual(
        txfs.store.PublishResult.committed,
        try batch_b.publish(snapshot_b.version.bytes, &anchor_b),
    );
    try batch_b.stabilize();

    try std.testing.expectError(error.CommitGenerationMismatch, batch_a.stabilize());
}

test "transaction and tree reopen through the SCSI extent store" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    {
        var transaction = try txfs.transaction.Transaction.begin(
            store,
            std.testing.allocator,
            txn_a,
        );
        defer transaction.deinit();
        var mutator = txfs.tree.Mutator.init(&transaction);
        defer mutator.deinit();
        var root = try mutator.createEmpty();
        root = try mutator.put(root, "alpha", "one");
        root = try mutator.put(root, "beta", "two");
        try std.testing.expectEqual(
            txfs.transaction.Outcome.committed,
            try transaction.commit(root),
        );
    }

    fixture.model.crash();
    var reopened = try fixture.reopened();
    const reopened_store = reopened.conditionalStore();
    var snapshot = try reopened_store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    const state = try txfs.anchor.decode(&snapshot.anchor);
    var commit_bytes = try reopened_store.loadImmutable(state.head.?, std.testing.allocator);
    defer commit_bytes.deinit();
    const record = try txfs.commit.decode(commit_bytes.bytes);
    var value = (try txfs.tree.get(
        reopened_store,
        std.testing.allocator,
        record.root,
        "beta",
    )).?;
    defer value.deinit();
    try std.testing.expectEqualStrings("two", value.bytes);
}

test "maintenance transitions persist through the SCSI extent store" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();

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

    fixture.model.crash();
    var reopened = try fixture.reopened();
    const reopened_store = reopened.conditionalStore();
    var snapshot = try reopened_store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    const state = try txfs.anchor.decode(&snapshot.anchor);
    try std.testing.expectEqual(@as(u64, 3), state.revision);
    try std.testing.expectEqual(@as(u64, 0), state.generation);
    try std.testing.expectEqual(txfs.anchor.Mode.active, state.mode);
    try std.testing.expectEqual(@as(u64, 2), state.mode_epoch);
    var control = try reopened_store.loadImmutable(state.control_ref.?, std.testing.allocator);
    defer control.deinit();
    const record = try txfs.maintenance.decode(control.bytes);
    try std.testing.expectEqual(txfs.anchor.Mode.maintenance, record.previous_mode);
    try std.testing.expectEqual(txfs.anchor.Mode.active, record.mode);
}

test "SCSI maintenance stabilization resolves a durable descendant after reset" {
    var fixture = try Fixture.init(std.testing.allocator, 512);
    defer fixture.deinit();
    const store = fixture.backend.conditionalStore();
    var snapshot = try store.readAnchor(std.testing.allocator);
    defer snapshot.deinit();
    var quiescing = try store.beginControlBatch(
        std.testing.allocator,
        txn_a,
        snapshot.version.bytes,
    );
    defer quiescing.deinit();
    const encoded = txfs.maintenance.encode(.{
        .revision = 1,
        .generation = 0,
        .mode_epoch = 2,
        .operation_id = txn_a,
        .previous_mode = .active,
        .mode = .quiescing,
        .parent = null,
    });
    const control_ref = try quiescing.putImmutable(&encoded);
    try quiescing.prepare();
    fixture.model.injectNextCawFault(.indeterminate_after_write);
    try std.testing.expectEqual(
        txfs.store.PublishResult.indeterminate,
        try quiescing.publish(snapshot.version.bytes, &txfs.anchor.encode(.{
            .revision = 1,
            .generation = 0,
            .transaction_id = @splat(0),
            .head = null,
            .mode = .quiescing,
            .mode_epoch = 2,
            .control_operation_id = txn_a,
            .control_ref = control_ref,
        })),
    );

    var maintenance = try txfs.maintenance.Transition.begin(
        store,
        std.testing.allocator,
        txn_a,
        .maintenance,
    );
    defer maintenance.deinit();
    try std.testing.expectEqual(
        txfs.maintenance.Outcome.committed,
        try maintenance.commit(),
    );
    fixture.model.crash();

    try quiescing.stabilize();
}
