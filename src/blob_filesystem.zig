const std = @import("std");
const blob_file = @import("blob_file.zig");
const blob_format = @import("blob_format.zig");
const filesystem_format = @import("blob_filesystem_format.zig");
const metadata_map = @import("blob_metadata_map.zig");
const metadata_map_store = @import("blob_metadata_map_store.zig");
const blob_store = @import("blob_store.zig");
const metadata = @import("metadata.zig");
const name_profile = @import("name_profile.zig");

const Io = std.Io;

pub const Filesystem = struct {
    allocator: std.mem.Allocator,
    blobs: blob_store.Store,
    authority_ref: blob_format.BlobRef,
    root: filesystem_format.Root,

    /// Takes ownership of blobs, including on failure.
    pub fn format(
        allocator: std.mem.Allocator,
        io: Io,
        blobs: blob_store.Store,
        profile: name_profile.Profile,
    ) !Filesystem {
        var owned_blobs = blobs;
        errdefer owned_blobs.close(io) catch {};
        if (owned_blobs.authorityRoot() != null or owned_blobs.committedUnits() != 0 or
            owned_blobs.stagedUnits() != 0)
            return error.BlobStoreNotEmpty;

        const inode_key = try filesystem_format.inodeKey(filesystem_format.root_inode);
        const inode_value = try filesystem_format.encodeInode(.{
            .metadata = metadata.Metadata.init(io, .directory, 0o040755, 0, 0),
            .generation = 1,
            .nlink = 2,
            .allocated_bytes = 0,
            .parent_inode = filesystem_format.root_inode,
            .data = null,
        });
        const entries = [_]metadata_map.LeafEntry{.{ .key = &inode_key, .value = &inode_value }};
        var maps = metadata_map_store.MapStore.init(allocator, &owned_blobs);
        const metadata_root = try maps.build(io, 1, &entries);
        const root: filesystem_format.Root = .{
            .generation = 1,
            .next_inode = 2,
            .record_count = 1,
            .orphan_count = 0,
            .name_profile = profile,
            .metadata_root = metadata_root,
        };
        const root_bytes = try filesystem_format.encodeRoot(root);
        const authority_ref = try owned_blobs.put(io, &root_bytes);
        try owned_blobs.commitAuthority(io, authority_ref);
        return .{
            .allocator = allocator,
            .blobs = owned_blobs,
            .authority_ref = authority_ref,
            .root = root,
        };
    }

    /// Takes ownership of blobs, including on failure.
    pub fn open(allocator: std.mem.Allocator, io: Io, blobs: blob_store.Store) !Filesystem {
        var owned_blobs = blobs;
        errdefer owned_blobs.close(io) catch {};
        var candidates = owned_blobs.authorityCandidates();
        if (candidates[0] == null or
            (candidates[1] != null and candidates[1].?.sequence > candidates[0].?.sequence))
            std.mem.swap(?blob_format.Header, &candidates[0], &candidates[1]);

        var first_error: ?anyerror = null;
        for (candidates) |candidate_optional| {
            const candidate = candidate_optional orelse continue;
            const authority_ref = candidate.authority_root orelse continue;
            try owned_blobs.selectAuthority(io, candidate);
            const root = loadCandidate(allocator, io, &owned_blobs, candidate, authority_ref) catch |err| {
                if (!isRecoverableAuthorityError(err)) return err;
                if (first_error == null) first_error = err;
                continue;
            };
            return .{
                .allocator = allocator,
                .blobs = owned_blobs,
                .authority_ref = authority_ref,
                .root = root,
            };
        }
        return first_error orelse error.NoValidBlobFilesystemAuthority;
    }

    pub fn close(self: *Filesystem, io: Io) !void {
        try self.blobs.close(io);
        self.* = undefined;
    }
};

fn loadCandidate(
    allocator: std.mem.Allocator,
    io: Io,
    blobs: *blob_store.Store,
    candidate: blob_format.Header,
    authority_ref: blob_format.BlobRef,
) !filesystem_format.Root {
    try authority_ref.validate(candidate.unit_count);
    if (authority_ref.valid_bytes != filesystem_format.root_encoded_size or
        authority_ref.endUnit() > candidate.committed_units)
        return error.InvalidBlobFilesystemAuthority;
    const buffer = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(blob_format.allocation_unit),
        blob_format.storedBytes(authority_ref.valid_bytes),
    );
    defer allocator.free(buffer);
    const amount = try blobs.read(io, authority_ref, buffer);
    if (amount != filesystem_format.root_encoded_size) return error.InvalidBlobFilesystemAuthority;
    const root = try filesystem_format.decodeRoot(@ptrCast(buffer.ptr));
    var maps = metadata_map_store.MapStore.init(allocator, blobs);
    const entries = try maps.loadAllAlloc(io, root.metadata_root, root.generation);
    defer metadata_map_store.deinitEntries(allocator, entries);
    try validateGraph(allocator, io, blobs, root, entries);
    return root;
}

fn validateGraph(
    allocator: std.mem.Allocator,
    io: Io,
    blobs: *blob_store.Store,
    root: filesystem_format.Root,
    entries: []const metadata_map_store.OwnedEntry,
) !void {
    if (entries.len != root.record_count) return error.InvalidBlobFilesystemGraph;
    var inodes = std.AutoHashMap(u64, filesystem_format.InodeRecord).init(allocator);
    defer inodes.deinit();
    var links = std.AutoHashMap(u64, u64).init(allocator);
    defer links.deinit();
    var child_directories = std.AutoHashMap(u64, u64).init(allocator);
    defer child_directories.deinit();
    var orphans = std.AutoHashMap(u64, filesystem_format.OrphanRecord).init(allocator);
    defer orphans.deinit();

    for (entries) |entry| switch (try filesystem_format.decodeKey(entry.key)) {
        .inode => |inode| {
            if (inode >= root.next_inode or entry.value.len != filesystem_format.inode_encoded_size)
                return error.InvalidBlobFilesystemGraph;
            const record = try filesystem_format.decodeInode(@ptrCast(entry.value.ptr));
            if (record.generation > root.generation) return error.InvalidBlobFilesystemGraph;
            const result = try inodes.getOrPut(inode);
            if (result.found_existing) return error.InvalidBlobFilesystemGraph;
            result.value_ptr.* = record;
            if (record.data) |snapshot| {
                var file = try blob_file.State.open(allocator, io, blobs, snapshot);
                defer file.deinit();
                if (file.allocatedBytes() != record.allocated_bytes)
                    return error.InvalidBlobFilesystemGraph;
            }
        },
        .orphan => |inode| {
            if (entry.value.len != filesystem_format.orphan_encoded_size)
                return error.InvalidBlobFilesystemGraph;
            const record = try filesystem_format.decodeOrphan(@ptrCast(entry.value.ptr));
            if (record.generation > root.generation) return error.InvalidBlobFilesystemGraph;
            const result = try orphans.getOrPut(inode);
            if (result.found_existing) return error.InvalidBlobFilesystemGraph;
            result.value_ptr.* = record;
        },
        .dentry => {},
    };

    if (orphans.count() != root.orphan_count) return error.InvalidBlobFilesystemGraph;
    for (entries) |entry| switch (try filesystem_format.decodeKey(entry.key)) {
        .dentry => |key| {
            const record = try filesystem_format.decodeDentry(entry.value);
            try filesystem_format.validateDentryIdentity(
                allocator,
                root.name_profile,
                key.lookup_name,
                record,
            );
            const parent = inodes.get(key.parent_inode) orelse return error.InvalidBlobFilesystemGraph;
            if (parent.metadata.kind != .directory or parent.nlink == 0)
                return error.InvalidBlobFilesystemGraph;
            const child = inodes.get(record.child_inode) orelse return error.InvalidBlobFilesystemGraph;
            if (child.generation != record.child_generation or child.metadata.kind != record.kind)
                return error.InvalidBlobFilesystemGraph;
            try increment(&links, record.child_inode);
            if (child.metadata.kind == .directory) {
                if (child.parent_inode != key.parent_inode) return error.InvalidBlobFilesystemGraph;
                try increment(&child_directories, key.parent_inode);
            }
        },
        else => {},
    };

    const root_record = inodes.get(filesystem_format.root_inode) orelse
        return error.InvalidBlobFilesystemGraph;
    if (root_record.metadata.kind != .directory or
        root_record.parent_inode != filesystem_format.root_inode or root_record.nlink == 0)
        return error.InvalidBlobFilesystemGraph;
    var iterator = inodes.iterator();
    while (iterator.next()) |entry| {
        const inode = entry.key_ptr.*;
        const record = entry.value_ptr.*;
        const namespace_links = links.get(inode) orelse 0;
        const orphan = orphans.get(inode);
        if (orphan) |value| {
            if (inode == filesystem_format.root_inode or record.nlink != 0 or namespace_links != 0 or
                value.kind != record.metadata.kind)
                return error.InvalidBlobFilesystemGraph;
        } else if (record.nlink == 0) {
            return error.InvalidBlobFilesystemGraph;
        }
        if (record.metadata.kind == .directory) {
            if (record.nlink == 0) {
                if (child_directories.get(inode) != null) return error.InvalidBlobFilesystemGraph;
            } else {
                const expected_namespace_links: u64 = if (inode == filesystem_format.root_inode) 0 else 1;
                if (namespace_links != expected_namespace_links or
                    record.nlink != 2 + (child_directories.get(inode) orelse 0))
                    return error.InvalidBlobFilesystemGraph;
            }
        } else if (record.nlink != namespace_links) {
            return error.InvalidBlobFilesystemGraph;
        }
    }
    var orphan_iterator = orphans.iterator();
    while (orphan_iterator.next()) |entry| if (!inodes.contains(entry.key_ptr.*))
        return error.InvalidBlobFilesystemGraph;

    iterator = inodes.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.metadata.kind != .directory or entry.value_ptr.nlink == 0) continue;
        var current = entry.key_ptr.*;
        var steps: usize = 0;
        while (current != filesystem_format.root_inode) : (steps += 1) {
            if (steps >= inodes.count()) return error.InvalidBlobFilesystemGraph;
            const directory = inodes.get(current) orelse return error.InvalidBlobFilesystemGraph;
            if (directory.metadata.kind != .directory or directory.nlink == 0)
                return error.InvalidBlobFilesystemGraph;
            current = directory.parent_inode;
        }
    }
}

fn increment(counts: *std.AutoHashMap(u64, u64), key: u64) !void {
    const result = try counts.getOrPut(key);
    if (!result.found_existing) result.value_ptr.* = 0;
    result.value_ptr.* = std.math.add(u64, result.value_ptr.*, 1) catch
        return error.InvalidBlobFilesystemGraph;
}

fn isRecoverableAuthorityError(err: anyerror) bool {
    return switch (err) {
        error.InvalidBlobReference,
        error.UnpublishedBlobReference,
        error.BlobChecksumMismatch,
        error.BlobDigestMismatch,
        error.InvalidBlobFilesystemAuthority,
        error.InvalidBlobFilesystemRoot,
        error.InvalidBlobFilesystemGraph,
        error.InvalidBlobFilesystemKey,
        error.InvalidBlobFilesystemInode,
        error.InvalidBlobFilesystemDentry,
        error.InvalidBlobFilesystemOrphan,
        error.InvalidBlobMetadataPage,
        error.InvalidBlobMetadataEntry,
        error.InvalidBlobMetadataTree,
        error.BlobMetadataReferenceMismatch,
        error.InvalidBlobFileSnapshot,
        error.InvalidBlobMapPage,
        error.BlobMapReferenceMismatch,
        => true,
        else => false,
    };
}

test "blob filesystem formats and reopens an empty root" {
    const blob_device = @import("blob_device.zig");
    const storage_api = @import("v3/storage.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 16 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-filesystem",
        device_size,
        blob_format.allocation_unit,
    );
    const blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var filesystem = try Filesystem.format(
        std.testing.allocator,
        std.testing.io,
        blobs,
        .portable_v1,
    );
    var filesystem_open = true;
    defer if (filesystem_open) filesystem.close(std.testing.io) catch {};
    try std.testing.expectEqual(@as(u64, 1), filesystem.root.generation);
    try std.testing.expectEqual(name_profile.Profile.portable_v1, filesystem.root.name_profile);
    try std.testing.expectEqual(@as(u64, 2), filesystem.blobs.committedUnits());
    try std.testing.expectEqualDeep(filesystem.authority_ref, filesystem.blobs.authorityRoot().?);
    const previous_authority = filesystem.authority_ref;
    const replacement_root = try filesystem_format.encodeRoot(filesystem.root);
    const corrupt_authority = try filesystem.blobs.put(std.testing.io, &replacement_root);
    try filesystem.blobs.commitAuthority(std.testing.io, corrupt_authority);
    try filesystem.close(std.testing.io);
    filesystem_open = false;

    const corrupt = try tmp.dir.openFile(std.testing.io, "blob-filesystem", .{ .mode = .read_write });
    try corrupt.writePositionalAll(std.testing.io, "x", try blob_format.slotOffset(corrupt_authority.slot));
    corrupt.close(std.testing.io);

    const file = try tmp.dir.openFile(std.testing.io, "blob-filesystem", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = storage_api.Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, blob_format.allocation_unit);
    file_open = false;
    const reopened_blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    filesystem = try Filesystem.open(std.testing.allocator, std.testing.io, reopened_blobs);
    filesystem_open = true;
    try std.testing.expectEqual(@as(u64, 1), filesystem.root.record_count);
    try std.testing.expectEqual(name_profile.Profile.portable_v1, filesystem.root.name_profile);
    try std.testing.expectEqualDeep(previous_authority, filesystem.authority_ref);
    try std.testing.expectEqual(@as(u64, 3), filesystem.blobs.header.sequence);
}
