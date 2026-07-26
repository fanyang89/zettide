const std = @import("std");
const control_record = @import("control_record.zig");
const journal_api = @import("journal.zig");
const member_set_api = @import("member_set.zig");
const topology_format = @import("topology.zig");

pub const CommitResult = struct {
    record: control_record.Record,
    committed_slots: u8,
    stale_slots: u8,
    degraded: bool,
};

pub const ReplicatedJournal = struct {
    set: *member_set_api.MemberSet,
    io: std.Io,
    journals: [topology_format.member_count]?journal_api.Journal = .{ null, null, null },
    active_slots: u8,
    mutex: std.Io.Mutex = .init,
    frozen: std.atomic.Value(bool) = .init(false),
    closed: bool = false,

    pub fn open(set: *member_set_api.MemberSet) !ReplicatedJournal {
        const ready = set.controlWriteReady() orelse return error.ControlWriteNotReady;
        try set.claimCoordinator();
        var claim_owned = true;
        errdefer if (claim_owned) set.releaseCoordinator();
        const first_member = try set.memberAt(@intCast(firstSlot(ready.active_slots)));
        var coordinator: ReplicatedJournal = .{
            .set = set,
            .io = first_member.io,
            .active_slots = ready.active_slots,
        };
        errdefer coordinator.deinit();
        claim_owned = false;
        for (0..topology_format.member_count) |slot| {
            if (ready.active_slots & slotBit(slot) == 0) continue;
            coordinator.journals[slot] = try journal_api.Journal.open(try set.memberAt(@intCast(slot)));
            const token = try coordinator.journals[slot].?.tailToken();
            if (!std.mem.eql(u8, &token.history_digest, &ready.tail_history_digest))
                return error.ControlTailChanged;
        }
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
        if (@popCount(self.active_slots) < topology_format.control_write_quorum)
            return error.WriteQuorumUnavailable;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        if (prepare_proposal.membership_epoch != authority.membership_epoch)
            return error.MembershipEpochMismatch;
        if (prepare_proposal.generation != std.math.add(u64, authority.generation, 1) catch
            return error.GenerationOverflow) return error.UnexpectedGeneration;
        if (!std.mem.eql(u8, &prepare_proposal.topology_digest, &authority.topology_digest))
            return error.TopologyDigestMismatch;
        if (!std.mem.eql(u8, &prepare_proposal.layout_digest, &authority.layout_digest))
            return error.LayoutDigestMismatch;

        const original_active_slots = self.active_slots;
        var target_slots: u8 = 0;
        for (0..topology_format.member_count) |slot| {
            if (self.active_slots & slotBit(slot) == 0) continue;
            const state = try self.journals[slot].?.state();
            if (state.physical_frontier + 2 <= state.slot_count) target_slots |= slotBit(slot);
        }
        if (@popCount(target_slots) < topology_format.control_write_quorum)
            return error.InsufficientJournalCapacity;
        var prepared: [topology_format.member_count]?journal_api.PreparedAppend = .{ null, null, null };
        var shared_prepare_history: ?[32]u8 = null;
        for (0..topology_format.member_count) |slot| {
            if (target_slots & slotBit(slot) == 0) continue;
            const journal = &(self.journals[slot].?);
            const token = try journal.tailToken();
            prepared[slot] = try journal.prepareExact(token, prepare_proposal);
            const history_digest = prepared[slot].?.record.history_digest;
            if (shared_prepare_history) |expected| {
                if (!std.mem.eql(u8, &expected, &history_digest)) return error.PrepareHistoryDiverged;
            } else {
                shared_prepare_history = history_digest;
            }
        }

        for (0..topology_format.member_count) |slot| {
            if (original_active_slots & slotBit(slot) != 0 and target_slots & slotBit(slot) == 0)
                self.set.noteControlStale(slot);
        }
        self.active_slots = target_slots;
        self.set.beginControlMutation();
        var prepare_results: [topology_format.member_count]?journal_api.AppendResult = .{ null, null, null };
        var prepare_successes: u8 = 0;
        for (0..topology_format.member_count) |slot| {
            const item = if (prepared[slot]) |*value| value else continue;
            prepare_results[slot] = self.journals[slot].?.appendPrepared(item) catch {
                self.active_slots &= ~slotBit(slot);
                self.set.noteControlFailure(slot);
                continue;
            };
            prepare_successes |= slotBit(slot);
        }
        if (@popCount(prepare_successes) < topology_format.control_write_quorum) {
            self.frozen.store(true, .release);
            return error.PrepareQuorumFailed;
        }

        const certificate = makeCertificate(prepare_results, prepare_successes);
        var commit_proposal = prepare_results[firstSlot(prepare_successes)].?.record;
        commit_proposal.kind = control_record.generation_commit_kind;
        commit_proposal.payload = try control_record.Payload.init(
            &(try control_record.encodeCertificate(certificate)),
        );

        var commit_prepared: [topology_format.member_count]?journal_api.PreparedAppend = .{ null, null, null };
        var shared_commit_history: ?[32]u8 = null;
        for (0..topology_format.member_count) |slot| {
            if (prepare_successes & slotBit(slot) == 0) continue;
            const journal = &(self.journals[slot].?);
            commit_prepared[slot] = journal.prepareExact(try journal.tailToken(), commit_proposal) catch {
                self.frozen.store(true, .release);
                return error.CommitPreparationFailed;
            };
            const history_digest = commit_prepared[slot].?.record.history_digest;
            if (shared_commit_history) |expected| {
                if (!std.mem.eql(u8, &expected, &history_digest)) {
                    self.frozen.store(true, .release);
                    return error.CommitHistoryDiverged;
                }
            } else {
                shared_commit_history = history_digest;
            }
        }

        var commit_results: [topology_format.member_count]?journal_api.AppendResult = .{ null, null, null };
        var commit_successes: u8 = 0;
        for (0..topology_format.member_count) |slot| {
            const item = if (commit_prepared[slot]) |*value| value else continue;
            commit_results[slot] = self.journals[slot].?.appendPrepared(item) catch {
                self.set.noteControlFailure(slot);
                continue;
            };
            commit_successes |= slotBit(slot);
        }
        if (@popCount(commit_successes) < topology_format.control_write_quorum) {
            self.frozen.store(true, .release);
            return error.CommitOutcomeUnknown;
        }

        self.active_slots = commit_successes;
        const committed = commit_results[firstSlot(commit_successes)].?.record;
        self.set.noteCommittedControl(committed, commit_successes);
        return .{
            .record = committed,
            .committed_slots = commit_successes,
            .stale_slots = original_active_slots & ~commit_successes,
            .degraded = @popCount(commit_successes) < topology_format.member_count,
        };
    }

    pub fn isFrozen(self: *const ReplicatedJournal) bool {
        return self.frozen.load(.acquire);
    }

    pub fn close(self: *ReplicatedJournal) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        for (&self.journals) |*maybe_journal| {
            if (maybe_journal.*) |*journal| journal.close();
            maybe_journal.* = null;
        }
        self.closed = true;
        self.set.releaseCoordinator();
    }

    pub fn deinit(self: *ReplicatedJournal) void {
        self.close();
    }
};

fn makeCertificate(
    results: [topology_format.member_count]?journal_api.AppendResult,
    successful_slots: u8,
) control_record.CommitCertificate {
    var attestations: [2]control_record.Attestation = undefined;
    var count: usize = 0;
    for (0..topology_format.member_count) |slot| {
        if (successful_slots & slotBit(slot) == 0) continue;
        const result = results[slot].?;
        attestations[count] = .{
            .member_id = result.record.member_id,
            .prepare_record_digest = result.record_digest,
            .prepare_history_digest = result.record.history_digest,
        };
        count += 1;
        if (count == attestations.len) break;
    }
    return .{ .attestations = attestations };
}

fn slotBit(slot: usize) u8 {
    return @as(u8, 1) << @intCast(slot);
}

fn firstSlot(mask: u8) usize {
    for (0..topology_format.member_count) |slot| {
        if (mask & slotBit(slot) != 0) return slot;
    }
    unreachable;
}

const genesis_payload_format = @import("genesis_payload.zig");
const member_api = @import("member.zig");
const member_format = @import("member_format.zig");

fn testPayload() genesis_payload_format.GenesisPayload {
    return .{
        .topology = .{
            .set_id = @splat(0x10),
            .epoch = 1,
            .parent_digest = @splat(0),
            .members = .{
                .{ .member_id = @splat(0x20), .slot = 0 },
                .{ .member_id = @splat(0x30), .slot = 1 },
                .{ .member_id = @splat(0x40), .slot = 2 },
            },
        },
        .layout = .{ .layout_epoch = 1, .topology_epoch = 1, .chunk_size = 1024 * 1024 },
    };
}

fn testHeaders(payload: genesis_payload_format.GenesisPayload) ![3]member_format.Header {
    var headers: [3]member_format.Header = undefined;
    for (&headers, 0..) |*header, slot| {
        header.* = .{
            .header_sequence = 1,
            .set_id = payload.topology.set_id,
            .member_id = payload.topology.members[slot].member_id,
            .member_slot = @intCast(slot),
            .created_ns = 1,
            .member_bytes = 3 * 1024 * 1024,
            .logical_capacity = 1024 * 1024,
            .control = .{ .offset = 64 * 1024, .length = 4 * 4096 },
            .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
            .data = .{ .offset = 2 * 1024 * 1024, .length = 1024 * 1024 },
            .metadata_block_size = 4096,
            .metadata_read_size = 512,
            .metadata_program_size = 512,
            .chunk_size = 1024 * 1024,
            .metadata_format_version = 1,
            .object_format_version = 1,
            .layout_format_version = 1,
            .control_record_format_version = 1,
            .label = try member_format.Label.init("replicated-journal-test"),
            .genesis_topology_digest = try topology_format.digest(payload.topology),
        };
    }
    return headers;
}

fn testLocations(dir: std.Io.Dir) [3]member_set_api.Location {
    return .{
        .{ .parent = dir, .basename = "member0" },
        .{ .parent = dir, .basename = "member1" },
        .{ .parent = dir, .basename = "member2" },
    };
}

fn testProposal(payload: genesis_payload_format.GenesisPayload) !control_record.Record {
    var proposal = try genesis_payload_format.makeRecord(payload.topology.members[0].member_id, payload);
    proposal.kind = control_record.generation_prepare_kind;
    proposal.writer_term = 1;
    proposal.generation = 1;
    proposal.mount_session_id = @splat(0x50);
    proposal.transaction_id = @splat(0x60);
    proposal.data_root_digest = @splat(0x70);
    proposal.payload = try control_record.Payload.init("replicated generation");
    return proposal;
}

test "generation commits on all members and survives authority reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const locations = testLocations(tmp.dir);
    var set = try member_set_api.create(
        std.testing.io,
        locations,
        try testHeaders(payload),
        payload,
        .{},
    );
    var coordinator = try ReplicatedJournal.open(&set);
    try std.testing.expectError(error.CoordinatorActive, set.close());
    const result = try coordinator.commitGeneration(try testProposal(payload));
    try std.testing.expectEqual(@as(u8, 0b111), result.committed_slots);
    try std.testing.expect(!result.degraded);
    try std.testing.expectEqual(control_record.generation_commit_kind, result.record.kind);
    try std.testing.expectEqualSlices(u8, &result.record.history_digest, &set.authority().?.history_digest);
    coordinator.close();
    try std.testing.expectError(
        error.CoordinatorClosed,
        coordinator.commitGeneration(try testProposal(payload)),
    );
    try set.close();

    const optional_locations: [3]?member_set_api.Location = .{ locations[0], locations[1], locations[2] };
    var reopened = try member_set_api.open(
        std.testing.io,
        std.testing.allocator,
        optional_locations,
        .writable,
    );
    defer reopened.deinit();
    try std.testing.expectEqual(member_set_api.AuthorityKind.generation_commit, reopened.authority().?.kind);
    try std.testing.expectEqual(@as(u8, 0b111), reopened.controlWriteReady().?.active_slots);
}

test "one prepare failure commits degraded on the remaining quorum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    var set = try member_set_api.create(
        std.testing.io,
        testLocations(tmp.dir),
        try testHeaders(payload),
        payload,
        .{},
    );
    defer set.deinit();
    var fault: member_api.FaultController = .{ .fail_write_at = 0 };
    (try set.memberAt(2)).setFaultController(&fault);
    var coordinator = try ReplicatedJournal.open(&set);
    defer coordinator.deinit();
    const result = try coordinator.commitGeneration(try testProposal(payload));
    try std.testing.expectEqual(@as(u8, 0b011), result.committed_slots);
    try std.testing.expect(result.degraded);
    try std.testing.expect((try set.memberAt(2)).isFrozen());
}

test "prepare quorum failure and unknown commit outcome freeze the coordinator" {
    inline for (.{ "prepare", "commit" }) |phase| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const payload = testPayload();
        var set = try member_set_api.create(
            std.testing.io,
            testLocations(tmp.dir),
            try testHeaders(payload),
            payload,
            .{},
        );
        defer set.deinit();
        var fault1: member_api.FaultController = .{};
        var fault2: member_api.FaultController = .{};
        if (std.mem.eql(u8, phase, "prepare")) {
            fault1.fail_write_at = 0;
            fault2.fail_write_at = 0;
        } else {
            fault1.fail_write_at = 1;
            fault2.fail_write_at = 1;
        }
        (try set.memberAt(1)).setFaultController(&fault1);
        (try set.memberAt(2)).setFaultController(&fault2);
        var coordinator = try ReplicatedJournal.open(&set);
        defer coordinator.deinit();
        const expected = if (std.mem.eql(u8, phase, "prepare"))
            error.PrepareQuorumFailed
        else
            error.CommitOutcomeUnknown;
        try std.testing.expectError(expected, coordinator.commitGeneration(try testProposal(payload)));
        try std.testing.expect(coordinator.isFrozen());
        try std.testing.expect(set.controlWriteReady() == null);
        try std.testing.expectError(
            error.CoordinatorFrozen,
            coordinator.commitGeneration(try testProposal(payload)),
        );
    }
}
