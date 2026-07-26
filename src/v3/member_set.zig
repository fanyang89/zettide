const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const genesis_payload_format = @import("genesis_payload.zig");
const journal_api = @import("journal.zig");
const layout_format = @import("layout.zig");
const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const topology_format = @import("topology.zig");

pub const member_count = topology_format.member_count;

pub const Location = struct {
    parent: std.Io.Dir,
    basename: []const u8,
};

pub const CreateOptions = struct {
    member_options: [member_count]member_api.CreateOptions = .{ .{}, .{}, .{} },
};

pub const OpenIntent = enum { diagnostic, read_only, writable };

pub const SlotStatus = union(enum) {
    absent,
    open_failed: anyerror,
    scan_failed: anyerror,
    misplaced,
    foreign,
    damaged,
    stale,
    authority,
    active,
};

pub const AuthorityKind = enum { genesis, generation_commit };

pub const Authority = struct {
    kind: AuthorityKind,
    history_digest: codec.Digest,
    data_root_digest: codec.Digest,
    topology_digest: codec.Digest,
    layout_digest: codec.Digest,
    generation: u64,
    witness_slots: u8,
};

pub const ControlWriteReady = struct {
    tail_history_digest: codec.Digest,
    active_slots: u8,
};

pub const MemberSet = struct {
    members: [member_count]?member_api.Member = .{ null, null, null },
    histories: [member_count]?journal_api.HistoryScan = .{ null, null, null },
    slot_statuses: [member_count]SlotStatus = .{ .absent, .absent, .absent },
    genesis_payload: ?genesis_payload_format.GenesisPayload = null,
    authority_state: ?Authority = null,
    control_write_state: ?ControlWriteReady = null,

    pub fn create(
        io: std.Io,
        locations: [member_count]Location,
        headers: [member_count]member_format.Header,
        genesis_payload: genesis_payload_format.GenesisPayload,
        options: CreateOptions,
    ) !MemberSet {
        try validateCreate(locations, headers, genesis_payload);

        var set: MemberSet = .{ .genesis_payload = genesis_payload };
        errdefer set.deinit();

        for (0..member_count) |slot| {
            set.members[slot] = try member_api.createAt(
                io,
                locations[slot].parent,
                locations[slot].basename,
                headers[slot],
                genesis_payload,
                options.member_options[slot],
            );
            set.slot_statuses[slot] = .active;
        }
        const genesis = try genesis_payload_format.makeRecord(headers[0].member_id, genesis_payload);
        set.authority_state = authorityFromRecord(.genesis, genesis, 0b111);
        set.control_write_state = .{
            .tail_history_digest = genesis.history_digest,
            .active_slots = 0b111,
        };
        return set;
    }

    pub fn open(
        io: std.Io,
        allocator: std.mem.Allocator,
        locations: [member_count]?Location,
        intent: OpenIntent,
    ) !MemberSet {
        var set: MemberSet = .{};
        errdefer set.deinit();
        const member_mode: member_format.OpenMode = if (intent == .writable) .writable else .read_only;

        for (locations, 0..) |maybe_location, slot| {
            const location = maybe_location orelse continue;
            var member = member_api.openAt(io, location.parent, location.basename, member_mode) catch |err| {
                set.slot_statuses[slot] = .{ .open_failed = err };
                continue;
            };
            if (member.header().member_slot != slot) {
                member.deinit();
                set.slot_statuses[slot] = .misplaced;
                continue;
            }
            var history = journal_api.scanHistory(allocator, &member) catch |err| {
                member.deinit();
                if (err == error.OutOfMemory) return err;
                set.slot_statuses[slot] = .{ .scan_failed = err };
                continue;
            };
            if (history.entries().len == 0) {
                const scan_error = if (history.scan_result.unresolved_tail_damage)
                    error.JournalNeedsRecovery
                else
                    error.MissingGenesis;
                history.deinit();
                member.deinit();
                set.slot_statuses[slot] = .{ .scan_failed = scan_error };
                continue;
            }
            set.members[slot] = member;
            set.histories[slot] = history;
            set.slot_statuses[slot] = if (history.scan_result.unresolved_tail_damage) .damaged else .stale;
        }

        try set.selectAuthority(intent);
        return set;
    }

    pub fn memberAt(self: *MemberSet, slot: u16) !*member_api.Member {
        if (slot >= member_count) return error.InvalidMemberSlot;
        if (self.members[slot]) |*member| return member;
        return error.MemberUnavailable;
    }

    pub fn historyAt(self: *const MemberSet, slot: u16) !*const journal_api.HistoryScan {
        if (slot >= member_count) return error.InvalidMemberSlot;
        if (self.histories[slot]) |*history| return history;
        return error.MemberUnavailable;
    }

    pub fn statusAt(self: *const MemberSet, slot: u16) !SlotStatus {
        if (slot >= member_count) return error.InvalidMemberSlot;
        return self.slot_statuses[slot];
    }

    pub fn authority(self: *const MemberSet) ?Authority {
        return self.authority_state;
    }

    pub fn controlWriteReady(self: *const MemberSet) ?ControlWriteReady {
        return self.control_write_state;
    }

    pub fn close(self: *MemberSet) !void {
        var first_error: ?anyerror = null;
        for (&self.histories) |*maybe_history| {
            if (maybe_history.*) |*history| history.deinit();
            maybe_history.* = null;
        }
        for (&self.members) |*maybe_member| {
            if (maybe_member.*) |*member| member.close() catch |err| if (first_error == null) {
                first_error = err;
            };
            maybe_member.* = null;
        }
        if (first_error) |err| return err;
    }

    pub fn deinit(self: *MemberSet) void {
        self.close() catch {};
    }

    fn selectAuthority(self: *MemberSet, intent: OpenIntent) !void {
        const genesis_group = try self.selectGenesisGroup();
        if (genesis_group.count < topology_format.control_write_quorum) {
            if (genesis_group.count == 0) return error.NoReadableMember;
            if (intent != .diagnostic) return error.NoGenesisQuorum;
            self.genesis_payload = genesis_group.payload;
            return;
        }

        self.genesis_payload = genesis_group.payload;
        try self.validateSelectedMembers(genesis_group);
        try self.rejectQuorumMembershipHistory(genesis_group.mask);
        self.authority_state = authorityFromRecord(
            .genesis,
            self.histories[genesis_group.first_slot].?.entries()[0].record,
            genesis_group.mask,
        );
        try self.selectCommittedAuthority(genesis_group.mask);
        self.selectControlWriteQuorum(genesis_group.mask, intent);
        if (intent == .writable and self.control_write_state == null)
            return error.WriteQuorumUnavailable;
    }

    fn selectGenesisGroup(self: *MemberSet) !GenesisGroup {
        var selected: GenesisGroup = .{};
        for (&self.histories, 0..) |*maybe_history, slot| {
            const history = if (maybe_history.*) |*value| value else continue;
            const genesis = history.entries()[0].record;
            var mask: u8 = 0;
            var count: usize = 0;
            for (&self.histories, 0..) |*maybe_other, other_slot| {
                const other = if (maybe_other.*) |*value| value else continue;
                if (!std.mem.eql(
                    u8,
                    &genesis.history_digest,
                    &other.entries()[0].record.history_digest,
                )) continue;
                mask |= slotBit(other_slot);
                count += 1;
            }
            if (count < selected.count) continue;
            if (count == selected.count and selected.count != 0 and
                !std.mem.eql(u8, &genesis.history_digest, &selected.history_digest))
            {
                if (count >= topology_format.control_write_quorum)
                    return error.AmbiguousGenesisAuthority;
                continue;
            }
            selected = .{
                .count = count,
                .mask = mask,
                .first_slot = slot,
                .history_digest = genesis.history_digest,
                .payload = try genesis_payload_format.validateRecord(genesis),
            };
        }
        return selected;
    }

    fn validateSelectedMembers(self: *MemberSet, group: GenesisGroup) !void {
        const payload = group.payload.?;
        const genesis_digest = try topology_format.digest(payload.topology);
        var headers: [member_count]member_format.Header = undefined;
        var header_count: usize = 0;
        for (0..member_count) |slot| {
            if (group.mask & slotBit(slot) == 0) {
                if (self.histories[slot] != null) {
                    self.slot_statuses[slot] = .foreign;
                    if (self.members[slot]) |*member| member.deinit();
                    self.members[slot] = null;
                }
                continue;
            }
            const member = &(self.members[slot].?);
            const history = &(self.histories[slot].?);
            const member_payload = try genesis_payload_format.validateRecord(history.entries()[0].record);
            if (!std.meta.eql(payload, member_payload)) return error.GenesisPayloadMismatch;
            headers[header_count] = member.header();
            header_count += 1;
        }
        try topology_format.validateMemberSubset(
            payload.topology,
            genesis_digest,
            headers[0..header_count],
        );
        try layout_format.validateAgainstTopology(payload.layout, payload.topology);
        try layout_format.validateAgainstHeaderSubset(payload.layout, headers[0..header_count]);
    }

    fn rejectQuorumMembershipHistory(self: *const MemberSet, selected_mask: u8) !void {
        for (0..member_count) |slot| {
            if (selected_mask & slotBit(slot) == 0) continue;
            const history = &(self.histories[slot].?);
            for (history.entries()) |entry| {
                if (entry.record.kind != control_record.membership_prepare_kind and
                    entry.record.kind != control_record.membership_commit_kind) continue;
                if (@popCount(self.witnessMask(selected_mask, entry.record.kind, entry.record.history_digest)) >=
                    topology_format.control_write_quorum)
                    return error.UnsupportedMembershipHistory;
            }
        }
    }

    fn selectCommittedAuthority(self: *MemberSet, selected_mask: u8) !void {
        var history_pointers: [member_count]*const journal_api.HistoryScan = undefined;
        var history_count: usize = 0;
        for (0..member_count) |slot| {
            if (selected_mask & slotBit(slot) == 0) continue;
            history_pointers[history_count] = &(self.histories[slot].?);
            history_count += 1;
        }

        for (0..member_count) |slot| {
            if (selected_mask & slotBit(slot) == 0) continue;
            const history = &(self.histories[slot].?);
            for (history.entries(), 0..) |entry, entry_index| {
                if (entry.record.kind != control_record.generation_commit_kind) continue;
                if (self.commitSeenEarlier(selected_mask, slot, entry_index, entry.record.history_digest)) continue;
                const witnesses = self.witnessMask(
                    selected_mask,
                    control_record.generation_commit_kind,
                    entry.record.history_digest,
                );
                if (@popCount(witnesses) < topology_format.control_write_quorum) continue;
                _ = try journal_api.validateGenerationCommitEvidence(
                    history.member_id,
                    entry.raw_record_digest,
                    history_pointers[0..history_count],
                    self.genesis_payload.?.topology,
                );

                const current = self.authority_state.?;
                if (std.mem.eql(u8, &current.history_digest, &entry.record.history_digest)) continue;
                if (self.isDescendant(selected_mask, entry.record.history_digest, current.history_digest)) {
                    self.authority_state = authorityFromRecord(.generation_commit, entry.record, witnesses);
                } else if (!self.isDescendant(selected_mask, current.history_digest, entry.record.history_digest)) {
                    return error.ConflictingAuthority;
                }
            }
        }
    }

    fn selectControlWriteQuorum(self: *MemberSet, selected_mask: u8, intent: OpenIntent) void {
        const authority_digest = self.authority_state.?.history_digest;
        for (0..member_count) |slot| {
            if (selected_mask & slotBit(slot) == 0) continue;
            const history = &(self.histories[slot].?);
            if (history.scan_result.unresolved_tail_damage) {
                self.slot_statuses[slot] = .damaged;
            } else if (history.findHistoryDigest(authority_digest) != null) {
                self.slot_statuses[slot] = .authority;
            } else {
                self.slot_statuses[slot] = .stale;
            }
        }
        if (intent != .writable) return;

        for (0..member_count) |slot| {
            if (!self.controlAppendable(selected_mask, slot, authority_digest)) continue;
            const tail_digest = self.histories[slot].?.scan_result.tail.?.history_digest;
            var active_slots: u8 = 0;
            for (0..member_count) |other_slot| {
                if (!self.controlAppendable(selected_mask, other_slot, authority_digest)) continue;
                const other_tail = self.histories[other_slot].?.scan_result.tail.?.history_digest;
                if (std.mem.eql(u8, &tail_digest, &other_tail)) active_slots |= slotBit(other_slot);
            }
            if (@popCount(active_slots) < topology_format.control_write_quorum) continue;
            self.control_write_state = .{
                .tail_history_digest = tail_digest,
                .active_slots = active_slots,
            };
            for (0..member_count) |other_slot| {
                if (active_slots & slotBit(other_slot) != 0) self.slot_statuses[other_slot] = .active;
            }
            return;
        }
    }

    fn controlAppendable(
        self: *const MemberSet,
        selected_mask: u8,
        slot: usize,
        authority_digest: codec.Digest,
    ) bool {
        if (selected_mask & slotBit(slot) == 0) return false;
        const member = &(self.members[slot].?);
        const history = &(self.histories[slot].?);
        const tail_kind = history.scan_result.tail.?.kind;
        return member.mode() == .writable and !member.isFrozen() and
            !history.scan_result.unresolved_tail_damage and !history.scan_result.journal_full and
            history.findHistoryDigest(authority_digest) != null and
            (tail_kind == control_record.genesis_kind or tail_kind == control_record.generation_commit_kind);
    }

    fn witnessMask(
        self: *const MemberSet,
        selected_mask: u8,
        kind: u16,
        history_digest: codec.Digest,
    ) u8 {
        var witnesses: u8 = 0;
        for (0..member_count) |slot| {
            if (selected_mask & slotBit(slot) == 0) continue;
            const history = &(self.histories[slot].?);
            const entry = history.findHistoryDigest(history_digest) orelse continue;
            if (entry.record.kind == kind) witnesses |= slotBit(slot);
        }
        return witnesses;
    }

    fn commitSeenEarlier(
        self: *const MemberSet,
        selected_mask: u8,
        slot: usize,
        entry_index: usize,
        history_digest: codec.Digest,
    ) bool {
        for (0..slot) |previous_slot| {
            if (selected_mask & slotBit(previous_slot) == 0) continue;
            const entry = self.histories[previous_slot].?.findHistoryDigest(history_digest) orelse continue;
            if (entry.record.kind == control_record.generation_commit_kind) return true;
        }
        for (self.histories[slot].?.entries()[0..entry_index]) |entry| {
            if (entry.record.kind == control_record.generation_commit_kind and
                std.mem.eql(u8, &entry.record.history_digest, &history_digest)) return true;
        }
        return false;
    }

    fn isDescendant(
        self: *const MemberSet,
        selected_mask: u8,
        descendant: codec.Digest,
        ancestor: codec.Digest,
    ) bool {
        if (std.mem.eql(u8, &descendant, &ancestor)) return true;
        for (0..member_count) |slot| {
            if (selected_mask & slotBit(slot) == 0) continue;
            const history = &(self.histories[slot].?);
            var ancestor_seen = false;
            for (history.entries()) |entry| {
                if (std.mem.eql(u8, &entry.record.history_digest, &ancestor)) ancestor_seen = true;
                if (std.mem.eql(u8, &entry.record.history_digest, &descendant)) return ancestor_seen;
            }
        }
        return false;
    }
};

const GenesisGroup = struct {
    count: usize = 0,
    mask: u8 = 0,
    first_slot: usize = 0,
    history_digest: codec.Digest = @splat(0),
    payload: ?genesis_payload_format.GenesisPayload = null,
};

fn slotBit(slot: usize) u8 {
    return @as(u8, 1) << @intCast(slot);
}

fn authorityFromRecord(kind: AuthorityKind, record: control_record.Record, witnesses: u8) Authority {
    return .{
        .kind = kind,
        .history_digest = record.history_digest,
        .data_root_digest = record.data_root_digest,
        .topology_digest = record.topology_digest,
        .layout_digest = record.layout_digest,
        .generation = record.generation,
        .witness_slots = witnesses,
    };
}

pub fn create(
    io: std.Io,
    locations: [member_count]Location,
    headers: [member_count]member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
    options: CreateOptions,
) !MemberSet {
    return MemberSet.create(io, locations, headers, genesis_payload, options);
}

pub fn open(
    io: std.Io,
    allocator: std.mem.Allocator,
    locations: [member_count]?Location,
    intent: OpenIntent,
) !MemberSet {
    return MemberSet.open(io, allocator, locations, intent);
}

pub fn validateCreate(
    locations: [member_count]Location,
    headers: [member_count]member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
) !void {
    for (locations, 0..) |location, index| {
        for (locations[0..index]) |previous| {
            if (location.parent.handle == previous.parent.handle and
                std.mem.eql(u8, location.basename, previous.basename))
                return error.DuplicateMemberLocation;
        }
    }
    for (0..member_count) |slot| {
        if (headers[slot].member_slot != slot) return error.MemberPathSlotMismatch;
        try member_api.validateCreateAt(locations[slot].basename, headers[slot], genesis_payload);
    }
    const genesis_topology_digest = try topology_format.digest(genesis_payload.topology);
    try topology_format.validateMemberSet(genesis_payload.topology, genesis_topology_digest, &headers);
    try layout_format.validateAgainstTopology(genesis_payload.layout, genesis_payload.topology);
    try layout_format.validateAgainstHeaders(genesis_payload.layout, &headers);
}

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

fn otherTestPayload() genesis_payload_format.GenesisPayload {
    var payload = testPayload();
    payload.topology.set_id = @splat(0x80);
    payload.topology.members = .{
        .{ .member_id = @splat(0x90), .slot = 0 },
        .{ .member_id = @splat(0xa0), .slot = 1 },
        .{ .member_id = @splat(0xb0), .slot = 2 },
    };
    return payload;
}

fn testHeaders(payload: genesis_payload_format.GenesisPayload) ![member_count]member_format.Header {
    const data_offset = 2 * 1024 * 1024;
    var headers: [member_count]member_format.Header = undefined;
    for (&headers, 0..) |*header, slot| {
        header.* = .{
            .header_sequence = 1,
            .set_id = payload.topology.set_id,
            .member_id = payload.topology.members[slot].member_id,
            .member_slot = @intCast(slot),
            .created_ns = 1,
            .member_bytes = data_offset + 1024 * 1024,
            .logical_capacity = 1024 * 1024,
            .control = .{ .offset = 64 * 1024, .length = 4 * 4096 },
            .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
            .data = .{ .offset = data_offset, .length = 1024 * 1024 },
            .metadata_block_size = 4096,
            .metadata_read_size = 512,
            .metadata_program_size = 512,
            .chunk_size = 1024 * 1024,
            .metadata_format_version = 1,
            .object_format_version = 1,
            .layout_format_version = 1,
            .control_record_format_version = 1,
            .label = try member_format.Label.init("member-set-test"),
            .genesis_topology_digest = try topology_format.digest(payload.topology),
        };
    }
    return headers;
}

fn testLocations(dir: std.Io.Dir) [member_count]Location {
    return .{
        .{ .parent = dir, .basename = "member0" },
        .{ .parent = dir, .basename = "member1" },
        .{ .parent = dir, .basename = "member2" },
    };
}

fn testOptionalLocations(dir: std.Io.Dir) [member_count]?Location {
    const locations = testLocations(dir);
    return .{ locations[0], locations[1], locations[2] };
}

fn testGenerationProposal(payload: genesis_payload_format.GenesisPayload) !control_record.Record {
    var record = try genesis_payload_format.makeRecord(payload.topology.members[0].member_id, payload);
    record.kind = control_record.generation_prepare_kind;
    record.writer_term = 1;
    record.generation = 1;
    record.mount_session_id = @splat(0x50);
    record.transaction_id = @splat(0x60);
    record.data_root_digest = @splat(0x70);
    record.payload = try control_record.Payload.init("member set generation");
    return record;
}

test "create publishes three slot-indexed members and closes every lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    var set = try create(std.testing.io, testLocations(tmp.dir), headers, payload, .{});

    for (0..member_count) |slot| {
        const created = try set.memberAt(@intCast(slot));
        try std.testing.expectEqual(@as(u16, @intCast(slot)), created.header().member_slot);
        try std.testing.expectEqualSlices(u8, &headers[slot].member_id, &created.header().member_id);
    }
    try std.testing.expectError(error.InvalidMemberSlot, set.memberAt(member_count));
    try set.close();
    try set.close();

    for (testLocations(tmp.dir)) |location| {
        var reopened = try member_api.openAt(std.testing.io, location.parent, location.basename, .writable);
        try reopened.close();
    }
}

test "set validation rejects every input before creating a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    var locations = testLocations(tmp.dir);
    var headers = try testHeaders(payload);
    locations[2] = locations[0];

    try std.testing.expectError(error.DuplicateMemberLocation, create(std.testing.io, locations, headers, payload, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "member0", .{}));

    locations = testLocations(tmp.dir);
    headers[2].member_slot = 1;

    try std.testing.expectError(error.MemberPathSlotMismatch, create(std.testing.io, locations, headers, payload, .{}));
    for (locations) |location|
        try std.testing.expectError(error.FileNotFound, location.parent.openFile(std.testing.io, location.basename, .{}));

    headers = try testHeaders(payload);
    locations[2].basename = "bad/name";
    try std.testing.expectError(error.InvalidBasename, create(std.testing.io, locations, headers, payload, .{}));
    locations = testLocations(tmp.dir);
    for (locations) |location|
        try std.testing.expectError(error.FileNotFound, location.parent.openFile(std.testing.io, location.basename, .{}));

    headers = try testHeaders(payload);
    headers[2].created_ns += 1;
    try std.testing.expectError(error.StaticSetFieldsMismatch, create(std.testing.io, locations, headers, payload, .{}));
    for (locations) |location|
        try std.testing.expectError(error.FileNotFound, location.parent.openFile(std.testing.io, location.basename, .{}));
}

test "partial set creation closes members and retains only attempted files" {
    for ([_]usize{ 1, 2 }) |failed_slot| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const payload = testPayload();
        const headers = try testHeaders(payload);
        const locations = testLocations(tmp.dir);
        var fault: member_api.CreateFaultController = .{
            .fail = .{ .point = .genesis_write, .action = .before },
        };
        var options: CreateOptions = .{};
        options.member_options[failed_slot].fault = &fault;

        try std.testing.expectError(error.InjectedCreateFault, create(std.testing.io, locations, headers, payload, options));
        for (locations[0..failed_slot]) |location| {
            var reopened = try member_api.openAt(std.testing.io, location.parent, location.basename, .writable);
            try reopened.close();
        }
        const retained = try locations[failed_slot].parent.openFile(
            std.testing.io,
            locations[failed_slot].basename,
            .{},
        );
        retained.close(std.testing.io);
        for (locations[failed_slot + 1 ..]) |location|
            try std.testing.expectError(error.FileNotFound, location.parent.openFile(std.testing.io, location.basename, .{}));
    }
}

test "close reports the first error after releasing every member" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    const locations = testLocations(tmp.dir);
    var set = try create(std.testing.io, locations, headers, payload, .{});
    var fault: member_api.FaultController = .{ .fail_sync_at = 0 };
    const first = try set.memberAt(0);
    first.setFaultController(&fault);
    try first.write(.metadata, 0, &.{1});

    try std.testing.expectError(error.InjectedFault, set.close());
    try set.close();
    for (locations) |location| {
        var reopened = try member_api.openAt(std.testing.io, location.parent, location.basename, .writable);
        try reopened.close();
    }
}

test "open selects genesis authority and writable quorum with one absent member" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    var created = try create(std.testing.io, testLocations(tmp.dir), headers, payload, .{});
    try created.close();

    var locations = testOptionalLocations(tmp.dir);
    locations[2] = null;
    var set = try open(std.testing.io, std.testing.allocator, locations, .writable);
    defer set.deinit();
    const authority = set.authority().?;
    try std.testing.expectEqual(AuthorityKind.genesis, authority.kind);
    try std.testing.expectEqual(@as(u8, 0b011), authority.witness_slots);
    try std.testing.expectEqual(@as(u8, 0b011), set.controlWriteReady().?.active_slots);
    try std.testing.expectEqual(.active, std.meta.activeTag(try set.statusAt(0)));
    try std.testing.expectEqual(.active, std.meta.activeTag(try set.statusAt(1)));
    try std.testing.expectEqual(.absent, std.meta.activeTag(try set.statusAt(2)));
    try std.testing.expectError(error.MemberUnavailable, set.memberAt(2));
}

test "single member is diagnostic only and writable open never downgrades" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    var created = try create(std.testing.io, testLocations(tmp.dir), headers, payload, .{});
    try created.close();

    const all_locations = testOptionalLocations(tmp.dir);
    const one_location: [member_count]?Location = .{ all_locations[0], null, null };
    try std.testing.expectError(
        error.NoGenesisQuorum,
        open(std.testing.io, std.testing.allocator, one_location, .read_only),
    );
    try std.testing.expectError(
        error.NoGenesisQuorum,
        open(std.testing.io, std.testing.allocator, one_location, .writable),
    );
    var diagnostic = try open(std.testing.io, std.testing.allocator, one_location, .diagnostic);
    try std.testing.expect(diagnostic.authority() == null);
    try std.testing.expect(diagnostic.controlWriteReady() == null);
    try diagnostic.close();

    var reopened = try member_api.openAt(std.testing.io, tmp.dir, "member0", .writable);
    try reopened.close();
}

test "prepare quorum remains read only until a commit quorum exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    const locations = testLocations(tmp.dir);
    var created = try create(std.testing.io, locations, headers, payload, .{});
    var journal0 = try journal_api.Journal.open(try created.memberAt(0));
    defer journal0.deinit();
    var journal1 = try journal_api.Journal.open(try created.memberAt(1));
    defer journal1.deinit();
    const proposal = try testGenerationProposal(payload);
    _ = try journal0.append(proposal);
    _ = try journal1.append(proposal);
    journal0.close();
    journal1.close();
    try created.close();

    const optional_locations = testOptionalLocations(tmp.dir);
    try std.testing.expectError(
        error.WriteQuorumUnavailable,
        open(std.testing.io, std.testing.allocator, optional_locations, .writable),
    );
    var read_only = try open(std.testing.io, std.testing.allocator, optional_locations, .read_only);
    defer read_only.deinit();
    try std.testing.expectEqual(AuthorityKind.genesis, read_only.authority().?.kind);
    try std.testing.expect(read_only.controlWriteReady() == null);
}

test "two certified commit copies become the ancestry authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    const locations = testLocations(tmp.dir);
    var created = try create(std.testing.io, locations, headers, payload, .{});
    var journal0 = try journal_api.Journal.open(try created.memberAt(0));
    defer journal0.deinit();
    var journal1 = try journal_api.Journal.open(try created.memberAt(1));
    defer journal1.deinit();
    var journal2 = try journal_api.Journal.open(try created.memberAt(2));
    defer journal2.deinit();
    const proposal = try testGenerationProposal(payload);
    const prepare0 = try journal0.append(proposal);
    const prepare1 = try journal1.append(proposal);
    _ = try journal2.append(proposal);
    const certificate: control_record.CommitCertificate = .{ .attestations = .{
        .{
            .member_id = prepare0.record.member_id,
            .prepare_record_digest = prepare0.record_digest,
            .prepare_history_digest = prepare0.record.history_digest,
        },
        .{
            .member_id = prepare1.record.member_id,
            .prepare_record_digest = prepare1.record_digest,
            .prepare_history_digest = prepare1.record.history_digest,
        },
    } };
    var commit_proposal = proposal;
    commit_proposal.kind = control_record.generation_commit_kind;
    commit_proposal.payload = try control_record.Payload.init(&(try control_record.encodeCertificate(certificate)));
    const commit0 = try journal0.append(commit_proposal);
    _ = try journal1.append(commit_proposal);
    journal0.close();
    journal1.close();
    journal2.close();
    try created.close();

    var set = try open(
        std.testing.io,
        std.testing.allocator,
        testOptionalLocations(tmp.dir),
        .writable,
    );
    defer set.deinit();
    const authority = set.authority().?;
    try std.testing.expectEqual(AuthorityKind.generation_commit, authority.kind);
    try std.testing.expectEqualSlices(u8, &commit0.record.history_digest, &authority.history_digest);
    try std.testing.expectEqual(@as(u8, 0b011), authority.witness_slots);
    try std.testing.expectEqual(@as(u8, 0b011), set.controlWriteReady().?.active_slots);
    try std.testing.expectEqual(.stale, std.meta.activeTag(try set.statusAt(2)));
}

test "quorum commit with missing prepare evidence is fatal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    const locations = testLocations(tmp.dir);
    var created = try create(std.testing.io, locations, headers, payload, .{});
    var journal0 = try journal_api.Journal.open(try created.memberAt(0));
    defer journal0.deinit();
    var journal1 = try journal_api.Journal.open(try created.memberAt(1));
    defer journal1.deinit();
    const proposal = try testGenerationProposal(payload);
    const prepare0 = try journal0.append(proposal);
    const prepare1 = try journal1.append(proposal);
    const certificate: control_record.CommitCertificate = .{ .attestations = .{
        .{
            .member_id = prepare0.record.member_id,
            .prepare_record_digest = @splat(0x99),
            .prepare_history_digest = prepare0.record.history_digest,
        },
        .{
            .member_id = prepare1.record.member_id,
            .prepare_record_digest = prepare1.record_digest,
            .prepare_history_digest = prepare1.record.history_digest,
        },
    } };
    var commit_proposal = proposal;
    commit_proposal.kind = control_record.generation_commit_kind;
    commit_proposal.payload = try control_record.Payload.init(&(try control_record.encodeCertificate(certificate)));
    _ = try journal0.append(commit_proposal);
    _ = try journal1.append(commit_proposal);
    journal0.close();
    journal1.close();
    try created.close();

    try std.testing.expectError(
        error.MissingPrepareRecord,
        open(std.testing.io, std.testing.allocator, testOptionalLocations(tmp.dir), .read_only),
    );
    for (locations) |location| {
        var reopened = try member_api.openAt(std.testing.io, location.parent, location.basename, .writable);
        try reopened.close();
    }
}

test "unresolved third member is excluded from a healthy write quorum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    const locations = testLocations(tmp.dir);
    var created = try create(std.testing.io, locations, headers, payload, .{});
    try created.close();
    const file = try tmp.dir.openFile(std.testing.io, "member2", .{ .mode = .read_write });
    try file.writePositionalAll(
        std.testing.io,
        &.{0xaa},
        headers[2].control.offset + control_record.encoded_size,
    );
    file.close(std.testing.io);

    var set = try open(
        std.testing.io,
        std.testing.allocator,
        testOptionalLocations(tmp.dir),
        .writable,
    );
    defer set.deinit();
    try std.testing.expectEqual(@as(u8, 0b011), set.controlWriteReady().?.active_slots);
    try std.testing.expectEqual(.damaged, std.meta.activeTag(try set.statusAt(2)));
}

test "foreign member is diagnostic evidence without a writable handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload_a = testPayload();
    const headers_a = try testHeaders(payload_a);
    const locations_a = testLocations(tmp.dir);
    var set_a = try create(std.testing.io, locations_a, headers_a, payload_a, .{});
    try set_a.close();

    const payload_b = otherTestPayload();
    const headers_b = try testHeaders(payload_b);
    const locations_b: [member_count]Location = .{
        .{ .parent = tmp.dir, .basename = "other0" },
        .{ .parent = tmp.dir, .basename = "other1" },
        .{ .parent = tmp.dir, .basename = "other2" },
    };
    var set_b = try create(std.testing.io, locations_b, headers_b, payload_b, .{});
    try set_b.close();

    const mixed_locations: [member_count]?Location = .{
        locations_a[0],
        locations_a[1],
        locations_b[2],
    };
    var mixed = try open(std.testing.io, std.testing.allocator, mixed_locations, .writable);
    defer mixed.deinit();
    try std.testing.expectEqual(@as(u8, 0b011), mixed.controlWriteReady().?.active_slots);
    try std.testing.expectEqual(.foreign, std.meta.activeTag(try mixed.statusAt(2)));
    try std.testing.expectError(error.MemberUnavailable, mixed.memberAt(2));

    var foreign = try member_api.openAt(std.testing.io, tmp.dir, "other2", .writable);
    try foreign.close();
}

test "quorum membership history is rejected until transitions are supported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    const locations = testLocations(tmp.dir);
    var created = try create(std.testing.io, locations, headers, payload, .{});
    var journal0 = try journal_api.Journal.open(try created.memberAt(0));
    defer journal0.deinit();
    var journal1 = try journal_api.Journal.open(try created.memberAt(1));
    defer journal1.deinit();
    var proposal = try testGenerationProposal(payload);
    proposal.kind = control_record.membership_prepare_kind;
    _ = try journal0.append(proposal);
    _ = try journal1.append(proposal);
    journal0.close();
    journal1.close();
    try created.close();

    try std.testing.expectError(
        error.UnsupportedMembershipHistory,
        open(std.testing.io, std.testing.allocator, testOptionalLocations(tmp.dir), .read_only),
    );
}
