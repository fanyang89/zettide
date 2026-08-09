const std = @import("std");
const filesystem_format = @import("blob_filesystem_format.zig");
const google_crc32c = @import("crc32c");

pub const page_size: usize = 4096;
pub const header_size: usize = 64;
pub const checksum_offset: usize = page_size - @sizeOf(u32);
pub const max_entries: usize = 128;
pub const internal_prefix_size: usize = 52;

const magic = [8]u8{ 'Z', 'T', 'M', 'E', 'T', 'A', '0', '1' };
const version: u16 = 1;

pub const Kind = enum(u8) {
    leaf = 1,
    internal = 2,
};

pub const Header = struct {
    kind: Kind,
    level: u8,
    count: u16,
    generation: u64,
};

pub const LeafEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const InternalEntry = struct {
    upper_key: []const u8,
    child: filesystem_format.TreeRef,
};

pub fn encodeLeaf(generation: u64, entries: []const LeafEntry) ![page_size]u8 {
    try validateEntryCount(generation, entries.len);
    for (entries, 0..) |entry, index| {
        try validateLeafEntry(entry);
        if (index != 0 and std.mem.order(u8, entries[index - 1].key, entry.key) != .lt)
            return error.UnsortedBlobMetadataEntries;
    }

    var bytes: [page_size]u8 = @splat(0);
    var cell_start = checksum_offset;
    for (entries, 0..) |entry, index| {
        const cell_size = 4 + entry.key.len + entry.value.len;
        if (cell_size > cell_start or cell_start - cell_size < header_size + 2 * entries.len)
            return error.BlobMetadataPageFull;
        cell_start -= cell_size;
        std.mem.writeInt(u16, bytes[header_size + 2 * index ..][0..2], @intCast(cell_start), .little);
        std.mem.writeInt(u16, bytes[cell_start..][0..2], @intCast(entry.key.len), .little);
        std.mem.writeInt(u16, bytes[cell_start + 2 ..][0..2], @intCast(entry.value.len), .little);
        @memcpy(bytes[cell_start + 4 ..][0..entry.key.len], entry.key);
        @memcpy(bytes[cell_start + 4 + entry.key.len ..][0..entry.value.len], entry.value);
    }
    finishPage(&bytes, .{
        .kind = .leaf,
        .level = 0,
        .count = @intCast(entries.len),
        .generation = generation,
    }, cell_start);
    return bytes;
}

pub fn encodeInternal(level: u8, generation: u64, entries: []const InternalEntry) ![page_size]u8 {
    if (level == 0) return error.InvalidBlobMetadataPage;
    try validateEntryCount(generation, entries.len);
    for (entries, 0..) |entry, index| {
        _ = filesystem_format.decodeKey(entry.upper_key) catch return error.InvalidBlobMetadataEntry;
        if (entry.child.level == std.math.maxInt(u8) or entry.child.level + 1 != level)
            return error.InvalidBlobMetadataEntry;
        for (entries[0..index]) |previous| if (previous.child.page == entry.child.page)
            return error.InvalidBlobMetadataEntry;
        if (index != 0 and std.mem.order(u8, entries[index - 1].upper_key, entry.upper_key) != .lt)
            return error.UnsortedBlobMetadataEntries;
    }

    var bytes: [page_size]u8 = @splat(0);
    var cell_start = checksum_offset;
    for (entries, 0..) |entry, index| {
        const cell_size = internal_prefix_size + entry.upper_key.len;
        if (cell_size > cell_start or cell_start - cell_size < header_size + 2 * entries.len)
            return error.BlobMetadataPageFull;
        cell_start -= cell_size;
        std.mem.writeInt(u16, bytes[header_size + 2 * index ..][0..2], @intCast(cell_start), .little);
        std.mem.writeInt(u16, bytes[cell_start..][0..2], @intCast(entry.upper_key.len), .little);
        std.mem.writeInt(u64, bytes[cell_start + 4 ..][0..8], entry.child.page, .little);
        bytes[cell_start + 12] = entry.child.level;
        @memcpy(bytes[cell_start + 20 ..][0..32], &entry.child.digest);
        @memcpy(bytes[cell_start + internal_prefix_size ..][0..entry.upper_key.len], entry.upper_key);
    }
    finishPage(&bytes, .{
        .kind = .internal,
        .level = level,
        .count = @intCast(entries.len),
        .generation = generation,
    }, cell_start);
    return bytes;
}

pub fn decodeLeaf(bytes: *const [page_size]u8, entries: []LeafEntry) !Header {
    const header = try decodeHeader(bytes);
    if (header.kind != .leaf or header.level != 0 or entries.len < header.count)
        return error.InvalidBlobMetadataPage;
    var expected_end: usize = checksum_offset;
    for (entries[0..header.count], 0..) |*entry, index| {
        const offset = getCellOffset(bytes, index);
        if (offset + 4 > expected_end) return error.InvalidBlobMetadataPage;
        const key_len: usize = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        const value_len: usize = std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little);
        const end = std.math.add(usize, offset, 4 + key_len + value_len) catch
            return error.InvalidBlobMetadataPage;
        if (key_len == 0 or value_len == 0 or end != expected_end)
            return error.InvalidBlobMetadataPage;
        entry.* = .{
            .key = bytes[offset + 4 ..][0..key_len],
            .value = bytes[offset + 4 + key_len ..][0..value_len],
        };
        try validateLeafEntry(entry.*);
        if (index != 0 and std.mem.order(u8, entries[index - 1].key, entry.key) != .lt)
            return error.InvalidBlobMetadataPage;
        expected_end = offset;
    }
    if (expected_end != cellStart(bytes)) return error.InvalidBlobMetadataPage;
    return header;
}

pub fn decodeInternal(bytes: *const [page_size]u8, entries: []InternalEntry) !Header {
    const header = try decodeHeader(bytes);
    if (header.kind != .internal or header.level == 0 or entries.len < header.count)
        return error.InvalidBlobMetadataPage;
    var expected_end: usize = checksum_offset;
    for (entries[0..header.count], 0..) |*entry, index| {
        const offset = getCellOffset(bytes, index);
        if (offset + internal_prefix_size > expected_end or
            !std.mem.allEqual(u8, bytes[offset + 2 ..][0..2], 0) or
            !std.mem.allEqual(u8, bytes[offset + 13 ..][0..7], 0))
            return error.InvalidBlobMetadataPage;
        const key_len: usize = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        const end = std.math.add(usize, offset, internal_prefix_size + key_len) catch
            return error.InvalidBlobMetadataPage;
        if (key_len == 0 or end != expected_end) return error.InvalidBlobMetadataPage;
        entry.* = .{
            .upper_key = bytes[offset + internal_prefix_size ..][0..key_len],
            .child = .{
                .page = std.mem.readInt(u64, bytes[offset + 4 ..][0..8], .little),
                .level = bytes[offset + 12],
                .digest = bytes[offset + 20 ..][0..32].*,
            },
        };
        _ = filesystem_format.decodeKey(entry.upper_key) catch return error.InvalidBlobMetadataPage;
        if (entry.child.level == std.math.maxInt(u8) or entry.child.level + 1 != header.level or
            (index != 0 and std.mem.order(u8, entries[index - 1].upper_key, entry.upper_key) != .lt))
            return error.InvalidBlobMetadataPage;
        for (entries[0..index]) |previous| if (previous.child.page == entry.child.page)
            return error.InvalidBlobMetadataPage;
        expected_end = offset;
    }
    if (expected_end != cellStart(bytes)) return error.InvalidBlobMetadataPage;
    return header;
}

pub fn decodeHeader(bytes: *const [page_size]u8) !Header {
    if (!std.mem.eql(u8, bytes[0..8], &magic) or
        std.mem.readInt(u16, bytes[8..10], .little) != version or
        !std.mem.allEqual(u8, bytes[14..16], 0) or
        !std.mem.allEqual(u8, bytes[28..header_size], 0) or
        std.mem.readInt(u32, bytes[checksum_offset..], .little) != google_crc32c.value(bytes[0..checksum_offset]))
        return error.InvalidBlobMetadataPage;
    const kind = std.enums.fromInt(Kind, bytes[10]) orelse return error.InvalidBlobMetadataPage;
    const header: Header = .{
        .kind = kind,
        .level = bytes[11],
        .count = std.mem.readInt(u16, bytes[12..14], .little),
        .generation = std.mem.readInt(u64, bytes[16..24], .little),
    };
    const slots_end: usize = std.mem.readInt(u16, bytes[24..26], .little);
    const cells_start: usize = std.mem.readInt(u16, bytes[26..28], .little);
    if (header.generation == 0 or header.count == 0 or header.count > max_entries or
        slots_end != header_size + 2 * header.count or cells_start < slots_end or
        cells_start >= checksum_offset or !std.mem.allEqual(u8, bytes[slots_end..cells_start], 0))
        return error.InvalidBlobMetadataPage;
    return header;
}

pub fn pageDigest(bytes: *const [page_size]u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return digest;
}

fn validateEntryCount(generation: u64, count: usize) !void {
    if (generation == 0 or count == 0 or count > max_entries)
        return error.InvalidBlobMetadataEntryCount;
}

fn validateLeafEntry(entry: LeafEntry) !void {
    const key = filesystem_format.decodeKey(entry.key) catch return error.InvalidBlobMetadataEntry;
    switch (key) {
        .inode => {
            if (entry.value.len != filesystem_format.inode_encoded_size)
                return error.InvalidBlobMetadataEntry;
            _ = filesystem_format.decodeInode(@ptrCast(entry.value.ptr)) catch
                return error.InvalidBlobMetadataEntry;
        },
        .dentry => _ = filesystem_format.decodeDentry(entry.value) catch
            return error.InvalidBlobMetadataEntry,
        .orphan => {
            if (entry.value.len != filesystem_format.orphan_encoded_size)
                return error.InvalidBlobMetadataEntry;
            _ = filesystem_format.decodeOrphan(@ptrCast(entry.value.ptr)) catch
                return error.InvalidBlobMetadataEntry;
        },
        .reservation => |reservation| {
            if (entry.value.len != filesystem_format.reservation_encoded_size)
                return error.InvalidBlobMetadataEntry;
            const end_block = filesystem_format.decodeReservation(@ptrCast(entry.value.ptr)) catch
                return error.InvalidBlobMetadataEntry;
            if (reservation.start_block >= end_block) return error.InvalidBlobMetadataEntry;
        },
    }
}

fn finishPage(bytes: *[page_size]u8, header: Header, cells_start: usize) void {
    @memcpy(bytes[0..8], &magic);
    std.mem.writeInt(u16, bytes[8..10], version, .little);
    bytes[10] = @intFromEnum(header.kind);
    bytes[11] = header.level;
    std.mem.writeInt(u16, bytes[12..14], header.count, .little);
    std.mem.writeInt(u64, bytes[16..24], header.generation, .little);
    std.mem.writeInt(u16, bytes[24..26], @intCast(header_size + 2 * header.count), .little);
    std.mem.writeInt(u16, bytes[26..28], @intCast(cells_start), .little);
    std.mem.writeInt(u32, bytes[checksum_offset..], google_crc32c.value(bytes[0..checksum_offset]), .little);
}

fn getCellOffset(bytes: *const [page_size]u8, index: usize) usize {
    return std.mem.readInt(u16, bytes[header_size + 2 * index ..][0..2], .little);
}

fn cellStart(bytes: *const [page_size]u8) usize {
    return std.mem.readInt(u16, bytes[26..28], .little);
}

test "blob metadata leaf round trips variable records" {
    const inode_key = try filesystem_format.inodeKey(filesystem_format.root_inode);
    const inode_value = try filesystem_format.encodeInode(.{
        .metadata = .{
            .kind = .directory,
            .mode = 0o040755,
            .uid = 0,
            .gid = 0,
            .atime_ns = 1,
            .mtime_ns = 1,
            .ctime_ns = 1,
            .birthtime_ns = 1,
        },
        .generation = 1,
        .nlink = 2,
        .allocated_bytes = 0,
        .parent_inode = filesystem_format.root_inode,
        .data = null,
    });
    var dentry_key_buffer: [filesystem_format.max_key_size]u8 = undefined;
    const dentry_key = try filesystem_format.dentryKey(&dentry_key_buffer, filesystem_format.root_inode, "file");
    var dentry_value_buffer: [filesystem_format.max_dentry_size]u8 = undefined;
    const dentry_value = try filesystem_format.encodeDentry(&dentry_value_buffer, .{
        .child_inode = 2,
        .child_generation = 1,
        .kind = .file,
        .spelling = "file",
    });
    const entries = [_]LeafEntry{
        .{ .key = &inode_key, .value = &inode_value },
        .{ .key = dentry_key, .value = dentry_value },
    };
    const page = try encodeLeaf(3, &entries);
    var decoded: [max_entries]LeafEntry = undefined;
    const header = try decodeLeaf(&page, &decoded);
    try std.testing.expectEqual(@as(u64, 3), header.generation);
    try std.testing.expectEqual(@as(u16, 2), header.count);
    try std.testing.expectEqualSlices(u8, entries[0].key, decoded[0].key);
    try std.testing.expectEqualSlices(u8, entries[1].value, decoded[1].value);

    var malformed = page;
    const first_offset = getCellOffset(&malformed, 0);
    std.mem.writeInt(u16, malformed[header_size..][0..2], @intCast(first_offset - 1), .little);
    refreshChecksum(&malformed);
    try std.testing.expectError(error.InvalidBlobMetadataPage, decodeLeaf(&malformed, &decoded));
}

test "blob metadata internal page round trips child references" {
    const first_key = try filesystem_format.inodeKey(2);
    const second_key = try filesystem_format.orphanKey(9);
    const entries = [_]InternalEntry{
        .{ .upper_key = &first_key, .child = .{ .page = 7, .level = 0, .digest = @splat(0x11) } },
        .{ .upper_key = &second_key, .child = .{ .page = 8, .level = 0, .digest = @splat(0x22) } },
    };
    const page = try encodeInternal(1, 4, &entries);
    var decoded: [max_entries]InternalEntry = undefined;
    const header = try decodeInternal(&page, &decoded);
    try std.testing.expectEqual(@as(u8, 1), header.level);
    try std.testing.expectEqualDeep(entries[1].child, decoded[1].child);

    var corrupt = page;
    corrupt[checksum_offset] ^= 1;
    try std.testing.expectError(error.InvalidBlobMetadataPage, decodeInternal(&corrupt, &decoded));

    var duplicate_child = page;
    const second_offset = getCellOffset(&duplicate_child, 1);
    std.mem.writeInt(u64, duplicate_child[second_offset + 4 ..][0..8], entries[0].child.page, .little);
    refreshChecksum(&duplicate_child);
    try std.testing.expectError(error.InvalidBlobMetadataPage, decodeInternal(&duplicate_child, &decoded));

    const duplicate_entries = [_]InternalEntry{ entries[0], .{
        .upper_key = &second_key,
        .child = entries[0].child,
    } };
    try std.testing.expectError(error.InvalidBlobMetadataEntry, encodeInternal(1, 4, &duplicate_entries));
}

test "blob metadata pages reject unsorted and oversized entries" {
    const first = try filesystem_format.orphanKey(2);
    const second = try filesystem_format.orphanKey(1);
    const value = try filesystem_format.encodeOrphan(.{ .generation = 1, .kind = .file });
    const unsorted = [_]LeafEntry{
        .{ .key = &first, .value = &value },
        .{ .key = &second, .value = &value },
    };
    try std.testing.expectError(error.UnsortedBlobMetadataEntries, encodeLeaf(1, &unsorted));

    const lookup_name = "a" ** filesystem_format.max_lookup_name_bytes;
    var key_buffers: [4][filesystem_format.max_key_size]u8 = undefined;
    var oversized: [4]InternalEntry = undefined;
    for (&oversized, &key_buffers, 1..) |*entry, *key_buffer, parent| entry.* = .{
        .upper_key = try filesystem_format.dentryKey(key_buffer, parent, lookup_name),
        .child = .{ .page = parent, .level = 0, .digest = @splat(@intCast(parent)) },
    };
    try std.testing.expectError(error.BlobMetadataPageFull, encodeInternal(1, 1, &oversized));
}

fn refreshChecksum(bytes: *[page_size]u8) void {
    std.mem.writeInt(u32, bytes[checksum_offset..], google_crc32c.value(bytes[0..checksum_offset]), .little);
}
