const std = @import("std");
const control_record = @import("control_record.zig");
const journal = @import("journal.zig");
const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const pool_authority = @import("pool_authority.zig");
const pool_layout = @import("pool_layout.zig");
const pool_policy = @import("pool_policy.zig");
const pool_topology = @import("pool_topology.zig");

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
    authority,
    active_voter,
};

pub const ControlWriteReady = struct {
    tail_history_digest: [32]u8,
    active_members: [max_member_count]bool,
    active_count: u16,
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

    fn finishOpen(set: *PoolMemberSet, intent: OpenIntent) !PoolMemberSet {
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
        if (intent == .writable and set.control_write_state == null)
            return error.WriteQuorumUnavailable;
        return set.*;
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
        if (history.scan_result.unresolved_tail_damage) return error.JournalNeedsRecovery;
        if (history.scan_result.slot_count - history.scan_result.physical_frontier < 2)
            return error.InsufficientJournalCapacity;
        var selected_authority = try pool_authority.selectAdministrativeRecovery(history);
        selected_authority.administrative_recovery = true;
        set.authority_state = selected_authority;
        set.classifyMembers(.read_only);
        set.control_write_state = .{
            .tail_history_digest = selected_authority.history_digest,
            .active_members = @splat(false),
            .active_count = 1,
        };
        set.control_write_state.?.active_members[0] = true;
        set.statuses[0] = .active_voter;
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

    pub fn memberById(self: *PoolMemberSet, member_id: [16]u8) !*member_api.Member {
        for (self.members[0..self.supplied_count]) |*maybe_member| {
            const member = if (maybe_member.*) |*value| value else continue;
            if (std.mem.eql(u8, &member.header().member_id, &member_id)) return member;
        }
        return error.MemberUnavailable;
    }

    pub fn claimCoordinator(self: *PoolMemberSet) !void {
        if (self.coordinator_state.cmpxchgStrong(0, 1, .acq_rel, .acquire)) |state|
            return if (state == 2) error.MemberSetClosed else error.CoordinatorAlreadyOpen;
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
        };
        self.updateVoterStatuses(previous.topology, active_members);
    }

    pub fn noteCommittedMembership(
        self: *PoolMemberSet,
        record: control_record.Record,
        topology: pool_topology.Topology,
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
        };
        for (0..self.supplied_count) |index| {
            const member = if (self.members[index]) |*value| value else continue;
            if (pool_topology.findMember(&topology, member.header().member_id) == null) {
                self.statuses[index] = .removed;
            } else if (active_members[index]) {
                self.statuses[index] = .active_voter;
            } else {
                self.statuses[index] = .authority;
            }
        }
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
        };
        self.updateVoterStatuses(previous.topology, active_members);
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
        };
        self.updateVoterStatuses(previous.topology, active_members);
    }

    pub fn close(self: *PoolMemberSet) !void {
        if (self.coordinator_state.cmpxchgStrong(0, 2, .acq_rel, .acquire)) |state| {
            if (state == 1) return error.CoordinatorActive;
            return;
        }
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
        self.control_write_state = null;
        if (first_error) |err| return err;
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
            if (intent != .writable or descriptor.control_role != pool_topology.voter_role or
                member.mode() != .writable or member.isFrozen() or history.scan_result.unresolved_tail_damage or
                history.scan_result.journal_full or
                !std.mem.eql(u8, &tail.history_digest, &selected_authority.history_digest)) continue;
            ready.active_members[index] = true;
            ready.active_count += 1;
            self.statuses[index] = .active_voter;
        }
        self.data_access_state = pool_policy.dataAccess(
            selected_authority.layout.protection() catch unreachable,
            available_data_members,
        ) catch .unavailable;
        if (intent == .writable and ready.active_count >= selected_authority.topology.quorum)
            self.control_write_state = ready;
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
            if (descriptor.control_role == pool_topology.voter_role) self.statuses[index] = .stale;
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
    return a.logical_capacity == b.logical_capacity and
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
    if (storages.len == 0 or storages.len > max_member_count) {
        for (storages) |*storage| storage.close(io) catch {};
        return error.InvalidMemberCount;
    }
    var set: PoolMemberSet = .{ .supplied_count = storages.len };
    var consumed_count: usize = 0;
    errdefer {
        set.deinit();
        for (storages[consumed_count..]) |*storage| storage.close(io) catch {};
    }
    for (storages, 0..) |storage, index| {
        consumed_count += 1;
        var member = member_api.openStorage(io, storage, mode) catch |err| {
            set.statuses[index] = .{ .open_failed = err };
            continue;
        };
        try scanMember(allocator, &set, index, &member);
    }
    return set;
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

test "administrative recovery requires capacity for prepare and commit" {
    inline for (.{ 4096, 2 * 4096 }) |control_bytes| {
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
    try createTestPoolWithControlBytes(tmp.dir, "member", .unprotected, 3 * 4096);
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
