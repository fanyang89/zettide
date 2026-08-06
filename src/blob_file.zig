const std = @import("std");
const blob_device = @import("blob_device.zig");
const blob_format = @import("blob_format.zig");
const blob_map = @import("blob_map.zig");
const blob_map_store = @import("blob_map_store.zig");
const blob_store = @import("blob_store.zig");

const Io = std.Io;

pub const block_size: u32 = blob_format.allocation_unit;

pub const Snapshot = struct {
    generation: u64,
    logical_size: u64,
    root: ?blob_map.PageRef,
};

pub fn readSnapshot(
    allocator: std.mem.Allocator,
    io: Io,
    blobs: *blob_store.Store,
    snapshot: Snapshot,
    output: []u8,
    offset: u64,
) !usize {
    return readSnapshotAt(allocator, io, blobs, blobs.committedUnits(), snapshot, output, offset);
}

pub fn readSnapshotAt(
    allocator: std.mem.Allocator,
    io: Io,
    blobs: *blob_store.Store,
    readable_units: u64,
    snapshot: Snapshot,
    output: []u8,
    offset: u64,
) !usize {
    if (snapshot.generation == 0 or snapshot.logical_size > std.math.maxInt(i64) or
        (snapshot.root != null and snapshot.logical_size == 0))
        return error.InvalidBlobFileSnapshot;
    const block_count = try std.math.divCeil(u64, snapshot.logical_size, block_size);
    if (snapshot.root) |root| {
        if (root.first_key > root.last_key or root.last_key >= block_count)
            return error.InvalidBlobFileSnapshot;
    }
    if (offset >= snapshot.logical_size or output.len == 0) return 0;

    const amount: usize = @intCast(@min(@as(u64, output.len), snapshot.logical_size - offset));
    const map_scratch = try allocator.alignedAlloc(u8, .fromByteUnits(blob_format.allocation_unit), blob_map.page_size);
    defer allocator.free(map_scratch);
    const touched_blocks = try std.math.divCeil(
        usize,
        @as(usize, @intCast(offset % block_size)) + amount,
        block_size,
    );
    const block_scratch = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(block_size),
        @min(touched_blocks, blob_device.max_batch) * block_size,
    );
    defer allocator.free(block_scratch);
    var maps = blob_map_store.MapStore.init(allocator, blobs);

    var consumed: usize = 0;
    while (consumed < amount) {
        const first_block = (offset + consumed) / block_size;
        const requested_end_block = try std.math.divCeil(u64, offset + amount, block_size);
        const end_block = @min(requested_end_block, first_block + blob_device.max_batch);
        var entries: [blob_device.max_batch]blob_map.LeafEntry = undefined;
        const loaded = if (snapshot.root) |root|
            try maps.loadRangeAt(
                io,
                root,
                snapshot.generation,
                readable_units,
                first_block,
                end_block,
                map_scratch,
                &entries,
            )
        else
            blob_map_store.MapStore.LoadedRange{ .end_key = end_block, .count = 0 };
        const loaded_end_block = loaded.end_key;
        var reads: [blob_device.max_batch]blob_store.Store.Read = undefined;
        var copies: [blob_device.max_batch]struct {
            output_offset: usize,
            block_offset: usize,
            len: usize,
        } = undefined;
        var read_count: usize = 0;
        var entry_index: usize = 0;
        var pending_error: ?anyerror = null;
        while (consumed < amount and (offset + consumed) / block_size < loaded_end_block) {
            const position = offset + consumed;
            const block = position / block_size;
            const block_offset: usize = @intCast(position % block_size);
            const part = @min(amount - consumed, block_size - block_offset);
            if (entry_index < loaded.count and entries[entry_index].logical_blob == block) {
                const ref = entries[entry_index].reference;
                ref.validate(blobs.header.unit_count) catch {
                    pending_error = error.InvalidBlobFileSnapshot;
                    break;
                };
                if (ref.valid_bytes != block_size or ref.endUnit() > readable_units) {
                    pending_error = error.InvalidBlobFileSnapshot;
                    break;
                }
                const scratch = block_scratch[read_count * block_size ..][0..block_size];
                reads[read_count] = .{ .reference = ref, .output = scratch };
                copies[read_count] = .{
                    .output_offset = consumed,
                    .block_offset = block_offset,
                    .len = part,
                };
                read_count += 1;
                entry_index += 1;
            } else {
                @memset(output[consumed..][0..part], 0);
            }
            consumed += part;
        }
        if (pending_error == null and entry_index != loaded.count)
            return error.InvalidBlobFileSnapshot;
        if (read_count != 0) {
            var results: [blob_device.max_batch]blob_store.Store.ReadResult = undefined;
            try blobs.readMany(io, reads[0..read_count], results[0..read_count]);
            for (results[0..read_count], copies[0..read_count], 0..) |result, copy, index| {
                if (result.failure) |err| return err;
                if (result.amount != block_size) return error.InvalidBlobFileBlock;
                @memcpy(
                    output[copy.output_offset..][0..copy.len],
                    block_scratch[index * block_size + copy.block_offset ..][0..copy.len],
                );
            }
        }
        if (pending_error) |err| return err;
    }
    return amount;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    blobs: *blob_store.Store,
    generation: u64,
    logical_size: u64,
    root: ?blob_map.PageRef,
    readable_units: u64,
    blocks: std.AutoHashMap(u64, blob_format.BlobRef),
    allocated_blocks: u64,
    blocks_materialized: bool,
    pending: std.AutoHashMap(u64, ?blob_format.BlobRef),
    dirty: bool = false,
    prepared: ?Snapshot = null,
    prepared_checkpoint: ?u64 = null,
    prepared_readable_units: ?u64 = null,
    frozen: bool = false,

    pub fn init(allocator: std.mem.Allocator, blobs: *blob_store.Store) State {
        return .{
            .allocator = allocator,
            .blobs = blobs,
            .generation = 1,
            .logical_size = 0,
            .root = null,
            .readable_units = 0,
            .blocks = .init(allocator),
            .allocated_blocks = 0,
            .blocks_materialized = true,
            .pending = .init(allocator),
        };
    }

    pub fn open(
        allocator: std.mem.Allocator,
        io: Io,
        blobs: *blob_store.Store,
        snapshot: Snapshot,
    ) !State {
        return openAt(allocator, io, blobs, blobs.committedUnits(), snapshot);
    }

    pub fn openAt(
        allocator: std.mem.Allocator,
        io: Io,
        blobs: *blob_store.Store,
        readable_units: u64,
        snapshot: Snapshot,
    ) !State {
        if (snapshot.generation == 0 or snapshot.logical_size > std.math.maxInt(i64) or
            (snapshot.root != null and snapshot.logical_size == 0))
            return error.InvalidBlobFileSnapshot;
        var result: State = .{
            .allocator = allocator,
            .blobs = blobs,
            .generation = snapshot.generation,
            .logical_size = snapshot.logical_size,
            .root = snapshot.root,
            .readable_units = readable_units,
            .blocks = .init(allocator),
            .allocated_blocks = 0,
            .blocks_materialized = true,
            .pending = .init(allocator),
        };
        errdefer result.deinit();
        const root = snapshot.root orelse return result;
        const scratch = try allocator.alignedAlloc(u8, .fromByteUnits(blob_format.allocation_unit), blob_map.page_size);
        defer allocator.free(scratch);
        var maps = blob_map_store.MapStore.init(allocator, blobs);
        const entries = try maps.loadAllAllocAt(io, root, snapshot.generation, readable_units, scratch);
        defer allocator.free(entries);
        try result.blocks.ensureUnusedCapacity(@intCast(entries.len));
        const block_count = try std.math.divCeil(u64, snapshot.logical_size, block_size);
        for (entries) |entry| {
            entry.reference.validate(blobs.header.unit_count) catch
                return error.InvalidBlobFileSnapshot;
            if (entry.logical_blob >= block_count or entry.reference.valid_bytes != block_size or
                entry.reference.endUnit() > readable_units)
                return error.InvalidBlobFileSnapshot;
            const block = result.blocks.getOrPutAssumeCapacity(entry.logical_blob);
            if (block.found_existing) return error.InvalidBlobFileSnapshot;
            block.value_ptr.* = entry.reference;
        }
        result.allocated_blocks = @intCast(entries.len);
        return result;
    }

    /// The inode record supplying `allocated_bytes` must already belong to a validated filesystem graph.
    pub fn openKnownAllocated(
        allocator: std.mem.Allocator,
        blobs: *blob_store.Store,
        snapshot: Snapshot,
        allocated_bytes: u64,
    ) !State {
        return openKnownAllocatedAt(allocator, blobs, blobs.committedUnits(), snapshot, allocated_bytes);
    }

    pub fn openKnownAllocatedAt(
        allocator: std.mem.Allocator,
        blobs: *blob_store.Store,
        readable_units: u64,
        snapshot: Snapshot,
        allocated_bytes: u64,
    ) !State {
        if (snapshot.generation == 0 or snapshot.logical_size > std.math.maxInt(i64) or
            allocated_bytes % block_size != 0)
            return error.InvalidBlobFileSnapshot;
        const allocated_blocks = allocated_bytes / block_size;
        const block_count = try std.math.divCeil(u64, snapshot.logical_size, block_size);
        if (allocated_blocks > block_count or (snapshot.root == null) != (allocated_blocks == 0))
            return error.InvalidBlobFileSnapshot;
        if (snapshot.root) |root| {
            if (snapshot.logical_size == 0 or root.first_key > root.last_key or
                root.last_key >= block_count or root.page >= readable_units)
                return error.InvalidBlobFileSnapshot;
        }
        return .{
            .allocator = allocator,
            .blobs = blobs,
            .generation = snapshot.generation,
            .logical_size = snapshot.logical_size,
            .root = snapshot.root,
            .readable_units = readable_units,
            .blocks = .init(allocator),
            .allocated_blocks = allocated_blocks,
            .blocks_materialized = false,
            .pending = .init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.blocks.deinit();
        self.pending.deinit();
        self.* = undefined;
    }

    pub fn size(self: *const State) u64 {
        return self.logical_size;
    }

    pub fn allocatedBytes(self: *const State) u64 {
        return std.math.mul(u64, self.allocated_blocks, block_size) catch unreachable;
    }

    pub fn read(self: *State, io: Io, output: []u8, offset: u64) !usize {
        try self.requireUsable();
        if (offset >= self.logical_size or output.len == 0) return 0;
        const amount: usize = @intCast(@min(@as(u64, output.len), self.logical_size - offset));
        const scratch = try self.allocator.alignedAlloc(u8, .fromByteUnits(block_size), block_size);
        defer self.allocator.free(scratch);

        var consumed: usize = 0;
        while (consumed < amount) {
            const position = offset + consumed;
            const block = position / block_size;
            const block_offset: usize = @intCast(position % block_size);
            const part = @min(amount - consumed, block_size - block_offset);
            if (try self.lookupCurrent(io, block)) |reference| {
                const read_amount = try self.blobs.read(io, reference, scratch);
                if (read_amount != block_size) return error.InvalidBlobFileBlock;
                @memcpy(output[consumed..][0..part], scratch[block_offset..][0..part]);
            } else {
                @memset(output[consumed..][0..part], 0);
            }
            consumed += part;
        }
        return amount;
    }

    pub fn write(self: *State, io: Io, data: []const u8, offset: u64) !usize {
        try self.requireMutable();
        const end = std.math.add(u64, offset, data.len) catch return error.FileTooLarge;
        if (end > std.math.maxInt(i64)) return error.FileTooLarge;
        if (data.len == 0) return 0;
        const span = std.math.add(usize, @intCast(offset % block_size), data.len) catch return error.FileTooLarge;
        const touched = try std.math.divCeil(usize, span, block_size);
        if (self.blocks_materialized) try self.blocks.ensureUnusedCapacity(@intCast(touched));
        try self.pending.ensureUnusedCapacity(@intCast(touched));
        const old_block_count = try std.math.divCeil(u64, self.logical_size, block_size);
        const old_is_dense = self.allocated_blocks == old_block_count;

        const buffers = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(block_size),
            blob_device.max_batch * block_size,
        );
        defer self.allocator.free(buffers);
        var inputs: [blob_device.max_batch][]const u8 = undefined;
        var references: [blob_device.max_batch]blob_format.BlobRef = undefined;
        var block_indices: [blob_device.max_batch]u64 = undefined;
        var existence_known: [blob_device.max_batch]bool = @splat(false);
        var existed: [blob_device.max_batch]bool = @splat(false);
        var consumed: usize = 0;
        var staged_data = false;
        errdefer if (staged_data) {
            self.frozen = true;
        };
        while (consumed < data.len) {
            @memset(&existence_known, false);
            @memset(&existed, false);
            var count: usize = 0;
            while (count < blob_device.max_batch and consumed < data.len) : (count += 1) {
                const position = offset + consumed;
                const block = position / block_size;
                const block_offset: usize = @intCast(position % block_size);
                const part = @min(data.len - consumed, block_size - block_offset);
                const buffer = buffers[count * block_size ..][0..block_size];
                if (block_offset != 0 or part != block_size) {
                    if (try self.lookupCurrent(io, block)) |reference| {
                        existed[count] = true;
                        const read_amount = try self.blobs.read(io, reference, buffer);
                        if (read_amount != block_size) return error.InvalidBlobFileBlock;
                    } else {
                        @memset(buffer, 0);
                    }
                    existence_known[count] = true;
                } else if (old_is_dense) {
                    existed[count] = block < old_block_count;
                    existence_known[count] = true;
                }
                @memcpy(buffer[block_offset..][0..part], data[consumed..][0..part]);
                inputs[count] = buffer;
                block_indices[count] = block;
                consumed += part;
            }
            self.blobs.putMany(io, inputs[0..count], references[0..count]) catch |err| {
                self.frozen = true;
                return err;
            };
            staged_data = true;
            try self.resolveExistence(
                io,
                block_indices[0..count],
                existence_known[0..count],
                existed[0..count],
            );
            for (block_indices[0..count], references[0..count], existed[0..count]) |block, reference, block_existed| {
                if (self.blocks_materialized) self.blocks.putAssumeCapacity(block, reference);
                self.pending.putAssumeCapacity(block, reference);
                if (!block_existed) self.allocated_blocks += 1;
            }
        }
        self.logical_size = @max(self.logical_size, end);
        self.dirty = true;
        return data.len;
    }

    pub fn truncate(self: *State, io: Io, size_value: u64) !void {
        try self.requireMutable();
        if (size_value > std.math.maxInt(i64)) return error.FileTooLarge;
        if (size_value == self.logical_size) return;
        try self.materializeCurrent(io);
        const shrinking = size_value < self.logical_size;
        const first_removed = try std.math.divCeil(u64, size_value, block_size);
        const keys = try self.allocator.alloc(u64, if (shrinking) self.blocks.count() else 0);
        defer self.allocator.free(keys);
        var removed_count: usize = 0;
        if (shrinking) {
            var iterator = self.blocks.keyIterator();
            while (iterator.next()) |block| {
                if (block.* < first_removed) continue;
                keys[removed_count] = block.*;
                removed_count += 1;
            }
        }
        const partial_upsert: usize = if (shrinking and size_value % block_size != 0 and
            self.blocks.contains(size_value / block_size)) 1 else 0;
        try self.pending.ensureUnusedCapacity(@intCast(removed_count + partial_upsert));
        if (shrinking and size_value % block_size != 0) {
            const block = size_value / block_size;
            if (self.blocks.get(block)) |reference| {
                const buffer = try self.allocator.alignedAlloc(u8, .fromByteUnits(block_size), block_size);
                defer self.allocator.free(buffer);
                const amount = try self.blobs.read(io, reference, buffer);
                if (amount != block_size) return error.InvalidBlobFileBlock;
                @memset(buffer[@intCast(size_value % block_size)..], 0);
                const updated = self.blobs.put(io, buffer) catch |err| {
                    self.frozen = true;
                    return err;
                };
                self.blocks.putAssumeCapacity(block, updated);
                self.pending.putAssumeCapacity(block, updated);
            }
        }
        if (shrinking) {
            for (keys[0..removed_count]) |block| {
                _ = self.blocks.remove(block);
                self.pending.putAssumeCapacity(block, null);
                self.allocated_blocks -= 1;
            }
        }
        self.logical_size = size_value;
        self.dirty = true;
    }

    pub fn prepareSnapshot(self: *State, io: Io) !Snapshot {
        try self.requireUsable();
        if (self.prepared) |snapshot| return snapshot;
        if (!self.dirty) return self.currentSnapshot();
        errdefer self.frozen = true;
        const generation = std.math.add(u64, self.generation, 1) catch return error.BlobFileGenerationExhausted;
        const mutations = try self.allocator.alloc(blob_map_store.Mutation, self.pending.count());
        defer self.allocator.free(mutations);
        var iterator = self.pending.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) mutations[index] = if (entry.value_ptr.*) |reference| .{
            .upsert = .{
                .logical_blob = entry.key_ptr.*,
                .reference = reference,
            },
        } else .{
            .remove = entry.key_ptr.*,
        };
        std.mem.sort(blob_map_store.Mutation, mutations, {}, struct {
            fn lessThan(_: void, left: blob_map_store.Mutation, right: blob_map_store.Mutation) bool {
                return left.key() < right.key();
            }
        }.lessThan);
        const scratch = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(blob_format.allocation_unit),
            blob_map.page_size,
        );
        defer self.allocator.free(scratch);
        var maps = blob_map_store.MapStore.init(self.allocator, self.blobs);
        const checkpoint = self.blobs.stagedUnits();
        var map_pages_owned = true;
        errdefer if (map_pages_owned) self.blobs.discardStaged(io, checkpoint) catch {};
        const snapshot: Snapshot = .{
            .generation = generation,
            .logical_size = self.logical_size,
            .root = try maps.applyBatchAt(
                io,
                self.root,
                self.generation,
                self.readable_units,
                generation,
                mutations,
                null,
                scratch,
            ),
        };
        const block_count = try std.math.divCeil(u64, snapshot.logical_size, block_size);
        if ((snapshot.root == null) != (self.allocated_blocks == 0) or
            (snapshot.root != null and (snapshot.root.?.first_key > snapshot.root.?.last_key or
                snapshot.root.?.last_key >= block_count)))
            return error.InvalidBlobFileSnapshot;
        self.prepared = snapshot;
        self.prepared_checkpoint = checkpoint;
        self.prepared_readable_units = self.blobs.stagedUnits();
        map_pages_owned = false;
        return snapshot;
    }

    pub fn acceptSnapshot(self: *State, snapshot: Snapshot) !void {
        const prepared = self.prepared orelse {
            if (!self.dirty and std.meta.eql(snapshot, self.currentSnapshot())) return;
            return error.BlobFileSnapshotNotPrepared;
        };
        if (!std.meta.eql(prepared, snapshot)) return error.BlobFileSnapshotMismatch;
        self.generation = snapshot.generation;
        self.root = snapshot.root;
        self.readable_units = self.prepared_readable_units.?;
        self.prepared = null;
        self.prepared_checkpoint = null;
        self.prepared_readable_units = null;
        self.dirty = false;
        self.pending.clearRetainingCapacity();
    }

    pub fn abortSnapshot(self: *State, io: Io) !void {
        const checkpoint = self.prepared_checkpoint orelse {
            std.debug.assert(self.prepared == null);
            return;
        };
        std.debug.assert(self.prepared != null);
        try self.blobs.discardStaged(io, checkpoint);
        self.prepared = null;
        self.prepared_checkpoint = null;
        self.prepared_readable_units = null;
    }

    fn currentSnapshot(self: *const State) Snapshot {
        return .{
            .generation = self.generation,
            .logical_size = self.logical_size,
            .root = self.root,
        };
    }

    fn lookupCurrent(self: *State, io: Io, key: u64) !?blob_format.BlobRef {
        if (self.pending.get(key)) |reference| return reference;
        if (self.blocks_materialized) return self.blocks.get(key);
        const root = self.root orelse return null;
        const scratch = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(blob_format.allocation_unit),
            blob_map.page_size,
        );
        defer self.allocator.free(scratch);
        var maps = blob_map_store.MapStore.init(self.allocator, self.blobs);
        const reference = try maps.lookupAt(
            io,
            root,
            self.generation,
            self.readable_units,
            key,
            scratch,
        ) orelse return null;
        reference.validate(self.blobs.header.unit_count) catch return error.InvalidBlobFileSnapshot;
        if (reference.valid_bytes != block_size or reference.endUnit() > self.readable_units)
            return error.InvalidBlobFileSnapshot;
        return reference;
    }

    fn resolveExistence(
        self: *State,
        io: Io,
        keys: []const u64,
        known: []bool,
        existed: []bool,
    ) !void {
        std.debug.assert(keys.len == known.len and keys.len == existed.len);
        if (keys.len == 0) return;
        var all_known = true;
        for (keys, 0..) |key, index| {
            if (index != 0) std.debug.assert(key == keys[0] + index);
            if (!known[index]) {
                if (self.pending.get(key)) |reference| {
                    existed[index] = reference != null;
                    known[index] = true;
                } else if (self.blocks_materialized) {
                    existed[index] = self.blocks.contains(key);
                    known[index] = true;
                }
            }
            all_known = all_known and known[index];
        }
        if (all_known or self.blocks_materialized or self.root == null) return;

        const scratch = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(blob_format.allocation_unit),
            blob_map.page_size,
        );
        defer self.allocator.free(scratch);
        var maps = blob_map_store.MapStore.init(self.allocator, self.blobs);
        var entries: [blob_device.max_batch]blob_map.LeafEntry = undefined;
        const end_key = keys[0] + keys.len;
        var first_key = keys[0];
        while (first_key < end_key) {
            const loaded = try maps.loadRangeAt(
                io,
                self.root.?,
                self.generation,
                self.readable_units,
                first_key,
                end_key,
                scratch,
                &entries,
            );
            if (loaded.end_key <= first_key) return error.InvalidBlobFileSnapshot;
            for (entries[0..loaded.count]) |entry| {
                entry.reference.validate(self.blobs.header.unit_count) catch
                    return error.InvalidBlobFileSnapshot;
                if (entry.reference.valid_bytes != block_size or
                    entry.reference.endUnit() > self.readable_units)
                    return error.InvalidBlobFileSnapshot;
                const index: usize = @intCast(entry.logical_blob - keys[0]);
                if (!known[index]) {
                    existed[index] = true;
                    known[index] = true;
                }
            }
            first_key = loaded.end_key;
        }
    }

    fn materializeCurrent(self: *State, io: Io) !void {
        if (self.blocks_materialized) return;
        var blocks = std.AutoHashMap(u64, blob_format.BlobRef).init(self.allocator);
        errdefer blocks.deinit();
        if (self.root) |root| {
            const scratch = try self.allocator.alignedAlloc(
                u8,
                .fromByteUnits(blob_format.allocation_unit),
                blob_map.page_size,
            );
            defer self.allocator.free(scratch);
            var maps = blob_map_store.MapStore.init(self.allocator, self.blobs);
            const entries = try maps.loadAllAllocAt(
                io,
                root,
                self.generation,
                self.readable_units,
                scratch,
            );
            defer self.allocator.free(entries);
            try blocks.ensureUnusedCapacity(@intCast(try std.math.add(
                usize,
                entries.len,
                self.pending.count(),
            )));
            const block_count = try std.math.divCeil(u64, self.logical_size, block_size);
            for (entries) |entry| {
                entry.reference.validate(self.blobs.header.unit_count) catch
                    return error.InvalidBlobFileSnapshot;
                if (entry.logical_blob >= block_count or entry.reference.valid_bytes != block_size or
                    entry.reference.endUnit() > self.readable_units)
                    return error.InvalidBlobFileSnapshot;
                const block = blocks.getOrPutAssumeCapacity(entry.logical_blob);
                if (block.found_existing) return error.InvalidBlobFileSnapshot;
                block.value_ptr.* = entry.reference;
            }
        } else {
            try blocks.ensureUnusedCapacity(@intCast(self.pending.count()));
        }
        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*) |reference|
                blocks.putAssumeCapacity(entry.key_ptr.*, reference)
            else
                _ = blocks.remove(entry.key_ptr.*);
        }
        if (blocks.count() != self.allocated_blocks) return error.InvalidBlobFileSnapshot;
        std.debug.assert(self.blocks.count() == 0);
        self.blocks.deinit();
        self.blocks = blocks;
        self.blocks_materialized = true;
    }

    fn requireUsable(self: *const State) !void {
        if (self.frozen) return error.BlobFileFrozen;
    }

    fn requireMutable(self: *const State) !void {
        try self.requireUsable();
        if (self.prepared != null) return error.BlobFileSnapshotPending;
    }
};

test "blob file preserves random writes sparse holes and truncate across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 32 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file",
        device_size,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var blobs_open = true;
    defer if (blobs_open) blobs.close(std.testing.io) catch {};
    var file = State.init(std.testing.allocator, &blobs);
    defer file.deinit();

    const sparse_offset = 2 * block_size + 100;
    try std.testing.expectEqual(@as(usize, 3), try file.write(std.testing.io, "abc", sparse_offset));
    try std.testing.expectEqual(@as(usize, 1), try file.write(std.testing.io, "Z", sparse_offset + 1));
    try std.testing.expectEqual(@as(u64, block_size), file.allocatedBytes());
    const expected_size = sparse_offset + 3;
    const contents = try std.testing.allocator.alloc(u8, expected_size);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(contents.len, try file.read(std.testing.io, contents, 0));
    try std.testing.expect(std.mem.allEqual(u8, contents[0..sparse_offset], 0));
    try std.testing.expectEqualStrings("aZc", contents[sparse_offset..]);

    try file.truncate(std.testing.io, sparse_offset + 2);
    try file.truncate(std.testing.io, sparse_offset + 100);
    var tail: [100]u8 = undefined;
    try std.testing.expectEqual(tail.len, try file.read(std.testing.io, &tail, sparse_offset));
    try std.testing.expectEqual(@as(u8, 'a'), tail[0]);
    try std.testing.expectEqual(@as(u8, 'Z'), tail[1]);
    try std.testing.expect(std.mem.allEqual(u8, tail[2..], 0));

    const snapshot = try file.prepareSnapshot(std.testing.io);
    try std.testing.expectError(error.BlobFileSnapshotPending, file.write(std.testing.io, "x", 0));
    try std.testing.expectError(error.BlobFileSnapshotPending, file.truncate(std.testing.io, 1));
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(snapshot);
    const committed_units = blobs.committedUnits();
    try std.testing.expect(committed_units < 16);

    file.deinit();
    try blobs.close(std.testing.io);
    blobs_open = false;
    const backing = try tmp.dir.openFile(std.testing.io, "blob-file", .{ .mode = .read_write });
    var backing_open = true;
    defer if (backing_open) backing.close(std.testing.io);
    const storage = @import("v3/storage.zig").Storage.initOwned(backing, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, blob_format.allocation_unit);
    backing_open = false;
    blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    blobs_open = true;
    file = try State.open(std.testing.allocator, std.testing.io, &blobs, snapshot);
    var reopened_tail: [100]u8 = undefined;
    try std.testing.expectEqual(reopened_tail.len, try file.read(std.testing.io, &reopened_tail, sparse_offset));
    try std.testing.expectEqualSlices(u8, &tail, &reopened_tail);
}

test "blob file replaces one block with path copy and preserves old snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-path-copy",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var file = State.init(std.testing.allocator, &blobs);
    defer file.deinit();

    const old_data: [block_size]u8 = @splat('o');
    const old_reference = try blobs.put(std.testing.io, &old_data);
    const entry_count = blob_map.max_leaf_entries * blob_map.max_internal_entries + 1;
    try file.blocks.ensureUnusedCapacity(entry_count);
    try file.pending.ensureUnusedCapacity(entry_count);
    for (0..entry_count) |key| {
        file.blocks.putAssumeCapacity(key, old_reference);
        file.pending.putAssumeCapacity(key, old_reference);
    }
    file.allocated_blocks = entry_count;
    file.logical_size = entry_count * block_size;
    file.dirty = true;
    const old_snapshot = try file.prepareSnapshot(std.testing.io);
    try std.testing.expectEqual(@as(u8, 2), old_snapshot.root.?.level);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(old_snapshot);
    file.deinit();
    file = try State.openKnownAllocated(
        std.testing.allocator,
        &blobs,
        old_snapshot,
        entry_count * block_size,
    );
    try std.testing.expect(!file.blocks_materialized);
    try std.testing.expectEqual(@as(usize, 0), file.blocks.count());

    const replaced_key = entry_count / 2;
    const new_data: [block_size]u8 = @splat('n');
    try std.testing.expectEqual(
        new_data.len,
        try file.write(std.testing.io, &new_data, replaced_key * block_size),
    );
    try std.testing.expect(!file.blocks_materialized);
    try std.testing.expectEqual(@as(u64, entry_count * block_size), file.allocatedBytes());
    var pending_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try file.read(
        std.testing.io,
        &pending_byte,
        replaced_key * block_size,
    ));
    try std.testing.expectEqual(@as(u8, 'n'), pending_byte[0]);
    const map_checkpoint = blobs.stagedUnits();
    const new_snapshot = try file.prepareSnapshot(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, old_snapshot.root.?.level + 1),
        blobs.stagedUnits() - map_checkpoint,
    );
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(new_snapshot);
    try std.testing.expect(!file.blocks_materialized);
    try std.testing.expectEqual(@as(usize, 0), file.pending.count());

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        old_snapshot,
        &byte,
        replaced_key * block_size,
    ));
    try std.testing.expectEqual(@as(u8, 'o'), byte[0]);
    try std.testing.expectEqual(@as(usize, 1), try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        new_snapshot,
        &byte,
        replaced_key * block_size,
    ));
    try std.testing.expectEqual(@as(u8, 'n'), byte[0]);
}

test "blob file lazy writes track allocation and expose pending partial blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-lazy-write",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var base = State.init(std.testing.allocator, &blobs);
    defer base.deinit();
    const original: [block_size]u8 = @splat('a');
    _ = try base.write(std.testing.io, &original, block_size);
    const snapshot = try base.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try base.acceptSnapshot(snapshot);

    var file = try State.openKnownAllocated(std.testing.allocator, &blobs, snapshot, block_size);
    defer file.deinit();
    _ = try file.write(std.testing.io, "XY", block_size + 10);
    try std.testing.expectEqual(@as(u64, block_size), file.allocatedBytes());
    _ = try file.write(std.testing.io, "hole", 3 * block_size + 20);
    try std.testing.expectEqual(@as(u64, 2 * block_size), file.allocatedBytes());
    _ = try file.write(std.testing.io, "again", 3 * block_size + 20);
    _ = try file.write(std.testing.io, "final", 3 * block_size + 20);
    try std.testing.expectEqual(@as(u64, 2 * block_size), file.allocatedBytes());

    var existing: [4]u8 = undefined;
    _ = try file.read(std.testing.io, &existing, block_size + 9);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'a', 'X', 'Y', 'a' }, &existing);
    var inserted: [7]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try file.read(std.testing.io, &inserted, 3 * block_size + 19));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 'f', 'i', 'n', 'a', 'l' }, inserted[0..6]);
    try std.testing.expect(!file.blocks_materialized);
}

test "blob file dense rewrites skip allocation lookups across device batches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-lazy-batch-rewrite",
        16 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    const block_count = blob_map.max_leaf_entries + 5;
    const data = try std.testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(block_size),
        block_count * block_size,
    );
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    var base = State.init(std.testing.allocator, &blobs);
    defer base.deinit();
    _ = try base.write(std.testing.io, data, 0);
    const snapshot = try base.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try base.acceptSnapshot(snapshot);

    var file = try State.openKnownAllocated(
        std.testing.allocator,
        &blobs,
        snapshot,
        block_count * block_size,
    );
    defer file.deinit();
    file.root.?.digest[0] ^= 1;
    @memset(data, 'b');
    try std.testing.expectEqual(data.len, try file.write(std.testing.io, data, 0));
    try std.testing.expectEqual(@as(u64, block_count * block_size), file.allocatedBytes());
    try std.testing.expect(!file.blocks_materialized);
    file.root.?.digest = snapshot.root.?.digest;
    const updated = try file.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(updated);
    var boundary: [2]u8 = undefined;
    _ = try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        updated,
        &boundary,
        blob_device.max_batch * block_size - 1,
    );
    try std.testing.expectEqualSlices(u8, "bb", &boundary);
}

test "blob file sparse rewrites batch allocation lookups across map leaves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-lazy-sparse-batch-rewrite",
        16 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    const block_count = blob_map.max_leaf_entries + 5;
    const block: [block_size]u8 = @splat('a');
    var base = State.init(std.testing.allocator, &blobs);
    defer base.deinit();
    var allocated_blocks: u64 = 0;
    for (0..block_count) |index| {
        if (index % 7 == 0) continue;
        _ = try base.write(std.testing.io, &block, index * block_size);
        allocated_blocks += 1;
    }
    const snapshot = try base.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try base.acceptSnapshot(snapshot);

    var file = try State.openKnownAllocated(
        std.testing.allocator,
        &blobs,
        snapshot,
        allocated_blocks * block_size,
    );
    defer file.deinit();
    const data = try std.testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(block_size),
        block_count * block_size,
    );
    defer std.testing.allocator.free(data);
    @memset(data, 'b');
    try std.testing.expectEqual(data.len, try file.write(std.testing.io, data, 0));
    try std.testing.expectEqual(@as(u64, block_count * block_size), file.allocatedBytes());
    try std.testing.expect(!file.blocks_materialized);
    const updated = try file.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(updated);
    var boundary: [2]u8 = undefined;
    _ = try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        updated,
        &boundary,
        blob_map.max_leaf_entries * block_size - 1,
    );
    try std.testing.expectEqualSlices(u8, "bb", &boundary);
}

test "blob file lazy empty root materializes pending writes transactionally" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-lazy-empty-root",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    const empty: Snapshot = .{ .generation = 1, .logical_size = 0, .root = null };
    var file = try State.openKnownAllocated(std.testing.allocator, &blobs, empty, 0);
    defer file.deinit();
    try file.pending.put(7, null);

    const original: [3 * block_size]u8 = @splat('o');
    _ = try file.write(std.testing.io, &original, 0);
    _ = try file.write(std.testing.io, "OVER", block_size + 8);
    try std.testing.expectEqual(@as(u64, 3 * block_size), file.allocatedBytes());
    try file.truncate(std.testing.io, block_size + 12);
    try std.testing.expect(file.blocks_materialized);
    try std.testing.expectEqual(@as(u64, 2 * block_size), file.allocatedBytes());
    try file.truncate(std.testing.io, 3 * block_size);
    _ = try file.write(std.testing.io, "new", 2 * block_size + 7);
    try std.testing.expectEqual(@as(u64, 3 * block_size), file.allocatedBytes());

    const snapshot = try file.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(snapshot);
    var tail: [12]u8 = undefined;
    try std.testing.expectEqual(tail.len, try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        snapshot,
        &tail,
        2 * block_size,
    ));
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 'n', 'e', 'w', 0, 0 },
        &tail,
    );
    var reopened = try State.open(std.testing.allocator, std.testing.io, &blobs, snapshot);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 3), reopened.blocks.count());
    try std.testing.expectEqual(@as(u64, 3 * block_size), reopened.allocatedBytes());
}

test "blob file lazy truncate materializes and prevents removed block resurrection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-lazy-truncate",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var base = State.init(std.testing.allocator, &blobs);
    defer base.deinit();
    const data: [block_size]u8 = @splat('x');
    _ = try base.write(std.testing.io, &data, 0);
    _ = try base.write(std.testing.io, &data, 2 * block_size);
    _ = try base.write(std.testing.io, &data, 4 * block_size);
    const snapshot = try base.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try base.acceptSnapshot(snapshot);

    var file = try State.openKnownAllocated(std.testing.allocator, &blobs, snapshot, 3 * block_size);
    defer file.deinit();
    try file.truncate(std.testing.io, 2 * block_size + 100);
    try std.testing.expect(file.blocks_materialized);
    try std.testing.expectEqual(@as(u64, 2 * block_size), file.allocatedBytes());
    try file.truncate(std.testing.io, 5 * block_size);
    var removed: [1]u8 = undefined;
    _ = try file.read(std.testing.io, &removed, 4 * block_size);
    try std.testing.expectEqual(@as(u8, 0), removed[0]);
    _ = try file.write(std.testing.io, "new", 4 * block_size + 10);
    try std.testing.expectEqual(@as(u64, 3 * block_size), file.allocatedBytes());
    var rewritten: [5]u8 = undefined;
    _ = try file.read(std.testing.io, &rewritten, 4 * block_size + 9);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 'n', 'e', 'w', 0 }, &rewritten);
    const updated = try file.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(updated);
    var persisted: [5]u8 = undefined;
    _ = try readSnapshot(std.testing.allocator, std.testing.io, &blobs, updated, &persisted, 4 * block_size + 9);
    try std.testing.expectEqualSlices(u8, &rewritten, &persisted);
}

test "blob file lazy open rejects inconsistent allocation and root bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-lazy-invalid",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    const empty: Snapshot = .{ .generation = 1, .logical_size = 0, .root = null };
    try std.testing.expectError(error.InvalidBlobFileSnapshot, State.openKnownAllocated(
        std.testing.allocator,
        &blobs,
        empty,
        1,
    ));
    try std.testing.expectError(error.InvalidBlobFileSnapshot, State.openKnownAllocated(
        std.testing.allocator,
        &blobs,
        empty,
        block_size,
    ));

    const root: blob_map.PageRef = .{
        .page = 0,
        .level = 0,
        .first_key = 0,
        .last_key = 0,
        .digest = @splat(0),
    };
    try std.testing.expectError(error.InvalidBlobFileSnapshot, State.openKnownAllocated(
        std.testing.allocator,
        &blobs,
        .{ .generation = 1, .logical_size = block_size, .root = root },
        0,
    ));
    try std.testing.expectError(error.InvalidBlobFileSnapshot, State.openKnownAllocated(
        std.testing.allocator,
        &blobs,
        .{ .generation = 1, .logical_size = block_size, .root = root },
        block_size,
    ));
    var invalid_range = root;
    invalid_range.first_key = 1;
    try std.testing.expectError(error.InvalidBlobFileSnapshot, State.openKnownAllocated(
        std.testing.allocator,
        &blobs,
        .{ .generation = 1, .logical_size = block_size, .root = invalid_range },
        block_size,
    ));
}

test "blob file pending mutations retain final write and truncate state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-pending",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var file = State.init(std.testing.allocator, &blobs);
    defer file.deinit();

    const full_block: [block_size]u8 = @splat('x');
    _ = try file.write(std.testing.io, &full_block, 5 * block_size);
    const base = try file.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(base);
    try std.testing.expectEqual(@as(usize, 0), file.pending.count());

    _ = try file.write(std.testing.io, "gone", 8 * block_size);
    _ = try file.write(std.testing.io, "removed", 9 * block_size);
    try file.truncate(std.testing.io, 6 * block_size);
    try file.truncate(std.testing.io, 5 * block_size + 100);
    _ = try file.write(std.testing.io, "Y", 5 * block_size + 50);
    _ = try file.write(std.testing.io, "first", 9 * block_size);
    _ = try file.write(std.testing.io, "final", 9 * block_size);
    try std.testing.expectEqual(@as(u64, 2 * block_size), file.allocatedBytes());
    try std.testing.expectEqual(@as(usize, 3), file.pending.count());

    const map_checkpoint = blobs.stagedUnits();
    _ = try file.prepareSnapshot(std.testing.io);
    const staged_after_prepare = blobs.stagedUnits();
    try std.testing.expect(staged_after_prepare > map_checkpoint);
    try file.abortSnapshot(std.testing.io);
    try std.testing.expectEqual(map_checkpoint, blobs.stagedUnits());
    try std.testing.expectEqual(@as(usize, 3), file.pending.count());
    _ = try file.prepareSnapshot(std.testing.io);
    try std.testing.expectEqual(staged_after_prepare, blobs.stagedUnits());
    try file.abortSnapshot(std.testing.io);
    try std.testing.expectEqual(map_checkpoint, blobs.stagedUnits());
    const retried = try file.prepareSnapshot(std.testing.io);
    try std.testing.expectEqual(staged_after_prepare, blobs.stagedUnits());
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(retried);
    try std.testing.expectEqual(@as(usize, 0), file.pending.count());

    var final: [5]u8 = undefined;
    try std.testing.expectEqual(final.len, try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        retried,
        &final,
        9 * block_size,
    ));
    try std.testing.expectEqualStrings("final", &final);
    var removed: [1]u8 = undefined;
    try std.testing.expectEqual(removed.len, try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        retried,
        &removed,
        8 * block_size,
    ));
    try std.testing.expectEqual(@as(u8, 0), removed[0]);
    var tail: [52]u8 = undefined;
    try std.testing.expectEqual(tail.len, try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        retried,
        &tail,
        5 * block_size + 49,
    ));
    try std.testing.expectEqual(@as(u8, 'x'), tail[0]);
    try std.testing.expectEqual(@as(u8, 'Y'), tail[1]);
    try std.testing.expect(std.mem.allEqual(u8, tail[2..51], 'x'));
    try std.testing.expectEqual(@as(u8, 0), tail[51]);

    try file.truncate(std.testing.io, 0);
    try std.testing.expectEqual(@as(u64, 0), file.allocatedBytes());
    const empty = try file.prepareSnapshot(std.testing.io);
    try std.testing.expectEqual(@as(?blob_map.PageRef, null), empty.root);
    try file.abortSnapshot(std.testing.io);
    const empty_retry = try file.prepareSnapshot(std.testing.io);
    try std.testing.expectEqual(@as(?blob_map.PageRef, null), empty_retry.root);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(empty_retry);
    try std.testing.expectEqual(@as(usize, 0), file.pending.count());
}

test "blob file freezes when a later write batch cannot read a partial block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-partial-write-failure",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var file = State.init(std.testing.allocator, &blobs);
    defer file.deinit();

    const old_data: [block_size]u8 = @splat('o');
    var invalid_reference = try blobs.put(std.testing.io, &old_data);
    invalid_reference.checksums[0] ^= 1;
    try file.blocks.put(blob_device.max_batch, invalid_reference);
    file.allocated_blocks = 1;
    file.logical_size = (blob_device.max_batch + 1) * block_size;
    const data = try std.testing.allocator.alloc(u8, blob_device.max_batch * block_size + 1);
    defer std.testing.allocator.free(data);
    @memset(data, 'n');

    try std.testing.expectError(error.BlobChecksumMismatch, file.write(std.testing.io, data, 0));
    try std.testing.expect(file.frozen);
    try std.testing.expectError(error.BlobFileFrozen, file.read(std.testing.io, data[0..1], 0));
}

test "blob file rejects accepting dirty state without a prepared snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-unprepared-accept",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var file = State.init(std.testing.allocator, &blobs);
    defer file.deinit();

    _ = try file.write(std.testing.io, "old", 0);
    const snapshot = try file.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(snapshot);
    try file.acceptSnapshot(snapshot);

    _ = try file.write(std.testing.io, "new", 0);
    try std.testing.expectError(error.BlobFileSnapshotNotPrepared, file.acceptSnapshot(snapshot));

    try file.truncate(std.testing.io, 1);
    const truncated = file.currentSnapshot();
    try std.testing.expectError(error.BlobFileSnapshotNotPrepared, file.acceptSnapshot(truncated));
}

test "blob file map capacity failure preserves checkpoints for outer rollback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-capacity",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var file = State.init(std.testing.allocator, &blobs);
    defer file.deinit();

    _ = try file.write(std.testing.io, "old", 0);
    const old_snapshot = try file.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(old_snapshot);

    const transaction_checkpoint = blobs.stagedUnits();
    _ = try file.write(std.testing.io, "new", 0);
    const map_checkpoint = blobs.stagedUnits();
    const unit_count = blobs.header.unit_count;
    blobs.header.unit_count = map_checkpoint;
    try std.testing.expectError(error.BlobStoreFull, file.prepareSnapshot(std.testing.io));
    try std.testing.expectEqual(map_checkpoint, blobs.stagedUnits());
    try std.testing.expect(file.frozen);

    blobs.header.unit_count = unit_count;
    try blobs.discardStaged(std.testing.io, transaction_checkpoint);
    try std.testing.expectEqual(transaction_checkpoint, blobs.stagedUnits());
    var contents: [3]u8 = undefined;
    try std.testing.expectEqual(contents.len, try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        old_snapshot,
        &contents,
        0,
    ));
    try std.testing.expectEqualStrings("old", &contents);
}

test "blob file snapshot reads empty sparse partial multi-block and EOF ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-snapshot-read",
        32 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};

    var output: [16]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(usize, 0), try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        .{ .generation = 1, .logical_size = 0, .root = null },
        &output,
        0,
    ));

    var file = State.init(std.testing.allocator, &blobs);
    defer file.deinit();
    try std.testing.expectEqual(@as(usize, 4), try file.write(std.testing.io, "ABCD", block_size - 2));
    try std.testing.expectEqual(@as(usize, 4), try file.write(std.testing.io, "tail", 3 * block_size + 1));
    const snapshot = try file.prepareSnapshot(std.testing.io);
    try blobs.commit(std.testing.io);
    try file.acceptSnapshot(snapshot);

    @memset(&output, 0xff);
    try std.testing.expectEqual(@as(usize, 8), try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        snapshot,
        output[0..8],
        block_size - 3,
    ));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 'A', 'B', 'C', 'D', 0, 0, 0 }, output[0..8]);

    @memset(&output, 0xff);
    try std.testing.expectEqual(output.len, try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        snapshot,
        &output,
        2 * block_size + 100,
    ));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));

    const across = try std.testing.allocator.alloc(u8, 2 * block_size + 7);
    defer std.testing.allocator.free(across);
    @memset(across, 0xff);
    try std.testing.expectEqual(across.len, try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        snapshot,
        across,
        block_size - 2,
    ));
    try std.testing.expectEqualStrings("ABCD", across[0..4]);
    try std.testing.expect(std.mem.allEqual(u8, across[4 .. 2 * block_size + 3], 0));
    try std.testing.expectEqualStrings("tail", across[2 * block_size + 3 ..]);

    @memset(&output, 0xff);
    try std.testing.expectEqual(@as(usize, 2), try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        snapshot,
        &output,
        snapshot.logical_size - 2,
    ));
    try std.testing.expectEqualStrings("il", output[0..2]);
    try std.testing.expectEqual(@as(usize, 0), try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        snapshot,
        &output,
        snapshot.logical_size,
    ));
}

test "blob file snapshot point reads preserve corruption validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-file-snapshot-corruption",
        32 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var file = State.init(std.testing.allocator, &blobs);
    defer file.deinit();
    const data: [block_size]u8 = @splat('x');
    try std.testing.expectEqual(data.len, try file.write(std.testing.io, &data, 0));
    const reference = file.blocks.get(0).?;

    var maps = blob_map_store.MapStore.init(std.testing.allocator, &blobs);
    var entries: [blob_map.max_leaf_entries + 1]blob_map.LeafEntry = undefined;
    for (&entries, 0..) |*entry, index| entry.* = .{
        .logical_blob = index,
        .reference = reference,
    };
    entries[entries.len - 1].reference.slot = blobs.header.unit_count;
    const generation: u64 = 9;
    const root = try maps.build(std.testing.io, generation, &entries);
    try blobs.commit(std.testing.io);
    const snapshot: Snapshot = .{
        .generation = generation,
        .logical_size = entries.len * block_size,
        .root = root,
    };

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        snapshot,
        &byte,
        0,
    ));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
    try std.testing.expectError(error.InvalidBlobFileSnapshot, readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        snapshot,
        &byte,
        (entries.len - 1) * block_size,
    ));

    var out_of_range = snapshot;
    out_of_range.root.?.last_key = entries.len;
    try std.testing.expectError(error.InvalidBlobFileSnapshot, readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        out_of_range,
        &byte,
        0,
    ));
    var wrong_generation = snapshot;
    wrong_generation.generation += 1;
    try std.testing.expectError(error.BlobMapReferenceMismatch, readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        wrong_generation,
        &byte,
        0,
    ));
    var wrong_digest = snapshot;
    wrong_digest.root.?.digest[0] ^= 1;
    try std.testing.expectError(error.BlobDigestMismatch, readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        wrong_digest,
        &byte,
        0,
    ));

    var bad_checksum = reference;
    bad_checksum.checksums[0] ^= 1;
    const checksum_root = try maps.build(std.testing.io, 10, &.{.{
        .logical_blob = 0,
        .reference = bad_checksum,
    }});
    try blobs.commit(std.testing.io);
    try std.testing.expectError(error.BlobChecksumMismatch, readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        .{ .generation = 10, .logical_size = block_size, .root = checksum_root },
        &byte,
        0,
    ));

    var bad_page = try blob_map.encodeLeaf(11, &.{.{
        .logical_blob = 0,
        .reference = reference,
    }});
    bad_page[blob_map.header_size + 20] = 1;
    const bad_page_slot = try blobs.putDigestOnly(std.testing.io, &bad_page);
    try blobs.commit(std.testing.io);
    try std.testing.expectError(error.InvalidBlobMapPage, readSnapshot(
        std.testing.allocator,
        std.testing.io,
        &blobs,
        .{ .generation = 11, .logical_size = block_size, .root = .{
            .page = bad_page_slot,
            .level = 0,
            .first_key = 0,
            .last_key = 0,
            .digest = blob_map.pageDigest(&bad_page),
        } },
        &byte,
        0,
    ));
}
