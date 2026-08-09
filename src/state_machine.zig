const std = @import("std");

const pb = @import("control_proto");
const heartbeat = @import("heartbeat.zig");
const raft = @import("raftz");
const uuid = @import("uuid");
const wire = @import("protobuf_wire.zig");

pub const command_format_version: u32 = 2;
pub const snapshot_format_version: u32 = 5;
pub const max_name_bytes: usize = 127;
pub const max_description_bytes: usize = 1024;
pub const max_request_id_bytes: usize = 127;
pub const max_node_endpoint_bytes: usize = 1024;
pub const max_failure_domain_bytes: usize = 255;
pub const max_pools: usize = 25_000;
pub const max_nodes: usize = 10_000;
pub const max_members: usize = 10_000;
pub const min_volume_size_bytes: u64 = 256 * 1024;
pub const volume_block_size_bytes: u64 = 4096;
pub const max_volume_size_bytes: u64 = @as(u64, std.math.maxInt(u32)) * volume_block_size_bytes;
pub const volume_target_replica_count: u32 = 3;
pub const volume_write_quorum: u32 = 2;
pub const volume_read_quorum: u32 = 1;
pub const max_volumes: usize = 25_000;
pub const max_volume_tombstones: usize = 25_000;
pub const max_replica_placements: usize = max_volumes * @as(usize, volume_target_replica_count);
pub const max_replica_allocations: usize = max_replica_placements;
pub const max_volume_attachments: usize = max_volumes;
pub const max_consumer_id_bytes: usize = 255;
pub const max_requests: usize = 50_000;
pub const max_snapshot_bytes: usize = 256 * 1024 * 1024;

const max_pool_wire_bytes: usize = 2048;
const max_node_wire_bytes: usize = 4096;
const max_member_wire_bytes: usize = 4096;
const max_volume_wire_bytes: usize = 4096;
const max_volume_tombstone_wire_bytes: usize = 8192;
const max_replica_placement_wire_bytes: usize = 2048;
const max_replica_allocation_wire_bytes: usize = 2048;
const max_volume_attachment_wire_bytes: usize = 4096;
const max_command_wire_bytes: usize = 8192;
const max_response_wire_bytes: usize = 8192;
const max_request_wire_bytes: usize = max_request_id_bytes + @sizeOf(Fingerprint) + max_response_wire_bytes + max_command_wire_bytes + 40;

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

const Node = struct {
    id: []u8,
    cluster_id: []u8,
    control_endpoint: []u8,
    nvmf_endpoint: []u8,
    failure_domain: []u8,
    capability_bits: u64,
    protocol_version: u32,
    registered_at_unix_ms: i64,
    registered_revision: u64,

    fn init(allocator: std.mem.Allocator, source: pb.Node) !Node {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const cluster_id = try allocator.dupe(u8, source.cluster_id);
        errdefer allocator.free(cluster_id);
        const control_endpoint = try allocator.dupe(u8, source.control_endpoint);
        errdefer allocator.free(control_endpoint);
        const nvmf_endpoint = try allocator.dupe(u8, source.nvmf_endpoint);
        errdefer allocator.free(nvmf_endpoint);
        const failure_domain = try allocator.dupe(u8, source.failure_domain);
        return .{
            .id = id,
            .cluster_id = cluster_id,
            .control_endpoint = control_endpoint,
            .nvmf_endpoint = nvmf_endpoint,
            .failure_domain = failure_domain,
            .capability_bits = source.capability_bits,
            .protocol_version = source.protocol_version,
            .registered_at_unix_ms = source.registered_at_unix_ms,
            .registered_revision = source.registered_revision,
        };
    }

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.cluster_id);
        allocator.free(self.control_endpoint);
        allocator.free(self.nvmf_endpoint);
        allocator.free(self.failure_domain);
        self.* = undefined;
    }

    fn proto(self: Node) pb.Node {
        return .{
            .id = self.id,
            .cluster_id = self.cluster_id,
            .control_endpoint = self.control_endpoint,
            .nvmf_endpoint = self.nvmf_endpoint,
            .failure_domain = self.failure_domain,
            .capability_bits = self.capability_bits,
            .protocol_version = self.protocol_version,
            .registered_at_unix_ms = self.registered_at_unix_ms,
            .registered_revision = self.registered_revision,
        };
    }
};

const Member = struct {
    id: []u8,
    pool_id: []u8,
    node_id: []u8,
    local_set_id: []u8,
    member_slot: u32,
    birth_topology_digest: []u8,
    metadata_capacity_bytes: u64,
    data_capacity_bytes: u64,
    extent_size_bytes: u32,
    registered_at_unix_ms: i64,
    registered_revision: u64,

    fn init(allocator: std.mem.Allocator, source: pb.Member) !Member {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const pool_id = try allocator.dupe(u8, source.pool_id);
        errdefer allocator.free(pool_id);
        const node_id = try allocator.dupe(u8, source.node_id);
        errdefer allocator.free(node_id);
        const local_set_id = try allocator.dupe(u8, source.local_set_id);
        errdefer allocator.free(local_set_id);
        const birth_topology_digest = try allocator.dupe(u8, source.birth_topology_digest);
        return .{
            .id = id,
            .pool_id = pool_id,
            .node_id = node_id,
            .local_set_id = local_set_id,
            .member_slot = source.member_slot,
            .birth_topology_digest = birth_topology_digest,
            .metadata_capacity_bytes = source.metadata_capacity_bytes,
            .data_capacity_bytes = source.data_capacity_bytes,
            .extent_size_bytes = source.extent_size_bytes,
            .registered_at_unix_ms = source.registered_at_unix_ms,
            .registered_revision = source.registered_revision,
        };
    }

    fn deinit(self: *Member, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.pool_id);
        allocator.free(self.node_id);
        allocator.free(self.local_set_id);
        allocator.free(self.birth_topology_digest);
        self.* = undefined;
    }

    fn proto(self: Member) pb.Member {
        return .{
            .id = self.id,
            .pool_id = self.pool_id,
            .node_id = self.node_id,
            .local_set_id = self.local_set_id,
            .member_slot = self.member_slot,
            .birth_topology_digest = self.birth_topology_digest,
            .metadata_capacity_bytes = self.metadata_capacity_bytes,
            .data_capacity_bytes = self.data_capacity_bytes,
            .extent_size_bytes = self.extent_size_bytes,
            .registered_at_unix_ms = self.registered_at_unix_ms,
            .registered_revision = self.registered_revision,
        };
    }
};

const MemberSlotKey = struct {
    local_set_id: [16]u8,
    member_slot: u16,
};

const Volume = struct {
    id: []u8,
    pool_id: []u8,
    name: []u8,
    scoped_name: []u8,
    description: []u8,
    size_bytes: u64,
    protection_kind: pb.VolumeProtectionKind,
    target_replica_count: u32,
    write_quorum: u32,
    read_quorum: u32,
    lifecycle_state: pb.VolumeLifecycleState,
    availability_state: pb.VolumeAvailabilityState,
    operation_phase: pb.VolumeOperationPhase,
    generation: u64,
    write_epoch: u64,
    placement_revision: u64,
    created_at_unix_ms: i64,
    created_revision: u64,
    resource_version: u64,

    fn init(allocator: std.mem.Allocator, source: pb.Volume) !Volume {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const pool_id = try allocator.dupe(u8, source.pool_id);
        errdefer allocator.free(pool_id);
        const name = try allocator.dupe(u8, source.name);
        errdefer allocator.free(name);
        const scoped_name = try makeScopedKey(allocator, source.pool_id, source.name);
        errdefer allocator.free(scoped_name);
        const description = try allocator.dupe(u8, source.description);
        return .{
            .id = id,
            .pool_id = pool_id,
            .name = name,
            .scoped_name = scoped_name,
            .description = description,
            .size_bytes = source.size_bytes,
            .protection_kind = source.protection_kind,
            .target_replica_count = source.target_replica_count,
            .write_quorum = source.write_quorum,
            .read_quorum = source.read_quorum,
            .lifecycle_state = source.lifecycle_state,
            .availability_state = source.availability_state,
            .operation_phase = source.operation_phase,
            .generation = source.generation,
            .write_epoch = source.write_epoch,
            .placement_revision = source.placement_revision,
            .created_at_unix_ms = source.created_at_unix_ms,
            .created_revision = source.created_revision,
            .resource_version = source.resource_version,
        };
    }

    fn deinit(self: *Volume, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.pool_id);
        allocator.free(self.name);
        allocator.free(self.scoped_name);
        allocator.free(self.description);
        self.* = undefined;
    }

    fn proto(self: Volume) pb.Volume {
        return .{
            .id = self.id,
            .pool_id = self.pool_id,
            .name = self.name,
            .description = self.description,
            .size_bytes = self.size_bytes,
            .protection_kind = self.protection_kind,
            .target_replica_count = self.target_replica_count,
            .write_quorum = self.write_quorum,
            .read_quorum = self.read_quorum,
            .lifecycle_state = self.lifecycle_state,
            .availability_state = self.availability_state,
            .operation_phase = self.operation_phase,
            .generation = self.generation,
            .write_epoch = self.write_epoch,
            .placement_revision = self.placement_revision,
            .created_at_unix_ms = self.created_at_unix_ms,
            .created_revision = self.created_revision,
            .resource_version = self.resource_version,
        };
    }
};

const VolumeTombstone = struct {
    volume: Volume,
    deleted_at_unix_ms: i64,
    deleted_revision: u64,

    fn deinit(self: *VolumeTombstone, allocator: std.mem.Allocator) void {
        self.volume.deinit(allocator);
        self.* = undefined;
    }

    fn proto(self: VolumeTombstone) pb.VolumeTombstone {
        return .{
            .volume = self.volume.proto(),
            .deleted_at_unix_ms = self.deleted_at_unix_ms,
            .deleted_revision = self.deleted_revision,
        };
    }
};

const ReplicaPlacement = struct {
    id: []u8,
    volume_id: []u8,
    node_id: []u8,
    replica_key: []u8,
    replica_index: u32,
    generation: u64,
    state: pb.ReplicaPlacementState,
    created_revision: u64,
    resource_version: u64,

    fn init(allocator: std.mem.Allocator, source: pb.ReplicaPlacement) !ReplicaPlacement {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const volume_id = try allocator.dupe(u8, source.volume_id);
        errdefer allocator.free(volume_id);
        const node_id = try allocator.dupe(u8, source.node_id);
        errdefer allocator.free(node_id);
        const replica_key = try makeReplicaKey(allocator, source.volume_id, source.replica_index);
        return .{
            .id = id,
            .volume_id = volume_id,
            .node_id = node_id,
            .replica_key = replica_key,
            .replica_index = source.replica_index,
            .generation = source.generation,
            .state = source.state,
            .created_revision = source.created_revision,
            .resource_version = source.resource_version,
        };
    }

    fn deinit(self: *ReplicaPlacement, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.volume_id);
        allocator.free(self.node_id);
        allocator.free(self.replica_key);
        self.* = undefined;
    }

    fn proto(self: ReplicaPlacement) pb.ReplicaPlacement {
        return .{ .id = self.id, .volume_id = self.volume_id, .node_id = self.node_id, .replica_index = self.replica_index, .generation = self.generation, .state = self.state, .created_revision = self.created_revision, .resource_version = self.resource_version };
    }
};

const ReplicaAllocation = struct {
    id: []u8,
    replica_id: []u8,
    member_id: []u8,
    offset_bytes: u64,
    length_bytes: u64,
    generation: u64,
    state: pb.ReplicaAllocationState,
    created_revision: u64,
    resource_version: u64,

    fn init(allocator: std.mem.Allocator, source: pb.ReplicaAllocation) !ReplicaAllocation {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const replica_id = try allocator.dupe(u8, source.replica_id);
        errdefer allocator.free(replica_id);
        const member_id = try allocator.dupe(u8, source.member_id);
        return .{ .id = id, .replica_id = replica_id, .member_id = member_id, .offset_bytes = source.offset_bytes, .length_bytes = source.length_bytes, .generation = source.generation, .state = source.state, .created_revision = source.created_revision, .resource_version = source.resource_version };
    }

    fn deinit(self: *ReplicaAllocation, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.replica_id);
        allocator.free(self.member_id);
        self.* = undefined;
    }

    fn proto(self: ReplicaAllocation) pb.ReplicaAllocation {
        return .{ .id = self.id, .replica_id = self.replica_id, .member_id = self.member_id, .offset_bytes = self.offset_bytes, .length_bytes = self.length_bytes, .generation = self.generation, .state = self.state, .created_revision = self.created_revision, .resource_version = self.resource_version };
    }
};

const VolumeAttachment = struct {
    id: []u8,
    volume_id: []u8,
    target_node_id: []u8,
    consumer_id: []u8,
    consumer_key: []u8,
    access_mode: pb.VolumeAccessMode,
    state: pb.VolumeAttachmentState,
    generation: u64,
    created_revision: u64,
    resource_version: u64,

    fn init(allocator: std.mem.Allocator, source: pb.VolumeAttachment) !VolumeAttachment {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const volume_id = try allocator.dupe(u8, source.volume_id);
        errdefer allocator.free(volume_id);
        const target_node_id = try allocator.dupe(u8, source.target_node_id);
        errdefer allocator.free(target_node_id);
        const consumer_id = try allocator.dupe(u8, source.consumer_id);
        errdefer allocator.free(consumer_id);
        const consumer_key = try makeScopedKey(allocator, source.volume_id, source.consumer_id);
        return .{ .id = id, .volume_id = volume_id, .target_node_id = target_node_id, .consumer_id = consumer_id, .consumer_key = consumer_key, .access_mode = source.access_mode, .state = source.state, .generation = source.generation, .created_revision = source.created_revision, .resource_version = source.resource_version };
    }

    fn deinit(self: *VolumeAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.volume_id);
        allocator.free(self.target_node_id);
        allocator.free(self.consumer_id);
        allocator.free(self.consumer_key);
        self.* = undefined;
    }

    fn proto(self: VolumeAttachment) pb.VolumeAttachment {
        return .{ .id = self.id, .volume_id = self.volume_id, .target_node_id = self.target_node_id, .consumer_id = self.consumer_id, .access_mode = self.access_mode, .state = self.state, .generation = self.generation, .created_revision = self.created_revision, .resource_version = self.resource_version };
    }
};

const RequestKind = enum {
    create_pool,
    register_node,
    register_member,
    create_volume,
    delete_volume,
};

const Request = struct {
    request_id: []u8,
    kind: RequestKind,
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
    nodes_by_id: std.StringHashMapUnmanaged(Node) = .empty,
    node_ids_by_revision: std.ArrayList([]const u8) = .empty,
    members_by_id: std.StringHashMapUnmanaged(Member) = .empty,
    member_ids_by_revision: std.ArrayList([]const u8) = .empty,
    pool_ids_by_local_set: std.StringHashMapUnmanaged([]const u8) = .empty,
    member_ids_by_slot: std.AutoHashMapUnmanaged(MemberSlotKey, []const u8) = .empty,
    volumes_by_id: std.StringHashMapUnmanaged(Volume) = .empty,
    volume_ids_by_scoped_name: std.StringHashMapUnmanaged([]const u8) = .empty,
    volume_ids_by_revision: std.ArrayList([]const u8) = .empty,
    volume_tombstones_by_id: std.StringHashMapUnmanaged(VolumeTombstone) = .empty,
    replica_placements_by_id: std.StringHashMapUnmanaged(ReplicaPlacement) = .empty,
    replica_ids_by_volume_index: std.StringHashMapUnmanaged([]const u8) = .empty,
    replica_allocations_by_id: std.StringHashMapUnmanaged(ReplicaAllocation) = .empty,
    volume_attachments_by_id: std.StringHashMapUnmanaged(VolumeAttachment) = .empty,
    attachment_ids_by_volume_consumer: std.StringHashMapUnmanaged([]const u8) = .empty,
    requests: std.StringHashMapUnmanaged(Request) = .empty,
    max_pool_created_revision: u64 = 0,
    max_node_registered_revision: u64 = 0,
    max_member_registered_revision: u64 = 0,
    max_volume_created_revision: u64 = 0,
    max_volume_deleted_revision: u64 = 0,

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var request_iterator = self.requests.valueIterator();
        while (request_iterator.next()) |request| request.deinit(allocator);
        self.requests.deinit(allocator);

        self.attachment_ids_by_volume_consumer.deinit(allocator);
        var attachment_iterator = self.volume_attachments_by_id.valueIterator();
        while (attachment_iterator.next()) |attachment| attachment.deinit(allocator);
        self.volume_attachments_by_id.deinit(allocator);

        var allocation_iterator = self.replica_allocations_by_id.valueIterator();
        while (allocation_iterator.next()) |allocation| allocation.deinit(allocator);
        self.replica_allocations_by_id.deinit(allocator);

        self.replica_ids_by_volume_index.deinit(allocator);
        var replica_iterator = self.replica_placements_by_id.valueIterator();
        while (replica_iterator.next()) |replica| replica.deinit(allocator);
        self.replica_placements_by_id.deinit(allocator);

        var tombstone_iterator = self.volume_tombstones_by_id.valueIterator();
        while (tombstone_iterator.next()) |tombstone| tombstone.deinit(allocator);
        self.volume_tombstones_by_id.deinit(allocator);

        self.volume_ids_by_revision.deinit(allocator);
        self.volume_ids_by_scoped_name.deinit(allocator);
        var volume_iterator = self.volumes_by_id.valueIterator();
        while (volume_iterator.next()) |volume| volume.deinit(allocator);
        self.volumes_by_id.deinit(allocator);

        self.member_ids_by_slot.deinit(allocator);
        self.pool_ids_by_local_set.deinit(allocator);
        self.member_ids_by_revision.deinit(allocator);
        var member_iterator = self.members_by_id.valueIterator();
        while (member_iterator.next()) |member| member.deinit(allocator);
        self.members_by_id.deinit(allocator);

        self.node_ids_by_revision.deinit(allocator);
        var node_iterator = self.nodes_by_id.valueIterator();
        while (node_iterator.next()) |node| node.deinit(allocator);
        self.nodes_by_id.deinit(allocator);

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
        if (envelope.format_version != 1 and envelope.format_version != command_format_version) return error.PayloadParseFailed;
        return switch (envelope.command orelse return error.PayloadParseFailed) {
            .create_pool => |command| self.applyCreatePool(entry.index, command),
            .register_node => |command| self.applyRegisterNode(entry.index, command),
            .register_member => |command| self.applyRegisterMember(entry.index, command),
            .create_volume => |command| if (envelope.format_version == command_format_version)
                self.applyCreateVolume(entry.index, command)
            else
                error.PayloadParseFailed,
            .delete_volume => |command| if (envelope.format_version == command_format_version)
                self.applyDeleteVolume(entry.index, command)
            else
                error.PayloadParseFailed,
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

        const node_proto: pb.Node = .{
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
        const encoded_response = try encodeRegisterNodeApplyResponse(self.allocator, .REGISTER_NODE_APPLY_CODE_REGISTERED, node_proto);
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeRegisterNodeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        var node = try Node.init(self.allocator, node_proto);
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

    fn applyDeleteVolume(self: *PoolStateMachine, revision: u64, command: pb.DeleteVolumeCommand) raft.Error!raft.ApplyResult {
        try validateDeleteVolumeCommand(command);
        if (revision == 0) return error.PayloadParseFailed;

        const fingerprint = deleteVolumeFingerprint(command);
        if (self.state.requests.get(command.request_id)) |request| {
            if (request.kind != .delete_volume or !std.mem.eql(u8, &fingerprint, &request.fingerprint)) {
                return .{ .response = try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_REQUEST_CONFLICT, "", 0, 0) };
            }
            return .{ .response = try self.allocator.dupe(u8, request.encoded_response) };
        }
        if (self.state.requests.count() >= max_requests) {
            return .{ .response = try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_REQUEST_LIMIT, "", 0, 0) };
        }
        const volume = self.state.volumes_by_id.get(command.volume_id) orelse {
            return self.recordDeleteVolumeResponse(command, fingerprint, try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_NOT_FOUND, "", 0, 0), revision);
        };
        if (volume.resource_version != command.expected_resource_version) {
            return self.recordDeleteVolumeResponse(command, fingerprint, try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_VERSION_CONFLICT, "", 0, 0), revision);
        }
        if (hasVolumeDependencies(&self.state, command.volume_id)) {
            return self.recordDeleteVolumeResponse(command, fingerprint, try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_HAS_DEPENDENCIES, "", 0, 0), revision);
        }
        if (self.state.volume_tombstones_by_id.count() >= max_volume_tombstones) {
            return self.recordDeleteVolumeResponse(command, fingerprint, try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_TOMBSTONE_LIMIT, "", 0, 0), revision);
        }

        const encoded_response = try encodeDeleteVolumeApplyResponse(self.allocator, .DELETE_VOLUME_APPLY_CODE_DELETED, command.volume_id, command.proposed_deleted_at_unix_ms, revision);
        errdefer self.allocator.free(encoded_response);
        const returned_response = try self.allocator.dupe(u8, encoded_response);
        errdefer self.allocator.free(returned_response);
        const encoded_command = try encodeDeleteVolumeCommand(self.allocator, command);
        errdefer self.allocator.free(encoded_command);
        const request_id = try self.allocator.dupe(u8, command.request_id);
        errdefer self.allocator.free(request_id);
        try self.state.volume_tombstones_by_id.ensureUnusedCapacity(self.allocator, 1);
        try self.state.requests.ensureUnusedCapacity(self.allocator, 1);

        var revision_index: usize = 0;
        while (!std.mem.eql(u8, self.state.volume_ids_by_revision.items[revision_index], command.volume_id)) : (revision_index += 1) {}
        const removed = self.state.volumes_by_id.fetchRemove(command.volume_id).?;
        _ = self.state.volume_ids_by_scoped_name.remove(removed.value.scoped_name);
        _ = self.state.volume_ids_by_revision.orderedRemove(revision_index);
        self.state.volume_tombstones_by_id.putAssumeCapacity(removed.value.id, .{ .volume = removed.value, .deleted_at_unix_ms = command.proposed_deleted_at_unix_ms, .deleted_revision = revision });
        self.state.max_volume_deleted_revision = @max(self.state.max_volume_deleted_revision, revision);
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
            try restoreReplicaPlacement(self.allocator, &restored, source, metadata.index);
        }
        for (snapshot.replica_allocations.items) |source| {
            try restoreReplicaAllocation(self.allocator, &restored, source, metadata.index);
        }
        for (snapshot.volume_attachments.items) |source| {
            try restoreVolumeAttachment(self.allocator, &restored, source, metadata.index);
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
        if (created_pool_ids.count() != restored.pools_by_id.count() or
            registered_node_ids.count() != restored.nodes_by_id.count() or
            registered_member_ids.count() != restored.members_by_id.count() or
            created_volume_ids.count() != restored.volumes_by_id.count() + restored.volume_tombstones_by_id.count() or
            deleted_volume_ids.count() != restored.volume_tombstones_by_id.count())
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

pub fn decodeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.ApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.ApplyResponse.decode(&reader, allocator);
}

pub fn decodeRegisterNodeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.RegisterNodeApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.RegisterNodeApplyResponse.decode(&reader, allocator);
}

pub fn decodeRegisterMemberApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.RegisterMemberApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.RegisterMemberApplyResponse.decode(&reader, allocator);
}

pub fn decodeCreateVolumeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.CreateVolumeApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.CreateVolumeApplyResponse.decode(&reader, allocator);
}

pub fn decodeDeleteVolumeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.DeleteVolumeApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.DeleteVolumeApplyResponse.decode(&reader, allocator);
}

pub fn deinitPoolList(allocator: std.mem.Allocator, pools: []pb.Pool) void {
    for (pools) |*pool| pool.deinit(allocator);
    allocator.free(pools);
}

pub fn deinitNodeList(allocator: std.mem.Allocator, nodes: []pb.Node) void {
    for (nodes) |*node| node.deinit(allocator);
    allocator.free(nodes);
}

pub fn deinitMemberList(allocator: std.mem.Allocator, members: []pb.Member) void {
    for (members) |*member| member.deinit(allocator);
    allocator.free(members);
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

fn validVolumeSize(size_bytes: u64) bool {
    return size_bytes >= min_volume_size_bytes and size_bytes <= max_volume_size_bytes and size_bytes % volume_block_size_bytes == 0;
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

fn validClusterId(value: []const u8) bool {
    return validFixedNonzero(value, 16);
}

fn validFixedNonzero(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (byte != 0) return true;
    return false;
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

fn encodeDeleteVolumeApplyResponse(allocator: std.mem.Allocator, code: pb.DeleteVolumeApplyCode, volume_id: []const u8, deleted_at_unix_ms: i64, deleted_revision: u64) raft.Error![]u8 {
    return encodeMessage(allocator, pb.DeleteVolumeApplyResponse{ .code = code, .volume_id = volume_id, .deleted_at_unix_ms = deleted_at_unix_ms, .deleted_revision = deleted_revision });
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

fn restoreReplicaPlacement(allocator: std.mem.Allocator, state: *State, source: pb.ReplicaPlacement, snapshot_index: u64) raft.Error!void {
    if (!validUuidV7(source.id) or !validUuidV7(source.volume_id) or !validUuidV7(source.node_id) or
        source.replica_index >= volume_target_replica_count or source.generation == 0 or
        !validReplicaPlacementState(source.state) or !validResourceRevisions(source.created_revision, source.resource_version, snapshot_index))
    {
        return error.PayloadParseFailed;
    }
    const volume = state.volumes_by_id.get(source.volume_id) orelse return error.PayloadParseFailed;
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

fn restoreReplicaAllocation(allocator: std.mem.Allocator, state: *State, source: pb.ReplicaAllocation, snapshot_index: u64) raft.Error!void {
    if (!validUuidV7(source.id) or !validUuidV7(source.replica_id) or !validFixedNonzero(source.member_id, 16) or
        source.length_bytes == 0 or source.generation == 0 or !validReplicaAllocationState(source.state) or
        !validResourceRevisions(source.created_revision, source.resource_version, snapshot_index) or
        state.replica_allocations_by_id.contains(source.id))
    {
        return error.PayloadParseFailed;
    }
    const replica = state.replica_placements_by_id.get(source.replica_id) orelse return error.PayloadParseFailed;
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
    state.replica_allocations_by_id.putAssumeCapacity(allocation.id, allocation);
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
    if (envelope.format_version != 1 and envelope.format_version != command_format_version) return error.PayloadParseFailed;
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
            if (snapshot_version < 5 or envelope.format_version != command_format_version) return error.PayloadParseFailed;
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
            if (snapshot_version < 5 or envelope.format_version != command_format_version) return error.PayloadParseFailed;
            try validateDeleteVolumeCommand(command);
            if (!std.mem.eql(u8, source.request_id, command.request_id)) return error.PayloadParseFailed;
            const expected_fingerprint = deleteVolumeFingerprint(command);
            if (!std.mem.eql(u8, source.request_fingerprint, &expected_fingerprint)) return error.PayloadParseFailed;

            var response_reader: std.Io.Reader = .fixed(source.encoded_response);
            var response = pb.DeleteVolumeApplyResponse.decode(&response_reader, decode_allocator) catch |err| return mapDecodeError(err);
            defer response.deinit(decode_allocator);
            try validateStoredDeleteVolumeResponse(state, command, response, source.applied_revision);
            const encoded_response = try encodeDeleteVolumeApplyResponse(allocator, response.code, response.volume_id, response.deleted_at_unix_ms, response.deleted_revision);
            errdefer allocator.free(encoded_response);
            const encoded_command = try encodeDeleteVolumeCommand(allocator, command);
            errdefer allocator.free(encoded_command);
            try insertRestoredRequest(allocator, state, source, .delete_volume, encoded_response, encoded_command);
            return if (response.code == .DELETE_VOLUME_APPLY_CODE_DELETED) RestoredCreation{ .volume_deleted = state.volume_tombstones_by_id.get(command.volume_id).?.volume.id } else null;
        },
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
            if (!volumesEqual(stored_volume, response_volume) or
                !std.mem.eql(u8, command.proposed_volume_id, response_volume.id) or
                !std.mem.eql(u8, command.pool_id, response_volume.pool_id) or
                !std.mem.eql(u8, command.name, response_volume.name) or
                !std.mem.eql(u8, command.description, response_volume.description) or
                command.size_bytes != response_volume.size_bytes or
                command.proposed_created_at_unix_ms != response_volume.created_at_unix_ms or
                response_volume.created_revision != applied_revision or
                response_volume.resource_version != applied_revision or !pool_existed or id_existed or name_volume != null)
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
) raft.Error!void {
    const volume = storedVolumeById(state, command.volume_id);
    const was_live = if (volume) |value| volumeWasLiveAt(state, value.id, applied_revision) else false;
    const response_is_empty = response.volume_id.len == 0 and response.deleted_at_unix_ms == 0 and response.deleted_revision == 0;
    switch (response.code) {
        .DELETE_VOLUME_APPLY_CODE_DELETED => {
            const tombstone = state.volume_tombstones_by_id.get(command.volume_id) orelse return error.PayloadParseFailed;
            if (!std.mem.eql(u8, response.volume_id, command.volume_id) or
                response.deleted_at_unix_ms != command.proposed_deleted_at_unix_ms or
                response.deleted_revision != applied_revision or
                tombstone.deleted_at_unix_ms != response.deleted_at_unix_ms or
                tombstone.deleted_revision != response.deleted_revision or
                tombstone.volume.resource_version != command.expected_resource_version)
            {
                return error.PayloadParseFailed;
            }
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

fn scopedKey(prefix: []const u8, suffix: []const u8, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= prefix.len + 1 + suffix.len);
    @memcpy(buffer[0..prefix.len], prefix);
    buffer[prefix.len] = 0;
    @memcpy(buffer[prefix.len + 1 .. prefix.len + 1 + suffix.len], suffix);
    return buffer[0 .. prefix.len + 1 + suffix.len];
}

fn makeScopedKey(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, prefix.len + 1 + suffix.len);
    _ = scopedKey(prefix, suffix, result);
    return result;
}

fn replicaKey(volume_id: []const u8, replica_index: u32, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= volume_id.len + 1 and replica_index < volume_target_replica_count);
    @memcpy(buffer[0..volume_id.len], volume_id);
    buffer[volume_id.len] = @intCast(replica_index);
    return buffer[0 .. volume_id.len + 1];
}

fn makeReplicaKey(allocator: std.mem.Allocator, volume_id: []const u8, replica_index: u32) ![]u8 {
    const result = try allocator.alloc(u8, volume_id.len + 1);
    _ = replicaKey(volume_id, replica_index, result);
    return result;
}

fn hasVolumeDependencies(state: *const State, volume_id: []const u8) bool {
    var replica_iterator = state.replica_placements_by_id.valueIterator();
    while (replica_iterator.next()) |replica| if (std.mem.eql(u8, replica.volume_id, volume_id)) return true;
    var attachment_iterator = state.volume_attachments_by_id.valueIterator();
    while (attachment_iterator.next()) |attachment| if (std.mem.eql(u8, attachment.volume_id, volume_id)) return true;
    return false;
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

const WireError = wire.Error;
const WireCursor = wire.Cursor;

fn preflightCommand(bytes: []const u8) WireError!void {
    _ = try preflightCommandKind(bytes);
}

fn preflightCommandKind(bytes: []const u8) WireError!RequestKind {
    if (bytes.len > max_command_wire_bytes) return error.InvalidWire;
    var cursor = WireCursor{ .bytes = bytes };
    var seen_format = false;
    var format_version: u64 = 0;
    var kind: ?RequestKind = null;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_format) return error.InvalidWire;
            seen_format = true;
            format_version = try cursor.readVarint();
            if (format_version != 1 and format_version != command_format_version) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .create_pool;
            try preflightCreatePool(try cursor.readBytes(max_pool_wire_bytes));
        },
        3 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .register_node;
            try preflightRegisterNode(try cursor.readBytes(max_node_wire_bytes));
        },
        4 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .register_member;
            try preflightRegisterMember(try cursor.readBytes(max_member_wire_bytes));
        },
        5 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .create_volume;
            try preflightCreateVolumeCommand(try cursor.readBytes(max_volume_wire_bytes));
        },
        6 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .delete_volume;
            try preflightDeleteVolumeCommand(try cursor.readBytes(max_volume_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_format) return error.InvalidWire;
    const result = kind orelse return error.InvalidWire;
    if ((result == .create_volume or result == .delete_volume) and format_version != command_format_version) return error.InvalidWire;
    return result;
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

fn preflightRegisterNode(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 10;
    while (try cursor.next()) |field| {
        if (field.number > 9 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            4, 5 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_node_endpoint_bytes), max_node_endpoint_bytes, false)) return error.InvalidWire,
            6 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_failure_domain_bytes), max_failure_domain_bytes, false)) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            8 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const version = try cursor.readVarint();
                if (version == 0 or version > std.math.maxInt(u32)) return error.InvalidWire;
            },
            9 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5] or !seen[6] or !seen[8] or !seen[9]) return error.InvalidWire;
}

fn preflightRegisterMember(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 13;
    var member_id: ?[]const u8 = null;
    var local_set_id: ?[]const u8 = null;
    while (try cursor.next()) |field| {
        if (field.number > 12 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            3 => {
                if (field.wire_type != 2) return error.InvalidWire;
                member_id = try cursor.readBytes(16);
                if (!validFixedNonzero(member_id.?, 16)) return error.InvalidWire;
            },
            4, 5 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            6 => {
                if (field.wire_type != 2) return error.InvalidWire;
                local_set_id = try cursor.readBytes(16);
                if (!validFixedNonzero(local_set_id.?, 16)) return error.InvalidWire;
            },
            7 => if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u16)) return error.InvalidWire,
            8 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            9, 10 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            11 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const extent_size = try cursor.readVarint();
                if (extent_size == 0 or extent_size > std.math.maxInt(u32)) return error.InvalidWire;
            },
            12 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5] or !seen[6] or
        !seen[8] or !seen[9] or !seen[10] or !seen[11] or !seen[12] or
        std.mem.eql(u8, member_id.?, local_set_id.?)) return error.InvalidWire;
}

fn preflightCreateVolumeCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 8;
    while (try cursor.next()) |field| {
        if (field.number > 7 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_name_bytes), max_name_bytes, false)) return error.InvalidWire,
            5 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire,
            6 => if (field.wire_type != 0 or !validVolumeSize(try cursor.readVarint())) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[6] or !seen[7]) return error.InvalidWire;
}

fn preflightDeleteVolumeCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 5;
    while (try cursor.next()) |field| {
        if (field.number > 4 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4]) return error.InvalidWire;
}

fn preflightSnapshot(bytes: []const u8) WireError!void {
    if (bytes.len > max_snapshot_bytes) return error.InvalidWire;
    var cursor = WireCursor{ .bytes = bytes };
    var seen_format = false;
    var snapshot_version: u32 = 0;
    var pool_count: usize = 0;
    var request_count: usize = 0;
    var node_count: usize = 0;
    var member_count: usize = 0;
    var volume_count: usize = 0;
    var tombstone_count: usize = 0;
    var replica_count: usize = 0;
    var allocation_count: usize = 0;
    var attachment_count: usize = 0;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_format) return error.InvalidWire;
            seen_format = true;
            const version = try cursor.readVarint();
            if (version < 2 or version > snapshot_format_version) return error.InvalidWire;
            snapshot_version = @intCast(version);
        },
        2 => {
            if (field.wire_type != 2 or pool_count == max_pools) return error.InvalidWire;
            pool_count += 1;
            _ = try cursor.readBytes(max_pool_wire_bytes);
        },
        3 => {
            if (field.wire_type != 2 or request_count == max_requests) return error.InvalidWire;
            request_count += 1;
            _ = try cursor.readBytes(max_request_wire_bytes);
        },
        4 => {
            if (field.wire_type != 2 or node_count == max_nodes) return error.InvalidWire;
            node_count += 1;
            _ = try cursor.readBytes(max_node_wire_bytes);
        },
        5 => {
            if (field.wire_type != 2 or member_count == max_members) return error.InvalidWire;
            member_count += 1;
            _ = try cursor.readBytes(max_member_wire_bytes);
        },
        6 => {
            if (field.wire_type != 2 or volume_count == max_volumes) return error.InvalidWire;
            volume_count += 1;
            _ = try cursor.readBytes(max_volume_wire_bytes);
        },
        7 => {
            if (field.wire_type != 2 or tombstone_count == max_volume_tombstones) return error.InvalidWire;
            tombstone_count += 1;
            _ = try cursor.readBytes(max_volume_tombstone_wire_bytes);
        },
        8 => {
            if (field.wire_type != 2 or replica_count == max_replica_placements) return error.InvalidWire;
            replica_count += 1;
            _ = try cursor.readBytes(max_replica_placement_wire_bytes);
        },
        9 => {
            if (field.wire_type != 2 or allocation_count == max_replica_allocations) return error.InvalidWire;
            allocation_count += 1;
            _ = try cursor.readBytes(max_replica_allocation_wire_bytes);
        },
        10 => {
            if (field.wire_type != 2 or attachment_count == max_volume_attachments) return error.InvalidWire;
            attachment_count += 1;
            _ = try cursor.readBytes(max_volume_attachment_wire_bytes);
        },
        else => return error.InvalidWire,
    };
    if (!seen_format or (snapshot_version == 2 and node_count != 0) or
        (snapshot_version < 4 and member_count != 0) or
        (snapshot_version < 5 and (volume_count != 0 or tombstone_count != 0 or replica_count != 0 or allocation_count != 0 or attachment_count != 0))) return error.InvalidWire;

    cursor = .{ .bytes = bytes };
    while (try cursor.next()) |field| switch (field.number) {
        1 => _ = try cursor.readVarint(),
        2 => try preflightPool(try cursor.readBytes(max_pool_wire_bytes)),
        3 => try preflightRequest(try cursor.readBytes(max_request_wire_bytes), snapshot_version),
        4 => try preflightNode(try cursor.readBytes(max_node_wire_bytes)),
        5 => try preflightMember(try cursor.readBytes(max_member_wire_bytes)),
        6 => try preflightVolume(try cursor.readBytes(max_volume_wire_bytes)),
        7 => try preflightVolumeTombstone(try cursor.readBytes(max_volume_tombstone_wire_bytes)),
        8 => try preflightReplicaPlacement(try cursor.readBytes(max_replica_placement_wire_bytes)),
        9 => try preflightReplicaAllocation(try cursor.readBytes(max_replica_allocation_wire_bytes)),
        10 => try preflightVolumeAttachment(try cursor.readBytes(max_volume_attachment_wire_bytes)),
        else => unreachable,
    };
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

fn preflightNode(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 10;
    while (try cursor.next()) |field| {
        if (field.number > 9 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            3, 4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_node_endpoint_bytes), max_node_endpoint_bytes, false)) return error.InvalidWire,
            5 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_failure_domain_bytes), max_failure_domain_bytes, false)) return error.InvalidWire,
            6 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const version = try cursor.readVarint();
                if (version == 0 or version > std.math.maxInt(u32)) return error.InvalidWire;
            },
            8 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            9 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5] or !seen[7] or !seen[8] or !seen[9]) return error.InvalidWire;
}

fn preflightMember(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 12;
    var member_id: ?[]const u8 = null;
    var local_set_id: ?[]const u8 = null;
    while (try cursor.next()) |field| {
        if (field.number > 11 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2) return error.InvalidWire;
                member_id = try cursor.readBytes(16);
                if (!validFixedNonzero(member_id.?, 16)) return error.InvalidWire;
            },
            2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => {
                if (field.wire_type != 2) return error.InvalidWire;
                local_set_id = try cursor.readBytes(16);
                if (!validFixedNonzero(local_set_id.?, 16)) return error.InvalidWire;
            },
            5 => if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u16)) return error.InvalidWire,
            6 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            7, 8 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            9 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const extent_size = try cursor.readVarint();
                if (extent_size == 0 or extent_size > std.math.maxInt(u32)) return error.InvalidWire;
            },
            10 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            11 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[6] or !seen[7] or
        !seen[8] or !seen[9] or !seen[10] or !seen[11] or
        std.mem.eql(u8, member_id.?, local_set_id.?)) return error.InvalidWire;
}

fn preflightVolume(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 19;
    while (try cursor.next()) |field| {
        if (field.number > 18 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_name_bytes), max_name_bytes, false)) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire,
            5 => if (field.wire_type != 0 or !validVolumeSize(try cursor.readVarint())) return error.InvalidWire,
            6 => if (field.wire_type != 0 or try cursor.readVarint() != 1) return error.InvalidWire,
            7 => if (field.wire_type != 0 or try cursor.readVarint() != volume_target_replica_count) return error.InvalidWire,
            8 => if (field.wire_type != 0 or try cursor.readVarint() != volume_write_quorum) return error.InvalidWire,
            9 => if (field.wire_type != 0 or try cursor.readVarint() != volume_read_quorum) return error.InvalidWire,
            10 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 4) return error.InvalidWire;
            },
            11, 12 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 5) return error.InvalidWire;
            },
            13, 14 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            15 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            16 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            17, 18 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5] or !seen[6] or !seen[7] or !seen[8] or !seen[9] or
        !seen[10] or !seen[11] or !seen[12] or !seen[13] or !seen[14] or !seen[16] or !seen[17] or !seen[18]) return error.InvalidWire;
}

fn preflightVolumeTombstone(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 4;
    while (try cursor.next()) |field| {
        if (field.number > 3 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightVolume(try cursor.readBytes(max_volume_wire_bytes));
            },
            2 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            3 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3]) return error.InvalidWire;
}

fn preflightReplicaPlacement(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 9;
    while (try cursor.next()) |field| {
        if (field.number > 8 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => if (field.wire_type != 0 or try cursor.readVarint() >= volume_target_replica_count) return error.InvalidWire,
            5, 7, 8 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            6 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 3) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5] or !seen[6] or !seen[7] or !seen[8]) return error.InvalidWire;
}

fn preflightReplicaAllocation(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 10;
    while (try cursor.next()) |field| {
        if (field.number > 9 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            5, 6, 8, 9 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 3) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5] or !seen[6] or !seen[7] or !seen[8] or !seen[9]) return error.InvalidWire;
}

fn preflightVolumeAttachment(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 10;
    while (try cursor.next()) |field| {
        if (field.number > 9 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_consumer_id_bytes), max_consumer_id_bytes, false)) return error.InvalidWire,
            5 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 2) return error.InvalidWire;
            },
            6 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 4) return error.InvalidWire;
            },
            7, 8, 9 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5] or !seen[6] or !seen[7] or !seen[8] or !seen[9]) return error.InvalidWire;
}

fn preflightRequest(bytes: []const u8, snapshot_version: u32) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 6;
    var response_bytes: ?[]const u8 = null;
    var command_bytes: ?[]const u8 = null;
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
                response_bytes = try cursor.readBytes(max_response_wire_bytes);
            },
            4 => {
                if (field.wire_type != 2) return error.InvalidWire;
                command_bytes = try cursor.readBytes(max_command_wire_bytes);
            },
            5 => {
                if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5]) return error.InvalidWire;
    const kind = try preflightCommandKind(command_bytes.?);
    if ((snapshot_version == 2 and kind != .create_pool) or
        (snapshot_version < 4 and kind == .register_member) or
        (snapshot_version < 5 and (kind == .create_volume or kind == .delete_volume))) return error.InvalidWire;
    switch (kind) {
        .create_pool => try preflightApplyResponse(response_bytes.?),
        .register_node => try preflightRegisterNodeApplyResponse(response_bytes.?),
        .register_member => try preflightRegisterMemberApplyResponse(response_bytes.?),
        .create_volume => try preflightCreateVolumeApplyResponse(response_bytes.?),
        .delete_volume => try preflightDeleteVolumeApplyResponse(response_bytes.?),
    }
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

fn preflightRegisterNodeApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_node = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code > 5) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_node) return error.InvalidWire;
            seen_node = true;
            try preflightNode(try cursor.readBytes(max_node_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn preflightRegisterMemberApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_member = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code > 10) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_member) return error.InvalidWire;
            seen_member = true;
            try preflightMember(try cursor.readBytes(max_member_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn preflightCreateVolumeApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_volume = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code > 7) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_volume) return error.InvalidWire;
            seen_volume = true;
            try preflightVolume(try cursor.readBytes(max_volume_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn preflightDeleteVolumeApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen = [_]bool{false} ** 5;
    while (try cursor.next()) |field| {
        if (field.number > 4 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const code = try cursor.readVarint();
                if (code == 0 or code > 7) return error.InvalidWire;
            },
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            4 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1]) return error.InvalidWire;
    if (seen[2] != seen[3] or seen[2] != seen[4]) return error.InvalidWire;
}

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
const test_volume_id = "0198f54d-5c2a-7000-8000-000000000021";
const test_second_volume_id = "0198f54d-5c2a-7000-8000-000000000022";
const test_replica_id = "0198f54d-5c2a-7000-8000-000000000031";
const test_second_replica_id = "0198f54d-5c2a-7000-8000-000000000032";
const test_third_replica_id = "0198f54d-5c2a-7000-8000-000000000033";
const test_allocation_id = "0198f54d-5c2a-7000-8000-000000000041";
const test_second_allocation_id = "0198f54d-5c2a-7000-8000-000000000042";
const test_attachment_id = "0198f54d-5c2a-7000-8000-000000000051";
const test_member_id_a = [_]u8{ 0x10, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_member_id_b = [_]u8{ 0x20, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_member_id_c = [_]u8{ 0x30, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_local_set_id = [_]u8{ 0x40, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const test_birth_topology_digest = [_]u8{0x5a} ** 32;

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
    try std.testing.expectEqual(@as(u64, 8), deleted_response.deleted_revision);
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
    }, 7);
    try std.testing.expectError(error.PayloadParseFailed, restoreReplicaPlacement(allocator, &machine.state, .{
        .id = test_second_replica_id,
        .volume_id = test_volume_id,
        .node_id = test_node_id,
        .replica_index = 1,
        .generation = 1,
        .state = .REPLICA_PLACEMENT_STATE_RESERVED,
        .created_revision = 6,
        .resource_version = 6,
    }, 7));
    try std.testing.expectError(error.PayloadParseFailed, restoreReplicaPlacement(allocator, &machine.state, .{
        .id = test_third_replica_id,
        .volume_id = test_volume_id,
        .node_id = test_second_node_id,
        .replica_index = 1,
        .generation = 1,
        .state = .REPLICA_PLACEMENT_STATE_RESERVED,
        .created_revision = 7,
        .resource_version = 7,
    }, 7));
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
        response.deleted_revision = 5;
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
    try std.testing.expectEqual(pb.DeleteVolumeApplyCode.DELETE_VOLUME_APPLY_CODE_HAS_DEPENDENCIES, blocked_response.code);

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
    try std.testing.checkAllAllocationFailures(allocator, VolumeApplyAllocationCheck.run, .{ pool_command, create_command, delete_command });
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
    try std.testing.checkAllAllocationFailures(
        allocator,
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
    try std.testing.checkAllAllocationFailures(
        allocator,
        MemberRestoreAllocationCheck.run,
        .{ existing_command, snapshot.data, snapshot.metadata },
    );
}
