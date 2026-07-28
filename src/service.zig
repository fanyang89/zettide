const std = @import("std");

const grpc = @import("grpc_lite");
const pb = @import("control_proto");
const raft = @import("raft_zig");
const uuid = @import("uuid");
const state_machine = @import("state_machine.zig");
const wire = @import("protobuf_wire.zig");

pub const default_page_size: usize = 100;
pub const max_page_size: usize = 1000;
pub const max_pending_rpc_calls: usize = 1024;

const max_request_wire_bytes: usize = 2048;

pub const RpcResult = struct {
    status: grpc.Status,
    payload: []const u8 = &.{},
};

pub const Completion = struct {
    ctx: *anyopaque,
    function: *const fn (*anyopaque, RpcResult) void,

    pub fn invoke(self: Completion, result: RpcResult) void {
        self.function(self.ctx, result);
    }
};

pub const PoolService = struct {
    /// Must be safe for allocation on gRPC reactor and Raft callback threads.
    allocator: std.mem.Allocator,
    io: std.Io,
    raftor: *raft.Raftor,
    machine: *state_machine.PoolStateMachine,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        raftor: *raft.Raftor,
        machine: *state_machine.PoolStateMachine,
    ) error{UnsafeRaftConfiguration}!PoolService {
        if (!raftor.leaderServicePolicy().isSafe()) return error.UnsafeRaftConfiguration;
        return .{
            .allocator = allocator,
            .io = io,
            .raftor = raftor,
            .machine = machine,
        };
    }

    pub fn createPool(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightCreatePoolRequest(payload) catch {
            completion.invoke(invalidArgument("invalid CreatePool request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.CreatePoolRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid CreatePool request"));
            return;
        };
        defer request.deinit(arena.allocator());
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }

        const timestamp = std.math.cast(i64, std.Io.Timestamp.now(self.io, .real).toMilliseconds()) orelse {
            completion.invoke(internalError());
            return;
        };
        const pool_id = uuid.urn.serialize(uuid.v7.new(self.io));
        const command = state_machine.encodeCreatePoolCommand(self.allocator, .{
            .request_id = request.request_id,
            .proposed_pool_id = &pool_id,
            .name = request.name,
            .description = request.description,
            .proposed_created_at_unix_ms = timestamp,
        }) catch {
            completion.invoke(internalError());
            return;
        };
        defer self.allocator.free(command);

        const pending = self.allocator.create(CreatePending) catch {
            completion.invoke(internalError());
            return;
        };
        pending.* = .{ .owner = self, .completion = completion };
        self.raftor.propose(command, pending.callback()) catch |err| {
            self.allocator.destroy(pending);
            completion.invoke(raftFailure(err));
        };
    }

    pub fn getPool(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightGetPoolRequest(payload) catch {
            completion.invoke(invalidArgument("invalid GetPool request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.GetPoolRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid GetPool request"));
            return;
        };
        defer request.deinit(arena.allocator());
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }

        const selector_source = request.selector orelse {
            completion.invoke(invalidArgument("Pool selector is required"));
            return;
        };
        const selector: GetPending.Selector = switch (selector_source) {
            .id => |id| .{ .id = self.allocator.dupe(u8, id) catch {
                completion.invoke(internalError());
                return;
            } },
            .name => |name| .{ .name = self.allocator.dupe(u8, name) catch {
                completion.invoke(internalError());
                return;
            } },
        };
        const pending = self.allocator.create(GetPending) catch {
            deinitSelector(self.allocator, selector);
            completion.invoke(internalError());
            return;
        };
        pending.* = .{ .owner = self, .completion = completion, .selector = selector };
        self.raftor.readIndex("get-pool", pending.callback()) catch |err| {
            pending.destroy();
            completion.invoke(raftFailure(err));
        };
    }

    pub fn listPools(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightListPoolsRequest(payload) catch {
            completion.invoke(invalidArgument("invalid ListPools request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.ListPoolsRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid ListPools request"));
            return;
        };
        defer request.deinit(arena.allocator());
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }

        const page_size: usize = if (request.page_size == 0) default_page_size else request.page_size;
        if (page_size > max_page_size) {
            completion.invoke(invalidArgument("page_size exceeds 1000"));
            return;
        }
        const after_id = if (request.page_token.len == 0)
            null
        else
            self.allocator.dupe(u8, request.page_token) catch {
                completion.invoke(internalError());
                return;
            };
        const pending = self.allocator.create(ListPending) catch {
            if (after_id) |id| self.allocator.free(id);
            completion.invoke(internalError());
            return;
        };
        pending.* = .{
            .owner = self,
            .completion = completion,
            .page_size = page_size,
            .after_id = after_id,
        };
        self.raftor.readIndex("list-pools", pending.callback()) catch |err| {
            pending.destroy();
            completion.invoke(raftFailure(err));
        };
    }

    fn isLeader(self: *const PoolService) bool {
        const status = self.raftor.getStatus();
        return status.role == .leader and status.leader_id == status.id;
    }
};

const CreatePending = struct {
    owner: *PoolService,
    completion: Completion,

    fn callback(self: *CreatePending) raft.ProposalCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn complete(ctx: *anyopaque, result: raft.ProposalResult) void {
        const self: *CreatePending = @ptrCast(@alignCast(ctx));
        defer self.owner.allocator.destroy(self);
        switch (result) {
            .ok => |payload| self.completeApplied(payload),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeApplied(self: *CreatePending, payload: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.owner.allocator);
        defer arena.deinit();
        var response = state_machine.decodeApplyResponse(arena.allocator(), payload) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer response.deinit(arena.allocator());
        switch (response.code) {
            .APPLY_CODE_CREATED => {
                const pool = response.pool orelse {
                    self.completion.invoke(internalError());
                    return;
                };
                const encoded = encodeMessage(self.owner.allocator, pb.CreatePoolResponse{ .pool = pool }) catch {
                    self.completion.invoke(internalError());
                    return;
                };
                defer self.owner.allocator.free(encoded);
                self.completion.invoke(.{ .status = .ok, .payload = encoded });
            },
            .APPLY_CODE_NAME_EXISTS => self.completion.invoke(.{
                .status = grpc.Status.init(.already_exists, "Pool name already exists"),
            }),
            .APPLY_CODE_ID_EXISTS => self.completion.invoke(.{
                .status = grpc.Status.init(.already_exists, "Pool ID already exists"),
            }),
            .APPLY_CODE_REQUEST_CONFLICT => self.completion.invoke(.{
                .status = grpc.Status.init(.failed_precondition, "request_id was reused with different fields"),
            }),
            .APPLY_CODE_REQUEST_LIMIT => self.completion.invoke(.{
                .status = grpc.Status.init(.resource_exhausted, "request history limit reached"),
            }),
            .APPLY_CODE_POOL_LIMIT => self.completion.invoke(.{
                .status = grpc.Status.init(.resource_exhausted, "Pool limit reached"),
            }),
            else => self.completion.invoke(internalError()),
        }
    }
};

const GetPending = struct {
    owner: *PoolService,
    completion: Completion,
    selector: Selector,

    const Selector = union(enum) {
        id: []u8,
        name: []u8,
    };

    fn callback(self: *GetPending) raft.ReadIndexCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn destroy(self: *GetPending) void {
        const allocator = self.owner.allocator;
        deinitSelector(allocator, self.selector);
        allocator.destroy(self);
    }

    fn complete(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *GetPending = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        switch (result) {
            .ok => self.completeRead(),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeRead(self: *GetPending) void {
        var pool = (switch (self.selector) {
            .id => |id| self.owner.machine.getPoolById(self.owner.allocator, id),
            .name => |name| self.owner.machine.getPoolByName(self.owner.allocator, name),
        }) catch {
            self.completion.invoke(internalError());
            return;
        } orelse {
            self.completion.invoke(.{ .status = grpc.Status.init(.not_found, "Pool not found") });
            return;
        };
        defer pool.deinit(self.owner.allocator);
        const encoded = encodeMessage(self.owner.allocator, pb.GetPoolResponse{ .pool = pool }) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer self.owner.allocator.free(encoded);
        self.completion.invoke(.{ .status = .ok, .payload = encoded });
    }
};

const ListPending = struct {
    owner: *PoolService,
    completion: Completion,
    page_size: usize,
    after_id: ?[]u8,

    fn callback(self: *ListPending) raft.ReadIndexCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn destroy(self: *ListPending) void {
        const allocator = self.owner.allocator;
        if (self.after_id) |id| allocator.free(id);
        allocator.destroy(self);
    }

    fn complete(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *ListPending = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        switch (result) {
            .ok => self.completeRead(),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeRead(self: *ListPending) void {
        var result = self.owner.machine.listPoolsPage(
            self.owner.allocator,
            if (self.after_id) |id| id else null,
            self.page_size,
        ) catch |err| {
            self.completion.invoke(if (err == error.InvalidPageToken)
                invalidArgument("invalid page_token")
            else
                internalError());
            return;
        };
        defer result.deinit(self.owner.allocator);
        const page_items = result.pools;
        const page: std.ArrayList(pb.Pool) = .{ .items = page_items, .capacity = page_items.len };
        const next_token: []const u8 = if (result.has_more) page_items[page_items.len - 1].id else &.{};
        const encoded = encodeMessage(self.owner.allocator, pb.ListPoolsResponse{
            .pools = page,
            .next_page_token = next_token,
        }) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer self.owner.allocator.free(encoded);
        self.completion.invoke(.{ .status = .ok, .payload = encoded });
    }
};

pub const PoolRpc = struct {
    /// Must be thread-safe when the server has multiple reactors.
    allocator: std.mem.Allocator,
    service: *PoolService,
    pending_calls: std.atomic.Value(usize) = .init(0),
    accepting: std.atomic.Value(bool) = .init(true),
    calls_lock: std.atomic.Mutex = .unlocked,
    calls: std.AutoHashMapUnmanaged(grpc.ServerCallId, *InboundCall) = .empty,

    pub fn init(allocator: std.mem.Allocator, service: *PoolService) PoolRpc {
        return .{ .allocator = allocator, .service = service };
    }

    pub fn register(self: *PoolRpc, server: *grpc.Server) !void {
        try server.registerStream("/zettide.control.v1.PoolService/CreatePool", handler(self, .create));
        try server.registerStream("/zettide.control.v1.PoolService/GetPool", handler(self, .get));
        try server.registerStream("/zettide.control.v1.PoolService/ListPools", handler(self, .list));
    }

    pub fn pendingCallCount(self: *const PoolRpc) usize {
        return self.pending_calls.load(.acquire);
    }

    pub fn stopAccepting(self: *PoolRpc) void {
        self.accepting.store(false, .release);
    }

    /// Call after Server.wait, while the Server object is still alive.
    pub fn shutdown(self: *PoolRpc) error{ ServerStillActive, PendingCallbacks }!void {
        self.stopAccepting();
        self.lockCalls();
        const active_server_calls = self.calls.count();
        self.unlockCalls();
        if (active_server_calls != 0) return error.ServerStillActive;
        self.service.raftor.stop();
        if (self.pendingCallCount() != 0) return error.PendingCallbacks;
    }

    pub fn deinit(self: *PoolRpc) void {
        std.debug.assert(!self.accepting.load(.acquire));
        std.debug.assert(self.pendingCallCount() == 0);
        std.debug.assert(self.calls.count() == 0);
        self.calls.deinit(self.allocator);
        self.* = undefined;
    }

    const Method = enum { create, get, list };

    fn handler(self: *PoolRpc, comptime method: Method) grpc.ServerStreamHandler {
        return .{
            .context = self,
            .initial_metadata_mode = .explicit,
            .on_start = onStart,
            .on_message = switch (method) {
                .create => onCreate,
                .get => onGet,
                .list => onList,
            },
            .on_remote_end = onRemoteEnd,
            .on_cancel = onCancel,
            .on_terminal = onTerminal,
        };
    }

    fn onStart(ctx: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        const self: *PoolRpc = @ptrCast(@alignCast(ctx.?));
        var call = try stream.retain();
        const pending = self.allocator.create(InboundCall) catch |err| {
            call.deinit();
            return err;
        };
        pending.* = .{ .owner = self, .call = call };
        self.lockCalls();
        const rejection: ?grpc.Status = if (!self.accepting.load(.acquire))
            grpc.Status.init(.unavailable, "control plane is shutting down")
        else if (self.pending_calls.load(.acquire) >= max_pending_rpc_calls)
            grpc.Status.init(.resource_exhausted, "too many pending RPCs")
        else
            null;
        if (rejection) |status| {
            self.unlockCalls();
            defer call.deinit();
            defer self.allocator.destroy(pending);
            try call.sendInitialMetadata(&.{}, .identity);
            try call.finish(status, &.{});
            return;
        }
        self.calls.putNoClobber(self.allocator, stream.id(), pending) catch |err| {
            self.unlockCalls();
            call.deinit();
            self.allocator.destroy(pending);
            return err;
        };
        _ = self.pending_calls.fetchAdd(1, .monotonic);
        self.unlockCalls();
    }

    fn onCreate(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .create, stream, payload);
    }

    fn onGet(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .get, stream, payload);
    }

    fn onList(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .list, stream, payload);
    }

    fn receive(
        ctx: ?*anyopaque,
        method: Method,
        stream: grpc.ServerStream,
        payload: []const u8,
    ) !grpc.StreamReceiveAction {
        const self: *PoolRpc = @ptrCast(@alignCast(ctx.?));
        self.lockCalls();
        const pending = self.calls.get(stream.id()) orelse {
            self.unlockCalls();
            return .pause;
        };
        if (pending.payload != null or payload.len > max_request_wire_bytes) {
            pending.invalid_cardinality = true;
            self.unlockCalls();
            return .continue_receiving;
        }
        self.unlockCalls();

        const owned_payload = try self.allocator.dupe(u8, payload);
        self.lockCalls();
        const current = self.calls.get(stream.id()) orelse {
            self.unlockCalls();
            self.allocator.free(owned_payload);
            return .pause;
        };
        if (current.payload == null) {
            current.payload = owned_payload;
            current.method = method;
        } else {
            current.invalid_cardinality = true;
            self.allocator.free(owned_payload);
        }
        self.unlockCalls();
        return .continue_receiving;
    }

    fn onRemoteEnd(ctx: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) !void {
        const self: *PoolRpc = @ptrCast(@alignCast(ctx.?));
        const pending = self.removeCall(stream.id()) orelse return;
        if (pending.invalid_cardinality or pending.payload == null) {
            pending.completion().invoke(.{ .status = grpc.Status.init(.invalid_argument, "exactly one request message is required") });
            return;
        }
        if (!self.accepting.load(.acquire)) {
            pending.completion().invoke(.{ .status = grpc.Status.init(.unavailable, "control plane is shutting down") });
            return;
        }

        const payload = pending.payload.?;
        pending.payload = null;
        defer self.allocator.free(payload);
        switch (pending.method) {
            .create => self.service.createPool(payload, pending.completion()),
            .get => self.service.getPool(payload, pending.completion()),
            .list => self.service.listPools(payload, pending.completion()),
        }
    }

    fn onCancel(ctx: ?*anyopaque, stream: grpc.ServerStream, _: *grpc.ServerContext) void {
        const self: *PoolRpc = @ptrCast(@alignCast(ctx.?));
        if (self.removeCall(stream.id())) |pending| pending.destroy();
    }

    fn onTerminal(ctx: ?*anyopaque, id: grpc.ServerCallId, _: grpc.ServerTerminalReason) void {
        const self: *PoolRpc = @ptrCast(@alignCast(ctx.?));
        if (self.removeCall(id)) |pending| pending.destroy();
    }

    fn removeCall(self: *PoolRpc, id: grpc.ServerCallId) ?*InboundCall {
        self.lockCalls();
        defer self.unlockCalls();
        return if (self.calls.fetchRemove(id)) |entry| entry.value else null;
    }

    fn lockCalls(self: *PoolRpc) void {
        while (!self.calls_lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockCalls(self: *PoolRpc) void {
        self.calls_lock.unlock();
    }
};

const InboundCall = struct {
    owner: *PoolRpc,
    call: grpc.ServerCall,
    payload: ?[]u8 = null,
    method: PoolRpc.Method = .create,
    invalid_cardinality: bool = false,

    fn completion(self: *InboundCall) Completion {
        return .{ .ctx = self, .function = complete };
    }

    fn complete(ctx: *anyopaque, result: RpcResult) void {
        const self: *InboundCall = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        if (self.call.isCancelled() or self.call.isTerminal()) return;
        self.call.sendInitialMetadata(&.{}, .identity) catch return;
        if (result.status.isOk()) {
            self.call.send(result.payload, .{}) catch {
                self.call.finish(grpc.Status.init(.internal, "response send failed"), &.{}) catch {};
                return;
            };
        }
        self.call.finish(result.status, &.{}) catch {};
    }

    fn destroy(self: *InboundCall) void {
        const owner = self.owner;
        if (self.payload) |payload| owner.allocator.free(payload);
        self.call.deinit();
        _ = owner.pending_calls.fetchSub(1, .release);
        owner.allocator.destroy(self);
    }
};

fn preflightCreatePoolRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 4;
    while (try cursor.next()) |field| {
        if (field.number > 3) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (field.wire_type != 2) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (!validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (!validText(try cursor.readBytes(state_machine.max_name_bytes), state_machine.max_name_bytes, false)) return error.InvalidWire,
            3 => if (!validText(try cursor.readBytes(state_machine.max_description_bytes), state_machine.max_description_bytes, true)) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2]) return error.InvalidWire;
}

fn preflightGetPoolRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_selector = false;
    while (try cursor.next()) |field| {
        if (field.number > 2) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (field.wire_type != 2) return error.InvalidWire;
        seen_selector = true;
        switch (field.number) {
            1 => if (!validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (!validText(try cursor.readBytes(state_machine.max_name_bytes), state_machine.max_name_bytes, false)) return error.InvalidWire,
            else => return error.InvalidWire,
        }
    }
    if (!seen_selector) return error.InvalidWire;
}

fn preflightListPoolsRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 3;
    while (try cursor.next()) |field| {
        if (field.number > 2) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u32)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
}

fn validText(value: []const u8, max_bytes: usize, allow_empty: bool) bool {
    return (allow_empty or value.len != 0) and value.len <= max_bytes and std.unicode.utf8ValidateSlice(value);
}

fn validUuidV7(value: []const u8) bool {
    const parsed = uuid.urn.deserialize(value) catch return false;
    const canonical = uuid.urn.serialize(parsed);
    return canonical[14] == '7' and std.mem.eql(u8, value, &canonical);
}

fn encodeMessage(allocator: std.mem.Allocator, message: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    message.encode(&output.writer, allocator) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn deinitSelector(allocator: std.mem.Allocator, selector: GetPending.Selector) void {
    switch (selector) {
        .id => |id| allocator.free(id),
        .name => |name| allocator.free(name),
    }
}

fn invalidArgument(message: []const u8) RpcResult {
    return .{ .status = grpc.Status.init(.invalid_argument, message) };
}

fn decodeFailure(err: anyerror, invalid_message: []const u8) RpcResult {
    return if (err == error.OutOfMemory) internalError() else invalidArgument(invalid_message);
}

fn notLeader() RpcResult {
    return .{ .status = grpc.Status.init(.unavailable, "node is not the Raft leader") };
}

fn internalError() RpcResult {
    return .{ .status = grpc.Status.init(.internal, "control plane operation failed") };
}

fn raftFailure(err: raft.Error) RpcResult {
    return .{ .status = switch (err) {
        error.ProposalBackpressure, error.ReadIndexBackpressure => grpc.Status.init(.resource_exhausted, "Raft request queue is full"),
        error.ProposalDropped, error.LostLeadership => grpc.Status.init(.unavailable, "Raft leadership changed"),
        error.ShuttingDown => grpc.Status.init(.unavailable, "control plane is shutting down"),
        error.Timeout => grpc.Status.init(.unavailable, "Raft operation timed out"),
        else => grpc.Status.init(.internal, "Raft operation failed"),
    } };
}

const CompletionProbe = struct {
    allocator: std.mem.Allocator,
    completed: bool = false,
    code: grpc.StatusCode = .unknown,
    payload: []u8 = &.{},

    fn deinit(self: *CompletionProbe) void {
        if (self.payload.len != 0) self.allocator.free(self.payload);
    }

    fn completion(self: *CompletionProbe) Completion {
        return .{ .ctx = self, .function = complete };
    }

    fn complete(ctx: *anyopaque, result: RpcResult) void {
        const self: *CompletionProbe = @ptrCast(@alignCast(ctx));
        self.completed = true;
        self.code = result.status.code;
        self.payload = self.allocator.dupe(u8, result.payload) catch &.{};
    }
};

test "Pool service rejects unbounded follower-forwarding Raft policy" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
    defer raftor.destroy();
    try std.testing.expectError(
        error.UnsafeRaftConfiguration,
        PoolService.init(allocator, std.testing.io, raftor, &machine),
    );
}

test "Pool service gates followers and completes linearizable CRUD reads" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    config.raft.election_timeout_seed = 42;
    config.raft.check_quorum = true;
    config.raft.disable_proposal_forwarding = true;
    config.proposal_timeout_ticks = 32;
    config.read_index_timeout_ticks = 32;
    const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
    defer raftor.destroy();
    var service = try PoolService.init(allocator, std.testing.io, raftor, &machine);

    const create_payload = try encodeMessage(allocator, pb.CreatePoolRequest{
        .request_id = "request-1",
        .name = "primary",
        .description = "Primary storage pool",
    });
    defer allocator.free(create_payload);
    var follower_probe = CompletionProbe{ .allocator = allocator };
    defer follower_probe.deinit();
    service.createPool(create_payload, follower_probe.completion());
    try std.testing.expect(follower_probe.completed);
    try std.testing.expectEqual(grpc.StatusCode.unavailable, follower_probe.code);

    try raftor.campaign();
    var create_probe = CompletionProbe{ .allocator = allocator };
    defer create_probe.deinit();
    service.createPool(create_payload, create_probe.completion());
    for (0..32) |_| {
        if (create_probe.completed) break;
        _ = try raftor.tick();
    }
    try std.testing.expect(create_probe.completed);
    try std.testing.expectEqual(grpc.StatusCode.ok, create_probe.code);
    var create_reader: std.Io.Reader = .fixed(create_probe.payload);
    var create_response = try pb.CreatePoolResponse.decode(&create_reader, allocator);
    defer create_response.deinit(allocator);
    try std.testing.expectEqualStrings("primary", create_response.pool.?.name);

    const second_create_payload = try encodeMessage(allocator, pb.CreatePoolRequest{
        .request_id = "request-2",
        .name = "secondary",
    });
    defer allocator.free(second_create_payload);
    var second_create_probe = CompletionProbe{ .allocator = allocator };
    defer second_create_probe.deinit();
    service.createPool(second_create_payload, second_create_probe.completion());
    for (0..32) |_| {
        if (second_create_probe.completed) break;
        _ = try raftor.tick();
    }
    try std.testing.expectEqual(grpc.StatusCode.ok, second_create_probe.code);

    const get_payload = try encodeMessage(allocator, pb.GetPoolRequest{ .selector = .{ .name = "primary" } });
    defer allocator.free(get_payload);
    var get_probe = CompletionProbe{ .allocator = allocator };
    defer get_probe.deinit();
    service.getPool(get_payload, get_probe.completion());
    for (0..32) |_| {
        if (get_probe.completed) break;
        _ = try raftor.tick();
    }
    try std.testing.expect(get_probe.completed);
    try std.testing.expectEqual(grpc.StatusCode.ok, get_probe.code);

    const list_payload = try encodeMessage(allocator, pb.ListPoolsRequest{ .page_size = 1 });
    defer allocator.free(list_payload);
    var list_probe = CompletionProbe{ .allocator = allocator };
    defer list_probe.deinit();
    service.listPools(list_payload, list_probe.completion());
    for (0..32) |_| {
        if (list_probe.completed) break;
        _ = try raftor.tick();
    }
    try std.testing.expect(list_probe.completed);
    try std.testing.expectEqual(grpc.StatusCode.ok, list_probe.code);
    var list_reader: std.Io.Reader = .fixed(list_probe.payload);
    var list_response = try pb.ListPoolsResponse.decode(&list_reader, allocator);
    defer list_response.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list_response.pools.items.len);
    try std.testing.expectEqualStrings("primary", list_response.pools.items[0].name);
    try std.testing.expectEqual(@as(usize, 36), list_response.next_page_token.len);

    const second_page_payload = try encodeMessage(allocator, pb.ListPoolsRequest{
        .page_size = 1,
        .page_token = list_response.next_page_token,
    });
    defer allocator.free(second_page_payload);
    var second_page_probe = CompletionProbe{ .allocator = allocator };
    defer second_page_probe.deinit();
    service.listPools(second_page_payload, second_page_probe.completion());
    for (0..32) |_| {
        if (second_page_probe.completed) break;
        _ = try raftor.tick();
    }
    try std.testing.expectEqual(grpc.StatusCode.ok, second_page_probe.code);
    var second_page_reader: std.Io.Reader = .fixed(second_page_probe.payload);
    var second_page_response = try pb.ListPoolsResponse.decode(&second_page_reader, allocator);
    defer second_page_response.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), second_page_response.pools.items.len);
    try std.testing.expectEqualStrings("secondary", second_page_response.pools.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), second_page_response.next_page_token.len);
}

const RaftDriver = struct {
    raftor: *raft.Raftor,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *RaftDriver) void {
        self.raftor.run() catch |err| {
            if (err != error.ShuttingDown) self.failed.store(true, .release);
        };
    }
};

const StreamProbe = struct {
    completed: std.atomic.Value(bool) = .init(false),
    code: std.atomic.Value(u8) = .init(@intFromEnum(grpc.StatusCode.unknown)),

    fn onMessage(_: ?*anyopaque, _: grpc.ClientStream, _: []const u8, _: grpc.Compression) grpc.StreamReceiveAction {
        return .continue_receiving;
    }

    fn onTerminal(
        ctx: ?*anyopaque,
        _: grpc.ClientStream,
        status: grpc.Status,
        _: *const grpc.Metadata,
    ) void {
        const self: *StreamProbe = @ptrCast(@alignCast(ctx.?));
        self.code.store(@intFromEnum(status.code), .release);
        self.completed.store(true, .release);
    }
};

test "raw unary client reaches asynchronous Pool RPC" {
    const allocator = std.heap.smp_allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    config.raft.election_timeout_seed = 42;
    config.raft.check_quorum = true;
    config.raft.disable_proposal_forwarding = true;
    config.proposal_timeout_ticks = 32;
    config.read_index_timeout_ticks = 32;
    const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
    defer raftor.destroy();
    try raftor.campaign();

    var pool_service = try PoolService.init(allocator, std.testing.io, raftor, &machine);
    var pool_rpc = PoolRpc.init(allocator, &pool_service);
    var server = try grpc.Server.init(allocator, .{});
    try pool_rpc.register(&server);
    try server.start();
    var driver = RaftDriver{ .raftor = raftor };
    const run_thread = try std.Thread.spawn(.{}, RaftDriver.run, .{&driver});
    var shutdown_complete = false;
    defer if (!shutdown_complete) {
        pool_rpc.stopAccepting();
        server.shutdown();
        server.wait();
        pool_rpc.shutdown() catch {};
        run_thread.join();
        pool_rpc.deinit();
        server.deinit();
    };

    const target = try std.fmt.allocPrint(allocator, "127.0.0.1:{}", .{try server.port()});
    defer allocator.free(target);
    var channel = try grpc.Channel.init(allocator, target, .{});
    defer channel.deinit();
    const request = try encodeMessage(allocator, pb.CreatePoolRequest{
        .request_id = "grpc-request-1",
        .name = "grpc-primary",
    });
    defer allocator.free(request);
    var result = try channel.callUnary(
        allocator,
        "/zettide.control.v1.PoolService/CreatePool",
        request,
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, result.status.code);
    var response_reader: std.Io.Reader = .fixed(result.payload);
    var response = try pb.CreatePoolResponse.decode(&response_reader, allocator);
    defer response.deinit(allocator);
    try std.testing.expectEqualStrings("grpc-primary", response.pool.?.name);

    const multi_request = try encodeMessage(allocator, pb.CreatePoolRequest{
        .request_id = "grpc-multi-1",
        .name = "must-not-exist",
    });
    defer allocator.free(multi_request);
    var stream_probe = StreamProbe{};
    var stream = try channel.openStream(
        "/zettide.control.v1.PoolService/CreatePool",
        .{ .timeout_ns = 5 * std.time.ns_per_s },
        .{
            .context = &stream_probe,
            .on_message = StreamProbe.onMessage,
            .on_terminal = StreamProbe.onTerminal,
        },
    );
    defer stream.deinit();
    try stream.send(multi_request, .{});
    try stream.send(multi_request, .{});
    try stream.closeSend();
    while (!stream_probe.completed.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectEqual(
        grpc.StatusCode.invalid_argument,
        grpc.StatusCode.fromInt(stream_probe.code.load(.acquire)),
    );
    try std.testing.expectEqual(@as(usize, 1), machine.poolCount());

    pool_rpc.stopAccepting();
    server.shutdownGracefully(std.time.ns_per_s);
    server.wait();
    try pool_rpc.shutdown();
    run_thread.join();
    pool_rpc.deinit();
    server.deinit();
    shutdown_complete = true;
    try std.testing.expect(!driver.failed.load(.acquire));
}
