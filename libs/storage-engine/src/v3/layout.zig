const std = @import("std");
const codec = @import("codec.zig");
const member_format = @import("member_format.zig");
const topology_format = @import("topology.zig");

pub const encoded_size: usize = 256;
pub const checksum_offset: usize = 0x0fc;
pub const replicated_kind: u16 = 1;
pub const replica_count: usize = 3;
pub const target_replicas: u16 = 3;
pub const durable_write_threshold: u16 = 2;
pub const read_threshold: u16 = 1;

const magic = [8]u8{ 'D', 'D', 'V', 'L', 'A', 'Y', '1', 0 };
const envelope_version: u16 = 1;
const reserved_offset: usize = 0x036;

pub const Layout = struct {
    kind: u16 = replicated_kind,
    layout_epoch: u64,
    topology_epoch: u64,
    chunk_size: u32,
    target_replicas: u16 = target_replicas,
    durable_write_threshold: u16 = durable_write_threshold,
    read_threshold: u16 = read_threshold,
    member_count: u16 = replica_count,
    flags: u32 = 0,
    member_slots: [replica_count]u16 = .{ 0, 1, 2 },
};

pub fn encode(layout: Layout) ![encoded_size]u8 {
    try checkKindPolicy(layout);
    try validate(layout);
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, envelope_version);
    codec.putInt(u16, &bytes, 0x00a, layout.kind);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    codec.putInt(u64, &bytes, 0x010, layout.layout_epoch);
    codec.putInt(u64, &bytes, 0x018, layout.topology_epoch);
    codec.putInt(u32, &bytes, 0x020, layout.chunk_size);
    codec.putInt(u16, &bytes, 0x024, layout.target_replicas);
    codec.putInt(u16, &bytes, 0x026, layout.durable_write_threshold);
    codec.putInt(u16, &bytes, 0x028, layout.read_threshold);
    codec.putInt(u16, &bytes, 0x02a, layout.member_count);
    codec.putInt(u32, &bytes, 0x02c, layout.flags);
    for (layout.member_slots, 0..) |slot, index|
        codec.putInt(u16, &bytes, 0x030 + index * @sizeOf(u16), slot);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(bytes: *const [encoded_size]u8) !Layout {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != envelope_version)
        return error.UnsupportedEnvelopeVersion;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size) return error.InvalidEncodedSize;
    if (!codec.isZero(bytes[reserved_offset..checksum_offset])) return error.NonZeroReserved;

    const layout: Layout = .{
        .kind = codec.getInt(u16, bytes, 0x00a),
        .layout_epoch = codec.getInt(u64, bytes, 0x010),
        .topology_epoch = codec.getInt(u64, bytes, 0x018),
        .chunk_size = codec.getInt(u32, bytes, 0x020),
        .target_replicas = codec.getInt(u16, bytes, 0x024),
        .durable_write_threshold = codec.getInt(u16, bytes, 0x026),
        .read_threshold = codec.getInt(u16, bytes, 0x028),
        .member_count = codec.getInt(u16, bytes, 0x02a),
        .flags = codec.getInt(u32, bytes, 0x02c),
        .member_slots = .{
            codec.getInt(u16, bytes, 0x030),
            codec.getInt(u16, bytes, 0x032),
            codec.getInt(u16, bytes, 0x034),
        },
    };
    try validateEnvelope(layout);
    if (layout.kind == replicated_kind) try validateReplica(layout);
    return layout;
}

pub fn digest(layout: Layout) !codec.Digest {
    const bytes = try encode(layout);
    return codec.blake3(bytes[0..checksum_offset]);
}

pub fn checkKindPolicy(layout: Layout) !void {
    if (layout.kind != replicated_kind) return error.UnsupportedLayoutKind;
}

pub fn validateAgainstTopology(layout: Layout, topology: topology_format.Topology) !void {
    try checkKindPolicy(layout);
    try validate(layout);
    if (layout.topology_epoch > topology.epoch) return error.FutureTopologyEpoch;
    for (layout.member_slots) |slot| {
        var found = false;
        for (topology.members) |member| {
            if (member.slot != slot) continue;
            found = true;
            if (member.control_role != topology_format.voter_role)
                return error.ReplicaIsNotVoter;
            if (member.role_flags & member_format.data_role == 0)
                return error.ReplicaHasNoDataRole;
            break;
        }
        if (!found) return error.ReplicaSlotNotInTopology;
    }
}

pub fn validateAgainstHeaders(layout: Layout, headers: []const member_format.Header) !void {
    if (headers.len != replica_count) return error.InvalidHeaderCount;
    try validateAgainstHeaderSubset(layout, headers);
}

pub fn validateAgainstHeaderSubset(layout: Layout, headers: []const member_format.Header) !void {
    try checkKindPolicy(layout);
    try validate(layout);
    if (headers.len == 0 or headers.len > replica_count) return error.InvalidHeaderCount;
    for (headers) |header| {
        if (header.chunk_size != layout.chunk_size) return error.ChunkSizeMismatch;
        if (header.layout_format_version != member_format.supported_layout_format_version)
            return error.UnsupportedLayoutFormat;
    }
}

fn validate(layout: Layout) !void {
    try validateEnvelope(layout);
    try validateReplica(layout);
}

fn validateEnvelope(layout: Layout) !void {
    if (layout.layout_epoch == 0) return error.InvalidLayoutEpoch;
    if (layout.topology_epoch == 0) return error.InvalidTopologyEpoch;
    if (layout.chunk_size == 0 or !std.math.isPowerOfTwo(layout.chunk_size))
        return error.InvalidChunkSize;
}

fn validateReplica(layout: Layout) !void {
    if (layout.target_replicas != target_replicas) return error.InvalidTargetReplicas;
    if (layout.durable_write_threshold != durable_write_threshold)
        return error.InvalidDurableWriteThreshold;
    if (layout.read_threshold != read_threshold) return error.InvalidReadThreshold;
    if (layout.member_count != replica_count) return error.InvalidMemberCount;
    if (layout.flags != 0) return error.InvalidLayoutFlags;

    var present: [replica_count]bool = @splat(false);
    for (layout.member_slots, 0..) |slot, index| {
        if (slot >= replica_count) return error.InvalidReplicaSlot;
        if (present[slot]) return error.DuplicateReplicaSlot;
        present[slot] = true;
        if (slot != index) return error.NonCanonicalReplicaSlots;
    }
    for (present) |is_present| if (!is_present) return error.MissingReplicaSlot;
}

fn testLayout() Layout {
    return .{
        .layout_epoch = 7,
        .topology_epoch = 3,
        .chunk_size = 1024 * 1024,
    };
}

fn testTopology() topology_format.Topology {
    return .{
        .set_id = @splat(1),
        .epoch = 3,
        .parent_digest = @splat(2),
        .members = .{
            .{ .member_id = @splat(3), .slot = 0 },
            .{ .member_id = @splat(4), .slot = 1 },
            .{ .member_id = @splat(5), .slot = 2 },
        },
    };
}

fn testHeader(slot: u16) !member_format.Header {
    var member_id: [16]u8 = @splat(0);
    member_id[0] = @intCast(slot + 1);
    return .{
        .header_sequence = 1,
        .set_id = @splat(9),
        .member_id = member_id,
        .member_slot = slot,
        .created_ns = 1,
        .member_bytes = 1,
        .logical_capacity = 1,
        .control = .{ .offset = 0, .length = 0 },
        .metadata = .{ .offset = 0, .length = 0 },
        .data = .{ .offset = 0, .length = 0 },
        .metadata_block_size = 1,
        .metadata_read_size = 1,
        .metadata_program_size = 1,
        .chunk_size = testLayout().chunk_size,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = 1,
        .control_record_format_version = 1,
        .label = try member_format.Label.init("layout-test"),
        .genesis_topology_digest = @splat(1),
    };
}

fn testHeaders() ![replica_count]member_format.Header {
    return .{ try testHeader(0), try testHeader(1), try testHeader(2) };
}

fn fixChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

fn readFixture() ![encoded_size]u8 {
    const fixture_text = @embedFile("../testdata/v3/replica-layout.hex");
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

test "exact offsets round trip and digest excludes checksum" {
    const layout = testLayout();
    const bytes = try encode(layout);
    try std.testing.expectEqualSlices(u8, &magic, bytes[0x000..0x008]);
    try std.testing.expectEqual(envelope_version, codec.getInt(u16, &bytes, 0x008));
    try std.testing.expectEqual(replicated_kind, codec.getInt(u16, &bytes, 0x00a));
    try std.testing.expectEqual(@as(u32, encoded_size), codec.getInt(u32, &bytes, 0x00c));
    try std.testing.expectEqual(layout.layout_epoch, codec.getInt(u64, &bytes, 0x010));
    try std.testing.expectEqual(layout.topology_epoch, codec.getInt(u64, &bytes, 0x018));
    try std.testing.expectEqual(layout.chunk_size, codec.getInt(u32, &bytes, 0x020));
    try std.testing.expectEqual(target_replicas, codec.getInt(u16, &bytes, 0x024));
    try std.testing.expectEqual(durable_write_threshold, codec.getInt(u16, &bytes, 0x026));
    try std.testing.expectEqual(read_threshold, codec.getInt(u16, &bytes, 0x028));
    try std.testing.expectEqual(@as(u16, replica_count), codec.getInt(u16, &bytes, 0x02a));
    try std.testing.expectEqual(@as(u32, 0), codec.getInt(u32, &bytes, 0x02c));
    for (0..replica_count) |slot|
        try std.testing.expectEqual(@as(u16, @intCast(slot)), codec.getInt(u16, &bytes, 0x030 + slot * 2));
    try std.testing.expect(codec.isZero(bytes[reserved_offset..checksum_offset]));
    try std.testing.expectEqual(codec.crc32c(bytes[0..checksum_offset]), codec.getInt(u32, &bytes, checksum_offset));
    try std.testing.expectEqualSlices(u8, &bytes, &(try encode(try decode(&bytes))));

    var alternate_crc = bytes;
    alternate_crc[checksum_offset] ^= 1;
    try std.testing.expectEqualSlices(
        u8,
        &codec.blake3(bytes[0..checksum_offset]),
        &codec.blake3(alternate_crc[0..checksum_offset]),
    );
}

test "golden fixture and layout fingerprint" {
    const canonical = try encode(testLayout());
    try std.testing.expectEqualSlices(u8, &(try readFixture()), &canonical);
    var expected: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected, "40d718657f7fc9ee67045f8d3658c0a246e509fa1ae0cd770cd8f81885ffdd19");
    try std.testing.expectEqualSlices(u8, &expected, &(try digest(testLayout())));
}

test "unknown kind is structurally decoded before policy rejection" {
    var bytes = try encode(testLayout());
    codec.putInt(u16, &bytes, 0x00a, 0x8001);
    fixChecksum(&bytes);
    const layout = try decode(&bytes);
    try std.testing.expectEqual(@as(u16, 0x8001), layout.kind);
    try std.testing.expectError(error.UnsupportedLayoutKind, checkKindPolicy(layout));
    try std.testing.expectError(error.UnsupportedLayoutKind, encode(layout));
}

test "framing checksum padding version and flags are rejected" {
    const canonical = try encode(testLayout());
    const cases = [_]struct { offset: usize, expected: anyerror }{
        .{ .offset = 0x000, .expected = error.InvalidMagic },
        .{ .offset = 0x008, .expected = error.UnsupportedEnvelopeVersion },
        .{ .offset = 0x00c, .expected = error.InvalidEncodedSize },
        .{ .offset = 0x02c, .expected = error.InvalidLayoutFlags },
        .{ .offset = reserved_offset, .expected = error.NonZeroReserved },
    };
    for (cases) |case| {
        var bytes = canonical;
        bytes[case.offset] ^= 1;
        fixChecksum(&bytes);
        try std.testing.expectError(case.expected, decode(&bytes));
    }
    var checksum_bad = canonical;
    checksum_bad[0x020] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&checksum_bad));
}

test "epochs chunk size thresholds and member count are validated" {
    var layout = testLayout();
    layout.layout_epoch = 0;
    try std.testing.expectError(error.InvalidLayoutEpoch, encode(layout));
    layout = testLayout();
    layout.topology_epoch = 0;
    try std.testing.expectError(error.InvalidTopologyEpoch, encode(layout));
    layout = testLayout();
    layout.chunk_size = 0;
    try std.testing.expectError(error.InvalidChunkSize, encode(layout));
    layout.chunk_size = 3;
    try std.testing.expectError(error.InvalidChunkSize, encode(layout));
    layout = testLayout();
    layout.target_replicas = 2;
    try std.testing.expectError(error.InvalidTargetReplicas, encode(layout));
    layout = testLayout();
    layout.durable_write_threshold = 1;
    try std.testing.expectError(error.InvalidDurableWriteThreshold, encode(layout));
    layout = testLayout();
    layout.read_threshold = 2;
    try std.testing.expectError(error.InvalidReadThreshold, encode(layout));
    layout = testLayout();
    layout.member_count = 2;
    try std.testing.expectError(error.InvalidMemberCount, encode(layout));
}

test "replica slots are complete unique and canonical" {
    var layout = testLayout();
    layout.member_slots = .{ 0, 1, 1 };
    try std.testing.expectError(error.DuplicateReplicaSlot, encode(layout));
    layout.member_slots = .{ 0, 1, 3 };
    try std.testing.expectError(error.InvalidReplicaSlot, encode(layout));
    layout.member_slots = .{ 1, 0, 2 };
    try std.testing.expectError(error.NonCanonicalReplicaSlots, encode(layout));
}

test "topology validation checks epoch slots voters and data roles" {
    const layout = testLayout();
    var topology = testTopology();
    try validateAgainstTopology(layout, topology);
    topology.epoch = 2;
    try std.testing.expectError(error.FutureTopologyEpoch, validateAgainstTopology(layout, topology));
    topology = testTopology();
    topology.members[2].slot = 4;
    try std.testing.expectError(error.ReplicaSlotNotInTopology, validateAgainstTopology(layout, topology));
    topology = testTopology();
    topology.members[1].control_role = 2;
    try std.testing.expectError(error.ReplicaIsNotVoter, validateAgainstTopology(layout, topology));
    topology = testTopology();
    topology.members[1].role_flags &= ~member_format.data_role;
    try std.testing.expectError(error.ReplicaHasNoDataRole, validateAgainstTopology(layout, topology));
}

test "header validation checks count chunk size and layout policy only" {
    const layout = testLayout();
    var headers = try testHeaders();
    try validateAgainstHeaders(layout, &headers);
    try std.testing.expectError(error.InvalidHeaderCount, validateAgainstHeaders(layout, headers[0..2]));
    try validateAgainstHeaderSubset(layout, headers[0..2]);
    try std.testing.expectError(error.InvalidHeaderCount, validateAgainstHeaderSubset(layout, headers[0..0]));
    headers[1].chunk_size /= 2;
    try std.testing.expectError(error.ChunkSizeMismatch, validateAgainstHeaders(layout, &headers));
    headers = try testHeaders();
    headers[2].layout_format_version = 2;
    try std.testing.expectError(error.UnsupportedLayoutFormat, validateAgainstHeaders(layout, &headers));

    headers = try testHeaders();
    headers[1].set_id = @splat(0xff);
    headers[1].genesis_topology_digest = @splat(0);
    try validateAgainstHeaders(layout, &headers);
}

test "all single byte mutations are detected without checksum repair" {
    const canonical = try encode(testLayout());
    for (0..encoded_size) |offset| {
        var mutated = canonical;
        mutated[offset] ^= 0x80;
        try std.testing.expectError(error.ChecksumMismatch, decode(&mutated));
    }
}
