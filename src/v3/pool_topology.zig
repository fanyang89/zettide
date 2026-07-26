const std = @import("std");
const codec = @import("codec.zig");
const member_format = @import("member_format.zig");
const pool_policy = @import("pool_policy.zig");

pub const encoded_size: usize = 3200;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);
pub const max_member_count: usize = 96;
pub const non_voter_role: u8 = 0;
pub const voter_role: u8 = 1;

const magic = [8]u8{ 'D', 'D', 'V', 'T', 'O', 'P', '2', 0 };
const format_version: u16 = 2;
const header_size: u16 = 80;
const descriptors_offset: usize = header_size;
const descriptor_size: usize = 32;
const descriptors_end: usize = descriptors_offset + max_member_count * descriptor_size;

comptime {
    std.debug.assert(descriptors_end <= checksum_offset);
}

pub const MemberState = enum(u8) {
    joining = 1,
    active = 2,
    draining = 3,
};

pub const Member = struct {
    member_id: [16]u8,
    slot: u16,
    control_role: u8 = non_voter_role,
    state: MemberState = .active,
    role_flags: u32 = member_format.data_role,
};

pub const Topology = struct {
    set_id: [16]u8,
    epoch: u64,
    parent_digest: codec.Digest,
    quorum: u16,
    member_count: u16,
    members: [max_member_count]Member,
    flags: u32 = 0,

    pub fn init(
        set_id: [16]u8,
        epoch: u64,
        parent_digest: codec.Digest,
        members: []const Member,
    ) !Topology {
        if (members.len == 0 or members.len > max_member_count) return error.InvalidMemberCount;
        const policy = try pool_policy.controlPolicy(activeMemberCount(members));
        var topology: Topology = .{
            .set_id = set_id,
            .epoch = epoch,
            .parent_digest = parent_digest,
            .quorum = policy.write_quorum,
            .member_count = @intCast(members.len),
            .members = @splat(zeroMember()),
        };
        @memcpy(topology.members[0..members.len], members);
        try validate(topology);
        return topology;
    }

    pub fn memberSlice(self: *const Topology) []const Member {
        return self.members[0..self.member_count];
    }
};

pub fn encode(topology: Topology) ![encoded_size]u8 {
    try validate(topology);
    var members: [max_member_count]Member = @splat(zeroMember());
    @memcpy(members[0..topology.member_count], topology.memberSlice());
    sortMembers(members[0..topology.member_count]);

    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, header_size);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    @memcpy(bytes[0x010..0x020], &topology.set_id);
    codec.putInt(u64, &bytes, 0x020, topology.epoch);
    @memcpy(bytes[0x028..0x048], &topology.parent_digest);
    codec.putInt(u16, &bytes, 0x048, topology.quorum);
    codec.putInt(u16, &bytes, 0x04a, topology.member_count);
    codec.putInt(u32, &bytes, 0x04c, topology.flags);
    for (members[0..topology.member_count], 0..) |member, index|
        putMember(&bytes, descriptors_offset + index * descriptor_size, member);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(bytes: *const [encoded_size]u8) !Topology {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != format_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u16, bytes, 0x00a) != header_size or
        codec.getInt(u32, bytes, 0x00c) != encoded_size) return error.InvalidHeaderSize;

    const count = codec.getInt(u16, bytes, 0x04a);
    if (count == 0 or count > max_member_count) return error.InvalidMemberCount;
    const used_end = descriptors_offset + @as(usize, count) * descriptor_size;
    if (!codec.isZero(bytes[used_end..checksum_offset])) return error.NonZeroReserved;

    var members: [max_member_count]Member = @splat(zeroMember());
    for (members[0..count], 0..) |*member, index| {
        const offset = descriptors_offset + index * descriptor_size;
        if (!codec.isZero(bytes[offset + 24 .. offset + descriptor_size]))
            return error.NonZeroDescriptorReserved;
        member.* = try getMember(bytes, offset);
        if (index != 0 and member.slot <= members[index - 1].slot)
            return error.NonCanonicalMemberOrder;
    }

    const topology: Topology = .{
        .set_id = bytes[0x010..0x020].*,
        .epoch = codec.getInt(u64, bytes, 0x020),
        .parent_digest = bytes[0x028..0x048].*,
        .quorum = codec.getInt(u16, bytes, 0x048),
        .member_count = count,
        .members = members,
        .flags = codec.getInt(u32, bytes, 0x04c),
    };
    try validate(topology);
    return topology;
}

pub fn digest(topology: Topology) !codec.Digest {
    const bytes = try encode(topology);
    return codec.blake3(bytes[0..checksum_offset]);
}

pub fn validate(topology: Topology) !void {
    if (codec.isZero(&topology.set_id)) return error.InvalidSetId;
    if (topology.epoch == 0) return error.InvalidEpoch;
    if ((topology.epoch == 1) != codec.isZero(&topology.parent_digest))
        return error.InvalidParentDigest;
    if (topology.member_count == 0 or topology.member_count > max_member_count)
        return error.InvalidMemberCount;
    if (topology.flags != 0) return error.InvalidTopologyFlags;
    for (topology.members[topology.member_count..]) |member| {
        if (!isZeroMember(member)) return error.NonZeroOwnedMemberPadding;
    }

    const members = topology.memberSlice();
    const active_count = activeMemberCount(members);
    const policy = pool_policy.controlPolicy(active_count) catch return error.InvalidActiveMemberCount;
    if (topology.quorum != policy.write_quorum) return error.InvalidQuorum;

    var voter_count: usize = 0;
    for (members, 0..) |member, index| {
        if (codec.isZero(&member.member_id) or std.mem.eql(u8, &member.member_id, &topology.set_id))
            return error.InvalidMemberId;
        for (members[0..index]) |previous| {
            if (std.mem.eql(u8, &member.member_id, &previous.member_id)) return error.DuplicateMemberId;
            if (member.slot == previous.slot) return error.DuplicateMemberSlot;
        }
        if (member.control_role != non_voter_role and member.control_role != voter_role)
            return error.InvalidControlRole;
        if (member.control_role == voter_role) {
            if (member.state == .joining) return error.JoiningMemberIsVoter;
            if (member.role_flags & member_format.metadata_role == 0)
                return error.VoterHasNoMetadataRole;
            voter_count += 1;
        }
        if (member.role_flags & ~member_format.known_role_flags != 0 or
            member.role_flags & member_format.data_role == 0) return error.InvalidRoleFlags;
    }
    if (voter_count != policy.voter_count) return error.InvalidVoterCount;
}

pub fn findMember(topology: *const Topology, member_id: [16]u8) ?*const Member {
    for (topology.memberSlice()) |*member| {
        if (std.mem.eql(u8, &member.member_id, &member_id)) return member;
    }
    return null;
}

pub fn findSlot(topology: *const Topology, slot: u16) ?*const Member {
    for (topology.memberSlice()) |*member| {
        if (member.slot == slot) return member;
    }
    return null;
}

fn activeMemberCount(members: []const Member) usize {
    var count: usize = 0;
    for (members) |member| if (member.state != .joining) {
        count += 1;
    };
    return count;
}

fn sortMembers(members: []Member) void {
    for (0..members.len) |target| {
        for (target + 1..members.len) |candidate| {
            if (members[candidate].slot < members[target].slot)
                std.mem.swap(Member, &members[target], &members[candidate]);
        }
    }
}

fn putMember(bytes: []u8, offset: usize, member: Member) void {
    @memcpy(bytes[offset..][0..16], &member.member_id);
    codec.putInt(u16, bytes, offset + 16, member.slot);
    bytes[offset + 18] = member.control_role;
    bytes[offset + 19] = @intFromEnum(member.state);
    codec.putInt(u32, bytes, offset + 20, member.role_flags);
}

fn getMember(bytes: []const u8, offset: usize) !Member {
    return .{
        .member_id = bytes[offset..][0..16].*,
        .slot = codec.getInt(u16, bytes, offset + 16),
        .control_role = bytes[offset + 18],
        .state = std.enums.fromInt(MemberState, bytes[offset + 19]) orelse
            return error.InvalidMemberState,
        .role_flags = codec.getInt(u32, bytes, offset + 20),
    };
}

fn zeroMember() Member {
    return .{
        .member_id = @splat(0),
        .slot = 0,
        .control_role = 0,
        .state = .joining,
        .role_flags = 0,
    };
}

fn isZeroMember(member: Member) bool {
    return codec.isZero(&member.member_id) and member.slot == 0 and
        member.control_role == 0 and member.state == .joining and member.role_flags == 0;
}

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn testTopology() !Topology {
    const members = [_]Member{
        .{ .member_id = id(5), .slot = 41, .state = .active },
        .{ .member_id = id(2), .slot = 3, .control_role = voter_role, .state = .draining, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(4), .slot = 20, .control_role = voter_role, .state = .active, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(3), .slot = 9, .control_role = voter_role, .state = .active, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(6), .slot = 77, .state = .joining },
    };
    return Topology.init(id(1), 7, id(9) ++ id(9), &members);
}

fn fixChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

test "dynamic topology round trips sparse slots in canonical order" {
    const topology = try testTopology();
    const bytes = try encode(topology);
    try std.testing.expectEqualSlices(u8, &magic, bytes[0..8]);
    try std.testing.expectEqual(@as(u16, 5), codec.getInt(u16, &bytes, 0x04a));
    try std.testing.expectEqual(@as(u16, 2), codec.getInt(u16, &bytes, 0x048));
    const expected_slots = [_]u16{ 3, 9, 20, 41, 77 };
    for (expected_slots, 0..) |slot, index|
        try std.testing.expectEqual(slot, codec.getInt(u16, &bytes, descriptors_offset + index * descriptor_size + 16));
    const decoded = try decode(&bytes);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encode(decoded)));
    try std.testing.expect(findSlot(&decoded, 41) != null);
    try std.testing.expect(findMember(&decoded, id(6)) != null);
}

test "one two and three-plus active members enforce control policy" {
    const one = [_]Member{.{ .member_id = id(2), .slot = 8, .control_role = voter_role, .role_flags = member_format.known_role_flags }};
    const topology_one = try Topology.init(id(1), 1, @splat(0), &one);
    try std.testing.expectEqual(@as(u16, 1), topology_one.quorum);

    const two = [_]Member{
        .{ .member_id = id(2), .slot = 8, .control_role = voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(3), .slot = 12, .control_role = voter_role, .role_flags = member_format.known_role_flags },
    };
    const topology_two = try Topology.init(id(1), 1, @splat(0), &two);
    try std.testing.expectEqual(@as(u16, 2), topology_two.quorum);

    const three = [_]Member{
        .{ .member_id = id(2), .slot = 8, .control_role = voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(3), .slot = 12, .control_role = voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(4), .slot = 19, .control_role = voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(5), .slot = 31 },
    };
    const topology_three = try Topology.init(id(1), 1, @splat(0), &three);
    try std.testing.expectEqual(@as(u16, 2), topology_three.quorum);
}

test "joining members do not change stable voter policy" {
    const members = [_]Member{
        .{ .member_id = id(2), .slot = 8, .control_role = voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(3), .slot = 12, .state = .joining },
    };
    _ = try Topology.init(id(1), 1, @splat(0), &members);

    var invalid = members;
    invalid[1].control_role = voter_role;
    invalid[1].role_flags = member_format.known_role_flags;
    try std.testing.expectError(error.JoiningMemberIsVoter, Topology.init(id(1), 1, @splat(0), &invalid));
}

test "duplicate identity slot and invalid voter sets are rejected" {
    var topology = try testTopology();
    topology.members[1].member_id = topology.members[0].member_id;
    try std.testing.expectError(error.DuplicateMemberId, encode(topology));

    topology = try testTopology();
    topology.members[1].slot = topology.members[0].slot;
    try std.testing.expectError(error.DuplicateMemberSlot, encode(topology));

    topology = try testTopology();
    topology.members[1].control_role = non_voter_role;
    try std.testing.expectError(error.InvalidVoterCount, encode(topology));
}

test "decoder rejects noncanonical descriptors state padding and checksum" {
    const canonical = try encode(try testTopology());
    var bytes = canonical;
    const first = bytes[descriptors_offset..][0..descriptor_size].*;
    const second = bytes[descriptors_offset + descriptor_size ..][0..descriptor_size].*;
    @memcpy(bytes[descriptors_offset..][0..descriptor_size], &second);
    @memcpy(bytes[descriptors_offset + descriptor_size ..][0..descriptor_size], &first);
    fixChecksum(&bytes);
    try std.testing.expectError(error.NonCanonicalMemberOrder, decode(&bytes));

    bytes = canonical;
    bytes[descriptors_offset + 19] = 99;
    fixChecksum(&bytes);
    try std.testing.expectError(error.InvalidMemberState, decode(&bytes));

    bytes = canonical;
    bytes[descriptors_end] = 1;
    fixChecksum(&bytes);
    try std.testing.expectError(error.NonZeroReserved, decode(&bytes));

    bytes = canonical;
    bytes[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&bytes));
}
