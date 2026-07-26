const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const journal = @import("journal.zig");
const membership = @import("membership.zig");
const pool_certificate = @import("pool_certificate.zig");
const pool_evidence = @import("pool_evidence.zig");
const pool_genesis = @import("pool_genesis_payload.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const Kind = enum { genesis, generation_commit, membership_commit, member_bootstrap };

pub const Authority = struct {
    kind: Kind,
    history_digest: codec.Digest,
    data_root_digest: codec.Digest,
    topology: pool_topology.Topology,
    layout: pool_layout.Layout,
    membership_epoch: u64,
    writer_term: u64,
    generation: u64,
    witness_count: u16,
    administrative_recovery: bool = false,

    pub fn evidence(self: Authority) !pool_evidence.Authority {
        return .{
            .history_digest = self.history_digest,
            .data_root_digest = self.data_root_digest,
            .topology_digest = try pool_topology.digest(self.topology),
            .layout_digest = try pool_layout.digest(self.layout),
            .membership_epoch = self.membership_epoch,
            .writer_term = self.writer_term,
            .generation = self.generation,
        };
    }
};

pub fn select(histories: []const *const journal.HistoryScan) !Authority {
    try validateUniqueHistories(histories);
    var authority = try selectGenesis(histories);
    while (true) {
        var next: ?Authority = null;
        for (histories) |history| {
            for (history.entries()) |entry| {
                if (std.mem.eql(u8, &entry.record.history_digest, &authority.history_digest)) continue;
                const candidate = try validateCandidate(histories, authority, history, entry) orelse continue;
                if (next) |selected| {
                    if (!std.mem.eql(u8, &selected.history_digest, &candidate.history_digest))
                        return error.ConflictingAuthority;
                    continue;
                }
                next = candidate;
            }
        }
        authority = next orelse return authority;
    }
}

fn selectGenesis(histories: []const *const journal.HistoryScan) !Authority {
    var selected: ?Authority = null;
    for (histories) |history| {
        if (history.entries().len == 0) continue;
        const record = try verifiedWitness(history, &history.entries()[0]);
        if (record.kind != control_record.genesis_kind) continue;
        const payload = pool_genesis.validateRecord(record) catch continue;
        const witnesses = try countVoterWitnesses(
            histories,
            record.history_digest,
            control_record.genesis_kind,
            payload.topology,
        );
        if (witnesses < payload.topology.quorum) continue;
        const candidate: Authority = .{
            .kind = .genesis,
            .history_digest = record.history_digest,
            .data_root_digest = record.data_root_digest,
            .topology = payload.topology,
            .layout = payload.layout,
            .membership_epoch = record.membership_epoch,
            .writer_term = record.writer_term,
            .generation = record.generation,
            .witness_count = witnesses,
        };
        if (selected) |current| {
            if (!std.mem.eql(u8, &current.history_digest, &candidate.history_digest))
                return error.AmbiguousGenesisAuthority;
        } else {
            selected = candidate;
        }
    }
    return selected orelse error.NoGenesisQuorum;
}

fn validateCandidate(
    histories: []const *const journal.HistoryScan,
    current: Authority,
    history: *const journal.HistoryScan,
    entry: journal.HistoryEntry,
) !?Authority {
    return switch (entry.record.kind) {
        control_record.generation_commit_kind => try validateGenerationCandidate(histories, current, history, entry),
        control_record.membership_commit_kind => try validateMembershipCandidate(histories, current, history, entry),
        control_record.member_bootstrap_kind => try validateBootstrapCandidate(histories, current, entry),
        else => null,
    };
}

fn validateGenerationCandidate(
    histories: []const *const journal.HistoryScan,
    current: Authority,
    history: *const journal.HistoryScan,
    entry: journal.HistoryEntry,
) !?Authority {
    if (!prepareExtends(histories, entry.record.previous_history_digest, current.history_digest)) return null;
    _ = try pool_evidence.validateGenerationCommitEvidence(
        history.member_id,
        entry.raw_record_digest,
        histories,
        current.topology,
        try current.evidence(),
    );
    const witnesses = try countVoterWitnesses(
        histories,
        entry.record.history_digest,
        control_record.generation_commit_kind,
        current.topology,
    );
    if (witnesses < current.topology.quorum) return null;
    return .{
        .kind = .generation_commit,
        .history_digest = entry.record.history_digest,
        .data_root_digest = entry.record.data_root_digest,
        .topology = current.topology,
        .layout = current.layout,
        .membership_epoch = entry.record.membership_epoch,
        .writer_term = entry.record.writer_term,
        .generation = entry.record.generation,
        .witness_count = witnesses,
        .administrative_recovery = current.administrative_recovery,
    };
}

fn validateMembershipCandidate(
    histories: []const *const journal.HistoryScan,
    current: Authority,
    history: *const journal.HistoryScan,
    entry: journal.HistoryEntry,
) !?Authority {
    if (!prepareExtends(histories, entry.record.previous_history_digest, current.history_digest)) return null;
    const validated = try pool_evidence.validateMembershipCommitEvidence(
        history.member_id,
        entry.raw_record_digest,
        histories,
        current.topology,
        try current.evidence(),
    );
    const old_witnesses = try countVoterWitnesses(
        histories,
        entry.record.history_digest,
        control_record.membership_commit_kind,
        current.topology,
    );
    const new_witnesses = try countVoterWitnesses(
        histories,
        entry.record.history_digest,
        control_record.membership_commit_kind,
        validated.proposal.topology,
    );
    switch (validated.proposal.mode) {
        .normal => if (old_witnesses < current.topology.quorum or
            new_witnesses < validated.proposal.topology.quorum) return null,
        .administrative_recovery => if (new_witnesses < validated.proposal.topology.quorum) return null,
    }
    return .{
        .kind = .membership_commit,
        .history_digest = entry.record.history_digest,
        .data_root_digest = entry.record.data_root_digest,
        .topology = validated.proposal.topology,
        .layout = current.layout,
        .membership_epoch = entry.record.membership_epoch,
        .writer_term = entry.record.writer_term,
        .generation = entry.record.generation,
        .witness_count = new_witnesses,
        .administrative_recovery = current.administrative_recovery or
            validated.proposal.mode == .administrative_recovery,
    };
}

fn validateBootstrapCandidate(
    histories: []const *const journal.HistoryScan,
    current: Authority,
    entry: journal.HistoryEntry,
) !?Authority {
    if (!std.mem.eql(u8, &entry.record.previous_history_digest, &current.history_digest)) return null;
    const validated = try pool_evidence.validateMemberBootstrapEvidence(
        entry.record.history_digest,
        histories,
        current.topology,
        current.layout,
        try current.evidence(),
    );
    return .{
        .kind = .member_bootstrap,
        .history_digest = entry.record.history_digest,
        .data_root_digest = entry.record.data_root_digest,
        .topology = current.topology,
        .layout = current.layout,
        .membership_epoch = entry.record.membership_epoch,
        .writer_term = entry.record.writer_term,
        .generation = entry.record.generation,
        .witness_count = validated.voter_witness_count,
        .administrative_recovery = current.administrative_recovery,
    };
}

fn prepareExtends(
    histories: []const *const journal.HistoryScan,
    prepare_history_digest: codec.Digest,
    authority_history_digest: codec.Digest,
) bool {
    for (histories) |history| {
        const entry = history.findHistoryDigest(prepare_history_digest) orelse continue;
        if ((entry.record.kind == control_record.generation_prepare_kind or
            entry.record.kind == control_record.membership_prepare_kind) and
            std.mem.eql(u8, &entry.record.previous_history_digest, &authority_history_digest)) return true;
    }
    return false;
}

fn countVoterWitnesses(
    histories: []const *const journal.HistoryScan,
    history_digest: codec.Digest,
    kind: u16,
    topology: pool_topology.Topology,
) !u16 {
    var count: u16 = 0;
    for (histories) |history| {
        const member = pool_topology.findMember(&topology, history.member_id) orelse continue;
        if (member.control_role != pool_topology.voter_role) continue;
        const entry = history.findHistoryDigest(history_digest) orelse continue;
        const record = try verifiedWitness(history, entry);
        if (record.kind == kind) count += 1;
    }
    return count;
}

fn verifiedWitness(
    history: *const journal.HistoryScan,
    entry: *const journal.HistoryEntry,
) !control_record.Record {
    if (!std.mem.eql(u8, &entry.raw_record_digest, &control_record.recordDigest(&entry.raw_record)))
        return error.EvidenceRecordDigestMismatch;
    const record = try control_record.decode(&entry.raw_record);
    try control_record.validateDynamicPoolPolicy(record);
    if (!std.meta.eql(record, entry.record)) return error.EvidenceRecordMismatch;
    if (!std.mem.eql(u8, &record.member_id, &history.member_id)) return error.WitnessMemberMismatch;
    return record;
}

fn validateUniqueHistories(histories: []const *const journal.HistoryScan) !void {
    for (histories, 0..) |history, index| {
        for (histories[0..index]) |previous| {
            if (std.mem.eql(u8, &history.member_id, &previous.member_id))
                return error.DuplicateMemberHistory;
        }
    }
}

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn testTopology() !pool_topology.Topology {
    const members = [_]pool_topology.Member{.{
        .member_id = id(2),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = 3,
    }};
    return pool_topology.Topology.init(id(1), 1, @splat(0), &members);
}

fn makeEntry(record: control_record.Record, raw: [control_record.encoded_size]u8, slot: u64) journal.HistoryEntry {
    return .{
        .record = record,
        .raw_record = raw,
        .raw_record_digest = control_record.recordDigest(&raw),
        .physical_slot = slot,
    };
}

fn makeHistory(entries: []journal.HistoryEntry) journal.HistoryScan {
    return .{
        .scan_result = .{ .slot_count = entries.len },
        .member_id = id(2),
        .storage = entries,
        .entry_count = entries.len,
        .allocator = std.testing.allocator,
    };
}

test "authority advances from one-member genesis through generation commit" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const payload: pool_genesis.GenesisPayload = .{ .topology = topology, .layout = layout };
    const genesis = try pool_genesis.makeRecord(id(2), payload);
    const genesis_raw = try control_record.encodeDynamicPool(genesis);

    var prepare: control_record.Record = .{
        .kind = control_record.generation_prepare_kind,
        .local_sequence = 2,
        .membership_epoch = 1,
        .writer_term = 1,
        .generation = 1,
        .set_id = topology.set_id,
        .member_id = id(2),
        .mount_session_id = id(3),
        .transaction_id = id(4),
        .previous_record_digest = control_record.recordDigest(&genesis_raw),
        .previous_history_digest = genesis.history_digest,
        .data_root_digest = @splat(0x55),
        .topology_digest = try pool_topology.digest(topology),
        .layout_digest = try pool_layout.digest(layout),
        .payload = try control_record.Payload.init("prepare"),
    };
    prepare.history_digest = try control_record.historyDigest(prepare);
    const prepare_raw = try control_record.encodeDynamicPool(prepare);
    const certificate: pool_certificate.Certificate = .{
        .count = 1,
        .attestations = .{
            .{
                .member_id = id(2),
                .prepare_record_digest = control_record.recordDigest(&prepare_raw),
                .prepare_history_digest = prepare.history_digest,
            },
            .{ .member_id = @splat(0), .prepare_record_digest = @splat(0), .prepare_history_digest = @splat(0) },
        },
    };
    var commit = prepare;
    commit.kind = control_record.generation_commit_kind;
    commit.local_sequence = 3;
    commit.previous_record_digest = control_record.recordDigest(&prepare_raw);
    commit.previous_history_digest = prepare.history_digest;
    commit.payload = try control_record.Payload.init(&(try pool_certificate.encode(certificate)));
    commit.history_digest = try control_record.historyDigest(commit);
    const commit_raw = try control_record.encodeDynamicPool(commit);

    var entries = [_]journal.HistoryEntry{
        makeEntry(genesis, genesis_raw, 0),
        makeEntry(prepare, prepare_raw, 1),
        makeEntry(commit, commit_raw, 2),
    };
    var history = makeHistory(&entries);
    const histories = [_]*const journal.HistoryScan{&history};
    const authority = try select(&histories);
    try std.testing.expectEqual(Kind.generation_commit, authority.kind);
    try std.testing.expectEqual(@as(u64, 1), authority.generation);
    try std.testing.expectEqualSlices(u8, &commit.history_digest, &authority.history_digest);
}

test "authority does not advance a commit without commit quorum" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const payload: pool_genesis.GenesisPayload = .{ .topology = topology, .layout = layout };
    const genesis = try pool_genesis.makeRecord(id(2), payload);
    const genesis_raw = try control_record.encodeDynamicPool(genesis);
    var entries = [_]journal.HistoryEntry{makeEntry(genesis, genesis_raw, 0)};
    var history = makeHistory(&entries);
    const histories = [_]*const journal.HistoryScan{&history};
    const authority = try select(&histories);
    try std.testing.expectEqual(Kind.genesis, authority.kind);
}
