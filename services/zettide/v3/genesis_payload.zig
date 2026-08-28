const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const layout_format = @import("layout.zig");
const member_format = @import("member_format.zig");
const topology_format = @import("topology.zig");

pub const encoded_size: usize = 1024;
pub const checksum_offset: usize = 0x3fc;
pub const topology_offset: usize = 0x020;
pub const layout_offset: usize = 0x220;

const magic = [8]u8{ 'D', 'D', 'V', 'G', 'E', 'N', '1', 0 };
const format_version: u16 = 1;
const reserved_offset: usize = 0x320;

comptime {
    std.debug.assert(topology_offset + topology_format.encoded_size == layout_offset);
    std.debug.assert(layout_offset + layout_format.encoded_size == reserved_offset);
    std.debug.assert(checksum_offset + @sizeOf(u32) == encoded_size);
}

pub const GenesisPayload = struct {
    topology: topology_format.Topology,
    layout: layout_format.Layout,
};

pub fn encode(payload: GenesisPayload) ![encoded_size]u8 {
    try validate(payload);
    const topology_bytes = try topology_format.encode(payload.topology);
    const layout_bytes = try layout_format.encode(payload.layout);

    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, 0);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    codec.putInt(u32, &bytes, 0x010, topology_format.encoded_size);
    codec.putInt(u32, &bytes, 0x014, layout_format.encoded_size);
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
        codec.getInt(u32, bytes, 0x010) != topology_format.encoded_size or
        codec.getInt(u32, bytes, 0x014) != layout_format.encoded_size) return error.InvalidFraming;
    if (!codec.isZero(bytes[0x018..topology_offset]) or
        !codec.isZero(bytes[reserved_offset..checksum_offset])) return error.NonZeroReserved;

    const topology_bytes: *const [topology_format.encoded_size]u8 = bytes[topology_offset..layout_offset];
    const layout_bytes: *const [layout_format.encoded_size]u8 = bytes[layout_offset..reserved_offset];
    const payload: GenesisPayload = .{
        .topology = try topology_format.decode(topology_bytes),
        .layout = try layout_format.decode(layout_bytes),
    };
    try validate(payload);
    return payload;
}

pub fn digest(payload: GenesisPayload) !codec.Digest {
    const bytes = try encode(payload);
    return codec.blake3(bytes[0..checksum_offset]);
}

pub fn makeRecord(member_id: [16]u8, payload: GenesisPayload) !control_record.Record {
    try validateMember(payload, member_id);
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
        .topology_digest = try topology_format.digest(payload.topology),
        .layout_digest = try layout_format.digest(payload.layout),
        .payload = try control_record.Payload.init(&payload_bytes),
    };
    record.history_digest = try control_record.historyDigest(record);
    try control_record.validatePolicy(record);
    return record;
}

pub fn validateRecord(record: control_record.Record) !GenesisPayload {
    try control_record.validatePolicy(record);
    if (!std.mem.eql(u8, &record.history_digest, &(try control_record.historyDigest(record))))
        return error.HistoryDigestMismatch;
    if (record.kind != control_record.genesis_kind) return error.NotGenesisRecord;
    const payload = try decode(record.payload.slice());
    try validateMember(payload, record.member_id);
    if (!std.mem.eql(u8, &record.set_id, &payload.topology.set_id)) return error.GenesisSetIdMismatch;
    if (!std.mem.eql(u8, &record.topology_digest, &(try topology_format.digest(payload.topology))))
        return error.GenesisTopologyDigestMismatch;
    if (!std.mem.eql(u8, &record.layout_digest, &(try layout_format.digest(payload.layout))))
        return error.GenesisLayoutDigestMismatch;
    return payload;
}

fn validate(payload: GenesisPayload) !void {
    _ = try topology_format.encode(payload.topology);
    if (payload.topology.epoch != 1 or !codec.isZero(&payload.topology.parent_digest))
        return error.InvalidGenesisTopology;
    try layout_format.checkKindPolicy(payload.layout);
    if (payload.layout.layout_epoch != 1 or payload.layout.topology_epoch != 1)
        return error.InvalidGenesisLayout;
    try layout_format.validateAgainstTopology(payload.layout, payload.topology);
}

fn validateMember(payload: GenesisPayload, member_id: [16]u8) !void {
    try validate(payload);
    for (payload.topology.members) |member| {
        if (!std.mem.eql(u8, &member.member_id, &member_id)) continue;
        if (member.control_role != topology_format.voter_role or
            member.role_flags & member_format.data_role == 0) return error.InvalidGenesisMemberRole;
        return;
    }
    return error.GenesisMemberNotFound;
}

fn testPayload() GenesisPayload {
    return .{
        .topology = .{
            .set_id = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff },
            .epoch = 1,
            .parent_digest = @splat(0),
            .members = .{
                .{ .member_id = .{ 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f }, .slot = 2 },
                .{ .member_id = .{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f }, .slot = 0 },
                .{ .member_id = .{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f }, .slot = 1 },
            },
        },
        .layout = .{ .layout_epoch = 1, .topology_epoch = 1, .chunk_size = 1024 * 1024 },
    };
}

fn fixChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

fn readFixture() ![encoded_size]u8 {
    const fixture_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fixtures/v3/genesis-payload.hex",
        std.testing.allocator,
        .limited(8192),
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

test "exact offsets round trip and owned payload" {
    const payload = testPayload();
    var bytes = try encode(payload);
    try std.testing.expectEqualSlices(u8, &magic, bytes[0x000..0x008]);
    try std.testing.expectEqual(format_version, codec.getInt(u16, &bytes, 0x008));
    try std.testing.expectEqual(@as(u16, 0), codec.getInt(u16, &bytes, 0x00a));
    try std.testing.expectEqual(@as(u32, encoded_size), codec.getInt(u32, &bytes, 0x00c));
    try std.testing.expectEqual(@as(u32, topology_format.encoded_size), codec.getInt(u32, &bytes, 0x010));
    try std.testing.expectEqual(@as(u32, layout_format.encoded_size), codec.getInt(u32, &bytes, 0x014));
    try std.testing.expect(codec.isZero(bytes[0x018..topology_offset]));
    try std.testing.expectEqualSlices(u8, &(try topology_format.encode(payload.topology)), bytes[topology_offset..layout_offset]);
    try std.testing.expectEqualSlices(u8, &(try layout_format.encode(payload.layout)), bytes[layout_offset..reserved_offset]);
    try std.testing.expect(codec.isZero(bytes[reserved_offset..checksum_offset]));
    try std.testing.expectEqual(codec.crc32c(bytes[0..checksum_offset]), codec.getInt(u32, &bytes, checksum_offset));
    const decoded = try decode(&bytes);
    bytes[topology_offset + 0x010] ^= 1;
    try std.testing.expectEqualSlices(u8, &(try encode(payload)), &(try encode(decoded)));
}

test "golden fixture and payload fingerprint" {
    const canonical = try encode(testPayload());
    try std.testing.expectEqualSlices(u8, &(try readFixture()), &canonical);
    var expected: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected, "e8102b500fbc4f4685e9bb6460817ff3905d70889fbdfc8e4e8cc8e0cc5790a2");
    try std.testing.expectEqualSlices(u8, &expected, &(try digest(testPayload())));
}

test "framing checksum padding and exact length are rejected" {
    const canonical = try encode(testPayload());
    const cases = [_]struct { offset: usize, expected: anyerror }{
        .{ .offset = 0x000, .expected = error.InvalidMagic },
        .{ .offset = 0x008, .expected = error.UnsupportedFormatVersion },
        .{ .offset = 0x00a, .expected = error.InvalidFlags },
        .{ .offset = 0x00c, .expected = error.InvalidFraming },
        .{ .offset = 0x010, .expected = error.InvalidFraming },
        .{ .offset = 0x014, .expected = error.InvalidFraming },
        .{ .offset = 0x018, .expected = error.NonZeroReserved },
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
    try std.testing.expectError(error.InvalidGenesisPayloadLength, decode(canonical[0 .. encoded_size - 1]));
    var trailing: [encoded_size + 1]u8 = @splat(0);
    @memcpy(trailing[0..encoded_size], &canonical);
    try std.testing.expectError(error.InvalidGenesisPayloadLength, decode(&trailing));
}

test "genesis epochs and layout kind are enforced" {
    var payload = testPayload();
    payload.topology.epoch = 2;
    payload.topology.parent_digest = @splat(1);
    try std.testing.expectError(error.InvalidGenesisTopology, encode(payload));
    payload = testPayload();
    payload.layout.layout_epoch = 2;
    try std.testing.expectError(error.InvalidGenesisLayout, encode(payload));
    payload = testPayload();
    payload.layout.topology_epoch = 2;
    try std.testing.expectError(error.InvalidGenesisLayout, encode(payload));
    payload = testPayload();
    payload.layout.kind = 0x8001;
    try std.testing.expectError(error.UnsupportedLayoutKind, encode(payload));

    var bytes = try encode(testPayload());
    codec.putInt(u16, &bytes, layout_offset + 0x00a, 0x8001);
    codec.putInt(
        u32,
        &bytes,
        layout_offset + layout_format.checksum_offset,
        codec.crc32c(bytes[layout_offset .. layout_offset + layout_format.checksum_offset]),
    );
    fixChecksum(&bytes);
    try std.testing.expectError(error.UnsupportedLayoutKind, decode(&bytes));
}

test "record identity membership digests and payload length are validated" {
    const payload = testPayload();
    const member_id = payload.topology.members[0].member_id;
    const base = try makeRecord(member_id, payload);
    _ = try validateRecord(base);

    try std.testing.expectError(error.GenesisMemberNotFound, makeRecord(@splat(0x99), payload));
    var record = base;
    record.history_digest[0] ^= 1;
    try std.testing.expectError(error.HistoryDigestMismatch, validateRecord(record));
    record = base;
    record.set_id[0] ^= 1;
    record.history_digest = try control_record.historyDigest(record);
    try std.testing.expectError(error.GenesisSetIdMismatch, validateRecord(record));
    record = base;
    record.member_id = @splat(0x99);
    try std.testing.expectError(error.GenesisMemberNotFound, validateRecord(record));
    record = base;
    record.topology_digest[0] ^= 1;
    record.history_digest = try control_record.historyDigest(record);
    try std.testing.expectError(error.GenesisTopologyDigestMismatch, validateRecord(record));
    record = base;
    record.layout_digest[0] ^= 1;
    record.history_digest = try control_record.historyDigest(record);
    try std.testing.expectError(error.GenesisLayoutDigestMismatch, validateRecord(record));
    record = base;
    record.payload = try control_record.Payload.init(record.payload.slice()[0 .. encoded_size - 1]);
    record.history_digest = try control_record.historyDigest(record);
    try std.testing.expectError(error.InvalidGenesisPayloadLength, validateRecord(record));
}

test "three member records share history and have distinct record digests" {
    const payload = testPayload();
    var records: [topology_format.member_count]control_record.Record = undefined;
    var record_digests: [topology_format.member_count]codec.Digest = undefined;
    for (payload.topology.members, 0..) |member, index| {
        records[index] = try makeRecord(member.member_id, payload);
        const bytes = try control_record.encode(records[index]);
        record_digests[index] = control_record.recordDigest(&bytes);
    }
    try std.testing.expectEqualSlices(u8, &records[0].history_digest, &records[1].history_digest);
    try std.testing.expectEqualSlices(u8, &records[0].history_digest, &records[2].history_digest);
    try std.testing.expect(!std.mem.eql(u8, &record_digests[0], &record_digests[1]));
    try std.testing.expect(!std.mem.eql(u8, &record_digests[0], &record_digests[2]));
    try std.testing.expect(!std.mem.eql(u8, &record_digests[1], &record_digests[2]));
}

test "every single byte mutation fails checksum without panic" {
    const canonical = try encode(testPayload());
    for (0..encoded_size) |offset| {
        var mutated = canonical;
        mutated[offset] ^= 0x80;
        try std.testing.expectError(error.ChecksumMismatch, decode(&mutated));
    }
}
