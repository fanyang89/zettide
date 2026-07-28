const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const encoded_size: usize = 3584;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);

const magic = [8]u8{ 'D', 'D', 'V', 'P', 'C', 'H', 'K', '1' };
const format_version: u16 = 1;
const administrative_recovery_flag: u16 = 1 << 0;
const known_flags = administrative_recovery_flag;
const topology_offset: usize = 0x060;
const layout_offset: usize = topology_offset + pool_topology.encoded_size;
const reserved_offset: usize = layout_offset + pool_layout.encoded_size;

comptime {
    std.debug.assert(encoded_size <= control_record.payload_capacity);
    std.debug.assert(reserved_offset <= checksum_offset);
}

pub const Snapshot = struct {
    previous_authority_history_digest: codec.Digest,
    data_root_digest: codec.Digest,
    writer_term: u64,
    generation: u64,
    topology: pool_topology.Topology,
    layout: pool_layout.Layout,
    administrative_recovery: bool = false,
};

pub const AuthorityContext = struct {
    history_digest: codec.Digest,
    data_root_digest: codec.Digest,
    topology: pool_topology.Topology,
    layout: pool_layout.Layout,
    membership_epoch: u64,
    writer_term: u64,
    generation: u64,
    administrative_recovery: bool,
};

pub fn encode(snapshot: Snapshot) ![encoded_size]u8 {
    try validate(snapshot);
    const topology_bytes = try pool_topology.encode(snapshot.topology);
    const layout_bytes = try pool_layout.encode(snapshot.layout);
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, if (snapshot.administrative_recovery) administrative_recovery_flag else 0);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    @memcpy(bytes[0x010..0x030], &snapshot.previous_authority_history_digest);
    @memcpy(bytes[0x030..0x050], &snapshot.data_root_digest);
    codec.putInt(u64, &bytes, 0x050, snapshot.writer_term);
    codec.putInt(u64, &bytes, 0x058, snapshot.generation);
    @memcpy(bytes[topology_offset..layout_offset], &topology_bytes);
    @memcpy(bytes[layout_offset..reserved_offset], &layout_bytes);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(bytes: *const [encoded_size]u8) !Snapshot {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != format_version) return error.UnsupportedFormatVersion;
    const flags = codec.getInt(u16, bytes, 0x00a);
    if (flags & ~known_flags != 0) return error.UnsupportedFlags;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size) return error.InvalidEncodedSize;
    if (!codec.isZero(bytes[reserved_offset..checksum_offset])) return error.NonZeroReserved;

    const topology_bytes: [pool_topology.encoded_size]u8 = bytes[topology_offset..layout_offset].*;
    const layout_bytes: [pool_layout.encoded_size]u8 = bytes[layout_offset..reserved_offset].*;
    const snapshot: Snapshot = .{
        .previous_authority_history_digest = bytes[0x010..0x030].*,
        .data_root_digest = bytes[0x030..0x050].*,
        .writer_term = codec.getInt(u64, bytes, 0x050),
        .generation = codec.getInt(u64, bytes, 0x058),
        .topology = try pool_topology.decode(&topology_bytes),
        .layout = try pool_layout.decode(&layout_bytes),
        .administrative_recovery = flags & administrative_recovery_flag != 0,
    };
    try validate(snapshot);
    return snapshot;
}

pub fn makePayload(snapshot: Snapshot) !control_record.Payload {
    return control_record.Payload.init(&(try encode(snapshot)));
}

pub fn isSnapshotRecord(record: control_record.Record) bool {
    return record.kind == control_record.checkpoint_kind and record.payload.len == encoded_size and
        std.mem.eql(u8, record.payload.slice()[0..magic.len], &magic);
}

pub fn validateRecord(record: control_record.Record, expected: AuthorityContext) !Snapshot {
    if (record.kind != control_record.checkpoint_kind) return error.NotCheckpointRecord;
    try control_record.validateDynamicPoolPolicy(record);
    if (!std.mem.eql(u8, &record.history_digest, &(try control_record.historyDigest(record))))
        return error.HistoryDigestMismatch;
    if (codec.isZero(&record.transaction_id)) return error.InvalidCheckpointTransaction;
    try validateContext(expected);
    if (record.payload.len != encoded_size) return error.InvalidCheckpointPayloadLength;
    var bytes: [encoded_size]u8 = undefined;
    @memcpy(&bytes, record.payload.slice());
    const snapshot = try decode(&bytes);
    if (!std.mem.eql(u8, &snapshot.previous_authority_history_digest, &expected.history_digest) or
        !std.mem.eql(u8, &record.previous_history_digest, &expected.history_digest))
        return error.PreviousAuthorityDigestMismatch;
    if (!std.meta.eql(snapshot.topology, expected.topology) or
        !std.meta.eql(snapshot.layout, expected.layout) or
        !std.mem.eql(u8, &snapshot.data_root_digest, &expected.data_root_digest) or
        snapshot.writer_term != expected.writer_term or snapshot.generation != expected.generation or
        snapshot.administrative_recovery != expected.administrative_recovery)
        return error.CheckpointAuthorityMismatch;
    if (!std.mem.eql(u8, &record.set_id, &snapshot.topology.set_id)) return error.CheckpointSetMismatch;
    if (record.membership_epoch != snapshot.topology.epoch) return error.MembershipEpochMismatch;
    if (!std.mem.eql(u8, &record.data_root_digest, &snapshot.data_root_digest) or
        record.writer_term != snapshot.writer_term or record.generation != snapshot.generation)
        return error.CheckpointAuthorityMismatch;
    if (!std.mem.eql(u8, &record.topology_digest, &(try pool_topology.digest(snapshot.topology))))
        return error.TopologyDigestMismatch;
    if (!std.mem.eql(u8, &record.layout_digest, &(try pool_layout.digest(snapshot.layout))))
        return error.LayoutDigestMismatch;
    const publisher = pool_topology.findMember(&snapshot.topology, record.member_id) orelse
        return error.CheckpointPublisherNotInTopology;
    if (publisher.control_role != pool_topology.voter_role)
        return error.CheckpointPublisherIsNotVoter;
    return snapshot;
}

pub fn validate(snapshot: Snapshot) !void {
    if (codec.isZero(&snapshot.previous_authority_history_digest))
        return error.InvalidPreviousAuthorityDigest;
    try pool_topology.validate(snapshot.topology);
    _ = try pool_layout.dataAccess(snapshot.layout, snapshot.topology);
    for (snapshot.topology.memberSlice()) |member| {
        if (member.state == .joining) return error.UnsettledCheckpointTopology;
    }
}

fn validateContext(context: AuthorityContext) !void {
    try validate(.{
        .previous_authority_history_digest = context.history_digest,
        .data_root_digest = context.data_root_digest,
        .writer_term = context.writer_term,
        .generation = context.generation,
        .topology = context.topology,
        .layout = context.layout,
        .administrative_recovery = context.administrative_recovery,
    });
    if (context.membership_epoch != context.topology.epoch) return error.MembershipEpochMismatch;
}

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn testSnapshot() !Snapshot {
    const members = [_]pool_topology.Member{
        .{ .member_id = id(2), .slot = 1, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = id(3), .slot = 4, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = id(4), .slot = 9, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = id(5), .slot = 12 },
    };
    return .{
        .previous_authority_history_digest = @splat(0x55),
        .data_root_digest = @splat(0x66),
        .writer_term = 5,
        .generation = 11,
        .topology = try pool_topology.Topology.init(id(1), 3, @splat(0x44), &members),
        .layout = try pool_layout.Layout.init(.replicated, 1, 2, 1024 * 1024),
        .administrative_recovery = true,
    };
}

fn testContext(snapshot: Snapshot) AuthorityContext {
    return .{
        .history_digest = snapshot.previous_authority_history_digest,
        .data_root_digest = snapshot.data_root_digest,
        .topology = snapshot.topology,
        .layout = snapshot.layout,
        .membership_epoch = snapshot.topology.epoch,
        .writer_term = snapshot.writer_term,
        .generation = snapshot.generation,
        .administrative_recovery = snapshot.administrative_recovery,
    };
}

fn testRecord(snapshot: Snapshot) !control_record.Record {
    var record: control_record.Record = .{
        .kind = control_record.checkpoint_kind,
        .local_sequence = 7,
        .membership_epoch = snapshot.topology.epoch,
        .writer_term = snapshot.writer_term,
        .generation = snapshot.generation,
        .set_id = snapshot.topology.set_id,
        .member_id = snapshot.topology.members[0].member_id,
        .mount_session_id = id(6),
        .transaction_id = id(7),
        .previous_record_digest = @splat(0x33),
        .previous_history_digest = snapshot.previous_authority_history_digest,
        .data_root_digest = snapshot.data_root_digest,
        .topology_digest = try pool_topology.digest(snapshot.topology),
        .layout_digest = try pool_layout.digest(snapshot.layout),
        .payload = try makePayload(snapshot),
    };
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

fn fixChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

test "authority checkpoint snapshot round trips canonically" {
    const snapshot = try testSnapshot();
    const bytes = try encode(snapshot);
    var expected_digest: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected_digest, "5a892f9839213bf82ce4f71b73a4cdf2f62f30c1d88b1cfe041167d26c1e4761");
    try std.testing.expectEqualSlices(u8, &expected_digest, &codec.blake3(&bytes));
    try std.testing.expectEqualSlices(u8, &magic, bytes[0x000..0x008]);
    try std.testing.expectEqual(format_version, codec.getInt(u16, &bytes, 0x008));
    try std.testing.expectEqual(administrative_recovery_flag, codec.getInt(u16, &bytes, 0x00a));
    try std.testing.expectEqual(@as(u32, encoded_size), codec.getInt(u32, &bytes, 0x00c));
    try std.testing.expectEqualSlices(u8, &snapshot.previous_authority_history_digest, bytes[0x010..0x030]);
    try std.testing.expectEqualSlices(u8, &snapshot.data_root_digest, bytes[0x030..0x050]);
    try std.testing.expectEqual(snapshot.writer_term, codec.getInt(u64, &bytes, 0x050));
    try std.testing.expectEqual(snapshot.generation, codec.getInt(u64, &bytes, 0x058));
    try std.testing.expectEqualSlices(u8, &(try pool_topology.encode(snapshot.topology)), bytes[topology_offset..layout_offset]);
    try std.testing.expectEqualSlices(u8, &(try pool_layout.encode(snapshot.layout)), bytes[layout_offset..reserved_offset]);
    try std.testing.expectEqual(snapshot, try decode(&bytes));
}

test "authority checkpoint record binds its predecessor configuration and publisher" {
    const snapshot = try testSnapshot();
    const record = try testRecord(snapshot);
    const context = testContext(snapshot);
    try std.testing.expectEqual(snapshot, try validateRecord(record, context));

    var changed = record;
    changed.previous_history_digest[0] ^= 1;
    changed.history_digest = try control_record.historyDigest(changed);
    try std.testing.expectError(error.PreviousAuthorityDigestMismatch, validateRecord(changed, context));
    changed = record;
    changed.membership_epoch += 1;
    changed.history_digest = try control_record.historyDigest(changed);
    try std.testing.expectError(error.MembershipEpochMismatch, validateRecord(changed, context));
    changed = record;
    changed.topology_digest[0] ^= 1;
    changed.history_digest = try control_record.historyDigest(changed);
    try std.testing.expectError(error.TopologyDigestMismatch, validateRecord(changed, context));
    changed = record;
    changed.layout_digest[0] ^= 1;
    changed.history_digest = try control_record.historyDigest(changed);
    try std.testing.expectError(error.LayoutDigestMismatch, validateRecord(changed, context));
    changed = record;
    changed.history_digest[0] ^= 1;
    try std.testing.expectError(error.HistoryDigestMismatch, validateRecord(changed, context));
    changed = record;
    changed.member_id = id(5);
    try std.testing.expectError(error.CheckpointPublisherIsNotVoter, validateRecord(changed, context));
    changed = record;
    changed.member_id = id(9);
    try std.testing.expectError(error.CheckpointPublisherNotInTopology, validateRecord(changed, context));
    changed = record;
    changed.kind = control_record.writer_fence_kind;
    changed.history_digest = try control_record.historyDigest(changed);
    try std.testing.expectError(error.NotCheckpointRecord, validateRecord(changed, context));
    changed = record;
    changed.payload.len -= 1;
    changed.payload.bytes[changed.payload.len] = 0;
    changed.history_digest = try control_record.historyDigest(changed);
    try std.testing.expectError(error.InvalidCheckpointPayloadLength, validateRecord(changed, context));
    var mismatched_context = context;
    mismatched_context.generation += 1;
    try std.testing.expectError(error.CheckpointAuthorityMismatch, validateRecord(record, mismatched_context));
}

test "authority checkpoint rejects framing padding and invalid context" {
    const snapshot = try testSnapshot();
    const canonical = try encode(snapshot);
    const cases = [_]struct { offset: usize, expected: anyerror }{
        .{ .offset = 0x000, .expected = error.InvalidMagic },
        .{ .offset = 0x008, .expected = error.UnsupportedFormatVersion },
        .{ .offset = 0x00a, .expected = error.UnsupportedFlags },
        .{ .offset = 0x00c, .expected = error.InvalidEncodedSize },
        .{ .offset = reserved_offset, .expected = error.NonZeroReserved },
    };
    for (cases) |case| {
        var bytes = canonical;
        bytes[case.offset] ^= 0x80;
        fixChecksum(&bytes);
        try std.testing.expectError(case.expected, decode(&bytes));
    }
    var corrupt = canonical;
    corrupt[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&corrupt));

    var invalid = snapshot;
    invalid.previous_authority_history_digest = @splat(0);
    try std.testing.expectError(error.InvalidPreviousAuthorityDigest, encode(invalid));
    invalid = snapshot;
    invalid.layout.topology_epoch = invalid.topology.epoch + 1;
    try std.testing.expectError(error.FutureTopologyEpoch, encode(invalid));
    invalid = snapshot;
    invalid.topology.members[3].state = .joining;
    try std.testing.expectError(error.UnsettledCheckpointTopology, encode(invalid));

    var record = try testRecord(snapshot);
    record.local_sequence = 0;
    try std.testing.expectError(error.InvalidLocalSequence, validateRecord(record, testContext(snapshot)));
    record = try testRecord(snapshot);
    record.payload.len -= 1;
    try std.testing.expectError(error.NonZeroOwnedPayloadPadding, validateRecord(record, testContext(snapshot)));
}
