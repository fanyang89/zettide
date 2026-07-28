const std = @import("std");

const pb = @import("control_proto");
const raft = @import("raft_zig");
const uuid = @import("uuid");
const wire = @import("protobuf_wire.zig");

pub const command_format_version: u32 = 1;
pub const snapshot_format_version: u32 = 2;
pub const max_name_bytes: usize = 127;
pub const max_description_bytes: usize = 1024;
pub const max_request_id_bytes: usize = 127;
pub const max_pools: usize = 25_000;
pub const max_requests: usize = 50_000;
pub const max_snapshot_bytes: usize = 256 * 1024 * 1024;

const max_pool_wire_bytes: usize = 2048;
const max_response_wire_bytes: usize = 2048;
const max_request_wire_bytes: usize = max_request_id_bytes + @sizeOf(Fingerprint) + max_response_wire_bytes + max_pool_wire_bytes + 40;

const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

const Pool = struct {
    id: []u8,
    name: []u8,
    description: []u8,
    created_at_unix_ms: i64,
    created_revision: u64,

    fn init(allocator: std.mem.Allocator, source: pb.Pool) !Pool {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, source.name);
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, source.description);
        return .{
            .id = id,
            .name = name,
            .description = description,
            .created_at_unix_ms = source.created_at_unix_ms,
            .created_revision = source.created_revision,
        };
    }

    fn deinit(self: *Pool, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
        self.* = undefined;
    }

    fn proto(self: Pool) pb.Pool {
        return .{
            .id = self.id,
            .name = self.name,
            .description = self.description,
            .created_at_unix_ms = self.created_at_unix_ms,
            .created_revision = self.created_revision,
        };
    }
};

const Request = struct {
    request_id: []u8,
    fingerprint: Fingerprint,
    encoded_response: []u8,
    encoded_command: []u8,
    applied_revision: u64,

    fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.encoded_response);
        allocator.free(self.encoded_command);
        self.* = undefined;
    }
};

const State = struct {
    pools_by_id: std.StringHashMapUnmanaged(Pool) = .empty,
    pool_ids_by_name: std.StringHashMapUnmanaged([]const u8) = .empty,
    pool_ids_by_revision: std.ArrayList([]const u8) = .empty,
    requests: std.StringHashMapUnmanaged(Request) = .empty,
    max_pool_created_revision: u64 = 0,

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var request_iterator = self.requests.valueIterator();
        while (request_iterator.next()) |request| request.deinit(allocator);
        self.requests.deinit(allocator);

        self.pool_ids_by_revision.deinit(allocator);
        var pool_iterator = self.pools_by_id.valueIterator();
        while (pool_iterator.next()) |pool| pool.deinit(allocator);
        self.pools_by_id.deinit(allocator);
        self.pool_ids_by_name.deinit(allocator);
        self.* = .{};
    }
};

pub const PoolStateMachine = struct {
    allocator: std.mem.Allocator,
    state: State = .{},

    pub fn init(allocator: std.mem.Allocator) PoolStateMachine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PoolStateMachine) void {
        self.state.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn stateMachine(self: *PoolStateMachine) raft.StateMachine {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn poolCount(self: *const PoolStateMachine) usize {
        return self.state.pools_by_id.count();
    }

    pub fn requestCount(self: *const PoolStateMachine) usize {
        return self.state.requests.count();
    }

    pub fn getPoolById(self: *const PoolStateMachine, allocator: std.mem.Allocator, id: []const u8) !?pb.Pool {
        const pool = self.state.pools_by_id.get(id) orelse return null;
        return try dupePool(allocator, pool.proto());
    }

    pub fn getPoolByName(self: *const PoolStateMachine, allocator: std.mem.Allocator, name: []const u8) !?pb.Pool {
        const id = self.state.pool_ids_by_name.get(name) orelse return null;
        return self.getPoolById(allocator, id);
    }

    pub fn listPools(self: *const PoolStateMachine, allocator: std.mem.Allocator) ![]pb.Pool {
        var pools: std.ArrayList(pb.Pool) = .empty;
        errdefer {
            for (pools.items) |*pool| pool.deinit(allocator);
            pools.deinit(allocator);
        }
        try pools.ensureTotalCapacity(allocator, self.state.pool_ids_by_revision.items.len);
        for (self.state.pool_ids_by_revision.items) |id| {
            pools.appendAssumeCapacity(try dupePool(allocator, self.state.pools_by_id.get(id).?.proto()));
        }
        return pools.toOwnedSlice(allocator);
    }

    pub const PoolPage = struct {
        pools: []pb.Pool,
        has_more: bool,

        pub fn deinit(self: *PoolPage, allocator: std.mem.Allocator) void {
            deinitPoolList(allocator, self.pools);
            self.* = undefined;
        }
    };

    pub fn listPoolsPage(
        self: *const PoolStateMachine,
        allocator: std.mem.Allocator,
        after_id: ?[]const u8,
        limit: usize,
    ) !PoolPage {
        var start: usize = 0;
        if (after_id) |target| {
            while (start < self.state.pool_ids_by_revision.items.len and
                !std.mem.eql(u8, self.state.pool_ids_by_revision.items[start], target)) : (start += 1)
            {}
            if (start == self.state.pool_ids_by_revision.items.len) return error.InvalidPageToken;
            start += 1;
        }
        const end = @min(start +| limit, self.state.pool_ids_by_revision.items.len);
        var pools: std.ArrayList(pb.Pool) = .empty;
        errdefer {
            for (pools.items) |*pool| pool.deinit(allocator);
            pools.deinit(allocator);
        }
        try pools.ensureTotalCapacity(allocator, end - start);
        for (self.state.pool_ids_by_revision.items[start..end]) |id| {
            pools.appendAssumeCapacity(try dupePool(allocator, self.state.pools_by_id.get(id).?.proto()));
        }
        return .{
            .pools = try pools.toOwnedSlice(allocator),
            .has_more = end < self.state.pool_ids_by_revision.items.len,
        };
    }

    fn apply(ctx: *anyopaque, entry: raft.Entry) raft.Error!raft.ApplyResult {
        const self: *PoolStateMachine = @ptrCast(@alignCast(ctx));
        if (entry.data.len == 0) return .{};
        preflightCommand(entry.data) catch return error.PayloadParseFailed;

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(entry.data);
        var envelope = pb.CommandEnvelope.decode(&reader, arena.allocator()) catch |err| return mapDecodeError(err);
        defer envelope.deinit(arena.allocator());
        if (envelope.format_version != command_format_version) return error.PayloadParseFailed;
        const command = envelope.create_pool orelse return error.PayloadParseFailed;
        try validateCommand(command);

        const fingerprint = requestFingerprint(command);
        if (self.state.requests.get(command.request_id)) |request| {
            if (!std.mem.eql(u8, &fingerprint, &request.fingerprint)) {
                return .{ .response = try encodeApplyResponse(self.allocator, .APPLY_CODE_REQUEST_CONFLICT, null) };
            }
            return .{ .response = try self.allocator.dupe(u8, request.encoded_response) };
        }
        if (self.state.requests.count() >= max_requests) {
            return .{ .response = try encodeApplyResponse(self.allocator, .APPLY_CODE_REQUEST_LIMIT, null) };
        }

        if (self.state.pool_ids_by_name.get(command.name)) |existing_id| {
            const existing = self.state.pools_by_id.get(existing_id).?;
            return try self.recordResponse(
                command,
                fingerprint,
                try encodeApplyResponse(self.allocator, .APPLY_CODE_NAME_EXISTS, existing.proto()),
                entry.index,
            );
        }
        if (self.state.pools_by_id.get(command.proposed_pool_id)) |existing| {
            return try self.recordResponse(
                command,
                fingerprint,
                try encodeApplyResponse(self.allocator, .APPLY_CODE_ID_EXISTS, existing.proto()),
                entry.index,
            );
        }
        if (self.state.pools_by_id.count() >= max_pools) {
            return try self.recordResponse(
                command,
                fingerprint,
                try encodeApplyResponse(self.allocator, .APPLY_CODE_POOL_LIMIT, null),
                entry.index,
            );
        }

        const pool_proto: pb.Pool = .{
            .id = command.proposed_pool_id,
            .name = command.name,
            .description = command.description,
            .created_at_unix_ms = command.proposed_created_at_unix_ms,
            .created_revision = entry.index,
        };
        const encoded_response = try encodeApplyResponse(self.allocator, .APPLY_CODE_CREATED, pool_proto);
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeCreatePoolCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        var pool = try Pool.init(self.allocator, pool_proto);
        errdefer pool.deinit(self.allocator);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);

        try self.state.pools_by_id.ensureUnusedCapacity(self.allocator, 1);
        try self.state.pool_ids_by_name.ensureUnusedCapacity(self.allocator, 1);
        try self.state.pool_ids_by_revision.ensureUnusedCapacity(self.allocator, 1);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.pools_by_id.putAssumeCapacity(pool.id, pool);
        self.state.pool_ids_by_name.putAssumeCapacity(pool.name, pool.id);
        self.state.pool_ids_by_revision.appendAssumeCapacity(pool.id);
        self.state.max_pool_created_revision = @max(self.state.max_pool_created_revision, pool.created_revision);
        self.state.requests.putAssumeCapacity(request_id, .{
            .request_id = request_id,
            .fingerprint = fingerprint,
            .encoded_response = encoded_response,
            .encoded_command = encoded_command,
            .applied_revision = entry.index,
        });
        return .{ .response = returned_response };
    }

    fn recordResponse(
        self: *PoolStateMachine,
        command: pb.CreatePoolCommand,
        fingerprint: Fingerprint,
        encoded_response: []u8,
        applied_revision: u64,
    ) raft.Error!raft.ApplyResult {
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeCreatePoolCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.requests.putAssumeCapacity(request_id, .{
            .request_id = request_id,
            .fingerprint = fingerprint,
            .encoded_response = encoded_response,
            .encoded_command = encoded_command,
            .applied_revision = applied_revision,
        });
        return .{ .response = returned_response };
    }

    fn takeSnapshot(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        applied_index: u64,
        applied_term: u64,
        conf_state: raft.ConfState,
    ) raft.Error!raft.Snapshot {
        const self: *PoolStateMachine = @ptrCast(@alignCast(ctx));
        var pools: std.ArrayList(pb.Pool) = .empty;
        defer pools.deinit(allocator);
        try pools.ensureTotalCapacity(allocator, self.state.pools_by_id.count());
        var pool_iterator = self.state.pools_by_id.valueIterator();
        while (pool_iterator.next()) |pool| pools.appendAssumeCapacity(pool.proto());
        std.mem.sort(pb.Pool, pools.items, {}, poolIdLessThan);

        var requests: std.ArrayList(pb.RequestRecord) = .empty;
        defer requests.deinit(allocator);
        try requests.ensureTotalCapacity(allocator, self.state.requests.count());
        var request_iterator = self.state.requests.valueIterator();
        while (request_iterator.next()) |request| {
            requests.appendAssumeCapacity(.{
                .request_id = request.request_id,
                .request_fingerprint = &request.fingerprint,
                .encoded_response = request.encoded_response,
                .encoded_command = request.encoded_command,
                .applied_revision = request.applied_revision,
            });
        }
        std.mem.sort(pb.RequestRecord, requests.items, {}, requestIdLessThan);

        const data = try encodeMessage(allocator, pb.StateSnapshot{
            .format_version = snapshot_format_version,
            .pools = pools,
            .requests = requests,
        });
        errdefer allocator.free(data);
        if (data.len > max_snapshot_bytes) return error.MessageTooLarge;
        return .{
            .data = data,
            .metadata = .{
                .index = applied_index,
                .term = applied_term,
                .conf_state = try raft.cloneConfState(allocator, conf_state),
            },
        };
    }

    fn restoreSnapshot(ctx: *anyopaque, metadata: raft.SnapshotMetadata, reader: raft.SnapshotReader) raft.Error!void {
        const self: *PoolStateMachine = @ptrCast(@alignCast(ctx));
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = try reader.read(&buffer);
            if (count == 0) break;
            if (bytes.items.len > max_snapshot_bytes -| count) return error.MessageTooLarge;
            try bytes.appendSlice(self.allocator, buffer[0..count]);
        }
        preflightSnapshot(bytes.items) catch return error.PayloadParseFailed;

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var wire_reader: std.Io.Reader = .fixed(bytes.items);
        var snapshot = pb.StateSnapshot.decode(&wire_reader, arena.allocator()) catch |err| return mapDecodeError(err);
        defer snapshot.deinit(arena.allocator());
        if (snapshot.format_version != snapshot_format_version) return error.PayloadParseFailed;
        if (snapshot.pools.items.len > max_pools or snapshot.requests.items.len > max_requests) return error.PayloadParseFailed;

        var restored: State = .{};
        errdefer restored.deinit(self.allocator);
        var revisions: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer revisions.deinit(self.allocator);
        for (snapshot.pools.items) |source| {
            if (source.created_revision > metadata.index or revisions.contains(source.created_revision)) return error.PayloadParseFailed;
            try revisions.put(self.allocator, source.created_revision, {});
            try restorePool(self.allocator, &restored, source);
        }
        std.mem.sort([]const u8, restored.pool_ids_by_revision.items, &restored, poolRevisionIdLessThan);

        var created_pool_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer created_pool_ids.deinit(self.allocator);
        var request_revisions: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer request_revisions.deinit(self.allocator);
        for (snapshot.requests.items) |source| {
            if (source.applied_revision == 0 or
                source.applied_revision > metadata.index or
                request_revisions.contains(source.applied_revision))
            {
                return error.PayloadParseFailed;
            }
            try request_revisions.put(self.allocator, source.applied_revision, {});
            if (try restoreRequest(self.allocator, arena.allocator(), &restored, source)) |created_pool_id| {
                if (created_pool_ids.contains(created_pool_id)) return error.PayloadParseFailed;
                try created_pool_ids.put(self.allocator, created_pool_id, {});
            }
        }
        if (created_pool_ids.count() != restored.pools_by_id.count()) return error.PayloadParseFailed;
        self.state.deinit(self.allocator);
        self.state = restored;
    }

    const vtable: raft.StateMachine.VTable = .{
        .apply = apply,
        .take_snapshot = takeSnapshot,
        .restore_snapshot = restoreSnapshot,
    };
};

pub fn encodeCreatePoolCommand(allocator: std.mem.Allocator, command: pb.CreatePoolCommand) ![]u8 {
    try validateCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{
        .format_version = command_format_version,
        .create_pool = command,
    });
}

pub fn decodeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.ApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.ApplyResponse.decode(&reader, allocator);
}

pub fn deinitPoolList(allocator: std.mem.Allocator, pools: []pb.Pool) void {
    for (pools) |*pool| pool.deinit(allocator);
    allocator.free(pools);
}

fn validateCommand(command: pb.CreatePoolCommand) raft.Error!void {
    if (!validText(command.request_id, max_request_id_bytes, false)) return error.PayloadParseFailed;
    if (!validUuidV7(command.proposed_pool_id)) return error.PayloadParseFailed;
    if (!validText(command.name, max_name_bytes, false)) return error.PayloadParseFailed;
    if (!validText(command.description, max_description_bytes, true)) return error.PayloadParseFailed;
    if (command.proposed_created_at_unix_ms <= 0) return error.PayloadParseFailed;
}

fn validatePool(pool: pb.Pool) raft.Error!void {
    if (!validUuidV7(pool.id)) return error.PayloadParseFailed;
    if (!validText(pool.name, max_name_bytes, false)) return error.PayloadParseFailed;
    if (!validText(pool.description, max_description_bytes, true)) return error.PayloadParseFailed;
    if (pool.created_at_unix_ms <= 0 or pool.created_revision == 0) return error.PayloadParseFailed;
}

fn validText(value: []const u8, max_bytes: usize, allow_empty: bool) bool {
    return (allow_empty or value.len != 0) and value.len <= max_bytes and std.unicode.utf8ValidateSlice(value);
}

fn validUuidV7(value: []const u8) bool {
    const parsed = uuid.urn.deserialize(value) catch return false;
    const canonical = uuid.urn.serialize(parsed);
    return canonical[14] == '7' and std.mem.eql(u8, value, &canonical);
}

fn requestFingerprint(command: pb.CreatePoolCommand) Fingerprint {
    return semanticFingerprint(command.name, command.description);
}

fn semanticFingerprint(name: []const u8, description: []const u8) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, name);
    hashField(&hasher, description);
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .little);
    hasher.update(&length);
    hasher.update(value);
}

fn encodeApplyResponse(allocator: std.mem.Allocator, code: pb.ApplyCode, pool: ?pb.Pool) raft.Error![]u8 {
    return encodeMessage(allocator, pb.ApplyResponse{ .code = code, .pool = pool });
}

fn encodeMessage(allocator: std.mem.Allocator, message: anytype) raft.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    message.encode(&output.writer, allocator) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn mapDecodeError(err: anyerror) raft.Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.PayloadParseFailed;
}

fn restorePool(allocator: std.mem.Allocator, state: *State, source: pb.Pool) raft.Error!void {
    try validatePool(source);
    if (state.pools_by_id.contains(source.id) or state.pool_ids_by_name.contains(source.name)) return error.PayloadParseFailed;
    var pool = try Pool.init(allocator, source);
    errdefer pool.deinit(allocator);
    try state.pools_by_id.ensureUnusedCapacity(allocator, 1);
    try state.pool_ids_by_name.ensureUnusedCapacity(allocator, 1);
    try state.pool_ids_by_revision.ensureUnusedCapacity(allocator, 1);
    state.pools_by_id.putAssumeCapacity(pool.id, pool);
    state.pool_ids_by_name.putAssumeCapacity(pool.name, pool.id);
    state.pool_ids_by_revision.appendAssumeCapacity(pool.id);
    state.max_pool_created_revision = @max(state.max_pool_created_revision, pool.created_revision);
}

fn restoreRequest(
    allocator: std.mem.Allocator,
    decode_allocator: std.mem.Allocator,
    state: *State,
    source: pb.RequestRecord,
) raft.Error!?[]const u8 {
    if (!validText(source.request_id, max_request_id_bytes, false)) return error.PayloadParseFailed;
    if (source.request_fingerprint.len != @sizeOf(Fingerprint) or source.encoded_response.len == 0 or source.encoded_command.len == 0) return error.PayloadParseFailed;
    if (state.requests.contains(source.request_id)) return error.PayloadParseFailed;

    var command_reader: std.Io.Reader = .fixed(source.encoded_command);
    var envelope = pb.CommandEnvelope.decode(&command_reader, decode_allocator) catch |err| return mapDecodeError(err);
    defer envelope.deinit(decode_allocator);
    if (envelope.format_version != command_format_version) return error.PayloadParseFailed;
    const command = envelope.create_pool orelse return error.PayloadParseFailed;
    try validateCommand(command);
    if (!std.mem.eql(u8, source.request_id, command.request_id)) return error.PayloadParseFailed;
    const expected_fingerprint = requestFingerprint(command);
    if (!std.mem.eql(u8, source.request_fingerprint, &expected_fingerprint)) return error.PayloadParseFailed;

    var response_reader: std.Io.Reader = .fixed(source.encoded_response);
    var response = pb.ApplyResponse.decode(&response_reader, decode_allocator) catch |err| return mapDecodeError(err);
    defer response.deinit(decode_allocator);
    const created_pool_id = try validateStoredResponse(state, command, response, source.applied_revision);

    const request_id = try allocator.dupe(u8, source.request_id);
    errdefer allocator.free(request_id);
    const encoded_response = try encodeApplyResponse(allocator, response.code, response.pool);
    errdefer allocator.free(encoded_response);
    const encoded_command = try encodeCreatePoolCommand(allocator, command);
    errdefer allocator.free(encoded_command);
    var fingerprint: Fingerprint = undefined;
    @memcpy(&fingerprint, source.request_fingerprint);
    try state.requests.ensureUnusedCapacity(allocator, 1);
    state.requests.putAssumeCapacity(request_id, .{
        .request_id = request_id,
        .fingerprint = fingerprint,
        .encoded_response = encoded_response,
        .encoded_command = encoded_command,
        .applied_revision = source.applied_revision,
    });
    return created_pool_id;
}

fn validateStoredResponse(
    state: *const State,
    command: pb.CreatePoolCommand,
    response: pb.ApplyResponse,
    applied_revision: u64,
) raft.Error!?[]const u8 {
    switch (response.code) {
        .APPLY_CODE_CREATED => {
            const response_pool = response.pool orelse return error.PayloadParseFailed;
            const stored_pool = state.pools_by_id.get(response_pool.id) orelse return error.PayloadParseFailed;
            if (!poolsEqual(stored_pool.proto(), response_pool)) return error.PayloadParseFailed;
            if (!std.mem.eql(u8, command.proposed_pool_id, response_pool.id) or
                !std.mem.eql(u8, command.name, response_pool.name) or
                !std.mem.eql(u8, command.description, response_pool.description) or
                command.proposed_created_at_unix_ms != response_pool.created_at_unix_ms or
                applied_revision != response_pool.created_revision)
            {
                return error.PayloadParseFailed;
            }
            return stored_pool.id;
        },
        .APPLY_CODE_NAME_EXISTS => {
            const response_pool = response.pool orelse return error.PayloadParseFailed;
            const stored_pool = state.pools_by_id.get(response_pool.id) orelse return error.PayloadParseFailed;
            if (!poolsEqual(stored_pool.proto(), response_pool) or
                !std.mem.eql(u8, command.name, response_pool.name) or
                response_pool.created_revision >= applied_revision)
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        .APPLY_CODE_ID_EXISTS => {
            const response_pool = response.pool orelse return error.PayloadParseFailed;
            const stored_pool = state.pools_by_id.get(response_pool.id) orelse return error.PayloadParseFailed;
            const name_conflict_before_request = if (state.pool_ids_by_name.get(command.name)) |name_pool_id|
                state.pools_by_id.get(name_pool_id).?.created_revision < applied_revision
            else
                false;
            if (!poolsEqual(stored_pool.proto(), response_pool) or
                !std.mem.eql(u8, command.proposed_pool_id, response_pool.id) or
                response_pool.created_revision >= applied_revision or
                name_conflict_before_request)
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        .APPLY_CODE_POOL_LIMIT => {
            const id_conflict_before_request = if (state.pools_by_id.get(command.proposed_pool_id)) |id_pool|
                id_pool.created_revision < applied_revision
            else
                false;
            const name_conflict_before_request = if (state.pool_ids_by_name.get(command.name)) |name_pool_id|
                state.pools_by_id.get(name_pool_id).?.created_revision < applied_revision
            else
                false;
            if (response.pool != null or
                state.pools_by_id.count() != max_pools or
                state.max_pool_created_revision >= applied_revision or
                id_conflict_before_request or
                name_conflict_before_request)
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        else => return error.PayloadParseFailed,
    }
}

fn poolsEqual(lhs: pb.Pool, rhs: pb.Pool) bool {
    return std.mem.eql(u8, lhs.id, rhs.id) and
        std.mem.eql(u8, lhs.name, rhs.name) and
        std.mem.eql(u8, lhs.description, rhs.description) and
        lhs.created_at_unix_ms == rhs.created_at_unix_ms and
        lhs.created_revision == rhs.created_revision;
}

fn dupePool(allocator: std.mem.Allocator, source: pb.Pool) !pb.Pool {
    const owned = try Pool.init(allocator, source);
    return owned.proto();
}

const WireError = wire.Error;
const WireCursor = wire.Cursor;

fn preflightCommand(bytes: []const u8) WireError!void {
    if (bytes.len > max_pool_wire_bytes) return error.InvalidWire;
    var cursor = WireCursor{ .bytes = bytes };
    var seen_format = false;
    var seen_create = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_format) return error.InvalidWire;
            seen_format = true;
            if (try cursor.readVarint() != command_format_version) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_create) return error.InvalidWire;
            seen_create = true;
            try preflightCreatePool(try cursor.readBytes(max_pool_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_format or !seen_create) return error.InvalidWire;
}

fn preflightCreatePool(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 6;
    while (try cursor.next()) |field| {
        if (field.number > 5 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            },
            3 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_name_bytes), max_name_bytes, false)) return error.InvalidWire;
            },
            4 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire;
            },
            5 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5]) return error.InvalidWire;
}

fn preflightSnapshot(bytes: []const u8) WireError!void {
    if (bytes.len > max_snapshot_bytes) return error.InvalidWire;
    var cursor = WireCursor{ .bytes = bytes };
    var seen_format = false;
    var pool_count: usize = 0;
    var request_count: usize = 0;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_format) return error.InvalidWire;
            seen_format = true;
            const version = try cursor.readVarint();
            if (version > std.math.maxInt(u32)) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or pool_count == max_pools) return error.InvalidWire;
            pool_count += 1;
            try preflightPool(try cursor.readBytes(max_pool_wire_bytes));
        },
        3 => {
            if (field.wire_type != 2 or request_count == max_requests) return error.InvalidWire;
            request_count += 1;
            try preflightRequest(try cursor.readBytes(max_request_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_format) return error.InvalidWire;
}

fn preflightPool(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 6;
    while (try cursor.next()) |field| {
        if (field.number > 5 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_name_bytes), max_name_bytes, false)) return error.InvalidWire;
            },
            3 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire;
            },
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            5 => {
                if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[4] or !seen[5]) return error.InvalidWire;
}

fn preflightRequest(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 6;
    while (try cursor.next()) |field| {
        if (field.number > 5 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or (try cursor.readBytes(@sizeOf(Fingerprint))).len != @sizeOf(Fingerprint)) return error.InvalidWire;
            },
            3 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightApplyResponse(try cursor.readBytes(max_response_wire_bytes));
            },
            4 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightCommand(try cursor.readBytes(max_pool_wire_bytes));
            },
            5 => {
                if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5]) return error.InvalidWire;
}

fn preflightApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_pool = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code == 2 or code > 7) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_pool) return error.InvalidWire;
            seen_pool = true;
            try preflightPool(try cursor.readBytes(max_pool_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn poolRevisionIdLessThan(state: *State, lhs_id: []const u8, rhs_id: []const u8) bool {
    const lhs = state.pools_by_id.get(lhs_id).?;
    const rhs = state.pools_by_id.get(rhs_id).?;
    if (lhs.created_revision != rhs.created_revision) return lhs.created_revision < rhs.created_revision;
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn poolIdLessThan(_: void, lhs: pb.Pool, rhs: pb.Pool) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn requestIdLessThan(_: void, lhs: pb.RequestRecord, rhs: pb.RequestRecord) bool {
    return std.mem.order(u8, lhs.request_id, rhs.request_id) == .lt;
}

fn testCommand(request_id: []const u8, pool_id: []const u8, name: []const u8, description: []const u8, timestamp: i64) pb.CreatePoolCommand {
    return .{
        .request_id = request_id,
        .proposed_pool_id = pool_id,
        .name = name,
        .description = description,
        .proposed_created_at_unix_ms = timestamp,
    };
}

fn applyTestCommand(allocator: std.mem.Allocator, machine: *PoolStateMachine, index: u64, command: pb.CreatePoolCommand) !raft.ApplyResult {
    const encoded = try encodeCreatePoolCommand(allocator, command);
    defer allocator.free(encoded);
    return machine.stateMachine().apply(.{ .index = index, .term = 1, .data = encoded });
}

fn overlongOne(allocator: std.mem.Allocator, canonical: []const u8) ![]u8 {
    try std.testing.expect(canonical.len >= 2 and canonical[0] == 0x08 and canonical[1] == 0x01);
    const result = try allocator.alloc(u8, canonical.len + 1);
    result[0] = 0x08;
    result[1] = 0x81;
    result[2] = 0x00;
    @memcpy(result[3..], canonical[2..]);
    return result;
}

const TestSnapshotReader = struct {
    data: []const u8,
    offset: usize = 0,

    fn reader(self: *TestSnapshotReader) raft.SnapshotReader {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn read(ctx: *anyopaque, output: []u8) raft.Error!usize {
        const self: *TestSnapshotReader = @ptrCast(@alignCast(ctx));
        if (self.offset == self.data.len) return 0;
        const count = @min(output.len, self.data.len - self.offset);
        @memcpy(output[0..count], self.data[self.offset..][0..count]);
        self.offset += count;
        return count;
    }

    const vtable: raft.SnapshotReader.VTable = .{ .read = read };
};

test "create pool is idempotent by request semantics" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();

    const command = testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "Primary storage pool",
        1_753_744_000_000,
    );
    var first = try applyTestCommand(allocator, &machine, 7, command);
    defer first.deinit(allocator);
    var created = try decodeApplyResponse(allocator, first.response.?);
    defer created.deinit(allocator);
    try std.testing.expectEqual(pb.ApplyCode.APPLY_CODE_CREATED, created.code);
    try std.testing.expectEqual(@as(u64, 7), created.pool.?.created_revision);
    try std.testing.expectEqual(@as(usize, 1), machine.poolCount());

    var stored = (try machine.getPoolByName(allocator, "primary")).?;
    defer stored.deinit(allocator);
    try std.testing.expectEqualStrings(command.proposed_pool_id, stored.id);

    const retry = testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000002",
        "primary",
        "Primary storage pool",
        1_753_744_000_999,
    );
    var repeated = try applyTestCommand(allocator, &machine, 8, retry);
    defer repeated.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.response.?, repeated.response.?);
    try std.testing.expectEqual(@as(usize, 1), machine.poolCount());

    const conflict = testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000003",
        "primary",
        "Changed description",
        1_753_744_001_000,
    );
    var rejected = try applyTestCommand(allocator, &machine, 9, conflict);
    defer rejected.deinit(allocator);
    var response = try decodeApplyResponse(allocator, rejected.response.?);
    defer response.deinit(allocator);
    try std.testing.expectEqual(pb.ApplyCode.APPLY_CODE_REQUEST_CONFLICT, response.code);
    try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
}

test "name conflict response is recorded for retries" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();

    var created = try applyTestCommand(allocator, &machine, 1, testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "",
        1_753_744_000_000,
    ));
    defer created.deinit(allocator);
    const duplicate_name = testCommand(
        "request-2",
        "0198f54d-5c2a-7000-8000-000000000002",
        "primary",
        "",
        1_753_744_000_001,
    );
    var first_rejection = try applyTestCommand(allocator, &machine, 2, duplicate_name);
    defer first_rejection.deinit(allocator);
    var response = try decodeApplyResponse(allocator, first_rejection.response.?);
    defer response.deinit(allocator);
    try std.testing.expectEqual(pb.ApplyCode.APPLY_CODE_NAME_EXISTS, response.code);
    try std.testing.expectEqualStrings("0198f54d-5c2a-7000-8000-000000000001", response.pool.?.id);

    var repeated = try applyTestCommand(allocator, &machine, 3, duplicate_name);
    defer repeated.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first_rejection.response.?, repeated.response.?);
    try std.testing.expectEqual(@as(usize, 1), machine.poolCount());

    const duplicate_id = testCommand(
        "request-3",
        "0198f54d-5c2a-7000-8000-000000000001",
        "secondary",
        "",
        1_753_744_000_002,
    );
    var id_rejection = try applyTestCommand(allocator, &machine, 4, duplicate_id);
    defer id_rejection.deinit(allocator);
    var id_response = try decodeApplyResponse(allocator, id_rejection.response.?);
    defer id_response.deinit(allocator);
    try std.testing.expectEqual(pb.ApplyCode.APPLY_CODE_ID_EXISTS, id_response.code);
    try std.testing.expectEqualStrings("primary", id_response.pool.?.name);

    var secondary = try applyTestCommand(allocator, &machine, 5, testCommand(
        "request-4",
        "0198f54d-5c2a-7000-8000-000000000004",
        "secondary",
        "",
        1_753_744_000_003,
    ));
    defer secondary.deinit(allocator);
    var snapshot = try machine.stateMachine().takeSnapshot(allocator, 5, 1, .{});
    defer snapshot.deinit(allocator);

    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var snapshot_reader = TestSnapshotReader{ .data = snapshot.data };
    try restored.stateMachine().restoreSnapshot(snapshot.metadata, snapshot_reader.reader());
    var restored_retry = try applyTestCommand(allocator, &restored, 6, testCommand(
        "request-3",
        "0198f54d-5c2a-7000-8000-000000000005",
        "secondary",
        "",
        1_753_744_000_999,
    ));
    defer restored_retry.deinit(allocator);
    try std.testing.expectEqualSlices(u8, id_rejection.response.?, restored_retry.response.?);
}

test "snapshot bytes are deterministic and restore request history" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();

    const first_command = testCommand(
        "request-beta",
        "0198f54d-5c2a-7000-8000-000000000002",
        "beta",
        "Second by identifier",
        1_753_744_000_000,
    );
    var first_result = try applyTestCommand(allocator, &machine, 4, first_command);
    defer first_result.deinit(allocator);
    var second_result = try applyTestCommand(allocator, &machine, 5, testCommand(
        "request-alpha",
        "0198f54d-5c2a-7000-8000-000000000001",
        "alpha",
        "First by identifier",
        1_753_744_000_001,
    ));
    defer second_result.deinit(allocator);

    var voters = [_]u64{1};
    const conf_state: raft.ConfState = .{ .voters = &voters };
    var first_snapshot = try machine.stateMachine().takeSnapshot(allocator, 5, 2, conf_state);
    defer first_snapshot.deinit(allocator);
    var second_snapshot = try machine.stateMachine().takeSnapshot(allocator, 5, 2, conf_state);
    defer second_snapshot.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first_snapshot.data, second_snapshot.data);

    var decoded_reader: std.Io.Reader = .fixed(first_snapshot.data);
    var decoded_snapshot = try pb.StateSnapshot.decode(&decoded_reader, allocator);
    defer decoded_snapshot.deinit(allocator);
    std.mem.swap(pb.Pool, &decoded_snapshot.pools.items[0], &decoded_snapshot.pools.items[1]);
    std.mem.swap(pb.RequestRecord, &decoded_snapshot.requests.items[0], &decoded_snapshot.requests.items[1]);
    const noncanonical_response = try overlongOne(allocator, decoded_snapshot.requests.items[0].encoded_response);
    allocator.free(decoded_snapshot.requests.items[0].encoded_response);
    decoded_snapshot.requests.items[0].encoded_response = noncanonical_response;
    const noncanonical_command = try overlongOne(allocator, decoded_snapshot.requests.items[0].encoded_command);
    allocator.free(decoded_snapshot.requests.items[0].encoded_command);
    decoded_snapshot.requests.items[0].encoded_command = noncanonical_command;
    const reversed_snapshot = try encodeMessage(allocator, decoded_snapshot);
    defer allocator.free(reversed_snapshot);

    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var snapshot_reader = TestSnapshotReader{ .data = reversed_snapshot };
    try restored.stateMachine().restoreSnapshot(first_snapshot.metadata, snapshot_reader.reader());
    const pools = try restored.listPools(allocator);
    defer deinitPoolList(allocator, pools);
    try std.testing.expectEqual(@as(usize, 2), pools.len);
    try std.testing.expectEqualStrings("beta", pools[0].name);
    try std.testing.expectEqualStrings("alpha", pools[1].name);

    const retry = testCommand(
        "request-beta",
        "0198f54d-5c2a-7000-8000-000000000003",
        "beta",
        "Second by identifier",
        1_753_744_999_999,
    );
    var repeated = try applyTestCommand(allocator, &restored, 6, retry);
    defer repeated.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first_result.response.?, repeated.response.?);

    var normalized_snapshot = try restored.stateMachine().takeSnapshot(allocator, 5, 2, conf_state);
    defer normalized_snapshot.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first_snapshot.data, normalized_snapshot.data);
}

test "invalid snapshot leaves state unchanged" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    var created = try applyTestCommand(allocator, &machine, 1, testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "",
        1_753_744_000_000,
    ));
    defer created.deinit(allocator);

    const invalid = try encodeMessage(allocator, pb.StateSnapshot{ .format_version = 99 });
    defer allocator.free(invalid);
    var snapshot_reader = TestSnapshotReader{ .data = invalid };
    try std.testing.expectError(
        error.PayloadParseFailed,
        machine.stateMachine().restoreSnapshot(.{}, snapshot_reader.reader()),
    );
    try std.testing.expectEqual(@as(usize, 1), machine.poolCount());

    var valid_snapshot = try machine.stateMachine().takeSnapshot(allocator, 1, 1, .{});
    defer valid_snapshot.deinit(allocator);
    var stale_metadata_reader = TestSnapshotReader{ .data = valid_snapshot.data };
    try std.testing.expectError(
        error.PayloadParseFailed,
        machine.stateMachine().restoreSnapshot(.{ .index = 0 }, stale_metadata_reader.reader()),
    );
    try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
}

test "wire preflight rejects overflowing protobuf lengths" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();

    const malformed = [_]u8{0x12} ++ [_]u8{0xff} ** 9 ++ [_]u8{0x01};
    var reader = TestSnapshotReader{ .data = &malformed };
    try std.testing.expectError(
        error.PayloadParseFailed,
        machine.stateMachine().restoreSnapshot(.{}, reader.reader()),
    );
    try std.testing.expectEqual(@as(usize, 0), machine.poolCount());
}

test "empty raft entry is a no-op and malformed command is terminal" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();

    var no_op = try machine.stateMachine().apply(.{ .index = 1, .term = 1 });
    defer no_op.deinit(allocator);
    try std.testing.expect(no_op.response == null);

    const invalid_name = testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000001",
        "",
        "",
        1_753_744_000_000,
    );
    const encoded = try encodeMessage(allocator, pb.CommandEnvelope{
        .format_version = command_format_version,
        .create_pool = invalid_name,
    });
    defer allocator.free(encoded);
    try std.testing.expectError(
        error.PayloadParseFailed,
        machine.stateMachine().apply(.{ .index = 2, .term = 1, .data = encoded }),
    );
    try std.testing.expectEqual(@as(usize, 0), machine.poolCount());
}

const ApplyAllocationCheck = struct {
    fn run(allocator: std.mem.Allocator, encoded: []const u8) !void {
        var machine = PoolStateMachine.init(allocator);
        defer machine.deinit();
        var result = machine.stateMachine().apply(.{ .index = 1, .term = 1, .data = encoded }) catch |err| {
            try std.testing.expectEqual(@as(usize, 0), machine.poolCount());
            return err;
        };
        defer result.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
    }
};

test "create apply is atomic across allocation failures" {
    const encoded = try encodeCreatePoolCommand(std.testing.allocator, testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "Primary storage pool",
        1_753_744_000_000,
    ));
    defer std.testing.allocator.free(encoded);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ApplyAllocationCheck.run, .{encoded});
}

const ConflictAllocationCheck = struct {
    fn run(allocator: std.mem.Allocator, created_command: []const u8, conflict_command: []const u8) !void {
        var machine = PoolStateMachine.init(allocator);
        defer machine.deinit();
        var created = machine.stateMachine().apply(.{ .index = 1, .term = 1, .data = created_command }) catch |err| {
            try std.testing.expectEqual(@as(usize, 0), machine.requestCount());
            return err;
        };
        defer created.deinit(allocator);

        var conflict = machine.stateMachine().apply(.{ .index = 2, .term = 1, .data = conflict_command }) catch |err| {
            try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
            try std.testing.expectEqual(@as(usize, 1), machine.requestCount());
            return err;
        };
        defer conflict.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
        try std.testing.expectEqual(@as(usize, 2), machine.requestCount());
    }
};

test "conflict response is atomic across allocation failures" {
    const allocator = std.testing.allocator;
    const created_command = try encodeCreatePoolCommand(allocator, testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "",
        1_753_744_000_000,
    ));
    defer allocator.free(created_command);
    const conflict_command = try encodeCreatePoolCommand(allocator, testCommand(
        "request-2",
        "0198f54d-5c2a-7000-8000-000000000002",
        "primary",
        "",
        1_753_744_000_001,
    ));
    defer allocator.free(conflict_command);
    try std.testing.checkAllAllocationFailures(
        allocator,
        ConflictAllocationCheck.run,
        .{ created_command, conflict_command },
    );
}

const RestoreAllocationCheck = struct {
    fn run(allocator: std.mem.Allocator, existing_command: []const u8, snapshot_data: []const u8, metadata: raft.SnapshotMetadata) !void {
        var machine = PoolStateMachine.init(allocator);
        defer machine.deinit();
        var applied = machine.stateMachine().apply(.{ .index = 1, .term = 1, .data = existing_command }) catch |err| {
            try std.testing.expectEqual(@as(usize, 0), machine.poolCount());
            return err;
        };
        defer applied.deinit(allocator);

        var reader = TestSnapshotReader{ .data = snapshot_data };
        machine.stateMachine().restoreSnapshot(metadata, reader.reader()) catch |err| {
            try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
            return err;
        };
        try std.testing.expectEqual(@as(usize, 2), machine.poolCount());
    }
};

test "snapshot restore is atomic across allocation failures" {
    const allocator = std.testing.allocator;
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    var first = try applyTestCommand(allocator, &source, 2, testCommand(
        "request-1",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "",
        1_753_744_000_000,
    ));
    defer first.deinit(allocator);
    var second = try applyTestCommand(allocator, &source, 3, testCommand(
        "request-2",
        "0198f54d-5c2a-7000-8000-000000000002",
        "secondary",
        "",
        1_753_744_000_001,
    ));
    defer second.deinit(allocator);
    var snapshot = try source.stateMachine().takeSnapshot(allocator, 3, 1, .{});
    defer snapshot.deinit(allocator);

    const existing_command = try encodeCreatePoolCommand(allocator, testCommand(
        "existing-request",
        "0198f54d-5c2a-7000-8000-000000000003",
        "existing",
        "",
        1_753_744_000_002,
    ));
    defer allocator.free(existing_command);
    try std.testing.checkAllAllocationFailures(
        allocator,
        RestoreAllocationCheck.run,
        .{ existing_command, snapshot.data, snapshot.metadata },
    );
}
