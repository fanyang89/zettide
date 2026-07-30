const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const journal_api = @import("journal.zig");
const member_bootstrap = @import("member_bootstrap.zig");
const membership = @import("membership.zig");
const pool_authority = @import("pool_authority.zig");
const pool_authority_checkpoint = @import("pool_authority_checkpoint.zig");
const pool_catalog = @import("pool_catalog.zig");
const pool_catalog_graph = @import("pool_catalog_graph.zig");
const pool_catalog_page = @import("pool_catalog_page.zig");
const pool_catalog_store = @import("pool_catalog_store.zig");
const pool_certificate = @import("pool_certificate.zig");
const pool_member_set = @import("pool_member_set.zig");
const pool_policy = @import("pool_policy.zig");

const max_control_participant_count: usize = 6;

pub const CommitResult = struct {
    record: control_record.Record,
    committed_members: [pool_member_set.max_member_count]bool,
    committed_count: u16,
    degraded: bool,
    prepare_witness_members: [pool_member_set.max_member_count]bool = @splat(false),
};

pub const CatalogGenerationRequest = struct {
    prepare_proposal: control_record.Record,
    previous_graph: ?pool_catalog_graph.Graph,
    current_graph: pool_catalog_graph.Graph,
    data_initializations: []const pool_catalog_graph.DataInitialization = &.{},
};

pub const CatalogCommitResult = struct {
    generation: CommitResult,
    staged_members: [pool_member_set.max_member_count]bool,
    repaired_members: [pool_member_set.max_member_count]bool,
    repair_failed_members: [pool_member_set.max_member_count]bool,
};

pub const ControlCatchupResult = struct {
    target_index: usize,
    appended_count: usize,
    history_digest: codec.Digest,
};

pub const BootstrapResult = struct {
    record: control_record.Record,
    target_index: usize,
    voter_ack_count: u16,
};

pub const RolloverResult = struct {
    active_members: [pool_member_set.max_member_count]bool,
    active_count: u16,
    degraded: bool,
};

const Participant = struct {
    set_index: usize,
    journal: journal_api.Journal,
    active: bool,
};

const InferredAnchorTransition = enum { none, first_anchor, replacement };

pub const ReplicatedJournal = struct {
    io: std.Io,
    set: *pool_member_set.PoolMemberSet,
    participants: [max_control_participant_count]?Participant = @splat(null),
    participant_count: usize = 0,
    quorum: u16,
    recovery_only: bool,
    reclaim_required: bool,
    pending_anchor_history_digest: ?codec.Digest = null,
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
            .reclaim_required = ready.reclaim_required,
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

    fn commitGenerationLocked(
        self: *ReplicatedJournal,
        prepare_proposal: control_record.Record,
    ) !CommitResult {
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (self.reclaim_required) return error.ReclaimBarrierRequired;
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
        if (prepare_proposal.writer_term < authority.writer_term) return error.WriterTermRegression;

        var targets: [max_control_participant_count]bool = @splat(false);
        var target_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            if (!participant.active) continue;
            if (!try participant.journal.hasAppendCapacity(3)) continue;
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
                participant.active = false;
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
        var prepare_witness_members: [pool_member_set.max_member_count]bool = @splat(false);
        for (certificate.attestations[0..certificate.count]) |attestation| {
            for (0..self.participant_count) |index| {
                const participant = self.participants[index].?;
                const member = (try self.set.memberAt(participant.set_index)) orelse continue;
                if (std.mem.eql(u8, &member.header().member_id, &attestation.member_id))
                    prepare_witness_members[participant.set_index] = true;
            }
        }
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
                participant.active = false;
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
            .degraded = commit_count < target_count,
            .prepare_witness_members = prepare_witness_members,
        };
    }

    pub fn commitCatalogGeneration(
        self: *ReplicatedJournal,
        request: CatalogGenerationRequest,
    ) !CatalogCommitResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const authority = try self.validateGenerationProposal(request.prepare_proposal);

        var voter_buffer: [pool_member_set.max_member_count]pool_member_set.CatalogVoter = undefined;
        const voters = try self.set.collectCatalogVoters(&voter_buffer);
        var catalog_claims: [pool_member_set.max_member_count]?member_api.CatalogClaim = @splat(null);
        var claimed_voter_count: usize = 0;
        for (voters, 0..) |voter, index| {
            catalog_claims[index] = voter.member.claimCatalog() catch {
                for (catalog_claims[0..claimed_voter_count]) |*maybe_claim| {
                    if (maybe_claim.*) |*claim| claim.release() catch unreachable;
                }
                self.frozen.store(true, .release);
                self.set.revokeWriteReady();
                return error.CatalogClaimUnavailable;
            };
            claimed_voter_count += 1;
        }
        defer for (catalog_claims[0..claimed_voter_count]) |*maybe_claim| {
            if (maybe_claim.*) |*claim| claim.release() catch unreachable;
        };
        var data_claims: [pool_member_set.max_member_count]?member_api.DataClaim = @splat(null);
        defer for (&data_claims) |*maybe_claim| {
            if (maybe_claim.*) |*claim| claim.release() catch unreachable;
        };

        var geometry_buffer: [pool_member_set.max_member_count]pool_catalog_graph.MemberGeometry = undefined;
        const geometry = try self.set.collectCatalogGeometry(&geometry_buffer);
        const current_binding: pool_catalog_graph.AuthorityBinding = .{
            .generation = request.prepare_proposal.generation,
            .data_root_digest = request.prepare_proposal.data_root_digest,
            .topology = authority.topology,
            .layout = authority.layout,
        };
        var previous: ?pool_catalog_graph.ValidatedCatalog = null;
        const current = if (authority.generation == 0) current: {
            if (request.previous_graph != null) return error.UnexpectedPreviousCatalog;
            break :current try pool_catalog_graph.validateGraph(
                current_binding,
                request.current_graph,
                geometry,
            );
        } else current: {
            const previous_graph = request.previous_graph orelse return error.MissingPreviousCatalog;
            const previous_binding: pool_catalog_graph.AuthorityBinding = .{
                .generation = authority.generation,
                .data_root_digest = authority.data_root_digest,
                .topology = authority.topology,
                .layout = authority.layout,
            };
            previous = try pool_catalog_graph.validateGraph(
                previous_binding,
                previous_graph,
                geometry,
            );
            break :current try pool_catalog_graph.validateTransition(
                previous_binding,
                previous_graph,
                geometry,
                current_binding,
                request.current_graph,
                geometry,
            );
        };
        try pool_catalog_graph.validateDataInitializations(
            if (previous) |*value| value else null,
            &current,
            request.data_initializations,
        );
        self.claimDataMembers(if (previous) |*value| value else null, &current, &data_claims) catch
            return error.DataClaimUnavailable;
        self.activateCatalogData(catalog_claims[0..claimed_voter_count], &data_claims) catch {
            self.failDataPublication();
            return error.CatalogDataActivationFailed;
        };
        if (request.data_initializations.len != 0) {
            self.stageDataInitializations(&current, request.data_initializations, &data_claims) catch {
                self.frozen.store(true, .release);
                self.set.revokeWriteReady();
                self.set.revokeDataAccess();
                return error.DataStagingFailed;
            };
        }

        var staged_members: [pool_member_set.max_member_count]bool = @splat(false);
        for (voters, 0..) |voter, voter_index| {
            const claim = &(catalog_claims[voter_index].?);
            if (authority.generation == 0) {
                _ = pool_catalog_store.stageInitialization(
                    claim,
                    authority,
                    &current,
                    request.current_graph,
                ) catch {
                    self.failCatalogMember(voter.set_index);
                    self.set.revokeDataAccess();
                    return error.CatalogStagingFailed;
                };
            } else {
                _ = pool_catalog_store.stageTransition(
                    claim,
                    authority,
                    &previous.?,
                    &current,
                    request.current_graph,
                ) catch {
                    self.failCatalogMember(voter.set_index);
                    self.set.revokeDataAccess();
                    return error.CatalogStagingFailed;
                };
            }
            staged_members[voter.set_index] = true;
        }

        const generation = self.commitGenerationLocked(request.prepare_proposal) catch |err| {
            self.failDataPublication();
            return err;
        };
        for (generation.prepare_witness_members, 0..) |witness, index| {
            if (witness and !staged_members[index]) {
                self.frozen.store(true, .release);
                self.set.revokeWriteReady();
                self.set.revokeDataAccess();
                return error.UnstagedPrepareWitness;
            }
        }

        var repaired_members: [pool_member_set.max_member_count]bool = @splat(false);
        var repair_failed_members: [pool_member_set.max_member_count]bool = @splat(false);
        const committed_authority = self.set.authority().?;
        for (voters, 0..) |voter, voter_index| {
            _ = pool_catalog_store.repairRootMirror(
                &(catalog_claims[voter_index].?),
                committed_authority,
                request.current_graph.root_bytes,
            ) catch {
                repair_failed_members[voter.set_index] = true;
                self.failCatalogMember(voter.set_index);
                self.set.revokeDataAccess();
                continue;
            };
            repaired_members[voter.set_index] = true;
        }
        return .{
            .generation = generation,
            .staged_members = staged_members,
            .repaired_members = repaired_members,
            .repair_failed_members = repair_failed_members,
        };
    }

    pub fn installCatalogForMember(
        self: *ReplicatedJournal,
        target_member_id: [16]u8,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (self.recovery_only) return error.RecoveryOnlyCoordinator;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        if (authority.generation == 0 or codec.isZero(&authority.data_root_digest))
            return error.GenesisHasNoCatalogRoot;
        const descriptor = pool_topology.findMember(&authority.topology, target_member_id) orelse
            return error.CatalogTargetNotInTopology;
        if (descriptor.control_role == pool_topology.voter_role) return error.CatalogTargetAlreadyVoter;
        if (descriptor.state != .joining and descriptor.state != .active)
            return error.CatalogTargetMustBeNonVoter;

        var target_index: ?usize = null;
        for (0..self.set.suppliedCount()) |index| {
            const member = (try self.set.memberAt(index)) orelse continue;
            if (std.mem.eql(u8, &member.header().member_id, &target_member_id)) {
                target_index = index;
                break;
            }
        }
        const resolved_target_index = target_index orelse return error.CatalogTargetUnavailable;
        const target_history = if (self.set.histories[resolved_target_index]) |*value| value else return error.CatalogTargetNotCaughtUp;
        const target_tail = target_history.scan_result.tail orelse return error.CatalogTargetNotCaughtUp;
        if (!std.mem.eql(u8, &target_tail.history_digest, &authority.history_digest) or
            target_history.findHistoryDigest(authority.history_digest) == null or
            target_history.scan_result.unresolved_tail_damage or
            journal_api.availableSlotCount(target_history.scan_result) < 3)
            return error.CatalogTargetNotCaughtUp;
        const target_entries = target_history.entries();
        if (target_entries.len == 0) return error.MemberBootstrapRequired;
        if (descriptor.state == .joining) {
            if (target_entries[0].record.kind != control_record.member_bootstrap_kind)
                return error.MemberBootstrapRequired;
            const bootstrap = try member_bootstrap.validateRecord(target_entries[0].record);
            if (!std.mem.eql(u8, &bootstrap.target_member_id, &target_member_id))
                return error.MemberBootstrapRequired;
        } else {
            if (target_entries[0].record.kind != control_record.genesis_kind)
                return error.PoolGenesisRequired;
            const genesis = try pool_genesis.validateRecord(target_entries[0].record);
            if (pool_topology.findMember(&genesis.topology, target_member_id) == null)
                return error.PoolGenesisRequired;
        }

        var voter_buffer: [pool_member_set.max_member_count]pool_member_set.CatalogVoter = undefined;
        const voters = try self.set.collectCatalogVoters(&voter_buffer);
        const source = voters[0];
        self.set.validateCatalogTargetGeometry(source.set_index, resolved_target_index) catch |err| {
            self.set.noteCatalogFailure(resolved_target_index, err);
            return error.CatalogTargetGeometryMismatch;
        };
        var geometry_buffer: [pool_member_set.max_member_count]pool_catalog_graph.MemberGeometry = undefined;
        const geometry = try self.set.collectCatalogGeometry(&geometry_buffer);
        var source_claim = try source.member.claimCatalog();
        defer source_claim.release() catch unreachable;
        const target_member = (try self.set.memberAt(resolved_target_index)) orelse
            return error.CatalogTargetUnavailable;
        var target_claim = target_member.claimCatalog() catch return error.CatalogTargetUnavailable;
        defer target_claim.release() catch unreachable;

        var source_scratch: pool_catalog_store.LoadScratch = .{};
        _ = pool_catalog_store.loadAuthorityCatalog(
            source.member,
            authority,
            geometry,
            &source_scratch,
        ) catch |err| {
            self.set.noteCatalogFailure(source.set_index, err);
            self.frozen.store(true, .release);
            self.set.revokeWriteReady();
            self.set.revokeDataAccess();
            return error.CatalogSourceInvalid;
        };
        target_claim.activateCatalogData() catch {
            self.set.noteCatalogFailure(resolved_target_index, error.CatalogDataActivationFailed);
            return error.CatalogDataActivationFailed;
        };
        var verify_scratch: pool_catalog_store.LoadScratch = .{};
        pool_catalog_store.installAuthorityCatalog(
            &target_claim,
            authority,
            geometry,
            &source_scratch,
            &verify_scratch,
        ) catch |err| {
            self.set.noteCatalogFailure(resolved_target_index, err);
            return err;
        };
        self.set.noteCatalogInstalled(resolved_target_index);
    }

    pub fn catchUpControlForMember(
        self: *ReplicatedJournal,
        allocator: std.mem.Allocator,
        target_member_id: [16]u8,
    ) !ControlCatchupResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (self.recovery_only) return error.RecoveryOnlyCoordinator;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        const descriptor = pool_topology.findMember(&authority.topology, target_member_id) orelse
            return error.ControlCatchupTargetNotInTopology;
        if (descriptor.state != .active or descriptor.control_role == pool_topology.voter_role)
            return error.ControlCatchupTargetMustBeActiveNonVoter;

        var target_index: ?usize = null;
        for (0..self.set.suppliedCount()) |index| {
            const member = (try self.set.memberAt(index)) orelse continue;
            if (std.mem.eql(u8, &member.header().member_id, &target_member_id)) {
                target_index = index;
                break;
            }
        }
        const resolved_target_index = target_index orelse return error.ControlCatchupTargetUnavailable;
        const target_member = (try self.set.memberAt(resolved_target_index)) orelse
            return error.ControlCatchupTargetUnavailable;
        if (target_member.mode() != .writable or target_member.isFrozen() or target_member.isClosed())
            return error.ControlCatchupTargetUnavailable;

        var target_history = journal_api.scanHistory(allocator, target_member) catch |err| {
            self.set.noteControlCatchupFailure(resolved_target_index);
            return err;
        };
        defer target_history.deinit();
        const target_entries = target_history.entries();
        if (target_entries.len == 0 or target_entries[0].record.kind != control_record.genesis_kind)
            return error.ControlCatchupTargetIsNotGenesisMember;
        const genesis = try pool_genesis.validateRecord(target_entries[0].record);
        if (pool_topology.findMember(&genesis.topology, target_member_id) == null)
            return error.ControlCatchupTargetIsNotGenesisMember;
        if (target_history.scan_result.unresolved_tail_damage or target_history.scan_result.anchored)
            return error.ControlCatchupTargetDamaged;
        const target_tail = target_history.scan_result.tail orelse return error.MissingGenesis;

        var source_history: ?journal_api.HistoryScan = null;
        defer if (source_history) |*history| history.deinit();
        var replay_start: usize = 0;
        if (!std.mem.eql(u8, &target_tail.history_digest, &authority.history_digest)) {
            var crossed_checkpoint = false;
            var crossed_voter_role = false;
            for (self.participants[0..self.participant_count]) |*maybe_participant| {
                const participant = &(maybe_participant.* orelse continue);
                if (!participant.active) continue;
                var candidate = journal_api.scanHistory(allocator, participant.journal.member) catch continue;
                var keep = false;
                defer if (!keep) candidate.deinit();
                const source_tail = candidate.scan_result.tail orelse continue;
                if (!std.mem.eql(u8, &source_tail.history_digest, &authority.history_digest)) continue;
                const entries = candidate.entries();
                var target_position: ?usize = null;
                for (entries, 0..) |entry, index| {
                    if (std.mem.eql(u8, &entry.record.history_digest, &target_tail.history_digest)) {
                        target_position = index;
                        break;
                    }
                }
                const position = target_position orelse continue;
                var replay_topology = switch (entries[0].record.kind) {
                    control_record.genesis_kind => (pool_genesis.validateRecord(entries[0].record) catch continue).topology,
                    control_record.member_bootstrap_kind => (member_bootstrap.validateRecord(entries[0].record) catch continue).topology,
                    else => continue,
                };
                var valid_topology_history = true;
                for (entries[1 .. position + 1]) |entry| {
                    if (entry.record.kind != control_record.membership_commit_kind) continue;
                    const proposal = membership.validateRecordProposal(entry.record) catch {
                        valid_topology_history = false;
                        break;
                    };
                    replay_topology = proposal.topology;
                }
                if (!valid_topology_history) continue;
                if (isVoter(replay_topology, target_member_id)) {
                    crossed_voter_role = true;
                    continue;
                }
                var expected_digest = target_tail.history_digest;
                var continuous = true;
                for (entries[position + 1 ..]) |entry| {
                    if (!std.mem.eql(u8, &entry.record.previous_history_digest, &expected_digest)) {
                        continuous = false;
                        break;
                    }
                    if (entry.record.kind == control_record.checkpoint_kind) {
                        crossed_checkpoint = true;
                        continuous = false;
                        break;
                    }
                    if (entry.record.kind == control_record.membership_commit_kind) {
                        const proposal = membership.validateRecordProposal(entry.record) catch {
                            continuous = false;
                            break;
                        };
                        if (isVoter(replay_topology, target_member_id) or
                            isVoter(proposal.topology, target_member_id))
                        {
                            crossed_voter_role = true;
                            continuous = false;
                            break;
                        }
                        replay_topology = proposal.topology;
                    }
                    expected_digest = entry.record.history_digest;
                }
                if (!continuous or !std.mem.eql(u8, &expected_digest, &authority.history_digest)) continue;
                replay_start = position + 1;
                source_history = candidate;
                keep = true;
                break;
            }
            if (source_history == null) {
                if (crossed_voter_role) return error.ControlCatchupCrossesVoterRole;
                if (crossed_checkpoint) return error.ControlCatchupCrossesCheckpoint;
                return error.ControlCatchupHistoryUnavailable;
            }
        }

        const replay_entries = if (source_history) |*history| history.entries()[replay_start..] else &.{};
        const required_slots = std.math.add(u64, @intCast(replay_entries.len), 3) catch
            return error.ControlCatchupCapacityOverflow;
        if (journal_api.availableSlotCount(target_history.scan_result) < required_slots)
            return error.InsufficientJournalCapacity;
        _ = std.math.add(u64, target_tail.local_sequence, @as(u64, @intCast(replay_entries.len))) catch
            return error.RecordSequenceOverflow;

        if (replay_entries.len != 0) {
            var target_journal = journal_api.Journal.open(target_member) catch {
                self.set.noteControlCatchupFailure(resolved_target_index);
                return error.ControlCatchupTargetUnavailable;
            };
            defer target_journal.deinit();
            for (replay_entries) |entry| {
                const prepared = target_journal.prepareExact(
                    try target_journal.tailToken(),
                    entry.record,
                ) catch |err| {
                    self.set.noteControlCatchupFailure(resolved_target_index);
                    return err;
                };
                if (!std.mem.eql(u8, &prepared.record.history_digest, &entry.record.history_digest))
                    return error.ControlCatchupHistoryDiverged;
                const appended = target_journal.appendPrepared(&prepared) catch {
                    self.set.noteControlCatchupFailure(resolved_target_index);
                    return error.ControlCatchupOutcomeUnknown;
                };
                if (!std.mem.eql(u8, &appended.record.history_digest, &entry.record.history_digest))
                    return error.ControlCatchupHistoryDiverged;
            }
            target_journal.close();
        }

        var replacement = journal_api.scanHistory(allocator, target_member) catch |err| {
            self.set.noteControlCatchupFailure(resolved_target_index);
            return err;
        };
        var transferred = false;
        defer if (!transferred) replacement.deinit();
        self.set.noteControlCaughtUp(resolved_target_index, replacement) catch |err| {
            self.set.noteControlCatchupFailure(resolved_target_index);
            return err;
        };
        transferred = true;
        return .{
            .target_index = resolved_target_index,
            .appended_count = replay_entries.len,
            .history_digest = authority.history_digest,
        };
    }

    fn validateGenerationProposal(
        self: *ReplicatedJournal,
        prepare_proposal: control_record.Record,
    ) !pool_authority.Authority {
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (self.reclaim_required) return error.ReclaimBarrierRequired;
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
        if (prepare_proposal.writer_term < authority.writer_term) return error.WriterTermRegression;
        return authority;
    }

    fn failCatalogMember(self: *ReplicatedJournal, set_index: usize) void {
        self.frozen.store(true, .release);
        self.set.noteControlFailure(set_index);
        self.set.revokeWriteReady();
    }

    fn failDataPublication(self: *ReplicatedJournal) void {
        self.frozen.store(true, .release);
        self.set.revokeWriteReady();
        self.set.revokeDataAccess();
    }

    fn claimDataMembers(
        self: *ReplicatedJournal,
        previous: ?*const pool_catalog_graph.ValidatedCatalog,
        current: *const pool_catalog_graph.ValidatedCatalog,
        claims: *[pool_member_set.max_member_count]?member_api.DataClaim,
    ) !void {
        var required_slots: [pool_topology.max_member_count]bool = @splat(false);
        for ([_]?*const pool_catalog_graph.ValidatedCatalog{ previous, current }) |maybe_catalog| {
            const catalog = maybe_catalog orelse continue;
            for (0..catalog.root.volume_count) |volume_index| {
                for (catalog.extentSlice(volume_index)) |run| {
                    for (run.memberSlice()) |slot| {
                        var topology_index: ?usize = null;
                        for (self.set.authority().?.topology.memberSlice(), 0..) |member, index| {
                            if (member.slot == slot) topology_index = index;
                        }
                        const resolved_index = topology_index orelse return error.DataMemberNotInTopology;
                        required_slots[resolved_index] = true;
                    }
                }
            }
        }
        for (required_slots, 0..) |required, topology_index| {
            if (!required) continue;
            const slot = self.set.authority().?.topology.members[topology_index].slot;
            const data_member = try self.set.dataMemberForWrite(slot);
            if (claims[data_member.set_index] != null) continue;
            claims[data_member.set_index] = try data_member.member.claimData();
        }
    }

    fn activateCatalogData(
        self: *ReplicatedJournal,
        catalog_claims: []const ?member_api.CatalogClaim,
        data_claims: *[pool_member_set.max_member_count]?member_api.DataClaim,
    ) !void {
        _ = self;
        for (catalog_claims) |maybe_claim| if (maybe_claim) |claim| try claim.activateCatalogData();
        for (data_claims) |maybe_claim| if (maybe_claim) |claim| try claim.activateCatalogData();
    }

    fn stageDataInitializations(
        self: *ReplicatedJournal,
        current: *const pool_catalog_graph.ValidatedCatalog,
        initializations: []const pool_catalog_graph.DataInitialization,
        claims: *[pool_member_set.max_member_count]?member_api.DataClaim,
    ) !void {
        const zeroes: [64 * 1024]u8 = @splat(0);
        var written_members: [pool_member_set.max_member_count]bool = @splat(false);
        for (initializations) |initialization| {
            const run = findInitializationRun(current, initialization) orelse
                return error.DataInitializationMismatch;
            const run_offset = initialization.logical_start - run.logical_start;
            const physical_extent = try std.math.add(u64, run.physical_start, run_offset);
            const physical_offset = try std.math.mul(u64, physical_extent, current.root.extent_size);
            const byte_count = try std.math.mul(u64, initialization.extent_count, current.root.extent_size);
            for (run.memberSlice()) |slot| {
                const data_member = try self.set.dataMemberForWrite(slot);
                const claim = &(claims[data_member.set_index] orelse return error.DataClaimUnavailable);
                var byte_offset: u64 = 0;
                while (byte_offset < byte_count) {
                    const amount: usize = @intCast(@min(@as(u64, zeroes.len), byte_count - byte_offset));
                    const bytes = switch (initialization.contents) {
                        .zero => zeroes[0..amount],
                        .bytes => |contents| contents[@intCast(byte_offset)..][0..amount],
                    };
                    try claim.write(try std.math.add(u64, physical_offset, byte_offset), bytes);
                    byte_offset += amount;
                }
                written_members[data_member.set_index] = true;
            }
        }
        for (written_members, 0..) |written, set_index| {
            if (written) try claims[set_index].?.sync();
        }
    }

    pub fn commitMembership(
        self: *ReplicatedJournal,
        prepare_proposal: control_record.Record,
    ) !CommitResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (self.reclaim_required) return error.ReclaimBarrierRequired;
        if (prepare_proposal.kind != control_record.membership_prepare_kind)
            return error.NotMembershipPrepare;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        const proposal = try membership.validateRecordProposal(prepare_proposal);
        if (self.recovery_only and proposal.mode != .administrative_recovery)
            return error.AdministrativeRecoveryRequired;
        try membership.validateTransition(authority.topology, proposal);
        if (proposal.mode == .normal) try self.validateAnchorRetention(proposal.topology);
        try self.validateCatalogMembershipGates(authority.topology, proposal.topology, authority.history_digest);
        var promotion_claims: [pool_member_set.max_member_count]?member_api.CatalogClaim = @splat(null);
        const promotion_claim_count = try self.claimPromotionCatalogs(
            authority,
            proposal.topology,
            &promotion_claims,
        );
        defer for (promotion_claims[0..promotion_claim_count]) |*maybe_claim| {
            if (maybe_claim.*) |*claim| claim.release() catch unreachable;
        };
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
            if (!try participant.journal.hasAppendCapacity(3)) continue;
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
        const committed_count = countTrue(commit_successes[0..self.participant_count]);
        self.set.noteCommittedMembership(
            committed,
            proposal.topology,
            committed_members,
            active_members,
            active_count,
            proposal.mode == .administrative_recovery,
        );
        self.dropInactiveParticipants();
        return .{
            .record = committed,
            .committed_members = committed_members,
            .committed_count = committed_count,
            .degraded = active_count < voterCount(proposal.topology),
        };
    }

    pub fn commitAuthorityCheckpoint(
        self: *ReplicatedJournal,
        proposal: control_record.Record,
    ) !CommitResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.requireFullVoterSet(2, false);
        const committed = try self.commitAuthorityCheckpointLocked(proposal, 2);
        if (committed.committed_count != voterCount(self.set.authority().?.topology)) {
            self.set.beginControlMutation();
            self.frozen.store(true, .release);
            return error.CheckpointOutcomeUnknown;
        }
        return committed;
    }

    pub fn rolloverAuthorityCheckpoint(
        self: *ReplicatedJournal,
        proposal: control_record.Record,
    ) !CommitResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.requireFullVoterSet(1, true);
        const committed = try self.commitAuthorityCheckpointLocked(proposal, 1);
        const voter_count = voterCount(self.set.authority().?.topology);
        if (committed.committed_count != voter_count) {
            self.set.beginControlMutation();
            self.frozen.store(true, .release);
            return error.RolloverCheckpointIncomplete;
        }
        self.reclaim_required = true;
        self.pending_anchor_history_digest = committed.record.history_digest;
        _ = self.resumeRolloverLocked() catch |err| {
            self.set.beginControlMutation();
            self.frozen.store(true, .release);
            return err;
        };
        return committed;
    }

    pub fn resumeRollover(self: *ReplicatedJournal) !RolloverResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        return self.resumeRolloverLocked();
    }

    fn commitAuthorityCheckpointLocked(
        self: *ReplicatedJournal,
        proposal: control_record.Record,
        required_slots: u64,
    ) !CommitResult {
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        if (self.reclaim_required) return error.ReclaimBarrierRequired;
        if (self.recovery_only) return error.RecoveryOnlyCoordinator;
        if (proposal.kind != control_record.checkpoint_kind) return error.NotCheckpointRecord;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        const context: pool_authority_checkpoint.AuthorityContext = .{
            .history_digest = authority.history_digest,
            .data_root_digest = authority.data_root_digest,
            .topology = authority.topology,
            .layout = authority.layout,
            .membership_epoch = authority.membership_epoch,
            .writer_term = authority.writer_term,
            .generation = authority.generation,
            .administrative_recovery = authority.administrative_recovery,
        };

        var prepared: [max_control_participant_count]?journal_api.PreparedAppend = @splat(null);
        var target_count: u16 = 0;
        var shared_history: ?codec.Digest = null;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            if (!participant.active) continue;
            if (!try participant.journal.hasAppendCapacity(required_slots)) continue;
            const item = try participant.journal.prepareCheckpointExact(
                try participant.journal.tailToken(),
                proposal,
            );
            _ = try pool_authority_checkpoint.validateRecord(item.record, context);
            if (shared_history) |expected| {
                if (!std.mem.eql(u8, &expected, &item.record.history_digest))
                    return error.CheckpointHistoryDiverged;
            } else {
                shared_history = item.record.history_digest;
            }
            prepared[index] = item;
            target_count += 1;
        }
        if (target_count < self.quorum) return error.InsufficientJournalCapacity;

        self.set.beginControlMutation();
        var committed_members: [pool_member_set.max_member_count]bool = @splat(false);
        var committed_record: ?control_record.Record = null;
        var commit_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const item = prepared[index] orelse continue;
            const result = participant.journal.appendPreparedCheckpoint(&item) catch {
                participant.active = false;
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            committed_members[participant.set_index] = true;
            commit_count += 1;
            if (committed_record == null) committed_record = result.record;
        }
        if (commit_count < self.quorum) {
            self.frozen.store(true, .release);
            return error.CheckpointOutcomeUnknown;
        }
        const committed = committed_record.?;
        self.set.noteCommittedCheckpoint(committed, committed_members, commit_count);
        return .{
            .record = committed,
            .committed_members = committed_members,
            .committed_count = commit_count,
            .degraded = commit_count < target_count,
        };
    }

    fn resumeRolloverLocked(self: *ReplicatedJournal) !RolloverResult {
        if (!self.reclaim_required) return error.RolloverNotRequired;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        const voter_count = voterCount(authority.topology);
        const inferred = if (self.pending_anchor_history_digest == null)
            try self.inferAnchorTransition(authority, voter_count)
        else
            .none;
        const superseding = self.pending_anchor_history_digest != null or inferred == .replacement;
        const target_anchor_digest = self.pending_anchor_history_digest orelse
            if (inferred != .none) authority.history_digest else null;
        const required_participants: u16 = if (self.recovery_only)
            1
        else if (superseding)
            voter_count
        else
            authority.topology.quorum;
        if (self.activeParticipantCount() < required_participants) return error.WriteQuorumUnavailable;

        self.set.beginControlMutation();
        var published: [max_control_participant_count]bool = @splat(false);
        var needs_reclaim: [max_control_participant_count]bool = @splat(false);
        var publication_anchors: [max_control_participant_count]?journal_api.AnchorState = @splat(null);
        var publish_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            if (!participant.active) continue;
            const state = participant.journal.state() catch {
                participant.active = false;
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            const tail = state.tail orelse {
                participant.active = false;
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            const maybe_anchor: ?journal_api.AnchorState = if (target_anchor_digest) |pending|
                if (tail.kind == control_record.checkpoint_kind and
                    std.mem.eql(u8, &tail.history_digest, &pending))
                    journal_api.AnchorState{
                        .record = tail,
                        .raw_record_digest = state.tail_raw_record_digest,
                        .physical_slot = state.tail_physical_slot.?,
                    }
                else
                    null
            else if (state.active_anchor) |anchor|
                anchor
            else if (self.recovery_only and tail.kind == control_record.checkpoint_kind and
                std.mem.eql(u8, &tail.history_digest, &authority.history_digest))
                journal_api.AnchorState{
                    .record = tail,
                    .raw_record_digest = state.tail_raw_record_digest,
                    .physical_slot = state.tail_physical_slot.?,
                }
            else
                null;
            const anchor = maybe_anchor orelse {
                published[index] = true;
                publish_count += 1;
                continue;
            };
            const header = participant.journal.member.header();
            const relative_offset = std.math.mul(u64, anchor.physical_slot, control_record.encoded_size) catch {
                participant.active = false;
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            const absolute_offset = std.math.add(u64, header.control.offset, relative_offset) catch {
                participant.active = false;
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            participant.journal.member.publishCheckpointRedundant(
                absolute_offset,
                anchor.record.local_sequence,
                anchor.raw_record_digest,
            ) catch {
                participant.active = false;
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            published[index] = true;
            needs_reclaim[index] = true;
            publication_anchors[index] = anchor;
            publish_count += 1;
        }
        if (publish_count < required_participants or
            (!self.recovery_only and !try self.hasAnchorQuorum(&publication_anchors, &published)))
        {
            self.frozen.store(true, .release);
            return error.AnchorPublicationFailed;
        }

        var active_members: [pool_member_set.max_member_count]bool = @splat(false);
        var reclaimed: [max_control_participant_count]bool = @splat(false);
        var reclaimed_count: u16 = 0;
        for (0..self.participant_count) |index| {
            if (!published[index]) continue;
            const participant = &(self.participants[index].?);
            if (needs_reclaim[index]) participant.journal.reclaimPublishedAnchor() catch {
                participant.active = false;
                self.set.noteControlFailure(participant.set_index);
                continue;
            };
            reclaimed[index] = true;
            active_members[participant.set_index] = true;
            reclaimed_count += 1;
        }
        const required_quorum: u16 = if (self.recovery_only) 1 else authority.topology.quorum;
        if (reclaimed_count < required_quorum or
            (!self.recovery_only and !try self.hasAnchorQuorum(&publication_anchors, &reclaimed)))
        {
            self.frozen.store(true, .release);
            return error.ReclaimQuorumFailed;
        }
        self.set.noteControlReclaimed(active_members, reclaimed_count);
        self.reclaim_required = false;
        self.pending_anchor_history_digest = null;
        return .{
            .active_members = active_members,
            .active_count = reclaimed_count,
            .degraded = reclaimed_count != required_participants,
        };
    }

    fn requireFullVoterSet(
        self: *ReplicatedJournal,
        required_slots: u64,
        validate_rollover_topology: bool,
    ) !void {
        if (self.closed) return error.CoordinatorClosed;
        if (self.frozen.load(.acquire)) return error.CoordinatorFrozen;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        const voter_count = voterCount(authority.topology);
        if (validate_rollover_topology and voter_count != 1 and voter_count != 3)
            return error.UnsupportedRolloverTopology;
        if (self.activeParticipantCount() != voter_count)
            return error.FullVoterSetRequired;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            if (participant.active and !try participant.journal.hasAppendCapacity(required_slots))
                return error.InsufficientJournalCapacity;
        }
    }

    fn hasAnchorQuorum(
        self: *ReplicatedJournal,
        anchors: *const [max_control_participant_count]?journal_api.AnchorState,
        successes: *const [max_control_participant_count]bool,
    ) !bool {
        for (anchors) |maybe_candidate| {
            const candidate = maybe_candidate orelse continue;
            const snapshot = try pool_authority_checkpoint.validateCompactedRootRecord(candidate.record);
            var witnesses: u16 = 0;
            for (anchors, 0..) |maybe_anchor, index| {
                if (!successes[index]) continue;
                const anchor = maybe_anchor orelse continue;
                if (!std.mem.eql(u8, &anchor.record.history_digest, &candidate.record.history_digest)) continue;
                const member_id = self.participants[index].?.journal.member.header().member_id;
                if (isVoter(snapshot.topology, member_id)) witnesses += 1;
            }
            if (witnesses >= snapshot.topology.quorum) return true;
        }
        return false;
    }

    fn inferAnchorTransition(
        self: *ReplicatedJournal,
        authority: pool_authority.Authority,
        voter_count: u16,
    ) !InferredAnchorTransition {
        if (voter_count != 1 and voter_count != 3) return .none;
        if (authority.kind != .checkpoint) return .none;
        var has_existing_anchor = false;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            if (!participant.active) continue;
            const state = try participant.journal.state();
            has_existing_anchor = has_existing_anchor or state.active_anchor != null;
            const tail = state.tail orelse return .none;
            if (!state.journal_full or tail.kind != control_record.checkpoint_kind or
                !std.mem.eql(u8, &tail.history_digest, &authority.history_digest)) return .none;
        }
        if (!has_existing_anchor) return .first_anchor;
        return if (self.activeParticipantCount() == voter_count) .replacement else .none;
    }

    fn validateAnchorRetention(self: *ReplicatedJournal, next: pool_topology.Topology) !void {
        var anchors: [max_control_participant_count]?journal_api.AnchorState = @splat(null);
        var active: [max_control_participant_count]bool = @splat(false);
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            if (!participant.active) continue;
            anchors[index] = (try participant.journal.state()).active_anchor;
            active[index] = true;
        }
        var saw_anchor = false;
        var retained_root_quorum = false;
        for (anchors) |maybe_candidate| {
            const candidate = maybe_candidate orelse continue;
            saw_anchor = true;
            const snapshot = try pool_authority_checkpoint.validateCompactedRootRecord(candidate.record);
            var current_witnesses: u16 = 0;
            var retained_witnesses: u16 = 0;
            for (anchors, 0..) |maybe_anchor, index| {
                if (!active[index]) continue;
                const anchor = maybe_anchor orelse continue;
                if (!std.mem.eql(u8, &anchor.record.history_digest, &candidate.record.history_digest)) continue;
                const member_id = self.participants[index].?.journal.member.header().member_id;
                if (!isVoter(snapshot.topology, member_id)) continue;
                current_witnesses += 1;
                if (isVoter(next, member_id)) retained_witnesses += 1;
            }
            if (current_witnesses >= snapshot.topology.quorum) {
                if (retained_witnesses < snapshot.topology.quorum)
                    return error.RolloverRequiredBeforeMembership;
                retained_root_quorum = true;
            }
        }
        if (saw_anchor and !retained_root_quorum) return error.AnchorQuorumUnavailable;
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
        if (self.reclaim_required) return error.ReclaimBarrierRequired;
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
            if (!try participant.journal.hasAppendCapacity(2)) continue;
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

    fn dropInactiveParticipants(self: *ReplicatedJournal) void {
        var retained_count: usize = 0;
        for (0..self.participant_count) |index| {
            var participant = self.participants[index].?;
            if (!participant.active) {
                participant.journal.close();
                self.participants[index] = null;
                continue;
            }
            if (retained_count != index) {
                self.participants[retained_count] = participant;
                self.participants[index] = null;
            }
            retained_count += 1;
        }
        self.participant_count = retained_count;
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

    fn validateCatalogMembershipGates(
        self: *const ReplicatedJournal,
        current: pool_topology.Topology,
        next: pool_topology.Topology,
        authority_digest: codec.Digest,
    ) !void {
        const selected = self.set.authority() orelse return error.MissingAuthority;
        if (!codec.isZero(&selected.data_root_digest) and removesMember(current, next))
            return error.CatalogDrainRequired;
        for (current.memberSlice()) |old_member| {
            const new_member = pool_topology.findMember(&next, old_member.member_id) orelse continue;
            if (old_member.state != .joining) continue;
            if (new_member.state != .active) continue;
            if (activatesAsNonVoter(old_member, new_member.*)) return error.ActiveNonVoterCatchupNotSupported;
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

    fn claimPromotionCatalogs(
        self: *ReplicatedJournal,
        authority: pool_authority.Authority,
        next: pool_topology.Topology,
        claims: *[pool_member_set.max_member_count]?member_api.CatalogClaim,
    ) !usize {
        if (codec.isZero(&authority.data_root_digest)) return 0;
        var geometry_buffer: [pool_member_set.max_member_count]pool_catalog_graph.MemberGeometry = undefined;
        const geometry = try self.set.collectCatalogGeometry(&geometry_buffer);
        var scratch: pool_catalog_store.LoadScratch = .{};
        var count: usize = 0;
        errdefer for (claims[0..count]) |*maybe_claim| {
            if (maybe_claim.*) |*claim| claim.release() catch unreachable;
        };
        for (authority.topology.memberSlice()) |old_member| {
            const new_member = pool_topology.findMember(&next, old_member.member_id) orelse continue;
            if (!requiresCatalogPromotionProof(old_member, new_member.*)) continue;
            var target_index: ?usize = null;
            for (0..self.set.suppliedCount()) |index| {
                const member = (try self.set.memberAt(index)) orelse continue;
                if (std.mem.eql(u8, &member.header().member_id, &old_member.member_id)) {
                    target_index = index;
                    break;
                }
            }
            const index = target_index orelse return error.CatalogCatchupRequired;
            const member = (try self.set.memberAt(index)) orelse return error.CatalogCatchupRequired;
            claims[count] = member.claimCatalog() catch return error.CatalogCatchupRequired;
            count += 1;
            const loaded = pool_catalog_store.loadAuthorityCatalog(
                member,
                authority,
                geometry,
                &scratch,
            ) catch return error.CatalogCatchupRequired;
            if (loaded.selection.mirror_degraded) return error.CatalogCatchupRequired;
            _ = pool_catalog_graph.validateGraph(.{
                .generation = authority.generation,
                .data_root_digest = authority.data_root_digest,
                .topology = next,
                .layout = authority.layout,
            }, scratch.graph(), geometry) catch return error.CatalogCatchupRequired;
        }
        return count;
    }
};

fn findInitializationRun(
    catalog: *const pool_catalog_graph.ValidatedCatalog,
    initialization: pool_catalog_graph.DataInitialization,
) ?pool_catalog.ExtentRun {
    const initialization_end = std.math.add(
        u64,
        initialization.logical_start,
        initialization.extent_count,
    ) catch return null;
    for (catalog.descriptorSlice(), 0..) |descriptor, volume_index| {
        if (!std.mem.eql(u8, &descriptor.volume_id, &initialization.volume_id)) continue;
        for (catalog.extentSlice(volume_index)) |run| {
            const run_end = run.logical_start + run.extent_count;
            if (run.state == .mapped and initialization.logical_start >= run.logical_start and
                initialization_end <= run_end) return run;
        }
        return null;
    }
    return null;
}

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

fn requiresCatalogPromotionProof(old_member: pool_topology.Member, new_member: pool_topology.Member) bool {
    return (old_member.state == .joining and new_member.state == .active) or
        (old_member.control_role != pool_topology.voter_role and
            new_member.control_role == pool_topology.voter_role);
}

fn activatesAsNonVoter(old_member: pool_topology.Member, new_member: pool_topology.Member) bool {
    return old_member.state == .joining and new_member.state == .active and
        new_member.control_role != pool_topology.voter_role;
}

fn removesMember(current: pool_topology.Topology, next: pool_topology.Topology) bool {
    for (current.memberSlice()) |member| {
        if (pool_topology.findMember(&next, member.member_id) == null) return true;
    }
    return false;
}

pub fn open(io: std.Io, set: *pool_member_set.PoolMemberSet) !ReplicatedJournal {
    return ReplicatedJournal.open(io, set);
}

const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const container = @import("../container.zig");
const pool_genesis = @import("pool_genesis_payload.zig");
const pool_layout = @import("pool_layout.zig");
const pool_provision = @import("pool_provision.zig");
const pool_topology = @import("pool_topology.zig");
const storage_api = @import("storage.zig");

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn checkpointProposalForAuthority(authority: pool_authority.Authority, transaction_id: [16]u8) !control_record.Record {
    return .{
        .kind = control_record.checkpoint_kind,
        .local_sequence = 0,
        .membership_epoch = authority.membership_epoch,
        .writer_term = authority.writer_term,
        .generation = authority.generation,
        .set_id = authority.topology.set_id,
        .member_id = id(8),
        .mount_session_id = id(3),
        .transaction_id = transaction_id,
        .previous_record_digest = @splat(0),
        .previous_history_digest = authority.history_digest,
        .data_root_digest = authority.data_root_digest,
        .topology_digest = try pool_topology.digest(authority.topology),
        .layout_digest = try pool_layout.digest(authority.layout),
        .payload = try pool_authority_checkpoint.makePayload(.{
            .previous_authority_history_digest = authority.history_digest,
            .data_root_digest = authority.data_root_digest,
            .writer_term = authority.writer_term,
            .generation = authority.generation,
            .topology = authority.topology,
            .layout = authority.layout,
            .administrative_recovery = authority.administrative_recovery,
        }),
    };
}

const three_voter_names = [_][]const u8{ "member0", "member1", "member2" };
const four_member_names = [_][]const u8{ "member0", "member1", "member2", "member3" };

fn threeVoterTestLocations(dir: std.Io.Dir) [three_voter_names.len]pool_member_set.Location {
    const supplied_order = [_]usize{ 2, 0, 1 };
    var locations: [three_voter_names.len]pool_member_set.Location = undefined;
    for (supplied_order, 0..) |name_index, index|
        locations[index] = .{ .parent = dir, .basename = three_voter_names[name_index] };
    return locations;
}

fn createThreeVoterTestSet(dir: std.Io.Dir) !pool_member_set.PoolMemberSet {
    var storages: [three_voter_names.len]storage_api.Storage = undefined;
    for (three_voter_names, 0..) |name, index| {
        storages[index] = storage_api.Storage.createFile(std.testing.io, dir, name, 8 * 1024 * 1024) catch |err| {
            storage_api.closeAll(storages[0..index], std.testing.io) catch {};
            return err;
        };
    }
    const outcome = try pool_provision.create(std.testing.io, std.testing.allocator, &storages, .{});
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    try provisioned.close();
    const locations = threeVoterTestLocations(dir);
    return pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
}

fn fourMemberTestLocations(dir: std.Io.Dir) [four_member_names.len]pool_member_set.Location {
    var locations: [four_member_names.len]pool_member_set.Location = undefined;
    for (four_member_names, 0..) |name, index|
        locations[index] = .{ .parent = dir, .basename = name };
    return locations;
}

fn createFourMemberTestSet(
    dir: std.Io.Dir,
    options: pool_provision.Options,
) !pool_member_set.PoolMemberSet {
    var storages: [four_member_names.len]storage_api.Storage = undefined;
    for (four_member_names, 0..) |name, index| {
        storages[index] = storage_api.Storage.createFile(std.testing.io, dir, name, 8 * 1024 * 1024) catch |err| {
            storage_api.closeAll(storages[0..index], std.testing.io) catch {};
            return err;
        };
    }
    const outcome = try pool_provision.create(std.testing.io, std.testing.allocator, &storages, options);
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    try provisioned.close();
    const locations = fourMemberTestLocations(dir);
    return pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
}

fn activeNonVoter(authority: pool_authority.Authority) !struct { pool_topology.Member, usize } {
    for (authority.topology.memberSlice(), 0..) |descriptor, index| {
        if (descriptor.control_role == pool_topology.non_voter_role) return .{ descriptor, index };
    }
    return error.MissingActiveNonVoter;
}

const GenesisCatalog = struct {
    physical_bytes: [pool_catalog.page_size]u8,
    metadata_bytes: [pool_catalog.page_size]u8,
    physical_reference: pool_catalog.PageReference,
    metadata_reference: pool_catalog.PageReference,
    root: pool_catalog.Root,
    root_bytes: [pool_catalog.root_encoded_size]u8,

    fn init(set: *pool_member_set.PoolMemberSet) !GenesisCatalog {
        const authority = set.authority() orelse return error.MissingAuthority;
        var physical: [pool_member_set.max_member_count]pool_catalog_page.PhysicalInterval = undefined;
        for (authority.topology.memberSlice(), 0..) |descriptor, index| {
            const member = try set.memberById(descriptor.member_id);
            physical[index] = .{
                .member_slot = descriptor.slot,
                .physical_start = 0,
                .extent_count = member.header().data.length / authority.layout.chunk_size,
            };
        }
        const physical_bytes = try pool_catalog_page.encodePhysicalIntervals(
            .physical_allocator,
            1,
            physical[0..authority.topology.member_count],
        );
        const metadata_page_count = ((try set.memberAt(0)).?).header().metadata.length / pool_catalog.page_size;
        const metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(1, &.{.{
            .page_start = 4,
            .page_count = @intCast(metadata_page_count - 4),
        }});
        const physical_reference = try pool_catalog_page.pageReference(2 * pool_catalog.page_size, &physical_bytes);
        const metadata_reference = try pool_catalog_page.pageReference(3 * pool_catalog.page_size, &metadata_bytes);
        const root: pool_catalog.Root = .{
            .set_id = authority.topology.set_id,
            .generation = 1,
            .sequence = 1,
            .previous_root_digest = @splat(0),
            .allocator_root = physical_reference,
            .metadata_allocator_root = metadata_reference,
            .extent_size = authority.layout.chunk_size,
        };
        return .{
            .physical_bytes = physical_bytes,
            .metadata_bytes = metadata_bytes,
            .physical_reference = physical_reference,
            .metadata_reference = metadata_reference,
            .root = root,
            .root_bytes = try pool_catalog.encodeRoot(root),
        };
    }

    fn proposal(self: *const GenesisCatalog, authority: pool_authority.Authority) !control_record.Record {
        var result: control_record.Record = .{
            .kind = control_record.generation_prepare_kind,
            .local_sequence = 99,
            .membership_epoch = authority.membership_epoch,
            .writer_term = @max(authority.writer_term, 1),
            .generation = 1,
            .set_id = authority.topology.set_id,
            .member_id = id(8),
            .mount_session_id = id(3),
            .transaction_id = id(4),
            .previous_record_digest = @splat(0x11),
            .previous_history_digest = @splat(0x22),
            .data_root_digest = try pool_catalog.rootDigest(self.root),
            .topology_digest = try pool_topology.digest(authority.topology),
            .layout_digest = try pool_layout.digest(authority.layout),
            .payload = try control_record.Payload.init("generation"),
        };
        result.history_digest = try control_record.historyDigest(result);
        return result;
    }
};

fn commitTestGenesisCatalog(
    coordinator: *ReplicatedJournal,
    set: *pool_member_set.PoolMemberSet,
) !CatalogCommitResult {
    const catalog = try GenesisCatalog.init(set);
    const images = [_]pool_catalog_graph.PageImage{
        .{ .offset = catalog.physical_reference.offset, .bytes = &catalog.physical_bytes },
        .{ .offset = catalog.metadata_reference.offset, .bytes = &catalog.metadata_bytes },
    };
    return coordinator.commitCatalogGeneration(.{
        .prepare_proposal = try catalog.proposal(set.authority().?),
        .previous_graph = null,
        .current_graph = .{ .root_bytes = &catalog.root_bytes, .pages = &images },
    });
}

test "catalog promotion proof covers joining and active non-voters" {
    const active_non_voter: pool_topology.Member = .{
        .member_id = id(2),
        .slot = 7,
        .control_role = 0,
        .role_flags = member_format.data_role,
    };
    var promoted = active_non_voter;
    promoted.control_role = pool_topology.voter_role;
    try std.testing.expect(requiresCatalogPromotionProof(active_non_voter, promoted));

    var joining = active_non_voter;
    joining.state = .joining;
    try std.testing.expect(requiresCatalogPromotionProof(joining, promoted));
    try std.testing.expect(activatesAsNonVoter(joining, active_non_voter));
}

test "member removal requires catalog drain" {
    const members = [_]pool_topology.Member{
        .{ .member_id = id(2), .slot = 7, .control_role = pool_topology.voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = id(3), .slot = 11, .state = .draining, .control_role = pool_topology.voter_role, .role_flags = member_format.known_role_flags },
    };
    const current = try pool_topology.Topology.init(id(1), 1, @splat(0), &members);
    const next = try pool_topology.Topology.init(id(1), 2, try pool_topology.digest(current), members[0..1]);
    try std.testing.expect(removesMember(current, next));
    try std.testing.expect(!removesMember(current, current));
}

test "three-voter catalog publication fault matrix" {
    const Case = enum {
        success,
        activation_failure,
        staging_first_page,
        staging_second_page,
        staging_root,
        single_prepare_failure,
        prepare_quorum_failure,
        unknown_commit_before,
        unknown_commit_after,
        repair_failure,
    };
    inline for (std.enums.values(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var set = try createThreeVoterTestSet(tmp.dir);
        defer set.deinit();
        var coordinator = try open(std.testing.io, &set);
        defer coordinator.deinit();
        var faults: [three_voter_names.len]member_api.FaultController = @splat(.{});
        switch (case) {
            .success => {},
            .activation_failure => faults[2].fail_write_at = 0,
            .staging_first_page => faults[2].fail_write_at = 2,
            .staging_second_page => faults[2].fail_write_at = 3,
            .staging_root => faults[2].fail_write_at = 4,
            .single_prepare_failure => faults[0].fail_write_at = 5,
            .prepare_quorum_failure => {
                faults[1].fail_write_at = 5;
                faults[2].fail_write_at = 5;
            },
            .unknown_commit_before => {
                faults[1].fail_write_at = 6;
                faults[2].fail_write_at = 6;
            },
            .unknown_commit_after => {
                faults[1].fail_sync_after_at = 5;
                faults[2].fail_sync_after_at = 5;
            },
            .repair_failure => faults[2].fail_write_at = 7,
        }
        for (&faults, 0..) |*fault, index|
            ((try set.memberAt(index)) orelse return error.MemberUnavailable).setFaultController(fault);

        switch (case) {
            .activation_failure => {
                try std.testing.expectError(error.CatalogDataActivationFailed, commitTestGenesisCatalog(&coordinator, &set));
                try std.testing.expectEqual(@as(u64, 0), set.authority().?.generation);
                try std.testing.expectEqual(@as(u64, 0), faults[0].write_count);
                try std.testing.expectEqual(@as(u64, 2), faults[1].write_count);
                try std.testing.expectEqual(@as(u64, 1), faults[2].write_count);
            },
            .staging_first_page, .staging_second_page, .staging_root => {
                try std.testing.expectError(error.CatalogStagingFailed, commitTestGenesisCatalog(&coordinator, &set));
                try std.testing.expectEqual(@as(u64, 0), set.authority().?.generation);
                try std.testing.expectEqual(@as(u64, 2), faults[0].write_count);
                try std.testing.expectEqual(@as(u64, 5), faults[1].write_count);
                const failed_writes: u64 = switch (case) {
                    .staging_first_page => 3,
                    .staging_second_page => 4,
                    .staging_root => 5,
                    else => unreachable,
                };
                try std.testing.expectEqual(failed_writes, faults[2].write_count);
            },
            .prepare_quorum_failure => {
                try std.testing.expectError(error.PrepareQuorumFailed, commitTestGenesisCatalog(&coordinator, &set));
                try std.testing.expectEqual(@as(u64, 0), set.authority().?.generation);
                for (faults) |fault| try std.testing.expectEqual(@as(u64, 6), fault.write_count);
            },
            .unknown_commit_before, .unknown_commit_after => {
                try std.testing.expectError(error.CommitOutcomeUnknown, commitTestGenesisCatalog(&coordinator, &set));
                try std.testing.expectEqual(@as(u64, 0), set.authority().?.generation);
                for (faults) |fault| try std.testing.expectEqual(@as(u64, 7), fault.write_count);
            },
            .success, .single_prepare_failure, .repair_failure => {
                const result = try commitTestGenesisCatalog(&coordinator, &set);
                try std.testing.expectEqual(@as(u64, 1), set.authority().?.generation);
                const expected_commit_count: u16 = if (case == .single_prepare_failure) 2 else 3;
                try std.testing.expectEqual(expected_commit_count, result.generation.committed_count);
                try std.testing.expectEqual(@as(u16, 2), countTrue(&result.generation.prepare_witness_members));
                const omitted_witness_index: usize = if (case == .single_prepare_failure) 0 else 2;
                for (0..three_voter_names.len) |index|
                    try std.testing.expectEqual(index != omitted_witness_index, result.generation.prepare_witness_members[index]);
                for (0..three_voter_names.len) |index| try std.testing.expect(result.staged_members[index]);
                if (case == .success) {
                    for (0..three_voter_names.len) |index| try std.testing.expect(result.repaired_members[index]);
                } else {
                    const failed_index: usize = if (case == .single_prepare_failure) 0 else 2;
                    for (0..three_voter_names.len) |index| {
                        try std.testing.expectEqual(index == failed_index, result.repair_failed_members[index]);
                        try std.testing.expectEqual(index != failed_index, result.repaired_members[index]);
                    }
                }
            },
        }
        if (case != .success) {
            try std.testing.expect(coordinator.isFrozen());
            try std.testing.expect(set.controlWriteReady() == null);
        }
        if (case == .unknown_commit_before or case == .unknown_commit_after) {
            coordinator.close();
            try std.testing.expectError(error.WriteFrozen, set.close());
            const locations = threeVoterTestLocations(tmp.dir);
            var reopened = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .read_only);
            defer reopened.deinit();
            const expected_generation: u64 = if (case == .unknown_commit_after) 1 else 0;
            try std.testing.expectEqual(expected_generation, reopened.authority().?.generation);
        } else if (case == .repair_failure) {
            coordinator.close();
            try std.testing.expectError(error.WriteFrozen, set.close());
            const locations = threeVoterTestLocations(tmp.dir);
            var reopened = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
            defer reopened.deinit();
            try std.testing.expectEqual(@as(u16, 3), reopened.controlWriteReady().?.active_count);
            for (0..three_voter_names.len) |index| {
                const member = (try reopened.memberAt(index)) orelse return error.MemberUnavailable;
                var claim = try member.claimCatalog();
                defer claim.release() catch unreachable;
                const selection = try pool_catalog_store.selectAuthorityRoot(
                    pool_catalog_store.readRootCopies(&claim),
                    reopened.authority().?,
                );
                try std.testing.expect(!selection.mirror_degraded);
                try claim.release();
            }
        }
    }
}

test "genesis active non-voter catches up installs catalog and promotes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const locations = fourMemberTestLocations(tmp.dir);
    var set = try createFourMemberTestSet(tmp.dir, .{});
    defer set.deinit();
    var coordinator = try open(std.testing.io, &set);
    defer coordinator.deinit();
    const genesis_authority = set.authority().?;
    var demoted_index: ?usize = null;
    for (genesis_authority.topology.memberSlice(), 0..) |descriptor, index| {
        if (demoted_index == null and descriptor.control_role == pool_topology.voter_role) demoted_index = index;
    }
    const target_input = try activeNonVoter(genesis_authority);
    const target = target_input[0];
    const target_index = target_input[1];

    _ = try commitTestGenesisCatalog(&coordinator, &set);
    try std.testing.expectError(error.CatalogTargetNotCaughtUp, coordinator.installCatalogForMember(target.member_id));
    const catchup = try coordinator.catchUpControlForMember(std.testing.allocator, target.member_id);
    try std.testing.expectEqual(@as(usize, 2), catchup.appended_count);
    try std.testing.expectEqualSlices(u8, &set.authority().?.history_digest, &catchup.history_digest);
    const repeated = try coordinator.catchUpControlForMember(std.testing.allocator, target.member_id);
    try std.testing.expectEqual(@as(usize, 0), repeated.appended_count);
    try coordinator.installCatalogForMember(target.member_id);

    const current = set.authority().?;
    var next_members: [four_member_names.len]pool_topology.Member = undefined;
    @memcpy(&next_members, current.topology.memberSlice());
    const demoted_member_id = next_members[demoted_index.?].member_id;
    next_members[demoted_index.?].control_role = pool_topology.non_voter_role;
    next_members[demoted_index.?].role_flags = member_format.data_role;
    next_members[target_index].control_role = pool_topology.voter_role;
    next_members[target_index].role_flags = member_format.known_role_flags;
    const proposal: membership.Proposal = .{
        .mode = .normal,
        .topology = try pool_topology.Topology.init(
            current.topology.set_id,
            current.topology.epoch + 1,
            try pool_topology.digest(current.topology),
            &next_members,
        ),
    };
    var prepare: control_record.Record = .{
        .kind = control_record.membership_prepare_kind,
        .local_sequence = 99,
        .membership_epoch = proposal.topology.epoch,
        .writer_term = current.writer_term,
        .generation = current.generation,
        .set_id = current.topology.set_id,
        .member_id = id(8),
        .mount_session_id = id(6),
        .transaction_id = id(7),
        .previous_record_digest = @splat(0x11),
        .previous_history_digest = @splat(0x22),
        .data_root_digest = current.data_root_digest,
        .topology_digest = try pool_topology.digest(proposal.topology),
        .layout_digest = try pool_layout.digest(current.layout),
        .payload = try membership.makePreparePayload(proposal),
    };
    prepare.history_digest = try control_record.historyDigest(prepare);
    const promoted = try coordinator.commitMembership(prepare);
    try std.testing.expectEqual(control_record.membership_commit_kind, promoted.record.kind);
    try std.testing.expectEqual(
        pool_topology.voter_role,
        pool_topology.findMember(&set.authority().?.topology, target.member_id).?.control_role,
    );
    const demoted_catchup = try coordinator.catchUpControlForMember(std.testing.allocator, demoted_member_id);
    try std.testing.expectEqual(@as(usize, 0), demoted_catchup.appended_count);
    _ = try coordinator.commitAuthorityCheckpoint(
        try checkpointProposalForAuthority(set.authority().?, id(15)),
    );
    var demoted_set_index: ?usize = null;
    for (0..set.suppliedCount()) |index| {
        const member = (try set.memberAt(index)) orelse continue;
        if (std.mem.eql(u8, &member.header().member_id, &demoted_member_id)) demoted_set_index = index;
    }
    switch (try set.statusAt(demoted_set_index.?)) {
        .stale => {},
        else => return error.ExpectedStaleTarget,
    }

    coordinator.close();
    try set.close();
    var reopened = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
    defer reopened.deinit();
    try std.testing.expectEqual(
        pool_topology.voter_role,
        pool_topology.findMember(&reopened.authority().?.topology, target.member_id).?.control_role,
    );
}

test "active non-voter catchup preflights capacity and checkpoint ancestry" {
    inline for (.{ false, true }) |cross_checkpoint| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const options: pool_provision.Options = if (cross_checkpoint)
            .{}
        else
            .{ .control_bytes = 5 * control_record.encoded_size };
        var set = try createFourMemberTestSet(tmp.dir, options);
        defer set.deinit();
        var coordinator = try open(std.testing.io, &set);
        defer coordinator.deinit();
        const target = (try activeNonVoter(set.authority().?))[0];
        _ = try commitTestGenesisCatalog(&coordinator, &set);
        if (cross_checkpoint) {
            _ = try coordinator.commitAuthorityCheckpoint(
                try checkpointProposalForAuthority(set.authority().?, id(14)),
            );
        }
        const member = try set.memberById(target.member_id);
        var fault: member_api.FaultController = .{};
        member.setFaultController(&fault);

        if (cross_checkpoint) {
            try std.testing.expectError(
                error.ControlCatchupCrossesCheckpoint,
                coordinator.catchUpControlForMember(std.testing.allocator, target.member_id),
            );
        } else {
            try std.testing.expectError(
                error.InsufficientJournalCapacity,
                coordinator.catchUpControlForMember(std.testing.allocator, target.member_id),
            );
        }
        try std.testing.expectEqual(@as(u64, 0), fault.write_count);
        try std.testing.expect(!coordinator.isFrozen());
        try std.testing.expect(set.controlWriteReady() != null);
    }
}

test "active non-voter catchup failure only isolates target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var set = try createFourMemberTestSet(tmp.dir, .{});
    defer set.deinit();
    var coordinator = try open(std.testing.io, &set);
    defer coordinator.deinit();
    const target = (try activeNonVoter(set.authority().?))[0];
    _ = try commitTestGenesisCatalog(&coordinator, &set);
    const member = try set.memberById(target.member_id);
    var fault: member_api.FaultController = .{ .fail_write_at = 0 };
    member.setFaultController(&fault);

    try std.testing.expectError(
        error.ControlCatchupOutcomeUnknown,
        coordinator.catchUpControlForMember(std.testing.allocator, target.member_id),
    );
    try std.testing.expectEqual(@as(u64, 1), fault.write_count);
    try std.testing.expect(!coordinator.isFrozen());
    try std.testing.expect(set.controlWriteReady() != null);
    switch (try set.statusAt((try activeNonVoter(set.authority().?))[1])) {
        .stale => {},
        else => return error.ExpectedStaleTarget,
    }
}

test "mapped extents are durable before catalog publication" {
    const Case = enum {
        success,
        data_write_failure,
        data_sync_failure,
        catalog_staging_failure,
        unknown_commit_before,
        unknown_commit_after,
    };
    inline for (std.enums.values(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storages = [_]storage_api.Storage{
            try storage_api.Storage.createFile(std.testing.io, tmp.dir, "member", 8 * 1024 * 1024),
        };
        const outcome = try pool_provision.create(
            std.testing.io,
            std.testing.allocator,
            &storages,
            .{ .protection = .unprotected },
        );
        var provisioned = switch (outcome) {
            .complete => |value| value,
            .partial => return error.UnexpectedPartialCreation,
        };
        defer provisioned.deinit();
        try provisioned.close();

        const locations = [_]pool_member_set.Location{.{ .parent = tmp.dir, .basename = "member" }};
        var set = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
        defer set.deinit();
        var coordinator = try open(std.testing.io, &set);
        defer coordinator.deinit();
        const authority = set.authority().?;
        const member = (try set.memberAt(0)) orelse return error.MemberUnavailable;
        const extent_size = authority.layout.chunk_size;
        const extent_count = member.header().data.length / extent_size;

        var volume_header = try container.Header.init(std.testing.io, extent_size, "mapped");
        volume_header.chunk_size = extent_size;
        const volume_header_bytes = volume_header.encode();
        const volume_header_reference = try pool_catalog_page.pageReference(6 * pool_catalog.page_size, &volume_header_bytes);
        const run: pool_catalog.ExtentRun = .{
            .logical_start = 0,
            .physical_start = 0,
            .extent_count = 1,
            .state = .mapped,
            .member_count = 1,
            .member_slots = .{ authority.topology.members[0].slot, 0, 0 },
        };
        const extent_bytes = try pool_catalog_page.encodeExtentMap(1, volume_header.uuid, &.{run});
        const extent_reference = try pool_catalog_page.pageReference(7 * pool_catalog.page_size, &extent_bytes);
        const descriptor: pool_catalog.VolumeDescriptor = .{
            .volume_id = volume_header.uuid,
            .state = .creating,
            .provisioning = .thin,
            .created_ns = volume_header.created_ns,
            .logical_size = volume_header.logical_size,
            .header_page = volume_header_reference,
            .extent_map_root = extent_reference,
            .allocated_extent_count = 1,
            .extent_size = extent_size,
            .name = try pool_catalog.Name.init("mapped"),
        };
        const volume_bytes = try pool_catalog_page.encodeVolumeIndex(1, &.{descriptor});
        const name_bytes = try pool_catalog_page.encodeNameIndex(1, &.{.{
            .volume_id = descriptor.volume_id,
            .name = descriptor.name,
        }});
        const physical_bytes = try pool_catalog_page.encodePhysicalIntervals(.physical_allocator, 1, &.{.{
            .member_slot = run.member_slots[0],
            .physical_start = 1,
            .extent_count = extent_count - 1,
        }});
        const metadata_page_count = member.header().metadata.length / pool_catalog.page_size;
        const metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(1, &.{.{
            .page_start = 8,
            .page_count = @intCast(metadata_page_count - 8),
        }});
        const volume_reference = try pool_catalog_page.pageReference(2 * pool_catalog.page_size, &volume_bytes);
        const name_reference = try pool_catalog_page.pageReference(3 * pool_catalog.page_size, &name_bytes);
        const physical_reference = try pool_catalog_page.pageReference(4 * pool_catalog.page_size, &physical_bytes);
        const metadata_reference = try pool_catalog_page.pageReference(5 * pool_catalog.page_size, &metadata_bytes);
        const root: pool_catalog.Root = .{
            .set_id = authority.topology.set_id,
            .generation = 1,
            .sequence = 1,
            .previous_root_digest = @splat(0),
            .volume_tree_root = volume_reference,
            .name_index_root = name_reference,
            .allocator_root = physical_reference,
            .metadata_allocator_root = metadata_reference,
            .volume_count = 1,
            .extent_size = extent_size,
        };
        const root_bytes = try pool_catalog.encodeRoot(root);
        const images = [_]pool_catalog_graph.PageImage{
            .{ .offset = volume_reference.offset, .bytes = &volume_bytes },
            .{ .offset = name_reference.offset, .bytes = &name_bytes },
            .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
            .{ .offset = metadata_reference.offset, .bytes = &metadata_bytes },
            .{ .offset = volume_header_reference.offset, .bytes = &volume_header_bytes },
            .{ .offset = extent_reference.offset, .bytes = &extent_bytes },
        };
        var proposal: control_record.Record = .{
            .kind = control_record.generation_prepare_kind,
            .local_sequence = 99,
            .membership_epoch = authority.membership_epoch,
            .writer_term = @max(authority.writer_term, 1),
            .generation = 1,
            .set_id = authority.topology.set_id,
            .member_id = id(8),
            .mount_session_id = id(3),
            .transaction_id = id(4),
            .previous_record_digest = @splat(0x11),
            .previous_history_digest = @splat(0x22),
            .data_root_digest = try pool_catalog.rootDigest(root),
            .topology_digest = try pool_topology.digest(authority.topology),
            .layout_digest = try pool_layout.digest(authority.layout),
            .payload = try control_record.Payload.init("generation"),
        };
        proposal.history_digest = try control_record.historyDigest(proposal);
        const contents = try std.testing.allocator.alloc(u8, extent_size);
        defer std.testing.allocator.free(contents);
        @memset(contents, 0x5a);
        var fault: member_api.FaultController = switch (case) {
            .success => .{},
            .data_write_failure => .{ .fail_write_at = 2 },
            .data_sync_failure => .{ .fail_sync_at = 2 },
            .catalog_staging_failure => .{ .fail_write_at = 18 },
            .unknown_commit_before => .{ .fail_write_at = 26 },
            .unknown_commit_after => .{ .fail_sync_after_at = 6 },
        };
        member.setFaultController(&fault);
        const request: CatalogGenerationRequest = .{
            .prepare_proposal = proposal,
            .previous_graph = null,
            .current_graph = .{ .root_bytes = &root_bytes, .pages = &images },
            .data_initializations = &.{.{
                .volume_id = descriptor.volume_id,
                .logical_start = 0,
                .extent_count = 1,
                .contents = .{ .bytes = contents },
            }},
        };

        if (case == .success) {
            _ = try coordinator.commitCatalogGeneration(request);
            try std.testing.expectEqual(@as(u64, 1), set.authority().?.generation);
            var actual: [64]u8 = undefined;
            try member.read(.data, 0, &actual);
            try std.testing.expect(std.mem.allEqual(u8, &actual, 0x5a));
            try std.testing.expectError(
                error.DataGenerationLeaseRequired,
                member.asReplicaEndpoint().writeData(0, "stale"),
            );
        } else {
            const expected_error: anyerror = switch (case) {
                .data_write_failure, .data_sync_failure => error.DataStagingFailed,
                .catalog_staging_failure => error.CatalogStagingFailed,
                .unknown_commit_before, .unknown_commit_after => error.CommitOutcomeUnknown,
                .success => unreachable,
            };
            try std.testing.expectError(expected_error, coordinator.commitCatalogGeneration(request));
            try std.testing.expectEqual(@as(u64, 0), set.authority().?.generation);
            try std.testing.expect(coordinator.isFrozen());
            try std.testing.expectEqual(pool_policy.DataAccess.unavailable, set.dataAccess());
            try std.testing.expectError(
                error.DataGenerationLeaseRequired,
                member.asReplicaEndpoint().writeData(0, "stale"),
            );
            var root_a: [pool_catalog.root_encoded_size]u8 = undefined;
            var root_b: [pool_catalog.root_encoded_size]u8 = undefined;
            try member.read(.metadata, 0, &root_a);
            try member.read(.metadata, pool_catalog.page_size, &root_b);
            if (case == .data_write_failure or case == .data_sync_failure or case == .catalog_staging_failure) {
                try std.testing.expect(std.mem.allEqual(u8, &root_a, 0));
                try std.testing.expect(std.mem.allEqual(u8, &root_b, 0));
            } else {
                try std.testing.expect(!std.mem.allEqual(u8, &root_a, 0));
            }
            coordinator.close();
            try std.testing.expectError(error.WriteFrozen, set.close());
            var reopened = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .read_only);
            defer reopened.deinit();
            const expected_generation: u64 = if (case == .unknown_commit_after) 1 else 0;
            try std.testing.expectEqual(expected_generation, reopened.authority().?.generation);
        }
    }
}

test "replicated data staging writes and syncs every placement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var set = try createThreeVoterTestSet(tmp.dir);
    defer set.deinit();
    var coordinator = try open(std.testing.io, &set);
    defer coordinator.deinit();
    const authority = set.authority().?;
    var slots: [3]u16 = .{
        authority.topology.members[0].slot,
        authority.topology.members[1].slot,
        authority.topology.members[2].slot,
    };
    if (slots[0] > slots[1]) std.mem.swap(u16, &slots[0], &slots[1]);
    if (slots[1] > slots[2]) std.mem.swap(u16, &slots[1], &slots[2]);
    if (slots[0] > slots[1]) std.mem.swap(u16, &slots[0], &slots[1]);

    var catalog: pool_catalog_graph.ValidatedCatalog = .{ .root = .{
        .set_id = authority.topology.set_id,
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .allocator_root = .{ .offset = 2 * pool_catalog.page_size, .digest = @splat(1) },
        .metadata_allocator_root = .{ .offset = 3 * pool_catalog.page_size, .digest = @splat(2) },
        .volume_count = 1,
        .extent_size = authority.layout.chunk_size,
    } };
    catalog.descriptors[0].volume_id = id(9);
    catalog.extent_counts[0] = 1;
    catalog.extent_runs[0][0] = .{
        .logical_start = 0,
        .physical_start = 0,
        .extent_count = 1,
        .state = .mapped,
        .member_count = 3,
        .member_slots = slots,
    };
    const contents = try std.testing.allocator.alloc(u8, authority.layout.chunk_size);
    defer std.testing.allocator.free(contents);
    @memset(contents, 0x6b);
    const initialization: pool_catalog_graph.DataInitialization = .{
        .volume_id = id(9),
        .logical_start = 0,
        .extent_count = 1,
        .contents = .{ .bytes = contents },
    };
    var faults: [three_voter_names.len]member_api.FaultController = @splat(.{});
    for (&faults, 0..) |*fault, set_index|
        ((try set.memberAt(set_index)) orelse return error.MemberUnavailable).setFaultController(fault);
    var claims: [pool_member_set.max_member_count]?member_api.DataClaim = @splat(null);
    defer for (&claims) |*maybe_claim| {
        if (maybe_claim.*) |*claim| claim.release() catch unreachable;
    };
    try coordinator.claimDataMembers(null, &catalog, &claims);
    for (&claims) |*maybe_claim| if (maybe_claim.*) |*claim| try claim.activateCatalogData();
    try coordinator.stageDataInitializations(&catalog, &.{initialization}, &claims);
    for (0..set.suppliedCount()) |set_index| {
        const member = (try set.memberAt(set_index)) orelse return error.MemberUnavailable;
        var actual: [64]u8 = undefined;
        try member.read(.data, 0, &actual);
        try std.testing.expect(std.mem.allEqual(u8, &actual, 0x6b));
        try std.testing.expectError(error.DataGenerationLeaseRequired, member.write(.data, 0, "stale"));
        try std.testing.expectEqual(@as(u64, 18), faults[set_index].write_count);
        try std.testing.expectEqual(@as(u64, 3), faults[set_index].sync_count);
    }
}

test "catalog reopen excludes a voter with corrupt leaf pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var set = try createThreeVoterTestSet(tmp.dir);
    defer set.deinit();
    var coordinator = try open(std.testing.io, &set);
    _ = try commitTestGenesisCatalog(&coordinator, &set);
    coordinator.close();

    const corrupt_index = 2;
    const member = (try set.memberAt(corrupt_index)) orelse return error.MemberUnavailable;
    var page: [pool_catalog.page_size]u8 = undefined;
    try member.read(.metadata, 2 * pool_catalog.page_size, &page);
    page[0] ^= 1;
    var claim = try member.claimCatalog();
    try claim.writeBatchDurable(&.{.{ .offset = 2 * pool_catalog.page_size, .bytes = &page }});
    try claim.release();
    try set.close();

    const locations = threeVoterTestLocations(tmp.dir);
    var reopened = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u16, 2), reopened.controlWriteReady().?.active_count);
    switch (try reopened.statusAt(corrupt_index)) {
        .catalog_failed => |reason| try std.testing.expectEqual(error.PageDigestMismatch, reason),
        else => return error.ExpectedCatalogFailure,
    }
    var voters: [pool_member_set.max_member_count]pool_member_set.CatalogVoter = undefined;
    try std.testing.expectError(error.CatalogVoterUnavailable, reopened.collectCatalogVoters(&voters));
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
        .control = .{ .offset = 64 * 1024, .length = 8 * control_record.encoded_size },
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
    const physical_bytes = try pool_catalog_page.encodePhysicalIntervals(.physical_allocator, 1, &.{.{
        .member_slot = 7,
        .physical_start = 0,
        .extent_count = 1,
    }});
    const metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(1, &.{.{
        .page_start = 4,
        .page_count = 60,
    }});
    const physical_reference = try pool_catalog_page.pageReference(2 * pool_catalog.page_size, &physical_bytes);
    const metadata_reference = try pool_catalog_page.pageReference(3 * pool_catalog.page_size, &metadata_bytes);
    const catalog_root: pool_catalog.Root = .{
        .set_id = authority.topology.set_id,
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .allocator_root = physical_reference,
        .metadata_allocator_root = metadata_reference,
        .extent_size = authority.layout.chunk_size,
    };
    const catalog_root_bytes = try pool_catalog.encodeRoot(catalog_root);
    const catalog_images = [_]pool_catalog_graph.PageImage{
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = metadata_reference.offset, .bytes = &metadata_bytes },
    };
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
        .data_root_digest = try pool_catalog.rootDigest(catalog_root),
        .topology_digest = try pool_topology.digest(authority.topology),
        .layout_digest = try pool_layout.digest(authority.layout),
        .payload = try control_record.Payload.init("generation"),
    };
    proposal.history_digest = try control_record.historyDigest(proposal);
    const result = try coordinator.commitCatalogGeneration(.{
        .prepare_proposal = proposal,
        .previous_graph = null,
        .current_graph = .{ .root_bytes = &catalog_root_bytes, .pages = &catalog_images },
    });
    try std.testing.expectEqual(@as(u16, 1), result.generation.committed_count);
    try std.testing.expectEqual(@as(u64, 1), result.generation.record.generation);
    try std.testing.expect(result.staged_members[0]);
    try std.testing.expect(result.repaired_members[0]);
    try std.testing.expect(result.generation.prepare_witness_members[0]);
    try std.testing.expectEqual(@as(u64, 1), set.authority().?.generation);
    const checkpoint_authority = set.authority().?;
    const snapshot: pool_authority_checkpoint.Snapshot = .{
        .previous_authority_history_digest = checkpoint_authority.history_digest,
        .data_root_digest = checkpoint_authority.data_root_digest,
        .writer_term = checkpoint_authority.writer_term,
        .generation = checkpoint_authority.generation,
        .topology = checkpoint_authority.topology,
        .layout = checkpoint_authority.layout,
        .administrative_recovery = checkpoint_authority.administrative_recovery,
    };
    var checkpoint_proposal: control_record.Record = .{
        .kind = control_record.checkpoint_kind,
        .local_sequence = 99,
        .membership_epoch = checkpoint_authority.membership_epoch,
        .writer_term = checkpoint_authority.writer_term,
        .generation = checkpoint_authority.generation,
        .set_id = checkpoint_authority.topology.set_id,
        .member_id = id(8),
        .mount_session_id = id(3),
        .transaction_id = id(11),
        .previous_record_digest = @splat(0x11),
        .previous_history_digest = checkpoint_authority.history_digest,
        .data_root_digest = checkpoint_authority.data_root_digest,
        .topology_digest = try pool_topology.digest(checkpoint_authority.topology),
        .layout_digest = try pool_layout.digest(checkpoint_authority.layout),
        .payload = try pool_authority_checkpoint.makePayload(snapshot),
    };
    checkpoint_proposal.history_digest = try control_record.historyDigest(checkpoint_proposal);
    const checkpoint_result = try coordinator.commitAuthorityCheckpoint(checkpoint_proposal);
    try std.testing.expectEqual(@as(u16, 1), checkpoint_result.committed_count);
    try std.testing.expectEqual(pool_authority.Kind.checkpoint, set.authority().?.kind);
    try std.testing.expect(!coordinator.reclaim_required);
    _ = try coordinator.rolloverAuthorityCheckpoint(
        try checkpointProposalForAuthority(set.authority().?, id(13)),
    );
    coordinator.close();
    try set.close();

    var reopened = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .writable);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 1), reopened.authority().?.generation);
    try std.testing.expectEqual(pool_authority.Kind.checkpoint, reopened.authority().?.kind);
    var membership_coordinator = try open(std.testing.io, &reopened);
    defer membership_coordinator.deinit();
    _ = try membership_coordinator.resumeRollover();
    _ = try membership_coordinator.rolloverAuthorityCheckpoint(
        try checkpointProposalForAuthority(reopened.authority().?, id(12)),
    );
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
        .control = .{ .offset = 64 * 1024, .length = 8 * control_record.encoded_size },
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

    try std.testing.expectError(
        error.CatalogCatchupRequired,
        membership_coordinator.commitMembership(promotion_prepare),
    );
    try membership_coordinator.installCatalogForMember(id(5));
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
        .writable,
    );
    defer recovered.deinit();
    try std.testing.expectEqual(pool_authority.Kind.membership_commit, recovered.authority().?.kind);
    try std.testing.expectEqual(@as(u16, 2), recovered.authority().?.topology.member_count);
    try std.testing.expectEqual(pool_topology.MemberState.active, recovered.authority().?.topology.members[1].state);
    try std.testing.expect(recovered.controlWriteReady().?.reclaim_required);
    var resumed = try open(std.testing.io, &recovered);
    defer resumed.deinit();
    try std.testing.expectEqual(@as(u16, 2), (try resumed.resumeRollover()).active_count);
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
    var normal = try open(std.testing.io, &recovered);
    _ = try normal.rolloverAuthorityCheckpoint(try checkpointProposalForAuthority(recovered.authority().?, id(12)));
    normal.close();
    try recovered.close();

    var anchored_recovery = try pool_member_set.openAdministrativeRecovery(
        std.testing.io,
        std.testing.allocator,
        survivor_location,
        id(2),
    );
    defer anchored_recovery.deinit();
    try std.testing.expect(anchored_recovery.controlWriteReady().?.reclaim_required);
    var anchored_coordinator = try open(std.testing.io, &anchored_recovery);
    defer anchored_coordinator.deinit();
    try std.testing.expectEqual(@as(u16, 1), (try anchored_coordinator.resumeRollover()).active_count);
}
