const std = @import("std");
const codec = @import("codec.zig");
const pool_policy = @import("pool_policy.zig");
const pool_blob_schedule = @import("pool_blob_schedule.zig");
const pool_topology = @import("pool_topology.zig");

pub const encoded_size: usize = 256;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);

const legacy_magic = [8]u8{ 'D', 'D', 'V', 'L', 'A', 'Y', '2', 0 };
const scheduled_magic = [8]u8{ 'D', 'D', 'V', 'L', 'A', 'Y', '3', 0 };
const legacy_format_version: u16 = 2;
const scheduled_format_version: u16 = 3;
const placement_format_version: u16 = 1;
const legacy_reserved_offset: usize = 0x030;
const scheduled_reserved_offset: usize = 0x060;

pub const Kind = enum(u16) {
    unprotected = 1,
    replicated = 2,
    erasure_coded = 3,
};

pub const ScheduledBlob = struct {
    member_count: u16,
    logical_capacity: u64,
    placement_digest: codec.Digest,
};

pub const Layout = struct {
    kind: Kind,
    layout_epoch: u64,
    topology_epoch: u64,
    chunk_size: u32,
    data_fragments: u16,
    parity_fragments: u16,
    durable_write_threshold: u16,
    read_threshold: u16,
    flags: u32 = 0,
    scheduled_blob: ?ScheduledBlob = null,

    pub fn init(
        protection_mode: pool_policy.Protection,
        layout_epoch: u64,
        topology_epoch: u64,
        chunk_size: u32,
    ) !Layout {
        try protection_mode.validate();
        const layout: Layout = switch (protection_mode) {
            .unprotected => .{
                .kind = .unprotected,
                .layout_epoch = layout_epoch,
                .topology_epoch = topology_epoch,
                .chunk_size = chunk_size,
                .data_fragments = 1,
                .parity_fragments = 0,
                .durable_write_threshold = 1,
                .read_threshold = 1,
            },
            .replicated => .{
                .kind = .replicated,
                .layout_epoch = layout_epoch,
                .topology_epoch = topology_epoch,
                .chunk_size = chunk_size,
                .data_fragments = pool_policy.replica_count,
                .parity_fragments = 0,
                .durable_write_threshold = pool_policy.replica_durable_write_count,
                .read_threshold = 1,
            },
            .erasure_coded => |profile| .{
                .kind = .erasure_coded,
                .layout_epoch = layout_epoch,
                .topology_epoch = topology_epoch,
                .chunk_size = chunk_size,
                .data_fragments = profile.data_shards,
                .parity_fragments = profile.parity_shards,
                .durable_write_threshold = try profile.width(),
                .read_threshold = profile.data_shards,
            },
        };
        try validate(layout);
        return layout;
    }

    pub fn initScheduledBlob(
        plan: pool_blob_schedule.PlacementPlan,
        layout_epoch: u64,
        topology_epoch: u64,
    ) !Layout {
        try pool_blob_schedule.validate(plan);
        const logical_capacity = std.math.mul(u64, plan.logical_stripe_count, plan.stripe_size) catch
            return error.LogicalCapacityOverflow;
        const layout: Layout = .{
            .kind = .replicated,
            .layout_epoch = layout_epoch,
            .topology_epoch = topology_epoch,
            .chunk_size = plan.stripe_size,
            .data_fragments = pool_blob_schedule.replica_count,
            .parity_fragments = 0,
            .durable_write_threshold = pool_blob_schedule.replica_count,
            .read_threshold = pool_blob_schedule.replica_count - 1,
            .scheduled_blob = .{
                .member_count = plan.member_count,
                .logical_capacity = logical_capacity,
                .placement_digest = try pool_blob_schedule.digest(plan),
            },
        };
        try validate(layout);
        return layout;
    }

    pub fn protection(self: Layout) !pool_policy.Protection {
        try validate(self);
        return switch (self.kind) {
            .unprotected => .unprotected,
            .replicated => .replicated,
            .erasure_coded => .{ .erasure_coded = .{
                .data_shards = self.data_fragments,
                .parity_shards = self.parity_fragments,
            } },
        };
    }
};

pub fn encode(layout: Layout) ![encoded_size]u8 {
    try validate(layout);
    var bytes: [encoded_size]u8 = @splat(0);
    if (layout.scheduled_blob) |scheduled| {
        @memcpy(bytes[0x000..0x008], &scheduled_magic);
        codec.putInt(u16, &bytes, 0x008, scheduled_format_version);
        codec.putInt(u16, &bytes, 0x030, scheduled.member_count);
        codec.putInt(u16, &bytes, 0x032, placement_format_version);
        codec.putInt(u32, &bytes, 0x034, pool_blob_schedule.encoded_size);
        codec.putInt(u64, &bytes, 0x038, scheduled.logical_capacity);
        @memcpy(bytes[0x040..0x060], &scheduled.placement_digest);
    } else {
        @memcpy(bytes[0x000..0x008], &legacy_magic);
        codec.putInt(u16, &bytes, 0x008, legacy_format_version);
    }
    codec.putInt(u16, &bytes, 0x00a, @backingInt(layout.kind));
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    codec.putInt(u64, &bytes, 0x010, layout.layout_epoch);
    codec.putInt(u64, &bytes, 0x018, layout.topology_epoch);
    codec.putInt(u32, &bytes, 0x020, layout.chunk_size);
    codec.putInt(u16, &bytes, 0x024, layout.data_fragments);
    codec.putInt(u16, &bytes, 0x026, layout.parity_fragments);
    codec.putInt(u16, &bytes, 0x028, layout.durable_write_threshold);
    codec.putInt(u16, &bytes, 0x02a, layout.read_threshold);
    codec.putInt(u32, &bytes, 0x02c, layout.flags);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(bytes: *const [encoded_size]u8) !Layout {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    const is_scheduled = if (std.mem.eql(u8, bytes[0x000..0x008], &legacy_magic))
        false
    else if (std.mem.eql(u8, bytes[0x000..0x008], &scheduled_magic))
        true
    else
        return error.InvalidMagic;
    const expected_version: u16 = if (is_scheduled) scheduled_format_version else legacy_format_version;
    if (codec.getInt(u16, bytes, 0x008) != expected_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size) return error.InvalidEncodedSize;
    if (is_scheduled) {
        if (codec.getInt(u16, bytes, 0x032) != placement_format_version)
            return error.UnsupportedPlacementFormatVersion;
        if (codec.getInt(u32, bytes, 0x034) != pool_blob_schedule.encoded_size)
            return error.InvalidPlacementEncodedSize;
        if (!codec.isZero(bytes[scheduled_reserved_offset..checksum_offset])) return error.NonZeroReserved;
    } else if (!codec.isZero(bytes[legacy_reserved_offset..checksum_offset])) {
        return error.NonZeroReserved;
    }
    const kind = std.enums.fromInt(Kind, codec.getInt(u16, bytes, 0x00a)) orelse
        return error.UnsupportedLayoutKind;
    const layout: Layout = .{
        .kind = kind,
        .layout_epoch = codec.getInt(u64, bytes, 0x010),
        .topology_epoch = codec.getInt(u64, bytes, 0x018),
        .chunk_size = codec.getInt(u32, bytes, 0x020),
        .data_fragments = codec.getInt(u16, bytes, 0x024),
        .parity_fragments = codec.getInt(u16, bytes, 0x026),
        .durable_write_threshold = codec.getInt(u16, bytes, 0x028),
        .read_threshold = codec.getInt(u16, bytes, 0x02a),
        .flags = codec.getInt(u32, bytes, 0x02c),
        .scheduled_blob = if (is_scheduled) .{
            .member_count = codec.getInt(u16, bytes, 0x030),
            .logical_capacity = codec.getInt(u64, bytes, 0x038),
            .placement_digest = bytes[0x040..0x060].*,
        } else null,
    };
    try validate(layout);
    return layout;
}

pub fn digest(layout: Layout) !codec.Digest {
    const bytes = try encode(layout);
    return codec.blake3(bytes[0..checksum_offset]);
}

pub fn validate(layout: Layout) !void {
    if (layout.layout_epoch == 0) return error.InvalidLayoutEpoch;
    if (layout.topology_epoch == 0) return error.InvalidTopologyEpoch;
    if (layout.chunk_size == 0 or !std.math.isPowerOfTwo(layout.chunk_size))
        return error.InvalidChunkSize;
    if (layout.flags != 0) return error.InvalidLayoutFlags;
    if (layout.scheduled_blob) |scheduled| {
        if (layout.kind != .replicated or
            layout.data_fragments != pool_blob_schedule.replica_count or
            layout.parity_fragments != 0 or
            layout.durable_write_threshold != pool_blob_schedule.replica_count or
            layout.read_threshold != pool_blob_schedule.replica_count - 1)
            return error.InvalidScheduledBlobProfile;
        if (scheduled.member_count < pool_blob_schedule.replica_count or
            scheduled.member_count > pool_blob_schedule.max_member_count)
            return error.InvalidScheduledBlobMemberCount;
        if (layout.chunk_size < 4096 or scheduled.logical_capacity < layout.chunk_size or
            scheduled.logical_capacity % layout.chunk_size != 0)
            return error.InvalidScheduledBlobCapacity;
        if (codec.isZero(&scheduled.placement_digest)) return error.InvalidPlacementDigest;
        return;
    }
    switch (layout.kind) {
        .unprotected => {
            if (layout.data_fragments != 1 or layout.parity_fragments != 0 or
                layout.durable_write_threshold != 1 or layout.read_threshold != 1)
                return error.InvalidUnprotectedProfile;
        },
        .replicated => {
            if (layout.data_fragments != pool_policy.replica_count or layout.parity_fragments != 0 or
                layout.durable_write_threshold != pool_policy.replica_durable_write_count or
                layout.read_threshold != 1) return error.InvalidReplicaProfile;
        },
        .erasure_coded => {
            const profile: pool_policy.ErasureCode = .{
                .data_shards = layout.data_fragments,
                .parity_shards = layout.parity_fragments,
            };
            if (layout.durable_write_threshold != try profile.width() or
                layout.read_threshold != profile.data_shards) return error.InvalidErasureCodeProfile;
        },
    }
}

pub fn dataAccess(layout: Layout, topology: pool_topology.Topology) !pool_policy.DataAccess {
    try validate(layout);
    try pool_topology.validate(topology);
    if (layout.topology_epoch > topology.epoch) return error.FutureTopologyEpoch;
    return dataAccessForMemberCount(layout, activeDataMemberCount(topology));
}

pub fn dataAccessForMemberCount(layout: Layout, available_count: usize) !pool_policy.DataAccess {
    try validate(layout);
    if (layout.scheduled_blob) |scheduled| {
        if (available_count == scheduled.member_count) return .read_write;
        if (available_count == scheduled.member_count - 1) return .read_only;
        return .unavailable;
    }
    return pool_policy.dataAccess(try layout.protection(), available_count);
}

fn activeDataMemberCount(topology: pool_topology.Topology) usize {
    var count: usize = 0;
    for (topology.memberSlice()) |member| {
        if (member.state != .joining) count += 1;
    }
    return count;
}

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn testTopology(member_count: usize) !pool_topology.Topology {
    var members: [pool_blob_schedule.max_member_count]pool_topology.Member = undefined;
    for (members[0..member_count], 0..) |*member, index| {
        member.* = .{ .member_id = id(@intCast(index + 2)), .slot = @intCast(index * 3 + 1) };
        if (index < @min(member_count, 3)) {
            member.control_role = pool_topology.voter_role;
            member.role_flags = 3;
        }
    }
    return pool_topology.Topology.init(id(1), 1, @splat(0), members[0..member_count]);
}

fn fixChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

test "all protection profiles round trip canonically" {
    const protections = [_]pool_policy.Protection{
        .unprotected,
        .replicated,
        .{ .erasure_coded = .{ .data_shards = 4, .parity_shards = 2 } },
    };
    for (protections) |protection| {
        const layout = try Layout.init(protection, 3, 2, 1024 * 1024);
        const bytes = try encode(layout);
        try std.testing.expectEqualSlices(u8, &bytes, &(try encode(try decode(&bytes))));
        try std.testing.expectEqual(protection, try layout.protection());
    }
}

test "protection parameters are exact and fixed" {
    var layout = try Layout.init(.replicated, 1, 1, 1024 * 1024);
    layout.data_fragments = 2;
    try std.testing.expectError(error.InvalidReplicaProfile, encode(layout));

    layout = try Layout.init(.{ .erasure_coded = .{ .data_shards = 4, .parity_shards = 2 } }, 1, 1, 1024 * 1024);
    layout.durable_write_threshold = 5;
    try std.testing.expectError(error.InvalidErasureCodeProfile, encode(layout));
    layout.durable_write_threshold = 6;
    layout.read_threshold = 3;
    try std.testing.expectError(error.InvalidErasureCodeProfile, encode(layout));
}

test "member removal below full width makes protected layouts read only" {
    const replicated = try Layout.init(.replicated, 1, 1, 1024 * 1024);
    try std.testing.expectEqual(.read_write, try dataAccess(replicated, try testTopology(3)));
    try std.testing.expectEqual(.read_only, try dataAccess(replicated, try testTopology(2)));
    try std.testing.expectEqual(.read_only, try dataAccess(replicated, try testTopology(1)));

    const ec = try Layout.init(.{ .erasure_coded = .{ .data_shards = 4, .parity_shards = 2 } }, 1, 1, 1024 * 1024);
    try std.testing.expectEqual(.read_write, try dataAccess(ec, try testTopology(6)));
    try std.testing.expectEqual(.read_only, try dataAccess(ec, try testTopology(5)));
    try std.testing.expectEqual(.unavailable, try dataAccess(ec, try testTopology(3)));
}

test "unknown kind reserved bytes and checksum corruption are rejected" {
    const layout = try Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const canonical = try encode(layout);
    var bytes = canonical;
    codec.putInt(u16, &bytes, 0x00a, 99);
    fixChecksum(&bytes);
    try std.testing.expectError(error.UnsupportedLayoutKind, decode(&bytes));

    bytes = canonical;
    bytes[legacy_reserved_offset] = 1;
    fixChecksum(&bytes);
    try std.testing.expectError(error.NonZeroReserved, decode(&bytes));

    bytes = canonical;
    bytes[100] = 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&bytes));
}

fn testPlan(member_count: usize, stripes: u64) !pool_blob_schedule.PlacementPlan {
    var geometries: [pool_blob_schedule.max_member_count]pool_blob_schedule.Geometry = undefined;
    for (geometries[0..member_count], 0..) |*geometry, index|
        geometry.* = .{ .slot = @intCast(index * 3 + 1), .available_stripes = stripes };
    return pool_blob_schedule.build(1024 * 1024, geometries[0..member_count], 41);
}

test "scheduled blob layout round trips and binds placement fields" {
    const plan = try testPlan(6, 17);
    const layout = try Layout.initScheduledBlob(plan, 3, 2);
    const bytes = try encode(layout);
    try std.testing.expectEqualSlices(u8, &scheduled_magic, bytes[0x000..0x008]);
    try std.testing.expectEqual(@as(u16, 3), codec.getInt(u16, &bytes, 0x008));
    try std.testing.expectEqual(plan.member_count, codec.getInt(u16, &bytes, 0x030));
    try std.testing.expectEqual(@as(u16, 1), codec.getInt(u16, &bytes, 0x032));
    try std.testing.expectEqual(@as(u32, 256), codec.getInt(u32, &bytes, 0x034));
    try std.testing.expectEqualSlices(u8, &(try pool_blob_schedule.digest(plan)), &layout.scheduled_blob.?.placement_digest);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encode(try decode(&bytes))));
    try std.testing.expectEqual(codec.blake3(bytes[0..checksum_offset]), try digest(layout));
    try std.testing.expectEqual(pool_policy.Protection.replicated, try layout.protection());

    var corrupted = bytes;
    corrupted[0x040] ^= 1;
    fixChecksum(&corrupted);
    const changed = try decode(&corrupted);
    try std.testing.expect(!std.mem.eql(u8, &(try digest(layout)), &(try digest(changed))));

    corrupted = bytes;
    codec.putInt(u16, &corrupted, 0x032, 2);
    fixChecksum(&corrupted);
    try std.testing.expectError(error.UnsupportedPlacementFormatVersion, decode(&corrupted));
    corrupted = bytes;
    codec.putInt(u32, &corrupted, 0x034, 128);
    fixChecksum(&corrupted);
    try std.testing.expectError(error.InvalidPlacementEncodedSize, decode(&corrupted));
    corrupted = bytes;
    corrupted[scheduled_reserved_offset] = 1;
    fixChecksum(&corrupted);
    try std.testing.expectError(error.NonZeroReserved, decode(&corrupted));
    corrupted = bytes;
    corrupted[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&corrupted));
}

test "scheduled blob supports capacities above 16 TiB and exact access thresholds" {
    const stripes = (@as(u64, 16) * 1024 * 1024 * 1024 * 1024) / (1024 * 1024) + 1;
    const layout = try Layout.initScheduledBlob(try testPlan(6, stripes), 1, 1);
    try std.testing.expect(layout.scheduled_blob.?.logical_capacity > @as(u64, 16) * 1024 * 1024 * 1024 * 1024);
    try std.testing.expectEqual(@as(u16, 3), layout.durable_write_threshold);
    try std.testing.expectEqual(@as(u16, 2), layout.read_threshold);
    try std.testing.expectEqual(.read_write, try dataAccess(layout, try testTopology(6)));
    try std.testing.expectEqual(.read_only, try dataAccess(layout, try testTopology(5)));
    try std.testing.expectEqual(.unavailable, try dataAccess(layout, try testTopology(4)));
}

test "scheduled blob member availability requires all but at most one" {
    const layout = try Layout.initScheduledBlob(try testPlan(12, 17), 1, 1);
    try std.testing.expectEqual(.read_write, try dataAccessForMemberCount(layout, 12));
    try std.testing.expectEqual(.read_only, try dataAccessForMemberCount(layout, 11));
    try std.testing.expectEqual(.unavailable, try dataAccessForMemberCount(layout, 10));
}

test "layout magic and version pairs cannot be crossed" {
    const legacy = try encode(try Layout.init(.replicated, 1, 1, 1024 * 1024));
    var bytes = legacy;
    @memcpy(bytes[0x000..0x008], &scheduled_magic);
    fixChecksum(&bytes);
    try std.testing.expectError(error.UnsupportedFormatVersion, decode(&bytes));

    bytes = try encode(try Layout.initScheduledBlob(try testPlan(3, 4), 1, 1));
    @memcpy(bytes[0x000..0x008], &legacy_magic);
    fixChecksum(&bytes);
    try std.testing.expectError(error.UnsupportedFormatVersion, decode(&bytes));
}
