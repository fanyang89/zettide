//! Stable CAWFS volume header and physical region layout.

const std = @import("std");
const allocation = @import("allocation_format.zig");
const block = @import("conditional_block.zig");
const claim_index = @import("claim_index_format.zig");
const store = @import("store.zig");
const voting_region = @import("voting_region.zig");

pub const encoded_size = 512;
pub const format_version: u16 = 2;
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
    claim_gate_base_block: u64,
    claim_stripe_count: u32,
    claim_index_base_block: u64,
    claim_index_block_count: u64,
    claim_index_slot_count: u64,
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
        const index_entries_per_page = try claim_index.entriesPerPage(geometry.logical_block_size);
        const stripe_count = adaptiveStripeCount(
            (geometry.block_count - fixed_block_count) / extent_blocks,
        );
        var lower: u64 = 0;
        var upper = (geometry.block_count - fixed_block_count) / extent_blocks;
        while (lower < upper) {
            const difference = upper - lower;
            const candidate = lower + difference / 2 + difference % 2;
            if (try layoutFits(
                geometry.block_count,
                extent_blocks,
                entries_per_page,
                index_entries_per_page,
                stripe_count,
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
        const multiplied = std.math.mul(u64, extent_count, 8) catch
            return error.DeviceTooLarge;
        const required_index_slots = try divCeil(multiplied, 7);
        const index_blocks = try divCeil(required_index_slots, index_entries_per_page);
        const index_slots = std.math.mul(u64, index_blocks, index_entries_per_page) catch
            return error.DeviceTooLarge;
        const after_gates = std.math.add(u64, fixed_block_count, stripe_count) catch
            return error.DeviceTooLarge;
        const index_base = after_gates;
        const allocator_base = std.math.add(u64, index_base, index_blocks) catch
            return error.DeviceTooLarge;
        const after_allocator = std.math.add(u64, allocator_base, allocator_blocks) catch
            return error.DeviceTooLarge;
        const extent_base = try alignForward(after_allocator, extent_blocks);
        return .{
            .claim_gate_base_block = fixed_block_count,
            .claim_stripe_count = stripe_count,
            .claim_index_base_block = index_base,
            .claim_index_block_count = index_blocks,
            .claim_index_slot_count = index_slots,
            .allocator_base_block = allocator_base,
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
    putInt(u64, &bytes, 80, header.layout.claim_gate_base_block);
    putInt(u32, &bytes, 88, header.layout.claim_stripe_count);
    putInt(u64, &bytes, 96, header.layout.claim_index_base_block);
    putInt(u64, &bytes, 104, header.layout.claim_index_block_count);
    putInt(u64, &bytes, 112, header.layout.claim_index_slot_count);
    putInt(u64, &bytes, 120, header.layout.allocator_base_block);
    putInt(u64, &bytes, 128, header.layout.allocator_block_count);
    putInt(u64, &bytes, 136, header.layout.extent_base_block);
    putInt(u64, &bytes, 144, header.layout.extent_count);
    putInt(i64, &bytes, 152, header.created_ns);
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
        getInt(u32, encoded, 92) != 0 or
        !allZero(encoded[160..checksum_start]))
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
            .claim_gate_base_block = getInt(u64, encoded, 80),
            .claim_stripe_count = getInt(u32, encoded, 88),
            .claim_index_base_block = getInt(u64, encoded, 96),
            .claim_index_block_count = getInt(u64, encoded, 104),
            .claim_index_slot_count = getInt(u64, encoded, 112),
            .allocator_base_block = getInt(u64, encoded, 120),
            .allocator_block_count = getInt(u64, encoded, 128),
            .extent_base_block = getInt(u64, encoded, 136),
            .extent_count = getInt(u64, encoded, 144),
        },
        .created_ns = getInt(i64, encoded, 152),
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
    index_entries_per_page: u32,
    stripe_count: u32,
    extent_count: u64,
) !bool {
    if (extent_count == 0) return true;
    const allocator_blocks = try divCeil(extent_count, entries_per_page);
    const multiplied = std.math.mul(u64, extent_count, 8) catch return false;
    const required_index_slots = try divCeil(multiplied, 7);
    const index_blocks = try divCeil(required_index_slots, index_entries_per_page);
    const after_gates = std.math.add(u64, fixed_block_count, stripe_count) catch
        return false;
    const after_index = std.math.add(u64, after_gates, index_blocks) catch return false;
    const after_allocator = std.math.add(u64, after_index, allocator_blocks) catch return false;
    const extent_base = alignForward(after_allocator, extent_blocks) catch return false;
    if (extent_base >= block_count) return false;
    return extent_count <= (block_count - extent_base) / extent_blocks;
}

fn adaptiveStripeCount(rough_extent_count: u64) u32 {
    if (rough_extent_count >= 1024) return 64;
    if (rough_extent_count >= 256) return 16;
    if (rough_extent_count >= 64) return 4;
    return 1;
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
        try std.testing.expectEqual(fixed_block_count, layout.claim_gate_base_block);
        try std.testing.expectEqual(@as(u32, 64), layout.claim_stripe_count);
        try std.testing.expectEqual(
            layout.claim_gate_base_block + layout.claim_stripe_count,
            layout.claim_index_base_block,
        );
        try std.testing.expectEqual(
            layout.claim_index_base_block + layout.claim_index_block_count,
            layout.allocator_base_block,
        );
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
    try std.testing.expect(first.extent_count != 0);
    const second = try Layout.compute(.{
        .logical_block_size = 4096,
        .block_count = 53,
    }, 4096);
    try std.testing.expect(second.extent_count != 0);
    const threshold = try Layout.compute(.{
        .logical_block_size = 512,
        .block_count = 15,
    }, 512);
    try std.testing.expect(threshold.extent_count != 0);
}

test "volume layout adapts claim stripes without penalizing tiny devices" {
    const tiny = try Layout.compute(.{
        .logical_block_size = 512,
        .block_count = 64,
    }, 512);
    try std.testing.expectEqual(@as(u32, 1), tiny.claim_stripe_count);

    const medium = try Layout.compute(.{
        .logical_block_size = 512,
        .block_count = 512,
    }, 512);
    try std.testing.expectEqual(@as(u32, 16), medium.claim_stripe_count);

    const realistic = try Layout.compute(.{
        .logical_block_size = 4096,
        .block_count = 2 * 1024 * 1024 * 1024 / 4096,
    }, default_extent_size);
    try std.testing.expectEqual(@as(u32, 64), realistic.claim_stripe_count);
}

test "volume header v2 encoding matches the golden vector" {
    const header = try Header.init(testId(), 123456, .{
        .logical_block_size = 512,
        .block_count = 4 * 1024 * 1024,
    }, default_extent_size);
    const encoded = try encode(header);
    var expected: Encoded = @splat(0);
    @memcpy(expected[0..8], "ZCAWVH\x00\x00");
    expected[9] = 2;
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
    expected[91] = 64;
    expected[103] = 0x4a;
    expected[110] = 0x02;
    expected[111] = 0x49;
    expected[118] = 0x09;
    expected[119] = 0x24;
    expected[126] = 0x02;
    expected[127] = 0x93;
    expected[134] = 0x02;
    expected[142] = 0x08;
    expected[150] = 0x07;
    expected[151] = 0xff;
    expected[157..160].* = .{ 1, 0xe2, 0x40 };
    @memcpy(expected[480..512], &[_]u8{
        0x8c, 0x11, 0x94, 0x77, 0x1b, 0x76, 0x7a, 0x48,
        0x6f, 0x23, 0x9c, 0xaf, 0x66, 0x2a, 0x25, 0x40,
        0xe0, 0x04, 0xa2, 0xef, 0x6a, 0xc3, 0xb3, 0xd8,
        0x42, 0x01, 0xa3, 0xbc, 0x06, 0x23, 0x68, 0x3f,
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
    physical.bytes[9] = format_version - 1;
    try std.testing.expectError(error.UnsupportedFormatVersion, decodePhysical(physical.bytes));
    physical.bytes[9] = format_version;
    physical.bytes[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodePhysical(physical.bytes));
    physical.bytes[100] ^= 1;
    physical.bytes[encoded_size] = 1;
    try std.testing.expectError(error.NonCanonicalPhysicalBlock, decodePhysical(physical.bytes));
}
