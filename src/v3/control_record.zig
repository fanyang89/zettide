const std = @import("std");
const codec = @import("codec.zig");
const topology_format = @import("topology.zig");

pub const encoded_size: usize = 4096;
pub const header_size: usize = 320;
pub const payload_capacity: usize = 3752;
pub const payload_offset: usize = 0x140;
pub const footer_offset: usize = 0xfe8;
pub const checksum_offset: usize = 0xffc;

pub const genesis_kind: u16 = 1;
pub const writer_fence_kind: u16 = 2;
pub const generation_prepare_kind: u16 = 3;
pub const generation_commit_kind: u16 = 4;
pub const membership_prepare_kind: u16 = 5;
pub const membership_commit_kind: u16 = 6;
pub const mount_dirty_kind: u16 = 7;
pub const clean_shutdown_kind: u16 = 8;
pub const checkpoint_kind: u16 = 9;
pub const member_bootstrap_kind: u16 = 10;

pub const certificate_size: usize = 192;
pub const certificate_checksum_offset: usize = 0xbc;

const magic = [8]u8{ 'D', 'D', 'V', 'C', 'T', 'L', '1', 0 };
const envelope_version: u16 = 1;
const footer_magic = [4]u8{ 'C', 'T', 'L', '!' };
const certificate_magic = [8]u8{ 'D', 'D', 'V', 'C', 'E', 'R', 'T', '1' };
const certificate_version: u16 = 1;
const attestation_count: u16 = 2;
const history_domain = [16]u8{ 'D', 'D', 'V', 'C', 'T', 'L', '1', '-', 'H', 'I', 'S', 'T', 'O', 'R', 'Y', 0 };

comptime {
    std.debug.assert(header_size == payload_offset);
    std.debug.assert(payload_offset + payload_capacity == footer_offset);
    std.debug.assert(footer_offset + 20 == checksum_offset);
    std.debug.assert(checksum_offset + @sizeOf(u32) == encoded_size);
    std.debug.assert(0x10 + 80 == 0x60);
    std.debug.assert(0x60 + 80 == 0xb0);
    std.debug.assert(0xb0 + 12 == certificate_checksum_offset);
    std.debug.assert(certificate_checksum_offset + @sizeOf(u32) == certificate_size);
}

pub const Payload = struct {
    bytes: [payload_capacity]u8 = @splat(0),
    len: u32 = 0,

    pub fn init(input: []const u8) !Payload {
        if (input.len > payload_capacity) return error.PayloadTooLarge;
        var payload: Payload = .{};
        @memcpy(payload.bytes[0..input.len], input);
        payload.len = @intCast(input.len);
        return payload;
    }

    pub fn slice(self: *const Payload) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Record = struct {
    kind: u16,
    local_sequence: u64,
    membership_epoch: u64,
    writer_term: u64,
    generation: u64,
    set_id: [16]u8,
    member_id: [16]u8,
    mount_session_id: [16]u8,
    transaction_id: [16]u8,
    previous_record_digest: codec.Digest,
    previous_history_digest: codec.Digest,
    history_digest: codec.Digest = @splat(0),
    data_root_digest: codec.Digest,
    topology_digest: codec.Digest,
    layout_digest: codec.Digest,
    payload: Payload = .{},
};

pub const Attestation = struct {
    member_id: [16]u8,
    prepare_record_digest: codec.Digest,
    prepare_history_digest: codec.Digest,
};

pub const CommitCertificate = struct {
    attestations: [attestation_count]Attestation,
};

pub fn encode(record: Record) ![encoded_size]u8 {
    try validatePolicy(record);
    return encodeValidated(record);
}

pub fn encodeDynamicPool(record: Record) ![encoded_size]u8 {
    try validateDynamicPoolPolicy(record);
    return encodeValidated(record);
}

fn encodeValidated(record: Record) ![encoded_size]u8 {
    if (!std.mem.eql(u8, &record.history_digest, &(try historyDigest(record))))
        return error.HistoryDigestMismatch;

    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, envelope_version);
    codec.putInt(u16, &bytes, 0x00a, record.kind);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    codec.putInt(u16, &bytes, 0x010, header_size);
    codec.putInt(u16, &bytes, 0x012, 0);
    codec.putInt(u32, &bytes, 0x014, record.payload.len);
    codec.putInt(u64, &bytes, 0x018, record.local_sequence);
    codec.putInt(u64, &bytes, 0x020, record.membership_epoch);
    codec.putInt(u64, &bytes, 0x028, record.writer_term);
    codec.putInt(u64, &bytes, 0x030, record.generation);
    @memcpy(bytes[0x038..0x048], &record.set_id);
    @memcpy(bytes[0x048..0x058], &record.member_id);
    @memcpy(bytes[0x058..0x068], &record.mount_session_id);
    @memcpy(bytes[0x068..0x078], &record.transaction_id);
    @memcpy(bytes[0x078..0x098], &record.previous_record_digest);
    @memcpy(bytes[0x098..0x0b8], &record.previous_history_digest);
    @memcpy(bytes[0x0b8..0x0d8], &record.history_digest);
    @memcpy(bytes[0x0d8..0x0f8], &record.data_root_digest);
    @memcpy(bytes[0x0f8..0x118], &record.topology_digest);
    @memcpy(bytes[0x118..0x138], &record.layout_digest);
    @memcpy(bytes[payload_offset..][0..record.payload.len], record.payload.slice());
    codec.putInt(u64, &bytes, 0xfe8, record.local_sequence);
    codec.putInt(u16, &bytes, 0xff0, record.kind);
    codec.putInt(u16, &bytes, 0xff2, 0);
    codec.putInt(u32, &bytes, 0xff4, record.payload.len);
    @memcpy(bytes[0xff8..0xffc], &footer_magic);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(bytes: *const [encoded_size]u8) !Record {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != envelope_version) return error.UnsupportedEnvelopeVersion;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size) return error.InvalidEncodedSize;
    if (codec.getInt(u16, bytes, 0x010) != header_size) return error.InvalidHeaderSize;
    if (codec.getInt(u16, bytes, 0x012) != 0) return error.InvalidHeaderFlags;
    if (!codec.isZero(bytes[0x138..payload_offset])) return error.NonZeroHeaderReserved;

    const payload_len = codec.getInt(u32, bytes, 0x014);
    if (payload_len > payload_capacity) return error.PayloadTooLarge;
    const kind = codec.getInt(u16, bytes, 0x00a);
    const local_sequence = codec.getInt(u64, bytes, 0x018);
    if (codec.getInt(u64, bytes, 0xfe8) != local_sequence or
        codec.getInt(u16, bytes, 0xff0) != kind or
        codec.getInt(u32, bytes, 0xff4) != payload_len) return error.FooterMismatch;
    if (codec.getInt(u16, bytes, 0xff2) != 0) return error.InvalidFooterFlags;
    if (!std.mem.eql(u8, bytes[0xff8..0xffc], &footer_magic)) return error.InvalidFooterMagic;
    if (!codec.isZero(bytes[payload_offset + payload_len .. footer_offset])) return error.NonZeroPayloadPadding;

    const record: Record = .{
        .kind = kind,
        .local_sequence = local_sequence,
        .membership_epoch = codec.getInt(u64, bytes, 0x020),
        .writer_term = codec.getInt(u64, bytes, 0x028),
        .generation = codec.getInt(u64, bytes, 0x030),
        .set_id = bytes[0x038..0x048].*,
        .member_id = bytes[0x048..0x058].*,
        .mount_session_id = bytes[0x058..0x068].*,
        .transaction_id = bytes[0x068..0x078].*,
        .previous_record_digest = bytes[0x078..0x098].*,
        .previous_history_digest = bytes[0x098..0x0b8].*,
        .history_digest = bytes[0x0b8..0x0d8].*,
        .data_root_digest = bytes[0x0d8..0x0f8].*,
        .topology_digest = bytes[0x0f8..0x118].*,
        .layout_digest = bytes[0x118..0x138].*,
        .payload = try Payload.init(bytes[payload_offset..][0..payload_len]),
    };
    try validateStructural(record);
    if (!std.mem.eql(u8, &record.history_digest, &(try historyDigest(record))))
        return error.HistoryDigestMismatch;
    return record;
}

pub fn recordDigest(bytes: *const [encoded_size]u8) codec.Digest {
    return codec.blake3(bytes[0..checksum_offset]);
}

pub fn historyDigest(record: Record) !codec.Digest {
    if (record.payload.len > payload_capacity) return error.PayloadTooLarge;
    if (!codec.isZero(record.payload.bytes[record.payload.len..])) return error.NonZeroOwnedPayloadPadding;
    var preimage: [history_domain.len + 206 + payload_capacity]u8 = @splat(0);
    var offset: usize = 0;
    append(&preimage, &offset, &history_domain);
    putHistoryInt(u16, &preimage, &offset, record.kind);
    append(&preimage, &offset, &record.set_id);
    putHistoryInt(u64, &preimage, &offset, record.membership_epoch);
    putHistoryInt(u64, &preimage, &offset, record.writer_term);
    putHistoryInt(u64, &preimage, &offset, record.generation);
    append(&preimage, &offset, &record.mount_session_id);
    append(&preimage, &offset, &record.transaction_id);
    append(&preimage, &offset, &record.previous_history_digest);
    append(&preimage, &offset, &record.data_root_digest);
    append(&preimage, &offset, &record.topology_digest);
    append(&preimage, &offset, &record.layout_digest);
    putHistoryInt(u32, &preimage, &offset, record.payload.len);
    append(&preimage, &offset, record.payload.slice());
    return codec.blake3(preimage[0..offset]);
}

pub fn checkKindPolicy(record: Record) !void {
    switch (record.kind) {
        genesis_kind, writer_fence_kind, generation_prepare_kind, generation_commit_kind, membership_prepare_kind, membership_commit_kind, mount_dirty_kind, clean_shutdown_kind, checkpoint_kind => {},
        else => return error.UnsupportedRecordKind,
    }
}

pub fn validatePolicy(record: Record) !void {
    try checkKindPolicy(record);
    try validateStructural(record);
    if (record.kind == genesis_kind) {
        if (record.membership_epoch != 1 or record.local_sequence != 1 or
            record.writer_term != 0 or record.generation != 0 or
            !codec.isZero(&record.mount_session_id) or !codec.isZero(&record.transaction_id) or
            !codec.isZero(&record.previous_history_digest) or !codec.isZero(&record.data_root_digest))
            return error.InvalidGenesisRecord;
    } else if (codec.isZero(&record.previous_history_digest)) {
        return error.InvalidPreviousHistoryDigest;
    }
    if (record.kind == generation_prepare_kind or record.kind == generation_commit_kind) {
        if (record.writer_term == 0 or record.generation == 0 or
            codec.isZero(&record.mount_session_id) or codec.isZero(&record.transaction_id) or
            codec.isZero(&record.data_root_digest)) return error.InvalidGenerationRecord;
    }
    if (record.kind == generation_commit_kind) {
        if (record.payload.len != certificate_size) return error.InvalidCertificatePayloadLength;
        var bytes: [certificate_size]u8 = undefined;
        @memcpy(&bytes, record.payload.slice());
        _ = try decodeCertificate(&bytes);
    }
}

pub fn validateDynamicPoolPolicy(record: Record) !void {
    if (record.kind == member_bootstrap_kind) {
        try validateStructural(record);
        if (codec.isZero(&record.previous_history_digest) or
            codec.isZero(&record.transaction_id) or !codec.isZero(&record.mount_session_id) or
            record.payload.len == 0) return error.InvalidMemberBootstrapRecord;
        return;
    }
    if (record.kind == generation_commit_kind) {
        try validateStructural(record);
        if (codec.isZero(&record.previous_history_digest) or record.writer_term == 0 or
            record.generation == 0 or codec.isZero(&record.mount_session_id) or
            codec.isZero(&record.transaction_id) or codec.isZero(&record.data_root_digest))
            return error.InvalidGenerationRecord;
        if (record.payload.len != certificate_size) return error.InvalidCertificatePayloadLength;
        return;
    }
    return validatePolicy(record);
}

fn validateStructural(record: Record) !void {
    if (record.payload.len > payload_capacity) return error.PayloadTooLarge;
    if (!codec.isZero(record.payload.bytes[record.payload.len..])) return error.NonZeroOwnedPayloadPadding;
    if (record.local_sequence == 0) return error.InvalidLocalSequence;
    if (record.membership_epoch == 0) return error.InvalidMembershipEpoch;
    if (codec.isZero(&record.set_id) or codec.isZero(&record.member_id) or
        std.mem.eql(u8, &record.set_id, &record.member_id)) return error.InvalidIdentity;
    if (codec.isZero(&record.topology_digest)) return error.InvalidTopologyDigest;
    if (codec.isZero(&record.layout_digest)) return error.InvalidLayoutDigest;
    if ((record.local_sequence == 1) != codec.isZero(&record.previous_record_digest))
        return error.InvalidPreviousRecordDigest;
}

pub fn encodeCertificate(certificate_input: CommitCertificate) ![certificate_size]u8 {
    try validateCertificate(certificate_input);
    var certificate = certificate_input;
    if (std.mem.order(u8, &certificate.attestations[0].member_id, &certificate.attestations[1].member_id) == .gt)
        std.mem.swap(Attestation, &certificate.attestations[0], &certificate.attestations[1]);
    var bytes: [certificate_size]u8 = @splat(0);
    @memcpy(bytes[0x00..0x08], &certificate_magic);
    codec.putInt(u16, &bytes, 0x08, certificate_version);
    codec.putInt(u16, &bytes, 0x0a, attestation_count);
    codec.putInt(u32, &bytes, 0x0c, 0);
    putAttestation(&bytes, 0x10, certificate.attestations[0]);
    putAttestation(&bytes, 0x60, certificate.attestations[1]);
    codec.putInt(u32, &bytes, certificate_checksum_offset, codec.crc32c(bytes[0..certificate_checksum_offset]));
    return bytes;
}

pub fn decodeCertificate(bytes: *const [certificate_size]u8) !CommitCertificate {
    if (codec.getInt(u32, bytes, certificate_checksum_offset) != codec.crc32c(bytes[0..certificate_checksum_offset]))
        return error.CertificateChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x00..0x08], &certificate_magic)) return error.InvalidCertificateMagic;
    if (codec.getInt(u16, bytes, 0x08) != certificate_version) return error.UnsupportedCertificateVersion;
    if (codec.getInt(u16, bytes, 0x0a) != attestation_count) return error.InvalidAttestationCount;
    if (codec.getInt(u32, bytes, 0x0c) != 0) return error.InvalidCertificateFlags;
    if (!codec.isZero(bytes[0xb0..certificate_checksum_offset])) return error.NonZeroCertificateReserved;
    const certificate: CommitCertificate = .{ .attestations = .{
        getAttestation(bytes, 0x10),
        getAttestation(bytes, 0x60),
    } };
    try validateCertificate(certificate);
    if (std.mem.order(u8, &certificate.attestations[0].member_id, &certificate.attestations[1].member_id) != .lt)
        return error.NonCanonicalAttestationOrder;
    return certificate;
}

pub fn certificateDigest(bytes: *const [certificate_size]u8) codec.Digest {
    return codec.blake3(bytes[0..certificate_checksum_offset]);
}

pub fn validateAgainstTopology(
    certificate: CommitCertificate,
    topology: topology_format.Topology,
) !void {
    try validateCertificate(certificate);
    for (certificate.attestations) |attestation| {
        var found = false;
        for (topology.members) |member| {
            if (!std.mem.eql(u8, &member.member_id, &attestation.member_id)) continue;
            found = true;
            if (member.control_role != topology_format.voter_role) return error.CertificateMemberIsNotVoter;
            break;
        }
        if (!found) return error.CertificateMemberNotInTopology;
    }
}

fn validateCertificate(certificate: CommitCertificate) !void {
    const a = certificate.attestations[0];
    const b = certificate.attestations[1];
    for (certificate.attestations) |attestation| {
        if (codec.isZero(&attestation.member_id)) return error.InvalidCertificateMemberId;
        if (codec.isZero(&attestation.prepare_record_digest)) return error.InvalidPrepareRecordDigest;
        if (codec.isZero(&attestation.prepare_history_digest)) return error.InvalidPrepareHistoryDigest;
    }
    if (std.mem.eql(u8, &a.member_id, &b.member_id)) return error.DuplicateCertificateMember;
    if (!std.mem.eql(u8, &a.prepare_history_digest, &b.prepare_history_digest))
        return error.PrepareHistoryDigestMismatch;
}

fn append(bytes: []u8, offset: *usize, value: []const u8) void {
    @memcpy(bytes[offset.*..][0..value.len], value);
    offset.* += value.len;
}

fn putHistoryInt(comptime T: type, bytes: []u8, offset: *usize, value: T) void {
    codec.putInt(T, bytes, offset.*, value);
    offset.* += @sizeOf(T);
}

fn putAttestation(bytes: []u8, offset: usize, attestation: Attestation) void {
    @memcpy(bytes[offset..][0..16], &attestation.member_id);
    @memcpy(bytes[offset + 16 ..][0..32], &attestation.prepare_record_digest);
    @memcpy(bytes[offset + 48 ..][0..32], &attestation.prepare_history_digest);
}

fn getAttestation(bytes: []const u8, offset: usize) Attestation {
    return .{
        .member_id = bytes[offset..][0..16].*,
        .prepare_record_digest = bytes[offset + 16 ..][0..32].*,
        .prepare_history_digest = bytes[offset + 48 ..][0..32].*,
    };
}

fn testCertificate() CommitCertificate {
    return .{ .attestations = .{
        .{ .member_id = @splat(0x22), .prepare_record_digest = @splat(0x44), .prepare_history_digest = @splat(0x66) },
        .{ .member_id = @splat(0x11), .prepare_record_digest = @splat(0x33), .prepare_history_digest = @splat(0x66) },
    } };
}

fn testRecord(kind: u16) !Record {
    var record: Record = .{
        .kind = kind,
        .local_sequence = 7,
        .membership_epoch = 3,
        .writer_term = 9,
        .generation = 11,
        .set_id = @splat(0x10),
        .member_id = @splat(0x20),
        .mount_session_id = @splat(0x30),
        .transaction_id = @splat(0x40),
        .previous_record_digest = @splat(0x50),
        .previous_history_digest = @splat(0x60),
        .data_root_digest = @splat(0x70),
        .topology_digest = @splat(0x80),
        .layout_digest = @splat(0x90),
        .payload = try Payload.init("opaque prepare payload"),
    };
    record.history_digest = try historyDigest(record);
    return record;
}

fn testCommitRecord() !Record {
    var record = try testRecord(generation_commit_kind);
    record.payload = try Payload.init(&(try encodeCertificate(testCertificate())));
    record.history_digest = try historyDigest(record);
    return record;
}

fn fixRecordChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

fn fixCertificateChecksum(bytes: *[certificate_size]u8) void {
    codec.putInt(u32, bytes, certificate_checksum_offset, codec.crc32c(bytes[0..certificate_checksum_offset]));
}

fn readFixture(comptime size: usize, path: []const u8) ![size]u8 {
    const fixture_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(32768));
    defer std.testing.allocator.free(fixture_text);
    var fixture: [size]u8 = @splat(0);
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

test "record exact offsets round trip and owned payload" {
    const record = try testRecord(generation_prepare_kind);
    var bytes = try encode(record);
    try std.testing.expectEqualSlices(u8, &magic, bytes[0x000..0x008]);
    try std.testing.expectEqual(envelope_version, codec.getInt(u16, &bytes, 0x008));
    try std.testing.expectEqual(record.kind, codec.getInt(u16, &bytes, 0x00a));
    try std.testing.expectEqual(@as(u32, encoded_size), codec.getInt(u32, &bytes, 0x00c));
    try std.testing.expectEqual(@as(u16, header_size), codec.getInt(u16, &bytes, 0x010));
    try std.testing.expectEqual(@as(u16, 0), codec.getInt(u16, &bytes, 0x012));
    try std.testing.expectEqual(record.payload.len, codec.getInt(u32, &bytes, 0x014));
    try std.testing.expectEqual(record.local_sequence, codec.getInt(u64, &bytes, 0x018));
    try std.testing.expectEqual(record.membership_epoch, codec.getInt(u64, &bytes, 0x020));
    try std.testing.expectEqual(record.writer_term, codec.getInt(u64, &bytes, 0x028));
    try std.testing.expectEqual(record.generation, codec.getInt(u64, &bytes, 0x030));
    try std.testing.expectEqualSlices(u8, &record.set_id, bytes[0x038..0x048]);
    try std.testing.expectEqualSlices(u8, &record.member_id, bytes[0x048..0x058]);
    try std.testing.expectEqualSlices(u8, &record.mount_session_id, bytes[0x058..0x068]);
    try std.testing.expectEqualSlices(u8, &record.transaction_id, bytes[0x068..0x078]);
    try std.testing.expectEqualSlices(u8, &record.previous_record_digest, bytes[0x078..0x098]);
    try std.testing.expectEqualSlices(u8, &record.previous_history_digest, bytes[0x098..0x0b8]);
    try std.testing.expectEqualSlices(u8, &record.history_digest, bytes[0x0b8..0x0d8]);
    try std.testing.expectEqualSlices(u8, &record.data_root_digest, bytes[0x0d8..0x0f8]);
    try std.testing.expectEqualSlices(u8, &record.topology_digest, bytes[0x0f8..0x118]);
    try std.testing.expectEqualSlices(u8, &record.layout_digest, bytes[0x118..0x138]);
    try std.testing.expect(codec.isZero(bytes[0x138..payload_offset]));
    try std.testing.expectEqualSlices(u8, record.payload.slice(), bytes[payload_offset..][0..record.payload.len]);
    try std.testing.expect(codec.isZero(bytes[payload_offset + record.payload.len .. footer_offset]));
    try std.testing.expectEqual(record.local_sequence, codec.getInt(u64, &bytes, 0xfe8));
    try std.testing.expectEqual(record.kind, codec.getInt(u16, &bytes, 0xff0));
    try std.testing.expectEqual(record.payload.len, codec.getInt(u32, &bytes, 0xff4));
    try std.testing.expectEqualSlices(u8, &footer_magic, bytes[0xff8..0xffc]);
    try std.testing.expectEqual(codec.crc32c(bytes[0..checksum_offset]), codec.getInt(u32, &bytes, checksum_offset));
    var decoded = try decode(&bytes);
    bytes[payload_offset] ^= 0xff;
    try std.testing.expectEqualStrings("opaque prepare payload", decoded.payload.slice());
    decoded.payload.bytes[decoded.payload.len] = 1;
    try std.testing.expectError(error.NonZeroOwnedPayloadPadding, encode(decoded));
}

test "record golden fixture and fingerprint" {
    const canonical = try encode(try testRecord(generation_prepare_kind));
    const fixture = try readFixture(encoded_size, "test/fixtures/v3/control-record.hex");
    try std.testing.expectEqualSlices(u8, &fixture, &canonical);
    var expected: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected, "d6d8f95afb52b9b488823c3380eff25e97b649b970fb7d5e92598ed49d93f785");
    try std.testing.expectEqualSlices(u8, &expected, &recordDigest(&canonical));
}

test "history digest field coverage and member local exclusions" {
    const base = try testRecord(generation_prepare_kind);
    const base_history = try historyDigest(base);
    const base_bytes = try encode(base);
    var local = base;
    local.member_id = @splat(0x21);
    local.local_sequence += 1;
    local.previous_record_digest = @splat(0x51);
    local.history_digest = @splat(0xaa);
    try std.testing.expectEqualSlices(u8, &base_history, &(try historyDigest(local)));
    local.history_digest = base_history;
    const local_bytes = try encode(local);
    try std.testing.expect(!std.mem.eql(u8, &recordDigest(&base_bytes), &recordDigest(&local_bytes)));

    inline for (.{
        "kind",           "set_id",                  "membership_epoch", "writer_term",     "generation",    "mount_session_id",
        "transaction_id", "previous_history_digest", "data_root_digest", "topology_digest", "layout_digest",
    }) |field| {
        var changed = base;
        const value = &@field(changed, field);
        switch (@TypeOf(value.*)) {
            u16, u64 => value.* += 1,
            else => value[0] ^= 1,
        }
        try std.testing.expect(!std.mem.eql(u8, &base_history, &(try historyDigest(changed))));
    }
    var changed_payload = base;
    changed_payload.payload.bytes[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &base_history, &(try historyDigest(changed_payload))));
    changed_payload = base;
    changed_payload.payload = try Payload.init("opaque prepare payload!");
    try std.testing.expect(!std.mem.eql(u8, &base_history, &(try historyDigest(changed_payload))));
}

test "unknown kind structural decode is separate from policy" {
    var bytes = try encode(try testRecord(generation_prepare_kind));
    codec.putInt(u16, &bytes, 0x00a, 0x7777);
    codec.putInt(u16, &bytes, 0xff0, 0x7777);
    var record = try testRecord(0x7777);
    const history = try historyDigest(record);
    @memcpy(bytes[0x0b8..0x0d8], &history);
    fixRecordChecksum(&bytes);
    record = try decode(&bytes);
    try std.testing.expectEqual(@as(u16, 0x7777), record.kind);
    try std.testing.expectError(error.UnsupportedRecordKind, validatePolicy(record));
}

test "genesis policy requires initial epoch and local sequence" {
    var genesis = try testRecord(genesis_kind);
    genesis.local_sequence = 1;
    genesis.membership_epoch = 1;
    genesis.writer_term = 0;
    genesis.generation = 0;
    genesis.mount_session_id = @splat(0);
    genesis.transaction_id = @splat(0);
    genesis.previous_record_digest = @splat(0);
    genesis.previous_history_digest = @splat(0);
    genesis.data_root_digest = @splat(0);
    genesis.history_digest = try historyDigest(genesis);
    const bytes = try encode(genesis);
    try validatePolicy(try decode(&bytes));

    var wrong_epoch = genesis;
    wrong_epoch.membership_epoch = 2;
    try std.testing.expectError(error.InvalidGenesisRecord, validatePolicy(wrong_epoch));

    var wrong_sequence = genesis;
    wrong_sequence.local_sequence = 2;
    wrong_sequence.previous_record_digest = @splat(1);
    try std.testing.expectError(error.InvalidGenesisRecord, validatePolicy(wrong_sequence));
}

test "record framing chain and semantic policy failures" {
    const canonical = try encode(try testRecord(generation_prepare_kind));
    const cases = [_]struct { offset: usize, expected: anyerror }{
        .{ .offset = 0x000, .expected = error.InvalidMagic },
        .{ .offset = 0x008, .expected = error.UnsupportedEnvelopeVersion },
        .{ .offset = 0x00c, .expected = error.InvalidEncodedSize },
        .{ .offset = 0x010, .expected = error.InvalidHeaderSize },
        .{ .offset = 0x012, .expected = error.InvalidHeaderFlags },
        .{ .offset = 0x138, .expected = error.NonZeroHeaderReserved },
        .{ .offset = 0xfe8, .expected = error.FooterMismatch },
        .{ .offset = 0xff0, .expected = error.FooterMismatch },
        .{ .offset = 0xff2, .expected = error.InvalidFooterFlags },
        .{ .offset = 0xff4, .expected = error.FooterMismatch },
        .{ .offset = 0xff8, .expected = error.InvalidFooterMagic },
    };
    for (cases) |case| {
        var bytes = canonical;
        bytes[case.offset] ^= 1;
        fixRecordChecksum(&bytes);
        try std.testing.expectError(case.expected, decode(&bytes));
    }
    var padded = canonical;
    padded[payload_offset + codec.getInt(u32, &padded, 0x014)] = 1;
    fixRecordChecksum(&padded);
    try std.testing.expectError(error.NonZeroPayloadPadding, decode(&padded));
    var history_bad = canonical;
    history_bad[0x0b8] ^= 1;
    fixRecordChecksum(&history_bad);
    try std.testing.expectError(error.HistoryDigestMismatch, decode(&history_bad));
    var checksum_bad = canonical;
    checksum_bad[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&checksum_bad));

    var record = try testRecord(generation_prepare_kind);
    record.local_sequence = 1;
    try std.testing.expectError(error.InvalidPreviousRecordDigest, encode(record));
    record.previous_record_digest = @splat(0);
    _ = try encode(record);
    record.local_sequence = 2;
    try std.testing.expectError(error.InvalidPreviousRecordDigest, encode(record));
    record = try testRecord(genesis_kind);
    try std.testing.expectError(error.InvalidGenesisRecord, encode(record));
    record = try testRecord(generation_prepare_kind);
    record.writer_term = 0;
    try std.testing.expectError(error.InvalidGenerationRecord, encode(record));
}

test "certificate exact offsets canonical ordering round trip and fixture" {
    const certificate = testCertificate();
    const bytes = try encodeCertificate(certificate);
    try std.testing.expectEqualSlices(u8, &certificate_magic, bytes[0x00..0x08]);
    try std.testing.expectEqual(certificate_version, codec.getInt(u16, &bytes, 0x08));
    try std.testing.expectEqual(attestation_count, codec.getInt(u16, &bytes, 0x0a));
    try std.testing.expectEqual(@as(u32, 0), codec.getInt(u32, &bytes, 0x0c));
    try std.testing.expectEqualSlices(u8, &certificate.attestations[1].member_id, bytes[0x10..0x20]);
    try std.testing.expectEqualSlices(u8, &certificate.attestations[1].prepare_record_digest, bytes[0x20..0x40]);
    try std.testing.expectEqualSlices(u8, &certificate.attestations[1].prepare_history_digest, bytes[0x40..0x60]);
    try std.testing.expectEqualSlices(u8, &certificate.attestations[0].member_id, bytes[0x60..0x70]);
    try std.testing.expectEqualSlices(u8, &certificate.attestations[0].prepare_record_digest, bytes[0x70..0x90]);
    try std.testing.expectEqualSlices(u8, &certificate.attestations[0].prepare_history_digest, bytes[0x90..0xb0]);
    try std.testing.expect(codec.isZero(bytes[0xb0..0xbc]));
    try std.testing.expectEqual(codec.crc32c(bytes[0..certificate_checksum_offset]), codec.getInt(u32, &bytes, certificate_checksum_offset));
    const decoded = try decodeCertificate(&bytes);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encodeCertificate(decoded)));
    var reordered = certificate;
    std.mem.swap(Attestation, &reordered.attestations[0], &reordered.attestations[1]);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encodeCertificate(reordered)));
    const fixture = try readFixture(certificate_size, "test/fixtures/v3/commit-certificate.hex");
    try std.testing.expectEqualSlices(u8, &fixture, &bytes);
    var expected: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected, "081fc29e4f925cdf4f24d638c0e14b23c1d5c0447f481ae1b75dd765e9868e07");
    try std.testing.expectEqualSlices(u8, &expected, &certificateDigest(&bytes));
}

test "certificate validation and topology voter checks" {
    var certificate = testCertificate();
    certificate.attestations[1].member_id = certificate.attestations[0].member_id;
    try std.testing.expectError(error.DuplicateCertificateMember, encodeCertificate(certificate));
    certificate = testCertificate();
    certificate.attestations[0].prepare_record_digest = @splat(0);
    try std.testing.expectError(error.InvalidPrepareRecordDigest, encodeCertificate(certificate));
    certificate = testCertificate();
    certificate.attestations[0].prepare_history_digest = @splat(0);
    try std.testing.expectError(error.InvalidPrepareHistoryDigest, encodeCertificate(certificate));
    certificate = testCertificate();
    certificate.attestations[0].prepare_history_digest[0] ^= 1;
    try std.testing.expectError(error.PrepareHistoryDigestMismatch, encodeCertificate(certificate));

    certificate = testCertificate();
    var topology: topology_format.Topology = .{
        .set_id = @splat(1),
        .epoch = 1,
        .parent_digest = @splat(0),
        .members = .{
            .{ .member_id = @splat(0x11), .slot = 0 },
            .{ .member_id = @splat(0x22), .slot = 1 },
            .{ .member_id = @splat(0x33), .slot = 2 },
        },
    };
    try validateAgainstTopology(certificate, topology);
    topology.members[1].control_role = 2;
    try std.testing.expectError(error.CertificateMemberIsNotVoter, validateAgainstTopology(certificate, topology));
    topology.members[1].member_id = @splat(0x44);
    try std.testing.expectError(error.CertificateMemberNotInTopology, validateAgainstTopology(certificate, topology));
}

test "certificate corruption and generation commit payload are rejected" {
    const canonical = try encodeCertificate(testCertificate());
    const cases = [_]struct { offset: usize, expected: anyerror }{
        .{ .offset = 0x00, .expected = error.InvalidCertificateMagic },
        .{ .offset = 0x08, .expected = error.UnsupportedCertificateVersion },
        .{ .offset = 0x0a, .expected = error.InvalidAttestationCount },
        .{ .offset = 0x0c, .expected = error.InvalidCertificateFlags },
    };
    for (cases) |case| {
        var bytes = canonical;
        bytes[case.offset] ^= 1;
        fixCertificateChecksum(&bytes);
        try std.testing.expectError(case.expected, decodeCertificate(&bytes));
    }
    var checksum_bad = canonical;
    checksum_bad[20] ^= 1;
    try std.testing.expectError(error.CertificateChecksumMismatch, decodeCertificate(&checksum_bad));
    var reserved = canonical;
    reserved[0xb0] = 1;
    fixCertificateChecksum(&reserved);
    try std.testing.expectError(error.NonZeroCertificateReserved, decodeCertificate(&reserved));
    var noncanonical = canonical;
    const first = noncanonical[0x10..0x60].*;
    const second = noncanonical[0x60..0xb0].*;
    @memcpy(noncanonical[0x10..0x60], &second);
    @memcpy(noncanonical[0x60..0xb0], &first);
    fixCertificateChecksum(&noncanonical);
    try std.testing.expectError(error.NonCanonicalAttestationOrder, decodeCertificate(&noncanonical));

    _ = try encode(try testCommitRecord());
    var commit = try testCommitRecord();
    commit.payload = try Payload.init(commit.payload.slice()[0 .. certificate_size - 1]);
    try std.testing.expectError(error.InvalidCertificatePayloadLength, encode(commit));
    commit = try testCommitRecord();
    commit.payload.bytes[20] ^= 1;
    try std.testing.expectError(error.CertificateChecksumMismatch, encode(commit));
}

test "every single byte record mutation fails checksum without panic" {
    const canonical = try encode(try testRecord(generation_prepare_kind));
    for (0..encoded_size) |offset| {
        var mutated = canonical;
        mutated[offset] ^= 0x80;
        try std.testing.expectError(error.ChecksumMismatch, decode(&mutated));
    }
}
