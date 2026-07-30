const std = @import("std");

const grpc = @import("grpc_lite");
const pb = @import("control_proto");
const raft = @import("raft_zig");
const uuid = @import("uuid");
const heartbeat = @import("heartbeat.zig");
const state_machine = @import("state_machine.zig");
const wire = @import("protobuf_wire.zig");

pub const default_page_size: usize = 100;
pub const max_page_size: usize = 1000;
pub const max_pending_rpc_calls: usize = 1024;

const max_request_wire_bytes: usize = 4096;
pub const max_heartbeat_request_wire_bytes: usize = 32768;

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
    heartbeat_store: *heartbeat.HeartbeatStore,
    expected_cluster_id: raft.ClusterId,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        raftor: *raft.Raftor,
        machine: *state_machine.PoolStateMachine,
        heartbeat_store: *heartbeat.HeartbeatStore,
        expected_cluster_id: raft.ClusterId,
    ) error{ UnsafeRaftConfiguration, UnsafeHeartbeatConfiguration }!PoolService {
        if (!raftor.leaderServicePolicy().isSafe()) return error.UnsafeRaftConfiguration;
        if (!machine.hasHeartbeatStore(heartbeat_store)) return error.UnsafeHeartbeatConfiguration;
        return .{
            .allocator = allocator,
            .io = io,
            .raftor = raftor,
            .machine = machine,
            .heartbeat_store = heartbeat_store,
            .expected_cluster_id = expected_cluster_id,
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

    pub fn registerNode(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightRegisterNodeRequest(payload) catch {
            completion.invoke(invalidArgument("invalid RegisterNode request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.RegisterNodeRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid RegisterNode request"));
            return;
        };
        defer request.deinit(arena.allocator());
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }
        if (!std.mem.eql(u8, request.cluster_id, &self.expected_cluster_id)) {
            completion.invoke(.{ .status = grpc.Status.init(.failed_precondition, "cluster_id does not match this cluster") });
            return;
        }

        const timestamp = std.math.cast(i64, std.Io.Timestamp.now(self.io, .real).toMilliseconds()) orelse {
            completion.invoke(internalError());
            return;
        };
        const command = state_machine.encodeRegisterNodeCommand(self.allocator, .{
            .request_id = request.request_id,
            .node_id = request.node_id,
            .cluster_id = request.cluster_id,
            .control_endpoint = request.control_endpoint,
            .nvmf_endpoint = request.nvmf_endpoint,
            .failure_domain = request.failure_domain,
            .capability_bits = request.capability_bits,
            .protocol_version = request.protocol_version,
            .proposed_registered_at_unix_ms = timestamp,
        }) catch {
            completion.invoke(internalError());
            return;
        };
        defer self.allocator.free(command);

        const pending = self.allocator.create(RegisterNodePending) catch {
            completion.invoke(internalError());
            return;
        };
        pending.* = .{ .owner = self, .completion = completion };
        self.raftor.propose(command, pending.callback()) catch |err| {
            self.allocator.destroy(pending);
            completion.invoke(raftFailure(err));
        };
    }

    pub fn getNode(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightGetNodeRequest(payload) catch {
            completion.invoke(invalidArgument("invalid GetNode request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.GetNodeRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid GetNode request"));
            return;
        };
        defer request.deinit(arena.allocator());
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }

        const node_id = self.allocator.dupe(u8, request.node_id) catch {
            completion.invoke(internalError());
            return;
        };
        const pending = self.allocator.create(GetNodePending) catch {
            self.allocator.free(node_id);
            completion.invoke(internalError());
            return;
        };
        pending.* = .{ .owner = self, .completion = completion, .node_id = node_id };
        self.raftor.readIndex("get-node", pending.callback()) catch |err| {
            pending.destroy();
            completion.invoke(raftFailure(err));
        };
    }

    pub fn listNodes(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightListNodesRequest(payload) catch {
            completion.invoke(invalidArgument("invalid ListNodes request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.ListNodesRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid ListNodes request"));
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
        const pending = self.allocator.create(ListNodesPending) catch {
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
        self.raftor.readIndex("list-nodes", pending.callback()) catch |err| {
            pending.destroy();
            completion.invoke(raftFailure(err));
        };
    }

    pub fn registerMember(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightRegisterMemberRequest(payload) catch {
            completion.invoke(invalidArgument("invalid RegisterMember request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.RegisterMemberRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid RegisterMember request"));
            return;
        };
        defer request.deinit(arena.allocator());
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }
        if (!std.mem.eql(u8, request.cluster_id, &self.expected_cluster_id)) {
            completion.invoke(.{ .status = grpc.Status.init(.failed_precondition, "cluster_id does not match this cluster") });
            return;
        }

        const timestamp = std.math.cast(i64, std.Io.Timestamp.now(self.io, .real).toMilliseconds()) orelse {
            completion.invoke(internalError());
            return;
        };
        const command = state_machine.encodeRegisterMemberCommand(self.allocator, .{
            .request_id = request.request_id,
            .cluster_id = request.cluster_id,
            .member_id = request.member_id,
            .pool_id = request.pool_id,
            .node_id = request.node_id,
            .local_set_id = request.local_set_id,
            .member_slot = request.member_slot,
            .birth_topology_digest = request.birth_topology_digest,
            .metadata_capacity_bytes = request.metadata_capacity_bytes,
            .data_capacity_bytes = request.data_capacity_bytes,
            .extent_size_bytes = request.extent_size_bytes,
            .proposed_registered_at_unix_ms = timestamp,
        }) catch {
            completion.invoke(internalError());
            return;
        };
        defer self.allocator.free(command);

        const pending = self.allocator.create(RegisterMemberPending) catch {
            completion.invoke(internalError());
            return;
        };
        pending.* = .{ .owner = self, .completion = completion };
        self.raftor.propose(command, pending.callback()) catch |err| {
            self.allocator.destroy(pending);
            completion.invoke(raftFailure(err));
        };
    }

    pub fn getMember(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightGetMemberRequest(payload) catch {
            completion.invoke(invalidArgument("invalid GetMember request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.GetMemberRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid GetMember request"));
            return;
        };
        defer request.deinit(arena.allocator());
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }

        const member_id = self.allocator.dupe(u8, request.member_id) catch {
            completion.invoke(internalError());
            return;
        };
        const pending = self.allocator.create(GetMemberPending) catch {
            self.allocator.free(member_id);
            completion.invoke(internalError());
            return;
        };
        pending.* = .{ .owner = self, .completion = completion, .member_id = member_id };
        self.raftor.readIndex("get-member", pending.callback()) catch |err| {
            pending.destroy();
            completion.invoke(raftFailure(err));
        };
    }

    pub fn listMembers(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightListMembersRequest(payload) catch {
            completion.invoke(invalidArgument("invalid ListMembers request"));
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.ListMembersRequest.decode(&reader, arena.allocator()) catch |err| {
            completion.invoke(decodeFailure(err, "invalid ListMembers request"));
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
        const pending = self.allocator.create(ListMembersPending) catch {
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
        self.raftor.readIndex("list-members", pending.callback()) catch |err| {
            pending.destroy();
            completion.invoke(raftFailure(err));
        };
    }

    pub fn reportHeartbeat(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightReportHeartbeatRequest(payload) catch {
            completion.invoke(invalidArgument("invalid ReportHeartbeat request"));
            return;
        };
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.ReportHeartbeatRequest.decode(&reader, self.allocator) catch |err| {
            completion.invoke(decodeFailure(err, "invalid ReportHeartbeat request"));
            return;
        };
        const pending = self.allocator.create(ReportHeartbeatPending) catch {
            request.deinit(self.allocator);
            completion.invoke(internalError());
            return;
        };
        pending.* = .{ .owner = self, .completion = completion, .request = request };
        self.raftor.readIndex("report-heartbeat", pending.callback()) catch |err| {
            pending.destroy();
            completion.invoke(raftFailure(err));
        };
    }

    pub fn getHeartbeat(self: *PoolService, payload: []const u8, completion: Completion) void {
        preflightGetHeartbeatRequest(payload) catch {
            completion.invoke(invalidArgument("invalid GetHeartbeat request"));
            return;
        };
        if (!self.isLeader()) {
            completion.invoke(notLeader());
            return;
        }
        var reader: std.Io.Reader = .fixed(payload);
        var request = pb.GetHeartbeatRequest.decode(&reader, self.allocator) catch |err| {
            completion.invoke(decodeFailure(err, "invalid GetHeartbeat request"));
            return;
        };
        const pending = self.allocator.create(GetHeartbeatPending) catch {
            request.deinit(self.allocator);
            completion.invoke(internalError());
            return;
        };
        pending.* = .{ .owner = self, .completion = completion, .request = request };
        self.raftor.readIndex("get-heartbeat", pending.callback()) catch |err| {
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

const RegisterNodePending = struct {
    owner: *PoolService,
    completion: Completion,

    fn callback(self: *RegisterNodePending) raft.ProposalCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn complete(ctx: *anyopaque, result: raft.ProposalResult) void {
        const self: *RegisterNodePending = @ptrCast(@alignCast(ctx));
        defer self.owner.allocator.destroy(self);
        switch (result) {
            .ok => |payload| self.completeApplied(payload),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeApplied(self: *RegisterNodePending, payload: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.owner.allocator);
        defer arena.deinit();
        var response = state_machine.decodeRegisterNodeApplyResponse(arena.allocator(), payload) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer response.deinit(arena.allocator());
        switch (response.code) {
            .REGISTER_NODE_APPLY_CODE_REGISTERED => {
                const node = response.node orelse {
                    self.completion.invoke(internalError());
                    return;
                };
                const encoded = encodeMessage(self.owner.allocator, pb.RegisterNodeResponse{ .node = node }) catch {
                    self.completion.invoke(internalError());
                    return;
                };
                defer self.owner.allocator.free(encoded);
                self.completion.invoke(.{ .status = .ok, .payload = encoded });
            },
            .REGISTER_NODE_APPLY_CODE_ID_EXISTS => self.completion.invoke(.{
                .status = grpc.Status.init(.already_exists, "Node ID already exists"),
            }),
            .REGISTER_NODE_APPLY_CODE_REQUEST_CONFLICT => self.completion.invoke(.{
                .status = grpc.Status.init(.failed_precondition, "request_id was reused with different fields"),
            }),
            .REGISTER_NODE_APPLY_CODE_REQUEST_LIMIT => self.completion.invoke(.{
                .status = grpc.Status.init(.resource_exhausted, "request history limit reached"),
            }),
            .REGISTER_NODE_APPLY_CODE_NODE_LIMIT => self.completion.invoke(.{
                .status = grpc.Status.init(.resource_exhausted, "Node limit reached"),
            }),
            else => self.completion.invoke(internalError()),
        }
    }
};

const GetNodePending = struct {
    owner: *PoolService,
    completion: Completion,
    node_id: []u8,

    fn callback(self: *GetNodePending) raft.ReadIndexCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn destroy(self: *GetNodePending) void {
        const allocator = self.owner.allocator;
        allocator.free(self.node_id);
        allocator.destroy(self);
    }

    fn complete(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *GetNodePending = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        switch (result) {
            .ok => self.completeRead(),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeRead(self: *GetNodePending) void {
        var node = self.owner.machine.getNodeById(self.owner.allocator, self.node_id) catch {
            self.completion.invoke(internalError());
            return;
        } orelse {
            self.completion.invoke(.{ .status = grpc.Status.init(.not_found, "Node not found") });
            return;
        };
        defer node.deinit(self.owner.allocator);
        const encoded = encodeMessage(self.owner.allocator, pb.GetNodeResponse{ .node = node }) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer self.owner.allocator.free(encoded);
        self.completion.invoke(.{ .status = .ok, .payload = encoded });
    }
};

const ListNodesPending = struct {
    owner: *PoolService,
    completion: Completion,
    page_size: usize,
    after_id: ?[]u8,

    fn callback(self: *ListNodesPending) raft.ReadIndexCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn destroy(self: *ListNodesPending) void {
        const allocator = self.owner.allocator;
        if (self.after_id) |id| allocator.free(id);
        allocator.destroy(self);
    }

    fn complete(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *ListNodesPending = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        switch (result) {
            .ok => self.completeRead(),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeRead(self: *ListNodesPending) void {
        var result = self.owner.machine.listNodesPage(
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
        const page_items = result.nodes;
        const page: std.ArrayList(pb.Node) = .{ .items = page_items, .capacity = page_items.len };
        const next_token: []const u8 = if (result.has_more) page_items[page_items.len - 1].id else &.{};
        const encoded = encodeMessage(self.owner.allocator, pb.ListNodesResponse{
            .nodes = page,
            .next_page_token = next_token,
        }) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer self.owner.allocator.free(encoded);
        self.completion.invoke(.{ .status = .ok, .payload = encoded });
    }
};

const RegisterMemberPending = struct {
    owner: *PoolService,
    completion: Completion,

    fn callback(self: *RegisterMemberPending) raft.ProposalCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn complete(ctx: *anyopaque, result: raft.ProposalResult) void {
        const self: *RegisterMemberPending = @ptrCast(@alignCast(ctx));
        defer self.owner.allocator.destroy(self);
        switch (result) {
            .ok => |payload| self.completeApplied(payload),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeApplied(self: *RegisterMemberPending, payload: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.owner.allocator);
        defer arena.deinit();
        var response = state_machine.decodeRegisterMemberApplyResponse(arena.allocator(), payload) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer response.deinit(arena.allocator());
        switch (response.code) {
            .REGISTER_MEMBER_APPLY_CODE_REGISTERED => {
                const member = response.member orelse {
                    self.completion.invoke(internalError());
                    return;
                };
                const encoded = encodeMessage(self.owner.allocator, pb.RegisterMemberResponse{ .member = member }) catch {
                    self.completion.invoke(internalError());
                    return;
                };
                defer self.owner.allocator.free(encoded);
                self.completion.invoke(.{ .status = .ok, .payload = encoded });
            },
            .REGISTER_MEMBER_APPLY_CODE_REQUEST_CONFLICT => self.completion.invoke(.{
                .status = grpc.Status.init(.failed_precondition, "request_id was reused with different fields"),
            }),
            .REGISTER_MEMBER_APPLY_CODE_CLUSTER_MISMATCH => self.completion.invoke(.{
                .status = grpc.Status.init(.failed_precondition, "Node cluster does not match member cluster"),
            }),
            .REGISTER_MEMBER_APPLY_CODE_LOCAL_SET_CONFLICT => self.completion.invoke(.{
                .status = grpc.Status.init(.failed_precondition, "local_set_id belongs to another Pool"),
            }),
            .REGISTER_MEMBER_APPLY_CODE_ID_EXISTS => self.completion.invoke(.{
                .status = grpc.Status.init(.already_exists, "Member ID already exists"),
            }),
            .REGISTER_MEMBER_APPLY_CODE_SLOT_EXISTS => self.completion.invoke(.{
                .status = grpc.Status.init(.already_exists, "Member slot already exists"),
            }),
            .REGISTER_MEMBER_APPLY_CODE_POOL_NOT_FOUND => self.completion.invoke(.{
                .status = grpc.Status.init(.not_found, "Pool not found"),
            }),
            .REGISTER_MEMBER_APPLY_CODE_NODE_NOT_FOUND => self.completion.invoke(.{
                .status = grpc.Status.init(.not_found, "Node not found"),
            }),
            .REGISTER_MEMBER_APPLY_CODE_REQUEST_LIMIT => self.completion.invoke(.{
                .status = grpc.Status.init(.resource_exhausted, "request history limit reached"),
            }),
            .REGISTER_MEMBER_APPLY_CODE_MEMBER_LIMIT => self.completion.invoke(.{
                .status = grpc.Status.init(.resource_exhausted, "Member limit reached"),
            }),
            else => self.completion.invoke(internalError()),
        }
    }
};

const GetMemberPending = struct {
    owner: *PoolService,
    completion: Completion,
    member_id: []u8,

    fn callback(self: *GetMemberPending) raft.ReadIndexCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn destroy(self: *GetMemberPending) void {
        const allocator = self.owner.allocator;
        allocator.free(self.member_id);
        allocator.destroy(self);
    }

    fn complete(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *GetMemberPending = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        switch (result) {
            .ok => self.completeRead(),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeRead(self: *GetMemberPending) void {
        var member = self.owner.machine.getMemberById(self.owner.allocator, self.member_id) catch {
            self.completion.invoke(internalError());
            return;
        } orelse {
            self.completion.invoke(.{ .status = grpc.Status.init(.not_found, "Member not found") });
            return;
        };
        defer member.deinit(self.owner.allocator);
        const encoded = encodeMessage(self.owner.allocator, pb.GetMemberResponse{ .member = member }) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer self.owner.allocator.free(encoded);
        self.completion.invoke(.{ .status = .ok, .payload = encoded });
    }
};

const ListMembersPending = struct {
    owner: *PoolService,
    completion: Completion,
    page_size: usize,
    after_id: ?[]u8,

    fn callback(self: *ListMembersPending) raft.ReadIndexCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn destroy(self: *ListMembersPending) void {
        const allocator = self.owner.allocator;
        if (self.after_id) |id| allocator.free(id);
        allocator.destroy(self);
    }

    fn complete(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *ListMembersPending = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        switch (result) {
            .ok => self.completeRead(),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeRead(self: *ListMembersPending) void {
        var result = self.owner.machine.listMembersPage(
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
        const page_items = result.members;
        const page: std.ArrayList(pb.Member) = .{ .items = page_items, .capacity = page_items.len };
        const next_token: []const u8 = if (result.has_more) page_items[page_items.len - 1].id else &.{};
        const encoded = encodeMessage(self.owner.allocator, pb.ListMembersResponse{
            .members = page,
            .next_page_token = next_token,
        }) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer self.owner.allocator.free(encoded);
        self.completion.invoke(.{ .status = .ok, .payload = encoded });
    }
};

const ReportHeartbeatPending = struct {
    owner: *PoolService,
    completion: Completion,
    request: pb.ReportHeartbeatRequest,

    fn callback(self: *ReportHeartbeatPending) raft.ReadIndexCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn destroy(self: *ReportHeartbeatPending) void {
        const allocator = self.owner.allocator;
        self.request.deinit(allocator);
        allocator.destroy(self);
    }

    fn complete(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *ReportHeartbeatPending = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        switch (result) {
            .ok => self.completeRead(),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeRead(self: *ReportHeartbeatPending) void {
        const term = currentHeartbeatTerm(self.owner) orelse {
            self.completion.invoke(notLeader());
            return;
        };
        switch (self.owner.machine.validateHeartbeatBinding(self.request)) {
            .node_not_found => {
                self.completion.invoke(.{ .status = grpc.Status.init(.not_found, "Node not found") });
                return;
            },
            .member_not_found => {
                self.completion.invoke(.{ .status = grpc.Status.init(.not_found, "Member not found") });
                return;
            },
            .binding_mismatch => {
                self.completion.invoke(.{ .status = grpc.Status.init(.failed_precondition, "heartbeat binding does not match registration") });
                return;
            },
            .capacity_mismatch => {
                self.completion.invoke(.{ .status = grpc.Status.init(.failed_precondition, "heartbeat capacity does not match registration") });
                return;
            },
            .ok => {},
        }
        const accepted_at_ms = std.math.cast(u64, std.Io.Timestamp.now(self.owner.io, .awake).toMilliseconds()) orelse {
            self.completion.invoke(internalError());
            return;
        };
        const accepted_at_unix_ms = std.math.cast(i64, std.Io.Timestamp.now(self.owner.io, .real).toMilliseconds()) orelse {
            self.completion.invoke(internalError());
            return;
        };
        const result = self.owner.heartbeat_store.report(
            self.request,
            term,
            accepted_at_ms,
            accepted_at_unix_ms,
        ) catch |err| {
            self.completion.invoke(heartbeatFailure(err));
            return;
        };
        const encoded = encodeMessage(self.owner.allocator, pb.ReportHeartbeatResponse{
            .observation = result.observation,
            .recommended_interval_ms = result.recommended_interval_ms,
            .stale_after_ms = result.stale_after_ms,
        }) catch {
            self.completion.invoke(internalError());
            return;
        };
        defer self.owner.allocator.free(encoded);
        self.completion.invoke(.{ .status = .ok, .payload = encoded });
    }
};

const GetHeartbeatPending = struct {
    owner: *PoolService,
    completion: Completion,
    request: pb.GetHeartbeatRequest,

    fn callback(self: *GetHeartbeatPending) raft.ReadIndexCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn destroy(self: *GetHeartbeatPending) void {
        const allocator = self.owner.allocator;
        self.request.deinit(allocator);
        allocator.destroy(self);
    }

    fn complete(ctx: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *GetHeartbeatPending = @ptrCast(@alignCast(ctx));
        defer self.destroy();
        switch (result) {
            .ok => self.completeRead(),
            .err => |err| self.completion.invoke(raftFailure(err)),
        }
    }

    fn completeRead(self: *GetHeartbeatPending) void {
        const term = currentHeartbeatTerm(self.owner) orelse {
            self.completion.invoke(notLeader());
            return;
        };
        const now_ms = std.math.cast(u64, std.Io.Timestamp.now(self.owner.io, .awake).toMilliseconds()) orelse {
            self.completion.invoke(internalError());
            return;
        };
        const result = self.owner.heartbeat_store.get(self.request.node_id, term, now_ms) catch |err| {
            self.completion.invoke(heartbeatFailure(err));
            return;
        } orelse {
            self.completion.invoke(.{ .status = grpc.Status.init(.not_found, "Heartbeat not found") });
            return;
        };
        const encoded = encodeMessage(self.owner.allocator, pb.GetHeartbeatResponse{
            .observation = result.observation,
            .freshness = result.freshness,
            .age_ms = result.age_ms,
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
        try server.registerStream("/zettide.control.v1.NodeService/RegisterNode", handler(self, .register_node));
        try server.registerStream("/zettide.control.v1.NodeService/GetNode", handler(self, .get_node));
        try server.registerStream("/zettide.control.v1.NodeService/ListNodes", handler(self, .list_nodes));
        try server.registerStream("/zettide.control.v1.MemberService/RegisterMember", handler(self, .register_member));
        try server.registerStream("/zettide.control.v1.MemberService/GetMember", handler(self, .get_member));
        try server.registerStream("/zettide.control.v1.MemberService/ListMembers", handler(self, .list_members));
        try server.registerStream("/zettide.control.v1.HeartbeatService/ReportHeartbeat", handler(self, .report_heartbeat));
        try server.registerStream("/zettide.control.v1.HeartbeatService/GetHeartbeat", handler(self, .get_heartbeat));
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

    const Method = enum {
        create,
        get,
        list,
        register_node,
        get_node,
        list_nodes,
        register_member,
        get_member,
        list_members,
        report_heartbeat,
        get_heartbeat,
    };

    fn handler(self: *PoolRpc, comptime method: Method) grpc.ServerStreamHandler {
        return .{
            .context = self,
            .initial_metadata_mode = .explicit,
            .on_start = onStart,
            .on_message = switch (method) {
                .create => onCreate,
                .get => onGet,
                .list => onList,
                .register_node => onRegisterNode,
                .get_node => onGetNode,
                .list_nodes => onListNodes,
                .register_member => onRegisterMember,
                .get_member => onGetMember,
                .list_members => onListMembers,
                .report_heartbeat => onReportHeartbeat,
                .get_heartbeat => onGetHeartbeat,
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

    fn onRegisterNode(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .register_node, stream, payload);
    }

    fn onGetNode(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .get_node, stream, payload);
    }

    fn onListNodes(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .list_nodes, stream, payload);
    }

    fn onRegisterMember(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .register_member, stream, payload);
    }

    fn onGetMember(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .get_member, stream, payload);
    }

    fn onListMembers(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .list_members, stream, payload);
    }

    fn onReportHeartbeat(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .report_heartbeat, stream, payload);
    }

    fn onGetHeartbeat(ctx: ?*anyopaque, stream: grpc.ServerStream, context: *grpc.ServerContext, payload: []const u8, _: grpc.Compression) !grpc.StreamReceiveAction {
        _ = context;
        return receive(ctx, .get_heartbeat, stream, payload);
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
        if (pending.payload != null or payload.len > requestWireLimit(method)) {
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
            .register_node => self.service.registerNode(payload, pending.completion()),
            .get_node => self.service.getNode(payload, pending.completion()),
            .list_nodes => self.service.listNodes(payload, pending.completion()),
            .register_member => self.service.registerMember(payload, pending.completion()),
            .get_member => self.service.getMember(payload, pending.completion()),
            .list_members => self.service.listMembers(payload, pending.completion()),
            .report_heartbeat => self.service.reportHeartbeat(payload, pending.completion()),
            .get_heartbeat => self.service.getHeartbeat(payload, pending.completion()),
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

    fn requestWireLimit(method: Method) usize {
        return switch (method) {
            .report_heartbeat => max_heartbeat_request_wire_bytes,
            else => max_request_wire_bytes,
        };
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
        sendRpcResult(self.call, result);
    }

    fn destroy(self: *InboundCall) void {
        const owner = self.owner;
        if (self.payload) |payload| owner.allocator.free(payload);
        self.call.deinit();
        _ = owner.pending_calls.fetchSub(1, .release);
        owner.allocator.destroy(self);
    }
};

fn sendRpcResult(call: grpc.ServerCall, result: RpcResult) void {
    call.sendInitialMetadata(&.{}, .identity) catch {
        call.abort();
        return;
    };
    if (result.status.isOk()) {
        call.send(result.payload, .{}) catch {
            call.abort();
            return;
        };
    }
    call.finish(result.status, &.{}) catch call.abort();
}

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

fn preflightRegisterNodeRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 9;
    while (try cursor.next()) |field| {
        if (field.number > 8) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            4, 5 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_node_endpoint_bytes), state_machine.max_node_endpoint_bytes, false)) return error.InvalidWire,
            6 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_failure_domain_bytes), state_machine.max_failure_domain_bytes, false)) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            8 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const version = try cursor.readVarint();
                if (version == 0 or version > std.math.maxInt(u32)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 8 }) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
}

fn preflightGetNodeRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_node_id = false;
    while (try cursor.next()) |field| {
        if (field.number != 1) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen_node_id or field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
        seen_node_id = true;
    }
    if (!seen_node_id) return error.InvalidWire;
}

fn preflightListNodesRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 3;
    while (try cursor.next()) |field| {
        if (field.number > 2) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
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

fn preflightRegisterMemberRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 12;
    var member_id: []const u8 = &.{};
    var local_set_id: []const u8 = &.{};
    while (try cursor.next()) |field| {
        if (field.number > 11) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            3 => {
                if (field.wire_type != 2) return error.InvalidWire;
                member_id = try cursor.readBytes(16);
                if (!validFixedNonzero(member_id, 16)) return error.InvalidWire;
            },
            4, 5 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            6 => {
                if (field.wire_type != 2) return error.InvalidWire;
                local_set_id = try cursor.readBytes(16);
                if (!validFixedNonzero(local_set_id, 16)) return error.InvalidWire;
            },
            7 => {
                if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u16)) return error.InvalidWire;
            },
            8 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            9, 10 => {
                if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire;
            },
            11 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const extent_size = try cursor.readVarint();
                if (extent_size == 0 or extent_size > std.math.maxInt(u32)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 8, 9, 10, 11 }) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
    if (std.mem.eql(u8, member_id, local_set_id)) return error.InvalidWire;
}

fn preflightGetMemberRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_member_id = false;
    while (try cursor.next()) |field| {
        if (field.number != 1) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen_member_id or field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire;
        seen_member_id = true;
    }
    if (!seen_member_id) return error.InvalidWire;
}

fn preflightListMembersRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 3;
    while (try cursor.next()) |field| {
        if (field.number > 2) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u32)) return error.InvalidWire;
            },
            2 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            else => unreachable,
        }
    }
}

fn preflightReportHeartbeatRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_heartbeat_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 5;
    var member_ids: [heartbeat.max_members_per_report][]const u8 = undefined;
    var member_count: usize = 0;
    while (try cursor.next()) |field| {
        if (field.number > 5) {
            try cursor.skip(field, max_heartbeat_request_wire_bytes);
            continue;
        }
        if (field.number != 5) {
            if (seen[field.number]) return error.InvalidWire;
            seen[field.number] = true;
        }
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3, 4 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            5 => {
                if (field.wire_type != 2 or member_count == heartbeat.max_members_per_report) return error.InvalidWire;
                const member_id = try preflightMemberHeartbeat(try cursor.readBytes(max_heartbeat_request_wire_bytes));
                for (member_ids[0..member_count]) |previous| {
                    if (std.mem.eql(u8, previous, member_id)) return error.InvalidWire;
                }
                member_ids[member_count] = member_id;
                member_count += 1;
            },
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4 }) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
}

fn preflightMemberHeartbeat(payload: []const u8) wire.Error![]const u8 {
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 6;
    var member_id: []const u8 = &.{};
    var local_set_id: []const u8 = &.{};
    var state: u64 = 0;
    while (try cursor.next()) |field| {
        if (field.number > 5) {
            try cursor.skip(field, max_heartbeat_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2) return error.InvalidWire;
                member_id = try cursor.readBytes(16);
                if (!validFixedNonzero(member_id, 16)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2) return error.InvalidWire;
                local_set_id = try cursor.readBytes(16);
                if (!validFixedNonzero(local_set_id, 16)) return error.InvalidWire;
            },
            3 => if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u16)) return error.InvalidWire,
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                state = try cursor.readVarint();
                if (state != @intFromEnum(pb.MemberHeartbeatState.MEMBER_HEARTBEAT_STATE_PRESENT) and
                    state != @intFromEnum(pb.MemberHeartbeatState.MEMBER_HEARTBEAT_STATE_UNAVAILABLE))
                {
                    return error.InvalidWire;
                }
            },
            5 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightMemberCapacity(try cursor.readBytes(max_heartbeat_request_wire_bytes));
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[4] or
        std.mem.eql(u8, member_id, local_set_id) or
        (state == @intFromEnum(pb.MemberHeartbeatState.MEMBER_HEARTBEAT_STATE_UNAVAILABLE) and seen[5]))
    {
        return error.InvalidWire;
    }
    return member_id;
}

fn preflightMemberCapacity(payload: []const u8) wire.Error!void {
    var cursor = wire.Cursor{ .bytes = payload };
    var seen = [_]bool{false} ** 5;
    var total: u64 = 0;
    while (try cursor.next()) |field| {
        if (field.number > 4) {
            try cursor.skip(field, max_heartbeat_request_wire_bytes);
            continue;
        }
        if (seen[field.number] or field.wire_type != 0) return error.InvalidWire;
        seen[field.number] = true;
        total = std.math.add(u64, total, try cursor.readVarint()) catch return error.InvalidWire;
    }
}

fn preflightGetHeartbeatRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_node_id = false;
    while (try cursor.next()) |field| {
        if (field.number != 1) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen_node_id or field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
        seen_node_id = true;
    }
    if (!seen_node_id) return error.InvalidWire;
}

fn validText(value: []const u8, max_bytes: usize, allow_empty: bool) bool {
    return (allow_empty or value.len != 0) and value.len <= max_bytes and std.unicode.utf8ValidateSlice(value);
}

fn validClusterId(value: []const u8) bool {
    return validFixedNonzero(value, 16);
}

fn validFixedNonzero(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (byte != 0) return true;
    return false;
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

fn currentHeartbeatTerm(service: *const PoolService) ?u64 {
    const status = service.raftor.getStatus();
    if (status.role != .leader or status.leader_id != status.id) return null;
    return status.term;
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

fn heartbeatFailure(err: heartbeat.Error) RpcResult {
    return .{ .status = switch (err) {
        error.InvalidHeartbeat => grpc.Status.init(.invalid_argument, "invalid heartbeat"),
        error.OrderingConflict => grpc.Status.init(.failed_precondition, "heartbeat ordering conflict"),
        error.NodeLimit, error.MemberLimit => grpc.Status.init(.resource_exhausted, "heartbeat observation limit reached"),
        error.Inactive, error.TermMismatch => grpc.Status.init(.unavailable, "Raft leadership changed"),
        error.OutOfMemory => grpc.Status.init(.internal, "control plane operation failed"),
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

const test_cluster_id: raft.ClusterId = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_member_id_a = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f };
const test_member_id_b = [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f };
const test_member_id_c = [_]u8{ 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f };
const test_local_set_id = [_]u8{ 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf };
const test_birth_topology_digest = [_]u8{0x5a} ** 32;

fn testRegisterNodeRequest(request_id: []const u8, node_id: []const u8, cluster_id: []const u8, control_endpoint: []const u8) pb.RegisterNodeRequest {
    return .{
        .request_id = request_id,
        .node_id = node_id,
        .cluster_id = cluster_id,
        .control_endpoint = control_endpoint,
        .nvmf_endpoint = "127.0.0.1:4420",
        .failure_domain = "rack-a",
        .capability_bits = 5,
        .protocol_version = 1,
    };
}

fn testRegisterMemberRequest(
    request_id: []const u8,
    member_id: []const u8,
    pool_id: []const u8,
    node_id: []const u8,
    member_slot: u32,
) pb.RegisterMemberRequest {
    return .{
        .request_id = request_id,
        .cluster_id = &test_cluster_id,
        .member_id = member_id,
        .pool_id = pool_id,
        .node_id = node_id,
        .local_set_id = &test_local_set_id,
        .member_slot = member_slot,
        .birth_topology_digest = &test_birth_topology_digest,
        .metadata_capacity_bytes = 1024,
        .data_capacity_bytes = 8192,
        .extent_size_bytes = 4096,
    };
}

fn awaitCompletion(raftor: *raft.Raftor, probe: *const CompletionProbe) !void {
    for (0..32) |_| {
        if (probe.completed) return;
        _ = try raftor.tick();
    }
    return error.TestTimeout;
}

fn expectRegisterMemberStatus(
    allocator: std.mem.Allocator,
    service: *PoolService,
    raftor: *raft.Raftor,
    request: pb.RegisterMemberRequest,
    expected: grpc.StatusCode,
) !void {
    const payload = try encodeMessage(allocator, request);
    defer allocator.free(payload);
    var probe = CompletionProbe{ .allocator = allocator };
    defer probe.deinit();
    service.registerMember(payload, probe.completion());
    if (!probe.completed) try awaitCompletion(raftor, &probe);
    try std.testing.expectEqual(expected, probe.code);
}

test "response command failures abort retained calls" {
    const Failure = enum { initial_metadata, message, finish };
    const CallProbe = struct {
        failure: Failure,
        aborts: usize = 0,
        initial_metadata: usize = 0,
        messages: usize = 0,
        finishes: usize = 0,

        fn call(self: *@This()) grpc.ServerCall {
            return grpc.ServerCall.initAbortable(
                self,
                id,
                isCancelled,
                isTerminal,
                abort,
                sendInitialMetadata,
                send,
                finish,
                resumeReceive,
                retain,
                release,
            );
        }

        fn id(_: *anyopaque) grpc.ServerCallId {
            return @enumFromInt(1);
        }

        fn isCancelled(_: *anyopaque) bool {
            return false;
        }

        fn isTerminal(_: *anyopaque) bool {
            return false;
        }

        fn abort(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.aborts += 1;
        }

        fn sendInitialMetadata(ctx: *anyopaque, _: []const grpc.MetadataEntry, _: grpc.Compression) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.initial_metadata += 1;
            if (self.failure == .initial_metadata) return error.OutOfMemory;
        }

        fn send(ctx: *anyopaque, _: []const u8, _: grpc.StreamSendOptions) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.messages += 1;
            if (self.failure == .message) return error.OutOfMemory;
        }

        fn finish(ctx: *anyopaque, _: grpc.Status, _: []const grpc.MetadataEntry) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.finishes += 1;
            if (self.failure == .finish) return error.OutOfMemory;
        }

        fn resumeReceive(_: *anyopaque) !void {}
        fn retain(_: *anyopaque) void {}
        fn release(_: *anyopaque) void {}
    };

    const failures = [_]Failure{ .initial_metadata, .message, .finish };
    for (failures) |failure| {
        var probe = CallProbe{ .failure = failure };
        sendRpcResult(probe.call(), .{ .status = .ok, .payload = "response" });
        try std.testing.expectEqual(@as(usize, 1), probe.aborts);
        try std.testing.expectEqual(@as(usize, 1), probe.initial_metadata);
        try std.testing.expectEqual(@as(usize, @intFromBool(failure != .initial_metadata)), probe.messages);
        try std.testing.expectEqual(@as(usize, @intFromBool(failure == .finish)), probe.finishes);
    }
}

test "Pool service rejects unbounded follower-forwarding Raft policy" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var heartbeat_store = heartbeat.HeartbeatStore.init(allocator);
    defer heartbeat_store.deinit();
    machine.setHeartbeatStore(&heartbeat_store);
    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
    defer raftor.destroy();
    try std.testing.expectError(
        error.UnsafeRaftConfiguration,
        PoolService.init(allocator, std.testing.io, raftor, &machine, &heartbeat_store, test_cluster_id),
    );
}

test "Pool service gates followers and completes linearizable CRUD reads" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var heartbeat_store = heartbeat.HeartbeatStore.init(allocator);
    defer heartbeat_store.deinit();
    machine.setHeartbeatStore(&heartbeat_store);
    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    config.raft.election_timeout_seed = 42;
    config.raft.check_quorum = true;
    config.raft.disable_proposal_forwarding = true;
    config.proposal_timeout_ticks = 32;
    config.read_index_timeout_ticks = 32;
    const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
    defer raftor.destroy();
    var service = try PoolService.init(allocator, std.testing.io, raftor, &machine, &heartbeat_store, test_cluster_id);

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

test "Node service validates registration and completes linearizable reads" {
    const allocator = std.testing.allocator;
    const first_id = "0198f54d-5c2a-7000-8000-000000000011";
    const second_id = "0198f54d-5c2a-7000-8000-000000000022";
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var heartbeat_store = heartbeat.HeartbeatStore.init(allocator);
    defer heartbeat_store.deinit();
    machine.setHeartbeatStore(&heartbeat_store);
    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    config.raft.election_timeout_seed = 42;
    config.raft.check_quorum = true;
    config.raft.disable_proposal_forwarding = true;
    config.proposal_timeout_ticks = 32;
    config.read_index_timeout_ticks = 32;
    const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
    defer raftor.destroy();
    var service = try PoolService.init(allocator, std.testing.io, raftor, &machine, &heartbeat_store, test_cluster_id);

    const register_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "node-request-1",
        first_id,
        &test_cluster_id,
        "127.0.0.1:9000",
    ));
    defer allocator.free(register_payload);
    const get_payload = try encodeMessage(allocator, pb.GetNodeRequest{ .node_id = first_id });
    defer allocator.free(get_payload);
    const list_payload = try encodeMessage(allocator, pb.ListNodesRequest{});
    defer allocator.free(list_payload);
    var follower_register = CompletionProbe{ .allocator = allocator };
    defer follower_register.deinit();
    service.registerNode(register_payload, follower_register.completion());
    try std.testing.expectEqual(grpc.StatusCode.unavailable, follower_register.code);
    var follower_get = CompletionProbe{ .allocator = allocator };
    defer follower_get.deinit();
    service.getNode(get_payload, follower_get.completion());
    try std.testing.expectEqual(grpc.StatusCode.unavailable, follower_get.code);
    var follower_list = CompletionProbe{ .allocator = allocator };
    defer follower_list.deinit();
    service.listNodes(list_payload, follower_list.completion());
    try std.testing.expectEqual(grpc.StatusCode.unavailable, follower_list.code);

    try raftor.campaign();
    const other_cluster_id: raft.ClusterId = .{0x99} ++ .{0x88} ** 15;
    const mismatch_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "node-mismatch",
        first_id,
        &other_cluster_id,
        "127.0.0.1:9000",
    ));
    defer allocator.free(mismatch_payload);
    var mismatch_probe = CompletionProbe{ .allocator = allocator };
    defer mismatch_probe.deinit();
    service.registerNode(mismatch_payload, mismatch_probe.completion());
    try std.testing.expectEqual(grpc.StatusCode.failed_precondition, mismatch_probe.code);

    const short_cluster_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "node-short-cluster",
        first_id,
        "short",
        "127.0.0.1:9000",
    ));
    defer allocator.free(short_cluster_payload);
    var short_cluster_probe = CompletionProbe{ .allocator = allocator };
    defer short_cluster_probe.deinit();
    service.registerNode(short_cluster_payload, short_cluster_probe.completion());
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, short_cluster_probe.code);

    const zero_cluster_id: raft.ClusterId = .{0} ** 16;
    const zero_cluster_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "node-zero-cluster",
        first_id,
        &zero_cluster_id,
        "127.0.0.1:9000",
    ));
    defer allocator.free(zero_cluster_payload);
    var zero_cluster_probe = CompletionProbe{ .allocator = allocator };
    defer zero_cluster_probe.deinit();
    service.registerNode(zero_cluster_payload, zero_cluster_probe.completion());
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, zero_cluster_probe.code);

    var invalid_version = testRegisterNodeRequest("node-invalid-version", first_id, &test_cluster_id, "127.0.0.1:9000");
    invalid_version.protocol_version = 0;
    const invalid_version_payload = try encodeMessage(allocator, invalid_version);
    defer allocator.free(invalid_version_payload);
    var invalid_version_probe = CompletionProbe{ .allocator = allocator };
    defer invalid_version_probe.deinit();
    service.registerNode(invalid_version_payload, invalid_version_probe.completion());
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, invalid_version_probe.code);

    var register_probe = CompletionProbe{ .allocator = allocator };
    defer register_probe.deinit();
    service.registerNode(register_payload, register_probe.completion());
    try awaitCompletion(raftor, &register_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, register_probe.code);
    var register_reader: std.Io.Reader = .fixed(register_probe.payload);
    var register_response = try pb.RegisterNodeResponse.decode(&register_reader, allocator);
    defer register_response.deinit(allocator);
    try std.testing.expectEqualStrings(first_id, register_response.node.?.id);
    try std.testing.expectEqualSlices(u8, &test_cluster_id, register_response.node.?.cluster_id);

    const conflict_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "node-request-1",
        first_id,
        &test_cluster_id,
        "127.0.0.2:9000",
    ));
    defer allocator.free(conflict_payload);
    var conflict_probe = CompletionProbe{ .allocator = allocator };
    defer conflict_probe.deinit();
    service.registerNode(conflict_payload, conflict_probe.completion());
    try awaitCompletion(raftor, &conflict_probe);
    try std.testing.expectEqual(grpc.StatusCode.failed_precondition, conflict_probe.code);

    const duplicate_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "node-request-duplicate",
        first_id,
        &test_cluster_id,
        "127.0.0.2:9000",
    ));
    defer allocator.free(duplicate_payload);
    var duplicate_probe = CompletionProbe{ .allocator = allocator };
    defer duplicate_probe.deinit();
    service.registerNode(duplicate_payload, duplicate_probe.completion());
    try awaitCompletion(raftor, &duplicate_probe);
    try std.testing.expectEqual(grpc.StatusCode.already_exists, duplicate_probe.code);

    const second_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "node-request-2",
        second_id,
        &test_cluster_id,
        "127.0.0.2:9000",
    ));
    defer allocator.free(second_payload);
    var second_probe = CompletionProbe{ .allocator = allocator };
    defer second_probe.deinit();
    service.registerNode(second_payload, second_probe.completion());
    try awaitCompletion(raftor, &second_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, second_probe.code);

    var get_probe = CompletionProbe{ .allocator = allocator };
    defer get_probe.deinit();
    service.getNode(get_payload, get_probe.completion());
    try awaitCompletion(raftor, &get_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, get_probe.code);
    var get_reader: std.Io.Reader = .fixed(get_probe.payload);
    var get_response = try pb.GetNodeResponse.decode(&get_reader, allocator);
    defer get_response.deinit(allocator);
    try std.testing.expectEqualStrings("127.0.0.1:9000", get_response.node.?.control_endpoint);

    const missing_payload = try encodeMessage(allocator, pb.GetNodeRequest{
        .node_id = "0198f54d-5c2a-7000-8000-000000000033",
    });
    defer allocator.free(missing_payload);
    var missing_probe = CompletionProbe{ .allocator = allocator };
    defer missing_probe.deinit();
    service.getNode(missing_payload, missing_probe.completion());
    try awaitCompletion(raftor, &missing_probe);
    try std.testing.expectEqual(grpc.StatusCode.not_found, missing_probe.code);

    const first_page_payload = try encodeMessage(allocator, pb.ListNodesRequest{ .page_size = 1 });
    defer allocator.free(first_page_payload);
    var first_page_probe = CompletionProbe{ .allocator = allocator };
    defer first_page_probe.deinit();
    service.listNodes(first_page_payload, first_page_probe.completion());
    try awaitCompletion(raftor, &first_page_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, first_page_probe.code);
    var first_page_reader: std.Io.Reader = .fixed(first_page_probe.payload);
    var first_page = try pb.ListNodesResponse.decode(&first_page_reader, allocator);
    defer first_page.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), first_page.nodes.items.len);
    try std.testing.expectEqualStrings(first_id, first_page.nodes.items[0].id);
    try std.testing.expectEqualStrings(first_id, first_page.next_page_token);

    const second_page_payload = try encodeMessage(allocator, pb.ListNodesRequest{
        .page_size = 1,
        .page_token = first_page.next_page_token,
    });
    defer allocator.free(second_page_payload);
    var second_page_probe = CompletionProbe{ .allocator = allocator };
    defer second_page_probe.deinit();
    service.listNodes(second_page_payload, second_page_probe.completion());
    try awaitCompletion(raftor, &second_page_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, second_page_probe.code);
    var second_page_reader: std.Io.Reader = .fixed(second_page_probe.payload);
    var second_page = try pb.ListNodesResponse.decode(&second_page_reader, allocator);
    defer second_page.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), second_page.nodes.items.len);
    try std.testing.expectEqualStrings(second_id, second_page.nodes.items[0].id);
    try std.testing.expectEqual(@as(usize, 0), second_page.next_page_token.len);
}

test "Member service validates registration and completes linearizable reads" {
    const allocator = std.testing.allocator;
    const node_id = "0198f54d-5c2a-7000-8000-000000000055";
    const missing_pool_id = "0198f54d-5c2a-7000-8000-000000000066";
    const missing_node_id = "0198f54d-5c2a-7000-8000-000000000077";
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var heartbeat_store = heartbeat.HeartbeatStore.init(allocator);
    defer heartbeat_store.deinit();
    machine.setHeartbeatStore(&heartbeat_store);
    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    config.raft.election_timeout_seed = 42;
    config.raft.check_quorum = true;
    config.raft.disable_proposal_forwarding = true;
    config.proposal_timeout_ticks = 32;
    config.read_index_timeout_ticks = 32;
    const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
    defer raftor.destroy();
    var service = try PoolService.init(allocator, std.testing.io, raftor, &machine, &heartbeat_store, test_cluster_id);

    const follower_register_payload = try encodeMessage(allocator, testRegisterMemberRequest(
        "member-follower",
        &test_member_id_a,
        missing_pool_id,
        node_id,
        0,
    ));
    defer allocator.free(follower_register_payload);
    var follower_register = CompletionProbe{ .allocator = allocator };
    defer follower_register.deinit();
    service.registerMember(follower_register_payload, follower_register.completion());
    try std.testing.expectEqual(grpc.StatusCode.unavailable, follower_register.code);

    const follower_get_payload = try encodeMessage(allocator, pb.GetMemberRequest{ .member_id = &test_member_id_a });
    defer allocator.free(follower_get_payload);
    var follower_get = CompletionProbe{ .allocator = allocator };
    defer follower_get.deinit();
    service.getMember(follower_get_payload, follower_get.completion());
    try std.testing.expectEqual(grpc.StatusCode.unavailable, follower_get.code);

    const empty_list_payload = try encodeMessage(allocator, pb.ListMembersRequest{});
    defer allocator.free(empty_list_payload);
    var follower_list = CompletionProbe{ .allocator = allocator };
    defer follower_list.deinit();
    service.listMembers(empty_list_payload, follower_list.completion());
    try std.testing.expectEqual(grpc.StatusCode.unavailable, follower_list.code);

    try raftor.campaign();

    var short_member = testRegisterMemberRequest("member-short", "short", missing_pool_id, node_id, 0);
    try expectRegisterMemberStatus(allocator, &service, raftor, short_member, .invalid_argument);
    const zero_member_id = [_]u8{0} ** 16;
    short_member.member_id = &zero_member_id;
    try expectRegisterMemberStatus(allocator, &service, raftor, short_member, .invalid_argument);
    var same_local_set = testRegisterMemberRequest("member-same-local-set", &test_member_id_a, missing_pool_id, node_id, 0);
    same_local_set.local_set_id = &test_member_id_a;
    try expectRegisterMemberStatus(allocator, &service, raftor, same_local_set, .invalid_argument);
    var short_digest = testRegisterMemberRequest("member-short-digest", &test_member_id_a, missing_pool_id, node_id, 0);
    short_digest.birth_topology_digest = "short";
    try expectRegisterMemberStatus(allocator, &service, raftor, short_digest, .invalid_argument);
    const zero_digest = [_]u8{0} ** 32;
    short_digest.birth_topology_digest = &zero_digest;
    try expectRegisterMemberStatus(allocator, &service, raftor, short_digest, .invalid_argument);
    var invalid_geometry = testRegisterMemberRequest("member-zero-metadata", &test_member_id_a, missing_pool_id, node_id, 0);
    invalid_geometry.metadata_capacity_bytes = 0;
    try expectRegisterMemberStatus(allocator, &service, raftor, invalid_geometry, .invalid_argument);
    invalid_geometry = testRegisterMemberRequest("member-zero-data", &test_member_id_a, missing_pool_id, node_id, 0);
    invalid_geometry.data_capacity_bytes = 0;
    try expectRegisterMemberStatus(allocator, &service, raftor, invalid_geometry, .invalid_argument);
    invalid_geometry = testRegisterMemberRequest("member-zero-extent", &test_member_id_a, missing_pool_id, node_id, 0);
    invalid_geometry.extent_size_bytes = 0;
    try expectRegisterMemberStatus(allocator, &service, raftor, invalid_geometry, .invalid_argument);
    const invalid_slot = testRegisterMemberRequest("member-invalid-slot", &test_member_id_a, missing_pool_id, node_id, std.math.maxInt(u16) + 1);
    try expectRegisterMemberStatus(allocator, &service, raftor, invalid_slot, .invalid_argument);
    const invalid_pool = testRegisterMemberRequest("member-invalid-pool", &test_member_id_a, "not-a-uuid", node_id, 0);
    try expectRegisterMemberStatus(allocator, &service, raftor, invalid_pool, .invalid_argument);

    const canonical_payload = try encodeMessage(allocator, testRegisterMemberRequest(
        "member-duplicate-field",
        &test_member_id_a,
        missing_pool_id,
        node_id,
        0,
    ));
    defer allocator.free(canonical_payload);
    const duplicate_field_payload = try std.mem.concat(allocator, u8, &.{ canonical_payload, "\x0a\x03dup" });
    defer allocator.free(duplicate_field_payload);
    var duplicate_field_probe = CompletionProbe{ .allocator = allocator };
    defer duplicate_field_probe.deinit();
    service.registerMember(duplicate_field_payload, duplicate_field_probe.completion());
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, duplicate_field_probe.code);

    try expectRegisterMemberStatus(
        allocator,
        &service,
        raftor,
        testRegisterMemberRequest("member-missing-pool", &test_member_id_a, missing_pool_id, node_id, 0),
        .not_found,
    );

    const create_pool_payload = try encodeMessage(allocator, pb.CreatePoolRequest{
        .request_id = "member-pool-request",
        .name = "member-pool",
    });
    defer allocator.free(create_pool_payload);
    var create_pool_probe = CompletionProbe{ .allocator = allocator };
    defer create_pool_probe.deinit();
    service.createPool(create_pool_payload, create_pool_probe.completion());
    try awaitCompletion(raftor, &create_pool_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, create_pool_probe.code);
    var create_pool_reader: std.Io.Reader = .fixed(create_pool_probe.payload);
    var create_pool_response = try pb.CreatePoolResponse.decode(&create_pool_reader, allocator);
    defer create_pool_response.deinit(allocator);
    const pool_id = create_pool_response.pool.?.id;

    try expectRegisterMemberStatus(
        allocator,
        &service,
        raftor,
        testRegisterMemberRequest("member-missing-node", &test_member_id_a, pool_id, missing_node_id, 0),
        .not_found,
    );

    const register_node_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "member-node-request",
        node_id,
        &test_cluster_id,
        "127.0.0.1:9100",
    ));
    defer allocator.free(register_node_payload);
    var register_node_probe = CompletionProbe{ .allocator = allocator };
    defer register_node_probe.deinit();
    service.registerNode(register_node_payload, register_node_probe.completion());
    try awaitCompletion(raftor, &register_node_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, register_node_probe.code);

    var wrong_cluster = testRegisterMemberRequest("member-request-a", &test_member_id_a, pool_id, node_id, 0);
    const other_cluster_id: raft.ClusterId = .{0x99} ++ .{0x88} ** 15;
    wrong_cluster.cluster_id = &other_cluster_id;
    try expectRegisterMemberStatus(allocator, &service, raftor, wrong_cluster, .failed_precondition);

    const first_request = testRegisterMemberRequest("member-request-a", &test_member_id_a, pool_id, node_id, 0);
    const first_payload = try encodeMessage(allocator, first_request);
    defer allocator.free(first_payload);
    var first_probe = CompletionProbe{ .allocator = allocator };
    defer first_probe.deinit();
    service.registerMember(first_payload, first_probe.completion());
    try awaitCompletion(raftor, &first_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, first_probe.code);
    var first_reader: std.Io.Reader = .fixed(first_probe.payload);
    var first_response = try pb.RegisterMemberResponse.decode(&first_reader, allocator);
    defer first_response.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, first_response.member.?.id);
    try std.testing.expectEqual(@as(u32, 0), first_response.member.?.member_slot);

    try expectRegisterMemberStatus(allocator, &service, raftor, first_request, .ok);
    var request_conflict = first_request;
    request_conflict.data_capacity_bytes += 1;
    try expectRegisterMemberStatus(allocator, &service, raftor, request_conflict, .failed_precondition);
    try expectRegisterMemberStatus(
        allocator,
        &service,
        raftor,
        testRegisterMemberRequest("member-duplicate-id", &test_member_id_a, pool_id, node_id, 1),
        .already_exists,
    );
    try expectRegisterMemberStatus(
        allocator,
        &service,
        raftor,
        testRegisterMemberRequest("member-request-b", &test_member_id_b, pool_id, node_id, 1),
        .ok,
    );
    try expectRegisterMemberStatus(
        allocator,
        &service,
        raftor,
        testRegisterMemberRequest("member-duplicate-slot", &test_member_id_c, pool_id, node_id, 1),
        .already_exists,
    );

    const get_payload = try encodeMessage(allocator, pb.GetMemberRequest{ .member_id = &test_member_id_a });
    defer allocator.free(get_payload);
    var get_probe = CompletionProbe{ .allocator = allocator };
    defer get_probe.deinit();
    service.getMember(get_payload, get_probe.completion());
    try awaitCompletion(raftor, &get_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, get_probe.code);
    var get_reader: std.Io.Reader = .fixed(get_probe.payload);
    var get_response = try pb.GetMemberResponse.decode(&get_reader, allocator);
    defer get_response.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, get_response.member.?.id);

    const invalid_get_payload = try encodeMessage(allocator, pb.GetMemberRequest{ .member_id = "short" });
    defer allocator.free(invalid_get_payload);
    var invalid_get_probe = CompletionProbe{ .allocator = allocator };
    defer invalid_get_probe.deinit();
    service.getMember(invalid_get_payload, invalid_get_probe.completion());
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, invalid_get_probe.code);

    const missing_member_id = [_]u8{0x77} ** 16;
    const missing_get_payload = try encodeMessage(allocator, pb.GetMemberRequest{ .member_id = &missing_member_id });
    defer allocator.free(missing_get_payload);
    var missing_get_probe = CompletionProbe{ .allocator = allocator };
    defer missing_get_probe.deinit();
    service.getMember(missing_get_payload, missing_get_probe.completion());
    try awaitCompletion(raftor, &missing_get_probe);
    try std.testing.expectEqual(grpc.StatusCode.not_found, missing_get_probe.code);

    const invalid_list_payload = try encodeMessage(allocator, pb.ListMembersRequest{ .page_size = max_page_size + 1 });
    defer allocator.free(invalid_list_payload);
    var invalid_list_probe = CompletionProbe{ .allocator = allocator };
    defer invalid_list_probe.deinit();
    service.listMembers(invalid_list_payload, invalid_list_probe.completion());
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, invalid_list_probe.code);
    const invalid_token_payload = try encodeMessage(allocator, pb.ListMembersRequest{ .page_token = "short" });
    defer allocator.free(invalid_token_payload);
    var invalid_token_probe = CompletionProbe{ .allocator = allocator };
    defer invalid_token_probe.deinit();
    service.listMembers(invalid_token_payload, invalid_token_probe.completion());
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, invalid_token_probe.code);

    const first_page_payload = try encodeMessage(allocator, pb.ListMembersRequest{ .page_size = 1 });
    defer allocator.free(first_page_payload);
    var first_page_probe = CompletionProbe{ .allocator = allocator };
    defer first_page_probe.deinit();
    service.listMembers(first_page_payload, first_page_probe.completion());
    try awaitCompletion(raftor, &first_page_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, first_page_probe.code);
    var first_page_reader: std.Io.Reader = .fixed(first_page_probe.payload);
    var first_page = try pb.ListMembersResponse.decode(&first_page_reader, allocator);
    defer first_page.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), first_page.members.items.len);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, first_page.members.items[0].id);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, first_page.next_page_token);

    const second_page_payload = try encodeMessage(allocator, pb.ListMembersRequest{
        .page_size = 1,
        .page_token = first_page.next_page_token,
    });
    defer allocator.free(second_page_payload);
    var second_page_probe = CompletionProbe{ .allocator = allocator };
    defer second_page_probe.deinit();
    service.listMembers(second_page_payload, second_page_probe.completion());
    try awaitCompletion(raftor, &second_page_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, second_page_probe.code);
    var second_page_reader: std.Io.Reader = .fixed(second_page_probe.payload);
    var second_page = try pb.ListMembersResponse.decode(&second_page_reader, allocator);
    defer second_page.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), second_page.members.items.len);
    try std.testing.expectEqualSlices(u8, &test_member_id_b, second_page.members.items[0].id);
    try std.testing.expectEqual(@as(usize, 0), second_page.next_page_token.len);
}

test "heartbeat preflight enforces report bounds and canonical wire" {
    const allocator = std.testing.allocator;
    const node_id = "0198f54d-5c2a-7000-8000-000000000088";
    var ids: [heartbeat.max_members_per_report][16]u8 = @splat(@splat(0));
    var members: [heartbeat.max_members_per_report]pb.MemberHeartbeat = undefined;
    const quarter = std.math.maxInt(u64) / 4;
    for (&members, &ids, 0..) |*member, *id, index| {
        std.mem.writeInt(u16, id[14..16], @intCast(index + 1), .big);
        member.* = .{
            .member_id = id,
            .local_set_id = &test_local_set_id,
            .member_slot = @intCast(index),
            .state = .MEMBER_HEARTBEAT_STATE_PRESENT,
            .capacity = .{
                .free_extent_count = quarter,
                .allocated_extent_count = quarter,
                .reserved_extent_count = quarter,
                .retired_extent_count = quarter,
            },
        };
    }
    const request = pb.ReportHeartbeatRequest{
        .cluster_id = &test_cluster_id,
        .node_id = node_id,
        .incarnation = 1,
        .sequence = 1,
        .members = .{ .items = &members, .capacity = members.len },
    };
    const payload = try encodeMessage(allocator, request);
    defer allocator.free(payload);
    try std.testing.expect(payload.len > max_request_wire_bytes);
    try std.testing.expect(payload.len <= max_heartbeat_request_wire_bytes);
    try preflightReportHeartbeatRequest(payload);

    const duplicate_sequence = try std.mem.concat(allocator, u8, &.{ payload, "\x20\x01" });
    defer allocator.free(duplicate_sequence);
    try std.testing.expectError(error.InvalidWire, preflightReportHeartbeatRequest(duplicate_sequence));

    members[1].member_id = members[0].member_id;
    const duplicate_member = try encodeMessage(allocator, request);
    defer allocator.free(duplicate_member);
    try std.testing.expectError(error.InvalidWire, preflightReportHeartbeatRequest(duplicate_member));

    try std.testing.expectError(error.InvalidWire, preflightMemberCapacity("\x08\x01\x08\x02"));
    try std.testing.expectError(
        error.InvalidWire,
        preflightMemberCapacity("\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01\x10\x01"),
    );

    var unavailable = members[0];
    unavailable.state = .MEMBER_HEARTBEAT_STATE_UNAVAILABLE;
    const unavailable_payload = try encodeMessage(allocator, unavailable);
    defer allocator.free(unavailable_payload);
    try std.testing.expectError(error.InvalidWire, preflightMemberHeartbeat(unavailable_payload));
}

test "Heartbeat service completes report and get on ReadIndex callbacks" {
    const allocator = std.testing.allocator;
    const node_id = "0198f54d-5c2a-7000-8000-000000000099";
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var heartbeat_store = heartbeat.HeartbeatStore.init(allocator);
    defer heartbeat_store.deinit();
    machine.setHeartbeatStore(&heartbeat_store);
    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    config.raft.election_timeout_seed = 42;
    config.raft.check_quorum = true;
    config.raft.disable_proposal_forwarding = true;
    config.proposal_timeout_ticks = 32;
    config.read_index_timeout_ticks = 32;
    const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
    defer raftor.destroy();
    var service = try PoolService.init(allocator, std.testing.io, raftor, &machine, &heartbeat_store, test_cluster_id);

    const follower_get_payload = try encodeMessage(allocator, pb.GetHeartbeatRequest{ .node_id = node_id });
    defer allocator.free(follower_get_payload);
    var follower_probe = CompletionProbe{ .allocator = allocator };
    defer follower_probe.deinit();
    service.getHeartbeat(follower_get_payload, follower_probe.completion());
    try std.testing.expect(follower_probe.completed);
    try std.testing.expectEqual(grpc.StatusCode.unavailable, follower_probe.code);

    try raftor.campaign();

    const register_payload = try encodeMessage(allocator, testRegisterNodeRequest(
        "heartbeat-node-request",
        node_id,
        &test_cluster_id,
        "127.0.0.1:9200",
    ));
    defer allocator.free(register_payload);
    var register_probe = CompletionProbe{ .allocator = allocator };
    defer register_probe.deinit();
    service.registerNode(register_payload, register_probe.completion());
    try awaitCompletion(raftor, &register_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, register_probe.code);

    const report_payload = try encodeMessage(allocator, pb.ReportHeartbeatRequest{
        .cluster_id = &test_cluster_id,
        .node_id = node_id,
        .incarnation = 1,
        .sequence = 1,
    });
    defer allocator.free(report_payload);
    var report_probe = CompletionProbe{ .allocator = allocator };
    defer report_probe.deinit();
    service.reportHeartbeat(report_payload, report_probe.completion());
    try std.testing.expect(!report_probe.completed);
    try std.testing.expectEqual(@as(usize, 0), heartbeat_store.observationCount());
    try awaitCompletion(raftor, &report_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, report_probe.code);
    var report_reader: std.Io.Reader = .fixed(report_probe.payload);
    var report_response = try pb.ReportHeartbeatResponse.decode(&report_reader, allocator);
    defer report_response.deinit(allocator);
    try std.testing.expectEqualStrings(node_id, report_response.observation.?.node_id);
    try std.testing.expectEqual(raftor.getStatus().term, report_response.observation.?.leader_term);
    try std.testing.expectEqual(heartbeat.recommended_interval_ms, report_response.recommended_interval_ms);
    const accepted_at_unix_ms = report_response.observation.?.accepted_at_unix_ms;

    var replay_probe = CompletionProbe{ .allocator = allocator };
    defer replay_probe.deinit();
    service.reportHeartbeat(report_payload, replay_probe.completion());
    try awaitCompletion(raftor, &replay_probe);
    var replay_reader: std.Io.Reader = .fixed(replay_probe.payload);
    var replay_response = try pb.ReportHeartbeatResponse.decode(&replay_reader, allocator);
    defer replay_response.deinit(allocator);
    try std.testing.expectEqual(accepted_at_unix_ms, replay_response.observation.?.accepted_at_unix_ms);

    const get_payload = try encodeMessage(allocator, pb.GetHeartbeatRequest{ .node_id = node_id });
    defer allocator.free(get_payload);
    var get_probe = CompletionProbe{ .allocator = allocator };
    defer get_probe.deinit();
    service.getHeartbeat(get_payload, get_probe.completion());
    try std.testing.expect(!get_probe.completed);
    try awaitCompletion(raftor, &get_probe);
    try std.testing.expectEqual(grpc.StatusCode.ok, get_probe.code);
    var get_reader: std.Io.Reader = .fixed(get_probe.payload);
    var get_response = try pb.GetHeartbeatResponse.decode(&get_reader, allocator);
    defer get_response.deinit(allocator);
    try std.testing.expectEqualStrings(node_id, get_response.observation.?.node_id);

    const missing_payload = try encodeMessage(allocator, pb.ReportHeartbeatRequest{
        .cluster_id = &test_cluster_id,
        .node_id = "0198f54d-5c2a-7000-8000-0000000000aa",
        .incarnation = 1,
        .sequence = 1,
    });
    defer allocator.free(missing_payload);
    var missing_probe = CompletionProbe{ .allocator = allocator };
    defer missing_probe.deinit();
    service.reportHeartbeat(missing_payload, missing_probe.completion());
    try std.testing.expect(!missing_probe.completed);
    try awaitCompletion(raftor, &missing_probe);
    try std.testing.expectEqual(grpc.StatusCode.not_found, missing_probe.code);
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

test "raw unary client reaches asynchronous Pool Node and Member RPCs" {
    const allocator = std.heap.smp_allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var heartbeat_store = heartbeat.HeartbeatStore.init(allocator);
    defer heartbeat_store.deinit();
    machine.setHeartbeatStore(&heartbeat_store);
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

    var pool_service = try PoolService.init(allocator, std.testing.io, raftor, &machine, &heartbeat_store, test_cluster_id);
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

    const node_id = "0198f54d-5c2a-7000-8000-000000000044";
    const register_node_request = try encodeMessage(allocator, testRegisterNodeRequest(
        "grpc-node-request-1",
        node_id,
        &test_cluster_id,
        "127.0.0.1:9000",
    ));
    defer allocator.free(register_node_request);
    var register_node_result = try channel.callUnary(
        allocator,
        "/zettide.control.v1.NodeService/RegisterNode",
        register_node_request,
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer register_node_result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, register_node_result.status.code);
    var register_node_reader: std.Io.Reader = .fixed(register_node_result.payload);
    var register_node_response = try pb.RegisterNodeResponse.decode(&register_node_reader, allocator);
    defer register_node_response.deinit(allocator);
    try std.testing.expectEqualStrings(node_id, register_node_response.node.?.id);

    const get_node_request = try encodeMessage(allocator, pb.GetNodeRequest{ .node_id = node_id });
    defer allocator.free(get_node_request);
    var get_node_result = try channel.callUnary(
        allocator,
        "/zettide.control.v1.NodeService/GetNode",
        get_node_request,
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer get_node_result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, get_node_result.status.code);
    var get_node_reader: std.Io.Reader = .fixed(get_node_result.payload);
    var get_node_response = try pb.GetNodeResponse.decode(&get_node_reader, allocator);
    defer get_node_response.deinit(allocator);
    try std.testing.expectEqualStrings(node_id, get_node_response.node.?.id);

    const list_nodes_request = try encodeMessage(allocator, pb.ListNodesRequest{});
    defer allocator.free(list_nodes_request);
    var list_nodes_result = try channel.callUnary(
        allocator,
        "/zettide.control.v1.NodeService/ListNodes",
        list_nodes_request,
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer list_nodes_result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, list_nodes_result.status.code);
    var list_nodes_reader: std.Io.Reader = .fixed(list_nodes_result.payload);
    var list_nodes_response = try pb.ListNodesResponse.decode(&list_nodes_reader, allocator);
    defer list_nodes_response.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list_nodes_response.nodes.items.len);
    try std.testing.expectEqualStrings(node_id, list_nodes_response.nodes.items[0].id);

    const register_member_request = try encodeMessage(allocator, testRegisterMemberRequest(
        "grpc-member-request-1",
        &test_member_id_a,
        response.pool.?.id,
        node_id,
        0,
    ));
    defer allocator.free(register_member_request);
    var register_member_result = try channel.callUnary(
        allocator,
        "/zettide.control.v1.MemberService/RegisterMember",
        register_member_request,
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer register_member_result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, register_member_result.status.code);
    var register_member_reader: std.Io.Reader = .fixed(register_member_result.payload);
    var register_member_response = try pb.RegisterMemberResponse.decode(&register_member_reader, allocator);
    defer register_member_response.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, register_member_response.member.?.id);

    const get_member_request = try encodeMessage(allocator, pb.GetMemberRequest{ .member_id = &test_member_id_a });
    defer allocator.free(get_member_request);
    var get_member_result = try channel.callUnary(
        allocator,
        "/zettide.control.v1.MemberService/GetMember",
        get_member_request,
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer get_member_result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, get_member_result.status.code);
    var get_member_reader: std.Io.Reader = .fixed(get_member_result.payload);
    var get_member_response = try pb.GetMemberResponse.decode(&get_member_reader, allocator);
    defer get_member_response.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, get_member_response.member.?.id);

    const list_members_request = try encodeMessage(allocator, pb.ListMembersRequest{});
    defer allocator.free(list_members_request);
    var list_members_result = try channel.callUnary(
        allocator,
        "/zettide.control.v1.MemberService/ListMembers",
        list_members_request,
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer list_members_result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, list_members_result.status.code);
    var list_members_reader: std.Io.Reader = .fixed(list_members_result.payload);
    var list_members_response = try pb.ListMembersResponse.decode(&list_members_reader, allocator);
    defer list_members_response.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list_members_response.members.items.len);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, list_members_response.members.items[0].id);

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
