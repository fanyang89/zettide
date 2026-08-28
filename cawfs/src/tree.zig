//! Immutable path-copying B+tree.
//!
//! The insertion and split control flow is adapted from xitdb's SortedMap at
//! commit 97f5d68962a70cbf9d3bbaf0a087271e5da642b7. Storage, page encoding,
//! references, and publication are native to zettide-cawfs.

const std = @import("std");
const page = @import("page.zig");
const store_mod = @import("store.zig");
const transaction_mod = @import("transaction.zig");

pub const max_key_size = 1024;
pub const max_entry_payload = (page.page_size - page.header_size) / 2 - 6;
pub const max_height = 64;

pub const Error = error{
    KeyTooLarge,
    EntryTooLarge,
    CannotSplit,
    LevelMismatch,
    TreeTooDeep,
    StagedPageLimit,
    CursorInvalid,
};

const StagedPage = struct {
    object_ref: store_mod.ObjectRef,
    encoded: *page.Encoded,
};

const LoadedPage = union(enum) {
    staged: *const page.Encoded,
    stored: store_mod.OwnedBytes,

    fn bytes(self: *const LoadedPage) []const u8 {
        return switch (self.*) {
            .staged => |encoded| encoded,
            .stored => |owned| owned.bytes,
        };
    }

    fn deinit(self: *LoadedPage) void {
        switch (self.*) {
            .staged => {},
            .stored => |*owned| owned.deinit(),
        }
        self.* = undefined;
    }
};

const Split = struct {
    separator: store_mod.OwnedBytes,
    right: store_mod.ObjectRef,

    fn deinit(self: *Split) void {
        self.separator.deinit();
        self.* = undefined;
    }
};

const PutResult = struct {
    node: store_mod.ObjectRef,
    level: u16,
    split: ?Split = null,

    fn deinit(self: *PutResult) void {
        if (self.split) |*split| split.deinit();
        self.* = undefined;
    }
};

const DeleteNodeResult = struct {
    node: store_mod.ObjectRef,
    level: u16,
    removed: bool,
};

pub const DeleteResult = struct {
    root: store_mod.ObjectRef,
    removed: bool,
};

pub const Entry = struct {
    key: store_mod.OwnedBytes,
    value: store_mod.OwnedBytes,

    pub fn deinit(self: *Entry) void {
        self.key.deinit();
        self.value.deinit();
        self.* = undefined;
    }
};

const CursorSource = union(enum) {
    stored: store_mod.ConditionalStore,
    speculative: *Mutator,

    fn load(self: CursorSource, object_ref: store_mod.ObjectRef, allocator: std.mem.Allocator) !LoadedPage {
        return switch (self) {
            .stored => |store| .{ .stored = try store.loadImmutable(object_ref, allocator) },
            .speculative => |mutator| mutator.load(object_ref),
        };
    }
};

const CursorFrame = struct {
    loaded: LoadedPage,
    child_index: usize,
};

/// Iterates entries in bytewise key order starting at an inclusive lower
/// bound. The source store or Mutator must outlive the Cursor. An error while
/// moving between leaves invalidates the cursor for further iteration.
pub const Cursor = struct {
    source: CursorSource,
    allocator: std.mem.Allocator,
    frames: std.ArrayList(CursorFrame) = .empty,
    leaf: ?LoadedPage = null,
    leaf_index: usize = 0,
    failed: bool = false,

    fn init(
        source: CursorSource,
        allocator: std.mem.Allocator,
        root: store_mod.ObjectRef,
        start: []const u8,
    ) !Cursor {
        var cursor = Cursor{ .source = source, .allocator = allocator };
        errdefer cursor.deinit();
        try cursor.descend(root, start, null);
        return cursor;
    }

    pub fn deinit(self: *Cursor) void {
        if (self.leaf) |*leaf| leaf.deinit();
        for (self.frames.items) |*frame| frame.loaded.deinit();
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *Cursor) !?Entry {
        if (self.failed) return error.CursorInvalid;
        while (self.leaf != null) {
            const view = try page.decode(self.leaf.?.bytes());
            if (self.leaf_index < view.entry_count) {
                const item = try view.leafEntry(self.leaf_index);
                var key = try store_mod.OwnedBytes.dupe(self.allocator, item.key);
                errdefer key.deinit();
                const value = try store_mod.OwnedBytes.dupe(self.allocator, item.value);
                self.leaf_index += 1;
                return .{ .key = key, .value = value };
            }
            self.advanceLeaf() catch |err| {
                self.failed = true;
                return err;
            };
        }
        return null;
    }

    fn advanceLeaf(self: *Cursor) !void {
        self.leaf.?.deinit();
        self.leaf = null;
        while (self.frames.items.len != 0) {
            const frame = &self.frames.items[self.frames.items.len - 1];
            const view = try page.decode(frame.loaded.bytes());
            if (frame.child_index < view.entry_count) {
                const child = (try view.internalEntry(frame.child_index)).child;
                frame.child_index += 1;
                try self.descend(child, null, view.level - 1);
                return;
            }
            var finished = self.frames.pop().?;
            finished.loaded.deinit();
        }
    }

    fn descend(
        self: *Cursor,
        root: store_mod.ObjectRef,
        start: ?[]const u8,
        initial_level: ?u16,
    ) !void {
        var current = root;
        var expected_level = initial_level;
        var depth = self.frames.items.len;
        while (true) : (depth += 1) {
            if (depth > max_height) return error.TreeTooDeep;
            var loaded = try self.source.load(current, self.allocator);
            var retained = false;
            defer if (!retained) loaded.deinit();
            const view = try page.decode(loaded.bytes());
            if (view.level > max_height) return error.TreeTooDeep;
            if (expected_level) |level| {
                if (view.level != level) return error.LevelMismatch;
            }
            switch (view.kind) {
                .leaf => {
                    self.leaf_index = if (start) |key| try view.lowerBound(key) else 0;
                    self.leaf = loaded;
                    retained = true;
                    return;
                },
                .internal => {
                    if (view.level == 0) return error.LevelMismatch;
                    const route = if (start) |key|
                        try view.route(key)
                    else
                        page.Route{ .child = try view.firstChild(), .child_index = 0 };
                    try self.frames.append(self.allocator, .{
                        .loaded = loaded,
                        .child_index = route.child_index,
                    });
                    retained = true;
                    current = route.child;
                    expected_level = view.level - 1;
                },
            }
        }
    }
};

/// Owns speculative pages created by one publication transaction. The
/// Transaction and its ConditionalStore backend must outlive the Mutator.
pub const Mutator = struct {
    pub const Options = struct {
        max_staged_pages: usize = 4096,
    };

    transaction: *transaction_mod.Transaction,
    allocator: std.mem.Allocator,
    max_staged_pages: usize,
    stage_count: usize = 0,
    staged: std.ArrayList(StagedPage) = .empty,
    staged_index: std.AutoHashMapUnmanaged(store_mod.ObjectRef, usize) = .empty,

    pub fn init(transaction: *transaction_mod.Transaction) Mutator {
        return initOptions(transaction, .{});
    }

    pub fn initOptions(transaction: *transaction_mod.Transaction, options: Options) Mutator {
        return .{
            .transaction = transaction,
            .allocator = transaction.allocator,
            .max_staged_pages = options.max_staged_pages,
        };
    }

    pub fn deinit(self: *Mutator) void {
        for (self.staged.items) |staged| self.allocator.destroy(staged.encoded);
        self.staged.deinit(self.allocator);
        self.staged_index.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createEmpty(self: *Mutator) !store_mod.ObjectRef {
        const encoded = try page.encodeLeaf(&.{});
        return self.stage(&encoded);
    }

    pub fn get(
        self: *Mutator,
        root: store_mod.ObjectRef,
        key: []const u8,
    ) !?store_mod.OwnedBytes {
        return getWithLoader(self, loadMutator, self.allocator, root, key);
    }

    pub fn scan(self: *Mutator, root: store_mod.ObjectRef, start: []const u8) !Cursor {
        return Cursor.init(.{ .speculative = self }, self.allocator, root, start);
    }

    pub fn put(
        self: *Mutator,
        root: store_mod.ObjectRef,
        key: []const u8,
        value: []const u8,
    ) !store_mod.ObjectRef {
        try validateEntry(key, value);
        var result = try self.putNode(root, key, value, 0);
        defer result.deinit();
        if (result.split) |split| {
            if (result.level >= max_height) return error.TreeTooDeep;
            const encoded = try page.encodeInternal(result.level + 1, result.node, &.{.{
                .key = split.separator.bytes,
                .child = split.right,
            }});
            return self.stage(&encoded);
        }
        return result.node;
    }

    pub fn delete(
        self: *Mutator,
        root: store_mod.ObjectRef,
        key: []const u8,
    ) !DeleteResult {
        if (key.len > max_key_size) return error.KeyTooLarge;
        const result = try self.deleteNode(root, key, 0);
        return .{ .root = result.node, .removed = result.removed };
    }

    fn putNode(
        self: *Mutator,
        node_ref: store_mod.ObjectRef,
        key: []const u8,
        value: []const u8,
        depth: usize,
    ) !PutResult {
        if (depth > max_height) return error.TreeTooDeep;
        var loaded = try self.load(node_ref);
        defer loaded.deinit();
        const view = try page.decode(loaded.bytes());
        if (view.level > max_height) return error.TreeTooDeep;
        return switch (view.kind) {
            .leaf => self.putLeaf(view, key, value),
            .internal => self.putInternal(view, key, value, depth),
        };
    }

    fn putLeaf(self: *Mutator, view: page.View, key: []const u8, value: []const u8) !PutResult {
        var entries: std.ArrayList(page.LeafEntry) = .empty;
        defer entries.deinit(self.allocator);
        try entries.ensureTotalCapacity(self.allocator, view.entry_count + 1);

        var inserted = false;
        for (0..view.entry_count) |index| {
            const current = try view.leafEntry(index);
            if (!inserted) switch (std.mem.order(u8, key, current.key)) {
                .lt => {
                    entries.appendAssumeCapacity(.{ .key = key, .value = value });
                    inserted = true;
                },
                .eq => {
                    entries.appendAssumeCapacity(.{ .key = key, .value = value });
                    inserted = true;
                    continue;
                },
                .gt => {},
            };
            entries.appendAssumeCapacity(current);
        }
        if (!inserted) entries.appendAssumeCapacity(.{ .key = key, .value = value });

        if (page.encodeLeaf(entries.items)) |encoded| {
            return .{ .node = try self.stage(&encoded), .level = 0 };
        } else |err| switch (err) {
            error.PageFull => {},
            else => return err,
        }

        const split_index = try chooseLeafSplit(entries.items);
        var separator = try store_mod.OwnedBytes.dupe(self.allocator, entries.items[split_index].key);
        errdefer separator.deinit();
        const left_encoded = try page.encodeLeaf(entries.items[0..split_index]);
        const right_encoded = try page.encodeLeaf(entries.items[split_index..]);
        const left = try self.stage(&left_encoded);
        const right = try self.stage(&right_encoded);
        return .{
            .node = left,
            .level = 0,
            .split = .{ .separator = separator, .right = right },
        };
    }

    fn putInternal(
        self: *Mutator,
        view: page.View,
        key: []const u8,
        value: []const u8,
        depth: usize,
    ) !PutResult {
        const route = try view.route(key);
        var child = try self.putNode(route.child, key, value, depth + 1);
        defer child.deinit();
        if (child.level + 1 != view.level) return error.LevelMismatch;

        var entries: std.ArrayList(page.InternalEntry) = .empty;
        defer entries.deinit(self.allocator);
        try entries.ensureTotalCapacity(
            self.allocator,
            view.entry_count + @intFromBool(child.split != null),
        );
        var first_child = try view.firstChild();
        if (route.child_index == 0) first_child = child.node;
        for (0..view.entry_count) |index| {
            var entry = try view.internalEntry(index);
            if (index + 1 == route.child_index) entry.child = child.node;
            entries.appendAssumeCapacity(entry);
        }
        if (child.split) |split| {
            entries.insertAssumeCapacity(route.child_index, .{
                .key = split.separator.bytes,
                .child = split.right,
            });
        }

        if (page.encodeInternal(view.level, first_child, entries.items)) |encoded| {
            return .{ .node = try self.stage(&encoded), .level = view.level };
        } else |err| switch (err) {
            error.PageFull => {},
            else => return err,
        }

        const promote = try chooseInternalSplit(entries.items);
        var separator = try store_mod.OwnedBytes.dupe(self.allocator, entries.items[promote].key);
        errdefer separator.deinit();
        const left_encoded = try page.encodeInternal(view.level, first_child, entries.items[0..promote]);
        const right_encoded = try page.encodeInternal(
            view.level,
            entries.items[promote].child,
            entries.items[promote + 1 ..],
        );
        const left = try self.stage(&left_encoded);
        const right = try self.stage(&right_encoded);
        return .{
            .node = left,
            .level = view.level,
            .split = .{ .separator = separator, .right = right },
        };
    }

    fn deleteNode(
        self: *Mutator,
        node_ref: store_mod.ObjectRef,
        key: []const u8,
        depth: usize,
    ) !DeleteNodeResult {
        if (depth > max_height) return error.TreeTooDeep;
        var loaded = try self.load(node_ref);
        defer loaded.deinit();
        const view = try page.decode(loaded.bytes());
        if (view.level > max_height) return error.TreeTooDeep;
        switch (view.kind) {
            .leaf => {
                var entries: std.ArrayList(page.LeafEntry) = .empty;
                defer entries.deinit(self.allocator);
                try entries.ensureTotalCapacity(self.allocator, view.entry_count);
                var removed = false;
                for (0..view.entry_count) |index| {
                    const entry = try view.leafEntry(index);
                    if (std.mem.eql(u8, entry.key, key)) {
                        removed = true;
                    } else {
                        entries.appendAssumeCapacity(entry);
                    }
                }
                if (!removed) return .{ .node = node_ref, .level = 0, .removed = false };
                const encoded = try page.encodeLeaf(entries.items);
                return .{ .node = try self.stage(&encoded), .level = 0, .removed = true };
            },
            .internal => {
                const route = try view.route(key);
                const child = try self.deleteNode(route.child, key, depth + 1);
                if (child.level + 1 != view.level) return error.LevelMismatch;
                if (!child.removed)
                    return .{ .node = node_ref, .level = view.level, .removed = false };

                var entries: std.ArrayList(page.InternalEntry) = .empty;
                defer entries.deinit(self.allocator);
                try entries.ensureTotalCapacity(self.allocator, view.entry_count);
                var first_child = try view.firstChild();
                if (route.child_index == 0) first_child = child.node;
                for (0..view.entry_count) |index| {
                    var entry = try view.internalEntry(index);
                    if (index + 1 == route.child_index) entry.child = child.node;
                    entries.appendAssumeCapacity(entry);
                }
                const encoded = try page.encodeInternal(view.level, first_child, entries.items);
                return .{
                    .node = try self.stage(&encoded),
                    .level = view.level,
                    .removed = true,
                };
            },
        }
    }

    fn load(self: *Mutator, object_ref: store_mod.ObjectRef) !LoadedPage {
        if (self.staged_index.get(object_ref)) |index|
            return .{ .staged = self.staged.items[index].encoded };
        return .{ .stored = try self.transaction.store.loadImmutable(object_ref, self.allocator) };
    }

    fn stage(self: *Mutator, encoded: *const page.Encoded) !store_mod.ObjectRef {
        if (self.stage_count >= self.max_staged_pages) return error.StagedPageLimit;
        try self.staged.ensureUnusedCapacity(self.allocator, 1);
        try self.staged_index.ensureUnusedCapacity(self.allocator, 1);
        const copy = try self.allocator.create(page.Encoded);
        errdefer self.allocator.destroy(copy);
        copy.* = encoded.*;
        const object_ref = try self.transaction.putImmutable(copy);
        self.stage_count += 1;
        if (self.staged_index.get(object_ref)) |_| {
            self.allocator.destroy(copy);
            return object_ref;
        }
        const index = self.staged.items.len;
        self.staged.appendAssumeCapacity(.{ .object_ref = object_ref, .encoded = copy });
        self.staged_index.putAssumeCapacityNoClobber(object_ref, index);
        return object_ref;
    }
};

pub fn get(
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    root: store_mod.ObjectRef,
    key: []const u8,
) !?store_mod.OwnedBytes {
    const Loader = struct {
        store: store_mod.ConditionalStore,
        allocator: std.mem.Allocator,

        fn load(self: *@This(), object_ref: store_mod.ObjectRef) !LoadedPage {
            return .{ .stored = try self.store.loadImmutable(object_ref, self.allocator) };
        }
    };
    var loader = Loader{ .store = store, .allocator = allocator };
    return getWithLoader(&loader, Loader.load, allocator, root, key);
}

pub fn scan(
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    root: store_mod.ObjectRef,
    start: []const u8,
) !Cursor {
    return Cursor.init(.{ .stored = store }, allocator, root, start);
}

fn getWithLoader(
    loader: anytype,
    comptime loadFn: anytype,
    allocator: std.mem.Allocator,
    root: store_mod.ObjectRef,
    key: []const u8,
) !?store_mod.OwnedBytes {
    var current = root;
    var expected_level: ?u16 = null;
    var depth: usize = 0;
    while (true) : (depth += 1) {
        if (depth > max_height) return error.TreeTooDeep;
        var loaded = try loadFn(loader, current);
        defer loaded.deinit();
        const view = try page.decode(loaded.bytes());
        if (view.level > max_height) return error.TreeTooDeep;
        if (expected_level) |level| {
            if (view.level != level) return error.LevelMismatch;
        }
        switch (view.kind) {
            .leaf => {
                const value = (try view.find(key)) orelse return null;
                return @as(?store_mod.OwnedBytes, try store_mod.OwnedBytes.dupe(allocator, value));
            },
            .internal => {
                if (view.level == 0) return error.LevelMismatch;
                expected_level = view.level - 1;
                current = try view.childFor(key);
            },
        }
    }
}

fn loadMutator(self: *Mutator, object_ref: store_mod.ObjectRef) !LoadedPage {
    return self.load(object_ref);
}

fn validateEntry(key: []const u8, value: []const u8) Error!void {
    if (key.len > max_key_size) return error.KeyTooLarge;
    const payload = std.math.add(usize, key.len, value.len) catch return error.EntryTooLarge;
    if (payload > max_entry_payload) return error.EntryTooLarge;
}

fn chooseLeafSplit(entries: []const page.LeafEntry) Error!usize {
    if (entries.len < 2) return error.CannotSplit;
    var best: ?usize = null;
    var best_difference: usize = std.math.maxInt(usize);
    for (1..entries.len) |index| {
        const left = leafSize(entries[0..index]) catch continue;
        const right = leafSize(entries[index..]) catch continue;
        const difference = if (left > right) left - right else right - left;
        if (difference < best_difference) {
            best = index;
            best_difference = difference;
        }
    }
    return best orelse error.CannotSplit;
}

fn chooseInternalSplit(entries: []const page.InternalEntry) Error!usize {
    if (entries.len < 3) return error.CannotSplit;
    var best: ?usize = null;
    var best_difference: usize = std.math.maxInt(usize);
    for (1..entries.len - 1) |index| {
        const left = internalSize(entries[0..index]) catch continue;
        const right = internalSize(entries[index + 1 ..]) catch continue;
        const difference = if (left > right) left - right else right - left;
        if (difference < best_difference) {
            best = index;
            best_difference = difference;
        }
    }
    return best orelse error.CannotSplit;
}

fn leafSize(entries: []const page.LeafEntry) Error!usize {
    var size: usize = page.header_size;
    for (entries) |entry| {
        size = std.math.add(usize, size, 6) catch return error.CannotSplit;
        size = std.math.add(usize, size, entry.key.len) catch return error.CannotSplit;
        size = std.math.add(usize, size, entry.value.len) catch return error.CannotSplit;
        if (size > page.page_size) return error.CannotSplit;
    }
    return size;
}

fn internalSize(entries: []const page.InternalEntry) Error!usize {
    var size: usize = page.header_size;
    for (entries) |entry| {
        size = std.math.add(usize, size, 2 + store_mod.object_ref_size) catch
            return error.CannotSplit;
        size = std.math.add(usize, size, entry.key.len) catch return error.CannotSplit;
        if (size > page.page_size) return error.CannotSplit;
    }
    return size;
}
