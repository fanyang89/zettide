const std = @import("std");
const blob_file = @import("blob_file.zig");
const blob_format = @import("blob_format.zig");
const blob_map = @import("blob_map.zig");
const google_crc32c = @import("crc32c");
const metadata = @import("metadata.zig");
const name_profile = @import("name_profile.zig");

pub const root_encoded_size: usize = 256;
pub const inode_encoded_size: usize = 192;
pub const orphan_encoded_size: usize = 16;
pub const max_name_bytes: usize = name_profile.max_utf8_bytes;
pub const max_lookup_name_bytes: usize = 4 * max_name_bytes;
pub const max_key_size: usize = 1 + @sizeOf(u64) + max_lookup_name_bytes;
pub const max_dentry_size: usize = 24 + max_name_bytes;
pub const root_inode: u64 = 1;

const root_magic = [8]u8{ 'Z', 'T', 'F', 'S', 'R', 'T', '0', '1' };
const root_version: u16 = 1;
const root_checksum_offset = root_encoded_size - @sizeOf(u32);
const inode_flag_data_root: u8 = 1 << 0;
const inode_supported_flags = inode_flag_data_root;

pub const KeyKind = enum(u8) {
    inode = 1,
    dentry = 2,
    orphan = 3,
};

pub const TreeRef = struct {
    page: u64,
    level: u8,
    digest: [32]u8,
};

pub const Root = struct {
    generation: u64,
    next_inode: u64,
    record_count: u64,
    orphan_count: u64,
    name_profile: name_profile.Profile,
    metadata_root: TreeRef,

    pub fn validate(self: Root) !void {
        if (self.generation == 0 or self.next_inode <= root_inode or
            self.record_count == 0 or self.orphan_count > self.record_count)
            return error.InvalidBlobFilesystemRoot;
    }
};

pub const InodeRecord = struct {
    metadata: metadata.Metadata,
    generation: u64,
    nlink: u64,
    allocated_bytes: u64,
    parent_inode: u64,
    data: ?blob_file.Snapshot,

    pub fn validate(self: InodeRecord) !void {
        if (self.generation == 0 or self.allocated_bytes % blob_file.block_size != 0)
            return error.InvalidBlobFilesystemInode;
        const expected_type: u32 = switch (self.metadata.kind) {
            .file => 0o100000,
            .directory => 0o040000,
            .symlink => 0o120000,
            .fifo => 0o010000,
        };
        if (self.metadata.mode & 0o170000 != expected_type)
            return error.InvalidBlobFilesystemInode;
        switch (self.metadata.kind) {
            .directory => {
                if (self.parent_inode == 0 or self.data != null or self.allocated_bytes != 0 or
                    (self.nlink != 0 and self.nlink < 2))
                    return error.InvalidBlobFilesystemInode;
            },
            .fifo => if (self.parent_inode != 0 or self.data != null or self.allocated_bytes != 0)
                return error.InvalidBlobFilesystemInode,
            .file, .symlink => {
                if (self.parent_inode != 0 or self.data == null)
                    return error.InvalidBlobFilesystemInode;
                const snapshot = self.data.?;
                if (snapshot.generation == 0 or snapshot.logical_size > std.math.maxInt(i64))
                    return error.InvalidBlobFilesystemInode;
                const block_count = std.math.divCeil(u64, snapshot.logical_size, blob_file.block_size) catch
                    return error.InvalidBlobFilesystemInode;
                const maximum_allocated = std.math.mul(u64, block_count, blob_file.block_size) catch
                    return error.InvalidBlobFilesystemInode;
                if (self.allocated_bytes > maximum_allocated)
                    return error.InvalidBlobFilesystemInode;
                if (snapshot.root) |root| {
                    if (snapshot.logical_size == 0 or self.allocated_bytes == 0 or
                        root.first_key > root.last_key or root.last_key >= block_count)
                        return error.InvalidBlobFilesystemInode;
                    const allocated_blocks = self.allocated_bytes / blob_file.block_size;
                    const minimum_blocks: u64 = if (root.first_key == root.last_key) 1 else 2;
                    const maximum_blocks = root.last_key - root.first_key + 1;
                    if (allocated_blocks < minimum_blocks or allocated_blocks > maximum_blocks)
                        return error.InvalidBlobFilesystemInode;
                } else if (self.allocated_bytes != 0) {
                    return error.InvalidBlobFilesystemInode;
                }
            },
        }
    }
};

pub const DentryRecord = struct {
    child_inode: u64,
    child_generation: u64,
    kind: metadata.Kind,
    spelling: []const u8,
};

/// A decoded dentry borrows `spelling` from its input buffer.
pub const DentryView = DentryRecord;

pub const DecodedKey = union(KeyKind) {
    inode: u64,
    dentry: struct {
        parent_inode: u64,
        lookup_name: []const u8,
    },
    orphan: u64,
};

pub const OrphanRecord = struct {
    generation: u64,
    kind: metadata.Kind,
};

pub fn encodeRoot(root: Root) ![root_encoded_size]u8 {
    try root.validate();
    var bytes: [root_encoded_size]u8 = @splat(0);
    @memcpy(bytes[0..8], &root_magic);
    putInt(u16, &bytes, 8, root_version, .little);
    putInt(u16, &bytes, 10, root_encoded_size, .little);
    putInt(u64, &bytes, 16, root.generation, .little);
    putInt(u64, &bytes, 24, root_inode, .little);
    putInt(u64, &bytes, 32, root.next_inode, .little);
    putInt(u64, &bytes, 40, root.record_count, .little);
    putInt(u64, &bytes, 48, root.orphan_count, .little);
    putInt(u16, &bytes, 56, root.name_profile.persistedId(), .little);
    putInt(u16, &bytes, 58, root.name_profile.persistedVersion(), .little);
    putInt(u64, &bytes, 64, root.metadata_root.page, .little);
    bytes[72] = root.metadata_root.level;
    @memcpy(bytes[80..112], &root.metadata_root.digest);
    putInt(u32, &bytes, root_checksum_offset, google_crc32c.value(bytes[0..root_checksum_offset]), .little);
    return bytes;
}

pub fn decodeRoot(bytes: *const [root_encoded_size]u8) !Root {
    if (!std.mem.eql(u8, bytes[0..8], &root_magic) or
        getInt(u16, bytes, 8, .little) != root_version or
        getInt(u16, bytes, 10, .little) != root_encoded_size or
        getInt(u64, bytes, 24, .little) != root_inode or
        !std.mem.allEqual(u8, bytes[12..16], 0) or
        !std.mem.allEqual(u8, bytes[60..64], 0) or
        !std.mem.allEqual(u8, bytes[73..80], 0) or
        !std.mem.allEqual(u8, bytes[112..root_checksum_offset], 0) or
        getInt(u32, bytes, root_checksum_offset, .little) != google_crc32c.value(bytes[0..root_checksum_offset]))
        return error.InvalidBlobFilesystemRoot;
    const root: Root = .{
        .generation = getInt(u64, bytes, 16, .little),
        .next_inode = getInt(u64, bytes, 32, .little),
        .record_count = getInt(u64, bytes, 40, .little),
        .orphan_count = getInt(u64, bytes, 48, .little),
        .name_profile = name_profile.Profile.fromPersisted(
            getInt(u16, bytes, 56, .little),
            getInt(u16, bytes, 58, .little),
        ) catch return error.InvalidBlobFilesystemRoot,
        .metadata_root = .{
            .page = getInt(u64, bytes, 64, .little),
            .level = bytes[72],
            .digest = bytes[80..112].*,
        },
    };
    try root.validate();
    return root;
}

pub fn encodeInode(record: InodeRecord) ![inode_encoded_size]u8 {
    try record.validate();
    var bytes: [inode_encoded_size]u8 = @splat(0);
    @memcpy(bytes[0..metadata.encoded_size], &record.metadata.encode());
    putInt(u64, &bytes, 64, record.generation, .little);
    putInt(u64, &bytes, 72, record.nlink, .little);
    putInt(u64, &bytes, 80, record.allocated_bytes, .little);
    putInt(u64, &bytes, 88, record.parent_inode, .little);
    if (record.data) |snapshot| {
        putInt(u64, &bytes, 96, snapshot.generation, .little);
        putInt(u64, &bytes, 104, snapshot.logical_size, .little);
        if (snapshot.root) |root| {
            bytes[169] = inode_flag_data_root;
            putInt(u64, &bytes, 112, root.page, .little);
            putInt(u64, &bytes, 120, root.first_key, .little);
            putInt(u64, &bytes, 128, root.last_key, .little);
            @memcpy(bytes[136..168], &root.digest);
            bytes[168] = root.level;
        }
    }
    putInt(u32, &bytes, 188, google_crc32c.value(bytes[0..188]), .little);
    return bytes;
}

pub fn decodeInode(bytes: *const [inode_encoded_size]u8) !InodeRecord {
    if (bytes[169] & ~inode_supported_flags != 0 or
        !std.mem.allEqual(u8, bytes[170..188], 0) or
        getInt(u32, bytes, 188, .little) != google_crc32c.value(bytes[0..188]))
        return error.InvalidBlobFilesystemInode;
    const value_metadata = metadata.Metadata.decode(bytes[0..metadata.encoded_size]) catch
        return error.InvalidBlobFilesystemInode;
    if (!std.mem.allEqual(u8, bytes[2..4], 0) or !std.mem.allEqual(u8, bytes[52..60], 0))
        return error.InvalidBlobFilesystemInode;
    const has_data = value_metadata.kind == .file or value_metadata.kind == .symlink;
    const record: InodeRecord = .{
        .metadata = value_metadata,
        .generation = getInt(u64, bytes, 64, .little),
        .nlink = getInt(u64, bytes, 72, .little),
        .allocated_bytes = getInt(u64, bytes, 80, .little),
        .parent_inode = getInt(u64, bytes, 88, .little),
        .data = if (has_data) .{
            .generation = getInt(u64, bytes, 96, .little),
            .logical_size = getInt(u64, bytes, 104, .little),
            .root = if (bytes[169] & inode_flag_data_root != 0) .{
                .page = getInt(u64, bytes, 112, .little),
                .level = bytes[168],
                .first_key = getInt(u64, bytes, 120, .little),
                .last_key = getInt(u64, bytes, 128, .little),
                .digest = bytes[136..168].*,
            } else null,
        } else null,
    };
    if (!has_data and !std.mem.allEqual(u8, bytes[96..170], 0))
        return error.InvalidBlobFilesystemInode;
    if (has_data and bytes[169] & inode_flag_data_root == 0 and
        !std.mem.allEqual(u8, bytes[112..169], 0))
        return error.InvalidBlobFilesystemInode;
    try record.validate();
    return record;
}

pub fn inodeKey(inode: u64) ![9]u8 {
    return fixedKey(.inode, inode);
}

pub fn orphanKey(inode: u64) ![9]u8 {
    return fixedKey(.orphan, inode);
}

pub fn dentryKey(output: *[max_key_size]u8, parent_inode: u64, lookup_name: []const u8) ![]const u8 {
    if (parent_inode == 0) return error.InvalidBlobFilesystemKey;
    try validateLookupName(lookup_name);
    output[0] = @intFromEnum(KeyKind.dentry);
    std.mem.writeInt(u64, output[1..9], parent_inode, .big);
    @memcpy(output[9..][0..lookup_name.len], lookup_name);
    return output[0 .. 9 + lookup_name.len];
}

pub fn decodeKey(key: []const u8) !DecodedKey {
    if (key.len < 9) return error.InvalidBlobFilesystemKey;
    const kind = std.enums.fromInt(KeyKind, key[0]) orelse return error.InvalidBlobFilesystemKey;
    const inode = std.mem.readInt(u64, key[1..9], .big);
    if (inode == 0) return error.InvalidBlobFilesystemKey;
    return switch (kind) {
        .inode => if (key.len == 9) .{ .inode = inode } else error.InvalidBlobFilesystemKey,
        .orphan => if (key.len == 9) .{ .orphan = inode } else error.InvalidBlobFilesystemKey,
        .dentry => dentry: {
            validateLookupName(key[9..]) catch return error.InvalidBlobFilesystemKey;
            break :dentry .{ .dentry = .{ .parent_inode = inode, .lookup_name = key[9..] } };
        },
    };
}

pub fn encodeDentry(output: *[max_dentry_size]u8, record: DentryRecord) ![]const u8 {
    if (record.child_inode == 0 or record.child_generation == 0)
        return error.InvalidBlobFilesystemDentry;
    validateSpelling(record.spelling) catch return error.InvalidBlobFilesystemDentry;
    var spelling: [max_name_bytes]u8 = undefined;
    @memcpy(spelling[0..record.spelling.len], record.spelling);
    @memset(output, 0);
    putInt(u64, output, 0, record.child_inode, .little);
    putInt(u64, output, 8, record.child_generation, .little);
    putInt(u16, output, 16, @intCast(record.spelling.len), .little);
    output[18] = @intFromEnum(record.kind);
    @memcpy(output[24..][0..record.spelling.len], spelling[0..record.spelling.len]);
    return output[0 .. 24 + record.spelling.len];
}

pub fn decodeDentry(bytes: []const u8) !DentryView {
    if (bytes.len < 24 or bytes.len > max_dentry_size or
        !std.mem.allEqual(u8, bytes[19..24], 0))
        return error.InvalidBlobFilesystemDentry;
    const spelling_len: usize = std.mem.readInt(u16, bytes[16..18], .little);
    if (spelling_len > max_name_bytes) return error.InvalidBlobFilesystemDentry;
    if (bytes.len != 24 + spelling_len) return error.InvalidBlobFilesystemDentry;
    const record: DentryRecord = .{
        .child_inode = std.mem.readInt(u64, bytes[0..8], .little),
        .child_generation = std.mem.readInt(u64, bytes[8..16], .little),
        .kind = std.enums.fromInt(metadata.Kind, bytes[18]) orelse
            return error.InvalidBlobFilesystemDentry,
        .spelling = bytes[24..],
    };
    if (record.child_inode == 0 or record.child_generation == 0)
        return error.InvalidBlobFilesystemDentry;
    validateSpelling(record.spelling) catch return error.InvalidBlobFilesystemDentry;
    return record;
}

pub fn validateDentryIdentity(
    allocator: std.mem.Allocator,
    profile: name_profile.Profile,
    lookup_name: []const u8,
    record: DentryRecord,
) !void {
    validateLookupName(lookup_name) catch return error.InvalidBlobFilesystemDentry;
    validateSpelling(record.spelling) catch return error.InvalidBlobFilesystemDentry;
    switch (profile) {
        .legacy_raw => if (!std.mem.eql(u8, lookup_name, record.spelling))
            return error.InvalidBlobFilesystemDentry,
        .portable_v1 => {
            var prepared = name_profile.preparePortableV1(allocator, record.spelling) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidBlobFilesystemDentry,
            };
            defer prepared.deinit(allocator);
            if (prepared.key.len > max_lookup_name_bytes or
                !std.mem.eql(u8, prepared.spelling, record.spelling) or
                !std.mem.eql(u8, prepared.key, lookup_name))
                return error.InvalidBlobFilesystemDentry;
        },
    }
}

pub fn encodeOrphan(record: OrphanRecord) ![orphan_encoded_size]u8 {
    if (record.generation == 0) return error.InvalidBlobFilesystemOrphan;
    var bytes: [orphan_encoded_size]u8 = @splat(0);
    std.mem.writeInt(u64, bytes[0..8], record.generation, .little);
    bytes[8] = @intFromEnum(record.kind);
    return bytes;
}

pub fn decodeOrphan(bytes: *const [orphan_encoded_size]u8) !OrphanRecord {
    const record: OrphanRecord = .{
        .generation = std.mem.readInt(u64, bytes[0..8], .little),
        .kind = std.enums.fromInt(metadata.Kind, bytes[8]) orelse
            return error.InvalidBlobFilesystemOrphan,
    };
    if (record.generation == 0 or !std.mem.allEqual(u8, bytes[9..], 0))
        return error.InvalidBlobFilesystemOrphan;
    return record;
}

fn fixedKey(kind: KeyKind, inode: u64) ![9]u8 {
    if (inode == 0) return error.InvalidBlobFilesystemKey;
    var key: [9]u8 = undefined;
    key[0] = @intFromEnum(kind);
    std.mem.writeInt(u64, key[1..9], inode, .big);
    return key;
}

fn validateSpelling(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_bytes or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, &.{ 0, '/' }) != null)
        return error.InvalidBlobFilesystemKey;
}

fn validateLookupName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_lookup_name_bytes or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, &.{ 0, '/' }) != null)
        return error.InvalidBlobFilesystemKey;
}

fn putInt(comptime T: type, bytes: []u8, offset: usize, value: T, endian: std.builtin.Endian) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, endian);
}

fn getInt(comptime T: type, bytes: []const u8, offset: usize, endian: std.builtin.Endian) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], endian);
}

test "blob filesystem root round trips and rejects corruption" {
    const root: Root = .{
        .generation = 7,
        .next_inode = 42,
        .record_count = 10,
        .orphan_count = 1,
        .name_profile = .portable_v1,
        .metadata_root = .{ .page = 8, .level = 2, .digest = @splat(0x5a) },
    };
    const encoded = try encodeRoot(root);
    try std.testing.expectEqualDeep(root, try decodeRoot(&encoded));

    var corrupt = encoded;
    corrupt[80] ^= 1;
    try std.testing.expectError(error.InvalidBlobFilesystemRoot, decodeRoot(&corrupt));
}

test "blob filesystem inode records preserve sparse snapshots" {
    const file: InodeRecord = .{
        .metadata = .{
            .kind = .file,
            .mode = 0o100644,
            .uid = 1000,
            .gid = 1000,
            .atime_ns = 1,
            .mtime_ns = 2,
            .ctime_ns = 3,
            .birthtime_ns = 4,
        },
        .generation = 5,
        .nlink = 1,
        .allocated_bytes = blob_format.allocation_unit,
        .parent_inode = 0,
        .data = .{
            .generation = 3,
            .logical_size = 3 * blob_format.allocation_unit,
            .root = .{
                .page = 9,
                .level = 0,
                .first_key = 2,
                .last_key = 2,
                .digest = @splat(0x33),
            },
        },
    };
    try std.testing.expectEqualDeep(file, try decodeInode(&try encodeInode(file)));

    var sparse = file;
    sparse.allocated_bytes = 0;
    sparse.data.?.root = null;
    try std.testing.expectEqualDeep(sparse, try decodeInode(&try encodeInode(sparse)));

    var invalid = file;
    invalid.data.?.root.?.last_key = 3;
    try std.testing.expectError(error.InvalidBlobFilesystemInode, encodeInode(invalid));
}

test "blob filesystem keys sort and dentry records preserve spelling" {
    const inode_two = try inodeKey(2);
    const inode_ten = try inodeKey(10);
    try std.testing.expect(std.mem.order(u8, &inode_two, &inode_ten) == .lt);

    var first_buffer: [max_key_size]u8 = undefined;
    const first = try dentryKey(&first_buffer, 4, "alpha");
    var second_buffer: [max_key_size]u8 = undefined;
    const second = try dentryKey(&second_buffer, 5, "alpha");
    try std.testing.expect(std.mem.order(u8, first, second) == .lt);
    const decoded_key = try decodeKey(first);
    try std.testing.expectEqual(@as(u64, 4), decoded_key.dentry.parent_inode);
    try std.testing.expectEqualStrings("alpha", decoded_key.dentry.lookup_name);

    var value_buffer: [max_dentry_size]u8 = undefined;
    const encoded = try encodeDentry(&value_buffer, .{
        .child_inode = 9,
        .child_generation = 2,
        .kind = .directory,
        .spelling = "Alpha",
    });
    const decoded = try decodeDentry(encoded);
    try std.testing.expectEqual(@as(u64, 9), decoded.child_inode);
    try std.testing.expectEqual(metadata.Kind.directory, decoded.kind);
    try std.testing.expectEqualStrings("Alpha", decoded.spelling);
    try std.testing.expectError(error.InvalidBlobFilesystemKey, dentryKey(&first_buffer, 4, ".."));
    try validateDentryIdentity(std.testing.allocator, .portable_v1, "alpha", decoded);
    try std.testing.expectError(
        error.InvalidBlobFilesystemDentry,
        validateDentryIdentity(std.testing.allocator, .portable_v1, "wrong", decoded),
    );

    const expanded_spelling = "İ" ** 127;
    var prepared = try name_profile.preparePortableV1(std.testing.allocator, expanded_spelling);
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expect(prepared.key.len > max_name_bytes);
    _ = try dentryKey(&first_buffer, 4, prepared.key);

    var corrupt_value: [24]u8 = @splat(0);
    std.mem.writeInt(u16, corrupt_value[16..18], std.math.maxInt(u16), .little);
    try std.testing.expectError(error.InvalidBlobFilesystemDentry, decodeDentry(&corrupt_value));
}

test "blob filesystem orphan records round trip" {
    const orphan: OrphanRecord = .{ .generation = 12, .kind = .symlink };
    try std.testing.expectEqualDeep(orphan, try decodeOrphan(&try encodeOrphan(orphan)));
}
