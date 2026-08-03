const std = @import("std");
const crc32c = @import("crc32c");
const metadata = @import("metadata.zig");
const object_format = @import("object_format.zig");

pub const encoded_size = 44;
const magic = [4]u8{ 'Z', 'N', 'F', 'H' };
const version: u8 = 1;

pub const Handle = struct {
    kind: metadata.Kind,
    identity: object_format.ObjectId,
};

pub fn encode(volume_uuid: [16]u8, handle: Handle) [encoded_size]u8 {
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0..magic.len], &magic);
    bytes[4] = version;
    bytes[5] = @intFromEnum(handle.kind);
    @memcpy(bytes[8..24], &volume_uuid);
    @memcpy(bytes[24..40], &handle.identity);
    std.mem.writeInt(u32, bytes[40..44], crc32c.value(bytes[0..40]), .little);
    return bytes;
}

pub fn decode(expected_volume_uuid: [16]u8, bytes: []const u8) !Handle {
    if (bytes.len != encoded_size or !std.mem.eql(u8, bytes[0..magic.len], &magic) or
        bytes[4] != version or bytes[6] != 0 or bytes[7] != 0 or
        std.mem.readInt(u32, bytes[40..44], .little) != crc32c.value(bytes[0..40]))
        return error.InvalidFileHandle;
    if (!std.mem.eql(u8, bytes[8..24], &expected_volume_uuid)) return error.ForeignVolume;
    return .{
        .kind = std.enums.fromInt(metadata.Kind, bytes[5]) orelse return error.InvalidFileHandle,
        .identity = bytes[24..40].*,
    };
}

test "NFS file handles have a stable canonical encoding" {
    const volume_uuid: [16]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const identity: object_format.ObjectId = .{
        15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
    };
    const bytes = encode(volume_uuid, .{ .kind = .directory, .identity = identity });
    try std.testing.expectEqualSlices(u8, &magic, bytes[0..4]);
    try std.testing.expectEqual(version, bytes[4]);
    try std.testing.expectEqual(@intFromEnum(metadata.Kind.directory), bytes[5]);
    try std.testing.expectEqualSlices(u8, &volume_uuid, bytes[8..24]);
    try std.testing.expectEqualSlices(u8, &identity, bytes[24..40]);
    const decoded = try decode(volume_uuid, &bytes);
    try std.testing.expectEqual(metadata.Kind.directory, decoded.kind);
    try std.testing.expectEqualSlices(u8, &identity, &decoded.identity);
}

test "NFS file handles reject malformed and foreign encodings" {
    const volume_uuid: [16]u8 = @splat(1);
    const identity: object_format.ObjectId = @splat(2);
    const canonical = encode(volume_uuid, .{ .kind = .file, .identity = identity });
    try std.testing.expectError(error.InvalidFileHandle, decode(volume_uuid, canonical[0 .. encoded_size - 1]));

    var corrupt = canonical;
    corrupt[24] ^= 1;
    try std.testing.expectError(error.InvalidFileHandle, decode(volume_uuid, &corrupt));

    var invalid_kind = canonical;
    invalid_kind[5] = 0xff;
    std.mem.writeInt(u32, invalid_kind[40..44], crc32c.value(invalid_kind[0..40]), .little);
    try std.testing.expectError(error.InvalidFileHandle, decode(volume_uuid, &invalid_kind));

    const foreign_uuid: [16]u8 = @splat(3);
    try std.testing.expectError(error.ForeignVolume, decode(foreign_uuid, &canonical));
}
