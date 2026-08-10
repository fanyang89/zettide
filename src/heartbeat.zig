const std = @import("std");

const pb = @import("control_proto");

pub const max_nodes: usize = 10_000;
pub const max_member_observations: usize = 10_000;
pub const max_members_per_report: usize = 256;
pub const recommended_interval_ms: u32 = 1_000;
pub const stale_after_ms: u32 = 5_000;

const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const Error = std.mem.Allocator.Error || error{
    Inactive,
    TermMismatch,
    InvalidHeartbeat,
    OrderingConflict,
    NodeLimit,
    MemberLimit,
};

pub const ReportResult = struct {
    /// Driver-thread view that must be consumed before another store operation.
    observation: pb.NodeHeartbeat,
    recommended_interval_ms: u32,
    stale_after_ms: u32,
};

pub const GetResult = struct {
    /// Driver-thread view that must be consumed before another store operation.
    observation: pb.NodeHeartbeat,
    freshness: pb.HeartbeatFreshness,
    age_ms: u64,
};

const Limits = struct {
    nodes: usize = max_nodes,
    members: usize = max_member_observations,
};

const Analysis = struct {
    indices: [max_members_per_report]usize,
    fingerprint: Fingerprint,
};

const StoredObservation = struct {
    observation: pb.NodeHeartbeat,
    accepted_at_ms: u64,
    fingerprint: Fingerprint,

    fn init(
        allocator: std.mem.Allocator,
        request: pb.ReportHeartbeatRequest,
        indices: []const usize,
        fingerprint: Fingerprint,
        leader_term: u64,
        accepted_at_ms: u64,
        accepted_at_unix_ms: i64,
    ) !StoredObservation {
        const node_id = try allocator.dupe(u8, request.node_id);
        errdefer allocator.free(node_id);
        var members: std.ArrayList(pb.MemberHeartbeat) = .empty;
        errdefer {
            for (members.items) |*member| member.deinit(allocator);
            members.deinit(allocator);
        }
        try members.ensureTotalCapacity(allocator, indices.len);
        for (indices) |index| {
            members.appendAssumeCapacity(try cloneMember(allocator, request.members.items[index]));
        }
        return .{
            .observation = .{
                .node_id = node_id,
                .incarnation = request.incarnation,
                .sequence = request.sequence,
                .accepted_at_unix_ms = accepted_at_unix_ms,
                .leader_term = leader_term,
                .members = members,
            },
            .accepted_at_ms = accepted_at_ms,
            .fingerprint = fingerprint,
        };
    }

    fn deinit(self: *StoredObservation, allocator: std.mem.Allocator) void {
        allocator.free(self.observation.node_id);
        self.deinitMembers(allocator);
        self.* = undefined;
    }

    fn deinitMembers(self: *StoredObservation, allocator: std.mem.Allocator) void {
        for (self.observation.members.items) |*member| member.deinit(allocator);
        self.observation.members.deinit(allocator);
    }
};

pub const HeartbeatStore = struct {
    allocator: std.mem.Allocator,
    observations: std.StringHashMapUnmanaged(StoredObservation) = .empty,
    member_count: usize = 0,
    active: bool = false,
    term: u64 = 0,
    limits: Limits = .{},

    pub fn init(allocator: std.mem.Allocator) HeartbeatStore {
        return .{ .allocator = allocator };
    }

    fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) HeartbeatStore {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *HeartbeatStore) void {
        self.clearObservations();
        self.observations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn onLeadershipChange(self: *HeartbeatStore, is_leader: bool, term: u64) void {
        self.clearObservations();
        self.active = is_leader;
        self.term = if (is_leader) term else 0;
    }

    pub fn clearObservations(self: *HeartbeatStore) void {
        var iterator = self.observations.valueIterator();
        while (iterator.next()) |observation| observation.deinit(self.allocator);
        self.observations.clearRetainingCapacity();
        self.member_count = 0;
    }

    pub fn report(
        self: *HeartbeatStore,
        request: pb.ReportHeartbeatRequest,
        leader_term: u64,
        accepted_at_ms: u64,
        accepted_at_unix_ms: i64,
    ) Error!ReportResult {
        try self.requireTerm(leader_term);
        const analysis = try analyze(request);
        const existing = self.observations.getPtr(request.node_id);
        if (existing) |current| {
            if (request.incarnation < current.observation.incarnation or
                (request.incarnation == current.observation.incarnation and request.sequence < current.observation.sequence))
            {
                return error.OrderingConflict;
            }
            if (request.incarnation == current.observation.incarnation and request.sequence == current.observation.sequence) {
                if (!std.mem.eql(u8, &analysis.fingerprint, &current.fingerprint)) return error.OrderingConflict;
                return reportResult(current.observation);
            }
        }

        const old_member_count = if (existing) |current| current.observation.members.items.len else 0;
        if (request.members.items.len > self.limits.members -| (self.member_count - old_member_count)) return error.MemberLimit;
        if (existing == null and self.observations.count() >= self.limits.nodes) return error.NodeLimit;

        var replacement = try StoredObservation.init(
            self.allocator,
            request,
            analysis.indices[0..request.members.items.len],
            analysis.fingerprint,
            leader_term,
            accepted_at_ms,
            accepted_at_unix_ms,
        );
        errdefer replacement.deinit(self.allocator);

        if (existing) |current| {
            self.allocator.free(replacement.observation.node_id);
            replacement.observation.node_id = current.observation.node_id;
            current.deinitMembers(self.allocator);
            current.* = replacement;
        } else {
            try self.observations.ensureUnusedCapacity(self.allocator, 1);
            self.observations.putAssumeCapacity(replacement.observation.node_id, replacement);
        }
        self.member_count = self.member_count - old_member_count + request.members.items.len;
        return reportResult(replacement.observation);
    }

    pub fn get(self: *const HeartbeatStore, node_id: []const u8, leader_term: u64, now_ms: u64) Error!?GetResult {
        try self.requireTerm(leader_term);
        if (node_id.len == 0) return error.InvalidHeartbeat;
        const stored = self.observations.get(node_id) orelse return null;
        const age_ms = now_ms -| stored.accepted_at_ms;
        return .{
            .observation = stored.observation,
            .freshness = if (age_ms < stale_after_ms)
                .HEARTBEAT_FRESHNESS_FRESH
            else
                .HEARTBEAT_FRESHNESS_STALE,
            .age_ms = age_ms,
        };
    }

    pub fn observationCount(self: *const HeartbeatStore) usize {
        return self.observations.count();
    }

    pub fn memberObservationCount(self: *const HeartbeatStore) usize {
        return self.member_count;
    }

    fn requireTerm(self: *const HeartbeatStore, leader_term: u64) Error!void {
        if (!self.active) return error.Inactive;
        if (leader_term != self.term) return error.TermMismatch;
    }
};

pub fn validateReport(request: pb.ReportHeartbeatRequest) Error!void {
    _ = try analyze(request);
}

fn reportResult(observation: pb.NodeHeartbeat) ReportResult {
    return .{
        .observation = observation,
        .recommended_interval_ms = recommended_interval_ms,
        .stale_after_ms = stale_after_ms,
    };
}

fn analyze(request: pb.ReportHeartbeatRequest) Error!Analysis {
    if (!validFixedNonzero(request.cluster_id, 16) or
        request.node_id.len == 0 or request.node_id.len > 127 or
        !std.unicode.utf8ValidateSlice(request.node_id) or
        request.incarnation == 0 or request.sequence == 0 or
        request.members.items.len > max_members_per_report)
    {
        return error.InvalidHeartbeat;
    }

    var analysis: Analysis = undefined;
    for (request.members.items, 0..) |member, index| {
        if (!validFixedNonzero(member.member_id, 16) or
            !validFixedNonzero(member.local_set_id, 16) or
            std.mem.eql(u8, member.member_id, member.local_set_id) or
            member.member_slot > std.math.maxInt(u16))
        {
            return error.InvalidHeartbeat;
        }
        switch (member.state) {
            .MEMBER_HEARTBEAT_STATE_PRESENT => {},
            .MEMBER_HEARTBEAT_STATE_UNAVAILABLE => if (member.capacity != null) return error.InvalidHeartbeat,
            else => return error.InvalidHeartbeat,
        }
        if (member.capacity) |capacity| _ = capacityTotal(capacity) catch return error.InvalidHeartbeat;
        analysis.indices[index] = index;
    }
    std.mem.sort(usize, analysis.indices[0..request.members.items.len], request.members.items, memberIndexLessThan);
    if (request.members.items.len > 1) {
        for (analysis.indices[1..request.members.items.len], analysis.indices[0 .. request.members.items.len - 1]) |index, previous| {
            if (std.mem.eql(u8, request.members.items[index].member_id, request.members.items[previous].member_id)) {
                return error.InvalidHeartbeat;
            }
        }
    }
    analysis.fingerprint = semanticFingerprint(request, analysis.indices[0..request.members.items.len]);
    return analysis;
}

fn capacityTotal(capacity: pb.MemberCapacity) error{Overflow}!u64 {
    var total = try std.math.add(u64, capacity.free_extent_count, capacity.allocated_extent_count);
    total = try std.math.add(u64, total, capacity.reserved_extent_count);
    return std.math.add(u64, total, capacity.retired_extent_count);
}

fn cloneMember(allocator: std.mem.Allocator, source: pb.MemberHeartbeat) !pb.MemberHeartbeat {
    const member_id = try allocator.dupe(u8, source.member_id);
    errdefer allocator.free(member_id);
    const local_set_id = try allocator.dupe(u8, source.local_set_id);
    return .{
        .member_id = member_id,
        .local_set_id = local_set_id,
        .member_slot = source.member_slot,
        .state = source.state,
        .capacity = source.capacity,
    };
}

fn semanticFingerprint(request: pb.ReportHeartbeatRequest, indices: []const usize) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, request.cluster_id);
    hashField(&hasher, request.node_id);
    hashInt(&hasher, u64, request.incarnation);
    hashInt(&hasher, u64, request.sequence);
    hashInt(&hasher, u64, indices.len);
    for (indices) |index| {
        const member = request.members.items[index];
        hashField(&hasher, member.member_id);
        hashField(&hasher, member.local_set_id);
        hashInt(&hasher, u32, member.member_slot);
        hashInt(&hasher, i32, @intFromEnum(member.state));
        if (member.capacity) |capacity| {
            hashInt(&hasher, u8, 1);
            hashInt(&hasher, u64, capacity.free_extent_count);
            hashInt(&hasher, u64, capacity.allocated_extent_count);
            hashInt(&hasher, u64, capacity.reserved_extent_count);
            hashInt(&hasher, u64, capacity.retired_extent_count);
        } else {
            hashInt(&hasher, u8, 0);
        }
    }
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
}

fn memberIndexLessThan(members: []pb.MemberHeartbeat, lhs: usize, rhs: usize) bool {
    return std.mem.order(u8, members[lhs].member_id, members[rhs].member_id) == .lt;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .little);
    hasher.update(&length);
    hasher.update(value);
}

fn hashInt(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    hashField(hasher, &encoded);
}

fn validFixedNonzero(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (byte != 0) return true;
    return false;
}

const test_cluster_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_member_id_a = [_]u8{ 0x10, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_member_id_b = [_]u8{ 0x20, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_local_set_id = [_]u8{ 0x40, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

fn testMember(id: []const u8, slot: u32, free: u64) pb.MemberHeartbeat {
    return .{
        .member_id = id,
        .local_set_id = &test_local_set_id,
        .member_slot = slot,
        .state = .MEMBER_HEARTBEAT_STATE_PRESENT,
        .capacity = .{ .free_extent_count = free },
    };
}

fn testRequest(node_id: []const u8, incarnation: u64, sequence: u64, members: []pb.MemberHeartbeat) pb.ReportHeartbeatRequest {
    return .{
        .cluster_id = &test_cluster_id,
        .node_id = node_id,
        .incarnation = incarnation,
        .sequence = sequence,
        .members = .{ .items = members, .capacity = members.len },
    };
}

test "heartbeat ordering replay and canonical member order" {
    const allocator = std.testing.allocator;
    var store = HeartbeatStore.init(allocator);
    defer store.deinit();
    store.onLeadershipChange(true, 7);

    var first_members = [_]pb.MemberHeartbeat{
        testMember(&test_member_id_b, 1, 2),
        testMember(&test_member_id_a, 0, 1),
    };
    const first = try store.report(testRequest("node-a", 1, 1, &first_members), 7, 100, 1_000);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, first.observation.members.items[0].member_id);
    try std.testing.expectEqualSlices(u8, &test_member_id_b, first.observation.members.items[1].member_id);

    var replay_members = [_]pb.MemberHeartbeat{
        testMember(&test_member_id_a, 0, 1),
        testMember(&test_member_id_b, 1, 2),
    };
    const replay = try store.report(testRequest("node-a", 1, 1, &replay_members), 7, 900, 9_000);
    try std.testing.expectEqual(@as(i64, 1_000), replay.observation.accepted_at_unix_ms);
    try std.testing.expectEqual(@as(u64, 100), (try store.get("node-a", 7, 200)).?.age_ms);

    replay_members[0].capacity.?.free_extent_count = 9;
    try std.testing.expectError(error.OrderingConflict, store.report(testRequest("node-a", 1, 1, &replay_members), 7, 200, 2_000));
    replay_members[0].capacity.?.free_extent_count = 1;
    const next = try store.report(testRequest("node-a", 1, 2, &replay_members), 7, 300, 3_000);
    try std.testing.expectEqual(@as(u64, 2), next.observation.sequence);
    try std.testing.expectError(error.OrderingConflict, store.report(testRequest("node-a", 1, 1, &replay_members), 7, 350, 3_500));
    const reincarnated = try store.report(testRequest("node-a", 2, 1, &replay_members), 7, 400, 4_000);
    try std.testing.expectEqual(@as(u64, 2), reincarnated.observation.incarnation);
}

test "heartbeat freshness leadership clearing and term checks" {
    var store = HeartbeatStore.init(std.testing.allocator);
    defer store.deinit();
    var no_members: [0]pb.MemberHeartbeat = .{};
    const request = testRequest("node-a", 1, 1, &no_members);

    try std.testing.expectError(error.Inactive, store.report(request, 1, 100, 1_000));
    store.onLeadershipChange(true, 3);
    try std.testing.expectError(error.TermMismatch, store.report(request, 2, 100, 1_000));
    _ = try store.report(request, 3, 100, 1_000);
    try std.testing.expectEqual(pb.HeartbeatFreshness.HEARTBEAT_FRESHNESS_FRESH, (try store.get("node-a", 3, 5_099)).?.freshness);
    const stale = (try store.get("node-a", 3, 5_100)).?;
    try std.testing.expectEqual(pb.HeartbeatFreshness.HEARTBEAT_FRESHNESS_STALE, stale.freshness);
    try std.testing.expectEqual(@as(u64, stale_after_ms), stale.age_ms);
    try std.testing.expectEqual(@as(u64, 0), (try store.get("node-a", 3, 50)).?.age_ms);

    store.onLeadershipChange(true, 4);
    try std.testing.expectEqual(@as(usize, 0), store.observationCount());
    try std.testing.expectError(error.TermMismatch, store.get("node-a", 3, 200));
    try std.testing.expectEqual(@as(?GetResult, null), try store.get("node-a", 4, 200));
    store.onLeadershipChange(false, 4);
    try std.testing.expectError(error.Inactive, store.get("node-a", 4, 200));
}

test "heartbeat report bounds duplicates states and capacity overflow" {
    var store = HeartbeatStore.initWithLimits(std.testing.allocator, .{ .nodes = 2, .members = 2 });
    defer store.deinit();
    store.onLeadershipChange(true, 1);

    var members = [_]pb.MemberHeartbeat{
        testMember(&test_member_id_a, 0, 1),
        testMember(&test_member_id_b, 1, 1),
    };
    _ = try store.report(testRequest("node-a", 1, 1, &members), 1, 1, 1);
    var duplicate = [_]pb.MemberHeartbeat{ members[0], members[0] };
    try std.testing.expectError(error.InvalidHeartbeat, store.report(testRequest("node-a", 1, 2, &duplicate), 1, 2, 2));
    try std.testing.expectEqual(@as(u64, 1), (try store.get("node-a", 1, 2)).?.observation.sequence);

    var one_member = [_]pb.MemberHeartbeat{testMember(&test_member_id_a, 0, 1)};
    try std.testing.expectError(error.MemberLimit, store.report(testRequest("node-b", 1, 1, &one_member), 1, 2, 2));
    var no_members: [0]pb.MemberHeartbeat = .{};
    _ = try store.report(testRequest("node-b", 1, 1, &no_members), 1, 2, 2);
    try std.testing.expectError(error.NodeLimit, store.report(testRequest("node-c", 1, 1, &no_members), 1, 3, 3));

    var unavailable = testMember(&test_member_id_a, 0, 0);
    unavailable.state = .MEMBER_HEARTBEAT_STATE_UNAVAILABLE;
    var invalid_state = [_]pb.MemberHeartbeat{unavailable};
    try std.testing.expectError(error.InvalidHeartbeat, validateReport(testRequest("node-a", 2, 1, &invalid_state)));
    invalid_state[0].capacity = null;
    try validateReport(testRequest("node-a", 2, 1, &invalid_state));
    invalid_state[0].state = .MEMBER_HEARTBEAT_STATE_UNSPECIFIED;
    try std.testing.expectError(error.InvalidHeartbeat, validateReport(testRequest("node-a", 2, 1, &invalid_state)));
    invalid_state[0] = testMember(&test_member_id_a, 0, std.math.maxInt(u64));
    invalid_state[0].capacity.?.allocated_extent_count = 1;
    try std.testing.expectError(error.InvalidHeartbeat, validateReport(testRequest("node-a", 2, 1, &invalid_state)));

    var too_many: [max_members_per_report + 1]pb.MemberHeartbeat = undefined;
    try std.testing.expectError(error.InvalidHeartbeat, validateReport(testRequest("node-a", 2, 1, &too_many)));
}

fn checkAtomicReplacement(allocator: std.mem.Allocator) !void {
    var store = HeartbeatStore.init(allocator);
    defer store.deinit();
    store.onLeadershipChange(true, 1);
    var first_members = [_]pb.MemberHeartbeat{testMember(&test_member_id_a, 0, 1)};
    _ = store.report(testRequest("node-a", 1, 1, &first_members), 1, 10, 100) catch |err| return err;

    var replacement_members = [_]pb.MemberHeartbeat{
        testMember(&test_member_id_a, 0, 2),
        testMember(&test_member_id_b, 1, 3),
    };
    _ = store.report(testRequest("node-a", 1, 2, &replacement_members), 1, 20, 200) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        const old = (try store.get("node-a", 1, 20)).?;
        try std.testing.expectEqual(@as(u64, 1), old.observation.sequence);
        try std.testing.expectEqual(@as(i64, 100), old.observation.accepted_at_unix_ms);
        try std.testing.expectEqual(@as(usize, 1), store.memberObservationCount());
        return err;
    };
    try std.testing.expectEqual(@as(u64, 2), (try store.get("node-a", 1, 20)).?.observation.sequence);
}

test "heartbeat replacement is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAtomicReplacement, .{});
}
