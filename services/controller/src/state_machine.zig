const std = @import("std");

const pb = @import("controller_proto");
const heartbeat = @import("heartbeat.zig");
const primary_lease = @import("primary_lease.zig");
const raft = @import("raftz");
const codec = @import("state_machine/codec.zig");
const model = @import("state_machine/model.zig");
const preflight = @import("state_machine/preflight.zig");
const schema = @import("state_machine/schema.zig");

const Fingerprint = schema.Fingerprint;
const Pool = model.Pool;
const Node = model.Node;
const Member = model.Member;
const MemberSlotKey = model.MemberSlotKey;
const Volume = model.Volume;
const VolumeTombstone = model.VolumeTombstone;
const ReplicaPlacement = model.ReplicaPlacement;
const ReplicaAllocation = model.ReplicaAllocation;
const VolumeAttachment = model.VolumeAttachment;
const PrimaryAuthority = model.PrimaryAuthority;
const PrimaryFailover = model.PrimaryFailover;
const RequestKind = schema.RequestKind;
const Request = model.Request;
const State = model.State;
const scopedKey = model.scopedKey;
const makeScopedKey = model.makeScopedKey;
const replicaKey = model.replicaKey;
const makeReplicaKey = model.makeReplicaKey;

pub const command_format_version = schema.command_format_version;
pub const snapshot_format_version = schema.snapshot_format_version;
pub const max_name_bytes = schema.max_name_bytes;
pub const max_description_bytes = schema.max_description_bytes;
pub const max_request_id_bytes = schema.max_request_id_bytes;
pub const max_node_endpoint_bytes = schema.max_node_endpoint_bytes;
pub const max_failure_domain_bytes = schema.max_failure_domain_bytes;
pub const max_pools = schema.max_pools;
pub const max_nodes = schema.max_nodes;
pub const max_members = schema.max_members;
pub const min_volume_size_bytes = schema.min_volume_size_bytes;
pub const volume_block_size_bytes = schema.volume_block_size_bytes;
pub const max_volume_size_bytes = schema.max_volume_size_bytes;
pub const volume_target_replica_count = schema.volume_target_replica_count;
pub const volume_write_quorum = schema.volume_write_quorum;
pub const volume_read_quorum = schema.volume_read_quorum;
pub const max_volumes = schema.max_volumes;
pub const max_volume_tombstones = schema.max_volume_tombstones;
pub const max_replica_placements = schema.max_replica_placements;
pub const max_replica_allocations = schema.max_replica_allocations;
pub const max_volume_attachments = schema.max_volume_attachments;
pub const max_primary_authorities = schema.max_primary_authorities;
pub const max_consumer_id_bytes = schema.max_consumer_id_bytes;
pub const max_requests = schema.max_requests;
pub const max_snapshot_bytes = schema.max_snapshot_bytes;

const max_pool_wire_bytes = schema.max_pool_wire_bytes;
const max_node_wire_bytes = schema.max_node_wire_bytes;
const max_member_wire_bytes = schema.max_member_wire_bytes;
const max_volume_wire_bytes = schema.max_volume_wire_bytes;
const max_volume_tombstone_wire_bytes = schema.max_volume_tombstone_wire_bytes;
const max_replica_placement_wire_bytes = schema.max_replica_placement_wire_bytes;
const max_replica_allocation_wire_bytes = schema.max_replica_allocation_wire_bytes;
const max_volume_attachment_wire_bytes = schema.max_volume_attachment_wire_bytes;
const max_primary_authority_wire_bytes = schema.max_primary_authority_wire_bytes;
const max_command_wire_bytes = schema.max_command_wire_bytes;
const max_response_wire_bytes = schema.max_response_wire_bytes;
const max_request_wire_bytes = schema.max_request_wire_bytes;

const validVolumeSize = schema.validVolumeSize;
const validClusterId = schema.validClusterId;
const validFixedNonzero = schema.validFixedNonzero;
const validText = schema.validText;
const validUuidV7 = schema.validUuidV7;
const validUuidV7Bytes = schema.validUuidV7Bytes;

pub const PoolStateMachine = struct {
    allocator: std.mem.Allocator,
    state: State = .{},
    heartbeat_store: ?*heartbeat.HeartbeatStore = null,

    pub const HeartbeatBindingResult = enum {
        node_not_found,
        member_not_found,
        binding_mismatch,
        capacity_mismatch,
        ok,
    };

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

    pub fn setHeartbeatStore(self: *PoolStateMachine, store: ?*heartbeat.HeartbeatStore) void {
        self.heartbeat_store = store;
    }

    pub fn hasHeartbeatStore(self: *const PoolStateMachine, store: *const heartbeat.HeartbeatStore) bool {
        return if (self.heartbeat_store) |configured| configured == store else false;
    }

    pub fn poolCount(self: *const PoolStateMachine) usize {
        return self.state.pools_by_id.count();
    }

    pub fn requestCount(self: *const PoolStateMachine) usize {
        return self.state.requests.count();
    }

    pub fn nodeCount(self: *const PoolStateMachine) usize {
        return self.state.nodes_by_id.count();
    }

    pub fn memberCount(self: *const PoolStateMachine) usize {
        return self.state.members_by_id.count();
    }

    pub fn volumeCount(self: *const PoolStateMachine) usize {
        return self.state.volumes_by_id.count();
    }

    pub fn volumeTombstoneCount(self: *const PoolStateMachine) usize {
        return self.state.volume_tombstones_by_id.count();
    }

    pub fn replicaPlacementCount(self: *const PoolStateMachine) usize {
        return self.state.replica_placements_by_id.count();
    }

    pub fn replicaAllocationCount(self: *const PoolStateMachine) usize {
        return self.state.replica_allocations_by_id.count();
    }

    pub fn primaryAuthorityCount(self: *const PoolStateMachine) usize {
        return self.state.primary_authorities_by_volume.count();
    }

    pub fn primaryAuthorityCandidateCount(self: *const PoolStateMachine) usize {
        return self.state.primary_authority_candidates_by_volume.count();
    }

    pub fn primaryFailoverCount(self: *const PoolStateMachine) usize {
        return self.state.primary_failovers_by_volume.count();
    }

    pub fn getPrimaryAuthority(self: *const PoolStateMachine, allocator: std.mem.Allocator, volume_id: []const u8) !?pb.PrimaryAuthority {
        const authority = self.state.primary_authorities_by_volume.get(volume_id) orelse return null;
        return try dupePrimaryAuthority(allocator, authority.proto());
    }

    pub fn getPrimaryAuthorityCandidate(self: *const PoolStateMachine, allocator: std.mem.Allocator, volume_id: []const u8) !?pb.PrimaryAuthority {
        const authority = self.state.primary_authority_candidates_by_volume.get(volume_id) orelse return null;
        return try dupePrimaryAuthority(allocator, authority.proto());
    }

    pub fn getPrimaryFailover(self: *const PoolStateMachine, allocator: std.mem.Allocator, volume_id: []const u8) !?pb.PrimaryFailover {
        const failover = self.state.primary_failovers_by_volume.get(volume_id) orelse return null;
        return try dupePrimaryFailover(allocator, failover.proto());
    }

    pub fn validateHeartbeatBinding(self: *const PoolStateMachine, request: pb.ReportHeartbeatRequest) HeartbeatBindingResult {
        if (request.node_id.len == 0 or request.cluster_id.len != 16 or request.incarnation == 0 or request.sequence == 0) {
            return .binding_mismatch;
        }
        const node = self.state.nodes_by_id.get(request.node_id) orelse return .node_not_found;
        if (!std.mem.eql(u8, node.cluster_id, request.cluster_id)) return .binding_mismatch;
        for (request.members.items) |reported| {
            if (reported.member_id.len != 16 or reported.local_set_id.len != 16 or reported.member_slot > std.math.maxInt(u16)) {
                return .binding_mismatch;
            }
            const registered = self.state.members_by_id.get(reported.member_id) orelse return .member_not_found;
            if (!std.mem.eql(u8, registered.node_id, request.node_id) or
                !std.mem.eql(u8, registered.local_set_id, reported.local_set_id) or
                registered.member_slot != reported.member_slot)
            {
                return .binding_mismatch;
            }
            if (reported.capacity) |capacity| {
                if (registered.extent_size_bytes == 0 or registered.data_capacity_bytes % registered.extent_size_bytes != 0) {
                    return .capacity_mismatch;
                }
                var total = std.math.add(u64, capacity.free_extent_count, capacity.allocated_extent_count) catch return .capacity_mismatch;
                total = std.math.add(u64, total, capacity.reserved_extent_count) catch return .capacity_mismatch;
                total = std.math.add(u64, total, capacity.retired_extent_count) catch return .capacity_mismatch;
                if (total != registered.data_capacity_bytes / registered.extent_size_bytes) return .capacity_mismatch;
            }
        }
        return .ok;
    }

    pub fn getPoolById(self: *const PoolStateMachine, allocator: std.mem.Allocator, id: []const u8) !?pb.Pool {
        const pool = self.state.pools_by_id.get(id) orelse return null;
        return try dupePool(allocator, pool.proto());
    }

    pub fn getVolumeById(self: *const PoolStateMachine, allocator: std.mem.Allocator, id: []const u8) !?pb.Volume {
        const volume = self.state.volumes_by_id.get(id) orelse return null;
        return try dupeVolume(allocator, volume.proto());
    }

    pub const VolumePage = struct {
        volumes: []pb.Volume,
        has_more: bool,

        pub fn deinit(self: *VolumePage, allocator: std.mem.Allocator) void {
            deinitVolumeList(allocator, self.volumes);
            self.* = undefined;
        }
    };

    pub fn listVolumesPage(self: *const PoolStateMachine, allocator: std.mem.Allocator, pool_id: ?[]const u8, after_id: ?[]const u8, limit: usize) !VolumePage {
        var start: usize = 0;
        if (after_id) |target| {
            while (start < self.state.volume_ids_by_revision.items.len and !std.mem.eql(u8, self.state.volume_ids_by_revision.items[start], target)) : (start += 1) {}
            if (start == self.state.volume_ids_by_revision.items.len) return error.InvalidPageToken;
            start += 1;
        }
        var volumes: std.ArrayList(pb.Volume) = .empty;
        errdefer {
            for (volumes.items) |*volume| volume.deinit(allocator);
            volumes.deinit(allocator);
        }
        var cursor = start;
        while (cursor < self.state.volume_ids_by_revision.items.len and volumes.items.len < limit) : (cursor += 1) {
            const volume = self.state.volumes_by_id.get(self.state.volume_ids_by_revision.items[cursor]).?;
            if (pool_id) |filter| if (!std.mem.eql(u8, filter, volume.pool_id)) continue;
            try volumes.append(allocator, try dupeVolume(allocator, volume.proto()));
        }
        var has_more = false;
        while (cursor < self.state.volume_ids_by_revision.items.len) : (cursor += 1) {
            const volume = self.state.volumes_by_id.get(self.state.volume_ids_by_revision.items[cursor]).?;
            if (pool_id == null or std.mem.eql(u8, pool_id.?, volume.pool_id)) {
                has_more = true;
                break;
            }
        }
        return .{ .volumes = try volumes.toOwnedSlice(allocator), .has_more = has_more };
    }

    pub const ReconcileVolume = struct {
        volume: pb.Volume,
        primary_authority: ?pb.PrimaryAuthority,
        primary_authority_candidate: ?pb.PrimaryAuthority,
        primary_failover: ?pb.PrimaryFailover,
        has_attachments: bool,
        placements: []pb.ReplicaPlacement,
        allocations: []pb.ReplicaAllocation,
        nodes: []pb.Node,
        members: []pb.Member,

        pub fn deinit(self: *ReconcileVolume, allocator: std.mem.Allocator) void {
            self.volume.deinit(allocator);
            if (self.primary_authority) |*authority| authority.deinit(allocator);
            if (self.primary_authority_candidate) |*authority| authority.deinit(allocator);
            if (self.primary_failover) |*failover| failover.deinit(allocator);
            for (self.placements) |*value| value.deinit(allocator);
            allocator.free(self.placements);
            for (self.allocations) |*value| value.deinit(allocator);
            allocator.free(self.allocations);
            deinitNodeList(allocator, self.nodes);
            deinitMemberList(allocator, self.members);
            self.* = undefined;
        }
    };

    pub fn listReconcileVolumes(self: *const PoolStateMachine, allocator: std.mem.Allocator) ![]ReconcileVolume {
        var result: std.ArrayList(ReconcileVolume) = .empty;
        errdefer {
            for (result.items) |*item| item.deinit(allocator);
            result.deinit(allocator);
        }
        for (self.state.volume_ids_by_revision.items) |volume_id| {
            const stored_volume = self.state.volumes_by_id.get(volume_id).?;
            const stored_authority = self.state.primary_authorities_by_volume.get(volume_id);
            const stored_candidate = self.state.primary_authority_candidates_by_volume.get(volume_id);
            const stored_failover = self.state.primary_failovers_by_volume.get(volume_id);
            var has_attachments = false;
            var attachment_iterator = self.state.volume_attachments_by_id.valueIterator();
            while (attachment_iterator.next()) |attachment| if (std.mem.eql(u8, attachment.volume_id, volume_id)) {
                has_attachments = true;
                break;
            };
            if (stored_volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_ACTIVE and
                stored_volume.operation_phase == .VOLUME_OPERATION_PHASE_NONE and
                (stored_authority == null or stored_authority.?.state != .PRIMARY_AUTHORITY_STATE_READY)) continue;
            var placements: std.ArrayList(pb.ReplicaPlacement) = .empty;
            var allocations: std.ArrayList(pb.ReplicaAllocation) = .empty;
            var nodes: std.ArrayList(pb.Node) = .empty;
            var members: std.ArrayList(pb.Member) = .empty;
            errdefer {
                for (placements.items) |*value| value.deinit(allocator);
                placements.deinit(allocator);
                for (allocations.items) |*value| value.deinit(allocator);
                allocations.deinit(allocator);
                for (nodes.items) |*value| value.deinit(allocator);
                nodes.deinit(allocator);
                for (members.items) |*value| value.deinit(allocator);
                members.deinit(allocator);
            }
            for (0..volume_target_replica_count) |index| {
                var key_buffer: [37]u8 = undefined;
                const replica_id = self.state.replica_ids_by_volume_index.get(replicaKey(volume_id, @intCast(index), &key_buffer)) orelse continue;
                const placement = self.state.replica_placements_by_id.get(replica_id).?;
                try placements.append(allocator, try dupeReplicaPlacement(allocator, placement.proto()));
                try nodes.append(allocator, try dupeNode(allocator, self.state.nodes_by_id.get(placement.node_id).?.proto()));
                const allocation_id = self.state.allocation_ids_by_replica.get(replica_id) orelse continue;
                const allocation = self.state.replica_allocations_by_id.get(allocation_id) orelse continue;
                try allocations.append(allocator, try dupeReplicaAllocation(allocator, allocation.proto()));
                try members.append(allocator, try dupeMember(allocator, self.state.members_by_id.get(allocation.member_id).?.proto()));
            }
            try result.append(allocator, .{
                .volume = try dupeVolume(allocator, stored_volume.proto()),
                .primary_authority = if (stored_authority) |authority| try dupePrimaryAuthority(allocator, authority.proto()) else null,
                .primary_authority_candidate = if (stored_candidate) |authority| try dupePrimaryAuthority(allocator, authority.proto()) else null,
                .primary_failover = if (stored_failover) |failover| try dupePrimaryFailover(allocator, failover.proto()) else null,
                .has_attachments = has_attachments,
                .placements = try placements.toOwnedSlice(allocator),
                .allocations = try allocations.toOwnedSlice(allocator),
                .nodes = try nodes.toOwnedSlice(allocator),
                .members = try members.toOwnedSlice(allocator),
            });
        }
        return result.toOwnedSlice(allocator);
    }

    /// Call under the same synchronization boundary as apply/listReconcileVolumes.
    /// Durable allocations and static registration are authoritative; heartbeat
    /// summaries do not contain enough range detail for safe first-fit planning.
    pub fn buildVolumeReservations(
        self: *const PoolStateMachine,
        allocator: std.mem.Allocator,
        volume_id: []const u8,
        placement_ids: [volume_target_replica_count][]const u8,
        allocation_ids: [volume_target_replica_count][]const u8,
    ) ![]pb.ReplicaReservation {
        const volume = self.state.volumes_by_id.get(volume_id) orelse return error.VolumeNotFound;
        if (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_PROVISIONING or
            volume.operation_phase != .VOLUME_OPERATION_PHASE_NONE or hasVolumeDependencies(&self.state, volume.id))
            return error.InvalidVolumeState;
        for (placement_ids, 0..) |id, index| {
            if (!validUuidV7(id) or self.state.replica_placements_by_id.contains(id)) return error.InvalidPlacementId;
            for (placement_ids[0..index]) |prior| if (std.mem.eql(u8, id, prior)) return error.InvalidPlacementId;
        }
        for (allocation_ids, 0..) |id, index| {
            if (!validUuidV7(id) or self.state.replica_allocations_by_id.contains(id)) return error.InvalidAllocationId;
            for (allocation_ids[0..index]) |prior| if (std.mem.eql(u8, id, prior)) return error.InvalidAllocationId;
        }

        const Candidate = struct { node: *const Node, member: *const Member };
        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(allocator);
        var members = self.state.members_by_id.valueIterator();
        while (members.next()) |member| {
            if (!std.mem.eql(u8, member.pool_id, volume.pool_id) or member.extent_size_bytes == 0 or
                member.data_capacity_bytes == 0 or member.data_capacity_bytes % member.extent_size_bytes != 0) continue;
            const node = self.state.nodes_by_id.getPtr(member.node_id) orelse continue;
            try candidates.append(allocator, .{ .node = node, .member = member });
        }
        std.mem.sort(Candidate, candidates.items, {}, struct {
            fn lessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
                const order = std.mem.order(u8, lhs.node.id, rhs.node.id);
                return order == .lt or (order == .eq and std.mem.lessThan(u8, lhs.member.id, rhs.member.id));
            }
        }.lessThan);

        var topology_nodes: [volume_target_replica_count][]const u8 = undefined;
        var topology_domains: [volume_target_replica_count][]const u8 = undefined;
        var topology_count: usize = 0;
        for (candidates.items) |candidate| {
            if (containsString(topology_nodes[0..topology_count], candidate.node.id) or
                containsString(topology_domains[0..topology_count], candidate.node.failure_domain)) continue;
            topology_nodes[topology_count] = candidate.node.id;
            topology_domains[topology_count] = candidate.node.failure_domain;
            topology_count += 1;
            if (topology_count == volume_target_replica_count) break;
        }
        if (topology_count != volume_target_replica_count) return error.InsufficientPlacement;

        var selected_nodes: [volume_target_replica_count][]const u8 = undefined;
        var selected_domains: [volume_target_replica_count][]const u8 = undefined;
        var selected_members: [volume_target_replica_count]*const Member = undefined;
        var selected_offsets: [volume_target_replica_count]u64 = undefined;
        var selected_lengths: [volume_target_replica_count]u64 = undefined;
        var selected_count: usize = 0;
        for (candidates.items) |candidate| {
            if (containsString(selected_nodes[0..selected_count], candidate.node.id) or
                containsString(selected_domains[0..selected_count], candidate.node.failure_domain)) continue;
            const extent: u64 = candidate.member.extent_size_bytes;
            const rounded = std.math.add(u64, volume.size_bytes, extent - 1) catch return error.InsufficientCapacity;
            const length = rounded / extent * extent;
            const offset = try firstFitAllocationOffset(&self.state, allocator, candidate.member.*, length) orelse continue;
            selected_nodes[selected_count] = candidate.node.id;
            selected_domains[selected_count] = candidate.node.failure_domain;
            selected_members[selected_count] = candidate.member;
            selected_offsets[selected_count] = offset;
            selected_lengths[selected_count] = length;
            selected_count += 1;
            if (selected_count == volume_target_replica_count) break;
        }
        if (selected_count != volume_target_replica_count) return error.InsufficientCapacity;

        var reservations: std.ArrayList(pb.ReplicaReservation) = .empty;
        errdefer {
            for (reservations.items) |*reservation| reservation.deinit(allocator);
            reservations.deinit(allocator);
        }
        try reservations.ensureTotalCapacity(allocator, volume_target_replica_count);
        for (0..volume_target_replica_count) |index| {
            const placement_id = try allocator.dupe(u8, placement_ids[index]);
            errdefer allocator.free(placement_id);
            const owned_volume_id = try allocator.dupe(u8, volume.id);
            errdefer allocator.free(owned_volume_id);
            const node_id = try allocator.dupe(u8, selected_nodes[index]);
            errdefer allocator.free(node_id);
            const allocation_id = try allocator.dupe(u8, allocation_ids[index]);
            errdefer allocator.free(allocation_id);
            const replica_id = try allocator.dupe(u8, placement_ids[index]);
            errdefer allocator.free(replica_id);
            const member_id = try allocator.dupe(u8, selected_members[index].id);
            reservations.appendAssumeCapacity(.{
                .placement = .{
                    .id = placement_id,
                    .volume_id = owned_volume_id,
                    .node_id = node_id,
                    .replica_index = @intCast(index),
                    .generation = volume.generation,
                    .state = .REPLICA_PLACEMENT_STATE_RESERVED,
                },
                .allocation = .{
                    .id = allocation_id,
                    .replica_id = replica_id,
                    .member_id = member_id,
                    .offset_bytes = selected_offsets[index],
                    .length_bytes = selected_lengths[index],
                    .generation = volume.generation,
                    .state = .REPLICA_ALLOCATION_STATE_RESERVED,
                },
            });
        }
        return reservations.toOwnedSlice(allocator);
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

    pub fn getNodeById(self: *const PoolStateMachine, allocator: std.mem.Allocator, id: []const u8) !?pb.Node {
        const node = self.state.nodes_by_id.get(id) orelse return null;
        return try dupeNode(allocator, node.proto());
    }

    pub const NodePage = struct {
        nodes: []pb.Node,
        has_more: bool,

        pub fn deinit(self: *NodePage, allocator: std.mem.Allocator) void {
            deinitNodeList(allocator, self.nodes);
            self.* = undefined;
        }
    };

    pub fn listNodesPage(
        self: *const PoolStateMachine,
        allocator: std.mem.Allocator,
        after_id: ?[]const u8,
        limit: usize,
    ) !NodePage {
        var start: usize = 0;
        if (after_id) |target| {
            while (start < self.state.node_ids_by_revision.items.len and
                !std.mem.eql(u8, self.state.node_ids_by_revision.items[start], target)) : (start += 1)
            {}
            if (start == self.state.node_ids_by_revision.items.len) return error.InvalidPageToken;
            start += 1;
        }
        const end = @min(start +| limit, self.state.node_ids_by_revision.items.len);
        var nodes: std.ArrayList(pb.Node) = .empty;
        errdefer {
            for (nodes.items) |*node| node.deinit(allocator);
            nodes.deinit(allocator);
        }
        try nodes.ensureTotalCapacity(allocator, end - start);
        for (self.state.node_ids_by_revision.items[start..end]) |id| {
            nodes.appendAssumeCapacity(try dupeNode(allocator, self.state.nodes_by_id.get(id).?.proto()));
        }
        return .{
            .nodes = try nodes.toOwnedSlice(allocator),
            .has_more = end < self.state.node_ids_by_revision.items.len,
        };
    }

    pub fn getMemberById(self: *const PoolStateMachine, allocator: std.mem.Allocator, id: []const u8) !?pb.Member {
        const member = self.state.members_by_id.get(id) orelse return null;
        return try dupeMember(allocator, member.proto());
    }

    pub const MemberPage = struct {
        members: []pb.Member,
        has_more: bool,

        pub fn deinit(self: *MemberPage, allocator: std.mem.Allocator) void {
            deinitMemberList(allocator, self.members);
            self.* = undefined;
        }
    };

    pub fn listMembersPage(
        self: *const PoolStateMachine,
        allocator: std.mem.Allocator,
        after_id: ?[]const u8,
        limit: usize,
    ) !MemberPage {
        var start: usize = 0;
        if (after_id) |target| {
            while (start < self.state.member_ids_by_revision.items.len and
                !std.mem.eql(u8, self.state.member_ids_by_revision.items[start], target)) : (start += 1)
            {}
            if (start == self.state.member_ids_by_revision.items.len) return error.InvalidPageToken;
            start += 1;
        }
        const end = @min(start +| limit, self.state.member_ids_by_revision.items.len);
        var members: std.ArrayList(pb.Member) = .empty;
        errdefer {
            for (members.items) |*member| member.deinit(allocator);
            members.deinit(allocator);
        }
        try members.ensureTotalCapacity(allocator, end - start);
        for (self.state.member_ids_by_revision.items[start..end]) |id| {
            members.appendAssumeCapacity(try dupeMember(allocator, self.state.members_by_id.get(id).?.proto()));
        }
        return .{
            .members = try members.toOwnedSlice(allocator),
            .has_more = end < self.state.member_ids_by_revision.items.len,
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
        if (envelope.format_version < 1 or envelope.format_version > command_format_version) return error.PayloadParseFailed;
        return switch (envelope.command orelse return error.PayloadParseFailed) {
            .create_pool => |command| self.applyCreatePool(entry.index, command),
            .register_node => |command| self.applyRegisterNode(entry.index, command),
            .register_member => |command| self.applyRegisterMember(entry.index, command),
            .create_volume => |command| if (envelope.format_version >= 2)
                self.applyCreateVolume(entry.index, command)
            else
                error.PayloadParseFailed,
            .delete_volume => |command| if (envelope.format_version >= 2)
                self.applyDeleteVolume(entry.index, command)
            else
                error.PayloadParseFailed,
            .update_volume => |command| if (envelope.format_version >= 3) self.applyUpdateVolume(entry.index, command) else error.PayloadParseFailed,
            .reserve_volume_resources => |command| if (envelope.format_version >= 3) self.applyReserveVolumeResources(entry.index, command) else error.PayloadParseFailed,
            .activate_replica => |command| if (envelope.format_version >= 4)
                self.applyActivateReplica(entry.index, command)
            else if (envelope.format_version == 3)
                self.rejectLegacyActivateReplica(command)
            else
                error.PayloadParseFailed,
            .finalize_volume_deletion => |command| if (envelope.format_version >= 3) self.applyFinalizeVolumeDeletion(entry.index, command) else error.PayloadParseFailed,
            .propose_primary_authority => |command| if (envelope.format_version >= 5) self.applyProposePrimaryAuthority(entry.index, command) else error.PayloadParseFailed,
            .activate_primary_authority => |command| if (envelope.format_version >= 5) self.applyActivatePrimaryAuthority(entry.index, command) else error.PayloadParseFailed,
            .commit_primary_authority_ready => |command| if (envelope.format_version >= 5) self.applyCommitPrimaryAuthorityReady(entry.index, command) else error.PayloadParseFailed,
            .commit_primary_authority_renewal_ready => |command| if (envelope.format_version >= 6) self.applyCommitPrimaryAuthorityRenewalReady(entry.index, command) else error.PayloadParseFailed,
            .abort_primary_authority_candidate => |command| if (envelope.format_version >= 7) self.applyAbortPrimaryAuthorityCandidate(entry.index, command) else error.PayloadParseFailed,
            .begin_primary_failover => |command| if (envelope.format_version >= 8) self.applyBeginPrimaryFailover(entry.index, command) else error.PayloadParseFailed,
            .commit_primary_authority_failover_ready => |command| if (envelope.format_version >= 8) self.applyCommitPrimaryAuthorityFailoverReady(entry.index, command) else error.PayloadParseFailed,
            .complete_primary_failover_lease_wait => |command| if (envelope.format_version >= 8) self.applyCompletePrimaryFailoverLeaseWait(entry.index, command) else error.PayloadParseFailed,
        };
    }

    fn applyCreatePool(self: *PoolStateMachine, revision: u64, command: pb.CreatePoolCommand) raft.Error!raft.ApplyResult {
        try validateCommand(command);

        const fingerprint = requestFingerprint(command);
        if (self.state.requests.get(command.request_id)) |request| {
            if (request.kind != .create_pool or !std.mem.eql(u8, &fingerprint, &request.fingerprint)) {
                return .{ .response = try encodeApplyResponse(self.allocator, .APPLY_CODE_REQUEST_CONFLICT, null) };
            }
            return .{ .response = try self.allocator.dupe(u8, request.encoded_response) };
        }
        if (self.state.requests.count() >= max_requests) {
            return .{ .response = try encodeApplyResponse(self.allocator, .APPLY_CODE_REQUEST_LIMIT, null) };
        }

        if (self.state.pool_ids_by_name.get(command.name)) |existing_id| {
            const existing = self.state.pools_by_id.get(existing_id).?;
            return try self.recordPoolResponse(
                command,
                fingerprint,
                try encodeApplyResponse(self.allocator, .APPLY_CODE_NAME_EXISTS, existing.proto()),
                revision,
            );
        }
        if (self.state.pools_by_id.get(command.proposed_pool_id)) |existing| {
            return try self.recordPoolResponse(
                command,
                fingerprint,
                try encodeApplyResponse(self.allocator, .APPLY_CODE_ID_EXISTS, existing.proto()),
                revision,
            );
        }
        if (self.state.pools_by_id.count() >= max_pools) {
            return try self.recordPoolResponse(
                command,
                fingerprint,
                try encodeApplyResponse(self.allocator, .APPLY_CODE_POOL_LIMIT, null),
                revision,
            );
        }

        const pool_proto: pb.Pool = .{
            .id = command.proposed_pool_id,
            .name = command.name,
            .description = command.description,
            .created_at_unix_ms = command.proposed_created_at_unix_ms,
            .created_revision = revision,
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
            .kind = .create_pool,
            .fingerprint = fingerprint,
            .encoded_response = encoded_response,
            .encoded_command = encoded_command,
            .applied_revision = revision,
        });
        return .{ .response = returned_response };
    }

    fn recordPoolResponse(
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
            .kind = .create_pool,
            .fingerprint = fingerprint,
            .encoded_response = encoded_response,
            .encoded_command = encoded_command,
            .applied_revision = applied_revision,
        });
        return .{ .response = returned_response };
    }

    fn applyRegisterNode(self: *PoolStateMachine, revision: u64, command: pb.RegisterNodeCommand) raft.Error!raft.ApplyResult {
        try validateRegisterNodeCommand(command);
        if (revision == 0) return error.PayloadParseFailed;

        const fingerprint = registerNodeFingerprint(command);
        if (self.state.requests.get(command.request_id)) |request| {
            if (request.kind != .register_node or !std.mem.eql(u8, &fingerprint, &request.fingerprint)) {
                return .{ .response = try encodeRegisterNodeApplyResponse(self.allocator, .REGISTER_NODE_APPLY_CODE_REQUEST_CONFLICT, null) };
            }
            return .{ .response = try self.allocator.dupe(u8, request.encoded_response) };
        }
        if (self.state.requests.count() >= max_requests) {
            return .{ .response = try encodeRegisterNodeApplyResponse(self.allocator, .REGISTER_NODE_APPLY_CODE_REQUEST_LIMIT, null) };
        }

        if (self.state.nodes_by_id.get(command.node_id)) |existing| {
            return self.recordNodeResponse(
                command,
                fingerprint,
                try encodeRegisterNodeApplyResponse(self.allocator, .REGISTER_NODE_APPLY_CODE_ID_EXISTS, existing.proto()),
                revision,
            );
        }
        if (self.state.nodes_by_id.count() >= max_nodes) {
            return self.recordNodeResponse(
                command,
                fingerprint,
                try encodeRegisterNodeApplyResponse(self.allocator, .REGISTER_NODE_APPLY_CODE_NODE_LIMIT, null),
                revision,
            );
        }

        const data_node_proto: pb.Node = .{
            .id = command.node_id,
            .cluster_id = command.cluster_id,
            .control_endpoint = command.control_endpoint,
            .nvmf_endpoint = command.nvmf_endpoint,
            .failure_domain = command.failure_domain,
            .capability_bits = command.capability_bits,
            .protocol_version = command.protocol_version,
            .registered_at_unix_ms = command.proposed_registered_at_unix_ms,
            .registered_revision = revision,
        };
        const encoded_response = try encodeRegisterNodeApplyResponse(self.allocator, .REGISTER_NODE_APPLY_CODE_REGISTERED, data_node_proto);
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeRegisterNodeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        var node = try Node.init(self.allocator, data_node_proto);
        errdefer node.deinit(self.allocator);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);

        try self.state.nodes_by_id.ensureUnusedCapacity(self.allocator, 1);
        try self.state.node_ids_by_revision.ensureUnusedCapacity(self.allocator, 1);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.nodes_by_id.putAssumeCapacity(node.id, node);
        self.state.node_ids_by_revision.appendAssumeCapacity(node.id);
        self.state.max_node_registered_revision = @max(self.state.max_node_registered_revision, node.registered_revision);
        self.state.requests.putAssumeCapacity(request_id, .{
            .request_id = request_id,
            .kind = .register_node,
            .fingerprint = fingerprint,
            .encoded_response = encoded_response,
            .encoded_command = encoded_command,
            .applied_revision = revision,
        });
        return .{ .response = returned_response };
    }

    fn recordNodeResponse(
        self: *PoolStateMachine,
        command: pb.RegisterNodeCommand,
        fingerprint: Fingerprint,
        encoded_response: []u8,
        applied_revision: u64,
    ) raft.Error!raft.ApplyResult {
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeRegisterNodeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.requests.putAssumeCapacity(request_id, .{
            .request_id = request_id,
            .kind = .register_node,
            .fingerprint = fingerprint,
            .encoded_response = encoded_response,
            .encoded_command = encoded_command,
            .applied_revision = applied_revision,
        });
        return .{ .response = returned_response };
    }

    fn applyRegisterMember(self: *PoolStateMachine, revision: u64, command: pb.RegisterMemberCommand) raft.Error!raft.ApplyResult {
        try validateRegisterMemberCommand(command);
        if (revision == 0) return error.PayloadParseFailed;

        const fingerprint = registerMemberFingerprint(command);
        if (self.state.requests.get(command.request_id)) |request| {
            if (request.kind != .register_member or !std.mem.eql(u8, &fingerprint, &request.fingerprint)) {
                return .{ .response = try encodeRegisterMemberApplyResponse(self.allocator, .REGISTER_MEMBER_APPLY_CODE_REQUEST_CONFLICT, null) };
            }
            return .{ .response = try self.allocator.dupe(u8, request.encoded_response) };
        }
        if (self.state.requests.count() >= max_requests) {
            return .{ .response = try encodeRegisterMemberApplyResponse(self.allocator, .REGISTER_MEMBER_APPLY_CODE_REQUEST_LIMIT, null) };
        }

        if (!self.state.pools_by_id.contains(command.pool_id)) {
            return self.recordMemberResponse(command, fingerprint, try encodeRegisterMemberApplyResponse(
                self.allocator,
                .REGISTER_MEMBER_APPLY_CODE_POOL_NOT_FOUND,
                null,
            ), revision);
        }
        const node = self.state.nodes_by_id.get(command.node_id) orelse {
            return self.recordMemberResponse(command, fingerprint, try encodeRegisterMemberApplyResponse(
                self.allocator,
                .REGISTER_MEMBER_APPLY_CODE_NODE_NOT_FOUND,
                null,
            ), revision);
        };
        if (!std.mem.eql(u8, command.cluster_id, node.cluster_id)) {
            return self.recordMemberResponse(command, fingerprint, try encodeRegisterMemberApplyResponse(
                self.allocator,
                .REGISTER_MEMBER_APPLY_CODE_CLUSTER_MISMATCH,
                null,
            ), revision);
        }
        if (self.state.members_by_id.get(command.member_id)) |existing| {
            return self.recordMemberResponse(command, fingerprint, try encodeRegisterMemberApplyResponse(
                self.allocator,
                .REGISTER_MEMBER_APPLY_CODE_ID_EXISTS,
                existing.proto(),
            ), revision);
        }
        if (self.state.pool_ids_by_local_set.get(command.local_set_id)) |pool_id| {
            if (!std.mem.eql(u8, command.pool_id, pool_id)) {
                return self.recordMemberResponse(command, fingerprint, try encodeRegisterMemberApplyResponse(
                    self.allocator,
                    .REGISTER_MEMBER_APPLY_CODE_LOCAL_SET_CONFLICT,
                    null,
                ), revision);
            }
        }
        const slot_key = memberSlotKey(command.local_set_id, command.member_slot);
        if (self.state.member_ids_by_slot.get(slot_key)) |member_id| {
            return self.recordMemberResponse(command, fingerprint, try encodeRegisterMemberApplyResponse(
                self.allocator,
                .REGISTER_MEMBER_APPLY_CODE_SLOT_EXISTS,
                self.state.members_by_id.get(member_id).?.proto(),
            ), revision);
        }
        if (self.state.members_by_id.count() >= max_members) {
            return self.recordMemberResponse(command, fingerprint, try encodeRegisterMemberApplyResponse(
                self.allocator,
                .REGISTER_MEMBER_APPLY_CODE_MEMBER_LIMIT,
                null,
            ), revision);
        }

        const member_proto: pb.Member = .{
            .id = command.member_id,
            .pool_id = command.pool_id,
            .node_id = command.node_id,
            .local_set_id = command.local_set_id,
            .member_slot = command.member_slot,
            .birth_topology_digest = command.birth_topology_digest,
            .metadata_capacity_bytes = command.metadata_capacity_bytes,
            .data_capacity_bytes = command.data_capacity_bytes,
            .extent_size_bytes = command.extent_size_bytes,
            .registered_at_unix_ms = command.proposed_registered_at_unix_ms,
            .registered_revision = revision,
        };
        const encoded_response = try encodeRegisterMemberApplyResponse(self.allocator, .REGISTER_MEMBER_APPLY_CODE_REGISTERED, member_proto);
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeRegisterMemberCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        var member = try Member.init(self.allocator, member_proto);
        errdefer member.deinit(self.allocator);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);

        try self.state.members_by_id.ensureUnusedCapacity(self.allocator, 1);
        try self.state.member_ids_by_revision.ensureUnusedCapacity(self.allocator, 1);
        if (!self.state.pool_ids_by_local_set.contains(command.local_set_id)) {
            try self.state.pool_ids_by_local_set.ensureUnusedCapacity(self.allocator, 1);
        }
        try self.state.member_ids_by_slot.ensureUnusedCapacity(self.allocator, 1);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.members_by_id.putAssumeCapacity(member.id, member);
        self.state.member_ids_by_revision.appendAssumeCapacity(member.id);
        if (!self.state.pool_ids_by_local_set.contains(member.local_set_id)) {
            self.state.pool_ids_by_local_set.putAssumeCapacity(member.local_set_id, member.pool_id);
        }
        self.state.member_ids_by_slot.putAssumeCapacity(slot_key, member.id);
        self.state.max_member_registered_revision = @max(self.state.max_member_registered_revision, member.registered_revision);
        self.state.requests.putAssumeCapacity(request_id, .{
            .request_id = request_id,
            .kind = .register_member,
            .fingerprint = fingerprint,
            .encoded_response = encoded_response,
            .encoded_command = encoded_command,
            .applied_revision = revision,
        });
        return .{ .response = returned_response };
    }

    fn recordMemberResponse(
        self: *PoolStateMachine,
        command: pb.RegisterMemberCommand,
        fingerprint: Fingerprint,
        encoded_response: []u8,
        applied_revision: u64,
    ) raft.Error!raft.ApplyResult {
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeRegisterMemberCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.requests.putAssumeCapacity(request_id, .{
            .request_id = request_id,
            .kind = .register_member,
            .fingerprint = fingerprint,
            .encoded_response = encoded_response,
            .encoded_command = encoded_command,
            .applied_revision = applied_revision,
        });
        return .{ .response = returned_response };
    }

    fn applyCreateVolume(self: *PoolStateMachine, revision: u64, command: pb.CreateVolumeCommand) raft.Error!raft.ApplyResult {
        try validateCreateVolumeCommand(command);
        if (revision == 0) return error.PayloadParseFailed;

        const fingerprint = createVolumeFingerprint(command);
        if (self.state.requests.get(command.request_id)) |request| {
            if (request.kind != .create_volume or !std.mem.eql(u8, &fingerprint, &request.fingerprint)) {
                return .{ .response = try encodeCreateVolumeApplyResponse(self.allocator, .CREATE_VOLUME_APPLY_CODE_REQUEST_CONFLICT, null) };
            }
            return .{ .response = try self.allocator.dupe(u8, request.encoded_response) };
        }
        if (self.state.requests.count() >= max_requests) {
            return .{ .response = try encodeCreateVolumeApplyResponse(self.allocator, .CREATE_VOLUME_APPLY_CODE_REQUEST_LIMIT, null) };
        }
        if (!self.state.pools_by_id.contains(command.pool_id)) {
            return self.recordCreateVolumeResponse(command, fingerprint, try encodeCreateVolumeApplyResponse(self.allocator, .CREATE_VOLUME_APPLY_CODE_POOL_NOT_FOUND, null), revision);
        }
        if (self.state.volumes_by_id.get(command.proposed_volume_id)) |existing| {
            return self.recordCreateVolumeResponse(command, fingerprint, try encodeCreateVolumeApplyResponse(self.allocator, .CREATE_VOLUME_APPLY_CODE_ID_EXISTS, existing.proto()), revision);
        }
        if (self.state.volume_tombstones_by_id.get(command.proposed_volume_id)) |existing| {
            return self.recordCreateVolumeResponse(command, fingerprint, try encodeCreateVolumeApplyResponse(self.allocator, .CREATE_VOLUME_APPLY_CODE_ID_EXISTS, existing.volume.proto()), revision);
        }
        var scoped_buffer: [36 + 1 + max_name_bytes]u8 = undefined;
        const scoped_name = scopedKey(command.pool_id, command.name, &scoped_buffer);
        if (self.state.volume_ids_by_scoped_name.get(scoped_name)) |existing_id| {
            const existing = self.state.volumes_by_id.get(existing_id).?;
            return self.recordCreateVolumeResponse(command, fingerprint, try encodeCreateVolumeApplyResponse(self.allocator, .CREATE_VOLUME_APPLY_CODE_NAME_EXISTS, existing.proto()), revision);
        }
        if (self.state.volumes_by_id.count() >= max_volumes) {
            return self.recordCreateVolumeResponse(command, fingerprint, try encodeCreateVolumeApplyResponse(self.allocator, .CREATE_VOLUME_APPLY_CODE_VOLUME_LIMIT, null), revision);
        }

        const volume_proto: pb.Volume = .{
            .id = command.proposed_volume_id,
            .pool_id = command.pool_id,
            .name = command.name,
            .description = command.description,
            .size_bytes = command.size_bytes,
            .protection_kind = .VOLUME_PROTECTION_KIND_REPLICATED,
            .target_replica_count = volume_target_replica_count,
            .write_quorum = volume_write_quorum,
            .read_quorum = volume_read_quorum,
            .lifecycle_state = .VOLUME_LIFECYCLE_STATE_PROVISIONING,
            .availability_state = .VOLUME_AVAILABILITY_STATE_UNKNOWN,
            .operation_phase = .VOLUME_OPERATION_PHASE_NONE,
            .generation = 1,
            .write_epoch = 1,
            .placement_revision = 0,
            .created_at_unix_ms = command.proposed_created_at_unix_ms,
            .created_revision = revision,
            .resource_version = revision,
        };
        const encoded_response = try encodeCreateVolumeApplyResponse(self.allocator, .CREATE_VOLUME_APPLY_CODE_CREATED, volume_proto);
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeCreateVolumeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        var volume = try Volume.init(self.allocator, volume_proto);
        errdefer volume.deinit(self.allocator);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);

        try self.state.volumes_by_id.ensureUnusedCapacity(self.allocator, 1);
        try self.state.volume_ids_by_scoped_name.ensureUnusedCapacity(self.allocator, 1);
        try self.state.volume_ids_by_revision.ensureUnusedCapacity(self.allocator, 1);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.volumes_by_id.putAssumeCapacity(volume.id, volume);
        self.state.volume_ids_by_scoped_name.putAssumeCapacity(volume.scoped_name, volume.id);
        self.state.volume_ids_by_revision.appendAssumeCapacity(volume.id);
        self.state.max_volume_created_revision = @max(self.state.max_volume_created_revision, revision);
        self.state.requests.putAssumeCapacity(request_id, .{ .request_id = request_id, .kind = .create_volume, .fingerprint = fingerprint, .encoded_response = encoded_response, .encoded_command = encoded_command, .applied_revision = revision });
        return .{ .response = returned_response };
    }

    fn recordCreateVolumeResponse(self: *PoolStateMachine, command: pb.CreateVolumeCommand, fingerprint: Fingerprint, encoded_response: []u8, revision: u64) raft.Error!raft.ApplyResult {
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeCreateVolumeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.requests.putAssumeCapacity(request_id, .{ .request_id = request_id, .kind = .create_volume, .fingerprint = fingerprint, .encoded_response = encoded_response, .encoded_command = encoded_command, .applied_revision = revision });
        return .{ .response = returned_response };
    }

    fn applyUpdateVolume(self: *PoolStateMachine, revision: u64, command: pb.UpdateVolumeCommand) raft.Error!raft.ApplyResult {
        try validateUpdateVolumeCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const fingerprint = updateVolumeFingerprint(command);
        if (self.state.requests.get(command.request_id)) |request| {
            if (request.kind != .update_volume or !std.mem.eql(u8, &fingerprint, &request.fingerprint)) return .{ .response = try encodeUpdateVolumeApplyResponse(self.allocator, .UPDATE_VOLUME_APPLY_CODE_REQUEST_CONFLICT, null) };
            return .{ .response = try self.allocator.dupe(u8, request.encoded_response) };
        }
        if (self.state.requests.count() >= max_requests) return .{ .response = try encodeUpdateVolumeApplyResponse(self.allocator, .UPDATE_VOLUME_APPLY_CODE_REQUEST_LIMIT, null) };
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return self.recordUpdateVolumeResponse(command, fingerprint, try encodeUpdateVolumeApplyResponse(self.allocator, .UPDATE_VOLUME_APPLY_CODE_NOT_FOUND, null), revision);
        if (volume.resource_version != command.expected_resource_version) return self.recordUpdateVolumeResponse(command, fingerprint, try encodeUpdateVolumeApplyResponse(self.allocator, .UPDATE_VOLUME_APPLY_CODE_VERSION_CONFLICT, volume.proto()), revision);
        if (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE) return self.recordUpdateVolumeResponse(command, fingerprint, try encodeUpdateVolumeApplyResponse(self.allocator, .UPDATE_VOLUME_APPLY_CODE_INVALID_STATE, volume.proto()), revision);

        const description = try self.allocator.dupe(u8, command.description);
        errdefer self.allocator.free(description);
        const encoded_command = try encodeUpdateVolumeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        var response_volume = volume.proto();
        response_volume.description = command.description;
        response_volume.generation += 1;
        response_volume.resource_version = revision;
        const encoded_response = try encodeUpdateVolumeApplyResponse(self.allocator, .UPDATE_VOLUME_APPLY_CODE_UPDATED, response_volume);
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.allocator.free(volume.description);
        volume.description = description;
        volume.generation += 1;
        volume.resource_version = revision;
        self.state.requests.putAssumeCapacity(request_id, .{ .request_id = request_id, .kind = .update_volume, .fingerprint = fingerprint, .encoded_response = encoded_response, .encoded_command = encoded_command, .applied_revision = revision });
        return .{ .response = returned_response };
    }

    fn recordUpdateVolumeResponse(self: *PoolStateMachine, command: pb.UpdateVolumeCommand, fingerprint: Fingerprint, encoded_response: []u8, revision: u64) raft.Error!raft.ApplyResult {
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeUpdateVolumeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.requests.putAssumeCapacity(request_id, .{ .request_id = request_id, .kind = .update_volume, .fingerprint = fingerprint, .encoded_response = encoded_response, .encoded_command = encoded_command, .applied_revision = revision });
        return .{ .response = returned_response };
    }

    fn applyReserveVolumeResources(self: *PoolStateMachine, revision: u64, command: pb.ReserveVolumeResourcesCommand) raft.Error!raft.ApplyResult {
        try validateReserveVolumeResourcesCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodeReserveApplyResponse(self.allocator, .RESERVE_VOLUME_RESOURCES_APPLY_CODE_NOT_FOUND, null) };
        if (volume.resource_version != command.expected_resource_version) return .{ .response = try encodeReserveApplyResponse(self.allocator, .RESERVE_VOLUME_RESOURCES_APPLY_CODE_VERSION_CONFLICT, volume.proto()) };
        if (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_PROVISIONING or volume.operation_phase != .VOLUME_OPERATION_PHASE_NONE or hasVolumeDependencies(&self.state, volume.id)) return .{ .response = try encodeReserveApplyResponse(self.allocator, .RESERVE_VOLUME_RESOURCES_APPLY_CODE_INVALID_STATE, volume.proto()) };
        if (self.state.replica_placements_by_id.count() > max_replica_placements - volume_target_replica_count or self.state.replica_allocations_by_id.count() > max_replica_allocations - volume_target_replica_count) return .{ .response = try encodeReserveApplyResponse(self.allocator, .RESERVE_VOLUME_RESOURCES_APPLY_CODE_RESOURCE_LIMIT, volume.proto()) };
        validateReservations(&self.state, volume.*, command.reservations.items) catch return .{ .response = try encodeReserveApplyResponse(self.allocator, .RESERVE_VOLUME_RESOURCES_APPLY_CODE_INVALID_RESERVATION, volume.proto()) };

        var placements: [volume_target_replica_count]ReplicaPlacement = undefined;
        var allocations: [volume_target_replica_count]ReplicaAllocation = undefined;
        var placement_count: usize = 0;
        var allocation_count: usize = 0;
        errdefer {
            for (0..placement_count) |index| placements[index].deinit(self.allocator);
            for (0..allocation_count) |index| allocations[index].deinit(self.allocator);
        }
        for (command.reservations.items, 0..) |reservation, index| {
            var placement_proto = reservation.placement.?;
            placement_proto.created_revision = revision;
            placement_proto.resource_version = revision;
            placement_proto.state = .REPLICA_PLACEMENT_STATE_RESERVED;
            placement_proto.backend_digest = &.{};
            placement_proto.attested_revision = 0;
            var allocation_proto = reservation.allocation.?;
            allocation_proto.created_revision = revision;
            allocation_proto.resource_version = revision;
            allocation_proto.state = .REPLICA_ALLOCATION_STATE_RESERVED;
            placements[index] = try ReplicaPlacement.init(self.allocator, placement_proto);
            placement_count += 1;
            allocations[index] = try ReplicaAllocation.init(self.allocator, allocation_proto);
            allocation_count += 1;
        }
        var response_volume = volume.proto();
        response_volume.operation_phase = .VOLUME_OPERATION_PHASE_PLACING;
        response_volume.placement_revision = revision;
        response_volume.resource_version = revision;
        const response = try encodeReserveApplyResponse(self.allocator, .RESERVE_VOLUME_RESOURCES_APPLY_CODE_RESERVED, response_volume);
        errdefer self.allocator.free(response);
        try self.state.replica_placements_by_id.ensureUnusedCapacity(self.allocator, volume_target_replica_count);
        try self.state.replica_ids_by_volume_index.ensureUnusedCapacity(self.allocator, volume_target_replica_count);
        try self.state.replica_allocations_by_id.ensureUnusedCapacity(self.allocator, volume_target_replica_count);
        try self.state.allocation_ids_by_replica.ensureUnusedCapacity(self.allocator, volume_target_replica_count);
        for (0..volume_target_replica_count) |index| {
            const placement = placements[index];
            const allocation = allocations[index];
            self.state.replica_placements_by_id.putAssumeCapacity(placement.id, placement);
            self.state.replica_ids_by_volume_index.putAssumeCapacity(placement.replica_key, placement.id);
            self.state.replica_allocations_by_id.putAssumeCapacity(allocation.id, allocation);
            self.state.allocation_ids_by_replica.putAssumeCapacity(allocation.replica_id, allocation.id);
        }
        volume.operation_phase = .VOLUME_OPERATION_PHASE_PLACING;
        volume.placement_revision = revision;
        volume.resource_version = revision;
        return .{ .response = response };
    }

    fn applyActivateReplica(self: *PoolStateMachine, revision: u64, command: pb.ActivateReplicaCommand) raft.Error!raft.ApplyResult {
        try validateActivateReplicaCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodeActivateApplyResponse(self.allocator, .ACTIVATE_REPLICA_APPLY_CODE_NOT_FOUND, null, null, null) };
        const placement = self.state.replica_placements_by_id.getPtr(command.placement_id) orelse return .{ .response = try encodeActivateApplyResponse(self.allocator, .ACTIVATE_REPLICA_APPLY_CODE_NOT_FOUND, volume.proto(), null, null) };
        const allocation = self.state.replica_allocations_by_id.getPtr(command.allocation_id) orelse return .{ .response = try encodeActivateApplyResponse(self.allocator, .ACTIVATE_REPLICA_APPLY_CODE_NOT_FOUND, volume.proto(), placement.proto(), null) };
        if (!std.mem.eql(u8, placement.volume_id, volume.id) or !std.mem.eql(u8, allocation.replica_id, placement.id)) return .{ .response = try encodeActivateApplyResponse(self.allocator, .ACTIVATE_REPLICA_APPLY_CODE_BINDING_MISMATCH, volume.proto(), placement.proto(), allocation.proto()) };
        if (volume.resource_version != command.expected_volume_resource_version or placement.resource_version != command.expected_placement_resource_version or allocation.resource_version != command.expected_allocation_resource_version) return .{ .response = try encodeActivateApplyResponse(self.allocator, .ACTIVATE_REPLICA_APPLY_CODE_VERSION_CONFLICT, volume.proto(), placement.proto(), allocation.proto()) };
        if (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_PROVISIONING or volume.operation_phase != .VOLUME_OPERATION_PHASE_PLACING or placement.state != .REPLICA_PLACEMENT_STATE_RESERVED or allocation.state != .REPLICA_ALLOCATION_STATE_RESERVED) return .{ .response = try encodeActivateApplyResponse(self.allocator, .ACTIVATE_REPLICA_APPLY_CODE_INVALID_STATE, volume.proto(), placement.proto(), allocation.proto()) };
        const attestation = command.attestation.?;
        if (!std.mem.eql(u8, attestation.volume_id, volume.id) or
            !std.mem.eql(u8, attestation.placement_id, placement.id) or
            !std.mem.eql(u8, attestation.allocation_id, allocation.id) or
            attestation.generation != placement.generation or
            !std.mem.eql(u8, attestation.member_id, allocation.member_id) or
            attestation.offset_bytes != allocation.offset_bytes or
            attestation.length_bytes != allocation.length_bytes)
        {
            return .{ .response = try encodeActivateApplyResponse(self.allocator, .ACTIVATE_REPLICA_APPLY_CODE_BINDING_MISMATCH, volume.proto(), placement.proto(), allocation.proto()) };
        }
        const backend_digest = try self.allocator.dupe(u8, attestation.backend_digest);
        errdefer self.allocator.free(backend_digest);
        var all_active = true;
        for (0..volume_target_replica_count) |index| {
            var key_buffer: [37]u8 = undefined;
            const id = self.state.replica_ids_by_volume_index.get(replicaKey(volume.id, @intCast(index), &key_buffer)) orelse {
                all_active = false;
                break;
            };
            if (!std.mem.eql(u8, id, placement.id) and self.state.replica_placements_by_id.get(id).?.state != .REPLICA_PLACEMENT_STATE_ACTIVE) {
                all_active = false;
                break;
            }
        }
        var response_volume = volume.proto();
        response_volume.resource_version = revision;
        if (all_active) {
            response_volume.operation_phase = .VOLUME_OPERATION_PHASE_FENCING;
        }
        var response_placement = placement.proto();
        response_placement.state = .REPLICA_PLACEMENT_STATE_ACTIVE;
        response_placement.resource_version = revision;
        response_placement.backend_digest = attestation.backend_digest;
        response_placement.attested_revision = revision;
        var response_allocation = allocation.proto();
        response_allocation.state = .REPLICA_ALLOCATION_STATE_ACTIVE;
        response_allocation.resource_version = revision;
        const response = try encodeActivateApplyResponse(self.allocator, .ACTIVATE_REPLICA_APPLY_CODE_ACTIVATED, response_volume, response_placement, response_allocation);
        placement.state = .REPLICA_PLACEMENT_STATE_ACTIVE;
        placement.resource_version = revision;
        self.allocator.free(placement.backend_digest);
        placement.backend_digest = backend_digest;
        placement.attested_revision = revision;
        allocation.state = .REPLICA_ALLOCATION_STATE_ACTIVE;
        allocation.resource_version = revision;
        volume.resource_version = revision;
        if (all_active) {
            volume.operation_phase = .VOLUME_OPERATION_PHASE_FENCING;
        }
        return .{ .response = response };
    }

    fn rejectLegacyActivateReplica(self: *PoolStateMachine, command: pb.ActivateReplicaCommand) raft.Error!raft.ApplyResult {
        try validateLegacyActivateReplicaCommand(command);
        const volume = self.state.volumes_by_id.get(command.volume_id);
        const placement = self.state.replica_placements_by_id.get(command.placement_id);
        const allocation = self.state.replica_allocations_by_id.get(command.allocation_id);
        return .{ .response = try encodeActivateApplyResponse(
            self.allocator,
            .ACTIVATE_REPLICA_APPLY_CODE_INVALID_STATE,
            if (volume) |value| value.proto() else null,
            if (placement) |value| value.proto() else null,
            if (allocation) |value| value.proto() else null,
        ) };
    }

    fn applyProposePrimaryAuthority(self: *PoolStateMachine, revision: u64, command: pb.ProposePrimaryAuthorityCommand) raft.Error!raft.ApplyResult {
        try validateProposePrimaryAuthorityCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const proposed = command.authority.?;
        const volume = self.state.volumes_by_id.getPtr(proposed.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, null) };
        if (self.state.primary_authority_candidates_by_volume.get(proposed.volume_id)) |existing| {
            const code: pb.PrimaryAuthorityApplyCode = if (existing.state == .PRIMARY_AUTHORITY_STATE_PENDING and authorityProposalMatches(existing.proto(), proposed))
                .PRIMARY_AUTHORITY_APPLY_CODE_PROPOSED
            else
                .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE;
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, code, existing.proto(), volume.proto()) };
        }
        if (volume.resource_version != command.expected_volume_resource_version) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT, null, volume.proto()) };
        const current = self.state.primary_authorities_by_volume.get(proposed.volume_id);
        const failover = self.state.primary_failovers_by_volume.getPtr(proposed.volume_id);
        const initial = current == null;
        if (failover != null) {
            if (!std.mem.eql(u8, failover.?.failover_id, command.failover_id) or failover.?.resource_version != command.expected_failover_resource_version or current == null or
                volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE or volume.availability_state != .VOLUME_AVAILABILITY_STATE_UNAVAILABLE or volume.operation_phase != .VOLUME_OPERATION_PHASE_FENCING or
                !failoverProposalValid(failover.?.*, current.?, proposed, volume.*))
                return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, null, volume.proto()) };
        } else if (command.failover_id.len != 0 or command.expected_failover_resource_version != 0) {
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, null, volume.proto()) };
        } else if ((initial and (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_PROVISIONING or volume.operation_phase != .VOLUME_OPERATION_PHASE_FENCING)) or
            (!initial and (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE or volume.availability_state != .VOLUME_AVAILABILITY_STATE_HEALTHY or volume.operation_phase != .VOLUME_OPERATION_PHASE_NONE)) or
            volume.write_epoch != proposed.write_epoch or volume.placement_revision != proposed.placement_revision)
        {
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, null, volume.proto()) };
        }
        if (!activePlacementSetValid(&self.state, volume.*, proposed.primary_placement_id, proposed.primary_node_id)) {
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, null, volume.proto()) };
        }
        if (failover == null and ((initial and proposed.authority_generation != 1) or
            (!initial and !renewalProposalValid(current.?, proposed))))
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, null, volume.proto()) };
        if (self.state.primary_authority_candidates_by_volume.count() >= max_primary_authorities) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_RESOURCE_LIMIT, null, volume.proto()) };

        var stored_proto = proposed;
        stored_proto.created_revision = revision;
        stored_proto.resource_version = revision;
        var authority = try PrimaryAuthority.init(self.allocator, stored_proto);
        errdefer authority.deinit(self.allocator);
        const response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_PROPOSED, stored_proto, blk: {
            var result = volume.proto();
            result.resource_version = revision;
            if (failover) |value| result.write_epoch = value.target_write_epoch;
            break :blk result;
        });
        errdefer self.allocator.free(response);
        try self.state.primary_authority_candidates_by_volume.ensureUnusedCapacity(self.allocator, 1);
        self.state.primary_authority_candidates_by_volume.putAssumeCapacity(authority.volume_id, authority);
        volume.resource_version = revision;
        if (failover) |value| {
            volume.write_epoch = value.target_write_epoch;
            value.state = .PRIMARY_FAILOVER_STATE_FENCING;
            value.resource_version = revision;
        }
        return .{ .response = response };
    }

    fn applyActivatePrimaryAuthority(self: *PoolStateMachine, revision: u64, command: pb.ActivatePrimaryAuthorityCommand) raft.Error!raft.ApplyResult {
        try validateActivatePrimaryAuthorityCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, null) };
        const authority = self.state.primary_authority_candidates_by_volume.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, volume.proto()) };
        if (!activationCommandMatches(authority.*, command)) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, authority.proto(), volume.proto()) };
        if (authority.state == .PRIMARY_AUTHORITY_STATE_ACTIVATED) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_ACTIVATED, authority.proto(), volume.proto()) };
        if (volume.resource_version != command.expected_volume_resource_version or authority.resource_version != command.expected_authority_resource_version) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT, authority.proto(), volume.proto()) };
        const initial_state = self.state.primary_authorities_by_volume.get(command.volume_id) == null and volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_PROVISIONING and volume.operation_phase == .VOLUME_OPERATION_PHASE_FENCING;
        const renewal_state = self.state.primary_authorities_by_volume.get(command.volume_id) != null and volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_ACTIVE and
            ((volume.availability_state == .VOLUME_AVAILABILITY_STATE_HEALTHY and volume.operation_phase == .VOLUME_OPERATION_PHASE_NONE) or
                (self.state.primary_failovers_by_volume.contains(command.volume_id) and volume.availability_state == .VOLUME_AVAILABILITY_STATE_UNAVAILABLE and volume.operation_phase == .VOLUME_OPERATION_PHASE_FENCING));
        if (authority.state != .PRIMARY_AUTHORITY_STATE_PENDING or (!initial_state and !renewal_state)) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, authority.proto(), volume.proto()) };
        var response_authority = authority.proto();
        response_authority.state = .PRIMARY_AUTHORITY_STATE_ACTIVATED;
        response_authority.activated_revision = revision;
        response_authority.resource_version = revision;
        var response_volume = volume.proto();
        response_volume.resource_version = revision;
        const response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_ACTIVATED, response_authority, response_volume);
        authority.state = .PRIMARY_AUTHORITY_STATE_ACTIVATED;
        authority.activated_revision = revision;
        authority.resource_version = revision;
        volume.resource_version = revision;
        return .{ .response = response };
    }

    fn applyCommitPrimaryAuthorityReady(self: *PoolStateMachine, revision: u64, command: pb.CommitPrimaryAuthorityReadyCommand) raft.Error!raft.ApplyResult {
        try validateCommitPrimaryAuthorityReadyCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, null) };
        if (self.state.primary_authorities_by_volume.contains(command.volume_id)) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, self.state.primary_authorities_by_volume.get(command.volume_id).?.proto(), volume.proto()) };
        const authority = self.state.primary_authority_candidates_by_volume.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, volume.proto()) };
        const recovery = command.recovery_evidence.?;
        if (!readyCommandMatches(authority.*, command)) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, authority.proto(), volume.proto()) };
        if (volume.resource_version != command.expected_volume_resource_version or authority.resource_version != command.expected_authority_resource_version) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT, authority.proto(), volume.proto()) };
        if (authority.state != .PRIMARY_AUTHORITY_STATE_ACTIVATED or volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_PROVISIONING or volume.operation_phase != .VOLUME_OPERATION_PHASE_FENCING) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, authority.proto(), volume.proto()) };
        if (!readyEvidenceValid(&self.state, volume.*, authority.*, command.fence_evidence.items, recovery)) return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_PROOF_INVALID, authority.proto(), volume.proto()) };

        const recovery_digest = try self.allocator.dupe(u8, recovery.history_digest);
        errdefer self.allocator.free(recovery_digest);
        var response_authority = authority.proto();
        response_authority.state = .PRIMARY_AUTHORITY_STATE_READY;
        response_authority.ready_revision = revision;
        response_authority.resource_version = revision;
        response_authority.recovery_sequence = recovery.certified_sequence;
        response_authority.recovery_digest = recovery.history_digest;
        response_authority.recovery_empty_frontier = recovery.empty_frontier;
        var response_volume = volume.proto();
        response_volume.lifecycle_state = .VOLUME_LIFECYCLE_STATE_ACTIVE;
        response_volume.availability_state = .VOLUME_AVAILABILITY_STATE_HEALTHY;
        response_volume.operation_phase = .VOLUME_OPERATION_PHASE_NONE;
        response_volume.resource_version = revision;
        const response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_READY, response_authority, response_volume);
        try self.state.primary_authorities_by_volume.ensureUnusedCapacity(self.allocator, 1);
        var promoted = self.state.primary_authority_candidates_by_volume.fetchRemove(command.volume_id).?.value;
        promoted.state = .PRIMARY_AUTHORITY_STATE_READY;
        promoted.ready_revision = revision;
        promoted.resource_version = revision;
        promoted.recovery_sequence = recovery.certified_sequence;
        self.allocator.free(promoted.recovery_digest);
        promoted.recovery_digest = recovery_digest;
        promoted.recovery_empty_frontier = recovery.empty_frontier;
        self.state.primary_authorities_by_volume.putAssumeCapacity(promoted.volume_id, promoted);
        volume.lifecycle_state = .VOLUME_LIFECYCLE_STATE_ACTIVE;
        volume.availability_state = .VOLUME_AVAILABILITY_STATE_HEALTHY;
        volume.operation_phase = .VOLUME_OPERATION_PHASE_NONE;
        volume.resource_version = revision;
        return .{ .response = response };
    }

    fn applyCommitPrimaryAuthorityRenewalReady(self: *PoolStateMachine, revision: u64, command: pb.CommitPrimaryAuthorityRenewalReadyCommand) raft.Error!raft.ApplyResult {
        try validateCommitPrimaryAuthorityRenewalReadyCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, null) };
        const current = self.state.primary_authorities_by_volume.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, volume.proto()) };
        if (renewalReadyCommandMatches(current.*, command) and self.state.primary_authority_candidates_by_volume.get(command.volume_id) == null)
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_READY, current.proto(), volume.proto()) };
        const candidate = self.state.primary_authority_candidates_by_volume.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, current.proto(), volume.proto()) };
        if (!renewalReadyCommandMatches(candidate.*, command) or !renewalProposalValid(current.*, candidate.proto()))
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, candidate.proto(), volume.proto()) };
        if (volume.resource_version != command.expected_volume_resource_version or candidate.resource_version != command.expected_candidate_resource_version or current.resource_version != command.expected_current_resource_version)
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT, candidate.proto(), volume.proto()) };
        if (candidate.state != .PRIMARY_AUTHORITY_STATE_ACTIVATED or current.state != .PRIMARY_AUTHORITY_STATE_READY or volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE or volume.availability_state != .VOLUME_AVAILABILITY_STATE_HEALTHY or volume.operation_phase != .VOLUME_OPERATION_PHASE_NONE)
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, candidate.proto(), volume.proto()) };

        const inherited_digest = try self.allocator.dupe(u8, current.recovery_digest);
        errdefer self.allocator.free(inherited_digest);
        var response_authority = candidate.proto();
        response_authority.state = .PRIMARY_AUTHORITY_STATE_READY;
        response_authority.ready_revision = revision;
        response_authority.resource_version = revision;
        response_authority.recovery_sequence = current.recovery_sequence;
        response_authority.recovery_digest = current.recovery_digest;
        response_authority.recovery_empty_frontier = current.recovery_empty_frontier;
        var response_volume = volume.proto();
        response_volume.resource_version = revision;
        const response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_READY, response_authority, response_volume);
        errdefer self.allocator.free(response);

        var old = self.state.primary_authorities_by_volume.fetchRemove(command.volume_id).?.value;
        var promoted = self.state.primary_authority_candidates_by_volume.fetchRemove(command.volume_id).?.value;
        promoted.state = .PRIMARY_AUTHORITY_STATE_READY;
        promoted.ready_revision = revision;
        promoted.resource_version = revision;
        promoted.recovery_sequence = old.recovery_sequence;
        self.allocator.free(promoted.recovery_digest);
        promoted.recovery_digest = inherited_digest;
        promoted.recovery_empty_frontier = old.recovery_empty_frontier;
        old.deinit(self.allocator);
        self.state.primary_authorities_by_volume.putAssumeCapacity(promoted.volume_id, promoted);
        volume.resource_version = revision;
        return .{ .response = response };
    }

    fn applyAbortPrimaryAuthorityCandidate(self: *PoolStateMachine, revision: u64, command: pb.AbortPrimaryAuthorityCandidateCommand) raft.Error!raft.ApplyResult {
        try validateAbortPrimaryAuthorityCandidateCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, null) };
        const current = self.state.primary_authorities_by_volume.get(command.volume_id);
        const candidate = self.state.primary_authority_candidates_by_volume.get(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, volume.proto()) };
        if (!std.mem.eql(u8, candidate.lease_id, command.lease_id) or candidate.authority_generation != command.authority_generation)
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, candidate.proto(), volume.proto()) };
        const current_version_matches = if (current) |authority|
            command.expected_current_resource_version == authority.resource_version
        else
            command.expected_current_resource_version == 0;
        if (volume.resource_version != command.expected_volume_resource_version or candidate.resource_version != command.expected_candidate_resource_version or !current_version_matches)
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT, candidate.proto(), volume.proto()) };
        if (candidate.state != .PRIMARY_AUTHORITY_STATE_PENDING and candidate.state != .PRIMARY_AUTHORITY_STATE_ACTIVATED)
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, candidate.proto(), volume.proto()) };

        const failover = self.state.primary_failovers_by_volume.getPtr(command.volume_id);
        const next_failover_epoch = if (failover) |value| blk: {
            if (value.state != .PRIMARY_FAILOVER_STATE_FENCING) break :blk null;
            break :blk std.math.add(u64, value.target_write_epoch, 1) catch
                return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, candidate.proto(), volume.proto()) };
        } else null;
        var response_volume = volume.proto();
        response_volume.resource_version = revision;
        if (next_failover_epoch) |epoch| response_volume.write_epoch = epoch;
        const response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_ABORTED, candidate.proto(), response_volume);
        var removed = self.state.primary_authority_candidates_by_volume.fetchRemove(command.volume_id).?.value;
        removed.deinit(self.allocator);
        if (next_failover_epoch) |epoch| {
            failover.?.target_write_epoch = epoch;
            failover.?.resource_version = revision;
            volume.write_epoch = epoch;
        }
        volume.resource_version = revision;
        return .{ .response = response };
    }

    fn applyBeginPrimaryFailover(self: *PoolStateMachine, revision: u64, command: pb.BeginPrimaryFailoverCommand) raft.Error!raft.ApplyResult {
        try validateBeginPrimaryFailoverCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_NOT_FOUND, null, null, null) };
        const current = self.state.primary_authorities_by_volume.get(command.volume_id) orelse return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_NOT_FOUND, null, null, volume.proto()) };
        if (self.state.primary_failovers_by_volume.get(command.volume_id)) |existing| {
            const exact = std.mem.eql(u8, existing.failover_id, command.failover_id) and std.mem.eql(u8, existing.revoked_lease_id, command.current_lease_id) and
                existing.revoked_authority_generation == command.current_authority_generation and existing.revoked_write_epoch == command.current_write_epoch;
            return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, if (exact) .PRIMARY_FAILOVER_APPLY_CODE_BEGUN else .PRIMARY_FAILOVER_APPLY_CODE_BINDING_MISMATCH, existing.proto(), current.proto(), volume.proto()) };
        }
        if (!std.mem.eql(u8, current.lease_id, command.current_lease_id) or current.authority_generation != command.current_authority_generation or current.write_epoch != command.current_write_epoch)
            return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_BINDING_MISMATCH, null, current.proto(), volume.proto()) };
        if (volume.resource_version != command.expected_volume_resource_version or current.resource_version != command.expected_current_resource_version)
            return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_VERSION_CONFLICT, null, current.proto(), volume.proto()) };
        if (current.state != .PRIMARY_AUTHORITY_STATE_READY or current.authority_generation == std.math.maxInt(u64) or self.state.primary_authority_candidates_by_volume.contains(command.volume_id) or
            volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE or volume.availability_state != .VOLUME_AVAILABILITY_STATE_HEALTHY or volume.operation_phase != .VOLUME_OPERATION_PHASE_NONE)
            return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_INVALID_STATE, null, current.proto(), volume.proto()) };
        const target_epoch = std.math.add(u64, current.write_epoch, 1) catch return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_INVALID_STATE, null, current.proto(), volume.proto()) };
        const failover_proto: pb.PrimaryFailover = .{
            .failover_id = command.failover_id,
            .volume_id = command.volume_id,
            .revoked_lease_id = command.current_lease_id,
            .revoked_authority_generation = command.current_authority_generation,
            .revoked_write_epoch = command.current_write_epoch,
            .target_write_epoch = target_epoch,
            .state = .PRIMARY_FAILOVER_STATE_WAITING_LEASE,
            .created_revision = revision,
            .resource_version = revision,
        };
        var failover = try PrimaryFailover.init(self.allocator, failover_proto);
        errdefer failover.deinit(self.allocator);
        var response_volume = volume.proto();
        response_volume.availability_state = .VOLUME_AVAILABILITY_STATE_UNAVAILABLE;
        response_volume.operation_phase = .VOLUME_OPERATION_PHASE_FENCING;
        response_volume.resource_version = revision;
        const response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_BEGUN, failover_proto, current.proto(), response_volume);
        errdefer self.allocator.free(response);
        try self.state.primary_failovers_by_volume.ensureUnusedCapacity(self.allocator, 1);
        self.state.primary_failovers_by_volume.putAssumeCapacity(failover.volume_id, failover);
        volume.availability_state = .VOLUME_AVAILABILITY_STATE_UNAVAILABLE;
        volume.operation_phase = .VOLUME_OPERATION_PHASE_FENCING;
        volume.resource_version = revision;
        return .{ .response = response };
    }

    fn applyCompletePrimaryFailoverLeaseWait(self: *PoolStateMachine, revision: u64, command: pb.CompletePrimaryFailoverLeaseWaitCommand) raft.Error!raft.ApplyResult {
        try validateCompletePrimaryFailoverLeaseWaitCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_NOT_FOUND, null, null, null) };
        const current = self.state.primary_authorities_by_volume.get(command.volume_id) orelse return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_NOT_FOUND, null, null, volume.proto()) };
        const failover = self.state.primary_failovers_by_volume.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_NOT_FOUND, null, current.proto(), volume.proto()) };
        if (!std.mem.eql(u8, failover.failover_id, command.failover_id) or !std.mem.eql(u8, failover.revoked_lease_id, command.revoked_lease_id) or
            failover.revoked_authority_generation != command.revoked_authority_generation or failover.revoked_write_epoch != command.revoked_write_epoch or
            !std.mem.eql(u8, current.lease_id, command.revoked_lease_id) or current.authority_generation != command.revoked_authority_generation or current.write_epoch != command.revoked_write_epoch)
            return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_BINDING_MISMATCH, failover.proto(), current.proto(), volume.proto()) };
        if (failover.state == .PRIMARY_FAILOVER_STATE_LEASE_EXPIRED or failover.state == .PRIMARY_FAILOVER_STATE_FENCING)
            return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_LEASE_WAIT_COMPLETED, failover.proto(), current.proto(), volume.proto()) };
        if (volume.resource_version != command.expected_volume_resource_version or failover.resource_version != command.expected_failover_resource_version or current.resource_version != command.expected_current_resource_version)
            return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_VERSION_CONFLICT, failover.proto(), current.proto(), volume.proto()) };
        if (failover.state != .PRIMARY_FAILOVER_STATE_WAITING_LEASE or volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE or
            volume.availability_state != .VOLUME_AVAILABILITY_STATE_UNAVAILABLE or volume.operation_phase != .VOLUME_OPERATION_PHASE_FENCING)
            return .{ .response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_INVALID_STATE, failover.proto(), current.proto(), volume.proto()) };
        var response_failover = failover.proto();
        response_failover.state = .PRIMARY_FAILOVER_STATE_LEASE_EXPIRED;
        response_failover.resource_version = revision;
        var response_volume = volume.proto();
        response_volume.resource_version = revision;
        const response = try encodePrimaryFailoverApplyResponse(self.allocator, .PRIMARY_FAILOVER_APPLY_CODE_LEASE_WAIT_COMPLETED, response_failover, current.proto(), response_volume);
        failover.state = .PRIMARY_FAILOVER_STATE_LEASE_EXPIRED;
        failover.resource_version = revision;
        volume.resource_version = revision;
        return .{ .response = response };
    }

    fn applyCommitPrimaryAuthorityFailoverReady(self: *PoolStateMachine, revision: u64, command: pb.CommitPrimaryAuthorityFailoverReadyCommand) raft.Error!raft.ApplyResult {
        try validateCommitPrimaryAuthorityFailoverReadyCommand(command);
        if (revision == 0) return error.PayloadParseFailed;
        const volume = self.state.volumes_by_id.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, null) };
        const current = self.state.primary_authorities_by_volume.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, null, volume.proto()) };
        const failover = self.state.primary_failovers_by_volume.getPtr(command.volume_id) orelse {
            if (renewalFailoverReadyCommandMatches(current.*, command) and self.state.primary_authority_candidates_by_volume.get(command.volume_id) == null)
                return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_READY, current.proto(), volume.proto()) };
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, current.proto(), volume.proto()) };
        };
        const candidate = self.state.primary_authority_candidates_by_volume.getPtr(command.volume_id) orelse return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, current.proto(), volume.proto()) };
        const recovery = command.recovery_evidence.?;
        if (!std.mem.eql(u8, failover.failover_id, command.failover_id) or !renewalFailoverReadyCommandMatches(candidate.*, command) or !failoverProposalValid(failover.*, current.*, candidate.proto(), volume.*))
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, candidate.proto(), volume.proto()) };
        if (volume.resource_version != command.expected_volume_resource_version or candidate.resource_version != command.expected_candidate_resource_version or
            current.resource_version != command.expected_current_resource_version or failover.resource_version != command.expected_failover_resource_version)
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT, candidate.proto(), volume.proto()) };
        if (failover.state != .PRIMARY_FAILOVER_STATE_FENCING or candidate.state != .PRIMARY_AUTHORITY_STATE_ACTIVATED or
            volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE or volume.availability_state != .VOLUME_AVAILABILITY_STATE_UNAVAILABLE or volume.operation_phase != .VOLUME_OPERATION_PHASE_FENCING)
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, candidate.proto(), volume.proto()) };
        if (!readyEvidenceValid(&self.state, volume.*, candidate.*, command.fence_evidence.items, recovery))
            return .{ .response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_PROOF_INVALID, candidate.proto(), volume.proto()) };

        const recovery_digest = try self.allocator.dupe(u8, recovery.history_digest);
        errdefer self.allocator.free(recovery_digest);
        var response_authority = candidate.proto();
        response_authority.state = .PRIMARY_AUTHORITY_STATE_READY;
        response_authority.ready_revision = revision;
        response_authority.resource_version = revision;
        response_authority.recovery_sequence = recovery.certified_sequence;
        response_authority.recovery_digest = recovery.history_digest;
        response_authority.recovery_empty_frontier = recovery.empty_frontier;
        var response_volume = volume.proto();
        response_volume.availability_state = .VOLUME_AVAILABILITY_STATE_HEALTHY;
        response_volume.operation_phase = .VOLUME_OPERATION_PHASE_NONE;
        response_volume.resource_version = revision;
        const response = try encodePrimaryAuthorityApplyResponse(self.allocator, .PRIMARY_AUTHORITY_APPLY_CODE_READY, response_authority, response_volume);
        errdefer self.allocator.free(response);

        var old = self.state.primary_authorities_by_volume.fetchRemove(command.volume_id).?.value;
        var promoted = self.state.primary_authority_candidates_by_volume.fetchRemove(command.volume_id).?.value;
        var removed_failover = self.state.primary_failovers_by_volume.fetchRemove(command.volume_id).?.value;
        promoted.state = .PRIMARY_AUTHORITY_STATE_READY;
        promoted.ready_revision = revision;
        promoted.resource_version = revision;
        promoted.recovery_sequence = recovery.certified_sequence;
        self.allocator.free(promoted.recovery_digest);
        promoted.recovery_digest = recovery_digest;
        promoted.recovery_empty_frontier = recovery.empty_frontier;
        old.deinit(self.allocator);
        removed_failover.deinit(self.allocator);
        self.state.primary_authorities_by_volume.putAssumeCapacity(promoted.volume_id, promoted);
        volume.availability_state = .VOLUME_AVAILABILITY_STATE_HEALTHY;
        volume.operation_phase = .VOLUME_OPERATION_PHASE_NONE;
        volume.resource_version = revision;
        return .{ .response = response };
    }

    fn applyFinalizeVolumeDeletion(self: *PoolStateMachine, revision: u64, command: pb.FinalizeVolumeDeletionCommand) raft.Error!raft.ApplyResult {
        try validateFinalizeVolumeDeletionCommand(command);
        const volume = self.state.volumes_by_id.get(command.volume_id) orelse return .{ .response = try encodeFinalizeApplyResponse(self.allocator, .FINALIZE_VOLUME_DELETION_APPLY_CODE_NOT_FOUND, "", 0) };
        if (volume.resource_version != command.expected_resource_version) return .{ .response = try encodeFinalizeApplyResponse(self.allocator, .FINALIZE_VOLUME_DELETION_APPLY_CODE_VERSION_CONFLICT, "", 0) };
        if (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_DELETING) return .{ .response = try encodeFinalizeApplyResponse(self.allocator, .FINALIZE_VOLUME_DELETION_APPLY_CODE_INVALID_STATE, "", 0) };
        var attachment_iterator = self.state.volume_attachments_by_id.valueIterator();
        while (attachment_iterator.next()) |attachment| if (std.mem.eql(u8, attachment.volume_id, volume.id)) return .{ .response = try encodeFinalizeApplyResponse(self.allocator, .FINALIZE_VOLUME_DELETION_APPLY_CODE_HAS_ATTACHMENTS, "", 0) };
        if (!deletionProofMatches(&self.state, volume.id, command.placement_ids.items, command.allocation_ids.items)) return .{ .response = try encodeFinalizeApplyResponse(self.allocator, .FINALIZE_VOLUME_DELETION_APPLY_CODE_PROOF_MISMATCH, "", 0) };
        if (self.state.volume_tombstones_by_id.count() >= max_volume_tombstones) return .{ .response = try encodeFinalizeApplyResponse(self.allocator, .FINALIZE_VOLUME_DELETION_APPLY_CODE_TOMBSTONE_LIMIT, "", 0) };
        const response = try encodeFinalizeApplyResponse(self.allocator, .FINALIZE_VOLUME_DELETION_APPLY_CODE_FINALIZED, volume.id, revision);
        errdefer self.allocator.free(response);
        try self.state.volume_tombstones_by_id.ensureUnusedCapacity(self.allocator, 1);
        removeVolumeChildren(self, volume.id);
        self.finalizeVolume(volume.id, command.proposed_deleted_at_unix_ms, revision);
        return .{ .response = response };
    }

    fn finalizeVolume(self: *PoolStateMachine, volume_id: []const u8, deleted_at_unix_ms: i64, revision: u64) void {
        var revision_index: usize = 0;
        while (!std.mem.eql(u8, self.state.volume_ids_by_revision.items[revision_index], volume_id)) : (revision_index += 1) {}
        const removed = self.state.volumes_by_id.fetchRemove(volume_id).?;
        _ = self.state.volume_ids_by_scoped_name.remove(removed.value.scoped_name);
        _ = self.state.volume_ids_by_revision.orderedRemove(revision_index);
        self.state.volume_tombstones_by_id.putAssumeCapacity(removed.value.id, .{ .volume = removed.value, .deleted_at_unix_ms = deleted_at_unix_ms, .deleted_revision = revision });
        self.state.max_volume_deleted_revision = @max(self.state.max_volume_deleted_revision, revision);
    }

    fn applyDeleteVolume(self: *PoolStateMachine, revision: u64, command: pb.DeleteVolumeCommand) raft.Error!raft.ApplyResult {
        try validateDeleteVolumeCommand(command);
        if (revision == 0) return error.PayloadParseFailed;

        const fingerprint = deleteVolumeFingerprint(command);
        if (self.state.requests.get(command.request_id)) |request| {
            if (request.kind != .delete_volume or !std.mem.eql(u8, &fingerprint, &request.fingerprint)) {
                return .{ .response = try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_REQUEST_CONFLICT, "", 0, 0, false, null) };
            }
            return .{ .response = try self.allocator.dupe(u8, request.encoded_response) };
        }
        if (self.state.requests.count() >= max_requests) {
            return .{ .response = try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_REQUEST_LIMIT, "", 0, 0, false, null) };
        }
        const volume = self.state.volumes_by_id.get(command.volume_id) orelse {
            return self.recordDeleteVolumeResponse(command, fingerprint, try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_NOT_FOUND, "", 0, 0, false, null), revision);
        };
        if (volume.resource_version != command.expected_resource_version) {
            return self.recordDeleteVolumeResponse(command, fingerprint, try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_VERSION_CONFLICT, "", 0, 0, false, null), revision);
        }
        if (self.state.volume_tombstones_by_id.count() >= max_volume_tombstones) {
            return self.recordDeleteVolumeResponse(command, fingerprint, try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_TOMBSTONE_LIMIT, "", 0, 0, false, null), revision);
        }

        const has_dependencies = hasVolumeDependencies(&self.state, command.volume_id);
        var accepted_volume = volume.proto();
        if (has_dependencies) {
            accepted_volume.lifecycle_state = .VOLUME_LIFECYCLE_STATE_DELETING;
            accepted_volume.availability_state = .VOLUME_AVAILABILITY_STATE_UNAVAILABLE;
            accepted_volume.operation_phase = .VOLUME_OPERATION_PHASE_NONE;
            accepted_volume.resource_version = revision;
        }
        const code: pb.DeleteVolumeApplyCode = if (has_dependencies) .DELETE_VOLUME_APPLY_CODE_DELETION_ACCEPTED else .DELETE_VOLUME_APPLY_CODE_DELETED;
        const encoded_response = try encodeDeleteVolumeApplyResponse(self.allocator, code, command.volume_id, command.proposed_deleted_at_unix_ms, revision, has_dependencies, if (has_dependencies) accepted_volume else null);
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeDeleteVolumeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        if (!has_dependencies) try self.state.volume_tombstones_by_id.ensureUnusedCapacity(self.allocator, 1);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        if (has_dependencies) {
            const deleting = self.state.volumes_by_id.getPtr(command.volume_id).?;
            if (self.state.primary_authority_candidates_by_volume.fetchRemove(command.volume_id)) |removed_value| {
                var removed = removed_value.value;
                removed.deinit(self.allocator);
            }
            if (self.state.primary_failovers_by_volume.fetchRemove(command.volume_id)) |removed_value| {
                var removed = removed_value.value;
                removed.deinit(self.allocator);
            }
            deleting.lifecycle_state = .VOLUME_LIFECYCLE_STATE_DELETING;
            deleting.availability_state = .VOLUME_AVAILABILITY_STATE_UNAVAILABLE;
            deleting.operation_phase = .VOLUME_OPERATION_PHASE_NONE;
            deleting.resource_version = revision;
        } else self.finalizeVolume(command.volume_id, command.proposed_deleted_at_unix_ms, revision);
        self.state.requests.putAssumeCapacity(request_id, .{ .request_id = request_id, .kind = .delete_volume, .fingerprint = fingerprint, .encoded_response = encoded_response, .encoded_command = encoded_command, .applied_revision = revision });
        return .{ .response = returned_response };
    }

    fn recordDeleteVolumeResponse(self: *PoolStateMachine, command: pb.DeleteVolumeCommand, fingerprint: Fingerprint, encoded_response: []u8, revision: u64) raft.Error!raft.ApplyResult {
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeDeleteVolumeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);
        self.state.requests.putAssumeCapacity(request_id, .{ .request_id = request_id, .kind = .delete_volume, .fingerprint = fingerprint, .encoded_response = encoded_response, .encoded_command = encoded_command, .applied_revision = revision });
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

        var nodes: std.ArrayList(pb.Node) = .empty;
        defer nodes.deinit(allocator);
        try nodes.ensureTotalCapacity(allocator, self.state.nodes_by_id.count());
        var node_iterator = self.state.nodes_by_id.valueIterator();
        while (node_iterator.next()) |node| nodes.appendAssumeCapacity(node.proto());
        std.mem.sort(pb.Node, nodes.items, {}, nodeIdLessThan);

        var members: std.ArrayList(pb.Member) = .empty;
        defer members.deinit(allocator);
        try members.ensureTotalCapacity(allocator, self.state.members_by_id.count());
        var member_iterator = self.state.members_by_id.valueIterator();
        while (member_iterator.next()) |member| members.appendAssumeCapacity(member.proto());
        std.mem.sort(pb.Member, members.items, {}, memberIdLessThan);

        var volumes: std.ArrayList(pb.Volume) = .empty;
        defer volumes.deinit(allocator);
        try volumes.ensureTotalCapacity(allocator, self.state.volumes_by_id.count());
        var volume_iterator = self.state.volumes_by_id.valueIterator();
        while (volume_iterator.next()) |volume| volumes.appendAssumeCapacity(volume.proto());
        std.mem.sort(pb.Volume, volumes.items, {}, volumeIdLessThan);

        var volume_tombstones: std.ArrayList(pb.VolumeTombstone) = .empty;
        defer volume_tombstones.deinit(allocator);
        try volume_tombstones.ensureTotalCapacity(allocator, self.state.volume_tombstones_by_id.count());
        var tombstone_iterator = self.state.volume_tombstones_by_id.valueIterator();
        while (tombstone_iterator.next()) |tombstone| volume_tombstones.appendAssumeCapacity(tombstone.proto());
        std.mem.sort(pb.VolumeTombstone, volume_tombstones.items, {}, volumeTombstoneIdLessThan);

        var replica_placements: std.ArrayList(pb.ReplicaPlacement) = .empty;
        defer replica_placements.deinit(allocator);
        try replica_placements.ensureTotalCapacity(allocator, self.state.replica_placements_by_id.count());
        var replica_iterator = self.state.replica_placements_by_id.valueIterator();
        while (replica_iterator.next()) |replica| replica_placements.appendAssumeCapacity(replica.proto());
        std.mem.sort(pb.ReplicaPlacement, replica_placements.items, {}, replicaPlacementIdLessThan);

        var replica_allocations: std.ArrayList(pb.ReplicaAllocation) = .empty;
        defer replica_allocations.deinit(allocator);
        try replica_allocations.ensureTotalCapacity(allocator, self.state.replica_allocations_by_id.count());
        var allocation_iterator = self.state.replica_allocations_by_id.valueIterator();
        while (allocation_iterator.next()) |allocation| replica_allocations.appendAssumeCapacity(allocation.proto());
        std.mem.sort(pb.ReplicaAllocation, replica_allocations.items, {}, replicaAllocationIdLessThan);

        var volume_attachments: std.ArrayList(pb.VolumeAttachment) = .empty;
        defer volume_attachments.deinit(allocator);
        try volume_attachments.ensureTotalCapacity(allocator, self.state.volume_attachments_by_id.count());
        var attachment_iterator = self.state.volume_attachments_by_id.valueIterator();
        while (attachment_iterator.next()) |attachment| volume_attachments.appendAssumeCapacity(attachment.proto());
        std.mem.sort(pb.VolumeAttachment, volume_attachments.items, {}, volumeAttachmentIdLessThan);

        var primary_authorities: std.ArrayList(pb.PrimaryAuthority) = .empty;
        defer primary_authorities.deinit(allocator);
        try primary_authorities.ensureTotalCapacity(allocator, self.state.primary_authorities_by_volume.count());
        var authority_iterator = self.state.primary_authorities_by_volume.valueIterator();
        while (authority_iterator.next()) |authority| primary_authorities.appendAssumeCapacity(authority.proto());
        std.mem.sort(pb.PrimaryAuthority, primary_authorities.items, {}, primaryAuthorityVolumeIdLessThan);

        var primary_authority_candidates: std.ArrayList(pb.PrimaryAuthority) = .empty;
        defer primary_authority_candidates.deinit(allocator);
        try primary_authority_candidates.ensureTotalCapacity(allocator, self.state.primary_authority_candidates_by_volume.count());
        var candidate_iterator = self.state.primary_authority_candidates_by_volume.valueIterator();
        while (candidate_iterator.next()) |authority| primary_authority_candidates.appendAssumeCapacity(authority.proto());
        std.mem.sort(pb.PrimaryAuthority, primary_authority_candidates.items, {}, primaryAuthorityVolumeIdLessThan);

        var primary_failovers: std.ArrayList(pb.PrimaryFailover) = .empty;
        defer primary_failovers.deinit(allocator);
        try primary_failovers.ensureTotalCapacity(allocator, self.state.primary_failovers_by_volume.count());
        var failover_iterator = self.state.primary_failovers_by_volume.valueIterator();
        while (failover_iterator.next()) |failover| primary_failovers.appendAssumeCapacity(failover.proto());
        std.mem.sort(pb.PrimaryFailover, primary_failovers.items, {}, primaryFailoverVolumeIdLessThan);

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
            .nodes = nodes,
            .members = members,
            .volumes = volumes,
            .volume_tombstones = volume_tombstones,
            .replica_placements = replica_placements,
            .replica_allocations = replica_allocations,
            .volume_attachments = volume_attachments,
            .primary_authorities = primary_authorities,
            .primary_authority_candidates = primary_authority_candidates,
            .primary_failovers = primary_failovers,
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
        if (snapshot.format_version < 2 or snapshot.format_version > snapshot_format_version) return error.PayloadParseFailed;
        if (snapshot.pools.items.len > max_pools or
            snapshot.nodes.items.len > max_nodes or
            snapshot.members.items.len > max_members or
            snapshot.volumes.items.len > max_volumes or
            snapshot.volume_tombstones.items.len > max_volume_tombstones or
            snapshot.replica_placements.items.len > max_replica_placements or
            snapshot.replica_allocations.items.len > max_replica_allocations or
            snapshot.volume_attachments.items.len > max_volume_attachments or
            snapshot.primary_authorities.items.len > max_primary_authorities or
            snapshot.primary_authority_candidates.items.len > max_primary_authorities or
            snapshot.primary_failovers.items.len > max_primary_authorities or
            snapshot.requests.items.len > max_requests or
            (snapshot.format_version == 2 and snapshot.nodes.items.len != 0) or
            (snapshot.format_version < 4 and snapshot.members.items.len != 0) or
            (snapshot.format_version < 5 and (snapshot.volumes.items.len != 0 or snapshot.volume_tombstones.items.len != 0 or snapshot.replica_placements.items.len != 0 or snapshot.replica_allocations.items.len != 0 or snapshot.volume_attachments.items.len != 0)))
        {
            return error.PayloadParseFailed;
        }

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
        for (snapshot.nodes.items) |source| {
            if (source.registered_revision > metadata.index or revisions.contains(source.registered_revision)) return error.PayloadParseFailed;
            try revisions.put(self.allocator, source.registered_revision, {});
            try restoreNode(self.allocator, &restored, source);
        }
        std.mem.sort([]const u8, restored.node_ids_by_revision.items, &restored, nodeRevisionIdLessThan);
        for (snapshot.members.items) |source| {
            if (source.registered_revision > metadata.index or revisions.contains(source.registered_revision)) return error.PayloadParseFailed;
            try revisions.put(self.allocator, source.registered_revision, {});
            try restoreMember(self.allocator, &restored, source);
        }
        std.mem.sort([]const u8, restored.member_ids_by_revision.items, &restored, memberRevisionIdLessThan);
        for (snapshot.volumes.items) |source| {
            if (source.created_revision > metadata.index or source.resource_version > metadata.index or revisions.contains(source.created_revision)) return error.PayloadParseFailed;
            try revisions.put(self.allocator, source.created_revision, {});
            try restoreVolume(self.allocator, &restored, source);
        }
        std.mem.sort([]const u8, restored.volume_ids_by_revision.items, &restored, volumeRevisionIdLessThan);
        for (snapshot.volume_tombstones.items) |source| {
            const source_volume = source.volume orelse return error.PayloadParseFailed;
            if (source_volume.created_revision > metadata.index or revisions.contains(source_volume.created_revision)) return error.PayloadParseFailed;
            try revisions.put(self.allocator, source_volume.created_revision, {});
            try restoreVolumeTombstone(self.allocator, &restored, source, metadata.index);
        }
        for (snapshot.replica_placements.items) |source| {
            try restoreReplicaPlacement(self.allocator, &restored, source, metadata.index, snapshot.format_version);
        }
        for (snapshot.replica_allocations.items) |source| {
            try restoreReplicaAllocation(self.allocator, &restored, source, metadata.index, snapshot.format_version);
        }
        if (snapshot.format_version >= 6) {
            if (restored.replica_placements_by_id.count() != restored.allocation_ids_by_replica.count()) return error.PayloadParseFailed;
            var restored_placement_iterator = restored.replica_placements_by_id.keyIterator();
            while (restored_placement_iterator.next()) |placement_id| {
                if (!restored.allocation_ids_by_replica.contains(placement_id.*)) return error.PayloadParseFailed;
            }
        }
        for (snapshot.volume_attachments.items) |source| {
            try restoreVolumeAttachment(self.allocator, &restored, source, metadata.index);
        }
        if (snapshot.format_version >= 9) {
            if (snapshot.format_version < 11 and snapshot.primary_failovers.items.len != 0) return error.PayloadParseFailed;
            for (snapshot.primary_failovers.items) |source| try restorePrimaryFailover(self.allocator, &restored, source, metadata.index);
            for (snapshot.primary_authorities.items) |source| {
                if (snapshot.format_version >= 10 and source.state != .PRIMARY_AUTHORITY_STATE_READY) return error.PayloadParseFailed;
                try restorePrimaryAuthority(self.allocator, &restored, source, metadata.index, source.state != .PRIMARY_AUTHORITY_STATE_READY);
            }
            if (snapshot.format_version < 10 and snapshot.primary_authority_candidates.items.len != 0) return error.PayloadParseFailed;
            for (snapshot.primary_authority_candidates.items) |source| {
                if (source.state == .PRIMARY_AUTHORITY_STATE_READY) return error.PayloadParseFailed;
                try restorePrimaryAuthority(self.allocator, &restored, source, metadata.index, true);
            }
            try validateAuthorityVolumeInvariants(&restored);
        } else {
            if (snapshot.primary_authorities.items.len != 0) return error.PayloadParseFailed;
            var legacy_volume_iterator = restored.volumes_by_id.valueIterator();
            while (legacy_volume_iterator.next()) |volume| {
                if (volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_ACTIVE) {
                    volume.lifecycle_state = .VOLUME_LIFECYCLE_STATE_PROVISIONING;
                    volume.availability_state = .VOLUME_AVAILABILITY_STATE_UNKNOWN;
                    volume.operation_phase = .VOLUME_OPERATION_PHASE_FENCING;
                }
            }
        }

        var created_pool_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer created_pool_ids.deinit(self.allocator);
        var registered_node_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer registered_node_ids.deinit(self.allocator);
        var registered_member_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer registered_member_ids.deinit(self.allocator);
        var created_volume_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer created_volume_ids.deinit(self.allocator);
        var deleted_volume_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer deleted_volume_ids.deinit(self.allocator);
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
            if (try restoreRequest(self.allocator, arena.allocator(), &restored, source, snapshot.format_version)) |creation| {
                switch (creation) {
                    .pool => |id| {
                        if (created_pool_ids.contains(id)) return error.PayloadParseFailed;
                        try created_pool_ids.put(self.allocator, id, {});
                    },
                    .node => |id| {
                        if (registered_node_ids.contains(id)) return error.PayloadParseFailed;
                        try registered_node_ids.put(self.allocator, id, {});
                    },
                    .member => |id| {
                        if (registered_member_ids.contains(id)) return error.PayloadParseFailed;
                        try registered_member_ids.put(self.allocator, id, {});
                    },
                    .volume => |id| {
                        if (created_volume_ids.contains(id)) return error.PayloadParseFailed;
                        try created_volume_ids.put(self.allocator, id, {});
                    },
                    .volume_deleted => |id| {
                        if (deleted_volume_ids.contains(id)) return error.PayloadParseFailed;
                        try deleted_volume_ids.put(self.allocator, id, {});
                    },
                }
            }
        }
        var request_backed_tombstone_count: usize = 0;
        var restored_tombstone_iterator = restored.volume_tombstones_by_id.valueIterator();
        while (restored_tombstone_iterator.next()) |tombstone| if (tombstone.volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_DELETING) {
            request_backed_tombstone_count += 1;
        };
        if (created_pool_ids.count() != restored.pools_by_id.count() or
            registered_node_ids.count() != restored.nodes_by_id.count() or
            registered_member_ids.count() != restored.members_by_id.count() or
            created_volume_ids.count() != restored.volumes_by_id.count() + restored.volume_tombstones_by_id.count() or
            deleted_volume_ids.count() != request_backed_tombstone_count)
        {
            return error.PayloadParseFailed;
        }
        self.state.deinit(self.allocator);
        self.state = restored;
        if (self.heartbeat_store) |store| store.clearObservations();
    }

    fn onLeadershipChange(ctx: *anyopaque, is_leader: bool, term: u64, _: u64) void {
        const self: *PoolStateMachine = @ptrCast(@alignCast(ctx));
        if (self.heartbeat_store) |store| store.onLeadershipChange(is_leader, term);
    }

    const vtable: raft.StateMachine.VTable = .{
        .apply = apply,
        .take_snapshot = takeSnapshot,
        .restore_snapshot = restoreSnapshot,
        .on_leadership_change = onLeadershipChange,
    };
};

pub fn encodeCreatePoolCommand(allocator: std.mem.Allocator, command: pb.CreatePoolCommand) ![]u8 {
    try validateCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{
        .format_version = command_format_version,
        .command = .{ .create_pool = command },
    });
}

pub fn encodeRegisterNodeCommand(allocator: std.mem.Allocator, command: pb.RegisterNodeCommand) ![]u8 {
    try validateRegisterNodeCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{
        .format_version = command_format_version,
        .command = .{ .register_node = command },
    });
}

pub fn encodeRegisterMemberCommand(allocator: std.mem.Allocator, command: pb.RegisterMemberCommand) ![]u8 {
    try validateRegisterMemberCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{
        .format_version = command_format_version,
        .command = .{ .register_member = command },
    });
}

pub fn encodeCreateVolumeCommand(allocator: std.mem.Allocator, command: pb.CreateVolumeCommand) ![]u8 {
    try validateCreateVolumeCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{
        .format_version = command_format_version,
        .command = .{ .create_volume = command },
    });
}

pub fn encodeDeleteVolumeCommand(allocator: std.mem.Allocator, command: pb.DeleteVolumeCommand) ![]u8 {
    try validateDeleteVolumeCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{
        .format_version = command_format_version,
        .command = .{ .delete_volume = command },
    });
}

pub fn encodeUpdateVolumeCommand(allocator: std.mem.Allocator, command: pb.UpdateVolumeCommand) ![]u8 {
    try validateUpdateVolumeCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .update_volume = command } });
}

pub fn encodeReserveVolumeResourcesCommand(allocator: std.mem.Allocator, command: pb.ReserveVolumeResourcesCommand) ![]u8 {
    try validateReserveVolumeResourcesCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .reserve_volume_resources = command } });
}

pub fn encodeActivateReplicaCommand(allocator: std.mem.Allocator, command: pb.ActivateReplicaCommand) ![]u8 {
    try validateActivateReplicaCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .activate_replica = command } });
}

pub fn encodeFinalizeVolumeDeletionCommand(allocator: std.mem.Allocator, command: pb.FinalizeVolumeDeletionCommand) ![]u8 {
    try validateFinalizeVolumeDeletionCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .finalize_volume_deletion = command } });
}

pub fn encodeProposePrimaryAuthorityCommand(allocator: std.mem.Allocator, command: pb.ProposePrimaryAuthorityCommand) ![]u8 {
    try validateProposePrimaryAuthorityCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .propose_primary_authority = command } });
}

pub fn encodeActivatePrimaryAuthorityCommand(allocator: std.mem.Allocator, command: pb.ActivatePrimaryAuthorityCommand) ![]u8 {
    try validateActivatePrimaryAuthorityCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .activate_primary_authority = command } });
}

pub fn encodeCommitPrimaryAuthorityReadyCommand(allocator: std.mem.Allocator, command: pb.CommitPrimaryAuthorityReadyCommand) ![]u8 {
    try validateCommitPrimaryAuthorityReadyCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .commit_primary_authority_ready = command } });
}

pub fn encodeCommitPrimaryAuthorityRenewalReadyCommand(allocator: std.mem.Allocator, command: pb.CommitPrimaryAuthorityRenewalReadyCommand) ![]u8 {
    try validateCommitPrimaryAuthorityRenewalReadyCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .commit_primary_authority_renewal_ready = command } });
}

pub fn encodeAbortPrimaryAuthorityCandidateCommand(allocator: std.mem.Allocator, command: pb.AbortPrimaryAuthorityCandidateCommand) ![]u8 {
    try validateAbortPrimaryAuthorityCandidateCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .abort_primary_authority_candidate = command } });
}

pub fn encodeBeginPrimaryFailoverCommand(allocator: std.mem.Allocator, command: pb.BeginPrimaryFailoverCommand) ![]u8 {
    try validateBeginPrimaryFailoverCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .begin_primary_failover = command } });
}

pub fn encodeCommitPrimaryAuthorityFailoverReadyCommand(allocator: std.mem.Allocator, command: pb.CommitPrimaryAuthorityFailoverReadyCommand) ![]u8 {
    try validateCommitPrimaryAuthorityFailoverReadyCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .commit_primary_authority_failover_ready = command } });
}

pub fn encodeCompletePrimaryFailoverLeaseWaitCommand(allocator: std.mem.Allocator, command: pb.CompletePrimaryFailoverLeaseWaitCommand) ![]u8 {
    try validateCompletePrimaryFailoverLeaseWaitCommand(command);
    return encodeMessage(allocator, pb.CommandEnvelope{ .format_version = command_format_version, .command = .{ .complete_primary_failover_lease_wait = command } });
}

pub fn decodeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.ApplyResponse {
    return codec.decodeApplyResponse(allocator, bytes);
}

pub fn decodeRegisterNodeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.RegisterNodeApplyResponse {
    return codec.decodeRegisterNodeApplyResponse(allocator, bytes);
}

pub fn decodeRegisterMemberApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.RegisterMemberApplyResponse {
    return codec.decodeRegisterMemberApplyResponse(allocator, bytes);
}

pub fn decodeCreateVolumeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.CreateVolumeApplyResponse {
    return codec.decodeCreateVolumeApplyResponse(allocator, bytes);
}

pub fn decodeDeleteVolumeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.DeleteVolumeApplyResponse {
    return codec.decodeDeleteVolumeApplyResponse(allocator, bytes);
}

pub fn decodeUpdateVolumeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.UpdateVolumeApplyResponse {
    return codec.decodeUpdateVolumeApplyResponse(allocator, bytes);
}

pub fn decodeReserveVolumeResourcesApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.ReserveVolumeResourcesApplyResponse {
    return codec.decodeReserveVolumeResourcesApplyResponse(allocator, bytes);
}

pub fn decodeActivateReplicaApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.ActivateReplicaApplyResponse {
    return codec.decodeActivateReplicaApplyResponse(allocator, bytes);
}

pub fn decodeFinalizeVolumeDeletionApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.FinalizeVolumeDeletionApplyResponse {
    return codec.decodeFinalizeVolumeDeletionApplyResponse(allocator, bytes);
}

pub fn decodePrimaryAuthorityApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.PrimaryAuthorityApplyResponse {
    return codec.decodePrimaryAuthorityApplyResponse(allocator, bytes);
}

pub fn decodePrimaryFailoverApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.PrimaryFailoverApplyResponse {
    return codec.decodePrimaryFailoverApplyResponse(allocator, bytes);
}

pub fn deinitPoolList(allocator: std.mem.Allocator, pools: []pb.Pool) void {
    codec.deinitPoolList(allocator, pools);
}

pub fn deinitNodeList(allocator: std.mem.Allocator, nodes: []pb.Node) void {
    codec.deinitNodeList(allocator, nodes);
}

pub fn deinitMemberList(allocator: std.mem.Allocator, members: []pb.Member) void {
    codec.deinitMemberList(allocator, members);
}

pub fn deinitVolumeList(allocator: std.mem.Allocator, volumes: []pb.Volume) void {
    codec.deinitVolumeList(allocator, volumes);
}

pub fn deinitReplicaReservations(allocator: std.mem.Allocator, reservations: []pb.ReplicaReservation) void {
    codec.deinitReplicaReservations(allocator, reservations);
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

fn validateRegisterNodeCommand(command: pb.RegisterNodeCommand) raft.Error!void {
    if (!validText(command.request_id, max_request_id_bytes, false)) return error.PayloadParseFailed;
    if (!validUuidV7(command.node_id)) return error.PayloadParseFailed;
    if (!validClusterId(command.cluster_id)) return error.PayloadParseFailed;
    if (!validText(command.control_endpoint, max_node_endpoint_bytes, false)) return error.PayloadParseFailed;
    if (!validText(command.nvmf_endpoint, max_node_endpoint_bytes, false)) return error.PayloadParseFailed;
    if (!validText(command.failure_domain, max_failure_domain_bytes, false)) return error.PayloadParseFailed;
    if (command.protocol_version == 0 or command.proposed_registered_at_unix_ms <= 0) return error.PayloadParseFailed;
}

fn validateNode(node: pb.Node) raft.Error!void {
    if (!validUuidV7(node.id)) return error.PayloadParseFailed;
    if (!validClusterId(node.cluster_id)) return error.PayloadParseFailed;
    if (!validText(node.control_endpoint, max_node_endpoint_bytes, false)) return error.PayloadParseFailed;
    if (!validText(node.nvmf_endpoint, max_node_endpoint_bytes, false)) return error.PayloadParseFailed;
    if (!validText(node.failure_domain, max_failure_domain_bytes, false)) return error.PayloadParseFailed;
    if (node.protocol_version == 0 or node.registered_at_unix_ms <= 0 or node.registered_revision == 0) return error.PayloadParseFailed;
}

fn validateRegisterMemberCommand(command: pb.RegisterMemberCommand) raft.Error!void {
    if (!validText(command.request_id, max_request_id_bytes, false)) return error.PayloadParseFailed;
    if (!validClusterId(command.cluster_id)) return error.PayloadParseFailed;
    if (!validFixedNonzero(command.member_id, 16)) return error.PayloadParseFailed;
    if (!validUuidV7(command.pool_id) or !validUuidV7(command.node_id)) return error.PayloadParseFailed;
    if (!validFixedNonzero(command.local_set_id, 16) or std.mem.eql(u8, command.member_id, command.local_set_id)) return error.PayloadParseFailed;
    if (command.member_slot > std.math.maxInt(u16)) return error.PayloadParseFailed;
    if (!validFixedNonzero(command.birth_topology_digest, 32)) return error.PayloadParseFailed;
    if (command.metadata_capacity_bytes == 0 or command.data_capacity_bytes == 0 or command.extent_size_bytes == 0) return error.PayloadParseFailed;
    if (command.proposed_registered_at_unix_ms <= 0) return error.PayloadParseFailed;
}

fn validateMember(member: pb.Member) raft.Error!void {
    if (!validFixedNonzero(member.id, 16)) return error.PayloadParseFailed;
    if (!validUuidV7(member.pool_id) or !validUuidV7(member.node_id)) return error.PayloadParseFailed;
    if (!validFixedNonzero(member.local_set_id, 16) or std.mem.eql(u8, member.id, member.local_set_id)) return error.PayloadParseFailed;
    if (member.member_slot > std.math.maxInt(u16)) return error.PayloadParseFailed;
    if (!validFixedNonzero(member.birth_topology_digest, 32)) return error.PayloadParseFailed;
    if (member.metadata_capacity_bytes == 0 or member.data_capacity_bytes == 0 or member.extent_size_bytes == 0) return error.PayloadParseFailed;
    if (member.registered_at_unix_ms <= 0 or member.registered_revision == 0) return error.PayloadParseFailed;
}

fn validateCreateVolumeCommand(command: pb.CreateVolumeCommand) raft.Error!void {
    if (!validText(command.request_id, max_request_id_bytes, false)) return error.PayloadParseFailed;
    if (!validUuidV7(command.proposed_volume_id) or !validUuidV7(command.pool_id)) return error.PayloadParseFailed;
    if (!validText(command.name, max_name_bytes, false)) return error.PayloadParseFailed;
    if (!validText(command.description, max_description_bytes, true)) return error.PayloadParseFailed;
    if (!validVolumeSize(command.size_bytes) or command.proposed_created_at_unix_ms <= 0) return error.PayloadParseFailed;
}

fn validateDeleteVolumeCommand(command: pb.DeleteVolumeCommand) raft.Error!void {
    if (!validText(command.request_id, max_request_id_bytes, false)) return error.PayloadParseFailed;
    if (!validUuidV7(command.volume_id) or command.expected_resource_version == 0 or command.proposed_deleted_at_unix_ms <= 0) return error.PayloadParseFailed;
}

fn validateUpdateVolumeCommand(command: pb.UpdateVolumeCommand) raft.Error!void {
    if (!validText(command.request_id, max_request_id_bytes, false) or !validUuidV7(command.volume_id) or
        !validText(command.description, max_description_bytes, true) or command.expected_resource_version == 0) return error.PayloadParseFailed;
}

fn validateReserveVolumeResourcesCommand(command: pb.ReserveVolumeResourcesCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or command.expected_resource_version == 0 or command.reservations.items.len != volume_target_replica_count) return error.PayloadParseFailed;
    for (command.reservations.items) |reservation| {
        const placement = reservation.placement orelse return error.PayloadParseFailed;
        const allocation = reservation.allocation orelse return error.PayloadParseFailed;
        if (!validUuidV7(placement.id) or !std.mem.eql(u8, placement.volume_id, command.volume_id) or !validUuidV7(placement.node_id) or
            placement.replica_index >= volume_target_replica_count or placement.generation == 0 or
            placement.state != .REPLICA_PLACEMENT_STATE_RESERVED or placement.created_revision != 0 or placement.resource_version != 0 or placement.backend_digest.len != 0 or placement.attested_revision != 0 or
            !validUuidV7(allocation.id) or !std.mem.eql(u8, allocation.replica_id, placement.id) or !validFixedNonzero(allocation.member_id, 16) or
            allocation.length_bytes == 0 or allocation.generation != placement.generation or allocation.state != .REPLICA_ALLOCATION_STATE_RESERVED or
            allocation.created_revision != 0 or allocation.resource_version != 0) return error.PayloadParseFailed;
    }
}

fn validateActivateReplicaCommand(command: pb.ActivateReplicaCommand) raft.Error!void {
    try validateLegacyActivateReplicaCommand(command);
    const attestation = command.attestation orelse return error.PayloadParseFailed;
    if (!validUuidV7(attestation.volume_id) or !validUuidV7(attestation.placement_id) or !validUuidV7(attestation.allocation_id) or
        attestation.generation == 0 or !validFixedNonzero(attestation.member_id, 16) or attestation.length_bytes == 0 or
        !validFixedNonzero(attestation.backend_digest, 32)) return error.PayloadParseFailed;
    _ = std.math.add(u64, attestation.offset_bytes, attestation.length_bytes) catch return error.PayloadParseFailed;
}

fn validateLegacyActivateReplicaCommand(command: pb.ActivateReplicaCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or !validUuidV7(command.placement_id) or !validUuidV7(command.allocation_id) or
        command.expected_volume_resource_version == 0 or command.expected_placement_resource_version == 0 or command.expected_allocation_resource_version == 0) return error.PayloadParseFailed;
}

fn validateFinalizeVolumeDeletionCommand(command: pb.FinalizeVolumeDeletionCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or command.expected_resource_version == 0 or command.proposed_deleted_at_unix_ms <= 0 or
        command.placement_ids.items.len > volume_target_replica_count or command.allocation_ids.items.len > volume_target_replica_count) return error.PayloadParseFailed;
    for (command.placement_ids.items) |id| if (!validUuidV7(id)) return error.PayloadParseFailed;
    for (command.allocation_ids.items) |id| if (!validUuidV7(id)) return error.PayloadParseFailed;
}

fn validateProposePrimaryAuthorityCommand(command: pb.ProposePrimaryAuthorityCommand) raft.Error!void {
    const authority = command.authority orelse return error.PayloadParseFailed;
    if (command.expected_volume_resource_version == 0 or !validUuidV7(authority.volume_id) or
        !validUuidV7(authority.primary_placement_id) or !validUuidV7(authority.primary_node_id) or
        !validFixedNonzero(authority.lease_id, 16) or !validFixedNonzero(authority.holder_boot_id, 16) or
        authority.authority_generation == 0 or authority.write_epoch == 0 or authority.placement_revision == 0 or
        !validFixedNonzero(authority.activation_nonce, 16) or authority.lease_duration_ms != primary_lease.duration_ms or
        authority.state != .PRIMARY_AUTHORITY_STATE_PENDING or !validFixedNonzero(authority.authority_digest, 32) or
        authority.created_revision != 0 or authority.activated_revision != 0 or authority.ready_revision != 0 or
        authority.resource_version != 0 or authority.recovery_sequence != 0 or authority.recovery_digest.len != 0 or authority.recovery_empty_frontier)
    {
        return error.PayloadParseFailed;
    }
    if ((command.failover_id.len == 0) != (command.expected_failover_resource_version == 0) or
        (command.failover_id.len != 0 and !validUuidV7Bytes(command.failover_id))) return error.PayloadParseFailed;
}

fn validateActivatePrimaryAuthorityCommand(command: pb.ActivatePrimaryAuthorityCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or !validFixedNonzero(command.lease_id, 16) or
        !validFixedNonzero(command.activation_nonce, 16) or command.authority_generation == 0 or
        command.write_epoch == 0 or command.placement_revision == 0 or
        command.expected_volume_resource_version == 0 or command.expected_authority_resource_version == 0)
    {
        return error.PayloadParseFailed;
    }
}

fn validateCommitPrimaryAuthorityReadyCommand(command: pb.CommitPrimaryAuthorityReadyCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or !validFixedNonzero(command.lease_id, 16) or command.authority_digest.len != 32 or
        command.authority_generation == 0 or command.write_epoch == 0 or command.placement_revision == 0 or
        command.expected_volume_resource_version == 0 or command.expected_authority_resource_version == 0 or
        command.fence_evidence.items.len != volume_target_replica_count)
    {
        return error.PayloadParseFailed;
    }
    for (command.fence_evidence.items) |evidence| {
        if (!validUuidV7(evidence.placement_id) or evidence.replica_generation == 0 or evidence.write_epoch == 0 or
            !validFixedNonzero(evidence.lease_id, 16) or !validFixedNonzero(evidence.authority_digest, 32) or !validFixedNonzero(evidence.fence_digest, 32))
        {
            return error.PayloadParseFailed;
        }
    }
    const recovery = command.recovery_evidence orelse return error.PayloadParseFailed;
    if (!validUuidV7(recovery.volume_id) or recovery.write_epoch == 0 or !validFixedNonzero(recovery.history_digest, 32) or
        (recovery.certified_sequence == 0) != recovery.empty_frontier)
    {
        return error.PayloadParseFailed;
    }
}

fn validateCommitPrimaryAuthorityRenewalReadyCommand(command: pb.CommitPrimaryAuthorityRenewalReadyCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or !validFixedNonzero(command.lease_id, 16) or
        command.authority_generation == 0 or command.write_epoch == 0 or command.placement_revision == 0 or
        command.expected_volume_resource_version == 0 or command.expected_candidate_resource_version == 0 or
        command.expected_current_resource_version == 0)
    {
        return error.PayloadParseFailed;
    }
}

fn validateAbortPrimaryAuthorityCandidateCommand(command: pb.AbortPrimaryAuthorityCandidateCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or !validFixedNonzero(command.lease_id, 16) or
        command.authority_generation == 0 or command.expected_volume_resource_version == 0 or
        command.expected_candidate_resource_version == 0)
    {
        return error.PayloadParseFailed;
    }
}

fn validateBeginPrimaryFailoverCommand(command: pb.BeginPrimaryFailoverCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or !validFixedNonzero(command.current_lease_id, 16) or
        command.current_authority_generation == 0 or command.current_write_epoch == 0 or !validUuidV7Bytes(command.failover_id) or
        command.expected_volume_resource_version == 0 or command.expected_current_resource_version == 0) return error.PayloadParseFailed;
}

fn validateCompletePrimaryFailoverLeaseWaitCommand(command: pb.CompletePrimaryFailoverLeaseWaitCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or !validUuidV7Bytes(command.failover_id) or !validFixedNonzero(command.revoked_lease_id, 16) or
        command.revoked_authority_generation == 0 or command.revoked_write_epoch == 0 or command.expected_volume_resource_version == 0 or
        command.expected_failover_resource_version == 0 or command.expected_current_resource_version == 0) return error.PayloadParseFailed;
}

fn validateCommitPrimaryAuthorityFailoverReadyCommand(command: pb.CommitPrimaryAuthorityFailoverReadyCommand) raft.Error!void {
    if (!validUuidV7(command.volume_id) or !validUuidV7Bytes(command.failover_id) or !validFixedNonzero(command.lease_id, 16) or
        !validFixedNonzero(command.authority_digest, 32) or command.authority_generation == 0 or command.write_epoch == 0 or
        command.placement_revision == 0 or command.expected_volume_resource_version == 0 or command.expected_candidate_resource_version == 0 or
        command.expected_current_resource_version == 0 or command.expected_failover_resource_version == 0 or
        command.fence_evidence.items.len != volume_target_replica_count) return error.PayloadParseFailed;
    for (command.fence_evidence.items) |evidence| {
        if (!validUuidV7(evidence.placement_id) or evidence.replica_generation == 0 or evidence.write_epoch == 0 or
            !validFixedNonzero(evidence.lease_id, 16) or !validFixedNonzero(evidence.authority_digest, 32) or !validFixedNonzero(evidence.fence_digest, 32)) return error.PayloadParseFailed;
    }
    const recovery = command.recovery_evidence orelse return error.PayloadParseFailed;
    if (!validUuidV7(recovery.volume_id) or recovery.write_epoch == 0 or !validFixedNonzero(recovery.history_digest, 32) or
        (recovery.certified_sequence == 0) != recovery.empty_frontier) return error.PayloadParseFailed;
}

fn validateVolume(volume: pb.Volume) raft.Error!void {
    if (!validUuidV7(volume.id) or !validUuidV7(volume.pool_id)) return error.PayloadParseFailed;
    if (!validText(volume.name, max_name_bytes, false) or !validText(volume.description, max_description_bytes, true)) return error.PayloadParseFailed;
    if (!validVolumeSize(volume.size_bytes) or
        volume.protection_kind != .VOLUME_PROTECTION_KIND_REPLICATED or
        volume.target_replica_count != volume_target_replica_count or
        volume.write_quorum != volume_write_quorum or
        volume.read_quorum != volume_read_quorum or
        !validVolumeLifecycleState(volume.lifecycle_state) or
        !validVolumeAvailabilityState(volume.availability_state) or
        !validVolumeOperationPhase(volume.operation_phase) or
        volume.generation == 0 or volume.write_epoch == 0 or
        volume.created_at_unix_ms <= 0 or volume.created_revision == 0 or
        volume.resource_version < volume.created_revision or
        volume.placement_revision > volume.resource_version)
    {
        return error.PayloadParseFailed;
    }
}

fn validVolumeLifecycleState(value: pb.VolumeLifecycleState) bool {
    return value != .VOLUME_LIFECYCLE_STATE_UNSPECIFIED;
}

fn validVolumeAvailabilityState(value: pb.VolumeAvailabilityState) bool {
    return value != .VOLUME_AVAILABILITY_STATE_UNSPECIFIED;
}

fn validVolumeOperationPhase(value: pb.VolumeOperationPhase) bool {
    return value != .VOLUME_OPERATION_PHASE_UNSPECIFIED;
}

fn requestFingerprint(command: pb.CreatePoolCommand) Fingerprint {
    return semanticFingerprint(command.name, command.description);
}

fn registerNodeFingerprint(command: pb.RegisterNodeCommand) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, command.node_id);
    hashField(&hasher, command.cluster_id);
    hashField(&hasher, command.control_endpoint);
    hashField(&hasher, command.nvmf_endpoint);
    hashField(&hasher, command.failure_domain);
    hashInt(&hasher, u64, command.capability_bits);
    hashInt(&hasher, u32, command.protocol_version);
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
}

fn registerMemberFingerprint(command: pb.RegisterMemberCommand) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, command.cluster_id);
    hashField(&hasher, command.member_id);
    hashField(&hasher, command.pool_id);
    hashField(&hasher, command.node_id);
    hashField(&hasher, command.local_set_id);
    hashInt(&hasher, u32, command.member_slot);
    hashField(&hasher, command.birth_topology_digest);
    hashInt(&hasher, u64, command.metadata_capacity_bytes);
    hashInt(&hasher, u64, command.data_capacity_bytes);
    hashInt(&hasher, u32, command.extent_size_bytes);
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
}

fn createVolumeFingerprint(command: pb.CreateVolumeCommand) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, command.pool_id);
    hashField(&hasher, command.name);
    hashField(&hasher, command.description);
    hashInt(&hasher, u64, command.size_bytes);
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
}

fn deleteVolumeFingerprint(command: pb.DeleteVolumeCommand) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, command.volume_id);
    hashInt(&hasher, u64, command.expected_resource_version);
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
}

fn updateVolumeFingerprint(command: pb.UpdateVolumeCommand) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, command.volume_id);
    hashField(&hasher, command.description);
    hashInt(&hasher, u64, command.expected_resource_version);
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
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

fn hashInt(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    hashField(hasher, &encoded);
}

fn encodeApplyResponse(allocator: std.mem.Allocator, code: pb.ApplyCode, pool: ?pb.Pool) raft.Error![]u8 {
    return encodeMessage(allocator, pb.ApplyResponse{ .code = code, .pool = pool });
}

fn encodeRegisterNodeApplyResponse(
    allocator: std.mem.Allocator,
    code: pb.RegisterNodeApplyCode,
    node: ?pb.Node,
) raft.Error![]u8 {
    return encodeMessage(allocator, pb.RegisterNodeApplyResponse{ .code = code, .node = node });
}

fn encodeRegisterMemberApplyResponse(
    allocator: std.mem.Allocator,
    code: pb.RegisterMemberApplyCode,
    member: ?pb.Member,
) raft.Error![]u8 {
    return encodeMessage(allocator, pb.RegisterMemberApplyResponse{ .code = code, .member = member });
}

fn encodeCreateVolumeApplyResponse(allocator: std.mem.Allocator, code: pb.CreateVolumeApplyCode, volume: ?pb.Volume) raft.Error![]u8 {
    return encodeMessage(allocator, pb.CreateVolumeApplyResponse{ .code = code, .volume = volume });
}

fn encodeDeleteVolumeApplyResponse(
    allocator: std.mem.Allocator,
    code: pb.DeleteVolumeApplyCode,
    volume_id: []const u8,
    accepted_at_unix_ms: i64,
    accepted_revision: u64,
    deletion_pending: bool,
    volume: ?pb.Volume,
) raft.Error![]u8 {
    return encodeMessage(allocator, pb.DeleteVolumeApplyResponse{
        .code = code,
        .volume_id = volume_id,
        .accepted_at_unix_ms = accepted_at_unix_ms,
        .accepted_revision = accepted_revision,
        .deletion_pending = deletion_pending,
        .volume = volume,
    });
}

fn encodeUpdateVolumeApplyResponse(allocator: std.mem.Allocator, code: pb.UpdateVolumeApplyCode, volume: ?pb.Volume) raft.Error![]u8 {
    return encodeMessage(allocator, pb.UpdateVolumeApplyResponse{ .code = code, .volume = volume });
}

fn encodeReserveApplyResponse(allocator: std.mem.Allocator, code: pb.ReserveVolumeResourcesApplyCode, volume: ?pb.Volume) raft.Error![]u8 {
    return encodeMessage(allocator, pb.ReserveVolumeResourcesApplyResponse{ .code = code, .volume = volume });
}

fn encodeActivateApplyResponse(allocator: std.mem.Allocator, code: pb.ActivateReplicaApplyCode, volume: ?pb.Volume, placement: ?pb.ReplicaPlacement, allocation: ?pb.ReplicaAllocation) raft.Error![]u8 {
    return encodeMessage(allocator, pb.ActivateReplicaApplyResponse{ .code = code, .volume = volume, .placement = placement, .allocation = allocation });
}

fn encodeFinalizeApplyResponse(allocator: std.mem.Allocator, code: pb.FinalizeVolumeDeletionApplyCode, volume_id: []const u8, deleted_revision: u64) raft.Error![]u8 {
    return encodeMessage(allocator, pb.FinalizeVolumeDeletionApplyResponse{ .code = code, .volume_id = volume_id, .deleted_revision = deleted_revision });
}

fn encodePrimaryAuthorityApplyResponse(allocator: std.mem.Allocator, code: pb.PrimaryAuthorityApplyCode, authority: ?pb.PrimaryAuthority, volume: ?pb.Volume) raft.Error![]u8 {
    return encodeMessage(allocator, pb.PrimaryAuthorityApplyResponse{ .code = code, .authority = authority, .volume = volume });
}

fn encodePrimaryFailoverApplyResponse(allocator: std.mem.Allocator, code: pb.PrimaryFailoverApplyCode, failover: ?pb.PrimaryFailover, authority: ?pb.PrimaryAuthority, volume: ?pb.Volume) raft.Error![]u8 {
    return encodeMessage(allocator, pb.PrimaryFailoverApplyResponse{ .code = code, .failover = failover, .authority = authority, .volume = volume });
}

const encodeMessage = codec.encodeMessage;
const mapDecodeError = codec.mapDecodeError;

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

fn restoreNode(allocator: std.mem.Allocator, state: *State, source: pb.Node) raft.Error!void {
    try validateNode(source);
    if (state.nodes_by_id.contains(source.id)) return error.PayloadParseFailed;
    var node = try Node.init(allocator, source);
    errdefer node.deinit(allocator);
    try state.nodes_by_id.ensureUnusedCapacity(allocator, 1);
    try state.node_ids_by_revision.ensureUnusedCapacity(allocator, 1);
    state.nodes_by_id.putAssumeCapacity(node.id, node);
    state.node_ids_by_revision.appendAssumeCapacity(node.id);
    state.max_node_registered_revision = @max(state.max_node_registered_revision, node.registered_revision);
}

fn restoreMember(allocator: std.mem.Allocator, state: *State, source: pb.Member) raft.Error!void {
    try validateMember(source);
    if (!state.pools_by_id.contains(source.pool_id) or !state.nodes_by_id.contains(source.node_id)) return error.PayloadParseFailed;
    if (state.members_by_id.contains(source.id)) return error.PayloadParseFailed;
    if (state.pool_ids_by_local_set.get(source.local_set_id)) |pool_id| {
        if (!std.mem.eql(u8, pool_id, source.pool_id)) return error.PayloadParseFailed;
    }
    const slot_key = memberSlotKey(source.local_set_id, source.member_slot);
    if (state.member_ids_by_slot.contains(slot_key)) return error.PayloadParseFailed;
    var member = try Member.init(allocator, source);
    errdefer member.deinit(allocator);
    try state.members_by_id.ensureUnusedCapacity(allocator, 1);
    try state.member_ids_by_revision.ensureUnusedCapacity(allocator, 1);
    if (!state.pool_ids_by_local_set.contains(source.local_set_id)) {
        try state.pool_ids_by_local_set.ensureUnusedCapacity(allocator, 1);
    }
    try state.member_ids_by_slot.ensureUnusedCapacity(allocator, 1);
    state.members_by_id.putAssumeCapacity(member.id, member);
    state.member_ids_by_revision.appendAssumeCapacity(member.id);
    if (!state.pool_ids_by_local_set.contains(member.local_set_id)) {
        state.pool_ids_by_local_set.putAssumeCapacity(member.local_set_id, member.pool_id);
    }
    state.member_ids_by_slot.putAssumeCapacity(slot_key, member.id);
    state.max_member_registered_revision = @max(state.max_member_registered_revision, member.registered_revision);
}

fn restoreVolume(allocator: std.mem.Allocator, state: *State, source: pb.Volume) raft.Error!void {
    try validateVolume(source);
    if (!state.pools_by_id.contains(source.pool_id) or state.volumes_by_id.contains(source.id) or state.volume_tombstones_by_id.contains(source.id)) return error.PayloadParseFailed;
    var scoped_buffer: [36 + 1 + max_name_bytes]u8 = undefined;
    if (state.volume_ids_by_scoped_name.contains(scopedKey(source.pool_id, source.name, &scoped_buffer))) return error.PayloadParseFailed;
    var volume = try Volume.init(allocator, source);
    errdefer volume.deinit(allocator);
    try state.volumes_by_id.ensureUnusedCapacity(allocator, 1);
    try state.volume_ids_by_scoped_name.ensureUnusedCapacity(allocator, 1);
    try state.volume_ids_by_revision.ensureUnusedCapacity(allocator, 1);
    state.volumes_by_id.putAssumeCapacity(volume.id, volume);
    state.volume_ids_by_scoped_name.putAssumeCapacity(volume.scoped_name, volume.id);
    state.volume_ids_by_revision.appendAssumeCapacity(volume.id);
    state.max_volume_created_revision = @max(state.max_volume_created_revision, volume.created_revision);
}

fn restoreVolumeTombstone(allocator: std.mem.Allocator, state: *State, source: pb.VolumeTombstone, snapshot_index: u64) raft.Error!void {
    const source_volume = source.volume orelse return error.PayloadParseFailed;
    try validateVolume(source_volume);
    if (!state.pools_by_id.contains(source_volume.pool_id) or
        state.volumes_by_id.contains(source_volume.id) or
        state.volume_tombstones_by_id.contains(source_volume.id) or
        source_volume.resource_version > snapshot_index or
        source.deleted_at_unix_ms <= 0 or
        source.deleted_revision <= source_volume.resource_version or
        source.deleted_revision > snapshot_index)
    {
        return error.PayloadParseFailed;
    }
    var volume = try Volume.init(allocator, source_volume);
    errdefer volume.deinit(allocator);
    try state.volume_tombstones_by_id.ensureUnusedCapacity(allocator, 1);
    state.volume_tombstones_by_id.putAssumeCapacity(volume.id, .{ .volume = volume, .deleted_at_unix_ms = source.deleted_at_unix_ms, .deleted_revision = source.deleted_revision });
    state.max_volume_created_revision = @max(state.max_volume_created_revision, volume.created_revision);
    state.max_volume_deleted_revision = @max(state.max_volume_deleted_revision, source.deleted_revision);
}

fn restoreReplicaPlacement(allocator: std.mem.Allocator, state: *State, source_value: pb.ReplicaPlacement, snapshot_index: u64, snapshot_version: u32) raft.Error!void {
    var source = source_value;
    if (!validUuidV7(source.id) or !validUuidV7(source.volume_id) or !validUuidV7(source.node_id) or
        source.replica_index >= volume_target_replica_count or source.generation == 0 or
        !validReplicaPlacementState(source.state) or !validResourceRevisions(source.created_revision, source.resource_version, snapshot_index))
    {
        return error.PayloadParseFailed;
    }
    const attested = validFixedNonzero(source.backend_digest, 32) and source.attested_revision >= source.created_revision and source.attested_revision <= source.resource_version;
    if ((source.state == .REPLICA_PLACEMENT_STATE_RESERVED and (source.backend_digest.len != 0 or source.attested_revision != 0)) or
        (source.state != .REPLICA_PLACEMENT_STATE_RESERVED and !attested and snapshot_version >= snapshot_format_version)) return error.PayloadParseFailed;
    const volume = state.volumes_by_id.getPtr(source.volume_id) orelse return error.PayloadParseFailed;
    if (source.state != .REPLICA_PLACEMENT_STATE_RESERVED and !attested) {
        source.state = .REPLICA_PLACEMENT_STATE_RESERVED;
        source.backend_digest = &.{};
        source.attested_revision = 0;
        if (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_DELETING) {
            volume.lifecycle_state = .VOLUME_LIFECYCLE_STATE_PROVISIONING;
            volume.availability_state = .VOLUME_AVAILABILITY_STATE_UNKNOWN;
            volume.operation_phase = .VOLUME_OPERATION_PHASE_PLACING;
        }
    }
    const node = state.nodes_by_id.get(source.node_id) orelse return error.PayloadParseFailed;
    if (source.generation > volume.generation or state.replica_placements_by_id.contains(source.id)) return error.PayloadParseFailed;
    var key_buffer: [36 + @sizeOf(u32)]u8 = undefined;
    if (state.replica_ids_by_volume_index.contains(replicaKey(source.volume_id, source.replica_index, &key_buffer))) return error.PayloadParseFailed;
    for (0..volume_target_replica_count) |replica_index| {
        var existing_key_buffer: [36 + @sizeOf(u32)]u8 = undefined;
        const existing_id = state.replica_ids_by_volume_index.get(replicaKey(source.volume_id, @intCast(replica_index), &existing_key_buffer)) orelse continue;
        const existing = state.replica_placements_by_id.get(existing_id).?;
        const existing_node = state.nodes_by_id.get(existing.node_id).?;
        if (std.mem.eql(u8, existing.node_id, source.node_id) or std.mem.eql(u8, existing_node.failure_domain, node.failure_domain)) return error.PayloadParseFailed;
    }
    var replica = try ReplicaPlacement.init(allocator, source);
    errdefer replica.deinit(allocator);
    try state.replica_placements_by_id.ensureUnusedCapacity(allocator, 1);
    try state.replica_ids_by_volume_index.ensureUnusedCapacity(allocator, 1);
    state.replica_placements_by_id.putAssumeCapacity(replica.id, replica);
    state.replica_ids_by_volume_index.putAssumeCapacity(replica.replica_key, replica.id);
}

fn restoreReplicaAllocation(allocator: std.mem.Allocator, state: *State, source_value: pb.ReplicaAllocation, snapshot_index: u64, snapshot_version: u32) raft.Error!void {
    var source = source_value;
    if (!validUuidV7(source.id) or !validUuidV7(source.replica_id) or !validFixedNonzero(source.member_id, 16) or
        source.length_bytes == 0 or source.generation == 0 or !validReplicaAllocationState(source.state) or
        !validResourceRevisions(source.created_revision, source.resource_version, snapshot_index) or
        state.replica_allocations_by_id.contains(source.id) or state.allocation_ids_by_replica.contains(source.replica_id))
    {
        return error.PayloadParseFailed;
    }
    const replica = state.replica_placements_by_id.get(source.replica_id) orelse return error.PayloadParseFailed;
    const states_match = switch (replica.state) {
        .REPLICA_PLACEMENT_STATE_RESERVED => source.state == .REPLICA_ALLOCATION_STATE_RESERVED,
        .REPLICA_PLACEMENT_STATE_ACTIVE => source.state == .REPLICA_ALLOCATION_STATE_ACTIVE,
        .REPLICA_PLACEMENT_STATE_RETIRING => source.state == .REPLICA_ALLOCATION_STATE_RETIRING,
        else => false,
    };
    if (!states_match) {
        if (snapshot_version < snapshot_format_version and replica.state == .REPLICA_PLACEMENT_STATE_RESERVED)
            source.state = .REPLICA_ALLOCATION_STATE_RESERVED
        else
            return error.PayloadParseFailed;
    }
    const volume = state.volumes_by_id.get(replica.volume_id) orelse return error.PayloadParseFailed;
    const member = state.members_by_id.get(source.member_id) orelse return error.PayloadParseFailed;
    const end = std.math.add(u64, source.offset_bytes, source.length_bytes) catch return error.PayloadParseFailed;
    if (!std.mem.eql(u8, member.pool_id, volume.pool_id) or !std.mem.eql(u8, member.node_id, replica.node_id) or
        source.generation > replica.generation or source.offset_bytes % member.extent_size_bytes != 0 or
        source.length_bytes % member.extent_size_bytes != 0 or end > member.data_capacity_bytes)
    {
        return error.PayloadParseFailed;
    }
    var allocation_iterator = state.replica_allocations_by_id.valueIterator();
    while (allocation_iterator.next()) |existing| {
        if (!std.mem.eql(u8, existing.member_id, source.member_id)) continue;
        const existing_end = existing.offset_bytes + existing.length_bytes;
        if (source.offset_bytes < existing_end and existing.offset_bytes < end) return error.PayloadParseFailed;
    }
    var allocation = try ReplicaAllocation.init(allocator, source);
    errdefer allocation.deinit(allocator);
    try state.replica_allocations_by_id.ensureUnusedCapacity(allocator, 1);
    try state.allocation_ids_by_replica.ensureUnusedCapacity(allocator, 1);
    state.replica_allocations_by_id.putAssumeCapacity(allocation.id, allocation);
    state.allocation_ids_by_replica.putAssumeCapacity(allocation.replica_id, allocation.id);
}

fn restoreVolumeAttachment(allocator: std.mem.Allocator, state: *State, source: pb.VolumeAttachment, snapshot_index: u64) raft.Error!void {
    if (!validUuidV7(source.id) or !validUuidV7(source.volume_id) or !validUuidV7(source.target_node_id) or
        !validText(source.consumer_id, max_consumer_id_bytes, false) or !validVolumeAccessMode(source.access_mode) or
        !validVolumeAttachmentState(source.state) or source.generation == 0 or
        !validResourceRevisions(source.created_revision, source.resource_version, snapshot_index) or
        state.volume_attachments_by_id.contains(source.id))
    {
        return error.PayloadParseFailed;
    }
    const volume = state.volumes_by_id.get(source.volume_id) orelse return error.PayloadParseFailed;
    if (!state.nodes_by_id.contains(source.target_node_id) or source.generation > volume.generation) return error.PayloadParseFailed;
    var key_buffer: [36 + 1 + max_consumer_id_bytes]u8 = undefined;
    if (state.attachment_ids_by_volume_consumer.contains(scopedKey(source.volume_id, source.consumer_id, &key_buffer))) return error.PayloadParseFailed;
    var attachment = try VolumeAttachment.init(allocator, source);
    errdefer attachment.deinit(allocator);
    try state.volume_attachments_by_id.ensureUnusedCapacity(allocator, 1);
    try state.attachment_ids_by_volume_consumer.ensureUnusedCapacity(allocator, 1);
    state.volume_attachments_by_id.putAssumeCapacity(attachment.id, attachment);
    state.attachment_ids_by_volume_consumer.putAssumeCapacity(attachment.consumer_key, attachment.id);
}

fn restorePrimaryAuthority(allocator: std.mem.Allocator, state: *State, source: pb.PrimaryAuthority, snapshot_index: u64, candidate: bool) raft.Error!void {
    if (!validUuidV7(source.volume_id) or !validUuidV7(source.primary_placement_id) or !validUuidV7(source.primary_node_id) or
        !validFixedNonzero(source.lease_id, 16) or !validFixedNonzero(source.holder_boot_id, 16) or
        source.authority_generation == 0 or source.write_epoch == 0 or source.placement_revision == 0 or
        !validFixedNonzero(source.activation_nonce, 16) or source.lease_duration_ms != primary_lease.duration_ms or !validFixedNonzero(source.authority_digest, 32) or
        source.created_revision == 0 or source.resource_version > snapshot_index or source.resource_version < source.created_revision or
        (if (candidate) state.primary_authority_candidates_by_volume.contains(source.volume_id) else state.primary_authorities_by_volume.contains(source.volume_id))) return error.PayloadParseFailed;
    switch (source.state) {
        .PRIMARY_AUTHORITY_STATE_PENDING => if (source.activated_revision != 0 or source.ready_revision != 0 or source.resource_version != source.created_revision or source.recovery_sequence != 0 or source.recovery_digest.len != 0 or source.recovery_empty_frontier) return error.PayloadParseFailed,
        .PRIMARY_AUTHORITY_STATE_ACTIVATED => if (source.activated_revision <= source.created_revision or source.ready_revision != 0 or source.resource_version != source.activated_revision or source.recovery_sequence != 0 or source.recovery_digest.len != 0 or source.recovery_empty_frontier) return error.PayloadParseFailed,
        .PRIMARY_AUTHORITY_STATE_READY => if (source.activated_revision <= source.created_revision or source.ready_revision <= source.activated_revision or source.resource_version != source.ready_revision or !validFixedNonzero(source.recovery_digest, 32) or (source.recovery_sequence == 0) != source.recovery_empty_frontier) return error.PayloadParseFailed,
        else => return error.PayloadParseFailed,
    }
    const volume = state.volumes_by_id.get(source.volume_id) orelse return error.PayloadParseFailed;
    const placement = state.replica_placements_by_id.get(source.primary_placement_id) orelse return error.PayloadParseFailed;
    const epoch_matches = if (state.primary_failovers_by_volume.get(source.volume_id)) |failover|
        source.write_epoch == (if (candidate) failover.target_write_epoch else failover.revoked_write_epoch)
    else if (!candidate and volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_DELETING)
        source.write_epoch <= volume.write_epoch
    else
        source.write_epoch == volume.write_epoch;
    if (!std.mem.eql(u8, placement.volume_id, volume.id) or !std.mem.eql(u8, placement.node_id, source.primary_node_id) or
        !epoch_matches or source.placement_revision != volume.placement_revision or volume.resource_version < source.resource_version or
        !activePlacementSetValid(state, volume, source.primary_placement_id, source.primary_node_id)) return error.PayloadParseFailed;
    var authority = try PrimaryAuthority.init(allocator, source);
    errdefer authority.deinit(allocator);
    const target = if (candidate) &state.primary_authority_candidates_by_volume else &state.primary_authorities_by_volume;
    try target.ensureUnusedCapacity(allocator, 1);
    target.putAssumeCapacity(authority.volume_id, authority);
}

fn restorePrimaryFailover(allocator: std.mem.Allocator, state: *State, source: pb.PrimaryFailover, snapshot_index: u64) raft.Error!void {
    if (!validUuidV7Bytes(source.failover_id) or !validUuidV7(source.volume_id) or !validFixedNonzero(source.revoked_lease_id, 16) or
        source.revoked_authority_generation == 0 or source.revoked_write_epoch == 0 or source.revoked_write_epoch == std.math.maxInt(u64) or
        source.target_write_epoch <= source.revoked_write_epoch or
        (source.state != .PRIMARY_FAILOVER_STATE_FENCING and source.target_write_epoch != source.revoked_write_epoch + 1) or
        (source.state != .PRIMARY_FAILOVER_STATE_WAITING_LEASE and source.state != .PRIMARY_FAILOVER_STATE_LEASE_EXPIRED and source.state != .PRIMARY_FAILOVER_STATE_FENCING) or
        !validResourceRevisions(source.created_revision, source.resource_version, snapshot_index) or
        (source.state == .PRIMARY_FAILOVER_STATE_WAITING_LEASE and source.resource_version != source.created_revision) or
        ((source.state == .PRIMARY_FAILOVER_STATE_LEASE_EXPIRED or source.state == .PRIMARY_FAILOVER_STATE_FENCING) and source.resource_version <= source.created_revision) or
        state.primary_failovers_by_volume.contains(source.volume_id)) return error.PayloadParseFailed;
    const volume = state.volumes_by_id.get(source.volume_id) orelse return error.PayloadParseFailed;
    if (volume.resource_version < source.resource_version) return error.PayloadParseFailed;
    var failover = try PrimaryFailover.init(allocator, source);
    errdefer failover.deinit(allocator);
    try state.primary_failovers_by_volume.ensureUnusedCapacity(allocator, 1);
    state.primary_failovers_by_volume.putAssumeCapacity(failover.volume_id, failover);
}

fn validateAuthorityVolumeInvariants(state: *const State) raft.Error!void {
    var authority_iterator = state.primary_authorities_by_volume.valueIterator();
    while (authority_iterator.next()) |authority| {
        const volume = state.volumes_by_id.get(authority.volume_id) orelse return error.PayloadParseFailed;
        if (volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_DELETING) {
            if (authority.state != .PRIMARY_AUTHORITY_STATE_READY or volume.availability_state != .VOLUME_AVAILABILITY_STATE_UNAVAILABLE or
                volume.operation_phase != .VOLUME_OPERATION_PHASE_NONE or volume.write_epoch < authority.write_epoch or
                state.primary_authority_candidates_by_volume.contains(volume.id) or state.primary_failovers_by_volume.contains(volume.id)) return error.PayloadParseFailed;
            continue;
        }
        const failover = state.primary_failovers_by_volume.get(authority.volume_id);
        if (authority.state != .PRIMARY_AUTHORITY_STATE_READY or volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE) return error.PayloadParseFailed;
        if (failover != null) {
            if (volume.availability_state != .VOLUME_AVAILABILITY_STATE_UNAVAILABLE or volume.operation_phase != .VOLUME_OPERATION_PHASE_FENCING or
                !std.mem.eql(u8, failover.?.revoked_lease_id, authority.lease_id) or failover.?.revoked_authority_generation != authority.authority_generation or
                failover.?.revoked_write_epoch != authority.write_epoch or
                ((failover.?.state == .PRIMARY_FAILOVER_STATE_WAITING_LEASE or failover.?.state == .PRIMARY_FAILOVER_STATE_LEASE_EXPIRED) and volume.write_epoch != failover.?.revoked_write_epoch) or
                (failover.?.state == .PRIMARY_FAILOVER_STATE_FENCING and volume.write_epoch != failover.?.target_write_epoch)) return error.PayloadParseFailed;
        } else if (volume.availability_state != .VOLUME_AVAILABILITY_STATE_HEALTHY or volume.operation_phase != .VOLUME_OPERATION_PHASE_NONE) return error.PayloadParseFailed;
    }
    var candidate_iterator = state.primary_authority_candidates_by_volume.valueIterator();
    while (candidate_iterator.next()) |candidate| {
        const volume = state.volumes_by_id.get(candidate.volume_id) orelse return error.PayloadParseFailed;
        const current = state.primary_authorities_by_volume.get(candidate.volume_id);
        if (candidate.state == .PRIMARY_AUTHORITY_STATE_READY) return error.PayloadParseFailed;
        if (volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_DELETING) return error.PayloadParseFailed;
        if (current) |ready| {
            if (state.primary_failovers_by_volume.get(candidate.volume_id)) |failover| {
                if (!failoverProposalValid(failover, ready, candidate.proto(), volume) or failover.state != .PRIMARY_FAILOVER_STATE_FENCING) return error.PayloadParseFailed;
            } else if (!renewalProposalValid(ready, candidate.proto()) or volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE or volume.availability_state != .VOLUME_AVAILABILITY_STATE_HEALTHY or volume.operation_phase != .VOLUME_OPERATION_PHASE_NONE) return error.PayloadParseFailed;
        } else if (candidate.authority_generation != 1 or volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_PROVISIONING or volume.availability_state != .VOLUME_AVAILABILITY_STATE_UNKNOWN or volume.operation_phase != .VOLUME_OPERATION_PHASE_FENCING) return error.PayloadParseFailed;
    }
    var failover_iterator = state.primary_failovers_by_volume.valueIterator();
    while (failover_iterator.next()) |failover| {
        const current = state.primary_authorities_by_volume.get(failover.volume_id) orelse return error.PayloadParseFailed;
        if (!std.mem.eql(u8, failover.revoked_lease_id, current.lease_id) or failover.revoked_authority_generation != current.authority_generation or
            failover.revoked_write_epoch != current.write_epoch) return error.PayloadParseFailed;
    }
    var volume_iterator = state.volumes_by_id.valueIterator();
    while (volume_iterator.next()) |volume| {
        if (volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_ACTIVE) continue;
        const authority = state.primary_authorities_by_volume.get(volume.id) orelse return error.PayloadParseFailed;
        if (authority.state != .PRIMARY_AUTHORITY_STATE_READY) return error.PayloadParseFailed;
    }
}

fn validResourceRevisions(created_revision: u64, resource_version: u64, snapshot_index: u64) bool {
    return created_revision != 0 and resource_version >= created_revision and resource_version <= snapshot_index;
}

fn validReplicaPlacementState(value: pb.ReplicaPlacementState) bool {
    return value == .REPLICA_PLACEMENT_STATE_RESERVED or value == .REPLICA_PLACEMENT_STATE_ACTIVE or value == .REPLICA_PLACEMENT_STATE_RETIRING;
}

fn validReplicaAllocationState(value: pb.ReplicaAllocationState) bool {
    return value == .REPLICA_ALLOCATION_STATE_RESERVED or value == .REPLICA_ALLOCATION_STATE_ACTIVE or value == .REPLICA_ALLOCATION_STATE_RETIRING;
}

fn validVolumeAccessMode(value: pb.VolumeAccessMode) bool {
    return value == .VOLUME_ACCESS_MODE_SINGLE_NODE_WRITER or value == .VOLUME_ACCESS_MODE_SINGLE_NODE_READER;
}

fn validVolumeAttachmentState(value: pb.VolumeAttachmentState) bool {
    return value == .VOLUME_ATTACHMENT_STATE_ATTACHING or value == .VOLUME_ATTACHMENT_STATE_ATTACHED or value == .VOLUME_ATTACHMENT_STATE_DETACHING or value == .VOLUME_ATTACHMENT_STATE_FAILED;
}

const RestoredCreation = union(enum) {
    pool: []const u8,
    node: []const u8,
    member: []const u8,
    volume: []const u8,
    volume_deleted: []const u8,
};

fn restoreRequest(
    allocator: std.mem.Allocator,
    decode_allocator: std.mem.Allocator,
    state: *State,
    source: pb.RequestRecord,
    snapshot_version: u32,
) raft.Error!?RestoredCreation {
    if (!validText(source.request_id, max_request_id_bytes, false)) return error.PayloadParseFailed;
    if (source.request_fingerprint.len != @sizeOf(Fingerprint) or source.encoded_response.len == 0 or source.encoded_command.len == 0) return error.PayloadParseFailed;
    if (state.requests.contains(source.request_id)) return error.PayloadParseFailed;

    var command_reader: std.Io.Reader = .fixed(source.encoded_command);
    var envelope = pb.CommandEnvelope.decode(&command_reader, decode_allocator) catch |err| return mapDecodeError(err);
    defer envelope.deinit(decode_allocator);
    if (envelope.format_version < 1 or envelope.format_version > command_format_version) return error.PayloadParseFailed;
    switch (envelope.command orelse return error.PayloadParseFailed) {
        .create_pool => |command| {
            try validateCommand(command);
            if (!std.mem.eql(u8, source.request_id, command.request_id)) return error.PayloadParseFailed;
            const expected_fingerprint = requestFingerprint(command);
            if (!std.mem.eql(u8, source.request_fingerprint, &expected_fingerprint)) return error.PayloadParseFailed;

            var response_reader: std.Io.Reader = .fixed(source.encoded_response);
            var response = pb.ApplyResponse.decode(&response_reader, decode_allocator) catch |err| return mapDecodeError(err);
            defer response.deinit(decode_allocator);
            const created_pool_id = try validateStoredResponse(state, command, response, source.applied_revision);
            const encoded_response = try encodeApplyResponse(allocator, response.code, response.pool);
            errdefer allocator.free(encoded_response);
            const encoded_command = try encodeCreatePoolCommand(allocator, command);
            errdefer allocator.free(encoded_command);
            try insertRestoredRequest(allocator, state, source, .create_pool, encoded_response, encoded_command);
            return if (created_pool_id) |id| RestoredCreation{ .pool = id } else null;
        },
        .register_node => |command| {
            if (snapshot_version == 2) return error.PayloadParseFailed;
            try validateRegisterNodeCommand(command);
            if (!std.mem.eql(u8, source.request_id, command.request_id)) return error.PayloadParseFailed;
            const expected_fingerprint = registerNodeFingerprint(command);
            if (!std.mem.eql(u8, source.request_fingerprint, &expected_fingerprint)) return error.PayloadParseFailed;

            var response_reader: std.Io.Reader = .fixed(source.encoded_response);
            var response = pb.RegisterNodeApplyResponse.decode(&response_reader, decode_allocator) catch |err| return mapDecodeError(err);
            defer response.deinit(decode_allocator);
            const registered_node_id = try validateStoredNodeResponse(state, command, response, source.applied_revision);
            const encoded_response = try encodeRegisterNodeApplyResponse(allocator, response.code, response.node);
            errdefer allocator.free(encoded_response);
            const encoded_command = try encodeRegisterNodeCommand(allocator, command);
            errdefer allocator.free(encoded_command);
            try insertRestoredRequest(allocator, state, source, .register_node, encoded_response, encoded_command);
            return if (registered_node_id) |id| RestoredCreation{ .node = id } else null;
        },
        .register_member => |command| {
            if (snapshot_version < 4) return error.PayloadParseFailed;
            try validateRegisterMemberCommand(command);
            if (!std.mem.eql(u8, source.request_id, command.request_id)) return error.PayloadParseFailed;
            const expected_fingerprint = registerMemberFingerprint(command);
            if (!std.mem.eql(u8, source.request_fingerprint, &expected_fingerprint)) return error.PayloadParseFailed;

            var response_reader: std.Io.Reader = .fixed(source.encoded_response);
            var response = pb.RegisterMemberApplyResponse.decode(&response_reader, decode_allocator) catch |err| return mapDecodeError(err);
            defer response.deinit(decode_allocator);
            const registered_member_id = try validateStoredMemberResponse(state, command, response, source.applied_revision);
            const encoded_response = try encodeRegisterMemberApplyResponse(allocator, response.code, response.member);
            errdefer allocator.free(encoded_response);
            const encoded_command = try encodeRegisterMemberCommand(allocator, command);
            errdefer allocator.free(encoded_command);
            try insertRestoredRequest(allocator, state, source, .register_member, encoded_response, encoded_command);
            return if (registered_member_id) |id| RestoredCreation{ .member = id } else null;
        },
        .create_volume => |command| {
            if (snapshot_version < 5 or envelope.format_version < 2) return error.PayloadParseFailed;
            try validateCreateVolumeCommand(command);
            if (!std.mem.eql(u8, source.request_id, command.request_id)) return error.PayloadParseFailed;
            const expected_fingerprint = createVolumeFingerprint(command);
            if (!std.mem.eql(u8, source.request_fingerprint, &expected_fingerprint)) return error.PayloadParseFailed;

            var response_reader: std.Io.Reader = .fixed(source.encoded_response);
            var response = pb.CreateVolumeApplyResponse.decode(&response_reader, decode_allocator) catch |err| return mapDecodeError(err);
            defer response.deinit(decode_allocator);
            const created_volume_id = try validateStoredVolumeResponse(state, command, response, source.applied_revision);
            const encoded_response = try encodeCreateVolumeApplyResponse(allocator, response.code, response.volume);
            errdefer allocator.free(encoded_response);
            const encoded_command = try encodeCreateVolumeCommand(allocator, command);
            errdefer allocator.free(encoded_command);
            try insertRestoredRequest(allocator, state, source, .create_volume, encoded_response, encoded_command);
            return if (created_volume_id) |id| RestoredCreation{ .volume = id } else null;
        },
        .delete_volume => |command| {
            if (snapshot_version < 5 or envelope.format_version < 2) return error.PayloadParseFailed;
            try validateDeleteVolumeCommand(command);
            if (!std.mem.eql(u8, source.request_id, command.request_id)) return error.PayloadParseFailed;
            const expected_fingerprint = deleteVolumeFingerprint(command);
            if (!std.mem.eql(u8, source.request_fingerprint, &expected_fingerprint)) return error.PayloadParseFailed;

            var response_reader: std.Io.Reader = .fixed(source.encoded_response);
            var response = pb.DeleteVolumeApplyResponse.decode(&response_reader, decode_allocator) catch |err| return mapDecodeError(err);
            defer response.deinit(decode_allocator);
            const legacy_pending = try validateStoredDeleteVolumeResponse(state, command, response, source.applied_revision, snapshot_version);
            const canonical_code: pb.DeleteVolumeApplyCode = if (legacy_pending) .DELETE_VOLUME_APPLY_CODE_DELETION_ACCEPTED else response.code;
            const canonical_volume = if (legacy_pending) storedVolumeById(state, command.volume_id) else response.volume;
            const encoded_response = try encodeDeleteVolumeApplyResponse(
                allocator,
                canonical_code,
                response.volume_id,
                response.accepted_at_unix_ms,
                response.accepted_revision,
                legacy_pending or response.deletion_pending,
                canonical_volume,
            );
            errdefer allocator.free(encoded_response);
            const encoded_command = try encodeDeleteVolumeCommand(allocator, command);
            errdefer allocator.free(encoded_command);
            try insertRestoredRequest(allocator, state, source, .delete_volume, encoded_response, encoded_command);
            if (canonical_code == .DELETE_VOLUME_APPLY_CODE_DELETED) {
                if (state.volume_tombstones_by_id.get(command.volume_id)) |tombstone| {
                    if (tombstone.volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_DELETING) return RestoredCreation{ .volume_deleted = tombstone.volume.id };
                }
            }
            return null;
        },
        .update_volume => |command| {
            if (snapshot_version < 6 or envelope.format_version < 3 or envelope.format_version > command_format_version) return error.PayloadParseFailed;
            try validateUpdateVolumeCommand(command);
            if (!std.mem.eql(u8, source.request_id, command.request_id)) return error.PayloadParseFailed;
            const expected_fingerprint = updateVolumeFingerprint(command);
            if (!std.mem.eql(u8, source.request_fingerprint, &expected_fingerprint)) return error.PayloadParseFailed;
            var response_reader: std.Io.Reader = .fixed(source.encoded_response);
            var response = pb.UpdateVolumeApplyResponse.decode(&response_reader, decode_allocator) catch |err| return mapDecodeError(err);
            defer response.deinit(decode_allocator);
            try validateStoredUpdateVolumeResponse(state, command, response, source.applied_revision);
            const encoded_response = try encodeUpdateVolumeApplyResponse(allocator, response.code, response.volume);
            errdefer allocator.free(encoded_response);
            const encoded_command = try encodeUpdateVolumeCommand(allocator, command);
            errdefer allocator.free(encoded_command);
            try insertRestoredRequest(allocator, state, source, .update_volume, encoded_response, encoded_command);
            return null;
        },
        .reserve_volume_resources,
        .activate_replica,
        .finalize_volume_deletion,
        .propose_primary_authority,
        .activate_primary_authority,
        .commit_primary_authority_ready,
        .commit_primary_authority_renewal_ready,
        .abort_primary_authority_candidate,
        .begin_primary_failover,
        .commit_primary_authority_failover_ready,
        .complete_primary_failover_lease_wait,
        => return error.PayloadParseFailed,
    }
}

fn insertRestoredRequest(
    allocator: std.mem.Allocator,
    state: *State,
    source: pb.RequestRecord,
    kind: RequestKind,
    encoded_response: []u8,
    encoded_command: []u8,
) raft.Error!void {
    const request_id = try allocator.dupe(u8, source.request_id);
    errdefer allocator.free(request_id);
    var fingerprint: Fingerprint = undefined;
    @memcpy(&fingerprint, source.request_fingerprint);
    try state.requests.ensureUnusedCapacity(allocator, 1);
    state.requests.putAssumeCapacity(request_id, .{
        .request_id = request_id,
        .kind = kind,
        .fingerprint = fingerprint,
        .encoded_response = encoded_response,
        .encoded_command = encoded_command,
        .applied_revision = source.applied_revision,
    });
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

fn validateStoredNodeResponse(
    state: *const State,
    command: pb.RegisterNodeCommand,
    response: pb.RegisterNodeApplyResponse,
    applied_revision: u64,
) raft.Error!?[]const u8 {
    switch (response.code) {
        .REGISTER_NODE_APPLY_CODE_REGISTERED => {
            const response_node = response.node orelse return error.PayloadParseFailed;
            const stored_node = state.nodes_by_id.get(response_node.id) orelse return error.PayloadParseFailed;
            if (!nodesEqual(stored_node.proto(), response_node) or
                !std.mem.eql(u8, command.node_id, response_node.id) or
                !std.mem.eql(u8, command.cluster_id, response_node.cluster_id) or
                !std.mem.eql(u8, command.control_endpoint, response_node.control_endpoint) or
                !std.mem.eql(u8, command.nvmf_endpoint, response_node.nvmf_endpoint) or
                !std.mem.eql(u8, command.failure_domain, response_node.failure_domain) or
                command.capability_bits != response_node.capability_bits or
                command.protocol_version != response_node.protocol_version or
                command.proposed_registered_at_unix_ms != response_node.registered_at_unix_ms or
                applied_revision != response_node.registered_revision)
            {
                return error.PayloadParseFailed;
            }
            return stored_node.id;
        },
        .REGISTER_NODE_APPLY_CODE_ID_EXISTS => {
            const response_node = response.node orelse return error.PayloadParseFailed;
            const stored_node = state.nodes_by_id.get(response_node.id) orelse return error.PayloadParseFailed;
            if (!nodesEqual(stored_node.proto(), response_node) or
                !std.mem.eql(u8, command.node_id, response_node.id) or
                response_node.registered_revision >= applied_revision)
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        .REGISTER_NODE_APPLY_CODE_NODE_LIMIT => {
            const id_conflict_before_request = if (state.nodes_by_id.get(command.node_id)) |node|
                node.registered_revision < applied_revision
            else
                false;
            if (response.node != null or
                state.nodes_by_id.count() != max_nodes or
                state.max_node_registered_revision >= applied_revision or
                id_conflict_before_request)
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        else => return error.PayloadParseFailed,
    }
}

fn validateStoredMemberResponse(
    state: *const State,
    command: pb.RegisterMemberCommand,
    response: pb.RegisterMemberApplyResponse,
    applied_revision: u64,
) raft.Error!?[]const u8 {
    const pool = state.pools_by_id.get(command.pool_id);
    const node = state.nodes_by_id.get(command.node_id);
    const pool_existed = if (pool) |value| value.created_revision < applied_revision else false;
    const node_existed = if (node) |value| value.registered_revision < applied_revision else false;
    const node_matches_cluster = if (node) |value| std.mem.eql(u8, value.cluster_id, command.cluster_id) else false;
    const existing_id = state.members_by_id.get(command.member_id);
    const id_existed = if (existing_id) |value| value.registered_revision < applied_revision else false;
    const local_set_pool = memberLocalSetPoolBefore(state, command.local_set_id, applied_revision);
    const slot_member = state.member_ids_by_slot.get(memberSlotKey(command.local_set_id, command.member_slot));
    const stored_slot_member = if (slot_member) |id| state.members_by_id.get(id) else null;
    const slot_existed = if (stored_slot_member) |value| value.registered_revision < applied_revision else false;

    switch (response.code) {
        .REGISTER_MEMBER_APPLY_CODE_REGISTERED => {
            const response_member = response.member orelse return error.PayloadParseFailed;
            const stored_member = state.members_by_id.get(response_member.id) orelse return error.PayloadParseFailed;
            if (!membersEqual(stored_member.proto(), response_member) or
                !std.mem.eql(u8, command.member_id, response_member.id) or
                !std.mem.eql(u8, command.pool_id, response_member.pool_id) or
                !std.mem.eql(u8, command.node_id, response_member.node_id) or
                !std.mem.eql(u8, command.local_set_id, response_member.local_set_id) or
                command.member_slot != response_member.member_slot or
                !std.mem.eql(u8, command.birth_topology_digest, response_member.birth_topology_digest) or
                command.metadata_capacity_bytes != response_member.metadata_capacity_bytes or
                command.data_capacity_bytes != response_member.data_capacity_bytes or
                command.extent_size_bytes != response_member.extent_size_bytes or
                command.proposed_registered_at_unix_ms != response_member.registered_at_unix_ms or
                applied_revision != response_member.registered_revision or
                !pool_existed or !node_existed or !node_matches_cluster)
            {
                return error.PayloadParseFailed;
            }
            return stored_member.id;
        },
        .REGISTER_MEMBER_APPLY_CODE_POOL_NOT_FOUND => {
            if (response.member != null or pool_existed) return error.PayloadParseFailed;
            return null;
        },
        .REGISTER_MEMBER_APPLY_CODE_NODE_NOT_FOUND => {
            if (response.member != null or !pool_existed or node_existed) return error.PayloadParseFailed;
            return null;
        },
        .REGISTER_MEMBER_APPLY_CODE_CLUSTER_MISMATCH => {
            if (response.member != null or !pool_existed or !node_existed or node_matches_cluster) return error.PayloadParseFailed;
            return null;
        },
        .REGISTER_MEMBER_APPLY_CODE_ID_EXISTS => {
            const response_member = response.member orelse return error.PayloadParseFailed;
            if (!pool_existed or !node_existed or !node_matches_cluster or !id_existed or
                !membersEqual(existing_id.?.proto(), response_member))
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        .REGISTER_MEMBER_APPLY_CODE_LOCAL_SET_CONFLICT => {
            if (response.member != null or !pool_existed or !node_existed or !node_matches_cluster or id_existed or
                local_set_pool == null or std.mem.eql(u8, local_set_pool.?, command.pool_id))
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        .REGISTER_MEMBER_APPLY_CODE_SLOT_EXISTS => {
            const response_member = response.member orelse return error.PayloadParseFailed;
            if (!pool_existed or !node_existed or !node_matches_cluster or id_existed or
                (local_set_pool != null and !std.mem.eql(u8, local_set_pool.?, command.pool_id)) or
                !slot_existed or !membersEqual(stored_slot_member.?.proto(), response_member))
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        .REGISTER_MEMBER_APPLY_CODE_MEMBER_LIMIT => {
            if (response.member != null or !pool_existed or !node_existed or !node_matches_cluster or id_existed or
                (local_set_pool != null and !std.mem.eql(u8, local_set_pool.?, command.pool_id)) or slot_existed or
                state.members_by_id.count() != max_members or state.max_member_registered_revision >= applied_revision)
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        else => return error.PayloadParseFailed,
    }
}

fn validateStoredVolumeResponse(
    state: *const State,
    command: pb.CreateVolumeCommand,
    response: pb.CreateVolumeApplyResponse,
    applied_revision: u64,
) raft.Error!?[]const u8 {
    const pool = state.pools_by_id.get(command.pool_id);
    const pool_existed = if (pool) |value| value.created_revision < applied_revision else false;
    const id_volume = storedVolumeById(state, command.proposed_volume_id);
    const id_existed = if (id_volume) |value| volumeWasLiveAt(state, value.id, applied_revision) else false;
    const name_volume = volumeByScopedNameAt(state, command.pool_id, command.name, applied_revision);

    switch (response.code) {
        .CREATE_VOLUME_APPLY_CODE_CREATED => {
            const response_volume = response.volume orelse return error.PayloadParseFailed;
            const stored_volume = storedVolumeById(state, response_volume.id) orelse return error.PayloadParseFailed;
            if (!std.mem.eql(u8, command.proposed_volume_id, response_volume.id) or
                !std.mem.eql(u8, command.pool_id, response_volume.pool_id) or
                !std.mem.eql(u8, command.name, response_volume.name) or
                !std.mem.eql(u8, command.description, response_volume.description) or
                command.size_bytes != response_volume.size_bytes or
                command.proposed_created_at_unix_ms != response_volume.created_at_unix_ms or
                response_volume.created_revision != applied_revision or
                response_volume.resource_version != applied_revision or
                stored_volume.created_revision != response_volume.created_revision or !std.mem.eql(u8, stored_volume.pool_id, response_volume.pool_id) or
                !std.mem.eql(u8, stored_volume.name, response_volume.name) or stored_volume.size_bytes != response_volume.size_bytes or
                stored_volume.resource_version < response_volume.resource_version or !pool_existed or id_existed or name_volume != null)
            {
                return error.PayloadParseFailed;
            }
            return storedVolumeId(state, response_volume.id).?;
        },
        .CREATE_VOLUME_APPLY_CODE_POOL_NOT_FOUND => {
            if (response.volume != null or pool_existed) return error.PayloadParseFailed;
            return null;
        },
        .CREATE_VOLUME_APPLY_CODE_ID_EXISTS => {
            const response_volume = response.volume orelse return error.PayloadParseFailed;
            if (!pool_existed or !id_existed or !std.mem.eql(u8, response_volume.id, command.proposed_volume_id) or
                !volumesEqual(id_volume.?, response_volume)) return error.PayloadParseFailed;
            return null;
        },
        .CREATE_VOLUME_APPLY_CODE_NAME_EXISTS => {
            const response_volume = response.volume orelse return error.PayloadParseFailed;
            if (!pool_existed or id_existed or name_volume == null or !volumesEqual(name_volume.?, response_volume)) return error.PayloadParseFailed;
            return null;
        },
        .CREATE_VOLUME_APPLY_CODE_VOLUME_LIMIT => {
            if (response.volume != null or !pool_existed or id_existed or name_volume != null or
                liveVolumeCountAt(state, applied_revision) != max_volumes)
            {
                return error.PayloadParseFailed;
            }
            return null;
        },
        else => return error.PayloadParseFailed,
    }
}

fn validateStoredDeleteVolumeResponse(
    state: *const State,
    command: pb.DeleteVolumeCommand,
    response: pb.DeleteVolumeApplyResponse,
    applied_revision: u64,
    snapshot_version: u32,
) raft.Error!bool {
    const volume = storedVolumeById(state, command.volume_id);
    const was_live = if (volume) |value| volumeWasLiveAt(state, value.id, applied_revision) else false;
    const response_is_empty = response.volume_id.len == 0 and response.accepted_at_unix_ms == 0 and response.accepted_revision == 0 and !response.deletion_pending and response.volume == null;
    const legacy_pending = snapshot_version <= 6 and response.code == .DELETE_VOLUME_APPLY_CODE_DELETED and
        !response.deletion_pending and response.volume == null and volume != null and
        volume.?.lifecycle_state == .VOLUME_LIFECYCLE_STATE_DELETING;
    switch (response.code) {
        .DELETE_VOLUME_APPLY_CODE_DELETED => {
            if (!std.mem.eql(u8, response.volume_id, command.volume_id) or
                response.accepted_at_unix_ms != command.proposed_deleted_at_unix_ms or
                response.accepted_revision != applied_revision)
            {
                return error.PayloadParseFailed;
            }
            if (legacy_pending) {
                if (!was_live or volume.?.resource_version != applied_revision) return error.PayloadParseFailed;
                return true;
            }
            if (response.deletion_pending or response.volume != null) return error.PayloadParseFailed;
            const tombstone = state.volume_tombstones_by_id.get(command.volume_id) orelse return error.PayloadParseFailed;
            if (tombstone.volume.lifecycle_state == .VOLUME_LIFECYCLE_STATE_DELETING or
                tombstone.deleted_at_unix_ms != response.accepted_at_unix_ms or tombstone.deleted_revision != response.accepted_revision or
                tombstone.volume.resource_version != command.expected_resource_version) return error.PayloadParseFailed;
        },
        .DELETE_VOLUME_APPLY_CODE_DELETION_ACCEPTED => {
            const accepted_volume = response.volume orelse return error.PayloadParseFailed;
            if (!response.deletion_pending or !std.mem.eql(u8, response.volume_id, command.volume_id) or
                response.accepted_at_unix_ms != command.proposed_deleted_at_unix_ms or response.accepted_revision != applied_revision or
                accepted_volume.lifecycle_state != .VOLUME_LIFECYCLE_STATE_DELETING or accepted_volume.resource_version != applied_revision or
                volume == null or !volumesEqual(volume.?, accepted_volume) or !was_live) return error.PayloadParseFailed;
        },
        .DELETE_VOLUME_APPLY_CODE_NOT_FOUND => {
            if (!response_is_empty or was_live) return error.PayloadParseFailed;
        },
        .DELETE_VOLUME_APPLY_CODE_VERSION_CONFLICT => {
            if (!response_is_empty or !was_live or volume.?.resource_version == command.expected_resource_version) return error.PayloadParseFailed;
        },
        .DELETE_VOLUME_APPLY_CODE_HAS_DEPENDENCIES => {
            if (!response_is_empty or !was_live or volume.?.resource_version != command.expected_resource_version or !hasVolumeDependenciesBefore(state, command.volume_id, applied_revision)) return error.PayloadParseFailed;
        },
        .DELETE_VOLUME_APPLY_CODE_TOMBSTONE_LIMIT => {
            if (!response_is_empty or !was_live or volume.?.resource_version != command.expected_resource_version or
                hasVolumeDependenciesBefore(state, command.volume_id, applied_revision) or tombstoneCountBefore(state, applied_revision) != max_volume_tombstones or
                state.max_volume_deleted_revision >= applied_revision)
            {
                return error.PayloadParseFailed;
            }
        },
        else => return error.PayloadParseFailed,
    }
    return false;
}

fn validateStoredUpdateVolumeResponse(state: *const State, command: pb.UpdateVolumeCommand, response: pb.UpdateVolumeApplyResponse, applied_revision: u64) raft.Error!void {
    switch (response.code) {
        .UPDATE_VOLUME_APPLY_CODE_UPDATED => {
            const response_volume = response.volume orelse return error.PayloadParseFailed;
            const stored = storedVolumeById(state, command.volume_id) orelse return error.PayloadParseFailed;
            if (!std.mem.eql(u8, response_volume.id, command.volume_id) or !std.mem.eql(u8, response_volume.description, command.description) or
                response_volume.resource_version != applied_revision or response_volume.generation < 2 or
                stored.created_revision != response_volume.created_revision or stored.generation < response_volume.generation or stored.resource_version < applied_revision) return error.PayloadParseFailed;
        },
        .UPDATE_VOLUME_APPLY_CODE_NOT_FOUND => if (response.volume != null or volumeWasLiveAt(state, command.volume_id, applied_revision)) return error.PayloadParseFailed,
        .UPDATE_VOLUME_APPLY_CODE_VERSION_CONFLICT, .UPDATE_VOLUME_APPLY_CODE_INVALID_STATE => {
            const response_volume = response.volume orelse return error.PayloadParseFailed;
            if (!std.mem.eql(u8, response_volume.id, command.volume_id) or response_volume.created_revision >= applied_revision) return error.PayloadParseFailed;
        },
        else => return error.PayloadParseFailed,
    }
}

fn storedVolumeById(state: *const State, id: []const u8) ?pb.Volume {
    if (state.volumes_by_id.get(id)) |volume| return volume.proto();
    if (state.volume_tombstones_by_id.get(id)) |tombstone| return tombstone.volume.proto();
    return null;
}

fn storedVolumeId(state: *const State, id: []const u8) ?[]const u8 {
    if (state.volumes_by_id.get(id)) |volume| return volume.id;
    if (state.volume_tombstones_by_id.get(id)) |tombstone| return tombstone.volume.id;
    return null;
}

fn volumeWasLiveAt(state: *const State, id: []const u8, revision: u64) bool {
    if (state.volumes_by_id.get(id)) |volume| return volume.created_revision < revision;
    if (state.volume_tombstones_by_id.get(id)) |tombstone| return tombstone.volume.created_revision < revision and tombstone.deleted_revision >= revision;
    return false;
}

fn volumeByScopedNameAt(state: *const State, pool_id: []const u8, name: []const u8, revision: u64) ?pb.Volume {
    var iterator = state.volumes_by_id.valueIterator();
    while (iterator.next()) |volume| {
        if (volume.created_revision < revision and std.mem.eql(u8, volume.pool_id, pool_id) and std.mem.eql(u8, volume.name, name)) return volume.proto();
    }
    var tombstone_iterator = state.volume_tombstones_by_id.valueIterator();
    while (tombstone_iterator.next()) |tombstone| {
        const volume = tombstone.volume;
        if (volume.created_revision < revision and tombstone.deleted_revision >= revision and std.mem.eql(u8, volume.pool_id, pool_id) and std.mem.eql(u8, volume.name, name)) return volume.proto();
    }
    return null;
}

fn liveVolumeCountAt(state: *const State, revision: u64) usize {
    var count: usize = 0;
    var iterator = state.volumes_by_id.valueIterator();
    while (iterator.next()) |volume| if (volume.created_revision < revision) {
        count += 1;
    };
    var tombstone_iterator = state.volume_tombstones_by_id.valueIterator();
    while (tombstone_iterator.next()) |tombstone| if (tombstone.volume.created_revision < revision and tombstone.deleted_revision >= revision) {
        count += 1;
    };
    return count;
}

fn tombstoneCountBefore(state: *const State, revision: u64) usize {
    var count: usize = 0;
    var iterator = state.volume_tombstones_by_id.valueIterator();
    while (iterator.next()) |tombstone| if (tombstone.deleted_revision < revision) {
        count += 1;
    };
    return count;
}

fn memberLocalSetPoolBefore(state: *const State, local_set_id: []const u8, revision: u64) ?[]const u8 {
    for (state.member_ids_by_revision.items) |id| {
        const member = state.members_by_id.get(id).?;
        if (member.registered_revision >= revision) break;
        if (std.mem.eql(u8, member.local_set_id, local_set_id)) return member.pool_id;
    }
    return null;
}

fn poolsEqual(lhs: pb.Pool, rhs: pb.Pool) bool {
    return std.mem.eql(u8, lhs.id, rhs.id) and
        std.mem.eql(u8, lhs.name, rhs.name) and
        std.mem.eql(u8, lhs.description, rhs.description) and
        lhs.created_at_unix_ms == rhs.created_at_unix_ms and
        lhs.created_revision == rhs.created_revision;
}

fn nodesEqual(lhs: pb.Node, rhs: pb.Node) bool {
    return std.mem.eql(u8, lhs.id, rhs.id) and
        std.mem.eql(u8, lhs.cluster_id, rhs.cluster_id) and
        std.mem.eql(u8, lhs.control_endpoint, rhs.control_endpoint) and
        std.mem.eql(u8, lhs.nvmf_endpoint, rhs.nvmf_endpoint) and
        std.mem.eql(u8, lhs.failure_domain, rhs.failure_domain) and
        lhs.capability_bits == rhs.capability_bits and
        lhs.protocol_version == rhs.protocol_version and
        lhs.registered_at_unix_ms == rhs.registered_at_unix_ms and
        lhs.registered_revision == rhs.registered_revision;
}

fn membersEqual(lhs: pb.Member, rhs: pb.Member) bool {
    return std.mem.eql(u8, lhs.id, rhs.id) and
        std.mem.eql(u8, lhs.pool_id, rhs.pool_id) and
        std.mem.eql(u8, lhs.node_id, rhs.node_id) and
        std.mem.eql(u8, lhs.local_set_id, rhs.local_set_id) and
        lhs.member_slot == rhs.member_slot and
        std.mem.eql(u8, lhs.birth_topology_digest, rhs.birth_topology_digest) and
        lhs.metadata_capacity_bytes == rhs.metadata_capacity_bytes and
        lhs.data_capacity_bytes == rhs.data_capacity_bytes and
        lhs.extent_size_bytes == rhs.extent_size_bytes and
        lhs.registered_at_unix_ms == rhs.registered_at_unix_ms and
        lhs.registered_revision == rhs.registered_revision;
}

fn volumesEqual(lhs: pb.Volume, rhs: pb.Volume) bool {
    return std.mem.eql(u8, lhs.id, rhs.id) and
        std.mem.eql(u8, lhs.pool_id, rhs.pool_id) and
        std.mem.eql(u8, lhs.name, rhs.name) and
        std.mem.eql(u8, lhs.description, rhs.description) and
        lhs.size_bytes == rhs.size_bytes and lhs.protection_kind == rhs.protection_kind and
        lhs.target_replica_count == rhs.target_replica_count and lhs.write_quorum == rhs.write_quorum and
        lhs.read_quorum == rhs.read_quorum and lhs.lifecycle_state == rhs.lifecycle_state and
        lhs.availability_state == rhs.availability_state and lhs.operation_phase == rhs.operation_phase and
        lhs.generation == rhs.generation and lhs.write_epoch == rhs.write_epoch and
        lhs.placement_revision == rhs.placement_revision and lhs.created_at_unix_ms == rhs.created_at_unix_ms and
        lhs.created_revision == rhs.created_revision and lhs.resource_version == rhs.resource_version;
}

fn dupePool(allocator: std.mem.Allocator, source: pb.Pool) !pb.Pool {
    const owned = try Pool.init(allocator, source);
    return owned.proto();
}

fn dupeNode(allocator: std.mem.Allocator, source: pb.Node) !pb.Node {
    const owned = try Node.init(allocator, source);
    return owned.proto();
}

fn dupeMember(allocator: std.mem.Allocator, source: pb.Member) !pb.Member {
    const owned = try Member.init(allocator, source);
    return owned.proto();
}

fn dupeVolume(allocator: std.mem.Allocator, source: pb.Volume) !pb.Volume {
    var owned = try Volume.init(allocator, source);
    allocator.free(owned.scoped_name);
    owned.scoped_name = undefined;
    return owned.proto();
}

fn dupeReplicaPlacement(allocator: std.mem.Allocator, source: pb.ReplicaPlacement) !pb.ReplicaPlacement {
    var owned = try ReplicaPlacement.init(allocator, source);
    allocator.free(owned.replica_key);
    owned.replica_key = undefined;
    return owned.proto();
}

fn dupeReplicaAllocation(allocator: std.mem.Allocator, source: pb.ReplicaAllocation) !pb.ReplicaAllocation {
    const owned = try ReplicaAllocation.init(allocator, source);
    return owned.proto();
}

fn dupePrimaryAuthority(allocator: std.mem.Allocator, source: pb.PrimaryAuthority) !pb.PrimaryAuthority {
    const owned = try PrimaryAuthority.init(allocator, source);
    return owned.proto();
}

fn dupePrimaryFailover(allocator: std.mem.Allocator, source: pb.PrimaryFailover) !pb.PrimaryFailover {
    const owned = try PrimaryFailover.init(allocator, source);
    return owned.proto();
}

fn authorityProposalMatches(existing: pb.PrimaryAuthority, proposed: pb.PrimaryAuthority) bool {
    return std.mem.eql(u8, existing.volume_id, proposed.volume_id) and
        std.mem.eql(u8, existing.primary_placement_id, proposed.primary_placement_id) and
        std.mem.eql(u8, existing.primary_node_id, proposed.primary_node_id) and
        std.mem.eql(u8, existing.lease_id, proposed.lease_id) and
        std.mem.eql(u8, existing.holder_boot_id, proposed.holder_boot_id) and
        existing.authority_generation == proposed.authority_generation and existing.write_epoch == proposed.write_epoch and
        existing.placement_revision == proposed.placement_revision and std.mem.eql(u8, existing.activation_nonce, proposed.activation_nonce) and
        existing.lease_duration_ms == proposed.lease_duration_ms and std.mem.eql(u8, existing.authority_digest, proposed.authority_digest);
}

fn renewalProposalValid(current: PrimaryAuthority, proposed: pb.PrimaryAuthority) bool {
    return current.state == .PRIMARY_AUTHORITY_STATE_READY and proposed.state != .PRIMARY_AUTHORITY_STATE_READY and
        std.mem.eql(u8, current.volume_id, proposed.volume_id) and
        std.mem.eql(u8, current.primary_placement_id, proposed.primary_placement_id) and
        std.mem.eql(u8, current.primary_node_id, proposed.primary_node_id) and
        std.mem.eql(u8, current.holder_boot_id, proposed.holder_boot_id) and
        current.authority_generation != std.math.maxInt(u64) and proposed.authority_generation == current.authority_generation + 1 and
        current.write_epoch == proposed.write_epoch and current.placement_revision == proposed.placement_revision and
        current.lease_duration_ms == proposed.lease_duration_ms and
        !std.mem.eql(u8, current.lease_id, proposed.lease_id) and
        !std.mem.eql(u8, current.activation_nonce, proposed.activation_nonce) and
        !std.mem.eql(u8, current.authority_digest, proposed.authority_digest);
}

fn failoverProposalValid(failover: PrimaryFailover, current: PrimaryAuthority, proposed: pb.PrimaryAuthority, volume: Volume) bool {
    return current.state == .PRIMARY_AUTHORITY_STATE_READY and
        std.mem.eql(u8, failover.volume_id, current.volume_id) and std.mem.eql(u8, failover.revoked_lease_id, current.lease_id) and
        failover.revoked_authority_generation == current.authority_generation and failover.revoked_write_epoch == current.write_epoch and
        failover.target_write_epoch > current.write_epoch and
        (failover.state == .PRIMARY_FAILOVER_STATE_LEASE_EXPIRED or failover.state == .PRIMARY_FAILOVER_STATE_FENCING) and
        (volume.write_epoch == failover.revoked_write_epoch or volume.write_epoch == failover.target_write_epoch) and
        std.mem.eql(u8, proposed.volume_id, current.volume_id) and !std.mem.eql(u8, proposed.primary_placement_id, current.primary_placement_id) and
        !std.mem.eql(u8, proposed.primary_node_id, current.primary_node_id) and proposed.authority_generation == current.authority_generation + 1 and
        proposed.write_epoch == failover.target_write_epoch and proposed.placement_revision == current.placement_revision and
        proposed.lease_duration_ms == current.lease_duration_ms and proposed.state != .PRIMARY_AUTHORITY_STATE_READY and
        !std.mem.eql(u8, proposed.lease_id, current.lease_id) and !std.mem.eql(u8, proposed.activation_nonce, current.activation_nonce) and
        !std.mem.eql(u8, proposed.authority_digest, current.authority_digest);
}

fn activationCommandMatches(authority: PrimaryAuthority, command: pb.ActivatePrimaryAuthorityCommand) bool {
    return std.mem.eql(u8, authority.volume_id, command.volume_id) and std.mem.eql(u8, authority.lease_id, command.lease_id) and
        std.mem.eql(u8, authority.activation_nonce, command.activation_nonce) and authority.authority_generation == command.authority_generation and
        authority.write_epoch == command.write_epoch and authority.placement_revision == command.placement_revision;
}

fn readyCommandMatches(authority: PrimaryAuthority, command: pb.CommitPrimaryAuthorityReadyCommand) bool {
    return std.mem.eql(u8, authority.volume_id, command.volume_id) and std.mem.eql(u8, authority.lease_id, command.lease_id) and
        std.mem.eql(u8, authority.authority_digest, command.authority_digest) and authority.authority_generation == command.authority_generation and
        authority.write_epoch == command.write_epoch and authority.placement_revision == command.placement_revision;
}

fn renewalReadyCommandMatches(authority: PrimaryAuthority, command: pb.CommitPrimaryAuthorityRenewalReadyCommand) bool {
    return std.mem.eql(u8, authority.volume_id, command.volume_id) and std.mem.eql(u8, authority.lease_id, command.lease_id) and
        authority.authority_generation == command.authority_generation and authority.write_epoch == command.write_epoch and
        authority.placement_revision == command.placement_revision;
}

fn renewalFailoverReadyCommandMatches(authority: PrimaryAuthority, command: pb.CommitPrimaryAuthorityFailoverReadyCommand) bool {
    return std.mem.eql(u8, authority.volume_id, command.volume_id) and std.mem.eql(u8, authority.lease_id, command.lease_id) and
        std.mem.eql(u8, authority.authority_digest, command.authority_digest) and authority.authority_generation == command.authority_generation and
        authority.write_epoch == command.write_epoch and authority.placement_revision == command.placement_revision;
}

fn activePlacementSetValid(state: *const State, volume: Volume, primary_placement_id: []const u8, primary_node_id: []const u8) bool {
    var count: usize = 0;
    var found_primary = false;
    var iterator = state.replica_placements_by_id.valueIterator();
    while (iterator.next()) |placement| {
        if (!std.mem.eql(u8, placement.volume_id, volume.id)) continue;
        count += 1;
        if (placement.state != .REPLICA_PLACEMENT_STATE_ACTIVE or placement.generation != volume.generation or
            placement.backend_digest.len != 32 or placement.attested_revision == 0) return false;
        const allocation_id = state.allocation_ids_by_replica.get(placement.id) orelse return false;
        const allocation = state.replica_allocations_by_id.get(allocation_id) orelse return false;
        if (allocation.state != .REPLICA_ALLOCATION_STATE_ACTIVE or allocation.generation != placement.generation) return false;
        if (std.mem.eql(u8, placement.id, primary_placement_id)) {
            if (!std.mem.eql(u8, placement.node_id, primary_node_id)) return false;
            found_primary = true;
        }
    }
    return count == volume_target_replica_count and found_primary;
}

fn readyEvidenceValid(state: *const State, volume: Volume, authority: PrimaryAuthority, evidence: []const pb.ReplicaFenceEvidence, recovery: pb.RecoveryEvidence) bool {
    if (!std.mem.eql(u8, recovery.volume_id, volume.id) or recovery.write_epoch != authority.write_epoch or
        (recovery.certified_sequence == 0) != recovery.empty_frontier) return false;
    var covered: [volume_target_replica_count]bool = @splat(false);
    for (evidence) |proof| {
        if (proof.write_epoch != authority.write_epoch or !std.mem.eql(u8, proof.lease_id, authority.lease_id) or
            !std.mem.eql(u8, proof.authority_digest, authority.authority_digest)) return false;
        var matched = false;
        for (0..volume_target_replica_count) |index| {
            var key_buffer: [37]u8 = undefined;
            const placement_id = state.replica_ids_by_volume_index.get(replicaKey(volume.id, @intCast(index), &key_buffer)) orelse return false;
            if (!std.mem.eql(u8, placement_id, proof.placement_id)) continue;
            if (covered[index]) return false;
            const placement = state.replica_placements_by_id.get(placement_id) orelse return false;
            if (placement.state != .REPLICA_PLACEMENT_STATE_ACTIVE or placement.generation != proof.replica_generation) return false;
            covered[index] = true;
            matched = true;
            break;
        }
        if (!matched) return false;
    }
    for (covered) |value| if (!value) return false;
    return true;
}

fn hasVolumeDependencies(state: *const State, volume_id: []const u8) bool {
    if (state.primary_authorities_by_volume.contains(volume_id)) return true;
    if (state.primary_authority_candidates_by_volume.contains(volume_id)) return true;
    if (state.primary_failovers_by_volume.contains(volume_id)) return true;
    var replica_iterator = state.replica_placements_by_id.valueIterator();
    while (replica_iterator.next()) |replica| if (std.mem.eql(u8, replica.volume_id, volume_id)) return true;
    var attachment_iterator = state.volume_attachments_by_id.valueIterator();
    while (attachment_iterator.next()) |attachment| if (std.mem.eql(u8, attachment.volume_id, volume_id)) return true;
    return false;
}

fn validateReservations(state: *const State, volume: Volume, reservations: []const pb.ReplicaReservation) !void {
    for (reservations, 0..) |reservation, index| {
        const placement = reservation.placement.?;
        const allocation = reservation.allocation.?;
        if (placement.replica_index != index or placement.generation != volume.generation or
            state.replica_placements_by_id.contains(placement.id) or state.replica_allocations_by_id.contains(allocation.id)) return error.InvalidReservation;
        const node = state.nodes_by_id.get(placement.node_id) orelse return error.InvalidReservation;
        const member = state.members_by_id.get(allocation.member_id) orelse return error.InvalidReservation;
        if (!std.mem.eql(u8, member.pool_id, volume.pool_id) or !std.mem.eql(u8, member.node_id, placement.node_id)) return error.InvalidReservation;
        const extent = @as(u64, member.extent_size_bytes);
        const rounded_length = std.math.add(u64, volume.size_bytes, extent - 1) catch return error.InvalidReservation;
        const expected_length = rounded_length / extent * extent;
        const end = std.math.add(u64, allocation.offset_bytes, allocation.length_bytes) catch return error.InvalidReservation;
        if (allocation.length_bytes != expected_length or allocation.offset_bytes % extent != 0 or end > member.data_capacity_bytes) return error.InvalidReservation;
        var existing_iterator = state.replica_allocations_by_id.valueIterator();
        while (existing_iterator.next()) |existing| {
            if (!std.mem.eql(u8, existing.member_id, allocation.member_id)) continue;
            const existing_end = existing.offset_bytes + existing.length_bytes;
            if (allocation.offset_bytes < existing_end and existing.offset_bytes < end) return error.InvalidReservation;
        }
        for (reservations[0..index]) |prior_reservation| {
            const prior_placement = prior_reservation.placement.?;
            const prior_allocation = prior_reservation.allocation.?;
            const prior_node = state.nodes_by_id.get(prior_placement.node_id).?;
            if (std.mem.eql(u8, prior_placement.id, placement.id) or std.mem.eql(u8, prior_allocation.id, allocation.id) or
                std.mem.eql(u8, prior_placement.node_id, placement.node_id) or std.mem.eql(u8, prior_node.failure_domain, node.failure_domain)) return error.InvalidReservation;
            if (std.mem.eql(u8, prior_allocation.member_id, allocation.member_id)) {
                const prior_end = prior_allocation.offset_bytes + prior_allocation.length_bytes;
                if (allocation.offset_bytes < prior_end and prior_allocation.offset_bytes < end) return error.InvalidReservation;
            }
        }
    }
}

fn firstFitAllocationOffset(state: *const State, allocator: std.mem.Allocator, member: Member, length: u64) !?u64 {
    const Interval = struct { offset: u64, end: u64 };
    var intervals: std.ArrayList(Interval) = .empty;
    defer intervals.deinit(allocator);
    var allocations = state.replica_allocations_by_id.valueIterator();
    while (allocations.next()) |allocation| {
        if (!std.mem.eql(u8, allocation.member_id, member.id)) continue;
        const end = std.math.add(u64, allocation.offset_bytes, allocation.length_bytes) catch return error.InvalidPersistentAllocation;
        if (end > member.data_capacity_bytes) return error.InvalidPersistentAllocation;
        try intervals.append(allocator, .{ .offset = allocation.offset_bytes, .end = end });
    }
    std.mem.sort(Interval, intervals.items, {}, struct {
        fn lessThan(_: void, lhs: Interval, rhs: Interval) bool {
            return lhs.offset < rhs.offset or (lhs.offset == rhs.offset and lhs.end < rhs.end);
        }
    }.lessThan);
    var cursor: u64 = 0;
    for (intervals.items) |interval| {
        if (interval.offset > cursor and interval.offset - cursor >= length) return cursor;
        cursor = @max(cursor, interval.end);
    }
    if (cursor <= member.data_capacity_bytes and member.data_capacity_bytes - cursor >= length) return cursor;
    return null;
}

fn containsString(values: []const []const u8, target: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, target)) return true;
    return false;
}

fn deletionProofMatches(state: *const State, volume_id: []const u8, placement_ids: []const []const u8, allocation_ids: []const []const u8) bool {
    var placement_count: usize = 0;
    var placement_iterator = state.replica_placements_by_id.valueIterator();
    while (placement_iterator.next()) |placement| if (std.mem.eql(u8, placement.volume_id, volume_id)) {
        placement_count += 1;
        if (!containsString(placement_ids, placement.id)) return false;
    };
    var allocation_count: usize = 0;
    var allocation_iterator = state.replica_allocations_by_id.valueIterator();
    while (allocation_iterator.next()) |allocation| {
        const placement = state.replica_placements_by_id.get(allocation.replica_id) orelse return false;
        if (!std.mem.eql(u8, placement.volume_id, volume_id)) continue;
        allocation_count += 1;
        if (!containsString(allocation_ids, allocation.id)) return false;
    }
    if (placement_count != placement_ids.len or allocation_count != allocation_ids.len) return false;
    for (placement_ids, 0..) |id, index| if (containsString(placement_ids[0..index], id)) return false;
    for (allocation_ids, 0..) |id, index| if (containsString(allocation_ids[0..index], id)) return false;
    return true;
}

fn removeVolumeChildren(self: *PoolStateMachine, volume_id: []const u8) void {
    if (self.state.primary_failovers_by_volume.fetchRemove(volume_id)) |removed_value| {
        var removed_failover = removed_value.value;
        removed_failover.deinit(self.allocator);
    }
    if (self.state.primary_authority_candidates_by_volume.fetchRemove(volume_id)) |removed_value| {
        var removed_authority = removed_value.value;
        removed_authority.deinit(self.allocator);
    }
    if (self.state.primary_authorities_by_volume.fetchRemove(volume_id)) |removed_value| {
        var removed_authority = removed_value.value;
        removed_authority.deinit(self.allocator);
    }
    var placement_ids: [volume_target_replica_count][]const u8 = undefined;
    var placement_count: usize = 0;
    var placement_iterator = self.state.replica_placements_by_id.valueIterator();
    while (placement_iterator.next()) |placement| if (std.mem.eql(u8, placement.volume_id, volume_id)) {
        placement_ids[placement_count] = placement.id;
        placement_count += 1;
    };
    var allocation_ids: [volume_target_replica_count][]const u8 = undefined;
    var allocation_count: usize = 0;
    var allocation_iterator = self.state.replica_allocations_by_id.valueIterator();
    while (allocation_iterator.next()) |allocation| if (containsString(placement_ids[0..placement_count], allocation.replica_id)) {
        allocation_ids[allocation_count] = allocation.id;
        allocation_count += 1;
    };
    for (allocation_ids[0..allocation_count]) |id| {
        var removed = self.state.replica_allocations_by_id.fetchRemove(id).?.value;
        _ = self.state.allocation_ids_by_replica.remove(removed.replica_id);
        removed.deinit(self.allocator);
    }
    for (placement_ids[0..placement_count]) |id| {
        var removed = self.state.replica_placements_by_id.fetchRemove(id).?.value;
        _ = self.state.replica_ids_by_volume_index.remove(removed.replica_key);
        removed.deinit(self.allocator);
    }
}

fn hasVolumeDependenciesBefore(state: *const State, volume_id: []const u8, revision: u64) bool {
    var replica_iterator = state.replica_placements_by_id.valueIterator();
    while (replica_iterator.next()) |replica| if (replica.created_revision < revision and std.mem.eql(u8, replica.volume_id, volume_id)) return true;
    var attachment_iterator = state.volume_attachments_by_id.valueIterator();
    while (attachment_iterator.next()) |attachment| if (attachment.created_revision < revision and std.mem.eql(u8, attachment.volume_id, volume_id)) return true;
    return false;
}

fn memberSlotKey(local_set_id: []const u8, member_slot: u32) MemberSlotKey {
    var key: MemberSlotKey = undefined;
    @memcpy(&key.local_set_id, local_set_id);
    key.member_slot = @intCast(member_slot);
    return key;
}

const preflightCommand = preflight.preflightCommand;
const preflightSnapshot = preflight.preflightSnapshot;

fn poolRevisionIdLessThan(state: *State, lhs_id: []const u8, rhs_id: []const u8) bool {
    const lhs = state.pools_by_id.get(lhs_id).?;
    const rhs = state.pools_by_id.get(rhs_id).?;
    if (lhs.created_revision != rhs.created_revision) return lhs.created_revision < rhs.created_revision;
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn nodeRevisionIdLessThan(state: *State, lhs_id: []const u8, rhs_id: []const u8) bool {
    const lhs = state.nodes_by_id.get(lhs_id).?;
    const rhs = state.nodes_by_id.get(rhs_id).?;
    if (lhs.registered_revision != rhs.registered_revision) return lhs.registered_revision < rhs.registered_revision;
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn memberRevisionIdLessThan(state: *State, lhs_id: []const u8, rhs_id: []const u8) bool {
    const lhs = state.members_by_id.get(lhs_id).?;
    const rhs = state.members_by_id.get(rhs_id).?;
    if (lhs.registered_revision != rhs.registered_revision) return lhs.registered_revision < rhs.registered_revision;
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn volumeRevisionIdLessThan(state: *State, lhs_id: []const u8, rhs_id: []const u8) bool {
    const lhs = state.volumes_by_id.get(lhs_id).?;
    const rhs = state.volumes_by_id.get(rhs_id).?;
    if (lhs.created_revision != rhs.created_revision) return lhs.created_revision < rhs.created_revision;
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn poolIdLessThan(_: void, lhs: pb.Pool, rhs: pb.Pool) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn nodeIdLessThan(_: void, lhs: pb.Node, rhs: pb.Node) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn memberIdLessThan(_: void, lhs: pb.Member, rhs: pb.Member) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn volumeIdLessThan(_: void, lhs: pb.Volume, rhs: pb.Volume) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn volumeTombstoneIdLessThan(_: void, lhs: pb.VolumeTombstone, rhs: pb.VolumeTombstone) bool {
    return std.mem.order(u8, lhs.volume.?.id, rhs.volume.?.id) == .lt;
}

fn replicaPlacementIdLessThan(_: void, lhs: pb.ReplicaPlacement, rhs: pb.ReplicaPlacement) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn replicaAllocationIdLessThan(_: void, lhs: pb.ReplicaAllocation, rhs: pb.ReplicaAllocation) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn volumeAttachmentIdLessThan(_: void, lhs: pb.VolumeAttachment, rhs: pb.VolumeAttachment) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn primaryAuthorityVolumeIdLessThan(_: void, lhs: pb.PrimaryAuthority, rhs: pb.PrimaryAuthority) bool {
    return std.mem.lessThan(u8, lhs.volume_id, rhs.volume_id);
}

fn primaryFailoverVolumeIdLessThan(_: void, lhs: pb.PrimaryFailover, rhs: pb.PrimaryFailover) bool {
    return std.mem.lessThan(u8, lhs.volume_id, rhs.volume_id);
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

const test_cluster_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_pool_id = "0198f54d-5c2a-7000-8000-000000000001";
const test_second_pool_id = "0198f54d-5c2a-7000-8000-000000000002";
const test_node_id = "0198f54d-5c2a-7000-8000-000000000011";
const test_second_node_id = "0198f54d-5c2a-7000-8000-000000000012";
const test_third_node_id = "0198f54d-5c2a-7000-8000-000000000013";
const test_volume_id = "0198f54d-5c2a-7000-8000-000000000021";
const test_second_volume_id = "0198f54d-5c2a-7000-8000-000000000022";
const test_replica_id = "0198f54d-5c2a-7000-8000-000000000031";
const test_second_replica_id = "0198f54d-5c2a-7000-8000-000000000032";
const test_third_replica_id = "0198f54d-5c2a-7000-8000-000000000033";
const test_allocation_id = "0198f54d-5c2a-7000-8000-000000000041";
const test_second_allocation_id = "0198f54d-5c2a-7000-8000-000000000042";
const test_third_allocation_id = "0198f54d-5c2a-7000-8000-000000000043";
const test_attachment_id = "0198f54d-5c2a-7000-8000-000000000051";
const test_member_id_a = [_]u8{ 0x10, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_member_id_b = [_]u8{ 0x20, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_member_id_c = [_]u8{ 0x30, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_local_set_id = [_]u8{ 0x40, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_birth_topology_digest: [32]u8 = @splat(0x5a);
const test_backend_digest: [32]u8 = @splat(0xa5);
const test_lease_id: [16]u8 = @splat(0x11);
const test_holder_boot_id: [16]u8 = @splat(0x22);
const test_activation_nonce: [16]u8 = @splat(0x33);
const test_authority_digest: [32]u8 = @splat(0x44);
const test_renewal_lease_id: [16]u8 = @splat(0x66);
const test_renewal_nonce: [16]u8 = @splat(0x77);
const test_renewal_digest: [32]u8 = @splat(0x88);
const test_failover_id: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 4, 1 };
const test_failover_lease_id: [16]u8 = @splat(0x91);
const test_failover_nonce: [16]u8 = @splat(0x92);
const test_failover_digest: [32]u8 = @splat(0x93);
const test_fence_digest: [32]u8 = @splat(0x55);
const test_recovery_digest: [32]u8 = @splat(0x66);

fn testNodeCommand(request_id: []const u8, node_id: []const u8, control_endpoint: []const u8, timestamp: i64) pb.RegisterNodeCommand {
    return .{
        .request_id = request_id,
        .node_id = node_id,
        .cluster_id = &test_cluster_id,
        .control_endpoint = control_endpoint,
        .nvmf_endpoint = "127.0.0.1:4420",
        .failure_domain = "rack-a",
        .capability_bits = 5,
        .protocol_version = 1,
        .proposed_registered_at_unix_ms = timestamp,
    };
}

fn applyTestNodeCommand(allocator: std.mem.Allocator, machine: *PoolStateMachine, index: u64, command: pb.RegisterNodeCommand) !raft.ApplyResult {
    const encoded = try encodeRegisterNodeCommand(allocator, command);
    defer allocator.free(encoded);
    return machine.stateMachine().apply(.{ .index = index, .term = 1, .data = encoded });
}

fn testMemberCommand(
    request_id: []const u8,
    member_id: []const u8,
    pool_id: []const u8,
    node_id: []const u8,
    local_set_id: []const u8,
    member_slot: u32,
    timestamp: i64,
) pb.RegisterMemberCommand {
    return .{
        .request_id = request_id,
        .cluster_id = &test_cluster_id,
        .member_id = member_id,
        .pool_id = pool_id,
        .node_id = node_id,
        .local_set_id = local_set_id,
        .member_slot = member_slot,
        .birth_topology_digest = &test_birth_topology_digest,
        .metadata_capacity_bytes = 1024,
        .data_capacity_bytes = 8192,
        .extent_size_bytes = 4096,
        .proposed_registered_at_unix_ms = timestamp,
    };
}

fn applyTestMemberCommand(allocator: std.mem.Allocator, machine: *PoolStateMachine, index: u64, command: pb.RegisterMemberCommand) !raft.ApplyResult {
    const encoded = try encodeRegisterMemberCommand(allocator, command);
    defer allocator.free(encoded);
    return machine.stateMachine().apply(.{ .index = index, .term = 1, .data = encoded });
}

fn testVolumeCommand(request_id: []const u8, volume_id: []const u8, name: []const u8, description: []const u8, size_bytes: u64, timestamp: i64) pb.CreateVolumeCommand {
    return .{
        .request_id = request_id,
        .proposed_volume_id = volume_id,
        .pool_id = test_pool_id,
        .name = name,
        .description = description,
        .size_bytes = size_bytes,
        .proposed_created_at_unix_ms = timestamp,
    };
}

fn applyTestVolumeCommand(allocator: std.mem.Allocator, machine: *PoolStateMachine, index: u64, command: pb.CreateVolumeCommand) !raft.ApplyResult {
    const encoded = try encodeCreateVolumeCommand(allocator, command);
    defer allocator.free(encoded);
    return machine.stateMachine().apply(.{ .index = index, .term = 1, .data = encoded });
}

fn testDeleteVolumeCommand(request_id: []const u8, volume_id: []const u8, expected_resource_version: u64, timestamp: i64) pb.DeleteVolumeCommand {
    return .{ .request_id = request_id, .volume_id = volume_id, .expected_resource_version = expected_resource_version, .proposed_deleted_at_unix_ms = timestamp };
}

fn applyTestDeleteVolumeCommand(allocator: std.mem.Allocator, machine: *PoolStateMachine, index: u64, command: pb.DeleteVolumeCommand) !raft.ApplyResult {
    const encoded = try encodeDeleteVolumeCommand(allocator, command);
    defer allocator.free(encoded);
    return machine.stateMachine().apply(.{ .index = index, .term = 1, .data = encoded });
}

fn addTestPoolAndNode(allocator: std.mem.Allocator, machine: *PoolStateMachine) !void {
    var pool = try applyTestCommand(allocator, machine, 1, testCommand(
        "member-pool-request",
        test_pool_id,
        "member-pool",
        "",
        1_753_744_000_000,
    ));
    defer pool.deinit(allocator);
    var node = try applyTestNodeCommand(allocator, machine, 2, testNodeCommand(
        "member-node-request",
        test_node_id,
        "node-a:9000",
        1_753_744_000_001,
    ));
    defer node.deinit(allocator);
}

fn addTestVolumeTopology(allocator: std.mem.Allocator, machine: *PoolStateMachine) !void {
    return addTestVolumeTopologyWithDomains(allocator, machine, .{ "rack-a", "rack-b", "rack-c" });
}

fn addTestVolumeTopologyWithDomains(allocator: std.mem.Allocator, machine: *PoolStateMachine, domains: [volume_target_replica_count][]const u8) !void {
    var pool = try applyTestCommand(allocator, machine, 1, testCommand("topology-pool", test_pool_id, "primary", "", 1_753_744_000_000));
    defer pool.deinit(allocator);
    const node_ids = [_][]const u8{ test_node_id, test_second_node_id, test_third_node_id };
    for (node_ids, domains, 0..) |node_id, domain, index| {
        var command = testNodeCommand(try std.fmt.allocPrint(allocator, "topology-node-{d}", .{index}), node_id, "node:9000", 1_753_744_000_001 + @as(i64, @intCast(index)));
        defer allocator.free(command.request_id);
        command.failure_domain = domain;
        var applied = try applyTestNodeCommand(allocator, machine, 2 + index, command);
        defer applied.deinit(allocator);
    }
    const member_ids = [_][]const u8{ &test_member_id_a, &test_member_id_b, &test_member_id_c };
    for (member_ids, node_ids, 0..) |member_id, node_id, index| {
        const request_id = try std.fmt.allocPrint(allocator, "topology-member-{d}", .{index});
        defer allocator.free(request_id);
        var command = testMemberCommand(request_id, member_id, test_pool_id, node_id, &test_local_set_id, @intCast(index), 1_753_744_000_004 + @as(i64, @intCast(index)));
        command.data_capacity_bytes = 1024 * 1024;
        var applied = try applyTestMemberCommand(allocator, machine, 5 + index, command);
        defer applied.deinit(allocator);
    }
}

test "reservation planner is deterministic and avoids durable allocations" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try addTestVolumeTopology(allocator, &machine);
    var created = try applyTestVolumeCommand(allocator, &machine, 8, testVolumeCommand("planner-first", test_volume_id, "first", "", min_volume_size_bytes, 1_753_744_000_010));
    defer created.deinit(allocator);

    const placement_ids = [volume_target_replica_count][]const u8{ test_replica_id, test_second_replica_id, test_third_replica_id };
    const allocation_ids = [volume_target_replica_count][]const u8{ test_allocation_id, test_second_allocation_id, test_third_allocation_id };
    const first = try machine.buildVolumeReservations(allocator, test_volume_id, placement_ids, allocation_ids);
    defer deinitReplicaReservations(allocator, first);
    const repeated = try machine.buildVolumeReservations(allocator, test_volume_id, placement_ids, allocation_ids);
    defer deinitReplicaReservations(allocator, repeated);
    for (first, repeated) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs.placement.?.node_id, rhs.placement.?.node_id);
        try std.testing.expectEqualSlices(u8, lhs.allocation.?.member_id, rhs.allocation.?.member_id);
        try std.testing.expectEqual(lhs.allocation.?.offset_bytes, rhs.allocation.?.offset_bytes);
        try std.testing.expectEqual(@as(u64, 0), lhs.allocation.?.offset_bytes);
    }

    const reserve = try encodeReserveVolumeResourcesCommand(allocator, .{
        .volume_id = test_volume_id,
        .expected_resource_version = 8,
        .reservations = .{ .items = first, .capacity = first.len },
    });
    defer allocator.free(reserve);
    var applied = try applyEncodedTestCommand(allocator, &machine, 9, reserve);
    defer applied.deinit(allocator);
    var second = try applyTestVolumeCommand(allocator, &machine, 10, testVolumeCommand("planner-second", test_second_volume_id, "second", "", min_volume_size_bytes, 1_753_744_000_011));
    defer second.deinit(allocator);
    const next_placement_ids = [volume_target_replica_count][]const u8{
        "0198f54d-5c2a-7000-8000-000000000061",
        "0198f54d-5c2a-7000-8000-000000000062",
        "0198f54d-5c2a-7000-8000-000000000063",
    };
    const next_allocation_ids = [volume_target_replica_count][]const u8{
        "0198f54d-5c2a-7000-8000-000000000071",
        "0198f54d-5c2a-7000-8000-000000000072",
        "0198f54d-5c2a-7000-8000-000000000073",
    };
    const next = try machine.buildVolumeReservations(allocator, test_second_volume_id, next_placement_ids, next_allocation_ids);
    defer deinitReplicaReservations(allocator, next);
    for (next) |reservation| try std.testing.expectEqual(min_volume_size_bytes, reservation.allocation.?.offset_bytes);
}

test "reservation planner distinguishes failure domains from fragmented capacity" {
    const allocator = std.testing.allocator;
    const placement_ids = [volume_target_replica_count][]const u8{ test_replica_id, test_second_replica_id, test_third_replica_id };
    const allocation_ids = [volume_target_replica_count][]const u8{ test_allocation_id, test_second_allocation_id, test_third_allocation_id };

    var placement_machine = PoolStateMachine.init(allocator);
    defer placement_machine.deinit();
    try addTestVolumeTopologyWithDomains(allocator, &placement_machine, .{ "rack-a", "rack-a", "rack-b" });
    var placement_volume = try applyTestVolumeCommand(allocator, &placement_machine, 8, testVolumeCommand("planner-placement", test_volume_id, "placement", "", min_volume_size_bytes, 1_753_744_000_010));
    defer placement_volume.deinit(allocator);
    try std.testing.expectError(error.InsufficientPlacement, placement_machine.buildVolumeReservations(allocator, test_volume_id, placement_ids, allocation_ids));

    var capacity_machine = PoolStateMachine.init(allocator);
    defer capacity_machine.deinit();
    try addTestVolumeTopology(allocator, &capacity_machine);
    var first_volume = try applyTestVolumeCommand(allocator, &capacity_machine, 8, testVolumeCommand("planner-fragment", test_volume_id, "fragment", "", min_volume_size_bytes, 1_753_744_000_010));
    defer first_volume.deinit(allocator);
    var fragmented = testReservations(min_volume_size_bytes);
    for (&fragmented) |*reservation| reservation.allocation.?.offset_bytes = 384 * 1024;
    const encoded = try encodeReserveVolumeResourcesCommand(allocator, .{
        .volume_id = test_volume_id,
        .expected_resource_version = 8,
        .reservations = .{ .items = &fragmented, .capacity = fragmented.len },
    });
    defer allocator.free(encoded);
    var reserved = try applyEncodedTestCommand(allocator, &capacity_machine, 9, encoded);
    defer reserved.deinit(allocator);
    var second_volume = try applyTestVolumeCommand(allocator, &capacity_machine, 10, testVolumeCommand("planner-capacity", test_second_volume_id, "capacity", "", 512 * 1024, 1_753_744_000_011));
    defer second_volume.deinit(allocator);
    try std.testing.expectError(error.InsufficientCapacity, capacity_machine.buildVolumeReservations(allocator, test_second_volume_id, .{
        "0198f54d-5c2a-7000-8000-000000000061",
        "0198f54d-5c2a-7000-8000-000000000062",
        "0198f54d-5c2a-7000-8000-000000000063",
    }, .{
        "0198f54d-5c2a-7000-8000-000000000071",
        "0198f54d-5c2a-7000-8000-000000000072",
        "0198f54d-5c2a-7000-8000-000000000073",
    }));
}

fn testReservations(length_bytes: u64) [volume_target_replica_count]pb.ReplicaReservation {
    const placement_ids = [_][]const u8{ test_replica_id, test_second_replica_id, test_third_replica_id };
    const allocation_ids = [_][]const u8{ test_allocation_id, test_second_allocation_id, test_third_allocation_id };
    const node_ids = [_][]const u8{ test_node_id, test_second_node_id, test_third_node_id };
    const member_ids = [_][]const u8{ &test_member_id_a, &test_member_id_b, &test_member_id_c };
    var reservations: [volume_target_replica_count]pb.ReplicaReservation = undefined;
    for (&reservations, 0..) |*reservation, index| reservation.* = .{
        .placement = .{
            .id = placement_ids[index],
            .volume_id = test_volume_id,
            .node_id = node_ids[index],
            .replica_index = @intCast(index),
            .generation = 1,
            .state = .REPLICA_PLACEMENT_STATE_RESERVED,
        },
        .allocation = .{
            .id = allocation_ids[index],
            .replica_id = placement_ids[index],
            .member_id = member_ids[index],
            .length_bytes = length_bytes,
            .generation = 1,
            .state = .REPLICA_ALLOCATION_STATE_RESERVED,
        },
    };
    return reservations;
}

fn testReplicaAttestation(placement_id: []const u8, allocation_id: []const u8, member_id: []const u8, length_bytes: u64) pb.ReplicaAttestation {
    return .{
        .volume_id = test_volume_id,
        .placement_id = placement_id,
        .allocation_id = allocation_id,
        .generation = 1,
        .member_id = member_id,
        .length_bytes = length_bytes,
        .backend_digest = &test_backend_digest,
    };
}

fn testPrimaryAuthority() pb.PrimaryAuthority {
    return .{
        .volume_id = test_volume_id,
        .primary_placement_id = test_replica_id,
        .primary_node_id = test_node_id,
        .lease_id = &test_lease_id,
        .holder_boot_id = &test_holder_boot_id,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .activation_nonce = &test_activation_nonce,
        .lease_duration_ms = 30_000,
        .state = .PRIMARY_AUTHORITY_STATE_PENDING,
        .authority_digest = &test_authority_digest,
    };
}

fn testFenceEvidence() [volume_target_replica_count]pb.ReplicaFenceEvidence {
    const placement_ids = [_][]const u8{ test_replica_id, test_second_replica_id, test_third_replica_id };
    var evidence: [volume_target_replica_count]pb.ReplicaFenceEvidence = undefined;
    for (&evidence, placement_ids) |*proof, placement_id| proof.* = .{
        .placement_id = placement_id,
        .replica_generation = 1,
        .write_epoch = 1,
        .lease_id = &test_lease_id,
        .authority_digest = &test_authority_digest,
        .fence_digest = &test_fence_digest,
    };
    return evidence;
}

fn testRecoveryEvidence() pb.RecoveryEvidence {
    return .{
        .volume_id = test_volume_id,
        .write_epoch = 1,
        .certified_sequence = 0,
        .history_digest = &test_recovery_digest,
        .empty_frontier = true,
    };
}

fn prepareFencingVolume(allocator: std.mem.Allocator, machine: *PoolStateMachine) !void {
    try addTestVolumeTopology(allocator, machine);
    var created = try applyTestVolumeCommand(allocator, machine, 8, testVolumeCommand("authority-volume", test_volume_id, "authority", "", min_volume_size_bytes, 1_753_744_000_010));
    defer created.deinit(allocator);
    var reservations = testReservations(min_volume_size_bytes);
    const reserve = try encodeReserveVolumeResourcesCommand(allocator, .{ .volume_id = test_volume_id, .expected_resource_version = 8, .reservations = .{ .items = &reservations, .capacity = reservations.len } });
    defer allocator.free(reserve);
    var reserved = try applyEncodedTestCommand(allocator, machine, 9, reserve);
    defer reserved.deinit(allocator);
    const placement_ids = [_][]const u8{ test_replica_id, test_second_replica_id, test_third_replica_id };
    const allocation_ids = [_][]const u8{ test_allocation_id, test_second_allocation_id, test_third_allocation_id };
    const member_ids = [_][]const u8{ &test_member_id_a, &test_member_id_b, &test_member_id_c };
    var volume_rv: u64 = 9;
    for (placement_ids, allocation_ids, member_ids, 0..) |placement_id, allocation_id, member_id, index| {
        const encoded = try encodeActivateReplicaCommand(allocator, .{
            .volume_id = test_volume_id,
            .placement_id = placement_id,
            .allocation_id = allocation_id,
            .expected_volume_resource_version = volume_rv,
            .expected_placement_resource_version = 9,
            .expected_allocation_resource_version = 9,
            .attestation = testReplicaAttestation(placement_id, allocation_id, member_id, min_volume_size_bytes),
        });
        defer allocator.free(encoded);
        var applied = try applyEncodedTestCommand(allocator, machine, 10 + index, encoded);
        defer applied.deinit(allocator);
        volume_rv = 10 + index;
    }
}

fn prepareReadyAuthority(allocator: std.mem.Allocator, machine: *PoolStateMachine) !void {
    try prepareFencingVolume(allocator, machine);
    const proposal = try encodeProposePrimaryAuthorityCommand(allocator, .{ .authority = testPrimaryAuthority(), .expected_volume_resource_version = 12 });
    defer allocator.free(proposal);
    var proposed = try applyEncodedTestCommand(allocator, machine, 13, proposal);
    defer proposed.deinit(allocator);
    const activation = try encodeActivatePrimaryAuthorityCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .activation_nonce = &test_activation_nonce,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 13,
        .expected_authority_resource_version = 13,
    });
    defer allocator.free(activation);
    var activated = try applyEncodedTestCommand(allocator, machine, 14, activation);
    defer activated.deinit(allocator);
    var fences = testFenceEvidence();
    const ready = try encodeCommitPrimaryAuthorityReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .authority_digest = &test_authority_digest,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 14,
        .expected_authority_resource_version = 14,
        .fence_evidence = .{ .items = &fences, .capacity = fences.len },
        .recovery_evidence = testRecoveryEvidence(),
    });
    defer allocator.free(ready);
    var committed = try applyEncodedTestCommand(allocator, machine, 15, ready);
    defer committed.deinit(allocator);
}

fn applyEncodedTestCommand(allocator: std.mem.Allocator, machine: *PoolStateMachine, index: u64, encoded: []const u8) !raft.ApplyResult {
    _ = allocator;
    return machine.stateMachine().apply(.{ .index = index, .term = 1, .data = encoded });
}

test "primary authority lifecycle snapshot and deletion" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try prepareFencingVolume(allocator, &machine);

    const proposal = try encodeProposePrimaryAuthorityCommand(allocator, .{ .authority = testPrimaryAuthority(), .expected_volume_resource_version = 12 });
    defer allocator.free(proposal);
    var proposed = try applyEncodedTestCommand(allocator, &machine, 13, proposal);
    defer proposed.deinit(allocator);
    var proposed_response = try decodePrimaryAuthorityApplyResponse(allocator, proposed.response.?);
    defer proposed_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_PROPOSED, proposed_response.code);
    try std.testing.expectEqual(pb.PrimaryAuthorityState.PRIMARY_AUTHORITY_STATE_PENDING, proposed_response.authority.?.state);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_PROVISIONING, proposed_response.volume.?.lifecycle_state);

    const activation = try encodeActivatePrimaryAuthorityCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .activation_nonce = &test_activation_nonce,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 13,
        .expected_authority_resource_version = 13,
    });
    defer allocator.free(activation);
    var activated = try applyEncodedTestCommand(allocator, &machine, 14, activation);
    defer activated.deinit(allocator);
    var activated_response = try decodePrimaryAuthorityApplyResponse(allocator, activated.response.?);
    defer activated_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityState.PRIMARY_AUTHORITY_STATE_ACTIVATED, activated_response.authority.?.state);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_PROVISIONING, activated_response.volume.?.lifecycle_state);

    var fences = testFenceEvidence();
    const ready_command = try encodeCommitPrimaryAuthorityReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .authority_digest = &test_authority_digest,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 14,
        .expected_authority_resource_version = 14,
        .fence_evidence = .{ .items = &fences, .capacity = fences.len },
        .recovery_evidence = testRecoveryEvidence(),
    });
    defer allocator.free(ready_command);
    var ready = try applyEncodedTestCommand(allocator, &machine, 15, ready_command);
    defer ready.deinit(allocator);
    var ready_response = try decodePrimaryAuthorityApplyResponse(allocator, ready.response.?);
    defer ready_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_READY, ready_response.code);
    try std.testing.expectEqual(pb.PrimaryAuthorityState.PRIMARY_AUTHORITY_STATE_READY, ready_response.authority.?.state);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_ACTIVE, ready_response.volume.?.lifecycle_state);
    try std.testing.expectEqual(pb.VolumeAvailabilityState.VOLUME_AVAILABILITY_STATE_HEALTHY, ready_response.volume.?.availability_state);
    try std.testing.expectEqual(pb.VolumeOperationPhase.VOLUME_OPERATION_PHASE_NONE, ready_response.volume.?.operation_phase);

    var snapshot_a = try machine.stateMachine().takeSnapshot(allocator, 15, 1, .{});
    defer snapshot_a.deinit(allocator);
    var snapshot_b = try machine.stateMachine().takeSnapshot(allocator, 15, 1, .{});
    defer snapshot_b.deinit(allocator);
    try std.testing.expectEqualSlices(u8, snapshot_a.data, snapshot_b.data);
    var recovered = PoolStateMachine.init(allocator);
    defer recovered.deinit();
    var reader = TestSnapshotReader{ .data = snapshot_a.data };
    try recovered.stateMachine().restoreSnapshot(snapshot_a.metadata, reader.reader());
    var recovered_authority = (try recovered.getPrimaryAuthority(allocator, test_volume_id)).?;
    defer recovered_authority.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityState.PRIMARY_AUTHORITY_STATE_READY, recovered_authority.state);
    try std.testing.expectEqualSlices(u8, &test_recovery_digest, recovered_authority.recovery_digest);

    var deleted = try applyTestDeleteVolumeCommand(allocator, &machine, 16, testDeleteVolumeCommand("delete-authority", test_volume_id, 15, 1_753_744_000_020));
    defer deleted.deinit(allocator);
    const placement_ids = [_][]const u8{ test_replica_id, test_second_replica_id, test_third_replica_id };
    const allocation_ids = [_][]const u8{ test_allocation_id, test_second_allocation_id, test_third_allocation_id };
    const finalize = try encodeFinalizeVolumeDeletionCommand(allocator, .{
        .volume_id = test_volume_id,
        .expected_resource_version = 16,
        .placement_ids = .{ .items = @constCast(&placement_ids), .capacity = placement_ids.len },
        .allocation_ids = .{ .items = @constCast(&allocation_ids), .capacity = allocation_ids.len },
        .proposed_deleted_at_unix_ms = 1_753_744_000_021,
    });
    defer allocator.free(finalize);
    var finalized = try applyEncodedTestCommand(allocator, &machine, 17, finalize);
    defer finalized.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCount());
}

test "primary authority renewal preserves ready authority until atomic swap" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try prepareReadyAuthority(allocator, &machine);

    var renewal = testPrimaryAuthority();
    renewal.lease_id = &test_renewal_lease_id;
    renewal.activation_nonce = &test_renewal_nonce;
    renewal.authority_digest = &test_renewal_digest;
    renewal.authority_generation = 2;
    const proposal = try encodeProposePrimaryAuthorityCommand(allocator, .{ .authority = renewal, .expected_volume_resource_version = 15 });
    defer allocator.free(proposal);
    var proposed = try applyEncodedTestCommand(allocator, &machine, 16, proposal);
    defer proposed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCandidateCount());
    var current = (try machine.getPrimaryAuthority(allocator, test_volume_id)).?;
    defer current.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityState.PRIMARY_AUTHORITY_STATE_READY, current.state);
    try std.testing.expectEqual(@as(u64, 1), current.authority_generation);

    const early = try encodeCommitPrimaryAuthorityRenewalReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_renewal_lease_id,
        .authority_generation = 2,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 16,
        .expected_candidate_resource_version = 16,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(early);
    var early_result = try applyEncodedTestCommand(allocator, &machine, 17, early);
    defer early_result.deinit(allocator);
    var early_response = try decodePrimaryAuthorityApplyResponse(allocator, early_result.response.?);
    defer early_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, early_response.code);

    const activation = try encodeActivatePrimaryAuthorityCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_renewal_lease_id,
        .activation_nonce = &test_renewal_nonce,
        .authority_generation = 2,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 16,
        .expected_authority_resource_version = 16,
    });
    defer allocator.free(activation);
    var activated = try applyEncodedTestCommand(allocator, &machine, 18, activation);
    defer activated.deinit(allocator);

    var snapshot_a = try machine.stateMachine().takeSnapshot(allocator, 18, 1, .{});
    defer snapshot_a.deinit(allocator);
    var snapshot_b = try machine.stateMachine().takeSnapshot(allocator, 18, 1, .{});
    defer snapshot_b.deinit(allocator);
    try std.testing.expectEqualSlices(u8, snapshot_a.data, snapshot_b.data);
    var recovered = PoolStateMachine.init(allocator);
    defer recovered.deinit();
    var reader = TestSnapshotReader{ .data = snapshot_a.data };
    try recovered.stateMachine().restoreSnapshot(snapshot_a.metadata, reader.reader());
    try std.testing.expectEqual(@as(usize, 1), recovered.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 1), recovered.primaryAuthorityCandidateCount());

    var legacy_arena: std.heap.ArenaAllocator = .init(allocator);
    defer legacy_arena.deinit();
    var legacy_reader: std.Io.Reader = .fixed(snapshot_a.data);
    var legacy = try pb.StateSnapshot.decode(&legacy_reader, legacy_arena.allocator());
    legacy.format_version = 9;
    try legacy.primary_authorities.append(legacy_arena.allocator(), legacy.primary_authority_candidates.items[0]);
    legacy.primary_authority_candidates.clearRetainingCapacity();
    const legacy_wire = try encodeMessage(allocator, legacy);
    defer allocator.free(legacy_wire);
    var migrated = PoolStateMachine.init(allocator);
    defer migrated.deinit();
    var legacy_snapshot_reader = TestSnapshotReader{ .data = legacy_wire };
    try migrated.stateMachine().restoreSnapshot(snapshot_a.metadata, legacy_snapshot_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), migrated.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 1), migrated.primaryAuthorityCandidateCount());

    legacy.primary_authorities.items[1].state = .PRIMARY_AUTHORITY_STATE_PENDING;
    legacy.primary_authorities.items[1].activated_revision = 0;
    legacy.primary_authorities.items[1].resource_version = legacy.primary_authorities.items[1].created_revision;
    const pending_legacy_wire = try encodeMessage(allocator, legacy);
    defer allocator.free(pending_legacy_wire);
    var pending_migrated = PoolStateMachine.init(allocator);
    defer pending_migrated.deinit();
    var pending_legacy_reader = TestSnapshotReader{ .data = pending_legacy_wire };
    try pending_migrated.stateMachine().restoreSnapshot(snapshot_a.metadata, pending_legacy_reader.reader());
    var pending_candidate = (try pending_migrated.getPrimaryAuthorityCandidate(allocator, test_volume_id)).?;
    defer pending_candidate.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityState.PRIMARY_AUTHORITY_STATE_PENDING, pending_candidate.state);

    legacy.primary_authorities.items[1].holder_boot_id = &test_renewal_nonce;
    const malformed_wire = try encodeMessage(allocator, legacy);
    defer allocator.free(malformed_wire);
    var malformed = PoolStateMachine.init(allocator);
    defer malformed.deinit();
    var malformed_reader = TestSnapshotReader{ .data = malformed_wire };
    try std.testing.expectError(error.PayloadParseFailed, malformed.stateMachine().restoreSnapshot(snapshot_a.metadata, malformed_reader.reader()));

    const commit = try encodeCommitPrimaryAuthorityRenewalReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_renewal_lease_id,
        .authority_generation = 2,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 18,
        .expected_candidate_resource_version = 18,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(commit);
    var committed = try applyEncodedTestCommand(allocator, &machine, 19, commit);
    defer committed.deinit(allocator);
    var response = try decodePrimaryAuthorityApplyResponse(allocator, committed.response.?);
    defer response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_READY, response.code);
    try std.testing.expectEqual(@as(u64, 2), response.authority.?.authority_generation);
    try std.testing.expectEqualSlices(u8, &test_renewal_lease_id, response.authority.?.lease_id);
    try std.testing.expectEqualSlices(u8, &test_recovery_digest, response.authority.?.recovery_digest);
    try std.testing.expect(response.authority.?.recovery_empty_frontier);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_ACTIVE, response.volume.?.lifecycle_state);
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());

    var replay = try applyEncodedTestCommand(allocator, &machine, 20, commit);
    defer replay.deinit(allocator);
    var replay_response = try decodePrimaryAuthorityApplyResponse(allocator, replay.response.?);
    defer replay_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_READY, replay_response.code);
}

test "renewal binding rejects authority changes and reused identities" {
    const allocator = std.testing.allocator;
    var current_proto = testPrimaryAuthority();
    current_proto.state = .PRIMARY_AUTHORITY_STATE_READY;
    current_proto.created_revision = 13;
    current_proto.activated_revision = 14;
    current_proto.ready_revision = 15;
    current_proto.resource_version = 15;
    current_proto.recovery_digest = &test_recovery_digest;
    current_proto.recovery_empty_frontier = true;
    var current = try PrimaryAuthority.init(allocator, current_proto);
    defer current.deinit(allocator);
    var renewal = testPrimaryAuthority();
    renewal.lease_id = &test_renewal_lease_id;
    renewal.activation_nonce = &test_renewal_nonce;
    renewal.authority_digest = &test_renewal_digest;
    renewal.authority_generation = 2;
    try std.testing.expect(renewalProposalValid(current, renewal));

    var changed = renewal;
    changed.holder_boot_id = &test_renewal_nonce;
    try std.testing.expect(!renewalProposalValid(current, changed));
    changed = renewal;
    changed.primary_node_id = test_second_node_id;
    try std.testing.expect(!renewalProposalValid(current, changed));
    changed = renewal;
    changed.write_epoch += 1;
    try std.testing.expect(!renewalProposalValid(current, changed));
    changed = renewal;
    changed.placement_revision += 1;
    try std.testing.expect(!renewalProposalValid(current, changed));
    changed = renewal;
    changed.authority_generation += 1;
    try std.testing.expect(!renewalProposalValid(current, changed));
    changed = renewal;
    changed.lease_id = current.lease_id;
    try std.testing.expect(!renewalProposalValid(current, changed));
    changed = renewal;
    changed.activation_nonce = current.activation_nonce;
    try std.testing.expect(!renewalProposalValid(current, changed));
}

test "abort primary authority candidate exact binds and retains current" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try prepareReadyAuthority(allocator, &machine);
    var renewal = testPrimaryAuthority();
    renewal.lease_id = &test_renewal_lease_id;
    renewal.activation_nonce = &test_renewal_nonce;
    renewal.authority_digest = &test_renewal_digest;
    renewal.authority_generation = 2;
    const proposal = try encodeProposePrimaryAuthorityCommand(allocator, .{ .authority = renewal, .expected_volume_resource_version = 15 });
    defer allocator.free(proposal);
    var proposed = try applyEncodedTestCommand(allocator, &machine, 16, proposal);
    defer proposed.deinit(allocator);

    const wrong_binding = try encodeAbortPrimaryAuthorityCandidateCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .authority_generation = 2,
        .expected_volume_resource_version = 16,
        .expected_candidate_resource_version = 16,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(wrong_binding);
    var wrong_result = try applyEncodedTestCommand(allocator, &machine, 17, wrong_binding);
    defer wrong_result.deinit(allocator);
    var wrong_response = try decodePrimaryAuthorityApplyResponse(allocator, wrong_result.response.?);
    defer wrong_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, wrong_response.code);
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCandidateCount());

    const stale = try encodeAbortPrimaryAuthorityCandidateCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_renewal_lease_id,
        .authority_generation = 2,
        .expected_volume_resource_version = 15,
        .expected_candidate_resource_version = 16,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(stale);
    var stale_result = try applyEncodedTestCommand(allocator, &machine, 18, stale);
    defer stale_result.deinit(allocator);
    var stale_response = try decodePrimaryAuthorityApplyResponse(allocator, stale_result.response.?);
    defer stale_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT, stale_response.code);
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCandidateCount());

    var snapshot = try machine.stateMachine().takeSnapshot(allocator, 18, 1, .{});
    defer snapshot.deinit(allocator);
    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var snapshot_reader = TestSnapshotReader{ .data = snapshot.data };
    try restored.stateMachine().restoreSnapshot(snapshot.metadata, snapshot_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), restored.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 1), restored.primaryAuthorityCandidateCount());

    const abort_command = try encodeAbortPrimaryAuthorityCandidateCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_renewal_lease_id,
        .authority_generation = 2,
        .expected_volume_resource_version = 16,
        .expected_candidate_resource_version = 16,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(abort_command);
    var aborted = try applyEncodedTestCommand(allocator, &machine, 19, abort_command);
    defer aborted.deinit(allocator);
    var aborted_response = try decodePrimaryAuthorityApplyResponse(allocator, aborted.response.?);
    defer aborted_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_ABORTED, aborted_response.code);
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());

    var aborted_snapshot = try machine.stateMachine().takeSnapshot(allocator, 19, 1, .{});
    defer aborted_snapshot.deinit(allocator);
    var aborted_restored = PoolStateMachine.init(allocator);
    defer aborted_restored.deinit();
    var aborted_reader = TestSnapshotReader{ .data = aborted_snapshot.data };
    try aborted_restored.stateMachine().restoreSnapshot(aborted_snapshot.metadata, aborted_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), aborted_restored.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 0), aborted_restored.primaryAuthorityCandidateCount());

    var replay = try applyEncodedTestCommand(allocator, &machine, 20, abort_command);
    defer replay.deinit(allocator);
    var replay_response = try decodePrimaryAuthorityApplyResponse(allocator, replay.response.?);
    defer replay_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_NOT_FOUND, replay_response.code);
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCount());
}

test "primary failover revokes waits advances epoch and atomically switches ready" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try prepareReadyAuthority(allocator, &machine);

    const begin = try encodeBeginPrimaryFailoverCommand(allocator, .{
        .volume_id = test_volume_id,
        .current_lease_id = &test_lease_id,
        .current_authority_generation = 1,
        .current_write_epoch = 1,
        .failover_id = &test_failover_id,
        .expected_volume_resource_version = 15,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(begin);
    var begun = try applyEncodedTestCommand(allocator, &machine, 16, begin);
    defer begun.deinit(allocator);
    var begin_response = try decodePrimaryFailoverApplyResponse(allocator, begun.response.?);
    defer begin_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryFailoverApplyCode.PRIMARY_FAILOVER_APPLY_CODE_BEGUN, begin_response.code);
    try std.testing.expectEqual(pb.VolumeAvailabilityState.VOLUME_AVAILABILITY_STATE_UNAVAILABLE, begin_response.volume.?.availability_state);
    try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 1), machine.primaryFailoverCount());

    var waiting_snapshot = try machine.stateMachine().takeSnapshot(allocator, 16, 1, .{});
    defer waiting_snapshot.deinit(allocator);
    var waiting_restored = PoolStateMachine.init(allocator);
    defer waiting_restored.deinit();
    var waiting_reader = TestSnapshotReader{ .data = waiting_snapshot.data };
    try waiting_restored.stateMachine().restoreSnapshot(waiting_snapshot.metadata, waiting_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), waiting_restored.primaryFailoverCount());

    var forbidden_renewal = testPrimaryAuthority();
    forbidden_renewal.lease_id = &test_renewal_lease_id;
    forbidden_renewal.activation_nonce = &test_renewal_nonce;
    forbidden_renewal.authority_digest = &test_renewal_digest;
    forbidden_renewal.authority_generation = 2;
    const forbidden = try encodeProposePrimaryAuthorityCommand(allocator, .{
        .authority = forbidden_renewal,
        .expected_volume_resource_version = 16,
    });
    defer allocator.free(forbidden);
    var forbidden_result = try applyEncodedTestCommand(allocator, &machine, 17, forbidden);
    defer forbidden_result.deinit(allocator);
    var forbidden_response = try decodePrimaryAuthorityApplyResponse(allocator, forbidden_result.response.?);
    defer forbidden_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, forbidden_response.code);
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());

    const complete = try encodeCompletePrimaryFailoverLeaseWaitCommand(allocator, .{
        .volume_id = test_volume_id,
        .failover_id = &test_failover_id,
        .revoked_lease_id = &test_lease_id,
        .revoked_authority_generation = 1,
        .revoked_write_epoch = 1,
        .expected_volume_resource_version = 16,
        .expected_failover_resource_version = 16,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(complete);
    var completed = try applyEncodedTestCommand(allocator, &machine, 18, complete);
    defer completed.deinit(allocator);

    var proposal_authority = testPrimaryAuthority();
    proposal_authority.primary_placement_id = test_second_replica_id;
    proposal_authority.primary_node_id = test_second_node_id;
    proposal_authority.lease_id = &test_renewal_lease_id;
    proposal_authority.activation_nonce = &test_renewal_nonce;
    proposal_authority.authority_digest = &test_renewal_digest;
    proposal_authority.authority_generation = 2;
    proposal_authority.write_epoch = 2;
    const proposal = try encodeProposePrimaryAuthorityCommand(allocator, .{
        .authority = proposal_authority,
        .expected_volume_resource_version = 18,
        .failover_id = &test_failover_id,
        .expected_failover_resource_version = 18,
    });
    defer allocator.free(proposal);
    var proposed = try applyEncodedTestCommand(allocator, &machine, 19, proposal);
    defer proposed.deinit(allocator);
    var proposed_volume = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer proposed_volume.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2), proposed_volume.write_epoch);

    const abort = try encodeAbortPrimaryAuthorityCandidateCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_renewal_lease_id,
        .authority_generation = 2,
        .expected_volume_resource_version = 19,
        .expected_candidate_resource_version = 19,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(abort);
    var aborted = try applyEncodedTestCommand(allocator, &machine, 20, abort);
    defer aborted.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    var after_abort = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer after_abort.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), after_abort.write_epoch);
    var retry_snapshot = try machine.stateMachine().takeSnapshot(allocator, 20, 1, .{});
    defer retry_snapshot.deinit(allocator);
    var retry_restored = PoolStateMachine.init(allocator);
    defer retry_restored.deinit();
    var retry_reader = TestSnapshotReader{ .data = retry_snapshot.data };
    try retry_restored.stateMachine().restoreSnapshot(retry_snapshot.metadata, retry_reader.reader());
    var restored_failover = (try retry_restored.getPrimaryFailover(allocator, test_volume_id)).?;
    defer restored_failover.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 3), restored_failover.target_write_epoch);

    proposal_authority.lease_id = &test_failover_lease_id;
    proposal_authority.activation_nonce = &test_failover_nonce;
    proposal_authority.authority_digest = &test_failover_digest;
    proposal_authority.write_epoch = 3;
    const reproposal = try encodeProposePrimaryAuthorityCommand(allocator, .{
        .authority = proposal_authority,
        .expected_volume_resource_version = 20,
        .failover_id = &test_failover_id,
        .expected_failover_resource_version = 20,
    });
    defer allocator.free(reproposal);
    var reproposed = try applyEncodedTestCommand(allocator, &machine, 21, reproposal);
    defer reproposed.deinit(allocator);
    const activation = try encodeActivatePrimaryAuthorityCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_failover_lease_id,
        .activation_nonce = &test_failover_nonce,
        .authority_generation = 2,
        .write_epoch = 3,
        .placement_revision = 9,
        .expected_volume_resource_version = 21,
        .expected_authority_resource_version = 21,
    });
    defer allocator.free(activation);
    var activated = try applyEncodedTestCommand(allocator, &machine, 22, activation);
    defer activated.deinit(allocator);

    var fences = testFenceEvidence();
    for (&fences) |*fence| {
        fence.write_epoch = 3;
        fence.lease_id = &test_failover_lease_id;
        fence.authority_digest = &test_failover_digest;
    }
    var recovery = testRecoveryEvidence();
    recovery.write_epoch = 3;
    const ready = try encodeCommitPrimaryAuthorityFailoverReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .failover_id = &test_failover_id,
        .lease_id = &test_failover_lease_id,
        .authority_digest = &test_failover_digest,
        .authority_generation = 2,
        .write_epoch = 3,
        .placement_revision = 9,
        .expected_volume_resource_version = 22,
        .expected_candidate_resource_version = 22,
        .expected_current_resource_version = 15,
        .expected_failover_resource_version = 21,
        .fence_evidence = .{ .items = &fences, .capacity = fences.len },
        .recovery_evidence = recovery,
    });
    defer allocator.free(ready);
    var committed = try applyEncodedTestCommand(allocator, &machine, 23, ready);
    defer committed.deinit(allocator);
    var response = try decodePrimaryAuthorityApplyResponse(allocator, committed.response.?);
    defer response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_READY, response.code);
    try std.testing.expectEqualSlices(u8, test_second_replica_id, response.authority.?.primary_placement_id);
    try std.testing.expectEqual(@as(u64, 3), response.authority.?.write_epoch);
    try std.testing.expectEqualSlices(u8, &test_recovery_digest, response.authority.?.recovery_digest);
    try std.testing.expectEqual(pb.VolumeAvailabilityState.VOLUME_AVAILABILITY_STATE_HEALTHY, response.volume.?.availability_state);
    try std.testing.expectEqual(@as(usize, 0), machine.primaryFailoverCount());
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
}

test "volume deletion cleans current candidate and primary failover" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try prepareReadyAuthority(allocator, &machine);
    const begin = try encodeBeginPrimaryFailoverCommand(allocator, .{
        .volume_id = test_volume_id,
        .current_lease_id = &test_lease_id,
        .current_authority_generation = 1,
        .current_write_epoch = 1,
        .failover_id = &test_failover_id,
        .expected_volume_resource_version = 15,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(begin);
    var begun = try applyEncodedTestCommand(allocator, &machine, 16, begin);
    defer begun.deinit(allocator);
    var failover_snapshot = try machine.stateMachine().takeSnapshot(allocator, 16, 1, .{});
    defer failover_snapshot.deinit(allocator);
    var malformed_arena: std.heap.ArenaAllocator = .init(allocator);
    defer malformed_arena.deinit();
    var malformed_wire_reader: std.Io.Reader = .fixed(failover_snapshot.data);
    var malformed = try pb.StateSnapshot.decode(&malformed_wire_reader, malformed_arena.allocator());
    malformed.primary_failovers.items[0].target_write_epoch += 1;
    const malformed_epoch_wire = try encodeMessage(allocator, malformed);
    defer allocator.free(malformed_epoch_wire);
    var malformed_epoch_machine = PoolStateMachine.init(allocator);
    defer malformed_epoch_machine.deinit();
    var malformed_epoch_reader = TestSnapshotReader{ .data = malformed_epoch_wire };
    try std.testing.expectError(error.PayloadParseFailed, malformed_epoch_machine.stateMachine().restoreSnapshot(failover_snapshot.metadata, malformed_epoch_reader.reader()));
    malformed.primary_failovers.items[0].target_write_epoch -= 1;
    malformed.volumes.items[0].lifecycle_state = .VOLUME_LIFECYCLE_STATE_DELETING;
    malformed.volumes.items[0].availability_state = .VOLUME_AVAILABILITY_STATE_UNAVAILABLE;
    malformed.volumes.items[0].operation_phase = .VOLUME_OPERATION_PHASE_NONE;
    const malformed_wire = try encodeMessage(allocator, malformed);
    defer allocator.free(malformed_wire);
    var malformed_machine = PoolStateMachine.init(allocator);
    defer malformed_machine.deinit();
    var malformed_reader = TestSnapshotReader{ .data = malformed_wire };
    try std.testing.expectError(error.PayloadParseFailed, malformed_machine.stateMachine().restoreSnapshot(failover_snapshot.metadata, malformed_reader.reader()));
    machine.state.volumes_by_id.getPtr(test_volume_id).?.write_epoch = 2;
    const delete = try encodeDeleteVolumeCommand(allocator, .{
        .request_id = "delete-failover-volume",
        .volume_id = test_volume_id,
        .expected_resource_version = 16,
        .proposed_deleted_at_unix_ms = 1_753_744_000_020,
    });
    defer allocator.free(delete);
    var deletion = try applyEncodedTestCommand(allocator, &machine, 17, delete);
    defer deletion.deinit(allocator);
    var deleting_snapshot = try machine.stateMachine().takeSnapshot(allocator, 17, 1, .{});
    defer deleting_snapshot.deinit(allocator);
    var deleting_restored = PoolStateMachine.init(allocator);
    defer deleting_restored.deinit();
    var deleting_reader = TestSnapshotReader{ .data = deleting_snapshot.data };
    try deleting_restored.stateMachine().restoreSnapshot(deleting_snapshot.metadata, deleting_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), deleting_restored.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 0), deleting_restored.primaryAuthorityCandidateCount());
    try std.testing.expectEqual(@as(usize, 0), deleting_restored.primaryFailoverCount());
    const placement_ids = [_][]const u8{ test_replica_id, test_second_replica_id, test_third_replica_id };
    const allocation_ids = [_][]const u8{ test_allocation_id, test_second_allocation_id, test_third_allocation_id };
    const finalize = try encodeFinalizeVolumeDeletionCommand(allocator, .{
        .volume_id = test_volume_id,
        .expected_resource_version = 17,
        .placement_ids = .{ .items = @constCast(&placement_ids), .capacity = placement_ids.len },
        .allocation_ids = .{ .items = @constCast(&allocation_ids), .capacity = allocation_ids.len },
        .proposed_deleted_at_unix_ms = 1_753_744_000_021,
    });
    defer allocator.free(finalize);
    var finalized = try applyEncodedTestCommand(allocator, &machine, 18, finalize);
    defer finalized.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCount());
    try std.testing.expectEqual(@as(usize, 0), machine.primaryAuthorityCandidateCount());
    try std.testing.expectEqual(@as(usize, 0), machine.primaryFailoverCount());
}

test "primary authority rejects stale activation and invalid ready evidence" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try prepareFencingVolume(allocator, &machine);

    var invalid_proposal = testPrimaryAuthority();
    invalid_proposal.lease_duration_ms -= 1;
    try std.testing.expectError(error.PayloadParseFailed, encodeProposePrimaryAuthorityCommand(allocator, .{
        .authority = invalid_proposal,
        .expected_volume_resource_version = 12,
    }));
    invalid_proposal = testPrimaryAuthority();
    const zero_digest: [32]u8 = @splat(0);
    invalid_proposal.authority_digest = &zero_digest;
    try std.testing.expectError(error.PayloadParseFailed, encodeProposePrimaryAuthorityCommand(allocator, .{
        .authority = invalid_proposal,
        .expected_volume_resource_version = 12,
    }));

    const proposal = try encodeProposePrimaryAuthorityCommand(allocator, .{ .authority = testPrimaryAuthority(), .expected_volume_resource_version = 12 });
    defer allocator.free(proposal);
    var proposed = try applyEncodedTestCommand(allocator, &machine, 13, proposal);
    defer proposed.deinit(allocator);

    var fences = testFenceEvidence();
    const before_activation = try encodeCommitPrimaryAuthorityReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .authority_digest = &test_authority_digest,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 13,
        .expected_authority_resource_version = 13,
        .fence_evidence = .{ .items = &fences, .capacity = fences.len },
        .recovery_evidence = testRecoveryEvidence(),
    });
    defer allocator.free(before_activation);
    var rejected_ready = try applyEncodedTestCommand(allocator, &machine, 14, before_activation);
    defer rejected_ready.deinit(allocator);
    var rejected_ready_response = try decodePrimaryAuthorityApplyResponse(allocator, rejected_ready.response.?);
    defer rejected_ready_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_INVALID_STATE, rejected_ready_response.code);

    var stale_nonce: [16]u8 = @splat(0x77);
    const bad_nonce = try encodeActivatePrimaryAuthorityCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .activation_nonce = &stale_nonce,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 13,
        .expected_authority_resource_version = 13,
    });
    defer allocator.free(bad_nonce);
    var nonce_result = try applyEncodedTestCommand(allocator, &machine, 15, bad_nonce);
    defer nonce_result.deinit(allocator);
    var nonce_response = try decodePrimaryAuthorityApplyResponse(allocator, nonce_result.response.?);
    defer nonce_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_BINDING_MISMATCH, nonce_response.code);

    const stale_version = try encodeActivatePrimaryAuthorityCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .activation_nonce = &test_activation_nonce,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 12,
        .expected_authority_resource_version = 13,
    });
    defer allocator.free(stale_version);
    var version_result = try applyEncodedTestCommand(allocator, &machine, 16, stale_version);
    defer version_result.deinit(allocator);
    var version_response = try decodePrimaryAuthorityApplyResponse(allocator, version_result.response.?);
    defer version_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_VERSION_CONFLICT, version_response.code);

    const activation = try encodeActivatePrimaryAuthorityCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .activation_nonce = &test_activation_nonce,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 13,
        .expected_authority_resource_version = 13,
    });
    defer allocator.free(activation);
    var activated = try applyEncodedTestCommand(allocator, &machine, 17, activation);
    defer activated.deinit(allocator);

    fences[2].placement_id = test_second_replica_id;
    const duplicate = try encodeCommitPrimaryAuthorityReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .authority_digest = &test_authority_digest,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 17,
        .expected_authority_resource_version = 17,
        .fence_evidence = .{ .items = &fences, .capacity = fences.len },
        .recovery_evidence = testRecoveryEvidence(),
    });
    defer allocator.free(duplicate);
    var duplicate_result = try applyEncodedTestCommand(allocator, &machine, 18, duplicate);
    defer duplicate_result.deinit(allocator);
    var duplicate_response = try decodePrimaryAuthorityApplyResponse(allocator, duplicate_result.response.?);
    defer duplicate_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_PROOF_INVALID, duplicate_response.code);

    fences = testFenceEvidence();
    fences[0].write_epoch = 2;
    const mismatched = try encodeCommitPrimaryAuthorityReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .authority_digest = &test_authority_digest,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 17,
        .expected_authority_resource_version = 17,
        .fence_evidence = .{ .items = &fences, .capacity = fences.len },
        .recovery_evidence = testRecoveryEvidence(),
    });
    defer allocator.free(mismatched);
    var mismatched_result = try applyEncodedTestCommand(allocator, &machine, 19, mismatched);
    defer mismatched_result.deinit(allocator);
    var mismatched_response = try decodePrimaryAuthorityApplyResponse(allocator, mismatched_result.response.?);
    defer mismatched_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_PROOF_INVALID, mismatched_response.code);

    fences = testFenceEvidence();
    var bad_recovery = testRecoveryEvidence();
    bad_recovery.write_epoch = 2;
    const bad_recovery_command = try encodeCommitPrimaryAuthorityReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .authority_digest = &test_authority_digest,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 17,
        .expected_authority_resource_version = 17,
        .fence_evidence = .{ .items = &fences, .capacity = fences.len },
        .recovery_evidence = bad_recovery,
    });
    defer allocator.free(bad_recovery_command);
    var bad_recovery_result = try applyEncodedTestCommand(allocator, &machine, 20, bad_recovery_command);
    defer bad_recovery_result.deinit(allocator);
    var bad_recovery_response = try decodePrimaryAuthorityApplyResponse(allocator, bad_recovery_result.response.?);
    defer bad_recovery_response.deinit(allocator);
    try std.testing.expectEqual(pb.PrimaryAuthorityApplyCode.PRIMARY_AUTHORITY_APPLY_CODE_PROOF_INVALID, bad_recovery_response.code);

    var invalid_recovery = testRecoveryEvidence();
    invalid_recovery.history_digest = "short";
    try std.testing.expectError(error.PayloadParseFailed, encodeCommitPrimaryAuthorityReadyCommand(allocator, .{
        .volume_id = test_volume_id,
        .lease_id = &test_lease_id,
        .authority_digest = &test_authority_digest,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 9,
        .expected_volume_resource_version = 17,
        .expected_authority_resource_version = 17,
        .fence_evidence = .{ .items = &fences, .capacity = fences.len },
        .recovery_evidence = invalid_recovery,
    }));
}

test "primary authority snapshot invariants and legacy fail closed" {
    const allocator = std.testing.allocator;
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    try prepareReadyAuthority(allocator, &source);
    var snapshot = try source.stateMachine().takeSnapshot(allocator, 15, 1, .{});
    defer snapshot.deinit(allocator);

    var missing_arena: std.heap.ArenaAllocator = .init(allocator);
    defer missing_arena.deinit();
    var missing_reader: std.Io.Reader = .fixed(snapshot.data);
    var missing = try pb.StateSnapshot.decode(&missing_reader, missing_arena.allocator());
    _ = missing.primary_authorities.pop();
    const missing_wire = try encodeMessage(allocator, missing);
    defer allocator.free(missing_wire);
    var missing_machine = PoolStateMachine.init(allocator);
    defer missing_machine.deinit();
    var missing_snapshot_reader = TestSnapshotReader{ .data = missing_wire };
    try std.testing.expectError(error.PayloadParseFailed, missing_machine.stateMachine().restoreSnapshot(snapshot.metadata, missing_snapshot_reader.reader()));

    var orphan_arena: std.heap.ArenaAllocator = .init(allocator);
    defer orphan_arena.deinit();
    var orphan_reader: std.Io.Reader = .fixed(snapshot.data);
    var orphan = try pb.StateSnapshot.decode(&orphan_reader, orphan_arena.allocator());
    orphan.primary_authorities.items[0].volume_id = test_second_volume_id;
    const orphan_wire = try encodeMessage(allocator, orphan);
    defer allocator.free(orphan_wire);
    var orphan_machine = PoolStateMachine.init(allocator);
    defer orphan_machine.deinit();
    var orphan_snapshot_reader = TestSnapshotReader{ .data = orphan_wire };
    try std.testing.expectError(error.PayloadParseFailed, orphan_machine.stateMachine().restoreSnapshot(snapshot.metadata, orphan_snapshot_reader.reader()));

    var malformed_arena: std.heap.ArenaAllocator = .init(allocator);
    defer malformed_arena.deinit();
    var malformed_reader: std.Io.Reader = .fixed(snapshot.data);
    var malformed = try pb.StateSnapshot.decode(&malformed_reader, malformed_arena.allocator());
    malformed.primary_authorities.items[0].authority_digest = "short";
    const malformed_wire = try encodeMessage(allocator, malformed);
    defer allocator.free(malformed_wire);
    var malformed_machine = PoolStateMachine.init(allocator);
    defer malformed_machine.deinit();
    var malformed_snapshot_reader = TestSnapshotReader{ .data = malformed_wire };
    try std.testing.expectError(error.PayloadParseFailed, malformed_machine.stateMachine().restoreSnapshot(snapshot.metadata, malformed_snapshot_reader.reader()));

    var implicit_empty_arena: std.heap.ArenaAllocator = .init(allocator);
    defer implicit_empty_arena.deinit();
    var implicit_empty_reader: std.Io.Reader = .fixed(snapshot.data);
    var implicit_empty = try pb.StateSnapshot.decode(&implicit_empty_reader, implicit_empty_arena.allocator());
    implicit_empty.primary_authorities.items[0].recovery_empty_frontier = false;
    const implicit_empty_wire = try encodeMessage(allocator, implicit_empty);
    defer allocator.free(implicit_empty_wire);
    var implicit_empty_machine = PoolStateMachine.init(allocator);
    defer implicit_empty_machine.deinit();
    var implicit_empty_snapshot_reader = TestSnapshotReader{ .data = implicit_empty_wire };
    try std.testing.expectError(error.PayloadParseFailed, implicit_empty_machine.stateMachine().restoreSnapshot(snapshot.metadata, implicit_empty_snapshot_reader.reader()));

    var legacy_arena: std.heap.ArenaAllocator = .init(allocator);
    defer legacy_arena.deinit();
    var legacy_reader: std.Io.Reader = .fixed(snapshot.data);
    var legacy = try pb.StateSnapshot.decode(&legacy_reader, legacy_arena.allocator());
    legacy.format_version = 8;
    _ = legacy.primary_authorities.pop();
    const legacy_wire = try encodeMessage(allocator, legacy);
    defer allocator.free(legacy_wire);
    var legacy_machine = PoolStateMachine.init(allocator);
    defer legacy_machine.deinit();
    var legacy_snapshot_reader = TestSnapshotReader{ .data = legacy_wire };
    try legacy_machine.stateMachine().restoreSnapshot(snapshot.metadata, legacy_snapshot_reader.reader());
    var legacy_volume = (try legacy_machine.getVolumeById(allocator, test_volume_id)).?;
    defer legacy_volume.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_PROVISIONING, legacy_volume.lifecycle_state);
    try std.testing.expectEqual(pb.VolumeAvailabilityState.VOLUME_AVAILABILITY_STATE_UNKNOWN, legacy_volume.availability_state);
    try std.testing.expectEqual(pb.VolumeOperationPhase.VOLUME_OPERATION_PHASE_FENCING, legacy_volume.operation_phase);
    try std.testing.expectEqual(@as(usize, 0), legacy_machine.primaryAuthorityCount());
}

test "volume resource lifecycle update list and snapshot recovery" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try addTestVolumeTopology(allocator, &machine);
    var created = try applyTestVolumeCommand(allocator, &machine, 8, testVolumeCommand("lifecycle-volume", test_volume_id, "database", "initial", min_volume_size_bytes, 1_753_744_000_010));
    defer created.deinit(allocator);

    var invalid_reservations = testReservations(min_volume_size_bytes - volume_block_size_bytes);
    const invalid_encoded = try encodeReserveVolumeResourcesCommand(allocator, .{ .volume_id = test_volume_id, .expected_resource_version = 8, .reservations = .{ .items = &invalid_reservations, .capacity = invalid_reservations.len } });
    defer allocator.free(invalid_encoded);
    var invalid = try applyEncodedTestCommand(allocator, &machine, 9, invalid_encoded);
    defer invalid.deinit(allocator);
    var invalid_response = try decodeReserveVolumeResourcesApplyResponse(allocator, invalid.response.?);
    defer invalid_response.deinit(allocator);
    try std.testing.expectEqual(pb.ReserveVolumeResourcesApplyCode.RESERVE_VOLUME_RESOURCES_APPLY_CODE_INVALID_RESERVATION, invalid_response.code);
    try std.testing.expectEqual(@as(usize, 0), machine.replicaPlacementCount());
    try std.testing.expectEqual(@as(usize, 0), machine.replicaAllocationCount());
    var unchanged = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer unchanged.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 8), unchanged.resource_version);

    var reservations = testReservations(min_volume_size_bytes);
    const reserve_encoded = try encodeReserveVolumeResourcesCommand(allocator, .{ .volume_id = test_volume_id, .expected_resource_version = 8, .reservations = .{ .items = &reservations, .capacity = reservations.len } });
    defer allocator.free(reserve_encoded);
    var reserved = try applyEncodedTestCommand(allocator, &machine, 10, reserve_encoded);
    defer reserved.deinit(allocator);
    var reserve_response = try decodeReserveVolumeResourcesApplyResponse(allocator, reserved.response.?);
    defer reserve_response.deinit(allocator);
    try std.testing.expectEqual(pb.ReserveVolumeResourcesApplyCode.RESERVE_VOLUME_RESOURCES_APPLY_CODE_RESERVED, reserve_response.code);
    try std.testing.expectEqual(@as(usize, 8), machine.requestCount());
    const reconcile = try machine.listReconcileVolumes(allocator);
    defer {
        for (reconcile) |*item| item.deinit(allocator);
        allocator.free(reconcile);
    }
    try std.testing.expectEqual(@as(usize, 3), reconcile[0].placements.len);
    try std.testing.expectEqualStrings("node:9000", reconcile[0].nodes[0].control_endpoint);
    try std.testing.expectEqual(@as(u32, 4096), reconcile[0].members[0].extent_size_bytes);

    const placement_ids = [_][]const u8{ test_replica_id, test_second_replica_id, test_third_replica_id };
    const allocation_ids = [_][]const u8{ test_allocation_id, test_second_allocation_id, test_third_allocation_id };
    const member_ids = [_][]const u8{ &test_member_id_a, &test_member_id_b, &test_member_id_c };
    var volume_rv: u64 = 10;
    for (placement_ids, allocation_ids, 0..) |placement_id, allocation_id, index| {
        const activation_encoded = try encodeActivateReplicaCommand(allocator, .{
            .volume_id = test_volume_id,
            .placement_id = placement_id,
            .allocation_id = allocation_id,
            .expected_volume_resource_version = volume_rv,
            .expected_placement_resource_version = 10,
            .expected_allocation_resource_version = 10,
            .attestation = testReplicaAttestation(placement_id, allocation_id, member_ids[index], min_volume_size_bytes),
        });
        defer allocator.free(activation_encoded);
        var activation = try applyEncodedTestCommand(allocator, &machine, 11 + index, activation_encoded);
        defer activation.deinit(allocator);
        var response = try decodeActivateReplicaApplyResponse(allocator, activation.response.?);
        defer response.deinit(allocator);
        try std.testing.expectEqual(pb.ActivateReplicaApplyCode.ACTIVATE_REPLICA_APPLY_CODE_ACTIVATED, response.code);
        volume_rv = 11 + index;
    }
    var active = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer active.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_PROVISIONING, active.lifecycle_state);
    try std.testing.expectEqual(pb.VolumeAvailabilityState.VOLUME_AVAILABILITY_STATE_UNKNOWN, active.availability_state);
    try std.testing.expectEqual(pb.VolumeOperationPhase.VOLUME_OPERATION_PHASE_FENCING, active.operation_phase);

    const update_encoded = try encodeUpdateVolumeCommand(allocator, .{ .request_id = "update-volume", .volume_id = test_volume_id, .description = "updated", .expected_resource_version = 13 });
    defer allocator.free(update_encoded);
    var updated = try applyEncodedTestCommand(allocator, &machine, 14, update_encoded);
    defer updated.deinit(allocator);
    var update_response = try decodeUpdateVolumeApplyResponse(allocator, updated.response.?);
    defer update_response.deinit(allocator);
    try std.testing.expectEqual(pb.UpdateVolumeApplyCode.UPDATE_VOLUME_APPLY_CODE_INVALID_STATE, update_response.code);
    try std.testing.expectEqual(@as(u64, 1), update_response.volume.?.generation);

    var second = try applyTestVolumeCommand(allocator, &machine, 15, testVolumeCommand("second-lifecycle-volume", test_second_volume_id, "logs", "", min_volume_size_bytes, 1_753_744_000_011));
    defer second.deinit(allocator);
    var first_page = try machine.listVolumesPage(allocator, test_pool_id, null, 1);
    defer first_page.deinit(allocator);
    try std.testing.expect(first_page.has_more);
    try std.testing.expectEqualStrings(test_volume_id, first_page.volumes[0].id);
    var second_page = try machine.listVolumesPage(allocator, test_pool_id, first_page.volumes[0].id, 1);
    defer second_page.deinit(allocator);
    try std.testing.expect(!second_page.has_more);
    try std.testing.expectEqualStrings(test_second_volume_id, second_page.volumes[0].id);

    var snapshot = try machine.stateMachine().takeSnapshot(allocator, 15, 1, .{});
    defer snapshot.deinit(allocator);
    var recovered = PoolStateMachine.init(allocator);
    defer recovered.deinit();
    var snapshot_reader = TestSnapshotReader{ .data = snapshot.data };
    try recovered.stateMachine().restoreSnapshot(snapshot.metadata, snapshot_reader.reader());
    var recovered_volume = (try recovered.getVolumeById(allocator, test_volume_id)).?;
    defer recovered_volume.deinit(allocator);
    try std.testing.expectEqualStrings("initial", recovered_volume.description);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_PROVISIONING, recovered_volume.lifecycle_state);
    try std.testing.expectEqual(pb.VolumeOperationPhase.VOLUME_OPERATION_PHASE_FENCING, recovered_volume.operation_phase);
    try std.testing.expectEqual(@as(usize, 3), recovered.replicaAllocationCount());

    var deleted = try applyTestDeleteVolumeCommand(allocator, &machine, 16, testDeleteVolumeCommand("delete-lifecycle", test_volume_id, 13, 1_753_744_000_020));
    defer deleted.deinit(allocator);
    var deleting = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer deleting.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_DELETING, deleting.lifecycle_state);
    try std.testing.expectEqual(pb.VolumeAvailabilityState.VOLUME_AVAILABILITY_STATE_UNAVAILABLE, deleting.availability_state);
    const finalize_encoded = try encodeFinalizeVolumeDeletionCommand(allocator, .{
        .volume_id = test_volume_id,
        .expected_resource_version = 16,
        .placement_ids = .{ .items = @constCast(&placement_ids), .capacity = placement_ids.len },
        .allocation_ids = .{ .items = @constCast(&allocation_ids), .capacity = allocation_ids.len },
        .proposed_deleted_at_unix_ms = 1_753_744_000_020,
    });
    defer allocator.free(finalize_encoded);
    var finalized = try applyEncodedTestCommand(allocator, &machine, 17, finalize_encoded);
    defer finalized.deinit(allocator);
    var finalize_response = try decodeFinalizeVolumeDeletionApplyResponse(allocator, finalized.response.?);
    defer finalize_response.deinit(allocator);
    try std.testing.expectEqual(pb.FinalizeVolumeDeletionApplyCode.FINALIZE_VOLUME_DELETION_APPLY_CODE_FINALIZED, finalize_response.code);
    try std.testing.expectEqual(@as(usize, 0), machine.replicaPlacementCount());
    try std.testing.expectEqual(@as(usize, 0), machine.replicaAllocationCount());
    try std.testing.expectEqual(@as(usize, 1), machine.volumeTombstoneCount());
    try std.testing.expectEqual(@as(?pb.Volume, null), try machine.getVolumeById(allocator, test_volume_id));
    var finalized_snapshot = try machine.stateMachine().takeSnapshot(allocator, 17, 1, .{});
    defer finalized_snapshot.deinit(allocator);
    var finalized_recovery = PoolStateMachine.init(allocator);
    defer finalized_recovery.deinit();
    var finalized_reader = TestSnapshotReader{ .data = finalized_snapshot.data };
    try finalized_recovery.stateMachine().restoreSnapshot(finalized_snapshot.metadata, finalized_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), finalized_recovery.volumeTombstoneCount());
    try std.testing.expectEqual(@as(usize, 1), finalized_recovery.volumeCount());
}

test "volume create get delete replay and durable conflicts" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();

    var pool = try applyTestCommand(allocator, &machine, 1, testCommand("pool-request", test_pool_id, "primary", "", 1_753_744_000_000));
    defer pool.deinit(allocator);
    var created = try applyTestVolumeCommand(allocator, &machine, 2, testVolumeCommand("create-volume", test_volume_id, "database", "primary data", min_volume_size_bytes, 1_753_744_000_001));
    defer created.deinit(allocator);
    var created_response = try decodeCreateVolumeApplyResponse(allocator, created.response.?);
    defer created_response.deinit(allocator);
    try std.testing.expectEqual(pb.CreateVolumeApplyCode.CREATE_VOLUME_APPLY_CODE_CREATED, created_response.code);
    try std.testing.expectEqual(@as(u64, 2), created_response.volume.?.resource_version);
    try std.testing.expectEqual(@as(usize, 1), machine.volumeCount());
    var fetched = (try machine.getVolumeById(allocator, test_volume_id)).?;
    defer fetched.deinit(allocator);
    try std.testing.expect(volumesEqual(created_response.volume.?, fetched));

    var replay = try applyTestVolumeCommand(allocator, &machine, 3, testVolumeCommand("create-volume", test_second_volume_id, "database", "primary data", min_volume_size_bytes, 1_753_744_000_099));
    defer replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, created.response.?, replay.response.?);
    const request_conflict_command = testVolumeCommand("create-volume", test_second_volume_id, "database", "primary data", min_volume_size_bytes * 2, 1_753_744_000_003);
    var request_conflict = try applyTestVolumeCommand(allocator, &machine, 4, request_conflict_command);
    defer request_conflict.deinit(allocator);
    var request_conflict_response = try decodeCreateVolumeApplyResponse(allocator, request_conflict.response.?);
    defer request_conflict_response.deinit(allocator);
    try std.testing.expectEqual(pb.CreateVolumeApplyCode.CREATE_VOLUME_APPLY_CODE_REQUEST_CONFLICT, request_conflict_response.code);

    var name_conflict = try applyTestVolumeCommand(allocator, &machine, 5, testVolumeCommand("name-conflict", test_second_volume_id, "database", "", min_volume_size_bytes, 1_753_744_000_004));
    defer name_conflict.deinit(allocator);
    var name_conflict_response = try decodeCreateVolumeApplyResponse(allocator, name_conflict.response.?);
    defer name_conflict_response.deinit(allocator);
    try std.testing.expectEqual(pb.CreateVolumeApplyCode.CREATE_VOLUME_APPLY_CODE_NAME_EXISTS, name_conflict_response.code);

    var version_conflict = try applyTestDeleteVolumeCommand(allocator, &machine, 6, testDeleteVolumeCommand("delete-version", test_volume_id, 1, 1_753_744_000_005));
    defer version_conflict.deinit(allocator);
    var version_conflict_response = try decodeDeleteVolumeApplyResponse(allocator, version_conflict.response.?);
    defer version_conflict_response.deinit(allocator);
    try std.testing.expectEqual(pb.DeleteVolumeApplyCode.DELETE_VOLUME_APPLY_CODE_VERSION_CONFLICT, version_conflict_response.code);
    var version_replay = try applyTestDeleteVolumeCommand(allocator, &machine, 7, testDeleteVolumeCommand("delete-version", test_volume_id, 1, 1_753_744_000_099));
    defer version_replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, version_conflict.response.?, version_replay.response.?);

    var deleted = try applyTestDeleteVolumeCommand(allocator, &machine, 8, testDeleteVolumeCommand("delete-volume", test_volume_id, 2, 1_753_744_000_006));
    defer deleted.deinit(allocator);
    var deleted_response = try decodeDeleteVolumeApplyResponse(allocator, deleted.response.?);
    defer deleted_response.deinit(allocator);
    try std.testing.expectEqual(pb.DeleteVolumeApplyCode.DELETE_VOLUME_APPLY_CODE_DELETED, deleted_response.code);
    try std.testing.expectEqual(@as(u64, 8), deleted_response.accepted_revision);
    try std.testing.expect(!deleted_response.deletion_pending);
    try std.testing.expectEqual(@as(usize, 0), machine.volumeCount());
    try std.testing.expectEqual(@as(usize, 1), machine.volumeTombstoneCount());
    try std.testing.expectEqual(@as(?pb.Volume, null), try machine.getVolumeById(allocator, test_volume_id));

    var reused_name = try applyTestVolumeCommand(allocator, &machine, 9, testVolumeCommand("reuse-name", test_second_volume_id, "database", "replacement", min_volume_size_bytes, 1_753_744_000_007));
    defer reused_name.deinit(allocator);
    var reused_name_response = try decodeCreateVolumeApplyResponse(allocator, reused_name.response.?);
    defer reused_name_response.deinit(allocator);
    try std.testing.expectEqual(pb.CreateVolumeApplyCode.CREATE_VOLUME_APPLY_CODE_CREATED, reused_name_response.code);
    var tombstoned_id = try applyTestVolumeCommand(allocator, &machine, 10, testVolumeCommand("reuse-id", test_volume_id, "other", "", min_volume_size_bytes, 1_753_744_000_008));
    defer tombstoned_id.deinit(allocator);
    var tombstoned_id_response = try decodeCreateVolumeApplyResponse(allocator, tombstoned_id.response.?);
    defer tombstoned_id_response.deinit(allocator);
    try std.testing.expectEqual(pb.CreateVolumeApplyCode.CREATE_VOLUME_APPLY_CODE_ID_EXISTS, tombstoned_id_response.code);
    var missing = try applyTestDeleteVolumeCommand(allocator, &machine, 11, testDeleteVolumeCommand("delete-tombstone", test_volume_id, 2, 1_753_744_000_009));
    defer missing.deinit(allocator);
    var missing_response = try decodeDeleteVolumeApplyResponse(allocator, missing.response.?);
    defer missing_response.deinit(allocator);
    try std.testing.expectEqual(pb.DeleteVolumeApplyCode.DELETE_VOLUME_APPLY_CODE_NOT_FOUND, missing_response.code);
}

test "replica placement restore rejects same node and failure domain" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try addTestPoolAndNode(allocator, &machine);
    var volume = try applyTestVolumeCommand(allocator, &machine, 3, testVolumeCommand("volume-request", test_volume_id, "database", "", min_volume_size_bytes, 1_753_744_000_002));
    defer volume.deinit(allocator);
    try restoreNode(allocator, &machine.state, .{
        .id = test_second_node_id,
        .cluster_id = &test_cluster_id,
        .control_endpoint = "127.0.0.2:9000",
        .nvmf_endpoint = "127.0.0.2:4420",
        .failure_domain = "rack-a",
        .capability_bits = 5,
        .protocol_version = 1,
        .registered_at_unix_ms = 1_753_744_000_003,
        .registered_revision = 4,
    });
    try restoreReplicaPlacement(allocator, &machine.state, .{
        .id = test_replica_id,
        .volume_id = test_volume_id,
        .node_id = test_node_id,
        .replica_index = 0,
        .generation = 1,
        .state = .REPLICA_PLACEMENT_STATE_ACTIVE,
        .created_revision = 5,
        .resource_version = 5,
        .backend_digest = &test_backend_digest,
        .attested_revision = 5,
    }, 7, snapshot_format_version);
    try std.testing.expectError(error.PayloadParseFailed, restoreReplicaPlacement(allocator, &machine.state, .{
        .id = test_second_replica_id,
        .volume_id = test_volume_id,
        .node_id = test_node_id,
        .replica_index = 1,
        .generation = 1,
        .state = .REPLICA_PLACEMENT_STATE_RESERVED,
        .created_revision = 6,
        .resource_version = 6,
    }, 7, snapshot_format_version));
    try std.testing.expectError(error.PayloadParseFailed, restoreReplicaPlacement(allocator, &machine.state, .{
        .id = test_third_replica_id,
        .volume_id = test_volume_id,
        .node_id = test_second_node_id,
        .replica_index = 1,
        .generation = 1,
        .state = .REPLICA_PLACEMENT_STATE_RESERVED,
        .created_revision = 7,
        .resource_version = 7,
    }, 7, snapshot_format_version));
    try std.testing.expectEqual(@as(usize, 1), machine.state.replica_placements_by_id.count());
}

test "historical volume limit validation allows a later replacement" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const state_allocator = arena.allocator();
    var state: State = .{};
    defer state.deinit(state_allocator);
    try restorePool(state_allocator, &state, .{
        .id = test_pool_id,
        .name = "primary",
        .created_at_unix_ms = 1_753_744_000_000,
        .created_revision = 1,
    });
    try state.volumes_by_id.ensureUnusedCapacity(state_allocator, max_volumes);
    const limit_revision: u64 = 30_000;
    for (0..max_volumes - 1) |index| {
        const id = try std.fmt.allocPrint(state_allocator, "historical-volume-{d}", .{index});
        const name = try std.fmt.allocPrint(state_allocator, "historical-name-{d}", .{index});
        const owned = try Volume.init(state_allocator, .{
            .id = id,
            .pool_id = test_pool_id,
            .name = name,
            .size_bytes = min_volume_size_bytes,
            .protection_kind = .VOLUME_PROTECTION_KIND_REPLICATED,
            .target_replica_count = volume_target_replica_count,
            .write_quorum = volume_write_quorum,
            .read_quorum = volume_read_quorum,
            .lifecycle_state = .VOLUME_LIFECYCLE_STATE_PROVISIONING,
            .availability_state = .VOLUME_AVAILABILITY_STATE_UNKNOWN,
            .operation_phase = .VOLUME_OPERATION_PHASE_NONE,
            .generation = 1,
            .write_epoch = 1,
            .created_at_unix_ms = 1_753_744_000_001,
            .created_revision = 2,
            .resource_version = 2,
        });
        state.volumes_by_id.putAssumeCapacity(owned.id, owned);
    }
    const deleted = try Volume.init(state_allocator, .{
        .id = "historical-deleted-volume",
        .pool_id = test_pool_id,
        .name = "historical-deleted-name",
        .size_bytes = min_volume_size_bytes,
        .protection_kind = .VOLUME_PROTECTION_KIND_REPLICATED,
        .target_replica_count = volume_target_replica_count,
        .write_quorum = volume_write_quorum,
        .read_quorum = volume_read_quorum,
        .lifecycle_state = .VOLUME_LIFECYCLE_STATE_PROVISIONING,
        .availability_state = .VOLUME_AVAILABILITY_STATE_UNKNOWN,
        .operation_phase = .VOLUME_OPERATION_PHASE_NONE,
        .generation = 1,
        .write_epoch = 1,
        .created_at_unix_ms = 1_753_744_000_001,
        .created_revision = 2,
        .resource_version = 2,
    });
    try state.volume_tombstones_by_id.put(state_allocator, deleted.id, .{
        .volume = deleted,
        .deleted_at_unix_ms = 1_753_744_000_010,
        .deleted_revision = limit_revision + 1,
    });
    const replacement = try Volume.init(state_allocator, .{
        .id = "later-replacement-volume",
        .pool_id = test_pool_id,
        .name = "later-replacement-name",
        .size_bytes = min_volume_size_bytes,
        .protection_kind = .VOLUME_PROTECTION_KIND_REPLICATED,
        .target_replica_count = volume_target_replica_count,
        .write_quorum = volume_write_quorum,
        .read_quorum = volume_read_quorum,
        .lifecycle_state = .VOLUME_LIFECYCLE_STATE_PROVISIONING,
        .availability_state = .VOLUME_AVAILABILITY_STATE_UNKNOWN,
        .operation_phase = .VOLUME_OPERATION_PHASE_NONE,
        .generation = 1,
        .write_epoch = 1,
        .created_at_unix_ms = 1_753_744_000_011,
        .created_revision = limit_revision + 2,
        .resource_version = limit_revision + 2,
    });
    state.volumes_by_id.putAssumeCapacity(replacement.id, replacement);
    state.max_volume_created_revision = limit_revision + 2;

    try std.testing.expectEqual(max_volumes, liveVolumeCountAt(&state, limit_revision));
    try std.testing.expect(state.max_volume_created_revision > limit_revision);
    try std.testing.expectEqual(@as(?[]const u8, null), try validateStoredVolumeResponse(&state, testVolumeCommand(
        "limit-request",
        test_volume_id,
        "limit-target",
        "",
        min_volume_size_bytes,
        1_753_744_000_002,
    ), .{ .code = .CREATE_VOLUME_APPLY_CODE_VOLUME_LIMIT }, limit_revision));
}

test "volume snapshot requires delete records and rejects forged name overlap" {
    const allocator = std.testing.allocator;
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    var pool = try applyTestCommand(allocator, &source, 1, testCommand("pool-request", test_pool_id, "primary", "", 1_753_744_000_000));
    defer pool.deinit(allocator);
    var original = try applyTestVolumeCommand(allocator, &source, 2, testVolumeCommand("create-original", test_volume_id, "database", "", min_volume_size_bytes, 1_753_744_000_001));
    defer original.deinit(allocator);
    var deleted = try applyTestDeleteVolumeCommand(allocator, &source, 3, testDeleteVolumeCommand("delete-original", test_volume_id, 2, 1_753_744_000_002));
    defer deleted.deinit(allocator);
    var replacement = try applyTestVolumeCommand(allocator, &source, 4, testVolumeCommand("create-replacement", test_second_volume_id, "database", "", min_volume_size_bytes, 1_753_744_000_003));
    defer replacement.deinit(allocator);
    var snapshot = try source.stateMachine().takeSnapshot(allocator, 5, 1, .{});
    defer snapshot.deinit(allocator);

    var legitimate = PoolStateMachine.init(allocator);
    defer legitimate.deinit();
    var legitimate_reader = TestSnapshotReader{ .data = snapshot.data };
    try legitimate.stateMachine().restoreSnapshot(snapshot.metadata, legitimate_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), legitimate.volumeCount());
    try std.testing.expectEqual(@as(usize, 1), legitimate.volumeTombstoneCount());

    var missing_arena: std.heap.ArenaAllocator = .init(allocator);
    defer missing_arena.deinit();
    var snapshot_reader: std.Io.Reader = .fixed(snapshot.data);
    var missing = try pb.StateSnapshot.decode(&snapshot_reader, missing_arena.allocator());
    var delete_index: usize = 0;
    while (!std.mem.eql(u8, missing.requests.items[delete_index].request_id, "delete-original")) : (delete_index += 1) {}
    _ = missing.requests.orderedRemove(delete_index);
    const missing_wire = try encodeMessage(allocator, missing);
    defer allocator.free(missing_wire);
    var missing_machine = PoolStateMachine.init(allocator);
    defer missing_machine.deinit();
    var missing_reader = TestSnapshotReader{ .data = missing_wire };
    try std.testing.expectError(error.PayloadParseFailed, missing_machine.stateMachine().restoreSnapshot(snapshot.metadata, missing_reader.reader()));

    var forged_arena: std.heap.ArenaAllocator = .init(allocator);
    defer forged_arena.deinit();
    var forged_reader: std.Io.Reader = .fixed(snapshot.data);
    var forged = try pb.StateSnapshot.decode(&forged_reader, forged_arena.allocator());
    forged.volume_tombstones.items[0].deleted_revision = 5;
    for (forged.requests.items) |*request| {
        if (!std.mem.eql(u8, request.request_id, "delete-original")) continue;
        request.applied_revision = 5;
        var response_reader: std.Io.Reader = .fixed(request.encoded_response);
        var response = try pb.DeleteVolumeApplyResponse.decode(&response_reader, forged_arena.allocator());
        response.accepted_revision = 5;
        request.encoded_response = try encodeMessage(forged_arena.allocator(), response);
    }
    const forged_wire = try encodeMessage(allocator, forged);
    defer allocator.free(forged_wire);
    var forged_machine = PoolStateMachine.init(allocator);
    defer forged_machine.deinit();
    var forged_snapshot_reader = TestSnapshotReader{ .data = forged_wire };
    try std.testing.expectError(error.PayloadParseFailed, forged_machine.stateMachine().restoreSnapshot(snapshot.metadata, forged_snapshot_reader.reader()));
}

test "version 5 snapshot deterministically preserves volume children" {
    const allocator = std.testing.allocator;
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    try addTestPoolAndNode(allocator, &source);
    var member = try applyTestMemberCommand(allocator, &source, 3, testMemberCommand("member-request", &test_member_id_a, test_pool_id, test_node_id, &test_local_set_id, 0, 1_753_744_000_002));
    defer member.deinit(allocator);
    var volume = try applyTestVolumeCommand(allocator, &source, 4, testVolumeCommand("volume-request", test_volume_id, "database", "", min_volume_size_bytes, 1_753_744_000_003));
    defer volume.deinit(allocator);
    var base = try source.stateMachine().takeSnapshot(allocator, 7, 1, .{});
    defer base.deinit(allocator);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var base_reader: std.Io.Reader = .fixed(base.data);
    var decoded = try pb.StateSnapshot.decode(&base_reader, arena.allocator());
    try decoded.replica_placements.append(arena.allocator(), .{
        .id = test_replica_id,
        .volume_id = test_volume_id,
        .node_id = test_node_id,
        .replica_index = 0,
        .generation = 1,
        .state = .REPLICA_PLACEMENT_STATE_ACTIVE,
        .created_revision = 5,
        .resource_version = 5,
    });
    try decoded.replica_allocations.append(arena.allocator(), .{
        .id = test_allocation_id,
        .replica_id = test_replica_id,
        .member_id = &test_member_id_a,
        .offset_bytes = 0,
        .length_bytes = 4096,
        .generation = 1,
        .state = .REPLICA_ALLOCATION_STATE_ACTIVE,
        .created_revision = 6,
        .resource_version = 6,
    });
    try decoded.volume_attachments.append(arena.allocator(), .{
        .id = test_attachment_id,
        .volume_id = test_volume_id,
        .target_node_id = test_node_id,
        .consumer_id = "test-consumer",
        .access_mode = .VOLUME_ACCESS_MODE_SINGLE_NODE_WRITER,
        .state = .VOLUME_ATTACHMENT_STATE_ATTACHED,
        .generation = 1,
        .created_revision = 7,
        .resource_version = 7,
    });
    decoded.format_version = 5;
    const child_wire = try encodeMessage(allocator, decoded);
    defer allocator.free(child_wire);

    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var child_reader = TestSnapshotReader{ .data = child_wire };
    try restored.stateMachine().restoreSnapshot(base.metadata, child_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), restored.volumeCount());
    try std.testing.expectEqual(@as(usize, 1), restored.state.replica_placements_by_id.count());
    try std.testing.expectEqual(@as(usize, 1), restored.state.replica_allocations_by_id.count());
    try std.testing.expectEqual(@as(usize, 1), restored.state.volume_attachments_by_id.count());

    var first = try restored.stateMachine().takeSnapshot(allocator, 7, 1, .{});
    defer first.deinit(allocator);
    var second = try restored.stateMachine().takeSnapshot(allocator, 7, 1, .{});
    defer second.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.data, second.data);
    var round_tripped = PoolStateMachine.init(allocator);
    defer round_tripped.deinit();
    var first_reader = TestSnapshotReader{ .data = first.data };
    try round_tripped.stateMachine().restoreSnapshot(first.metadata, first_reader.reader());
    var normalized = try round_tripped.stateMachine().takeSnapshot(allocator, 7, 1, .{});
    defer normalized.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.data, normalized.data);

    var blocked_delete = try applyTestDeleteVolumeCommand(allocator, &restored, 8, testDeleteVolumeCommand("blocked-delete", test_volume_id, 4, 1_753_744_000_004));
    defer blocked_delete.deinit(allocator);
    var blocked_response = try decodeDeleteVolumeApplyResponse(allocator, blocked_delete.response.?);
    defer blocked_response.deinit(allocator);
    try std.testing.expectEqual(pb.DeleteVolumeApplyCode.DELETE_VOLUME_APPLY_CODE_DELETION_ACCEPTED, blocked_response.code);
    try std.testing.expect(blocked_response.deletion_pending);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_DELETING, blocked_response.volume.?.lifecycle_state);
    var deleting_volume = (try restored.getVolumeById(allocator, test_volume_id)).?;
    defer deleting_volume.deinit(allocator);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_DELETING, deleting_volume.lifecycle_state);

    var pending_snapshot = try restored.stateMachine().takeSnapshot(allocator, 8, 1, .{});
    defer pending_snapshot.deinit(allocator);
    var legacy_arena: std.heap.ArenaAllocator = .init(allocator);
    defer legacy_arena.deinit();
    var pending_reader: std.Io.Reader = .fixed(pending_snapshot.data);
    var legacy = try pb.StateSnapshot.decode(&pending_reader, legacy_arena.allocator());
    legacy.format_version = 5;
    for (legacy.requests.items) |*request| {
        if (!std.mem.eql(u8, request.request_id, "blocked-delete")) continue;
        var response_reader: std.Io.Reader = .fixed(request.encoded_response);
        var response = try pb.DeleteVolumeApplyResponse.decode(&response_reader, legacy_arena.allocator());
        response.code = .DELETE_VOLUME_APPLY_CODE_DELETED;
        response.deletion_pending = false;
        response.volume = null;
        request.encoded_response = try encodeMessage(legacy_arena.allocator(), response);
    }
    const legacy_wire = try encodeMessage(allocator, legacy);
    defer allocator.free(legacy_wire);
    var legacy_restored = PoolStateMachine.init(allocator);
    defer legacy_restored.deinit();
    var legacy_reader = TestSnapshotReader{ .data = legacy_wire };
    try legacy_restored.stateMachine().restoreSnapshot(pending_snapshot.metadata, legacy_reader.reader());
    var replayed = try applyTestDeleteVolumeCommand(allocator, &legacy_restored, 9, testDeleteVolumeCommand("blocked-delete", test_volume_id, 4, 1_753_744_000_004));
    defer replayed.deinit(allocator);
    var replayed_response = try decodeDeleteVolumeApplyResponse(allocator, replayed.response.?);
    defer replayed_response.deinit(allocator);
    try std.testing.expectEqual(pb.DeleteVolumeApplyCode.DELETE_VOLUME_APPLY_CODE_DELETION_ACCEPTED, replayed_response.code);
    try std.testing.expect(replayed_response.deletion_pending);
    try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_DELETING, replayed_response.volume.?.lifecycle_state);

    var corrupt_arena: std.heap.ArenaAllocator = .init(allocator);
    defer corrupt_arena.deinit();
    var valid_reader: std.Io.Reader = .fixed(first.data);
    var corrupt = try pb.StateSnapshot.decode(&valid_reader, corrupt_arena.allocator());
    try corrupt.replica_allocations.append(corrupt_arena.allocator(), .{
        .id = test_second_allocation_id,
        .replica_id = test_replica_id,
        .member_id = &test_member_id_a,
        .offset_bytes = 0,
        .length_bytes = 4096,
        .generation = 1,
        .state = .REPLICA_ALLOCATION_STATE_RESERVED,
        .created_revision = 7,
        .resource_version = 7,
    });
    const corrupt_wire = try encodeMessage(allocator, corrupt);
    defer allocator.free(corrupt_wire);
    var rejected = PoolStateMachine.init(allocator);
    defer rejected.deinit();
    var corrupt_reader = TestSnapshotReader{ .data = corrupt_wire };
    try std.testing.expectError(error.PayloadParseFailed, rejected.stateMachine().restoreSnapshot(first.metadata, corrupt_reader.reader()));

    var missing_arena: std.heap.ArenaAllocator = .init(allocator);
    defer missing_arena.deinit();
    var complete_reader: std.Io.Reader = .fixed(first.data);
    var missing = try pb.StateSnapshot.decode(&complete_reader, missing_arena.allocator());
    _ = missing.replica_allocations.pop();
    missing.format_version = 5;
    const missing_wire = try encodeMessage(allocator, missing);
    defer allocator.free(missing_wire);
    var missing_machine = PoolStateMachine.init(allocator);
    defer missing_machine.deinit();
    var missing_reader = TestSnapshotReader{ .data = missing_wire };
    try missing_machine.stateMachine().restoreSnapshot(first.metadata, missing_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), missing_machine.volumeCount());
    try std.testing.expectEqual(@as(usize, 1), missing_machine.state.replica_placements_by_id.count());
    try std.testing.expectEqual(@as(usize, 0), missing_machine.state.replica_allocations_by_id.count());
    const reconcile_volumes = try missing_machine.listReconcileVolumes(allocator);
    defer {
        for (reconcile_volumes) |*reconcile_volume| reconcile_volume.deinit(allocator);
        allocator.free(reconcile_volumes);
    }
    try std.testing.expectEqual(@as(usize, 1), reconcile_volumes.len);
    try std.testing.expectEqual(@as(usize, 1), reconcile_volumes[0].placements.len);
    try std.testing.expectEqual(@as(usize, 0), reconcile_volumes[0].allocations.len);

    missing.format_version = 6;
    const version_6_wire = try encodeMessage(allocator, missing);
    defer allocator.free(version_6_wire);
    var version_6_machine = PoolStateMachine.init(allocator);
    defer version_6_machine.deinit();
    var version_6_reader = TestSnapshotReader{ .data = version_6_wire };
    try std.testing.expectError(error.PayloadParseFailed, version_6_machine.stateMachine().restoreSnapshot(first.metadata, version_6_reader.reader()));
}

test "legacy command version 1 and snapshot version 4 remain restorable" {
    const allocator = std.testing.allocator;
    const pool_command = testCommand("legacy-pool", test_pool_id, "primary", "", 1_753_744_000_000);
    const legacy_wire = try encodeMessage(allocator, pb.CommandEnvelope{ .format_version = 1, .command = .{ .create_pool = pool_command } });
    defer allocator.free(legacy_wire);
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    var applied = try source.stateMachine().apply(.{ .index = 1, .term = 1, .data = legacy_wire });
    defer applied.deinit(allocator);
    var current = try source.stateMachine().takeSnapshot(allocator, 1, 1, .{});
    defer current.deinit(allocator);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var current_reader: std.Io.Reader = .fixed(current.data);
    var decoded = try pb.StateSnapshot.decode(&current_reader, arena.allocator());
    decoded.format_version = 4;
    var request_reader: std.Io.Reader = .fixed(decoded.requests.items[0].encoded_command);
    var request_envelope = try pb.CommandEnvelope.decode(&request_reader, arena.allocator());
    request_envelope.format_version = 1;
    decoded.requests.items[0].encoded_command = try encodeMessage(arena.allocator(), request_envelope);
    const version_4_wire = try encodeMessage(allocator, decoded);
    defer allocator.free(version_4_wire);
    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var legacy_reader = TestSnapshotReader{ .data = version_4_wire };
    try restored.stateMachine().restoreSnapshot(current.metadata, legacy_reader.reader());
    try std.testing.expectEqual(@as(usize, 1), restored.poolCount());

    decoded.volumes = .empty;
    try decoded.volumes.append(arena.allocator(), .{
        .id = test_volume_id,
        .pool_id = test_pool_id,
        .name = "forbidden",
        .size_bytes = min_volume_size_bytes,
        .protection_kind = .VOLUME_PROTECTION_KIND_REPLICATED,
        .target_replica_count = volume_target_replica_count,
        .write_quorum = volume_write_quorum,
        .read_quorum = volume_read_quorum,
        .lifecycle_state = .VOLUME_LIFECYCLE_STATE_PROVISIONING,
        .availability_state = .VOLUME_AVAILABILITY_STATE_UNKNOWN,
        .operation_phase = .VOLUME_OPERATION_PHASE_NONE,
        .generation = 1,
        .write_epoch = 1,
        .created_at_unix_ms = 1_753_744_000_001,
        .created_revision = 1,
        .resource_version = 1,
    });
    const invalid_legacy_wire = try encodeMessage(allocator, decoded);
    defer allocator.free(invalid_legacy_wire);
    var invalid_reader = TestSnapshotReader{ .data = invalid_legacy_wire };
    try std.testing.expectError(error.PayloadParseFailed, restored.stateMachine().restoreSnapshot(current.metadata, invalid_reader.reader()));
}

fn testHeartbeatRequest(
    cluster_id: []const u8,
    node_id: []const u8,
    members: []pb.MemberHeartbeat,
) pb.ReportHeartbeatRequest {
    return .{
        .cluster_id = cluster_id,
        .node_id = node_id,
        .incarnation = 1,
        .sequence = 1,
        .members = .{ .items = members, .capacity = members.len },
    };
}

test "heartbeat binding validation covers registration and capacity outcomes" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    var no_members: [0]pb.MemberHeartbeat = .{};
    try std.testing.expectEqual(
        PoolStateMachine.HeartbeatBindingResult.node_not_found,
        machine.validateHeartbeatBinding(testHeartbeatRequest(&test_cluster_id, test_node_id, &no_members)),
    );

    try addTestPoolAndNode(allocator, &machine);
    var reported = [_]pb.MemberHeartbeat{.{
        .member_id = &test_member_id_a,
        .local_set_id = &test_local_set_id,
        .member_slot = 0,
        .state = .MEMBER_HEARTBEAT_STATE_PRESENT,
        .capacity = .{ .free_extent_count = 2 },
    }};
    try std.testing.expectEqual(
        PoolStateMachine.HeartbeatBindingResult.member_not_found,
        machine.validateHeartbeatBinding(testHeartbeatRequest(&test_cluster_id, test_node_id, &reported)),
    );

    var registered = try applyTestMemberCommand(allocator, &machine, 3, testMemberCommand(
        "heartbeat-member-request",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_002,
    ));
    defer registered.deinit(allocator);
    try std.testing.expectEqual(
        PoolStateMachine.HeartbeatBindingResult.ok,
        machine.validateHeartbeatBinding(testHeartbeatRequest(&test_cluster_id, test_node_id, &reported)),
    );

    var other_cluster = test_cluster_id;
    other_cluster[0] = 99;
    try std.testing.expectEqual(
        PoolStateMachine.HeartbeatBindingResult.binding_mismatch,
        machine.validateHeartbeatBinding(testHeartbeatRequest(&other_cluster, test_node_id, &reported)),
    );
    reported[0].member_slot = 1;
    try std.testing.expectEqual(
        PoolStateMachine.HeartbeatBindingResult.binding_mismatch,
        machine.validateHeartbeatBinding(testHeartbeatRequest(&test_cluster_id, test_node_id, &reported)),
    );
    reported[0].member_slot = 0;
    reported[0].capacity.?.free_extent_count = 1;
    try std.testing.expectEqual(
        PoolStateMachine.HeartbeatBindingResult.capacity_mismatch,
        machine.validateHeartbeatBinding(testHeartbeatRequest(&test_cluster_id, test_node_id, &reported)),
    );
}

test "heartbeat capacity validation rejects indivisible registered capacity" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try addTestPoolAndNode(allocator, &machine);
    var command = testMemberCommand(
        "indivisible-member-request",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_002,
    );
    command.data_capacity_bytes += 1;
    var registered = try applyTestMemberCommand(allocator, &machine, 3, command);
    defer registered.deinit(allocator);
    var reported = [_]pb.MemberHeartbeat{.{
        .member_id = &test_member_id_a,
        .local_set_id = &test_local_set_id,
        .state = .MEMBER_HEARTBEAT_STATE_PRESENT,
        .capacity = .{ .free_extent_count = 2 },
    }};
    try std.testing.expectEqual(
        PoolStateMachine.HeartbeatBindingResult.capacity_mismatch,
        machine.validateHeartbeatBinding(testHeartbeatRequest(&test_cluster_id, test_node_id, &reported)),
    );
}

test "heartbeat observations stay outside snapshots and restore" {
    const allocator = std.testing.allocator;
    var store = heartbeat.HeartbeatStore.init(allocator);
    defer store.deinit();
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    machine.setHeartbeatStore(&store);
    try addTestPoolAndNode(allocator, &machine);
    var registered = try applyTestMemberCommand(allocator, &machine, 3, testMemberCommand(
        "snapshot-heartbeat-member",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_002,
    ));
    defer registered.deinit(allocator);

    var before = try machine.stateMachine().takeSnapshot(allocator, 3, 1, .{});
    defer before.deinit(allocator);
    machine.stateMachine().onLeadershipChange(true, 9, 1);
    var reported = [_]pb.MemberHeartbeat{.{
        .member_id = &test_member_id_a,
        .local_set_id = &test_local_set_id,
        .state = .MEMBER_HEARTBEAT_STATE_PRESENT,
        .capacity = .{ .free_extent_count = 2 },
    }};
    _ = try store.report(testHeartbeatRequest(&test_cluster_id, test_node_id, &reported), 9, 100, 1_000);
    var after = try machine.stateMachine().takeSnapshot(allocator, 3, 1, .{});
    defer after.deinit(allocator);
    try std.testing.expectEqualSlices(u8, before.data, after.data);

    var in_place_reader = TestSnapshotReader{ .data = after.data };
    try machine.stateMachine().restoreSnapshot(after.metadata, in_place_reader.reader());
    try std.testing.expectEqual(@as(?heartbeat.GetResult, null), try store.get(test_node_id, 9, 200));

    var restored_store = heartbeat.HeartbeatStore.init(allocator);
    defer restored_store.deinit();
    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    restored.setHeartbeatStore(&restored_store);
    restored.stateMachine().onLeadershipChange(true, 10, 1);
    var reader = TestSnapshotReader{ .data = after.data };
    try restored.stateMachine().restoreSnapshot(after.metadata, reader.reader());
    try std.testing.expectEqual(@as(?heartbeat.GetResult, null), try restored_store.get(test_node_id, 10, 200));
}

fn overlongFirstVarint(allocator: std.mem.Allocator, canonical: []const u8) ![]u8 {
    try std.testing.expect(canonical.len >= 2 and canonical[0] == 0x08 and canonical[1] < 0x80);
    const result = try allocator.alloc(u8, canonical.len + 1);
    result[0] = 0x08;
    result[1] = canonical[1] | 0x80;
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

test "register member supports get revision pagination replay and cross-kind conflicts" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try addTestPoolAndNode(allocator, &machine);

    const first_command = testMemberCommand(
        "member-request-a",
        &test_member_id_b,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_002,
    );
    var first = try applyTestMemberCommand(allocator, &machine, 3, first_command);
    defer first.deinit(allocator);
    var first_response = try decodeRegisterMemberApplyResponse(allocator, first.response.?);
    defer first_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_REGISTERED, first_response.code);
    try std.testing.expectEqual(@as(u64, 3), first_response.member.?.registered_revision);
    try std.testing.expectEqual(@as(u32, 0), first_response.member.?.member_slot);

    var second = try applyTestMemberCommand(allocator, &machine, 4, testMemberCommand(
        "member-request-b",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        1,
        1_753_744_000_003,
    ));
    defer second.deinit(allocator);
    var fetched = (try machine.getMemberById(allocator, &test_member_id_a)).?;
    defer fetched.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), fetched.member_slot);

    var first_page = try machine.listMembersPage(allocator, null, 1);
    defer first_page.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &test_member_id_b, first_page.members[0].id);
    try std.testing.expect(first_page.has_more);
    var second_page = try machine.listMembersPage(allocator, &test_member_id_b, 10);
    defer second_page.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, second_page.members[0].id);
    try std.testing.expect(!second_page.has_more);
    try std.testing.expectError(error.InvalidPageToken, machine.listMembersPage(allocator, "missing", 1));

    var retry_command = first_command;
    retry_command.proposed_registered_at_unix_ms += 999;
    var replay = try applyTestMemberCommand(allocator, &machine, 5, retry_command);
    defer replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.response.?, replay.response.?);

    var fingerprint_conflict_command = retry_command;
    var other_cluster = test_cluster_id;
    other_cluster[0] = 99;
    fingerprint_conflict_command.cluster_id = &other_cluster;
    var fingerprint_conflict = try applyTestMemberCommand(allocator, &machine, 6, fingerprint_conflict_command);
    defer fingerprint_conflict.deinit(allocator);
    var fingerprint_conflict_response = try decodeRegisterMemberApplyResponse(allocator, fingerprint_conflict.response.?);
    defer fingerprint_conflict_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_REQUEST_CONFLICT, fingerprint_conflict_response.code);

    var member_conflict = try applyTestMemberCommand(allocator, &machine, 7, testMemberCommand(
        "member-pool-request",
        &test_member_id_c,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        2,
        1_753_744_000_004,
    ));
    defer member_conflict.deinit(allocator);
    var member_conflict_response = try decodeRegisterMemberApplyResponse(allocator, member_conflict.response.?);
    defer member_conflict_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_REQUEST_CONFLICT, member_conflict_response.code);

    var node_conflict = try applyTestNodeCommand(allocator, &machine, 8, testNodeCommand(
        "member-request-a",
        "0198f54d-5c2a-7000-8000-000000000022",
        "node-b:9000",
        1_753_744_000_005,
    ));
    defer node_conflict.deinit(allocator);
    var node_conflict_response = try decodeRegisterNodeApplyResponse(allocator, node_conflict.response.?);
    defer node_conflict_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterNodeApplyCode.REGISTER_NODE_APPLY_CODE_REQUEST_CONFLICT, node_conflict_response.code);
    try std.testing.expectEqual(@as(usize, 2), machine.memberCount());
}

test "member registration records missing pool and node outcomes" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();

    const missing_pool_command = testMemberCommand(
        "missing-pool-request",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_000,
    );
    var missing_pool = try applyTestMemberCommand(allocator, &machine, 1, missing_pool_command);
    defer missing_pool.deinit(allocator);
    var missing_pool_response = try decodeRegisterMemberApplyResponse(allocator, missing_pool.response.?);
    defer missing_pool_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_POOL_NOT_FOUND, missing_pool_response.code);

    var pool = try applyTestCommand(allocator, &machine, 2, testCommand(
        "pool-after-miss",
        test_pool_id,
        "member-pool",
        "",
        1_753_744_000_001,
    ));
    defer pool.deinit(allocator);
    const missing_node_command = testMemberCommand(
        "missing-node-request",
        &test_member_id_b,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_002,
    );
    var missing_node = try applyTestMemberCommand(allocator, &machine, 3, missing_node_command);
    defer missing_node.deinit(allocator);
    var missing_node_response = try decodeRegisterMemberApplyResponse(allocator, missing_node.response.?);
    defer missing_node_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_NODE_NOT_FOUND, missing_node_response.code);

    var node = try applyTestNodeCommand(allocator, &machine, 4, testNodeCommand(
        "node-after-miss",
        test_node_id,
        "node-a:9000",
        1_753_744_000_003,
    ));
    defer node.deinit(allocator);
    var pool_replay = try applyTestMemberCommand(allocator, &machine, 5, missing_pool_command);
    defer pool_replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, missing_pool.response.?, pool_replay.response.?);
    var node_replay = try applyTestMemberCommand(allocator, &machine, 6, missing_node_command);
    defer node_replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, missing_node.response.?, node_replay.response.?);

    var wrong_cluster_command = testMemberCommand(
        "wrong-cluster-request",
        &test_member_id_c,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_004,
    );
    var wrong_cluster = test_cluster_id;
    wrong_cluster[0] = 99;
    wrong_cluster_command.cluster_id = &wrong_cluster;
    var wrong_cluster_result = try applyTestMemberCommand(allocator, &machine, 7, wrong_cluster_command);
    defer wrong_cluster_result.deinit(allocator);
    var wrong_cluster_response = try decodeRegisterMemberApplyResponse(allocator, wrong_cluster_result.response.?);
    defer wrong_cluster_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_CLUSTER_MISMATCH, wrong_cluster_response.code);
    try std.testing.expectEqual(@as(usize, 0), machine.memberCount());
}

test "member id local set and slot conflicts are deterministic" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try addTestPoolAndNode(allocator, &machine);
    var second_pool = try applyTestCommand(allocator, &machine, 3, testCommand(
        "second-pool-request",
        test_second_pool_id,
        "second-member-pool",
        "",
        1_753_744_000_002,
    ));
    defer second_pool.deinit(allocator);
    var registered = try applyTestMemberCommand(allocator, &machine, 4, testMemberCommand(
        "member-request-a",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_003,
    ));
    defer registered.deinit(allocator);

    var duplicate_id = try applyTestMemberCommand(allocator, &machine, 5, testMemberCommand(
        "duplicate-id-request",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        1,
        1_753_744_000_004,
    ));
    defer duplicate_id.deinit(allocator);
    var duplicate_id_response = try decodeRegisterMemberApplyResponse(allocator, duplicate_id.response.?);
    defer duplicate_id_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_ID_EXISTS, duplicate_id_response.code);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, duplicate_id_response.member.?.id);

    var local_set_conflict = try applyTestMemberCommand(allocator, &machine, 6, testMemberCommand(
        "local-set-conflict-request",
        &test_member_id_b,
        test_second_pool_id,
        test_node_id,
        &test_local_set_id,
        1,
        1_753_744_000_005,
    ));
    defer local_set_conflict.deinit(allocator);
    var local_set_response = try decodeRegisterMemberApplyResponse(allocator, local_set_conflict.response.?);
    defer local_set_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_LOCAL_SET_CONFLICT, local_set_response.code);

    var slot_conflict = try applyTestMemberCommand(allocator, &machine, 7, testMemberCommand(
        "slot-conflict-request",
        &test_member_id_c,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_006,
    ));
    defer slot_conflict.deinit(allocator);
    var slot_response = try decodeRegisterMemberApplyResponse(allocator, slot_conflict.response.?);
    defer slot_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterMemberApplyCode.REGISTER_MEMBER_APPLY_CODE_SLOT_EXISTS, slot_response.code);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, slot_response.member.?.id);
    try std.testing.expectEqual(@as(usize, 1), machine.memberCount());
}

test "mixed member snapshots are deterministic and restore request history" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try addTestPoolAndNode(allocator, &machine);
    var member_b = try applyTestMemberCommand(allocator, &machine, 3, testMemberCommand(
        "member-request-b",
        &test_member_id_b,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_002,
    ));
    defer member_b.deinit(allocator);
    const member_a_command = testMemberCommand(
        "member-request-a",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        1,
        1_753_744_000_003,
    );
    var member_a = try applyTestMemberCommand(allocator, &machine, 4, member_a_command);
    defer member_a.deinit(allocator);

    var first = try machine.stateMachine().takeSnapshot(allocator, 4, 1, .{});
    defer first.deinit(allocator);
    var second = try machine.stateMachine().takeSnapshot(allocator, 4, 1, .{});
    defer second.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.data, second.data);
    var snapshot_reader: std.Io.Reader = .fixed(first.data);
    var decoded = try pb.StateSnapshot.decode(&snapshot_reader, allocator);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(snapshot_format_version, decoded.format_version);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, decoded.members.items[0].id);
    try std.testing.expectEqualSlices(u8, &test_member_id_b, decoded.members.items[1].id);

    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var reader = TestSnapshotReader{ .data = first.data };
    try restored.stateMachine().restoreSnapshot(first.metadata, reader.reader());
    try std.testing.expectEqual(@as(usize, 1), restored.poolCount());
    try std.testing.expectEqual(@as(usize, 1), restored.nodeCount());
    try std.testing.expectEqual(@as(usize, 2), restored.memberCount());
    var page = try restored.listMembersPage(allocator, null, 10);
    defer page.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &test_member_id_b, page.members[0].id);
    try std.testing.expectEqualSlices(u8, &test_member_id_a, page.members[1].id);

    var retry_command = member_a_command;
    retry_command.proposed_registered_at_unix_ms += 999;
    var replay = try applyTestMemberCommand(allocator, &restored, 5, retry_command);
    defer replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, member_a.response.?, replay.response.?);
    var normalized = try restored.stateMachine().takeSnapshot(allocator, 4, 1, .{});
    defer normalized.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.data, normalized.data);
}

test "version 3 pool and node snapshot wire restores without members" {
    const allocator = std.testing.allocator;
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    try addTestPoolAndNode(allocator, &source);
    var current = try source.stateMachine().takeSnapshot(allocator, 2, 1, .{});
    defer current.deinit(allocator);
    var current_reader: std.Io.Reader = .fixed(current.data);
    var decoded = try pb.StateSnapshot.decode(&current_reader, allocator);
    defer decoded.deinit(allocator);
    decoded.format_version = 3;
    const version_3_wire = try encodeMessage(allocator, decoded);
    defer allocator.free(version_3_wire);

    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var reader = TestSnapshotReader{ .data = version_3_wire };
    try restored.stateMachine().restoreSnapshot(current.metadata, reader.reader());
    try std.testing.expectEqual(@as(usize, 1), restored.poolCount());
    try std.testing.expectEqual(@as(usize, 1), restored.nodeCount());
    try std.testing.expectEqual(@as(usize, 0), restored.memberCount());
}

test "register node replays matching requests and rejects semantic conflicts" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();

    const command = testNodeCommand(
        "node-request-1",
        "0198f54d-5c2a-7000-8000-000000000011",
        "127.0.0.1:9000",
        1_753_744_000_000,
    );
    var first = try applyTestNodeCommand(allocator, &machine, 7, command);
    defer first.deinit(allocator);
    var registered = try decodeRegisterNodeApplyResponse(allocator, first.response.?);
    defer registered.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterNodeApplyCode.REGISTER_NODE_APPLY_CODE_REGISTERED, registered.code);
    try std.testing.expectEqual(@as(u64, 7), registered.node.?.registered_revision);

    var retry_command = command;
    retry_command.proposed_registered_at_unix_ms += 999;
    var replay = try applyTestNodeCommand(allocator, &machine, 8, retry_command);
    defer replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.response.?, replay.response.?);

    var conflict_command = retry_command;
    conflict_command.protocol_version = 2;
    var conflict = try applyTestNodeCommand(allocator, &machine, 9, conflict_command);
    defer conflict.deinit(allocator);
    var conflict_response = try decodeRegisterNodeApplyResponse(allocator, conflict.response.?);
    defer conflict_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterNodeApplyCode.REGISTER_NODE_APPLY_CODE_REQUEST_CONFLICT, conflict_response.code);
    try std.testing.expectEqual(@as(usize, 1), machine.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), machine.requestCount());
}

test "request ids conflict across pool and node command kinds" {
    const allocator = std.testing.allocator;
    var pool_first = PoolStateMachine.init(allocator);
    defer pool_first.deinit();
    var pool_result = try applyTestCommand(allocator, &pool_first, 1, testCommand(
        "shared-request",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "",
        1_753_744_000_000,
    ));
    defer pool_result.deinit(allocator);
    var node_conflict = try applyTestNodeCommand(allocator, &pool_first, 2, testNodeCommand(
        "shared-request",
        "0198f54d-5c2a-7000-8000-000000000011",
        "127.0.0.1:9000",
        1_753_744_000_001,
    ));
    defer node_conflict.deinit(allocator);
    var node_response = try decodeRegisterNodeApplyResponse(allocator, node_conflict.response.?);
    defer node_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterNodeApplyCode.REGISTER_NODE_APPLY_CODE_REQUEST_CONFLICT, node_response.code);

    var node_first = PoolStateMachine.init(allocator);
    defer node_first.deinit();
    var node_result = try applyTestNodeCommand(allocator, &node_first, 1, testNodeCommand(
        "shared-request",
        "0198f54d-5c2a-7000-8000-000000000011",
        "127.0.0.1:9000",
        1_753_744_000_001,
    ));
    defer node_result.deinit(allocator);
    var pool_conflict = try applyTestCommand(allocator, &node_first, 2, testCommand(
        "shared-request",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "",
        1_753_744_000_000,
    ));
    defer pool_conflict.deinit(allocator);
    var pool_response = try decodeApplyResponse(allocator, pool_conflict.response.?);
    defer pool_response.deinit(allocator);
    try std.testing.expectEqual(pb.ApplyCode.APPLY_CODE_REQUEST_CONFLICT, pool_response.code);
}

test "node id exists response is durable" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    const node_id = "0198f54d-5c2a-7000-8000-000000000011";
    var registered = try applyTestNodeCommand(allocator, &machine, 1, testNodeCommand(
        "node-request-1",
        node_id,
        "127.0.0.1:9000",
        1_753_744_000_000,
    ));
    defer registered.deinit(allocator);
    const duplicate_command = testNodeCommand(
        "node-request-2",
        node_id,
        "127.0.0.2:9000",
        1_753_744_000_001,
    );
    var duplicate = try applyTestNodeCommand(allocator, &machine, 2, duplicate_command);
    defer duplicate.deinit(allocator);
    var duplicate_response = try decodeRegisterNodeApplyResponse(allocator, duplicate.response.?);
    defer duplicate_response.deinit(allocator);
    try std.testing.expectEqual(pb.RegisterNodeApplyCode.REGISTER_NODE_APPLY_CODE_ID_EXISTS, duplicate_response.code);
    try std.testing.expectEqualStrings("127.0.0.1:9000", duplicate_response.node.?.control_endpoint);

    var snapshot = try machine.stateMachine().takeSnapshot(allocator, 2, 1, .{});
    defer snapshot.deinit(allocator);
    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var reader = TestSnapshotReader{ .data = snapshot.data };
    try restored.stateMachine().restoreSnapshot(snapshot.metadata, reader.reader());
    var retry_command = duplicate_command;
    retry_command.proposed_registered_at_unix_ms += 999;
    var replay = try applyTestNodeCommand(allocator, &restored, 3, retry_command);
    defer replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, duplicate.response.?, replay.response.?);
}

test "get and list nodes use registration revision order" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    const first_id = "0198f54d-5c2a-7000-8000-000000000022";
    const second_id = "0198f54d-5c2a-7000-8000-000000000011";
    var first = try applyTestNodeCommand(allocator, &machine, 2, testNodeCommand("node-request-1", first_id, "node-a:9000", 1_753_744_000_000));
    defer first.deinit(allocator);
    var second = try applyTestNodeCommand(allocator, &machine, 4, testNodeCommand("node-request-2", second_id, "node-b:9000", 1_753_744_000_001));
    defer second.deinit(allocator);

    var fetched = (try machine.getNodeById(allocator, second_id)).?;
    defer fetched.deinit(allocator);
    try std.testing.expectEqualStrings("node-b:9000", fetched.control_endpoint);

    var first_page = try machine.listNodesPage(allocator, null, 1);
    defer first_page.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), first_page.nodes.len);
    try std.testing.expectEqualStrings(first_id, first_page.nodes[0].id);
    try std.testing.expect(first_page.has_more);
    var second_page = try machine.listNodesPage(allocator, first_id, 10);
    defer second_page.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), second_page.nodes.len);
    try std.testing.expectEqualStrings(second_id, second_page.nodes[0].id);
    try std.testing.expect(!second_page.has_more);
    try std.testing.expectError(error.InvalidPageToken, machine.listNodesPage(allocator, "missing", 1));
}

test "mixed snapshots are deterministic and restore pool and node history" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    var pool = try applyTestCommand(allocator, &machine, 1, testCommand(
        "pool-request",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "",
        1_753_744_000_000,
    ));
    defer pool.deinit(allocator);
    var node_b = try applyTestNodeCommand(allocator, &machine, 2, testNodeCommand(
        "node-request-b",
        "0198f54d-5c2a-7000-8000-000000000022",
        "node-b:9000",
        1_753_744_000_001,
    ));
    defer node_b.deinit(allocator);
    var node_a = try applyTestNodeCommand(allocator, &machine, 3, testNodeCommand(
        "node-request-a",
        "0198f54d-5c2a-7000-8000-000000000011",
        "node-a:9000",
        1_753_744_000_002,
    ));
    defer node_a.deinit(allocator);

    var first = try machine.stateMachine().takeSnapshot(allocator, 3, 1, .{});
    defer first.deinit(allocator);
    var second = try machine.stateMachine().takeSnapshot(allocator, 3, 1, .{});
    defer second.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.data, second.data);
    var snapshot_reader: std.Io.Reader = .fixed(first.data);
    var decoded = try pb.StateSnapshot.decode(&snapshot_reader, allocator);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(snapshot_format_version, decoded.format_version);
    try std.testing.expectEqualStrings("0198f54d-5c2a-7000-8000-000000000011", decoded.nodes.items[0].id);

    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var reader = TestSnapshotReader{ .data = first.data };
    try restored.stateMachine().restoreSnapshot(first.metadata, reader.reader());
    try std.testing.expectEqual(@as(usize, 1), restored.poolCount());
    try std.testing.expectEqual(@as(usize, 2), restored.nodeCount());
    var page = try restored.listNodesPage(allocator, null, 10);
    defer page.deinit(allocator);
    try std.testing.expectEqualStrings("0198f54d-5c2a-7000-8000-000000000022", page.nodes[0].id);
    var normalized = try restored.stateMachine().takeSnapshot(allocator, 3, 1, .{});
    defer normalized.deinit(allocator);
    try std.testing.expectEqualSlices(u8, first.data, normalized.data);
}

test "version 2 pool-only snapshot wire restores" {
    const allocator = std.testing.allocator;
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    const command = testCommand(
        "pool-request",
        "0198f54d-5c2a-7000-8000-000000000001",
        "primary",
        "",
        1_753_744_000_000,
    );
    var created = try applyTestCommand(allocator, &source, 1, command);
    defer created.deinit(allocator);
    var current = try source.stateMachine().takeSnapshot(allocator, 1, 1, .{});
    defer current.deinit(allocator);
    var current_reader: std.Io.Reader = .fixed(current.data);
    var decoded = try pb.StateSnapshot.decode(&current_reader, allocator);
    defer decoded.deinit(allocator);
    decoded.format_version = 2;
    const version_2_wire = try encodeMessage(allocator, decoded);
    defer allocator.free(version_2_wire);

    var restored = PoolStateMachine.init(allocator);
    defer restored.deinit();
    var reader = TestSnapshotReader{ .data = version_2_wire };
    try restored.stateMachine().restoreSnapshot(current.metadata, reader.reader());
    try std.testing.expectEqual(@as(usize, 1), restored.poolCount());
    try std.testing.expectEqual(@as(usize, 0), restored.nodeCount());
    var replay = try applyTestCommand(allocator, &restored, 2, command);
    defer replay.deinit(allocator);
    try std.testing.expectEqualSlices(u8, created.response.?, replay.response.?);
}

test "corrupt node snapshot is rejected atomically" {
    const allocator = std.testing.allocator;
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    var registered = try applyTestNodeCommand(allocator, &source, 2, testNodeCommand(
        "source-request",
        "0198f54d-5c2a-7000-8000-000000000022",
        "source:9000",
        1_753_744_000_000,
    ));
    defer registered.deinit(allocator);
    var snapshot = try source.stateMachine().takeSnapshot(allocator, 2, 1, .{});
    defer snapshot.deinit(allocator);
    var snapshot_reader: std.Io.Reader = .fixed(snapshot.data);
    var decoded = try pb.StateSnapshot.decode(&snapshot_reader, allocator);
    defer decoded.deinit(allocator);
    decoded.nodes.items[0].registered_revision = 3;
    const corrupt = try encodeMessage(allocator, decoded);
    defer allocator.free(corrupt);

    var target = PoolStateMachine.init(allocator);
    defer target.deinit();
    const existing_id = "0198f54d-5c2a-7000-8000-000000000011";
    var existing = try applyTestNodeCommand(allocator, &target, 1, testNodeCommand(
        "target-request",
        existing_id,
        "target:9000",
        1_753_744_000_001,
    ));
    defer existing.deinit(allocator);
    var reader = TestSnapshotReader{ .data = corrupt };
    try std.testing.expectError(error.PayloadParseFailed, target.stateMachine().restoreSnapshot(snapshot.metadata, reader.reader()));
    try std.testing.expectEqual(@as(usize, 1), target.nodeCount());
    var stored = (try target.getNodeById(allocator, existing_id)).?;
    defer stored.deinit(allocator);
    try std.testing.expectEqualStrings("target:9000", stored.control_endpoint);
}

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
    const noncanonical_response = try overlongFirstVarint(allocator, decoded_snapshot.requests.items[0].encoded_response);
    allocator.free(decoded_snapshot.requests.items[0].encoded_response);
    decoded_snapshot.requests.items[0].encoded_response = noncanonical_response;
    const noncanonical_command = try overlongFirstVarint(allocator, decoded_snapshot.requests.items[0].encoded_command);
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

    const malformed = [_]u8{0x12} ++ @as([9]u8, @splat(0xff)) ++ [_]u8{0x01};
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
        .command = .{ .create_pool = invalid_name },
    });
    defer allocator.free(encoded);
    try std.testing.expectError(
        error.PayloadParseFailed,
        machine.stateMachine().apply(.{ .index = 2, .term = 1, .data = encoded }),
    );
    try std.testing.expectEqual(@as(usize, 0), machine.poolCount());
}

const VolumeApplyAllocationCheck = struct {
    fn run(allocator: std.mem.Allocator, pool_command: []const u8, create_command: []const u8, delete_command: []const u8) !void {
        var machine = PoolStateMachine.init(allocator);
        defer machine.deinit();
        var pool = machine.stateMachine().apply(.{ .index = 1, .term = 1, .data = pool_command }) catch |err| {
            try std.testing.expectEqual(@as(usize, 0), machine.poolCount());
            try std.testing.expectEqual(@as(usize, 0), machine.requestCount());
            return err;
        };
        defer pool.deinit(allocator);
        var created = machine.stateMachine().apply(.{ .index = 2, .term = 1, .data = create_command }) catch |err| {
            try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
            try std.testing.expectEqual(@as(usize, 0), machine.volumeCount());
            try std.testing.expectEqual(@as(usize, 0), machine.volumeTombstoneCount());
            try std.testing.expectEqual(@as(usize, 1), machine.requestCount());
            try std.testing.expectEqual(@as(usize, 0), machine.state.volume_ids_by_scoped_name.count());
            try std.testing.expectEqual(@as(usize, 0), machine.state.volume_ids_by_revision.items.len);
            return err;
        };
        defer created.deinit(allocator);
        var deleted = machine.stateMachine().apply(.{ .index = 3, .term = 1, .data = delete_command }) catch |err| {
            try std.testing.expectEqual(@as(usize, 1), machine.volumeCount());
            try std.testing.expectEqual(@as(usize, 0), machine.volumeTombstoneCount());
            try std.testing.expectEqual(@as(usize, 2), machine.requestCount());
            try std.testing.expectEqual(@as(usize, 1), machine.state.volume_ids_by_scoped_name.count());
            try std.testing.expectEqual(@as(usize, 1), machine.state.volume_ids_by_revision.items.len);
            return err;
        };
        defer deleted.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), machine.volumeCount());
        try std.testing.expectEqual(@as(usize, 1), machine.volumeTombstoneCount());
        try std.testing.expectEqual(@as(usize, 3), machine.requestCount());
        try std.testing.expectEqual(@as(usize, 0), machine.state.volume_ids_by_scoped_name.count());
        try std.testing.expectEqual(@as(usize, 0), machine.state.volume_ids_by_revision.items.len);
    }
};

test "volume create and delete are atomic across allocation failures" {
    const allocator = std.testing.allocator;
    const pool_command = try encodeCreatePoolCommand(allocator, testCommand("pool-request", test_pool_id, "primary", "", 1_753_744_000_000));
    defer allocator.free(pool_command);
    const create_command = try encodeCreateVolumeCommand(allocator, testVolumeCommand("volume-request", test_volume_id, "database", "", min_volume_size_bytes, 1_753_744_000_001));
    defer allocator.free(create_command);
    const delete_command = try encodeDeleteVolumeCommand(allocator, testDeleteVolumeCommand("delete-request", test_volume_id, 2, 1_753_744_000_002));
    defer allocator.free(delete_command);
    try checkAllAllocationFailures(VolumeApplyAllocationCheck.run, .{ pool_command, create_command, delete_command });
}

const FailoverDeleteAllocationCheck = struct {
    fn run(fail_index: usize, begin_command: []const u8, delete_command: []const u8) !bool {
        var allocation: NoResizeAllocator = .{ .backing = std.testing.allocator };
        const allocator = allocation.allocator();
        var machine = PoolStateMachine.init(allocator);
        defer machine.deinit();
        try prepareReadyAuthority(allocator, &machine);
        var begun = try applyEncodedTestCommand(allocator, &machine, 16, begin_command);
        begun.deinit(allocator);
        const request_count = machine.requestCount();
        allocation.fail_index = fail_index;
        allocation.allocation_index = 0;
        var deleted = machine.stateMachine().apply(.{ .index = 17, .term = 1, .data = delete_command }) catch |err| {
            if (err != error.OutOfMemory) return err;
            const volume = machine.state.volumes_by_id.get(test_volume_id).?;
            try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_ACTIVE, volume.lifecycle_state);
            try std.testing.expectEqual(@as(u64, 16), volume.resource_version);
            try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCount());
            try std.testing.expectEqual(@as(usize, 1), machine.primaryFailoverCount());
            try std.testing.expectEqual(request_count, machine.requestCount());
            return false;
        };
        defer deleted.deinit(allocator);
        const volume = machine.state.volumes_by_id.get(test_volume_id).?;
        try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_DELETING, volume.lifecycle_state);
        try std.testing.expectEqual(@as(usize, 1), machine.primaryAuthorityCount());
        try std.testing.expectEqual(@as(usize, 0), machine.primaryFailoverCount());
        try std.testing.expectEqual(request_count + 1, machine.requestCount());
        return true;
    }
};

test "failover deletion cleanup is atomic across allocation failures" {
    const allocator = std.testing.allocator;
    const begin_command = try encodeBeginPrimaryFailoverCommand(allocator, .{
        .volume_id = test_volume_id,
        .current_lease_id = &test_lease_id,
        .current_authority_generation = 1,
        .current_write_epoch = 1,
        .failover_id = &test_failover_id,
        .expected_volume_resource_version = 15,
        .expected_current_resource_version = 15,
    });
    defer allocator.free(begin_command);
    const delete_command = try encodeDeleteVolumeCommand(allocator, .{
        .request_id = "delete-failover-allocation-check",
        .volume_id = test_volume_id,
        .expected_resource_version = 16,
        .proposed_deleted_at_unix_ms = 1_753_744_000_020,
    });
    defer allocator.free(delete_command);
    var fail_index: usize = 0;
    while (!try FailoverDeleteAllocationCheck.run(fail_index, begin_command, delete_command)) fail_index += 1;
}

const ActivateReplicaAllocationCheck = struct {
    fn run(allocator: std.mem.Allocator, activation_command: []const u8) !void {
        var machine = PoolStateMachine.init(allocator);
        defer machine.deinit();
        try addTestVolumeTopology(allocator, &machine);
        var created = try applyTestVolumeCommand(allocator, &machine, 8, testVolumeCommand(
            "activation-volume",
            test_volume_id,
            "activation",
            "",
            min_volume_size_bytes,
            1_753_744_000_010,
        ));
        defer created.deinit(allocator);
        var reservations = testReservations(min_volume_size_bytes);
        const reserve_command = try encodeReserveVolumeResourcesCommand(allocator, .{
            .volume_id = test_volume_id,
            .expected_resource_version = 8,
            .reservations = .{ .items = &reservations, .capacity = reservations.len },
        });
        defer allocator.free(reserve_command);
        var reserved = try applyEncodedTestCommand(allocator, &machine, 9, reserve_command);
        defer reserved.deinit(allocator);

        var activated = machine.stateMachine().apply(.{ .index = 10, .term = 1, .data = activation_command }) catch |err| {
            const volume = machine.state.volumes_by_id.get(test_volume_id).?;
            const placement = machine.state.replica_placements_by_id.get(test_replica_id).?;
            const allocation = machine.state.replica_allocations_by_id.get(test_allocation_id).?;
            try std.testing.expectEqual(@as(u64, 9), volume.resource_version);
            try std.testing.expectEqual(pb.VolumeLifecycleState.VOLUME_LIFECYCLE_STATE_PROVISIONING, volume.lifecycle_state);
            try std.testing.expectEqual(pb.ReplicaPlacementState.REPLICA_PLACEMENT_STATE_RESERVED, placement.state);
            try std.testing.expectEqual(@as(u64, 9), placement.resource_version);
            try std.testing.expectEqual(pb.ReplicaAllocationState.REPLICA_ALLOCATION_STATE_RESERVED, allocation.state);
            try std.testing.expectEqual(@as(u64, 9), allocation.resource_version);
            return err;
        };
        defer activated.deinit(allocator);
        const volume = machine.state.volumes_by_id.get(test_volume_id).?;
        const placement = machine.state.replica_placements_by_id.get(test_replica_id).?;
        const allocation = machine.state.replica_allocations_by_id.get(test_allocation_id).?;
        try std.testing.expectEqual(@as(u64, 10), volume.resource_version);
        try std.testing.expectEqual(pb.ReplicaPlacementState.REPLICA_PLACEMENT_STATE_ACTIVE, placement.state);
        try std.testing.expectEqual(pb.ReplicaAllocationState.REPLICA_ALLOCATION_STATE_ACTIVE, allocation.state);
    }
};

test "replica activation is atomic across allocation failures" {
    const activation_command = try encodeActivateReplicaCommand(std.testing.allocator, .{
        .volume_id = test_volume_id,
        .placement_id = test_replica_id,
        .allocation_id = test_allocation_id,
        .expected_volume_resource_version = 9,
        .expected_placement_resource_version = 9,
        .expected_allocation_resource_version = 9,
        .attestation = testReplicaAttestation(test_replica_id, test_allocation_id, &test_member_id_a, min_volume_size_bytes),
    });
    defer std.testing.allocator.free(activation_command);
    try checkAllAllocationFailures(ActivateReplicaAllocationCheck.run, .{activation_command});
}

test "version 3 activation replays fail closed without attestation" {
    const allocator = std.testing.allocator;
    var machine = PoolStateMachine.init(allocator);
    defer machine.deinit();
    try addTestVolumeTopology(allocator, &machine);
    var created = try applyTestVolumeCommand(allocator, &machine, 8, testVolumeCommand(
        "legacy-activation-volume",
        test_volume_id,
        "legacy-activation",
        "",
        min_volume_size_bytes,
        1_753_744_000_010,
    ));
    defer created.deinit(allocator);
    var reservations = testReservations(min_volume_size_bytes);
    const reserve_command = try encodeReserveVolumeResourcesCommand(allocator, .{
        .volume_id = test_volume_id,
        .expected_resource_version = 8,
        .reservations = .{ .items = &reservations, .capacity = reservations.len },
    });
    defer allocator.free(reserve_command);
    var reserved = try applyEncodedTestCommand(allocator, &machine, 9, reserve_command);
    defer reserved.deinit(allocator);

    const legacy = try encodeMessage(allocator, pb.CommandEnvelope{
        .format_version = 3,
        .command = .{ .activate_replica = .{
            .volume_id = test_volume_id,
            .placement_id = test_replica_id,
            .allocation_id = test_allocation_id,
            .expected_volume_resource_version = 9,
            .expected_placement_resource_version = 9,
            .expected_allocation_resource_version = 9,
        } },
    });
    defer allocator.free(legacy);
    var replayed = try applyEncodedTestCommand(allocator, &machine, 10, legacy);
    defer replayed.deinit(allocator);
    var response = try decodeActivateReplicaApplyResponse(allocator, replayed.response.?);
    defer response.deinit(allocator);
    try std.testing.expectEqual(pb.ActivateReplicaApplyCode.ACTIVATE_REPLICA_APPLY_CODE_INVALID_STATE, response.code);
    try std.testing.expectEqual(pb.ReplicaPlacementState.REPLICA_PLACEMENT_STATE_RESERVED, machine.state.replica_placements_by_id.get(test_replica_id).?.state);
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
    try checkAllAllocationFailures(ApplyAllocationCheck.run, .{encoded});
}

const MemberApplyAllocationCheck = struct {
    fn run(
        allocator: std.mem.Allocator,
        pool_command: []const u8,
        node_command: []const u8,
        member_command: []const u8,
    ) !void {
        var machine = PoolStateMachine.init(allocator);
        defer machine.deinit();
        var pool = try machine.stateMachine().apply(.{ .index = 1, .term = 1, .data = pool_command });
        defer pool.deinit(allocator);
        var node = try machine.stateMachine().apply(.{ .index = 2, .term = 1, .data = node_command });
        defer node.deinit(allocator);

        var member = machine.stateMachine().apply(.{ .index = 3, .term = 1, .data = member_command }) catch |err| {
            try std.testing.expectEqual(@as(usize, 0), machine.memberCount());
            try std.testing.expectEqual(@as(usize, 0), machine.state.member_ids_by_revision.items.len);
            try std.testing.expectEqual(@as(usize, 0), machine.state.pool_ids_by_local_set.count());
            try std.testing.expectEqual(@as(usize, 0), machine.state.member_ids_by_slot.count());
            try std.testing.expectEqual(@as(u64, 0), machine.state.max_member_registered_revision);
            try std.testing.expectEqual(@as(usize, 2), machine.requestCount());
            return err;
        };
        defer member.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), machine.memberCount());
        try std.testing.expectEqual(@as(usize, 1), machine.state.member_ids_by_revision.items.len);
        try std.testing.expectEqual(@as(usize, 1), machine.state.pool_ids_by_local_set.count());
        try std.testing.expectEqual(@as(usize, 1), machine.state.member_ids_by_slot.count());
        try std.testing.expectEqual(@as(u64, 3), machine.state.max_member_registered_revision);
        try std.testing.expectEqual(@as(usize, 3), machine.requestCount());
        try std.testing.expect(machine.state.members_by_id.contains(&test_member_id_a));
        try std.testing.expectEqualStrings(test_pool_id, machine.state.pool_ids_by_local_set.get(&test_local_set_id).?);
        const member_id = machine.state.member_ids_by_slot.get(memberSlotKey(&test_local_set_id, 0)).?;
        try std.testing.expectEqualSlices(u8, &test_member_id_a, member_id);
    }
};

const NoResizeAllocator = struct {
    backing: std.mem.Allocator,
    fail_index: ?usize = null,
    allocation_index: usize = 0,

    fn allocator(self: *NoResizeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *NoResizeAllocator = @ptrCast(@alignCast(context));
        if (self.fail_index) |fail_index| {
            defer self.allocation_index += 1;
            if (self.allocation_index == fail_index) return null;
        }
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *NoResizeAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

fn checkAllAllocationFailures(comptime test_fn: anytype, extra_args: anytype) !void {
    var no_resize_allocator: NoResizeAllocator = .{ .backing = std.testing.allocator };
    return std.testing.checkAllAllocationFailures(no_resize_allocator.allocator(), test_fn, extra_args);
}

test "member registration is atomic across allocation failures" {
    const allocator = std.testing.allocator;
    const pool_command = try encodeCreatePoolCommand(allocator, testCommand(
        "member-pool-request",
        test_pool_id,
        "member-pool",
        "",
        1_753_744_000_000,
    ));
    defer allocator.free(pool_command);
    const node_command = try encodeRegisterNodeCommand(allocator, testNodeCommand(
        "member-node-request",
        test_node_id,
        "node-a:9000",
        1_753_744_000_001,
    ));
    defer allocator.free(node_command);
    const member_command = try encodeRegisterMemberCommand(allocator, testMemberCommand(
        "member-request",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_002,
    ));
    defer allocator.free(member_command);
    try checkAllAllocationFailures(
        MemberApplyAllocationCheck.run,
        .{ pool_command, node_command, member_command },
    );
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
    try checkAllAllocationFailures(
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
    try checkAllAllocationFailures(
        RestoreAllocationCheck.run,
        .{ existing_command, snapshot.data, snapshot.metadata },
    );
}

const MemberRestoreAllocationCheck = struct {
    fn run(allocator: std.mem.Allocator, existing_command: []const u8, snapshot_data: []const u8, metadata: raft.SnapshotMetadata) !void {
        var machine = PoolStateMachine.init(allocator);
        defer machine.deinit();
        var applied = try machine.stateMachine().apply(.{ .index = 1, .term = 1, .data = existing_command });
        defer applied.deinit(allocator);

        var reader = TestSnapshotReader{ .data = snapshot_data };
        machine.stateMachine().restoreSnapshot(metadata, reader.reader()) catch |err| {
            try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
            try std.testing.expectEqual(@as(usize, 0), machine.nodeCount());
            try std.testing.expectEqual(@as(usize, 0), machine.memberCount());
            try std.testing.expectEqual(@as(usize, 1), machine.requestCount());
            try std.testing.expect(machine.state.pools_by_id.contains("0198f54d-5c2a-7000-8000-000000000003"));
            try std.testing.expectEqual(@as(usize, 0), machine.state.member_ids_by_revision.items.len);
            try std.testing.expectEqual(@as(usize, 0), machine.state.pool_ids_by_local_set.count());
            try std.testing.expectEqual(@as(usize, 0), machine.state.member_ids_by_slot.count());
            return err;
        };
        try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
        try std.testing.expectEqual(@as(usize, 1), machine.nodeCount());
        try std.testing.expectEqual(@as(usize, 1), machine.memberCount());
        try std.testing.expectEqual(@as(usize, 3), machine.requestCount());
        try std.testing.expect(!machine.state.pools_by_id.contains("0198f54d-5c2a-7000-8000-000000000003"));
        try std.testing.expect(machine.state.pools_by_id.contains(test_pool_id));
        try std.testing.expect(machine.state.nodes_by_id.contains(test_node_id));
        try std.testing.expect(machine.state.members_by_id.contains(&test_member_id_a));
        try std.testing.expectEqual(@as(usize, 1), machine.state.member_ids_by_revision.items.len);
        try std.testing.expectEqual(@as(usize, 1), machine.state.pool_ids_by_local_set.count());
        try std.testing.expectEqual(@as(usize, 1), machine.state.member_ids_by_slot.count());
    }
};

test "version 4 member snapshot restore is atomic across allocation failures" {
    const allocator = std.testing.allocator;
    var source = PoolStateMachine.init(allocator);
    defer source.deinit();
    try addTestPoolAndNode(allocator, &source);
    var member = try applyTestMemberCommand(allocator, &source, 3, testMemberCommand(
        "member-request",
        &test_member_id_a,
        test_pool_id,
        test_node_id,
        &test_local_set_id,
        0,
        1_753_744_000_002,
    ));
    defer member.deinit(allocator);
    var snapshot = try source.stateMachine().takeSnapshot(allocator, 3, 1, .{});
    defer snapshot.deinit(allocator);

    const existing_command = try encodeCreatePoolCommand(allocator, testCommand(
        "existing-request",
        "0198f54d-5c2a-7000-8000-000000000003",
        "existing",
        "",
        1_753_744_000_003,
    ));
    defer allocator.free(existing_command);
    try checkAllAllocationFailures(
        MemberRestoreAllocationCheck.run,
        .{ existing_command, snapshot.data, snapshot.metadata },
    );
}
