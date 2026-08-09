const std = @import("std");

const data_service = @import("data_service.zig");
const pb = @import("control_proto");
const state_machine = @import("state_machine.zig");
const uuid = @import("uuid");

pub const DataServiceClient = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ensure: *const fn (*anyopaque, []const u8, data_service.Request) anyerror!data_service.Response,
        delete: *const fn (*anyopaque, []const u8, data_service.Request) anyerror!data_service.Response,
        /// Must be thread-safe, idempotent, and promptly unblock in-flight calls.
        cancel: *const fn (*anyopaque) void,
    };

    fn ensure(self: DataServiceClient, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        return self.vtable.ensure(self.context, endpoint, request);
    }

    fn delete(self: DataServiceClient, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        return self.vtable.delete(self.context, endpoint, request);
    }

    pub fn cancel(self: DataServiceClient) void {
        self.vtable.cancel(self.context);
    }
};

/// Runtime adapters submit the encoded command synchronously and return an
/// allocator-owned apply response.
pub const CommandSubmitter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        submit: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,
    };

    fn submit(self: CommandSubmitter, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        return self.vtable.submit(self.context, allocator, command);
    }
};

pub const Reconciler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    machine: *const state_machine.PoolStateMachine,
    data_client: DataServiceClient,
    submitter: CommandSubmitter,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        machine: *const state_machine.PoolStateMachine,
        data_client: DataServiceClient,
        submitter: CommandSubmitter,
    ) Reconciler {
        return .{
            .allocator = allocator,
            .io = io,
            .machine = machine,
            .data_client = data_client,
            .submitter = submitter,
        };
    }

    /// Must run on the Raft driver thread, normally from a ReadIndex callback.
    /// The returned action owns everything needed by `execute`.
    pub fn planOnce(self: *Reconciler) !?*Action {
        const volumes = try self.machine.listReconcileVolumes(self.allocator);
        defer {
            for (volumes) |*volume| volume.deinit(self.allocator);
            self.allocator.free(volumes);
        }
        for (volumes) |volume| {
            if (volume.placements.len != volume.allocations.len) return error.InconsistentSnapshot;
            if (volume.volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_PROVISIONING and
                volume.volume.operation_phase == .VOLUME_OPERATION_PHASE_NONE and
                volume.placements.len == 0 and volume.allocations.len == 0)
            {
                return try self.planReserve(volume.volume);
            }
            if (volume.volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_PROVISIONING and
                volume.volume.operation_phase == .VOLUME_OPERATION_PHASE_PLACING)
            {
                if (firstReservedPlacement(volume)) |placement| {
                    return try self.planEnsure(volume, placement);
                }
            }
            if (volume.volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_DELETING) {
                return try self.planDelete(volume);
            }
        }
        return null;
    }

    pub fn runOnce(self: *Reconciler) !void {
        const action = try self.planOnce() orelse return;
        defer action.deinit();
        try action.execute(self.data_client, self.submitter);
    }

    fn planReserve(self: *Reconciler, volume: pb.Volume) !*Action {
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        var placement_urns: [state_machine.volume_target_replica_count][36]u8 = undefined;
        var allocation_urns: [state_machine.volume_target_replica_count][36]u8 = undefined;
        var placement_ids: [state_machine.volume_target_replica_count][]const u8 = undefined;
        var allocation_ids: [state_machine.volume_target_replica_count][]const u8 = undefined;
        for (0..state_machine.volume_target_replica_count) |index| {
            placement_urns[index] = uuid.urn.serialize(uuid.v7.new(self.io));
            allocation_urns[index] = uuid.urn.serialize(uuid.v7.new(self.io));
            placement_ids[index] = &placement_urns[index];
            allocation_ids[index] = &allocation_urns[index];
        }
        const reservations = try self.machine.buildVolumeReservations(allocator, volume.id, placement_ids, allocation_ids);
        const encoded = try state_machine.encodeReserveVolumeResourcesCommand(allocator, .{
            .volume_id = volume.id,
            .expected_resource_version = volume.resource_version,
            .reservations = .{ .items = reservations, .capacity = reservations.len },
        });
        action.kind = .{ .reserve = encoded };
        return action;
    }

    fn planEnsure(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume, placement: pb.ReplicaPlacement) !*Action {
        const allocation = allocationForPlacement(volume.allocations, placement.id) orelse return error.InconsistentSnapshot;
        _ = memberById(volume.members, allocation.member_id) orelse return error.InconsistentSnapshot;
        const node = nodeById(volume.nodes, placement.node_id) orelse return error.InconsistentSnapshot;
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        var operation_urn = stableOperationId("ensure", placement.id, allocation.id, placement.generation);
        const request = try dupeDataRequest(allocator, &operation_urn, volume.volume, placement, allocation);
        const encoded = try state_machine.encodeActivateReplicaCommand(allocator, .{
            .volume_id = volume.volume.id,
            .placement_id = placement.id,
            .allocation_id = allocation.id,
            .expected_volume_resource_version = volume.volume.resource_version,
            .expected_placement_resource_version = placement.resource_version,
            .expected_allocation_resource_version = allocation.resource_version,
        });
        action.kind = .{ .ensure = .{
            .endpoint = try allocator.dupe(u8, node.control_endpoint),
            .request = request,
            .command = encoded,
        } };
        return action;
    }

    fn planDelete(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume) !*Action {
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        const replicas = try allocator.alloc(Action.DeleteReplica, volume.placements.len);
        for (volume.placements, replicas) |placement, *replica| {
            const allocation = allocationForPlacement(volume.allocations, placement.id) orelse return error.InconsistentSnapshot;
            const node = nodeById(volume.nodes, placement.node_id) orelse return error.InconsistentSnapshot;
            var operation_urn = stableOperationId("delete", placement.id, allocation.id, placement.generation);
            replica.* = .{
                .endpoint = try allocator.dupe(u8, node.control_endpoint),
                .request = try dupeDataRequest(allocator, &operation_urn, volume.volume, placement, allocation),
            };
        }

        var placement_ids: std.ArrayList([]const u8) = .empty;
        defer placement_ids.deinit(allocator);
        var allocation_ids: std.ArrayList([]const u8) = .empty;
        defer allocation_ids.deinit(allocator);
        for (volume.placements) |placement| try placement_ids.append(allocator, placement.id);
        for (volume.allocations) |allocation| try allocation_ids.append(allocator, allocation.id);
        const deleted_at = std.math.cast(i64, std.Io.Timestamp.now(self.io, .real).toMilliseconds()) orelse return error.InvalidTimestamp;
        if (deleted_at <= 0) return error.InvalidTimestamp;
        const encoded = try state_machine.encodeFinalizeVolumeDeletionCommand(allocator, .{
            .volume_id = volume.volume.id,
            .expected_resource_version = volume.volume.resource_version,
            .placement_ids = placement_ids,
            .allocation_ids = allocation_ids,
            .proposed_deleted_at_unix_ms = deleted_at,
        });
        action.kind = .{ .delete = .{ .replicas = replicas, .command = encoded } };
        return action;
    }
};

pub const Action = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    kind: Kind = undefined,

    const Ensure = struct {
        endpoint: []const u8,
        request: data_service.Request,
        command: []const u8,
    };

    const DeleteReplica = struct {
        endpoint: []const u8,
        request: data_service.Request,
    };

    const Delete = struct {
        replicas: []const DeleteReplica,
        command: []const u8,
    };

    const Kind = union(enum) {
        reserve: []const u8,
        ensure: Ensure,
        delete: Delete,
    };

    fn create(allocator: std.mem.Allocator) !*Action {
        const self = try allocator.create(Action);
        self.* = .{ .parent_allocator = allocator, .arena = .init(allocator) };
        return self;
    }

    pub fn deinit(self: *Action) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self);
    }

    pub fn execute(self: *Action, data_client: DataServiceClient, submitter: CommandSubmitter) !void {
        switch (self.kind) {
            .reserve => |command| try submitAndValidate(self.parent_allocator, submitter, command, .reserve),
            .ensure => |ensure| {
                const response = try data_client.ensure(ensure.endpoint, ensure.request);
                try validateDataResponse(response, ensure.request.operation_id, ensure.request, .active);
                try submitAndValidate(self.parent_allocator, submitter, ensure.command, .activate);
            },
            .delete => |delete| {
                for (delete.replicas) |replica| {
                    const response = try data_client.delete(replica.endpoint, replica.request);
                    try validateDataResponse(response, replica.request.operation_id, replica.request, .tombstoned);
                }
                try submitAndValidate(self.parent_allocator, submitter, delete.command, .finalize);
            },
        }
    }
};

const ApplyKind = enum { reserve, activate, finalize };

fn submitAndValidate(allocator: std.mem.Allocator, submitter: CommandSubmitter, command: []const u8, kind: ApplyKind) !void {
    const response_bytes = try submitter.submit(allocator, command);
    defer allocator.free(response_bytes);
    switch (kind) {
        .reserve => {
            var response = try state_machine.decodeReserveVolumeResourcesApplyResponse(allocator, response_bytes);
            defer response.deinit(allocator);
            switch (response.code) {
                .RESERVE_VOLUME_RESOURCES_APPLY_CODE_RESERVED,
                .RESERVE_VOLUME_RESOURCES_APPLY_CODE_VERSION_CONFLICT,
                .RESERVE_VOLUME_RESOURCES_APPLY_CODE_INVALID_STATE,
                => {},
                else => return error.ReservationRejected,
            }
        },
        .activate => {
            var response = try state_machine.decodeActivateReplicaApplyResponse(allocator, response_bytes);
            defer response.deinit(allocator);
            switch (response.code) {
                .ACTIVATE_REPLICA_APPLY_CODE_ACTIVATED,
                .ACTIVATE_REPLICA_APPLY_CODE_VERSION_CONFLICT,
                .ACTIVATE_REPLICA_APPLY_CODE_INVALID_STATE,
                => {},
                else => return error.ActivationRejected,
            }
        },
        .finalize => {
            var response = try state_machine.decodeFinalizeVolumeDeletionApplyResponse(allocator, response_bytes);
            defer response.deinit(allocator);
            switch (response.code) {
                .FINALIZE_VOLUME_DELETION_APPLY_CODE_FINALIZED,
                .FINALIZE_VOLUME_DELETION_APPLY_CODE_NOT_FOUND,
                .FINALIZE_VOLUME_DELETION_APPLY_CODE_VERSION_CONFLICT,
                .FINALIZE_VOLUME_DELETION_APPLY_CODE_INVALID_STATE,
                => {},
                else => return error.FinalizeRejected,
            }
        },
    }
}

fn firstReservedPlacement(volume: state_machine.PoolStateMachine.ReconcileVolume) ?pb.ReplicaPlacement {
    for (volume.placements) |placement| {
        if (placement.state == .REPLICA_PLACEMENT_STATE_RESERVED) return placement;
    }
    return null;
}

fn allocationForPlacement(allocations: []const pb.ReplicaAllocation, placement_id: []const u8) ?pb.ReplicaAllocation {
    for (allocations) |allocation| if (std.mem.eql(u8, allocation.replica_id, placement_id)) return allocation;
    return null;
}

fn memberById(members: []const pb.Member, id: []const u8) ?pb.Member {
    for (members) |member| if (std.mem.eql(u8, member.id, id)) return member;
    return null;
}

fn nodeById(nodes: []const pb.Node, id: []const u8) ?pb.Node {
    for (nodes) |node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}

fn dupeDataRequest(
    allocator: std.mem.Allocator,
    operation_id: []const u8,
    volume: pb.Volume,
    placement: pb.ReplicaPlacement,
    allocation: pb.ReplicaAllocation,
) !data_service.Request {
    return .{
        .operation_id = try allocator.dupe(u8, operation_id),
        .volume_id = try allocator.dupe(u8, volume.id),
        .placement_id = try allocator.dupe(u8, placement.id),
        .allocation_id = try allocator.dupe(u8, allocation.id),
        .generation = placement.generation,
        .member_id = try allocator.dupe(u8, allocation.member_id),
        .offset_bytes = allocation.offset_bytes,
        .length_bytes = allocation.length_bytes,
    };
}

fn stableOperationId(kind: []const u8, placement_id: []const u8, allocation_id: []const u8, generation: u64) [36]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(kind);
    hasher.update(&.{0});
    hasher.update(placement_id);
    hasher.update(&.{0});
    hasher.update(allocation_id);
    var generation_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &generation_bytes, generation, .little);
    hasher.update(&generation_bytes);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x70;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return uuid.urn.serialize(std.mem.readInt(u128, digest[0..16], .little));
}

fn validateDataResponse(
    response: data_service.Response,
    operation_id: []const u8,
    request: data_service.Request,
    expected_state: data_service.ReplicaState,
) !void {
    const parsed_operation = try uuid.urn.deserialize(operation_id);
    var operation_bytes: data_service.Id = undefined;
    std.mem.writeInt(u128, &operation_bytes, parsed_operation, .little);
    if (!std.mem.eql(u8, &response.operation_id, &operation_bytes) or response.replica.state != expected_state) return error.InvalidAttestation;
    const binding = response.replica.attestation.binding;
    if (!uuidMatches(request.volume_id, binding.volume_id) or
        !uuidMatches(request.placement_id, binding.placement_id) or
        !uuidMatches(request.allocation_id, binding.allocation_id) or
        request.member_id.len != binding.member_id.len or
        !std.mem.eql(u8, request.member_id, &binding.member_id) or
        request.generation != binding.generation or
        request.offset_bytes != binding.offset_bytes or
        request.length_bytes != binding.length_bytes) return error.InvalidAttestation;
}

fn uuidMatches(urn: []const u8, bytes: data_service.Id) bool {
    const parsed = uuid.urn.deserialize(urn) catch return false;
    var parsed_bytes: data_service.Id = undefined;
    std.mem.writeInt(u128, &parsed_bytes, parsed, .little);
    return std.mem.eql(u8, &parsed_bytes, &bytes);
}

const test_pool_id = "0198f54d-5c2a-7000-8000-000000000101";
const test_volume_id = "0198f54d-5c2a-7000-8000-000000000102";
const test_node_ids = [3][]const u8{
    "0198f54d-5c2a-7000-8000-000000000111",
    "0198f54d-5c2a-7000-8000-000000000112",
    "0198f54d-5c2a-7000-8000-000000000113",
};
const test_cluster_id = [_]u8{1} ** 16;
const test_local_set_id = [_]u8{2} ** 16;
const test_digest = [_]u8{3} ** 32;
const test_member_ids = [3][16]u8{
    .{ 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
    .{ 0x12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 },
    .{ 0x13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 },
};

fn applySetup(machine: *state_machine.PoolStateMachine, index: u64, encoded: []const u8) !void {
    var result = try machine.stateMachine().apply(.{ .index = index, .term = 1, .data = encoded });
    result.deinit(std.testing.allocator);
}

fn setupMachine(machine: *state_machine.PoolStateMachine, domains: [3][]const u8) !void {
    const allocator = std.testing.allocator;
    const pool = try state_machine.encodeCreatePoolCommand(allocator, .{
        .request_id = "reconciler-pool",
        .proposed_pool_id = test_pool_id,
        .name = "primary",
        .proposed_created_at_unix_ms = 1_753_744_000_000,
    });
    defer allocator.free(pool);
    try applySetup(machine, 1, pool);
    for (test_node_ids, domains, 0..) |node_id, domain, index| {
        const request_id = try std.fmt.allocPrint(allocator, "reconciler-node-{d}", .{index});
        defer allocator.free(request_id);
        const encoded = try state_machine.encodeRegisterNodeCommand(allocator, .{
            .request_id = request_id,
            .node_id = node_id,
            .cluster_id = &test_cluster_id,
            .control_endpoint = "data:9000",
            .nvmf_endpoint = "data:4420",
            .failure_domain = domain,
            .capability_bits = 1,
            .protocol_version = 1,
            .proposed_registered_at_unix_ms = 1_753_744_000_001 + @as(i64, @intCast(index)),
        });
        defer allocator.free(encoded);
        try applySetup(machine, 2 + index, encoded);
    }
    for (test_member_ids, test_node_ids, 0..) |member_id, node_id, index| {
        const request_id = try std.fmt.allocPrint(allocator, "reconciler-member-{d}", .{index});
        defer allocator.free(request_id);
        const encoded = try state_machine.encodeRegisterMemberCommand(allocator, .{
            .request_id = request_id,
            .cluster_id = &test_cluster_id,
            .member_id = &member_id,
            .pool_id = test_pool_id,
            .node_id = node_id,
            .local_set_id = &test_local_set_id,
            .member_slot = @intCast(index),
            .birth_topology_digest = &test_digest,
            .metadata_capacity_bytes = 4096,
            .data_capacity_bytes = 1024 * 1024,
            .extent_size_bytes = 4096,
            .proposed_registered_at_unix_ms = 1_753_744_000_004 + @as(i64, @intCast(index)),
        });
        defer allocator.free(encoded);
        try applySetup(machine, 5 + index, encoded);
    }
    const volume = try state_machine.encodeCreateVolumeCommand(allocator, .{
        .request_id = "reconciler-volume",
        .proposed_volume_id = test_volume_id,
        .pool_id = test_pool_id,
        .name = "database",
        .size_bytes = state_machine.min_volume_size_bytes,
        .proposed_created_at_unix_ms = 1_753_744_000_010,
    });
    defer allocator.free(volume);
    try applySetup(machine, 8, volume);
}

const TestSubmitter = struct {
    machine: *state_machine.PoolStateMachine,
    next_index: u64 = 9,
    submissions: usize = 0,

    fn interface(self: *TestSubmitter) CommandSubmitter {
        return .{ .context = self, .vtable = &vtable };
    }

    fn submitOpaque(context: *anyopaque, _: std.mem.Allocator, command: []const u8) ![]u8 {
        const self: *TestSubmitter = @ptrCast(@alignCast(context));
        const index = self.next_index;
        self.next_index += 1;
        self.submissions += 1;
        const result = try self.machine.stateMachine().apply(.{ .index = index, .term = 1, .data = command });
        return result.response orelse error.MissingApplyResponse;
    }

    const vtable: CommandSubmitter.VTable = .{ .submit = submitOpaque };
};

const TestBackend = struct {
    ensures: usize = 0,
    deletes: usize = 0,

    fn interface(self: *TestBackend) data_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn ensureOpaque(context: *anyopaque, binding: data_service.Binding) !data_service.Digest {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.ensures += 1;
        var digest: data_service.Digest = @splat(0);
        digest[0..16].* = binding.allocation_id;
        return digest;
    }

    fn deleteOpaque(context: *anyopaque, _: data_service.Binding) !void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.deletes += 1;
    }

    const vtable: data_service.Backend.VTable = .{ .ensure = ensureOpaque, .delete = deleteOpaque };
};

const TestDataClient = struct {
    service: *data_service.Service,
    lose_ensure_response: bool = false,
    stale_attestation: bool = false,

    fn interface(self: *TestDataClient) DataServiceClient {
        return .{ .context = self, .vtable = &vtable };
    }

    fn ensureOpaque(context: *anyopaque, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        const self: *TestDataClient = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, endpoint, "data:9000")) return error.InvalidEndpoint;
        var response = try self.service.ensureReplica(request);
        if (self.lose_ensure_response) {
            self.lose_ensure_response = false;
            return error.TransportUnknown;
        }
        if (self.stale_attestation) response.replica.attestation.binding.generation += 1;
        return response;
    }

    fn deleteOpaque(context: *anyopaque, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        const self: *TestDataClient = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, endpoint, "data:9000")) return error.InvalidEndpoint;
        return self.service.deleteReplica(request);
    }

    fn cancelOpaque(_: *anyopaque) void {}

    const vtable: DataServiceClient.VTable = .{
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
        .cancel = cancelOpaque,
    };
};

test "reconciler completes lifecycle and resumes lost ensure after reconstruction" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    try setupMachine(&machine, .{ "rack-a", "rack-b", "rack-c" });
    var submitter = TestSubmitter{ .machine = &machine };
    var store = data_service.MemoryStore.init(allocator);
    defer store.deinit();
    var backend: TestBackend = .{};
    var service = data_service.Service.init(store.store(), backend.interface());
    var data_client = TestDataClient{ .service = &service, .lose_ensure_response = true };
    var reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());

    try reconciler.runOnce();
    try std.testing.expectEqual(@as(usize, 1), submitter.submissions);
    try std.testing.expectError(error.TransportUnknown, reconciler.runOnce());
    try std.testing.expectEqual(@as(usize, 1), backend.ensures);
    try std.testing.expectEqual(@as(usize, 1), submitter.submissions);

    var rebuilt = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 1), backend.ensures);
    try rebuilt.runOnce();
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 3), backend.ensures);
    var active = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer active.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_ACTIVE, active.lifecycle_state);

    const delete_command = try state_machine.encodeDeleteVolumeCommand(allocator, .{
        .request_id = "reconciler-delete",
        .volume_id = test_volume_id,
        .expected_resource_version = active.resource_version,
        .proposed_deleted_at_unix_ms = 1_753_744_000_020,
    });
    defer allocator.free(delete_command);
    const delete_response = try submitter.interface().submit(allocator, delete_command);
    allocator.free(delete_response);
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 3), backend.deletes);
    try std.testing.expectEqual(@as(usize, 1), machine.volumeTombstoneCount());
    try std.testing.expect((try machine.getVolumeById(allocator, test_volume_id)) == null);
}

test "reconciler rejects stale attestation without activation" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    try setupMachine(&machine, .{ "rack-a", "rack-b", "rack-c" });
    var submitter = TestSubmitter{ .machine = &machine };
    var store = data_service.MemoryStore.init(allocator);
    defer store.deinit();
    var backend: TestBackend = .{};
    var service = data_service.Service.init(store.store(), backend.interface());
    var data_client = TestDataClient{ .service = &service, .stale_attestation = true };
    var reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());
    try reconciler.runOnce();
    try std.testing.expectError(error.InvalidAttestation, reconciler.runOnce());
    try std.testing.expectEqual(@as(usize, 1), submitter.submissions);
    const snapshot = try machine.listReconcileVolumes(allocator);
    defer {
        for (snapshot) |*volume| volume.deinit(allocator);
        allocator.free(snapshot);
    }
    try std.testing.expectEqual(pb.ReplicaPlacementState.REPLICA_PLACEMENT_STATE_RESERVED, snapshot[0].placements[0].state);
}

test "reconciler emits no command when placement is insufficient" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    try setupMachine(&machine, .{ "rack-a", "rack-a", "rack-b" });
    var submitter = TestSubmitter{ .machine = &machine };
    var store = data_service.MemoryStore.init(allocator);
    defer store.deinit();
    var backend: TestBackend = .{};
    var service = data_service.Service.init(store.store(), backend.interface());
    var data_client = TestDataClient{ .service = &service };
    var reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());
    try std.testing.expectError(error.InsufficientPlacement, reconciler.runOnce());
    try std.testing.expectEqual(@as(usize, 0), submitter.submissions);
}
