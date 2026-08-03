//! Stable CAWFS volume header and physical region layout.

const std = @import("std");
const allocation = @import("allocation_format.zig");
const block = @import("conditional_block.zig");
const store = @import("store.zig");
const voting_region = @import("voting_region.zig");

pub const encoded_size = 512;
pub const format_version: u16 = 1;
pub const default_extent_size: u32 = 1024 * 1024;

const magic = "ZCAWVH\x00\x00";
const checksum_start = encoded_size - std.crypto.hash.sha2.Sha256.digest_length;
const primary_header_block: u64 = 0;
const secondary_header_block: u64 = 1;
const anchor_block: u64 = 2;
const voting_base_block: u64 = 3;
const fixed_block_count = voting_base_block + voting_region.region_block_count;

pub const Layout = struct {
    header_primary_block: u64 = primary_header_block,
    header_secondary_block: u64 = secondary_header_block,
    anchor_block: u64 = anchor_block,
    voting_base_block: u64 = voting_base_block,
    allocator_base_block: u64,
    allocator_block_count: u64,
    extent_base_block: u64,
    extent_count: u64,

    pub fn compute(geometry: block.Geometry, extent_size: u32) !Layout {
        try geometry.validate();
        if (extent_size < geometry.logical_block_size or
            !std.math.isPowerOfTwo(extent_size) or
            extent_size % geometry.logical_block_size != 0)
        {
            return error.InvalidExtentSize;
        }
        const extent_blocks = extent_size / geometry.logical_block_size;
        if (geometry.block_count <= fixed_block_count) return error.DeviceTooSmall;
        const entries_per_page = try allocation.entriesPerPage(geometry.logical_block_size);
        var lower: u64 = 0;
        var upper = (geometry.block_count - fixed_block_count) / extent_blocks;
        while (lower < upper) {
            const difference = upper - lower;
            const candidate = lower + difference / 2 + difference % 2;
            if (try layoutFits(
                geometry.block_count,
                extent_blocks,
                entries_per_page,
                candidate,
            )) {
                lower = candidate;
            } else {
                upper = candidate - 1;
            }
        }
        const extent_count = lower;
        if (extent_count == 0) return error.DeviceTooSmall;
        const allocator_blocks = try divCeil(extent_count, entries_per_page);
        const after_allocator = std.math.add(u64, fixed_block_count, allocator_blocks) catch
            return error.DeviceTooLarge;
        const extent_base = try alignForward(after_allocator, extent_blocks);
        return .{
            .allocator_base_block = fixed_block_count,
            .allocator_block_count = allocator_blocks,
            .extent_base_block = extent_base,
            .extent_count = extent_count,
        };
    }
};

pub const Header = struct {
    volume_id: [16]u8,
    created_ns: i64,
    logical_block_size: u32,
    extent_size: u32,
    block_count: u64,
    layout: Layout,

    pub fn init(
        volume_id: [16]u8,
        created_ns: i64,
        device_geometry: block.Geometry,
        extent_size: u32,
    ) !Header {
        if (allZero(&volume_id)) return error.InvalidVolumeId;
        return .{
            .volume_id = volume_id,
            .created_ns = created_ns,
            .logical_block_size = device_geometry.logical_block_size,
            .extent_size = extent_size,
            .block_count = device_geometry.block_count,
            .layout = try Layout.compute(device_geometry, extent_size),
        };
    }

    pub fn geometry(self: Header) block.Geometry {
        return .{
            .logical_block_size = self.logical_block_size,
            .block_count = self.block_count,
        };
    }
};

pub const Encoded = [encoded_size]u8;

pub fn encode(header: Header) !Encoded {
    try validate(header);
    var bytes: Encoded = @splat(0);
    @memcpy(bytes[0..magic.len], magic);
    putInt(u16, &bytes, 8, format_version);
    putInt(u16, &bytes, 12, encoded_size);
    @memcpy(bytes[16..32], &header.volume_id);
    putInt(u32, &bytes, 32, header.logical_block_size);
    putInt(u32, &bytes, 36, header.extent_size);
    putInt(u64, &bytes, 40, header.block_count);
    putInt(u64, &bytes, 48, header.layout.header_primary_block);
    putInt(u64, &bytes, 56, header.layout.header_secondary_block);
    putInt(u64, &bytes, 64, header.layout.anchor_block);
    putInt(u64, &bytes, 72, header.layout.voting_base_block);
    putInt(u64, &bytes, 80, header.layout.allocator_base_block);
    putInt(u64, &bytes, 88, header.layout.allocator_block_count);
    putInt(u64, &bytes, 96, header.layout.extent_base_block);
    putInt(u64, &bytes, 104, header.layout.extent_count);
    putInt(i64, &bytes, 112, header.created_ns);
    seal(&bytes);
    return bytes;
}

pub fn decode(bytes: []const u8) !Header {
    if (bytes.len != encoded_size) return error.InvalidSize;
    const encoded: *const Encoded = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, encoded[0..magic.len], magic)) return error.InvalidMagic;
    if (getInt(u16, encoded, 8) != format_version) return error.UnsupportedFormatVersion;
    if (getInt(u16, encoded, 10) != 0 or
        getInt(u16, encoded, 12) != encoded_size or
        getInt(u16, encoded, 14) != 0 or
        !allZero(encoded[120..checksum_start]))
    {
        return error.NonCanonicalEncoding;
    }
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    checksum(encoded, &expected);
    if (!std.mem.eql(u8, encoded[checksum_start..], &expected))
        return error.ChecksumMismatch;

    const header = Header{
        .volume_id = encoded[16..32].*,
        .logical_block_size = getInt(u32, encoded, 32),
        .extent_size = getInt(u32, encoded, 36),
        .block_count = getInt(u64, encoded, 40),
        .layout = .{
            .header_primary_block = getInt(u64, encoded, 48),
            .header_secondary_block = getInt(u64, encoded, 56),
            .anchor_block = getInt(u64, encoded, 64),
            .voting_base_block = getInt(u64, encoded, 72),
            .allocator_base_block = getInt(u64, encoded, 80),
            .allocator_block_count = getInt(u64, encoded, 88),
            .extent_base_block = getInt(u64, encoded, 96),
            .extent_count = getInt(u64, encoded, 104),
        },
        .created_ns = getInt(i64, encoded, 112),
    };
    try validate(header);
    return header;
}

pub fn encodePhysical(
    allocator: std.mem.Allocator,
    header: Header,
) !store.OwnedBytes {
    const encoded = try encode(header);
    const bytes = try allocator.alloc(u8, header.logical_block_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..encoded.len], &encoded);
    return .{ .allocator = allocator, .bytes = bytes };
}

pub fn decodePhysical(bytes: []const u8) !Header {
    if (bytes.len != 512 and bytes.len != 4096) return error.UnsupportedLogicalBlockSize;
    if (!allZero(bytes[encoded_size..])) return error.NonCanonicalPhysicalBlock;
    const header = try decode(bytes[0..encoded_size]);
    if (header.logical_block_size != bytes.len) return error.GeometryMismatch;
    return header;
}

pub fn validate(header: Header) !void {
    if (allZero(&header.volume_id)) return error.InvalidVolumeId;
    const expected = try Layout.compute(header.geometry(), header.extent_size);
    if (!std.meta.eql(expected, header.layout)) return error.InvalidLayout;
}

fn divCeil(value: u64, divisor: u32) !u64 {
    if (divisor == 0) return error.DeviceTooLarge;
    return value / divisor + @intFromBool(value % divisor != 0);
}

fn layoutFits(
    block_count: u64,
    extent_blocks: u32,
    entries_per_page: u32,
    extent_count: u64,
) !bool {
    if (extent_count == 0) return true;
    const allocator_blocks = try divCeil(extent_count, entries_per_page);
    const after_allocator = std.math.add(u64, fixed_block_count, allocator_blocks) catch
        return false;
    const extent_base = alignForward(after_allocator, extent_blocks) catch return false;
    if (extent_base >= block_count) return false;
    return extent_count <= (block_count - extent_base) / extent_blocks;
}

fn alignForward(value: u64, alignment: u32) !u64 {
    const adjusted = std.math.add(u64, value, alignment - 1) catch return error.DeviceTooLarge;
    return adjusted / alignment * alignment;
}

fn putInt(comptime T: type, bytes: *Encoded, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
}

fn getInt(comptime T: type, bytes: *const Encoded, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}

fn seal(bytes: *Encoded) void {
    checksum(bytes, bytes[checksum_start..]);
}

fn checksum(bytes: *const Encoded, output: *[std.crypto.hash.sha2.Sha256.digest_length]u8) void {
    var canonical = bytes.*;
    @memset(canonical[checksum_start..], 0);
    std.crypto.hash.sha2.Sha256.hash(&canonical, output, .{});
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn testId() [16]u8 {
    return .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
}

test "volume layout reserves fixed metadata and aligned extents" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        const layout = try Layout.compute(.{
            .logical_block_size = block_size,
            .block_count = 2 * 1024 * 1024 * 1024 / block_size,
        }, default_extent_size);
        const extent_blocks = default_extent_size / block_size;
        try std.testing.expectEqual(fixed_block_count, layout.allocator_base_block);
        try std.testing.expect(layout.allocator_block_count != 0);
        try std.testing.expectEqual(@as(u64, 0), layout.extent_base_block % extent_blocks);
        try std.testing.expect(layout.extent_base_block + layout.extent_count * extent_blocks <=
            2 * 1024 * 1024 * 1024 / block_size);
        try std.testing.expect(layout.allocator_block_count *
            try allocation.entriesPerPage(block_size) >= layout.extent_count);
    }
}

test "volume layout converges at allocator alignment boundaries" {
    const first = try Layout.compute(.{
        .logical_block_size = 512,
        .block_count = 16,
    }, 512);
    try std.testing.expectEqual(@as(u64, 4), first.extent_count);
    const second = try Layout.compute(.{
        .logical_block_size = 4096,
        .block_count = 53,
    }, 4096);
    try std.testing.expectEqual(@as(u64, 41), second.extent_count);
    const threshold = try Layout.compute(.{
        .logical_block_size = 512,
        .block_count = 15,
    }, 512);
    try std.testing.expectEqual(@as(u64, 4), threshold.extent_count);
}

test "volume header v1 encoding matches the golden vector" {
    const header = try Header.init(testId(), 123456, .{
        .logical_block_size = 512,
        .block_count = 4 * 1024 * 1024,
    }, default_extent_size);
    const encoded = try encode(header);
    var expected: Encoded = @splat(0);
    @memcpy(expected[0..8], "ZCAWVH\x00\x00");
    expected[9] = 1;
    expected[12] = 2;
    @memcpy(expected[16..32], &testId());
    expected[34] = 2;
    expected[36] = 0;
    expected[37] = 0x10;
    expected[40..48].* = .{ 0, 0, 0, 0, 0, 0x40, 0, 0 };
    expected[63] = 1;
    expected[71] = 2;
    expected[79] = 3;
    expected[87] = 10;
    expected[94] = 2;
    expected[95] = 0;
    expected[102] = 8;
    expected[103] = 0;
    expected[110] = 7;
    expected[111] = 0xff;
    expected[117..120].* = .{ 1, 0xe2, 0x40 };
    @memcpy(expected[480..512], &[_]u8{
        0xf2, 0xb7, 0xe2, 0x90, 0xc4, 0xd4, 0x38, 0x3e,
        0xc3, 0x67, 0x55, 0x1c, 0x6c, 0x30, 0x5b, 0xb8,
        0x59, 0xba, 0xc6, 0xec, 0x91, 0x27, 0x0c, 0xcb,
        0x83, 0xff, 0xd2, 0x25, 0xab, 0xd5, 0xae, 0xfc,
    });
    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    try std.testing.expectEqual(header, try decode(&expected));
}

test "volume header round trips in 512 and 4096 byte physical blocks" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        const header = try Header.init(testId(), 123456, .{
            .logical_block_size = block_size,
            .block_count = 2 * 1024 * 1024 * 1024 / block_size,
        }, default_extent_size);
        var physical = try encodePhysical(std.testing.allocator, header);
        defer physical.deinit();
        try std.testing.expectEqual(header, try decodePhysical(physical.bytes));
    }
}

test "volume header rejects corruption and physical padding" {
    const header = try Header.init(testId(), 123456, .{
        .logical_block_size = 4096,
        .block_count = 1024 * 1024,
    }, default_extent_size);
    var physical = try encodePhysical(std.testing.allocator, header);
    defer physical.deinit();
    physical.bytes[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodePhysical(physical.bytes));
    physical.bytes[100] ^= 1;
    physical.bytes[encoded_size] = 1;
    try std.testing.expectError(error.NonCanonicalPhysicalBlock, decodePhysical(physical.bytes));
}
