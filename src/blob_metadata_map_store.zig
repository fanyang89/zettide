const std = @import("std");
const blob_format = @import("blob_format.zig");
const filesystem_format = @import("blob_filesystem_format.zig");
const metadata_map = @import("blob_metadata_map.zig");
const blob_store = @import("blob_store.zig");

const Io = std.Io;

fn uninitialized(comptime T: type) T {
    // Decoders initialize every element in the count they return.
    @setRuntimeSafety(false);
    return undefined;
}

fn allocPageForOverwrite(allocator: std.mem.Allocator) ![]align(blob_format.allocation_unit) u8 {
    // readPage overwrites the complete page before decoding it.
    const alignment: std.mem.Alignment = .fromByteUnits(blob_format.allocation_unit);
    const pointer = allocator.rawAlloc(metadata_map.page_size, alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    return @alignCast(pointer[0..metadata_map.page_size]);
}

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

const RewriteContext = struct {
    allocator: std.mem.Allocator,
    keys: std.ArrayList([]u8) = .empty,

    fn deinit(self: *RewriteContext) void {
        for (self.keys.items) |key| self.allocator.free(key);
        self.keys.deinit(self.allocator);
    }

    fn ownKey(self: *RewriteContext, key: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try self.keys.append(self.allocator, owned);
        return owned;
    }
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
        return self.lookupAllocAt(io, root, root_generation, self.blobs.stagedUnits(), key);
    }

    pub fn lookupAllocAt(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        readable_units: u64,
        key: []const u8,
    ) !?[]u8 {
        _ = filesystem_format.decodeKey(key) catch return error.InvalidBlobFilesystemKey;
        const scratch = try allocPageForOverwrite(self.allocator);
        defer self.allocator.free(scratch);
        var current = root;
        var expected_upper: ?[]const u8 = null;
        var upper_buffer = uninitialized([filesystem_format.max_key_size]u8);
        var is_root = true;
        var maximum_generation = root_generation;
        while (true) {
            try self.readPage(io, current, readable_units, scratch);
            const page: *const [metadata_map.page_size]u8 = @ptrCast(scratch.ptr);
            const header = try validateHeader(page, current, maximum_generation, is_root);
            is_root = false;
            maximum_generation = header.generation;
            if (header.kind == .leaf) {
                var entries = uninitialized([metadata_map.max_entries]metadata_map.LeafEntry);
                _ = try metadata_map.decodeLeaf(page, &entries);
                if (expected_upper) |upper| if (!std.mem.eql(u8, entries[header.count - 1].key, upper))
                    return error.BlobMetadataReferenceMismatch;
                const index = lowerBound(entries[0..header.count], key);
                if (index == header.count or !std.mem.eql(u8, entries[index].key, key)) return null;
                return try self.allocator.dupe(u8, entries[index].value);
            }

            var entries = uninitialized([metadata_map.max_entries]metadata_map.InternalEntry);
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
    /// The caller must serialize this multi-page staging operation with other writers.
    pub fn applyBatch(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        generation: u64,
        mutations: []const Mutation,
    ) !filesystem_format.TreeRef {
        return self.applyBatchAt(
            io,
            root,
            root_generation,
            self.blobs.stagedUnits(),
            generation,
            mutations,
        );
    }

    /// The caller must serialize this multi-page staging operation with other writers.
    pub fn applyBatchAt(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        readable_units: u64,
        generation: u64,
        mutations: []const Mutation,
    ) !filesystem_format.TreeRef {
        const write_checkpoint = self.blobs.stagedUnits();
        errdefer self.blobs.discardStaged(io, write_checkpoint) catch {};
        if (generation <= root_generation or mutations.len == 0)
            return error.InvalidBlobMetadataMutation;
        for (mutations, 0..) |mutation, index| {
            _ = filesystem_format.decodeKey(mutation.key()) catch
                return error.InvalidBlobMetadataMutation;
            if (index != 0 and std.mem.order(u8, mutations[index - 1].key(), mutation.key()) != .lt)
                return error.InvalidBlobMetadataMutation;
        }

        const scratch = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(blob_format.allocation_unit),
            metadata_map.page_size,
        );
        defer self.allocator.free(scratch);
        var context: RewriteContext = .{ .allocator = self.allocator };
        defer context.deinit();

        var forest = try self.rewritePage(
            io,
            root,
            readable_units,
            root_generation,
            null,
            true,
            generation,
            mutations,
            scratch,
            &context,
        );
        defer forest.deinit(self.allocator);
        if (forest.items.len == 0) return error.EmptyBlobMetadataMap;

        var level = forest.items[0].reference.level;
        while (forest.items.len > 1) {
            level = try growLevel(level);
            const parents = try self.writeInternalForest(io, level, generation, forest.items);
            forest.deinit(self.allocator);
            forest = parents;
        }

        var result = forest.items[0];
        while (result.reference.level != 0) {
            const child = (try self.onlyChild(
                io,
                result,
                readable_units,
                write_checkpoint,
                generation,
                scratch,
                &context,
            )) orelse break;
            result = try self.copyNodeAtGeneration(
                io,
                child,
                readable_units,
                write_checkpoint,
                generation,
                true,
                scratch,
            );
        }
        result = try self.copyNodeAtGeneration(
            io,
            result,
            readable_units,
            write_checkpoint,
            generation,
            false,
            scratch,
        );
        return result.reference;
    }

    pub fn loadAllAlloc(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
    ) ![]OwnedEntry {
        return self.loadAllAllocAt(io, root, root_generation, self.blobs.stagedUnits());
    }

    pub fn loadAllAllocAt(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        readable_units: u64,
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
        try self.collectPage(io, root, readable_units, root_generation, null, true, scratch, &result);
        return result.toOwnedSlice(self.allocator);
    }

    pub fn loadPrefixAlloc(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        prefix: []const u8,
    ) ![]OwnedEntry {
        return self.loadPrefixAllocAt(
            io,
            root,
            root_generation,
            self.blobs.stagedUnits(),
            prefix,
        );
    }

    pub fn loadPrefixAllocAt(
        self: *MapStore,
        io: Io,
        root: filesystem_format.TreeRef,
        root_generation: u64,
        readable_units: u64,
        prefix: []const u8,
    ) ![]OwnedEntry {
        const all = try self.loadAllAllocAt(io, root, root_generation, readable_units);
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
        readable_units: u64,
        maximum_generation: u64,
        expected_upper: ?[]const u8,
        is_root: bool,
        scratch: []u8,
        result: *std.ArrayList(OwnedEntry),
    ) !void {
        try self.readPage(io, reference, readable_units, scratch);
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
                readable_units,
                header.generation,
                child.upper_key,
                false,
                scratch,
                result,
            );
        }
    }

    fn rewritePage(
        self: *MapStore,
        io: Io,
        reference: filesystem_format.TreeRef,
        boundary: u64,
        maximum_generation: u64,
        expected_upper: ?[]const u8,
        is_root: bool,
        generation: u64,
        mutations: []const Mutation,
        scratch: []u8,
        context: *RewriteContext,
    ) !std.ArrayList(Node) {
        try self.readPage(io, reference, boundary, scratch);
        const page: *const [metadata_map.page_size]u8 = @ptrCast(scratch.ptr);
        const header = try validateHeader(page, reference, maximum_generation, is_root);
        if (header.kind == .leaf) {
            var existing: [metadata_map.max_entries]metadata_map.LeafEntry = undefined;
            _ = try metadata_map.decodeLeaf(page, &existing);
            if (expected_upper) |upper| if (!std.mem.eql(u8, existing[header.count - 1].key, upper))
                return error.BlobMetadataReferenceMismatch;
            var merged: std.ArrayList(metadata_map.LeafEntry) = .empty;
            defer merged.deinit(self.allocator);
            try mergeLeafEntries(self.allocator, &merged, existing[0..header.count], mutations);
            return self.writeLeafForest(io, generation, merged.items, context);
        }

        var existing: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
        _ = try metadata_map.decodeInternal(page, &existing);
        if (expected_upper) |upper| if (!std.mem.eql(u8, existing[header.count - 1].upper_key, upper))
            return error.BlobMetadataReferenceMismatch;
        var children: [metadata_map.max_entries]Node = undefined;
        for (existing[0..header.count], children[0..header.count]) |entry, *child| {
            try validatePageReference(entry.child, boundary);
            child.* = .{
                .reference = entry.child,
                .upper_key = try context.ownKey(entry.upper_key),
            };
        }

        var rewritten_children: std.ArrayList(Node) = .empty;
        defer rewritten_children.deinit(self.allocator);
        var mutation_index: usize = 0;
        for (children[0..header.count]) |child| {
            const child_end = upperBoundMutations(mutations, mutation_index, child.upper_key);
            if (child_end == mutation_index) {
                try self.validateNode(io, child, boundary, header.generation, scratch);
                try rewritten_children.append(self.allocator, child);
            } else {
                var rewritten = try self.rewritePage(
                    io,
                    child.reference,
                    boundary,
                    header.generation,
                    child.upper_key,
                    false,
                    generation,
                    mutations[mutation_index..child_end],
                    scratch,
                    context,
                );
                defer rewritten.deinit(self.allocator);
                try rewritten_children.appendSlice(self.allocator, rewritten.items);
            }
            mutation_index = child_end;
        }
        if (mutation_index < mutations.len) {
            var suffix = try self.writePutsAtLevel(
                io,
                generation,
                mutations[mutation_index..],
                header.level - 1,
                context,
            );
            defer suffix.deinit(self.allocator);
            try rewritten_children.appendSlice(self.allocator, suffix.items);
        }
        return self.writeInternalForest(io, header.level, generation, rewritten_children.items);
    }

    fn validateNode(
        self: *MapStore,
        io: Io,
        node: Node,
        boundary: u64,
        maximum_generation: u64,
        scratch: []u8,
    ) !void {
        try self.readPage(io, node.reference, boundary, scratch);
        const page: *const [metadata_map.page_size]u8 = @ptrCast(scratch.ptr);
        const header = try validateHeader(page, node.reference, maximum_generation, false);
        if (header.kind == .leaf) {
            var entries: [metadata_map.max_entries]metadata_map.LeafEntry = undefined;
            _ = try metadata_map.decodeLeaf(page, &entries);
            if (!std.mem.eql(u8, entries[header.count - 1].key, node.upper_key))
                return error.BlobMetadataReferenceMismatch;
            return;
        }
        var entries: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
        _ = try metadata_map.decodeInternal(page, &entries);
        if (!std.mem.eql(u8, entries[header.count - 1].upper_key, node.upper_key))
            return error.BlobMetadataReferenceMismatch;
        for (entries[0..header.count]) |entry| try validatePageReference(entry.child, boundary);
    }

    fn writeLeafForest(
        self: *MapStore,
        io: Io,
        generation: u64,
        entries: []const metadata_map.LeafEntry,
        context: *RewriteContext,
    ) !std.ArrayList(Node) {
        var result: std.ArrayList(Node) = .empty;
        errdefer result.deinit(self.allocator);
        var index: usize = 0;
        while (index < entries.len) {
            const count = leafGroupSize(entries[index..]);
            if (count == 0) return error.BlobMetadataPageFull;
            const page = try metadata_map.encodeLeaf(generation, entries[index..][0..count]);
            const upper_key = try context.ownKey(entries[index + count - 1].key);
            try result.append(self.allocator, .{
                .reference = try self.writePage(io, 0, &page),
                .upper_key = upper_key,
            });
            index += count;
        }
        return result;
    }

    fn writeInternalForest(
        self: *MapStore,
        io: Io,
        level: u8,
        generation: u64,
        children: []const Node,
    ) !std.ArrayList(Node) {
        var result: std.ArrayList(Node) = .empty;
        errdefer result.deinit(self.allocator);
        var index: usize = 0;
        while (index < children.len) {
            const count = internalGroupSize(children[index..]);
            if (count == 0) return error.BlobMetadataPageFull;
            var entries: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
            for (children[index..][0..count], entries[0..count]) |child, *entry| entry.* = .{
                .upper_key = child.upper_key,
                .child = child.reference,
            };
            const page = try metadata_map.encodeInternal(level, generation, entries[0..count]);
            try result.append(self.allocator, .{
                .reference = try self.writePage(io, level, &page),
                .upper_key = children[index + count - 1].upper_key,
            });
            index += count;
        }
        return result;
    }

    fn writePutsAtLevel(
        self: *MapStore,
        io: Io,
        generation: u64,
        mutations: []const Mutation,
        target_level: u8,
        context: *RewriteContext,
    ) !std.ArrayList(Node) {
        var entries: std.ArrayList(metadata_map.LeafEntry) = .empty;
        defer entries.deinit(self.allocator);
        for (mutations) |mutation| switch (mutation) {
            .put => |entry| try entries.append(self.allocator, entry),
            .remove => return error.BlobMetadataKeyNotFound,
        };
        var result = try self.writeLeafForest(io, generation, entries.items, context);
        errdefer result.deinit(self.allocator);
        var level: u8 = 0;
        while (level < target_level) {
            level = try growLevel(level);
            const parents = try self.writeInternalForest(io, level, generation, result.items);
            result.deinit(self.allocator);
            result = parents;
        }
        return result;
    }

    fn onlyChild(
        self: *MapStore,
        io: Io,
        node: Node,
        readable_units: u64,
        write_checkpoint: u64,
        generation: u64,
        scratch: []u8,
        context: *RewriteContext,
    ) !?Node {
        const boundary = pageBoundary(
            node.reference,
            readable_units,
            write_checkpoint,
            self.blobs.stagedUnits(),
        );
        try self.readPage(io, node.reference, boundary, scratch);
        const page: *const [metadata_map.page_size]u8 = @ptrCast(scratch.ptr);
        const header = try validateHeader(page, node.reference, generation, true);
        if (header.kind != .internal) return null;
        var entries: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
        _ = try metadata_map.decodeInternal(page, &entries);
        if (!std.mem.eql(u8, entries[header.count - 1].upper_key, node.upper_key))
            return error.BlobMetadataReferenceMismatch;
        if (header.count != 1) return null;
        const child = entries[0].child;
        try validatePageReference(
            child,
            pageBoundary(child, readable_units, write_checkpoint, self.blobs.stagedUnits()),
        );
        return .{
            .reference = child,
            .upper_key = try context.ownKey(entries[0].upper_key),
        };
    }

    fn copyNodeAtGeneration(
        self: *MapStore,
        io: Io,
        node: Node,
        readable_units: u64,
        write_checkpoint: u64,
        generation: u64,
        force_copy: bool,
        scratch: []u8,
    ) !Node {
        const boundary = pageBoundary(
            node.reference,
            readable_units,
            write_checkpoint,
            self.blobs.stagedUnits(),
        );
        try self.readPage(io, node.reference, boundary, scratch);
        const source: *const [metadata_map.page_size]u8 = @ptrCast(scratch.ptr);
        const header = try validateHeader(source, node.reference, generation, false);
        const page = if (header.kind == .leaf) leaf: {
            var entries: [metadata_map.max_entries]metadata_map.LeafEntry = undefined;
            _ = try metadata_map.decodeLeaf(source, &entries);
            if (!std.mem.eql(u8, entries[header.count - 1].key, node.upper_key))
                return error.BlobMetadataReferenceMismatch;
            if (!force_copy and header.generation == generation) return node;
            break :leaf try metadata_map.encodeLeaf(generation, entries[0..header.count]);
        } else internal: {
            var entries: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
            _ = try metadata_map.decodeInternal(source, &entries);
            if (!std.mem.eql(u8, entries[header.count - 1].upper_key, node.upper_key))
                return error.BlobMetadataReferenceMismatch;
            for (entries[0..header.count]) |entry| try validatePageReference(
                entry.child,
                pageBoundary(entry.child, readable_units, write_checkpoint, self.blobs.stagedUnits()),
            );
            if (!force_copy and header.generation == generation) return node;
            break :internal try metadata_map.encodeInternal(header.level, generation, entries[0..header.count]);
        };
        return .{
            .reference = try self.writePage(io, header.level, &page),
            .upper_key = node.upper_key,
        };
    }

    fn readPage(
        self: *MapStore,
        io: Io,
        reference: filesystem_format.TreeRef,
        readable_units: u64,
        scratch: []u8,
    ) !void {
        if (scratch.len != metadata_map.page_size) return error.InvalidBlobBuffer;
        const units = blob_format.allocationUnits(metadata_map.page_size);
        if (reference.page > readable_units or units > readable_units - reference.page)
            return error.UnpublishedBlobReference;
        try self.blobs.readDigestVerified(
            io,
            reference.page,
            metadata_map.page_size,
            &reference.digest,
            scratch,
            true,
        );
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

fn upperBoundMutations(mutations: []const Mutation, start: usize, key: []const u8) usize {
    var low = start;
    var high = mutations.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.order(u8, mutations[middle].key(), key) != .gt)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}

fn mergeLeafEntries(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(metadata_map.LeafEntry),
    existing: []const metadata_map.LeafEntry,
    mutations: []const Mutation,
) !void {
    const maximum_entries = std.math.add(usize, existing.len, mutations.len) catch
        return error.OutOfMemory;
    try output.ensureTotalCapacity(allocator, maximum_entries);
    var existing_index: usize = 0;
    var mutation_index: usize = 0;
    while (existing_index < existing.len or mutation_index < mutations.len) {
        if (mutation_index == mutations.len) {
            output.appendAssumeCapacity(existing[existing_index]);
            existing_index += 1;
            continue;
        }
        if (existing_index == existing.len) {
            switch (mutations[mutation_index]) {
                .put => |entry| output.appendAssumeCapacity(entry),
                .remove => return error.BlobMetadataKeyNotFound,
            }
            mutation_index += 1;
            continue;
        }

        switch (std.mem.order(u8, existing[existing_index].key, mutations[mutation_index].key())) {
            .lt => {
                output.appendAssumeCapacity(existing[existing_index]);
                existing_index += 1;
            },
            .eq => {
                switch (mutations[mutation_index]) {
                    .put => |entry| output.appendAssumeCapacity(entry),
                    .remove => {},
                }
                existing_index += 1;
                mutation_index += 1;
            },
            .gt => {
                switch (mutations[mutation_index]) {
                    .put => |entry| output.appendAssumeCapacity(entry),
                    .remove => return error.BlobMetadataKeyNotFound,
                }
                mutation_index += 1;
            },
        }
    }
}

fn validatePageReference(reference: filesystem_format.TreeRef, boundary: u64) !void {
    const units = blob_format.allocationUnits(metadata_map.page_size);
    if (reference.page > boundary or units > boundary - reference.page)
        return error.UnpublishedBlobReference;
}

fn pageBoundary(
    reference: filesystem_format.TreeRef,
    readable_units: u64,
    write_checkpoint: u64,
    staged_units: u64,
) u64 {
    return if (reference.page < write_checkpoint) readable_units else staged_units;
}

fn growLevel(level: u8) !u8 {
    if (level == std.math.maxInt(u8)) return error.BlobMetadataTreeTooDeep;
    return level + 1;
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
    const root_readable_units = blobs.stagedUnits();
    try std.testing.expectEqual(@as(u8, 1), root.level);
    try std.testing.expectError(
        error.UnpublishedBlobReference,
        maps.lookupAllocAt(std.testing.io, root, 2, root.page, &keys[64]),
    );
    const bounded_lookup = (try maps.lookupAllocAt(
        std.testing.io,
        root,
        2,
        root_readable_units,
        &keys[64],
    )).?;
    std.testing.allocator.free(bounded_lookup);
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
    const reopened_updated = (try maps.lookupAlloc(std.testing.io, updated_root, 4, &keys[64])).?;
    defer std.testing.allocator.free(reopened_updated);
    try std.testing.expectEqualSlices(u8, &replacement_value, reopened_updated);
}

test "blob metadata map rewrites touched paths and contracts roots" {
    const blob_device = @import("blob_device.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "metadata-map-path-copy",
        16 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};

    var keys: [130][9]u8 = undefined;
    var values: [130][filesystem_format.orphan_encoded_size]u8 = undefined;
    var entries: [130]metadata_map.LeafEntry = undefined;
    for (&keys, &values, &entries, 1..) |*key, *value, *entry, inode| {
        key.* = try filesystem_format.orphanKey(inode);
        value.* = try filesystem_format.encodeOrphan(.{ .generation = 1, .kind = .file });
        entry.* = .{ .key = key, .value = value };
    }
    var maps = MapStore.init(std.testing.allocator, &blobs);
    const root = try maps.build(std.testing.io, 1, &entries);
    try std.testing.expectEqual(@as(u8, 1), root.level);
    try blobs.commit(std.testing.io);

    const scratch = try std.testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(blob_format.allocation_unit),
        metadata_map.page_size,
    );
    defer std.testing.allocator.free(scratch);
    try maps.readPage(std.testing.io, root, blobs.stagedUnits(), scratch);
    var old_children: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
    const old_header = try metadata_map.decodeInternal(@ptrCast(scratch.ptr), &old_children);
    try std.testing.expectEqual(@as(u16, 2), old_header.count);
    const untouched_child = old_children[1].child;

    const replacement_value = try filesystem_format.encodeOrphan(.{ .generation = 2, .kind = .symlink });
    const root_readable_units = blobs.stagedUnits();
    try std.testing.expectError(
        error.UnpublishedBlobReference,
        maps.applyBatchAt(
            std.testing.io,
            root,
            1,
            root.page,
            2,
            &.{.{ .put = .{ .key = &keys[0], .value = &replacement_value } }},
        ),
    );
    _ = try blobs.put(std.testing.io, "unrelated staged payload");
    const update_checkpoint = blobs.stagedUnits();
    const updated = try maps.applyBatchAt(
        std.testing.io,
        root,
        1,
        root_readable_units,
        2,
        &.{.{ .put = .{ .key = &keys[0], .value = &replacement_value } }},
    );
    const page_units = blob_format.allocationUnits(metadata_map.page_size);
    try std.testing.expectEqual(update_checkpoint + 2 * page_units, blobs.stagedUnits());
    try maps.readPage(std.testing.io, updated, blobs.stagedUnits(), scratch);
    var updated_children: [metadata_map.max_entries]metadata_map.InternalEntry = undefined;
    const updated_header = try metadata_map.decodeInternal(@ptrCast(scratch.ptr), &updated_children);
    try std.testing.expectEqual(@as(u16, 2), updated_header.count);
    try std.testing.expectEqualDeep(untouched_child, updated_children[1].child);
    const old_value = (try maps.lookupAlloc(std.testing.io, root, 1, &keys[0])).?;
    defer std.testing.allocator.free(old_value);
    try std.testing.expectEqualSlices(u8, &values[0], old_value);
    const new_value = (try maps.lookupAlloc(std.testing.io, updated, 2, &keys[0])).?;
    defer std.testing.allocator.free(new_value);
    try std.testing.expectEqualSlices(u8, &replacement_value, new_value);
    try blobs.commit(std.testing.io);

    const missing_key = try filesystem_format.orphanKey(131);
    const rollback_checkpoint = blobs.stagedUnits();
    try std.testing.expectError(
        error.BlobMetadataKeyNotFound,
        maps.applyBatch(
            std.testing.io,
            updated,
            2,
            3,
            &.{
                .{ .put = .{ .key = &keys[0], .value = &values[0] } },
                .{ .remove = &missing_key },
            },
        ),
    );
    try std.testing.expectEqual(rollback_checkpoint, blobs.stagedUnits());

    const original_unit_count = blobs.header.unit_count;
    blobs.header.unit_count = rollback_checkpoint + page_units;
    try std.testing.expectError(
        error.BlobStoreFull,
        maps.applyBatch(
            std.testing.io,
            updated,
            2,
            3,
            &.{.{ .put = .{ .key = &keys[0], .value = &values[0] } }},
        ),
    );
    blobs.header.unit_count = original_unit_count;
    try std.testing.expectEqual(rollback_checkpoint, blobs.stagedUnits());

    var removals: [128]Mutation = undefined;
    for (&removals, keys[0..128]) |*mutation, *key| mutation.* = .{ .remove = key };
    const contraction_checkpoint = blobs.stagedUnits();
    const contracted = try maps.applyBatch(std.testing.io, updated, 2, 3, &removals);
    try std.testing.expectEqual(@as(u8, 0), contracted.level);
    try std.testing.expectEqual(contraction_checkpoint + 2 * page_units, blobs.stagedUnits());
    const remaining = try maps.loadAllAlloc(std.testing.io, contracted, 3);
    defer deinitEntries(std.testing.allocator, remaining);
    try std.testing.expectEqual(@as(usize, 2), remaining.len);
    try std.testing.expectEqualSlices(u8, &keys[128], remaining[0].key);
    try std.testing.expectEqualSlices(u8, &keys[129], remaining[1].key);

    const empty_checkpoint = blobs.stagedUnits();
    try std.testing.expectError(
        error.EmptyBlobMetadataMap,
        maps.applyBatch(
            std.testing.io,
            contracted,
            3,
            4,
            &.{ .{ .remove = &keys[128] }, .{ .remove = &keys[129] } },
        ),
    );
    try std.testing.expectEqual(empty_checkpoint, blobs.stagedUnits());
}

test "blob metadata map path-copy helpers reject boundary and level overflow" {
    try std.testing.expectEqual(@as(u8, 255), try growLevel(254));
    try std.testing.expectError(error.BlobMetadataTreeTooDeep, growLevel(255));
    const reference: filesystem_format.TreeRef = .{
        .page = std.math.maxInt(u64),
        .level = 0,
        .digest = @splat(0),
    };
    try std.testing.expectError(error.UnpublishedBlobReference, validatePageReference(reference, 1));
}

test "blob metadata map rejects future generation in an untouched child" {
    const blob_device = @import("blob_device.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "metadata-map-future-child",
        8 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var maps = MapStore.init(std.testing.allocator, &blobs);

    const first_key = try filesystem_format.orphanKey(1);
    const second_key = try filesystem_format.orphanKey(2);
    const first_value = try filesystem_format.encodeOrphan(.{ .generation = 1, .kind = .file });
    const second_value = try filesystem_format.encodeOrphan(.{ .generation = 2, .kind = .file });
    const first_page = try metadata_map.encodeLeaf(1, &.{.{ .key = &first_key, .value = &first_value }});
    const first = try maps.writePage(std.testing.io, 0, &first_page);
    const future_page = try metadata_map.encodeLeaf(2, &.{.{ .key = &second_key, .value = &second_value }});
    const future = try maps.writePage(std.testing.io, 0, &future_page);
    const root_page = try metadata_map.encodeInternal(1, 1, &.{
        .{ .upper_key = &first_key, .child = first },
        .{ .upper_key = &second_key, .child = future },
    });
    const root = try maps.writePage(std.testing.io, 1, &root_page);
    const checkpoint = blobs.stagedUnits();
    const replacement = try filesystem_format.encodeOrphan(.{ .generation = 2, .kind = .symlink });
    try std.testing.expectError(
        error.BlobMetadataReferenceMismatch,
        maps.applyBatch(
            std.testing.io,
            root,
            1,
            2,
            &.{.{ .put = .{ .key = &first_key, .value = &replacement } }},
        ),
    );
    try std.testing.expectEqual(checkpoint, blobs.stagedUnits());
}

test "blob metadata map path-copy splits variable records and grows roots" {
    const blob_device = @import("blob_device.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "metadata-map-growth",
        32 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    var maps = MapStore.init(std.testing.allocator, &blobs);

    const long_name = "a" ** filesystem_format.max_lookup_name_bytes;
    var keys: [9][filesystem_format.max_key_size]u8 = undefined;
    var values: [9][filesystem_format.max_dentry_size]u8 = undefined;
    var entries: [9]metadata_map.LeafEntry = undefined;
    for (&keys, &values, &entries, 0..) |*key, *value, *entry, index| {
        const parent = 2 + index * 2;
        const encoded_key = try filesystem_format.dentryKey(key, parent, long_name);
        const encoded_value = try filesystem_format.encodeDentry(value, .{
            .child_inode = parent + 100,
            .child_generation = 1,
            .kind = .file,
            .spelling = "entry",
        });
        entry.* = .{ .key = encoded_key, .value = encoded_value };
    }
    const root = try maps.build(std.testing.io, 1, &entries);
    try std.testing.expectEqual(@as(u8, 1), root.level);
    try blobs.commit(std.testing.io);

    const parents = [_]u64{ 3, 5, 9, 11, 15, 17 };
    var inserted_keys: [parents.len][filesystem_format.max_key_size]u8 = undefined;
    var inserted_values: [parents.len][filesystem_format.max_dentry_size]u8 = undefined;
    var mutations: [parents.len]Mutation = undefined;
    for (parents, &inserted_keys, &inserted_values, &mutations) |parent, *key, *value, *mutation| {
        const encoded_key = try filesystem_format.dentryKey(key, parent, long_name);
        const encoded_value = try filesystem_format.encodeDentry(value, .{
            .child_inode = parent + 100,
            .child_generation = 2,
            .kind = .file,
            .spelling = "inserted",
        });
        mutation.* = .{ .put = .{ .key = encoded_key, .value = encoded_value } };
    }
    const grown = try maps.applyBatch(std.testing.io, root, 1, 2, &mutations);
    try std.testing.expectEqual(@as(u8, 2), grown.level);
    try blobs.commit(std.testing.io);
    const old = try maps.loadAllAlloc(std.testing.io, root, 1);
    defer deinitEntries(std.testing.allocator, old);
    const current = try maps.loadAllAlloc(std.testing.io, grown, 2);
    defer deinitEntries(std.testing.allocator, current);
    try std.testing.expectEqual(@as(usize, 9), old.len);
    try std.testing.expectEqual(@as(usize, 15), current.len);
    for (current[1..], current[0 .. current.len - 1]) |entry, previous|
        try std.testing.expect(std.mem.order(u8, previous.key, entry.key) == .lt);
}

test "blob metadata map path-copy matches a deterministic model after reopen" {
    const blob_device = @import("blob_device.zig");
    const storage_api = @import("v3/storage.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 32 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "metadata-map-model",
        device_size,
        blob_format.allocation_unit,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var blobs_open = true;
    defer if (blobs_open) blobs.close(std.testing.io) catch {};
    var maps = MapStore.init(std.testing.allocator, &blobs);

    const count = 257;
    var keys: [count][9]u8 = undefined;
    var values: [count][filesystem_format.orphan_encoded_size]u8 = undefined;
    var entries: [count]metadata_map.LeafEntry = undefined;
    var present: [count]bool = @splat(true);
    for (&keys, &values, &entries, 1..) |*key, *value, *entry, inode| {
        key.* = try filesystem_format.orphanKey(inode);
        value.* = try filesystem_format.encodeOrphan(.{ .generation = 1, .kind = .file });
        entry.* = .{ .key = key, .value = value };
    }
    var root = try maps.build(std.testing.io, 1, &entries);
    var generation: u64 = 1;
    try blobs.commit(std.testing.io);
    var random = std.Random.DefaultPrng.init(0x5eed_c0de);
    const rng = random.random();

    for (0..25) |round| {
        var mutations: [count]Mutation = undefined;
        var mutation_count: usize = 0;
        for (0..count) |index| {
            if (index != 0 and rng.uintLessThan(u8, 17) != 0) continue;
            if (index != 0 and present[index] and rng.boolean()) {
                mutations[mutation_count] = .{ .remove = &keys[index] };
                present[index] = false;
            } else {
                values[index] = try filesystem_format.encodeOrphan(.{
                    .generation = @intCast(round + 2),
                    .kind = .file,
                });
                mutations[mutation_count] = .{ .put = .{
                    .key = &keys[index],
                    .value = &values[index],
                } };
                present[index] = true;
            }
            mutation_count += 1;
        }
        generation += 1;
        root = try maps.applyBatch(
            std.testing.io,
            root,
            generation - 1,
            generation,
            mutations[0..mutation_count],
        );
        try blobs.commit(std.testing.io);
        try expectTestModel(&maps, root, generation, &keys, &values, &present);
    }

    try blobs.close(std.testing.io);
    blobs_open = false;
    const file = try tmp.dir.openFile(std.testing.io, "metadata-map-model", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = storage_api.Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(
        storage,
        0,
        device_size,
        blob_format.allocation_unit,
    );
    file_open = false;
    blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    blobs_open = true;
    maps = MapStore.init(std.testing.allocator, &blobs);
    try expectTestModel(&maps, root, generation, &keys, &values, &present);
}

fn expectTestModel(
    maps: *MapStore,
    root: filesystem_format.TreeRef,
    generation: u64,
    keys: []const [9]u8,
    values: []const [filesystem_format.orphan_encoded_size]u8,
    present: []const bool,
) !void {
    const actual = try maps.loadAllAlloc(std.testing.io, root, generation);
    defer deinitEntries(std.testing.allocator, actual);
    var actual_index: usize = 0;
    for (present, keys, values) |exists, key, value| {
        if (!exists) continue;
        try std.testing.expectEqualSlices(u8, &key, actual[actual_index].key);
        try std.testing.expectEqualSlices(u8, &value, actual[actual_index].value);
        actual_index += 1;
    }
    try std.testing.expectEqual(actual.len, actual_index);
}
