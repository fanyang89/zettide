const std = @import("std");

const data_service = @import("data_service.zig");
const pb = @import("control_proto");
const primary_lease = @import("primary_lease.zig");
const protocol = @import("zettide_data_service_contracts");
const replica_fence = @import("replica_fence.zig");
const state_machine = @import("state_machine.zig");
const uuid = @import("uuid");

pub const Id = protocol.Id;
pub const Digest = protocol.Digest;
pub const AuthorityBinding = protocol.AuthorityBinding;
pub const StageRequest = protocol.StageRequest;
pub const StageAck = protocol.StageAck;
pub const RecoveryRequest = protocol.RecoveryRequest;
pub const RecoveryResult = protocol.RecoveryResult;
pub const MarkReadyRequest = protocol.MarkReadyRequest;
pub const PrimaryLeaseStatus = protocol.PrimaryLeaseStatus;

pub const DataServiceClient = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ensure: *const fn (*anyopaque, []const u8, data_service.Request) anyerror!data_service.Response,
        delete: *const fn (*anyopaque, []const u8, data_service.Request) anyerror!data_service.Response,
        identify_holder: *const fn (*anyopaque, []const u8) anyerror!Id,
        stage_primary: *const fn (*anyopaque, []const u8, StageRequest) anyerror!StageAck,
        fence_replica: *const fn (*anyopaque, []const u8, replica_fence.Binding) anyerror!replica_fence.Result,
        recover_primary: *const fn (*anyopaque, []const u8, RecoveryRequest) anyerror!RecoveryResult,
        mark_primary_ready: *const fn (*anyopaque, []const u8, MarkReadyRequest) anyerror!void,
        inspect_primary: *const fn (*anyopaque, []const u8, MarkReadyRequest) anyerror!PrimaryLeaseStatus,
        /// Must be thread-safe, idempotent, and promptly unblock in-flight calls.
        cancel: *const fn (*anyopaque) void,
    };

    fn ensure(self: DataServiceClient, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        return self.vtable.ensure(self.context, endpoint, request);
    }

    fn delete(self: DataServiceClient, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        return self.vtable.delete(self.context, endpoint, request);
    }

    fn identifyHolder(self: DataServiceClient, endpoint: []const u8) !Id {
        return self.vtable.identify_holder(self.context, endpoint);
    }

    fn stagePrimary(self: DataServiceClient, endpoint: []const u8, request: StageRequest) !StageAck {
        return self.vtable.stage_primary(self.context, endpoint, request);
    }

    fn fenceReplica(self: DataServiceClient, endpoint: []const u8, binding: replica_fence.Binding) !replica_fence.Result {
        return self.vtable.fence_replica(self.context, endpoint, binding);
    }

    fn recoverPrimary(self: DataServiceClient, endpoint: []const u8, request: RecoveryRequest) !RecoveryResult {
        return self.vtable.recover_primary(self.context, endpoint, request);
    }

    fn markPrimaryReady(self: DataServiceClient, endpoint: []const u8, request: MarkReadyRequest) !void {
        return self.vtable.mark_primary_ready(self.context, endpoint, request);
    }

    fn inspectPrimary(self: DataServiceClient, endpoint: []const u8, request: MarkReadyRequest) !PrimaryLeaseStatus {
        return self.vtable.inspect_primary(self.context, endpoint, request);
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
    failover_observations: std.AutoHashMapUnmanaged(Id, FailoverObservation) = .empty,
    deletion_observations: std.AutoHashMapUnmanaged(Id, DeletionObservation) = .empty,
    maintenance_cursor: usize = 0,
    awake_now_ms_override: ?u64 = null,

    const FailoverObservation = struct { resource_version: u64, first_seen_ms: u64 };
    const DeletionObservation = struct { resource_version: u64, lease_id: Id, first_seen_ms: u64 };

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

    pub fn deinit(self: *Reconciler) void {
        self.failover_observations.deinit(self.allocator);
        self.deletion_observations.deinit(self.allocator);
        self.* = undefined;
    }

    /// Must run on the Raft driver thread, normally from a ReadIndex callback.
    /// The returned action owns everything needed by `execute`.
    pub fn planOnce(self: *Reconciler) !?*Action {
        const volumes = try self.machine.listReconcileVolumes(self.allocator);
        defer {
            for (volumes) |*volume| volume.deinit(self.allocator);
            self.allocator.free(volumes);
        }
        try self.pruneFailoverObservations(volumes);
        try self.pruneDeletionObservations(volumes);
        // Deletion is globally highest priority, but immature/attached volumes do not block others.
        for (volumes) |volume| {
            if (volume.volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_DELETING or volume.has_attachments) continue;
            if (volume.primary_authority != null and !try self.deletionWaitMature(volume)) continue;
            return try self.planDelete(volume);
        }
        // Failover work precedes ordinary provisioning and lease maintenance.
        for (volumes) |volume| {
            if (volume.placements.len != volume.allocations.len) return error.InconsistentSnapshot;
            if (volume.primary_failover) |failover| {
                if (volume.primary_authority == null) return error.InconsistentSnapshot;
                switch (failover.state) {
                    .PRIMARY_FAILOVER_STATE_WAITING_LEASE => {
                        if (!try self.failoverWaitMature(failover)) continue;
                        return try self.planCompleteFailoverWait(volume, volume.primary_authority.?, failover);
                    },
                    .PRIMARY_FAILOVER_STATE_LEASE_EXPIRED => return try self.planFailoverProposal(volume, volume.primary_authority.?, failover),
                    .PRIMARY_FAILOVER_STATE_FENCING => {
                        if (volume.primary_authority_candidate) |candidate| switch (candidate.state) {
                            .PRIMARY_AUTHORITY_STATE_PENDING => return try self.planActivateAuthority(volume, candidate),
                            .PRIMARY_AUTHORITY_STATE_ACTIVATED => return try self.planFailoverReady(volume, volume.primary_authority.?, candidate, failover),
                            else => return error.InconsistentSnapshot,
                        } else return try self.planFailoverProposal(volume, volume.primary_authority.?, failover);
                    },
                    else => return error.InconsistentSnapshot,
                }
            }
        }
        // Provisioning and existing candidates are deterministic finite work.
        for (volumes) |volume| {
            if (volume.placements.len != volume.allocations.len or volume.primary_failover != null) continue;
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
            if (volume.volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_PROVISIONING and
                volume.volume.operation_phase == .VOLUME_OPERATION_PHASE_FENCING)
            {
                if (volume.primary_authority_candidate) |authority| switch (authority.state) {
                    .PRIMARY_AUTHORITY_STATE_PENDING => return try self.planActivateAuthority(volume, authority),
                    .PRIMARY_AUTHORITY_STATE_ACTIVATED => return try self.planReadyAuthority(volume, authority),
                    else => {},
                } else return try self.planProposeAuthority(volume);
            }
            if (volume.volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_ACTIVE and
                volume.volume.operation_phase == .VOLUME_OPERATION_PHASE_NONE and
                volume.primary_authority != null and
                volume.primary_authority.?.state == .PRIMARY_AUTHORITY_STATE_READY)
            {
                if (volume.primary_authority_candidate) |candidate| switch (candidate.state) {
                    .PRIMARY_AUTHORITY_STATE_PENDING => return try self.planActivateAuthority(volume, candidate),
                    .PRIMARY_AUTHORITY_STATE_ACTIVATED => return try self.planRenewalReady(volume, volume.primary_authority.?, candidate),
                    else => return error.InconsistentSnapshot,
                };
            }
        }
        // Stable ACTIVE inspection is last so it cannot starve finite work behind it.
        if (nextMaintenanceIndex(volumes, self.maintenance_cursor)) |index| {
            self.maintenance_cursor = (index + 1) % volumes.len;
            const volume = volumes[index];
            return try self.planInspectRenewal(volume, volume.primary_authority.?);
        }
        return null;
    }

    fn pruneFailoverObservations(self: *Reconciler, volumes: []const state_machine.PoolStateMachine.ReconcileVolume) !void {
        var live: std.AutoHashMapUnmanaged(Id, u64) = .empty;
        defer live.deinit(self.allocator);
        for (volumes) |volume| if (volume.primary_failover) |failover| {
            if (failover.failover_id.len != 16) return error.InconsistentSnapshot;
            try live.put(self.allocator, failover.failover_id[0..16].*, failover.resource_version);
        };
        var stale: std.ArrayList(Id) = .empty;
        defer stale.deinit(self.allocator);
        var iterator = self.failover_observations.iterator();
        while (iterator.next()) |entry| {
            if (live.get(entry.key_ptr.*)) |revision| {
                if (revision == entry.value_ptr.resource_version) continue;
            }
            try stale.append(self.allocator, entry.key_ptr.*);
        }
        for (stale.items) |id| _ = self.failover_observations.remove(id);
    }

    fn failoverWaitMature(self: *Reconciler, failover: pb.PrimaryFailover) !bool {
        const id = failover.failover_id[0..16].*;
        const now_ms = self.awake_now_ms_override orelse
            (std.math.cast(u64, std.Io.Timestamp.now(self.io, .awake).toMilliseconds()) orelse return error.InvalidTimestamp);
        const result = try self.failover_observations.getOrPut(self.allocator, id);
        if (!result.found_existing or result.value_ptr.resource_version != failover.resource_version) {
            result.value_ptr.* = .{ .resource_version = failover.resource_version, .first_seen_ms = now_ms };
            return false;
        }
        return now_ms -| result.value_ptr.first_seen_ms >= primary_lease.duration_ms;
    }

    fn pruneDeletionObservations(self: *Reconciler, volumes: []const state_machine.PoolStateMachine.ReconcileVolume) !void {
        var live: std.AutoHashMapUnmanaged(Id, DeletionObservation) = .empty;
        defer live.deinit(self.allocator);
        for (volumes) |volume| {
            if (volume.volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_DELETING) continue;
            const current = volume.primary_authority orelse continue;
            try live.put(self.allocator, try parseId(volume.volume.id), .{
                .resource_version = volume.volume.resource_version,
                .lease_id = current.lease_id[0..16].*,
                .first_seen_ms = 0,
            });
        }
        var stale: std.ArrayList(Id) = .empty;
        defer stale.deinit(self.allocator);
        var iterator = self.deletion_observations.iterator();
        while (iterator.next()) |entry| {
            const expected = live.get(entry.key_ptr.*);
            if (expected != null and expected.?.resource_version == entry.value_ptr.resource_version and std.mem.eql(u8, &expected.?.lease_id, &entry.value_ptr.lease_id)) continue;
            try stale.append(self.allocator, entry.key_ptr.*);
        }
        for (stale.items) |id| _ = self.deletion_observations.remove(id);
    }

    fn deletionWaitMature(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume) !bool {
        const current = volume.primary_authority orelse return true;
        const id = try parseId(volume.volume.id);
        const now_ms = self.awake_now_ms_override orelse
            (std.math.cast(u64, std.Io.Timestamp.now(self.io, .awake).toMilliseconds()) orelse return error.InvalidTimestamp);
        const result = try self.deletion_observations.getOrPut(self.allocator, id);
        const lease_id = current.lease_id[0..16].*;
        if (!result.found_existing or result.value_ptr.resource_version != volume.volume.resource_version or !std.mem.eql(u8, &result.value_ptr.lease_id, &lease_id)) {
            result.value_ptr.* = .{ .resource_version = volume.volume.resource_version, .lease_id = lease_id, .first_seen_ms = now_ms };
            return false;
        }
        return now_ms -| result.value_ptr.first_seen_ms >= primary_lease.duration_ms;
    }

    fn planCompleteFailoverWait(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume, current: pb.PrimaryAuthority, failover: pb.PrimaryFailover) !*Action {
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        action.kind = .{ .complete_failover_wait = try state_machine.encodeCompletePrimaryFailoverLeaseWaitCommand(action.arena.allocator(), .{
            .volume_id = volume.volume.id,
            .failover_id = failover.failover_id,
            .revoked_lease_id = failover.revoked_lease_id,
            .revoked_authority_generation = failover.revoked_authority_generation,
            .revoked_write_epoch = failover.revoked_write_epoch,
            .expected_volume_resource_version = volume.volume.resource_version,
            .expected_failover_resource_version = failover.resource_version,
            .expected_current_resource_version = current.resource_version,
        }) };
        return action;
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
        action.kind = .{ .ensure = .{
            .endpoint = try allocator.dupe(u8, node.control_endpoint),
            .request = request,
            .expected_volume_resource_version = volume.volume.resource_version,
            .expected_placement_resource_version = placement.resource_version,
            .expected_allocation_resource_version = allocation.resource_version,
        } };
        return action;
    }

    fn planDelete(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume) !*Action {
        if (volume.has_attachments) return error.VolumeHasAttachments;
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

    fn planProposeAuthority(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume) !*Action {
        if (volume.placements.len != state_machine.volume_target_replica_count) return error.InconsistentSnapshot;
        const primary = volume.placements[0];
        if (primary.replica_index != 0 or primary.state != .REPLICA_PLACEMENT_STATE_ACTIVE) return error.InconsistentSnapshot;
        const node = nodeById(volume.nodes, primary.node_id) orelse return error.InconsistentSnapshot;
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        action.kind = .{ .propose_authority = .{
            .endpoint = try allocator.dupe(u8, node.control_endpoint),
            .volume_id_text = try allocator.dupe(u8, volume.volume.id),
            .primary_placement_id_text = try allocator.dupe(u8, primary.id),
            .primary_node_id_text = try allocator.dupe(u8, primary.node_id),
            .volume_id = try parseId(volume.volume.id),
            .primary_placement_id = try parseId(primary.id),
            .primary_node_id = try parseId(primary.node_id),
            .lease_id = randomId(self.io),
            .activation_nonce = randomId(self.io),
            .write_epoch = volume.volume.write_epoch,
            .placement_revision = volume.volume.placement_revision,
            .expected_volume_resource_version = volume.volume.resource_version,
        } };
        return action;
    }

    fn planActivateAuthority(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume, authority: pb.PrimaryAuthority) !*Action {
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        action.kind = .{ .activate_authority = .{
            .endpoint = try allocator.dupe(u8, (nodeById(volume.nodes, authority.primary_node_id) orelse return error.InconsistentSnapshot).control_endpoint),
            .request = .{ .binding = try authorityBinding(authority), .lease_duration_ms = authority.lease_duration_ms },
            .volume_id_text = try allocator.dupe(u8, authority.volume_id),
            .expected_volume_resource_version = volume.volume.resource_version,
            .expected_authority_resource_version = authority.resource_version,
            .abort_command = try state_machine.encodeAbortPrimaryAuthorityCandidateCommand(allocator, .{
                .volume_id = authority.volume_id,
                .lease_id = authority.lease_id,
                .authority_generation = authority.authority_generation,
                .expected_volume_resource_version = volume.volume.resource_version,
                .expected_candidate_resource_version = authority.resource_version,
                .expected_current_resource_version = if (volume.primary_authority) |current| current.resource_version else 0,
            }),
        } };
        return action;
    }

    fn planReadyAuthority(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume, authority: pb.PrimaryAuthority) !*Action {
        if (volume.placements.len != state_machine.volume_target_replica_count) return error.InconsistentSnapshot;
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        const binding = try authorityBinding(authority);
        const replicas = try allocator.alloc(Action.FenceReplica, volume.placements.len);
        for (volume.placements, replicas) |placement, *replica| {
            const node = nodeById(volume.nodes, placement.node_id) orelse return error.InconsistentSnapshot;
            replica.* = .{
                .endpoint = try allocator.dupe(u8, node.control_endpoint),
                .binding = .{
                    .operation_id = stableFenceOperationId(binding, try parseId(placement.id), placement.generation),
                    .volume_id = binding.volume_id,
                    .placement_id = try parseId(placement.id),
                    .replica_generation = placement.generation,
                    .write_epoch = binding.write_epoch,
                    .primary_node_id = binding.primary_node_id,
                    .lease_id = binding.lease_id,
                    .authority_digest = binding.authority_digest,
                },
            };
        }
        const primary_node = nodeById(volume.nodes, authority.primary_node_id) orelse return error.InconsistentSnapshot;
        action.kind = .{ .ready_authority = .{
            .primary_endpoint = try allocator.dupe(u8, primary_node.control_endpoint),
            .volume_id_text = try allocator.dupe(u8, authority.volume_id),
            .placement_id_texts = try dupePlacementIds(allocator, volume.placements),
            .binding = binding,
            .request = .{ .binding = binding },
            .replicas = replicas,
            .expected_volume_resource_version = volume.volume.resource_version,
            .expected_authority_resource_version = authority.resource_version,
            .abort_command = try state_machine.encodeAbortPrimaryAuthorityCandidateCommand(allocator, .{
                .volume_id = authority.volume_id,
                .lease_id = authority.lease_id,
                .authority_generation = authority.authority_generation,
                .expected_volume_resource_version = volume.volume.resource_version,
                .expected_candidate_resource_version = authority.resource_version,
                .expected_current_resource_version = 0,
            }),
        } };
        return action;
    }

    fn planInspectRenewal(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume, authority: pb.PrimaryAuthority) !*Action {
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        var binding = try authorityBinding(authority);
        binding.lease_id = randomId(self.io);
        binding.activation_nonce = randomId(self.io);
        binding.authority_generation = std.math.add(u64, binding.authority_generation, 1) catch return error.InconsistentSnapshot;
        binding.authority_digest = @splat(0);
        binding.authority_digest = authorityDigest(binding);
        const proposed: pb.PrimaryAuthority = .{
            .volume_id = authority.volume_id,
            .primary_placement_id = authority.primary_placement_id,
            .primary_node_id = authority.primary_node_id,
            .lease_id = &binding.lease_id,
            .holder_boot_id = &binding.holder_boot_id,
            .authority_generation = binding.authority_generation,
            .write_epoch = binding.write_epoch,
            .placement_revision = binding.placement_revision,
            .activation_nonce = &binding.activation_nonce,
            .lease_duration_ms = primary_lease.duration_ms,
            .state = .PRIMARY_AUTHORITY_STATE_PENDING,
            .authority_digest = &binding.authority_digest,
        };
        const command = try state_machine.encodeProposePrimaryAuthorityCommand(allocator, .{
            .authority = proposed,
            .expected_volume_resource_version = volume.volume.resource_version,
        });
        const failover_id = randomId(self.io);
        action.kind = .{ .inspect_renewal = .{
            .endpoint = try allocator.dupe(u8, (nodeById(volume.nodes, authority.primary_node_id) orelse return error.InconsistentSnapshot).control_endpoint),
            .request = .{ .binding = try authorityBinding(authority) },
            .command = command,
            .begin_failover_command = try state_machine.encodeBeginPrimaryFailoverCommand(allocator, .{
                .volume_id = authority.volume_id,
                .current_lease_id = authority.lease_id,
                .current_authority_generation = authority.authority_generation,
                .current_write_epoch = authority.write_epoch,
                .failover_id = &failover_id,
                .expected_volume_resource_version = volume.volume.resource_version,
                .expected_current_resource_version = authority.resource_version,
            }),
        } };
        return action;
    }

    fn planFailoverProposal(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume, current: pb.PrimaryAuthority, failover: pb.PrimaryFailover) !*Action {
        var target: ?pb.ReplicaPlacement = null;
        for (volume.placements) |placement| {
            if (std.mem.eql(u8, placement.id, current.primary_placement_id) or placement.state != .REPLICA_PLACEMENT_STATE_ACTIVE) continue;
            if (target == null or placement.replica_index < target.?.replica_index) target = placement;
        }
        const placement = target orelse return error.InconsistentSnapshot;
        const node = nodeById(volume.nodes, placement.node_id) orelse return error.InconsistentSnapshot;
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        action.kind = .{ .propose_failover = .{
            .endpoint = try allocator.dupe(u8, node.control_endpoint),
            .volume_id_text = try allocator.dupe(u8, volume.volume.id),
            .placement_id_text = try allocator.dupe(u8, placement.id),
            .node_id_text = try allocator.dupe(u8, placement.node_id),
            .volume_id = try parseId(volume.volume.id),
            .placement_id = try parseId(placement.id),
            .node_id = try parseId(placement.node_id),
            .lease_id = randomId(self.io),
            .activation_nonce = randomId(self.io),
            .failover_id = failover.failover_id[0..16].*,
            .holder_generation = current.authority_generation + 1,
            .write_epoch = failover.target_write_epoch,
            .placement_revision = current.placement_revision,
            .expected_volume_resource_version = volume.volume.resource_version,
            .expected_failover_resource_version = failover.resource_version,
        } };
        return action;
    }

    fn planFailoverReady(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume, current: pb.PrimaryAuthority, candidate: pb.PrimaryAuthority, failover: pb.PrimaryFailover) !*Action {
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        const binding = try authorityBinding(candidate);
        const replicas = try allocator.alloc(Action.FenceReplica, volume.placements.len);
        for (volume.placements, replicas) |placement, *replica| {
            const node = nodeById(volume.nodes, placement.node_id) orelse return error.InconsistentSnapshot;
            replica.* = .{
                .endpoint = try allocator.dupe(u8, node.control_endpoint),
                .binding = .{
                    .operation_id = stableFenceOperationId(binding, try parseId(placement.id), placement.generation),
                    .volume_id = binding.volume_id,
                    .placement_id = try parseId(placement.id),
                    .replica_generation = placement.generation,
                    .write_epoch = binding.write_epoch,
                    .primary_node_id = binding.primary_node_id,
                    .lease_id = binding.lease_id,
                    .authority_digest = binding.authority_digest,
                },
            };
        }
        action.kind = .{ .failover_ready = .{
            .primary_endpoint = try allocator.dupe(u8, (nodeById(volume.nodes, candidate.primary_node_id) orelse return error.InconsistentSnapshot).control_endpoint),
            .volume_id_text = try allocator.dupe(u8, candidate.volume_id),
            .placement_id_texts = try dupePlacementIds(allocator, volume.placements),
            .request = .{ .binding = binding },
            .replicas = replicas,
            .failover_id = failover.failover_id[0..16].*,
            .expected_volume_resource_version = volume.volume.resource_version,
            .expected_candidate_resource_version = candidate.resource_version,
            .expected_current_resource_version = current.resource_version,
            .expected_failover_resource_version = failover.resource_version,
            .abort_command = try state_machine.encodeAbortPrimaryAuthorityCandidateCommand(allocator, .{
                .volume_id = candidate.volume_id,
                .lease_id = candidate.lease_id,
                .authority_generation = candidate.authority_generation,
                .expected_volume_resource_version = volume.volume.resource_version,
                .expected_candidate_resource_version = candidate.resource_version,
                .expected_current_resource_version = current.resource_version,
            }),
        } };
        return action;
    }

    fn planRenewalReady(self: *Reconciler, volume: state_machine.PoolStateMachine.ReconcileVolume, current: pb.PrimaryAuthority, candidate: pb.PrimaryAuthority) !*Action {
        const action = try Action.create(self.allocator);
        errdefer action.deinit();
        const allocator = action.arena.allocator();
        const binding = try authorityBinding(candidate);
        const command = try state_machine.encodeCommitPrimaryAuthorityRenewalReadyCommand(allocator, .{
            .volume_id = candidate.volume_id,
            .lease_id = candidate.lease_id,
            .authority_generation = candidate.authority_generation,
            .write_epoch = candidate.write_epoch,
            .placement_revision = candidate.placement_revision,
            .expected_volume_resource_version = volume.volume.resource_version,
            .expected_candidate_resource_version = candidate.resource_version,
            .expected_current_resource_version = current.resource_version,
        });
        action.kind = .{ .renewal_ready = .{
            .endpoint = try allocator.dupe(u8, (nodeById(volume.nodes, candidate.primary_node_id) orelse return error.InconsistentSnapshot).control_endpoint),
            .request = .{ .binding = binding },
            .ready_command = command,
            .abort_command = try state_machine.encodeAbortPrimaryAuthorityCandidateCommand(allocator, .{
                .volume_id = candidate.volume_id,
                .lease_id = candidate.lease_id,
                .authority_generation = candidate.authority_generation,
                .expected_volume_resource_version = volume.volume.resource_version,
                .expected_candidate_resource_version = candidate.resource_version,
                .expected_current_resource_version = current.resource_version,
            }),
        } };
        return action;
    }
};

fn nextMaintenanceIndex(volumes: []const state_machine.PoolStateMachine.ReconcileVolume, start: usize) ?usize {
    if (volumes.len == 0) return null;
    for (0..volumes.len) |offset| {
        const index = (start + offset) % volumes.len;
        const volume = volumes[index];
        if (volume.volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_ACTIVE and
            volume.volume.operation_phase == .VOLUME_OPERATION_PHASE_NONE and
            volume.primary_failover == null and volume.primary_authority_candidate == null and
            volume.primary_authority != null and volume.primary_authority.?.state == .PRIMARY_AUTHORITY_STATE_READY)
            return index;
    }
    return null;
}

pub const Action = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    kind: Kind = undefined,

    const Ensure = struct {
        endpoint: []const u8,
        request: data_service.Request,
        expected_volume_resource_version: u64,
        expected_placement_resource_version: u64,
        expected_allocation_resource_version: u64,
    };

    const DeleteReplica = struct {
        endpoint: []const u8,
        request: data_service.Request,
    };

    const Delete = struct {
        replicas: []const DeleteReplica,
        command: []const u8,
    };

    const ProposeAuthority = struct {
        endpoint: []const u8,
        volume_id_text: []const u8,
        primary_placement_id_text: []const u8,
        primary_node_id_text: []const u8,
        volume_id: Id,
        primary_placement_id: Id,
        primary_node_id: Id,
        lease_id: Id,
        activation_nonce: Id,
        write_epoch: u64,
        placement_revision: u64,
        expected_volume_resource_version: u64,
    };

    const ActivateAuthority = struct {
        endpoint: []const u8,
        request: StageRequest,
        volume_id_text: []const u8,
        expected_volume_resource_version: u64,
        expected_authority_resource_version: u64,
        abort_command: []const u8,
    };

    const FenceReplica = struct {
        endpoint: []const u8,
        binding: replica_fence.Binding,
    };

    const ReadyAuthority = struct {
        primary_endpoint: []const u8,
        volume_id_text: []const u8,
        placement_id_texts: []const []const u8,
        binding: AuthorityBinding,
        request: MarkReadyRequest,
        replicas: []const FenceReplica,
        expected_volume_resource_version: u64,
        expected_authority_resource_version: u64,
        abort_command: []const u8,
    };

    const InspectRenewal = struct {
        endpoint: []const u8,
        request: MarkReadyRequest,
        command: []const u8,
        begin_failover_command: []const u8,
    };

    const ProposeFailover = struct {
        endpoint: []const u8,
        volume_id_text: []const u8,
        placement_id_text: []const u8,
        node_id_text: []const u8,
        volume_id: Id,
        placement_id: Id,
        node_id: Id,
        lease_id: Id,
        activation_nonce: Id,
        failover_id: Id,
        holder_generation: u64,
        write_epoch: u64,
        placement_revision: u64,
        expected_volume_resource_version: u64,
        expected_failover_resource_version: u64,
    };

    const FailoverReady = struct {
        primary_endpoint: []const u8,
        volume_id_text: []const u8,
        placement_id_texts: []const []const u8,
        request: MarkReadyRequest,
        replicas: []const FenceReplica,
        failover_id: Id,
        expected_volume_resource_version: u64,
        expected_candidate_resource_version: u64,
        expected_current_resource_version: u64,
        expected_failover_resource_version: u64,
        abort_command: []const u8,
    };

    const RenewalReady = struct {
        endpoint: []const u8,
        request: MarkReadyRequest,
        ready_command: []const u8,
        abort_command: []const u8,
    };

    const Kind = union(enum) {
        reserve: []const u8,
        ensure: Ensure,
        delete: Delete,
        propose_authority: ProposeAuthority,
        activate_authority: ActivateAuthority,
        ready_authority: ReadyAuthority,
        inspect_renewal: InspectRenewal,
        renewal_ready: RenewalReady,
        propose_failover: ProposeFailover,
        failover_ready: FailoverReady,
        complete_failover_wait: []const u8,
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
                const command = try state_machine.encodeActivateReplicaCommand(self.parent_allocator, .{
                    .volume_id = ensure.request.volume_id,
                    .placement_id = ensure.request.placement_id,
                    .allocation_id = ensure.request.allocation_id,
                    .expected_volume_resource_version = ensure.expected_volume_resource_version,
                    .expected_placement_resource_version = ensure.expected_placement_resource_version,
                    .expected_allocation_resource_version = ensure.expected_allocation_resource_version,
                    .attestation = .{
                        .volume_id = ensure.request.volume_id,
                        .placement_id = ensure.request.placement_id,
                        .allocation_id = ensure.request.allocation_id,
                        .generation = ensure.request.generation,
                        .member_id = ensure.request.member_id,
                        .offset_bytes = ensure.request.offset_bytes,
                        .length_bytes = ensure.request.length_bytes,
                        .backend_digest = &response.replica.attestation.backend_digest,
                    },
                });
                defer self.parent_allocator.free(command);
                try submitAndValidate(self.parent_allocator, submitter, command, .activate);
            },
            .delete => |delete| {
                for (delete.replicas) |replica| {
                    const response = try data_client.delete(replica.endpoint, replica.request);
                    try validateDataResponse(response, replica.request.operation_id, replica.request, .tombstoned);
                }
                try submitAndValidate(self.parent_allocator, submitter, delete.command, .finalize);
            },
            .propose_authority => |propose| {
                const holder_boot_id = try data_client.identifyHolder(propose.endpoint);
                if (!validUuidV7Bytes(holder_boot_id)) return error.InvalidHolderIdentity;
                const binding: AuthorityBinding = .{
                    .volume_id = propose.volume_id,
                    .primary_placement_id = propose.primary_placement_id,
                    .primary_node_id = propose.primary_node_id,
                    .lease_id = propose.lease_id,
                    .holder_boot_id = holder_boot_id,
                    .authority_generation = 1,
                    .write_epoch = propose.write_epoch,
                    .placement_revision = propose.placement_revision,
                    .activation_nonce = propose.activation_nonce,
                    .authority_digest = @splat(0),
                };
                var finalized = binding;
                finalized.authority_digest = authorityDigest(binding);
                const command = try state_machine.encodeProposePrimaryAuthorityCommand(self.parent_allocator, .{
                    .authority = .{
                        .volume_id = propose.volume_id_text,
                        .primary_placement_id = propose.primary_placement_id_text,
                        .primary_node_id = propose.primary_node_id_text,
                        .lease_id = &finalized.lease_id,
                        .holder_boot_id = &finalized.holder_boot_id,
                        .authority_generation = finalized.authority_generation,
                        .write_epoch = finalized.write_epoch,
                        .placement_revision = finalized.placement_revision,
                        .activation_nonce = &finalized.activation_nonce,
                        .lease_duration_ms = primary_lease.duration_ms,
                        .state = .PRIMARY_AUTHORITY_STATE_PENDING,
                        .authority_digest = &finalized.authority_digest,
                    },
                    .expected_volume_resource_version = propose.expected_volume_resource_version,
                });
                defer self.parent_allocator.free(command);
                try submitAndValidate(self.parent_allocator, submitter, command, .propose_authority);
            },
            .activate_authority => |activate| {
                const holder_boot_id = try data_client.identifyHolder(activate.endpoint);
                if (!validUuidV7Bytes(holder_boot_id)) return error.InvalidHolderIdentity;
                if (!std.mem.eql(u8, &holder_boot_id, &activate.request.binding.holder_boot_id)) {
                    try submitAndValidate(self.parent_allocator, submitter, activate.abort_command, .abort_authority);
                    return;
                }
                const ack = try data_client.stagePrimary(activate.endpoint, activate.request);
                if (!std.meta.eql(ack.request, activate.request)) return error.InvalidStageAck;
                const binding = activate.request.binding;
                const command = try state_machine.encodeActivatePrimaryAuthorityCommand(self.parent_allocator, .{
                    .volume_id = activate.volume_id_text,
                    .lease_id = &binding.lease_id,
                    .activation_nonce = &binding.activation_nonce,
                    .authority_generation = binding.authority_generation,
                    .write_epoch = binding.write_epoch,
                    .placement_revision = binding.placement_revision,
                    .expected_volume_resource_version = activate.expected_volume_resource_version,
                    .expected_authority_resource_version = activate.expected_authority_resource_version,
                });
                defer self.parent_allocator.free(command);
                try submitAndValidate(self.parent_allocator, submitter, command, .activate_authority);
            },
            .ready_authority => |ready| {
                const status = try data_client.inspectPrimary(ready.primary_endpoint, ready.request);
                try validatePrimaryLeaseStatus(status, ready.request);
                if (!status.candidate_fresh) {
                    try submitAndValidate(self.parent_allocator, submitter, ready.abort_command, .abort_authority);
                    return;
                }
                const evidence = try self.parent_allocator.alloc(pb.ReplicaFenceEvidence, ready.replicas.len);
                defer self.parent_allocator.free(evidence);
                for (ready.replicas, evidence, ready.placement_id_texts) |replica, *proof, placement_id| {
                    const result = try data_client.fenceReplica(replica.endpoint, replica.binding);
                    if (!std.meta.eql(result.binding, replica.binding) or isZero(&result.fence_digest)) return error.InvalidFenceProof;
                    proof.* = .{
                        .placement_id = placement_id,
                        .replica_generation = result.binding.replica_generation,
                        .write_epoch = result.binding.write_epoch,
                        .lease_id = &result.binding.lease_id,
                        .authority_digest = &result.binding.authority_digest,
                        .fence_digest = &result.fence_digest,
                    };
                }
                const recovery_request: RecoveryRequest = .{ .binding = ready.binding };
                const recovery = try data_client.recoverPrimary(ready.primary_endpoint, recovery_request);
                if (!std.meta.eql(recovery.request, recovery_request) or isZero(&recovery.history_digest) or
                    (recovery.certified_sequence == 0) != recovery.empty_frontier) return error.InvalidRecoveryProof;
                const command = try state_machine.encodeCommitPrimaryAuthorityReadyCommand(self.parent_allocator, .{
                    .volume_id = ready.volume_id_text,
                    .lease_id = &ready.binding.lease_id,
                    .authority_digest = &ready.binding.authority_digest,
                    .authority_generation = ready.binding.authority_generation,
                    .write_epoch = ready.binding.write_epoch,
                    .placement_revision = ready.binding.placement_revision,
                    .expected_volume_resource_version = ready.expected_volume_resource_version,
                    .expected_authority_resource_version = ready.expected_authority_resource_version,
                    .fence_evidence = .{ .items = evidence, .capacity = evidence.len },
                    .recovery_evidence = .{
                        .volume_id = ready.volume_id_text,
                        .write_epoch = ready.binding.write_epoch,
                        .certified_sequence = recovery.certified_sequence,
                        .history_digest = &recovery.history_digest,
                        .empty_frontier = recovery.empty_frontier,
                    },
                });
                defer self.parent_allocator.free(command);
                if (try submitReadyAndValidate(self.parent_allocator, submitter, command, ready.binding)) {
                    try data_client.markPrimaryReady(ready.primary_endpoint, .{ .binding = ready.binding });
                }
            },
            .inspect_renewal => |inspect| {
                const status = try data_client.inspectPrimary(inspect.endpoint, inspect.request);
                try validatePrimaryLeaseStatus(status, inspect.request);
                if (status.candidate_fresh) {
                    try data_client.markPrimaryReady(inspect.endpoint, inspect.request);
                } else if (status.current_admitting) {
                    if (status.should_renew) try submitAndValidate(self.parent_allocator, submitter, inspect.command, .propose_authority);
                } else {
                    const holder_boot_id = try data_client.identifyHolder(inspect.endpoint);
                    if (!validUuidV7Bytes(holder_boot_id)) return error.InvalidHolderIdentity;
                    if (std.mem.eql(u8, &holder_boot_id, &inspect.request.binding.holder_boot_id)) {
                        try submitAndValidate(self.parent_allocator, submitter, inspect.command, .propose_authority);
                    } else {
                        try submitAndValidate(self.parent_allocator, submitter, inspect.begin_failover_command, .begin_failover);
                    }
                }
            },
            .renewal_ready => |renewal| {
                const status = try data_client.inspectPrimary(renewal.endpoint, renewal.request);
                try validatePrimaryLeaseStatus(status, renewal.request);
                if (!status.candidate_fresh) {
                    try submitAndValidate(self.parent_allocator, submitter, renewal.abort_command, .abort_authority);
                } else if (try submitReadyAndValidate(self.parent_allocator, submitter, renewal.ready_command, renewal.request.binding)) {
                    try data_client.markPrimaryReady(renewal.endpoint, renewal.request);
                }
            },
            .propose_failover => |propose| {
                const holder_boot_id = try data_client.identifyHolder(propose.endpoint);
                if (!validUuidV7Bytes(holder_boot_id)) return error.InvalidHolderIdentity;
                var binding: AuthorityBinding = .{
                    .volume_id = propose.volume_id,
                    .primary_placement_id = propose.placement_id,
                    .primary_node_id = propose.node_id,
                    .lease_id = propose.lease_id,
                    .holder_boot_id = holder_boot_id,
                    .authority_generation = propose.holder_generation,
                    .write_epoch = propose.write_epoch,
                    .placement_revision = propose.placement_revision,
                    .activation_nonce = propose.activation_nonce,
                    .authority_digest = @splat(0),
                };
                binding.authority_digest = authorityDigest(binding);
                const command = try state_machine.encodeProposePrimaryAuthorityCommand(self.parent_allocator, .{
                    .authority = .{
                        .volume_id = propose.volume_id_text,
                        .primary_placement_id = propose.placement_id_text,
                        .primary_node_id = propose.node_id_text,
                        .lease_id = &binding.lease_id,
                        .holder_boot_id = &binding.holder_boot_id,
                        .authority_generation = binding.authority_generation,
                        .write_epoch = binding.write_epoch,
                        .placement_revision = binding.placement_revision,
                        .activation_nonce = &binding.activation_nonce,
                        .lease_duration_ms = primary_lease.duration_ms,
                        .state = .PRIMARY_AUTHORITY_STATE_PENDING,
                        .authority_digest = &binding.authority_digest,
                    },
                    .expected_volume_resource_version = propose.expected_volume_resource_version,
                    .failover_id = &propose.failover_id,
                    .expected_failover_resource_version = propose.expected_failover_resource_version,
                });
                defer self.parent_allocator.free(command);
                try submitAndValidate(self.parent_allocator, submitter, command, .propose_authority);
            },
            .failover_ready => |ready| {
                const status = try data_client.inspectPrimary(ready.primary_endpoint, ready.request);
                try validatePrimaryLeaseStatus(status, ready.request);
                if (!status.candidate_fresh) {
                    try submitAndValidate(self.parent_allocator, submitter, ready.abort_command, .abort_authority);
                    return;
                }
                const evidence = try self.parent_allocator.alloc(pb.ReplicaFenceEvidence, ready.replicas.len);
                defer self.parent_allocator.free(evidence);
                for (ready.replicas, evidence, ready.placement_id_texts) |replica, *proof, placement_id| {
                    const result = try data_client.fenceReplica(replica.endpoint, replica.binding);
                    if (!std.meta.eql(result.binding, replica.binding) or isZero(&result.fence_digest)) return error.InvalidFenceProof;
                    proof.* = .{
                        .placement_id = placement_id,
                        .replica_generation = result.binding.replica_generation,
                        .write_epoch = result.binding.write_epoch,
                        .lease_id = &result.binding.lease_id,
                        .authority_digest = &result.binding.authority_digest,
                        .fence_digest = &result.fence_digest,
                    };
                }
                const recovery_request: RecoveryRequest = .{ .binding = ready.request.binding };
                const recovery = try data_client.recoverPrimary(ready.primary_endpoint, recovery_request);
                if (!std.meta.eql(recovery.request, recovery_request) or isZero(&recovery.history_digest) or
                    (recovery.certified_sequence == 0) != recovery.empty_frontier) return error.InvalidRecoveryProof;
                const binding = ready.request.binding;
                const command = try state_machine.encodeCommitPrimaryAuthorityFailoverReadyCommand(self.parent_allocator, .{
                    .volume_id = ready.volume_id_text,
                    .failover_id = &ready.failover_id,
                    .lease_id = &binding.lease_id,
                    .authority_digest = &binding.authority_digest,
                    .authority_generation = binding.authority_generation,
                    .write_epoch = binding.write_epoch,
                    .placement_revision = binding.placement_revision,
                    .expected_volume_resource_version = ready.expected_volume_resource_version,
                    .expected_candidate_resource_version = ready.expected_candidate_resource_version,
                    .expected_current_resource_version = ready.expected_current_resource_version,
                    .expected_failover_resource_version = ready.expected_failover_resource_version,
                    .fence_evidence = .{ .items = evidence, .capacity = evidence.len },
                    .recovery_evidence = .{
                        .volume_id = ready.volume_id_text,
                        .write_epoch = binding.write_epoch,
                        .certified_sequence = recovery.certified_sequence,
                        .history_digest = &recovery.history_digest,
                        .empty_frontier = recovery.empty_frontier,
                    },
                });
                defer self.parent_allocator.free(command);
                if (try submitReadyAndValidate(self.parent_allocator, submitter, command, binding))
                    try data_client.markPrimaryReady(ready.primary_endpoint, ready.request);
            },
            .complete_failover_wait => |command| try submitAndValidate(self.parent_allocator, submitter, command, .complete_failover_wait),
        }
    }
};

const ApplyKind = enum { reserve, activate, finalize, propose_authority, activate_authority, abort_authority, begin_failover, complete_failover_wait };

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
        .propose_authority => {
            var response = try state_machine.decodePrimaryAuthorityApplyResponse(allocator, response_bytes);
            defer response.deinit(allocator);
            switch (response.code) {
                .PRIMARY_AUTHORITY_APPLY_CODE_PROPOSED,
                .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT,
                .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE,
                => {},
                else => return error.PrimaryAuthorityProposalRejected,
            }
        },
        .activate_authority => {
            var response = try state_machine.decodePrimaryAuthorityApplyResponse(allocator, response_bytes);
            defer response.deinit(allocator);
            switch (response.code) {
                .PRIMARY_AUTHORITY_APPLY_CODE_ACTIVATED,
                .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT,
                .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE,
                => {},
                else => return error.PrimaryAuthorityActivationRejected,
            }
        },
        .abort_authority => {
            var response = try state_machine.decodePrimaryAuthorityApplyResponse(allocator, response_bytes);
            defer response.deinit(allocator);
            switch (response.code) {
                .PRIMARY_AUTHORITY_APPLY_CODE_ABORTED,
                .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND,
                .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT,
                .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE,
                => {},
                else => return error.PrimaryAuthorityAbortRejected,
            }
        },
        .begin_failover, .complete_failover_wait => {
            var response = try state_machine.decodePrimaryFailoverApplyResponse(allocator, response_bytes);
            defer response.deinit(allocator);
            switch (response.code) {
                .PRIMARY_FAILOVER_APPLY_CODE_BEGUN,
                .PRIMARY_FAILOVER_APPLY_CODE_LEASE_WAIT_COMPLETED,
                .PRIMARY_FAILOVER_APPLY_CODE_VERSION_CONFLICT,
                .PRIMARY_FAILOVER_APPLY_CODE_INVALID_STATE,
                => {},
                else => return if (kind == .begin_failover) error.PrimaryFailoverRejected else error.PrimaryFailoverWaitCompletionRejected,
            }
        },
    }
}

fn validatePrimaryLeaseStatus(status: PrimaryLeaseStatus, request: MarkReadyRequest) !void {
    if (!std.meta.eql(status.request, request) or
        (status.current_admitting and !status.current_active) or
        (status.should_renew and (!status.current_active or !status.current_admitting)) or
        (status.candidate_fresh and (status.current_active or status.current_admitting or status.should_renew)))
    {
        return error.InvalidPrimaryLeaseStatus;
    }
}

fn submitReadyAndValidate(allocator: std.mem.Allocator, submitter: CommandSubmitter, command: []const u8, binding: AuthorityBinding) !bool {
    const response_bytes = try submitter.submit(allocator, command);
    defer allocator.free(response_bytes);
    var response = try state_machine.decodePrimaryAuthorityApplyResponse(allocator, response_bytes);
    defer response.deinit(allocator);
    switch (response.code) {
        .PRIMARY_AUTHORITY_APPLY_CODE_READY => {
            const authority = response.authority orelse return error.InvalidReadyApplyResponse;
            if (authority.state != .PRIMARY_AUTHORITY_STATE_READY or
                !uuidMatches(authority.volume_id, binding.volume_id) or
                !uuidMatches(authority.primary_placement_id, binding.primary_placement_id) or
                !uuidMatches(authority.primary_node_id, binding.primary_node_id) or
                !std.mem.eql(u8, authority.lease_id, &binding.lease_id) or
                !std.mem.eql(u8, authority.holder_boot_id, &binding.holder_boot_id) or
                !std.mem.eql(u8, authority.activation_nonce, &binding.activation_nonce) or
                !std.mem.eql(u8, authority.authority_digest, &binding.authority_digest) or
                authority.authority_generation != binding.authority_generation or
                authority.write_epoch != binding.write_epoch or
                authority.placement_revision != binding.placement_revision or
                authority.lease_duration_ms != primary_lease.duration_ms) return error.InvalidReadyApplyResponse;
            return true;
        },
        .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT,
        .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE,
        => return false,
        else => return error.PrimaryAuthorityReadyRejected,
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

fn authorityBinding(authority: pb.PrimaryAuthority) !AuthorityBinding {
    if (authority.lease_id.len != 16 or authority.holder_boot_id.len != 16 or authority.activation_nonce.len != 16 or authority.authority_digest.len != 32)
        return error.InconsistentSnapshot;
    return .{
        .volume_id = try parseId(authority.volume_id),
        .primary_placement_id = try parseId(authority.primary_placement_id),
        .primary_node_id = try parseId(authority.primary_node_id),
        .lease_id = authority.lease_id[0..16].*,
        .holder_boot_id = authority.holder_boot_id[0..16].*,
        .authority_generation = authority.authority_generation,
        .write_epoch = authority.write_epoch,
        .placement_revision = authority.placement_revision,
        .activation_nonce = authority.activation_nonce[0..16].*,
        .authority_digest = authority.authority_digest[0..32].*,
    };
}

fn parseId(value: []const u8) !Id {
    const parsed = uuid.urn.deserialize(value) catch return error.InvalidId;
    const canonical = uuid.urn.serialize(parsed);
    if (canonical[14] != '7' or !std.mem.eql(u8, value, &canonical)) return error.InvalidId;
    var result: Id = undefined;
    std.mem.writeInt(u128, &result, parsed, .little);
    return result;
}

fn randomId(io: std.Io) Id {
    const text = uuid.urn.serialize(uuid.v7.new(io));
    return parseId(&text) catch unreachable;
}

fn validUuidV7Bytes(value: Id) bool {
    return value[6] & 0xf0 == 0x70 and value[8] & 0xc0 == 0x80;
}

fn authorityDigest(binding: AuthorityBinding) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide.primary-authority.v1");
    hashField(&hasher, &binding.volume_id);
    hashField(&hasher, &binding.primary_placement_id);
    hashField(&hasher, &binding.primary_node_id);
    hashField(&hasher, &binding.lease_id);
    hashField(&hasher, &binding.holder_boot_id);
    hashU64(&hasher, binding.authority_generation);
    hashU64(&hasher, binding.write_epoch);
    hashU64(&hasher, binding.placement_revision);
    hashField(&hasher, &binding.activation_nonce);
    hashU64(&hasher, primary_lease.duration_ms);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn stableFenceOperationId(binding: AuthorityBinding, placement_id: Id, replica_generation: u64) Id {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide.replica-fence-operation.v1");
    hashField(&hasher, &binding.volume_id);
    hashField(&hasher, &placement_id);
    hashField(&hasher, &binding.lease_id);
    hashField(&hasher, &binding.holder_boot_id);
    hashField(&hasher, &binding.authority_digest);
    hashU64(&hasher, binding.authority_generation);
    hashU64(&hasher, binding.write_epoch);
    hashU64(&hasher, binding.placement_revision);
    hashU64(&hasher, replica_generation);
    var digest: Digest = undefined;
    hasher.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x70;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return digest[0..16].*;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hasher.update(&length);
    hasher.update(value);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    hashField(hasher, &bytes);
}

fn dupePlacementIds(allocator: std.mem.Allocator, placements: []const pb.ReplicaPlacement) ![]const []const u8 {
    const ids = try allocator.alloc([]const u8, placements.len);
    for (placements, ids) |placement, *id| id.* = try allocator.dupe(u8, placement.id);
    return ids;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
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
const test_cluster_id: [16]u8 = @splat(1);
const test_local_set_id: [16]u8 = @splat(2);
const test_digest: [32]u8 = @splat(3);
const test_holder_boot_id: Id = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 2, 1 };
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
    lose_next_response: bool = false,

    fn interface(self: *TestSubmitter) CommandSubmitter {
        return .{ .context = self, .vtable = &vtable };
    }

    fn submitOpaque(context: *anyopaque, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        const self: *TestSubmitter = @ptrCast(@alignCast(context));
        const index = self.next_index;
        self.next_index += 1;
        self.submissions += 1;
        const result = try self.machine.stateMachine().apply(.{ .index = index, .term = 1, .data = command });
        if (self.lose_next_response) {
            self.lose_next_response = false;
            if (result.response) |response| allocator.free(response);
            return error.TransportUnknown;
        }
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
    machine: *state_machine.PoolStateMachine,
    holder: *primary_lease.Runtime,
    lose_ensure_response: bool = false,
    stale_attestation: bool = false,
    lose_stage_response: bool = false,
    lose_fence_response: bool = false,
    invalid_fence_proof: bool = false,
    invalid_recovery_proof: bool = false,
    staged: ?StageRequest = null,
    fences: [state_machine.volume_target_replica_count * 3]?replica_fence.Result = @splat(null),
    stage_grants: usize = 0,
    fence_drains: usize = 0,
    recoveries: usize = 0,
    mark_ready_calls: usize = 0,
    stage_now_ms: u64 = 1_000,
    now_ms: u64 = 2_000,
    mismatch_inspect_binding: bool = false,
    holder_identity: Id = test_holder_boot_id,

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

    fn identifyHolderOpaque(context: *anyopaque, endpoint: []const u8) !Id {
        const self: *TestDataClient = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, endpoint, "data:9000")) return error.InvalidEndpoint;
        return self.holder_identity;
    }

    fn stagePrimaryOpaque(context: *anyopaque, endpoint: []const u8, request: StageRequest) !StageAck {
        const self: *TestDataClient = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, endpoint, "data:9000")) return error.InvalidEndpoint;
        if (!std.mem.eql(u8, &request.binding.authority_digest, &authorityDigest(request.binding))) return error.InvalidAuthorityDigest;
        if (self.staged) |staged| {
            if (std.meta.eql(staged, request)) return .{ .request = request };
            if (request.binding.authority_generation < staged.binding.authority_generation) return error.StageConflict;
            _ = try self.holder.stage(.{
                .lease_id = request.binding.lease_id,
                .holder_boot_id = request.binding.holder_boot_id,
                .authority_generation = request.binding.authority_generation,
                .write_epoch = request.binding.write_epoch,
            }, self.stage_now_ms);
            self.staged = request;
            self.stage_grants += 1;
        } else {
            _ = try self.holder.stage(.{
                .lease_id = request.binding.lease_id,
                .holder_boot_id = request.binding.holder_boot_id,
                .authority_generation = request.binding.authority_generation,
                .write_epoch = request.binding.write_epoch,
            }, self.stage_now_ms);
            self.staged = request;
            self.stage_grants += 1;
        }
        if (self.lose_stage_response) {
            self.lose_stage_response = false;
            return error.TransportUnknown;
        }
        return .{ .request = request };
    }

    fn fenceReplicaOpaque(context: *anyopaque, endpoint: []const u8, binding: replica_fence.Binding) !replica_fence.Result {
        const self: *TestDataClient = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, endpoint, "data:9000")) return error.InvalidEndpoint;
        var slot: ?usize = null;
        for (&self.fences, 0..) |*existing, index| {
            if (existing.*) |result| {
                if (std.mem.eql(u8, &result.binding.operation_id, &binding.operation_id)) {
                    if (!std.meta.eql(result.binding, binding)) return error.FenceConflict;
                    slot = index;
                    break;
                }
            } else if (slot == null) slot = index;
        }
        const index = slot orelse return error.TooManyFences;
        if (self.fences[index] == null) {
            var digest = binding.authority_digest;
            digest[0] ^= @truncate(index + 1);
            self.fences[index] = .{ .binding = binding, .fence_digest = digest };
            self.fence_drains += 1;
        }
        if (self.lose_fence_response) {
            self.lose_fence_response = false;
            return error.TransportUnknown;
        }
        var result = self.fences[index].?;
        if (self.invalid_fence_proof) result.binding.write_epoch += 1;
        return result;
    }

    fn recoverPrimaryOpaque(context: *anyopaque, endpoint: []const u8, request: RecoveryRequest) !RecoveryResult {
        const self: *TestDataClient = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, endpoint, "data:9000")) return error.InvalidEndpoint;
        self.recoveries += 1;
        var result: RecoveryResult = .{
            .request = request,
            .certified_sequence = 0,
            .history_digest = request.binding.authority_digest,
            .empty_frontier = true,
        };
        if (self.invalid_recovery_proof) result.request.binding.write_epoch += 1;
        return result;
    }

    fn markPrimaryReadyOpaque(context: *anyopaque, endpoint: []const u8, request: MarkReadyRequest) !void {
        const self: *TestDataClient = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, endpoint, "data:9000")) return error.InvalidEndpoint;
        var authority = (try self.machine.getPrimaryAuthority(std.testing.allocator, test_volume_id)) orelse return error.AuthorityNotCommitted;
        defer authority.deinit(std.testing.allocator);
        if (authority.state != .PRIMARY_AUTHORITY_STATE_READY or !std.mem.eql(u8, authority.lease_id, &request.binding.lease_id)) return error.AuthorityNotReady;
        self.mark_ready_calls += 1;
        const token: primary_lease.Token = .{
            .lease_id = request.binding.lease_id,
            .holder_boot_id = request.binding.holder_boot_id,
            .authority_generation = request.binding.authority_generation,
            .write_epoch = request.binding.write_epoch,
        };
        if (self.holder.canAdmit(token, self.now_ms)) return;
        try self.holder.markReady(request.binding.lease_id, self.now_ms);
    }

    fn inspectPrimaryOpaque(context: *anyopaque, endpoint: []const u8, request: MarkReadyRequest) !PrimaryLeaseStatus {
        const self: *TestDataClient = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, endpoint, "data:9000")) return error.InvalidEndpoint;
        const token: primary_lease.Token = .{
            .lease_id = request.binding.lease_id,
            .holder_boot_id = request.binding.holder_boot_id,
            .authority_generation = request.binding.authority_generation,
            .write_epoch = request.binding.write_epoch,
        };
        var echoed = request;
        if (self.mismatch_inspect_binding) echoed.binding.holder_boot_id[0] ^= 1;
        return .{
            .request = echoed,
            .current_active = self.holder.canComplete(token, self.now_ms),
            .current_admitting = self.holder.canAdmit(token, self.now_ms),
            .candidate_fresh = self.holder.canMarkReadyToken(token, self.now_ms),
            .should_renew = self.holder.shouldRenew(token, self.now_ms),
        };
    }

    fn cancelOpaque(_: *anyopaque) void {}

    const vtable: DataServiceClient.VTable = .{
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
        .identify_holder = identifyHolderOpaque,
        .stage_primary = stagePrimaryOpaque,
        .fence_replica = fenceReplicaOpaque,
        .recover_primary = recoverPrimaryOpaque,
        .mark_primary_ready = markPrimaryReadyOpaque,
        .inspect_primary = inspectPrimaryOpaque,
        .cancel = cancelOpaque,
    };
};

test "reconciler refuses to plan attached volume deletion" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    var submitter = TestSubmitter{ .machine = &machine };
    var store = data_service.MemoryStore.init(allocator);
    defer store.deinit();
    var backend: TestBackend = .{};
    var service = data_service.Service.init(store.store(), backend.interface());
    var holder = try primary_lease.Runtime.init(test_holder_boot_id);
    var data_client = TestDataClient{ .service = &service, .machine = &machine, .holder = &holder };
    var reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());
    defer reconciler.deinit();
    var volume: state_machine.PoolStateMachine.ReconcileVolume = undefined;
    volume.has_attachments = true;
    try std.testing.expectError(error.VolumeHasAttachments, reconciler.planDelete(volume));
}

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
    var holder = try primary_lease.Runtime.init(test_holder_boot_id);
    var data_client = TestDataClient{ .service = &service, .machine = &machine, .holder = &holder, .lose_ensure_response = true };
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
    var fenced = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer fenced.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_PROVISIONING, fenced.lifecycle_state);
    try std.testing.expectEqual(pb.VolumeOperationPhase.VOLUME_OPERATION_PHASE_FENCING, fenced.operation_phase);

    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 5), submitter.submissions);
    data_client.lose_stage_response = true;
    try std.testing.expectError(error.TransportUnknown, rebuilt.runOnce());
    try std.testing.expectEqual(@as(usize, 1), data_client.stage_grants);
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 1), data_client.stage_grants);
    try std.testing.expectEqual(@as(usize, 6), submitter.submissions);
    data_client.lose_fence_response = true;
    try std.testing.expectError(error.TransportUnknown, rebuilt.runOnce());
    try std.testing.expectEqual(@as(usize, 1), data_client.fence_drains);
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 3), data_client.fence_drains);
    try std.testing.expectEqual(@as(usize, 7), submitter.submissions);
    try std.testing.expectEqual(@as(usize, 1), data_client.mark_ready_calls);
    var active = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer active.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_ACTIVE, active.lifecycle_state);
    try std.testing.expectEqual(pb.VolumeAvailabilityState.VOLUME_AVAILABILITY_STATE_HEALTHY, active.availability_state);
    try std.testing.expectEqual(pb.VolumeOperationPhase.VOLUME_OPERATION_PHASE_NONE, active.operation_phase);
    var authority = (try machine.getPrimaryAuthority(allocator, test_volume_id)).?;
    defer authority.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityState.PRIMARY_AUTHORITY_STATE_READY, authority.state);
    try std.testing.expect(validUuidV7Bytes(authority.lease_id[0..16].*));
    try std.testing.expect(validUuidV7Bytes(authority.holder_boot_id[0..16].*));
    try std.testing.expect(validUuidV7Bytes(authority.activation_nonce[0..16].*));
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 1), data_client.mark_ready_calls);
    try std.testing.expectEqual(@as(usize, 7), submitter.submissions);

    data_client.mismatch_inspect_binding = true;
    try std.testing.expectError(error.InvalidPrimaryLeaseStatus, rebuilt.runOnce());
    try std.testing.expectEqual(@as(usize, 7), submitter.submissions);
    data_client.mismatch_inspect_binding = false;

    const old_lease = authority.lease_id[0..16].*;
    data_client.stage_now_ms = 11_000;
    data_client.now_ms = 11_000;
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCandidateCount());
    try std.testing.expectEqual(@as(usize, 3), data_client.fence_drains);
    try std.testing.expectEqual(@as(usize, 1), data_client.recoveries);
    submitter.lose_next_response = true;
    try std.testing.expectError(error.TransportUnknown, rebuilt.runOnce());
    var staged_candidate = (try machine.getPrimaryAuthorityCandidate(allocator, test_volume_id)).?;
    defer staged_candidate.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityState.PRIMARY_AUTHORITY_STATE_ACTIVATED, staged_candidate.state);

    data_client.stage_now_ms = 31_001;
    data_client.now_ms = 31_001;
    submitter.lose_next_response = true;
    try std.testing.expectError(error.TransportUnknown, rebuilt.runOnce());
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    var retained = (try machine.getPrimaryAuthority(allocator, test_volume_id)).?;
    defer retained.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), retained.authority_generation);

    try rebuilt.runOnce();
    var replacement = (try machine.getPrimaryAuthorityCandidate(allocator, test_volume_id)).?;
    defer replacement.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), replacement.authority_generation);
    try std.testing.expect(!std.mem.eql(u8, staged_candidate.lease_id, replacement.lease_id));
    try rebuilt.runOnce();
    submitter.lose_next_response = true;
    try std.testing.expectError(error.TransportUnknown, rebuilt.runOnce());
    data_client.stage_now_ms = 51_002;
    data_client.now_ms = 51_002;
    try rebuilt.runOnce();
    var recovery_candidate = (try machine.getPrimaryAuthorityCandidate(allocator, test_volume_id)).?;
    defer recovery_candidate.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), recovery_candidate.authority_generation);
    try rebuilt.runOnce();
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    var renewed = (try machine.getPrimaryAuthority(allocator, test_volume_id)).?;
    defer renewed.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), renewed.authority_generation);
    try std.testing.expect(!std.mem.eql(u8, &old_lease, renewed.lease_id));
    try std.testing.expectEqual(@as(usize, 3), data_client.fence_drains);
    try std.testing.expectEqual(@as(usize, 1), data_client.recoveries);
    var renewed_volume = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer renewed_volume.deinit(allocator);

    const delete_command = try state_machine.encodeDeleteVolumeCommand(allocator, .{
        .request_id = "reconciler-delete",
        .volume_id = test_volume_id,
        .expected_resource_version = renewed_volume.resource_version,
        .proposed_deleted_at_unix_ms = 1_753_744_000_020,
    });
    defer allocator.free(delete_command);
    const delete_response = try submitter.interface().submit(allocator, delete_command);
    allocator.free(delete_response);
    rebuilt.awake_now_ms_override = 1_000;
    try rebuilt.runOnce();
    try std.testing.expectEqual(@as(usize, 0), backend.deletes);
    rebuilt.deinit();
    var deletion_reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());
    defer deletion_reconciler.deinit();
    deletion_reconciler.awake_now_ms_override = 2_000;
    try deletion_reconciler.runOnce();
    try std.testing.expectEqual(@as(usize, 0), backend.deletes);
    deletion_reconciler.awake_now_ms_override = 2_000 + primary_lease.duration_ms;
    try deletion_reconciler.runOnce();
    try std.testing.expectEqual(@as(usize, 3), backend.deletes);
    try std.testing.expectEqual(@as(usize, 2), data_client.mark_ready_calls);
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
    var holder = try primary_lease.Runtime.init(test_holder_boot_id);
    var data_client = TestDataClient{ .service = &service, .machine = &machine, .holder = &holder, .stale_attestation = true };
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

test "reconciler aborts stale initial candidate before fencing and retries generation one" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    try setupMachine(&machine, .{ "rack-a", "rack-b", "rack-c" });
    var submitter = TestSubmitter{ .machine = &machine };
    var store = data_service.MemoryStore.init(allocator);
    defer store.deinit();
    var backend: TestBackend = .{};
    var service = data_service.Service.init(store.store(), backend.interface());
    var holder = try primary_lease.Runtime.init(test_holder_boot_id);
    var data_client = TestDataClient{ .service = &service, .machine = &machine, .holder = &holder };
    var reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());

    for (0..6) |_| try reconciler.runOnce();
    data_client.now_ms = 21_001;
    try reconciler.runOnce();
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    try std.testing.expectEqual(@as(usize, 0), data_client.fence_drains);
    try std.testing.expectEqual(@as(usize, 0), data_client.recoveries);
    var fencing = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer fencing.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_PROVISIONING, fencing.lifecycle_state);
    try std.testing.expectEqual(pb.VolumeOperationPhase.VOLUME_OPERATION_PHASE_FENCING, fencing.operation_phase);

    data_client.stage_now_ms = 21_001;
    try reconciler.runOnce();
    var replacement = (try machine.getPrimaryAuthorityCandidate(allocator, test_volume_id)).?;
    defer replacement.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), replacement.authority_generation);
    try reconciler.runOnce();
    try reconciler.runOnce();
    try std.testing.expectEqual(@as(usize, 3), data_client.fence_drains);
    try std.testing.expectEqual(@as(usize, 1), data_client.recoveries);
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    var active = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer active.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_ACTIVE, active.lifecycle_state);
}

test "boot mismatch waits a full observation window and completes higher epoch failover" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    try setupMachine(&machine, .{ "rack-a", "rack-b", "rack-c" });
    var submitter = TestSubmitter{ .machine = &machine };
    var store = data_service.MemoryStore.init(allocator);
    defer store.deinit();
    var backend: TestBackend = .{};
    var service = data_service.Service.init(store.store(), backend.interface());
    var holder = try primary_lease.Runtime.init(test_holder_boot_id);
    var data_client = TestDataClient{ .service = &service, .machine = &machine, .holder = &holder };
    var reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());

    for (0..7) |_| try reconciler.runOnce();
    data_client.now_ms = 26_000;
    data_client.holder_identity = try parseId(test_node_ids[1]);
    submitter.lose_next_response = true;
    try std.testing.expectError(error.TransportUnknown, reconciler.runOnce());
    try std.testing.expectEqual(@as(usize, 1), machine.primaryFailoverCount());
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    var current = (try machine.getPrimaryAuthority(allocator, test_volume_id)).?;
    defer current.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), current.authority_generation);
    var volume = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer volume.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeAvailabilityState.VOLUME_AVAILABILITY_STATE_UNAVAILABLE, volume.availability_state);
    try std.testing.expectEqual(pb.VolumeOperationPhase.VOLUME_OPERATION_PHASE_FENCING, volume.operation_phase);

    const submissions_after_begin = submitter.submissions;
    reconciler.awake_now_ms_override = 1_000;
    try reconciler.runOnce();
    try std.testing.expectEqual(submissions_after_begin, submitter.submissions);
    try std.testing.expectEqual(@as(usize, 1), reconciler.failover_observations.count());
    reconciler.deinit();

    var restarted = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());
    defer restarted.deinit();
    restarted.awake_now_ms_override = 2_000;
    try restarted.runOnce();
    try std.testing.expectEqual(submissions_after_begin, submitter.submissions);
    var failover = (try machine.getPrimaryFailover(allocator, test_volume_id)).?;
    defer failover.deinit(allocator);
    const failover_id = failover.failover_id[0..16].*;
    try std.testing.expectEqual(@as(u64, 2_000), restarted.failover_observations.getPtr(failover_id).?.first_seen_ms);
    restarted.awake_now_ms_override = 2_000 + primary_lease.duration_ms;

    const old_token: primary_lease.Token = .{
        .lease_id = current.lease_id[0..16].*,
        .holder_boot_id = current.holder_boot_id[0..16].*,
        .authority_generation = current.authority_generation,
        .write_epoch = current.write_epoch,
    };
    const old_holder = holder;
    holder = try primary_lease.Runtime.init(data_client.holder_identity);
    data_client.stage_now_ms = 32_000;
    data_client.now_ms = 32_000;
    submitter.lose_next_response = true;
    try std.testing.expectError(error.TransportUnknown, restarted.runOnce());
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    var completed_failover = (try machine.getPrimaryFailover(allocator, test_volume_id)).?;
    defer completed_failover.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryFailoverState.PRIMARY_FAILOVER_STATE_LEASE_EXPIRED, completed_failover.state);
    submitter.lose_next_response = true;
    try std.testing.expectError(error.TransportUnknown, restarted.runOnce());
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCandidateCount());
    var failover_volume = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer failover_volume.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), failover_volume.write_epoch);

    data_client.holder_identity = try parseId(test_node_ids[2]);
    try restarted.runOnce();
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    try std.testing.expectEqual(@as(usize, 1), machine.primaryFailoverCount());
    var after_target_abort = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer after_target_abort.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), after_target_abort.write_epoch);
    data_client.holder_identity = try parseId(test_node_ids[1]);
    try restarted.runOnce();
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCandidateCount());
    try restarted.runOnce();
    data_client.lose_fence_response = true;
    try std.testing.expectError(error.TransportUnknown, restarted.runOnce());
    try std.testing.expectEqual(@as(usize, 4), data_client.fence_drains);
    data_client.now_ms = 52_001;
    submitter.lose_next_response = true;
    try std.testing.expectError(error.TransportUnknown, restarted.runOnce());
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    var after_partial_abort = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer after_partial_abort.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 4), after_partial_abort.write_epoch);
    data_client.stage_now_ms = 52_001;
    try restarted.runOnce();
    try restarted.runOnce();
    submitter.lose_next_response = true;
    try std.testing.expectError(error.TransportUnknown, restarted.runOnce());
    try restarted.runOnce();
    var failed_over = (try machine.getPrimaryAuthority(allocator, test_volume_id)).?;
    defer failed_over.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), failed_over.authority_generation);
    try std.testing.expectEqual(@as(u64, 4), failed_over.write_epoch);
    try std.testing.expectEqualSlices(u8, test_node_ids[1], failed_over.primary_node_id);
    try std.testing.expectEqual(@as(usize, 0), machine.primaryFailoverCount());
    try std.testing.expectEqual(@as(usize, 7), data_client.fence_drains);
    try std.testing.expectEqual(@as(usize, 2), data_client.recoveries);
    try std.testing.expectEqual(@as(usize, 2), data_client.mark_ready_calls);
    try std.testing.expect(!old_holder.canAdmit(old_token, 31_000));
}

test "reconciler rejects invalid authority proofs without READY submission" {
    const allocator = std.testing.allocator;
    var machine = state_machine.PoolStateMachine.init(allocator);
    defer machine.deinit();
    try setupMachine(&machine, .{ "rack-a", "rack-b", "rack-c" });
    var submitter = TestSubmitter{ .machine = &machine };
    var store = data_service.MemoryStore.init(allocator);
    defer store.deinit();
    var backend: TestBackend = .{};
    var service = data_service.Service.init(store.store(), backend.interface());
    var holder = try primary_lease.Runtime.init(test_holder_boot_id);
    var data_client = TestDataClient{ .service = &service, .machine = &machine, .holder = &holder };
    var reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());

    for (0..6) |_| try reconciler.runOnce();
    try std.testing.expectEqual(@as(usize, 6), submitter.submissions);
    data_client.invalid_fence_proof = true;
    try std.testing.expectError(error.InvalidFenceProof, reconciler.runOnce());
    try std.testing.expectEqual(@as(usize, 6), submitter.submissions);
    data_client.invalid_fence_proof = false;
    data_client.invalid_recovery_proof = true;
    try std.testing.expectError(error.InvalidRecoveryProof, reconciler.runOnce());
    try std.testing.expectEqual(@as(usize, 6), submitter.submissions);
    try std.testing.expectEqual(@as(usize, 0), data_client.mark_ready_calls);
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
    var holder = try primary_lease.Runtime.init(test_holder_boot_id);
    var data_client = TestDataClient{ .service = &service, .machine = &machine, .holder = &holder };
    var reconciler = Reconciler.init(allocator, std.testing.io, &machine, data_client.interface(), submitter.interface());
    try std.testing.expectError(error.InsufficientPlacement, reconciler.runOnce());
    try std.testing.expectEqual(@as(usize, 0), submitter.submissions);
}

test "stable authority maintenance rotates across volumes" {
    const stable: state_machine.PoolStateMachine.ReconcileVolume = .{
        .volume = .{
            .lifecycle_state = .VOLUME_LIFECYCLE_STATE_ACTIVE,
            .operation_phase = .VOLUME_OPERATION_PHASE_NONE,
        },
        .primary_authority = .{ .state = .PRIMARY_AUTHORITY_STATE_READY },
        .primary_authority_candidate = null,
        .primary_failover = null,
        .has_attachments = false,
        .placements = &.{},
        .allocations = &.{},
        .nodes = &.{},
        .members = &.{},
    };
    const volumes = [_]state_machine.PoolStateMachine.ReconcileVolume{ stable, stable };
    try std.testing.expectEqual(@as(?usize, 0), nextMaintenanceIndex(&volumes, 0));
    try std.testing.expectEqual(@as(?usize, 1), nextMaintenanceIndex(&volumes, 1));
    try std.testing.expectEqual(@as(?usize, 0), nextMaintenanceIndex(&volumes, 2));
}
