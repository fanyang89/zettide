const std = @import("std");
const blob_format = @import("blob_format.zig");
const blob_map = @import("blob_map.zig");
const blob_map_store = @import("blob_map_store.zig");
const blob_object_format = @import("blob_object_format.zig");
const blob_store = @import("blob_store.zig");
const storage_api = @import("v3/storage.zig");

const Io = std.Io;

pub const Object = struct {
    allocator: std.mem.Allocator,
    blobs: blob_store.Store,
    authority: blob_object_format.Head,
    staged: blob_object_format.Head,
    entries: std.ArrayList(blob_map.LeafEntry),
    frozen: bool = false,

    /// Takes ownership of blobs, including on failure.
    pub fn create(allocator: std.mem.Allocator, io: Io, blobs: blob_store.Store) !Object {
        var owned_blobs = blobs;
        errdefer owned_blobs.close(io) catch {};
        var head = blob_object_format.Head.init(io);
        try writeHead(allocator, io, &owned_blobs, blob_object_format.head_a_offset, head);
        try owned_blobs.device.syncData(io);
        head.sequence += 1;
        try writeHead(allocator, io, &owned_blobs, blob_object_format.head_b_offset, head);
        try owned_blobs.device.sync(io);
        return .{
            .allocator = allocator,
            .blobs = owned_blobs,
            .authority = head,
            .staged = head,
            .entries = .empty,
        };
    }

    /// Takes ownership of blobs, including on failure.
    pub fn open(allocator: std.mem.Allocator, io: Io, blobs: blob_store.Store) !Object {
        var owned_blobs = blobs;
        errdefer owned_blobs.close(io) catch {};
        const first = try readHead(allocator, io, &owned_blobs, blob_object_format.head_a_offset);
        const second = try readHead(allocator, io, &owned_blobs, blob_object_format.head_b_offset);
        const preferred = try selectHead(first, second);
        const alternate: ?blob_object_format.Head = if (first != null and second != null and
            first.?.sequence != second.?.sequence)
            (if (first.?.sequence < second.?.sequence) first.? else second.?)
        else
            null;
        const opened = loadHead(allocator, io, &owned_blobs, preferred) catch |preferred_error| fallback: {
            if (!isRecoverableHeadStateError(preferred_error) or alternate == null)
                return preferred_error;
            break :fallback loadHead(allocator, io, &owned_blobs, alternate.?) catch |alternate_error| {
                if (isRecoverableHeadStateError(alternate_error)) return preferred_error;
                return alternate_error;
            };
        };
        return .{
            .allocator = allocator,
            .blobs = owned_blobs,
            .authority = opened.head,
            .staged = opened.head,
            .entries = opened.entries,
        };
    }

    pub fn close(self: *Object, io: Io) !void {
        self.entries.deinit(self.allocator);
        try self.blobs.close(io);
        self.* = undefined;
    }

    pub fn logicalSize(self: *const Object) u64 {
        return self.staged.logical_size;
    }

    pub fn transportKind(self: *const Object) storage_api.TransportKind {
        return self.blobs.transportKind();
    }

    pub fn transportStats(self: *Object, io: Io) storage_api.TransportStats {
        return self.blobs.transportStats(io);
    }

    pub fn resetTransportStats(self: *Object, io: Io) void {
        self.blobs.resetTransportStats(io);
    }

    pub fn appendMany(self: *Object, io: Io, inputs: []const []const u8) !void {
        if (self.frozen) return error.BlobObjectFrozen;
        if (inputs.len == 0 or inputs.len > @min(blob_map.max_leaf_entries, @as(usize, 32)))
            return error.InvalidBlobObjectAppend;
        for (inputs) |input| if (input.len != blob_format.blob_size)
            return error.InvalidBlobObjectAppend;
        if (self.staged.logical_size % blob_format.blob_size != 0)
            return error.UnsupportedPartialBlobAppend;

        const old_count = self.entries.items.len;
        try self.entries.ensureUnusedCapacity(self.allocator, inputs.len);
        const scratch = try self.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
        defer self.allocator.free(scratch);
        var references: [32]blob_format.BlobRef = undefined;
        self.blobs.putMany(io, inputs, references[0..inputs.len]) catch |err| {
            self.frozen = true;
            return err;
        };
        var appended_entries: [32]blob_map.LeafEntry = undefined;
        for (references[0..inputs.len], appended_entries[0..inputs.len], old_count..) |reference, *entry, index|
            entry.* = .{ .logical_blob = index, .reference = reference };

        const generation = std.math.add(u64, self.staged.generation, 1) catch {
            self.frozen = true;
            return error.BlobObjectGenerationExhausted;
        };
        var maps = blob_map_store.MapStore.init(self.allocator, &self.blobs);
        const appended = appended_entries[0..inputs.len];
        const root = if (self.staged.root) |current|
            maps.append(io, current, self.staged.map_generation, generation, appended, scratch) catch |err| {
                self.frozen = true;
                return err;
            }
        else
            maps.build(io, generation, appended) catch |err| {
                self.frozen = true;
                return err;
            };

        self.entries.appendSliceAssumeCapacity(appended);
        self.staged.generation = generation;
        self.staged.map_generation = generation;
        self.staged.logical_size += inputs.len * blob_format.blob_size;
        self.staged.allocated_bytes += inputs.len * blob_format.blob_size;
        self.staged.root = root;
    }

    pub fn readBlob(self: *Object, io: Io, logical_blob: u64, output: []u8) !usize {
        if (self.frozen) return error.BlobObjectFrozen;
        if (logical_blob >= self.entries.items.len) return error.BlobOutsideObject;
        const entry = self.entries.items[logical_blob];
        if (entry.logical_blob != logical_blob) return error.InvalidBlobObjectMap;
        return self.blobs.read(io, entry.reference, output);
    }

    pub fn commit(self: *Object, io: Io) !void {
        if (self.frozen) return error.BlobObjectFrozen;
        if (std.meta.eql(self.authority, self.staged)) return;
        self.blobs.commit(io) catch |err| {
            self.frozen = true;
            return err;
        };
        var next = self.staged;
        next.sequence = std.math.add(u64, self.authority.sequence, 1) catch {
            self.frozen = true;
            return error.BlobObjectSequenceExhausted;
        };
        const offset = if (next.sequence % 2 == 1)
            blob_object_format.head_a_offset
        else
            blob_object_format.head_b_offset;
        writeHead(self.allocator, io, &self.blobs, offset, next) catch |err| {
            self.frozen = true;
            return err;
        };
        self.blobs.device.sync(io) catch |err| {
            self.frozen = true;
            return err;
        };
        self.authority = next;
        self.staged = next;
    }
};

fn writeHead(
    allocator: std.mem.Allocator,
    io: Io,
    blobs: *blob_store.Store,
    offset: u64,
    head: blob_object_format.Head,
) !void {
    const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_object_format.head_size);
    defer allocator.free(bytes);
    bytes[0..blob_object_format.head_size].* = try blob_object_format.encodeHead(head);
    try blobs.device.writeAllAt(io, bytes, offset);
}

fn readHead(
    allocator: std.mem.Allocator,
    io: Io,
    blobs: *blob_store.Store,
    offset: u64,
) !?blob_object_format.Head {
    const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_object_format.head_size);
    defer allocator.free(bytes);
    try blobs.device.readAt(io, bytes, offset);
    return blob_object_format.decodeHead(@ptrCast(bytes.ptr)) catch null;
}

fn selectHead(first: ?blob_object_format.Head, second: ?blob_object_format.Head) !blob_object_format.Head {
    if (first == null and second == null) return error.NoValidBlobObjectHead;
    if (first != null and second != null and
        !std.mem.eql(u8, &first.?.object_id, &second.?.object_id))
        return error.ConflictingBlobObjectHeads;
    if (first != null and second != null and
        first.?.sequence == second.?.sequence and !std.meta.eql(first.?, second.?))
        return error.AmbiguousBlobObjectAuthority;
    if (first) |head| if (second == null or head.sequence > second.?.sequence) return head;
    return second.?;
}

const OpenedHead = struct {
    head: blob_object_format.Head,
    entries: std.ArrayList(blob_map.LeafEntry),
};

fn loadHead(
    allocator: std.mem.Allocator,
    io: Io,
    blobs: *blob_store.Store,
    head: blob_object_format.Head,
) !OpenedHead {
    var entries: std.ArrayList(blob_map.LeafEntry) = .empty;
    errdefer entries.deinit(allocator);
    if (head.root) |root| {
        const scratch = try allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_map.page_size);
        defer allocator.free(scratch);
        var maps = blob_map_store.MapStore.init(allocator, blobs);
        entries = .fromOwnedSlice(try maps.loadAllAlloc(io, root, head.map_generation, scratch));
        const expected = try std.math.divCeil(u64, head.logical_size, blob_format.blob_size);
        if (entries.items.len != expected) return error.InvalidBlobObjectMap;
        for (entries.items, 0..) |entry, index| {
            if (entry.logical_blob != index or entry.reference.endUnit() > blobs.committedUnits())
                return error.InvalidBlobObjectMap;
            try entry.reference.validate(blobs.header.unit_count);
        }
    }
    return .{ .head = head, .entries = entries };
}

fn isRecoverableHeadStateError(err: anyerror) bool {
    return switch (err) {
        error.UncommittedBlobMapRoot,
        error.BlobDigestMismatch,
        error.InvalidBlobMapPage,
        error.BlobMapReferenceMismatch,
        error.InvalidBlobObjectMap,
        error.InvalidBlobReference,
        error.UnpublishedBlobReference,
        => true,
        else => false,
    };
}

test "blob object appends commits reopens and reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 16 * 1024 * 1024;
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-object",
        device_size,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var object = try Object.create(std.testing.allocator, std.testing.io, blobs);
    var object_open = true;
    defer if (object_open) object.close(std.testing.io) catch {};

    const first = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_format.blob_size);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_format.blob_size);
    defer std.testing.allocator.free(second);
    @memset(first, 0x11);
    @memset(second, 0x22);
    const inputs = [_][]const u8{ first, second };
    try object.appendMany(std.testing.io, &inputs);
    try object.commit(std.testing.io);
    try object.close(std.testing.io);
    object_open = false;

    const file = try tmp.dir.openFile(std.testing.io, "blob-object", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = @import("v3/storage.zig").Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try @import("blob_device.zig").Device.init(storage, 0, device_size, 4096);
    file_open = false;
    blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    object = try Object.open(std.testing.allocator, std.testing.io, blobs);
    object_open = true;
    try std.testing.expectEqual(@as(u64, 2 * blob_format.blob_size), object.logicalSize());

    const output = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_format.blob_size);
    defer std.testing.allocator.free(output);
    _ = try object.readBlob(std.testing.io, 1, output);
    try std.testing.expect(std.mem.allEqual(u8, output, 0x22));
}

test "blob object appends staged map generations across a leaf split" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 64 * 1024 * 1024;
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-object-staged-appends",
        device_size,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var object = try Object.create(std.testing.allocator, std.testing.io, blobs);
    var object_open = true;
    defer if (object_open) object.close(std.testing.io) catch {};

    const first = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_format.blob_size);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_format.blob_size);
    defer std.testing.allocator.free(second);
    @memset(first, 0x41);
    @memset(second, 0x42);
    const batch_count = 24;
    const first_inputs: [batch_count][]const u8 = @splat(first);
    const second_inputs: [batch_count][]const u8 = @splat(second);
    try object.appendMany(std.testing.io, &first_inputs);
    try object.appendMany(std.testing.io, &second_inputs);
    try std.testing.expectEqual(@as(u8, 1), object.staged.root.?.level);
    try std.testing.expectEqual(@as(u64, 3), object.staged.map_generation);
    try object.commit(std.testing.io);
    try object.close(std.testing.io);
    object_open = false;

    const file = try tmp.dir.openFile(std.testing.io, "blob-object-staged-appends", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = @import("v3/storage.zig").Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try @import("blob_device.zig").Device.init(storage, 0, device_size, 4096);
    file_open = false;
    blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    object = try Object.open(std.testing.allocator, std.testing.io, blobs);
    object_open = true;
    try std.testing.expectEqual(@as(u64, 2 * batch_count * blob_format.blob_size), object.logicalSize());
    try std.testing.expectEqual(@as(u8, 1), object.authority.root.?.level);

    const output = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_format.blob_size);
    defer std.testing.allocator.free(output);
    for (0..2 * batch_count) |index| {
        _ = try object.readBlob(std.testing.io, index, output);
        try std.testing.expect(std.mem.allEqual(u8, output, if (index < batch_count) 0x41 else 0x42));
    }
}

test "blob object falls back when the latest root is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 8 * 1024 * 1024;
    const device = try @import("blob_device.zig").Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-object-fallback",
        device_size,
        4096,
    );
    var blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var object = try Object.create(std.testing.allocator, std.testing.io, blobs);
    const payload = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), blob_format.blob_size);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x33);
    const inputs = [_][]const u8{payload};
    try object.appendMany(std.testing.io, &inputs);
    try object.commit(std.testing.io);
    try std.testing.expectEqual(@as(u64, 3), object.authority.sequence);
    var malformed = object.authority;
    malformed.root.?.page = std.math.maxInt(u64);
    const malformed_bytes = try blob_object_format.encodeHead(malformed);
    try object.close(std.testing.io);

    const corrupt = try tmp.dir.openFile(std.testing.io, "blob-object-fallback", .{ .mode = .read_write });
    try corrupt.writePositionalAll(std.testing.io, &malformed_bytes, blob_object_format.head_a_offset);
    corrupt.close(std.testing.io);

    const file = try tmp.dir.openFile(std.testing.io, "blob-object-fallback", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = @import("v3/storage.zig").Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try @import("blob_device.zig").Device.init(storage, 0, device_size, 4096);
    file_open = false;
    blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    object = try Object.open(std.testing.allocator, std.testing.io, blobs);
    defer object.close(std.testing.io) catch {};
    try std.testing.expectEqual(@as(u64, 2), object.authority.sequence);
    try std.testing.expectEqual(@as(u64, 0), object.logicalSize());
    try std.testing.expectEqual(
        blob_format.allocationUnits(blob_format.blob_size) + blob_format.allocationUnits(blob_map.page_size),
        object.blobs.committedUnits(),
    );
}
