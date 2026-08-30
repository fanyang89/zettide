const model = @import("model.zig");

pub const Id = model.Id;
pub const Digest = model.Digest;
pub const ReplicaState = model.ReplicaState;
pub const ReplicaRequest = model.ReplicaRequest;
pub const ReplicaBinding = model.ReplicaBinding;
pub const ReplicaAttestation = model.ReplicaAttestation;
pub const Replica = model.Replica;
pub const ReplicaResponse = model.ReplicaResponse;
pub const AuthorityBinding = model.AuthorityBinding;
pub const StageRequest = model.StageRequest;
pub const StageAck = model.StageAck;
pub const RecoveryRequest = model.RecoveryRequest;
pub const RecoveryResult = model.RecoveryResult;
pub const MarkReadyRequest = model.MarkReadyRequest;
pub const PrimaryLeaseStatus = model.PrimaryLeaseStatus;
pub const FenceBinding = model.FenceBinding;
pub const FenceResult = model.FenceResult;

pub const replica_service = @import("replica_service.zig");
pub const fence_service = @import("fence_service.zig");
pub const write_service = @import("write_service.zig");
pub const write_coordinator = @import("write_coordinator.zig");
pub const primary_lease = @import("primary_lease.zig");

test {
    _ = replica_service;
    _ = fence_service;
    _ = write_service;
    _ = write_coordinator;
    _ = primary_lease;
}
