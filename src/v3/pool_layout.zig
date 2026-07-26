const std = @import("std");
const codec = @import("codec.zig");
const pool_policy = @import("pool_policy.zig");
const pool_topology = @import("pool_topology.zig");

pub const encoded_size: usize = 256;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);

const magic = [8]u8{ 'D', 'D', 'V', 'L', 'A', 'Y', '2', 0 };
const format_version: u16 = 2;
const reserved_offset: usize = 0x030;

pub const Kind = enum(u16) {
    unprotected = 1,
    replicated = 2,
    erasure_coded = 3,
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
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, @intFromEnum(layout.kind));
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
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != format_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size) return error.InvalidEncodedSize;
    if (!codec.isZero(bytes[reserved_offset..checksum_offset])) return error.NonZeroReserved;
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
    return pool_policy.dataAccess(try layout.protection(), activeDataMemberCount(topology));
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
    var members: [6]pool_topology.Member = undefined;
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
    bytes[reserved_offset] = 1;
    fixChecksum(&bytes);
    try std.testing.expectError(error.NonZeroReserved, decode(&bytes));

    bytes = canonical;
    bytes[100] = 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&bytes));
}
