const std = @import("std");
const pb = @import("controller_proto");
const schema = @import("state_machine/schema.zig");
const wire = @import("protobuf_wire.zig");

pub const max_filesystems = 10_000;
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

    pub fn proto(self: *const Record) pb.Filesystem {
        return .{ .id = &self.id, .pool_id = &self.pool_id, .name = self.name_bytes[0..self.name_len], .description = self.description_bytes[0..self.description_len], .name_profile = self.name_profile, .backend_kind = .FILESYSTEM_BACKEND_KIND_BLOB, .format_version = 1, .lifecycle_state = if (self.deleted_revision == 0) .FILESYSTEM_LIFECYCLE_STATE_PROVISIONING else .FILESYSTEM_LIFECYCLE_STATE_DELETED, .created_revision = self.created_revision, .resource_version = self.resource_version, .deleted_revision = self.deleted_revision };
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

/// Logical records only. No placement, media initialization, or authority exists
/// in this slice; deletion cancels an unmaterialized provisioning intent.
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
    pub fn evaluate(self: *const Store, command: pb.FilesystemCommand, pool_available: bool, revision: u64) Outcome {
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
        if (command.operation == .FILESYSTEM_OPERATION_UPDATE) record.describe(request.description) else record.deleted_revision = revision;
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
        hash.update("zettide/filesystem/snapshot/v1");
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
    switch (command.operation) {
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

// Bound allocation before protobuf decoding; reject duplicate/unknown fields.
pub fn preflightRequest(bytes: []const u8) wire.Error!void {
    if (bytes.len > 2048) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = bytes };
    var seen: [9]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 8 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        if (field.number <= 5) {
            if (field.wire_type != 2) return error.InvalidWire;
            const maximum: usize = switch (field.number) {
                1 => schema.max_request_id_bytes,
                2, 3 => 36,
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
pub fn preflightCommand(bytes: []const u8) wire.Error!void {
    if (bytes.len > 2100) return error.InvalidWire;
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
            if (op < 1 or op > 3) return error.InvalidWire;
        }
    }
    if (!seen[1] or !seen[2]) return error.InvalidWire;
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
            var fields: [12]bool = @splat(false);
            while (try record.next()) |part| {
                if (part.number > 11 or fields[part.number]) return error.InvalidWire;
                fields[part.number] = true;
                if (part.number <= 4) {
                    if (part.wire_type != 2) return error.InvalidWire;
                    _ = try record.readBytes(if (part.number < 3) 36 else if (part.number == 3) schema.max_name_bytes else schema.max_description_bytes);
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
