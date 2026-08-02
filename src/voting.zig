//! Stable records for fixed-membership shared-disk voting.

const std = @import("std");

pub const block_size = 512;
pub const format_version: u16 = 1;
pub const max_members = 5;
pub const Id = [16]u8;
pub const Encoded = [block_size]u8;

pub const Error = error{
    InvalidSize,
    InvalidMagic,
    UnsupportedFormatVersion,
    InvalidFlags,
    NonCanonicalEncoding,
    ChecksumMismatch,
    InvalidConfiguration,
    InvalidMember,
    InvalidBallot,
    InvalidTransition,
    MissingQuorum,
};

pub const Configuration = struct {
    domain_id: Id,
    member_count: u8,
    members: [max_members]Id,

    pub fn quorum(self: Configuration) u8 {
        return self.member_count / 2 + 1;
    }
};

pub const Presence = struct {
    incarnation_id: Id,
    incarnation_counter: u64,
    sequence: u64,
};

pub const Ballot = struct {
    counter: u64,
    candidate_slot: u8,
    candidate_incarnation_id: Id,
    candidate_incarnation_counter: u64,
    proposal_id: Id,

    pub fn compare(a: Ballot, b: Ballot) std.math.Order {
        if (a.counter < b.counter) return .lt;
        if (a.counter > b.counter) return .gt;
        if (a.candidate_slot < b.candidate_slot) return .lt;
        if (a.candidate_slot > b.candidate_slot) return .gt;
        return .eq;
    }

    pub fn eql(a: Ballot, b: Ballot) bool {
        return a.counter == b.counter and
            a.candidate_slot == b.candidate_slot and
            std.mem.eql(u8, &a.candidate_incarnation_id, &b.candidate_incarnation_id) and
            a.candidate_incarnation_counter == b.candidate_incarnation_counter and
            std.mem.eql(u8, &a.proposal_id, &b.proposal_id);
    }
};

pub const Proposal = struct {
    ballot: Ballot,
    cohort_bitmap: u8,

    pub fn eql(a: Proposal, b: Proposal) bool {
        return a.cohort_bitmap == b.cohort_bitmap and a.ballot.eql(b.ballot);
    }
};

pub const Member = struct {
    domain_id: Id,
    slot: u8,
    presence: ?Presence,
    campaign: ?Proposal,
    vote: ?Proposal,
};

pub const CommittedProposal = struct {
    proposal: Proposal,
    voter_bitmap: u8,
};

pub const Authority = struct {
    domain_id: Id,
    active: ?CommittedProposal,
};

const config_magic = "ZCAWVC\x00\x00";
const member_magic = "ZCAWVM\x00\x00";
const authority_magic = "ZCAWVA\x00\x00";
const magic_start = 0;
const magic_end = 8;
const version_start = 8;
const version_end = 10;
const flags_start = 10;
const flags_end = 12;

const config_domain_start = 12;
const config_domain_end = 28;
const config_count = 28;
const config_members_start = 32;
const config_members_end = config_members_start + max_members * @sizeOf(Id);
const config_checksum_start = config_members_end;
const config_checksum_end = config_checksum_start + std.crypto.hash.sha2.Sha256.digest_length;

const member_domain_start = 12;
const member_domain_end = 28;
const member_slot = 28;
const presence_incarnation_start = 32;
const presence_incarnation_end = 48;
const presence_counter_start = 48;
const presence_counter_end = 56;
const presence_sequence_start = 56;
const presence_sequence_end = 64;
const campaign_ballot_start = 64;
const campaign_counter_start = campaign_ballot_start;
const campaign_counter_end = 72;
const campaign_candidate_slot = 72;
const campaign_incarnation_start = 80;
const campaign_incarnation_end = 96;
const campaign_incarnation_counter_start = 96;
const campaign_incarnation_counter_end = 104;
const campaign_proposal_start = 104;
const campaign_proposal_end = 120;
const campaign_cohort = 120;
const campaign_ballot_end = 128;
const vote_ballot_start = 128;
const vote_counter_start = vote_ballot_start;
const vote_counter_end = 136;
const vote_candidate_slot = 136;
const vote_incarnation_start = 144;
const vote_incarnation_end = 160;
const vote_incarnation_counter_start = 160;
const vote_incarnation_counter_end = 168;
const vote_proposal_start = 168;
const vote_proposal_end = 184;
const vote_cohort = 184;
const vote_ballot_end = 192;
const member_checksum_start = vote_ballot_end;
const member_checksum_end = member_checksum_start + std.crypto.hash.sha2.Sha256.digest_length;
const has_presence: u16 = 1 << 0;
const has_campaign: u16 = 1 << 1;
const has_vote: u16 = 1 << 2;
const known_member_flags = has_presence | has_campaign | has_vote;

const authority_domain_start = 12;
const authority_domain_end = 28;
const authority_ballot_start = 28;
const authority_counter_start = authority_ballot_start;
const authority_counter_end = 36;
const authority_candidate_slot = 36;
const authority_incarnation_start = 44;
const authority_incarnation_end = 60;
const authority_incarnation_counter_start = 60;
const authority_incarnation_counter_end = 68;
const authority_proposal_start = 68;
const authority_proposal_end = 84;
const authority_cohort = 84;
const authority_voters = 85;
const authority_ballot_end = 88;
const authority_checksum_start = authority_ballot_end;
const authority_checksum_end = authority_checksum_start + std.crypto.hash.sha2.Sha256.digest_length;
const has_active: u16 = 1 << 0;

comptime {
    std.debug.assert(config_checksum_end <= block_size);
    std.debug.assert(member_checksum_end <= block_size);
    std.debug.assert(authority_checksum_end <= block_size);
}

pub fn encodeConfiguration(configuration: Configuration) Error!Encoded {
    try validateConfiguration(configuration);
    var encoded: Encoded = @splat(0);
    encodeHeader(&encoded, config_magic, 0);
    @memcpy(encoded[config_domain_start..config_domain_end], &configuration.domain_id);
    encoded[config_count] = configuration.member_count;
    for (configuration.members, 0..) |member_id, index| {
        const start = config_members_start + index * @sizeOf(Id);
        @memcpy(encoded[start .. start + @sizeOf(Id)], &member_id);
    }
    seal(&encoded, config_checksum_start);
    return encoded;
}

pub fn decodeConfiguration(bytes: []const u8) Error!Configuration {
    const encoded = try decodeHeader(bytes, config_magic, 0);
    if (!allZero(encoded[29..32])) return error.NonCanonicalEncoding;
    if (!allZero(encoded[config_checksum_end..])) return error.NonCanonicalEncoding;
    try verifyChecksum(encoded, config_checksum_start);

    var members: [max_members]Id = undefined;
    for (&members, 0..) |*member_id, index| {
        const start = config_members_start + index * @sizeOf(Id);
        member_id.* = encoded[start..][0..@sizeOf(Id)].*;
    }
    const configuration = Configuration{
        .domain_id = encoded[config_domain_start..config_domain_end].*,
        .member_count = encoded[config_count],
        .members = members,
    };
    try validateConfiguration(configuration);
    return configuration;
}

pub fn encodeMember(member: Member) Error!Encoded {
    try validateMemberShape(member);
    var flags: u16 = 0;
    if (member.presence != null) flags |= has_presence;
    if (member.campaign != null) flags |= has_campaign;
    if (member.vote != null) flags |= has_vote;

    var encoded: Encoded = @splat(0);
    encodeHeader(&encoded, member_magic, flags);
    @memcpy(encoded[member_domain_start..member_domain_end], &member.domain_id);
    encoded[member_slot] = member.slot;
    if (member.presence) |presence| {
        @memcpy(
            encoded[presence_incarnation_start..presence_incarnation_end],
            &presence.incarnation_id,
        );
        writeU64(&encoded, presence_counter_start, presence.incarnation_counter);
        writeU64(&encoded, presence_sequence_start, presence.sequence);
    }
    if (member.campaign) |campaign| {
        encodeBallot(&encoded, campaign_ballot_start, campaign.ballot);
        encoded[campaign_cohort] = campaign.cohort_bitmap;
    }
    if (member.vote) |vote| {
        encodeBallot(&encoded, vote_ballot_start, vote.ballot);
        encoded[vote_cohort] = vote.cohort_bitmap;
    }
    seal(&encoded, member_checksum_start);
    return encoded;
}

pub fn decodeMember(bytes: []const u8) Error!Member {
    const encoded = try decodeHeader(bytes, member_magic, known_member_flags);
    const flags = readU16(encoded, flags_start);
    if (!allZero(encoded[29..32]) or
        !allZero(encoded[73..80]) or
        !allZero(encoded[121..128]) or
        !allZero(encoded[137..144]) or
        !allZero(encoded[185..192]) or
        !allZero(encoded[member_checksum_end..])) return error.NonCanonicalEncoding;
    if (flags & has_presence == 0 and !allZero(encoded[presence_incarnation_start..presence_sequence_end]))
        return error.NonCanonicalEncoding;
    if (flags & has_campaign == 0 and !allZero(encoded[campaign_ballot_start..campaign_ballot_end]))
        return error.NonCanonicalEncoding;
    if (flags & has_vote == 0 and !allZero(encoded[vote_ballot_start..vote_ballot_end]))
        return error.NonCanonicalEncoding;
    try verifyChecksum(encoded, member_checksum_start);

    const member = Member{
        .domain_id = encoded[member_domain_start..member_domain_end].*,
        .slot = encoded[member_slot],
        .presence = if (flags & has_presence != 0) .{
            .incarnation_id = encoded[presence_incarnation_start..presence_incarnation_end].*,
            .incarnation_counter = readU64(encoded, presence_counter_start),
            .sequence = readU64(encoded, presence_sequence_start),
        } else null,
        .campaign = if (flags & has_campaign != 0) .{
            .ballot = decodeBallot(encoded, campaign_ballot_start),
            .cohort_bitmap = encoded[campaign_cohort],
        } else null,
        .vote = if (flags & has_vote != 0) .{
            .ballot = decodeBallot(encoded, vote_ballot_start),
            .cohort_bitmap = encoded[vote_cohort],
        } else null,
    };
    try validateMemberShape(member);
    return member;
}

pub fn encodeAuthority(authority: Authority) Error!Encoded {
    try validateAuthorityShape(authority);
    const flags: u16 = if (authority.active != null) has_active else 0;
    var encoded: Encoded = @splat(0);
    encodeHeader(&encoded, authority_magic, flags);
    @memcpy(encoded[authority_domain_start..authority_domain_end], &authority.domain_id);
    if (authority.active) |active| {
        encodeBallot(&encoded, authority_ballot_start, active.proposal.ballot);
        encoded[authority_cohort] = active.proposal.cohort_bitmap;
        encoded[authority_voters] = active.voter_bitmap;
    }
    seal(&encoded, authority_checksum_start);
    return encoded;
}

pub fn decodeAuthority(bytes: []const u8) Error!Authority {
    const encoded = try decodeHeader(bytes, authority_magic, has_active);
    const flags = readU16(encoded, flags_start);
    if (!allZero(encoded[37..44]) or
        !allZero(encoded[86..88]) or
        !allZero(encoded[authority_checksum_end..]))
        return error.NonCanonicalEncoding;
    if (flags & has_active == 0 and !allZero(encoded[authority_ballot_start..authority_ballot_end]))
        return error.NonCanonicalEncoding;
    try verifyChecksum(encoded, authority_checksum_start);

    const authority = Authority{
        .domain_id = encoded[authority_domain_start..authority_domain_end].*,
        .active = if (flags & has_active != 0) .{
            .proposal = .{
                .ballot = decodeBallot(encoded, authority_ballot_start),
                .cohort_bitmap = encoded[authority_cohort],
            },
            .voter_bitmap = encoded[authority_voters],
        } else null,
    };
    try validateAuthorityShape(authority);
    return authority;
}

pub fn validateMember(configuration: Configuration, member: Member) Error!void {
    try validateConfiguration(configuration);
    try validateMemberShape(member);
    if (!std.mem.eql(u8, &configuration.domain_id, &member.domain_id)) return error.InvalidMember;
    if (member.slot >= configuration.member_count) return error.InvalidMember;
    if (member.campaign) |campaign| try validateProposal(configuration, campaign);
    if (member.vote) |vote| try validateProposal(configuration, vote);
}

pub fn validateMemberTransition(
    configuration: Configuration,
    previous: Member,
    next: Member,
) Error!void {
    try validateMember(configuration, previous);
    try validateMember(configuration, next);
    if (previous.slot != next.slot or
        !std.mem.eql(u8, &previous.domain_id, &next.domain_id)) return error.InvalidTransition;

    if (previous.presence) |old_presence| {
        const new_presence = next.presence orelse return error.InvalidTransition;
        if (std.mem.eql(u8, &old_presence.incarnation_id, &new_presence.incarnation_id)) {
            if (new_presence.incarnation_counter == old_presence.incarnation_counter) {
                if (new_presence.sequence <= old_presence.sequence) return error.InvalidTransition;
            } else if (new_presence.incarnation_counter <= old_presence.incarnation_counter or
                new_presence.sequence != 1)
            {
                return error.InvalidTransition;
            }
        } else if (new_presence.incarnation_counter <= old_presence.incarnation_counter or
            new_presence.sequence != 1)
        {
            return error.InvalidTransition;
        }
    } else {
        const new_presence = next.presence orelse return error.InvalidTransition;
        if (new_presence.incarnation_counter != 1 or new_presence.sequence != 1)
            return error.InvalidTransition;
    }
    try validateOptionalProposalTransition(previous.vote, next.vote, false);
    try validateOptionalProposalTransition(
        previous.campaign,
        next.campaign,
        previous.presence != null and
            next.presence != null and
            (!std.mem.eql(
                u8,
                &previous.presence.?.incarnation_id,
                &next.presence.?.incarnation_id,
            ) or previous.presence.?.incarnation_counter != next.presence.?.incarnation_counter),
    );
}

pub fn validateAuthority(configuration: Configuration, authority: Authority) Error!void {
    try validateConfiguration(configuration);
    try validateAuthorityShape(authority);
    if (!std.mem.eql(u8, &configuration.domain_id, &authority.domain_id))
        return error.InvalidConfiguration;
    if (authority.active) |active| {
        try validateProposal(configuration, active.proposal);
        const mask = memberMask(configuration.member_count);
        if (active.voter_bitmap & ~mask != 0 or
            active.voter_bitmap & ~active.proposal.cohort_bitmap != 0 or
            @popCount(active.voter_bitmap) < configuration.quorum()) return error.MissingQuorum;
    }
}

pub fn validateAuthorityTransition(
    configuration: Configuration,
    previous: Authority,
    next: Authority,
    members: []const Member,
) Error!void {
    try validateAuthority(configuration, previous);
    try validateAuthority(configuration, next);
    const next_active = next.active orelse return error.InvalidTransition;
    if (previous.active) |old_active| {
        if (next_active.proposal.ballot.compare(old_active.proposal.ballot) != .gt)
            return error.InvalidTransition;
    }
    try validateAuthorityVotes(configuration, next, members);
}

pub fn validateAuthorityVotes(
    configuration: Configuration,
    authority: Authority,
    members: []const Member,
) Error!void {
    try validateAuthority(configuration, authority);
    const active = authority.active orelse return error.MissingQuorum;
    if (members.len != configuration.member_count) return error.InvalidConfiguration;
    for (members, 0..) |member, index| {
        try validateMember(configuration, member);
        if (member.slot != index) return error.InvalidMember;
        const bit = memberBit(@intCast(index));
        if (active.voter_bitmap & bit != 0) {
            const vote = member.vote orelse return error.MissingQuorum;
            if (!proposalEql(vote, active.proposal)) return error.MissingQuorum;
        }
    }
    const candidate = members[active.proposal.ballot.candidate_slot];
    const campaign = candidate.campaign orelse return error.MissingQuorum;
    if (!proposalEql(campaign, active.proposal)) return error.MissingQuorum;
}

pub fn validateConfiguration(configuration: Configuration) Error!void {
    if (isZero(&configuration.domain_id)) return error.InvalidConfiguration;
    if (configuration.member_count != 3 and configuration.member_count != 5)
        return error.InvalidConfiguration;
    for (configuration.members, 0..) |member_id, index| {
        if (index >= configuration.member_count) {
            if (!isZero(&member_id)) return error.NonCanonicalEncoding;
            continue;
        }
        if (isZero(&member_id)) return error.InvalidConfiguration;
        for (configuration.members[0..index]) |previous| {
            if (std.mem.eql(u8, &member_id, &previous)) return error.InvalidConfiguration;
        }
    }
}

fn validateMemberShape(member: Member) Error!void {
    if (isZero(&member.domain_id) or member.slot >= max_members) return error.InvalidMember;
    if (member.presence) |presence| {
        if (isZero(&presence.incarnation_id) or
            presence.incarnation_counter == 0 or
            presence.sequence == 0) return error.InvalidMember;
    } else if (member.campaign != null or member.vote != null) {
        return error.InvalidMember;
    }
    if (member.campaign) |campaign| {
        try validateProposalShape(campaign);
        const presence = member.presence orelse return error.InvalidMember;
        if (campaign.ballot.candidate_slot != member.slot or
            !std.mem.eql(
                u8,
                &campaign.ballot.candidate_incarnation_id,
                &presence.incarnation_id,
            ) or
            campaign.ballot.candidate_incarnation_counter != presence.incarnation_counter)
            return error.InvalidMember;
    }
    if (member.vote) |vote| try validateProposalShape(vote);
}

fn validateAuthorityShape(authority: Authority) Error!void {
    if (isZero(&authority.domain_id)) return error.InvalidConfiguration;
    if (authority.active) |active| {
        try validateProposalShape(active.proposal);
        if (active.voter_bitmap == 0 or
            active.voter_bitmap & ~active.proposal.cohort_bitmap != 0) return error.MissingQuorum;
    }
}

pub fn validateProposal(configuration: Configuration, proposal: Proposal) Error!void {
    try validateProposalShape(proposal);
    try validateBallot(configuration, proposal.ballot);
    const mask = memberMask(configuration.member_count);
    if (proposal.cohort_bitmap & ~mask != 0 or
        proposal.cohort_bitmap & memberBit(proposal.ballot.candidate_slot) == 0 or
        @popCount(proposal.cohort_bitmap) < configuration.quorum()) return error.MissingQuorum;
}

fn validateProposalShape(proposal: Proposal) Error!void {
    try validateBallotShape(proposal.ballot);
    if (proposal.cohort_bitmap == 0 or proposal.cohort_bitmap & ~memberMask(max_members) != 0)
        return error.InvalidBallot;
}

fn validateBallot(configuration: Configuration, ballot: Ballot) Error!void {
    try validateBallotShape(ballot);
    if (ballot.candidate_slot >= configuration.member_count) return error.InvalidBallot;
}

fn validateBallotShape(ballot: Ballot) Error!void {
    if (ballot.counter == 0 or ballot.candidate_slot >= max_members or
        isZero(&ballot.candidate_incarnation_id) or
        ballot.candidate_incarnation_counter == 0 or
        isZero(&ballot.proposal_id))
        return error.InvalidBallot;
}

fn validateOptionalProposalTransition(
    previous: ?Proposal,
    next: ?Proposal,
    allow_clear: bool,
) Error!void {
    const old = previous orelse return;
    const new = next orelse {
        if (allow_clear) return;
        return error.InvalidTransition;
    };
    const order = new.ballot.compare(old.ballot);
    if (order == .lt or (order == .eq and !proposalEql(new, old)))
        return error.InvalidTransition;
}

fn proposalEql(a: Proposal, b: Proposal) bool {
    return a.eql(b);
}

fn encodeHeader(encoded: *Encoded, magic: *const [8]u8, flags: u16) void {
    @memcpy(encoded[magic_start..magic_end], magic);
    std.mem.writeInt(u16, encoded[version_start..version_end], format_version, .big);
    std.mem.writeInt(u16, encoded[flags_start..flags_end], flags, .big);
}

fn decodeHeader(bytes: []const u8, magic: *const [8]u8, known_flags: u16) Error!*const Encoded {
    if (bytes.len != block_size) return error.InvalidSize;
    const encoded: *const Encoded = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, encoded[magic_start..magic_end], magic)) return error.InvalidMagic;
    if (readU16(encoded, version_start) != format_version) return error.UnsupportedFormatVersion;
    if (readU16(encoded, flags_start) & ~known_flags != 0) return error.InvalidFlags;
    return encoded;
}

fn encodeBallot(encoded: *Encoded, start: usize, ballot: Ballot) void {
    writeU64(encoded, start, ballot.counter);
    encoded[start + 8] = ballot.candidate_slot;
    @memcpy(encoded[start + 16 .. start + 32], &ballot.candidate_incarnation_id);
    writeU64(encoded, start + 32, ballot.candidate_incarnation_counter);
    @memcpy(encoded[start + 40 .. start + 56], &ballot.proposal_id);
}

fn decodeBallot(encoded: *const Encoded, start: usize) Ballot {
    return .{
        .counter = readU64(encoded, start),
        .candidate_slot = encoded[start + 8],
        .candidate_incarnation_id = encoded[start + 16 ..][0..16].*,
        .candidate_incarnation_counter = readU64(encoded, start + 32),
        .proposal_id = encoded[start + 40 ..][0..16].*,
    };
}

fn seal(encoded: *Encoded, checksum_start: usize) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    checksum(encoded, checksum_start, &digest);
    @memcpy(encoded[checksum_start .. checksum_start + digest.len], &digest);
}

fn verifyChecksum(encoded: *const Encoded, checksum_start: usize) Error!void {
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    checksum(encoded, checksum_start, &expected);
    if (!std.mem.eql(
        u8,
        encoded[checksum_start .. checksum_start + expected.len],
        &expected,
    )) return error.ChecksumMismatch;
}

fn checksum(
    encoded: *const Encoded,
    checksum_start: usize,
    result: *[std.crypto.hash.sha2.Sha256.digest_length]u8,
) void {
    var canonical = encoded.*;
    @memset(canonical[checksum_start .. checksum_start + result.len], 0);
    std.crypto.hash.sha2.Sha256.hash(&canonical, result, .{});
}

fn writeU64(encoded: *Encoded, start: usize, value: u64) void {
    std.mem.writeInt(u64, encoded[start..][0..@sizeOf(u64)], value, .big);
}

fn readU16(encoded: *const Encoded, start: usize) u16 {
    return std.mem.readInt(u16, encoded[start..][0..@sizeOf(u16)], .big);
}

fn readU64(encoded: *const Encoded, start: usize) u64 {
    return std.mem.readInt(u64, encoded[start..][0..@sizeOf(u64)], .big);
}

fn memberMask(member_count: u8) u8 {
    return (@as(u8, 1) << @intCast(member_count)) - 1;
}

fn memberBit(slot: u8) u8 {
    return @as(u8, 1) << @intCast(slot);
}

fn isZero(id: *const Id) bool {
    return allZero(id);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn testId(seed: u8) Id {
    var result: Id = undefined;
    for (&result, 0..) |*byte, index| byte.* = seed +% @as(u8, @intCast(index));
    return result;
}

fn testConfiguration(member_count: u8) Configuration {
    var members: [max_members]Id = @splat(@splat(0));
    for (0..member_count) |index| members[index] = testId(@intCast(0x20 + index * 0x10));
    return .{ .domain_id = testId(1), .member_count = member_count, .members = members };
}

fn testBallot(counter: u64, slot: u8) Ballot {
    return testBallotFor(counter, slot, testId(@intCast(0x80 + slot)), 1);
}

fn testBallotFor(counter: u64, slot: u8, incarnation_id: Id, incarnation_counter: u64) Ballot {
    return .{
        .counter = counter,
        .candidate_slot = slot,
        .candidate_incarnation_id = incarnation_id,
        .candidate_incarnation_counter = incarnation_counter,
        .proposal_id = testId(@intCast(0xa0 + counter)),
    };
}

fn testProposal(counter: u64, slot: u8, cohort_bitmap: u8) Proposal {
    return .{ .ballot = testBallot(counter, slot), .cohort_bitmap = cohort_bitmap };
}

test "voting configuration round trips canonically" {
    const configuration = testConfiguration(3);
    const encoded = try encodeConfiguration(configuration);
    const decoded = try decodeConfiguration(&encoded);
    try std.testing.expectEqualDeep(configuration, decoded);
    try std.testing.expectEqual(@as(u8, 2), decoded.quorum());
}

test "member record round trips presence campaign and vote" {
    const member = Member{
        .domain_id = testId(1),
        .slot = 1,
        .presence = .{
            .incarnation_id = testId(0x81),
            .incarnation_counter = 3,
            .sequence = 42,
        },
        .campaign = .{
            .ballot = testBallotFor(7, 1, testId(0x81), 3),
            .cohort_bitmap = 0b00111,
        },
        .vote = testProposal(8, 2, 0b00111),
    };
    const encoded = try encodeMember(member);
    try std.testing.expectEqualDeep(member, try decodeMember(&encoded));
}

test "authority record round trips a quorum certificate" {
    const authority = Authority{
        .domain_id = testId(1),
        .active = .{
            .proposal = .{ .ballot = testBallot(9, 0), .cohort_bitmap = 0b00111 },
            .voter_bitmap = 0b00101,
        },
    };
    const encoded = try encodeAuthority(authority);
    const decoded = try decodeAuthority(&encoded);
    try std.testing.expectEqualDeep(authority, decoded);
    try validateAuthority(testConfiguration(3), decoded);
}

test "configuration rejects invalid and duplicate members" {
    var count = testConfiguration(3);
    count.member_count = 4;
    try std.testing.expectError(error.InvalidConfiguration, encodeConfiguration(count));

    var duplicate = testConfiguration(3);
    duplicate.members[1] = duplicate.members[0];
    try std.testing.expectError(error.InvalidConfiguration, encodeConfiguration(duplicate));

    var trailing = testConfiguration(3);
    trailing.members[4] = testId(0xf0);
    try std.testing.expectError(error.NonCanonicalEncoding, encodeConfiguration(trailing));
}

test "member and authority transitions are monotonic" {
    const configuration = testConfiguration(3);
    const previous = Member{
        .domain_id = configuration.domain_id,
        .slot = 0,
        .presence = .{
            .incarnation_id = testId(0x80),
            .incarnation_counter = 2,
            .sequence = 4,
        },
        .campaign = null,
        .vote = testProposal(4, 0, 0b00111),
    };
    var next = previous;
    next.presence.?.sequence = 5;
    try validateMemberTransition(configuration, previous, next);
    next.vote = testProposal(3, 0, 0b00111);
    try std.testing.expectError(
        error.InvalidTransition,
        validateMemberTransition(configuration, previous, next),
    );

    const empty = Authority{ .domain_id = configuration.domain_id, .active = null };
    const active = Authority{ .domain_id = configuration.domain_id, .active = .{
        .proposal = .{ .ballot = testBallot(5, 0), .cohort_bitmap = 0b00111 },
        .voter_bitmap = 0b00011,
    } };
    var voters: [3]Member = undefined;
    for (&voters, 0..) |*member, index| member.* = .{
        .domain_id = configuration.domain_id,
        .slot = @intCast(index),
        .presence = .{
            .incarnation_id = if (index == 0) testId(0x80) else testId(@intCast(0x40 + index)),
            .incarnation_counter = 1,
            .sequence = 1,
        },
        .campaign = if (index == 0) active.active.?.proposal else null,
        .vote = if (index == 0 or index == 1) active.active.?.proposal else null,
    };
    try validateAuthorityTransition(configuration, empty, active, &voters);
    try std.testing.expectError(
        error.InvalidTransition,
        validateAuthorityTransition(configuration, active, active, &voters),
    );
}

test "authority requires matching durable votes" {
    const configuration = testConfiguration(3);
    const ballot = testBallot(5, 0);
    const authority = Authority{ .domain_id = configuration.domain_id, .active = .{
        .proposal = .{ .ballot = ballot, .cohort_bitmap = 0b00111 },
        .voter_bitmap = 0b00101,
    } };
    var members: [3]Member = undefined;
    for (&members, 0..) |*member, index| member.* = .{
        .domain_id = configuration.domain_id,
        .slot = @intCast(index),
        .presence = .{
            .incarnation_id = if (index == 0) ballot.candidate_incarnation_id else testId(@intCast(0x40 + index)),
            .incarnation_counter = 1,
            .sequence = 1,
        },
        .campaign = if (index == 0) authority.active.?.proposal else null,
        .vote = if (index == 0 or index == 2) authority.active.?.proposal else null,
    };
    try validateAuthorityVotes(configuration, authority, &members);
    members[2].vote = testProposal(6, 2, 0b00111);
    try std.testing.expectError(
        error.MissingQuorum,
        validateAuthorityVotes(configuration, authority, &members),
    );
}

test "voting records reject corruption and noncanonical bytes" {
    var encoded = try encodeMember(.{
        .domain_id = testId(1),
        .slot = 0,
        .presence = .{ .incarnation_id = testId(2), .incarnation_counter = 1, .sequence = 1 },
        .campaign = null,
        .vote = null,
    });
    encoded[presence_sequence_start] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeMember(&encoded));

    encoded = try encodeMember(.{
        .domain_id = testId(1),
        .slot = 0,
        .presence = .{ .incarnation_id = testId(2), .incarnation_counter = 1, .sequence = 1 },
        .campaign = null,
        .vote = null,
    });
    encoded[block_size - 1] = 1;
    seal(&encoded, member_checksum_start);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeMember(&encoded));
    try std.testing.expectError(error.InvalidSize, decodeMember(encoded[0 .. block_size - 1]));
}

test "voting v1 encodings match golden vectors" {
    const configuration = try encodeConfiguration(testConfiguration(3));
    const member = try encodeMember(.{
        .domain_id = testId(1),
        .slot = 1,
        .presence = .{
            .incarnation_id = testId(0x81),
            .incarnation_counter = 3,
            .sequence = 42,
        },
        .campaign = .{
            .ballot = testBallotFor(7, 1, testId(0x81), 3),
            .cohort_bitmap = 0b00111,
        },
        .vote = testProposal(8, 2, 0b00111),
    });
    const authority = try encodeAuthority(.{
        .domain_id = testId(1),
        .active = .{
            .proposal = .{ .ballot = testBallot(9, 0), .cohort_bitmap = 0b00111 },
            .voter_bitmap = 0b00101,
        },
    });
    try expectGolden(
        &configuration,
        "\x88\x5c\x58\x18\x92\x6c\xfc\x81\x3a\xb1\x2c\x36\x5f\x1d\x40\x37" ++
            "\x72\x96\x1d\x91\xc4\x67\x86\xca\x68\x94\x0c\xef\x74\x31\xb8\x3e",
    );
    try expectGolden(
        &member,
        "\x7a\x78\xca\x92\x7f\xbc\xd2\xc3\x70\x44\x29\x30\xb2\xbd\xb1\xd7" ++
            "\xbc\x87\x24\xef\x77\x0b\x73\x5b\x0f\x99\x01\x49\x7b\x44\x7a\x65",
    );
    try expectGolden(
        &authority,
        "\xcd\x86\x5e\xb5\x70\x3a\x60\x31\x68\xfc\xbe\x07\x61\x07\x6d\x8d" ++
            "\x86\x4c\x31\xe0\x98\x1c\xfd\xf7\x70\x05\x28\xd0\x6d\x1a\xe1\xe5",
    );
}

test "voting records reject headers flags and absent optional data" {
    var configuration = try encodeConfiguration(testConfiguration(3));
    std.mem.writeInt(u16, configuration[version_start..version_end], format_version + 1, .big);
    seal(&configuration, config_checksum_start);
    try std.testing.expectError(
        error.UnsupportedFormatVersion,
        decodeConfiguration(&configuration),
    );

    var member = try encodeMember(.{
        .domain_id = testId(1),
        .slot = 0,
        .presence = .{ .incarnation_id = testId(2), .incarnation_counter = 1, .sequence = 1 },
        .campaign = null,
        .vote = null,
    });
    std.mem.writeInt(u16, member[flags_start..flags_end], 1 << 15, .big);
    seal(&member, member_checksum_start);
    try std.testing.expectError(error.InvalidFlags, decodeMember(&member));

    member = try encodeMember(.{
        .domain_id = testId(1),
        .slot = 0,
        .presence = .{ .incarnation_id = testId(2), .incarnation_counter = 1, .sequence = 1 },
        .campaign = null,
        .vote = null,
    });
    member[campaign_counter_end - 1] = 1;
    seal(&member, member_checksum_start);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeMember(&member));

    var authority = try encodeAuthority(.{ .domain_id = testId(1), .active = null });
    authority[authority_counter_end - 1] = 1;
    seal(&authority, authority_checksum_start);
    try std.testing.expectError(error.NonCanonicalEncoding, decodeAuthority(&authority));
}

fn expectGolden(encoded: *const Encoded, expected: []const u8) !void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    try std.testing.expectEqualSlices(u8, expected, &digest);
}

test "authority votes bind the exact cohort and candidate campaign" {
    const configuration = testConfiguration(3);
    const proposal = testProposal(10, 0, 0b00111);
    const authority = Authority{ .domain_id = configuration.domain_id, .active = .{
        .proposal = proposal,
        .voter_bitmap = 0b00011,
    } };
    var members: [3]Member = undefined;
    for (&members, 0..) |*member, index| member.* = .{
        .domain_id = configuration.domain_id,
        .slot = @intCast(index),
        .presence = .{
            .incarnation_id = if (index == 0) proposal.ballot.candidate_incarnation_id else testId(@intCast(0x30 + index)),
            .incarnation_counter = 1,
            .sequence = 1,
        },
        .campaign = if (index == 0) proposal else null,
        .vote = if (index < 2) proposal else null,
    };
    try validateAuthorityVotes(configuration, authority, &members);

    members[1].vote.?.cohort_bitmap = 0b00011;
    try std.testing.expectError(
        error.MissingQuorum,
        validateAuthorityVotes(configuration, authority, &members),
    );
    members[1].vote = proposal;
    members[0].campaign = null;
    try std.testing.expectError(
        error.MissingQuorum,
        validateAuthorityVotes(configuration, authority, &members),
    );
}

test "member incarnation counter prevents record ABA" {
    const configuration = testConfiguration(3);
    const first = Member{
        .domain_id = configuration.domain_id,
        .slot = 0,
        .presence = .{
            .incarnation_id = testId(0x40),
            .incarnation_counter = 1,
            .sequence = 1,
        },
        .campaign = null,
        .vote = null,
    };
    var second = first;
    second.presence = .{
        .incarnation_id = testId(0x50),
        .incarnation_counter = 2,
        .sequence = 1,
    };
    try validateMemberTransition(configuration, first, second);
    var third = first;
    third.presence.?.incarnation_counter = 3;
    try validateMemberTransition(configuration, second, third);
    try std.testing.expect(!std.mem.eql(
        u8,
        &(try encodeMember(first)),
        &(try encodeMember(third)),
    ));

    var reused = first;
    reused.presence.?.incarnation_counter = 2;
    try std.testing.expectError(
        error.InvalidTransition,
        validateMemberTransition(configuration, second, reused),
    );
}

test "campaign belongs to its current member incarnation" {
    const configuration = testConfiguration(3);
    var member = Member{
        .domain_id = configuration.domain_id,
        .slot = 0,
        .presence = .{
            .incarnation_id = testId(0x40),
            .incarnation_counter = 1,
            .sequence = 1,
        },
        .campaign = .{
            .ballot = testBallotFor(1, 0, testId(0x40), 1),
            .cohort_bitmap = 0b00111,
        },
        .vote = null,
    };
    try validateMember(configuration, member);
    member.campaign.?.ballot.candidate_slot = 1;
    try std.testing.expectError(error.InvalidMember, validateMember(configuration, member));
    member.campaign.?.ballot.candidate_slot = 0;
    member.campaign.?.ballot.candidate_incarnation_id = testId(0x41);
    try std.testing.expectError(error.InvalidMember, validateMember(configuration, member));
    member.campaign.?.ballot.candidate_incarnation_id = testId(0x40);
    member.campaign.?.ballot.candidate_incarnation_counter = 2;
    try std.testing.expectError(error.InvalidMember, validateMember(configuration, member));
}

test "reused incarnation id cannot revive an old campaign" {
    const configuration = testConfiguration(3);
    const old_proposal = Proposal{
        .ballot = testBallotFor(2, 0, testId(0x40), 1),
        .cohort_bitmap = 0b00111,
    };
    const first = Member{
        .domain_id = configuration.domain_id,
        .slot = 0,
        .presence = .{
            .incarnation_id = testId(0x40),
            .incarnation_counter = 1,
            .sequence = 1,
        },
        .campaign = old_proposal,
        .vote = old_proposal,
    };
    const second = Member{
        .domain_id = configuration.domain_id,
        .slot = 0,
        .presence = .{
            .incarnation_id = testId(0x50),
            .incarnation_counter = 2,
            .sequence = 1,
        },
        .campaign = null,
        .vote = old_proposal,
    };
    try validateMemberTransition(configuration, first, second);
    var revived = second;
    revived.presence = .{
        .incarnation_id = testId(0x40),
        .incarnation_counter = 3,
        .sequence = 1,
    };
    revived.campaign = old_proposal;
    try std.testing.expectError(error.InvalidMember, validateMember(configuration, revived));
}

test "five-member authority requires three exact votes" {
    const configuration = testConfiguration(5);
    const proposal = testProposal(4, 0, 0b11111);
    var authority = Authority{ .domain_id = configuration.domain_id, .active = .{
        .proposal = proposal,
        .voter_bitmap = 0b00111,
    } };
    try validateAuthority(configuration, authority);
    authority.active.?.voter_bitmap = 0b00011;
    try std.testing.expectError(error.MissingQuorum, validateAuthority(configuration, authority));
}
