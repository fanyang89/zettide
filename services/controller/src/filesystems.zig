const std = @import("std");
const pb = @import("controller_proto");
const schema = @import("state_machine/schema.zig");
const wire = @import("protobuf_wire.zig");

pub const max_filesystems = 10_000;
pub const DigestVersion = enum { v1, v2, v3 };
pub const Record = struct {
    id: [36]u8,
    pool_id: [36]u8,
    name_bytes: [schema.max_name_bytes]u8 = @splat(0),
    name_len: u16,
    description_bytes: [schema.max_description_bytes]u8 = @splat(0),
    description_len: u16 = 0,
    name_profile: pb.FilesystemNameProfile,
    created_revision: u64,
    resource_version: u64,
    deleted_revision: u64 = 0,
    authority_epoch: u64 = 0,
    candidate_node_id: ?[36]u8 = null,
    candidate_boot_id: [16]u8 = @splat(0),
    backend_digest: [32]u8 = @splat(0),
    placement_generation: u64 = 0,

    pub fn proto(self: *const Record) pb.Filesystem {
        return .{ .backend_digest = if (self.placement_generation != 0) &self.backend_digest else "", .placement_generation = self.placement_generation, .authority_state = if (self.placement_generation != 0) .FILESYSTEM_AUTHORITY_STATE_PREPARING else if (self.candidate_node_id != null) .FILESYSTEM_AUTHORITY_STATE_CANDIDATE else .FILESYSTEM_AUTHORITY_STATE_NONE, .authority_epoch = self.authority_epoch, .candidate_node_id = if (self.candidate_node_id) |*id| id else "", .candidate_boot_id = if (self.candidate_node_id != null) &self.candidate_boot_id else "", .id = &self.id, .pool_id = &self.pool_id, .name = self.name_bytes[0..self.name_len], .description = self.description_bytes[0..self.description_len], .name_profile = self.name_profile, .backend_kind = .FILESYSTEM_BACKEND_KIND_BLOB, .format_version = 1, .lifecycle_state = if (self.deleted_revision == 0) .FILESYSTEM_LIFECYCLE_STATE_PROVISIONING else .FILESYSTEM_LIFECYCLE_STATE_DELETED, .created_revision = self.created_revision, .resource_version = self.resource_version, .deleted_revision = self.deleted_revision };
    }
    fn describe(self: *Record, description: []const u8) void {
        @memset(&self.description_bytes, 0);
        @memcpy(self.description_bytes[0..description.len], description);
        self.description_len = @intCast(description.len);
    }
};
pub const Outcome = struct {
    code: pb.FilesystemCode,
    record: ?Record = null,
    changed: bool = false,
    pub fn proto(self: *const Outcome) pb.FilesystemApplyResponse {
        return .{ .code = self.code, .filesystem = if (self.record) |*record| record.proto() else null };
    }
};

/// Control-plane intent only, never evidence of physical readiness. PREPARING
/// pins a backend and owner irreversibly until a future fenced cleanup protocol.
/// Candidates alone must not perform external work.
pub const Store = struct {
    records: std.AutoHashMapUnmanaged([36]u8, Record) = .empty,
    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
    }
    pub fn blocksPoolAt(self: *const Store, pool_id: []const u8, revision: u64) bool {
        var it = self.records.valueIterator();
        while (it.next()) |record| {
            if (std.mem.eql(u8, &record.pool_id, pool_id) and record.created_revision < revision and
                (record.deleted_revision == 0 or record.deleted_revision >= revision)) return true;
        }
        return false;
    }
    pub fn evaluate(self: *const Store, command: pb.FilesystemCommand, pool_available: bool, node_available: bool, revision: u64) Outcome {
        const request = command.request.?;
        const existing = self.records.get(request.filesystem_id[0..36].*);
        if (command.operation == .FILESYSTEM_OPERATION_CREATE) {
            if (existing != null) return .{ .code = .FILESYSTEM_CODE_CONFLICT };
            if (!pool_available) return .{ .code = .FILESYSTEM_CODE_NOT_FOUND };
            if (self.records.count() >= max_filesystems) return .{ .code = .FILESYSTEM_CODE_RESOURCE_LIMIT };
            var it = self.records.valueIterator();
            while (it.next()) |record| {
                if (record.deleted_revision == 0 and std.mem.eql(u8, &record.pool_id, request.pool_id) and
                    std.mem.eql(u8, record.name_bytes[0..record.name_len], request.name)) return .{ .code = .FILESYSTEM_CODE_CONFLICT };
            }
            var record = Record{ .id = request.filesystem_id[0..36].*, .pool_id = request.pool_id[0..36].*, .name_len = @intCast(request.name.len), .name_profile = request.name_profile, .created_revision = revision, .resource_version = revision };
            @memcpy(record.name_bytes[0..request.name.len], request.name);
            record.describe(request.description);
            return .{ .code = .FILESYSTEM_CODE_OK, .record = record, .changed = true };
        }
        var record = existing orelse return .{ .code = .FILESYSTEM_CODE_NOT_FOUND };
        if (record.deleted_revision != 0) return .{ .code = .FILESYSTEM_CODE_NOT_FOUND };
        if (record.resource_version != request.expected_resource_version) return .{ .code = .FILESYSTEM_CODE_VERSION_CONFLICT };
        switch (command.operation) {
            .FILESYSTEM_OPERATION_UPDATE => record.describe(request.description),
            .FILESYSTEM_OPERATION_DELETE => {
                if (record.candidate_node_id != null or record.placement_generation != 0) return .{ .code = .FILESYSTEM_CODE_INVALID_STATE };
                record.deleted_revision = revision;
            },
            .FILESYSTEM_OPERATION_PROPOSE_AUTHORITY => {
                if (record.candidate_node_id != null or record.placement_generation != 0) return .{ .code = .FILESYSTEM_CODE_INVALID_STATE };
                if (request.expected_authority_epoch != record.authority_epoch) return .{ .code = .FILESYSTEM_CODE_VERSION_CONFLICT };
                if (!node_available) return .{ .code = .FILESYSTEM_CODE_NOT_FOUND };
                if (revision <= record.authority_epoch) return .{ .code = .FILESYSTEM_CODE_INVALID_STATE };
                record.authority_epoch = revision;
                record.candidate_node_id = request.holder_node_id[0..36].*;
                record.candidate_boot_id = request.holder_boot_id[0..16].*;
            },
            .FILESYSTEM_OPERATION_CANCEL_AUTHORITY, .FILESYSTEM_OPERATION_BEGIN_PREPARATION => {
                if (record.placement_generation != 0) return .{ .code = .FILESYSTEM_CODE_INVALID_STATE };
                const node = record.candidate_node_id orelse return .{ .code = .FILESYSTEM_CODE_INVALID_STATE };
                if (request.expected_authority_epoch != record.authority_epoch or
                    !std.mem.eql(u8, &node, request.holder_node_id) or
                    !std.mem.eql(u8, &record.candidate_boot_id, request.holder_boot_id)) return .{ .code = .FILESYSTEM_CODE_INVALID_STATE };
                if (command.operation == .FILESYSTEM_OPERATION_BEGIN_PREPARATION) {
                    if (revision <= record.resource_version) return .{ .code = .FILESYSTEM_CODE_INVALID_STATE };
                    // A canonical backend identity is exclusive across logical
                    // Pools too. Hash uniqueness is not physical verification.
                    var it = self.records.valueIterator();
                    while (it.next()) |other| {
                        if (other.placement_generation != 0 and std.mem.eql(u8, &other.backend_digest, request.backend_digest)) return .{ .code = .FILESYSTEM_CODE_CONFLICT };
                    }
                    record.backend_digest = request.backend_digest[0..32].*;
                    record.placement_generation = revision;
                } else {
                    record.candidate_node_id = null;
                    record.candidate_boot_id = @splat(0);
                }
            },
            else => unreachable,
        }
        record.resource_version = revision;
        return .{ .code = .FILESYSTEM_CODE_OK, .record = record, .changed = true };
    }
    pub fn reserve(self: *Store, allocator: std.mem.Allocator, outcome: Outcome) !void {
        if (outcome.changed and !self.records.contains(outcome.record.?.id)) try self.records.ensureUnusedCapacity(allocator, 1);
    }
    pub fn commit(self: *Store, outcome: Outcome) void {
        if (outcome.changed) self.records.putAssumeCapacity(outcome.record.?.id, outcome.record.?);
    }
    pub fn list(self: *const Store, allocator: std.mem.Allocator, pool_id: []const u8, after: []const u8, limit: usize) ![]Record {
        var result: std.ArrayList(Record) = .empty;
        errdefer result.deinit(allocator);
        var it = self.records.valueIterator();
        while (it.next()) |record| {
            if (record.deleted_revision == 0 and std.mem.eql(u8, &record.pool_id, pool_id) and
                (after.len == 0 or std.mem.lessThan(u8, after, &record.id))) try result.append(allocator, record.*);
        }
        std.mem.sort(Record, result.items, {}, struct {
            fn less(_: void, a: Record, b: Record) bool {
                return std.mem.lessThan(u8, &a.id, &b.id);
            }
        }.less);
        result.shrinkRetainingCapacity(@min(limit, result.items.len));
        return result.toOwnedSlice(allocator);
    }
    pub fn digest(self: *const Store, allocator: std.mem.Allocator) ![32]u8 {
        return self.digestVersion(allocator, .v3);
    }
    pub fn digestVersion(self: *const Store, allocator: std.mem.Allocator, version: DigestVersion) ![32]u8 {
        const keys = try allocator.alloc([36]u8, self.records.count());
        defer allocator.free(keys);
        var it = self.records.keyIterator();
        var index: usize = 0;
        while (it.next()) |key| : (index += 1) keys[index] = key.*;
        std.mem.sort([36]u8, keys, {}, struct {
            fn less(_: void, a: [36]u8, b: [36]u8) bool {
                return std.mem.lessThan(u8, &a, &b);
            }
        }.less);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(switch (version) {
            .v1 => "zettide/filesystem/snapshot/v1",
            .v2 => "zettide/filesystem/snapshot/v2",
            .v3 => "zettide/filesystem/snapshot/v3",
        });
        for (keys) |key| {
            const record = self.records.get(key).?;
            hash.update(&record.id);
            hash.update(&record.pool_id);
            for ([_]u64{ record.name_len, record.description_len, @intCast(@intFromEnum(record.name_profile)), record.created_revision, record.resource_version, record.deleted_revision }) |number| {
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, number, .little);
                hash.update(&bytes);
            }
            hash.update(record.name_bytes[0..record.name_len]);
            hash.update(record.description_bytes[0..record.description_len]);
            if (version != .v1) {
                var epoch: [8]u8 = undefined;
                std.mem.writeInt(u64, &epoch, record.authority_epoch, .little);
                hash.update(&epoch);
                hash.update(&.{@intFromBool(record.candidate_node_id != null)});
                if (record.candidate_node_id) |node| {
                    hash.update(&node);
                    hash.update(&record.candidate_boot_id);
                }
            }
            if (version == .v3) {
                var generation: [8]u8 = undefined;
                std.mem.writeInt(u64, &generation, record.placement_generation, .little);
                hash.update(&generation);
                hash.update(&record.backend_digest);
            }
        }
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }
};

pub fn validate(command: pb.FilesystemCommand) !void {
    const r = command.request orelse return error.InvalidWire;
    if (!schema.validText(r.request_id, schema.max_request_id_bytes, false) or !schema.validUuidV7(r.filesystem_id) or
        !schema.validText(r.description, schema.max_description_bytes, true)) return error.InvalidWire;
    if (!authorityOperation(command.operation) and (r.holder_node_id.len != 0 or r.holder_boot_id.len != 0 or r.expected_authority_epoch != 0)) return error.InvalidWire;
    if (command.operation == .FILESYSTEM_OPERATION_BEGIN_PREPARATION) {
        if (!schema.validFixedNonzero(r.backend_digest, 32)) return error.InvalidWire;
    } else if (r.backend_digest.len != 0) return error.InvalidWire;
    switch (command.operation) {
        .FILESYSTEM_OPERATION_PROPOSE_AUTHORITY, .FILESYSTEM_OPERATION_CANCEL_AUTHORITY, .FILESYSTEM_OPERATION_BEGIN_PREPARATION => {
            if (r.expected_resource_version == 0 or !schema.validUuidV7(r.holder_node_id) or
                !schema.validFixedNonzero(r.holder_boot_id, 16) or r.pool_id.len != 0 or r.name.len != 0 or r.description.len != 0 or
                r.backend_kind != .FILESYSTEM_BACKEND_KIND_UNSPECIFIED or r.name_profile != .FILESYSTEM_NAME_PROFILE_UNSPECIFIED or
                (command.operation != .FILESYSTEM_OPERATION_PROPOSE_AUTHORITY and r.expected_authority_epoch == 0)) return error.InvalidWire;
        },
        .FILESYSTEM_OPERATION_CREATE => {
            if (!schema.validUuidV7(r.pool_id) or !schema.validText(r.name, schema.max_name_bytes, false) or r.expected_resource_version != 0 or
                r.backend_kind != .FILESYSTEM_BACKEND_KIND_BLOB or
                (r.name_profile != .FILESYSTEM_NAME_PROFILE_LEGACY_RAW and r.name_profile != .FILESYSTEM_NAME_PROFILE_PORTABLE_V1)) return error.InvalidWire;
        },
        .FILESYSTEM_OPERATION_UPDATE, .FILESYSTEM_OPERATION_DELETE => {
            if (r.pool_id.len != 0 or r.name.len != 0 or r.backend_kind != .FILESYSTEM_BACKEND_KIND_UNSPECIFIED or
                r.name_profile != .FILESYSTEM_NAME_PROFILE_UNSPECIFIED or r.expected_resource_version == 0 or
                (command.operation == .FILESYSTEM_OPERATION_DELETE and r.description.len != 0)) return error.InvalidWire;
        },
        else => return error.InvalidWire,
    }
}

pub fn authorityOperation(operation: pb.FilesystemOperation) bool {
    return operation == .FILESYSTEM_OPERATION_PROPOSE_AUTHORITY or operation == .FILESYSTEM_OPERATION_CANCEL_AUTHORITY or operation == .FILESYSTEM_OPERATION_BEGIN_PREPARATION;
}

// Bound allocation before protobuf decoding; reject duplicate/unknown fields.
pub fn preflightRequest(bytes: []const u8) wire.Error!void {
    if (bytes.len > 2048) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = bytes };
    var seen: [13]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 12 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        if (field.number <= 5 or field.number == 9 or field.number == 10 or field.number == 12) {
            if (field.wire_type != 2) return error.InvalidWire;
            const maximum: usize = switch (field.number) {
                1 => schema.max_request_id_bytes,
                2, 3, 9 => 36,
                10 => 16,
                12 => 32,
                4 => schema.max_name_bytes,
                else => schema.max_description_bytes,
            };
            _ = try cursor.readBytes(maximum);
        } else {
            if (field.wire_type != 0) return error.InvalidWire;
            _ = try cursor.readVarint();
        }
    }
    if (!seen[1] or !seen[2]) return error.InvalidWire;
}
pub fn preflightCommand(bytes: []const u8) wire.Error!u32 {
    if (bytes.len > 2100) return error.InvalidWire;
    var minimum_version: u32 = 11;
    var cursor = wire.Cursor{ .bytes = bytes };
    var seen: [3]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 2 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        if (field.number == 1) {
            if (field.wire_type != 2) return error.InvalidWire;
            try preflightRequest(try cursor.readBytes(2048));
        } else {
            if (field.wire_type != 0) return error.InvalidWire;
            const op = try cursor.readVarint();
            if (op < 1 or op > 6) return error.InvalidWire;
            if (op >= 4) minimum_version = 12;
            if (op == 6) minimum_version = 13;
        }
    }
    if (!seen[1] or !seen[2]) return error.InvalidWire;
    return minimum_version;
}
pub fn preflightResponse(bytes: []const u8) wire.Error!void {
    if (bytes.len > 2048) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = bytes };
    var seen: [3]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 2 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        if (field.number == 1) {
            if (field.wire_type != 0) return error.InvalidWire;
            const code = try cursor.readVarint();
            if (code < 1 or code > 7) return error.InvalidWire;
        } else {
            if (field.wire_type != 2) return error.InvalidWire;
            var record = wire.Cursor{ .bytes = try cursor.readBytes(2000) };
            var fields: [18]bool = @splat(false);
            while (try record.next()) |part| {
                if (part.number > 17 or fields[part.number]) return error.InvalidWire;
                fields[part.number] = true;
                if (part.number <= 4 or part.number == 14 or part.number == 15 or part.number == 16) {
                    if (part.wire_type != 2) return error.InvalidWire;
                    _ = try record.readBytes(if (part.number == 16) 32 else if (part.number == 15) 16 else if (part.number < 3 or part.number == 14) 36 else if (part.number == 3) schema.max_name_bytes else schema.max_description_bytes);
                } else {
                    if (part.wire_type != 0) return error.InvalidWire;
                    _ = try record.readVarint();
                }
            }
        }
    }
    if (!seen[1]) return error.InvalidWire;
}

// Both query protocols use UUIDv7 field 1, optional cursor field 2 and size 3.
pub fn preflightQuery(bytes: []const u8, list_query: bool) wire.Error!void {
    try @import("range_leases.zig").preflightQuery(bytes, list_query);
    var cursor = wire.Cursor{ .bytes = bytes };
    while (try cursor.next()) |field| {
        if (field.number == 3) {
            if (try cursor.readVarint() > 32) return error.InvalidWire;
        } else _ = try cursor.readBytes(36);
    }
}
