const std = @import("std");
const control_record = @import("control_record.zig");
const journal = @import("journal.zig");
const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const pool_authority = @import("pool_authority.zig");
const pool_authority_checkpoint = @import("pool_authority_checkpoint.zig");
const pool_catalog_graph = @import("pool_catalog_graph.zig");
const pool_catalog_store = @import("pool_catalog_store.zig");
const pool_layout = @import("pool_layout.zig");
const pool_policy = @import("pool_policy.zig");
const pool_topology = @import("pool_topology.zig");
const storage_api = @import("storage.zig");

pub const max_member_count = pool_topology.max_member_count;

pub const Location = struct {
    parent: std.Io.Dir,
    basename: []const u8,
};

pub const OpenIntent = enum { diagnostic, read_only, writable };

pub const MemberStatus = union(enum) {
    absent,
    open_failed: anyerror,
    scan_failed: anyerror,
    legacy,
    removed,
    stale,
    catalog_failed: anyerror,
    authority,
    active_voter,
};

pub const ControlWriteReady = struct {
    tail_history_digest: [32]u8,
    active_members: [max_member_count]bool,
    active_count: u16,
    reclaim_required: bool = false,
};

pub const CatalogVoter = struct {
    set_index: usize,
    member: *member_api.Member,
};

pub const DataMember = struct {
    set_index: usize,
    member: *member_api.Member,
};

pub const PoolMemberSet = struct {
    members: [max_member_count]?member_api.Member = @splat(null),
    histories: [max_member_count]?journal.HistoryScan = @splat(null),
    statuses: [max_member_count]MemberStatus = @splat(.absent),
    supplied_count: usize = 0,
    authority_state: ?pool_authority.Authority = null,
    control_write_state: ?ControlWriteReady = null,
    data_access_state: pool_policy.DataAccess = .unavailable,
    coordinator_state: std.atomic.Value(u8) = .init(0),
    recovery_only: bool = false,

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        locations: []const Location,
        intent: OpenIntent,
    ) !PoolMemberSet {
        var set = try scanLocations(io, allocator, locations, if (intent == .writable) .writable else .read_only);
        return finishOpen(&set, intent);
    }

    pub fn openStorages(
        io: std.Io,
        allocator: std.mem.Allocator,
        storages: []member_api.Storage,
        intent: OpenIntent,
    ) !PoolMemberSet {
        var set = try scanStorages(io, allocator, storages, if (intent == .writable) .writable else .read_only);
        return finishOpen(&set, intent);
    }

    pub fn openStoragesInto(
        result: *PoolMemberSet,
        io: std.Io,
        allocator: std.mem.Allocator,
        storages: []member_api.Storage,
        intent: OpenIntent,
    ) !void {
        try scanStoragesInto(result, io, allocator, storages, if (intent == .writable) .writable else .read_only);
        return finishOpenInPlace(result, intent);
    }

    fn finishOpen(set: *PoolMemberSet, intent: OpenIntent) !PoolMemberSet {
        try finishOpenInPlace(set, intent);
        return set.*;
    }

    fn finishOpenInPlace(set: *PoolMemberSet, intent: OpenIntent) !void {
        errdefer set.deinit();

        var history_pointers: [max_member_count]*const journal.HistoryScan = undefined;
        var history_count: usize = 0;
        for (set.histories[0..set.supplied_count]) |*maybe_history| {
            if (maybe_history.*) |*history| {
                history_pointers[history_count] = history;
                history_count += 1;
            }
        }
        if (history_count == 0) return error.NoReadableMember;
        const selected_authority = try pool_authority.select(history_pointers[0..history_count]);
        try set.validateAuthorityGeometry(selected_authority);
        set.authority_state = selected_authority;
        set.classifyMembers(intent);
        try set.reopenCatalog(intent);
        if (intent == .writable and set.control_write_state == null)
            return error.WriteQuorumUnavailable;
    }

    pub fn openAdministrativeRecovery(
        io: std.Io,
        allocator: std.mem.Allocator,
        location: Location,
        trusted_member_id: [16]u8,
    ) !PoolMemberSet {
        var set = try scanLocations(io, allocator, &.{location}, .writable);
        errdefer set.deinit();
        const member = if (set.members[0]) |*value| value else return error.TrustedMemberUnavailable;
        if (!std.mem.eql(u8, &member.header().member_id, &trusted_member_id))
            return error.TrustedMemberMismatch;
        const history = if (set.histories[0]) |*value| value else return error.TrustedMemberUnavailable;
        if (history.scan_result.unresolved_tail_damage and !history.scan_result.anchored)
            return error.JournalNeedsRecovery;
        const tail = history.scan_result.tail;
        const resumable_full_checkpoint = history.scan_result.journal_full and tail != null and
            pool_authority_checkpoint.isSnapshotRecord(tail.?) and
            (pool_authority_checkpoint.validateCompactedRootRecord(tail.?) catch null) != null;
        if (!history.scan_result.anchored and !resumable_full_checkpoint and
            journal.availableSlotCount(history.scan_result) < 3)
            return error.InsufficientJournalCapacity;
        var selected_authority = try pool_authority.selectAdministrativeRecovery(history);
        selected_authority.administrative_recovery = true;
        set.authority_state = selected_authority;
        set.classifyMembers(.read_only);
        set.control_write_state = .{
            .tail_history_digest = selected_authority.history_digest,
            .active_members = @splat(false),
            .active_count = 1,
            .reclaim_required = history.scan_result.anchored or resumable_full_checkpoint,
        };
        set.control_write_state.?.active_members[0] = true;
        set.statuses[0] = .active_voter;
        if (selected_authority.generation != 0) {
            member.fenceUnleasedCatalogWrites();
            set.data_access_state = .unavailable;
        }
        set.recovery_only = true;
        return set;
    }

    pub fn authority(self: *const PoolMemberSet) ?pool_authority.Authority {
        return self.authority_state;
    }

    pub fn controlWriteReady(self: *const PoolMemberSet) ?ControlWriteReady {
        return self.control_write_state;
    }

    pub fn dataAccess(self: *const PoolMemberSet) pool_policy.DataAccess {
        return self.data_access_state;
    }

    pub fn isRecoveryOnly(self: *const PoolMemberSet) bool {
        return self.recovery_only;
    }

    pub fn statusAt(self: *const PoolMemberSet, index: usize) !MemberStatus {
        if (index >= self.supplied_count) return error.InvalidMemberIndex;
        return self.statuses[index];
    }

    pub fn suppliedCount(self: *const PoolMemberSet) usize {
        return self.supplied_count;
    }

    pub fn memberAt(self: *PoolMemberSet, index: usize) !?*member_api.Member {
        if (index >= self.supplied_count) return error.InvalidMemberIndex;
        return if (self.members[index]) |*member| member else null;
    }

    pub fn take(self: *PoolMemberSet) PoolMemberSet {
        const result = self.*;
        self.* = .{};
        return result;
    }

    pub fn isClosed(self: *const PoolMemberSet) bool {
        return self.coordinator_state.load(.acquire) == 2;
    }

    pub fn memberById(self: *PoolMemberSet, member_id: [16]u8) !*member_api.Member {
        for (self.members[0..self.supplied_count]) |*maybe_member| {
            const member = if (maybe_member.*) |*value| value else continue;
            if (std.mem.eql(u8, &member.header().member_id, &member_id)) return member;
        }
        return error.MemberUnavailable;
    }

    pub fn collectCatalogVoters(
        self: *PoolMemberSet,
        output: []CatalogVoter,
    ) ![]CatalogVoter {
        const selected = self.authority_state orelse return error.MissingAuthority;
        const ready = self.control_write_state orelse return error.WriteQuorumUnavailable;
        var count: usize = 0;
        for (selected.topology.memberSlice()) |descriptor| {
            if (descriptor.control_role != pool_topology.voter_role) continue;
            if (count == output.len) return error.OutputTooSmall;
            const set_index = self.findSuppliedMember(descriptor.member_id) orelse
                return error.CatalogVoterUnavailable;
            const member = if (self.members[set_index]) |*value| value else return error.CatalogVoterUnavailable;
            if (self.statuses[set_index] != .active_voter or !ready.active_members[set_index] or
                member.mode() != .writable or member.isFrozen() or member.isClosed())
                return error.CatalogVoterUnavailable;
            output[count] = .{ .set_index = set_index, .member = member };
            count += 1;
        }
        if (count == 0) return error.CatalogVoterUnavailable;
        return output[0..count];
    }

    pub fn collectCatalogGeometry(
        self: *PoolMemberSet,
        output: []pool_catalog_graph.MemberGeometry,
    ) ![]pool_catalog_graph.MemberGeometry {
        const selected = self.authority_state orelse return error.MissingAuthority;
        if (output.len < selected.topology.member_count) return error.OutputTooSmall;
        var count: usize = 0;
        for (selected.topology.memberSlice()) |descriptor| {
            const set_index = self.findSuppliedMember(descriptor.member_id) orelse {
                if (descriptor.state == .joining) continue;
                return error.MemberGeometryUnavailable;
            };
            const member = if (self.members[set_index]) |*value| value else return error.MemberGeometryUnavailable;
            const header = member.header();
            if (header.member_slot != descriptor.slot) return error.MemberGeometryIdentityMismatch;
            output[count] = .{
                .member_id = header.member_id,
                .slot = header.member_slot,
                .metadata_length = header.metadata.length,
                .data_length = header.data.length,
            };
            count += 1;
        }
        return output[0..count];
    }

    pub fn loadCatalog(self: *PoolMemberSet) !pool_catalog_graph.ValidatedCatalog {
        var scratch: pool_catalog_store.LoadScratch = .{};
        return self.loadCatalogInto(&scratch);
    }

    pub fn loadCatalogInto(
        self: *PoolMemberSet,
        scratch: *pool_catalog_store.LoadScratch,
    ) !pool_catalog_graph.ValidatedCatalog {
        const selected = self.authority_state orelse return error.MissingAuthority;
        if (selected.generation == 0) return error.GenesisHasNoCatalogRoot;
        if (self.data_access_state == .unavailable) return error.DataReadUnavailable;

        var geometry_buffer: [max_member_count]pool_catalog_graph.MemberGeometry = undefined;
        const geometry = try self.collectCatalogGeometry(&geometry_buffer);
        var first_error: ?anyerror = null;
        for (selected.topology.memberSlice()) |descriptor| {
            if (descriptor.control_role != pool_topology.voter_role) continue;
            const set_index = self.findSuppliedMember(descriptor.member_id) orelse continue;
            const member = if (self.members[set_index]) |*value| value else continue;
            switch (self.statuses[set_index]) {
                .authority, .active_voter => {},
                else => continue,
            }
            const loaded = pool_catalog_store.loadAuthorityCatalog(
                member,
                selected,
                geometry,
                scratch,
            ) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            return loaded.validated;
        }
        if (first_error) |err| return err;
        return error.CatalogReadQuorumUnavailable;
    }

    pub fn dataMemberForRead(self: *PoolMemberSet, slot: u16) !DataMember {
        const selected = self.authority_state orelse return error.MissingAuthority;
        if (self.data_access_state == .unavailable) return error.DataReadUnavailable;
        const descriptor = pool_topology.findSlot(&selected.topology, slot) orelse
            return error.DataMemberNotInTopology;
        if (descriptor.state == .joining) return error.DataMemberStillJoining;
        const set_index = self.findSuppliedMember(descriptor.member_id) orelse
            return error.DataMemberUnavailable;
        const member = if (self.members[set_index]) |*value| value else return error.DataMemberUnavailable;
        switch (self.statuses[set_index]) {
            .authority, .active_voter, .catalog_failed => {},
            else => return error.DataMemberUnavailable,
        }
        if (member.header().member_slot != slot) return error.MemberGeometryIdentityMismatch;
        if (member.isClosed()) return error.DataMemberUnavailable;
        return .{ .set_index = set_index, .member = member };
    }

    pub fn dataMemberForWrite(self: *PoolMemberSet, slot: u16) !DataMember {
        const selected = self.authority_state orelse return error.MissingAuthority;
        if (self.data_access_state != .read_write) return error.DataWriteUnavailable;
        const descriptor = pool_topology.findSlot(&selected.topology, slot) orelse
            return error.DataMemberNotInTopology;
        if (descriptor.state == .joining) return error.DataMemberStillJoining;
        const set_index = self.findSuppliedMember(descriptor.member_id) orelse
            return error.DataMemberUnavailable;
        const member = if (self.members[set_index]) |*value| value else return error.DataMemberUnavailable;
        switch (self.statuses[set_index]) {
            .authority, .active_voter, .catalog_failed => {},
            else => return error.DataMemberUnavailable,
        }
        if (member.header().member_slot != slot) return error.MemberGeometryIdentityMismatch;
        if (member.mode() != .writable or member.isFrozen() or member.isClosed())
            return error.DataMemberUnavailable;
        return .{ .set_index = set_index, .member = member };
    }

    pub fn revokeWriteReady(self: *PoolMemberSet) void {
        self.control_write_state = null;
    }

    pub fn revokeDataAccess(self: *PoolMemberSet) void {
        self.data_access_state = .unavailable;
    }

    pub fn claimCoordinator(self: *PoolMemberSet) !void {
        if (self.coordinator_state.cmpxchgStrong(0, 1, .acq_rel, .acquire)) |state|
            return if (state == 2 or state == 3) error.MemberSetClosed else error.CoordinatorAlreadyOpen;
    }

    fn findSuppliedMember(self: *const PoolMemberSet, member_id: [16]u8) ?usize {
        for (self.members[0..self.supplied_count], 0..) |maybe_member, index| {
            const member = if (maybe_member) |value| value else continue;
            if (std.mem.eql(u8, &member.header().member_id, &member_id)) return index;
        }
        return null;
    }

    pub fn releaseCoordinator(self: *PoolMemberSet) void {
        const previous = self.coordinator_state.swap(0, .acq_rel);
        std.debug.assert(previous == 1);
    }

    pub fn beginControlMutation(self: *PoolMemberSet) void {
        self.control_write_state = null;
        for (&self.histories) |*maybe_history| {
            if (maybe_history.*) |*history| history.deinit();
            maybe_history.* = null;
        }
    }

    pub fn noteControlFailure(self: *PoolMemberSet, index: usize) void {
        self.statuses[index] = .stale;
    }

    pub fn noteCatalogFailure(self: *PoolMemberSet, index: usize, reason: anyerror) void {
        self.invalidateCatalogVoter(index, reason);
    }

    pub fn noteCatalogInstalled(self: *PoolMemberSet, index: usize) void {
        if (self.members[index]) |*member| member.fenceUnleasedCatalogWrites();
        if (self.statuses[index] == .catalog_failed) self.statuses[index] = .authority;
    }

    pub fn noteControlCatchupFailure(self: *PoolMemberSet, index: usize) void {
        self.statuses[index] = .stale;
        self.recomputeDataAccess(self.authority_state.?.topology);
    }

    pub fn noteControlCaughtUp(
        self: *PoolMemberSet,
        index: usize,
        replacement: journal.HistoryScan,
    ) !void {
        if (index >= self.supplied_count) return error.InvalidMemberIndex;
        const member = if (self.members[index]) |*value| value else return error.MemberUnavailable;
        const tail = replacement.scan_result.tail orelse return error.MissingGenesis;
        if (!std.mem.eql(u8, &replacement.member_id, &member.header().member_id))
            return error.HistoryMemberMismatch;
        if (!std.mem.eql(u8, &tail.history_digest, &self.authority_state.?.history_digest) or
            replacement.scan_result.unresolved_tail_damage or
            journal.availableSlotCount(replacement.scan_result) < 3)
            return error.MemberNotCaughtUp;
        if (self.histories[index]) |*history| history.deinit();
        self.histories[index] = replacement;
        self.statuses[index] = .authority;
        self.recomputeDataAccess(self.authority_state.?.topology);
    }

    pub fn validateCatalogTargetGeometry(
        self: *PoolMemberSet,
        source_index: usize,
        target_index: usize,
    ) !void {
        const source = (try self.memberAt(source_index)) orelse return error.MemberUnavailable;
        const target = (try self.memberAt(target_index)) orelse return error.MemberUnavailable;
        if (!samePoolGeometry(source.header(), target.header())) return error.InconsistentMemberGeometry;
    }

    pub fn validateBootstrapTargetGeometry(
        self: *const PoolMemberSet,
        target: member_format.Header,
    ) !void {
        const ready = self.control_write_state orelse return error.WriteQuorumUnavailable;
        var found_source = false;
        for (ready.active_members[0..self.supplied_count], 0..) |active, index| {
            if (!active) continue;
            const member = if (self.members[index]) |*value| value else continue;
            found_source = true;
            if (!samePoolGeometry(member.header(), target)) return error.InconsistentMemberGeometry;
        }
        if (!found_source) return error.MemberUnavailable;
    }

    pub fn noteCommittedGeneration(
        self: *PoolMemberSet,
        record: control_record.Record,
        active_members: [max_member_count]bool,
        active_count: u16,
    ) void {
        const previous = self.authority_state.?;
        self.authority_state = .{
            .kind = .generation_commit,
            .history_digest = record.history_digest,
            .data_root_digest = record.data_root_digest,
            .topology = previous.topology,
            .layout = previous.layout,
            .membership_epoch = record.membership_epoch,
            .writer_term = record.writer_term,
            .generation = record.generation,
            .witness_count = active_count,
            .administrative_recovery = previous.administrative_recovery,
        };
        self.control_write_state = .{
            .tail_history_digest = record.history_digest,
            .active_members = active_members,
            .active_count = active_count,
            .reclaim_required = false,
        };
        self.updateVoterStatuses(previous.topology, active_members);
        self.recomputeDataAccess(previous.topology);
        self.fenceCatalogDataWrites();
    }

    pub fn noteCommittedMembership(
        self: *PoolMemberSet,
        record: control_record.Record,
        topology: pool_topology.Topology,
        committed_members: [max_member_count]bool,
        active_members: [max_member_count]bool,
        active_count: u16,
        administrative_recovery: bool,
    ) void {
        const previous = self.authority_state.?;
        self.authority_state = .{
            .kind = .membership_commit,
            .history_digest = record.history_digest,
            .data_root_digest = record.data_root_digest,
            .topology = topology,
            .layout = previous.layout,
            .membership_epoch = record.membership_epoch,
            .writer_term = record.writer_term,
            .generation = record.generation,
            .witness_count = active_count,
            .administrative_recovery = previous.administrative_recovery or administrative_recovery,
        };
        self.control_write_state = .{
            .tail_history_digest = record.history_digest,
            .active_members = active_members,
            .active_count = active_count,
            .reclaim_required = false,
        };
        for (0..self.supplied_count) |index| {
            const member = if (self.members[index]) |*value| value else continue;
            if (pool_topology.findMember(&topology, member.header().member_id) == null) {
                self.statuses[index] = .removed;
            } else if (active_members[index]) {
                self.statuses[index] = .active_voter;
            } else if (committed_members[index]) {
                self.statuses[index] = .authority;
            } else {
                self.statuses[index] = .stale;
            }
        }
        self.recomputeDataAccess(topology);
    }

    pub fn noteCommittedBootstrap(
        self: *PoolMemberSet,
        record: control_record.Record,
        target_member: member_api.Member,
        target_history: journal.HistoryScan,
        active_members: [max_member_count]bool,
        active_count: u16,
    ) !usize {
        if (self.supplied_count == max_member_count) return error.TooManyPoolMembers;
        const index = self.supplied_count;
        self.members[index] = target_member;
        self.histories[index] = target_history;
        self.statuses[index] = .authority;
        self.supplied_count += 1;
        const previous = self.authority_state.?;
        self.authority_state = .{
            .kind = .member_bootstrap,
            .history_digest = record.history_digest,
            .data_root_digest = record.data_root_digest,
            .topology = previous.topology,
            .layout = previous.layout,
            .membership_epoch = record.membership_epoch,
            .writer_term = record.writer_term,
            .generation = record.generation,
            .witness_count = active_count,
            .administrative_recovery = previous.administrative_recovery,
        };
        self.control_write_state = .{
            .tail_history_digest = record.history_digest,
            .active_members = active_members,
            .active_count = active_count,
            .reclaim_required = false,
        };
        self.updateVoterStatuses(previous.topology, active_members);
        self.recomputeDataAccess(previous.topology);
        return index;
    }

    pub fn noteCommittedCheckpoint(
        self: *PoolMemberSet,
        record: control_record.Record,
        active_members: [max_member_count]bool,
        active_count: u16,
    ) void {
        const previous = self.authority_state.?;
        self.authority_state = .{
            .kind = .checkpoint,
            .history_digest = record.history_digest,
            .data_root_digest = previous.data_root_digest,
            .topology = previous.topology,
            .layout = previous.layout,
            .membership_epoch = previous.membership_epoch,
            .writer_term = previous.writer_term,
            .generation = previous.generation,
            .witness_count = active_count,
            .administrative_recovery = previous.administrative_recovery,
        };
        self.control_write_state = .{
            .tail_history_digest = record.history_digest,
            .active_members = active_members,
            .active_count = active_count,
            .reclaim_required = false,
        };
        self.updateVoterStatuses(previous.topology, active_members);
        self.recomputeDataAccess(previous.topology);
    }

    pub fn noteControlReclaimed(
        self: *PoolMemberSet,
        active_members: [max_member_count]bool,
        active_count: u16,
    ) void {
        const selected = self.authority_state.?;
        self.control_write_state = .{
            .tail_history_digest = selected.history_digest,
            .active_members = active_members,
            .active_count = active_count,
            .reclaim_required = false,
        };
        self.updateVoterStatuses(selected.topology, active_members);
        self.recomputeDataAccess(selected.topology);
    }

    pub fn close(self: *PoolMemberSet) !void {
        while (true) {
            const state = self.coordinator_state.load(.acquire);
            if (state == 1) return error.CoordinatorActive;
            if (state == 2) return;
            if (self.coordinator_state.cmpxchgStrong(state, 2, .acq_rel, .acquire) == null) break;
        }
        var first_error: ?anyerror = null;
        var close_incomplete = false;
        for (&self.histories) |*maybe_history| {
            if (maybe_history.*) |*history| history.deinit();
            maybe_history.* = null;
        }
        for (&self.members) |*maybe_member| {
            if (maybe_member.*) |*member| {
                member.close() catch |err| {
                    if (first_error == null) first_error = err;
                    if (member.isClosed()) maybe_member.* = null else close_incomplete = true;
                    continue;
                };
                maybe_member.* = null;
            }
        }
        self.control_write_state = null;
        if (first_error) |err| {
            if (close_incomplete) self.coordinator_state.store(3, .release);
            return err;
        }
    }

    pub fn deinit(self: *PoolMemberSet) void {
        self.close() catch |err| {
            if (err == error.CoordinatorActive) @panic("PoolMemberSet deinitialized with active coordinator");
        };
    }

    fn classifyMembers(self: *PoolMemberSet, intent: OpenIntent) void {
        const selected_authority = self.authority_state.?;
        var ready: ControlWriteReady = .{
            .tail_history_digest = selected_authority.history_digest,
            .active_members = @splat(false),
            .active_count = 0,
            .reclaim_required = false,
        };
        var available_data_members: usize = 0;
        for (0..self.supplied_count) |index| {
            const member = if (self.members[index]) |*value| value else continue;
            const history = &(self.histories[index].?);
            const descriptor = pool_topology.findMember(&selected_authority.topology, member.header().member_id) orelse {
                self.statuses[index] = .removed;
                continue;
            };
            const has_authority = history.findHistoryDigest(selected_authority.history_digest) != null;
            if (!has_authority) {
                self.statuses[index] = .stale;
                continue;
            }
            self.statuses[index] = .authority;
            if (descriptor.state != .joining) available_data_members += 1;
            const tail = history.scan_result.tail orelse continue;
            const needs_reclaim = history.scan_result.anchored or
                (history.scan_result.journal_full and selected_authority.kind == .checkpoint and
                    tail.kind == control_record.checkpoint_kind);
            if (intent != .writable or descriptor.control_role != pool_topology.voter_role or
                member.mode() != .writable or member.isFrozen() or
                (history.scan_result.unresolved_tail_damage and !history.scan_result.anchored) or
                (history.scan_result.journal_full and !needs_reclaim) or
                !std.mem.eql(u8, &tail.history_digest, &selected_authority.history_digest)) continue;
            ready.active_members[index] = true;
            ready.active_count += 1;
            ready.reclaim_required = ready.reclaim_required or needs_reclaim;
            self.statuses[index] = .active_voter;
        }
        self.data_access_state = pool_policy.dataAccess(
            selected_authority.layout.protection() catch unreachable,
            available_data_members,
        ) catch .unavailable;
        if (intent == .writable and ready.active_count >= selected_authority.topology.quorum)
            self.control_write_state = ready;
    }

    fn reopenCatalog(self: *PoolMemberSet, intent: OpenIntent) !void {
        const selected = self.authority_state orelse return error.MissingAuthority;
        if (selected.generation == 0) return;
        self.fenceCatalogDataWrites();

        var geometry_buffer: [max_member_count]pool_catalog_graph.MemberGeometry = undefined;
        const geometry = try self.collectCatalogGeometry(&geometry_buffer);
        var scratch: pool_catalog_store.LoadScratch = .{};
        var selections: [max_member_count]?pool_catalog_store.RootSelection = @splat(null);
        var valid_count: u16 = 0;
        for (selected.topology.memberSlice()) |descriptor| {
            if (descriptor.control_role != pool_topology.voter_role) continue;
            const set_index = self.findSuppliedMember(descriptor.member_id) orelse continue;
            const member = if (self.members[set_index]) |*value| value else continue;
            switch (self.statuses[set_index]) {
                .authority, .active_voter => {},
                else => continue,
            }
            const loaded = pool_catalog_store.loadAuthorityCatalog(
                member,
                selected,
                geometry,
                &scratch,
            ) catch |err| {
                self.invalidateCatalogVoter(set_index, err);
                continue;
            };
            selections[set_index] = loaded.selection;
            valid_count += 1;
        }
        const read_threshold = try (try selected.layout.protection()).readThreshold();
        if (valid_count < read_threshold) {
            self.data_access_state = .unavailable;
            self.control_write_state = null;
            return error.CatalogReadQuorumUnavailable;
        }
        if (intent != .writable or self.control_write_state == null) return;

        for (selections, 0..) |maybe_selection, set_index| {
            const selection = maybe_selection orelse continue;
            if (self.statuses[set_index] != .active_voter or !selection.mirror_degraded) continue;
            const member = if (self.members[set_index]) |*value| value else continue;
            var claim = member.claimCatalog() catch {
                self.invalidateCatalogVoter(set_index, error.CatalogClaimUnavailable);
                if (self.control_write_state == null) break;
                continue;
            };
            _ = pool_catalog_store.repairRootMirror(
                &claim,
                selected,
                &selection.authoritative.bytes,
            ) catch |err| {
                claim.release() catch unreachable;
                self.invalidateCatalogVoter(set_index, err);
                if (self.control_write_state == null) break;
                continue;
            };
            claim.release() catch unreachable;
        }
    }

    fn invalidateCatalogVoter(self: *PoolMemberSet, set_index: usize, reason: anyerror) void {
        self.statuses[set_index] = .{ .catalog_failed = reason };
        if (self.control_write_state) |*ready| {
            if (ready.active_members[set_index]) {
                ready.active_members[set_index] = false;
                ready.active_count -= 1;
            }
            if (ready.active_count < self.authority_state.?.topology.quorum)
                self.control_write_state = null;
        }
    }

    fn fenceCatalogDataWrites(self: *PoolMemberSet) void {
        const selected = self.authority_state orelse return;
        for (self.members[0..self.supplied_count]) |*maybe_member| {
            const member = if (maybe_member.*) |*value| value else continue;
            if (pool_topology.findMember(&selected.topology, member.header().member_id) != null)
                member.fenceUnleasedCatalogWrites();
        }
    }

    fn recomputeDataAccess(self: *PoolMemberSet, topology: pool_topology.Topology) void {
        var available_data_members: usize = 0;
        for (self.members[0..self.supplied_count], 0..) |maybe_member, index| {
            const member = if (maybe_member) |value| value else continue;
            const descriptor = pool_topology.findMember(&topology, member.header().member_id) orelse continue;
            if (descriptor.state == .joining) continue;
            switch (self.statuses[index]) {
                .authority, .active_voter, .catalog_failed => available_data_members += 1,
                else => {},
            }
        }
        const protection = self.authority_state.?.layout.protection() catch {
            self.data_access_state = .unavailable;
            return;
        };
        self.data_access_state = pool_policy.dataAccess(protection, available_data_members) catch .unavailable;
    }

    fn updateVoterStatuses(
        self: *PoolMemberSet,
        topology: pool_topology.Topology,
        active_members: [max_member_count]bool,
    ) void {
        for (active_members[0..self.supplied_count], 0..) |active, index| {
            if (active) {
                self.statuses[index] = .active_voter;
                continue;
            }
            const member = if (self.members[index]) |*value| value else continue;
            const descriptor = pool_topology.findMember(&topology, member.header().member_id) orelse continue;
            const history_has_authority = if (self.histories[index]) |*history|
                history.findHistoryDigest(self.authority_state.?.history_digest) != null
            else
                false;
            if (history_has_authority) {
                self.statuses[index] = .authority;
            } else if (descriptor.control_role == pool_topology.voter_role or descriptor.state != .joining) {
                self.statuses[index] = .stale;
            }
        }
    }

    fn validateAuthorityGeometry(self: *const PoolMemberSet, selected: pool_authority.Authority) !void {
        var canonical: ?member_format.Header = null;
        for (0..self.supplied_count) |index| {
            const member = if (self.members[index]) |*value| value else continue;
            const history = &(self.histories[index].?);
            if (history.findHistoryDigest(selected.history_digest) == null) continue;
            const header = member.header();
            if (canonical) |expected| {
                if (!samePoolGeometry(expected, header)) return error.InconsistentMemberGeometry;
            } else {
                canonical = header;
            }
        }
    }
};

fn samePoolGeometry(a: member_format.Header, b: member_format.Header) bool {
    return member_format.poolFilesystem(a) == member_format.poolFilesystem(b) and
        a.logical_capacity == b.logical_capacity and
        a.control.offset == b.control.offset and a.control.length == b.control.length and
        a.metadata.offset == b.metadata.offset and a.metadata.length == b.metadata.length and
        a.data.offset == b.data.offset and
        a.metadata_block_size == b.metadata_block_size and
        a.metadata_read_size == b.metadata_read_size and
        a.metadata_program_size == b.metadata_program_size and
        a.chunk_size == b.chunk_size;
}

fn scanLocations(
    io: std.Io,
    allocator: std.mem.Allocator,
    locations: []const Location,
    mode: member_format.OpenMode,
) !PoolMemberSet {
    if (locations.len == 0 or locations.len > max_member_count) return error.InvalidMemberCount;
    try validateLocations(locations);
    var set: PoolMemberSet = .{ .supplied_count = locations.len };
    errdefer set.deinit();
    for (locations, 0..) |location, index| {
        var member = member_api.openAt(io, location.parent, location.basename, mode) catch |err| {
            set.statuses[index] = .{ .open_failed = err };
            continue;
        };
        try scanMember(allocator, &set, index, &member);
    }
    return set;
}

fn scanStorages(
    io: std.Io,
    allocator: std.mem.Allocator,
    storages: []member_api.Storage,
    mode: member_format.OpenMode,
) !PoolMemberSet {
    var set: PoolMemberSet = undefined;
    try scanStoragesInto(&set, io, allocator, storages, mode);
    return set;
}

fn scanStoragesInto(
    set: *PoolMemberSet,
    io: std.Io,
    allocator: std.mem.Allocator,
    storages: []member_api.Storage,
    mode: member_format.OpenMode,
) !void {
    if (storages.len == 0 or storages.len > max_member_count) {
        storage_api.closeAll(storages, io) catch {};
        return error.InvalidMemberCount;
    }
    for (storages, 0..) |*storage, index| for (storages[0..index]) |*previous| {
        if (storage.sameIdentity(previous)) {
            storage_api.closeAll(storages, io) catch {};
            return error.DuplicateStorage;
        }
    };
    set.* = .{ .supplied_count = storages.len };
    var consumed_count: usize = 0;
    errdefer {
        set.deinit();
        storage_api.closeAll(storages[consumed_count..], io) catch {};
    }
    for (storages, 0..) |storage, index| {
        consumed_count += 1;
        var member = member_api.openStorage(io, storage, mode) catch |err| {
            set.statuses[index] = .{ .open_failed = err };
            continue;
        };
        try scanMember(allocator, set, index, &member);
    }
}

fn scanMember(
    allocator: std.mem.Allocator,
    set: *PoolMemberSet,
    index: usize,
    member: *member_api.Member,
) !void {
    if (!member_format.isDynamicPool(member.header())) {
        member.deinit();
        set.statuses[index] = .legacy;
        return;
    }
    var history = journal.scanHistory(allocator, member) catch |err| {
        member.deinit();
        if (err == error.OutOfMemory) return err;
        set.statuses[index] = .{ .scan_failed = err };
        return;
    };
    if (history.entries().len == 0) {
        history.deinit();
        member.deinit();
        set.statuses[index] = .{ .scan_failed = error.MissingGenesis };
        return;
    }
    set.members[index] = member.*;
    set.histories[index] = history;
    set.statuses[index] = .stale;
}

fn validateLocations(locations: []const Location) !void {
    for (locations, 0..) |location, index| {
        for (locations[0..index]) |previous| {
            if (location.parent.handle == previous.parent.handle and
                std.mem.eql(u8, location.basename, previous.basename))
                return error.DuplicateMemberLocation;
        }
    }
}

pub fn open(
    io: std.Io,
    allocator: std.mem.Allocator,
    locations: []const Location,
    intent: OpenIntent,
) !PoolMemberSet {
    return PoolMemberSet.open(io, allocator, locations, intent);
}

pub fn openStorages(
    io: std.Io,
    allocator: std.mem.Allocator,
    storages: []member_api.Storage,
    intent: OpenIntent,
) !PoolMemberSet {
    return PoolMemberSet.openStorages(io, allocator, storages, intent);
}

pub fn openAdministrativeRecovery(
    io: std.Io,
    allocator: std.mem.Allocator,
    location: Location,
    trusted_member_id: [16]u8,
) !PoolMemberSet {
    return PoolMemberSet.openAdministrativeRecovery(io, allocator, location, trusted_member_id);
}

const pool_genesis = @import("pool_genesis_payload.zig");
const pool_provision = @import("pool_provision.zig");

fn id(value: u8) [16]u8 {
    return @splat(value);
}

fn createTestPool(dir: std.Io.Dir, name: []const u8, protection: pool_policy.Protection) !void {
    return createTestPoolWithControlBytes(dir, name, protection, 64 * 1024);
}

fn createTestPoolWithControlBytes(
    dir: std.Io.Dir,
    name: []const u8,
    protection: pool_policy.Protection,
    control_bytes: u64,
) !void {
    const members = [_]pool_topology.Member{.{
        .member_id = id(2),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = member_format.known_role_flags,
    }};
    const payload: pool_genesis.GenesisPayload = .{
        .topology = try pool_topology.Topology.init(id(1), 1, @splat(0), &members),
        .layout = try pool_layout.Layout.init(protection, 1, 1, 1024 * 1024),
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
        .control = .{ .offset = 64 * 1024, .length = control_bytes },
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
        .label = try member_format.Label.init("pool-member-set-test"),
        .genesis_topology_digest = try pool_topology.digest(payload.topology),
    };
    var member = try member_api.createPoolAt(std.testing.io, dir, name, header, payload, .{});
    try member.close();
}

fn rewriteFilesystemMarker(dir: std.Io.Dir, name: []const u8, filesystem: member_format.PoolFilesystem) !void {
    var member = try member_api.openAt(std.testing.io, dir, name, .writable);
    var header = member.header();
    try member.close();
    switch (filesystem) {
        .littlefs => header.incompat_features &= ~member_format.blob_filesystem_incompat_feature,
        .blob => header.incompat_features |= member_format.blob_filesystem_incompat_feature,
    }
    const bytes = try member_format.encode(header);
    const file = try dir.openFile(std.testing.io, name, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &bytes, 0);
    try file.writePositionalAll(std.testing.io, &bytes, member_format.encoded_size);
    try file.sync(std.testing.io);
}

test "one-member pool opens with one control voter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestPool(tmp.dir, "member", .unprotected);
    const locations = [_]Location{.{ .parent = tmp.dir, .basename = "member" }};
    var set = try open(std.testing.io, std.testing.allocator, &locations, .writable);
    defer set.deinit();
    try std.testing.expectEqual(pool_authority.Kind.genesis, set.authority().?.kind);
    try std.testing.expectEqual(@as(u16, 1), set.controlWriteReady().?.active_count);
    try std.testing.expectEqual(pool_policy.DataAccess.read_write, set.dataAccess());
    const data_member = try set.dataMemberForRead(7);
    try std.testing.expectEqual(@as(usize, 0), data_member.set_index);
    try std.testing.expectEqual(@as(u16, 7), data_member.member.header().member_slot);
}

test "replicated pool below full width permits maintenance but keeps data read only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestPool(tmp.dir, "member", .replicated);
    const locations = [_]Location{.{ .parent = tmp.dir, .basename = "member" }};
    var set = try open(std.testing.io, std.testing.allocator, &locations, .writable);
    defer set.deinit();
    try std.testing.expect(set.controlWriteReady() != null);
    try std.testing.expectEqual(pool_policy.DataAccess.read_only, set.dataAccess());
}

test "duplicate locations and legacy members are not admitted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestPool(tmp.dir, "member", .unprotected);
    const duplicate = [_]Location{
        .{ .parent = tmp.dir, .basename = "member" },
        .{ .parent = tmp.dir, .basename = "member" },
    };
    try std.testing.expectError(
        error.DuplicateMemberLocation,
        open(std.testing.io, std.testing.allocator, &duplicate, .read_only),
    );
}

test "authority geometry rejects mixed Pool filesystem members" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "a", "b", "c" };
    var storages: [names.len]storage_api.Storage = undefined;
    for (names, 0..) |name, index|
        storages[index] = try storage_api.Storage.createFile(std.testing.io, tmp.dir, name, 8 * 1024 * 1024);
    const outcome = try pool_provision.create(std.testing.io, std.testing.allocator, &storages, .{});
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    try provisioned.close();
    try rewriteFilesystemMarker(tmp.dir, "c", .blob);

    const locations = [_]Location{
        .{ .parent = tmp.dir, .basename = "a" },
        .{ .parent = tmp.dir, .basename = "b" },
        .{ .parent = tmp.dir, .basename = "c" },
    };
    try std.testing.expectError(
        error.InconsistentMemberGeometry,
        open(std.testing.io, std.testing.allocator, &locations, .read_only),
    );
}

test "catalog bootstrap target geometry rejects a mixed Pool filesystem" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestPool(tmp.dir, "source", .unprotected);
    try createTestPool(tmp.dir, "target", .unprotected);
    try rewriteFilesystemMarker(tmp.dir, "target", .blob);

    const source = try member_api.openAt(std.testing.io, tmp.dir, "source", .writable);
    const target = try member_api.openAt(std.testing.io, tmp.dir, "target", .writable);
    var set: PoolMemberSet = .{ .supplied_count = 2 };
    set.members[0] = source;
    set.members[1] = target;
    defer set.deinit();
    try std.testing.expectError(error.InconsistentMemberGeometry, set.validateCatalogTargetGeometry(0, 1));
}

test "administrative recovery reserves a checkpoint slot" {
    inline for (.{ 4096, 2 * 4096, 3 * 4096 }) |control_bytes| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try createTestPoolWithControlBytes(tmp.dir, "member", .unprotected, control_bytes);
        const location: Location = .{ .parent = tmp.dir, .basename = "member" };
        try std.testing.expectError(
            error.InsufficientJournalCapacity,
            openAdministrativeRecovery(std.testing.io, std.testing.allocator, location, id(2)),
        );
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestPoolWithControlBytes(tmp.dir, "member", .unprotected, 4 * 4096);
    const location: Location = .{ .parent = tmp.dir, .basename = "member" };
    var set = try openAdministrativeRecovery(std.testing.io, std.testing.allocator, location, id(2));
    defer set.deinit();
    try std.testing.expect(set.controlWriteReady() != null);
}

test "administrative recovery rejects a damaged physical tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTestPool(tmp.dir, "member", .unprotected);
    const file = try tmp.dir.openFile(std.testing.io, "member", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &.{0xaa}, 64 * 1024 + 4096);

    const location: Location = .{ .parent = tmp.dir, .basename = "member" };
    try std.testing.expectError(
        error.JournalNeedsRecovery,
        openAdministrativeRecovery(std.testing.io, std.testing.allocator, location, id(2)),
    );
}
