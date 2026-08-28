//! Append-only immutable extent store with a full-block SCSI publication anchor.

const std = @import("std");
const allocation = @import("allocation_format.zig");
const anchor_format = @import("anchor.zig");
const conditional_block = @import("conditional_block.zig");
const data_block = @import("data_block.zig");
const extent_allocator = @import("extent_allocator.zig");
const immutable_extent = @import("immutable_extent.zig");
const maintenance = @import("maintenance.zig");
const resolution_mod = @import("resolution.zig");
const store_mod = @import("store.zig");
const volume_format = @import("volume_format.zig");

pub const ConditionalStore = store_mod.ConditionalStore;
pub const WriteBatch = store_mod.WriteBatch;

pub const Options = struct {
    owner_id: [16]u8,
    owner_incarnation: [16]u8,
    owner_epoch: u64,
};

pub const AnchorFormatResult = enum { formatted, already_formatted, indeterminate };

/// Both transport views must be derived from the same device object.
pub const ScsiStore = struct {
    allocator: extent_allocator.ExtentAllocator,
    data_transport: data_block.DataBlockTransport,
    conditional_transport: conditional_block.ConditionalBlockTransport,
    header: volume_format.Header,
    options: Options,
    metadata_mutex: std.atomic.Mutex = .unlocked,

    pub fn init(
        allocator: extent_allocator.ExtentAllocator,
        data_transport: data_block.DataBlockTransport,
        conditional_transport: conditional_block.ConditionalBlockTransport,
        header: volume_format.Header,
        options: Options,
    ) !ScsiStore {
        try data_transport.validate();
        try conditional_transport.validate();
        try volume_format.validate(header);
        if (!std.meta.eql(data_transport.geometry, header.geometry()) or
            !std.meta.eql(conditional_transport.geometry, header.geometry()))
        {
            return error.GeometryMismatch;
        }
        if (!std.meta.eql(allocator.header, header)) return error.AllocatorHeaderMismatch;
        if (data_transport.deviceIdentity() != conditional_transport.deviceIdentity() or
            allocator.transport.deviceIdentity() != conditional_transport.deviceIdentity())
        {
            return error.TransportIdentityMismatch;
        }
        if (allZero(&options.owner_id)) return error.InvalidOwnerId;
        if (allZero(&options.owner_incarnation)) return error.InvalidOwnerIncarnation;
        if (options.owner_epoch == 0) return error.InvalidOwnerEpoch;
        if (header.extent_size < immutable_extent.header_size)
            return error.ExtentTooSmall;
        return .{
            .allocator = allocator,
            .data_transport = data_transport,
            .conditional_transport = conditional_transport,
            .header = header,
            .options = options,
        };
    }

    pub fn conditionalStore(self: *ScsiStore) ConditionalStore {
        return .{ .context = self, .vtable = &conditional_store_vtable };
    }

    /// Initializes the anchor from an all-zero physical block. This is a
    /// formatting operation, not transaction publication.
    pub fn formatAnchor(self: *ScsiStore, initial: *const store_mod.Anchor) !AnchorFormatResult {
        const state = try anchor_format.decode(initial);
        if (state.revision != 0 or state.generation != 0 or state.head != null or
            !allZero(&state.transaction_id) or state.mode != .active or
            state.mode_epoch != 1)
        {
            return error.InvalidInitialAnchor;
        }
        var current = try self.allocatePhysicalAnchor(self.allocator.allocator);
        defer current.deinit();
        try self.conditional_transport.readBlock(self.header.layout.anchor_block, current.bytes);
        var desired = try self.physicalAnchor(self.allocator.allocator, initial);
        defer desired.deinit();
        if (std.mem.eql(u8, current.bytes, desired.bytes)) {
            return if (try self.stabilizeAnchorAndMatches(desired.bytes))
                .already_formatted
            else
                .indeterminate;
        }
        if (!allZero(current.bytes)) {
            _ = try validatePhysicalAnchor(current.bytes, self.header.volume_id);
            return error.AnchorAlreadyFormatted;
        }
        const operation_epoch = self.conditional_transport.resetEpoch();
        return switch (try self.conditional_transport.compareAndWriteAtEpoch(
            operation_epoch,
            self.header.layout.anchor_block,
            current.bytes,
            desired.bytes,
        )) {
            .written => result: {
                break :result if (try self.stabilizeAnchorAndMatches(desired.bytes))
                    .formatted
                else
                    .indeterminate;
            },
            .miscompare => result: {
                try self.conditional_transport.readBlock(
                    self.header.layout.anchor_block,
                    current.bytes,
                );
                if (std.mem.eql(u8, current.bytes, desired.bytes)) {
                    break :result if (try self.stabilizeAnchorAndMatches(desired.bytes))
                        .already_formatted
                    else
                        .indeterminate;
                }
                _ = try validatePhysicalAnchor(current.bytes, self.header.volume_id);
                return error.AnchorFormatConflict;
            },
            .indeterminate => .indeterminate,
        };
    }

    fn readAnchor(context: *anyopaque, allocator: std.mem.Allocator) !store_mod.AnchorSnapshot {
        const self: *ScsiStore = @ptrCast(@alignCast(context));
        var physical = try self.allocatePhysicalAnchor(allocator);
        errdefer physical.deinit();
        try self.conditional_transport.readBlock(self.header.layout.anchor_block, physical.bytes);
        const envelope = try validatePhysicalAnchor(physical.bytes, self.header.volume_id);
        return .{
            .anchor = envelope,
            .version = physical,
        };
    }

    fn loadImmutable(
        context: *anyopaque,
        reference: store_mod.ObjectRef,
        allocator: std.mem.Allocator,
    ) !store_mod.OwnedBytes {
        const self: *ScsiStore = @ptrCast(@alignCast(context));
        const identity = try immutable_extent.decodeObjectRef(reference);
        spinLock(&self.metadata_mutex);
        const entry = self.allocator.readEntry(identity.extent_index) catch |err| {
            self.metadata_mutex.unlock();
            return err;
        };
        const first_block = self.allocator.extentFirstBlock(identity.extent_index) catch |err| {
            self.metadata_mutex.unlock();
            return err;
        };
        self.metadata_mutex.unlock();
        if (entry.state != .live or entry.kind != .immutable or
            entry.claim_epoch != identity.claim_epoch or
            !std.mem.eql(u8, &entry.claim_id, &identity.claim_id))
        {
            return error.ObjectNotFound;
        }

        const extent_size: usize = @intCast(self.header.extent_size);
        const extent = try data_block.allocateBuffer(allocator, extent_size);
        defer allocator.free(extent);
        try self.data_transport.readBlocks(
            first_block,
            extent,
        );
        const view = try immutable_extent.decode(extent, self.header.volume_id, reference);
        return store_mod.OwnedBytes.dupe(allocator, view.payload);
    }

    fn beginBatch(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        transaction_id: store_mod.TransactionId,
        base_version: []const u8,
    ) !WriteBatch {
        return beginBatchFor(context, allocator, transaction_id, base_version, .transaction);
    }

    fn beginControlBatch(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        operation_id: store_mod.TransactionId,
        base_version: []const u8,
    ) !WriteBatch {
        return beginBatchFor(context, allocator, operation_id, base_version, .control);
    }

    fn beginBatchFor(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        transaction_id: store_mod.TransactionId,
        base_version: []const u8,
        purpose: BatchPurpose,
    ) !WriteBatch {
        const self: *ScsiStore = @ptrCast(@alignCast(context));
        if (allZero(&transaction_id)) return error.InvalidTransactionId;
        if (base_version.len != self.header.logical_block_size)
            return error.InvalidVersionToken;
        const logical = try validatePhysicalAnchor(base_version, self.header.volume_id);
        const base_state = try anchor_format.decode(&logical);
        try validateAnchorState(base_state);
        if (purpose == .transaction and base_state.mode != .active)
            return error.VolumeNotActive;
        const publication_revision = std.math.add(u64, base_state.revision, 1) catch
            return error.RevisionOverflow;
        const publication_generation = std.math.add(u64, base_state.generation, 1) catch
            return error.GenerationOverflow;
        var base = try store_mod.OwnedBytes.dupe(allocator, base_version);
        errdefer base.deinit();
        const batch = try allocator.create(ScsiWriteBatch);
        batch.* = .{
            .backing_allocator = allocator,
            .store = self,
            .transaction_id = transaction_id,
            .purpose = purpose,
            .base_version = base,
            .base_revision = base_state.revision,
            .base_generation = base_state.generation,
            .base_mode_epoch = base_state.mode_epoch,
            .base_mode = base_state.mode,
            .base_control_ref = base_state.control_ref,
            .publication_revision = publication_revision,
            .publication_generation = publication_generation,
            .reset_epoch = self.conditional_transport.resetEpoch(),
        };
        return .{ .context = batch, .vtable = &batch_vtable };
    }

    fn allocatePhysicalAnchor(
        self: *const ScsiStore,
        allocator: std.mem.Allocator,
    ) !store_mod.OwnedBytes {
        return .{
            .allocator = allocator,
            .bytes = try allocator.alloc(u8, self.header.logical_block_size),
        };
    }

    fn physicalAnchor(
        self: *const ScsiStore,
        allocator: std.mem.Allocator,
        envelope: *const store_mod.Anchor,
    ) !store_mod.OwnedBytes {
        var physical = try self.allocatePhysicalAnchor(allocator);
        @memset(physical.bytes, 0);
        @memcpy(physical.bytes[0..anchor_format.encoded_size], envelope[0..anchor_format.encoded_size]);
        @memcpy(physical.bytes[anchor_format.encoded_size..][0..16], &self.header.volume_id);
        sealPhysicalAnchor(physical.bytes);
        return physical;
    }

    fn stabilizeAnchorAndMatches(self: *ScsiStore, expected: []const u8) !bool {
        try self.conditional_transport.stabilize();
        var observed = try self.allocatePhysicalAnchor(self.allocator.allocator);
        defer observed.deinit();
        try self.conditional_transport.readBlock(self.header.layout.anchor_block, observed.bytes);
        return std.mem.eql(u8, observed.bytes, expected);
    }

    const conditional_store_vtable = ConditionalStore.VTable{
        .read_anchor = readAnchor,
        .load_immutable = loadImmutable,
        .begin_batch = beginBatch,
        .begin_control_batch = beginControlBatch,
    };

    const batch_vtable = WriteBatch.VTable{
        .put_immutable = ScsiWriteBatch.putImmutable,
        .prepare = ScsiWriteBatch.prepare,
        .publish = ScsiWriteBatch.publish,
        .stabilize = ScsiWriteBatch.stabilize,
        .publication_terminated = ScsiWriteBatch.publicationTerminated,
        .deinit = ScsiWriteBatch.deinitErased,
    };
};

const ObjectPhase = enum { staged, written, live };

const StagedObject = struct {
    bytes: []u8,
    reference: store_mod.ObjectRef,
    claim: extent_allocator.Claim,
    phase: ObjectPhase = .staged,
    pending_activation: ?extent_allocator.PendingTransition = null,
};

const BatchState = enum { staging, preparing, prepared, finished, poisoned };
const BatchPurpose = enum { transaction, control };

const ScsiWriteBatch = struct {
    backing_allocator: std.mem.Allocator,
    store: *ScsiStore,
    transaction_id: store_mod.TransactionId,
    purpose: BatchPurpose,
    base_version: store_mod.OwnedBytes,
    base_revision: u64,
    base_generation: u64,
    base_mode_epoch: u64,
    base_mode: anchor_format.Mode,
    base_control_ref: ?store_mod.ObjectRef,
    publication_revision: u64,
    publication_generation: u64,
    reset_epoch: u64,
    objects: std.ArrayList(StagedObject) = .empty,
    state: BatchState = .staging,
    publication_may_have_run: bool = false,
    publication_replacement: ?store_mod.OwnedBytes = null,
    publication_mode: ?anchor_format.Mode = null,

    fn putImmutable(context: *anyopaque, bytes: []const u8) !store_mod.ObjectRef {
        const self: *ScsiWriteBatch = @ptrCast(@alignCast(context));
        if (self.state != .staging) return error.InvalidState;
        try self.checkEpoch();
        if (bytes.len > self.store.header.extent_size - immutable_extent.header_size)
            return error.ObjectTooLarge;

        const sequence = self.objects.items.len;
        const claim_id = makeClaimId(
            self.store.header.volume_id,
            self.base_generation,
            self.transaction_id,
            sequence,
            bytes,
        );
        spinLock(&self.store.metadata_mutex);
        const outcome = self.store.allocator.claim(.{
            .kind = .immutable,
            .claim_id = claim_id,
            .owner_id = self.store.options.owner_id,
            .owner_incarnation = self.store.options.owner_incarnation,
            .base_generation = self.base_generation,
            .owner_epoch = self.store.options.owner_epoch,
        }) catch |err| {
            self.store.metadata_mutex.unlock();
            return err;
        };
        self.store.metadata_mutex.unlock();
        const claim = switch (outcome) {
            .claimed => |value| value,
            .pending => return error.AllocationIndeterminate,
            .exhausted => return error.OutOfExtents,
        };
        const identity = try immutable_extent.identityFor(
            claim.extentIndex(),
            claim.entry.claim_epoch,
            claim.entry.claim_id,
            bytes,
        );
        const reference = try immutable_extent.objectRef(identity);
        const owned = try self.backing_allocator.dupe(u8, bytes);
        errdefer self.backing_allocator.free(owned);
        try self.objects.append(self.backing_allocator, .{
            .bytes = owned,
            .reference = reference,
            .claim = claim,
        });
        return reference;
    }

    fn prepare(context: *anyopaque) !void {
        const self: *ScsiWriteBatch = @ptrCast(@alignCast(context));
        if (self.state == .staging) self.state = .preparing;
        if (self.state != .preparing) return error.InvalidState;
        try self.checkEpoch();

        for (self.objects.items) |*object| {
            if (object.phase != .staged) continue;
            spinLock(&self.store.metadata_mutex);
            const current = self.store.allocator.readEntry(object.claim.extentIndex()) catch |err| {
                self.store.metadata_mutex.unlock();
                return err;
            };
            const first_block = self.store.allocator.extentFirstBlock(object.claim.extentIndex()) catch |err| {
                self.store.metadata_mutex.unlock();
                return err;
            };
            self.store.metadata_mutex.unlock();
            if (current.state == .live and sameClaim(current, object.claim.entry)) {
                var existing = try self.store.conditionalStore().loadImmutable(
                    object.reference,
                    self.backing_allocator,
                );
                defer existing.deinit();
                if (!std.mem.eql(u8, existing.bytes, object.bytes))
                    return error.ObjectReferenceCollision;
                object.phase = .live;
                continue;
            }
            if (current.state != .claimed or !std.meta.eql(current, object.claim.entry))
                return error.AllocationStateChanged;
            const extent = try data_block.allocateBuffer(
                self.backing_allocator,
                self.store.header.extent_size,
            );
            defer self.backing_allocator.free(extent);
            const identity = try immutable_extent.decodeObjectRef(object.reference);
            try immutable_extent.encode(extent, self.store.header.volume_id, identity, object.bytes);
            switch (try self.store.data_transport.writeBlocks(
                first_block,
                extent,
            )) {
                .written => object.phase = .written,
                .indeterminate => {
                    self.state = .poisoned;
                    return error.DataWriteIndeterminate;
                },
            }
        }

        self.store.data_transport.stabilize() catch |err| {
            for (self.objects.items) |*object| {
                if (object.phase == .written) object.phase = .staged;
            }
            return err;
        };
        try self.checkEpoch();
        for (self.objects.items) |*object| {
            if (object.phase == .live) continue;
            if (object.pending_activation) |pending| {
                spinLock(&self.store.metadata_mutex);
                const resolution = self.store.allocator.resolveTransition(pending) catch |err| {
                    self.store.metadata_mutex.unlock();
                    return err;
                };
                self.store.metadata_mutex.unlock();
                switch (resolution) {
                    .completed => {
                        object.phase = .live;
                        object.pending_activation = null;
                        continue;
                    },
                    .pending => return error.AllocationIndeterminate,
                    .not_completed => object.pending_activation = null,
                }
            }
            spinLock(&self.store.metadata_mutex);
            const activation = self.store.allocator.activate(
                object.claim,
                self.publication_generation,
            ) catch |err| {
                self.store.metadata_mutex.unlock();
                return err;
            };
            self.store.metadata_mutex.unlock();
            switch (activation) {
                .completed => object.phase = .live,
                .pending => |pending| {
                    object.pending_activation = pending;
                    return error.AllocationIndeterminate;
                },
            }
            try self.checkEpoch();
        }
        self.state = .prepared;
    }

    fn publish(
        context: *anyopaque,
        expected_version: []const u8,
        next_anchor: *const store_mod.Anchor,
    ) !store_mod.PublishResult {
        const self: *ScsiWriteBatch = @ptrCast(@alignCast(context));
        if (self.state != .prepared) return error.InvalidState;
        try self.checkEpoch();
        if (expected_version.len != self.store.header.logical_block_size)
            return error.InvalidVersionToken;
        if (!std.mem.eql(u8, expected_version, self.base_version.bytes))
            return error.BatchBaseVersionMismatch;
        const expected = try validatePhysicalAnchor(expected_version, self.store.header.volume_id);
        const previous = try anchor_format.decode(&expected);
        try validateAnchorState(previous);
        if (previous.revision != self.base_revision) return error.BatchBaseVersionMismatch;
        if (previous.generation != self.base_generation) return error.BatchBaseVersionMismatch;
        const next = try anchor_format.decode(next_anchor);
        try validateAnchorState(next);
        switch (self.purpose) {
            .transaction => {
                if (previous.mode != .active) return error.VolumeNotActive;
                if (next.mode != .active or next.mode_epoch != self.base_mode_epoch)
                    return error.InvalidAnchorMode;
                const expected_generation = std.math.add(u64, previous.generation, 1) catch
                    return error.GenerationOverflow;
                if (next.generation != expected_generation)
                    return error.InvalidAnchorGeneration;
                if (!std.mem.eql(u8, &next.transaction_id, &self.transaction_id))
                    return error.InvalidAnchorTransaction;
                if (next.head == null) return error.InvalidAnchorState;
                if (next.revision != self.publication_revision)
                    return error.InvalidAnchorRevision;
                if (!optionalRefEql(next.control_ref, previous.control_ref))
                    return error.InvalidAnchorControl;
            },
            .control => {
                if (next.revision != self.publication_revision)
                    return error.InvalidAnchorRevision;
                try validateControlSuccessor(previous, next, self.transaction_id);
            },
        }

        var replacement = try self.store.physicalAnchor(self.backing_allocator, next_anchor);
        errdefer replacement.deinit();
        const result = try self.store.conditional_transport.compareAndWriteAtEpoch(
            self.reset_epoch,
            self.store.header.layout.anchor_block,
            expected_version,
            replacement.bytes,
        );
        return switch (result) {
            .written => result: {
                self.state = .finished;
                self.publication_may_have_run = true;
                self.publication_replacement = replacement;
                self.publication_mode = next.mode;
                break :result .committed;
            },
            .miscompare => result: {
                replacement.deinit();
                self.state = .finished;
                break :result .conflict;
            },
            .indeterminate => result: {
                self.state = .finished;
                self.publication_may_have_run = true;
                self.publication_replacement = replacement;
                self.publication_mode = next.mode;
                break :result .indeterminate;
            },
        };
    }

    fn stabilize(context: *anyopaque) !void {
        const self: *ScsiWriteBatch = @ptrCast(@alignCast(context));
        if (self.state != .finished or !self.publication_may_have_run)
            return error.InvalidState;
        const reset = self.reset_epoch != self.store.conditional_transport.resetEpoch();
        if (reset and self.purpose != .control) return error.DeviceReset;
        try self.store.conditional_transport.stabilize();
        if (!reset) try self.checkEpoch();

        var observed = try self.store.allocatePhysicalAnchor(self.backing_allocator);
        defer observed.deinit();
        try self.store.conditional_transport.readBlock(self.store.header.layout.anchor_block, observed.bytes);
        if (!reset) try self.checkEpoch();
        if (std.mem.eql(u8, observed.bytes, self.publication_replacement.?.bytes)) return;

        const result = switch (self.purpose) {
            .transaction => try resolution_mod.resolve(
                self.store.conditionalStore(),
                self.backing_allocator,
                .{
                    .base_generation = self.base_generation,
                    .base_revision = self.base_revision,
                    .base_mode_epoch = self.base_mode_epoch,
                    .transaction_id = self.transaction_id,
                },
                .{},
            ),
            .control => control: {
                const attempt: maintenance.Attempt = .{
                    .base_revision = self.base_revision,
                    .base_generation = self.base_generation,
                    .base_mode_epoch = self.base_mode_epoch,
                    .base_control_ref = self.base_control_ref,
                    .operation_id = self.transaction_id,
                    .previous_mode = self.base_mode,
                    .mode = self.publication_mode.?,
                };
                const control_result = if (reset)
                    try maintenance.resolveTerminal(
                        self.store.conditionalStore(),
                        self.backing_allocator,
                        attempt,
                        .{},
                    )
                else
                    try maintenance.resolvePublication(
                        self.store.conditionalStore(),
                        self.backing_allocator,
                        attempt,
                        .{},
                    );
                break :control switch (control_result) {
                    .committed => resolution_mod.Resolution.committed,
                    .not_committed => .not_committed,
                    .pending => .pending,
                };
            },
        };
        if (!reset) try self.checkEpoch();
        if (result != .committed) return error.PublicationRequiresResolution;
    }

    fn deinitErased(context: *anyopaque) void {
        const self: *ScsiWriteBatch = @ptrCast(@alignCast(context));
        for (self.objects.items) |object| self.backing_allocator.free(object.bytes);
        self.objects.deinit(self.backing_allocator);
        self.base_version.deinit();
        if (self.publication_replacement) |*replacement| replacement.deinit();
        const allocator = self.backing_allocator;
        allocator.destroy(self);
    }

    fn checkEpoch(self: *const ScsiWriteBatch) !void {
        if (self.reset_epoch != self.store.conditional_transport.resetEpoch())
            return error.DeviceReset;
    }

    fn publicationTerminated(context: *anyopaque) bool {
        const self: *ScsiWriteBatch = @ptrCast(@alignCast(context));
        return self.reset_epoch != self.store.conditional_transport.resetEpoch();
    }
};

const physical_volume_end = anchor_format.encoded_size + 16;
const physical_checksum_end = physical_volume_end + std.crypto.hash.sha2.Sha256.digest_length;

fn validatePhysicalAnchor(physical: []const u8, volume_id: [16]u8) !store_mod.Anchor {
    if (physical.len != 512 and physical.len != 4096)
        return error.InvalidVersionToken;
    if (!std.mem.eql(u8, physical[anchor_format.encoded_size..physical_volume_end], &volume_id))
        return error.AnchorVolumeMismatch;
    if (!verifyPhysicalAnchor(physical)) return error.PhysicalAnchorChecksumMismatch;
    if (!allZero(physical[physical_checksum_end..]))
        return error.NonCanonicalAnchorPadding;
    var envelope: store_mod.Anchor = @splat(0);
    @memcpy(envelope[0..anchor_format.encoded_size], physical[0..anchor_format.encoded_size]);
    _ = try anchor_format.decode(&envelope);
    return envelope;
}

fn validateAnchorState(state: anchor_format.State) !void {
    anchor_format.validate(state) catch return error.InvalidAnchorState;
}

fn validateControlSuccessor(
    previous: anchor_format.State,
    next: anchor_format.State,
    operation_id: store_mod.TransactionId,
) !void {
    if (next.generation != previous.generation) return error.InvalidAnchorGeneration;
    if (!std.mem.eql(u8, &next.transaction_id, &previous.transaction_id) or
        !optionalRefEql(next.head, previous.head))
    {
        return error.InvalidAnchorTransaction;
    }
    if (next.control_ref == null or optionalRefEql(next.control_ref, previous.control_ref))
        return error.InvalidAnchorControl;
    if (next.mode == .active) {
        if (previous.mode != .maintenance or
            !std.mem.eql(u8, &previous.control_operation_id, &operation_id) or
            next.mode_epoch != previous.mode_epoch)
        {
            return error.InvalidAnchorMode;
        }
        return;
    }
    if (!std.mem.eql(u8, &next.control_operation_id, &operation_id))
        return error.InvalidAnchorControl;
    switch (previous.mode) {
        .active => if (next.mode != .quiescing or
            next.mode_epoch != std.math.add(u64, previous.mode_epoch, 1) catch
                return error.ModeEpochOverflow)
        {
            return error.InvalidAnchorMode;
        },
        .quiescing => if ((next.mode != .maintenance and next.mode != .blocked) or
            next.mode_epoch != previous.mode_epoch or
            !std.mem.eql(u8, &previous.control_operation_id, &operation_id))
        {
            return error.InvalidAnchorMode;
        },
        .maintenance => if (next.mode != .blocked or
            next.mode_epoch != previous.mode_epoch or
            !std.mem.eql(u8, &previous.control_operation_id, &operation_id))
        {
            return error.InvalidAnchorMode;
        },
        .blocked => return error.InvalidAnchorMode,
    }
}

fn optionalRefEql(a: ?store_mod.ObjectRef, b: ?store_mod.ObjectRef) bool {
    if (a) |a_ref| {
        const b_ref = b orelse return false;
        return store_mod.ObjectRef.eql(a_ref, b_ref);
    }
    return b == null;
}

fn makeClaimId(
    volume_id: [16]u8,
    base_generation: u64,
    transaction_id: store_mod.TransactionId,
    sequence: usize,
    payload: []const u8,
) [16]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Stable digest domain inherited from CAWFS volumes; never rename.
    hasher.update("CAWFS immutable extent claim v2");
    hasher.update(&volume_id);
    var generation_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &generation_bytes, base_generation, .big);
    hasher.update(&generation_bytes);
    hasher.update(&transaction_id);
    var sequence_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &sequence_bytes, @intCast(sequence), .big);
    hasher.update(&sequence_bytes);
    var payload_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &payload_digest, .{});
    hasher.update(&payload_digest);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    var result = digest[0..16].*;
    if (allZero(&result)) result[15] = 1;
    return result;
}

fn sameClaim(a: allocation.Entry, b: allocation.Entry) bool {
    return a.extent_index == b.extent_index and
        a.claim_epoch == b.claim_epoch and
        std.mem.eql(u8, &a.claim_id, &b.claim_id);
}

fn sealPhysicalAnchor(physical: []u8) void {
    @memset(physical[physical_volume_end..physical_checksum_end], 0);
    var checksum: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(physical, &checksum, .{});
    @memcpy(physical[physical_volume_end..physical_checksum_end], &checksum);
}

fn verifyPhysicalAnchor(physical: []const u8) bool {
    var canonical: [4096]u8 = @splat(0);
    @memcpy(canonical[0..physical.len], physical);
    @memset(canonical[physical_volume_end..physical_checksum_end], 0);
    var checksum: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical[0..physical.len], &checksum, .{});
    return std.mem.eql(u8, physical[physical_volume_end..physical_checksum_end], &checksum);
}

fn spinLock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {}
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
