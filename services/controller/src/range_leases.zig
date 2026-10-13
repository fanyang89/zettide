const std = @import("std");
const pb = @import("controller_proto");
const wire = @import("protobuf_wire.zig");
const schema = @import("state_machine/schema.zig");
const contract = @import("zettide_data_service_contracts").range_lease;

pub const max_leases = contract.max_leases;
pub const duration_ms = contract.duration_ms;
pub const Lease = struct {
    lease_id: [36]u8,
    volume_id: [36]u8,
    holder_node_id: [36]u8,
    holder_boot_id: [16]u8,
    offset_bytes: u64,
    length_bytes: u64,
    mode: pb.RangeLeaseMode,
    token_revision: u64,
    resource_version: u64,
    state: pb.RangeLeaseState,
    created_revision: u64,

    fn fromRequest(request: pb.RangeLeaseRequest, revision: u64) Lease {
        return .{ .lease_id = request.lease_id[0..36].*, .volume_id = request.volume_id[0..36].*, .holder_node_id = request.holder_node_id[0..36].*, .holder_boot_id = request.holder_boot_id[0..16].*, .offset_bytes = request.offset_bytes, .length_bytes = request.length_bytes, .mode = request.mode, .token_revision = revision, .resource_version = revision, .created_revision = revision, .state = .RANGE_LEASE_STATE_ACTIVE };
    }
    pub fn proto(self: *const Lease) pb.RangeLease {
        return .{ .lease_id = &self.lease_id, .volume_id = &self.volume_id, .holder_node_id = &self.holder_node_id, .holder_boot_id = &self.holder_boot_id, .offset_bytes = self.offset_bytes, .length_bytes = self.length_bytes, .mode = self.mode, .token_revision = self.token_revision, .resource_version = self.resource_version, .state = self.state, .created_revision = self.created_revision, .duration_ms = duration_ms };
    }
    fn matches(self: Lease, request: pb.RangeLeaseRequest) bool {
        return std.mem.eql(u8, &self.volume_id, request.volume_id) and std.mem.eql(u8, &self.holder_node_id, request.holder_node_id) and
            std.mem.eql(u8, &self.holder_boot_id, request.holder_boot_id) and self.offset_bytes == request.offset_bytes and self.length_bytes == request.length_bytes and self.mode == request.mode;
    }
};

pub const Context = struct { volume_available: bool, volume_size: u64, node_exists: bool };
pub const Outcome = struct {
    code: pb.RangeLeaseCode,
    lease: ?Lease = null,
    changed: bool = false,
    pub fn proto(self: *const Outcome) pb.RangeLeaseApplyResponse {
        return .{ .code = self.code, .lease = if (self.lease) |*lease| lease.proto() else null };
    }
};

/// Entries, including terminal tombstones, are reconstructed from retained
/// Raft request records on snapshot restore. No clock or external I/O in apply.
pub const Store = struct {
    leases: std.AutoHashMapUnmanaged([36]u8, Lease) = .empty,
    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.leases.deinit(allocator);
    }
    pub fn hasBlocking(self: *const Store, volume_id: []const u8) bool {
        var iterator = self.leases.valueIterator();
        while (iterator.next()) |lease| if (lease.state != .RANGE_LEASE_STATE_REVOKED and std.mem.eql(u8, &lease.volume_id, volume_id)) return true;
        return false;
    }
    pub fn digest(self: *const Store, allocator: std.mem.Allocator) ![32]u8 {
        const keys = try allocator.alloc([36]u8, self.leases.count());
        defer allocator.free(keys);
        var iterator = self.leases.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |key| : (index += 1) keys[index] = key.*;
        std.mem.sort([36]u8, keys, {}, struct {
            fn lessThan(_: void, a: [36]u8, b: [36]u8) bool {
                return std.mem.lessThan(u8, &a, &b);
            }
        }.lessThan);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zettide/range-lease/snapshot/v1");
        for (keys) |key| {
            const lease = self.leases.get(key).?;
            hash.update(&lease.lease_id);
            hash.update(&lease.volume_id);
            hash.update(&lease.holder_node_id);
            hash.update(&lease.holder_boot_id);
            for ([_]u64{ lease.offset_bytes, lease.length_bytes, @intCast(@intFromEnum(lease.mode)), lease.token_revision, lease.resource_version, @intCast(@intFromEnum(lease.state)), lease.created_revision, duration_ms }) |value| {
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, value, .little);
                hash.update(&bytes);
            }
        }
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }

    pub fn evaluate(self: *const Store, command: pb.RangeLeaseCommand, context: Context, revision: u64) Outcome {
        const request = command.request.?;
        const existing = self.leases.get(request.lease_id[0..36].*);
        if (command.operation == .RANGE_LEASE_OPERATION_ACQUIRE) {
            if (existing != null) return .{ .code = .RANGE_LEASE_CODE_CONFLICT };
            if (!context.volume_available or !context.node_exists) return .{ .code = .RANGE_LEASE_CODE_NOT_FOUND };
            if (!contract.validRange(request.offset_bytes, request.length_bytes, context.volume_size)) return .{ .code = .RANGE_LEASE_CODE_OUT_OF_RANGE };
            if (self.leases.count() >= max_leases) return .{ .code = .RANGE_LEASE_CODE_RESOURCE_LIMIT };
            var iterator = self.leases.valueIterator();
            while (iterator.next()) |lease| {
                if (lease.state == .RANGE_LEASE_STATE_REVOKED or !std.mem.eql(u8, &lease.volume_id, request.volume_id)) continue;
                if (contract.conflicts(mode(lease.mode), lease.offset_bytes, lease.length_bytes, mode(request.mode), request.offset_bytes, request.length_bytes)) return .{ .code = .RANGE_LEASE_CODE_CONFLICT };
            }
            return .{ .code = .RANGE_LEASE_CODE_OK, .lease = Lease.fromRequest(request, revision), .changed = true };
        }
        var lease = existing orelse return .{ .code = .RANGE_LEASE_CODE_NOT_FOUND };
        if (!lease.matches(request)) return .{ .code = .RANGE_LEASE_CODE_BINDING_MISMATCH };
        if (lease.resource_version != request.expected_resource_version) return .{ .code = .RANGE_LEASE_CODE_VERSION_CONFLICT };
        switch (command.operation) {
            .RANGE_LEASE_OPERATION_RENEW => {
                if (lease.state != .RANGE_LEASE_STATE_ACTIVE) return .{ .code = .RANGE_LEASE_CODE_INVALID_STATE };
                lease.token_revision = revision;
            },
            .RANGE_LEASE_OPERATION_REVOKE => {
                if (lease.state == .RANGE_LEASE_STATE_REVOKED) return .{ .code = .RANGE_LEASE_CODE_INVALID_STATE };
                if (lease.state == .RANGE_LEASE_STATE_REVOKING) return .{ .code = .RANGE_LEASE_CODE_OK, .lease = lease };
                lease.state = .RANGE_LEASE_STATE_REVOKING;
            },
            .RANGE_LEASE_OPERATION_COMPLETE_REVOKE => {
                if (lease.state != .RANGE_LEASE_STATE_REVOKING) return .{ .code = .RANGE_LEASE_CODE_INVALID_STATE };
                lease.state = .RANGE_LEASE_STATE_REVOKED;
            },
            else => unreachable,
        }
        lease.resource_version = revision;
        return .{ .code = .RANGE_LEASE_CODE_OK, .lease = lease, .changed = true };
    }
    pub fn reserve(self: *Store, allocator: std.mem.Allocator, outcome: Outcome) !void {
        if (outcome.changed and !self.leases.contains(outcome.lease.?.lease_id)) try self.leases.ensureUnusedCapacity(allocator, 1);
    }
    pub fn commit(self: *Store, outcome: Outcome) void {
        if (outcome.changed) self.leases.putAssumeCapacity(outcome.lease.?.lease_id, outcome.lease.?);
    }
};

fn mode(value: pb.RangeLeaseMode) contract.Mode {
    return if (value == .RANGE_LEASE_MODE_READ) .read else .write;
}

pub fn validate(command: pb.RangeLeaseCommand) !void {
    const request = command.request orelse return error.InvalidWire;
    if (!schema.validText(request.request_id, schema.max_request_id_bytes, false) or
        !schema.validUuidV7(request.lease_id) or !schema.validUuidV7(request.volume_id) or !schema.validUuidV7(request.holder_node_id) or
        !schema.validFixedNonzero(request.holder_boot_id, 16) or !contract.validRange(request.offset_bytes, request.length_bytes, std.math.maxInt(u64)) or
        (request.mode != .RANGE_LEASE_MODE_READ and request.mode != .RANGE_LEASE_MODE_WRITE)) return error.InvalidWire;
    switch (command.operation) {
        .RANGE_LEASE_OPERATION_ACQUIRE => if (request.expected_resource_version != 0) return error.InvalidWire,
        .RANGE_LEASE_OPERATION_RENEW, .RANGE_LEASE_OPERATION_REVOKE, .RANGE_LEASE_OPERATION_COMPLETE_REVOKE => if (request.expected_resource_version == 0) return error.InvalidWire,
        else => return error.InvalidWire,
    }
}

pub fn preflightRequest(bytes: []const u8) wire.Error!void {
    if (bytes.len > 1024) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = bytes };
    var seen: [10]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 9 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !schema.validText(try cursor.readBytes(schema.max_request_id_bytes), schema.max_request_id_bytes, false)) return error.InvalidWire,
            2...4 => if (field.wire_type != 2 or !schema.validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            5 => if (field.wire_type != 2 or !schema.validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            6...9 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4, 5, 7, 8 }) |index| if (!seen[index]) return error.InvalidWire;
}
pub fn preflightCommand(bytes: []const u8) wire.Error!void {
    if (bytes.len > 1100) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = bytes };
    var seen: [3]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 2 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        if (field.number == 1) {
            if (field.wire_type != 2) return error.InvalidWire;
            try preflightRequest(try cursor.readBytes(1024));
        } else {
            if (field.wire_type != 0) return error.InvalidWire;
            const operation = try cursor.readVarint();
            if (operation < 1 or operation > 4) return error.InvalidWire;
        }
    }
    if (!seen[1] or !seen[2]) return error.InvalidWire;
}

pub fn preflightResponse(bytes: []const u8) wire.Error!void {
    if (bytes.len > 1024) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = bytes };
    var seen: [3]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 2 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        if (field.number == 1) {
            if (field.wire_type != 0) return error.InvalidWire;
            const code = try cursor.readVarint();
            if (code < 1 or code > 9) return error.InvalidWire;
        } else {
            if (field.wire_type != 2) return error.InvalidWire;
            var lease = wire.Cursor{ .bytes = try cursor.readBytes(512) };
            var fields: [13]bool = @splat(false);
            while (try lease.next()) |part| {
                if (part.number > 12 or fields[part.number]) return error.InvalidWire;
                fields[part.number] = true;
                if (part.number <= 4) {
                    if (part.wire_type != 2) return error.InvalidWire;
                    const value = try lease.readBytes(36);
                    if (part.number <= 3) {
                        if (!schema.validUuidV7(value)) return error.InvalidWire;
                    } else if (!schema.validFixedNonzero(value, 16)) return error.InvalidWire;
                } else {
                    if (part.wire_type != 0) return error.InvalidWire;
                    _ = try lease.readVarint();
                }
            }
        }
    }
    if (!seen[1]) return error.InvalidWire;
}

pub fn preflightQuery(bytes: []const u8, list: bool) wire.Error!void {
    if (bytes.len > 128) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = bytes };
    var seen: [4]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > (if (list) @as(u32, 3) else 1) or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        if (field.number <= 2) {
            if (field.wire_type != 2 or !schema.validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
        } else if (field.wire_type != 0 or try cursor.readVarint() > 1000) return error.InvalidWire;
    }
    if (!seen[1]) return error.InvalidWire;
}
