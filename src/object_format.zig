const std = @import("std");
const metadata = @import("metadata.zig");
const google_crc32c = @import("crc32c");

pub const ObjectId = [16]u8;
pub const ref_encoded_size: usize = 64;
pub const head_encoded_size: usize = 192;
pub const format_version: u16 = 1;
pub const head_format_version: u16 = 2;
pub const chunk_size: u32 = 1024 * 1024;
pub const max_file_size: u64 = std.math.maxInt(i64);

const ref_magic = [8]u8{ 'D', 'D', 'V', 'R', 'E', 'F', '2', 0 };
const head_magic = [8]u8{ 'D', 'D', 'V', 'H', 'E', 'A', 'D', '2' };
const reservation_magic = [8]u8{ 'D', 'D', 'V', 'R', 'S', 'V', '1', 0 };
const reservation_format_version: u16 = 1;
const reservation_header_size: usize = 32;
const reservation_entry_size: usize = 16;
const reservation_checksum_size: usize = 4;

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
    reservation_generation: u64 = 0,
    reservation_interval_bytes: u64 = 0,
    reservation_payload_bytes: u64 = 0,
    reservation_existing_bytes: u64 = 0,
    reservation_chunk_count: u64 = 0,
    reservation_interval_count: u64 = 0,

    pub fn encode(value: ObjectHead) [head_encoded_size]u8 {
        var bytes: [head_encoded_size]u8 = @splat(0);
        @memcpy(bytes[0..head_magic.len], &head_magic);
        putInt(u16, &bytes, 8, head_format_version);
        putInt(u16, &bytes, 10, head_encoded_size);
        @memcpy(bytes[16..32], &value.object_id);
        putInt(u64, &bytes, 32, value.generation);
        putInt(u64, &bytes, 40, value.logical_size);
        putInt(u64, &bytes, 48, value.allocated_bytes);
        const metadata_bytes = value.metadata.encode();
        @memcpy(bytes[56..120], &metadata_bytes);
        putInt(u32, &bytes, 120, value.stored_chunk_size);
        putInt(u64, &bytes, 124, value.data_generation);
        putInt(u64, &bytes, 132, value.reservation_generation);
        putInt(u64, &bytes, 140, value.reservation_interval_bytes);
        putInt(u64, &bytes, 148, value.reservation_payload_bytes);
        putInt(u64, &bytes, 156, value.reservation_existing_bytes);
        putInt(u64, &bytes, 164, value.reservation_chunk_count);
        putInt(u64, &bytes, 172, value.reservation_interval_count);
        putInt(u32, &bytes, 188, checksum(bytes[0..188]));
        return bytes;
    }

    pub fn decode(bytes: *const [head_encoded_size]u8) !ObjectHead {
        if (!std.mem.eql(u8, bytes[0..head_magic.len], &head_magic)) return error.InvalidObjectHead;
        const version = getInt(u16, bytes, 8);
        if ((version != format_version and version != head_format_version) or
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
        var result: ObjectHead = .{
            .object_id = bytes[16..32].*,
            .generation = generation,
            .logical_size = logical_size,
            .allocated_bytes = getInt(u64, bytes, 48),
            .metadata = try metadata.Metadata.decode(bytes[56..120]),
            .stored_chunk_size = stored_chunk_size,
            .data_generation = data_generation,
        };
        if (version == head_format_version) {
            result.reservation_generation = getInt(u64, bytes, 132);
            result.reservation_interval_bytes = getInt(u64, bytes, 140);
            result.reservation_payload_bytes = getInt(u64, bytes, 148);
            result.reservation_existing_bytes = getInt(u64, bytes, 156);
            result.reservation_chunk_count = getInt(u64, bytes, 164);
            result.reservation_interval_count = getInt(u64, bytes, 172);
            if (result.reservation_generation > generation or
                result.reservation_interval_bytes > max_file_size or
                result.reservation_payload_bytes > max_file_size or
                result.reservation_existing_bytes > result.reservation_payload_bytes or
                result.reservation_existing_bytes > result.allocated_bytes)
                return error.InvalidObjectHead;
            const empty = result.reservation_generation == 0;
            if (empty != (result.reservation_interval_bytes == 0) or
                empty != (result.reservation_payload_bytes == 0) or
                empty != (result.reservation_chunk_count == 0) or
                empty != (result.reservation_interval_count == 0))
                return error.InvalidObjectHead;
        }
        return result;
    }
};

pub const ReservationInterval = struct {
    start: u64,
    end: u64,
};

pub const ReservationSidecar = struct {
    generation: u64,
    intervals: []ReservationInterval,

    pub fn encodeAlloc(
        allocator: std.mem.Allocator,
        generation: u64,
        intervals: []const ReservationInterval,
    ) ![]u8 {
        if (generation == 0 or intervals.len == 0) return error.InvalidReservation;
        const entries_size = std.math.mul(usize, intervals.len, reservation_entry_size) catch
            return error.OutOfMemory;
        const size = std.math.add(usize, reservation_header_size + reservation_checksum_size, entries_size) catch
            return error.OutOfMemory;
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);
        @memset(bytes, 0);
        @memcpy(bytes[0..reservation_magic.len], &reservation_magic);
        putInt(u16, bytes, 8, reservation_format_version);
        putInt(u16, bytes, 10, reservation_header_size);
        putInt(u64, bytes, 16, generation);
        putInt(u64, bytes, 24, @intCast(intervals.len));
        var previous_end: u64 = 0;
        for (intervals, 0..) |interval, index| {
            if (interval.start >= interval.end or interval.end > max_file_size or
                (index != 0 and previous_end >= interval.start))
                return error.InvalidReservation;
            const offset = reservation_header_size + index * reservation_entry_size;
            putInt(u64, bytes, offset, interval.start);
            putInt(u64, bytes, offset + 8, interval.end);
            previous_end = interval.end;
        }
        putInt(u32, bytes, size - reservation_checksum_size, checksum(bytes[0 .. size - reservation_checksum_size]));
        return bytes;
    }

    pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) !ReservationSidecar {
        if (bytes.len < reservation_header_size + reservation_checksum_size or
            !std.mem.eql(u8, bytes[0..reservation_magic.len], &reservation_magic))
            return error.InvalidReservation;
        if (getInt(u16, bytes, 8) != reservation_format_version or
            getInt(u16, bytes, 10) != reservation_header_size)
            return error.UnsupportedObjectFormat;
        const count = getInt(u64, bytes, 24);
        if (count == 0 or count > std.math.maxInt(usize)) return error.InvalidReservation;
        const entries_size = std.math.mul(usize, @intCast(count), reservation_entry_size) catch
            return error.InvalidReservation;
        const expected_size = std.math.add(usize, reservation_header_size + reservation_checksum_size, entries_size) catch
            return error.InvalidReservation;
        if (bytes.len != expected_size or getInt(u32, bytes, bytes.len - reservation_checksum_size) !=
            checksum(bytes[0 .. bytes.len - reservation_checksum_size]))
            return error.InvalidReservation;
        const intervals = try allocator.alloc(ReservationInterval, @intCast(count));
        errdefer allocator.free(intervals);
        var previous_end: u64 = 0;
        for (intervals, 0..) |*interval, index| {
            const offset = reservation_header_size + index * reservation_entry_size;
            interval.* = .{
                .start = getInt(u64, bytes, offset),
                .end = getInt(u64, bytes, offset + 8),
            };
            if (interval.start >= interval.end or interval.end > max_file_size or
                (index != 0 and previous_end >= interval.start))
                return error.InvalidReservation;
            previous_end = interval.end;
        }
        return .{ .generation = getInt(u64, bytes, 16), .intervals = intervals };
    }

    pub fn deinit(self: ReservationSidecar, allocator: std.mem.Allocator) void {
        allocator.free(self.intervals);
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
    return google_crc32c.value(bytes);
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
    try std.testing.expectEqual(head_format_version, std.mem.readInt(u16, value.encode()[8..10], .little));
    try std.testing.expectEqual(@as(u64, 0), decoded.reservation_generation);
    try std.testing.expectEqualSlices(u8, &value.object_id, &decoded.object_id);
    try std.testing.expectEqual(value.metadata.mode, decoded.metadata.mode);
}

test "object head v2 persists reservation selection and aggregates" {
    var value: ObjectHead = .{
        .object_id = @splat(0x3c),
        .generation = 2,
        .logical_size = 8192,
        .allocated_bytes = 1024,
        .metadata = .{
            .kind = .file,
            .mode = 0o100600,
            .uid = 1,
            .gid = 2,
            .atime_ns = 3,
            .mtime_ns = 4,
            .ctime_ns = 5,
            .birthtime_ns = 6,
        },
        .reservation_generation = 2,
        .reservation_interval_bytes = 4096,
        .reservation_payload_bytes = 8192,
        .reservation_existing_bytes = 1024,
        .reservation_chunk_count = 1,
        .reservation_interval_count = 1,
    };
    const decoded = try ObjectHead.decode(&value.encode());
    try std.testing.expectEqual(value.reservation_generation, decoded.reservation_generation);
    try std.testing.expectEqual(value.reservation_interval_bytes, decoded.reservation_interval_bytes);
    try std.testing.expectEqual(value.reservation_payload_bytes, decoded.reservation_payload_bytes);
    try std.testing.expectEqual(value.reservation_existing_bytes, decoded.reservation_existing_bytes);
    try std.testing.expectEqual(value.reservation_chunk_count, decoded.reservation_chunk_count);
    try std.testing.expectEqual(value.reservation_interval_count, decoded.reservation_interval_count);
}

test "object head v1 decodes without reservations" {
    const value: ObjectHead = .{
        .object_id = @splat(0x7a),
        .generation = 9,
        .logical_size = 12,
        .allocated_bytes = 3,
        .metadata = .{
            .kind = .file,
            .mode = 0o100600,
            .uid = 1,
            .gid = 2,
            .atime_ns = 3,
            .mtime_ns = 4,
            .ctime_ns = 5,
            .birthtime_ns = 6,
        },
        .reservation_generation = 8,
        .reservation_interval_bytes = 100,
        .reservation_payload_bytes = 200,
        .reservation_existing_bytes = 50,
        .reservation_chunk_count = 2,
        .reservation_interval_count = 2,
    };
    var bytes = value.encode();
    putInt(u16, &bytes, 8, format_version);
    putInt(u32, &bytes, 188, checksum(bytes[0..188]));
    const decoded = try ObjectHead.decode(&bytes);
    try std.testing.expectEqual(@as(u64, 0), decoded.reservation_generation);
    try std.testing.expectEqual(@as(u64, 0), decoded.reservation_interval_bytes);
    try std.testing.expectEqual(@as(u64, 0), decoded.reservation_payload_bytes);
    try std.testing.expectEqual(@as(u64, 0), decoded.reservation_existing_bytes);
    try std.testing.expectEqual(@as(u64, 0), decoded.reservation_chunk_count);
    try std.testing.expectEqual(@as(u64, 0), decoded.reservation_interval_count);
}

test "reservation sidecar round trip rejects non-canonical intervals" {
    const intervals = [_]ReservationInterval{
        .{ .start = 4096, .end = 8192 },
        .{ .start = 16384, .end = 20000 },
    };
    const bytes = try ReservationSidecar.encodeAlloc(std.testing.allocator, 7, &intervals);
    defer std.testing.allocator.free(bytes);
    const decoded = try ReservationSidecar.decodeAlloc(std.testing.allocator, bytes);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), decoded.generation);
    try std.testing.expectEqualSlices(ReservationInterval, &intervals, decoded.intervals);

    const adjacent = [_]ReservationInterval{
        .{ .start = 1, .end = 2 },
        .{ .start = 2, .end = 3 },
    };
    try std.testing.expectError(
        error.InvalidReservation,
        ReservationSidecar.encodeAlloc(std.testing.allocator, 1, &adjacent),
    );
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
