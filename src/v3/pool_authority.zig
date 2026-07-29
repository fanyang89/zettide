const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const journal = @import("journal.zig");
const member_bootstrap = @import("member_bootstrap.zig");
const membership = @import("membership.zig");
const pool_certificate = @import("pool_certificate.zig");
const pool_authority_checkpoint = @import("pool_authority_checkpoint.zig");
const pool_evidence = @import("pool_evidence.zig");
const pool_genesis = @import("pool_genesis_payload.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const Kind = enum { genesis, generation_commit, membership_commit, member_bootstrap, checkpoint };

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

const CompactedRoot = struct {
    authority: Authority,
    parent_history_digest: codec.Digest,
};

pub fn select(histories: []const *const journal.HistoryScan) !Authority {
    try validateUniqueHistories(histories);
    const compacted: ?CompactedRoot = selectCompactedRoot(histories) catch |err| switch (err) {
        error.NoCompactedRootQuorum => null,
        else => return err,
    };
    const genesis: ?Authority = selectGenesis(histories) catch |err| switch (err) {
        error.NoGenesisQuorum => null,
        else => return err,
    };

    if (compacted) |root| {
        const selected = try advanceAuthority(histories, root.authority);
        if (genesis) |genesis_root| {
            const legacy = try advanceAuthority(histories, genesis_root);
            try reconcileCompactedRoot(root, selected, legacy);
        }
        const recovery: ?Authority = selectRecoveryRoot(histories) catch |err| switch (err) {
            error.NoGenesisQuorum => null,
            else => return err,
        };
        if (recovery) |candidate| try reconcileCompactedRoot(root, selected, candidate);
        return selected;
    }
    if (genesis) |root| return advanceAuthority(histories, root);
    return selectRecoveryRoot(histories);
}

fn advanceAuthority(histories: []const *const journal.HistoryScan, root: Authority) !Authority {
    var authority = root;
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

fn reconcileCompactedRoot(root: CompactedRoot, selected: Authority, candidate: Authority) !void {
    if (std.mem.eql(u8, &candidate.history_digest, &selected.history_digest) or
        std.mem.eql(u8, &candidate.history_digest, &root.authority.history_digest) or
        std.mem.eql(u8, &candidate.history_digest, &root.parent_history_digest)) return;
    if (candidate.kind == .genesis and
        std.mem.eql(u8, &candidate.topology.set_id, &root.authority.topology.set_id)) return;
    return error.ConflictingAuthority;
}

pub fn selectAdministrativeRecovery(history: *const journal.HistoryScan) !Authority {
    return selectLocalRecoveryAuthority(history, true);
}

fn selectLocalRecoveryAuthority(history: *const journal.HistoryScan, require_committed_tail: bool) !Authority {
    if (history.scan_result.unresolved_tail_damage and !history.scan_result.anchored)
        return error.JournalNeedsRecovery;
    if (history.scan_result.anchored) return selectAnchoredAdministrativeRecovery(history, require_committed_tail);
    if (history.entries().len == 0) return error.MissingGenesis;
    const genesis = try verifiedWitness(history, &history.entries()[0]);
    if (genesis.kind != control_record.genesis_kind) return error.MissingGenesis;
    const payload = try pool_genesis.validateRecord(genesis);
    if (!isVoter(payload.topology, history.member_id)) return error.TrustedMemberIsNotVoter;
    var authority: Authority = .{
        .kind = .genesis,
        .history_digest = genesis.history_digest,
        .data_root_digest = genesis.data_root_digest,
        .topology = payload.topology,
        .layout = payload.layout,
        .membership_epoch = genesis.membership_epoch,
        .writer_term = genesis.writer_term,
        .generation = genesis.generation,
        .witness_count = 1,
    };
    replay: for (history.entries()[1..]) |*entry| {
        const record = verifiedWitness(history, entry) catch |err| {
            if (require_committed_tail) return err;
            break :replay;
        };
        switch (record.kind) {
            control_record.generation_commit_kind => authority = replayLocalGeneration(history, authority, record) catch |err| {
                if (require_committed_tail) return err;
                break :replay;
            },
            control_record.membership_commit_kind => authority = replayLocalMembership(history, authority, record) catch |err| {
                if (require_committed_tail) return err;
                break :replay;
            },
            control_record.member_bootstrap_kind => authority = replayLocalBootstrap(authority, record) catch |err| {
                if (require_committed_tail) return err;
                break :replay;
            },
            control_record.checkpoint_kind => if (pool_authority_checkpoint.isSnapshotRecord(record)) {
                authority = replayLocalCheckpoint(authority, record) catch |err| {
                    if (require_committed_tail) return err;
                    break :replay;
                };
            },
            else => {},
        }
    }
    if (require_committed_tail) {
        const tail = history.scan_result.tail orelse return error.MissingGenesis;
        if (!std.mem.eql(u8, &tail.history_digest, &authority.history_digest))
            return error.RecoveryTailIsNotCommitted;
    }
    if (!isVoter(authority.topology, history.member_id)) return error.TrustedMemberIsNotCurrentVoter;
    return authority;
}

fn selectAnchoredAdministrativeRecovery(
    history: *const journal.HistoryScan,
    require_committed_tail: bool,
) !Authority {
    const anchor_state = history.scan_result.active_anchor orelse return error.MissingAuthorityAnchor;
    const anchor_entry = history.findRawRecordDigest(anchor_state.raw_record_digest) orelse
        return error.MissingAuthorityAnchor;
    if (anchor_entry.physical_slot != anchor_state.physical_slot) return error.MissingAuthorityAnchor;
    const record = try verifiedWitness(history, anchor_entry);
    const snapshot = try pool_authority_checkpoint.validateCompactedRootRecord(record);
    if (!isVoter(snapshot.topology, history.member_id)) return error.TrustedMemberIsNotVoter;
    var authority = authorityFromSnapshot(record, snapshot, 1);
    var after_anchor = false;
    replay: for (history.entries()) |*entry| {
        if (entry == anchor_entry) {
            after_anchor = true;
            continue;
        }
        if (!after_anchor) continue;
        const next = verifiedWitness(history, entry) catch |err| {
            if (require_committed_tail) return err;
            break :replay;
        };
        switch (next.kind) {
            control_record.generation_commit_kind => authority = replayLocalGeneration(history, authority, next) catch |err| {
                if (require_committed_tail) return err;
                break :replay;
            },
            control_record.membership_commit_kind => authority = replayLocalMembership(history, authority, next) catch |err| {
                if (require_committed_tail) return err;
                break :replay;
            },
            control_record.member_bootstrap_kind => authority = replayLocalBootstrap(authority, next) catch |err| {
                if (require_committed_tail) return err;
                break :replay;
            },
            control_record.checkpoint_kind => if (pool_authority_checkpoint.isSnapshotRecord(next)) {
                authority = replayLocalCheckpoint(authority, next) catch |err| {
                    if (require_committed_tail) return err;
                    break :replay;
                };
            },
            else => {},
        }
    }
    if (require_committed_tail) {
        const tail = history.scan_result.tail orelse return error.MissingAuthorityAnchor;
        if (!std.mem.eql(u8, &tail.history_digest, &authority.history_digest))
            return error.RecoveryTailIsNotCommitted;
    }
    if (!isVoter(authority.topology, history.member_id)) return error.TrustedMemberIsNotCurrentVoter;
    return authority;
}

fn selectRecoveryRoot(histories: []const *const journal.HistoryScan) !Authority {
    var selected: ?Authority = null;
    for (histories) |history| {
        var candidate = selectLocalRecoveryAuthority(history, false) catch continue;
        if (!candidate.administrative_recovery) continue;
        candidate = try advanceAuthority(histories, candidate);
        const witnesses = try countVoterWitnesses(
            histories,
            candidate.history_digest,
            authorityRecordKind(candidate.kind),
            candidate.topology,
        );
        if (witnesses < candidate.topology.quorum) continue;
        var witnessed = candidate;
        witnessed.witness_count = witnesses;
        if (selected) |current| {
            if (!std.mem.eql(u8, &current.history_digest, &witnessed.history_digest))
                return error.ConflictingRecoveryAuthority;
        } else {
            selected = witnessed;
        }
    }
    return selected orelse error.NoGenesisQuorum;
}

fn replayLocalGeneration(
    history: *const journal.HistoryScan,
    current: Authority,
    commit: control_record.Record,
) !Authority {
    const prepare_entry = history.findHistoryDigest(commit.previous_history_digest) orelse
        return error.MissingLocalPrepare;
    const prepare = try verifiedWitness(history, prepare_entry);
    if (prepare.kind != control_record.generation_prepare_kind) return error.AttestedRecordIsNotPrepare;
    if (!std.mem.eql(u8, &prepare.previous_history_digest, &current.history_digest) or
        !std.mem.eql(u8, &prepare.history_digest, &commit.previous_history_digest))
        return error.DetachedLocalCommit;
    try validateLocalPrepareCommit(prepare, commit);
    if (commit.membership_epoch != current.membership_epoch or
        !std.mem.eql(u8, &commit.topology_digest, &(try pool_topology.digest(current.topology))) or
        !std.mem.eql(u8, &commit.layout_digest, &(try pool_layout.digest(current.layout))))
        return error.GenerationChangedConfiguration;
    if (current.generation == std.math.maxInt(u64) or commit.generation != current.generation + 1)
        return error.UnexpectedGeneration;
    if (commit.writer_term < current.writer_term) return error.WriterTermRegression;
    var certificate_bytes: [pool_certificate.encoded_size]u8 = undefined;
    @memcpy(&certificate_bytes, commit.payload.slice());
    const certificate = try pool_certificate.decode(&certificate_bytes);
    try pool_certificate.validateAgainstTopology(certificate, current.topology);
    return .{
        .kind = .generation_commit,
        .history_digest = commit.history_digest,
        .data_root_digest = commit.data_root_digest,
        .topology = current.topology,
        .layout = current.layout,
        .membership_epoch = commit.membership_epoch,
        .writer_term = commit.writer_term,
        .generation = commit.generation,
        .witness_count = 1,
        .administrative_recovery = current.administrative_recovery,
    };
}

fn replayLocalMembership(
    history: *const journal.HistoryScan,
    current: Authority,
    commit: control_record.Record,
) !Authority {
    const prepare_entry = history.findHistoryDigest(commit.previous_history_digest) orelse
        return error.MissingLocalPrepare;
    const prepare = try verifiedWitness(history, prepare_entry);
    if (prepare.kind != control_record.membership_prepare_kind)
        return error.AttestedRecordIsNotMembershipPrepare;
    if (!std.mem.eql(u8, &prepare.previous_history_digest, &current.history_digest) or
        !std.mem.eql(u8, &prepare.history_digest, &commit.previous_history_digest))
        return error.DetachedLocalCommit;
    try validateLocalPrepareCommit(prepare, commit);
    const proposal = try membership.validateRecordProposal(commit);
    _ = try membership.validateRecordProposal(prepare);
    try membership.validateTransition(current.topology, proposal);
    if (!std.mem.eql(u8, prepare.payload.slice(), commit.payload.slice()[0..membership.proposal_size]))
        return error.MembershipProposalMismatch;
    var certificate_bytes: [membership.certificate_size]u8 = undefined;
    @memcpy(&certificate_bytes, commit.payload.slice()[membership.proposal_size..]);
    _ = try membership.decodeCertificate(current.topology, proposal.topology, proposal.mode, &certificate_bytes);
    if (commit.generation != current.generation or
        !std.mem.eql(u8, &commit.data_root_digest, &current.data_root_digest) or
        !std.mem.eql(u8, &commit.layout_digest, &(try pool_layout.digest(current.layout))))
        return error.MembershipChangedAuthorityData;
    if (commit.writer_term < current.writer_term) return error.WriterTermRegression;
    return .{
        .kind = .membership_commit,
        .history_digest = commit.history_digest,
        .data_root_digest = commit.data_root_digest,
        .topology = proposal.topology,
        .layout = current.layout,
        .membership_epoch = commit.membership_epoch,
        .writer_term = commit.writer_term,
        .generation = commit.generation,
        .witness_count = 1,
        .administrative_recovery = current.administrative_recovery or
            proposal.mode == .administrative_recovery,
    };
}

fn replayLocalBootstrap(current: Authority, record: control_record.Record) !Authority {
    if (!std.mem.eql(u8, &record.previous_history_digest, &current.history_digest))
        return error.BootstrapDoesNotExtendAuthority;
    const evidence = try member_bootstrap.validateRecord(record);
    if (!std.meta.eql(evidence.topology, current.topology) or !std.meta.eql(evidence.layout, current.layout) or
        record.membership_epoch != current.membership_epoch or record.writer_term != current.writer_term or
        record.generation != current.generation or
        !std.mem.eql(u8, &record.data_root_digest, &current.data_root_digest))
        return error.BootstrapChangedAuthority;
    return .{
        .kind = .member_bootstrap,
        .history_digest = record.history_digest,
        .data_root_digest = record.data_root_digest,
        .topology = current.topology,
        .layout = current.layout,
        .membership_epoch = record.membership_epoch,
        .writer_term = record.writer_term,
        .generation = record.generation,
        .witness_count = 1,
        .administrative_recovery = current.administrative_recovery,
    };
}

fn replayLocalCheckpoint(current: Authority, record: control_record.Record) !Authority {
    _ = try pool_authority_checkpoint.validateRecord(record, checkpointContext(current));
    return .{
        .kind = .checkpoint,
        .history_digest = record.history_digest,
        .data_root_digest = current.data_root_digest,
        .topology = current.topology,
        .layout = current.layout,
        .membership_epoch = current.membership_epoch,
        .writer_term = current.writer_term,
        .generation = current.generation,
        .witness_count = 1,
        .administrative_recovery = current.administrative_recovery,
    };
}

fn validateLocalPrepareCommit(prepare: control_record.Record, commit: control_record.Record) !void {
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

fn selectCompactedRoot(histories: []const *const journal.HistoryScan) !CompactedRoot {
    var selected: ?CompactedRoot = null;
    for (histories) |history| {
        const anchor_state = history.scan_result.active_anchor orelse continue;
        const anchor_entry = history.findRawRecordDigest(anchor_state.raw_record_digest) orelse continue;
        if (anchor_entry.physical_slot != anchor_state.physical_slot) continue;
        const record = try verifiedWitness(history, anchor_entry);
        const snapshot = try pool_authority_checkpoint.validateCompactedRootRecord(record);
        const witnesses = try countAnchorWitnesses(histories, record.history_digest, snapshot.topology);
        if (witnesses < snapshot.topology.quorum) continue;
        const candidate: CompactedRoot = .{
            .authority = authorityFromSnapshot(record, snapshot, witnesses),
            .parent_history_digest = snapshot.previous_authority_history_digest,
        };
        if (selected) |current| {
            if (!std.mem.eql(u8, &current.authority.history_digest, &candidate.authority.history_digest))
                return error.ConflictingCompactedAuthority;
        } else {
            selected = candidate;
        }
    }
    return selected orelse error.NoCompactedRootQuorum;
}

fn countAnchorWitnesses(
    histories: []const *const journal.HistoryScan,
    history_digest: codec.Digest,
    topology: pool_topology.Topology,
) !u16 {
    var count: u16 = 0;
    for (histories) |history| {
        const member = pool_topology.findMember(&topology, history.member_id) orelse continue;
        if (member.control_role != pool_topology.voter_role) continue;
        const anchor_state = history.scan_result.active_anchor orelse continue;
        if (!std.mem.eql(u8, &anchor_state.record.history_digest, &history_digest)) continue;
        const entry = history.findRawRecordDigest(anchor_state.raw_record_digest) orelse continue;
        if (entry.physical_slot != anchor_state.physical_slot) continue;
        const record = try verifiedWitness(history, entry);
        _ = try pool_authority_checkpoint.validateCompactedRootRecord(record);
        count = std.math.add(u16, count, 1) catch unreachable;
    }
    return count;
}

fn authorityFromSnapshot(
    record: control_record.Record,
    snapshot: pool_authority_checkpoint.Snapshot,
    witnesses: u16,
) Authority {
    return .{
        .kind = .checkpoint,
        .history_digest = record.history_digest,
        .data_root_digest = snapshot.data_root_digest,
        .topology = snapshot.topology,
        .layout = snapshot.layout,
        .membership_epoch = snapshot.topology.epoch,
        .writer_term = snapshot.writer_term,
        .generation = snapshot.generation,
        .witness_count = witnesses,
        .administrative_recovery = snapshot.administrative_recovery,
    };
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
        control_record.checkpoint_kind => if (pool_authority_checkpoint.isSnapshotRecord(entry.record))
            try validateCheckpointCandidate(histories, current, history, entry)
        else
            null,
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

fn validateCheckpointCandidate(
    histories: []const *const journal.HistoryScan,
    current: Authority,
    history: *const journal.HistoryScan,
    entry: journal.HistoryEntry,
) !?Authority {
    if (!std.mem.eql(u8, &entry.record.previous_history_digest, &current.history_digest)) return null;
    const witnesses = try countVoterWitnesses(
        histories,
        entry.record.history_digest,
        control_record.checkpoint_kind,
        current.topology,
    );
    if (witnesses < current.topology.quorum) return null;
    const record = try verifiedWitness(history, &entry);
    _ = try pool_authority_checkpoint.validateRecord(record, checkpointContext(current));
    return .{
        .kind = .checkpoint,
        .history_digest = record.history_digest,
        .data_root_digest = current.data_root_digest,
        .topology = current.topology,
        .layout = current.layout,
        .membership_epoch = current.membership_epoch,
        .writer_term = current.writer_term,
        .generation = current.generation,
        .witness_count = witnesses,
        .administrative_recovery = current.administrative_recovery,
    };
}

fn checkpointContext(authority: Authority) pool_authority_checkpoint.AuthorityContext {
    return .{
        .history_digest = authority.history_digest,
        .data_root_digest = authority.data_root_digest,
        .topology = authority.topology,
        .layout = authority.layout,
        .membership_epoch = authority.membership_epoch,
        .writer_term = authority.writer_term,
        .generation = authority.generation,
        .administrative_recovery = authority.administrative_recovery,
    };
}

fn authorityRecordKind(kind: Kind) u16 {
    return switch (kind) {
        .genesis => control_record.genesis_kind,
        .generation_commit => control_record.generation_commit_kind,
        .membership_commit => control_record.membership_commit_kind,
        .member_bootstrap => control_record.member_bootstrap_kind,
        .checkpoint => control_record.checkpoint_kind,
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

fn isVoter(topology: pool_topology.Topology, member_id: [16]u8) bool {
    const member = pool_topology.findMember(&topology, member_id) orelse return false;
    return member.control_role == pool_topology.voter_role;
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
    return makeHistoryFor(id(2), entries);
}

fn makeHistoryFor(member_id: [16]u8, entries: []journal.HistoryEntry) journal.HistoryScan {
    return .{
        .scan_result = .{ .slot_count = entries.len },
        .member_id = member_id,
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

test "administrative recovery rejects unresolved journal damage" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const genesis = try pool_genesis.makeRecord(id(2), .{ .topology = topology, .layout = layout });
    const genesis_raw = try control_record.encodeDynamicPool(genesis);
    var entries = [_]journal.HistoryEntry{makeEntry(genesis, genesis_raw, 0)};
    var history = makeHistory(&entries);
    history.scan_result.tail = genesis;
    history.scan_result.unresolved_tail_damage = true;
    try std.testing.expectError(error.JournalNeedsRecovery, selectAdministrativeRecovery(&history));
}

test "quorum authority checkpoint advances authority and local hints do not" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const genesis = try pool_genesis.makeRecord(id(2), .{ .topology = topology, .layout = layout });
    const genesis_raw = try control_record.encodeDynamicPool(genesis);
    const snapshot: pool_authority_checkpoint.Snapshot = .{
        .previous_authority_history_digest = genesis.history_digest,
        .data_root_digest = genesis.data_root_digest,
        .writer_term = genesis.writer_term,
        .generation = genesis.generation,
        .topology = topology,
        .layout = layout,
    };
    var checkpoint: control_record.Record = .{
        .kind = control_record.checkpoint_kind,
        .local_sequence = 2,
        .membership_epoch = genesis.membership_epoch,
        .writer_term = genesis.writer_term,
        .generation = genesis.generation,
        .set_id = topology.set_id,
        .member_id = id(2),
        .mount_session_id = id(3),
        .transaction_id = id(4),
        .previous_record_digest = control_record.recordDigest(&genesis_raw),
        .previous_history_digest = genesis.history_digest,
        .data_root_digest = genesis.data_root_digest,
        .topology_digest = try pool_topology.digest(topology),
        .layout_digest = try pool_layout.digest(layout),
        .payload = try pool_authority_checkpoint.makePayload(snapshot),
    };
    checkpoint.history_digest = try control_record.historyDigest(checkpoint);
    const checkpoint_raw = try control_record.encodeDynamicPool(checkpoint);
    var entries = [_]journal.HistoryEntry{
        makeEntry(genesis, genesis_raw, 0),
        makeEntry(checkpoint, checkpoint_raw, 1),
    };
    var history = makeHistory(&entries);
    const histories = [_]*const journal.HistoryScan{&history};
    const selected = try select(&histories);
    try std.testing.expectEqual(Kind.checkpoint, selected.kind);
    try std.testing.expectEqualSlices(u8, &checkpoint.history_digest, &selected.history_digest);

    history.scan_result.active_anchor = .{
        .record = checkpoint,
        .raw_record_digest = control_record.recordDigest(&checkpoint_raw),
        .physical_slot = 1,
    };
    const compacted_selected = try select(&histories);
    try std.testing.expectEqualSlices(u8, &checkpoint.history_digest, &compacted_selected.history_digest);
    history.scan_result.active_anchor = null;

    var hint = checkpoint;
    hint.payload = try control_record.Payload.init("local scan hint");
    hint.history_digest = try control_record.historyDigest(hint);
    const hint_raw = try control_record.encodeDynamicPool(hint);
    entries[1] = makeEntry(hint, hint_raw, 1);
    history = makeHistory(&entries);
    const hint_histories = [_]*const journal.HistoryScan{&history};
    try std.testing.expectEqual(Kind.genesis, (try select(&hint_histories)).kind);
}

test "authority checkpoint requires current voter quorum before validation" {
    const members = [_]pool_topology.Member{
        .{ .member_id = id(2), .slot = 1, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = id(3), .slot = 4, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = id(4), .slot = 9, .control_role = pool_topology.voter_role, .role_flags = 3 },
    };
    const topology = try pool_topology.Topology.init(id(1), 1, @splat(0), &members);
    const layout = try pool_layout.Layout.init(.replicated, 1, 1, 1024 * 1024);
    var genesis_records: [3]control_record.Record = undefined;
    var genesis_raw: [3][control_record.encoded_size]u8 = undefined;
    for (members, 0..) |member, index| {
        genesis_records[index] = try pool_genesis.makeRecord(member.member_id, .{
            .topology = topology,
            .layout = layout,
        });
        genesis_raw[index] = try control_record.encodeDynamicPool(genesis_records[index]);
    }
    const snapshot: pool_authority_checkpoint.Snapshot = .{
        .previous_authority_history_digest = genesis_records[0].history_digest,
        .data_root_digest = genesis_records[0].data_root_digest,
        .writer_term = genesis_records[0].writer_term,
        .generation = genesis_records[0].generation,
        .topology = topology,
        .layout = layout,
    };
    var checkpoint_records: [2]control_record.Record = undefined;
    var checkpoint_raw: [2][control_record.encoded_size]u8 = undefined;
    for (members[0..2], 0..) |member, index| {
        checkpoint_records[index] = .{
            .kind = control_record.checkpoint_kind,
            .local_sequence = 2,
            .membership_epoch = topology.epoch,
            .writer_term = 0,
            .generation = 0,
            .set_id = topology.set_id,
            .member_id = member.member_id,
            .mount_session_id = id(5),
            .transaction_id = id(6),
            .previous_record_digest = control_record.recordDigest(&genesis_raw[index]),
            .previous_history_digest = genesis_records[index].history_digest,
            .data_root_digest = @splat(0),
            .topology_digest = try pool_topology.digest(topology),
            .layout_digest = try pool_layout.digest(layout),
            .payload = try pool_authority_checkpoint.makePayload(snapshot),
        };
        checkpoint_records[index].history_digest = try control_record.historyDigest(checkpoint_records[index]);
        checkpoint_raw[index] = try control_record.encodeDynamicPool(checkpoint_records[index]);
    }
    var entries0 = [_]journal.HistoryEntry{
        makeEntry(genesis_records[0], genesis_raw[0], 0),
        makeEntry(checkpoint_records[0], checkpoint_raw[0], 1),
    };
    var entries1 = [_]journal.HistoryEntry{makeEntry(genesis_records[1], genesis_raw[1], 0)};
    var entries2 = [_]journal.HistoryEntry{makeEntry(genesis_records[2], genesis_raw[2], 0)};
    var history0 = makeHistoryFor(id(2), &entries0);
    var history1 = makeHistoryFor(id(3), &entries1);
    var history2 = makeHistoryFor(id(4), &entries2);
    var histories = [_]*const journal.HistoryScan{ &history0, &history1, &history2 };
    try std.testing.expectEqual(Kind.genesis, (try select(&histories)).kind);

    entries1 = .{
        makeEntry(genesis_records[1], genesis_raw[1], 0),
    };
    var entries1_with_checkpoint = [_]journal.HistoryEntry{
        entries1[0],
        makeEntry(checkpoint_records[1], checkpoint_raw[1], 1),
    };
    history1 = makeHistoryFor(id(3), &entries1_with_checkpoint);
    histories = .{ &history0, &history1, &history2 };
    try std.testing.expectEqual(Kind.checkpoint, (try select(&histories)).kind);

    var collision = checkpoint_records[0];
    var collision_payload: [pool_authority_checkpoint.encoded_size]u8 = @splat(0);
    @memcpy(collision_payload[0..8], "DDVPCHK1");
    collision.payload = try control_record.Payload.init(&collision_payload);
    collision.history_digest = try control_record.historyDigest(collision);
    const collision_raw = try control_record.encodeDynamicPool(collision);
    entries0[1] = makeEntry(collision, collision_raw, 1);
    history0 = makeHistoryFor(id(2), &entries0);
    history1 = makeHistoryFor(id(3), &entries1);
    histories = .{ &history0, &history1, &history2 };
    try std.testing.expectEqual(Kind.genesis, (try select(&histories)).kind);

    var collision1 = checkpoint_records[1];
    collision1.payload = try control_record.Payload.init(&collision_payload);
    collision1.history_digest = try control_record.historyDigest(collision1);
    const collision1_raw = try control_record.encodeDynamicPool(collision1);
    entries1_with_checkpoint[1] = makeEntry(collision1, collision1_raw, 1);
    history1 = makeHistoryFor(id(3), &entries1_with_checkpoint);
    histories = .{ &history0, &history1, &history2 };
    try std.testing.expectError(error.ChecksumMismatch, select(&histories));
}

test "compacted checkpoint quorum is a self-contained authority root" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const snapshot: pool_authority_checkpoint.Snapshot = .{
        .previous_authority_history_digest = @splat(0x44),
        .data_root_digest = @splat(0x55),
        .writer_term = 3,
        .generation = 7,
        .topology = topology,
        .layout = layout,
        .administrative_recovery = true,
    };
    var checkpoint: control_record.Record = .{
        .kind = control_record.checkpoint_kind,
        .local_sequence = 9,
        .membership_epoch = topology.epoch,
        .writer_term = snapshot.writer_term,
        .generation = snapshot.generation,
        .set_id = topology.set_id,
        .member_id = id(2),
        .mount_session_id = id(3),
        .transaction_id = id(4),
        .previous_record_digest = @splat(0x33),
        .previous_history_digest = snapshot.previous_authority_history_digest,
        .data_root_digest = snapshot.data_root_digest,
        .topology_digest = try pool_topology.digest(topology),
        .layout_digest = try pool_layout.digest(layout),
        .payload = try pool_authority_checkpoint.makePayload(snapshot),
    };
    checkpoint.history_digest = try control_record.historyDigest(checkpoint);
    const raw = try control_record.encodeDynamicPool(checkpoint);
    var entries = [_]journal.HistoryEntry{makeEntry(checkpoint, raw, 3)};
    var history = makeHistory(&entries);
    history.scan_result.active_anchor = .{
        .record = checkpoint,
        .raw_record_digest = control_record.recordDigest(&raw),
        .physical_slot = 3,
    };
    history.scan_result.anchored = true;
    const histories = [_]*const journal.HistoryScan{&history};
    const selected = try select(&histories);
    try std.testing.expectEqual(Kind.checkpoint, selected.kind);
    try std.testing.expectEqual(snapshot.generation, selected.generation);
    try std.testing.expectEqual(snapshot.writer_term, selected.writer_term);
    try std.testing.expect(selected.administrative_recovery);
    try std.testing.expectEqualSlices(u8, &snapshot.data_root_digest, &selected.data_root_digest);
}

test "compacted root rejects an unrelated committed authority" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const root_authority: Authority = .{
        .kind = .checkpoint,
        .history_digest = @splat(0x22),
        .data_root_digest = @splat(0x33),
        .topology = topology,
        .layout = layout,
        .membership_epoch = topology.epoch,
        .writer_term = 3,
        .generation = 7,
        .witness_count = 1,
    };
    const root: CompactedRoot = .{
        .authority = root_authority,
        .parent_history_digest = @splat(0x11),
    };
    var divergent = root_authority;
    divergent.kind = .membership_commit;
    divergent.history_digest = @splat(0x44);
    divergent.administrative_recovery = true;
    try std.testing.expectError(error.ConflictingAuthority, reconcileCompactedRoot(root, root_authority, divergent));

    divergent.history_digest = root.parent_history_digest;
    try reconcileCompactedRoot(root, root_authority, divergent);
}
