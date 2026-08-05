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

pub const State = struct {
    allocator: std.mem.Allocator,
    blobs: *blob_store.Store,
    generation: u64,
    logical_size: u64,
    root: ?blob_map.PageRef,
    blocks: std.AutoHashMap(u64, blob_format.BlobRef),
    dirty: bool = false,
    prepared: ?Snapshot = null,
    frozen: bool = false,

    pub fn init(allocator: std.mem.Allocator, blobs: *blob_store.Store) State {
        return .{
            .allocator = allocator,
            .blobs = blobs,
            .generation = 1,
            .logical_size = 0,
            .root = null,
            .blocks = .init(allocator),
        };
    }

    pub fn open(
        allocator: std.mem.Allocator,
        io: Io,
        blobs: *blob_store.Store,
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
            .blocks = .init(allocator),
        };
        errdefer result.deinit();
        const root = snapshot.root orelse return result;
        const scratch = try allocator.alignedAlloc(u8, .fromByteUnits(blob_format.allocation_unit), blob_map.page_size);
        defer allocator.free(scratch);
        var maps = blob_map_store.MapStore.init(allocator, blobs);
        const entries = try maps.loadAllAlloc(io, root, snapshot.generation, scratch);
        defer allocator.free(entries);
        try result.blocks.ensureUnusedCapacity(@intCast(entries.len));
        const block_count = try std.math.divCeil(u64, snapshot.logical_size, block_size);
        for (entries) |entry| {
            if (entry.logical_blob >= block_count or entry.reference.valid_bytes != block_size or
                entry.reference.endUnit() > blobs.committedUnits())
                return error.InvalidBlobFileSnapshot;
            try entry.reference.validate(blobs.header.unit_count);
            const block = result.blocks.getOrPutAssumeCapacity(entry.logical_blob);
            if (block.found_existing) return error.InvalidBlobFileSnapshot;
            block.value_ptr.* = entry.reference;
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        self.blocks.deinit();
        self.* = undefined;
    }

    pub fn size(self: *const State) u64 {
        return self.logical_size;
    }

    pub fn allocatedBytes(self: *const State) u64 {
        return self.blocks.count() * block_size;
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
            if (self.blocks.get(block)) |reference| {
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
        try self.blocks.ensureUnusedCapacity(@intCast(touched));

        const buffers = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(block_size),
            blob_device.max_batch * block_size,
        );
        defer self.allocator.free(buffers);
        var inputs: [blob_device.max_batch][]const u8 = undefined;
        var references: [blob_device.max_batch]blob_format.BlobRef = undefined;
        var block_indices: [blob_device.max_batch]u64 = undefined;
        var consumed: usize = 0;
        while (consumed < data.len) {
            var count: usize = 0;
            while (count < blob_device.max_batch and consumed < data.len) : (count += 1) {
                const position = offset + consumed;
                const block = position / block_size;
                const block_offset: usize = @intCast(position % block_size);
                const part = @min(data.len - consumed, block_size - block_offset);
                const buffer = buffers[count * block_size ..][0..block_size];
                if (block_offset != 0 or part != block_size) {
                    if (self.blocks.get(block)) |reference| {
                        const read_amount = try self.blobs.read(io, reference, buffer);
                        if (read_amount != block_size) return error.InvalidBlobFileBlock;
                    } else {
                        @memset(buffer, 0);
                    }
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
            for (block_indices[0..count], references[0..count]) |block, reference|
                self.blocks.putAssumeCapacity(block, reference);
        }
        self.logical_size = @max(self.logical_size, end);
        self.dirty = true;
        return data.len;
    }

    pub fn truncate(self: *State, io: Io, size_value: u64) !void {
        try self.requireMutable();
        if (size_value > std.math.maxInt(i64)) return error.FileTooLarge;
        if (size_value == self.logical_size) return;
        if (size_value < self.logical_size and size_value % block_size != 0) {
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
                try self.blocks.put(block, updated);
            }
        }
        if (size_value < self.logical_size) {
            const first_removed = try std.math.divCeil(u64, size_value, block_size);
            const keys = try self.allocator.alloc(u64, self.blocks.count());
            defer self.allocator.free(keys);
            var count: usize = 0;
            var iterator = self.blocks.keyIterator();
            while (iterator.next()) |block| {
                if (block.* < first_removed) continue;
                keys[count] = block.*;
                count += 1;
            }
            for (keys[0..count]) |block| _ = self.blocks.remove(block);
        }
        self.logical_size = size_value;
        self.dirty = true;
    }

    pub fn prepareSnapshot(self: *State, io: Io) !Snapshot {
        try self.requireUsable();
        if (self.prepared) |snapshot| return snapshot;
        if (!self.dirty) return self.currentSnapshot();
        const generation = std.math.add(u64, self.generation, 1) catch return error.BlobFileGenerationExhausted;
        const entries = try self.allocator.alloc(blob_map.LeafEntry, self.blocks.count());
        defer self.allocator.free(entries);
        var iterator = self.blocks.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) entries[index] = .{
            .logical_blob = entry.key_ptr.*,
            .reference = entry.value_ptr.*,
        };
        std.mem.sort(blob_map.LeafEntry, entries, {}, struct {
            fn lessThan(_: void, left: blob_map.LeafEntry, right: blob_map.LeafEntry) bool {
                return left.logical_blob < right.logical_blob;
            }
        }.lessThan);
        var maps = blob_map_store.MapStore.init(self.allocator, self.blobs);
        const snapshot: Snapshot = .{
            .generation = generation,
            .logical_size = self.logical_size,
            .root = if (entries.len == 0) null else try maps.build(io, generation, entries),
        };
        self.prepared = snapshot;
        return snapshot;
    }

    pub fn acceptSnapshot(self: *State, snapshot: Snapshot) !void {
        const prepared = self.prepared orelse {
            if (std.meta.eql(snapshot, self.currentSnapshot())) return;
            return error.BlobFileSnapshotNotPrepared;
        };
        if (!std.meta.eql(prepared, snapshot)) return error.BlobFileSnapshotMismatch;
        self.generation = snapshot.generation;
        self.root = snapshot.root;
        self.prepared = null;
        self.dirty = false;
    }

    pub fn abortSnapshot(self: *State) void {
        self.prepared = null;
    }

    fn currentSnapshot(self: *const State) Snapshot {
        return .{
            .generation = self.generation,
            .logical_size = self.logical_size,
            .root = self.root,
        };
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
