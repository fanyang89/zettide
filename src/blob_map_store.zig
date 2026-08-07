const std = @import("std");
const blob_format = @import("blob_format.zig");
const blob_map = @import("blob_map.zig");
const blob_store = @import("blob_store.zig");

const Io = std.Io;

fn uninitialized(comptime T: type) T {
    // Decoders initialize every element in the count they return.
    @setRuntimeSafety(false);
    return undefined;
}

pub const Mutation = union(enum) {
    upsert: blob_map.LeafEntry,
    remove: u64,

    pub fn key(self: Mutation) u64 {
        return switch (self) {
            .upsert => |entry| entry.logical_blob,
            .remove => |value| value,
        };
    }
};

pub const KeyRange = struct {
    first: u64,
    end: ?u64,
};

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
        return self.lookupAt(io, root, root_generation, self.blobs.committedUnits(), logical_blob, scratch);
    }

    pub fn lookupAt(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        readable_units: u64,
        logical_blob: u64,
        scratch: []u8,
    ) !?blob_format.BlobRef {
        var current = root;
        var maximum_generation = root_generation;
        var is_root = true;
        while (true) {
            const header = try self.readPage(io, current, readable_units, maximum_generation, is_root, scratch);
            const page: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);
            is_root = false;
            maximum_generation = header.generation;
            if (logical_blob < current.first_key or logical_blob > current.last_key) return null;
            if (header.kind == .leaf) {
                var entries = uninitialized([blob_map.max_leaf_entries]blob_map.LeafEntry);
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

            var entries = uninitialized([blob_map.max_internal_entries]blob_map.InternalEntry);
            _ = try blob_map.decodeInternal(page, &entries);
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
            }, readable_units);
        }
    }

    pub const LoadedRange = struct {
        end_key: u64,
        count: usize,
    };

    pub fn loadRange(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        first_key: u64,
        end_key: u64,
        scratch: []u8,
        output: []blob_map.LeafEntry,
    ) !LoadedRange {
        return self.loadRangeAt(
            io,
            root,
            root_generation,
            self.blobs.committedUnits(),
            first_key,
            end_key,
            scratch,
            output,
        );
    }

    pub fn loadRangeAt(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        readable_units: u64,
        first_key: u64,
        end_key: u64,
        scratch: []u8,
        output: []blob_map.LeafEntry,
    ) !LoadedRange {
        if (first_key >= end_key or end_key - first_key > output.len)
            return error.InvalidBlobMapRange;
        var current = root;
        var maximum_generation = root_generation;
        var is_root = true;
        while (true) {
            const header = try self.readPage(io, current, readable_units, maximum_generation, is_root, scratch);
            const page: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);
            is_root = false;
            maximum_generation = header.generation;
            if (first_key < current.first_key)
                return .{ .end_key = @min(end_key, current.first_key), .count = 0 };
            if (first_key > current.last_key)
                return .{ .end_key = end_key, .count = 0 };
            if (header.kind == .leaf) {
                var entries = uninitialized([blob_map.max_leaf_entries]blob_map.LeafEntry);
                _ = try blob_map.decodeLeaf(page, &entries);
                const leaf_end = std.math.add(u64, current.last_key, 1) catch end_key;
                const range_end = @min(end_key, leaf_end);
                var count: usize = 0;
                for (entries[0..header.count]) |entry| {
                    if (entry.logical_blob < first_key or entry.logical_blob >= range_end) continue;
                    output[count] = entry;
                    count += 1;
                }
                return .{ .end_key = range_end, .count = count };
            }

            var entries = uninitialized([blob_map.max_internal_entries]blob_map.InternalEntry);
            _ = try blob_map.decodeInternal(page, &entries);
            var next_key = end_key;
            var selected: ?blob_map.InternalEntry = null;
            for (entries[0..header.count]) |entry| {
                if (first_key >= entry.first_key and first_key <= entry.last_key) {
                    selected = entry;
                    break;
                }
                if (entry.first_key > first_key) next_key = @min(next_key, entry.first_key);
            }
            const child = selected orelse return .{ .end_key = next_key, .count = 0 };
            current = try pageReference(.{
                .page = child.child_page,
                .level = header.level - 1,
                .first_key = child.first_key,
                .last_key = child.last_key,
                .digest = child.child_digest,
            }, readable_units);
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
        return self.appendAt(io, root, root_generation, self.blobs.stagedUnits(), generation, entries, scratch);
    }

    pub fn appendAt(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        readable_units: u64,
        generation: u64,
        entries: []const blob_map.LeafEntry,
        scratch: []u8,
    ) !blob_map.PageRef {
        const write_checkpoint = self.blobs.stagedUnits();
        errdefer self.blobs.discardStaged(io, write_checkpoint) catch {};
        if (generation <= root_generation or entries.len == 0 or entries.len > blob_map.max_leaf_entries or
            entries[0].logical_blob <= root.last_key)
            return error.InvalidBlobMapAppend;
        for (entries[1..], 1..) |entry, index| if (entries[index - 1].logical_blob >= entry.logical_blob)
            return error.UnsortedBlobMapEntries;
        const updated = try self.appendPage(
            io,
            root,
            readable_units,
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

    /// The caller must serialize this multi-page staging operation with other writers.
    pub fn applyBatch(
        self: *MapStore,
        io: Io,
        root: ?blob_map.PageRef,
        root_generation: u64,
        generation: u64,
        mutations: []const Mutation,
        remove_range: ?KeyRange,
        scratch: []u8,
    ) !?blob_map.PageRef {
        return self.applyBatchAt(
            io,
            root,
            root_generation,
            self.blobs.stagedUnits(),
            generation,
            mutations,
            remove_range,
            scratch,
        );
    }

    pub fn applyBatchAt(
        self: *MapStore,
        io: Io,
        root: ?blob_map.PageRef,
        root_generation: u64,
        readable_units: u64,
        generation: u64,
        mutations: []const Mutation,
        remove_range: ?KeyRange,
        scratch: []u8,
    ) !?blob_map.PageRef {
        const write_checkpoint = self.blobs.stagedUnits();
        errdefer self.blobs.discardStaged(io, write_checkpoint) catch {};
        if (generation <= root_generation) return error.InvalidBlobMapMutation;
        if (scratch.len != blob_map.page_size) return error.InvalidBlobBuffer;
        if (remove_range) |range| if (range.end) |end| if (range.first >= end)
            return error.InvalidBlobMapRange;
        for (mutations, 0..) |mutation, index| {
            if (index != 0 and mutations[index - 1].key() >= mutation.key())
                return error.UnsortedBlobMapMutations;
            if (mutation == .upsert) {
                const reference = mutation.upsert.reference;
                try validateEntryReference(reference, self.blobs.header.unit_count, write_checkpoint);
            }
        }

        var forest = if (root) |reference|
            try self.rewritePage(
                io,
                reference,
                readable_units,
                root_generation,
                true,
                generation,
                mutations,
                remove_range,
                scratch,
            )
        else
            try self.writeUpsertsAtLevel(io, generation, mutations, 0);
        defer forest.deinit(self.allocator);
        if (forest.items.len == 0) return null;

        var level = forest.items[0].level;
        while (forest.items.len > 1) {
            level = try growLevel(level);
            const parents = try self.writeInternalForest(io, level, generation, forest.items);
            forest.deinit(self.allocator);
            forest = parents;
        }

        var result = forest.items[0];
        while (result.level != 0) {
            const child = (try self.onlyChild(
                io,
                result,
                readable_units,
                write_checkpoint,
                generation,
                scratch,
            )) orelse break;
            result = try self.copyPageAtGeneration(
                io,
                child,
                readable_units,
                write_checkpoint,
                generation,
                scratch,
            );
        }
        result = try self.ensurePageGeneration(
            io,
            result,
            readable_units,
            write_checkpoint,
            generation,
            scratch,
        );
        return result;
    }

    pub fn loadAllAlloc(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        scratch: []u8,
    ) ![]blob_map.LeafEntry {
        return self.loadAllAllocAt(io, root, root_generation, self.blobs.committedUnits(), scratch);
    }

    pub fn loadAllAllocAt(
        self: *MapStore,
        io: Io,
        root: blob_map.PageRef,
        root_generation: u64,
        readable_units: u64,
        scratch: []u8,
    ) ![]blob_map.LeafEntry {
        var entries: std.ArrayList(blob_map.LeafEntry) = .empty;
        errdefer entries.deinit(self.allocator);
        try self.collectPage(
            io,
            root,
            readable_units,
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
        try self.blobs.readDigestVerified(
            io,
            reference.page,
            blob_map.page_size,
            &reference.digest,
            scratch,
            true,
        );
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

    fn rewritePage(
        self: *MapStore,
        io: Io,
        reference: blob_map.PageRef,
        boundary: u64,
        maximum_generation: u64,
        is_root: bool,
        generation: u64,
        mutations: []const Mutation,
        remove_range: ?KeyRange,
        scratch: []u8,
    ) !std.ArrayList(blob_map.PageRef) {
        const root_header = if (is_root)
            try self.readPage(io, reference, boundary, maximum_generation, true, scratch)
        else
            null;
        if (rangeCovers(remove_range, reference) and !hasUpsert(mutations))
            return .empty;
        if (mutations.len == 0 and !rangeIntersects(remove_range, reference)) {
            var unchanged: std.ArrayList(blob_map.PageRef) = .empty;
            try unchanged.append(self.allocator, try pageReference(reference, boundary));
            return unchanged;
        }
        if (rangeCovers(remove_range, reference))
            return self.writeUpsertsAtLevel(io, generation, mutations, reference.level);

        const header = root_header orelse
            try self.readPage(io, reference, boundary, maximum_generation, false, scratch);
        const page: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);
        if (header.kind == .leaf) {
            var existing: [blob_map.max_leaf_entries]blob_map.LeafEntry = undefined;
            _ = try blob_map.decodeLeaf(page, &existing);
            var merged: std.ArrayList(blob_map.LeafEntry) = .empty;
            defer merged.deinit(self.allocator);
            try mergeLeafEntries(
                self.allocator,
                &merged,
                existing[0..header.count],
                mutations,
                remove_range,
            );
            return self.writeLeafForest(io, generation, merged.items);
        }

        var existing: [blob_map.max_internal_entries]blob_map.InternalEntry = undefined;
        _ = try blob_map.decodeInternal(page, &existing);
        var children: [blob_map.max_internal_entries]blob_map.PageRef = undefined;
        for (existing[0..header.count], children[0..header.count]) |entry, *child| child.* = try pageReference(.{
            .page = entry.child_page,
            .level = header.level - 1,
            .first_key = entry.first_key,
            .last_key = entry.last_key,
            .digest = entry.child_digest,
        }, boundary);

        var rewritten_children: std.ArrayList(blob_map.PageRef) = .empty;
        defer rewritten_children.deinit(self.allocator);
        var mutation_index: usize = 0;
        for (children[0..header.count]) |child| {
            const gap_end = lowerBoundMutations(mutations, mutation_index, child.first_key);
            try self.appendUpsertsAtLevel(
                io,
                generation,
                mutations[mutation_index..gap_end],
                header.level - 1,
                &rewritten_children,
            );
            const child_end = upperBoundMutations(mutations, gap_end, child.last_key);
            var rewritten = try self.rewritePage(
                io,
                child,
                boundary,
                header.generation,
                false,
                generation,
                mutations[gap_end..child_end],
                remove_range,
                scratch,
            );
            defer rewritten.deinit(self.allocator);
            try rewritten_children.appendSlice(self.allocator, rewritten.items);
            mutation_index = child_end;
        }
        try self.appendUpsertsAtLevel(
            io,
            generation,
            mutations[mutation_index..],
            header.level - 1,
            &rewritten_children,
        );
        return self.writeInternalForest(io, header.level, generation, rewritten_children.items);
    }

    fn writeLeafForest(
        self: *MapStore,
        io: Io,
        generation: u64,
        entries: []const blob_map.LeafEntry,
    ) !std.ArrayList(blob_map.PageRef) {
        var result: std.ArrayList(blob_map.PageRef) = .empty;
        errdefer result.deinit(self.allocator);
        var index: usize = 0;
        while (index < entries.len) {
            const count = @min(entries.len - index, blob_map.max_leaf_entries);
            const page = try blob_map.encodeLeaf(generation, entries[index..][0..count]);
            try result.append(self.allocator, try self.writePage(
                io,
                0,
                entries[index].logical_blob,
                entries[index + count - 1].logical_blob,
                &page,
            ));
            index += count;
        }
        return result;
    }

    fn writeInternalForest(
        self: *MapStore,
        io: Io,
        level: u8,
        generation: u64,
        children: []const blob_map.PageRef,
    ) !std.ArrayList(blob_map.PageRef) {
        var result: std.ArrayList(blob_map.PageRef) = .empty;
        errdefer result.deinit(self.allocator);
        var index: usize = 0;
        while (index < children.len) {
            const count = @min(children.len - index, blob_map.max_internal_entries);
            var entries: [blob_map.max_internal_entries]blob_map.InternalEntry = undefined;
            for (children[index..][0..count], entries[0..count]) |child, *entry|
                entry.* = internalEntry(child);
            const page = try blob_map.encodeInternal(level, generation, entries[0..count]);
            try result.append(self.allocator, try self.writePage(
                io,
                level,
                children[index].first_key,
                children[index + count - 1].last_key,
                &page,
            ));
            index += count;
        }
        return result;
    }

    fn writeUpsertsAtLevel(
        self: *MapStore,
        io: Io,
        generation: u64,
        mutations: []const Mutation,
        target_level: u8,
    ) !std.ArrayList(blob_map.PageRef) {
        var entries: std.ArrayList(blob_map.LeafEntry) = .empty;
        defer entries.deinit(self.allocator);
        for (mutations) |mutation| switch (mutation) {
            .upsert => |entry| try entries.append(self.allocator, entry),
            .remove => {},
        };
        var result = try self.writeLeafForest(io, generation, entries.items);
        errdefer result.deinit(self.allocator);
        var level: u8 = 0;
        while (level < target_level) {
            level += 1;
            const parents = try self.writeInternalForest(io, level, generation, result.items);
            result.deinit(self.allocator);
            result = parents;
        }
        return result;
    }

    fn appendUpsertsAtLevel(
        self: *MapStore,
        io: Io,
        generation: u64,
        mutations: []const Mutation,
        target_level: u8,
        output: *std.ArrayList(blob_map.PageRef),
    ) !void {
        if (!hasUpsert(mutations)) return;
        var pages = try self.writeUpsertsAtLevel(io, generation, mutations, target_level);
        defer pages.deinit(self.allocator);
        try output.appendSlice(self.allocator, pages.items);
    }

    fn onlyChild(
        self: *MapStore,
        io: Io,
        reference: blob_map.PageRef,
        readable_units: u64,
        write_checkpoint: u64,
        generation: u64,
        scratch: []u8,
    ) !?blob_map.PageRef {
        const boundary = pageBoundary(reference, readable_units, write_checkpoint, self.blobs.stagedUnits());
        const header = try self.readPage(io, reference, boundary, generation, true, scratch);
        if (header.kind != .internal or header.count != 1) return null;
        const page: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);
        var entries: [blob_map.max_internal_entries]blob_map.InternalEntry = undefined;
        _ = try blob_map.decodeInternal(page, &entries);
        const child: blob_map.PageRef = .{
            .page = entries[0].child_page,
            .level = header.level - 1,
            .first_key = entries[0].first_key,
            .last_key = entries[0].last_key,
            .digest = entries[0].child_digest,
        };
        return try pageReference(
            child,
            pageBoundary(child, readable_units, write_checkpoint, self.blobs.stagedUnits()),
        );
    }

    fn ensurePageGeneration(
        self: *MapStore,
        io: Io,
        reference: blob_map.PageRef,
        readable_units: u64,
        write_checkpoint: u64,
        generation: u64,
        scratch: []u8,
    ) !blob_map.PageRef {
        const source_boundary = pageBoundary(
            reference,
            readable_units,
            write_checkpoint,
            self.blobs.stagedUnits(),
        );
        const header = try self.readPage(io, reference, source_boundary, generation, false, scratch);
        if (header.generation == generation) return reference;
        return self.copyDecodedPageAtGeneration(
            io,
            header,
            readable_units,
            write_checkpoint,
            generation,
            scratch,
        );
    }

    fn copyPageAtGeneration(
        self: *MapStore,
        io: Io,
        reference: blob_map.PageRef,
        readable_units: u64,
        write_checkpoint: u64,
        generation: u64,
        scratch: []u8,
    ) !blob_map.PageRef {
        const source_boundary = pageBoundary(
            reference,
            readable_units,
            write_checkpoint,
            self.blobs.stagedUnits(),
        );
        const header = try self.readPage(io, reference, source_boundary, generation, false, scratch);
        return self.copyDecodedPageAtGeneration(
            io,
            header,
            readable_units,
            write_checkpoint,
            generation,
            scratch,
        );
    }

    fn copyDecodedPageAtGeneration(
        self: *MapStore,
        io: Io,
        header: blob_map.Header,
        readable_units: u64,
        write_checkpoint: u64,
        generation: u64,
        scratch: []u8,
    ) !blob_map.PageRef {
        const source: *const [blob_map.page_size]u8 = @ptrCast(scratch.ptr);
        const page = if (header.kind == .leaf) leaf: {
            var entries: [blob_map.max_leaf_entries]blob_map.LeafEntry = undefined;
            _ = try blob_map.decodeLeaf(source, &entries);
            break :leaf try blob_map.encodeLeaf(generation, entries[0..header.count]);
        } else internal: {
            var entries: [blob_map.max_internal_entries]blob_map.InternalEntry = undefined;
            _ = try blob_map.decodeInternal(source, &entries);
            for (entries[0..header.count]) |entry| {
                const child: blob_map.PageRef = .{
                    .page = entry.child_page,
                    .level = header.level - 1,
                    .first_key = entry.first_key,
                    .last_key = entry.last_key,
                    .digest = entry.child_digest,
                };
                _ = try pageReference(
                    child,
                    pageBoundary(child, readable_units, write_checkpoint, self.blobs.stagedUnits()),
                );
            }
            break :internal try blob_map.encodeInternal(header.level, generation, entries[0..header.count]);
        };
        return self.writePage(io, header.level, header.first_key, header.last_key, &page);
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

fn pageBoundary(
    reference: blob_map.PageRef,
    readable_units: u64,
    write_checkpoint: u64,
    staged_units: u64,
) u64 {
    return if (reference.page < write_checkpoint) readable_units else staged_units;
}

fn growLevel(level: u8) !u8 {
    if (level == std.math.maxInt(u8)) return error.BlobMapTreeTooDeep;
    return level + 1;
}

fn validateEntryReference(reference: blob_format.BlobRef, unit_count: u64, boundary: u64) !void {
    if (reference.valid_bytes == 0 or reference.valid_bytes > blob_format.blob_size or
        reference.slot > unit_count)
        return error.InvalidBlobReference;
    const units = blob_format.allocationUnits(reference.valid_bytes);
    if (units > unit_count - reference.slot) return error.InvalidBlobReference;
    if (reference.slot > boundary or units > boundary - reference.slot)
        return error.UnpublishedBlobReference;
}

fn rangeContains(range: ?KeyRange, key: u64) bool {
    const value = range orelse return false;
    return key >= value.first and (value.end == null or key < value.end.?);
}

fn rangeIntersects(range: ?KeyRange, reference: blob_map.PageRef) bool {
    const value = range orelse return false;
    return value.first <= reference.last_key and (value.end == null or value.end.? > reference.first_key);
}

fn rangeCovers(range: ?KeyRange, reference: blob_map.PageRef) bool {
    const value = range orelse return false;
    return value.first <= reference.first_key and (value.end == null or value.end.? > reference.last_key);
}

fn hasUpsert(mutations: []const Mutation) bool {
    for (mutations) |mutation| if (mutation == .upsert) return true;
    return false;
}

fn lowerBoundMutations(mutations: []const Mutation, start: usize, key: u64) usize {
    var low = start;
    var high = mutations.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (mutations[middle].key() < key)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}

fn upperBoundMutations(mutations: []const Mutation, start: usize, key: u64) usize {
    var low = start;
    var high = mutations.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (mutations[middle].key() <= key)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}

fn mergeLeafEntries(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(blob_map.LeafEntry),
    existing: []const blob_map.LeafEntry,
    mutations: []const Mutation,
    remove_range: ?KeyRange,
) !void {
    try output.ensureTotalCapacity(allocator, try std.math.add(usize, existing.len, mutations.len));
    var existing_index: usize = 0;
    var mutation_index: usize = 0;
    while (existing_index < existing.len or mutation_index < mutations.len) {
        while (existing_index < existing.len and
            rangeContains(remove_range, existing[existing_index].logical_blob))
            existing_index += 1;
        if (existing_index == existing.len) {
            while (mutation_index < mutations.len) : (mutation_index += 1) switch (mutations[mutation_index]) {
                .upsert => |entry| output.appendAssumeCapacity(entry),
                .remove => {},
            };
            break;
        }
        if (mutation_index == mutations.len) {
            output.appendAssumeCapacity(existing[existing_index]);
            existing_index += 1;
            continue;
        }

        const existing_key = existing[existing_index].logical_blob;
        const mutation_key = mutations[mutation_index].key();
        if (existing_key < mutation_key) {
            output.appendAssumeCapacity(existing[existing_index]);
            existing_index += 1;
        } else if (existing_key > mutation_key) {
            switch (mutations[mutation_index]) {
                .upsert => |entry| output.appendAssumeCapacity(entry),
                .remove => {},
            }
            mutation_index += 1;
        } else {
            switch (mutations[mutation_index]) {
                .upsert => |entry| output.appendAssumeCapacity(entry),
                .remove => {},
            }
            existing_index += 1;
            mutation_index += 1;
        }
    }
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
    const root_readable_units = blobs.stagedUnits();
    try std.testing.expectEqual(@as(u8, 1), root.level);
    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);
    try std.testing.expectError(
        error.UnpublishedBlobReference,
        maps.lookupAt(std.testing.io, root, 7, root.page, 84, scratch),
    );
    try std.testing.expectEqual(
        @as(u64, 1042),
        (try maps.lookupAt(std.testing.io, root, 7, root_readable_units, 84, scratch)).?.slot,
    );
    try blobs.commit(std.testing.io);

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
    try std.testing.expectError(
        error.BlobMapReferenceMismatch,
        maps.applyBatch(std.testing.io, root, 2, 4, &.{.{ .remove = 4 }}, null, scratch),
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
    try std.testing.expectError(
        error.UnpublishedBlobReference,
        maps.applyBatch(std.testing.io, beyond, 1, 2, &.{.{ .remove = 1 }}, null, scratch),
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

test "blob map batch applies sparse mutations ranges and root contraction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-map-batch",
        8 * 1024 * 1024,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    const data = try blobs.put(std.testing.io, "entry");
    var maps = MapStore.init(std.testing.allocator, &blobs);
    var entries: [91]blob_map.LeafEntry = undefined;
    for (&entries, 0..) |*entry, key| entry.* = testStoredEntry(key, data, 1);
    const root = try maps.build(std.testing.io, 1, &entries);
    const root_readable_units = blobs.stagedUnits();
    _ = try blobs.put(std.testing.io, "unrelated staged payload");
    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);

    const mutations = [_]Mutation{
        .{ .upsert = testStoredEntry(0, data, 9) },
        .{ .upsert = testStoredEntry(3, data, 3) },
        .{ .remove = 5 },
        .{ .upsert = testStoredEntry(40, data, 4) },
        .{ .upsert = testStoredEntry(100, data, 5) },
        .{ .remove = 200 },
    };
    const ranged = (try maps.applyBatchAt(
        std.testing.io,
        root,
        1,
        root_readable_units,
        2,
        &mutations,
        .{ .first = 2, .end = 90 },
        scratch,
    )).?;
    try blobs.commit(std.testing.io);
    const all = try maps.loadAllAlloc(std.testing.io, ranged, 2, scratch);
    defer std.testing.allocator.free(all);
    const expected_keys = [_]u64{ 0, 1, 3, 40, 90, 100 };
    try std.testing.expectEqual(expected_keys.len, all.len);
    for (all, expected_keys) |entry, key| try std.testing.expectEqual(key, entry.logical_blob);
    try std.testing.expectEqual(@as(u32, 9), all[0].reference.checksums[0]);
    try std.testing.expectEqual(@as(u32, 4), all[3].reference.checksums[0]);

    const suffix = (try maps.applyBatch(
        std.testing.io,
        ranged,
        2,
        3,
        &.{.{ .upsert = testStoredEntry(100, data, 6) }},
        .{ .first = 90, .end = null },
        scratch,
    )).?;
    try blobs.commit(std.testing.io);
    const suffix_entries = try maps.loadAllAlloc(std.testing.io, suffix, 3, scratch);
    defer std.testing.allocator.free(suffix_entries);
    try std.testing.expectEqual(@as(usize, 5), suffix_entries.len);
    try std.testing.expectEqual(@as(u64, 100), suffix_entries[4].logical_blob);
    try std.testing.expectEqual(@as(u32, 6), suffix_entries[4].reference.checksums[0]);

    const contracted = (try maps.applyBatch(
        std.testing.io,
        root,
        1,
        4,
        &.{},
        .{ .first = 0, .end = 90 },
        scratch,
    )).?;
    try blobs.commit(std.testing.io);
    try std.testing.expectEqual(@as(u8, 0), contracted.level);
    try std.testing.expectEqual(@as(u64, 90), contracted.first_key);
    const no_op = (try maps.applyBatch(std.testing.io, contracted, 4, 5, &.{.{ .remove = 50 }}, null, scratch)).?;
    try blobs.commit(std.testing.io);
    const no_op_header = try maps.readPage(std.testing.io, no_op, blobs.stagedUnits(), 5, true, scratch);
    try std.testing.expectEqual(@as(u64, 5), no_op_header.generation);
    const no_op_entries = try maps.loadAllAlloc(std.testing.io, no_op, 5, scratch);
    defer std.testing.allocator.free(no_op_entries);
    try std.testing.expectEqual(@as(u64, 90), no_op_entries[0].logical_blob);

    const removed = try maps.applyBatch(
        std.testing.io,
        no_op,
        5,
        6,
        &.{},
        .{ .first = 0, .end = null },
        scratch,
    );
    try std.testing.expectEqual(@as(?blob_map.PageRef, null), removed);
    const sparse = (try maps.applyBatch(
        std.testing.io,
        null,
        6,
        7,
        &.{
            .{ .upsert = testStoredEntry(7, data, 7) },
            .{ .upsert = testStoredEntry(700, data, 8) },
        },
        null,
        scratch,
    )).?;
    try std.testing.expectEqual(@as(u64, 7), sparse.first_key);
    try std.testing.expectEqual(@as(u64, 700), sparse.last_key);
}

test "blob map batch splits leaves grows roots and preserves old generations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-map-growth",
        32 * 1024 * 1024,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    const data = try blobs.put(std.testing.io, "entry");
    var maps = MapStore.init(std.testing.allocator, &blobs);
    const count = blob_map.max_leaf_entries * blob_map.max_internal_entries;
    const entries = try std.testing.allocator.alloc(blob_map.LeafEntry, count);
    defer std.testing.allocator.free(entries);
    const mutations = try std.testing.allocator.alloc(Mutation, count);
    defer std.testing.allocator.free(mutations);
    for (entries, mutations, 0..) |*entry, *mutation, index| {
        entry.* = testStoredEntry(index * 2, data, 1);
        mutation.* = .{ .upsert = testStoredEntry(index * 2 + 1, data, 2) };
    }
    const root = try maps.build(std.testing.io, 10, entries);
    try std.testing.expectEqual(@as(u8, 1), root.level);
    try blobs.commit(std.testing.io);
    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);
    const next = (try maps.applyBatch(std.testing.io, root, 10, 11, mutations, null, scratch)).?;
    try std.testing.expectEqual(@as(u8, 2), next.level);
    try blobs.commit(std.testing.io);
    const old = try maps.loadAllAlloc(std.testing.io, root, 10, scratch);
    defer std.testing.allocator.free(old);
    const current = try maps.loadAllAlloc(std.testing.io, next, 11, scratch);
    defer std.testing.allocator.free(current);
    try std.testing.expectEqual(count, old.len);
    try std.testing.expectEqual(count * 2, current.len);
    for (current, 0..) |entry, key| try std.testing.expectEqual(@as(u64, @intCast(key)), entry.logical_blob);

    const mixed = (try maps.applyBatch(
        std.testing.io,
        next,
        11,
        12,
        &.{.{ .upsert = testStoredEntry(1, data, 12) }},
        null,
        scratch,
    )).?;
    try blobs.commit(std.testing.io);
    try std.testing.expectEqual(@as(u32, 12), (try maps.lookup(std.testing.io, mixed, 12, 1, scratch)).?.checksums[0]);
    try std.testing.expectEqual(@as(u32, 2), (try maps.lookup(std.testing.io, next, 11, 1, scratch)).?.checksums[0]);
}

test "blob map batch validates mutations boundaries and rolls back its pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-map-batch-errors",
        8 * 1024 * 1024,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    defer blobs.close(std.testing.io) catch {};
    const data = try blobs.put(std.testing.io, "entry");
    var maps = MapStore.init(std.testing.allocator, &blobs);
    var entries: [blob_map.max_leaf_entries]blob_map.LeafEntry = undefined;
    for (&entries, 0..) |*entry, key| entry.* = testStoredEntry(key * 2, data, 1);
    const root = try maps.build(std.testing.io, 2, &entries);
    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);

    try std.testing.expectError(
        error.InvalidBlobMapMutation,
        maps.applyBatch(std.testing.io, root, 2, 2, &.{}, null, scratch),
    );
    try std.testing.expectError(
        error.BlobMapReferenceMismatch,
        maps.applyBatch(std.testing.io, root, 1, 3, &.{.{ .remove = 1 }}, null, scratch),
    );
    try std.testing.expectError(
        error.BlobMapReferenceMismatch,
        maps.applyBatch(
            std.testing.io,
            root,
            1,
            3,
            &.{},
            .{ .first = 0, .end = null },
            scratch,
        ),
    );
    try std.testing.expectError(
        error.InvalidBlobBuffer,
        maps.applyBatch(std.testing.io, root, 2, 3, &.{}, null, scratch[0 .. scratch.len - 1]),
    );
    try std.testing.expectError(
        error.InvalidBlobMapRange,
        maps.applyBatch(std.testing.io, root, 2, 3, &.{}, .{ .first = 9, .end = 9 }, scratch),
    );
    const unsorted = [_]Mutation{ .{ .remove = 4 }, .{ .remove = 3 } };
    try std.testing.expectError(
        error.UnsortedBlobMapMutations,
        maps.applyBatch(std.testing.io, root, 2, 3, &unsorted, null, scratch),
    );
    const duplicate = [_]Mutation{ .{ .remove = 4 }, .{ .upsert = testStoredEntry(4, data, 2) } };
    try std.testing.expectError(
        error.UnsortedBlobMapMutations,
        maps.applyBatch(std.testing.io, root, 2, 3, &duplicate, null, scratch),
    );
    var invalid = testStoredEntry(1, data, 1);
    invalid.reference.valid_bytes = 0;
    try std.testing.expectError(
        error.InvalidBlobReference,
        maps.applyBatch(std.testing.io, root, 2, 3, &.{.{ .upsert = invalid }}, null, scratch),
    );
    var unpublished = testStoredEntry(1, data, 1);
    unpublished.reference.slot = blobs.stagedUnits();
    try std.testing.expectError(
        error.UnpublishedBlobReference,
        maps.applyBatch(std.testing.io, root, 2, 3, &.{.{ .upsert = unpublished }}, null, scratch),
    );

    const caller_checkpoint = blobs.stagedUnits();
    blobs.header.unit_count = caller_checkpoint + 1;
    const insertions = [_]Mutation{
        .{ .upsert = testStoredEntry(1, data, 2) },
        .{ .upsert = testStoredEntry(3, data, 2) },
    };
    try std.testing.expectError(
        error.BlobStoreFull,
        maps.applyBatch(std.testing.io, root, 2, 3, &insertions, null, scratch),
    );
    try std.testing.expectEqual(caller_checkpoint, blobs.stagedUnits());
}

test "blob map batch deterministic generations match model after reopen" {
    const blob_device = @import("blob_device.zig");
    const storage_api = @import("v3/storage.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 32 * 1024 * 1024;
    const device = try blob_device.Device.createFile(std.testing.io, tmp.dir, "blob-map-model", device_size, 4096);
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var blobs_open = true;
    defer if (blobs_open) blobs.close(std.testing.io) catch {};
    const data = try blobs.put(std.testing.io, "entry");
    var maps = MapStore.init(std.testing.allocator, &blobs);
    const scratch = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
    defer std.testing.allocator.free(scratch);
    var model: [257]?blob_map.LeafEntry = @splat(null);
    var root: ?blob_map.PageRef = null;
    var generation: u64 = 0;
    var random = std.Random.DefaultPrng.init(0x5eed_ba7c);
    const rng = random.random();

    for (0..30) |round| {
        var batch: std.ArrayList(Mutation) = .empty;
        defer batch.deinit(std.testing.allocator);
        for (0..model.len) |key| if (rng.uintLessThan(u8, 13) == 0) {
            if (rng.boolean()) {
                const entry = testStoredEntry(key, data, @intCast(round + 1));
                try batch.append(std.testing.allocator, .{ .upsert = entry });
                model[key] = entry;
            } else {
                try batch.append(std.testing.allocator, .{ .remove = key });
                model[key] = null;
            }
        };
        const range: ?KeyRange = if (round % 5 == 4) .{
            .first = @intCast(rng.uintLessThan(u8, 180)),
            .end = @intCast(180 + rng.uintLessThan(u8, 77)),
        } else null;
        if (range) |removed| for (&model, 0..) |*entry, key| {
            if (rangeContains(removed, key)) entry.* = null;
        };
        for (batch.items) |mutation| switch (mutation) {
            .upsert => |entry| model[entry.logical_blob] = entry,
            .remove => |key| model[key] = null,
        };
        const next_generation = generation + 1;
        root = try maps.applyBatch(std.testing.io, root, generation, next_generation, batch.items, range, scratch);
        generation = next_generation;
        try blobs.commit(std.testing.io);
        if (root) |reference| {
            const actual = try maps.loadAllAlloc(std.testing.io, reference, generation, scratch);
            defer std.testing.allocator.free(actual);
            var actual_index: usize = 0;
            for (model) |expected| if (expected) |entry| {
                try std.testing.expectEqualDeep(entry, actual[actual_index]);
                actual_index += 1;
            };
            try std.testing.expectEqual(actual.len, actual_index);
        } else {
            for (model) |entry| try std.testing.expect(entry == null);
        }
    }

    try blobs.close(std.testing.io);
    blobs_open = false;
    const file = try tmp.dir.openFile(std.testing.io, "blob-map-model", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = storage_api.Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, 4096);
    file_open = false;
    blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    blobs_open = true;
    maps = MapStore.init(std.testing.allocator, &blobs);
    const reopened = try maps.loadAllAlloc(std.testing.io, root.?, generation, scratch);
    defer std.testing.allocator.free(reopened);
    var reopened_index: usize = 0;
    for (model) |expected| if (expected) |entry| {
        try std.testing.expectEqualDeep(entry, reopened[reopened_index]);
        reopened_index += 1;
    };
    try std.testing.expectEqual(reopened.len, reopened_index);
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

fn testStoredEntry(logical_blob: u64, reference: blob_format.BlobRef, marker: u32) blob_map.LeafEntry {
    var stored = reference;
    stored.checksums[0] = marker;
    return .{ .logical_blob = logical_blob, .reference = stored };
}
