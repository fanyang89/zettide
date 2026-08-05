const std = @import("std");
const blob_format = @import("blob_format.zig");
const filesystem_format = @import("blob_filesystem_format.zig");
const metadata_map = @import("blob_metadata_map.zig");
const blob_store = @import("blob_store.zig");

const Io = std.Io;

pub const OwnedEntry = struct {
    key: []u8,
    value: []u8,

    pub fn deinit(self: OwnedEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        allocator.free(self.key);
    }

    pub fn view(self: OwnedEntry) metadata_map.LeafEntry {
        return .{ .key = self.key, .value = self.value };
    }
};

pub const Mutation = union(enum) {
    put: metadata_map.LeafEntry,
    remove: []const u8,

    pub fn key(self: Mutation) []const u8 {
        return switch (self) {
            .put => |entry| entry.key,
            .remove => |value| value,
        };
    }
};

const Node = struct {
    reference: filesystem_format.TreeRef,
    upper_key: []const u8,
};

pub const MapStore = struct {
    allocator: std.mem.Allocator,
    blobs: *blob_store.Store,

    pub fn init(allocator: std.mem.Allocator, blobs: *blob_store.Store) MapStore {
        return .{ .allocator = allocator, .blobs = blobs };
    }

    /// The caller must serialize this multi-blob staging operation with other writers.
    pub fn build(
        self: *MapStore,
        io: Io,
        generation: u64,
        entries: []const metadata_map.LeafEntry,
    ) !filesystem_format.TreeRef {
        const checkpoint = self.blobs.stagedUnits();
        errdefer self.blobs.discardStaged(io, checkpoint) catch {};
        if (generation == 0 or entries.len == 0) return error.EmptyBlobMetadataMap;
        for (entries, 0..) |entry, index| {
            if (index != 0 and std.mem.order(u8, entries[index - 1].key, entry.key) != .lt)
                return error.UnsortedBlobMetadataEntries;
        }

        var current: std.ArrayList(Node) = .empty;
        defer current.deinit(self.allocator);
        var entry_index: usize = 0;
        while (entry_index < entries.len) {
            const count = leafGroupSize(entries[entry_index..]);
            if (count == 0) return error.BlobMetadataPageFull;
            const page = try metadata_map.encodeLeaf(generation, entries[entry_index..][0..count]);
            try current.append(self.allocator, .{
                .reference = try self.writePage(io, 0, &page),
                .upper_key = entries[entry_index + count - 1].key,
            });
            entry_index += count;
        }

        var level: u8 = 1;
        while (current.items.len > 1) : (level += 1) {
            if (level == std.math.maxInt(u8)) return error.BlobMetadataTreeTooDeep;
            var parents: std.ArrayList(Node) = .empty;
            errdefer parents.deinit(self.allocator);
            var child_index: usize = 0;
            while (child_index < current.items.len) {
                const count = internalGroupSize(current.items[child_index..]);
                if (count == 0) return error.BlobMetadataPageFull;
                var children: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
                for (current.items[child_index..][0..count], children[0..count]) |child, *entry| entry.* = .{
                    .upper_key = child.upper_key,
                    .child = child.reference,
                };
                const page = try metadata_map.encodeInternal(level, generation, children[0..count]);
                try parents.append(self.allocator, .{
                    .reference = try self.writePage(io, level, &page),
                    .upper_key = current.items[child_index + count - 1].upper_key,
                });
                child_index += count;
            }
            current.deinit(self.allocator);
            current = parents;
        }
        return current.items[0].reference;
    }

    pub fn lookupAlloc(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        key: []const u8,
    ) !?[]u8 {
        _ = filesystem_format.decodeKey(key) catch return error.InvalidBlobFilesystemKey;
        const scratch = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(blob_format.allocation_unit),
            metadata_map.page_size,
        );
        defer self.allocator.free(scratch);
        var current = root;
        var expected_upper: ?[]const u8 = null;
        var upper_buffer: [filesystem_format.max_key_size]u8 = undefined;
        var is_root = true;
        var maximum_generation = root_generation;
        while (true) {
            try self.readPage(io, current, scratch);
            const page: *const [metadata_map.page_size]u8 = @ptrCast(scratch.ptr);
            const header = try validateHeader(page, current, maximum_generation, is_root);
            is_root = false;
            maximum_generation = header.generation;
            if (header.kind == .leaf) {
                var entries: [metadata_map.max_entries]metadata_map.LeafEntry = undefined;
                _ = try metadata_map.decodeLeaf(page, &entries);
                if (expected_upper) |upper| if (!std.mem.eql(u8, entries[header.count - 1].key, upper))
                    return error.BlobMetadataReferenceMismatch;
                const index = lowerBound(entries[0..header.count], key);
                if (index == header.count or !std.mem.eql(u8, entries[index].key, key)) return null;
                return try self.allocator.dupe(u8, entries[index].value);
            }

            var entries: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
            _ = try metadata_map.decodeInternal(page, &entries);
            if (expected_upper) |upper| if (!std.mem.eql(u8, entries[header.count - 1].upper_key, upper))
                return error.BlobMetadataReferenceMismatch;
            const index = internalLowerBound(entries[0..header.count], key);
            if (index == header.count) return null;
            if (entries[index].upper_key.len > upper_buffer.len) return error.InvalidBlobMetadataTree;
            @memcpy(upper_buffer[0..entries[index].upper_key.len], entries[index].upper_key);
            expected_upper = upper_buffer[0..entries[index].upper_key.len];
            current = entries[index].child;
        }
    }

    /// Applies one sorted mutation set and returns a single immutable replacement root.
    pub fn applyBatch(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        generation: u64,
        mutations: []const Mutation,
    ) !filesystem_format.TreeRef {
        if (generation <= root_generation or mutations.len == 0)
            return error.InvalidBlobMetadataMutation;
        for (mutations, 0..) |mutation, index| {
            _ = filesystem_format.decodeKey(mutation.key()) catch
                return error.InvalidBlobMetadataMutation;
            if (index != 0 and std.mem.order(u8, mutations[index - 1].key(), mutation.key()) != .lt)
                return error.InvalidBlobMetadataMutation;
        }

        const existing = try self.loadAllAlloc(io, root, root_generation);
        defer deinitEntries(self.allocator, existing);
        var merged: std.ArrayList(metadata_map.LeafEntry) = .empty;
        defer merged.deinit(self.allocator);
        const maximum_entries = std.math.add(usize, existing.len, mutations.len) catch
            return error.OutOfMemory;
        try merged.ensureTotalCapacity(self.allocator, maximum_entries);

        var existing_index: usize = 0;
        var mutation_index: usize = 0;
        while (existing_index < existing.len or mutation_index < mutations.len) {
            if (mutation_index == mutations.len) {
                merged.appendAssumeCapacity(existing[existing_index].view());
                existing_index += 1;
                continue;
            }
            if (existing_index == existing.len) {
                switch (mutations[mutation_index]) {
                    .put => |entry| merged.appendAssumeCapacity(entry),
                    .remove => return error.BlobMetadataKeyNotFound,
                }
                mutation_index += 1;
                continue;
            }

            const order = std.mem.order(u8, existing[existing_index].key, mutations[mutation_index].key());
            switch (order) {
                .lt => {
                    merged.appendAssumeCapacity(existing[existing_index].view());
                    existing_index += 1;
                },
                .eq => {
                    switch (mutations[mutation_index]) {
                        .put => |entry| merged.appendAssumeCapacity(entry),
                        .remove => {},
                    }
                    existing_index += 1;
                    mutation_index += 1;
                },
                .gt => {
                    switch (mutations[mutation_index]) {
                        .put => |entry| merged.appendAssumeCapacity(entry),
                        .remove => return error.BlobMetadataKeyNotFound,
                    }
                    mutation_index += 1;
                },
            }
        }
        if (merged.items.len == 0) return error.EmptyBlobMetadataMap;
        return self.build(io, generation, merged.items);
    }

    pub fn loadAllAlloc(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
    ) ![]OwnedEntry {
        const scratch = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(blob_format.allocation_unit),
            metadata_map.page_size,
        );
        defer self.allocator.free(scratch);
        var result: std.ArrayList(OwnedEntry) = .empty;
        errdefer {
            for (result.items) |entry| entry.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        try self.collectPage(io, root, root_generation, null, true, scratch, &result);
        return result.toOwnedSlice(self.allocator);
    }

    pub fn loadPrefixAlloc(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        prefix: []const u8,
    ) ![]OwnedEntry {
        const all = try self.loadAllAlloc(io, root, root_generation);
        var matching: usize = 0;
        for (all) |entry| if (std.mem.startsWith(u8, entry.key, prefix)) {
            matching += 1;
        };
        if (matching == all.len) return all;
        const result = self.allocator.alloc(OwnedEntry, matching) catch |err| {
            deinitEntries(self.allocator, all);
            return err;
        };
        var kept: usize = 0;
        for (all) |entry| {
            if (std.mem.startsWith(u8, entry.key, prefix)) {
                result[kept] = entry;
                kept += 1;
            } else {
                entry.deinit(self.allocator);
            }
        }
        self.allocator.free(all);
        return result;
    }

    fn collectPage(
        self: *MapStore,
        io: Io,
        reference: filesystem_format.TreeRef,
        maximum_generation: u64,
        expected_upper: ?[]const u8,
        is_root: bool,
        scratch: []u8,
        result: *std.ArrayList(OwnedEntry),
    ) !void {
        try self.readPage(io, reference, scratch);
        const page: *const [metadata_map.page_size]u8 = @ptrCast(scratch.ptr);
        const header = try validateHeader(page, reference, maximum_generation, is_root);
        if (header.kind == .leaf) {
            var entries: [metadata_map.max_entries]metadata_map.LeafEntry = undefined;
            _ = try metadata_map.decodeLeaf(page, &entries);
            if (expected_upper) |upper| if (!std.mem.eql(u8, entries[header.count - 1].key, upper))
                return error.BlobMetadataReferenceMismatch;
            for (entries[0..header.count]) |entry| {
                if (result.items.len != 0 and
                    std.mem.order(u8, result.items[result.items.len - 1].key, entry.key) != .lt)
                    return error.InvalidBlobMetadataTree;
                const key = try self.allocator.dupe(u8, entry.key);
                errdefer self.allocator.free(key);
                const value = try self.allocator.dupe(u8, entry.value);
                errdefer self.allocator.free(value);
                try result.append(self.allocator, .{ .key = key, .value = value });
            }
            return;
        }

        var entries: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
        _ = try metadata_map.decodeInternal(page, &entries);
        if (expected_upper) |upper| if (!std.mem.eql(u8, entries[header.count - 1].upper_key, upper))
            return error.BlobMetadataReferenceMismatch;
        const Child = struct {
            upper_key: []u8,
            reference: filesystem_format.TreeRef,
        };
        var children: [metadata_map.max_entries]Child = undefined;
        var child_count: usize = 0;
        defer for (children[0..child_count]) |child| self.allocator.free(child.upper_key);
        for (entries[0..header.count], children[0..header.count]) |entry, *child| {
            child.* = .{
                .upper_key = try self.allocator.dupe(u8, entry.upper_key),
                .reference = entry.child,
            };
            child_count += 1;
        }
        for (children[0..child_count]) |child| {
            try self.collectPage(
                io,
                child.reference,
                header.generation,
                child.upper_key,
                false,
                scratch,
                result,
            );
        }
    }

    fn readPage(
        self: *MapStore,
        io: Io,
        reference: filesystem_format.TreeRef,
        scratch: []u8,
    ) !void {
        if (scratch.len != metadata_map.page_size) return error.InvalidBlobBuffer;
        try self.blobs.readDigestVerified(io, reference.page, metadata_map.page_size, &reference.digest, scratch);
    }

    fn writePage(
        self: *MapStore,
        io: Io,
        level: u8,
        page: *const [metadata_map.page_size]u8,
    ) !filesystem_format.TreeRef {
        return .{
            .page = try self.blobs.putDigestOnly(io, page),
            .level = level,
            .digest = metadata_map.pageDigest(page),
        };
    }
};

pub fn deinitEntries(allocator: std.mem.Allocator, entries: []OwnedEntry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn validateHeader(
    page: *const [metadata_map.page_size]u8,
    reference: filesystem_format.TreeRef,
    maximum_generation: u64,
    is_root: bool,
) !metadata_map.Header {
    const header = try metadata_map.decodeHeader(page);
    if (header.level != reference.level or header.generation > maximum_generation or
        (is_root and header.generation != maximum_generation))
        return error.BlobMetadataReferenceMismatch;
    return header;
}

fn leafGroupSize(entries: []const metadata_map.LeafEntry) usize {
    var used: usize = metadata_map.header_size;
    var count: usize = 0;
    for (entries[0..@min(entries.len, metadata_map.max_entries)]) |entry| {
        const amount = 2 + 4 + entry.key.len + entry.value.len;
        if (amount > metadata_map.checksum_offset - used) break;
        used += amount;
        count += 1;
    }
    return count;
}

fn internalGroupSize(nodes: []const Node) usize {
    var used: usize = metadata_map.header_size;
    var count: usize = 0;
    for (nodes[0..@min(nodes.len, metadata_map.max_entries)]) |node| {
        const amount = 2 + metadata_map.internal_prefix_size + node.upper_key.len;
        if (amount > metadata_map.checksum_offset - used) break;
        used += amount;
        count += 1;
    }
    return count;
}

fn lowerBound(entries: []const metadata_map.LeafEntry, key: []const u8) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.order(u8, entries[middle].key, key) == .lt)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}

fn internalLowerBound(entries: []const metadata_map.InternalEntry, key: []const u8) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.order(u8, entries[middle].upper_key, key) == .lt)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}

test "blob metadata map builds looks up enumerates and reopens" {
    const blob_device = @import("blob_device.zig");
    const storage_api = @import("v3/storage.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 16 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "metadata-map",
        device_size,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var blobs_open = true;
    defer if (blobs_open) blobs.close(std.testing.io) catch {};

    var keys: [130][9]u8 = undefined;
    var values: [130][filesystem_format.orphan_encoded_size]u8 = undefined;
    var entries: [130]metadata_map.LeafEntry = undefined;
    for (&keys, &values, &entries, 1..) |*key, *value, *entry, inode| {
        key.* = try filesystem_format.orphanKey(inode);
        value.* = try filesystem_format.encodeOrphan(.{ .generation = 2, .kind = .file });
        entry.* = .{ .key = key, .value = value };
    }
    var maps = MapStore.init(std.testing.allocator, &blobs);
    const root = try maps.build(std.testing.io, 2, &entries);
    try std.testing.expectEqual(@as(u8, 1), root.level);
    const lookup = (try maps.lookupAlloc(std.testing.io, root, 2, &keys[64])).?;
    defer std.testing.allocator.free(lookup);
    try std.testing.expectEqualSlices(u8, &values[64], lookup);
    try std.testing.expectEqual(@as(?[]u8, null), try maps.lookupAlloc(
        std.testing.io,
        root,
        2,
        &try filesystem_format.inodeKey(1),
    ));

    const all = try maps.loadAllAlloc(std.testing.io, root, 2);
    defer deinitEntries(std.testing.allocator, all);
    try std.testing.expectEqual(entries.len, all.len);
    try std.testing.expectEqualSlices(u8, entries[129].key, all[129].key);

    const long_name = "a" ** filesystem_format.max_lookup_name_bytes;
    var deep_keys: [10][filesystem_format.max_key_size]u8 = undefined;
    var deep_values: [10][filesystem_format.max_dentry_size]u8 = undefined;
    var deep_entries: [10]metadata_map.LeafEntry = undefined;
    for (&deep_keys, &deep_values, &deep_entries, 1..) |*key, *value, *entry, parent| {
        const encoded_key = try filesystem_format.dentryKey(key, parent, long_name);
        const encoded_value = try filesystem_format.encodeDentry(value, .{
            .child_inode = parent + 20,
            .child_generation = 1,
            .kind = .file,
            .spelling = "entry",
        });
        entry.* = .{ .key = encoded_key, .value = encoded_value };
    }
    const deep_root = try maps.build(std.testing.io, 3, &deep_entries);
    try std.testing.expectEqual(@as(u8, 2), deep_root.level);
    const deep_lookup = (try maps.lookupAlloc(std.testing.io, deep_root, 3, deep_entries[5].key)).?;
    defer std.testing.allocator.free(deep_lookup);
    try std.testing.expectEqualSlices(u8, deep_entries[5].value, deep_lookup);
    const prefix = deep_entries[5].key[0..9];
    const prefixed = try maps.loadPrefixAlloc(std.testing.io, deep_root, 3, prefix);
    defer deinitEntries(std.testing.allocator, prefixed);
    try std.testing.expectEqual(@as(usize, 1), prefixed.len);
    try std.testing.expectEqualSlices(u8, deep_entries[5].key, prefixed[0].key);

    const replacement_value = try filesystem_format.encodeOrphan(.{ .generation = 4, .kind = .symlink });
    const inserted_key = try filesystem_format.orphanKey(131);
    const inserted_value = try filesystem_format.encodeOrphan(.{ .generation = 4, .kind = .fifo });
    const mutations = [_]Mutation{
        .{ .remove = &keys[0] },
        .{ .put = .{ .key = &keys[64], .value = &replacement_value } },
        .{ .put = .{ .key = &inserted_key, .value = &inserted_value } },
    };
    const updated_root = try maps.applyBatch(std.testing.io, root, 2, 4, &mutations);
    try std.testing.expectEqual(@as(?[]u8, null), try maps.lookupAlloc(std.testing.io, updated_root, 4, &keys[0]));
    const replacement = (try maps.lookupAlloc(std.testing.io, updated_root, 4, &keys[64])).?;
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqualSlices(u8, &replacement_value, replacement);
    const updated = try maps.loadAllAlloc(std.testing.io, updated_root, 4);
    defer deinitEntries(std.testing.allocator, updated);
    try std.testing.expectEqual(entries.len, updated.len);

    try blobs.commit(std.testing.io);
    try blobs.close(std.testing.io);
    blobs_open = false;
    const file = try tmp.dir.openFile(std.testing.io, "metadata-map", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = storage_api.Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, blob_format.allocation_unit);
    file_open = false;
    blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    blobs_open = true;
    maps = MapStore.init(std.testing.allocator, &blobs);
    const reopened = (try maps.lookupAlloc(std.testing.io, root, 2, &keys[0])).?;
    defer std.testing.allocator.free(reopened);
    try std.testing.expectEqualSlices(u8, &values[0], reopened);
}
