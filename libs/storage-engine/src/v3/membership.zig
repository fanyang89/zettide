const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const pool_topology = @import("pool_topology.zig");

pub const proposal_size: usize = 3220;
pub const proposal_checksum_offset: usize = proposal_size - @sizeOf(u32);
pub const certificate_size: usize = 500;
pub const certificate_checksum_offset: usize = certificate_size - @sizeOf(u32);
pub const commit_payload_size: usize = proposal_size + certificate_size;
pub const max_attestation_count: usize = 6;

const proposal_magic = [8]u8{ 'D', 'D', 'V', 'M', 'E', 'M', '1', 0 };
const certificate_magic = [8]u8{ 'D', 'D', 'V', 'M', 'C', 'E', 'R', '1' };
const format_version: u16 = 1;
const proposal_topology_offset: usize = 16;
const certificate_attestations_offset: usize = 16;
const attestation_size: usize = 80;

comptime {
    std.debug.assert(proposal_topology_offset + pool_topology.encoded_size == proposal_checksum_offset);
    std.debug.assert(certificate_attestations_offset + max_attestation_count * attestation_size == certificate_checksum_offset);
    std.debug.assert(commit_payload_size <= control_record.payload_capacity);
}

pub const Mode = enum(u16) {
    normal = 1,
    administrative_recovery = 2,
};

pub const Proposal = struct {
    mode: Mode,
    topology: pool_topology.Topology,
};

pub const Certificate = struct {
    old_count: u8,
    new_count: u8,
    attestations: [max_attestation_count]control_record.Attestation,
};

pub fn encodeProposal(proposal: Proposal) ![proposal_size]u8 {
    try pool_topology.validate(proposal.topology);
    const topology_bytes = try pool_topology.encode(proposal.topology);
    var bytes: [proposal_size]u8 = @splat(0);
    @memcpy(bytes[0x00..0x08], &proposal_magic);
    codec.putInt(u16, &bytes, 0x08, format_version);
    codec.putInt(u16, &bytes, 0x0a, @intFromEnum(proposal.mode));
    codec.putInt(u32, &bytes, 0x0c, proposal_size);
    @memcpy(bytes[proposal_topology_offset..proposal_checksum_offset], &topology_bytes);
    codec.putInt(u32, &bytes, proposal_checksum_offset, codec.crc32c(bytes[0..proposal_checksum_offset]));
    return bytes;
}

pub fn decodeProposal(bytes: *const [proposal_size]u8) !Proposal {
    if (codec.getInt(u32, bytes, proposal_checksum_offset) != codec.crc32c(bytes[0..proposal_checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x00..0x08], &proposal_magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x08) != format_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u32, bytes, 0x0c) != proposal_size) return error.InvalidEncodedSize;
    const mode = std.enums.fromInt(Mode, codec.getInt(u16, bytes, 0x0a)) orelse
        return error.InvalidMembershipMode;
    const topology_bytes: *const [pool_topology.encoded_size]u8 = bytes[proposal_topology_offset..proposal_checksum_offset];
    return .{ .mode = mode, .topology = try pool_topology.decode(topology_bytes) };
}

pub fn validateTransition(current: pool_topology.Topology, proposal: Proposal) !void {
    try pool_topology.validate(current);
    try pool_topology.validate(proposal.topology);
    const next = proposal.topology;
    if (!std.mem.eql(u8, &current.set_id, &next.set_id)) return error.ForeignSet;
    if (current.epoch == std.math.maxInt(u64) or next.epoch != current.epoch + 1)
        return error.InvalidMembershipEpoch;
    if (!std.mem.eql(u8, &next.parent_digest, &(try pool_topology.digest(current))))
        return error.ParentTopologyDigestMismatch;

    var changed = false;
    for (current.memberSlice()) |old_member| {
        const new_member = pool_topology.findMember(&next, old_member.member_id) orelse {
            if (proposal.mode == .normal and old_member.state == .active)
                return error.MemberMustDrainBeforeRemoval;
            changed = true;
            continue;
        };
        if (new_member.slot != old_member.slot) return error.MemberSlotChanged;
        if (!validStateTransition(old_member.state, new_member.state))
            return error.InvalidMemberStateTransition;
        if (new_member.state != old_member.state or
            new_member.control_role != old_member.control_role or
            new_member.role_flags != old_member.role_flags) changed = true;
    }
    for (next.memberSlice()) |new_member| {
        if (pool_topology.findMember(&current, new_member.member_id) != null) continue;
        if (new_member.state != .joining or new_member.control_role != pool_topology.non_voter_role)
            return error.NewMemberMustJoinAsNonVoter;
        changed = true;
    }
    if (!changed) return error.EmptyMembershipTransition;
}

pub fn encodeCertificate(
    current: pool_topology.Topology,
    next: pool_topology.Topology,
    mode: Mode,
    certificate_input: Certificate,
) ![certificate_size]u8 {
    try validateCertificate(current, next, mode, certificate_input);
    var certificate = certificate_input;
    sortAttestations(certificate.attestations[0..certificate.old_count]);
    const new_start = certificate.old_count;
    sortAttestations(certificate.attestations[new_start .. new_start + certificate.new_count]);

    var bytes: [certificate_size]u8 = @splat(0);
    @memcpy(bytes[0x00..0x08], &certificate_magic);
    codec.putInt(u16, &bytes, 0x08, format_version);
    bytes[0x0a] = certificate.old_count;
    bytes[0x0b] = certificate.new_count;
    codec.putInt(u32, &bytes, 0x0c, 0);
    const count = @as(usize, certificate.old_count) + certificate.new_count;
    for (certificate.attestations[0..count], 0..) |attestation, index|
        putAttestation(&bytes, certificate_attestations_offset + index * attestation_size, attestation);
    codec.putInt(u32, &bytes, certificate_checksum_offset, codec.crc32c(bytes[0..certificate_checksum_offset]));
    return bytes;
}

pub fn decodeCertificate(
    current: pool_topology.Topology,
    next: pool_topology.Topology,
    mode: Mode,
    bytes: *const [certificate_size]u8,
) !Certificate {
    if (codec.getInt(u32, bytes, certificate_checksum_offset) != codec.crc32c(bytes[0..certificate_checksum_offset]))
        return error.CertificateChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x00..0x08], &certificate_magic)) return error.InvalidCertificateMagic;
    if (codec.getInt(u16, bytes, 0x08) != format_version) return error.UnsupportedCertificateVersion;
    if (codec.getInt(u32, bytes, 0x0c) != 0) return error.InvalidCertificateFlags;
    const old_count = bytes[0x0a];
    const new_count = bytes[0x0b];
    const count = @as(usize, old_count) + new_count;
    if (count > max_attestation_count) return error.InvalidAttestationCount;
    const used_end = certificate_attestations_offset + count * attestation_size;
    if (!codec.isZero(bytes[used_end..certificate_checksum_offset])) return error.NonZeroCertificatePadding;

    var attestations: [max_attestation_count]control_record.Attestation = @splat(zeroAttestation());
    for (attestations[0..count], 0..) |*attestation, index|
        attestation.* = getAttestation(bytes, certificate_attestations_offset + index * attestation_size);
    const certificate: Certificate = .{
        .old_count = old_count,
        .new_count = new_count,
        .attestations = attestations,
    };
    try validateCertificate(current, next, mode, certificate);
    try validateCanonicalGroup(certificate.attestations[0..old_count]);
    try validateCanonicalGroup(certificate.attestations[old_count..count]);
    return certificate;
}

pub fn makePreparePayload(proposal: Proposal) !control_record.Payload {
    const bytes = try encodeProposal(proposal);
    return control_record.Payload.init(&bytes);
}

pub fn makeCommitPayload(
    current: pool_topology.Topology,
    proposal: Proposal,
    certificate: Certificate,
) !control_record.Payload {
    try validateTransition(current, proposal);
    const proposal_bytes = try encodeProposal(proposal);
    const certificate_bytes = try encodeCertificate(current, proposal.topology, proposal.mode, certificate);
    var bytes: [commit_payload_size]u8 = undefined;
    @memcpy(bytes[0..proposal_size], &proposal_bytes);
    @memcpy(bytes[proposal_size..], &certificate_bytes);
    return control_record.Payload.init(&bytes);
}

pub fn validateRecordProposal(record: control_record.Record) !Proposal {
    try control_record.validateDynamicPoolPolicy(record);
    const proposal = switch (record.kind) {
        control_record.membership_prepare_kind => blk: {
            if (record.payload.len != proposal_size) return error.InvalidMembershipPreparePayloadLength;
            var bytes: [proposal_size]u8 = undefined;
            @memcpy(&bytes, record.payload.slice());
            break :blk try decodeProposal(&bytes);
        },
        control_record.membership_commit_kind => blk: {
            if (record.payload.len != commit_payload_size) return error.InvalidMembershipCommitPayloadLength;
            var bytes: [proposal_size]u8 = undefined;
            @memcpy(&bytes, record.payload.slice()[0..proposal_size]);
            break :blk try decodeProposal(&bytes);
        },
        else => return error.NotMembershipRecord,
    };
    if (record.writer_term == 0 or codec.isZero(&record.mount_session_id) or
        codec.isZero(&record.transaction_id)) return error.InvalidMembershipRecord;
    if (!std.mem.eql(u8, &record.set_id, &proposal.topology.set_id)) return error.ForeignSet;
    if (record.membership_epoch != proposal.topology.epoch) return error.MembershipEpochMismatch;
    if (!std.mem.eql(u8, &record.topology_digest, &(try pool_topology.digest(proposal.topology))))
        return error.TopologyDigestMismatch;
    return proposal;
}

fn validateCertificate(
    current: pool_topology.Topology,
    next: pool_topology.Topology,
    mode: Mode,
    certificate: Certificate,
) !void {
    try pool_topology.validate(current);
    try pool_topology.validate(next);
    const expected_old_count: u8 = switch (mode) {
        .normal => @intCast(current.quorum),
        .administrative_recovery => 0,
    };
    if (certificate.old_count != expected_old_count or certificate.new_count != next.quorum)
        return error.InvalidAttestationCount;
    const count = @as(usize, certificate.old_count) + certificate.new_count;
    if (count == 0 or count > max_attestation_count) return error.InvalidAttestationCount;
    for (certificate.attestations[count..]) |attestation| {
        if (!isZeroAttestation(attestation)) return error.NonZeroOwnedCertificatePadding;
    }

    const old_group = certificate.attestations[0..certificate.old_count];
    const new_group = certificate.attestations[certificate.old_count..count];
    try validateWitnessGroup(current, old_group);
    try validateWitnessGroup(next, new_group);
    const history_digest = certificate.attestations[0].prepare_history_digest;
    for (certificate.attestations[0..count]) |attestation| {
        if (!std.mem.eql(u8, &attestation.prepare_history_digest, &history_digest))
            return error.PrepareHistoryDigestMismatch;
    }
    for (old_group) |old_attestation| {
        for (new_group) |new_attestation| {
            if (!std.mem.eql(u8, &old_attestation.member_id, &new_attestation.member_id)) continue;
            if (!std.mem.eql(u8, &old_attestation.prepare_record_digest, &new_attestation.prepare_record_digest))
                return error.ConflictingJointAttestation;
        }
    }
}

fn validateWitnessGroup(topology: pool_topology.Topology, attestations: []const control_record.Attestation) !void {
    for (attestations, 0..) |attestation, index| {
        if (codec.isZero(&attestation.member_id) or codec.isZero(&attestation.prepare_record_digest) or
            codec.isZero(&attestation.prepare_history_digest)) return error.InvalidAttestation;
        const member = pool_topology.findMember(&topology, attestation.member_id) orelse
            return error.AttestationMemberNotFound;
        if (member.control_role != pool_topology.voter_role) return error.AttestationMemberIsNotVoter;
        for (attestations[0..index]) |previous| {
            if (std.mem.eql(u8, &attestation.member_id, &previous.member_id))
                return error.DuplicateAttestationMember;
        }
    }
}

fn validateCanonicalGroup(attestations: []const control_record.Attestation) !void {
    if (attestations.len < 2) return;
    for (attestations[1..], 1..) |attestation, index| {
        if (std.mem.order(u8, &attestations[index - 1].member_id, &attestation.member_id) != .lt)
            return error.NonCanonicalAttestationOrder;
    }
}

fn validStateTransition(old: pool_topology.MemberState, new: pool_topology.MemberState) bool {
    return switch (old) {
        .joining => new == .joining or new == .active,
        .active => new == .active or new == .draining,
        .draining => new == .draining or new == .active,
    };
}

fn sortAttestations(attestations: []control_record.Attestation) void {
    for (0..attestations.len) |target| {
        for (target + 1..attestations.len) |candidate| {
            if (std.mem.order(u8, &attestations[candidate].member_id, &attestations[target].member_id) == .lt)
                std.mem.swap(control_record.Attestation, &attestations[target], &attestations[candidate]);
        }
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

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn topologyOne(epoch: u64, parent_digest: codec.Digest) !pool_topology.Topology {
    const members = [_]pool_topology.Member{.{
        .member_id = id(2),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = 3,
    }};
    return pool_topology.Topology.init(id(1), epoch, parent_digest, &members);
}

fn addJoining(current: pool_topology.Topology) !Proposal {
    var members: [2]pool_topology.Member = undefined;
    @memcpy(members[0..1], current.memberSlice());
    members[1] = .{ .member_id = id(3), .slot = 19, .state = .joining };
    return .{
        .mode = .normal,
        .topology = try pool_topology.Topology.init(current.set_id, current.epoch + 1, try pool_topology.digest(current), &members),
    };
}

fn testAttestation(member_id: [16]u8, raw: u8) control_record.Attestation {
    return .{ .member_id = member_id, .prepare_record_digest = @splat(raw), .prepare_history_digest = @splat(0x55) };
}

fn testCertificate(old: []const control_record.Attestation, new: []const control_record.Attestation) Certificate {
    var result: Certificate = .{
        .old_count = @intCast(old.len),
        .new_count = @intCast(new.len),
        .attestations = @splat(zeroAttestation()),
    };
    @memcpy(result.attestations[0..old.len], old);
    @memcpy(result.attestations[old.len .. old.len + new.len], new);
    return result;
}

fn testMembershipRecord(proposal: Proposal, kind: u16, payload: control_record.Payload) !control_record.Record {
    var record: control_record.Record = .{
        .kind = kind,
        .local_sequence = 2,
        .membership_epoch = proposal.topology.epoch,
        .writer_term = 1,
        .generation = 1,
        .set_id = proposal.topology.set_id,
        .member_id = id(2),
        .mount_session_id = id(7),
        .transaction_id = id(8),
        .previous_record_digest = @splat(0x33),
        .previous_history_digest = @splat(0x44),
        .data_root_digest = @splat(0x55),
        .topology_digest = try pool_topology.digest(proposal.topology),
        .layout_digest = @splat(0x66),
        .payload = payload,
    };
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

test "membership proposal round trips a joining member" {
    const current = try topologyOne(1, @splat(0));
    const proposal = try addJoining(current);
    try validateTransition(current, proposal);
    const bytes = try encodeProposal(proposal);
    const decoded = try decodeProposal(&bytes);
    try validateTransition(current, decoded);
    try std.testing.expectEqualSlices(u8, &bytes, &(try encodeProposal(decoded)));
}

test "normal removal requires draining while administrative recovery does not" {
    const current_members = [_]pool_topology.Member{
        .{ .member_id = id(2), .slot = 7, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = id(3), .slot = 19, .control_role = pool_topology.voter_role, .role_flags = 3 },
    };
    const current = try pool_topology.Topology.init(id(1), 1, @splat(0), &current_members);
    const survivor = [_]pool_topology.Member{.{
        .member_id = id(2),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = 3,
    }};
    const next = try pool_topology.Topology.init(current.set_id, 2, try pool_topology.digest(current), &survivor);
    try std.testing.expectError(error.MemberMustDrainBeforeRemoval, validateTransition(current, .{ .mode = .normal, .topology = next }));
    try validateTransition(current, .{ .mode = .administrative_recovery, .topology = next });
}

test "member addition cannot bypass joining state or become a voter" {
    const current = try topologyOne(1, @splat(0));
    var proposal = try addJoining(current);
    proposal.topology.members[1].state = .active;
    proposal.topology.members[1].control_role = pool_topology.voter_role;
    proposal.topology.members[1].role_flags = 3;
    proposal.topology.quorum = 2;
    try std.testing.expectError(error.NewMemberMustJoinAsNonVoter, validateTransition(current, proposal));
}

test "joint certificate proves old and new control quorums" {
    const current = try topologyOne(1, @splat(0));
    const proposal = try addJoining(current);
    const old_group = [_]control_record.Attestation{testAttestation(id(2), 0x20)};
    const new_group = [_]control_record.Attestation{testAttestation(id(2), 0x20)};
    const input = testCertificate(&old_group, &new_group);
    const bytes = try encodeCertificate(current, proposal.topology, .normal, input);
    const decoded = try decodeCertificate(current, proposal.topology, .normal, &bytes);
    try std.testing.expectEqual(@as(u8, 1), decoded.old_count);
    try std.testing.expectEqual(@as(u8, 1), decoded.new_count);
    const payload = try makeCommitPayload(current, proposal, input);
    try std.testing.expectEqual(@as(u32, commit_payload_size), payload.len);
}

test "administrative recovery certificate uses only new quorum" {
    const current_members = [_]pool_topology.Member{
        .{ .member_id = id(2), .slot = 7, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = id(3), .slot = 19, .control_role = pool_topology.voter_role, .role_flags = 3 },
    };
    const current = try pool_topology.Topology.init(id(1), 1, @splat(0), &current_members);
    const survivor = [_]pool_topology.Member{.{
        .member_id = id(2),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = 3,
    }};
    const next = try pool_topology.Topology.init(current.set_id, 2, try pool_topology.digest(current), &survivor);
    const new_group = [_]control_record.Attestation{testAttestation(id(2), 0x31)};
    const input = testCertificate(&.{}, &new_group);
    const bytes = try encodeCertificate(current, next, .administrative_recovery, input);
    _ = try decodeCertificate(current, next, .administrative_recovery, &bytes);
    try std.testing.expectError(error.InvalidAttestationCount, encodeCertificate(current, next, .normal, input));
}

test "certificate rejects non-voters duplicate witnesses and divergent prepare history" {
    const current = try topologyOne(1, @splat(0));
    const proposal = try addJoining(current);
    const old_group = [_]control_record.Attestation{testAttestation(id(2), 0x20)};
    var new_group = [_]control_record.Attestation{testAttestation(id(3), 0x30)};
    var input = testCertificate(&old_group, &new_group);
    try std.testing.expectError(error.AttestationMemberIsNotVoter, encodeCertificate(current, proposal.topology, .normal, input));

    new_group[0] = testAttestation(id(2), 0x21);
    new_group[0].prepare_history_digest = @splat(0x66);
    input = testCertificate(&old_group, &new_group);
    try std.testing.expectError(error.PrepareHistoryDigestMismatch, encodeCertificate(current, proposal.topology, .normal, input));

    new_group[0].prepare_history_digest = old_group[0].prepare_history_digest;
    input = testCertificate(&old_group, &new_group);
    try std.testing.expectError(error.ConflictingJointAttestation, encodeCertificate(current, proposal.topology, .normal, input));
}

test "proposal and certificate corruption are rejected" {
    const current = try topologyOne(1, @splat(0));
    const proposal = try addJoining(current);
    var proposal_bytes = try encodeProposal(proposal);
    proposal_bytes[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeProposal(&proposal_bytes));

    const group = [_]control_record.Attestation{testAttestation(id(2), 0x20)};
    var certificate_bytes = try encodeCertificate(current, proposal.topology, .normal, testCertificate(&group, &group));
    certificate_bytes[100] ^= 1;
    try std.testing.expectError(
        error.CertificateChecksumMismatch,
        decodeCertificate(current, proposal.topology, .normal, &certificate_bytes),
    );
}

test "membership records bind exact proposal length epoch and topology digest" {
    const current = try topologyOne(1, @splat(0));
    const proposal = try addJoining(current);
    var record = try testMembershipRecord(
        proposal,
        control_record.membership_prepare_kind,
        try makePreparePayload(proposal),
    );
    _ = try validateRecordProposal(record);
    record.membership_epoch += 1;
    record.history_digest = try control_record.historyDigest(record);
    try std.testing.expectError(error.MembershipEpochMismatch, validateRecordProposal(record));

    record = try testMembershipRecord(
        proposal,
        control_record.membership_prepare_kind,
        try control_record.Payload.init("short"),
    );
    try std.testing.expectError(error.InvalidMembershipPreparePayloadLength, validateRecordProposal(record));
}
