//! Stable filesystem metadata record and tree key encodings.

const std = @import("std");
const store = @import("store.zig");

pub const InodeId = u64;
pub const root_inode_id: InodeId = 1;
pub const max_name_size: usize = 255;
pub const format_version: u16 = 1;
pub const extent_mapping_format_version: u16 = 2;

pub const filesystem_root_size: usize = 256;
pub const inode_record_size: usize = 128;
pub const directory_entry_size: usize = 64;
pub const extent_mapping_size: usize = 160;
pub const inode_key_size: usize = 8;
pub const directory_key_max_size: usize = inode_key_size + max_name_size;
pub const extent_key_size: usize = 16;

pub const EncodedFilesystemRoot = [filesystem_root_size]u8;
pub const EncodedInode = [inode_record_size]u8;
pub const EncodedDirectoryEntry = [directory_entry_size]u8;
pub const EncodedExtentMapping = [extent_mapping_size]u8;
pub const InodeKey = [inode_key_size]u8;
pub const DirectoryKeyBuffer = [directory_key_max_size]u8;
pub const ExtentKey = [extent_key_size]u8;

pub const Kind = enum(u8) {
    file = 1,
    directory = 2,
};

pub const FilesystemRoot = struct {
    root_inode_id: InodeId,
    next_inode_id: InodeId,
    inode_tree_root: store.ObjectRef,
    directory_tree_root: store.ObjectRef,
    extent_tree_root: store.ObjectRef,
};

pub const Inode = struct {
    kind: Kind,
    inode_id: InodeId,
    logical_size: u64,
    allocated_bytes: u64,
    link_count: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    atime_ns: u64,
    mtime_ns: u64,
    ctime_ns: u64,
    birthtime_ns: u64,
};

pub const DirectoryEntry = struct {
    child_kind: Kind,
    parent_inode_id: InodeId,
    child_inode_id: InodeId,
};

pub const ExtentMapping = struct {
    inode_id: InodeId,
    logical_offset: u64,
    byte_length: u64,
    data_ref: store.ObjectRef,
};

pub const DirectoryKeyView = struct {
    parent_inode_id: InodeId,
    name: []const u8,
};

pub const ExtentKeyView = struct {
    inode_id: InodeId,
    logical_offset: u64,
};

pub const Error = error{
    InvalidSize,
    InvalidMagic,
    UnsupportedFormatVersion,
    InvalidFlags,
    NonCanonicalEncoding,
    ChecksumMismatch,
    InvalidRootInodeId,
    InvalidNextInodeId,
    InvalidKind,
    InvalidInodeId,
    InvalidAllocatedBytes,
    InvalidDirectorySize,
    InvalidLinkCount,
    InvalidByteLength,
    LogicalRangeOverflow,
    InvalidName,
    BufferTooSmall,
    KeyValueMismatch,
};

const filesystem_root_magic = "ZCAWFR\x00\x00";
const inode_magic = "ZCAWIN\x00\x00";
const directory_entry_magic = "ZCAWDE\x00\x00";
const extent_mapping_magic = "ZCAWEX\x00\x00";
const checksum_size = std.crypto.hash.sha2.Sha256.digest_length;

comptime {
    std.debug.assert(@sizeOf(store.ObjectRef) == store.object_ref_size);
    std.debug.assert(store.object_ref_size == 64);
    std.debug.assert(filesystem_root_size - checksum_size == 224);
    std.debug.assert(inode_record_size - checksum_size == 96);
    std.debug.assert(directory_entry_size - checksum_size == 32);
    std.debug.assert(extent_mapping_size - checksum_size == 128);
}

pub fn encodeFilesystemRoot(root: FilesystemRoot) Error!EncodedFilesystemRoot {
    try validateFilesystemRoot(root);
    var encoded = initRecord(filesystem_root_size, filesystem_root_magic);
    putInt(u64, &encoded, 16, root.root_inode_id);
    putInt(u64, &encoded, 24, root.next_inode_id);
    @memcpy(encoded[32..96], &root.inode_tree_root.bytes);
    @memcpy(encoded[96..160], &root.directory_tree_root.bytes);
    @memcpy(encoded[160..224], &root.extent_tree_root.bytes);
    seal(&encoded);
    return encoded;
}

pub fn decodeFilesystemRoot(bytes: []const u8) Error!FilesystemRoot {
    if (bytes.len != filesystem_root_size) return error.InvalidSize;
    const encoded: *const EncodedFilesystemRoot = @ptrCast(bytes.ptr);
    try validateCommonHeader(encoded, filesystem_root_magic);
    if (getInt(u16, encoded, 10) != 0) return error.InvalidFlags;
    try verifyChecksum(encoded);

    const root = FilesystemRoot{
        .root_inode_id = getInt(u64, encoded, 16),
        .next_inode_id = getInt(u64, encoded, 24),
        .inode_tree_root = objectRef(encoded[32..96]),
        .directory_tree_root = objectRef(encoded[96..160]),
        .extent_tree_root = objectRef(encoded[160..224]),
    };
    try validateFilesystemRoot(root);
    return root;
}

pub fn encodeInode(inode: Inode) Error!EncodedInode {
    try validateInode(inode);
    var encoded = initRecord(inode_record_size, inode_magic);
    encoded[10] = @intFromEnum(inode.kind);
    putInt(u64, &encoded, 16, inode.inode_id);
    putInt(u64, &encoded, 24, inode.logical_size);
    putInt(u64, &encoded, 32, inode.allocated_bytes);
    putInt(u64, &encoded, 40, inode.link_count);
    putInt(u32, &encoded, 48, inode.mode);
    putInt(u32, &encoded, 52, inode.uid);
    putInt(u32, &encoded, 56, inode.gid);
    putInt(u64, &encoded, 64, inode.atime_ns);
    putInt(u64, &encoded, 72, inode.mtime_ns);
    putInt(u64, &encoded, 80, inode.ctime_ns);
    putInt(u64, &encoded, 88, inode.birthtime_ns);
    seal(&encoded);
    return encoded;
}

pub fn decodeInode(bytes: []const u8) Error!Inode {
    if (bytes.len != inode_record_size) return error.InvalidSize;
    const encoded: *const EncodedInode = @ptrCast(bytes.ptr);
    try validateCommonHeader(encoded, inode_magic);
    const kind = std.enums.fromInt(Kind, encoded[10]) orelse return error.InvalidKind;
    if (encoded[11] != 0) return error.InvalidFlags;
    if (getInt(u32, encoded, 60) != 0) return error.NonCanonicalEncoding;
    try verifyChecksum(encoded);

    const inode = Inode{
        .kind = kind,
        .inode_id = getInt(u64, encoded, 16),
        .logical_size = getInt(u64, encoded, 24),
        .allocated_bytes = getInt(u64, encoded, 32),
        .link_count = getInt(u64, encoded, 40),
        .mode = getInt(u32, encoded, 48),
        .uid = getInt(u32, encoded, 52),
        .gid = getInt(u32, encoded, 56),
        .atime_ns = getInt(u64, encoded, 64),
        .mtime_ns = getInt(u64, encoded, 72),
        .ctime_ns = getInt(u64, encoded, 80),
        .birthtime_ns = getInt(u64, encoded, 88),
    };
    try validateInode(inode);
    return inode;
}

pub fn encodeDirectoryEntry(entry: DirectoryEntry) Error!EncodedDirectoryEntry {
    try validateDirectoryEntry(entry);
    var encoded = initRecord(directory_entry_size, directory_entry_magic);
    encoded[10] = @intFromEnum(entry.child_kind);
    putInt(u64, &encoded, 16, entry.parent_inode_id);
    putInt(u64, &encoded, 24, entry.child_inode_id);
    seal(&encoded);
    return encoded;
}

pub fn decodeDirectoryEntry(bytes: []const u8) Error!DirectoryEntry {
    if (bytes.len != directory_entry_size) return error.InvalidSize;
    const encoded: *const EncodedDirectoryEntry = @ptrCast(bytes.ptr);
    try validateCommonHeader(encoded, directory_entry_magic);
    const child_kind = std.enums.fromInt(Kind, encoded[10]) orelse return error.InvalidKind;
    if (encoded[11] != 0) return error.InvalidFlags;
    try verifyChecksum(encoded);

    const entry = DirectoryEntry{
        .child_kind = child_kind,
        .parent_inode_id = getInt(u64, encoded, 16),
        .child_inode_id = getInt(u64, encoded, 24),
    };
    try validateDirectoryEntry(entry);
    return entry;
}

pub fn encodeExtentMapping(mapping: ExtentMapping) Error!EncodedExtentMapping {
    try validateExtentMapping(mapping);
    var encoded = initRecordVersion(
        extent_mapping_size,
        extent_mapping_magic,
        extent_mapping_format_version,
    );
    putInt(u64, &encoded, 16, mapping.inode_id);
    putInt(u64, &encoded, 24, mapping.logical_offset);
    putInt(u64, &encoded, 32, mapping.byte_length);
    @memcpy(encoded[40..104], &mapping.data_ref.bytes);
    seal(&encoded);
    return encoded;
}

pub fn decodeExtentMapping(bytes: []const u8) Error!ExtentMapping {
    if (bytes.len != extent_mapping_size) return error.InvalidSize;
    const encoded: *const EncodedExtentMapping = @ptrCast(bytes.ptr);
    try validateCommonHeaderVersion(
        encoded,
        extent_mapping_magic,
        extent_mapping_format_version,
    );
    if (getInt(u16, encoded, 10) != 0) return error.InvalidFlags;
    if (!allZero(encoded[104..128])) return error.NonCanonicalEncoding;
    try verifyChecksum(encoded);

    const mapping = ExtentMapping{
        .inode_id = getInt(u64, encoded, 16),
        .logical_offset = getInt(u64, encoded, 24),
        .byte_length = getInt(u64, encoded, 32),
        .data_ref = objectRef(encoded[40..104]),
    };
    try validateExtentMapping(mapping);
    return mapping;
}

pub fn encodeInodeKey(inode_id: InodeId) Error!InodeKey {
    if (inode_id == 0) return error.InvalidInodeId;
    var encoded: InodeKey = undefined;
    std.mem.writeInt(u64, &encoded, inode_id, .big);
    return encoded;
}

pub fn decodeInodeKey(bytes: []const u8) Error!InodeId {
    if (bytes.len != inode_key_size) return error.InvalidSize;
    const inode_id = std.mem.readInt(u64, bytes[0..inode_key_size], .big);
    if (inode_id == 0) return error.InvalidInodeId;
    return inode_id;
}

pub fn encodeDirectoryKey(
    output: []u8,
    parent_inode_id: InodeId,
    name: []const u8,
) Error![]const u8 {
    if (parent_inode_id == 0) return error.InvalidInodeId;
    try validateName(name);
    const size = inode_key_size + name.len;
    if (output.len < size) return error.BufferTooSmall;
    std.mem.writeInt(u64, output[0..inode_key_size], parent_inode_id, .big);
    @memcpy(output[inode_key_size..size], name);
    return output[0..size];
}

pub fn decodeDirectoryKey(bytes: []const u8) Error!DirectoryKeyView {
    if (bytes.len <= inode_key_size or bytes.len > directory_key_max_size)
        return error.InvalidSize;
    const parent_inode_id = std.mem.readInt(u64, bytes[0..inode_key_size], .big);
    if (parent_inode_id == 0) return error.InvalidInodeId;
    const name = bytes[inode_key_size..];
    try validateName(name);
    return .{ .parent_inode_id = parent_inode_id, .name = name };
}

pub fn encodeExtentKey(inode_id: InodeId, logical_offset: u64) Error!ExtentKey {
    if (inode_id == 0) return error.InvalidInodeId;
    var encoded: ExtentKey = undefined;
    std.mem.writeInt(u64, encoded[0..8], inode_id, .big);
    std.mem.writeInt(u64, encoded[8..16], logical_offset, .big);
    return encoded;
}

pub fn decodeExtentKey(bytes: []const u8) Error!ExtentKeyView {
    if (bytes.len != extent_key_size) return error.InvalidSize;
    const inode_id = std.mem.readInt(u64, bytes[0..8], .big);
    if (inode_id == 0) return error.InvalidInodeId;
    return .{
        .inode_id = inode_id,
        .logical_offset = std.mem.readInt(u64, bytes[8..16], .big),
    };
}

pub fn validateInodeKeyValue(key: []const u8, inode: Inode) Error!void {
    if (try decodeInodeKey(key) != inode.inode_id) return error.KeyValueMismatch;
}

pub fn validateDirectoryKeyValue(key: []const u8, entry: DirectoryEntry) Error!void {
    if ((try decodeDirectoryKey(key)).parent_inode_id != entry.parent_inode_id)
        return error.KeyValueMismatch;
}

pub fn validateExtentKeyValue(key: []const u8, mapping: ExtentMapping) Error!void {
    const decoded = try decodeExtentKey(key);
    if (decoded.inode_id != mapping.inode_id or decoded.logical_offset != mapping.logical_offset)
        return error.KeyValueMismatch;
}

fn validateFilesystemRoot(root: FilesystemRoot) Error!void {
    if (root.root_inode_id != root_inode_id) return error.InvalidRootInodeId;
    if (root.next_inode_id < root_inode_id + 1) return error.InvalidNextInodeId;
}

fn validateInode(inode: Inode) Error!void {
    if (inode.inode_id == 0) return error.InvalidInodeId;
    switch (inode.kind) {
        .file => if (inode.allocated_bytes > inode.logical_size)
            return error.InvalidAllocatedBytes,
        .directory => if (inode.logical_size != 0 or inode.allocated_bytes != 0)
            return error.InvalidDirectorySize,
    }
    if (inode.link_count == 0) return error.InvalidLinkCount;
}

fn validateDirectoryEntry(entry: DirectoryEntry) Error!void {
    if (entry.parent_inode_id == 0 or entry.child_inode_id == 0)
        return error.InvalidInodeId;
}

fn validateExtentMapping(mapping: ExtentMapping) Error!void {
    if (mapping.inode_id == 0) return error.InvalidInodeId;
    if (mapping.byte_length == 0) return error.InvalidByteLength;
    _ = std.math.add(u64, mapping.logical_offset, mapping.byte_length) catch
        return error.LogicalRangeOverflow;
}

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_size) return error.InvalidName;
    for (name) |byte| if (byte == 0 or byte == '/') return error.InvalidName;
}

fn initRecord(comptime size: usize, magic: *const [8]u8) [size]u8 {
    return initRecordVersion(size, magic, format_version);
}

fn initRecordVersion(comptime size: usize, magic: *const [8]u8, version: u16) [size]u8 {
    var encoded: [size]u8 = @splat(0);
    @memcpy(encoded[0..8], magic);
    putInt(u16, &encoded, 8, version);
    putInt(u16, &encoded, 12, size);
    return encoded;
}

fn validateCommonHeader(encoded: anytype, magic: *const [8]u8) Error!void {
    return validateCommonHeaderVersion(encoded, magic, format_version);
}

fn validateCommonHeaderVersion(encoded: anytype, magic: *const [8]u8, version: u16) Error!void {
    if (!std.mem.eql(u8, encoded[0..8], magic)) return error.InvalidMagic;
    if (getInt(u16, encoded, 8) != version) return error.UnsupportedFormatVersion;
    if (getInt(u16, encoded, 12) != encoded.len or getInt(u16, encoded, 14) != 0)
        return error.NonCanonicalEncoding;
}

fn objectRef(bytes: *const [store.object_ref_size]u8) store.ObjectRef {
    return .{ .bytes = bytes.* };
}

fn putInt(comptime T: type, bytes: anytype, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
}

fn getInt(comptime T: type, bytes: anytype, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}

fn seal(encoded: anytype) void {
    const start = encoded.len - checksum_size;
    checksum(encoded, encoded[start..][0..checksum_size]);
}

fn verifyChecksum(encoded: anytype) Error!void {
    const start = encoded.len - checksum_size;
    var expected: [checksum_size]u8 = undefined;
    checksum(encoded, &expected);
    if (!std.mem.eql(u8, encoded[start..], &expected)) return error.ChecksumMismatch;
}

fn checksum(encoded: anytype, output: *[checksum_size]u8) void {
    const start = encoded.len - checksum_size;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(encoded[0..start]);
    hasher.update(&([_]u8{0} ** checksum_size));
    hasher.final(output);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn patternedRef(seed: u8) store.ObjectRef {
    var result: store.ObjectRef = .{};
    for (&result.bytes, 0..) |*byte, index| byte.* = seed +% @as(u8, @truncate(index));
    return result;
}

fn testInode(kind: Kind) Inode {
    return .{
        .kind = kind,
        .inode_id = 7,
        .logical_size = if (kind == .file) 4096 else 0,
        .allocated_bytes = if (kind == .file) 2048 else 0,
        .link_count = 2,
        .mode = 0o100644,
        .uid = 1000,
        .gid = 1001,
        .atime_ns = 11,
        .mtime_ns = 12,
        .ctime_ns = 13,
        .birthtime_ns = 14,
    };
}

fn testExtentMapping() ExtentMapping {
    return .{
        .inode_id = 7,
        .logical_offset = 4096,
        .byte_length = 8192,
        .data_ref = patternedRef(0x40),
    };
}

test "filesystem metadata records round trip" {
    const root = FilesystemRoot{
        .root_inode_id = root_inode_id,
        .next_inode_id = 8,
        .inode_tree_root = patternedRef(1),
        .directory_tree_root = patternedRef(65),
        .extent_tree_root = patternedRef(129),
    };
    const decoded_root = try decodeFilesystemRoot(&(try encodeFilesystemRoot(root)));
    try std.testing.expectEqual(root.root_inode_id, decoded_root.root_inode_id);
    try std.testing.expectEqual(root.next_inode_id, decoded_root.next_inode_id);
    try std.testing.expect(store.ObjectRef.eql(root.inode_tree_root, decoded_root.inode_tree_root));
    try std.testing.expect(store.ObjectRef.eql(root.directory_tree_root, decoded_root.directory_tree_root));
    try std.testing.expect(store.ObjectRef.eql(root.extent_tree_root, decoded_root.extent_tree_root));

    const inode = testInode(.file);
    try std.testing.expectEqual(inode, try decodeInode(&(try encodeInode(inode))));
    const entry = DirectoryEntry{
        .child_kind = .directory,
        .parent_inode_id = 1,
        .child_inode_id = 7,
    };
    try std.testing.expectEqual(entry, try decodeDirectoryEntry(&(try encodeDirectoryEntry(entry))));
    const mapping = testExtentMapping();
    try std.testing.expectEqual(mapping, try decodeExtentMapping(&(try encodeExtentMapping(mapping))));

    const empty_roots = try encodeFilesystemRoot(.{
        .root_inode_id = root_inode_id,
        .next_inode_id = 2,
        .inode_tree_root = .{},
        .directory_tree_root = .{},
        .extent_tree_root = .{},
    });
    _ = try decodeFilesystemRoot(&empty_roots);
}

test "filesystem root v1 encoding matches the golden vector" {
    const root = FilesystemRoot{
        .root_inode_id = root_inode_id,
        .next_inode_id = 0x0102030405060708,
        .inode_tree_root = patternedRef(0),
        .directory_tree_root = patternedRef(64),
        .extent_tree_root = patternedRef(128),
    };
    const encoded = try encodeFilesystemRoot(root);
    var expected: EncodedFilesystemRoot = @splat(0);
    @memcpy(expected[0..8], filesystem_root_magic);
    expected[9] = 1;
    expected[12] = 1;
    expected[23] = 1;
    expected[24..32].* = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    @memcpy(expected[32..96], &root.inode_tree_root.bytes);
    @memcpy(expected[96..160], &root.directory_tree_root.bytes);
    @memcpy(expected[160..224], &root.extent_tree_root.bytes);
    @memcpy(expected[224..256], &[_]u8{
        0xdb, 0xcd, 0x90, 0xa3, 0x10, 0xae, 0xf2, 0x46,
        0x19, 0x29, 0xcf, 0xfd, 0x8a, 0xe9, 0x05, 0x31,
        0xf1, 0xfa, 0xf5, 0x75, 0x03, 0xf9, 0x76, 0xe9,
        0x1c, 0xcd, 0x7a, 0xc1, 0x1a, 0xa2, 0x1e, 0x17,
    });
    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    _ = try decodeFilesystemRoot(&expected);
}

test "inode v1 encoding matches the golden vector" {
    const inode = Inode{
        .kind = .file,
        .inode_id = 0x0102030405060708,
        .logical_size = 0x1112131415161718,
        .allocated_bytes = 0x0101010101010101,
        .link_count = 2,
        .mode = 0x21222324,
        .uid = 0x31323334,
        .gid = 0x41424344,
        .atime_ns = 0x5152535455565758,
        .mtime_ns = 0x6162636465666768,
        .ctime_ns = 0x7172737475767778,
        .birthtime_ns = 0x8182838485868788,
    };
    const encoded = try encodeInode(inode);
    var expected: EncodedInode = @splat(0);
    @memcpy(expected[0..8], inode_magic);
    expected[9] = 1;
    expected[10] = 1;
    expected[13] = 128;
    expected[16..24].* = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    expected[24..32].* = .{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 };
    expected[32..40].* = @splat(1);
    expected[47] = 2;
    expected[48..52].* = .{ 0x21, 0x22, 0x23, 0x24 };
    expected[52..56].* = .{ 0x31, 0x32, 0x33, 0x34 };
    expected[56..60].* = .{ 0x41, 0x42, 0x43, 0x44 };
    expected[64..72].* = .{ 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58 };
    expected[72..80].* = .{ 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68 };
    expected[80..88].* = .{ 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78 };
    expected[88..96].* = .{ 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88 };
    @memcpy(expected[96..128], &[_]u8{
        0x5d, 0x7d, 0xe6, 0xb3, 0x1d, 0x16, 0x21, 0xf9,
        0xc7, 0x69, 0xc4, 0x57, 0xf8, 0x15, 0x50, 0x8d,
        0x4f, 0xe1, 0x67, 0x7f, 0x2f, 0xbd, 0x04, 0xe4,
        0xf5, 0xa0, 0x3a, 0x30, 0x9d, 0x86, 0x4f, 0xca,
    });
    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    _ = try decodeInode(&expected);
}

test "directory entry v1 encoding matches the golden vector" {
    const entry = DirectoryEntry{
        .child_kind = .directory,
        .parent_inode_id = 0x0102030405060708,
        .child_inode_id = 0x1112131415161718,
    };
    const encoded = try encodeDirectoryEntry(entry);
    var expected: EncodedDirectoryEntry = @splat(0);
    @memcpy(expected[0..8], directory_entry_magic);
    expected[9] = 1;
    expected[10] = 2;
    expected[13] = 64;
    expected[16..24].* = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    expected[24..32].* = .{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 };
    @memcpy(expected[32..64], &[_]u8{
        0x9b, 0x31, 0x2e, 0xf4, 0xf2, 0x93, 0x37, 0xa2,
        0x7f, 0x09, 0x7d, 0x8f, 0x49, 0xfb, 0x0b, 0xbe,
        0x5d, 0x2e, 0x92, 0xfd, 0x70, 0x28, 0x3d, 0x40,
        0x49, 0x6b, 0x88, 0x26, 0xe2, 0xc8, 0x36, 0xce,
    });
    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    _ = try decodeDirectoryEntry(&expected);
}

test "extent mapping v2 encoding matches the golden vector" {
    const mapping = ExtentMapping{
        .inode_id = 0x0102030405060708,
        .logical_offset = 0x1112131415161718,
        .byte_length = 0x0101010101010101,
        .data_ref = patternedRef(0x20),
    };
    const encoded = try encodeExtentMapping(mapping);
    var expected: EncodedExtentMapping = @splat(0);
    @memcpy(expected[0..8], extent_mapping_magic);
    expected[9] = 2;
    expected[12] = 0;
    expected[13] = 160;
    expected[16..24].* = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    expected[24..32].* = .{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 };
    expected[32..40].* = @splat(1);
    @memcpy(expected[40..104], &mapping.data_ref.bytes);
    @memcpy(expected[128..160], &[_]u8{
        0x59, 0x68, 0xe5, 0x42, 0x46, 0x4e, 0x8a, 0x5d,
        0x0b, 0xe6, 0x23, 0xa8, 0x86, 0xe8, 0x95, 0x14,
        0xe8, 0xc3, 0x0d, 0x71, 0xc7, 0xce, 0x8b, 0xa0,
        0xb6, 0xce, 0xc0, 0xd9, 0x27, 0x12, 0x37, 0xf8,
    });
    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    _ = try decodeExtentMapping(&expected);
}

test "metadata records reject invalid sizes and corruption" {
    var root = try encodeFilesystemRoot(.{
        .root_inode_id = root_inode_id,
        .next_inode_id = 2,
        .inode_tree_root = .{},
        .directory_tree_root = .{},
        .extent_tree_root = .{},
    });
    try std.testing.expectError(error.InvalidSize, decodeFilesystemRoot(root[0 .. root.len - 1]));
    root[24] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeFilesystemRoot(&root));

    var inode = try encodeInode(testInode(.file));
    try std.testing.expectError(error.InvalidSize, decodeInode(inode[0 .. inode.len - 1]));
    inode[24] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeInode(&inode));

    var entry = try encodeDirectoryEntry(.{
        .child_kind = .file,
        .parent_inode_id = 1,
        .child_inode_id = 2,
    });
    try std.testing.expectError(error.InvalidSize, decodeDirectoryEntry(entry[0 .. entry.len - 1]));
    entry[24] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeDirectoryEntry(&entry));

    var mapping = try encodeExtentMapping(testExtentMapping());
    try std.testing.expectError(error.InvalidSize, decodeExtentMapping(mapping[0 .. mapping.len - 1]));
    mapping[24] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeExtentMapping(&mapping));
}

test "metadata records reject unknown headers and noncanonical reserved bytes" {
    var root = try encodeFilesystemRoot(.{
        .root_inode_id = root_inode_id,
        .next_inode_id = 2,
        .inode_tree_root = .{},
        .directory_tree_root = .{},
        .extent_tree_root = .{},
    });
    root[11] = 1;
    seal(&root);
    try std.testing.expectError(error.InvalidFlags, decodeFilesystemRoot(&root));
    root[11] = 0;
    root[15] = 1;
    seal(&root);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeFilesystemRoot(&root));

    var inode = try encodeInode(testInode(.file));
    inode[11] = 1;
    seal(&inode);
    try std.testing.expectError(error.InvalidFlags, decodeInode(&inode));
    inode[11] = 0;
    inode[63] = 1;
    seal(&inode);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeInode(&inode));

    var entry = try encodeDirectoryEntry(.{
        .child_kind = .file,
        .parent_inode_id = 1,
        .child_inode_id = 2,
    });
    entry[11] = 1;
    seal(&entry);
    try std.testing.expectError(error.InvalidFlags, decodeDirectoryEntry(&entry));
    entry[11] = 0;
    entry[15] = 1;
    seal(&entry);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeDirectoryEntry(&entry));

    var mapping = try encodeExtentMapping(testExtentMapping());
    mapping[11] = 1;
    seal(&mapping);
    try std.testing.expectError(error.InvalidFlags, decodeExtentMapping(&mapping));
    mapping[11] = 0;
    mapping[104] = 1;
    seal(&mapping);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeExtentMapping(&mapping));
}

test "metadata records reject unsupported versions and encoded lengths" {
    var root = try encodeFilesystemRoot(.{
        .root_inode_id = root_inode_id,
        .next_inode_id = 2,
        .inode_tree_root = .{},
        .directory_tree_root = .{},
        .extent_tree_root = .{},
    });
    putInt(u16, &root, 8, format_version + 1);
    seal(&root);
    try std.testing.expectError(error.UnsupportedFormatVersion, decodeFilesystemRoot(&root));

    var inode = try encodeInode(testInode(.file));
    putInt(u16, &inode, 12, inode_record_size - 1);
    seal(&inode);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeInode(&inode));

    var entry = try encodeDirectoryEntry(.{
        .child_kind = .file,
        .parent_inode_id = 1,
        .child_inode_id = 2,
    });
    putInt(u16, &entry, 8, format_version + 1);
    seal(&entry);
    try std.testing.expectError(error.UnsupportedFormatVersion, decodeDirectoryEntry(&entry));

    var mapping = try encodeExtentMapping(testExtentMapping());
    putInt(u16, &mapping, 8, format_version);
    seal(&mapping);
    try std.testing.expectError(error.UnsupportedFormatVersion, decodeExtentMapping(&mapping));
    mapping = try encodeExtentMapping(testExtentMapping());
    putInt(u16, &mapping, 12, extent_mapping_size - 1);
    seal(&mapping);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeExtentMapping(&mapping));
}

test "metadata record invariants are enforced" {
    const root = FilesystemRoot{
        .root_inode_id = root_inode_id,
        .next_inode_id = 2,
        .inode_tree_root = .{},
        .directory_tree_root = .{},
        .extent_tree_root = .{},
    };
    var invalid_root = root;
    invalid_root.root_inode_id = 2;
    try std.testing.expectError(error.InvalidRootInodeId, encodeFilesystemRoot(invalid_root));
    invalid_root = root;
    invalid_root.next_inode_id = 1;
    try std.testing.expectError(error.InvalidNextInodeId, encodeFilesystemRoot(invalid_root));

    var inode = testInode(.file);
    inode.inode_id = 0;
    try std.testing.expectError(error.InvalidInodeId, encodeInode(inode));
    inode = testInode(.file);
    inode.allocated_bytes = inode.logical_size + 1;
    try std.testing.expectError(error.InvalidAllocatedBytes, encodeInode(inode));
    inode = testInode(.directory);
    inode.logical_size = 1;
    try std.testing.expectError(error.InvalidDirectorySize, encodeInode(inode));
    inode = testInode(.file);
    inode.link_count = 0;
    try std.testing.expectError(error.InvalidLinkCount, encodeInode(inode));

    try std.testing.expectError(error.InvalidInodeId, encodeDirectoryEntry(.{
        .child_kind = .file,
        .parent_inode_id = 0,
        .child_inode_id = 2,
    }));
    var encoded_inode = try encodeInode(testInode(.file));
    encoded_inode[10] = 0xff;
    seal(&encoded_inode);
    try std.testing.expectError(error.InvalidKind, decodeInode(&encoded_inode));
    var encoded_entry = try encodeDirectoryEntry(.{
        .child_kind = .file,
        .parent_inode_id = 1,
        .child_inode_id = 2,
    });
    encoded_entry[10] = 0xff;
    seal(&encoded_entry);
    try std.testing.expectError(error.InvalidKind, decodeDirectoryEntry(&encoded_entry));

    var mapping = testExtentMapping();
    mapping.byte_length = 0;
    try std.testing.expectError(error.InvalidByteLength, encodeExtentMapping(mapping));
    mapping = testExtentMapping();
    mapping.logical_offset = std.math.maxInt(u64);
    try std.testing.expectError(error.LogicalRangeOverflow, encodeExtentMapping(mapping));
    mapping = testExtentMapping();
    mapping.data_ref = .{};
    _ = try encodeExtentMapping(mapping);
}

test "filesystem tree keys round trip and validate repeated identities" {
    const inode_key = try encodeInodeKey(7);
    try std.testing.expectEqual(@as(InodeId, 7), try decodeInodeKey(&inode_key));
    try validateInodeKeyValue(&inode_key, testInode(.file));

    var directory_buffer: DirectoryKeyBuffer = undefined;
    const directory_key = try encodeDirectoryKey(&directory_buffer, 1, "alpha");
    const directory_view = try decodeDirectoryKey(directory_key);
    try std.testing.expectEqual(@as(InodeId, 1), directory_view.parent_inode_id);
    try std.testing.expectEqualStrings("alpha", directory_view.name);
    try validateDirectoryKeyValue(directory_key, .{
        .child_kind = .file,
        .parent_inode_id = 1,
        .child_inode_id = 7,
    });

    const extent_key = try encodeExtentKey(7, 4096);
    const extent_view = try decodeExtentKey(&extent_key);
    try std.testing.expectEqual(@as(InodeId, 7), extent_view.inode_id);
    try std.testing.expectEqual(@as(u64, 4096), extent_view.logical_offset);
    try validateExtentKeyValue(&extent_key, testExtentMapping());

    try std.testing.expectError(error.KeyValueMismatch, validateInodeKeyValue(
        &(try encodeInodeKey(8)),
        testInode(.file),
    ));
}

test "filesystem tree keys reject invalid identities names and lengths" {
    try std.testing.expectError(error.InvalidInodeId, encodeInodeKey(0));
    try std.testing.expectError(error.InvalidSize, decodeInodeKey(&[_]u8{1}));
    try std.testing.expectError(error.InvalidInodeId, decodeInodeKey(&([_]u8{0} ** 8)));

    var buffer: DirectoryKeyBuffer = undefined;
    try std.testing.expectError(error.InvalidInodeId, encodeDirectoryKey(&buffer, 0, "name"));
    try std.testing.expectError(error.InvalidName, encodeDirectoryKey(&buffer, 1, ""));
    try std.testing.expectError(error.InvalidName, encodeDirectoryKey(&buffer, 1, "a/b"));
    try std.testing.expectError(error.InvalidName, encodeDirectoryKey(&buffer, 1, "a\x00b"));
    try std.testing.expectError(error.BufferTooSmall, encodeDirectoryKey(buffer[0..8], 1, "a"));
    try std.testing.expectError(error.InvalidSize, decodeDirectoryKey(&([_]u8{0} ** 8)));
    const oversized_name = [_]u8{'a'} ** (max_name_size + 1);
    try std.testing.expectError(error.InvalidName, encodeDirectoryKey(&buffer, 1, &oversized_name));
    const maximum_name = [_]u8{'a'} ** max_name_size;
    const maximum_key = try encodeDirectoryKey(&buffer, 1, &maximum_name);
    try std.testing.expectEqual(directory_key_max_size, maximum_key.len);

    try std.testing.expectError(error.InvalidInodeId, encodeExtentKey(0, 0));
    try std.testing.expectError(error.InvalidSize, decodeExtentKey(&([_]u8{0} ** 15)));
}

test "big-endian tree keys preserve numeric bytewise ordering" {
    const inode_one = try encodeInodeKey(1);
    const inode_two = try encodeInodeKey(2);
    const inode_large = try encodeInodeKey(0x0100);
    try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, &inode_one, &inode_two));
    try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, &inode_two, &inode_large));

    const extent_low = try encodeExtentKey(1, 2);
    const extent_high_offset = try encodeExtentKey(1, 0x0100);
    const extent_next_inode = try encodeExtentKey(2, 0);
    try std.testing.expectEqual(
        std.math.Order.lt,
        std.mem.order(u8, &extent_low, &extent_high_offset),
    );
    try std.testing.expectEqual(
        std.math.Order.lt,
        std.mem.order(u8, &extent_high_offset, &extent_next_inode),
    );

    var first_buffer: DirectoryKeyBuffer = undefined;
    var second_buffer: DirectoryKeyBuffer = undefined;
    const first = try encodeDirectoryKey(&first_buffer, 1, "z");
    const second = try encodeDirectoryKey(&second_buffer, 2, "a");
    try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, first, second));
}
