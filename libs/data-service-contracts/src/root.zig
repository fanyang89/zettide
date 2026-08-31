const std = @import("std");
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
pub const write_evidence_contract = @import("write_evidence_contract.zig");
pub const write_evidence = @import("write_evidence.zig");
pub const write_coordinator = @import("write_coordinator.zig");
pub const primary_lease = @import("primary_lease.zig");
pub const authority_contract = @import("authority_contract.zig");

test {
    _ = replica_service;
    _ = fence_service;
    _ = write_service;
    _ = write_evidence;
    _ = write_coordinator;
    _ = primary_lease;
    _ = authority_contract;
}

fn evidenceTestId(value: u8) Id {
    var id: Id = @splat(0);
    id[15] = value;
    return id;
}

test "Signer transcripts are binary-compatible with cycle-free participant verification" {
    const first = try write_evidence.Signer.init(std.testing.allocator, evidenceTestId(1), evidenceTestId(31), &@as(write_evidence.Seed, @splat(0x11)));
    defer first.deinit();
    const second = try write_evidence.Signer.init(std.testing.allocator, evidenceTestId(2), evidenceTestId(32), &@as(write_evidence.Seed, @splat(0x22)));
    defer second.deinit();
    const third = try write_evidence.Signer.init(std.testing.allocator, evidenceTestId(3), evidenceTestId(33), &@as(write_evidence.Seed, @splat(0x33)));
    defer third.deinit();
    const identities = [3]write_service.WitnessIdentity{ first.identity(), second.identity(), third.identity() };
    const write: write_service.WriteRequest = .{
        .authority = .{
            .volume_id = evidenceTestId(10),
            .primary_placement_id = evidenceTestId(11),
            .primary_node_id = evidenceTestId(12),
            .lease_id = evidenceTestId(13),
            .holder_boot_id = evidenceTestId(14),
            .authority_generation = 1,
            .write_epoch = 1,
            .placement_revision = 1,
            .activation_nonce = evidenceTestId(15),
            .authority_digest = @splat(0x41),
        },
        .replica_members = write_evidence_contract.members(identities),
        .sequence = 1,
        .transaction_id = evidenceTestId(20),
        .previous_history_digest = @splat(0),
        .offset_bytes = 0,
        .length_bytes = 4096,
        .data_digest = @splat(0x42),
    };
    const transaction_digest = write_service.digestTransaction(write);
    const prepared_history = write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest);
    const first_attestation: write_service.PrepareAttestation = .{
        .member_id = identities[0].member_id,
        .transaction_digest = transaction_digest,
        .prepare_digest = @splat(0x51),
        .prepared_history_digest = prepared_history,
    };
    const second_attestation: write_service.PrepareAttestation = .{
        .member_id = identities[1].member_id,
        .transaction_digest = transaction_digest,
        .prepare_digest = @splat(0x52),
        .prepared_history_digest = prepared_history,
    };
    const first_evidence = try first.signPrepare(write, first_attestation);
    const second_evidence = try second.signPrepare(write, second_attestation);
    const signed: write_service.SignedCommitCertificate = .{ .prepare_evidence = .{ first_evidence, second_evidence } };
    _ = try write_evidence_contract.verifySignedCertificate(identities, write, first_attestation, signed);

    const certificate = try write_service.makeCommitCertificate(
        .{ first_attestation, second_attestation },
        transaction_digest,
        prepared_history,
        write.replica_members,
    );
    const result: write_service.CommitResult = .{
        .transaction_id = write.transaction_id,
        .sequence = write.sequence,
        .history_digest = write_service.digestCommitHistory(prepared_history, certificate),
    };
    const commit_evidence = try first.signCommit(write, certificate, result);
    try write_evidence_contract.verifyCommit(identities[0], write, certificate, commit_evidence);
}
