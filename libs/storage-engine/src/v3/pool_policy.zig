const std = @import("std");

pub const replica_count: u16 = 3;
pub const replica_durable_write_count: u16 = 2;

pub const ControlPolicy = struct {
    voter_count: u16,
    write_quorum: u16,
};

pub const ErasureCode = struct {
    data_shards: u16,
    parity_shards: u16,

    pub fn width(self: ErasureCode) !u16 {
        if (self.data_shards == 0 or self.parity_shards == 0)
            return error.InvalidErasureCodeProfile;
        return std.math.add(u16, self.data_shards, self.parity_shards) catch
            return error.InvalidErasureCodeProfile;
    }
};

pub const Protection = union(enum) {
    unprotected,
    replicated,
    erasure_coded: ErasureCode,

    pub fn validate(self: Protection) !void {
        if (self == .erasure_coded) _ = try self.erasure_coded.width();
    }

    pub fn fullWidth(self: Protection) !u16 {
        return switch (self) {
            .unprotected => 1,
            .replicated => replica_count,
            .erasure_coded => |profile| profile.width(),
        };
    }

    pub fn readThreshold(self: Protection) !u16 {
        return switch (self) {
            .unprotected, .replicated => 1,
            .erasure_coded => |profile| blk: {
                _ = try profile.width();
                break :blk profile.data_shards;
            },
        };
    }

    pub fn durableWriteThreshold(self: Protection) !u16 {
        return switch (self) {
            .unprotected => 1,
            .replicated => replica_durable_write_count,
            // Committing every shard preserves parity tolerance immediately after acknowledgement.
            .erasure_coded => |profile| profile.width(),
        };
    }
};

pub const DataAccess = enum {
    read_write,
    read_only,
    unavailable,
};

pub const Operation = enum {
    user_write,
    maintenance_write,
};

pub fn controlPolicy(pool_member_count: usize) !ControlPolicy {
    if (pool_member_count == 0 or pool_member_count > std.math.maxInt(u16))
        return error.InvalidPoolMemberCount;
    return switch (pool_member_count) {
        1 => .{ .voter_count = 1, .write_quorum = 1 },
        2 => .{ .voter_count = 2, .write_quorum = 2 },
        else => .{ .voter_count = 3, .write_quorum = 2 },
    };
}

pub fn dataAccess(protection: Protection, active_data_members: usize) !DataAccess {
    const full_width = try protection.fullWidth();
    if (active_data_members >= full_width) return .read_write;
    if (active_data_members >= try protection.readThreshold()) return .read_only;
    return .unavailable;
}

pub fn operationAllowed(control_write_ready: bool, access: DataAccess, operation: Operation) bool {
    if (!control_write_ready or access == .unavailable) return false;
    return switch (operation) {
        .user_write => access == .read_write,
        .maintenance_write => true,
    };
}

test "control policy scales from one member to a fixed three-voter group" {
    try std.testing.expectError(error.InvalidPoolMemberCount, controlPolicy(0));
    try std.testing.expectEqual(ControlPolicy{ .voter_count = 1, .write_quorum = 1 }, try controlPolicy(1));
    try std.testing.expectEqual(ControlPolicy{ .voter_count = 2, .write_quorum = 2 }, try controlPolicy(2));
    try std.testing.expectEqual(ControlPolicy{ .voter_count = 3, .write_quorum = 2 }, try controlPolicy(3));
    try std.testing.expectEqual(ControlPolicy{ .voter_count = 3, .write_quorum = 2 }, try controlPolicy(64));
    try std.testing.expectError(error.InvalidPoolMemberCount, controlPolicy(@as(usize, std.math.maxInt(u16)) + 1));
}

test "protection profiles expose stable read write and width policies" {
    const unprotected: Protection = .unprotected;
    try std.testing.expectEqual(@as(u16, 1), try unprotected.fullWidth());
    try std.testing.expectEqual(@as(u16, 1), try unprotected.readThreshold());
    try std.testing.expectEqual(@as(u16, 1), try unprotected.durableWriteThreshold());

    const replicated: Protection = .replicated;
    try std.testing.expectEqual(@as(u16, 3), try replicated.fullWidth());
    try std.testing.expectEqual(@as(u16, 1), try replicated.readThreshold());
    try std.testing.expectEqual(@as(u16, 2), try replicated.durableWriteThreshold());

    const ec: Protection = .{ .erasure_coded = .{ .data_shards = 4, .parity_shards = 2 } };
    try std.testing.expectEqual(@as(u16, 6), try ec.fullWidth());
    try std.testing.expectEqual(@as(u16, 4), try ec.readThreshold());
    try std.testing.expectEqual(@as(u16, 6), try ec.durableWriteThreshold());

    const invalid: Protection = .{ .erasure_coded = .{ .data_shards = 0, .parity_shards = 2 } };
    try std.testing.expectError(error.InvalidErasureCodeProfile, invalid.validate());
}

test "forced removal below protection width makes user data read only" {
    try std.testing.expectEqual(.read_write, try dataAccess(.replicated, 3));
    try std.testing.expectEqual(.read_only, try dataAccess(.replicated, 2));
    try std.testing.expectEqual(.read_only, try dataAccess(.replicated, 1));
    try std.testing.expectEqual(.unavailable, try dataAccess(.replicated, 0));

    const ec: Protection = .{ .erasure_coded = .{ .data_shards = 4, .parity_shards = 2 } };
    try std.testing.expectEqual(.read_write, try dataAccess(ec, 6));
    try std.testing.expectEqual(.read_only, try dataAccess(ec, 5));
    try std.testing.expectEqual(.read_only, try dataAccess(ec, 4));
    try std.testing.expectEqual(.unavailable, try dataAccess(ec, 3));
}

test "read-only pools permit recovery but reject user writes" {
    try std.testing.expect(operationAllowed(true, .read_write, .user_write));
    try std.testing.expect(!operationAllowed(true, .read_only, .user_write));
    try std.testing.expect(operationAllowed(true, .read_only, .maintenance_write));
    try std.testing.expect(!operationAllowed(false, .read_only, .maintenance_write));
    try std.testing.expect(!operationAllowed(true, .unavailable, .maintenance_write));
}
