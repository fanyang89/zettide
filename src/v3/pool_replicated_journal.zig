const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const journal_api = @import("journal.zig");
const pool_certificate = @import("pool_certificate.zig");
const pool_member_set = @import("pool_member_set.zig");

const max_voter_count: usize = 3;

pub const CommitResult = struct {
    record: control_record.Record,
    committed_members: [pool_member_set.max_member_count]bool,
    committed_count: u16,
    degraded: bool,
};

const Participant = struct {
    set_index: usize,
    journal: journal_api.Journal,
};

pub const ReplicatedJournal = struct {
    io: std.Io,
    set: *pool_member_set.PoolMemberSet,
    participants: [max_voter_count]?Participant = @splat(null),
    participant_count: usize = 0,
    quorum: u16,
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
        };
        errdefer coordinator.closeParticipants();
        for (ready.active_members[0..set.supplied_count], 0..) |active, set_index| {
            if (!active) continue;
            if (coordinator.participant_count == max_voter_count) return error.TooManyControlVoters;
            coordinator.participants[coordinator.participant_count] = .{
                .set_index = set_index,
                .journal = try journal_api.Journal.open(&(set.members[set_index].?)),
            };
            coordinator.participant_count += 1;
        }
        if (coordinator.participant_count < coordinator.quorum) return error.WriteQuorumUnavailable;
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

        var targets: [max_voter_count]bool = @splat(false);
        var target_count: u16 = 0;
        for (0..self.participant_count) |index| {
            const participant = &(self.participants[index].?);
            const state = try participant.journal.state();
            if (state.physical_frontier + 2 > state.slot_count) continue;
            targets[index] = true;
            target_count += 1;
        }
        if (target_count < self.quorum) return error.InsufficientJournalCapacity;

        var prepared: [max_voter_count]?journal_api.PreparedAppend = @splat(null);
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
        var prepare_results: [max_voter_count]?journal_api.AppendResult = @splat(null);
        var prepare_successes: [max_voter_count]bool = @splat(false);
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
        var commit_prepared: [max_voter_count]?journal_api.PreparedAppend = @splat(null);
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

        var commit_results: [max_voter_count]?journal_api.AppendResult = @splat(null);
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
            .degraded = commit_count < authority.topology.quorum or commit_count < self.participant_count,
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
};

fn makeCertificate(
    results: [max_voter_count]?journal_api.AppendResult,
    successes: [max_voter_count]bool,
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
    results: [max_voter_count]?journal_api.AppendResult,
    successes: [max_voter_count]bool,
) journal_api.AppendResult {
    for (successes, 0..) |success, index| if (success) return results[index].?;
    unreachable;
}

fn firstCommitted(results: [max_voter_count]?journal_api.AppendResult) journal_api.AppendResult {
    for (results) |result| if (result) |value| return value;
    unreachable;
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

test "one-member coordinator commits with one prepare attestation" {
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

    var reopened = try pool_member_set.open(std.testing.io, std.testing.allocator, &locations, .read_only);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 1), reopened.authority().?.generation);
}
