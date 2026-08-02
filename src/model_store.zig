const std = @import("std");
const store_mod = @import("store.zig");

pub const AnchorSnapshot = store_mod.AnchorSnapshot;
pub const Anchor = store_mod.Anchor;
pub const ConditionalStore = store_mod.ConditionalStore;
pub const ObjectRef = store_mod.ObjectRef;
pub const OwnedBytes = store_mod.OwnedBytes;
pub const PublishResult = store_mod.PublishResult;
pub const TransactionId = store_mod.TransactionId;
pub const WriteBatch = store_mod.WriteBatch;

pub const Error = error{
    InvalidState,
    InvalidVersionToken,
    ObjectNotFound,
    ObjectReferenceCollision,
    NoOpAnchor,
    InjectedStabilizeFailure,
};

pub const PublishFault = enum {
    none,
    indeterminate_before,
    indeterminate_after,
};

fn spinLock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {}
}

const ObjectRecord = struct {
    object_ref: ObjectRef,
    bytes: []u8,
};

pub const ModelStore = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    objects: std.ArrayList(ObjectRecord) = .empty,
    visible_anchor: Anchor,
    stable_anchor: Anchor,
    next_publish_fault: PublishFault = .none,
    fail_next_stabilize: bool = false,
    active_batches: usize = 0,
    epoch: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, initial_anchor: Anchor) ModelStore {
        return .{
            .allocator = allocator,
            .visible_anchor = initial_anchor,
            .stable_anchor = initial_anchor,
        };
    }

    pub fn deinit(self: *ModelStore) void {
        std.debug.assert(self.active_batches == 0);
        for (self.objects.items) |object| self.allocator.free(object.bytes);
        self.objects.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn conditionalStore(self: *ModelStore) ConditionalStore {
        return .{
            .context = self,
            .vtable = &conditional_store_vtable,
        };
    }

    pub fn injectNextPublishFault(self: *ModelStore, fault: PublishFault) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.next_publish_fault = fault;
    }

    pub fn injectNextStabilizeFailure(self: *ModelStore) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.fail_next_stabilize = true;
    }

    pub fn crash(self: *ModelStore) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();

        self.visible_anchor = self.stable_anchor;
        self.next_publish_fault = .none;
        self.fail_next_stabilize = false;
        self.epoch += 1;
    }

    fn readAnchor(context: *anyopaque, allocator: std.mem.Allocator) !AnchorSnapshot {
        const self: *ModelStore = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();

        return .{
            .anchor = self.visible_anchor,
            .version = try encodeVersion(allocator, self.visible_anchor),
        };
    }

    fn loadImmutable(
        context: *anyopaque,
        object_ref: ObjectRef,
        allocator: std.mem.Allocator,
    ) !OwnedBytes {
        const self: *ModelStore = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();

        for (self.objects.items) |object| {
            if (ObjectRef.eql(object.object_ref, object_ref)) {
                return OwnedBytes.dupe(allocator, object.bytes);
            }
        }
        return error.ObjectNotFound;
    }

    fn beginBatch(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        transaction_id: TransactionId,
    ) !WriteBatch {
        const self: *ModelStore = @ptrCast(@alignCast(context));
        const batch = try allocator.create(ModelBatch);

        spinLock(&self.mutex);
        batch.* = .{
            .allocator = allocator,
            .store = self,
            .transaction_id = transaction_id,
            .store_epoch = self.epoch,
        };
        self.active_batches += 1;
        self.mutex.unlock();

        return .{
            .context = batch,
            .vtable = &batch_vtable,
        };
    }

    fn encodeVersion(allocator: std.mem.Allocator, anchor: Anchor) !OwnedBytes {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&anchor, &digest, .{});
        return OwnedBytes.dupe(allocator, &digest);
    }

    fn currentVersion(anchor: Anchor) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&anchor, &digest, .{});
        return digest;
    }

    fn findObject(self: *ModelStore, object_ref: ObjectRef) ?[]const u8 {
        for (self.objects.items) |object| {
            if (ObjectRef.eql(object.object_ref, object_ref)) return object.bytes;
        }
        return null;
    }

    const conditional_store_vtable: ConditionalStore.VTable = .{
        .read_anchor = readAnchor,
        .load_immutable = loadImmutable,
        .begin_batch = beginBatch,
    };

    const batch_vtable: WriteBatch.VTable = .{
        .put_immutable = ModelBatch.putImmutable,
        .prepare = ModelBatch.prepare,
        .publish = ModelBatch.publish,
        .stabilize = ModelBatch.stabilize,
        .deinit = ModelBatch.deinitErased,
    };
};

const StagedObject = struct {
    object_ref: ObjectRef,
    bytes: ?[]u8,
};

const BatchState = enum {
    staging,
    prepared,
    finished,
};

const ModelBatch = struct {
    allocator: std.mem.Allocator,
    store: *ModelStore,
    transaction_id: TransactionId,
    store_epoch: u64,
    staged: std.ArrayList(StagedObject) = .empty,
    state: BatchState = .staging,
    publish_applied: bool = false,

    fn putImmutable(context: *anyopaque, bytes: []const u8) !ObjectRef {
        const self: *ModelBatch = @ptrCast(@alignCast(context));
        if (self.state != .staging) return error.InvalidState;

        spinLock(&self.store.mutex);
        defer self.store.mutex.unlock();
        if (self.store_epoch != self.store.epoch) return error.InvalidState;

        const owned = try self.store.allocator.dupe(u8, bytes);
        errdefer self.store.allocator.free(owned);
        const object_ref = makeObjectRef(self.transaction_id, self.staged.items.len, bytes);
        try self.staged.append(self.allocator, .{
            .object_ref = object_ref,
            .bytes = owned,
        });
        return object_ref;
    }

    fn prepare(context: *anyopaque) !void {
        const self: *ModelBatch = @ptrCast(@alignCast(context));
        if (self.state != .staging) return error.InvalidState;

        spinLock(&self.store.mutex);
        defer self.store.mutex.unlock();
        if (self.store_epoch != self.store.epoch) return error.InvalidState;

        for (self.staged.items) |*staged| {
            const bytes = staged.bytes orelse continue;
            if (self.store.findObject(staged.object_ref)) |existing| {
                if (!std.mem.eql(u8, existing, bytes)) return error.ObjectReferenceCollision;
                self.store.allocator.free(bytes);
                staged.bytes = null;
                continue;
            }
            try self.store.objects.append(self.store.allocator, .{
                .object_ref = staged.object_ref,
                .bytes = bytes,
            });
            staged.bytes = null;
        }
        self.state = .prepared;
    }

    fn publish(
        context: *anyopaque,
        expected_version: []const u8,
        next_anchor: *const Anchor,
    ) !PublishResult {
        const self: *ModelBatch = @ptrCast(@alignCast(context));
        if (self.state != .prepared) return error.InvalidState;
        if (expected_version.len != 32) return error.InvalidVersionToken;

        spinLock(&self.store.mutex);
        defer self.store.mutex.unlock();
        if (self.store_epoch != self.store.epoch) return error.InvalidState;

        const current_version = ModelStore.currentVersion(self.store.visible_anchor);
        if (!std.mem.eql(u8, expected_version, &current_version)) {
            self.state = .finished;
            return .conflict;
        }
        if (std.mem.eql(u8, &self.store.visible_anchor, next_anchor))
            return error.NoOpAnchor;

        const fault = self.store.next_publish_fault;
        self.store.next_publish_fault = .none;
        if (fault == .indeterminate_before) {
            self.state = .finished;
            return .indeterminate;
        }

        self.store.visible_anchor = next_anchor.*;
        self.publish_applied = true;
        self.state = .finished;

        return if (fault == .indeterminate_after) .indeterminate else .committed;
    }

    fn stabilize(context: *anyopaque) !void {
        const self: *ModelBatch = @ptrCast(@alignCast(context));
        if (self.state != .finished or !self.publish_applied)
            return error.InvalidState;

        spinLock(&self.store.mutex);
        defer self.store.mutex.unlock();
        if (self.store_epoch != self.store.epoch) return error.InvalidState;
        if (self.store.fail_next_stabilize) {
            self.store.fail_next_stabilize = false;
            return error.InjectedStabilizeFailure;
        }

        self.store.stable_anchor = self.store.visible_anchor;
    }

    fn deinitErased(context: *anyopaque) void {
        const self: *ModelBatch = @ptrCast(@alignCast(context));
        spinLock(&self.store.mutex);
        for (self.staged.items) |staged| {
            if (staged.bytes) |bytes| self.store.allocator.free(bytes);
        }
        self.store.active_batches -= 1;
        self.store.mutex.unlock();

        const allocator = self.allocator;
        self.staged.deinit(allocator);
        allocator.destroy(self);
    }

    fn makeObjectRef(transaction_id: TransactionId, sequence: usize, bytes: []const u8) ObjectRef {
        var object_ref: ObjectRef = .{};
        object_ref.bytes[0] = 1;
        @memcpy(object_ref.bytes[1..17], &transaction_id);
        var sequence_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &sequence_bytes, @intCast(sequence), .big);
        @memcpy(object_ref.bytes[17..25], &sequence_bytes);
        std.crypto.hash.sha2.Sha256.hash(bytes, object_ref.bytes[32..64], .{});
        return object_ref;
    }
};
