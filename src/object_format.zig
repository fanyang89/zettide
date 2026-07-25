const std = @import("std");
const metadata = @import("metadata.zig");

pub const ObjectId = [16]u8;
pub const ref_encoded_size: usize = 64;
pub const head_encoded_size: usize = 192;
pub const format_version: u16 = 1;
pub const chunk_size: u32 = 1024 * 1024;
pub const max_file_size: u64 = std.math.maxInt(i64);

const ref_magic = [8]u8{ 'D', 'D', 'V', 'R', 'E', 'F', '2', 0 };
const head_magic = [8]u8{ 'D', 'D', 'V', 'H', 'E', 'A', 'D', '2' };

pub const RefKind = enum(u8) {
    file = 1,
    symlink = 2,
    fifo = 3,
};

pub const ObjectRef = struct {
    kind: RefKind,
    object_id: ObjectId,

    pub fn encode(value: ObjectRef) [ref_encoded_size]u8 {
        var bytes: [ref_encoded_size]u8 = @splat(0);
        @memcpy(bytes[0..ref_magic.len], &ref_magic);
        putInt(u16, &bytes, 8, format_version);
        bytes[10] = @intFromEnum(value.kind);
        @memcpy(bytes[16..32], &value.object_id);
        putInt(u32, &bytes, 60, checksum(bytes[0..60]));
        return bytes;
    }

    pub fn decode(bytes: *const [ref_encoded_size]u8) !ObjectRef {
        if (!std.mem.eql(u8, bytes[0..ref_magic.len], &ref_magic)) return error.InvalidObjectRef;
        if (getInt(u16, bytes, 8) != format_version) return error.UnsupportedObjectFormat;
        if (getInt(u32, bytes, 60) != checksum(bytes[0..60])) return error.InvalidObjectRef;
        return .{
            .kind = std.enums.fromInt(RefKind, bytes[10]) orelse return error.InvalidObjectRef,
            .object_id = bytes[16..32].*,
        };
    }
};

pub const ObjectHead = struct {
    object_id: ObjectId,
    generation: u64,
    logical_size: u64,
    allocated_bytes: u64,
    metadata: metadata.Metadata,
    stored_chunk_size: u32 = chunk_size,
    data_generation: u64 = 1,

    pub fn encode(value: ObjectHead) [head_encoded_size]u8 {
        var bytes: [head_encoded_size]u8 = @splat(0);
        @memcpy(bytes[0..head_magic.len], &head_magic);
        putInt(u16, &bytes, 8, format_version);
        putInt(u16, &bytes, 10, head_encoded_size);
        @memcpy(bytes[16..32], &value.object_id);
        putInt(u64, &bytes, 32, value.generation);
        putInt(u64, &bytes, 40, value.logical_size);
        putInt(u64, &bytes, 48, value.allocated_bytes);
        const metadata_bytes = value.metadata.encode();
        @memcpy(bytes[56..120], &metadata_bytes);
        putInt(u32, &bytes, 120, value.stored_chunk_size);
        putInt(u64, &bytes, 124, value.data_generation);
        putInt(u32, &bytes, 188, checksum(bytes[0..188]));
        return bytes;
    }

    pub fn decode(bytes: *const [head_encoded_size]u8) !ObjectHead {
        if (!std.mem.eql(u8, bytes[0..head_magic.len], &head_magic)) return error.InvalidObjectHead;
        if (getInt(u16, bytes, 8) != format_version or
            getInt(u16, bytes, 10) != head_encoded_size)
            return error.UnsupportedObjectFormat;
        if (getInt(u32, bytes, 188) != checksum(bytes[0..188])) return error.InvalidObjectHead;
        const logical_size = getInt(u64, bytes, 40);
        if (logical_size > max_file_size) return error.InvalidObjectHead;
        const stored_chunk_size = getInt(u32, bytes, 120);
        if (stored_chunk_size == 0 or stored_chunk_size > 2_147_483_647)
            return error.InvalidObjectHead;
        const generation = getInt(u64, bytes, 32);
        const data_generation = getInt(u64, bytes, 124);
        if (data_generation == 0 or data_generation > generation) return error.InvalidObjectHead;
        return .{
            .object_id = bytes[16..32].*,
            .generation = generation,
            .logical_size = logical_size,
            .allocated_bytes = getInt(u64, bytes, 48),
            .metadata = try metadata.Metadata.decode(bytes[56..120]),
            .stored_chunk_size = stored_chunk_size,
            .data_generation = data_generation,
        };
    }
};

pub fn formatObjectId(id: ObjectId, buffer: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{x}", .{id}) catch unreachable;
}

pub fn parseObjectId(value: []const u8) !ObjectId {
    if (value.len != 32) return error.InvalidObjectId;
    var id: ObjectId = undefined;
    for (&id, 0..) |*byte, index| {
        byte.* = std.fmt.parseInt(u8, value[index * 2 .. index * 2 + 2], 16) catch
            return error.InvalidObjectId;
    }
    return id;
}

fn checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(bytes);
}

fn putInt(comptime T: type, bytes: anytype, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn getInt(comptime T: type, bytes: anytype, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "object ref round trip and corruption" {
    const value: ObjectRef = .{
        .kind = .file,
        .object_id = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    };
    var bytes = value.encode();
    const decoded = try ObjectRef.decode(&bytes);
    try std.testing.expectEqual(value.kind, decoded.kind);
    try std.testing.expectEqualSlices(u8, &value.object_id, &decoded.object_id);
    bytes[20] ^= 1;
    try std.testing.expectError(error.InvalidObjectRef, ObjectRef.decode(&bytes));
}

test "FIFO ref uses the existing version and encoded size" {
    const value: ObjectRef = .{
        .kind = .fifo,
        .object_id = @splat(0x5a),
    };
    const bytes = value.encode();
    try std.testing.expectEqual(@as(usize, 64), bytes.len);
    try std.testing.expectEqual(format_version, std.mem.readInt(u16, bytes[8..10], .little));
    try std.testing.expectEqual(RefKind.fifo, (try ObjectRef.decode(&bytes)).kind);
}

test "object head preserves 63-bit logical size" {
    const value: ObjectHead = .{
        .object_id = @splat(0xa5),
        .generation = 42,
        .logical_size = max_file_size,
        .allocated_bytes = 4096,
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
    };
    const decoded = try ObjectHead.decode(&value.encode());
    try std.testing.expectEqual(max_file_size, decoded.logical_size);
    try std.testing.expectEqual(value.generation, decoded.generation);
    try std.testing.expectEqual(value.data_generation, decoded.data_generation);
    try std.testing.expectEqualSlices(u8, &value.object_id, &decoded.object_id);
    try std.testing.expectEqual(value.metadata.mode, decoded.metadata.mode);
}

test "object id has fixed lowercase hexadecimal representation" {
    var buffer: [32]u8 = undefined;
    const id: ObjectId = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try std.testing.expectEqualStrings("000102030405060708090a0b0c0d0e0f", formatObjectId(id, &buffer));
    try std.testing.expectEqualSlices(
        u8,
        &id,
        &(try parseObjectId("000102030405060708090a0b0c0d0e0f")),
    );
}
