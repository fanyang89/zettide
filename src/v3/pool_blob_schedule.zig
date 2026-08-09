const std = @import("std");
const codec = @import("codec.zig");

pub const max_member_count: usize = 12;
pub const replica_count: usize = 3;
pub const encoded_size: usize = 256;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);

const magic = [8]u8{ 'D', 'D', 'B', 'S', 'C', 'H', '1', 0 };
const format_version: u16 = 1;
const entries_offset: usize = 0x030;
const entry_size: usize = 16;
const reserved_offset: usize = entries_offset + max_member_count * entry_size;

pub const Geometry = struct {
    slot: u16,
    available_stripes: u64,
};

pub const Entry = struct {
    slot: u16 = 0,
    assigned_stripes: u64 = 0,
};

pub const Location = struct {
    slot: u16,
    physical_stripe: u64,
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

pub fn build(stripe_size: u32, geometries: []const Geometry, seed: u64) !PlacementPlan {
    if (geometries.len < replica_count or geometries.len > max_member_count)
        return error.InvalidMemberCount;

    var sorted: [max_member_count]Geometry = undefined;
    @memcpy(sorted[0..geometries.len], geometries);
    std.mem.sort(Geometry, sorted[0..geometries.len], {}, struct {
        fn lessThan(_: void, a: Geometry, b: Geometry) bool {
            return a.slot < b.slot;
        }
    }.lessThan);
    for (sorted[0..geometries.len], 0..) |geometry, index| {
        if (geometry.available_stripes == 0) return error.ZeroCapacity;
        if (index != 0 and sorted[index - 1].slot == geometry.slot) return error.DuplicateSlot;
    }

    const logical_stripe_count = maximumLogicalStripes(sorted[0..geometries.len]);
    if (logical_stripe_count == 0) return error.InsufficientCapacity;

    const target = @as(u128, replica_count) * logical_stripe_count;
    var low: u64 = 0;
    var high: u64 = logical_stripe_count;
    while (low < high) {
        const level: u64 = @intCast((@as(u128, low) + high + 1) / 2);
        if (cappedSum(sorted[0..geometries.len], level) <= target)
            low = level
        else
            high = level - 1;
    }

    var assignments: [max_member_count]u64 = @splat(0);
    var assigned_sum: u128 = 0;
    for (sorted[0..geometries.len], 0..) |geometry, index| {
        const assigned = @min(geometry.available_stripes, low);
        assignments[index] = assigned;
        assigned_sum += assigned;
    }
    var remainder: usize = @intCast(target - assigned_sum);
    for (sorted[0..geometries.len], 0..) |geometry, index| {
        if (remainder == 0) break;
        if (assignments[index] < @min(geometry.available_stripes, logical_stripe_count)) {
            assignments[index] += 1;
            remainder -= 1;
        }
    }
    std.debug.assert(remainder == 0);

    var plan: PlacementPlan = .{
        .stripe_size = stripe_size,
        .logical_stripe_count = logical_stripe_count,
        .multiplier = undefined,
        .addend = if (logical_stripe_count == 1) 0 else seed % logical_stripe_count,
        .member_count = 0,
    };
    for (sorted[0..geometries.len], assignments[0..geometries.len]) |geometry, assigned| {
        if (assigned == 0) continue;
        plan.entries[plan.member_count] = .{ .slot = geometry.slot, .assigned_stripes = assigned };
        plan.member_count += 1;
    }
    plan.multiplier = chooseMultiplier(logical_stripe_count, plan.member_count);
    try validate(plan);
    return plan;
}

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

pub fn map(plan: PlacementPlan, logical_stripe: u64) ![replica_count]Location {
    try validate(plan);
    if (logical_stripe >= plan.logical_stripe_count) return error.LogicalStripeOutOfRange;
    const n = plan.logical_stripe_count;
    const permuted: u64 = if (n == 1) 0 else @intCast(
        (@as(u128, plan.multiplier) * logical_stripe + plan.addend) % n,
    );
    var result: [replica_count]Location = undefined;
    for (0..replica_count) |lane| {
        const position = @as(u128, lane) * n + permuted;
        var band_start: u128 = 0;
        for (plan.memberSlice()) |entry| {
            const band_end = band_start + entry.assigned_stripes;
            if (position < band_end) {
                result[lane] = .{
                    .slot = entry.slot,
                    .physical_stripe = @intCast(position - band_start),
                };
                break;
            }
            band_start = band_end;
        } else unreachable;
    }
    std.debug.assert(result[0].slot != result[1].slot and result[0].slot != result[2].slot and
        result[1].slot != result[2].slot);
    return result;
}

fn maximumLogicalStripes(geometries: []const Geometry) u64 {
    var total: u128 = 0;
    for (geometries) |geometry| total += geometry.available_stripes;
    var low: u64 = 0;
    var high: u64 = @intCast(@min(total / replica_count, std.math.maxInt(u64)));
    while (low < high) {
        const candidate: u64 = @intCast((@as(u128, low) + high + 1) / 2);
        if (cappedSum(geometries, candidate) >= @as(u128, replica_count) * candidate)
            low = candidate
        else
            high = candidate - 1;
    }
    return low;
}

fn cappedSum(geometries: []const Geometry, limit: u64) u128 {
    var sum: u128 = 0;
    for (geometries) |geometry| sum += @min(geometry.available_stripes, limit);
    return sum;
}

fn chooseMultiplier(n: u64, member_count: usize) u64 {
    if (n == 1) return 0;
    const groups: u64 = @intCast((member_count + replica_count - 1) / replica_count);
    const target = @max(@as(u64, 1), n / groups);
    var distance: u64 = 0;
    while (true) : (distance += 1) {
        if (distance <= target - 1) {
            const lower = target - distance;
            if (gcd(lower, n) == 1) return lower;
        }
        if (distance != 0 and distance <= n - 1 - target) {
            const upper = target + distance;
            if (gcd(upper, n) == 1) return upper;
        }
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

fn uniformGeometries(count: usize, capacity: u64) [max_member_count]Geometry {
    var geometries: [max_member_count]Geometry = undefined;
    for (0..count) |index| geometries[index] = .{ .slot = @intCast(index + 1), .available_stripes = capacity };
    return geometries;
}

test "placement plan codec is canonical and rejects envelope corruption" {
    const geometries = uniformGeometries(6, 17);
    const plan = try build(1024 * 1024, geometries[0..6], 41);
    const canonical = try encode(plan);
    try std.testing.expectEqualSlices(u8, &canonical, &(try encode(try decode(&canonical))));
    try std.testing.expectEqual(codec.blake3(canonical[0..checksum_offset]), try digest(plan));

    var bytes = canonical;
    bytes[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&bytes));
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

test "capacity assignment handles equal and heterogeneous members" {
    var geometries = uniformGeometries(12, 100);
    var plan = try build(4096, &geometries, 0);
    try std.testing.expectEqual(@as(u64, 400), plan.logical_stripe_count);
    for (plan.memberSlice()) |entry| try std.testing.expectEqual(@as(u64, 100), entry.assigned_stripes);

    for (0..12) |index| geometries[index].available_stripes = if (index < 6) 4 else 2;
    plan = try build(4096, &geometries, 0);
    try std.testing.expectEqual(@as(u64, 12), plan.logical_stripe_count);
    for (plan.memberSlice(), 0..) |entry, index|
        try std.testing.expectEqual(geometries[index].available_stripes, entry.assigned_stripes);

    for (0..12) |index| geometries[index].available_stripes = if (index < 2) 100 else 1;
    plan = try build(4096, &geometries, 0);
    try std.testing.expectEqual(@as(u64, 10), plan.logical_stripe_count);
    try std.testing.expectEqual(@as(u64, 10), plan.entries[0].assigned_stripes);
    try std.testing.expectEqual(@as(u64, 10), plan.entries[1].assigned_stripes);

    for (0..12) |index| geometries[index].available_stripes = if (index < 3) 100 else 1;
    plan = try build(4096, &geometries, 0);
    try std.testing.expectEqual(@as(u64, 103), plan.logical_stripe_count);
    for (plan.memberSlice()[3..]) |entry| try std.testing.expectEqual(@as(u64, 1), entry.assigned_stripes);
}

test "surplus assignment is balanced and input order independent" {
    const ordered = [_]Geometry{
        .{ .slot = 2, .available_stripes = 20 },
        .{ .slot = 4, .available_stripes = 20 },
        .{ .slot = 6, .available_stripes = 20 },
        .{ .slot = 8, .available_stripes = 20 },
    };
    const shuffled = [_]Geometry{ ordered[2], ordered[0], ordered[3], ordered[1] };
    const plan = try build(4096, &ordered, 19);
    try std.testing.expectEqual(@as(u64, 26), plan.logical_stripe_count);
    try std.testing.expectEqual(@as(u64, 20), plan.entries[0].assigned_stripes);
    try std.testing.expectEqual(@as(u64, 20), plan.entries[1].assigned_stripes);
    try std.testing.expectEqual(@as(u64, 19), plan.entries[2].assigned_stripes);
    try std.testing.expectEqual(@as(u64, 19), plan.entries[3].assigned_stripes);
    try std.testing.expectEqualSlices(u8, &(try encode(plan)), &(try encode(try build(4096, &shuffled, 19))));
}

test "small capacities produce the maximum feasible logical count" {
    var geometries: [5]Geometry = undefined;
    for (3..6) |member_count| {
        var combinations: usize = 1;
        for (0..member_count) |_| combinations *= 4;
        for (0..combinations) |value_initial| {
            var value = value_initial;
            for (0..member_count) |index| {
                geometries[index] = .{ .slot = @intCast(index + 1), .available_stripes = @intCast(value % 4 + 1) };
                value /= 4;
            }
            const plan = try build(4096, geometries[0..member_count], 0);
            var expected: u64 = 0;
            for (1..8) |candidate| {
                if (cappedSum(geometries[0..member_count], candidate) >= replica_count * candidate)
                    expected = candidate;
            }
            try std.testing.expectEqual(expected, plan.logical_stripe_count);
        }
    }
}

test "mapping exhaustively partitions assigned member stripes" {
    var geometries: [5]Geometry = undefined;
    for (3..6) |member_count| {
        var combinations: usize = 1;
        for (0..member_count) |_| combinations *= 3;
        for (0..combinations) |value_initial| {
            var value = value_initial;
            for (0..member_count) |index| {
                geometries[index] = .{ .slot = @intCast(index * 2 + 1), .available_stripes = @intCast(value % 3 + 1) };
                value /= 3;
            }
            const plan = try build(4096, geometries[0..member_count], 7);
            var seen: [max_member_count][16]bool = @splat(@splat(false));
            var counts: [max_member_count]u64 = @splat(0);
            for (0..plan.logical_stripe_count) |logical_stripe| {
                const locations = try map(plan, logical_stripe);
                try std.testing.expect(locations[0].slot != locations[1].slot);
                try std.testing.expect(locations[0].slot != locations[2].slot);
                try std.testing.expect(locations[1].slot != locations[2].slot);
                for (locations) |location| {
                    var member_index: usize = 0;
                    while (plan.entries[member_index].slot != location.slot) : (member_index += 1) {}
                    try std.testing.expect(location.physical_stripe < plan.entries[member_index].assigned_stripes);
                    try std.testing.expect(!seen[member_index][location.physical_stripe]);
                    seen[member_index][location.physical_stripe] = true;
                    counts[member_index] += 1;
                }
            }
            for (plan.memberSlice(), 0..) |entry, index|
                try std.testing.expectEqual(entry.assigned_stripes, counts[index]);
        }
    }
}

test "large logical counts round trip and map with u128 arithmetic" {
    const n = @as(u64, 1) << 32 | 17;
    const geometries = [_]Geometry{
        .{ .slot = 1, .available_stripes = n },
        .{ .slot = 2, .available_stripes = n },
        .{ .slot = 3, .available_stripes = n },
    };
    const plan = try decode(&(try encode(try build(4096, &geometries, std.math.maxInt(u64)))));
    try std.testing.expectEqual(n, plan.logical_stripe_count);
    const locations = try map(plan, n - 1);
    for (locations) |location| try std.testing.expect(location.physical_stripe < n);
    try std.testing.expectError(error.LogicalStripeOutOfRange, map(plan, n));
}

test "invalid geometry and persisted plans are rejected" {
    const too_few = uniformGeometries(2, 1);
    try std.testing.expectError(error.InvalidMemberCount, build(4096, too_few[0..2], 0));
    const duplicate = [_]Geometry{
        .{ .slot = 1, .available_stripes = 1 },
        .{ .slot = 1, .available_stripes = 1 },
        .{ .slot = 2, .available_stripes = 1 },
    };
    try std.testing.expectError(error.DuplicateSlot, build(4096, &duplicate, 0));
    var zero = uniformGeometries(3, 1);
    zero[1].available_stripes = 0;
    try std.testing.expectError(error.ZeroCapacity, build(4096, zero[0..3], 0));

    var plan = try build(4096, uniformGeometries(3, 4)[0..3], 0);
    plan.stripe_size = 2048;
    try std.testing.expectError(error.InvalidStripeSize, validate(plan));
    plan = try build(4096, uniformGeometries(3, 4)[0..3], 0);
    plan.entries[1].slot = plan.entries[0].slot;
    try std.testing.expectError(error.NonCanonicalSlotOrder, validate(plan));
    plan = try build(4096, uniformGeometries(3, 4)[0..3], 0);
    plan.entries[0].assigned_stripes -= 1;
    try std.testing.expectError(error.InvalidAssignedStripeSum, validate(plan));
    plan = try build(4096, uniformGeometries(3, 4)[0..3], 0);
    plan.multiplier = 0;
    try std.testing.expectError(error.InvalidPermutation, validate(plan));
    plan = try build(4096, uniformGeometries(3, 4)[0..3], 0);
    plan.addend = plan.logical_stripe_count;
    try std.testing.expectError(error.InvalidPermutation, validate(plan));
    plan = try build(4096, uniformGeometries(3, 4)[0..3], 0);
    plan.flags = 1;
    try std.testing.expectError(error.InvalidFlags, validate(plan));
    plan = try build(4096, uniformGeometries(3, 4)[0..3], 0);
    plan.entries[3].assigned_stripes = 1;
    try std.testing.expectError(error.NonCanonicalUnusedEntry, validate(plan));
    plan = try build(4096, uniformGeometries(3, 1)[0..3], 99);
    try std.testing.expectEqual(@as(u64, 0), plan.multiplier);
    try std.testing.expectEqual(@as(u64, 0), plan.addend);
}
