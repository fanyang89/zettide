const std = @import("std");
const model = @import("model.zig");

pub const Id = model.Id;
pub const Digest = model.Digest;
pub const AuthorityBinding = model.AuthorityBinding;
pub const PublicKey = [32]u8;
pub const KeyId = [32]u8;
pub const Signature = [64]u8;
pub const certificate_witness_count: usize = 2;

const Ed25519 = std.crypto.sign.Ed25519;
const protocol_version: u16 = 1;

pub const WriteRequest = struct {
    authority: AuthorityBinding,
    replica_members: [3]Id,
    sequence: u64,
    transaction_id: Id,
    previous_history_digest: Digest,
    offset_bytes: u64,
    length_bytes: u64,
    data_digest: Digest,
};

pub const PrepareAttestation = struct {
    member_id: Id,
    transaction_digest: Digest,
    prepare_digest: Digest,
    prepared_history_digest: Digest,
};

pub const CommitCertificate = struct {
    attestations: [certificate_witness_count]PrepareAttestation,
};

pub const CommitResult = struct {
    transaction_id: Id,
    sequence: u64,
    history_digest: Digest,
};

pub const WitnessIdentity = struct {
    member_id: Id = @splat(0),
    node_id: Id = @splat(0),
    key_id: KeyId = @splat(0),
    public_key: PublicKey = @splat(0),
};

pub const SignedPrepareEvidence = struct {
    attestation: PrepareAttestation,
    signer_node_id: Id,
    key_id: KeyId,
    signature: Signature,
};

pub const SignedCommitEvidence = struct {
    member_id: Id,
    signer_node_id: Id,
    key_id: KeyId,
    result: CommitResult,
    signature: Signature,
};

/// The durable participant decision. The unsigned certificate is a canonical
/// projection of these two independently verifiable signed PREPARE records.
pub const SignedCommitCertificate = struct {
    prepare_evidence: [certificate_witness_count]SignedPrepareEvidence,
};

pub fn keyId(public_key: PublicKey) KeyId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-write-evidence-key-id-v1");
    hashField(&hasher, &public_key);
    var result: KeyId = undefined;
    hasher.final(&result);
    return result;
}

pub fn validateIdentity(identity: WitnessIdentity) !void {
    if (isZero(&identity.member_id) or isZero(&identity.node_id) or
        isZero(&identity.key_id) or isZero(&identity.public_key) or
        !std.mem.eql(u8, &identity.key_id, &keyId(identity.public_key)))
        return error.InvalidWitnessIdentity;
    _ = Ed25519.PublicKey.fromBytes(identity.public_key) catch return error.InvalidWitnessIdentity;
    const point = Ed25519.Curve.fromBytes(identity.public_key) catch return error.InvalidWitnessIdentity;
    point.rejectIdentity() catch return error.InvalidWitnessIdentity;
    point.rejectUnexpectedSubgroup() catch return error.InvalidWitnessIdentity;
}

pub fn validateIdentities(identities: [3]WitnessIdentity) !void {
    for (identities, 0..) |identity, index| {
        try validateIdentity(identity);
        if (index != 0 and std.mem.order(u8, &identities[index - 1].member_id, &identity.member_id) != .lt)
            return error.InvalidReplicaSet;
        for (identities[0..index]) |previous| {
            if (std.mem.eql(u8, &previous.node_id, &identity.node_id)) return error.DuplicateSignerNode;
            if (std.mem.eql(u8, &previous.key_id, &identity.key_id) or
                std.mem.eql(u8, &previous.public_key, &identity.public_key)) return error.DuplicateSigningKey;
        }
    }
}

pub fn members(identities: [3]WitnessIdentity) [3]Id {
    return .{ identities[0].member_id, identities[1].member_id, identities[2].member_id };
}

pub fn identityForMember(identities: [3]WitnessIdentity, member_id: Id) ?WitnessIdentity {
    for (identities) |identity| if (std.mem.eql(u8, &identity.member_id, &member_id)) return identity;
    return null;
}

pub fn normalizeSignedCertificate(input: SignedCommitCertificate) !SignedCommitCertificate {
    var result = input;
    if (std.mem.order(u8, &result.prepare_evidence[1].attestation.member_id, &result.prepare_evidence[0].attestation.member_id) == .lt)
        std.mem.swap(SignedPrepareEvidence, &result.prepare_evidence[0], &result.prepare_evidence[1]);
    if (std.mem.order(u8, &result.prepare_evidence[0].attestation.member_id, &result.prepare_evidence[1].attestation.member_id) != .lt)
        return error.DuplicateWitness;
    return result;
}

pub fn certificateProjection(input: SignedCommitCertificate) !CommitCertificate {
    const signed = try normalizeSignedCertificate(input);
    return .{ .attestations = .{ signed.prepare_evidence[0].attestation, signed.prepare_evidence[1].attestation } };
}

pub fn verifySignedCertificate(
    identities: [3]WitnessIdentity,
    write: WriteRequest,
    local: PrepareAttestation,
    input: SignedCommitCertificate,
) !SignedCommitCertificate {
    try validateIdentities(identities);
    if (!std.meta.eql(members(identities), write.replica_members)) return error.EvidenceIdentityMismatch;
    const signed = try normalizeSignedCertificate(input);
    const projection = try makeCommitCertificate(
        .{ signed.prepare_evidence[0].attestation, signed.prepare_evidence[1].attestation },
        digestTransaction(write),
        digestPreparedHistory(write.previous_history_digest, digestTransaction(write)),
        write.replica_members,
    );
    var local_found = false;
    for (signed.prepare_evidence) |evidence| {
        const identity = identityForMember(identities, evidence.attestation.member_id) orelse
            return error.CertificateMemberNotEligible;
        try verifyPrepare(identity, write, evidence);
        if (std.mem.eql(u8, &evidence.attestation.member_id, &local.member_id)) {
            local_found = true;
            if (!std.meta.eql(evidence.attestation, local)) return error.CertificateMismatch;
        }
    }
    if (!local_found) return error.LocalWitnessMissing;
    _ = projection;
    return signed;
}

pub fn verifyPrepare(identity: WitnessIdentity, write: WriteRequest, evidence: SignedPrepareEvidence) !void {
    try validateIdentity(identity);
    if (!std.mem.eql(u8, &identity.node_id, &evidence.signer_node_id) or
        !std.mem.eql(u8, &identity.key_id, &evidence.key_id)) return error.EvidenceIdentityMismatch;
    try validatePrepareEnvelope(identity, write, evidence.attestation);
    try verifySignature(identity.public_key, prepareTranscript(identity, write, evidence.attestation), evidence.signature);
}

pub fn verifyCommit(identity: WitnessIdentity, write: WriteRequest, certificate: CommitCertificate, evidence: SignedCommitEvidence) !void {
    try validateIdentity(identity);
    if (!std.mem.eql(u8, &identity.member_id, &evidence.member_id) or
        !std.mem.eql(u8, &identity.node_id, &evidence.signer_node_id) or
        !std.mem.eql(u8, &identity.key_id, &evidence.key_id)) return error.EvidenceIdentityMismatch;
    try validateCommitEnvelope(identity, write, certificate, evidence.result);
    try verifySignature(identity.public_key, commitTranscript(identity, write, certificate, evidence.result), evidence.signature);
}

fn verifySignature(public_key_bytes: PublicKey, transcript: [64]u8, signature_bytes: Signature) !void {
    const public_key = Ed25519.PublicKey.fromBytes(public_key_bytes) catch return error.InvalidEvidencePublicKey;
    const signature = Ed25519.Signature.fromBytes(signature_bytes);
    signature.verifyStrict(&transcript, public_key) catch return error.InvalidEvidenceSignature;
}

fn validatePrepareEnvelope(identity: WitnessIdentity, write: WriteRequest, attestation: PrepareAttestation) !void {
    const transaction_digest = digestTransaction(write);
    const prepared_history_digest = digestPreparedHistory(write.previous_history_digest, transaction_digest);
    if (isZero(&attestation.member_id) or isZero(&attestation.transaction_digest) or
        isZero(&attestation.prepare_digest) or isZero(&attestation.prepared_history_digest) or
        !std.mem.eql(u8, &identity.member_id, &attestation.member_id) or
        !std.mem.eql(u8, &transaction_digest, &attestation.transaction_digest) or
        !std.mem.eql(u8, &prepared_history_digest, &attestation.prepared_history_digest))
        return error.PrepareEvidenceMismatch;
}

fn validateCommitEnvelope(identity: WitnessIdentity, write: WriteRequest, certificate: CommitCertificate, result: CommitResult) !void {
    const transaction_digest = digestTransaction(write);
    const prepared_history_digest = digestPreparedHistory(write.previous_history_digest, transaction_digest);
    const canonical = makeCommitCertificate(certificate.attestations, transaction_digest, prepared_history_digest, write.replica_members) catch
        return error.CommitEvidenceMismatch;
    if (!std.meta.eql(canonical, certificate)) return error.CommitEvidenceMismatch;
    var member_found = false;
    for (certificate.attestations) |attestation| if (std.mem.eql(u8, &attestation.member_id, &identity.member_id)) {
        member_found = true;
        break;
    };
    const expected_history = digestCommitHistory(prepared_history_digest, certificate);
    if (!member_found or isZero(&result.transaction_id) or result.sequence == 0 or isZero(&result.history_digest) or
        !std.mem.eql(u8, &result.transaction_id, &write.transaction_id) or result.sequence != write.sequence or
        !std.mem.eql(u8, &result.history_digest, &expected_history)) return error.CommitEvidenceMismatch;
}

pub fn makeCommitCertificate(attestations: [2]PrepareAttestation, transaction_digest: Digest, prepared_history_digest: Digest, replica_members: [3]Id) !CommitCertificate {
    for (replica_members, 0..) |member, index| {
        if (isZero(&member) or (index != 0 and std.mem.order(u8, &replica_members[index - 1], &member) != .lt))
            return error.InvalidReplicaSet;
    }
    var certificate = CommitCertificate{ .attestations = attestations };
    if (std.mem.order(u8, &certificate.attestations[1].member_id, &certificate.attestations[0].member_id) == .lt)
        std.mem.swap(PrepareAttestation, &certificate.attestations[0], &certificate.attestations[1]);
    const first = certificate.attestations[0];
    const second = certificate.attestations[1];
    if (isZero(&transaction_digest) or isZero(&prepared_history_digest) or isZero(&first.member_id) or
        isZero(&second.member_id) or isZero(&first.prepare_digest) or isZero(&second.prepare_digest) or
        std.mem.order(u8, &first.member_id, &second.member_id) != .lt) return error.InvalidCertificate;
    for (certificate.attestations) |attestation| {
        var eligible = false;
        for (replica_members) |member| if (std.mem.eql(u8, &member, &attestation.member_id)) {
            eligible = true;
            break;
        };
        if (!eligible) return error.CertificateMemberNotEligible;
        if (!std.mem.eql(u8, &attestation.transaction_digest, &transaction_digest) or
            !std.mem.eql(u8, &attestation.prepared_history_digest, &prepared_history_digest)) return error.CertificateMismatch;
    }
    return certificate;
}

pub fn digestTransaction(write: WriteRequest) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-replica-write-transaction-v1");
    hashAuthority(&hasher, write.authority);
    for (write.replica_members) |member| hashField(&hasher, &member);
    hashU64(&hasher, write.sequence);
    hashField(&hasher, &write.transaction_id);
    hashField(&hasher, &write.previous_history_digest);
    hashU64(&hasher, write.offset_bytes);
    hashU64(&hasher, write.length_bytes);
    hashField(&hasher, &write.data_digest);
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn digestPreparedHistory(previous: Digest, transaction: Digest) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-replica-write-prepared-history-v1");
    hashField(&hasher, &previous);
    hashField(&hasher, &transaction);
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn digestCommitHistory(prepared_history: Digest, certificate: CommitCertificate) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-replica-write-commit-history-v1");
    hashField(&hasher, &prepared_history);
    for (certificate.attestations) |attestation| {
        hashField(&hasher, &attestation.member_id);
        hashField(&hasher, &attestation.prepare_digest);
    }
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn prepareTranscript(identity: WitnessIdentity, write: WriteRequest, attestation: PrepareAttestation) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha512.init(.{});
    hashField(&hasher, "zettide-write-prepare-evidence-v1");
    hashU16(&hasher, protocol_version);
    hashIdentity(&hasher, identity);
    hashField(&hasher, &digestTransaction(write));
    hashAttestation(&hasher, attestation);
    var result: [64]u8 = undefined;
    hasher.final(&result);
    return result;
}

pub fn commitTranscript(identity: WitnessIdentity, write: WriteRequest, certificate: CommitCertificate, result: CommitResult) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha512.init(.{});
    hashField(&hasher, "zettide-write-commit-evidence-v1");
    hashU16(&hasher, protocol_version);
    hashIdentity(&hasher, identity);
    hashField(&hasher, &digestTransaction(write));
    for (certificate.attestations) |attestation| hashAttestation(&hasher, attestation);
    hashField(&hasher, &result.transaction_id);
    hashU64(&hasher, result.sequence);
    hashField(&hasher, &result.history_digest);
    var result_bytes: [64]u8 = undefined;
    hasher.final(&result_bytes);
    return result_bytes;
}

fn hashAuthority(hasher: anytype, authority: AuthorityBinding) void {
    hashField(hasher, &authority.volume_id);
    hashField(hasher, &authority.primary_placement_id);
    hashField(hasher, &authority.primary_node_id);
    hashField(hasher, &authority.lease_id);
    hashField(hasher, &authority.holder_boot_id);
    hashU64(hasher, authority.authority_generation);
    hashU64(hasher, authority.write_epoch);
    hashU64(hasher, authority.placement_revision);
    hashField(hasher, &authority.activation_nonce);
    hashField(hasher, &authority.authority_digest);
}
fn hashIdentity(hasher: anytype, identity: WitnessIdentity) void {
    hashField(hasher, &identity.node_id);
    hashField(hasher, &identity.member_id);
    hashField(hasher, &identity.key_id);
    hashField(hasher, &identity.public_key);
}
fn hashAttestation(hasher: anytype, attestation: PrepareAttestation) void {
    hashField(hasher, &attestation.member_id);
    hashField(hasher, &attestation.transaction_digest);
    hashField(hasher, &attestation.prepare_digest);
    hashField(hasher, &attestation.prepared_history_digest);
}
fn hashField(hasher: anytype, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    hasher.update(&length);
    hasher.update(bytes);
}
fn hashU16(hasher: anytype, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hasher.update(&bytes);
}
fn hashU64(hasher: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}
fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
