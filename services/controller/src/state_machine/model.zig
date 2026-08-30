const std = @import("std");
const pb = @import("controller_proto");
const schema = @import("schema.zig");

const Fingerprint = schema.Fingerprint;
const RequestKind = schema.RequestKind;
const volume_target_replica_count = schema.volume_target_replica_count;

pub const Pool = struct {
    id: []u8,
    name: []u8,
    description: []u8,
    created_at_unix_ms: i64,
    created_revision: u64,

    pub fn init(allocator: std.mem.Allocator, source: pb.Pool) !Pool {
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

    pub fn deinit(self: *Pool, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
        self.* = undefined;
    }

    pub fn proto(self: Pool) pb.Pool {
        return .{
            .id = self.id,
            .name = self.name,
            .description = self.description,
            .created_at_unix_ms = self.created_at_unix_ms,
            .created_revision = self.created_revision,
        };
    }
};

pub const Node = struct {
    id: []u8,
    cluster_id: []u8,
    control_endpoint: []u8,
    nvmf_endpoint: []u8,
    replica_endpoint: []u8,
    signing_public_key: []u8,
    failure_domain: []u8,
    capability_bits: u64,
    protocol_version: u32,
    registered_at_unix_ms: i64,
    registered_revision: u64,

    pub fn init(allocator: std.mem.Allocator, source: pb.Node) !Node {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const cluster_id = try allocator.dupe(u8, source.cluster_id);
        errdefer allocator.free(cluster_id);
        const control_endpoint = try allocator.dupe(u8, source.control_endpoint);
        errdefer allocator.free(control_endpoint);
        const nvmf_endpoint = try allocator.dupe(u8, source.nvmf_endpoint);
        errdefer allocator.free(nvmf_endpoint);
        const replica_endpoint = try allocator.dupe(u8, source.replica_endpoint);
        errdefer allocator.free(replica_endpoint);
        const signing_public_key = try allocator.dupe(u8, source.signing_public_key);
        errdefer allocator.free(signing_public_key);
        const failure_domain = try allocator.dupe(u8, source.failure_domain);
        return .{
            .id = id,
            .cluster_id = cluster_id,
            .control_endpoint = control_endpoint,
            .nvmf_endpoint = nvmf_endpoint,
            .replica_endpoint = replica_endpoint,
            .signing_public_key = signing_public_key,
            .failure_domain = failure_domain,
            .capability_bits = source.capability_bits,
            .protocol_version = source.protocol_version,
            .registered_at_unix_ms = source.registered_at_unix_ms,
            .registered_revision = source.registered_revision,
        };
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.cluster_id);
        allocator.free(self.control_endpoint);
        allocator.free(self.nvmf_endpoint);
        allocator.free(self.replica_endpoint);
        allocator.free(self.signing_public_key);
        allocator.free(self.failure_domain);
        self.* = undefined;
    }

    pub fn proto(self: Node) pb.Node {
        return .{
            .id = self.id,
            .cluster_id = self.cluster_id,
            .control_endpoint = self.control_endpoint,
            .nvmf_endpoint = self.nvmf_endpoint,
            .replica_endpoint = self.replica_endpoint,
            .signing_public_key = self.signing_public_key,
            .failure_domain = self.failure_domain,
            .capability_bits = self.capability_bits,
            .protocol_version = self.protocol_version,
            .registered_at_unix_ms = self.registered_at_unix_ms,
            .registered_revision = self.registered_revision,
        };
    }
};

pub const Member = struct {
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

    pub fn init(allocator: std.mem.Allocator, source: pb.Member) !Member {
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

    pub fn deinit(self: *Member, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.pool_id);
        allocator.free(self.node_id);
        allocator.free(self.local_set_id);
        allocator.free(self.birth_topology_digest);
        self.* = undefined;
    }

    pub fn proto(self: Member) pb.Member {
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

pub const MemberSlotKey = struct {
    local_set_id: [16]u8,
    member_slot: u16,
};

pub const Volume = struct {
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

    pub fn init(allocator: std.mem.Allocator, source: pb.Volume) !Volume {
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

    pub fn deinit(self: *Volume, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.pool_id);
        allocator.free(self.name);
        allocator.free(self.scoped_name);
        allocator.free(self.description);
        self.* = undefined;
    }

    pub fn proto(self: Volume) pb.Volume {
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

pub const VolumeTombstone = struct {
    volume: Volume,
    deleted_at_unix_ms: i64,
    deleted_revision: u64,

    pub fn deinit(self: *VolumeTombstone, allocator: std.mem.Allocator) void {
        self.volume.deinit(allocator);
        self.* = undefined;
    }

    pub fn proto(self: VolumeTombstone) pb.VolumeTombstone {
        return .{
            .volume = self.volume.proto(),
            .deleted_at_unix_ms = self.deleted_at_unix_ms,
            .deleted_revision = self.deleted_revision,
        };
    }
};

pub const ReplicaPlacement = struct {
    id: []u8,
    volume_id: []u8,
    node_id: []u8,
    replica_key: []u8,
    replica_index: u32,
    generation: u64,
    state: pb.ReplicaPlacementState,
    created_revision: u64,
    resource_version: u64,
    backend_digest: []u8,
    attested_revision: u64,

    pub fn init(allocator: std.mem.Allocator, source: pb.ReplicaPlacement) !ReplicaPlacement {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const volume_id = try allocator.dupe(u8, source.volume_id);
        errdefer allocator.free(volume_id);
        const node_id = try allocator.dupe(u8, source.node_id);
        errdefer allocator.free(node_id);
        const replica_key = try makeReplicaKey(allocator, source.volume_id, source.replica_index);
        errdefer allocator.free(replica_key);
        const backend_digest = try allocator.dupe(u8, source.backend_digest);
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
            .backend_digest = backend_digest,
            .attested_revision = source.attested_revision,
        };
    }

    pub fn deinit(self: *ReplicaPlacement, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.volume_id);
        allocator.free(self.node_id);
        allocator.free(self.replica_key);
        allocator.free(self.backend_digest);
        self.* = undefined;
    }

    pub fn proto(self: ReplicaPlacement) pb.ReplicaPlacement {
        return .{ .id = self.id, .volume_id = self.volume_id, .node_id = self.node_id, .replica_index = self.replica_index, .generation = self.generation, .state = self.state, .created_revision = self.created_revision, .resource_version = self.resource_version, .backend_digest = self.backend_digest, .attested_revision = self.attested_revision };
    }
};

pub const ReplicaAllocation = struct {
    id: []u8,
    replica_id: []u8,
    member_id: []u8,
    offset_bytes: u64,
    length_bytes: u64,
    generation: u64,
    state: pb.ReplicaAllocationState,
    created_revision: u64,
    resource_version: u64,

    pub fn init(allocator: std.mem.Allocator, source: pb.ReplicaAllocation) !ReplicaAllocation {
        const id = try allocator.dupe(u8, source.id);
        errdefer allocator.free(id);
        const replica_id = try allocator.dupe(u8, source.replica_id);
        errdefer allocator.free(replica_id);
        const member_id = try allocator.dupe(u8, source.member_id);
        return .{ .id = id, .replica_id = replica_id, .member_id = member_id, .offset_bytes = source.offset_bytes, .length_bytes = source.length_bytes, .generation = source.generation, .state = source.state, .created_revision = source.created_revision, .resource_version = source.resource_version };
    }

    pub fn deinit(self: *ReplicaAllocation, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.replica_id);
        allocator.free(self.member_id);
        self.* = undefined;
    }

    pub fn proto(self: ReplicaAllocation) pb.ReplicaAllocation {
        return .{ .id = self.id, .replica_id = self.replica_id, .member_id = self.member_id, .offset_bytes = self.offset_bytes, .length_bytes = self.length_bytes, .generation = self.generation, .state = self.state, .created_revision = self.created_revision, .resource_version = self.resource_version };
    }
};

pub const VolumeAttachment = struct {
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

    pub fn init(allocator: std.mem.Allocator, source: pb.VolumeAttachment) !VolumeAttachment {
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

    pub fn deinit(self: *VolumeAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.volume_id);
        allocator.free(self.target_node_id);
        allocator.free(self.consumer_id);
        allocator.free(self.consumer_key);
        self.* = undefined;
    }

    pub fn proto(self: VolumeAttachment) pb.VolumeAttachment {
        return .{ .id = self.id, .volume_id = self.volume_id, .target_node_id = self.target_node_id, .consumer_id = self.consumer_id, .access_mode = self.access_mode, .state = self.state, .generation = self.generation, .created_revision = self.created_revision, .resource_version = self.resource_version };
    }
};

pub const PrimaryAuthority = struct {
    volume_id: []u8,
    primary_placement_id: []u8,
    primary_node_id: []u8,
    lease_id: []u8,
    holder_boot_id: []u8,
    authority_generation: u64,
    write_epoch: u64,
    placement_revision: u64,
    activation_nonce: []u8,
    lease_duration_ms: u32,
    state: pb.PrimaryAuthorityState,
    authority_digest: []u8,
    created_revision: u64,
    activated_revision: u64,
    ready_revision: u64,
    resource_version: u64,
    recovery_sequence: u64,
    recovery_digest: []u8,
    recovery_empty_frontier: bool,

    pub fn init(allocator: std.mem.Allocator, source: pb.PrimaryAuthority) !PrimaryAuthority {
        const volume_id = try allocator.dupe(u8, source.volume_id);
        errdefer allocator.free(volume_id);
        const primary_placement_id = try allocator.dupe(u8, source.primary_placement_id);
        errdefer allocator.free(primary_placement_id);
        const primary_node_id = try allocator.dupe(u8, source.primary_node_id);
        errdefer allocator.free(primary_node_id);
        const lease_id = try allocator.dupe(u8, source.lease_id);
        errdefer allocator.free(lease_id);
        const holder_boot_id = try allocator.dupe(u8, source.holder_boot_id);
        errdefer allocator.free(holder_boot_id);
        const activation_nonce = try allocator.dupe(u8, source.activation_nonce);
        errdefer allocator.free(activation_nonce);
        const authority_digest = try allocator.dupe(u8, source.authority_digest);
        errdefer allocator.free(authority_digest);
        const recovery_digest = try allocator.dupe(u8, source.recovery_digest);
        return .{
            .volume_id = volume_id,
            .primary_placement_id = primary_placement_id,
            .primary_node_id = primary_node_id,
            .lease_id = lease_id,
            .holder_boot_id = holder_boot_id,
            .authority_generation = source.authority_generation,
            .write_epoch = source.write_epoch,
            .placement_revision = source.placement_revision,
            .activation_nonce = activation_nonce,
            .lease_duration_ms = source.lease_duration_ms,
            .state = source.state,
            .authority_digest = authority_digest,
            .created_revision = source.created_revision,
            .activated_revision = source.activated_revision,
            .ready_revision = source.ready_revision,
            .resource_version = source.resource_version,
            .recovery_sequence = source.recovery_sequence,
            .recovery_digest = recovery_digest,
            .recovery_empty_frontier = source.recovery_empty_frontier,
        };
    }

    pub fn deinit(self: *PrimaryAuthority, allocator: std.mem.Allocator) void {
        allocator.free(self.volume_id);
        allocator.free(self.primary_placement_id);
        allocator.free(self.primary_node_id);
        allocator.free(self.lease_id);
        allocator.free(self.holder_boot_id);
        allocator.free(self.activation_nonce);
        allocator.free(self.authority_digest);
        allocator.free(self.recovery_digest);
        self.* = undefined;
    }

    pub fn proto(self: PrimaryAuthority) pb.PrimaryAuthority {
        return .{
            .volume_id = self.volume_id,
            .primary_placement_id = self.primary_placement_id,
            .primary_node_id = self.primary_node_id,
            .lease_id = self.lease_id,
            .holder_boot_id = self.holder_boot_id,
            .authority_generation = self.authority_generation,
            .write_epoch = self.write_epoch,
            .placement_revision = self.placement_revision,
            .activation_nonce = self.activation_nonce,
            .lease_duration_ms = self.lease_duration_ms,
            .state = self.state,
            .authority_digest = self.authority_digest,
            .created_revision = self.created_revision,
            .activated_revision = self.activated_revision,
            .ready_revision = self.ready_revision,
            .resource_version = self.resource_version,
            .recovery_sequence = self.recovery_sequence,
            .recovery_digest = self.recovery_digest,
            .recovery_empty_frontier = self.recovery_empty_frontier,
        };
    }
};

pub const PrimaryFailover = struct {
    failover_id: []u8,
    volume_id: []u8,
    revoked_lease_id: []u8,
    revoked_authority_generation: u64,
    revoked_write_epoch: u64,
    target_write_epoch: u64,
    state: pb.PrimaryFailoverState,
    created_revision: u64,
    resource_version: u64,

    pub fn init(allocator: std.mem.Allocator, source: pb.PrimaryFailover) !PrimaryFailover {
        const failover_id = try allocator.dupe(u8, source.failover_id);
        errdefer allocator.free(failover_id);
        const volume_id = try allocator.dupe(u8, source.volume_id);
        errdefer allocator.free(volume_id);
        const revoked_lease_id = try allocator.dupe(u8, source.revoked_lease_id);
        return .{
            .failover_id = failover_id,
            .volume_id = volume_id,
            .revoked_lease_id = revoked_lease_id,
            .revoked_authority_generation = source.revoked_authority_generation,
            .revoked_write_epoch = source.revoked_write_epoch,
            .target_write_epoch = source.target_write_epoch,
            .state = source.state,
            .created_revision = source.created_revision,
            .resource_version = source.resource_version,
        };
    }

    pub fn deinit(self: *PrimaryFailover, allocator: std.mem.Allocator) void {
        allocator.free(self.failover_id);
        allocator.free(self.volume_id);
        allocator.free(self.revoked_lease_id);
        self.* = undefined;
    }

    pub fn proto(self: PrimaryFailover) pb.PrimaryFailover {
        return .{
            .failover_id = self.failover_id,
            .volume_id = self.volume_id,
            .revoked_lease_id = self.revoked_lease_id,
            .revoked_authority_generation = self.revoked_authority_generation,
            .revoked_write_epoch = self.revoked_write_epoch,
            .target_write_epoch = self.target_write_epoch,
            .state = self.state,
            .created_revision = self.created_revision,
            .resource_version = self.resource_version,
        };
    }
};

pub const Request = struct {
    request_id: []u8,
    kind: RequestKind,
    fingerprint: Fingerprint,
    encoded_response: []u8,
    encoded_command: []u8,
    applied_revision: u64,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.encoded_response);
        allocator.free(self.encoded_command);
        self.* = undefined;
    }
};

pub const State = struct {
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
    allocation_ids_by_replica: std.StringHashMapUnmanaged([]const u8) = .empty,
    volume_attachments_by_id: std.StringHashMapUnmanaged(VolumeAttachment) = .empty,
    attachment_ids_by_volume_consumer: std.StringHashMapUnmanaged([]const u8) = .empty,
    primary_authorities_by_volume: std.StringHashMapUnmanaged(PrimaryAuthority) = .empty,
    primary_authority_candidates_by_volume: std.StringHashMapUnmanaged(PrimaryAuthority) = .empty,
    primary_failovers_by_volume: std.StringHashMapUnmanaged(PrimaryFailover) = .empty,
    requests: std.StringHashMapUnmanaged(Request) = .empty,
    max_pool_created_revision: u64 = 0,
    max_node_registered_revision: u64 = 0,
    max_member_registered_revision: u64 = 0,
    max_volume_created_revision: u64 = 0,
    max_volume_deleted_revision: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var request_iterator = self.requests.valueIterator();
        while (request_iterator.next()) |request| request.deinit(allocator);
        self.requests.deinit(allocator);

        var failover_iterator = self.primary_failovers_by_volume.valueIterator();
        while (failover_iterator.next()) |failover| failover.deinit(allocator);
        self.primary_failovers_by_volume.deinit(allocator);

        var candidate_iterator = self.primary_authority_candidates_by_volume.valueIterator();
        while (candidate_iterator.next()) |authority| authority.deinit(allocator);
        self.primary_authority_candidates_by_volume.deinit(allocator);

        var authority_iterator = self.primary_authorities_by_volume.valueIterator();
        while (authority_iterator.next()) |authority| authority.deinit(allocator);
        self.primary_authorities_by_volume.deinit(allocator);

        self.attachment_ids_by_volume_consumer.deinit(allocator);
        var attachment_iterator = self.volume_attachments_by_id.valueIterator();
        while (attachment_iterator.next()) |attachment| attachment.deinit(allocator);
        self.volume_attachments_by_id.deinit(allocator);

        self.allocation_ids_by_replica.deinit(allocator);
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

pub fn scopedKey(prefix: []const u8, suffix: []const u8, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= prefix.len + 1 + suffix.len);
    @memcpy(buffer[0..prefix.len], prefix);
    buffer[prefix.len] = 0;
    @memcpy(buffer[prefix.len + 1 .. prefix.len + 1 + suffix.len], suffix);
    return buffer[0 .. prefix.len + 1 + suffix.len];
}

pub fn makeScopedKey(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, prefix.len + 1 + suffix.len);
    _ = scopedKey(prefix, suffix, result);
    return result;
}

pub fn replicaKey(volume_id: []const u8, replica_index: u32, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= volume_id.len + 1 and replica_index < volume_target_replica_count);
    @memcpy(buffer[0..volume_id.len], volume_id);
    buffer[volume_id.len] = @intCast(replica_index);
    return buffer[0 .. volume_id.len + 1];
}

pub fn makeReplicaKey(allocator: std.mem.Allocator, volume_id: []const u8, replica_index: u32) ![]u8 {
    const result = try allocator.alloc(u8, volume_id.len + 1);
    _ = replicaKey(volume_id, replica_index, result);
    return result;
}
