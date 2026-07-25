const std = @import("std");
const Io = std.Io;

pub const attribute_type: u8 = 0xe0;
pub const encoded_size: usize = 64;
const version: u8 = 1;

pub const Kind = enum(u8) {
    file = 1,
    directory = 2,
    symlink = 3,
    fifo = 4,
};

pub const Metadata = struct {
    kind: Kind,
    mode: u32,
    uid: u32,
    gid: u32,
    atime_ns: i64,
    mtime_ns: i64,
    ctime_ns: i64,
    birthtime_ns: i64,
    windows_attributes: u32 = 0,

    pub fn init(io: Io, kind: Kind, mode: u32, uid: u32, gid: u32) Metadata {
        const now: i64 = @intCast(Io.Clock.real.now(io).nanoseconds);
        return .{
            .kind = kind,
            .mode = mode,
            .uid = uid,
            .gid = gid,
            .atime_ns = now,
            .mtime_ns = now,
            .ctime_ns = now,
            .birthtime_ns = now,
        };
    }

    pub fn encode(metadata: Metadata) [encoded_size]u8 {
        var bytes: [encoded_size]u8 = @splat(0);
        bytes[0] = version;
        bytes[1] = @intFromEnum(metadata.kind);
        putInt(u32, &bytes, 4, metadata.mode);
        putInt(u32, &bytes, 8, metadata.uid);
        putInt(u32, &bytes, 12, metadata.gid);
        putInt(i64, &bytes, 16, metadata.atime_ns);
        putInt(i64, &bytes, 24, metadata.mtime_ns);
        putInt(i64, &bytes, 32, metadata.ctime_ns);
        putInt(i64, &bytes, 40, metadata.birthtime_ns);
        putInt(u32, &bytes, 48, metadata.windows_attributes);
        putInt(u32, &bytes, 60, checksum(bytes[0..60]));
        return bytes;
    }

    pub fn decode(bytes: *const [encoded_size]u8) !Metadata {
        if (bytes[0] != version) return error.UnsupportedMetadata;
        if (getInt(u32, bytes, 60) != checksum(bytes[0..60])) return error.InvalidMetadata;
        return .{
            .kind = std.enums.fromInt(Kind, bytes[1]) orelse return error.InvalidMetadata,
            .mode = getInt(u32, bytes, 4),
            .uid = getInt(u32, bytes, 8),
            .gid = getInt(u32, bytes, 12),
            .atime_ns = getInt(i64, bytes, 16),
            .mtime_ns = getInt(i64, bytes, 24),
            .ctime_ns = getInt(i64, bytes, 32),
            .birthtime_ns = getInt(i64, bytes, 40),
            .windows_attributes = getInt(u32, bytes, 48),
        };
    }
};

pub const Patch = struct {
    mode: ?u32 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    atime_ns: ?i64 = null,
    mtime_ns: ?i64 = null,
};

fn checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(bytes);
}

fn putInt(comptime T: type, bytes: *[encoded_size]u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn getInt(comptime T: type, bytes: *const [encoded_size]u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "metadata round trip" {
    const value: Metadata = .{
        .kind = .symlink,
        .mode = 0o120777,
        .uid = 1000,
        .gid = 1000,
        .atime_ns = 1,
        .mtime_ns = 2,
        .ctime_ns = 3,
        .birthtime_ns = 4,
    };
    const decoded = try Metadata.decode(&value.encode());
    try std.testing.expectEqual(value.kind, decoded.kind);
    try std.testing.expectEqual(value.mode, decoded.mode);
    try std.testing.expectEqual(value.mtime_ns, decoded.mtime_ns);
    try std.testing.expectEqual(value.uid, decoded.uid);
    try std.testing.expectEqual(value.gid, decoded.gid);
    try std.testing.expectEqual(value.atime_ns, decoded.atime_ns);
    try std.testing.expectEqual(value.ctime_ns, decoded.ctime_ns);
    try std.testing.expectEqual(value.birthtime_ns, decoded.birthtime_ns);
    try std.testing.expectEqual(value.windows_attributes, decoded.windows_attributes);
}

test "metadata rejects corruption version and kind" {
    const value: Metadata = .{
        .kind = .file,
        .mode = 0o100644,
        .uid = 1,
        .gid = 2,
        .atime_ns = -1,
        .mtime_ns = 2,
        .ctime_ns = 3,
        .birthtime_ns = 4,
    };
    var bytes = value.encode();
    bytes[20] ^= 1;
    try std.testing.expectError(error.InvalidMetadata, Metadata.decode(&bytes));
    bytes = value.encode();
    bytes[0] = 99;
    try std.testing.expectError(error.UnsupportedMetadata, Metadata.decode(&bytes));
    bytes = value.encode();
    bytes[1] = 99;
    std.mem.writeInt(u32, bytes[60..64], checksum(bytes[0..60]), .little);
    try std.testing.expectError(error.InvalidMetadata, Metadata.decode(&bytes));
}
