const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const pool_topology = @import("pool_topology.zig");

pub const encoded_size: usize = control_record.certificate_size;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);
pub const max_attestation_count: usize = 2;

const magic = [8]u8{ 'D', 'D', 'V', 'C', 'E', 'R', 'T', '2' };
const format_version: u16 = 2;
const attestations_offset: usize = 0x10;
const attestation_size: usize = 80;
const reserved_offset: usize = attestations_offset + max_attestation_count * attestation_size;

pub const Certificate = struct {
    count: u16,
    attestations: [max_attestation_count]control_record.Attestation,
};

pub fn encode(certificate_input: Certificate) ![encoded_size]u8 {
    try validate(certificate_input);
    var certificate = certificate_input;
    if (certificate.count == 2 and
        std.mem.order(u8, &certificate.attestations[0].member_id, &certificate.attestations[1].member_id) == .gt)
        std.mem.swap(control_record.Attestation, &certificate.attestations[0], &certificate.attestations[1]);
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x00..0x08], &magic);
    codec.putInt(u16, &bytes, 0x08, format_version);
    codec.putInt(u16, &bytes, 0x0a, certificate.count);
    codec.putInt(u32, &bytes, 0x0c, 0);
    for (certificate.attestations[0..certificate.count], 0..) |attestation, index|
        putAttestation(&bytes, attestations_offset + index * attestation_size, attestation);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(bytes: *const [encoded_size]u8) !Certificate {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.CertificateChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x00..0x08], &magic)) return error.InvalidCertificateMagic;
    if (codec.getInt(u16, bytes, 0x08) != format_version) return error.UnsupportedCertificateVersion;
    if (codec.getInt(u32, bytes, 0x0c) != 0) return error.InvalidCertificateFlags;
    const count = codec.getInt(u16, bytes, 0x0a);
    if (count == 0 or count > max_attestation_count) return error.InvalidAttestationCount;
    const used_end = attestations_offset + @as(usize, count) * attestation_size;
    if (!codec.isZero(bytes[used_end..checksum_offset])) return error.NonZeroCertificateReserved;
    var attestations: [max_attestation_count]control_record.Attestation = @splat(zeroAttestation());
    for (attestations[0..count], 0..) |*attestation, index|
        attestation.* = getAttestation(bytes, attestations_offset + index * attestation_size);
    const certificate: Certificate = .{ .count = count, .attestations = attestations };
    try validate(certificate);
    if (count == 2 and
        std.mem.order(u8, &certificate.attestations[0].member_id, &certificate.attestations[1].member_id) != .lt)
        return error.NonCanonicalAttestationOrder;
    return certificate;
}

pub fn validateAgainstTopology(certificate: Certificate, topology: pool_topology.Topology) !void {
    try validate(certificate);
    try pool_topology.validate(topology);
    if (certificate.count != topology.quorum) return error.CertificateDoesNotMeetQuorum;
    for (certificate.attestations[0..certificate.count]) |attestation| {
        const member = pool_topology.findMember(&topology, attestation.member_id) orelse
            return error.CertificateMemberNotInTopology;
        if (member.control_role != pool_topology.voter_role)
            return error.CertificateMemberIsNotVoter;
    }
}

fn validate(certificate: Certificate) !void {
    if (certificate.count == 0 or certificate.count > max_attestation_count)
        return error.InvalidAttestationCount;
    for (certificate.attestations[0..certificate.count], 0..) |attestation, index| {
        if (codec.isZero(&attestation.member_id)) return error.InvalidCertificateMemberId;
        if (codec.isZero(&attestation.prepare_record_digest)) return error.InvalidPrepareRecordDigest;
        if (codec.isZero(&attestation.prepare_history_digest)) return error.InvalidPrepareHistoryDigest;
        for (certificate.attestations[0..index]) |previous| {
            if (std.mem.eql(u8, &attestation.member_id, &previous.member_id))
                return error.DuplicateCertificateMember;
        }
        if (index != 0 and !std.mem.eql(
            u8,
            &attestation.prepare_history_digest,
            &certificate.attestations[0].prepare_history_digest,
        )) return error.PrepareHistoryDigestMismatch;
    }
    for (certificate.attestations[certificate.count..]) |attestation| {
        if (!isZeroAttestation(attestation)) return error.NonZeroOwnedCertificatePadding;
    }
}

fn putAttestation(bytes: []u8, offset: usize, attestation: control_record.Attestation) void {
    @memcpy(bytes[offset..][0..16], &attestation.member_id);
    @memcpy(bytes[offset + 16 ..][0..32], &attestation.prepare_record_digest);
    @memcpy(bytes[offset + 48 ..][0..32], &attestation.prepare_history_digest);
}

fn getAttestation(bytes: []const u8, offset: usize) control_record.Attestation {
    return .{
        .member_id = bytes[offset..][0..16].*,
        .prepare_record_digest = bytes[offset + 16 ..][0..32].*,
        .prepare_history_digest = bytes[offset + 48 ..][0..32].*,
    };
}

fn zeroAttestation() control_record.Attestation {
    return .{ .member_id = @splat(0), .prepare_record_digest = @splat(0), .prepare_history_digest = @splat(0) };
}

fn isZeroAttestation(attestation: control_record.Attestation) bool {
    return codec.isZero(&attestation.member_id) and codec.isZero(&attestation.prepare_record_digest) and
        codec.isZero(&attestation.prepare_history_digest);
}

fn testAttestation(member: u8, raw: u8) control_record.Attestation {
    return .{
        .member_id = @splat(member),
        .prepare_record_digest = @splat(raw),
        .prepare_history_digest = @splat(0x55),
    };
}

test "one and two attestation certificates round trip canonically" {
    const one: Certificate = .{
        .count = 1,
        .attestations = .{ testAttestation(2, 3), zeroAttestation() },
    };
    const one_bytes = try encode(one);
    try std.testing.expectEqualSlices(u8, &one_bytes, &(try encode(try decode(&one_bytes))));

    const two: Certificate = .{
        .count = 2,
        .attestations = .{ testAttestation(3, 4), testAttestation(2, 5) },
    };
    const two_bytes = try encode(two);
    const decoded = try decode(&two_bytes);
    try std.testing.expect(std.mem.order(u8, &decoded.attestations[0].member_id, &decoded.attestations[1].member_id) == .lt);
}

test "certificate count must equal dynamic topology quorum" {
    const members = [_]pool_topology.Member{.{
        .member_id = @splat(2),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = 3,
    }};
    const topology = try pool_topology.Topology.init(@splat(1), 1, @splat(0), &members);
    const certificate: Certificate = .{
        .count = 1,
        .attestations = .{ testAttestation(2, 3), zeroAttestation() },
    };
    try validateAgainstTopology(certificate, topology);
    var invalid = certificate;
    invalid.attestations[0].member_id = @splat(9);
    try std.testing.expectError(error.CertificateMemberNotInTopology, validateAgainstTopology(invalid, topology));
}

test "unused attestation bytes and checksum corruption are rejected" {
    const certificate: Certificate = .{
        .count = 1,
        .attestations = .{ testAttestation(2, 3), zeroAttestation() },
    };
    const canonical = try encode(certificate);
    var bytes = canonical;
    bytes[0x60] = 1;
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    try std.testing.expectError(error.NonZeroCertificateReserved, decode(&bytes));
    bytes = canonical;
    bytes[0x10] ^= 1;
    try std.testing.expectError(error.CertificateChecksumMismatch, decode(&bytes));
}
