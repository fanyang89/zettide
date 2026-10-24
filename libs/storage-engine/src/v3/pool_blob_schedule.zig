const std = @import("std");
const codec = @import("codec.zig");

pub const max_member_count: usize = 12;
pub const replica_count: usize = 3;
pub const encoded_size: usize = 256;
pub const placement_page_size: usize = 4096;
pub const PlacementPage = [placement_page_size]u8;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);

const magic = [8]u8{ 'D', 'D', 'B', 'S', 'C', 'H', '1', 0 };
const format_version: u16 = 1;
const entries_offset: usize = 0x030;
const entry_size: usize = 16;
const reserved_offset: usize = entries_offset + max_member_count * entry_size;

pub const Entry = struct {
    slot: u16 = 0,
    assigned_stripes: u64 = 0,
};

pub const PlacementPlan = struct {
    stripe_size: u32,
    logical_stripe_count: u64,
    multiplier: u64,
    addend: u64,
    member_count: u16,
    entries: [max_member_count]Entry = @splat(.{}),
    flags: u16 = 0,

    pub fn memberSlice(self: *const PlacementPlan) []const Entry {
        return self.entries[0..self.member_count];
    }
};

pub fn encode(plan: PlacementPlan) ![encoded_size]u8 {
    try validate(plan);
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, plan.flags);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    codec.putInt(u32, &bytes, 0x010, plan.stripe_size);
    codec.putInt(u16, &bytes, 0x014, plan.member_count);
    codec.putInt(u16, &bytes, 0x016, replica_count);
    codec.putInt(u64, &bytes, 0x018, plan.logical_stripe_count);
    codec.putInt(u64, &bytes, 0x020, plan.multiplier);
    codec.putInt(u64, &bytes, 0x028, plan.addend);
    for (plan.memberSlice(), 0..) |entry, index| {
        const offset = entries_offset + index * entry_size;
        codec.putInt(u16, &bytes, offset, entry.slot);
        codec.putInt(u64, &bytes, offset + 8, entry.assigned_stripes);
    }
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(bytes: *const [encoded_size]u8) !PlacementPlan {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != format_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size) return error.InvalidEncodedSize;
    if (codec.getInt(u16, bytes, 0x016) != replica_count) return error.InvalidReplicaCount;
    if (!codec.isZero(bytes[reserved_offset..checksum_offset])) return error.NonZeroReserved;

    const member_count = codec.getInt(u16, bytes, 0x014);
    if (member_count < replica_count or member_count > max_member_count) return error.InvalidMemberCount;
    var plan: PlacementPlan = .{
        .stripe_size = codec.getInt(u32, bytes, 0x010),
        .logical_stripe_count = codec.getInt(u64, bytes, 0x018),
        .multiplier = codec.getInt(u64, bytes, 0x020),
        .addend = codec.getInt(u64, bytes, 0x028),
        .member_count = member_count,
        .flags = codec.getInt(u16, bytes, 0x00a),
    };
    for (0..max_member_count) |index| {
        const offset = entries_offset + index * entry_size;
        if (!codec.isZero(bytes[offset + 2 .. offset + 8])) return error.NonZeroReserved;
        if (index < member_count) {
            plan.entries[index] = .{
                .slot = codec.getInt(u16, bytes, offset),
                .assigned_stripes = codec.getInt(u64, bytes, offset + 8),
            };
        } else if (!codec.isZero(bytes[offset .. offset + entry_size])) {
            return error.NonCanonicalUnusedEntry;
        }
    }
    try validate(plan);
    return plan;
}

pub fn encodePage(plan: PlacementPlan) !PlacementPage {
    var page: PlacementPage = @splat(0);
    page[0..encoded_size].* = try encode(plan);
    return page;
}

pub fn decodePage(page: *const PlacementPage) !PlacementPlan {
    if (!codec.isZero(page[encoded_size..])) return error.NonZeroPageTail;
    return decode(page[0..encoded_size]);
}

pub fn digest(plan: PlacementPlan) !codec.Digest {
    const bytes = try encode(plan);
    return codec.blake3(bytes[0..checksum_offset]);
}

pub fn validate(plan: PlacementPlan) !void {
    if (plan.stripe_size < 4096 or !std.math.isPowerOfTwo(plan.stripe_size))
        return error.InvalidStripeSize;
    if (plan.logical_stripe_count == 0) return error.InvalidLogicalStripeCount;
    if (plan.member_count < replica_count or plan.member_count > max_member_count)
        return error.InvalidMemberCount;
    if (plan.flags != 0) return error.InvalidFlags;
    if (plan.logical_stripe_count == 1) {
        if (plan.multiplier != 0 or plan.addend != 0) return error.InvalidPermutation;
    } else if (plan.multiplier == 0 or plan.multiplier >= plan.logical_stripe_count or
        gcd(plan.multiplier, plan.logical_stripe_count) != 1 or plan.addend >= plan.logical_stripe_count)
    {
        return error.InvalidPermutation;
    }

    var sum: u128 = 0;
    for (plan.memberSlice(), 0..) |entry, index| {
        if (index != 0 and plan.entries[index - 1].slot >= entry.slot) return error.NonCanonicalSlotOrder;
        if (entry.assigned_stripes == 0 or entry.assigned_stripes > plan.logical_stripe_count)
            return error.InvalidAssignedStripeCount;
        sum += entry.assigned_stripes;
    }
    if (sum != @as(u128, replica_count) * plan.logical_stripe_count)
        return error.InvalidAssignedStripeSum;
    for (plan.entries[plan.member_count..]) |entry| {
        if (entry.slot != 0 or entry.assigned_stripes != 0) return error.NonCanonicalUnusedEntry;
    }
}

fn gcd(a_initial: u64, b_initial: u64) u64 {
    var a = a_initial;
    var b = b_initial;
    while (b != 0) {
        const remainder = a % b;
        a = b;
        b = remainder;
    }
    return a;
}

fn fixChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

fn testGoldenBytes() ![encoded_size]u8 {
    // Frozen legacy planner output: six Members, 17 stripes each, seed 41.
    var bytes: [encoded_size]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, "44444253434831000100000000010000000010000600030022000000000000000f00000000000000070000000000000001000000000000001100000000000000" ++
        "02000000000000001100000000000000030000000000000011000000000000000400000000000000110000000000000005000000000000001100000000000000" ++
        "06000000000000001100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" ++
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f1cc9e43");
    return bytes;
}

test "historical placement golden bytes retain exact wire identity" {
    const bytes = try testGoldenBytes();
    const plan = try decode(&bytes);
    try std.testing.expectEqual(@as(u16, 6), plan.member_count);
    try std.testing.expectEqual(@as(u64, 34), plan.logical_stripe_count);
    try std.testing.expectEqual(@as(u64, 15), plan.multiplier);
    try std.testing.expectEqual(@as(u64, 7), plan.addend);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encode(plan)));
}

test "placement plan codec is canonical and rejects envelope corruption" {
    const canonical = try testGoldenBytes();
    try std.testing.expectEqualSlices(u8, &canonical, &(try encode(try decode(&canonical))));
    try std.testing.expectEqual(codec.blake3(canonical[0..checksum_offset]), try digest(try decode(&canonical)));

    var bytes = canonical;
    bytes[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&bytes));
    bytes = canonical;
    bytes[0] ^= 1;
    fixChecksum(&bytes);
    try std.testing.expectError(error.InvalidMagic, decode(&bytes));
    bytes = canonical;
    codec.putInt(u16, &bytes, 0x008, format_version + 1);
    fixChecksum(&bytes);
    try std.testing.expectError(error.UnsupportedFormatVersion, decode(&bytes));
    bytes = canonical;
    bytes[0x032] = 1;
    fixChecksum(&bytes);
    try std.testing.expectError(error.NonZeroReserved, decode(&bytes));
    bytes = canonical;
    bytes[reserved_offset] = 1;
    fixChecksum(&bytes);
    try std.testing.expectError(error.NonZeroReserved, decode(&bytes));
}

test "placement page is canonical and rejects a non-zero tail" {
    const plan = try decode(&(try testGoldenBytes()));
    const page = try encodePage(plan);
    try std.testing.expectEqualSlices(u8, &(try encode(plan)), page[0..encoded_size]);
    try std.testing.expect(codec.isZero(page[encoded_size..]));
    try std.testing.expectEqualSlices(u8, &page, &(try encodePage(try decodePage(&page))));

    var corrupted = page;
    corrupted[placement_page_size - 1] = 1;
    try std.testing.expectError(error.NonZeroPageTail, decodePage(&corrupted));
}

test "persisted placement fields reject malformed values even with a valid checksum" {
    inline for (.{
        .{ u32, 0x00c, 128, error.InvalidEncodedSize },
        .{ u16, 0x016, 2, error.InvalidReplicaCount },
        .{ u16, 0x014, 2, error.InvalidMemberCount },
        .{ u16, 0x014, 13, error.InvalidMemberCount },
        .{ u16, 0x00a, 1, error.InvalidFlags },
        .{ u32, 0x010, 2048, error.InvalidStripeSize },
        .{ u32, 0x010, 6000, error.InvalidStripeSize },
        .{ u64, 0x018, 0, error.InvalidLogicalStripeCount },
        .{ u64, 0x020, 0, error.InvalidPermutation },
        .{ u64, 0x020, 17, error.InvalidPermutation },
        .{ u64, 0x020, 34, error.InvalidPermutation },
        .{ u64, 0x028, 34, error.InvalidPermutation },
        .{ u16, 0x040, 1, error.NonCanonicalSlotOrder },
        .{ u16, 0x032, 1, error.NonZeroReserved },
        .{ u64, 0x038, 0, error.InvalidAssignedStripeCount },
        .{ u64, 0x038, 35, error.InvalidAssignedStripeCount },
        .{ u64, 0x038, 16, error.InvalidAssignedStripeSum },
        .{ u16, 0x090, 1, error.NonCanonicalUnusedEntry },
        .{ u16, 0x092, 1, error.NonZeroReserved },
        .{ u64, 0x098, 1, error.NonCanonicalUnusedEntry },
    }) |case| {
        var bytes = try testGoldenBytes();
        codec.putInt(case[0], &bytes, case[1], case[2]);
        fixChecksum(&bytes);
        try std.testing.expectError(case[3], decode(&bytes));
        var page: PlacementPage = @splat(0);
        page[0..encoded_size].* = bytes;
        try std.testing.expectError(case[3], decodePage(&page));
    }
}

test "stored stripe counts retain singleton and u64 limits without overflow" {
    for ([_]u64{ 1, (@as(u64, 1) << 32) | 17, std.math.maxInt(u64) }) |n| {
        var plan: PlacementPlan = .{
            .stripe_size = 4096,
            .logical_stripe_count = n,
            .multiplier = if (n == 1) 0 else 1,
            .addend = 0,
            .member_count = 3,
        };
        for (plan.entries[0..3], 0..) |*entry, index|
            entry.* = .{ .slot = @intCast(index + 1), .assigned_stripes = n };
        const bytes = try encode(plan);
        try std.testing.expectEqualDeep(plan, try decode(&bytes));
        plan.multiplier = n;
        try std.testing.expectError(error.InvalidPermutation, encode(plan));
        plan.multiplier = if (n == 1) 0 else 1;
        plan.addend = n;
        try std.testing.expectError(error.InvalidPermutation, encode(plan));
        plan.addend = 0;
        if (n > 1) {
            plan.entries[0].assigned_stripes -= 1;
            try std.testing.expectError(error.InvalidAssignedStripeSum, encode(plan));
        }
    }
}

test "stored heterogeneous placement retains exact assignments" {
    var plan: PlacementPlan = .{
        .stripe_size = 4096,
        .logical_stripe_count = 26,
        .multiplier = 25,
        .addend = 19,
        .member_count = 4,
    };
    for (plan.entries[0..4], [_]u64{ 20, 20, 19, 19 }, 0..) |*entry, assigned, index|
        entry.* = .{ .slot = @intCast(index * 2 + 2), .assigned_stripes = assigned };
    try std.testing.expectEqualDeep(plan, try decode(&(try encode(plan))));
}

test "stored maximum-width placement validates every entry" {
    var plan: PlacementPlan = .{
        .stripe_size = 4096,
        .logical_stripe_count = 4,
        .multiplier = 1,
        .addend = 0,
        .member_count = max_member_count,
    };
    for (&plan.entries, 0..) |*entry, index|
        entry.* = .{ .slot = @intCast(index + 1), .assigned_stripes = 1 };
    try std.testing.expectEqualDeep(plan, try decode(&(try encode(plan))));
    plan.entries[max_member_count - 1].slot = plan.entries[max_member_count - 2].slot;
    try std.testing.expectError(error.NonCanonicalSlotOrder, encode(plan));
}
