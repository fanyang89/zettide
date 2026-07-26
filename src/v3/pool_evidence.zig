const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const journal = @import("journal.zig");
const membership = @import("membership.zig");
const pool_topology = @import("pool_topology.zig");

pub const Authority = struct {
    history_digest: codec.Digest,
    data_root_digest: codec.Digest,
    layout_digest: codec.Digest,
    membership_epoch: u64,
    writer_term: u64,
    generation: u64,
};

pub const ValidatedMembership = struct {
    proposal: membership.Proposal,
    certificate: membership.Certificate,
};

pub fn validateMembershipCommitEvidence(
    commit_member_id: [16]u8,
    commit_raw_record_digest: codec.Digest,
    histories: []const *const journal.HistoryScan,
    current_topology: pool_topology.Topology,
    authority: Authority,
) !ValidatedMembership {
    try pool_topology.validate(current_topology);
    if (authority.membership_epoch != current_topology.epoch) return error.AuthorityTopologyMismatch;
    const commit_entry = try findEvidenceRecord(
        histories,
        commit_member_id,
        commit_raw_record_digest,
        error.MissingCommitMember,
        error.MissingCommitRecord,
    );
    const commit = try verifiedRecord(commit_entry);
    if (commit.kind != control_record.membership_commit_kind) return error.NotMembershipCommit;
    if (!std.mem.eql(u8, &commit.member_id, &commit_member_id)) return error.CommitMemberMismatch;
    const proposal = try membership.validateRecordProposal(commit);
    try membership.validateTransition(current_topology, proposal);
    if (!isVoter(current_topology, commit.member_id) and !isVoter(proposal.topology, commit.member_id))
        return error.CommitMemberIsNotVoter;
    try validateAuthorityBinding(commit, authority);

    var certificate_bytes: [membership.certificate_size]u8 = undefined;
    @memcpy(&certificate_bytes, commit.payload.slice()[membership.proposal_size..]);
    const certificate = try membership.decodeCertificate(
        current_topology,
        proposal.topology,
        proposal.mode,
        &certificate_bytes,
    );
    const attestation_count = @as(usize, certificate.old_count) + certificate.new_count;
    const prepare_history_digest = certificate.attestations[0].prepare_history_digest;
    if (!std.mem.eql(u8, &commit.previous_history_digest, &prepare_history_digest))
        return error.CommitDoesNotExtendPrepare;

    const proposal_bytes = commit.payload.slice()[0..membership.proposal_size];
    for (certificate.attestations[0..attestation_count]) |attestation| {
        const prepare_entry = try findEvidenceRecord(
            histories,
            attestation.member_id,
            attestation.prepare_record_digest,
            error.MissingPrepareMember,
            error.MissingPrepareRecord,
        );
        const prepare = try verifiedRecord(prepare_entry);
        if (prepare.kind != control_record.membership_prepare_kind)
            return error.AttestedRecordIsNotMembershipPrepare;
        if (!std.mem.eql(u8, &prepare.member_id, &attestation.member_id))
            return error.PrepareMemberMismatch;
        if (!std.mem.eql(u8, &prepare.history_digest, &attestation.prepare_history_digest))
            return error.PrepareHistoryDigestMismatch;
        if (!std.mem.eql(u8, prepare.payload.slice(), proposal_bytes))
            return error.MembershipProposalMismatch;
        _ = try membership.validateRecordProposal(prepare);
        try validatePrepareCommitBinding(prepare, commit, authority.history_digest);
    }
    return .{ .proposal = proposal, .certificate = certificate };
}

fn validateAuthorityBinding(record: control_record.Record, authority: Authority) !void {
    if (record.writer_term != authority.writer_term or record.generation != authority.generation or
        !std.mem.eql(u8, &record.data_root_digest, &authority.data_root_digest) or
        !std.mem.eql(u8, &record.layout_digest, &authority.layout_digest))
        return error.MembershipChangedAuthorityData;
}

fn validatePrepareCommitBinding(
    prepare: control_record.Record,
    commit: control_record.Record,
    authority_history_digest: codec.Digest,
) !void {
    if (!std.mem.eql(u8, &prepare.previous_history_digest, &authority_history_digest))
        return error.PrepareDoesNotExtendAuthority;
    if (!std.mem.eql(u8, &prepare.history_digest, &commit.previous_history_digest))
        return error.CommitDoesNotExtendPrepare;
    if (!std.mem.eql(u8, &prepare.set_id, &commit.set_id) or
        prepare.membership_epoch != commit.membership_epoch or
        prepare.writer_term != commit.writer_term or prepare.generation != commit.generation or
        !std.mem.eql(u8, &prepare.mount_session_id, &commit.mount_session_id) or
        !std.mem.eql(u8, &prepare.transaction_id, &commit.transaction_id) or
        !std.mem.eql(u8, &prepare.data_root_digest, &commit.data_root_digest) or
        !std.mem.eql(u8, &prepare.topology_digest, &commit.topology_digest) or
        !std.mem.eql(u8, &prepare.layout_digest, &commit.layout_digest))
        return error.PrepareCommitMismatch;
}

fn isVoter(topology: pool_topology.Topology, member_id: [16]u8) bool {
    const member = pool_topology.findMember(&topology, member_id) orelse return false;
    return member.control_role == pool_topology.voter_role;
}

fn findEvidenceRecord(
    histories: []const *const journal.HistoryScan,
    member_id: [16]u8,
    raw_record_digest: codec.Digest,
    missing_member_error: anyerror,
    missing_record_error: anyerror,
) !*const journal.HistoryEntry {
    var matching_history: ?*const journal.HistoryScan = null;
    for (histories) |history| {
        if (!std.mem.eql(u8, &history.member_id, &member_id)) continue;
        if (matching_history != null) return error.DuplicateMemberHistory;
        matching_history = history;
    }
    const history = matching_history orelse return missing_member_error;
    return history.findRawRecordDigest(raw_record_digest) orelse missing_record_error;
}

fn verifiedRecord(entry: *const journal.HistoryEntry) !control_record.Record {
    if (!std.mem.eql(u8, &entry.raw_record_digest, &control_record.recordDigest(&entry.raw_record)))
        return error.EvidenceRecordDigestMismatch;
    const record = try control_record.decode(&entry.raw_record);
    try control_record.validateDynamicPoolPolicy(record);
    if (!std.meta.eql(record, entry.record)) return error.EvidenceRecordMismatch;
    return record;
}

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn currentTopology() !pool_topology.Topology {
    const members = [_]pool_topology.Member{.{
        .member_id = id(2),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = 3,
    }};
    return pool_topology.Topology.init(id(1), 1, @splat(0), &members);
}

fn testProposal(current: pool_topology.Topology) !membership.Proposal {
    const members = [_]pool_topology.Member{
        current.members[0],
        .{ .member_id = id(3), .slot = 19, .state = .joining },
    };
    return .{
        .mode = .normal,
        .topology = try pool_topology.Topology.init(current.set_id, 2, try pool_topology.digest(current), &members),
    };
}

fn testAuthority() Authority {
    return .{
        .history_digest = @splat(0x11),
        .data_root_digest = @splat(0x22),
        .layout_digest = @splat(0x33),
        .membership_epoch = 1,
        .writer_term = 4,
        .generation = 9,
    };
}

fn prepareRecord(proposed: membership.Proposal, current_authority: Authority) !control_record.Record {
    var record: control_record.Record = .{
        .kind = control_record.membership_prepare_kind,
        .local_sequence = 2,
        .membership_epoch = proposed.topology.epoch,
        .writer_term = current_authority.writer_term,
        .generation = current_authority.generation,
        .set_id = proposed.topology.set_id,
        .member_id = id(2),
        .mount_session_id = id(4),
        .transaction_id = id(5),
        .previous_record_digest = @splat(0x44),
        .previous_history_digest = current_authority.history_digest,
        .data_root_digest = current_authority.data_root_digest,
        .topology_digest = try pool_topology.digest(proposed.topology),
        .layout_digest = current_authority.layout_digest,
        .payload = try membership.makePreparePayload(proposed),
    };
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

fn commitRecord(
    current: pool_topology.Topology,
    proposed: membership.Proposal,
    current_authority: Authority,
    prepare: control_record.Record,
    prepare_raw: *const [control_record.encoded_size]u8,
) !control_record.Record {
    const witness: control_record.Attestation = .{
        .member_id = prepare.member_id,
        .prepare_record_digest = control_record.recordDigest(prepare_raw),
        .prepare_history_digest = prepare.history_digest,
    };
    var certificate: membership.Certificate = .{
        .old_count = 1,
        .new_count = 1,
        .attestations = @splat(.{
            .member_id = @splat(0),
            .prepare_record_digest = @splat(0),
            .prepare_history_digest = @splat(0),
        }),
    };
    certificate.attestations[0] = witness;
    certificate.attestations[1] = witness;
    var record = prepare;
    record.kind = control_record.membership_commit_kind;
    record.local_sequence += 1;
    record.previous_record_digest = control_record.recordDigest(prepare_raw);
    record.previous_history_digest = prepare.history_digest;
    record.payload = try membership.makeCommitPayload(current, proposed, certificate);
    record.history_digest = try control_record.historyDigest(record);
    try validateAuthorityBinding(record, current_authority);
    return record;
}

fn testHistory(entries: []journal.HistoryEntry) journal.HistoryScan {
    return .{
        .scan_result = .{ .slot_count = entries.len },
        .member_id = id(2),
        .storage = entries,
        .entry_count = entries.len,
        .allocator = std.testing.allocator,
    };
}

test "membership commit evidence binds exact prepares and authority data" {
    const current = try currentTopology();
    const proposed = try testProposal(current);
    const current_authority = testAuthority();
    const prepare = try prepareRecord(proposed, current_authority);
    const prepare_raw = try control_record.encodeDynamicPool(prepare);
    const commit = try commitRecord(current, proposed, current_authority, prepare, &prepare_raw);
    const commit_raw = try control_record.encodeDynamicPool(commit);
    var entries = [_]journal.HistoryEntry{
        .{ .record = prepare, .raw_record = prepare_raw, .raw_record_digest = control_record.recordDigest(&prepare_raw), .physical_slot = 1 },
        .{ .record = commit, .raw_record = commit_raw, .raw_record_digest = control_record.recordDigest(&commit_raw), .physical_slot = 2 },
    };
    var member_history = testHistory(&entries);
    const histories = [_]*const journal.HistoryScan{&member_history};
    const validated = try validateMembershipCommitEvidence(
        id(2),
        entries[1].raw_record_digest,
        &histories,
        current,
        current_authority,
    );
    try std.testing.expectEqual(@as(u64, 2), validated.proposal.topology.epoch);
}

test "membership evidence rejects changed authority data and detached prepare" {
    const current = try currentTopology();
    const proposed = try testProposal(current);
    const current_authority = testAuthority();
    var prepare = try prepareRecord(proposed, current_authority);
    const valid_prepare_raw = try control_record.encodeDynamicPool(prepare);
    var commit = try commitRecord(current, proposed, current_authority, prepare, &valid_prepare_raw);
    commit.data_root_digest[0] ^= 1;
    commit.history_digest = try control_record.historyDigest(commit);
    var commit_raw = try control_record.encodeDynamicPool(commit);
    var entries = [_]journal.HistoryEntry{
        .{ .record = prepare, .raw_record = valid_prepare_raw, .raw_record_digest = control_record.recordDigest(&valid_prepare_raw), .physical_slot = 1 },
        .{ .record = commit, .raw_record = commit_raw, .raw_record_digest = control_record.recordDigest(&commit_raw), .physical_slot = 2 },
    };
    var member_history = testHistory(&entries);
    const histories = [_]*const journal.HistoryScan{&member_history};
    try std.testing.expectError(
        error.MembershipChangedAuthorityData,
        validateMembershipCommitEvidence(id(2), entries[1].raw_record_digest, &histories, current, current_authority),
    );

    prepare.previous_history_digest = @splat(0x77);
    prepare.history_digest = try control_record.historyDigest(prepare);
    const prepare_raw = try control_record.encodeDynamicPool(prepare);
    commit = try commitRecord(current, proposed, current_authority, prepare, &prepare_raw);
    commit_raw = try control_record.encodeDynamicPool(commit);
    entries[0] = .{ .record = prepare, .raw_record = prepare_raw, .raw_record_digest = control_record.recordDigest(&prepare_raw), .physical_slot = 1 };
    entries[1] = .{ .record = commit, .raw_record = commit_raw, .raw_record_digest = control_record.recordDigest(&commit_raw), .physical_slot = 2 };
    try std.testing.expectError(
        error.PrepareDoesNotExtendAuthority,
        validateMembershipCommitEvidence(id(2), entries[1].raw_record_digest, &histories, current, current_authority),
    );
}
