const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const journal_api = @import("journal.zig");
const member_bootstrap = @import("member_bootstrap.zig");
const membership = @import("membership.zig");
const pool_authority = @import("pool_authority.zig");
const pool_certificate = @import("pool_certificate.zig");
const pool_member_set = @import("pool_member_set.zig");
const pool_policy = @import("pool_policy.zig");

const max_control_participant_count: usize = 6;

pub const CommitResult = struct {
    record: control_record.Record,
    committed_members: [pool_member_set.max_member_count]bool,
    committed_count: u16,
    degraded: bool,
};

pub const BootstrapResult = struct {
    record: control_record.Record,
    target_index: usize,
    voter_ack_count: u16,
};

const Participant = struct {
    set_index: usize,
    journal: journal_api.Journal,
    active: bool,
};

pub const ReplicatedJournal = struct {
    io: std.Io,
    set: *pool_member_set.PoolMemberSet,
    participants: [max_control_participant_count]?Participant = @splat(null),
    participant_count: usize = 0,
    quorum: u16,
    recovery_only: bool,
    mutex: std.Io.Mutex = .init,
    frozen: std.atomic.Value(bool) = .init(false),
    closed: bool = false,

    pub fn open(io: std.Io, set: *pool_member_set.PoolMemberSet) !ReplicatedJournal {
        try set.claimCoordinator();
        errdefer set.releaseCoordinator();
        const ready = set.controlWriteReady() orelse return error.WriteQuorumUnavailable;
        const authority = set.authority() orelse return error.MissingAuthority;
        var coordinator: ReplicatedJournal = .{
            .io = io,
            .set = set,
            .quorum = authority.topology.quorum,
            .recovery_only = set.isRecoveryOnly(),
        };
        errdefer coordinator.closeParticipants();
        for (ready.active_members[0..set.supplied_count], 0..) |active, set_index| {
            if (!active) continue;
            if (coordinator.participant_count == max_control_participant_count) return error.TooManyControlVoters;
            coordinator.participants[coordinator.participant_count] = .{
                .set_index = set_index,
                .journal = try journal_api.Journal.open(&(set.members[set_index].?)),
                .active = true,
            };
            coordinator.participant_count += 1;
        }
        const open_quorum: u16 = if (coordinator.recovery_only) 1 else coordinator.quorum;
        if (coordinator.participant_count < open_quorum) return error.WriteQuorumUnavailable;
        return coordinator;
    }

    pub fn commitGeneration(
        self: *ReplicatedJournal,
        prepare_proposal: control_record.Record,
    ) !CommitResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (self.recovery_only) return error.RecoveryOnlyCoordinator;
        if (prepare_proposal.kind != control_record.generation_prepare_kind)
            return error.NotGenerationPrepare;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        if (prepare_proposal.membership_epoch != authority.membership_epoch)
            return error.MembershipEpochMismatch;
        if (authority.generation == std.math.maxInt(u64) or
            prepare_proposal.generation != authority.generation + 1) return error.UnexpectedGeneration;
        if (!std.mem.eql(u8, &prepare_proposal.topology_digest, &(try pool_topology.digest(authority.topology))))
            return error.TopologyDigestMismatch;
        if (!std.mem.eql(u8, &prepare_proposal.layout_digest, &(try pool_layout.digest(authority.layout))))
            return error.LayoutDigestMismatch;

        var targets: [max_control_participant_count]bool = @splat(false);
        var target_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            if (!participant.active) continue;
            const state = try participant.journal.state();
            if (state.physical_frontier + 2 > state.slot_count) continue;
            targets[index] = true;
            target_count += 1;
        }
        if (target_count < self.quorum) return error.InsufficientJournalCapacity;

        var prepared: [max_control_participant_count]?journal_api.PreparedAppend = @splat(null);
        var shared_prepare_history: ?codec.Digest = null;
        for (0..self.participant_count) |index| {
            if (!targets[index]) continue;
            const participant = &(self.participants[index].?);
            prepared[index] = try participant.journal.prepareExact(
                try participant.journal.tailToken(),
                prepare_proposal,
            );
            const digest = prepared[index].?.record.history_digest;
            if (shared_prepare_history) |expected| {
                if (!std.mem.eql(u8, &expected, &digest)) return error.PrepareHistoryDiverged;
            } else {
                shared_prepare_history = digest;
            }
        }

        self.set.beginControlMutation();
        var prepare_results: [max_control_participant_count]?journal_api.AppendResult = @splat(null);
        var prepare_successes: [max_control_participant_count]bool = @splat(false);
        var prepare_success_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const item = prepared[index] orelse continue;
            prepare_results[index] = participant.journal.appendPrepared(&item) catch {
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            prepare_successes[index] = true;
            prepare_success_count += 1;
        }
        if (prepare_success_count < self.quorum) {
            self.frozen.store(true, .release);
            return error.PrepareQuorumFailed;
        }

        const certificate = makeCertificate(prepare_results, prepare_successes, self.quorum);
        var commit_proposal = firstResult(prepare_results, prepare_successes).record;
        commit_proposal.kind = control_record.generation_commit_kind;
        commit_proposal.payload = try control_record.Payload.init(&(try pool_certificate.encode(certificate)));
        var commit_prepared: [max_control_participant_count]?journal_api.PreparedAppend = @splat(null);
        var shared_commit_history: ?codec.Digest = null;
        for (0..self.participant_count) |index| {
            if (!prepare_successes[index]) continue;
            const participant = &(self.participants[index].?);
            commit_prepared[index] = participant.journal.prepareExact(
                try participant.journal.tailToken(),
                commit_proposal,
            ) catch {
                self.frozen.store(true, .release);
                return error.CommitPreparationFailed;
            };
            const digest = commit_prepared[index].?.record.history_digest;
            if (shared_commit_history) |expected| {
                if (!std.mem.eql(u8, &expected, &digest)) {
                    self.frozen.store(true, .release);
                    return error.CommitHistoryDiverged;
                }
            } else {
                shared_commit_history = digest;
            }
        }

        var commit_results: [max_control_participant_count]?journal_api.AppendResult = @splat(null);
        var committed_members: [pool_member_set.max_member_count]bool = @splat(false);
        var commit_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const item = commit_prepared[index] orelse continue;
            commit_results[index] = participant.journal.appendPrepared(&item) catch {
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            committed_members[participant.set_index] = true;
            commit_count += 1;
        }
        if (commit_count < self.quorum) {
            self.frozen.store(true, .release);
            return error.CommitOutcomeUnknown;
        }
        const committed = firstCommitted(commit_results).record;
        self.set.noteCommittedGeneration(committed, committed_members, commit_count);
        return .{
            .record = committed,
            .committed_members = committed_members,
            .committed_count = commit_count,
            .degraded = commit_count < self.activeParticipantCount(),
        };
    }

    pub fn commitMembership(
        self: *ReplicatedJournal,
        prepare_proposal: control_record.Record,
    ) !CommitResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (prepare_proposal.kind != control_record.membership_prepare_kind)
            return error.NotMembershipPrepare;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        const proposal = try membership.validateRecordProposal(prepare_proposal);
        if (self.recovery_only and proposal.mode != .administrative_recovery)
            return error.AdministrativeRecoveryRequired;
        try membership.validateTransition(authority.topology, proposal);
        try self.validatePromotions(authority.topology, proposal.topology, authority.history_digest);
        if (prepare_proposal.generation != authority.generation or
            !std.mem.eql(u8, &prepare_proposal.data_root_digest, &authority.data_root_digest))
            return error.MembershipChangedAuthorityData;
        if (!std.mem.eql(u8, &prepare_proposal.layout_digest, &(try pool_layout.digest(authority.layout))))
            return error.LayoutDigestMismatch;
        if (prepare_proposal.writer_term < authority.writer_term) return error.WriterTermRegression;

        for (proposal.topology.memberSlice()) |member| {
            if (member.control_role != pool_topology.voter_role) continue;
            _ = try self.ensureParticipant(member.member_id, authority.history_digest);
        }

        var targets: [max_control_participant_count]bool = @splat(false);
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const member_id = participant.journal.member.header().member_id;
            if (!isVoter(authority.topology, member_id) and !isVoter(proposal.topology, member_id)) continue;
            const state = try participant.journal.state();
            if (state.physical_frontier + 2 > state.slot_count) continue;
            targets[index] = true;
        }
        if (!hasMembershipQuorums(targets, self.participants[0..self.participant_count], authority.topology, proposal))
            return error.InsufficientJournalCapacity;

        var prepared: [max_control_participant_count]?journal_api.PreparedAppend = @splat(null);
        var shared_prepare_history: ?codec.Digest = null;
        for (0..self.participant_count) |index| {
            if (!targets[index]) continue;
            const participant = &(self.participants[index].?);
            prepared[index] = try participant.journal.prepareExact(
                try participant.journal.tailToken(),
                prepare_proposal,
            );
            const digest = prepared[index].?.record.history_digest;
            if (shared_prepare_history) |expected| {
                if (!std.mem.eql(u8, &expected, &digest)) return error.PrepareHistoryDiverged;
            } else {
                shared_prepare_history = digest;
            }
        }

        self.set.beginControlMutation();
        var prepare_results: [max_control_participant_count]?journal_api.AppendResult = @splat(null);
        var prepare_successes: [max_control_participant_count]bool = @splat(false);
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const item = prepared[index] orelse continue;
            prepare_results[index] = participant.journal.appendPrepared(&item) catch {
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            prepare_successes[index] = true;
        }
        if (!hasMembershipQuorums(
            prepare_successes,
            self.participants[0..self.participant_count],
            authority.topology,
            proposal,
        )) {
            self.frozen.store(true, .release);
            return error.PrepareQuorumFailed;
        }

        const certificate = makeMembershipCertificate(
            prepare_results,
            prepare_successes,
            self.participants[0..self.participant_count],
            authority.topology,
            proposal,
        );
        var commit_proposal = firstResult(prepare_results, prepare_successes).record;
        commit_proposal.kind = control_record.membership_commit_kind;
        commit_proposal.payload = try membership.makeCommitPayload(authority.topology, proposal, certificate);
        var commit_prepared: [max_control_participant_count]?journal_api.PreparedAppend = @splat(null);
        var shared_commit_history: ?codec.Digest = null;
        for (0..self.participant_count) |index| {
            if (!prepare_successes[index]) continue;
            const participant = &(self.participants[index].?);
            commit_prepared[index] = participant.journal.prepareExact(
                try participant.journal.tailToken(),
                commit_proposal,
            ) catch {
                self.frozen.store(true, .release);
                return error.CommitPreparationFailed;
            };
            const digest = commit_prepared[index].?.record.history_digest;
            if (shared_commit_history) |expected| {
                if (!std.mem.eql(u8, &expected, &digest)) {
                    self.frozen.store(true, .release);
                    return error.CommitHistoryDiverged;
                }
            } else {
                shared_commit_history = digest;
            }
        }

        var commit_results: [max_control_participant_count]?journal_api.AppendResult = @splat(null);
        var commit_successes: [max_control_participant_count]bool = @splat(false);
        var committed_members: [pool_member_set.max_member_count]bool = @splat(false);
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const item = commit_prepared[index] orelse continue;
            commit_results[index] = participant.journal.appendPrepared(&item) catch {
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            commit_successes[index] = true;
            committed_members[participant.set_index] = true;
        }
        if (!hasMembershipQuorums(
            commit_successes,
            self.participants[0..self.participant_count],
            authority.topology,
            proposal,
        )) {
            self.frozen.store(true, .release);
            return error.CommitOutcomeUnknown;
        }

        var active_members: [pool_member_set.max_member_count]bool = @splat(false);
        var active_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const member_id = participant.journal.member.header().member_id;
            participant.active = commit_successes[index] and isVoter(proposal.topology, member_id);
            if (participant.active) {
                active_members[participant.set_index] = true;
                active_count += 1;
            }
        }
        const committed = firstCommitted(commit_results).record;
        self.quorum = proposal.topology.quorum;
        self.set.noteCommittedMembership(
            committed,
            proposal.topology,
            active_members,
            active_count,
            proposal.mode == .administrative_recovery,
        );
        return .{
            .record = committed,
            .committed_members = committed_members,
            .committed_count = countTrue(commit_successes[0..self.participant_count]),
            .degraded = active_count < voterCount(proposal.topology),
        };
    }

    pub fn bootstrapMember(
        self: *ReplicatedJournal,
        allocator: std.mem.Allocator,
        location: pool_member_set.Location,
        header: member_format.Header,
        bootstrap_record: control_record.Record,
        options: member_api.CreateOptions,
    ) !BootstrapResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (self.recovery_only) return error.RecoveryOnlyCoordinator;
        if (self.set.supplied_count == pool_member_set.max_member_count)
            return error.TooManyPoolMembers;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        const evidence = try member_bootstrap.validateTargetFirstRecord(header, bootstrap_record);
        if (!std.meta.eql(evidence.topology, authority.topology) or
            !std.meta.eql(evidence.layout, authority.layout)) return error.BootstrapAuthorityMismatch;
        if (!std.mem.eql(u8, &bootstrap_record.previous_history_digest, &authority.history_digest) or
            bootstrap_record.membership_epoch != authority.membership_epoch or
            bootstrap_record.writer_term != authority.writer_term or
            bootstrap_record.generation != authority.generation or
            !std.mem.eql(u8, &bootstrap_record.data_root_digest, &authority.data_root_digest))
            return error.BootstrapAuthorityMismatch;
        for (self.set.members[0..self.set.supplied_count]) |*maybe_member| {
            const member = if (maybe_member.*) |*value| value else continue;
            if (std.mem.eql(u8, &member.header().member_id, &evidence.target_member_id))
                return error.MemberAlreadyPresent;
        }

        var prepared: [max_control_participant_count]?journal_api.PreparedAppend = @splat(null);
        var target_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            if (!participant.active) continue;
            const state = try participant.journal.state();
            if (state.physical_frontier == state.slot_count) continue;
            prepared[index] = try participant.journal.prepareExact(
                try participant.journal.tailToken(),
                bootstrap_record,
            );
            if (!std.mem.eql(u8, &prepared[index].?.record.history_digest, &bootstrap_record.history_digest))
                return error.BootstrapHistoryDiverged;
            target_count += 1;
        }
        if (target_count < authority.topology.quorum) return error.InsufficientJournalCapacity;

        var target_member = try member_api.createJoiningAt(
            self.io,
            location.parent,
            location.basename,
            header,
            bootstrap_record,
            options,
        );
        var target_transferred = false;
        errdefer if (!target_transferred) target_member.deinit();
        var target_history = try journal_api.scanHistory(allocator, &target_member);
        var history_transferred = false;
        errdefer if (!history_transferred) target_history.deinit();

        self.set.beginControlMutation();
        var voter_ack_count: u16 = 0;
        var active_members: [pool_member_set.max_member_count]bool = @splat(false);
        var committed_record: ?control_record.Record = null;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const item = prepared[index] orelse continue;
            const result = participant.journal.appendPrepared(&item) catch {
                participant.active = false;
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            active_members[participant.set_index] = true;
            voter_ack_count += 1;
            if (committed_record == null) committed_record = result.record;
        }
        if (voter_ack_count < authority.topology.quorum) {
            self.frozen.store(true, .release);
            return error.BootstrapQuorumFailed;
        }
        const committed = committed_record.?;
        const target_index = try self.set.noteCommittedBootstrap(
            committed,
            target_member,
            target_history,
            active_members,
            voter_ack_count,
        );
        target_transferred = true;
        history_transferred = true;
        return .{
            .record = committed,
            .target_index = target_index,
            .voter_ack_count = voter_ack_count,
        };
    }

    pub fn isFrozen(self: *const ReplicatedJournal) bool {
        return self.frozen.load(.acquire);
    }

    pub fn close(self: *ReplicatedJournal) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        self.closeParticipants();
        self.closed = true;
        self.set.releaseCoordinator();
    }

    pub fn deinit(self: *ReplicatedJournal) void {
        self.close();
    }

    fn closeParticipants(self: *ReplicatedJournal) void {
        for (&self.participants) |*maybe_participant| {
            if (maybe_participant.*) |*participant| participant.journal.close();
            maybe_participant.* = null;
        }
    }

    fn activeParticipantCount(self: *const ReplicatedJournal) u16 {
        var count: u16 = 0;
        for (self.participants[0..self.participant_count]) |participant| {
            if (participant.?.active) count += 1;
        }
        return count;
    }

    fn ensureParticipant(self: *ReplicatedJournal, member_id: [16]u8, authority_digest: codec.Digest) !usize {
        for (self.participants[0..self.participant_count], 0..) |participant, index| {
            if (std.mem.eql(u8, &participant.?.journal.member.header().member_id, &member_id)) return index;
        }
        if (self.participant_count == max_control_participant_count) return error.TooManyControlParticipants;
        for (0..self.set.supplied_count) |set_index| {
            const member = if (self.set.members[set_index]) |*value| value else continue;
            if (!std.mem.eql(u8, &member.header().member_id, &member_id)) continue;
            const history = if (self.set.histories[set_index]) |*value| value else return error.NewVoterHistoryUnavailable;
            const tail = history.scan_result.tail orelse return error.NewVoterHistoryUnavailable;
            if (!std.mem.eql(u8, &tail.history_digest, &authority_digest) or
                history.scan_result.unresolved_tail_damage or history.scan_result.journal_full or
                member.mode() != .writable or member.isFrozen()) return error.NewVoterNotCaughtUp;
            self.participants[self.participant_count] = .{
                .set_index = set_index,
                .journal = try journal_api.Journal.open(member),
                .active = false,
            };
            self.participant_count += 1;
            return self.participant_count - 1;
        }
        return error.NewVoterUnavailable;
    }

    fn validatePromotions(
        self: *const ReplicatedJournal,
        current: pool_topology.Topology,
        next: pool_topology.Topology,
        authority_digest: codec.Digest,
    ) !void {
        for (current.memberSlice()) |old_member| {
            if (old_member.state != .joining) continue;
            const new_member = pool_topology.findMember(&next, old_member.member_id) orelse continue;
            if (new_member.state != .active) continue;
            var matching_history: ?*const journal_api.HistoryScan = null;
            for (self.set.histories[0..self.set.supplied_count]) |*maybe_history| {
                const history = if (maybe_history.*) |*value| value else continue;
                if (!std.mem.eql(u8, &history.member_id, &old_member.member_id)) continue;
                matching_history = history;
                break;
            }
            const history = matching_history orelse return error.MemberBootstrapRequired;
            const entries = history.entries();
            if (entries.len == 0 or entries[0].record.kind != control_record.member_bootstrap_kind)
                return error.MemberBootstrapRequired;
            const evidence = try member_bootstrap.validateRecord(entries[0].record);
            if (!std.mem.eql(u8, &evidence.target_member_id, &old_member.member_id))
                return error.MemberBootstrapRequired;
            const tail = history.scan_result.tail orelse return error.MemberNotCaughtUp;
            if (!std.mem.eql(u8, &tail.history_digest, &authority_digest) or
                history.findHistoryDigest(authority_digest) == null) return error.MemberNotCaughtUp;
        }
    }
};

fn makeCertificate(
    results: [max_control_participant_count]?journal_api.AppendResult,
    successes: [max_control_participant_count]bool,
    quorum: u16,
) pool_certificate.Certificate {
    var certificate: pool_certificate.Certificate = .{
        .count = quorum,
        .attestations = @splat(.{
            .member_id = @splat(0),
            .prepare_record_digest = @splat(0),
            .prepare_history_digest = @splat(0),
        }),
    };
    var count: usize = 0;
    for (successes, 0..) |success, index| {
        if (!success or count == quorum) continue;
        const result = results[index].?;
        certificate.attestations[count] = .{
            .member_id = result.record.member_id,
            .prepare_record_digest = result.record_digest,
            .prepare_history_digest = result.record.history_digest,
        };
        count += 1;
    }
    std.debug.assert(count == quorum);
    return certificate;
}

fn firstResult(
    results: [max_control_participant_count]?journal_api.AppendResult,
    successes: [max_control_participant_count]bool,
) journal_api.AppendResult {
    for (successes, 0..) |success, index| if (success) return results[index].?;
    unreachable;
}

fn firstCommitted(results: [max_control_participant_count]?journal_api.AppendResult) journal_api.AppendResult {
    for (results) |result| if (result) |value| return value;
    unreachable;
}

fn isVoter(topology: pool_topology.Topology, member_id: [16]u8) bool {
    const member = pool_topology.findMember(&topology, member_id) orelse return false;
    return member.control_role == pool_topology.voter_role;
}

fn hasMembershipQuorums(
    successes: [max_control_participant_count]bool,
    participants: []const ?Participant,
    current: pool_topology.Topology,
    proposal: membership.Proposal,
) bool {
    var old_count: u16 = 0;
    var new_count: u16 = 0;
    for (0..participants.len) |index| {
        if (!successes[index]) continue;
        const member_id = participants[index].?.journal.member.header().member_id;
        if (isVoter(current, member_id)) old_count += 1;
        if (isVoter(proposal.topology, member_id)) new_count += 1;
    }
    return new_count >= proposal.topology.quorum and
        (proposal.mode == .administrative_recovery or old_count >= current.quorum);
}

fn makeMembershipCertificate(
    results: [max_control_participant_count]?journal_api.AppendResult,
    successes: [max_control_participant_count]bool,
    participants: []const ?Participant,
    current: pool_topology.Topology,
    proposal: membership.Proposal,
) membership.Certificate {
    const old_required: u8 = if (proposal.mode == .normal) @intCast(current.quorum) else 0;
    const new_required: u8 = @intCast(proposal.topology.quorum);
    var certificate: membership.Certificate = .{
        .old_count = old_required,
        .new_count = new_required,
        .attestations = @splat(.{
            .member_id = @splat(0),
            .prepare_record_digest = @splat(0),
            .prepare_history_digest = @splat(0),
        }),
    };
    var count: usize = 0;
    for (0..participants.len) |index| {
        if (!successes[index] or count == old_required) continue;
        const result = results[index].?;
        if (!isVoter(current, result.record.member_id)) continue;
        certificate.attestations[count] = attestationFromResult(result);
        count += 1;
    }
    std.debug.assert(count == old_required);
    const new_end = count + new_required;
    for (0..participants.len) |index| {
        if (!successes[index] or count == new_end) continue;
        const result = results[index].?;
        if (!isVoter(proposal.topology, result.record.member_id)) continue;
        certificate.attestations[count] = attestationFromResult(result);
        count += 1;
    }
    std.debug.assert(count == new_end);
    return certificate;
}

fn attestationFromResult(result: journal_api.AppendResult) control_record.Attestation {
    return .{
        .member_id = result.record.member_id,
        .prepare_record_digest = result.record_digest,
        .prepare_history_digest = result.record.history_digest,
    };
}

fn countTrue(values: []const bool) u16 {
    var count: u16 = 0;
    for (values) |value| if (value) {
        count += 1;
    };
    return count;
}

fn voterCount(topology: pool_topology.Topology) u16 {
    var count: u16 = 0;
    for (topology.memberSlice()) |member| {
        if (member.control_role == pool_topology.voter_role) count += 1;
    }
    return count;
}

pub fn open(io: std.Io, set: *pool_member_set.PoolMemberSet) !ReplicatedJournal {
    return ReplicatedJournal.open(io, set);
}

const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const pool_genesis = @import("pool_genesis_payload.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

fn id(value: u8) [16]u8 {
    return @splat(value);
}

test "one-member coordinator commits generation and membership then reopens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const members = [_]pool_topology.Member{.{
        .member_id = id(2),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = member_format.known_role_flags,
    }};
    const payload: pool_genesis.GenesisPayload = .{
        .topology = try pool_topology.Topology.init(id(1), 1, @splat(0), &members),
        .layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024),
    };
    const header: member_format.Header = .{
        .header_sequence = 1,
        .incompat_features = member_format.dynamic_pool_incompat_feature,
        .set_id = payload.topology.set_id,
        .member_id = id(2),
        .member_slot = 7,
        .member_count = 1,
        .created_ns = 1,
        .member_bytes = 3 * 1024 * 1024,
        .logical_capacity = 1024 * 1024,
        .control = .{ .offset = 64 * 1024, .length = 64 * 1024 },
        .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
        .data = .{ .offset = 2 * 1024 * 1024, .length = 1024 * 1024 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = 1024 * 1024,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = member_format.dynamic_layout_format_version,
        .control_record_format_version = 1,
        .label = try member_format.Label.init("pool-coordinator-test"),
        .genesis_topology_digest = try pool_topology.digest(payload.topology),
    };
    var member = try member_api.createPoolAt(std.testing.io, tmp.dir, "member", header, payload, .{});
    try member.close();
    const locations = [_]pool_member_set.Location{.{ .parent = tmp.dir, .basename = "member" }};
    var set = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
    defer set.deinit();
    var coordinator = try open(std.testing.io, &set);
    defer coordinator.deinit();
    const authority = set.authority().?;
    var proposal: control_record.Record = .{
        .kind = control_record.generation_prepare_kind,
        .local_sequence = 99,
        .membership_epoch = authority.membership_epoch,
        .writer_term = 1,
        .generation = 1,
        .set_id = id(9),
        .member_id = id(8),
        .mount_session_id = id(3),
        .transaction_id = id(4),
        .previous_record_digest = @splat(0x11),
        .previous_history_digest = @splat(0x22),
        .data_root_digest = @splat(0x55),
        .topology_digest = try pool_topology.digest(authority.topology),
        .layout_digest = try pool_layout.digest(authority.layout),
        .payload = try control_record.Payload.init("generation"),
    };
    proposal.history_digest = try control_record.historyDigest(proposal);
    const result = try coordinator.commitGeneration(proposal);
    try std.testing.expectEqual(@as(u16, 1), result.committed_count);
    try std.testing.expectEqual(@as(u64, 1), result.record.generation);
    try std.testing.expectEqual(@as(u64, 1), set.authority().?.generation);
    coordinator.close();
    try set.close();

    var reopened = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 1), reopened.authority().?.generation);
    var membership_coordinator = try open(std.testing.io, &reopened);
    defer membership_coordinator.deinit();
    const current = reopened.authority().?;
    const next_members = [_]pool_topology.Member{
        current.topology.members[0],
        .{ .member_id = id(5), .slot = 19, .state = .joining },
    };
    const membership_change: membership.Proposal = .{
        .mode = .normal,
        .topology = try pool_topology.Topology.init(
            current.topology.set_id,
            current.topology.epoch + 1,
            try pool_topology.digest(current.topology),
            &next_members,
        ),
    };
    var membership_prepare: control_record.Record = .{
        .kind = control_record.membership_prepare_kind,
        .local_sequence = 99,
        .membership_epoch = membership_change.topology.epoch,
        .writer_term = current.writer_term,
        .generation = current.generation,
        .set_id = current.topology.set_id,
        .member_id = id(8),
        .mount_session_id = id(6),
        .transaction_id = id(7),
        .previous_record_digest = @splat(0x11),
        .previous_history_digest = @splat(0x22),
        .data_root_digest = current.data_root_digest,
        .topology_digest = try pool_topology.digest(membership_change.topology),
        .layout_digest = try pool_layout.digest(current.layout),
        .payload = try membership.makePreparePayload(membership_change),
    };
    membership_prepare.history_digest = try control_record.historyDigest(membership_prepare);
    const membership_result = try membership_coordinator.commitMembership(membership_prepare);
    try std.testing.expectEqual(control_record.membership_commit_kind, membership_result.record.kind);
    try std.testing.expectEqual(@as(u16, 2), reopened.authority().?.topology.member_count);

    const joining_authority = reopened.authority().?;
    var promoted_members = [_]pool_topology.Member{
        joining_authority.topology.members[0],
        joining_authority.topology.members[1],
    };
    promoted_members[1].state = .active;
    promoted_members[1].control_role = pool_topology.voter_role;
    promoted_members[1].role_flags = member_format.known_role_flags;
    const promotion: membership.Proposal = .{
        .mode = .normal,
        .topology = try pool_topology.Topology.init(
            joining_authority.topology.set_id,
            joining_authority.topology.epoch + 1,
            try pool_topology.digest(joining_authority.topology),
            &promoted_members,
        ),
    };
    var promotion_prepare = membership_prepare;
    promotion_prepare.membership_epoch = promotion.topology.epoch;
    promotion_prepare.transaction_id = id(9);
    promotion_prepare.data_root_digest = joining_authority.data_root_digest;
    promotion_prepare.topology_digest = try pool_topology.digest(promotion.topology);
    promotion_prepare.payload = try membership.makePreparePayload(promotion);
    promotion_prepare.history_digest = try control_record.historyDigest(promotion_prepare);
    try std.testing.expectError(
        error.MemberBootstrapRequired,
        membership_coordinator.commitMembership(promotion_prepare),
    );

    const bootstrap_evidence: member_bootstrap.Evidence = .{
        .target_member_id = id(5),
        .target_slot = 19,
        .topology = joining_authority.topology,
        .layout = joining_authority.layout,
    };
    const joining_header: member_format.Header = .{
        .header_sequence = 1,
        .incompat_features = member_format.dynamic_pool_incompat_feature,
        .set_id = joining_authority.topology.set_id,
        .member_id = id(5),
        .member_slot = 19,
        .member_count = joining_authority.topology.member_count,
        .role_flags = member_format.data_role,
        .created_ns = 2,
        .member_bytes = 3 * 1024 * 1024,
        .logical_capacity = 1024 * 1024,
        .control = .{ .offset = 64 * 1024, .length = 64 * 1024 },
        .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
        .data = .{ .offset = 2 * 1024 * 1024, .length = 1024 * 1024 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = 1024 * 1024,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = member_format.dynamic_layout_format_version,
        .control_record_format_version = 1,
        .label = try member_format.Label.init("joining-pool-member"),
        .genesis_topology_digest = try pool_topology.digest(joining_authority.topology),
    };
    var bootstrap_record: control_record.Record = .{
        .kind = control_record.member_bootstrap_kind,
        .local_sequence = 1,
        .membership_epoch = joining_authority.membership_epoch,
        .writer_term = joining_authority.writer_term,
        .generation = joining_authority.generation,
        .set_id = joining_authority.topology.set_id,
        .member_id = id(5),
        .mount_session_id = @splat(0),
        .transaction_id = id(10),
        .previous_record_digest = @splat(0),
        .previous_history_digest = joining_authority.history_digest,
        .data_root_digest = joining_authority.data_root_digest,
        .topology_digest = try pool_topology.digest(joining_authority.topology),
        .layout_digest = try pool_layout.digest(joining_authority.layout),
        .payload = try member_bootstrap.makePayload(bootstrap_evidence),
    };
    bootstrap_record.history_digest = try control_record.historyDigest(bootstrap_record);
    const bootstrap_result = try membership_coordinator.bootstrapMember(
        std.testing.allocator,
        .{ .parent = tmp.dir, .basename = "joining" },
        joining_header,
        bootstrap_record,
        .{},
    );
    try std.testing.expectEqual(@as(u16, 1), bootstrap_result.voter_ack_count);

    const promotion_result = try membership_coordinator.commitMembership(promotion_prepare);
    try std.testing.expectEqual(@as(u16, 2), promotion_result.committed_count);
    try std.testing.expectEqual(@as(u16, 2), reopened.controlWriteReady().?.active_count);
    membership_coordinator.close();
    try reopened.close();

    const recovered_locations = [_]pool_member_set.Location{
        .{ .parent = tmp.dir, .basename = "member" },
        .{ .parent = tmp.dir, .basename = "joining" },
    };
    var recovered = try pool_member_set.open(
        std.testing.io,
        std.testing.allocator,
        &recovered_locations,
        .read_only,
    );
    defer recovered.deinit();
    try std.testing.expectEqual(pool_authority.Kind.membership_commit, recovered.authority().?.kind);
    try std.testing.expectEqual(@as(u16, 2), recovered.authority().?.topology.member_count);
    try std.testing.expectEqual(pool_topology.MemberState.active, recovered.authority().?.topology.members[1].state);
}

test "administrative recovery converts a lost two-of-two quorum to one-of-one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const members = [_]pool_topology.Member{
        .{ .member_id = id(2), .slot = 7, .control_role = pool_topology.voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(3), .slot = 11, .control_role = pool_topology.voter_role, .role_flags = member_format.known_role_flags },
    };
    const payload: pool_genesis.GenesisPayload = .{
        .topology = try pool_topology.Topology.init(id(1), 1, @splat(0), &members),
        .layout = try pool_layout.Layout.init(.replicated, 1, 1, 1024 * 1024),
    };
    const names = [_][]const u8{ "survivor", "lost" };
    for (names, 0..) |name, index| {
        const header: member_format.Header = .{
            .header_sequence = 1,
            .incompat_features = member_format.dynamic_pool_incompat_feature,
            .set_id = payload.topology.set_id,
            .member_id = members[index].member_id,
            .member_slot = members[index].slot,
            .member_count = 2,
            .role_flags = member_format.known_role_flags,
            .created_ns = 1,
            .member_bytes = 3 * 1024 * 1024,
            .logical_capacity = 1024 * 1024,
            .control = .{ .offset = 64 * 1024, .length = 64 * 1024 },
            .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
            .data = .{ .offset = 2 * 1024 * 1024, .length = 1024 * 1024 },
            .metadata_block_size = 4096,
            .metadata_read_size = 512,
            .metadata_program_size = 512,
            .chunk_size = 1024 * 1024,
            .metadata_format_version = 1,
            .object_format_version = 1,
            .layout_format_version = member_format.dynamic_layout_format_version,
            .control_record_format_version = 1,
            .label = try member_format.Label.init("recovery-test"),
            .genesis_topology_digest = try pool_topology.digest(payload.topology),
        };
        var member = try member_api.createPoolAt(std.testing.io, tmp.dir, name, header, payload, .{});
        try member.close();
    }

    const survivor_location: pool_member_set.Location = .{ .parent = tmp.dir, .basename = names[0] };
    const survivor_locations = [_]pool_member_set.Location{survivor_location};
    try std.testing.expectError(
        error.NoGenesisQuorum,
        pool_member_set.open(std.testing.io, std.testing.allocator, &survivor_locations, .writable),
    );
    var recovery_set = try pool_member_set.openAdministrativeRecovery(
        std.testing.io,
        std.testing.allocator,
        survivor_location,
        id(2),
    );
    defer recovery_set.deinit();
    try std.testing.expect(recovery_set.isRecoveryOnly());
    var recovery_coordinator = try open(std.testing.io, &recovery_set);
    defer recovery_coordinator.deinit();
    const current = recovery_set.authority().?;
    const survivor = [_]pool_topology.Member{members[0]};
    const recovery_proposal: membership.Proposal = .{
        .mode = .administrative_recovery,
        .topology = try pool_topology.Topology.init(
            current.topology.set_id,
            current.topology.epoch + 1,
            try pool_topology.digest(current.topology),
            &survivor,
        ),
    };
    var prepare: control_record.Record = .{
        .kind = control_record.membership_prepare_kind,
        .local_sequence = 99,
        .membership_epoch = recovery_proposal.topology.epoch,
        .writer_term = 1,
        .generation = current.generation,
        .set_id = current.topology.set_id,
        .member_id = id(9),
        .mount_session_id = id(6),
        .transaction_id = id(7),
        .previous_record_digest = @splat(0x11),
        .previous_history_digest = @splat(0x22),
        .data_root_digest = current.data_root_digest,
        .topology_digest = try pool_topology.digest(recovery_proposal.topology),
        .layout_digest = try pool_layout.digest(current.layout),
        .payload = try membership.makePreparePayload(recovery_proposal),
    };
    prepare.history_digest = try control_record.historyDigest(prepare);
    const result = try recovery_coordinator.commitMembership(prepare);
    try std.testing.expectEqual(@as(u16, 1), result.committed_count);
    recovery_coordinator.close();
    try recovery_set.close();

    var recovered = try pool_member_set.open(
        std.testing.io,
        std.testing.allocator,
        &survivor_locations,
        .writable,
    );
    defer recovered.deinit();
    try std.testing.expect(!recovered.isRecoveryOnly());
    try std.testing.expectEqual(@as(u16, 1), recovered.authority().?.topology.member_count);
    try std.testing.expectEqual(@as(u16, 1), recovered.controlWriteReady().?.active_count);
    try std.testing.expectEqual(pool_policy.DataAccess.read_only, recovered.dataAccess());
}
