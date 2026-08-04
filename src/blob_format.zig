const std = @import("std");
const google_crc32c = @import("crc32c");

pub const header_size: usize = 4096;
pub const header_a_offset: u64 = 0;
pub const header_b_offset: u64 = header_size;
pub const arena_offset: u64 = 1024 * 1024;
pub const blob_size: u32 = 1024 * 1024;
pub const checksum_unit: u32 = 64 * 1024;
pub const checksum_count: usize = blob_size / checksum_unit;
pub const minimum_device_size: u64 = arena_offset + blob_size;

const magic = [8]u8{ 'Z', 'T', 'B', 'L', 'O', 'B', '0', '1' };
const version: u16 = 1;
const checksum_offset = header_size - @sizeOf(u32);

pub const Header = struct {
    sequence: u64,
    uuid: [16]u8,
    device_size: u64,
    slot_count: u64,
    committed_slots: u64,

    pub fn init(io: std.Io, device_size: u64) !Header {
        if (device_size < minimum_device_size or device_size % blob_size != 0)
            return error.InvalidBlobStoreSize;
        var uuid: [16]u8 = undefined;
        io.random(&uuid);
        return .{
            .sequence = 1,
            .uuid = uuid,
            .device_size = device_size,
            .slot_count = (device_size - arena_offset) / blob_size,
            .committed_slots = 0,
        };
    }

    pub fn validate(self: Header, actual_device_size: u64) !void {
        if (self.sequence == 0 or
            self.device_size != actual_device_size or
            self.device_size < minimum_device_size or
            self.device_size % blob_size != 0 or
            self.slot_count != (self.device_size - arena_offset) / blob_size or
            self.committed_slots > self.slot_count)
            return error.InvalidBlobStoreHeader;
    }
};

pub const BlobRef = struct {
    slot: u64,
    valid_bytes: u32,
    checksums: [checksum_count]u32,

    pub fn validate(self: BlobRef, slot_count: u64) !void {
        if (self.slot >= slot_count or self.valid_bytes > blob_size)
            return error.InvalidBlobReference;
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
    std.mem.writeInt(u64, bytes[64..72], header.slot_count, .little);
    std.mem.writeInt(u64, bytes[72..80], header.committed_slots, .little);
    std.mem.writeInt(u32, bytes[checksum_offset..header_size], google_crc32c.value(bytes[0..checksum_offset]), .little);
    return bytes;
}

pub fn decodeHeader(bytes: *const [header_size]u8) !Header {
    if (!std.mem.eql(u8, bytes[0..8], &magic) or
        std.mem.readInt(u16, bytes[8..10], .little) != version or
        std.mem.readInt(u16, bytes[10..12], .little) != header_size or
        std.mem.readInt(u64, bytes[48..56], .little) != arena_offset or
        std.mem.readInt(u32, bytes[56..60], .little) != blob_size or
        std.mem.readInt(u32, bytes[60..64], .little) != checksum_unit or
        !std.mem.allEqual(u8, bytes[12..16], 0) or
        !std.mem.allEqual(u8, bytes[80..checksum_offset], 0) or
        std.mem.readInt(u32, bytes[checksum_offset..header_size], .little) !=
            google_crc32c.value(bytes[0..checksum_offset]))
        return error.InvalidBlobStoreHeader;
    return .{
        .sequence = std.mem.readInt(u64, bytes[16..24], .little),
        .uuid = bytes[24..40].*,
        .device_size = std.mem.readInt(u64, bytes[40..48], .little),
        .slot_count = std.mem.readInt(u64, bytes[64..72], .little),
        .committed_slots = std.mem.readInt(u64, bytes[72..80], .little),
    };
}

pub fn slotOffset(slot: u64) !u64 {
    return std.math.add(u64, arena_offset, try std.math.mul(u64, slot, blob_size));
}

pub fn payloadChecksums(bytes: []const u8) [checksum_count]u32 {
    std.debug.assert(bytes.len == blob_size);
    var result: [checksum_count]u32 = undefined;
    for (&result, 0..) |*checksum, index| {
        const start = index * checksum_unit;
        checksum.* = google_crc32c.value(bytes[start..][0..checksum_unit]);
    }
    return result;
}

test "blob store header round trips and rejects corruption" {
    const header = try Header.init(std.testing.io, 8 * 1024 * 1024);
    const encoded = encodeHeader(header);
    const decoded = try decodeHeader(&encoded);
    try decoded.validate(header.device_size);
    try std.testing.expectEqualDeep(header, decoded);

    var corrupt = encoded;
    corrupt[72] ^= 1;
    try std.testing.expectError(error.InvalidBlobStoreHeader, decodeHeader(&corrupt));
}

test "blob store validates geometry and references" {
    try std.testing.expectError(error.InvalidBlobStoreSize, Header.init(std.testing.io, minimum_device_size - 1));
    const header = try Header.init(std.testing.io, 4 * 1024 * 1024);
    var reference: BlobRef = .{
        .slot = header.slot_count - 1,
        .valid_bytes = blob_size,
        .checksums = @splat(0),
    };
    try reference.validate(header.slot_count);
    reference.slot = header.slot_count;
    try std.testing.expectError(error.InvalidBlobReference, reference.validate(header.slot_count));
}
