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
    transaction_mutex: Io.Mutex = .init,
    frozen: bool = false,

    pub const LookupResult = struct {
        inode: u64,
        generation: u64,
        kind: metadata.Kind,
    };

    pub const RenameResult = enum {
        renamed,
        same_object,
    };

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

    pub fn stat(self: *Filesystem, io: Io, inode: u64) !filesystem_format.InodeRecord {
        try self.transaction_mutex.lock(io);
        defer self.transaction_mutex.unlock(io);
        return (try self.loadInode(io, inode)) orelse error.FileNotFound;
    }

    pub fn lookup(self: *Filesystem, io: Io, parent_inode: u64, name: []const u8) !?LookupResult {
        try self.transaction_mutex.lock(io);
        defer self.transaction_mutex.unlock(io);
        _ = try self.requireDirectory(io, parent_inode);
        var prepared = try PreparedName.init(self.allocator, self.root.name_profile, name);
        defer prepared.deinit(self.allocator);
        return self.lookupPrepared(io, parent_inode, prepared.key);
    }

    pub fn createFile(
        self: *Filesystem,
        io: Io,
        parent_inode: u64,
        name: []const u8,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !u64 {
        return self.createNode(io, parent_inode, name, .file, mode, uid, gid);
    }

    pub fn createDirectory(
        self: *Filesystem,
        io: Io,
        parent_inode: u64,
        name: []const u8,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !u64 {
        return self.createNode(io, parent_inode, name, .directory, mode, uid, gid);
    }

    pub fn createFifo(
        self: *Filesystem,
        io: Io,
        parent_inode: u64,
        name: []const u8,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !u64 {
        return self.createNode(io, parent_inode, name, .fifo, mode, uid, gid);
    }

    pub fn link(
        self: *Filesystem,
        io: Io,
        source_inode: u64,
        parent_inode: u64,
        name: []const u8,
    ) !void {
        try self.transaction_mutex.lock(io);
        defer self.transaction_mutex.unlock(io);
        try self.requireMutable();
        var source = (try self.loadInode(io, source_inode)) orelse return error.FileNotFound;
        if (source.nlink == 0) return error.FileNotFound;
        if (source.metadata.kind == .directory) return error.PermissionDenied;
        if (source.nlink == std.math.maxInt(u64)) return error.TooManyLinks;
        var parent = try self.requireDirectory(io, parent_inode);
        var prepared = try PreparedName.init(self.allocator, self.root.name_profile, name);
        defer prepared.deinit(self.allocator);
        if (try self.lookupPrepared(io, parent_inode, prepared.key) != null)
            return error.PathAlreadyExists;

        const now = timestamp(io);
        source.nlink += 1;
        source.metadata.ctime_ns = now;
        touchParent(&parent, now);
        var mutations: MutationAccumulator = .init(self.allocator);
        defer mutations.deinit();
        try mutations.putInode(source_inode, source);
        try mutations.putInode(parent_inode, parent);
        try mutations.putDentry(parent_inode, prepared.key, .{
            .child_inode = source_inode,
            .child_generation = source.generation,
            .kind = source.metadata.kind,
            .spelling = prepared.spelling,
        });
        var next_root = self.root;
        next_root.generation = try nextGeneration(self.root.generation);
        next_root.record_count = std.math.add(u64, next_root.record_count, 1) catch
            return error.FilesystemRecordCountOverflow;
        try self.publish(io, next_root, &mutations);
    }

    pub fn remove(self: *Filesystem, io: Io, parent_inode: u64, name: []const u8) !void {
        return self.removeNode(io, parent_inode, name, null);
    }

    pub fn unlink(self: *Filesystem, io: Io, parent_inode: u64, name: []const u8) !void {
        return self.removeNode(io, parent_inode, name, false);
    }

    pub fn rmdir(self: *Filesystem, io: Io, parent_inode: u64, name: []const u8) !void {
        return self.removeNode(io, parent_inode, name, true);
    }

    pub fn rename(
        self: *Filesystem,
        io: Io,
        old_parent_inode: u64,
        old_name: []const u8,
        new_parent_inode: u64,
        new_name: []const u8,
        no_replace: bool,
    ) !RenameResult {
        try self.transaction_mutex.lock(io);
        defer self.transaction_mutex.unlock(io);
        try self.requireMutable();
        var old_parent = try self.requireDirectory(io, old_parent_inode);
        var new_parent = if (new_parent_inode == old_parent_inode)
            old_parent
        else
            try self.requireDirectory(io, new_parent_inode);
        var old_prepared = try PreparedName.init(self.allocator, self.root.name_profile, old_name);
        defer old_prepared.deinit(self.allocator);
        var new_prepared = try PreparedName.init(self.allocator, self.root.name_profile, new_name);
        defer new_prepared.deinit(self.allocator);
        const source_dentry = (try self.lookupPrepared(io, old_parent_inode, old_prepared.key)) orelse
            return error.FileNotFound;
        var source = (try self.loadInode(io, source_dentry.inode)) orelse
            return error.InvalidBlobFilesystemGraph;
        const same_key = old_parent_inode == new_parent_inode and
            std.mem.eql(u8, old_prepared.key, new_prepared.key);
        if (same_key) {
            if (try self.dentrySpellingEquals(io, old_parent_inode, old_prepared.key, new_prepared.spelling))
                return .same_object;
            const now = timestamp(io);
            source.metadata.ctime_ns = now;
            touchParent(&old_parent, now);
            var mutations: MutationAccumulator = .init(self.allocator);
            defer mutations.deinit();
            try mutations.putDentry(old_parent_inode, old_prepared.key, .{
                .child_inode = source_dentry.inode,
                .child_generation = source.generation,
                .kind = source.metadata.kind,
                .spelling = new_prepared.spelling,
            });
            try mutations.putInode(source_dentry.inode, source);
            try mutations.putInode(old_parent_inode, old_parent);
            var next_root = self.root;
            next_root.generation = try nextGeneration(self.root.generation);
            try self.publish(io, next_root, &mutations);
            return .renamed;
        }
        const victim_dentry = try self.lookupPrepared(io, new_parent_inode, new_prepared.key);
        if (no_replace and victim_dentry != null) return error.PathAlreadyExists;
        if (victim_dentry != null and victim_dentry.?.inode == source_dentry.inode)
            return .same_object;

        var victim: ?filesystem_format.InodeRecord = null;
        if (victim_dentry) |entry| {
            victim = (try self.loadInode(io, entry.inode)) orelse
                return error.InvalidBlobFilesystemGraph;
            if (source.metadata.kind == .directory and victim.?.metadata.kind != .directory)
                return error.NotDirectory;
            if (source.metadata.kind != .directory and victim.?.metadata.kind == .directory)
                return error.IsDirectory;
            if (victim.?.metadata.kind == .directory and !try self.directoryIsEmpty(io, entry.inode))
                return error.DirectoryNotEmpty;
        }
        if (source.metadata.kind == .directory)
            try self.preventDirectoryCycle(io, source_dentry.inode, new_parent_inode);

        const now = timestamp(io);
        source.metadata.ctime_ns = now;
        if (source.metadata.kind == .directory and old_parent_inode != new_parent_inode)
            source.parent_inode = new_parent_inode;
        touchParent(&old_parent, now);
        if (old_parent_inode == new_parent_inode) {
            new_parent = old_parent;
        } else {
            touchParent(&new_parent, now);
        }
        if (source.metadata.kind == .directory) {
            if (old_parent_inode != new_parent_inode) {
                if (old_parent.nlink <= 2) return error.InvalidBlobFilesystemGraph;
                old_parent.nlink -= 1;
                if (victim == null)
                    new_parent.nlink = std.math.add(u64, new_parent.nlink, 1) catch
                        return error.TooManyLinks;
            } else if (victim != null and victim.?.metadata.kind == .directory) {
                if (new_parent.nlink <= 2) return error.InvalidBlobFilesystemGraph;
                new_parent.nlink -= 1;
            }
        }

        var mutations: MutationAccumulator = .init(self.allocator);
        defer mutations.deinit();
        try mutations.removeDentry(old_parent_inode, old_prepared.key);
        try mutations.putDentry(new_parent_inode, new_prepared.key, .{
            .child_inode = source_dentry.inode,
            .child_generation = source.generation,
            .kind = source.metadata.kind,
            .spelling = new_prepared.spelling,
        });
        try mutations.putInode(source_dentry.inode, source);
        try mutations.putInode(old_parent_inode, old_parent);
        if (old_parent_inode != new_parent_inode)
            try mutations.putInode(new_parent_inode, new_parent)
        else if (!std.meta.eql(old_parent, new_parent))
            try mutations.putInode(old_parent_inode, new_parent);

        var removed_records: u64 = 0;
        if (victim_dentry) |entry| {
            removed_records = 1;
            var record = victim.?;
            record.metadata.ctime_ns = now;
            if (record.metadata.kind == .directory) {
                try mutations.removeInode(entry.inode);
                removed_records += 1;
            } else {
                if (record.nlink == 0) return error.InvalidBlobFilesystemGraph;
                record.nlink -= 1;
                if (record.nlink == 0) {
                    try mutations.removeInode(entry.inode);
                    removed_records += 1;
                } else {
                    try mutations.putInode(entry.inode, record);
                }
            }
        }
        var next_root = self.root;
        next_root.generation = try nextGeneration(self.root.generation);
        next_root.record_count = std.math.sub(u64, next_root.record_count, removed_records) catch
            return error.InvalidBlobFilesystemGraph;
        try self.publish(io, next_root, &mutations);
        return .renamed;
    }

    fn createNode(
        self: *Filesystem,
        io: Io,
        parent_inode: u64,
        name: []const u8,
        kind: metadata.Kind,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !u64 {
        try self.transaction_mutex.lock(io);
        defer self.transaction_mutex.unlock(io);
        try self.requireMutable();
        var parent = try self.requireDirectory(io, parent_inode);
        var prepared = try PreparedName.init(self.allocator, self.root.name_profile, name);
        defer prepared.deinit(self.allocator);
        if (try self.lookupPrepared(io, parent_inode, prepared.key) != null)
            return error.PathAlreadyExists;
        const inode = self.root.next_inode;
        const following_inode = std.math.add(u64, inode, 1) catch return error.InodeExhausted;
        const generation = try nextGeneration(self.root.generation);
        const type_bits: u32 = switch (kind) {
            .file => 0o100000,
            .directory => 0o040000,
            .fifo => 0o010000,
            .symlink => unreachable,
        };
        const record: filesystem_format.InodeRecord = .{
            .metadata = metadata.Metadata.init(io, kind, type_bits | (mode & 0o7777), uid, gid),
            .generation = generation,
            .nlink = if (kind == .directory) 2 else 1,
            .allocated_bytes = 0,
            .parent_inode = if (kind == .directory) parent_inode else 0,
            .data = if (kind == .file) .{ .generation = 1, .logical_size = 0, .root = null } else null,
        };
        touchParent(&parent, timestamp(io));
        if (kind == .directory)
            parent.nlink = std.math.add(u64, parent.nlink, 1) catch return error.TooManyLinks;

        var mutations: MutationAccumulator = .init(self.allocator);
        defer mutations.deinit();
        try mutations.putInode(parent_inode, parent);
        try mutations.putInode(inode, record);
        try mutations.putDentry(parent_inode, prepared.key, .{
            .child_inode = inode,
            .child_generation = generation,
            .kind = kind,
            .spelling = prepared.spelling,
        });
        var next_root = self.root;
        next_root.generation = generation;
        next_root.next_inode = following_inode;
        next_root.record_count = std.math.add(u64, next_root.record_count, 2) catch
            return error.FilesystemRecordCountOverflow;
        try self.publish(io, next_root, &mutations);
        return inode;
    }

    fn removeNode(
        self: *Filesystem,
        io: Io,
        parent_inode: u64,
        name: []const u8,
        require_directory: ?bool,
    ) !void {
        try self.transaction_mutex.lock(io);
        defer self.transaction_mutex.unlock(io);
        try self.requireMutable();
        var parent = try self.requireDirectory(io, parent_inode);
        var prepared = try PreparedName.init(self.allocator, self.root.name_profile, name);
        defer prepared.deinit(self.allocator);
        const dentry = (try self.lookupPrepared(io, parent_inode, prepared.key)) orelse
            return error.FileNotFound;
        var record = (try self.loadInode(io, dentry.inode)) orelse
            return error.InvalidBlobFilesystemGraph;
        const is_directory = record.metadata.kind == .directory;
        if (require_directory) |required| {
            if (required and !is_directory) return error.NotDirectory;
            if (!required and is_directory) return error.IsDirectory;
        }
        if (is_directory and !try self.directoryIsEmpty(io, dentry.inode))
            return error.DirectoryNotEmpty;

        const now = timestamp(io);
        touchParent(&parent, now);
        if (is_directory) {
            if (parent.nlink <= 2) return error.InvalidBlobFilesystemGraph;
            parent.nlink -= 1;
        }
        var mutations: MutationAccumulator = .init(self.allocator);
        defer mutations.deinit();
        try mutations.removeDentry(parent_inode, prepared.key);
        try mutations.putInode(parent_inode, parent);
        var removed_records: u64 = 1;
        if (record.nlink == 0) return error.InvalidBlobFilesystemGraph;
        if (is_directory) {
            try mutations.removeInode(dentry.inode);
            removed_records += 1;
        } else {
            record.nlink -= 1;
            record.metadata.ctime_ns = now;
            if (record.nlink == 0) {
                try mutations.removeInode(dentry.inode);
                removed_records += 1;
            } else {
                try mutations.putInode(dentry.inode, record);
            }
        }
        var next_root = self.root;
        next_root.generation = try nextGeneration(self.root.generation);
        next_root.record_count = std.math.sub(u64, next_root.record_count, removed_records) catch
            return error.InvalidBlobFilesystemGraph;
        try self.publish(io, next_root, &mutations);
    }

    fn loadInode(self: *Filesystem, io: Io, inode: u64) !?filesystem_format.InodeRecord {
        const key = filesystem_format.inodeKey(inode) catch return error.FileNotFound;
        var maps = metadata_map_store.MapStore.init(self.allocator, &self.blobs);
        const value = try maps.lookupAlloc(io, self.root.metadata_root, self.root.generation, &key) orelse
            return null;
        defer self.allocator.free(value);
        if (value.len != filesystem_format.inode_encoded_size)
            return error.InvalidBlobFilesystemGraph;
        return filesystem_format.decodeInode(@ptrCast(value.ptr)) catch
            return error.InvalidBlobFilesystemGraph;
    }

    fn requireDirectory(self: *Filesystem, io: Io, inode: u64) !filesystem_format.InodeRecord {
        const record = (try self.loadInode(io, inode)) orelse return error.FileNotFound;
        if (record.metadata.kind != .directory) return error.NotDirectory;
        if (record.nlink == 0) return error.FileNotFound;
        return record;
    }

    fn dentrySpellingEquals(
        self: *Filesystem,
        io: Io,
        parent_inode: u64,
        key_name: []const u8,
        spelling: []const u8,
    ) !bool {
        var key_buffer: [filesystem_format.max_key_size]u8 = undefined;
        const key = try filesystem_format.dentryKey(&key_buffer, parent_inode, key_name);
        var maps = metadata_map_store.MapStore.init(self.allocator, &self.blobs);
        const value = try maps.lookupAlloc(io, self.root.metadata_root, self.root.generation, key) orelse
            return error.FileNotFound;
        defer self.allocator.free(value);
        const dentry = filesystem_format.decodeDentry(value) catch
            return error.InvalidBlobFilesystemGraph;
        return std.mem.eql(u8, dentry.spelling, spelling);
    }

    fn lookupPrepared(self: *Filesystem, io: Io, parent_inode: u64, key_name: []const u8) !?LookupResult {
        var key_buffer: [filesystem_format.max_key_size]u8 = undefined;
        const key = try filesystem_format.dentryKey(&key_buffer, parent_inode, key_name);
        var maps = metadata_map_store.MapStore.init(self.allocator, &self.blobs);
        const value = try maps.lookupAlloc(io, self.root.metadata_root, self.root.generation, key) orelse
            return null;
        defer self.allocator.free(value);
        const dentry = filesystem_format.decodeDentry(value) catch
            return error.InvalidBlobFilesystemGraph;
        return .{ .inode = dentry.child_inode, .generation = dentry.child_generation, .kind = dentry.kind };
    }

    fn directoryIsEmpty(self: *Filesystem, io: Io, inode: u64) !bool {
        const prefix = try filesystem_format.dentryPrefix(inode);
        var maps = metadata_map_store.MapStore.init(self.allocator, &self.blobs);
        const entries = try maps.loadPrefixAlloc(io, self.root.metadata_root, self.root.generation, &prefix);
        defer metadata_map_store.deinitEntries(self.allocator, entries);
        return entries.len == 0;
    }

    fn preventDirectoryCycle(self: *Filesystem, io: Io, source_inode: u64, parent_inode: u64) !void {
        var current = parent_inode;
        while (true) {
            if (current == source_inode) return error.InvalidArgument;
            if (current == filesystem_format.root_inode) return;
            const record = try self.requireDirectory(io, current);
            current = record.parent_inode;
        }
    }

    fn publish(
        self: *Filesystem,
        io: Io,
        next_root_value: filesystem_format.Root,
        mutations: *MutationAccumulator,
    ) !void {
        const checkpoint = self.blobs.stagedUnits();
        const sorted = try mutations.sortedViews();
        defer self.allocator.free(sorted);
        var maps = metadata_map_store.MapStore.init(self.allocator, &self.blobs);
        var next_root = next_root_value;
        next_root.metadata_root = maps.applyBatch(
            io,
            self.root.metadata_root,
            self.root.generation,
            next_root.generation,
            sorted,
        ) catch |err| {
            self.rollback(io, checkpoint);
            return err;
        };
        const root_bytes = filesystem_format.encodeRoot(next_root) catch |err| {
            self.rollback(io, checkpoint);
            return err;
        };
        const authority_ref = self.blobs.put(io, &root_bytes) catch |err| {
            self.rollback(io, checkpoint);
            return err;
        };
        self.blobs.commitAuthority(io, authority_ref) catch |err| {
            self.frozen = true;
            return err;
        };
        self.root = next_root;
        self.authority_ref = authority_ref;
    }

    fn rollback(self: *Filesystem, io: Io, checkpoint: u64) void {
        self.blobs.discardStaged(io, checkpoint) catch {
            self.frozen = true;
        };
    }

    fn requireMutable(self: *const Filesystem) !void {
        if (self.frozen) return error.BlobFilesystemFrozen;
    }
};

const PreparedName = struct {
    spelling: []const u8,
    key: []const u8,
    portable: ?name_profile.PreparedComponent = null,

    fn init(allocator: std.mem.Allocator, profile: name_profile.Profile, input: []const u8) !PreparedName {
        return switch (profile) {
            .legacy_raw => legacy: {
                if (input.len == 0 or input.len > filesystem_format.max_name_bytes or
                    std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..") or
                    std.mem.indexOfAny(u8, input, &.{ 0, '/' }) != null)
                    return error.InvalidName;
                break :legacy .{ .spelling = input, .key = input };
            },
            .portable_v1 => portable: {
                const value = try name_profile.preparePortableV1(allocator, input);
                break :portable .{ .spelling = value.spelling, .key = value.key, .portable = value };
            },
        };
    }

    fn deinit(self: *PreparedName, allocator: std.mem.Allocator) void {
        if (self.portable) |value| value.deinit(allocator);
        self.* = undefined;
    }
};

const OwnedMutation = struct {
    key: []u8,
    value: ?[]u8,
};

const MutationAccumulator = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(OwnedMutation) = .empty,

    fn init(allocator: std.mem.Allocator) MutationAccumulator {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MutationAccumulator) void {
        for (self.items.items) |item| {
            if (item.value) |value| self.allocator.free(value);
            self.allocator.free(item.key);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    fn putInode(self: *MutationAccumulator, inode: u64, record: filesystem_format.InodeRecord) !void {
        const key = try filesystem_format.inodeKey(inode);
        const value = try filesystem_format.encodeInode(record);
        try self.set(&key, &value);
    }

    fn removeInode(self: *MutationAccumulator, inode: u64) !void {
        const key = try filesystem_format.inodeKey(inode);
        try self.set(&key, null);
    }

    fn putDentry(
        self: *MutationAccumulator,
        parent_inode: u64,
        lookup_name: []const u8,
        record: filesystem_format.DentryRecord,
    ) !void {
        var key_buffer: [filesystem_format.max_key_size]u8 = undefined;
        const key = try filesystem_format.dentryKey(&key_buffer, parent_inode, lookup_name);
        var value_buffer: [filesystem_format.max_dentry_size]u8 = undefined;
        const value = try filesystem_format.encodeDentry(&value_buffer, record);
        try self.set(key, value);
    }

    fn removeDentry(self: *MutationAccumulator, parent_inode: u64, lookup_name: []const u8) !void {
        var key_buffer: [filesystem_format.max_key_size]u8 = undefined;
        const key = try filesystem_format.dentryKey(&key_buffer, parent_inode, lookup_name);
        try self.set(key, null);
    }

    fn set(self: *MutationAccumulator, key: []const u8, value: ?[]const u8) !void {
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.key, key)) continue;
            const replacement = if (value) |bytes| try self.allocator.dupe(u8, bytes) else null;
            if (item.value) |old| self.allocator.free(old);
            item.value = replacement;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = if (value) |bytes| try self.allocator.dupe(u8, bytes) else null;
        errdefer if (owned_value) |bytes| self.allocator.free(bytes);
        try self.items.append(self.allocator, .{ .key = owned_key, .value = owned_value });
    }

    fn sortedViews(self: *MutationAccumulator) ![]metadata_map_store.Mutation {
        std.mem.sort(OwnedMutation, self.items.items, {}, struct {
            fn lessThan(_: void, left: OwnedMutation, right: OwnedMutation) bool {
                return std.mem.order(u8, left.key, right.key) == .lt;
            }
        }.lessThan);
        const result = try self.allocator.alloc(metadata_map_store.Mutation, self.items.items.len);
        for (self.items.items, result) |item, *mutation| mutation.* = if (item.value) |value|
            .{ .put = .{ .key = item.key, .value = value } }
        else
            .{ .remove = item.key };
        return result;
    }
};

fn timestamp(io: Io) i64 {
    return @intCast(Io.Clock.real.now(io).nanoseconds);
}

fn touchParent(record: *filesystem_format.InodeRecord, now: i64) void {
    record.metadata.mtime_ns = now;
    record.metadata.ctime_ns = now;
}

fn nextGeneration(generation: u64) !u64 {
    return std.math.add(u64, generation, 1) catch error.FilesystemGenerationExhausted;
}

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

test "blob filesystem namespace transactions preserve inode and directory semantics" {
    const blob_device = @import("blob_device.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 64 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "namespace",
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
    defer filesystem.close(std.testing.io) catch {};

    const root_inode = filesystem_format.root_inode;
    const alpha = try filesystem.createDirectory(std.testing.io, root_inode, "Alpha", 0o750, 10, 20);
    const file = try filesystem.createFile(std.testing.io, alpha, "e\u{301}.TXT", 0o640, 11, 21);
    const fifo = try filesystem.createFifo(std.testing.io, root_inode, "Pipe", 0o622, 12, 22);
    try std.testing.expectEqual(alpha, (try filesystem.lookup(std.testing.io, root_inode, "ALPHA")).?.inode);
    try std.testing.expectEqual(file, (try filesystem.lookup(std.testing.io, alpha, "\u{e9}.txt")).?.inode);
    try std.testing.expectEqual(fifo, (try filesystem.lookup(std.testing.io, root_inode, "pipe")).?.inode);
    var canonical_name = try name_profile.preparePortableV1(std.testing.allocator, "e\u{301}.TXT");
    defer canonical_name.deinit(std.testing.allocator);
    var dentry_key_buffer: [filesystem_format.max_key_size]u8 = undefined;
    const dentry_key = try filesystem_format.dentryKey(&dentry_key_buffer, alpha, canonical_name.key);
    var maps = metadata_map_store.MapStore.init(std.testing.allocator, &filesystem.blobs);
    const dentry_value = (try maps.lookupAlloc(
        std.testing.io,
        filesystem.root.metadata_root,
        filesystem.root.generation,
        dentry_key,
    )).?;
    defer std.testing.allocator.free(dentry_value);
    try std.testing.expectEqualStrings("\u{e9}.TXT", (try filesystem_format.decodeDentry(dentry_value)).spelling);

    const file_initial = try filesystem.stat(std.testing.io, file);
    try std.testing.expectEqual(metadata.Kind.file, file_initial.metadata.kind);
    try std.testing.expectEqual(@as(u32, 0o100640), file_initial.metadata.mode);
    try std.testing.expectEqual(@as(u64, 1), file_initial.nlink);
    try std.testing.expectEqual(@as(u64, 1), file_initial.data.?.generation);
    try std.testing.expectEqual(@as(u64, 0), file_initial.data.?.logical_size);
    try std.testing.expect(file_initial.data.?.root == null);
    try std.testing.expectEqual(@as(u32, 0o010622), (try filesystem.stat(std.testing.io, fifo)).metadata.mode);
    try std.testing.expectEqual(@as(u64, 3), (try filesystem.stat(std.testing.io, root_inode)).nlink);
    try std.testing.expectEqual(@as(u64, 2), (try filesystem.stat(std.testing.io, alpha)).nlink);

    try filesystem.link(std.testing.io, file, root_inode, "Alias");
    try filesystem.link(std.testing.io, file, root_inode, "Second");
    try std.testing.expectEqual(@as(u64, 3), (try filesystem.stat(std.testing.io, file)).nlink);
    try filesystem.unlink(std.testing.io, alpha, "\u{e9}.TXT");
    const linked = try filesystem.stat(std.testing.io, file);
    try std.testing.expectEqual(@as(u64, 2), linked.nlink);
    try std.testing.expectEqual(file_initial.generation, linked.generation);

    const generation_before_noop = filesystem.root.generation;
    try std.testing.expectError(
        error.PathAlreadyExists,
        filesystem.rename(std.testing.io, root_inode, "Alias", root_inode, "Second", true),
    );
    try std.testing.expectEqual(generation_before_noop, filesystem.root.generation);
    try std.testing.expectEqual(
        Filesystem.RenameResult.same_object,
        try filesystem.rename(std.testing.io, root_inode, "Alias", root_inode, "Second", false),
    );
    try std.testing.expectEqual(generation_before_noop, filesystem.root.generation);
    try std.testing.expectError(
        error.PathAlreadyExists,
        filesystem.rename(std.testing.io, root_inode, "Alias", root_inode, "Pipe", true),
    );
    try std.testing.expectEqual(generation_before_noop, filesystem.root.generation);

    const victim = try filesystem.createFile(std.testing.io, root_inode, "Victim", 0o600, 1, 2);
    try std.testing.expectEqual(
        Filesystem.RenameResult.renamed,
        try filesystem.rename(std.testing.io, root_inode, "Alias", root_inode, "Victim", false),
    );
    try std.testing.expectEqual(@as(?Filesystem.LookupResult, null), try filesystem.lookup(
        std.testing.io,
        root_inode,
        "Alias",
    ));
    try std.testing.expectEqual(file, (try filesystem.lookup(std.testing.io, root_inode, "Victim")).?.inode);
    try std.testing.expectError(error.FileNotFound, filesystem.stat(std.testing.io, victim));
    try std.testing.expectEqual(@as(u64, 2), (try filesystem.stat(std.testing.io, file)).nlink);

    const left = try filesystem.createDirectory(std.testing.io, root_inode, "Left", 0o755, 0, 0);
    const right = try filesystem.createDirectory(std.testing.io, root_inode, "Right", 0o755, 0, 0);
    const child = try filesystem.createDirectory(std.testing.io, left, "Child", 0o755, 0, 0);
    try std.testing.expectEqual(@as(u64, 3), (try filesystem.stat(std.testing.io, left)).nlink);
    try std.testing.expectEqual(
        Filesystem.RenameResult.renamed,
        try filesystem.rename(std.testing.io, left, "Child", right, "Moved", false),
    );
    try std.testing.expectEqual(right, (try filesystem.stat(std.testing.io, child)).parent_inode);
    try std.testing.expectEqual(@as(u64, 2), (try filesystem.stat(std.testing.io, left)).nlink);
    try std.testing.expectEqual(@as(u64, 3), (try filesystem.stat(std.testing.io, right)).nlink);

    const first_empty = try filesystem.createDirectory(std.testing.io, root_inode, "FirstEmpty", 0o755, 0, 0);
    const second_empty = try filesystem.createDirectory(std.testing.io, root_inode, "SecondEmpty", 0o755, 0, 0);
    const root_links_before_replace = (try filesystem.stat(std.testing.io, root_inode)).nlink;
    try std.testing.expectEqual(
        Filesystem.RenameResult.renamed,
        try filesystem.rename(std.testing.io, root_inode, "FirstEmpty", root_inode, "SecondEmpty", false),
    );
    try std.testing.expectEqual(first_empty, (try filesystem.lookup(std.testing.io, root_inode, "SecondEmpty")).?.inode);
    try std.testing.expectError(error.FileNotFound, filesystem.stat(std.testing.io, second_empty));
    try std.testing.expectEqual(root_links_before_replace - 1, (try filesystem.stat(std.testing.io, root_inode)).nlink);

    _ = try filesystem.createFile(std.testing.io, child, "inside", 0o644, 0, 0);
    try std.testing.expectError(error.DirectoryNotEmpty, filesystem.rmdir(std.testing.io, right, "Moved"));
    const replacement = try filesystem.createDirectory(std.testing.io, root_inode, "Replacement", 0o755, 0, 0);
    try std.testing.expectError(
        error.DirectoryNotEmpty,
        filesystem.rename(std.testing.io, root_inode, "Replacement", right, "Moved", false),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        filesystem.rename(std.testing.io, root_inode, "Right", child, "Loop", false),
    );
    try std.testing.expectError(
        error.IsDirectory,
        filesystem.rename(std.testing.io, root_inode, "Pipe", root_inode, "Left", false),
    );
    try std.testing.expectError(error.IsDirectory, filesystem.unlink(std.testing.io, root_inode, "Left"));
    try std.testing.expectError(error.NotDirectory, filesystem.rmdir(std.testing.io, root_inode, "Pipe"));
    try std.testing.expectEqual(replacement, (try filesystem.lookup(std.testing.io, root_inode, "replacement")).?.inode);
    const generation_before_case_rename = filesystem.root.generation;
    try std.testing.expectEqual(
        Filesystem.RenameResult.renamed,
        try filesystem.rename(std.testing.io, root_inode, "Replacement", root_inode, "REPLACEMENT", false),
    );
    try std.testing.expect(filesystem.root.generation > generation_before_case_rename);
    var replacement_name = try name_profile.preparePortableV1(std.testing.allocator, "REPLACEMENT");
    defer replacement_name.deinit(std.testing.allocator);
    const replacement_key = try filesystem_format.dentryKey(
        &dentry_key_buffer,
        root_inode,
        replacement_name.key,
    );
    const replacement_value = (try maps.lookupAlloc(
        std.testing.io,
        filesystem.root.metadata_root,
        filesystem.root.generation,
        replacement_key,
    )).?;
    defer std.testing.allocator.free(replacement_value);
    try std.testing.expectEqualStrings(
        "REPLACEMENT",
        (try filesystem_format.decodeDentry(replacement_value)).spelling,
    );
    try expectValidGraph(&filesystem, std.testing.io);
}

test "blob filesystem commits canonical namespace and reopens a valid graph" {
    const blob_device = @import("blob_device.zig");
    const storage_api = @import("v3/storage.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 32 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "namespace-reopen",
        device_size,
        blob_format.allocation_unit,
    );
    const blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var filesystem = try Filesystem.format(
        std.testing.allocator,
        std.testing.io,
        blobs,
        .legacy_raw,
    );
    var filesystem_open = true;
    defer if (filesystem_open) filesystem.close(std.testing.io) catch {};
    const root_inode = filesystem_format.root_inode;
    const directory = try filesystem.createDirectory(std.testing.io, root_inode, "Mixed", 0o755, 1, 2);
    const removed = try filesystem.createFile(std.testing.io, directory, "File", 0o644, 3, 4);
    try std.testing.expectEqual(@as(?Filesystem.LookupResult, null), try filesystem.lookup(
        std.testing.io,
        root_inode,
        "mixed",
    ));
    try filesystem.remove(std.testing.io, directory, "File");
    try std.testing.expectError(error.FileNotFound, filesystem.stat(std.testing.io, removed));
    try filesystem.rmdir(std.testing.io, root_inode, "Mixed");
    try std.testing.expectError(error.FileNotFound, filesystem.stat(std.testing.io, directory));
    try std.testing.expectEqual(@as(u64, 1), filesystem.root.record_count);
    try expectValidGraph(&filesystem, std.testing.io);
    const committed_root = filesystem.root;
    const committed_authority = filesystem.authority_ref;
    try filesystem.close(std.testing.io);
    filesystem_open = false;

    const file = try tmp.dir.openFile(std.testing.io, "namespace-reopen", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = storage_api.Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, blob_format.allocation_unit);
    file_open = false;
    const reopened_blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    filesystem = try Filesystem.open(std.testing.allocator, std.testing.io, reopened_blobs);
    filesystem_open = true;
    try std.testing.expectEqualDeep(committed_root, filesystem.root);
    try std.testing.expectEqualDeep(committed_authority, filesystem.authority_ref);
    try std.testing.expectEqual(@as(u64, 2), (try filesystem.stat(std.testing.io, root_inode)).nlink);
    try expectValidGraph(&filesystem, std.testing.io);
}

test "blob filesystem pre-publication failure discards only its staged tail" {
    const blob_device = @import("blob_device.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 2 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "namespace-rollback",
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
    defer filesystem.close(std.testing.io) catch {};

    const available_units = filesystem.blobs.header.unit_count - filesystem.blobs.stagedUnits();
    const filler_units = available_units - 1;
    const filler = try std.testing.allocator.alloc(u8, @intCast(filler_units * blob_format.allocation_unit));
    defer std.testing.allocator.free(filler);
    @memset(filler, 0x5a);
    _ = try filesystem.blobs.put(std.testing.io, filler);
    const checkpoint = filesystem.blobs.stagedUnits();
    const root_before = filesystem.root;
    try std.testing.expectError(
        error.BlobStoreFull,
        filesystem.createFile(std.testing.io, filesystem_format.root_inode, "file", 0o644, 0, 0),
    );
    try std.testing.expectEqual(checkpoint, filesystem.blobs.stagedUnits());
    try std.testing.expectEqualDeep(root_before, filesystem.root);
    try std.testing.expect(!filesystem.frozen);
    try std.testing.expectEqual(@as(?Filesystem.LookupResult, null), try filesystem.lookup(
        std.testing.io,
        filesystem_format.root_inode,
        "file",
    ));
    try expectValidGraph(&filesystem, std.testing.io);
}

fn expectValidGraph(filesystem: *Filesystem, io: Io) !void {
    var maps = metadata_map_store.MapStore.init(std.testing.allocator, &filesystem.blobs);
    const entries = try maps.loadAllAlloc(io, filesystem.root.metadata_root, filesystem.root.generation);
    defer metadata_map_store.deinitEntries(std.testing.allocator, entries);
    try validateGraph(std.testing.allocator, io, &filesystem.blobs, filesystem.root, entries);
}
