//! Pure state transitions for fixed-membership shared-disk voting.

const std = @import("std");
const voting = @import("voting.zig");

pub const Error = voting.Error || error{
    CounterExhausted,
    SequenceExhausted,
    MemberNotPresent,
    MemberNotInCohort,
    MissingCampaign,
    StaleProposal,
    InconsistentSnapshot,
};

pub const CawResolution = enum {
    applied,
    superseded,
    pending,
};

pub fn resolveCaw(
    expected: *const voting.Encoded,
    replacement: *const voting.Encoded,
    current: *const voting.Encoded,
) CawResolution {
    if (std.mem.eql(u8, replacement, current)) return .applied;
    if (std.mem.eql(u8, expected, current)) return .pending;
    return .superseded;
}

pub fn startIncarnation(
    configuration: voting.Configuration,
    current: voting.Member,
    incarnation_id: voting.Id,
) Error!voting.Member {
    try voting.validateMember(configuration, current);
    const incarnation_counter = if (current.presence) |presence| blk: {
        if (presence.incarnation_counter == std.math.maxInt(u64)) return error.CounterExhausted;
        break :blk presence.incarnation_counter + 1;
    } else 1;
    const next = voting.Member{
        .domain_id = current.domain_id,
        .slot = current.slot,
        .presence = .{
            .incarnation_id = incarnation_id,
            .incarnation_counter = incarnation_counter,
            .sequence = 1,
        },
        .campaign = null,
        .vote = current.vote,
    };
    try voting.validateMemberTransition(configuration, current, next);
    return next;
}

pub fn heartbeat(
    configuration: voting.Configuration,
    current: voting.Member,
) Error!voting.Member {
    try voting.validateMember(configuration, current);
    var next = current;
    const presence = current.presence orelse return error.MemberNotPresent;
    if (presence.sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
    next.presence.?.sequence += 1;
    try voting.validateMemberTransition(configuration, current, next);
    return next;
}

pub fn beginCampaign(
    configuration: voting.Configuration,
    current: voting.Member,
    authority: voting.Authority,
    members: []const voting.Member,
    proposal_id: voting.Id,
    cohort_bitmap: u8,
) Error!voting.Member {
    try validateSnapshot(configuration, authority, members);
    try voting.validateMember(configuration, current);
    if (current.slot >= members.len or !std.meta.eql(current, members[current.slot]))
        return error.InconsistentSnapshot;
    const presence = current.presence orelse return error.MemberNotPresent;

    var highest: u64 = 0;
    if (authority.active) |active| highest = active.proposal.ballot.counter;
    for (members) |member| {
        if (member.campaign) |campaign| highest = @max(highest, campaign.ballot.counter);
        if (member.vote) |vote| highest = @max(highest, vote.ballot.counter);
    }
    if (highest == std.math.maxInt(u64)) return error.CounterExhausted;
    const proposal = voting.Proposal{
        .ballot = .{
            .counter = highest + 1,
            .candidate_slot = current.slot,
            .candidate_incarnation_id = presence.incarnation_id,
            .candidate_incarnation_counter = presence.incarnation_counter,
            .proposal_id = proposal_id,
        },
        .cohort_bitmap = cohort_bitmap,
    };
    try voting.validateProposal(configuration, proposal);

    var next = try heartbeat(configuration, current);
    next.campaign = proposal;
    next.vote = proposal;
    try voting.validateMemberTransition(configuration, current, next);
    return next;
}

pub fn castVote(
    configuration: voting.Configuration,
    current: voting.Member,
    authority: voting.Authority,
    candidate: voting.Member,
) Error!voting.Member {
    try voting.validateMember(configuration, current);
    try voting.validateMember(configuration, candidate);
    try voting.validateAuthority(configuration, authority);
    const proposal = candidate.campaign orelse return error.MissingCampaign;
    try voting.validateProposal(configuration, proposal);
    if (proposal.ballot.candidate_slot != candidate.slot) return error.MissingCampaign;
    if (proposal.cohort_bitmap & memberBit(current.slot) == 0) return error.MemberNotInCohort;
    if (authority.active) |active| {
        if (proposal.ballot.compare(active.proposal.ballot) != .gt) return error.StaleProposal;
    }
    if (current.vote) |vote| {
        const order = proposal.ballot.compare(vote.ballot);
        if (order == .lt or (order == .eq and !proposal.eql(vote))) return error.StaleProposal;
    }

    var next = try heartbeat(configuration, current);
    next.vote = proposal;
    try voting.validateMemberTransition(configuration, current, next);
    return next;
}

/// Forms the next authority from member records that have already crossed the
/// backend's durability barrier.
fn formAuthority(
    configuration: voting.Configuration,
    current: voting.Authority,
    members: []const voting.Member,
    proposal: voting.Proposal,
) Error!voting.Authority {
    try validateSnapshot(configuration, current, members);
    try voting.validateProposal(configuration, proposal);
    if (current.active) |active| {
        if (proposal.ballot.compare(active.proposal.ballot) != .gt) return error.StaleProposal;
    }

    var voter_bitmap: u8 = 0;
    for (members) |member| {
        if (proposal.cohort_bitmap & memberBit(member.slot) == 0) continue;
        if (member.vote) |vote| {
            if (proposal.eql(vote)) voter_bitmap |= memberBit(member.slot);
        }
    }
    const next = voting.Authority{
        .domain_id = configuration.domain_id,
        .active = .{ .proposal = proposal, .voter_bitmap = voter_bitmap },
    };
    try voting.validateAuthorityTransition(configuration, current, next, members);
    return next;
}

fn validateSnapshot(
    configuration: voting.Configuration,
    authority: voting.Authority,
    members: []const voting.Member,
) Error!void {
    try voting.validateConfiguration(configuration);
    try voting.validateAuthority(configuration, authority);
    if (members.len != configuration.member_count) return error.InconsistentSnapshot;
    for (members, 0..) |member, slot| {
        try voting.validateMember(configuration, member);
        if (member.slot != slot) return error.InconsistentSnapshot;
    }
}

fn memberBit(slot: u8) u8 {
    return @as(u8, 1) << @intCast(slot);
}

const ModelVotingDisk = @import("model_voting_disk.zig").ModelVotingDisk;
const ModelResult = @import("model_voting_disk.zig").Result;

fn id(seed: u8) voting.Id {
    var result: voting.Id = undefined;
    for (&result, 0..) |*byte, index| byte.* = seed +% @as(u8, @intCast(index));
    return result;
}

fn testConfiguration(member_count: u8) voting.Configuration {
    var members: [voting.max_members]voting.Id = @splat(@splat(0));
    for (0..member_count) |slot| members[slot] = id(@intCast(0x20 + slot * 0x10));
    return .{ .domain_id = id(1), .member_count = member_count, .members = members };
}

fn readMembers(
    disk: *ModelVotingDisk,
    configuration_value: voting.Configuration,
    members: *[voting.max_members]voting.Member,
) ![]voting.Member {
    for (members[0..configuration_value.member_count], 0..) |*member, slot| {
        member.* = try voting.decodeMember(&(try disk.readMember(@intCast(slot))));
    }
    return members[0..configuration_value.member_count];
}

fn startAll(disk: *ModelVotingDisk, configuration_value: voting.Configuration) !void {
    for (0..configuration_value.member_count) |slot| {
        const member_slot: u8 = @intCast(slot);
        const expected = try disk.readMember(member_slot);
        const current = try voting.decodeMember(&expected);
        const next = try startIncarnation(
            configuration_value,
            current,
            id(@intCast(0x80 + slot)),
        );
        try std.testing.expectEqual(
            ModelResult.written,
            try disk.compareAndWriteMember(
                member_slot,
                expected,
                try voting.encodeMember(next),
            ),
        );
    }
    disk.stabilize();
}

test "three-member election publishes authority after durable quorum" {
    const config = testConfiguration(3);
    var disk = try ModelVotingDisk.init(config);
    try startAll(&disk, config);

    var member_storage: [voting.max_members]voting.Member = undefined;
    var members = try readMembers(&disk, config, &member_storage);
    const initial_authority = try voting.decodeAuthority(&disk.readAuthority());
    const candidate = try beginCampaign(config, members[0], initial_authority, members, id(0xb0), 0b00111);
    var expected = try disk.readMember(0);
    try std.testing.expectEqual(
        ModelResult.written,
        try disk.compareAndWriteMember(0, expected, try voting.encodeMember(candidate)),
    );

    members = try readMembers(&disk, config, &member_storage);
    const voter = try castVote(config, members[1], initial_authority, members[0]);
    expected = try disk.readMember(1);
    try std.testing.expectEqual(
        ModelResult.written,
        try disk.compareAndWriteMember(1, expected, try voting.encodeMember(voter)),
    );
    disk.stabilize();

    members = try readMembers(&disk, config, &member_storage);
    const next_authority = try formAuthority(
        config,
        initial_authority,
        members,
        candidate.campaign.?,
    );
    const expected_authority = disk.readAuthority();
    try std.testing.expectEqual(
        ModelResult.written,
        try disk.compareAndWriteAuthority(
            expected_authority,
            try voting.encodeAuthority(next_authority),
        ),
    );
}

test "split votes cannot form authority" {
    const config = testConfiguration(3);
    var disk = try ModelVotingDisk.init(config);
    try startAll(&disk, config);
    var storage: [voting.max_members]voting.Member = undefined;
    var members = try readMembers(&disk, config, &storage);
    const authority = try voting.decodeAuthority(&disk.readAuthority());

    const first = try beginCampaign(config, members[0], authority, members, id(0xb0), 0b00111);
    members[0] = first;
    const second = try beginCampaign(config, members[1], authority, members, id(0xc0), 0b00111);
    members[1] = second;
    try std.testing.expectError(
        error.MissingQuorum,
        formAuthority(config, authority, members, first.campaign.?),
    );
    try std.testing.expectError(
        error.MissingQuorum,
        formAuthority(config, authority, members, second.campaign.?),
    );
}

test "five-member authority requires three votes" {
    const config = testConfiguration(5);
    var disk = try ModelVotingDisk.init(config);
    try startAll(&disk, config);
    var storage: [voting.max_members]voting.Member = undefined;
    var members = try readMembers(&disk, config, &storage);
    const authority = try voting.decodeAuthority(&disk.readAuthority());
    members[0] = try beginCampaign(config, members[0], authority, members, id(0xb0), 0b11111);
    members[1] = try castVote(config, members[1], authority, members[0]);
    try std.testing.expectError(
        error.MissingQuorum,
        formAuthority(config, authority, members, members[0].campaign.?),
    );
    members[2] = try castVote(config, members[2], authority, members[0]);
    _ = try formAuthority(config, authority, members, members[0].campaign.?);
}

test "candidate restart cannot inherit its old campaign" {
    const config = testConfiguration(3);
    var disk = try ModelVotingDisk.init(config);
    try startAll(&disk, config);
    var storage: [voting.max_members]voting.Member = undefined;
    var members = try readMembers(&disk, config, &storage);
    const authority = try voting.decodeAuthority(&disk.readAuthority());
    const campaign = try beginCampaign(config, members[0], authority, members, id(0xb0), 0b00111);
    var expected = try disk.readMember(0);
    try std.testing.expectEqual(
        ModelResult.written,
        try disk.compareAndWriteMember(0, expected, try voting.encodeMember(campaign)),
    );
    disk.stabilize();

    const restarted = try startIncarnation(config, campaign, id(0xd0));
    try std.testing.expectEqual(@as(?voting.Proposal, null), restarted.campaign);
    try std.testing.expect(restarted.vote.?.eql(campaign.vote.?));
    expected = try disk.readMember(0);
    try std.testing.expectEqual(
        ModelResult.written,
        try disk.compareAndWriteMember(0, expected, try voting.encodeMember(restarted)),
    );
    disk.stabilize();
    disk.crash();
    const recovered = try voting.decodeMember(&(try disk.readMember(0)));
    try std.testing.expectEqual(@as(?voting.Proposal, null), recovered.campaign);
    try std.testing.expect(recovered.vote.?.eql(campaign.vote.?));

    members[0] = restarted;
    members[1] = try castVote(config, members[1], authority, campaign);
    try std.testing.expectError(
        error.MissingQuorum,
        formAuthority(config, authority, members, campaign.campaign.?),
    );
}

test "member restart may reuse an incarnation id without ABA" {
    const config = testConfiguration(3);
    var disk = try ModelVotingDisk.init(config);
    try startAll(&disk, config);
    const encoded = try disk.readMember(0);
    const current = try voting.decodeMember(&encoded);
    const restarted = try startIncarnation(config, current, current.presence.?.incarnation_id);
    try std.testing.expectEqual(@as(u64, 2), restarted.presence.?.incarnation_counter);
    try std.testing.expectEqual(@as(u64, 1), restarted.presence.?.sequence);
    try std.testing.expect(!std.meta.eql(current, restarted));
}

test "concurrent campaigns use the candidate slot as ballot tie breaker" {
    const config = testConfiguration(3);
    var disk = try ModelVotingDisk.init(config);
    try startAll(&disk, config);
    var storage: [voting.max_members]voting.Member = undefined;
    const members = try readMembers(&disk, config, &storage);
    const authority = try voting.decodeAuthority(&disk.readAuthority());

    const first = try beginCampaign(config, members[0], authority, members, id(0xb0), 0b00111);
    const second = try beginCampaign(config, members[1], authority, members, id(0xc0), 0b00111);
    try std.testing.expectEqual(
        std.math.Order.lt,
        first.campaign.?.ballot.compare(second.campaign.?.ballot),
    );
    const lower_vote = try castVote(config, members[2], authority, first);
    const deciding_vote = try castVote(config, lower_vote, authority, second);
    try std.testing.expectError(
        error.StaleProposal,
        castVote(config, deciding_vote, authority, first),
    );
    var decided = members;
    decided[0] = first;
    decided[1] = second;
    decided[2] = deciding_vote;
    try std.testing.expectError(
        error.MissingQuorum,
        formAuthority(config, authority, decided, first.campaign.?),
    );
    const winner = try formAuthority(config, authority, decided, second.campaign.?);
    try std.testing.expect(winner.active.?.proposal.eql(second.campaign.?));
}

test "indeterminate CAW resolution distinguishes all outcomes" {
    var expected: voting.Encoded = @splat(0);
    var replacement = expected;
    replacement[0] = 1;
    var superseding = expected;
    superseding[0] = 2;
    try std.testing.expectEqual(CawResolution.pending, resolveCaw(&expected, &replacement, &expected));
    try std.testing.expectEqual(CawResolution.applied, resolveCaw(&expected, &replacement, &replacement));
    try std.testing.expectEqual(
        CawResolution.superseded,
        resolveCaw(&expected, &replacement, &superseding),
    );
}

test "indeterminate member CAW resolves from disk state" {
    const config = testConfiguration(3);
    var disk = try ModelVotingDisk.init(config);
    const expected = try disk.readMember(0);
    const current = try voting.decodeMember(&expected);
    const started = try startIncarnation(config, current, id(0x80));
    const replacement = try voting.encodeMember(started);

    disk.injectNextFault(.indeterminate_before);
    try std.testing.expectEqual(
        ModelResult.indeterminate,
        try disk.compareAndWriteMember(0, expected, replacement),
    );
    var observed = try disk.readMember(0);
    try std.testing.expectEqual(CawResolution.pending, resolveCaw(&expected, &replacement, &observed));

    disk.injectNextFault(.indeterminate_after);
    try std.testing.expectEqual(
        ModelResult.indeterminate,
        try disk.compareAndWriteMember(0, expected, replacement),
    );
    observed = try disk.readMember(0);
    try std.testing.expectEqual(CawResolution.applied, resolveCaw(&expected, &replacement, &observed));

    const successor = try voting.encodeMember(try heartbeat(config, started));
    try std.testing.expectEqual(
        ModelResult.written,
        try disk.compareAndWriteMember(0, replacement, successor),
    );
    observed = try disk.readMember(0);
    try std.testing.expectEqual(
        CawResolution.superseded,
        resolveCaw(&expected, &replacement, &observed),
    );
}
