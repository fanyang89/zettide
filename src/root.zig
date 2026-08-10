pub const Id = [16]u8;
pub const Digest = [32]u8;

pub const ReplicaState = enum {
    active,
    tombstoned,
};

pub const ReplicaRequest = struct {
    operation_id: []const u8,
    volume_id: []const u8,
    placement_id: []const u8,
    allocation_id: []const u8,
    generation: u64,
    member_id: []const u8,
    offset_bytes: u64,
    length_bytes: u64,
};

pub const ReplicaBinding = struct {
    volume_id: Id,
    placement_id: Id,
    allocation_id: Id,
    generation: u64,
    member_id: Id,
    offset_bytes: u64,
    length_bytes: u64,
};

pub const ReplicaAttestation = struct {
    binding: ReplicaBinding,
    backend_digest: Digest,
};

pub const Replica = struct {
    state: ReplicaState,
    attestation: ReplicaAttestation,
};

pub const ReplicaResponse = struct {
    operation_id: Id,
    replica: Replica,
};

pub const AuthorityBinding = struct {
    volume_id: Id,
    primary_placement_id: Id,
    primary_node_id: Id,
    lease_id: Id,
    holder_boot_id: Id,
    authority_generation: u64,
    write_epoch: u64,
    placement_revision: u64,
    activation_nonce: Id,
    authority_digest: Digest,
};

pub const StageRequest = struct {
    binding: AuthorityBinding,
    lease_duration_ms: u32,
};

pub const StageAck = struct {
    request: StageRequest,
};

pub const RecoveryRequest = struct {
    binding: AuthorityBinding,
};

pub const RecoveryResult = struct {
    request: RecoveryRequest,
    certified_sequence: u64,
    history_digest: Digest,
    empty_frontier: bool,
};

pub const MarkReadyRequest = struct {
    binding: AuthorityBinding,
};

pub const PrimaryLeaseStatus = struct {
    request: MarkReadyRequest,
    current_active: bool,
    current_admitting: bool,
    candidate_fresh: bool,
    should_renew: bool,
};

pub const FenceBinding = struct {
    operation_id: Id,
    volume_id: Id,
    placement_id: Id,
    replica_generation: u64,
    write_epoch: u64,
    primary_node_id: Id,
    lease_id: Id,
    authority_digest: Digest,
};

pub const FenceResult = struct {
    binding: FenceBinding,
    fence_digest: Digest,
};

pub const primary_lease = @import("primary_lease.zig");

test {
    _ = primary_lease;
}
