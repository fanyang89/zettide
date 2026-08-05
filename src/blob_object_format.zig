const std = @import("std");
const blob_format = @import("blob_format.zig");
const blob_map = @import("blob_map.zig");
const google_crc32c = @import("crc32c");

pub const head_size: usize = 4096;
pub const head_a_offset: u64 = 2 * head_size;
pub const head_b_offset: u64 = 3 * head_size;

const magic = [8]u8{ 'Z', 'T', 'B', 'H', 'E', 'A', 'D', '1' };
const version: u16 = 1;
const flag_root: u32 = 1 << 0;
const supported_flags = flag_root;
const checksum_offset = head_size - @sizeOf(u32);

pub const Head = struct {
    sequence: u64,
    object_id: [16]u8,
    generation: u64,
    logical_size: u64,
    allocated_bytes: u64,
    map_generation: u64,
    root: ?blob_map.PageRef,

    pub fn init(io: std.Io) Head {
        var object_id: [16]u8 = undefined;
        io.random(&object_id);
        return .{
            .sequence = 1,
            .object_id = object_id,
            .generation = 1,
            .logical_size = 0,
            .allocated_bytes = 0,
            .map_generation = 0,
            .root = null,
        };
    }

    pub fn validate(self: Head) !void {
        if (self.sequence == 0 or self.generation == 0 or
            self.logical_size > std.math.maxInt(i64) or
            self.allocated_bytes % blob_format.blob_size != 0 or
            self.allocated_bytes < self.logical_size)
            return error.InvalidBlobObjectHead;
        if (self.root) |root| {
            if (self.logical_size == 0 or self.allocated_bytes == 0 or
                self.map_generation == 0 or self.map_generation > self.generation or
                root.first_key > root.last_key)
                return error.InvalidBlobObjectHead;
            const required_blobs = try std.math.divCeil(u64, self.logical_size, blob_format.blob_size);
            if (required_blobs == 0 or root.first_key != 0 or root.last_key != required_blobs - 1)
                return error.InvalidBlobObjectHead;
        } else if (self.logical_size != 0 or self.allocated_bytes != 0 or self.map_generation != 0) {
            return error.InvalidBlobObjectHead;
        }
    }
};

pub fn encodeHead(head: Head) ![head_size]u8 {
    try head.validate();
    var bytes: [head_size]u8 = @splat(0);
    @memcpy(bytes[0..8], &magic);
    std.mem.writeInt(u16, bytes[8..10], version, .little);
    std.mem.writeInt(u16, bytes[10..12], head_size, .little);
    std.mem.writeInt(u32, bytes[12..16], if (head.root != null) flag_root else 0, .little);
    std.mem.writeInt(u64, bytes[16..24], head.sequence, .little);
    @memcpy(bytes[24..40], &head.object_id);
    std.mem.writeInt(u64, bytes[40..48], head.generation, .little);
    std.mem.writeInt(u64, bytes[48..56], head.logical_size, .little);
    std.mem.writeInt(u64, bytes[56..64], head.allocated_bytes, .little);
    std.mem.writeInt(u64, bytes[64..72], head.map_generation, .little);
    if (head.root) |root| {
        std.mem.writeInt(u64, bytes[72..80], root.page, .little);
        bytes[80] = root.level;
        std.mem.writeInt(u64, bytes[88..96], root.first_key, .little);
        std.mem.writeInt(u64, bytes[96..104], root.last_key, .little);
        @memcpy(bytes[104..136], &root.digest);
    }
    std.mem.writeInt(u32, bytes[checksum_offset..head_size], google_crc32c.value(bytes[0..checksum_offset]), .little);
    return bytes;
}

pub fn decodeHead(bytes: *const [head_size]u8) !Head {
    if (!std.mem.eql(u8, bytes[0..8], &magic) or
        std.mem.readInt(u16, bytes[8..10], .little) != version or
        std.mem.readInt(u16, bytes[10..12], .little) != head_size or
        std.mem.readInt(u32, bytes[12..16], .little) & ~supported_flags != 0 or
        !std.mem.allEqual(u8, bytes[81..88], 0) or
        !std.mem.allEqual(u8, bytes[136..checksum_offset], 0) or
        std.mem.readInt(u32, bytes[checksum_offset..head_size], .little) !=
            google_crc32c.value(bytes[0..checksum_offset]))
        return error.InvalidBlobObjectHead;
    const flags = std.mem.readInt(u32, bytes[12..16], .little);
    const head: Head = .{
        .sequence = std.mem.readInt(u64, bytes[16..24], .little),
        .object_id = bytes[24..40].*,
        .generation = std.mem.readInt(u64, bytes[40..48], .little),
        .logical_size = std.mem.readInt(u64, bytes[48..56], .little),
        .allocated_bytes = std.mem.readInt(u64, bytes[56..64], .little),
        .map_generation = std.mem.readInt(u64, bytes[64..72], .little),
        .root = if (flags & flag_root != 0) .{
            .page = std.mem.readInt(u64, bytes[72..80], .little),
            .level = bytes[80],
            .first_key = std.mem.readInt(u64, bytes[88..96], .little),
            .last_key = std.mem.readInt(u64, bytes[96..104], .little),
            .digest = bytes[104..136].*,
        } else null,
    };
    try head.validate();
    return head;
}

test "blob object head round trips empty and mapped states" {
    var head = Head.init(std.testing.io);
    const empty = try encodeHead(head);
    try std.testing.expectEqualDeep(head, try decodeHead(&empty));

    head.sequence = 3;
    head.generation = 2;
    head.logical_size = 2 * blob_format.blob_size;
    head.allocated_bytes = 2 * blob_format.blob_size;
    head.map_generation = 2;
    head.root = .{
        .page = 9,
        .level = 1,
        .first_key = 0,
        .last_key = 1,
        .digest = @splat(0x5a),
    };
    const mapped = try encodeHead(head);
    try std.testing.expectEqualDeep(head, try decodeHead(&mapped));
}

test "blob object head rejects corruption and inconsistent roots" {
    var head = Head.init(std.testing.io);
    var encoded = try encodeHead(head);
    encoded[48] ^= 1;
    try std.testing.expectError(error.InvalidBlobObjectHead, decodeHead(&encoded));

    head.logical_size = blob_format.blob_size;
    head.allocated_bytes = blob_format.blob_size;
    try std.testing.expectError(error.InvalidBlobObjectHead, encodeHead(head));
}

test "blob object head rejects max u64 last key without overflow" {
    var head = Head.init(std.testing.io);
    head.logical_size = blob_format.blob_size;
    head.allocated_bytes = blob_format.blob_size;
    head.map_generation = 1;
    head.root = .{
        .page = 0,
        .level = 0,
        .first_key = 0,
        .last_key = std.math.maxInt(u64),
        .digest = @splat(0),
    };
    try std.testing.expectError(error.InvalidBlobObjectHead, encodeHead(head));
}
