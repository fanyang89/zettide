const std = @import("std");
const blob_format = @import("blob_format.zig");
const blob_map = @import("blob_map.zig");
const blob_store = @import("blob_store.zig");

const Io = std.Io;

pub const MapStore = struct {
    allocator: std.mem.Allocator,
    blobs: *blob_store.Store,

    pub fn init(allocator: std.mem.Allocator, blobs: *blob_store.Store) MapStore {
        return .{ .allocator = allocator, .blobs = blobs };
    }

    pub fn build(
        self: *MapStore,
        io: Io,
        generation: u64,
        entries: []const blob_map.LeafEntry,
    ) !blob_map.PageRef {
        if (entries.len == 0) return error.EmptyBlobMap;
        for (entries[1..], 1..) |entry, index| if (entries[index - 1].logical_blob >= entry.logical_blob)
            return error.UnsortedBlobMapEntries;

        const leaf_count = try std.math.divCeil(usize, entries.len, blob_map.max_leaf_entries);
        var current = try self.allocator.alloc(blob_map.PageRef, leaf_count);
        defer self.allocator.free(current);
        var current_count: usize = 0;
        var entry_index: usize = 0;
        while (entry_index < entries.len) {
            const count = @min(entries.len - entry_index, blob_map.max_leaf_entries);
            const page = try blob_map.encodeLeaf(generation, entries[entry_index..][0..count]);
            current[current_count] = try self.writePage(io, 0, entries[entry_index].logical_blob, entries[entry_index + count - 1].logical_blob, &page);
            current_count += 1;
            entry_index += count;
        }

        var level: u8 = 1;
        while (current_count > 1) : (level += 1) {
            const parent_count = try std.math.divCeil(usize, current_count, blob_map.max_internal_entries);
            const parents = try self.allocator.alloc(blob_map.PageRef, parent_count);
            defer self.allocator.free(parents);
            var parent_index: usize = 0;
            var child_index: usize = 0;
            while (child_index < current_count) {
                const count = @min(current_count - child_index, blob_map.max_internal_entries);
                var internal: [blob_map.max_internal_entries]blob_map.InternalEntry = undefined;
                for (current[child_index..][0..count], internal[0..count]) |child, *entry| entry.* = .{
                    .first_key = child.first_key,
                    .last_key = child.last_key,
                    .child_page = child.page,
                    .child_digest = child.digest,
                };
                const page = try blob_map.encodeInternal(level, generation, internal[0..count]);
                parents[parent_index] = try self.writePage(
                    io,
                    level,
                    current[child_index].first_key,
                    current[child_index + count - 1].last_key,
                    &page,
                );
                parent_index += 1;
                child_index += count;
            }
            @memcpy(current[0..parent_count], parents);
            current_count = parent_count;
        }
        return current[0];
    }

    pub fn lookup(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        logical_blob: u64,
        scratch: []u8,
    ) !?blob_format.BlobRef {
        const boundary = self.blobs.committedUnits();
        var current = root;
        var maximum_generation = root_generation;
        var is_root = true;
        while (true) {
            const header = try self.readPage(io, current, boundary, maximum_generation, is_root, scratch);
            const page: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);
            is_root = false;
            maximum_generation = header.generation;
            if (logical_blob < current.first_key or logical_blob > current.last_key) return null;
            if (header.kind == .leaf) {
                var entries: [blob_map.max_leaf_entries]blob_map.LeafEntry = undefined;
                _ = try blob_map.decodeLeaf(page, &entries);
                var low: usize = 0;
                var high: usize = header.count;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    if (entries[middle].logical_blob < logical_blob)
                        low = middle + 1
                    else
                        high = middle;
                }
                if (low == header.count or entries[low].logical_blob != logical_blob) return null;
                return entries[low].reference;
            }

            var entries: [blob_map.max_internal_entries]blob_map.InternalEntry = undefined;
            _ = try blob_map.decodeInternal(page, &entries);
            for (entries[0..header.count]) |entry| _ = try pageReference(.{
                .page = entry.child_page,
                .level = header.level - 1,
                .first_key = entry.first_key,
                .last_key = entry.last_key,
                .digest = entry.child_digest,
            }, boundary);
            var selected: ?blob_map.InternalEntry = null;
            for (entries[0..header.count]) |entry| {
                if (logical_blob >= entry.first_key and logical_blob <= entry.last_key) {
                    selected = entry;
                    break;
                }
            }
            const child = selected orelse return null;
            current = try pageReference(.{
                .page = child.child_page,
                .level = header.level - 1,
                .first_key = child.first_key,
                .last_key = child.last_key,
                .digest = child.child_digest,
            }, boundary);
        }
    }

    /// The caller must serialize this multi-page staging operation with other writers.
    pub fn append(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        generation: u64,
        entries: []const blob_map.LeafEntry,
        scratch: []u8,
    ) !blob_map.PageRef {
        const checkpoint = self.blobs.stagedUnits();
        errdefer self.blobs.discardStaged(io, checkpoint) catch {};
        if (generation <= root_generation or entries.len == 0 or entries.len > blob_map.max_leaf_entries or
            entries[0].logical_blob <= root.last_key)
            return error.InvalidBlobMapAppend;
        for (entries[1..], 1..) |entry, index| if (entries[index - 1].logical_blob >= entry.logical_blob)
            return error.UnsortedBlobMapEntries;
        const updated = try self.appendPage(
            io,
            root,
            checkpoint,
            root_generation,
            true,
            generation,
            entries,
            scratch,
        );
        if (updated.count == 1) return updated.pages[0];
        const root_level = try growLevel(root.level);

        const children = [_]blob_map.InternalEntry{
            internalEntry(updated.pages[0]),
            internalEntry(updated.pages[1]),
        };
        const page = try blob_map.encodeInternal(root_level, generation, &children);
        return self.writePage(
            io,
            root_level,
            updated.pages[0].first_key,
            updated.pages[1].last_key,
            &page,
        );
    }

    pub fn loadAllAlloc(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        scratch: []u8,
    ) ![]blob_map.LeafEntry {
        var entries: std.ArrayList(blob_map.LeafEntry) = .empty;
        errdefer entries.deinit(self.allocator);
        try self.collectPage(
            io,
            root,
            self.blobs.committedUnits(),
            root_generation,
            true,
            scratch,
            &entries,
        );
        return entries.toOwnedSlice(self.allocator);
    }

    fn readPage(
        self: *MapStore,
        io: Io,
        reference: blob_map.PageRef,
        boundary: u64,
        maximum_generation: u64,
        is_root: bool,
        scratch: []u8,
    ) !blob_map.Header {
        if (scratch.len != blob_map.page_size) return error.InvalidBlobBuffer;
        _ = try pageReference(reference, boundary);
        try self.blobs.readDigestVerified(io, reference.page, blob_map.page_size, &reference.digest, scratch);
        const page: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);
        const header = try blob_map.decodeHeader(page);
        if (header.level != reference.level or
            header.first_key != reference.first_key or
            header.last_key != reference.last_key or
            (header.level == 0) != (header.kind == .leaf) or
            header.generation > maximum_generation or
            (is_root and header.generation != maximum_generation))
            return error.BlobMapReferenceMismatch;
        return header;
    }

    fn writePage(
        self: *MapStore,
        io: Io,
        level: u8,
        first_key: u64,
        last_key: u64,
        page: *const [blob_map.page_size]u8,
    ) !blob_map.PageRef {
        const slot = try self.blobs.putDigestOnly(io, page);
        return .{
            .page = slot,
            .level = level,
            .first_key = first_key,
            .last_key = last_key,
            .digest = blob_map.pageDigest(page),
        };
    }

    fn collectPage(
        self: *MapStore,
        io: Io,
        reference: blob_map.PageRef,
        boundary: u64,
        maximum_generation: u64,
        is_root: bool,
        scratch: []u8,
        output: *std.ArrayList(blob_map.LeafEntry),
    ) !void {
        const header = try self.readPage(io, reference, boundary, maximum_generation, is_root, scratch);
        const page: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);
        if (header.kind == .leaf) {
            var entries: [blob_map.max_leaf_entries]blob_map.LeafEntry = undefined;
            _ = try blob_map.decodeLeaf(page, &entries);
            try output.appendSlice(self.allocator, entries[0..header.count]);
            return;
        }
        var entries: [blob_map.max_internal_entries]blob_map.InternalEntry = undefined;
        _ = try blob_map.decodeInternal(page, &entries);
        for (entries[0..header.count]) |entry| try self.collectPage(
            io,
            try pageReference(.{
                .page = entry.child_page,
                .level = header.level - 1,
                .first_key = entry.first_key,
                .last_key = entry.last_key,
                .digest = entry.child_digest,
            }, boundary),
            boundary,
            header.generation,
            false,
            scratch,
            output,
        );
    }

    const UpdateResult = struct {
        pages: [2]blob_map.PageRef,
        count: u8,
    };

    fn appendPage(
        self: *MapStore,
        io: Io,
        reference: blob_map.PageRef,
        boundary: u64,
        maximum_generation: u64,
        is_root: bool,
        generation: u64,
        appended: []const blob_map.LeafEntry,
        scratch: []u8,
    ) !UpdateResult {
        const header = try self.readPage(io, reference, boundary, maximum_generation, is_root, scratch);
        const page: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);

        if (header.kind == .leaf) {
            var existing: [blob_map.max_leaf_entries]blob_map.LeafEntry = undefined;
            _ = try blob_map.decodeLeaf(page, &existing);
            var merged: [blob_map.max_leaf_entries * 2]blob_map.LeafEntry = undefined;
            @memcpy(merged[0..header.count], existing[0..header.count]);
            @memcpy(merged[header.count..][0..appended.len], appended);
            return self.writeLeafSplit(io, generation, merged[0 .. header.count + appended.len]);
        }

        var existing: [blob_map.max_internal_entries]blob_map.InternalEntry = undefined;
        _ = try blob_map.decodeInternal(page, &existing);
        for (existing[0..header.count]) |entry| _ = try pageReference(.{
            .page = entry.child_page,
            .level = header.level - 1,
            .first_key = entry.first_key,
            .last_key = entry.last_key,
            .digest = entry.child_digest,
        }, boundary);
        const last = existing[header.count - 1];
        const child = try pageReference(blob_map.PageRef{
            .page = last.child_page,
            .level = header.level - 1,
            .first_key = last.first_key,
            .last_key = last.last_key,
            .digest = last.child_digest,
        }, boundary);
        const updated_child = try self.appendPage(
            io,
            child,
            boundary,
            header.generation,
            false,
            generation,
            appended,
            scratch,
        );
        var merged: [blob_map.max_internal_entries + 1]blob_map.InternalEntry = undefined;
        @memcpy(merged[0 .. header.count - 1], existing[0 .. header.count - 1]);
        for (updated_child.pages[0..updated_child.count], header.count - 1..) |updated, index|
            merged[index] = internalEntry(updated);
        return self.writeInternalSplit(
            io,
            header.level,
            generation,
            merged[0 .. header.count - 1 + updated_child.count],
        );
    }

    fn writeLeafSplit(
        self: *MapStore,
        io: Io,
        generation: u64,
        entries: []const blob_map.LeafEntry,
    ) !UpdateResult {
        const first_count = @min(entries.len, blob_map.max_leaf_entries);
        const first_page = try blob_map.encodeLeaf(generation, entries[0..first_count]);
        var result: UpdateResult = .{
            .pages = undefined,
            .count = if (first_count == entries.len) 1 else 2,
        };
        result.pages[0] = try self.writePage(
            io,
            0,
            entries[0].logical_blob,
            entries[first_count - 1].logical_blob,
            &first_page,
        );
        if (result.count == 2) {
            const second_page = try blob_map.encodeLeaf(generation, entries[first_count..]);
            result.pages[1] = try self.writePage(
                io,
                0,
                entries[first_count].logical_blob,
                entries[entries.len - 1].logical_blob,
                &second_page,
            );
        }
        return result;
    }

    fn writeInternalSplit(
        self: *MapStore,
        io: Io,
        level: u8,
        generation: u64,
        entries: []const blob_map.InternalEntry,
    ) !UpdateResult {
        const first_count = @min(entries.len, blob_map.max_internal_entries);
        const first_page = try blob_map.encodeInternal(level, generation, entries[0..first_count]);
        var result: UpdateResult = .{
            .pages = undefined,
            .count = if (first_count == entries.len) 1 else 2,
        };
        result.pages[0] = try self.writePage(
            io,
            level,
            entries[0].first_key,
            entries[first_count - 1].last_key,
            &first_page,
        );
        if (result.count == 2) {
            const second_page = try blob_map.encodeInternal(level, generation, entries[first_count..]);
            result.pages[1] = try self.writePage(
                io,
                level,
                entries[first_count].first_key,
                entries[entries.len - 1].last_key,
                &second_page,
            );
        }
        return result;
    }
};

fn internalEntry(reference: blob_map.PageRef) blob_map.InternalEntry {
    return .{
        .first_key = reference.first_key,
        .last_key = reference.last_key,
        .child_page = reference.page,
        .child_digest = reference.digest,
    };
}

fn pageReference(reference: blob_map.PageRef, boundary: u64) !blob_map.PageRef {
    if (reference.first_key > reference.last_key) return error.BlobMapReferenceMismatch;
    const units = blob_format.allocationUnits(blob_map.page_size);
    if (reference.page > boundary or units > boundary - reference.page)
        return error.UnpublishedBlobReference;
    return reference;
}

fn growLevel(level: u8) !u8 {
    if (level == std.math.maxInt(u8)) return error.BlobMapTreeTooDeep;
    return level + 1;
}

test "blob map store builds and queries multiple levels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 16 * 1024 * 1024;
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-map-store",
        device_size,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var maps = MapStore.init(std.testing.allocator, &blobs);

    var entries: [100]blob_map.LeafEntry = undefined;
    for (&entries, 0..) |*entry, index| entry.* = .{
        .logical_blob = index * 2,
        .reference = .{
            .slot = 1000 + index,
            .valid_bytes = blob_format.blob_size,
            .checksums = @splat(@intCast(index)),
        },
    };
    const root = try maps.build(std.testing.io, 7, &entries);
    try std.testing.expectEqual(@as(u8, 1), root.level);
    try blobs.commit(std.testing.io);

    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);
    const found = (try maps.lookup(std.testing.io, root, 7, 84, scratch)).?;
    try std.testing.expectEqual(@as(u64, 1042), found.slot);
    try std.testing.expect((try maps.lookup(std.testing.io, root, 7, 85, scratch)) == null);
    try std.testing.expect((try maps.lookup(std.testing.io, root, 7, 1000, scratch)) == null);

    var appended: [40]blob_map.LeafEntry = undefined;
    for (&appended, 0..) |*entry, index| entry.* = .{
        .logical_blob = 200 + index,
        .reference = .{
            .slot = 2000 + index,
            .valid_bytes = blob_format.blob_size,
            .checksums = @splat(@intCast(index + 100)),
        },
    };
    const next_root = try maps.append(std.testing.io, root, 7, 8, &appended, scratch);
    try std.testing.expectEqual(@as(u64, 239), next_root.last_key);
    try blobs.commit(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2039), (try maps.lookup(std.testing.io, next_root, 8, 239, scratch)).?.slot);
    try std.testing.expectEqual(@as(u64, 1042), (try maps.lookup(std.testing.io, next_root, 8, 84, scratch)).?.slot);
    const all = try maps.loadAllAlloc(std.testing.io, next_root, 8, scratch);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(usize, 140), all.len);
}

test "blob map store detects root digest mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-map-digest",
        4 * 1024 * 1024,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var maps = MapStore.init(std.testing.allocator, &blobs);
    const entries = [_]blob_map.LeafEntry{.{
        .logical_blob = 0,
        .reference = .{ .slot = 1, .valid_bytes = 1, .checksums = @splat(0) },
    }};
    var root = try maps.build(std.testing.io, 1, &entries);
    try blobs.commit(std.testing.io);
    root.digest[0] ^= 1;
    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);
    try std.testing.expectError(error.BlobDigestMismatch, maps.lookup(std.testing.io, root, 1, 0, scratch));
}

test "blob map store rejects newer mixed-generation child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-map-newer-child",
        4 * 1024 * 1024,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var maps = MapStore.init(std.testing.allocator, &blobs);
    const leaf_entries = [_]blob_map.LeafEntry{testLeafEntry(4)};
    const leaf_page = try blob_map.encodeLeaf(3, &leaf_entries);
    const leaf = try maps.writePage(std.testing.io, 0, 4, 4, &leaf_page);
    const parent_entries = [_]blob_map.InternalEntry{internalEntry(leaf)};
    const parent_page = try blob_map.encodeInternal(1, 2, &parent_entries);
    const root = try maps.writePage(std.testing.io, 1, 4, 4, &parent_page);
    try blobs.commit(std.testing.io);

    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);
    try std.testing.expectError(
        error.BlobMapReferenceMismatch,
        maps.lookup(std.testing.io, root, 2, 4, scratch),
    );
    try std.testing.expectError(
        error.BlobMapReferenceMismatch,
        maps.loadAllAlloc(std.testing.io, root, 2, scratch),
    );
    const appended = [_]blob_map.LeafEntry{testLeafEntry(5)};
    const checkpoint = blobs.stagedUnits();
    try std.testing.expectError(
        error.BlobMapReferenceMismatch,
        maps.append(std.testing.io, root, 2, 4, &appended, scratch),
    );
    try std.testing.expectEqual(checkpoint, blobs.stagedUnits());
}

test "blob map store enforces committed and captured staged boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-map-boundaries",
        4 * 1024 * 1024,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var maps = MapStore.init(std.testing.allocator, &blobs);
    const entries = [_]blob_map.LeafEntry{testLeafEntry(1)};
    const root = try maps.build(std.testing.io, 1, &entries);
    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);

    try std.testing.expectError(
        error.UnpublishedBlobReference,
        maps.lookup(std.testing.io, root, 1, 1, scratch),
    );
    try std.testing.expectError(
        error.UnpublishedBlobReference,
        maps.loadAllAlloc(std.testing.io, root, 1, scratch),
    );

    var beyond = root;
    beyond.page = blobs.stagedUnits();
    const appended = [_]blob_map.LeafEntry{testLeafEntry(2)};
    const checkpoint = blobs.stagedUnits();
    try std.testing.expectError(
        error.UnpublishedBlobReference,
        maps.append(std.testing.io, beyond, 1, 2, &appended, scratch),
    );
    try std.testing.expectEqual(checkpoint, blobs.stagedUnits());

    const next = try maps.append(std.testing.io, root, 1, 2, &appended, scratch);
    try std.testing.expectEqual(@as(u64, 2), next.last_key);
}

test "blob map append rolls back only its own partial pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-map-rollback",
        4 * 1024 * 1024,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var maps = MapStore.init(std.testing.allocator, &blobs);
    var entries: [blob_map.max_leaf_entries]blob_map.LeafEntry = undefined;
    for (&entries, 0..) |*entry, key| entry.* = testLeafEntry(key);
    const root = try maps.build(std.testing.io, 1, &entries);
    const caller_checkpoint = blobs.stagedUnits();
    blobs.header.unit_count = caller_checkpoint + 1;

    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);
    const appended = [_]blob_map.LeafEntry{testLeafEntry(entries.len)};
    try std.testing.expectError(
        error.BlobStoreFull,
        maps.append(std.testing.io, root, 1, 2, &appended, scratch),
    );
    try std.testing.expectEqual(caller_checkpoint, blobs.stagedUnits());
}

test "blob map root level growth rejects u8 overflow" {
    try std.testing.expectEqual(@as(u8, 255), try growLevel(254));
    try std.testing.expectError(error.BlobMapTreeTooDeep, growLevel(255));
}

test "blob map page reference rejects max u64 without overflow" {
    const reference: blob_map.PageRef = .{
        .page = std.math.maxInt(u64),
        .level = 0,
        .first_key = 0,
        .last_key = 0,
        .digest = @splat(0),
    };
    try std.testing.expectError(error.UnpublishedBlobReference, pageReference(reference, 1));
}

fn testLeafEntry(logical_blob: u64) blob_map.LeafEntry {
    return .{
        .logical_blob = logical_blob,
        .reference = .{
            .slot = 1000 + logical_blob,
            .valid_bytes = blob_format.blob_size,
            .checksums = @splat(@truncate(logical_blob)),
        },
    };
}
