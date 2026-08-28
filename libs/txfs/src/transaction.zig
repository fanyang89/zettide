//! Transaction coordinator for immutable state publication.

const std = @import("std");
const anchor = @import("anchor.zig");
const commit_mod = @import("commit.zig");
const maintenance = @import("maintenance.zig");
const resolution = @import("resolution.zig");
const store_mod = @import("store.zig");

pub const Status = enum {
    staging,
    failed,
    conflict,
    indeterminate,
    not_committed,
    published,
    committed,
};

pub const Outcome = enum {
    committed,
    conflict,
    indeterminate,
};

pub const Error = error{
    InvalidAnchorState,
    InvalidState,
    GenerationOverflow,
    RevisionOverflow,
    VolumeNotActive,
};

/// A Transaction has one caller and follows Zig's move-only convention. It
/// must be deinitialized before its ConditionalStore backend is destroyed.
pub const Transaction = struct {
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    transaction_id: store_mod.TransactionId,
    base_revision: u64,
    base_generation: u64,
    base_mode_epoch: u64,
    base_head: ?store_mod.ObjectRef,
    base_control_ref: ?store_mod.ObjectRef,
    version: store_mod.OwnedBytes,
    batch: store_mod.WriteBatch,
    staged: std.ArrayList(store_mod.ObjectRef) = .empty,
    current_status: Status = .staging,
    prepared_commit: ?store_mod.ObjectRef = null,

    pub fn begin(
        store: store_mod.ConditionalStore,
        allocator: std.mem.Allocator,
        transaction_id: store_mod.TransactionId,
    ) !Transaction {
        var snapshot = try store.readAnchor(allocator);
        errdefer snapshot.deinit();
        const base = try anchor.decode(&snapshot.anchor);
        if (base.mode != .active) return error.VolumeNotActive;
        try maintenance.validateAnchorState(store, allocator, base);
        if (base.head) |head| {
            var bytes = try store.loadImmutable(head, allocator);
            defer bytes.deinit();
            const record = try commit_mod.decode(bytes.bytes);
            if (record.generation != base.generation or
                !std.mem.eql(u8, &record.transaction_id, &base.transaction_id) or
                ((record.generation == 1) != (record.parent == null)))
                return error.InvalidAnchorState;
        }
        const batch = try store.beginBatch(allocator, transaction_id, snapshot.version.bytes);

        return .{
            .store = store,
            .allocator = allocator,
            .transaction_id = transaction_id,
            .base_revision = base.revision,
            .base_generation = base.generation,
            .base_mode_epoch = base.mode_epoch,
            .base_head = base.head,
            .base_control_ref = base.control_ref,
            .version = snapshot.version,
            .batch = batch,
        };
    }

    pub fn deinit(self: *Transaction) void {
        self.batch.deinit();
        self.version.deinit();
        self.staged.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn status(self: *const Transaction) Status {
        return self.current_status;
    }

    /// Returns the durable candidate commit after prepare. It may be orphaned
    /// by a conflict or an indeterminate publication that did not occur.
    pub fn candidateCommitRef(self: *const Transaction) ?store_mod.ObjectRef {
        return self.prepared_commit;
    }

    pub fn putImmutable(self: *Transaction, bytes: []const u8) !store_mod.ObjectRef {
        if (self.current_status != .staging) return error.InvalidState;
        try self.staged.ensureUnusedCapacity(self.allocator, 1);
        const object_ref = try self.batch.putImmutable(bytes);
        self.staged.appendAssumeCapacity(object_ref);
        return object_ref;
    }

    /// Publishes `root` and stabilizes a definite winner. A stabilization error
    /// leaves the transaction in `.published` so durability can be retried.
    pub fn commit(self: *Transaction, root: store_mod.ObjectRef) !Outcome {
        if (self.current_status != .staging) return error.InvalidState;
        if (!self.isStaged(root)) {
            var bytes = try self.store.loadImmutable(root, self.allocator);
            bytes.deinit();
        }
        self.current_status = .failed;

        const generation = std.math.add(u64, self.base_generation, 1) catch
            return error.GenerationOverflow;
        const revision = std.math.add(u64, self.base_revision, 1) catch
            return error.RevisionOverflow;
        const encoded = commit_mod.encode(.{
            .generation = generation,
            .transaction_id = self.transaction_id,
            .parent = self.base_head,
            .root = root,
        });
        const commit_ref = try self.batch.putImmutable(&encoded);
        try self.batch.prepare();
        self.prepared_commit = commit_ref;

        const next = anchor.encode(.{
            .revision = revision,
            .generation = generation,
            .transaction_id = self.transaction_id,
            .head = commit_ref,
            .mode = .active,
            .mode_epoch = self.base_mode_epoch,
            .control_ref = self.base_control_ref,
        });
        const result = try self.batch.publish(self.version.bytes, &next);
        switch (result) {
            .conflict => {
                self.current_status = .conflict;
                return .conflict;
            },
            .indeterminate => {
                self.current_status = .indeterminate;
                return .indeterminate;
            },
            .committed => {
                self.current_status = .published;
                try self.stabilize();
                return .committed;
            },
        }
    }

    /// Resolves an indeterminate publication. A committed result transitions
    /// to `.published`; call stabilize before acknowledging the transaction.
    pub fn resolve(self: *Transaction, options: resolution.Options) !resolution.Resolution {
        const terminal = switch (self.current_status) {
            .indeterminate => self.batch.publicationTerminated(),
            .published => true,
            else => return error.InvalidState,
        };
        const attempt: resolution.Attempt = .{
            .base_revision = self.base_revision,
            .base_generation = self.base_generation,
            .base_mode_epoch = self.base_mode_epoch,
            .transaction_id = self.transaction_id,
        };
        const result = if (terminal)
            try resolution.resolveTerminal(self.store, self.allocator, attempt, options)
        else
            try resolution.resolve(self.store, self.allocator, attempt, options);
        switch (result) {
            .committed => self.current_status = .published,
            .not_committed => self.current_status = .not_committed,
            .pending => {},
        }
        return result;
    }

    pub fn stabilize(self: *Transaction) !void {
        if (self.current_status != .published) return error.InvalidState;
        try self.batch.stabilize();
        self.current_status = .committed;
    }

    fn isStaged(self: *const Transaction, object_ref: store_mod.ObjectRef) bool {
        for (self.staged.items) |staged| {
            if (store_mod.ObjectRef.eql(staged, object_ref)) return true;
        }
        return false;
    }
};
