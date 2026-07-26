const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const member_format = @import("member_format.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const encoded_size: usize = 3520;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);
pub const topology_offset: usize = 0x020;
pub const layout_offset: usize = topology_offset + pool_topology.encoded_size;
pub const reserved_offset: usize = layout_offset + pool_layout.encoded_size;

const magic = [8]u8{ 'D', 'D', 'V', 'G', 'E', 'N', '2', 0 };
const format_version: u16 = 2;

comptime {
    std.debug.assert(reserved_offset <= checksum_offset);
    std.debug.assert(encoded_size <= control_record.payload_capacity);
}

pub const GenesisPayload = struct {
    topology: pool_topology.Topology,
    layout: pool_layout.Layout,
};

pub fn encode(payload: GenesisPayload) ![encoded_size]u8 {
    try validate(payload);
    const topology_bytes = try pool_topology.encode(payload.topology);
    const layout_bytes = try pool_layout.encode(payload.layout);
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, 0);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    codec.putInt(u32, &bytes, 0x010, pool_topology.encoded_size);
    codec.putInt(u32, &bytes, 0x014, pool_layout.encoded_size);
    @memcpy(bytes[topology_offset..layout_offset], &topology_bytes);
    @memcpy(bytes[layout_offset..reserved_offset], &layout_bytes);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(input: []const u8) !GenesisPayload {
    if (input.len != encoded_size) return error.InvalidGenesisPayloadLength;
    const bytes: *const [encoded_size]u8 = input[0..encoded_size];
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != format_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u16, bytes, 0x00a) != 0) return error.InvalidFlags;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size or
        codec.getInt(u32, bytes, 0x010) != pool_topology.encoded_size or
        codec.getInt(u32, bytes, 0x014) != pool_layout.encoded_size) return error.InvalidFraming;
    if (!codec.isZero(bytes[0x018..topology_offset]) or
        !codec.isZero(bytes[reserved_offset..checksum_offset])) return error.NonZeroReserved;

    const topology_bytes: *const [pool_topology.encoded_size]u8 = bytes[topology_offset..layout_offset];
    const layout_bytes: *const [pool_layout.encoded_size]u8 = bytes[layout_offset..reserved_offset];
    const payload: GenesisPayload = .{
        .topology = try pool_topology.decode(topology_bytes),
        .layout = try pool_layout.decode(layout_bytes),
    };
    try validate(payload);
    return payload;
}

pub fn digest(payload: GenesisPayload) !codec.Digest {
    const bytes = try encode(payload);
    return codec.blake3(bytes[0..checksum_offset]);
}

pub fn makeRecord(member_id: [16]u8, payload: GenesisPayload) !control_record.Record {
    _ = try findGenesisMember(payload, member_id);
    const payload_bytes = try encode(payload);
    var record: control_record.Record = .{
        .kind = control_record.genesis_kind,
        .local_sequence = 1,
        .membership_epoch = 1,
        .writer_term = 0,
        .generation = 0,
        .set_id = payload.topology.set_id,
        .member_id = member_id,
        .mount_session_id = @splat(0),
        .transaction_id = @splat(0),
        .previous_record_digest = @splat(0),
        .previous_history_digest = @splat(0),
        .data_root_digest = @splat(0),
        .topology_digest = try pool_topology.digest(payload.topology),
        .layout_digest = try pool_layout.digest(payload.layout),
        .payload = try control_record.Payload.init(&payload_bytes),
    };
    record.history_digest = try control_record.historyDigest(record);
    try control_record.validatePolicy(record);
    return record;
}

pub fn validateRecord(record: control_record.Record) !GenesisPayload {
    try control_record.validatePolicy(record);
    if (record.kind != control_record.genesis_kind) return error.NotGenesisRecord;
    const payload = try decode(record.payload.slice());
    _ = try findGenesisMember(payload, record.member_id);
    if (!std.mem.eql(u8, &record.set_id, &payload.topology.set_id)) return error.GenesisSetIdMismatch;
    if (!std.mem.eql(u8, &record.topology_digest, &(try pool_topology.digest(payload.topology))))
        return error.GenesisTopologyDigestMismatch;
    if (!std.mem.eql(u8, &record.layout_digest, &(try pool_layout.digest(payload.layout))))
        return error.GenesisLayoutDigestMismatch;
    return payload;
}

pub fn validateMemberHeader(payload: GenesisPayload, header: member_format.Header) !void {
    try validate(payload);
    try member_format.validate(header);
    if (!member_format.isDynamicPool(header)) return error.DynamicPoolFeatureRequired;
    if (!std.mem.eql(u8, &header.set_id, &payload.topology.set_id)) return error.ForeignSet;
    const member = try findGenesisMember(payload, header.member_id);
    if (header.member_slot != member.slot or header.member_count != payload.topology.member_count or
        header.role_flags != member.role_flags) return error.MemberHeaderMismatch;
    if (!std.mem.eql(u8, &header.genesis_topology_digest, &(try pool_topology.digest(payload.topology))))
        return error.GenesisTopologyDigestMismatch;
    if (header.chunk_size != payload.layout.chunk_size) return error.ChunkSizeMismatch;
    if (header.layout_format_version != member_format.dynamic_layout_format_version)
        return error.UnsupportedLayoutFormat;
}

fn validate(payload: GenesisPayload) !void {
    try pool_topology.validate(payload.topology);
    try pool_layout.validate(payload.layout);
    if (payload.topology.epoch != 1 or !codec.isZero(&payload.topology.parent_digest))
        return error.InvalidGenesisTopology;
    if (payload.layout.layout_epoch != 1 or payload.layout.topology_epoch != 1)
        return error.InvalidGenesisLayout;
    for (payload.topology.memberSlice()) |member| {
        if (member.state != .active) return error.InvalidGenesisMemberState;
    }
}

fn findGenesisMember(payload: GenesisPayload, member_id: [16]u8) !pool_topology.Member {
    try validate(payload);
    return (pool_topology.findMember(&payload.topology, member_id) orelse
        return error.GenesisMemberNotFound).*;
}

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn testPayload(member_count: usize, protection: @import("pool_policy.zig").Protection) !GenesisPayload {
    var members: [4]pool_topology.Member = undefined;
    for (members[0..member_count], 0..) |*member, index| {
        member.* = .{ .member_id = id(@intCast(index + 2)), .slot = @intCast(index * 5 + 3) };
        if (index < @min(member_count, 3)) {
            member.control_role = pool_topology.voter_role;
            member.role_flags = member_format.known_role_flags;
        }
    }
    return .{
        .topology = try pool_topology.Topology.init(id(1), 1, @splat(0), members[0..member_count]),
        .layout = try pool_layout.Layout.init(protection, 1, 1, 1024 * 1024),
    };
}

fn testHeader(payload: GenesisPayload, member: pool_topology.Member) !member_format.Header {
    return .{
        .header_sequence = 1,
        .incompat_features = member_format.dynamic_pool_incompat_feature,
        .set_id = payload.topology.set_id,
        .member_id = member.member_id,
        .member_slot = member.slot,
        .member_count = payload.topology.member_count,
        .role_flags = member.role_flags,
        .created_ns = 1,
        .member_bytes = 3 * 1024 * 1024,
        .logical_capacity = 1024 * 1024,
        .control = .{ .offset = 64 * 1024, .length = 64 * 1024 },
        .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
        .data = .{ .offset = 2 * 1024 * 1024, .length = 1024 * 1024 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = payload.layout.chunk_size,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = member_format.dynamic_layout_format_version,
        .control_record_format_version = 1,
        .label = try member_format.Label.init("pool-genesis-test"),
        .genesis_topology_digest = try pool_topology.digest(payload.topology),
    };
}

test "one-member dynamic genesis round trips and creates a shared record" {
    const payload = try testPayload(1, .unprotected);
    const bytes = try encode(payload);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encode(try decode(&bytes))));
    const record = try makeRecord(payload.topology.members[0].member_id, payload);
    try std.testing.expectEqual(payload.topology.epoch, record.membership_epoch);
    _ = try validateRecord(record);
}

test "four-member genesis permits a non-voter data member" {
    const payload = try testPayload(4, .replicated);
    const member = payload.topology.members[3];
    try std.testing.expectEqual(pool_topology.non_voter_role, member.control_role);
    const record = try makeRecord(member.member_id, payload);
    _ = try validateRecord(record);
    try validateMemberHeader(payload, try testHeader(payload, member));
}

test "genesis rejects joining members and foreign record members" {
    var payload = try testPayload(1, .unprotected);
    payload.topology.members[0].state = .joining;
    payload.topology.members[0].control_role = pool_topology.non_voter_role;
    payload.topology.members[0].role_flags = member_format.data_role;
    try std.testing.expectError(error.InvalidActiveMemberCount, encode(payload));

    payload = try testPayload(1, .unprotected);
    try std.testing.expectError(error.GenesisMemberNotFound, makeRecord(id(9), payload));
}

test "dynamic member header binds birth topology identity and layout" {
    const payload = try testPayload(1, .unprotected);
    var header = try testHeader(payload, payload.topology.members[0]);
    try validateMemberHeader(payload, header);
    header.member_slot += 1;
    try std.testing.expectError(error.MemberHeaderMismatch, validateMemberHeader(payload, header));
    header = try testHeader(payload, payload.topology.members[0]);
    header.genesis_topology_digest[0] ^= 1;
    try std.testing.expectError(error.GenesisTopologyDigestMismatch, validateMemberHeader(payload, header));
}

test "framing reserved bytes and checksum corruption are rejected" {
    const payload = try testPayload(1, .unprotected);
    const canonical = try encode(payload);
    var bytes = canonical;
    bytes[reserved_offset] = 1;
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    try std.testing.expectError(error.NonZeroReserved, decode(&bytes));
    bytes = canonical;
    bytes[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&bytes));
}
