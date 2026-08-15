const std = @import("std");
const Io = std.Io;
const google_crc32c = @import("crc32c");

pub const attribute_type: u8 = 0xe0;
pub const directory_identity_attribute_type: u8 = 0xe1;
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
    update_ctime: bool = true,
};

pub fn relatimeNeedsUpdate(value: Metadata, now_ns: i64) bool {
    if (value.atime_ns <= value.mtime_ns or value.atime_ns <= value.ctime_ns) return true;
    const now_seconds = @divFloor(now_ns, @as(i64, std.time.ns_per_s));
    const atime_seconds = @divFloor(value.atime_ns, @as(i64, std.time.ns_per_s));
    return now_seconds - atime_seconds > 24 * 60 * 60;
}

fn checksum(bytes: []const u8) u32 {
    return google_crc32c.value(bytes);
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

test "relatime updates for metadata changes and once per day" {
    const day_ns: i64 = 24 * 60 * 60 * std.time.ns_per_s;
    const base: Metadata = .{
        .kind = .file,
        .mode = 0o100644,
        .uid = 1,
        .gid = 2,
        .atime_ns = 10 * std.time.ns_per_s + 500,
        .mtime_ns = 9 * std.time.ns_per_s,
        .ctime_ns = 9 * std.time.ns_per_s,
        .birthtime_ns = 0,
    };

    try std.testing.expect(!relatimeNeedsUpdate(base, base.atime_ns + day_ns));
    try std.testing.expect(relatimeNeedsUpdate(base, base.atime_ns + day_ns + std.time.ns_per_s));

    var changed = base;
    changed.mtime_ns = changed.atime_ns;
    try std.testing.expect(relatimeNeedsUpdate(changed, changed.atime_ns));
    changed.mtime_ns -= 1;
    changed.ctime_ns = changed.atime_ns;
    try std.testing.expect(relatimeNeedsUpdate(changed, changed.atime_ns));

    var future = base;
    future.atime_ns = 20 * std.time.ns_per_s;
    try std.testing.expect(!relatimeNeedsUpdate(future, 10 * std.time.ns_per_s));
}
