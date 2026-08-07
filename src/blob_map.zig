const std = @import("std");
const blob_format = @import("blob_format.zig");
const google_crc32c = @import("crc32c");

pub const page_size: usize = 4096;
pub const digest_size: usize = 32;
pub const leaf_entry_size: usize = 88;
pub const internal_entry_size: usize = 56;
pub const header_size: usize = 64;
pub const checksum_offset: usize = page_size - @sizeOf(u32);
pub const max_leaf_entries: usize = (checksum_offset - header_size) / leaf_entry_size;
pub const max_internal_entries: usize = (checksum_offset - header_size) / internal_entry_size;

const magic = [8]u8{ 'Z', 'T', 'B', 'M', 'A', 'P', '0', '1' };
const version: u16 = 1;

pub const Digest = [digest_size]u8;

pub const Kind = enum(u8) {
    leaf = 1,
    internal = 2,
};

pub const Header = struct {
    kind: Kind,
    level: u8,
    count: u16,
    generation: u64,
    first_key: u64,
    last_key: u64,
};

pub const LeafEntry = struct {
    logical_blob: u64,
    reference: blob_format.BlobRef,
};

pub const InternalEntry = struct {
    first_key: u64,
    last_key: u64,
    child_page: u64,
    child_digest: Digest,
};

pub const PageRef = struct {
    page: u64,
    level: u8,
    first_key: u64,
    last_key: u64,
    digest: Digest,
};

pub fn encodeLeaf(generation: u64, entries: []const LeafEntry) ![page_size]u8 {
    if (entries.len == 0 or entries.len > max_leaf_entries) return error.InvalidBlobMapEntryCount;
    for (entries, 0..) |entry, index| {
        if (entry.reference.valid_bytes > blob_format.blob_size) return error.InvalidBlobReference;
        if (index != 0 and entries[index - 1].logical_blob >= entry.logical_blob)
            return error.UnsortedBlobMapEntries;
    }
    var bytes: [page_size]u8 = @splat(0);
    encodeHeader(&bytes, .{
        .kind = .leaf,
        .level = 0,
        .count = @intCast(entries.len),
        .generation = generation,
        .first_key = entries[0].logical_blob,
        .last_key = entries[entries.len - 1].logical_blob,
    });
    for (entries, 0..) |entry, index| {
        const offset = header_size + index * leaf_entry_size;
        std.mem.writeInt(u64, bytes[offset..][0..8], entry.logical_blob, .little);
        std.mem.writeInt(u64, bytes[offset + 8 ..][0..8], entry.reference.slot, .little);
        std.mem.writeInt(u32, bytes[offset + 16 ..][0..4], entry.reference.valid_bytes, .little);
        for (entry.reference.checksums, 0..) |checksum, checksum_index|
            std.mem.writeInt(u32, bytes[offset + 24 + checksum_index * 4 ..][0..4], checksum, .little);
    }
    finishPage(&bytes);
    return bytes;
}

pub fn decodeLeaf(bytes: *const [page_size]u8, entries: []LeafEntry) !Header {
    return decodeLeafImpl(bytes, entries, true);
}

/// The caller has already verified the complete page against its BLAKE3 digest.
pub fn decodeLeafVerified(bytes: *const [page_size]u8, entries: []LeafEntry) !Header {
    return decodeLeafImpl(bytes, entries, false);
}

fn decodeLeafImpl(bytes: *const [page_size]u8, entries: []LeafEntry, verify_checksum: bool) !Header {
    const header = try decodeHeaderImpl(bytes, verify_checksum);
    if (header.kind != .leaf or header.level != 0 or entries.len < header.count)
        return error.InvalidBlobMapPage;
    for (entries[0..header.count], 0..) |*entry, index| {
        const offset = header_size + index * leaf_entry_size;
        entry.* = .{
            .logical_blob = std.mem.readInt(u64, bytes[offset..][0..8], .little),
            .reference = .{
                .slot = std.mem.readInt(u64, bytes[offset + 8 ..][0..8], .little),
                .valid_bytes = std.mem.readInt(u32, bytes[offset + 16 ..][0..4], .little),
                .checksums = undefined,
            },
        };
        if (!std.mem.allEqual(u8, bytes[offset + 20 ..][0..4], 0) or
            entry.reference.valid_bytes > blob_format.blob_size)
            return error.InvalidBlobMapPage;
        for (&entry.reference.checksums, 0..) |*checksum, checksum_index|
            checksum.* = std.mem.readInt(u32, bytes[offset + 24 + checksum_index * 4 ..][0..4], .little);
        if (index != 0 and entries[index - 1].logical_blob >= entry.logical_blob)
            return error.InvalidBlobMapPage;
    }
    if (entries[0].logical_blob != header.first_key or
        entries[header.count - 1].logical_blob != header.last_key)
        return error.InvalidBlobMapPage;
    return header;
}

pub fn encodeInternal(level: u8, generation: u64, entries: []const InternalEntry) ![page_size]u8 {
    if (level == 0 or entries.len == 0 or entries.len > max_internal_entries)
        return error.InvalidBlobMapEntryCount;
    for (entries, 0..) |entry, index| {
        if (entry.first_key > entry.last_key or
            (index != 0 and entries[index - 1].last_key >= entry.first_key))
            return error.UnsortedBlobMapEntries;
    }
    var bytes: [page_size]u8 = @splat(0);
    encodeHeader(&bytes, .{
        .kind = .internal,
        .level = level,
        .count = @intCast(entries.len),
        .generation = generation,
        .first_key = entries[0].first_key,
        .last_key = entries[entries.len - 1].last_key,
    });
    for (entries, 0..) |entry, index| {
        const offset = header_size + index * internal_entry_size;
        std.mem.writeInt(u64, bytes[offset..][0..8], entry.first_key, .little);
        std.mem.writeInt(u64, bytes[offset + 8 ..][0..8], entry.last_key, .little);
        std.mem.writeInt(u64, bytes[offset + 16 ..][0..8], entry.child_page, .little);
        @memcpy(bytes[offset + 24 ..][0..digest_size], &entry.child_digest);
    }
    finishPage(&bytes);
    return bytes;
}

pub fn decodeInternal(bytes: *const [page_size]u8, entries: []InternalEntry) !Header {
    return decodeInternalImpl(bytes, entries, true);
}

/// The caller has already verified the complete page against its BLAKE3 digest.
pub fn decodeInternalVerified(bytes: *const [page_size]u8, entries: []InternalEntry) !Header {
    return decodeInternalImpl(bytes, entries, false);
}

fn decodeInternalImpl(bytes: *const [page_size]u8, entries: []InternalEntry, verify_checksum: bool) !Header {
    const header = try decodeHeaderImpl(bytes, verify_checksum);
    if (header.kind != .internal or header.level == 0 or entries.len < header.count)
        return error.InvalidBlobMapPage;
    for (entries[0..header.count], 0..) |*entry, index| {
        const offset = header_size + index * internal_entry_size;
        entry.* = .{
            .first_key = std.mem.readInt(u64, bytes[offset..][0..8], .little),
            .last_key = std.mem.readInt(u64, bytes[offset + 8 ..][0..8], .little),
            .child_page = std.mem.readInt(u64, bytes[offset + 16 ..][0..8], .little),
            .child_digest = bytes[offset + 24 ..][0..digest_size].*,
        };
        if (entry.first_key > entry.last_key or
            (index != 0 and entries[index - 1].last_key >= entry.first_key))
            return error.InvalidBlobMapPage;
    }
    if (entries[0].first_key != header.first_key or
        entries[header.count - 1].last_key != header.last_key)
        return error.InvalidBlobMapPage;
    return header;
}

pub fn decodeHeader(bytes: *const [page_size]u8) !Header {
    return decodeHeaderImpl(bytes, true);
}

/// The caller has already verified the complete page against its BLAKE3 digest.
pub fn decodeHeaderVerified(bytes: *const [page_size]u8) !Header {
    return decodeHeaderImpl(bytes, false);
}

fn decodeHeaderImpl(bytes: *const [page_size]u8, verify_checksum: bool) !Header {
    if (!std.mem.eql(u8, bytes[0..8], &magic) or
        std.mem.readInt(u16, bytes[8..10], .little) != version or
        !std.mem.allEqual(u8, bytes[14..16], 0) or
        !std.mem.allEqual(u8, bytes[40..header_size], 0) or
        (verify_checksum and std.mem.readInt(u32, bytes[checksum_offset..page_size], .little) !=
            google_crc32c.value(bytes[0..checksum_offset])))
        return error.InvalidBlobMapPage;
    const kind = std.enums.fromInt(Kind, bytes[10]) orelse return error.InvalidBlobMapPage;
    const header: Header = .{
        .kind = kind,
        .level = bytes[11],
        .count = std.mem.readInt(u16, bytes[12..14], .little),
        .generation = std.mem.readInt(u64, bytes[16..24], .little),
        .first_key = std.mem.readInt(u64, bytes[24..32], .little),
        .last_key = std.mem.readInt(u64, bytes[32..40], .little),
    };
    const maximum = if (kind == .leaf) max_leaf_entries else max_internal_entries;
    if (header.count == 0 or header.count > maximum or header.first_key > header.last_key)
        return error.InvalidBlobMapPage;
    return header;
}

pub fn pageDigest(bytes: *const [page_size]u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return digest;
}

fn encodeHeader(bytes: *[page_size]u8, header: Header) void {
    @memcpy(bytes[0..8], &magic);
    std.mem.writeInt(u16, bytes[8..10], version, .little);
    bytes[10] = @intFromEnum(header.kind);
    bytes[11] = header.level;
    std.mem.writeInt(u16, bytes[12..14], header.count, .little);
    std.mem.writeInt(u64, bytes[16..24], header.generation, .little);
    std.mem.writeInt(u64, bytes[24..32], header.first_key, .little);
    std.mem.writeInt(u64, bytes[32..40], header.last_key, .little);
}

fn finishPage(bytes: *[page_size]u8) void {
    std.mem.writeInt(u32, bytes[checksum_offset..page_size], google_crc32c.value(bytes[0..checksum_offset]), .little);
}

test "blob map leaf page round trips" {
    const references = [_]LeafEntry{
        .{ .logical_blob = 3, .reference = .{ .slot = 7, .valid_bytes = blob_format.blob_size, .checksums = @splat(0x11) } },
        .{ .logical_blob = 4, .reference = .{ .slot = 8, .valid_bytes = 123, .checksums = @splat(0x22) } },
    };
    const encoded = try encodeLeaf(9, &references);
    var decoded: [max_leaf_entries]LeafEntry = undefined;
    const header = try decodeLeaf(&encoded, &decoded);
    try std.testing.expectEqual(Kind.leaf, header.kind);
    try std.testing.expectEqual(@as(u64, 9), header.generation);
    try std.testing.expectEqualDeep(references, decoded[0..references.len].*);
    _ = pageDigest(&encoded);

    var stale_checksum = encoded;
    stale_checksum[checksum_offset] ^= 1;
    try std.testing.expectError(error.InvalidBlobMapPage, decodeLeaf(&stale_checksum, &decoded));
    _ = try decodeLeafVerified(&stale_checksum, &decoded);
}

test "blob map internal page round trips and rejects corruption" {
    const entries = [_]InternalEntry{
        .{ .first_key = 0, .last_key = 44, .child_page = 10, .child_digest = @splat(0x33) },
        .{ .first_key = 45, .last_key = 89, .child_page = 11, .child_digest = @splat(0x44) },
    };
    const encoded = try encodeInternal(1, 12, &entries);
    var decoded: [max_internal_entries]InternalEntry = undefined;
    const header = try decodeInternal(&encoded, &decoded);
    try std.testing.expectEqual(@as(u8, 1), header.level);
    try std.testing.expectEqualDeep(entries, decoded[0..entries.len].*);

    var corrupt = encoded;
    corrupt[header_size] ^= 1;
    try std.testing.expectError(error.InvalidBlobMapPage, decodeInternal(&corrupt, &decoded));
}

test "blob map pages reject unsorted entries" {
    const entries = [_]LeafEntry{
        .{ .logical_blob = 2, .reference = .{ .slot = 0, .valid_bytes = 1, .checksums = @splat(0) } },
        .{ .logical_blob = 1, .reference = .{ .slot = 1, .valid_bytes = 1, .checksums = @splat(0) } },
    };
    try std.testing.expectError(error.UnsortedBlobMapEntries, encodeLeaf(1, &entries));
}
