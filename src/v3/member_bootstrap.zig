const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const member_format = @import("member_format.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const encoded_size: usize = 3584;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);
pub const topology_offset: usize = 0x040;
pub const layout_offset: usize = topology_offset + pool_topology.encoded_size;
pub const reserved_offset: usize = layout_offset + pool_layout.encoded_size;

const magic = [8]u8{ 'D', 'D', 'V', 'B', 'O', 'O', 'T', '1' };
const format_version: u16 = 1;

comptime {
    std.debug.assert(reserved_offset <= checksum_offset);
    std.debug.assert(encoded_size <= control_record.payload_capacity);
}

pub const Evidence = struct {
    target_member_id: [16]u8,
    target_slot: u16,
    topology: pool_topology.Topology,
    layout: pool_layout.Layout,
};

pub fn encode(evidence: Evidence) ![encoded_size]u8 {
    try validate(evidence);
    const topology_bytes = try pool_topology.encode(evidence.topology);
    const layout_bytes = try pool_layout.encode(evidence.layout);
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, 0);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    @memcpy(bytes[0x010..0x020], &evidence.target_member_id);
    codec.putInt(u16, &bytes, 0x020, evidence.target_slot);
    codec.putInt(u16, &bytes, 0x022, 0);
    codec.putInt(u32, &bytes, 0x024, pool_topology.encoded_size);
    codec.putInt(u32, &bytes, 0x028, pool_layout.encoded_size);
    @memcpy(bytes[topology_offset..layout_offset], &topology_bytes);
    @memcpy(bytes[layout_offset..reserved_offset], &layout_bytes);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(input: []const u8) !Evidence {
    if (input.len != encoded_size) return error.InvalidBootstrapPayloadLength;
    const bytes: *const [encoded_size]u8 = input[0..encoded_size];
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != format_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u16, bytes, 0x00a) != 0 or codec.getInt(u16, bytes, 0x022) != 0)
        return error.InvalidFlags;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size or
        codec.getInt(u32, bytes, 0x024) != pool_topology.encoded_size or
        codec.getInt(u32, bytes, 0x028) != pool_layout.encoded_size) return error.InvalidFraming;
    if (!codec.isZero(bytes[0x02c..topology_offset]) or
        !codec.isZero(bytes[reserved_offset..checksum_offset])) return error.NonZeroReserved;
    const topology_bytes: *const [pool_topology.encoded_size]u8 = bytes[topology_offset..layout_offset];
    const layout_bytes: *const [pool_layout.encoded_size]u8 = bytes[layout_offset..reserved_offset];
    const evidence: Evidence = .{
        .target_member_id = bytes[0x010..0x020].*,
        .target_slot = codec.getInt(u16, bytes, 0x020),
        .topology = try pool_topology.decode(topology_bytes),
        .layout = try pool_layout.decode(layout_bytes),
    };
    try validate(evidence);
    return evidence;
}

pub fn makePayload(evidence: Evidence) !control_record.Payload {
    const bytes = try encode(evidence);
    return control_record.Payload.init(&bytes);
}

pub fn validateRecord(record: control_record.Record) !Evidence {
    try control_record.validateDynamicPoolPolicy(record);
    if (record.kind != control_record.member_bootstrap_kind) return error.NotMemberBootstrapRecord;
    if (!std.mem.eql(u8, &record.history_digest, &(try control_record.historyDigest(record))))
        return error.HistoryDigestMismatch;
    const evidence = try decode(record.payload.slice());
    if (!std.mem.eql(u8, &record.set_id, &evidence.topology.set_id)) return error.ForeignSet;
    if (record.membership_epoch != evidence.topology.epoch) return error.MembershipEpochMismatch;
    if (!std.mem.eql(u8, &record.topology_digest, &(try pool_topology.digest(evidence.topology))))
        return error.TopologyDigestMismatch;
    if (!std.mem.eql(u8, &record.layout_digest, &(try pool_layout.digest(evidence.layout))))
        return error.LayoutDigestMismatch;
    return evidence;
}

pub fn validateTargetFirstRecord(header: member_format.Header, record: control_record.Record) !Evidence {
    const evidence = try validateRecord(record);
    if (record.local_sequence != 1 or !codec.isZero(&record.previous_record_digest) or
        codec.isZero(&record.previous_history_digest)) return error.InvalidBootstrapFirstRecord;
    if (!std.mem.eql(u8, &record.member_id, &evidence.target_member_id))
        return error.BootstrapTargetMismatch;
    try validateTargetHeader(evidence, header);
    return evidence;
}

pub fn validateTargetHeader(evidence: Evidence, header: member_format.Header) !void {
    try validate(evidence);
    try member_format.validate(header);
    if (!member_format.isDynamicPool(header)) return error.DynamicPoolFeatureRequired;
    if (member_format.hasScheduledBlobData(header) != (evidence.layout.scheduled_blob != null))
        return error.ScheduledBlobFeatureMismatch;
    if (!std.mem.eql(u8, &header.set_id, &evidence.topology.set_id)) return error.ForeignSet;
    if (!std.mem.eql(u8, &header.member_id, &evidence.target_member_id) or
        header.member_slot != evidence.target_slot) return error.BootstrapTargetMismatch;
    const target = pool_topology.findMember(&evidence.topology, evidence.target_member_id) orelse
        return error.BootstrapTargetNotFound;
    if (header.member_count != evidence.topology.member_count or header.role_flags != target.role_flags)
        return error.MemberHeaderMismatch;
    if (!std.mem.eql(u8, &header.genesis_topology_digest, &(try pool_topology.digest(evidence.topology))))
        return error.BirthTopologyDigestMismatch;
    if (header.chunk_size != evidence.layout.chunk_size) return error.ChunkSizeMismatch;
    if (header.layout_format_version != member_format.expectedLayoutFormatVersion(header))
        return error.UnsupportedLayoutFormat;
    if (evidence.layout.scheduled_blob) |scheduled| {
        if (header.logical_capacity != scheduled.logical_capacity) return error.LogicalCapacityMismatch;
        if (evidence.topology.member_count != scheduled.member_count)
            return error.ScheduledMemberCountMismatch;
    }
}

fn validate(evidence: Evidence) !void {
    try pool_topology.validate(evidence.topology);
    try pool_layout.validate(evidence.layout);
    if (evidence.layout.topology_epoch > evidence.topology.epoch) return error.FutureTopologyEpoch;
    const target = pool_topology.findMember(&evidence.topology, evidence.target_member_id) orelse
        return error.BootstrapTargetNotFound;
    if (target.slot != evidence.target_slot) return error.BootstrapTargetMismatch;
    if (target.state != .joining or target.control_role != pool_topology.non_voter_role)
        return error.InvalidBootstrapTargetState;
}

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn testEvidence() !Evidence {
    const members = [_]pool_topology.Member{
        .{ .member_id = id(2), .slot = 3, .control_role = pool_topology.voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(3), .slot = 19, .state = .joining },
    };
    return .{
        .target_member_id = id(3),
        .target_slot = 19,
        .topology = try pool_topology.Topology.init(id(1), 2, id(9) ++ id(9), &members),
        .layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024),
    };
}

fn testRecord(evidence: Evidence) !control_record.Record {
    var record: control_record.Record = .{
        .kind = control_record.member_bootstrap_kind,
        .local_sequence = 1,
        .membership_epoch = evidence.topology.epoch,
        .writer_term = 1,
        .generation = 4,
        .set_id = evidence.topology.set_id,
        .member_id = evidence.target_member_id,
        .mount_session_id = @splat(0),
        .transaction_id = id(8),
        .previous_record_digest = @splat(0),
        .previous_history_digest = @splat(0x44),
        .data_root_digest = @splat(0x55),
        .topology_digest = try pool_topology.digest(evidence.topology),
        .layout_digest = try pool_layout.digest(evidence.layout),
        .payload = try makePayload(evidence),
    };
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

fn testHeader(evidence: Evidence) !member_format.Header {
    return .{
        .header_sequence = 1,
        .incompat_features = member_format.dynamic_pool_incompat_feature,
        .set_id = evidence.topology.set_id,
        .member_id = evidence.target_member_id,
        .member_slot = evidence.target_slot,
        .member_count = evidence.topology.member_count,
        .role_flags = member_format.data_role,
        .created_ns = 1,
        .member_bytes = 3 * 1024 * 1024,
        .logical_capacity = 1024 * 1024,
        .control = .{ .offset = 64 * 1024, .length = 64 * 1024 },
        .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
        .data = .{ .offset = 2 * 1024 * 1024, .length = 1024 * 1024 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = evidence.layout.chunk_size,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = member_format.dynamic_layout_format_version,
        .control_record_format_version = 1,
        .label = try member_format.Label.init("bootstrap-test"),
        .genesis_topology_digest = try pool_topology.digest(evidence.topology),
    };
}

test "bootstrap payload round trips exact topology layout and target" {
    const evidence = try testEvidence();
    const bytes = try encode(evidence);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encode(try decode(&bytes))));
    try std.testing.expectEqual(@as(u16, 19), codec.getInt(u16, &bytes, 0x020));
}

test "target first record continues shared history from local sequence one" {
    const evidence = try testEvidence();
    const record = try testRecord(evidence);
    _ = try control_record.encodeDynamicPool(record);
    _ = try validateTargetFirstRecord(try testHeader(evidence), record);
    try std.testing.expectError(error.UnsupportedRecordKind, control_record.encode(record));
}

test "bootstrap target must be joining non-voter at its stable slot" {
    var evidence = try testEvidence();
    evidence.target_slot += 1;
    try std.testing.expectError(error.BootstrapTargetMismatch, encode(evidence));
    evidence = try testEvidence();
    evidence.topology.members[1].state = .active;
    evidence.topology.quorum = 2;
    evidence.topology.members[1].control_role = pool_topology.voter_role;
    evidence.topology.members[1].role_flags = member_format.known_role_flags;
    try std.testing.expectError(error.InvalidBootstrapTargetState, encode(evidence));
}

test "target header is bound to birth topology and chunk geometry" {
    const evidence = try testEvidence();
    var header = try testHeader(evidence);
    try validateTargetHeader(evidence, header);
    header.genesis_topology_digest[0] ^= 1;
    try std.testing.expectError(error.BirthTopologyDigestMismatch, validateTargetHeader(evidence, header));
    header = try testHeader(evidence);
    header.member_slot += 1;
    try std.testing.expectError(error.BootstrapTargetMismatch, validateTargetHeader(evidence, header));
}

test "record binds membership topology and layout digests" {
    const evidence = try testEvidence();
    var record = try testRecord(evidence);
    _ = try validateRecord(record);
    record.topology_digest[0] ^= 1;
    record.history_digest = try control_record.historyDigest(record);
    try std.testing.expectError(error.TopologyDigestMismatch, validateRecord(record));
}

test "framing reserved bytes and checksum corruption are rejected" {
    const canonical = try encode(try testEvidence());
    var bytes = canonical;
    bytes[0x02c] = 1;
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    try std.testing.expectError(error.NonZeroReserved, decode(&bytes));
    bytes = canonical;
    bytes[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&bytes));
}
