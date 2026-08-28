const std = @import("std");
const codec = @import("codec.zig");
const member_format = @import("member_format.zig");
const pool_policy = @import("pool_policy.zig");

pub const encoded_size: usize = 512;
pub const checksum_offset: usize = 0x1fc;
pub const member_count: usize = 3;
pub const control_write_quorum: u16 = 2;
pub const voter_role: u8 = 1;
pub const non_voter_role: u8 = 0;

pub const ControlPolicy = pool_policy.ControlPolicy;

pub fn controlPolicy(pool_member_count: usize) !ControlPolicy {
    return pool_policy.controlPolicy(pool_member_count);
}

const magic = [8]u8{ 'D', 'D', 'V', 'T', 'O', 'P', '1', 0 };
const format_version: u16 = 1;
const header_size: u16 = 80;
const descriptor_size: usize = 32;
const descriptors_offset: usize = 0x050;
const reserved_offset: usize = 0x0b0;

pub const Member = struct {
    member_id: [16]u8,
    slot: u16,
    control_role: u8 = voter_role,
    role_flags: u32 = member_format.known_role_flags,
};

pub const Topology = struct {
    set_id: [16]u8,
    epoch: u64,
    parent_digest: codec.Digest,
    quorum: u16 = control_write_quorum,
    members: [member_count]Member,
    flags: u32 = 0,
};

pub fn encode(topology: Topology) ![encoded_size]u8 {
    try validate(topology);
    const members = canonicalMembers(topology.members);
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, header_size);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    @memcpy(bytes[0x010..0x020], &topology.set_id);
    codec.putInt(u64, &bytes, 0x020, topology.epoch);
    @memcpy(bytes[0x028..0x048], &topology.parent_digest);
    codec.putInt(u16, &bytes, 0x048, topology.quorum);
    codec.putInt(u16, &bytes, 0x04a, member_count);
    codec.putInt(u32, &bytes, 0x04c, topology.flags);
    for (members, 0..) |member, index| putMember(&bytes, descriptors_offset + index * descriptor_size, member);
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
    if (codec.getInt(u16, bytes, 0x04a) != member_count) return error.InvalidMemberCount;
    if (!codec.isZero(bytes[reserved_offset..checksum_offset])) return error.NonZeroReserved;
    for (0..member_count) |index| {
        const offset = descriptors_offset + index * descriptor_size;
        if (bytes[offset + 19] != 0 or !codec.isZero(bytes[offset + 24 .. offset + descriptor_size]))
            return error.NonZeroDescriptorReserved;
    }

    var members: [member_count]Member = undefined;
    for (&members, 0..) |*member, index| {
        member.* = getMember(bytes, descriptors_offset + index * descriptor_size);
        if (member.slot != index) return error.NonCanonicalMemberOrder;
    }
    const topology: Topology = .{
        .set_id = bytes[0x010..0x020].*,
        .epoch = codec.getInt(u64, bytes, 0x020),
        .parent_digest = bytes[0x028..0x048].*,
        .quorum = codec.getInt(u16, bytes, 0x048),
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

pub fn validateMemberSet(
    topology: Topology,
    genesis_digest: codec.Digest,
    headers: []const member_format.Header,
) !void {
    if (headers.len < member_count) return error.MissingMember;
    if (headers.len > member_count) return error.InvalidHeaderCount;

    try validateMemberSubset(topology, genesis_digest, headers);
    var matched: [member_count]bool = @splat(false);
    for (headers) |header| {
        const index = findMember(topology.members, header.member_id) orelse unreachable;
        matched[index] = true;
    }
    for (matched) |present| if (!present) return error.MissingMember;
}

pub fn validateMemberSubset(
    topology: Topology,
    genesis_digest: codec.Digest,
    headers: []const member_format.Header,
) !void {
    try validate(topology);
    if (headers.len == 0) return error.MissingMember;
    if (headers.len > member_count) return error.InvalidHeaderCount;

    var matched: [member_count]bool = @splat(false);
    for (headers) |header| {
        try validateMemberHeader(topology, genesis_digest, header);
        const index = findMember(topology.members, header.member_id) orelse return error.ForeignMember;
        if (matched[index]) return error.DuplicateMember;
        matched[index] = true;
    }
    for (headers[1..]) |header| {
        if (!staticSetFieldsEqual(headers[0], header)) return error.StaticSetFieldsMismatch;
    }
}

pub fn validateMemberHeader(
    topology: Topology,
    genesis_digest: codec.Digest,
    header: member_format.Header,
) !void {
    try validate(topology);
    if (!std.mem.eql(u8, &header.set_id, &topology.set_id)) return error.ForeignSet;
    const index = findMember(topology.members, header.member_id) orelse return error.ForeignMember;
    const member = topology.members[index];
    if (header.member_slot != member.slot or header.member_count != member_count or
        header.role_flags != member.role_flags) return error.MemberHeaderMismatch;
    if (!std.mem.eql(u8, &header.genesis_topology_digest, &genesis_digest))
        return error.GenesisTopologyDigestMismatch;
}

fn validate(topology: Topology) !void {
    if (codec.isZero(&topology.set_id)) return error.InvalidSetId;
    if (topology.epoch == 0) return error.InvalidEpoch;
    if ((topology.epoch == 1) != codec.isZero(&topology.parent_digest)) return error.InvalidParentDigest;
    if (topology.quorum != control_write_quorum) return error.InvalidQuorum;
    if (topology.flags != 0) return error.InvalidTopologyFlags;

    var slots: [member_count]bool = @splat(false);
    for (topology.members, 0..) |member, index| {
        if (codec.isZero(&member.member_id) or std.mem.eql(u8, &member.member_id, &topology.set_id))
            return error.InvalidMemberId;
        for (topology.members[0..index]) |previous| {
            if (std.mem.eql(u8, &member.member_id, &previous.member_id)) return error.DuplicateMemberId;
        }
        if (member.slot >= member_count) return error.InvalidMemberSlot;
        if (slots[member.slot]) return error.DuplicateMemberSlot;
        slots[member.slot] = true;
        if (member.control_role != voter_role) return error.InvalidControlRole;
        if (member.role_flags != member_format.known_role_flags) return error.InvalidRoleFlags;
    }
    for (slots) |present| if (!present) return error.MissingMemberSlot;
}

fn canonicalMembers(input: [member_count]Member) [member_count]Member {
    var output = input;
    for (0..member_count) |target| {
        for (target + 1..member_count) |candidate| {
            if (output[candidate].slot < output[target].slot)
                std.mem.swap(Member, &output[target], &output[candidate]);
        }
    }
    return output;
}

fn putMember(bytes: []u8, offset: usize, member: Member) void {
    @memcpy(bytes[offset..][0..16], &member.member_id);
    codec.putInt(u16, bytes, offset + 16, member.slot);
    bytes[offset + 18] = member.control_role;
    codec.putInt(u32, bytes, offset + 20, member.role_flags);
}

fn getMember(bytes: []const u8, offset: usize) Member {
    return .{
        .member_id = bytes[offset..][0..16].*,
        .slot = codec.getInt(u16, bytes, offset + 16),
        .control_role = bytes[offset + 18],
        .role_flags = codec.getInt(u32, bytes, offset + 20),
    };
}

fn findMember(members: [member_count]Member, member_id: [16]u8) ?usize {
    for (members, 0..) |member, index| {
        if (std.mem.eql(u8, &member.member_id, &member_id)) return index;
    }
    return null;
}

fn staticSetFieldsEqual(a: member_format.Header, b: member_format.Header) bool {
    return a.compat_features == b.compat_features and
        a.ro_compat_features == b.ro_compat_features and
        a.incompat_features == b.incompat_features and
        a.created_ns == b.created_ns and
        a.logical_capacity == b.logical_capacity and
        std.meta.eql(a.control, b.control) and
        std.meta.eql(a.metadata, b.metadata) and
        std.meta.eql(a.data, b.data) and
        a.metadata_block_size == b.metadata_block_size and
        a.metadata_read_size == b.metadata_read_size and
        a.metadata_program_size == b.metadata_program_size and
        a.chunk_size == b.chunk_size and
        a.metadata_format_version == b.metadata_format_version and
        a.object_format_version == b.object_format_version and
        a.layout_format_version == b.layout_format_version and
        a.control_record_format_version == b.control_record_format_version and
        a.checksum_algorithm == b.checksum_algorithm and
        a.digest_algorithm == b.digest_algorithm and
        std.mem.eql(u8, a.label.slice(), b.label.slice());
}

fn testTopology() Topology {
    return .{
        .set_id = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff },
        .epoch = 1,
        .parent_digest = @splat(0),
        .members = .{
            .{ .member_id = .{ 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f }, .slot = 2 },
            .{ .member_id = .{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f }, .slot = 0 },
            .{ .member_id = .{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f }, .slot = 1 },
        },
    };
}

fn testHeader(topology: Topology, member: Member) !member_format.Header {
    return .{
        .header_sequence = 7,
        .set_id = topology.set_id,
        .member_id = member.member_id,
        .member_slot = member.slot,
        .created_ns = 1_700_000_000_123_456_789,
        .member_bytes = 0x41200000,
        .logical_capacity = 0x40000000,
        .control = .{ .offset = 0x10000, .length = 0x20000 },
        .metadata = .{ .offset = 0x100000, .length = 0x100000 },
        .data = .{ .offset = 0x200000, .length = 0x41000000 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = 1024 * 1024,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = 1,
        .control_record_format_version = 1,
        .label = try member_format.Label.init("topology-set"),
        .genesis_topology_digest = try digest(topology),
    };
}

fn testHeaders(topology: Topology) ![member_count]member_format.Header {
    return .{
        try testHeader(topology, topology.members[0]),
        try testHeader(topology, topology.members[1]),
        try testHeader(topology, topology.members[2]),
    };
}

fn fixChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

fn readFixture() ![encoded_size]u8 {
    const fixture_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fixtures/v3/topology.hex",
        std.testing.allocator,
        .limited(4096),
    );
    defer std.testing.allocator.free(fixture_text);
    var fixture: [encoded_size]u8 = @splat(0);
    var lines = std.mem.splitScalar(u8, fixture_text, '\n');
    while (lines.next()) |line| {
        const record = std.mem.trim(u8, line, " \t\r");
        if (record.len == 0 or record[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, record, " \t");
        const offset = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidFixture, 16);
        const hex = fields.next() orelse return error.InvalidFixture;
        if (fields.next() != null or hex.len % 2 != 0 or offset + hex.len / 2 > fixture.len)
            return error.InvalidFixture;
        _ = try std.fmt.hexToBytes(fixture[offset..], hex);
    }
    return fixture;
}

test "exact offsets canonical ordering and round trip" {
    const topology = testTopology();
    const bytes = try encode(topology);
    try std.testing.expectEqualSlices(u8, &magic, bytes[0x000..0x008]);
    try std.testing.expectEqual(format_version, codec.getInt(u16, &bytes, 0x008));
    try std.testing.expectEqual(header_size, codec.getInt(u16, &bytes, 0x00a));
    try std.testing.expectEqual(@as(u32, encoded_size), codec.getInt(u32, &bytes, 0x00c));
    try std.testing.expectEqualSlices(u8, &topology.set_id, bytes[0x010..0x020]);
    try std.testing.expectEqual(topology.epoch, codec.getInt(u64, &bytes, 0x020));
    try std.testing.expectEqualSlices(u8, &topology.parent_digest, bytes[0x028..0x048]);
    try std.testing.expectEqual(control_write_quorum, codec.getInt(u16, &bytes, 0x048));
    try std.testing.expectEqual(@as(u16, member_count), codec.getInt(u16, &bytes, 0x04a));
    try std.testing.expectEqual(@as(u32, 0), codec.getInt(u32, &bytes, 0x04c));
    for (0..member_count) |slot| {
        const offset = descriptors_offset + slot * descriptor_size;
        try std.testing.expectEqual(@as(u16, @intCast(slot)), codec.getInt(u16, &bytes, offset + 16));
        try std.testing.expectEqual(voter_role, bytes[offset + 18]);
        try std.testing.expectEqual(member_format.known_role_flags, codec.getInt(u32, &bytes, offset + 20));
        try std.testing.expect(codec.isZero(bytes[offset + 24 .. offset + descriptor_size]));
    }
    try std.testing.expect(codec.isZero(bytes[reserved_offset..checksum_offset]));
    try std.testing.expectEqual(codec.crc32c(bytes[0..checksum_offset]), codec.getInt(u32, &bytes, checksum_offset));
    const decoded = try decode(&bytes);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encode(decoded)));

    var reordered = topology;
    reordered.members = .{ topology.members[1], topology.members[2], topology.members[0] };
    try std.testing.expectEqualSlices(u8, &bytes, &(try encode(reordered)));
    try std.testing.expectEqualSlices(u8, &(try digest(topology)), &(try digest(reordered)));

    var alternate_crc = bytes;
    alternate_crc[checksum_offset] ^= 1;
    try std.testing.expectEqualSlices(
        u8,
        &codec.blake3(bytes[0..checksum_offset]),
        &codec.blake3(alternate_crc[0..checksum_offset]),
    );
}

test "golden fixture and topology fingerprint" {
    const canonical = try encode(testTopology());
    const fixture = try readFixture();
    try std.testing.expectEqualSlices(u8, &fixture, &canonical);
    var expected_fingerprint: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected_fingerprint, "af1b230be435c77b3f1ca3064bd757df027bc7c1863bc1ae66e528dc2258a107");
    try std.testing.expectEqualSlices(u8, &expected_fingerprint, &(try digest(testTopology())));
}

test "identity placement epoch quorum role and flags validation" {
    var topology = testTopology();
    topology.set_id = @splat(0);
    try std.testing.expectError(error.InvalidSetId, encode(topology));
    topology = testTopology();
    topology.members[0].member_id = @splat(0);
    try std.testing.expectError(error.InvalidMemberId, encode(topology));
    topology = testTopology();
    topology.members[0].member_id = topology.set_id;
    try std.testing.expectError(error.InvalidMemberId, encode(topology));
    topology = testTopology();
    topology.members[1].member_id = topology.members[0].member_id;
    try std.testing.expectError(error.DuplicateMemberId, encode(topology));
    topology = testTopology();
    topology.members[1].slot = topology.members[0].slot;
    try std.testing.expectError(error.DuplicateMemberSlot, encode(topology));
    topology = testTopology();
    topology.members[1].slot = 3;
    try std.testing.expectError(error.InvalidMemberSlot, encode(topology));
    topology = testTopology();
    topology.quorum = 1;
    try std.testing.expectError(error.InvalidQuorum, encode(topology));
    topology = testTopology();
    topology.members[0].control_role = 2;
    try std.testing.expectError(error.InvalidControlRole, encode(topology));
    topology = testTopology();
    topology.members[0].role_flags = member_format.metadata_role;
    try std.testing.expectError(error.InvalidRoleFlags, encode(topology));
    topology = testTopology();
    topology.flags = 1;
    try std.testing.expectError(error.InvalidTopologyFlags, encode(topology));
}

test "dynamic pool control policy is independent of legacy topology codec" {
    try std.testing.expectEqual(ControlPolicy{ .voter_count = 1, .write_quorum = 1 }, try controlPolicy(1));
    try std.testing.expectEqual(ControlPolicy{ .voter_count = 2, .write_quorum = 2 }, try controlPolicy(2));
    try std.testing.expectEqual(ControlPolicy{ .voter_count = 3, .write_quorum = 2 }, try controlPolicy(3));
    try std.testing.expectEqual(ControlPolicy{ .voter_count = 3, .write_quorum = 2 }, try controlPolicy(12));
}

test "parent digest follows epoch rules" {
    var topology = testTopology();
    topology.epoch = 0;
    try std.testing.expectError(error.InvalidEpoch, encode(topology));
    topology = testTopology();
    topology.parent_digest[0] = 1;
    try std.testing.expectError(error.InvalidParentDigest, encode(topology));
    topology.epoch = 2;
    _ = try encode(topology);
    topology.parent_digest = @splat(0);
    try std.testing.expectError(error.InvalidParentDigest, encode(topology));
}

test "corrupt framing checksum version and padding are rejected" {
    const canonical = try encode(testTopology());
    const cases = [_]struct { offset: usize, expected: anyerror }{
        .{ .offset = 0, .expected = error.InvalidMagic },
        .{ .offset = 8, .expected = error.UnsupportedFormatVersion },
        .{ .offset = 10, .expected = error.InvalidHeaderSize },
        .{ .offset = 76, .expected = error.InvalidTopologyFlags },
        .{ .offset = descriptors_offset + 19, .expected = error.NonZeroDescriptorReserved },
        .{ .offset = reserved_offset, .expected = error.NonZeroReserved },
    };
    for (cases) |case| {
        var bytes = canonical;
        bytes[case.offset] ^= 1;
        fixChecksum(&bytes);
        try std.testing.expectError(case.expected, decode(&bytes));
    }
    var checksum_bad = canonical;
    checksum_bad[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&checksum_bad));

    var noncanonical = canonical;
    const first = noncanonical[descriptors_offset..][0..descriptor_size].*;
    const second = noncanonical[descriptors_offset + descriptor_size ..][0..descriptor_size].*;
    @memcpy(noncanonical[descriptors_offset..][0..descriptor_size], &second);
    @memcpy(noncanonical[descriptors_offset + descriptor_size ..][0..descriptor_size], &first);
    fixChecksum(&noncanonical);
    try std.testing.expectError(error.NonCanonicalMemberOrder, decode(&noncanonical));
}

test "member header validation is order independent" {
    const topology = testTopology();
    const genesis_digest = try digest(topology);
    const headers = try testHeaders(topology);
    const permutations = [_][member_count]usize{
        .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 0, 2 },
        .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 },
    };
    for (permutations) |permutation| {
        const ordered = [_]member_format.Header{
            headers[permutation[0]], headers[permutation[1]], headers[permutation[2]],
        };
        try validateMemberSet(topology, genesis_digest, &ordered);
    }
}

test "single member header is cross-validated independently" {
    const topology = testTopology();
    const genesis_digest = try digest(topology);
    const base = try testHeader(topology, topology.members[0]);
    try validateMemberHeader(topology, genesis_digest, base);

    var invalid_topology = topology;
    invalid_topology.quorum = 1;
    try std.testing.expectError(error.InvalidQuorum, validateMemberHeader(invalid_topology, genesis_digest, base));

    var header = base;
    header.set_id[0] ^= 1;
    try std.testing.expectError(error.ForeignSet, validateMemberHeader(topology, genesis_digest, header));

    header = base;
    header.member_id = @splat(0x99);
    try std.testing.expectError(error.ForeignMember, validateMemberHeader(topology, genesis_digest, header));

    header = base;
    header.member_slot = topology.members[1].slot;
    try std.testing.expectError(error.MemberHeaderMismatch, validateMemberHeader(topology, genesis_digest, header));

    header = base;
    header.member_count -= 1;
    try std.testing.expectError(error.MemberHeaderMismatch, validateMemberHeader(topology, genesis_digest, header));

    header = base;
    header.role_flags = member_format.metadata_role;
    try std.testing.expectError(error.MemberHeaderMismatch, validateMemberHeader(topology, genesis_digest, header));

    header = base;
    header.genesis_topology_digest[0] ^= 1;
    try std.testing.expectError(error.GenesisTopologyDigestMismatch, validateMemberHeader(topology, genesis_digest, header));
}

test "member header membership and topology mismatches are distinct" {
    const topology = testTopology();
    const genesis_digest = try digest(topology);
    var headers = try testHeaders(topology);
    try std.testing.expectError(error.MissingMember, validateMemberSet(topology, genesis_digest, headers[0..2]));
    try validateMemberSubset(topology, genesis_digest, headers[0..2]);
    try std.testing.expectError(error.MissingMember, validateMemberSubset(topology, genesis_digest, headers[0..0]));
    headers[1].created_ns += 1;
    try std.testing.expectError(
        error.StaticSetFieldsMismatch,
        validateMemberSubset(topology, genesis_digest, headers[0..2]),
    );
    headers[2] = headers[0];
    try std.testing.expectError(error.DuplicateMember, validateMemberSet(topology, genesis_digest, &headers));
    headers = try testHeaders(topology);
    headers[2].member_id = @splat(0x99);
    try std.testing.expectError(error.ForeignMember, validateMemberSet(topology, genesis_digest, &headers));
    headers = try testHeaders(topology);
    headers[2].set_id[0] ^= 1;
    try std.testing.expectError(error.ForeignSet, validateMemberSet(topology, genesis_digest, &headers));
    headers = try testHeaders(topology);
    headers[2].member_slot = headers[1].member_slot;
    try std.testing.expectError(error.MemberHeaderMismatch, validateMemberSet(topology, genesis_digest, &headers));
    headers = try testHeaders(topology);
    headers[2].genesis_topology_digest[0] ^= 1;
    try std.testing.expectError(error.GenesisTopologyDigestMismatch, validateMemberSet(topology, genesis_digest, &headers));
}

test "current topology digest is separate from genesis identity" {
    const genesis = testTopology();
    const genesis_digest = try digest(genesis);
    const headers = try testHeaders(genesis);
    var current = genesis;
    current.epoch = 2;
    current.parent_digest = genesis_digest;
    try validateMemberSet(current, genesis_digest, &headers);

    var wrong_genesis_digest = genesis_digest;
    wrong_genesis_digest[0] ^= 1;
    try std.testing.expectError(
        error.GenesisTopologyDigestMismatch,
        validateMemberSet(current, wrong_genesis_digest, &headers),
    );
}

test "all set-level static fields are cross-validated" {
    const topology = testTopology();
    const genesis_digest = try digest(topology);
    const base = try testHeaders(topology);
    inline for (.{
        "compat_features",               "ro_compat_features", "incompat_features",       "created_ns",            "logical_capacity",
        "control",                       "metadata",           "data",                    "metadata_block_size",   "metadata_read_size",
        "metadata_program_size",         "chunk_size",         "metadata_format_version", "object_format_version", "layout_format_version",
        "control_record_format_version", "checksum_algorithm", "digest_algorithm",
    }) |field| {
        var headers = base;
        const value = &@field(headers[1], field);
        switch (@TypeOf(value.*)) {
            codec.Region => value.length += 1,
            else => value.* += 1,
        }
        try std.testing.expectError(error.StaticSetFieldsMismatch, validateMemberSet(topology, genesis_digest, &headers));
    }
    var headers = base;
    headers[1].label = try member_format.Label.init("different-label");
    try std.testing.expectError(error.StaticSetFieldsMismatch, validateMemberSet(topology, genesis_digest, &headers));
}

test "member-local sequence and checkpoint differences are accepted" {
    const topology = testTopology();
    const genesis_digest = try digest(topology);
    var headers = try testHeaders(topology);
    headers[1].header_sequence += 1;
    headers[1].checkpoint_offset = headers[1].control.offset;
    headers[1].checkpoint_record_sequence = 19;
    headers[1].checkpoint_record_digest = @splat(0x5a);
    try validateMemberSet(topology, genesis_digest, &headers);
}

test "all single byte mutations are detected without checksum repair" {
    const canonical = try encode(testTopology());
    for (0..encoded_size) |offset| {
        var mutated = canonical;
        mutated[offset] ^= 0x80;
        try std.testing.expectError(error.ChecksumMismatch, decode(&mutated));
    }
}
