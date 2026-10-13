const std = @import("std");
const pb = @import("controller_proto");
const leases = @import("range_leases.zig");
const machine = @import("state_machine.zig");
const submitter = @import("reconciler.zig").CommandSubmitter;

/// Opt-in storage integration. Success must cover EVERY read/write target,
/// including old routes and durable replay. New routes must inherit the fence
/// before publication. A holder-local gate is not a valid implementation.
/// This trusted adapter must reject unsupported/unfenced payload paths.
pub const Fencer = struct {
    context: *anyopaque,
    fence_all: *const fn (*anyopaque, leases.Lease) anyerror!leases.Lease,
    /// Thread-safe and promptly unblocks an in-flight fence during shutdown.
    cancel: *const fn (*anyopaque) void,
};

pub const Action = struct {
    lease: leases.Lease,
    operation: pb.RangeLeaseOperation,

    pub fn execute(self: Action, allocator: std.mem.Allocator, fencer: Fencer, commands: submitter) !void {
        if (self.operation == .RANGE_LEASE_OPERATION_COMPLETE_REVOKE) {
            const receipt = try fencer.fence_all(fencer.context, self.lease);
            if (!std.meta.eql(receipt, self.lease)) return error.FenceReceiptMismatch;
        }
        // Bind retries to the observed version and phase. A renewal racing the
        // expiry command loses neither its deadline nor its grant: CAS rejects
        // the old command. Unknown proposal outcomes replay the same request.
        var id_buffer: [127]u8 = undefined;
        const request_id = try std.fmt.bufPrint(&id_buffer, "range-reaper/{s}/{d}/{d}", .{ self.lease.lease_id, self.lease.resource_version, @intFromEnum(self.operation) });
        const encoded = try machine.encodeRangeLeaseCommand(allocator, .{ .operation = self.operation, .request = .{
            .request_id = request_id,
            .lease_id = &self.lease.lease_id,
            .volume_id = &self.lease.volume_id,
            .holder_node_id = &self.lease.holder_node_id,
            .holder_boot_id = &self.lease.holder_boot_id,
            .offset_bytes = self.lease.offset_bytes,
            .length_bytes = self.lease.length_bytes,
            .mode = self.lease.mode,
            .expected_resource_version = self.lease.resource_version,
        } });
        defer allocator.free(encoded);
        const response_bytes = try commands.vtable.submit(commands.context, allocator, encoded);
        defer allocator.free(response_bytes);
        var reader: std.Io.Reader = .fixed(response_bytes);
        var response = try pb.RangeLeaseApplyResponse.decode(&reader, allocator);
        defer response.deinit(allocator);
        switch (response.code) {
            .RANGE_LEASE_CODE_OK, .RANGE_LEASE_CODE_VERSION_CONFLICT, .RANGE_LEASE_CODE_INVALID_STATE => {},
            else => return error.RangeReaperApplyFailed,
        }
    }
};

const Observation = struct { revision: u64, deadline: u64 };

/// Called only on the Raft driver following ReadIndex. Time never enters apply.
/// A new leader/restart waits a complete TTL for observed ACTIVE leases. This
/// delays reclamation; it does not extend holder admission or skip a fence.
pub const Reaper = struct {
    allocator: std.mem.Allocator,
    observations: std.AutoHashMapUnmanaged([36]u8, Observation) = .empty,
    term: u64 = 0,
    last_now: u64 = 0,
    cursor: [36]u8 = @splat(0),

    pub fn deinit(self: *Reaper) void {
        self.observations.deinit(self.allocator);
    }

    pub fn plan(self: *Reaper, records: []const leases.Lease, term: u64, now_ms: u64) !?Action {
        if (term == 0) return error.InvalidTerm;
        if (term != self.term or now_ms < self.last_now) {
            self.observations.clearRetainingCapacity();
            self.cursor = @splat(0);
        }
        self.term = term;
        self.last_now = now_ms;
        var first: ?Action = null;
        var next: ?Action = null;
        for (records) |record| {
            if (record.state == .RANGE_LEASE_STATE_REVOKED) {
                _ = self.observations.remove(record.lease_id);
                continue;
            }
            if (record.state == .RANGE_LEASE_STATE_ACTIVE) {
                const observed = self.observations.get(record.lease_id);
                if (observed == null or observed.?.revision != record.token_revision) {
                    if (observed == null and self.observations.count() >= leases.max_leases) return error.LeaseLimit;
                    try self.observations.put(self.allocator, record.lease_id, .{ .revision = record.token_revision, .deadline = try std.math.add(u64, now_ms, leases.duration_ms) });
                    continue;
                }
                if (now_ms < observed.?.deadline) continue;
            } else if (record.state != .RANGE_LEASE_STATE_REVOKING) return error.InvalidLeaseState;
            const action = Action{ .lease = record, .operation = if (record.state == .RANGE_LEASE_STATE_ACTIVE) .RANGE_LEASE_OPERATION_REVOKE else .RANGE_LEASE_OPERATION_COMPLETE_REVOKE };
            if (first == null or less(record.lease_id, first.?.lease.lease_id)) first = action;
            if (less(self.cursor, record.lease_id) and (next == null or less(record.lease_id, next.?.lease.lease_id))) next = action;
        }
        const chosen = next orelse first orelse return null;
        self.cursor = chosen.lease.lease_id;
        return chosen;
    }
    fn less(a: [36]u8, b: [36]u8) bool {
        return std.mem.lessThan(u8, &a, &b);
    }
};

fn testLease() leases.Lease {
    return .{ .lease_id = "0198f54d-5c2a-7000-8000-000000000301".*, .volume_id = "0198f54d-5c2a-7000-8000-000000000302".*, .holder_node_id = "0198f54d-5c2a-7000-8000-000000000303".*, .holder_boot_id = @splat(1), .offset_bytes = 0, .length_bytes = 4096, .mode = .RANGE_LEASE_MODE_READ, .created_revision = 10, .token_revision = 10, .resource_version = 10, .state = .RANGE_LEASE_STATE_ACTIVE };
}

test "expiry observes renewal and starts conservatively after term or clock changes" {
    var reaper = Reaper{ .allocator = std.testing.allocator };
    defer reaper.deinit();
    var records = [_]leases.Lease{testLease()};
    try std.testing.expect(try reaper.plan(&records, 1, 100) == null);
    try std.testing.expect(try reaper.plan(&records, 1, 30_099) == null);
    const expired = (try reaper.plan(&records, 1, 30_100)).?;
    try std.testing.expectEqual(pb.RangeLeaseOperation.RANGE_LEASE_OPERATION_REVOKE, expired.operation);
    records[0].token_revision = 11;
    records[0].resource_version = 11;
    try std.testing.expect(try reaper.plan(&records, 1, 30_101) == null);
    try std.testing.expect(try reaper.plan(&records, 2, 60_102) == null);
    try std.testing.expect(try reaper.plan(&records, 2, 1) == null);
    try std.testing.expect(try reaper.plan(&records, 2, 30_000) == null);
    try std.testing.expect(try reaper.plan(&records, 2, 30_001) != null);
    records[0].state = .RANGE_LEASE_STATE_REVOKING;
    records[0].resource_version = 12;
    try std.testing.expectEqual(pb.RangeLeaseOperation.RANGE_LEASE_OPERATION_COMPLETE_REVOKE, (try reaper.plan(&records, 3, 1)).?.operation);
}

test "an unavailable fence does not starve another expired lease" {
    var reaper = Reaper{ .allocator = std.testing.allocator };
    defer reaper.deinit();
    var records = [_]leases.Lease{ testLease(), testLease() };
    for (&records) |*record| {
        record.state = .RANGE_LEASE_STATE_REVOKING;
        record.resource_version = 11;
    }
    records[1].lease_id[35] = '9';
    try std.testing.expectEqual(records[0].lease_id, (try reaper.plan(&records, 1, 0)).?.lease.lease_id);
    try std.testing.expectEqual(records[1].lease_id, (try reaper.plan(&records, 1, 1)).?.lease.lease_id);
    try std.testing.expectEqual(records[0].lease_id, (try reaper.plan(&records, 1, 2)).?.lease.lease_id);
}
