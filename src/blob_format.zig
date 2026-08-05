const std = @import("std");
const google_crc32c = @import("crc32c");

pub const header_size: usize = 4096;
pub const header_a_offset: u64 = 0;
pub const header_b_offset: u64 = header_size;
pub const arena_offset: u64 = 1024 * 1024;
pub const blob_size: u32 = 1024 * 1024;
pub const allocation_unit: u32 = 4096;
pub const checksum_unit: u32 = 64 * 1024;
pub const checksum_count: usize = blob_size / checksum_unit;
pub const minimum_device_size: u64 = arena_offset + blob_size;

const magic = [8]u8{ 'Z', 'T', 'B', 'L', 'O', 'B', '0', '1' };
const version: u16 = 3;
const checksum_offset = header_size - @sizeOf(u32);
const authority_present: u32 = 1;

pub fn hasHeaderMagic(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], &magic);
}

pub const Header = struct {
    sequence: u64,
    uuid: [16]u8,
    device_size: u64,
    unit_count: u64,
    committed_units: u64,
    authority_root: ?BlobRef,

    pub fn init(io: std.Io, device_size: u64) !Header {
        if (device_size < minimum_device_size or device_size % blob_size != 0)
            return error.InvalidBlobStoreSize;
        var uuid: [16]u8 = undefined;
        io.random(&uuid);
        return .{
            .sequence = 1,
            .uuid = uuid,
            .device_size = device_size,
            .unit_count = (device_size - arena_offset) / allocation_unit,
            .committed_units = 0,
            .authority_root = null,
        };
    }

    pub fn validate(self: Header, actual_device_size: u64) !void {
        if (self.sequence == 0 or
            self.device_size != actual_device_size or
            self.device_size < minimum_device_size or
            self.device_size % blob_size != 0 or
            self.unit_count != (self.device_size - arena_offset) / allocation_unit or
            self.committed_units > self.unit_count)
            return error.InvalidBlobStoreHeader;
        if (self.authority_root) |root| {
            root.validate(self.unit_count) catch return error.InvalidBlobStoreHeader;
            if (root.endUnit() > self.committed_units) return error.InvalidBlobStoreHeader;
        }
    }
};

pub const BlobRef = struct {
    slot: u64,
    valid_bytes: u32,
    checksums: [checksum_count]u32,

    pub fn validate(self: BlobRef, unit_count: u64) !void {
        if (self.valid_bytes == 0 or self.valid_bytes > blob_size or
            self.slot > unit_count or self.endUnit() > unit_count)
            return error.InvalidBlobReference;
    }

    pub fn endUnit(self: BlobRef) u64 {
        return self.slot + allocationUnits(self.valid_bytes);
    }
};

pub fn encodeHeader(header: Header) [header_size]u8 {
    var bytes: [header_size]u8 = @splat(0);
    @memcpy(bytes[0..8], &magic);
    std.mem.writeInt(u16, bytes[8..10], version, .little);
    std.mem.writeInt(u16, bytes[10..12], header_size, .little);
    std.mem.writeInt(u64, bytes[16..24], header.sequence, .little);
    @memcpy(bytes[24..40], &header.uuid);
    std.mem.writeInt(u64, bytes[40..48], header.device_size, .little);
    std.mem.writeInt(u64, bytes[48..56], arena_offset, .little);
    std.mem.writeInt(u32, bytes[56..60], blob_size, .little);
    std.mem.writeInt(u32, bytes[60..64], checksum_unit, .little);
    std.mem.writeInt(u32, bytes[64..68], allocation_unit, .little);
    std.mem.writeInt(u64, bytes[72..80], header.unit_count, .little);
    std.mem.writeInt(u64, bytes[80..88], header.committed_units, .little);
    if (header.authority_root) |root| {
        std.mem.writeInt(u32, bytes[88..92], authority_present, .little);
        std.mem.writeInt(u32, bytes[92..96], root.valid_bytes, .little);
        std.mem.writeInt(u64, bytes[96..104], root.slot, .little);
        for (root.checksums, 0..) |checksum, index|
            std.mem.writeInt(u32, bytes[104 + index * 4 ..][0..4], checksum, .little);
    }
    std.mem.writeInt(u32, bytes[checksum_offset..header_size], google_crc32c.value(bytes[0..checksum_offset]), .little);
    return bytes;
}

pub fn decodeHeader(bytes: *const [header_size]u8) !Header {
    if (!hasHeaderMagic(bytes) or
        std.mem.readInt(u32, bytes[checksum_offset..header_size], .little) !=
            google_crc32c.value(bytes[0..checksum_offset]))
        return error.InvalidBlobStoreHeader;
    if (std.mem.readInt(u16, bytes[8..10], .little) != version)
        return error.UnsupportedBlobStoreVersion;
    if (std.mem.readInt(u16, bytes[10..12], .little) != header_size or
        std.mem.readInt(u64, bytes[48..56], .little) != arena_offset or
        std.mem.readInt(u32, bytes[56..60], .little) != blob_size or
        std.mem.readInt(u32, bytes[60..64], .little) != checksum_unit or
        std.mem.readInt(u32, bytes[64..68], .little) != allocation_unit or
        !std.mem.allEqual(u8, bytes[12..16], 0) or
        !std.mem.allEqual(u8, bytes[68..72], 0) or
        !std.mem.allEqual(u8, bytes[168..checksum_offset], 0))
        return error.InvalidBlobStoreHeader;
    const flags = std.mem.readInt(u32, bytes[88..92], .little);
    if (flags & ~authority_present != 0 or
        (flags == 0 and !std.mem.allEqual(u8, bytes[92..168], 0)))
        return error.InvalidBlobStoreHeader;
    const authority_root: ?BlobRef = if (flags & authority_present != 0) .{
        .slot = std.mem.readInt(u64, bytes[96..104], .little),
        .valid_bytes = std.mem.readInt(u32, bytes[92..96], .little),
        .checksums = checksums: {
            var checksums: [checksum_count]u32 = undefined;
            for (&checksums, 0..) |*checksum, index|
                checksum.* = std.mem.readInt(u32, bytes[104 + index * 4 ..][0..4], .little);
            break :checksums checksums;
        },
    } else null;
    return .{
        .sequence = std.mem.readInt(u64, bytes[16..24], .little),
        .uuid = bytes[24..40].*,
        .device_size = std.mem.readInt(u64, bytes[40..48], .little),
        .unit_count = std.mem.readInt(u64, bytes[72..80], .little),
        .committed_units = std.mem.readInt(u64, bytes[80..88], .little),
        .authority_root = authority_root,
    };
}

pub fn slotOffset(slot: u64) !u64 {
    return std.math.add(u64, arena_offset, try std.math.mul(u64, slot, allocation_unit));
}

pub fn payloadChecksums(bytes: []const u8) [checksum_count]u32 {
    std.debug.assert(bytes.len > 0 and bytes.len <= blob_size);
    var result: [checksum_count]u32 = @splat(0);
    for (0..tryChecksumCount(bytes.len)) |index| {
        const start = index * checksum_unit;
        result[index] = google_crc32c.value(bytes[start..][0..@min(checksum_unit, bytes.len - start)]);
    }
    return result;
}

pub fn allocationUnits(valid_bytes: u64) u64 {
    std.debug.assert(valid_bytes > 0 and valid_bytes <= blob_size);
    return std.math.divCeil(u64, valid_bytes, allocation_unit) catch unreachable;
}

pub fn storedBytes(valid_bytes: u64) u64 {
    return allocationUnits(valid_bytes) * allocation_unit;
}

fn tryChecksumCount(valid_bytes: usize) usize {
    return std.math.divCeil(usize, valid_bytes, checksum_unit) catch unreachable;
}

test "blob store header round trips and rejects corruption" {
    var header = try Header.init(std.testing.io, 8 * 1024 * 1024);
    header.committed_units = 1;
    header.authority_root = .{
        .slot = 0,
        .valid_bytes = 123,
        .checksums = @splat(0x11223344),
    };
    const encoded = encodeHeader(header);
    const decoded = try decodeHeader(&encoded);
    try decoded.validate(header.device_size);
    try std.testing.expectEqualDeep(header, decoded);

    var corrupt = encoded;
    corrupt[72] ^= 1;
    try std.testing.expectError(error.InvalidBlobStoreHeader, decodeHeader(&corrupt));

    var unsupported = encoded;
    std.mem.writeInt(u16, unsupported[8..10], version + 1, .little);
    try std.testing.expectError(error.InvalidBlobStoreHeader, decodeHeader(&unsupported));
    std.mem.writeInt(
        u32,
        unsupported[checksum_offset..header_size],
        google_crc32c.value(unsupported[0..checksum_offset]),
        .little,
    );
    try std.testing.expectError(error.UnsupportedBlobStoreVersion, decodeHeader(&unsupported));

    header.committed_units = 0;
    try std.testing.expectError(error.InvalidBlobStoreHeader, header.validate(header.device_size));
}

test "blob store validates geometry and references" {
    try std.testing.expectError(error.InvalidBlobStoreSize, Header.init(std.testing.io, minimum_device_size - 1));
    const header = try Header.init(std.testing.io, 4 * 1024 * 1024);
    var reference: BlobRef = .{
        .slot = header.unit_count - allocationUnits(blob_size),
        .valid_bytes = blob_size,
        .checksums = @splat(0),
    };
    try reference.validate(header.unit_count);
    reference.slot = header.unit_count;
    try std.testing.expectError(error.InvalidBlobReference, reference.validate(header.unit_count));
}

test "variable blob geometry uses allocation units" {
    try std.testing.expectEqual(@as(u64, 1), allocationUnits(1));
    try std.testing.expectEqual(@as(u64, 1), allocationUnits(allocation_unit));
    try std.testing.expectEqual(@as(u64, 2), allocationUnits(allocation_unit + 1));
    try std.testing.expectEqual(@as(u64, blob_size), storedBytes(blob_size));
    const checksums = payloadChecksums("small blob");
    try std.testing.expect(checksums[0] != 0);
    try std.testing.expect(std.mem.allEqual(u32, checksums[1..], 0));
}
