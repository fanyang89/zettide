const std = @import("std");
const google_crc32c = @import("crc32c");

pub const Digest = [32]u8;

pub fn putInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

pub fn getInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

pub fn crc32c(bytes: []const u8) u32 {
    return google_crc32c.value(bytes);
}

pub fn blake3(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return digest;
}

pub fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

pub const Region = struct {
    offset: u64,
    length: u64,

    pub fn end(self: Region) !u64 {
        return std.math.add(u64, self.offset, self.length) catch error.RegionOverflow;
    }

    pub fn validate(self: Region, alignment: u64) !void {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;
        if (self.offset % alignment != 0 or self.length % alignment != 0) return error.UnalignedRegion;
        _ = try self.end();
    }
};

pub fn alignForward(value: u64, alignment: u64) !u64 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return std.math.add(u64, value, alignment - remainder) catch error.RegionOverflow;
}

pub fn validateOrdered(first: Region, second: Region) !void {
    if (try first.end() > second.offset) return error.OverlappingRegions;
}

test "codec primitives" {
    var bytes: [8]u8 = undefined;
    putInt(u64, &bytes, 0, 0x0807060504030201);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &bytes);
    try std.testing.expectEqual(@as(u64, 0x0807060504030201), getInt(u64, &bytes, 0));
    try std.testing.expectError(error.RegionOverflow, (Region{ .offset = std.math.maxInt(u64), .length = 1 }).end());
    try std.testing.expectError(error.RegionOverflow, alignForward(std.math.maxInt(u64), 4096));
    try std.testing.expectEqual(std.math.maxInt(u64) - 4095, try alignForward(std.math.maxInt(u64) - 4095, 4096));
    try std.testing.expectError(error.OverlappingRegions, validateOrdered(
        .{ .offset = 4096, .length = 8192 },
        .{ .offset = 8192, .length = 4096 },
    ));
}
