const std = @import("std");
const model = @import("model.zig");
const write_service = @import("write_service.zig");
const contract = @import("write_evidence_contract.zig");

pub const Id = model.Id;
pub const Digest = model.Digest;
pub const PublicKey = contract.PublicKey;
pub const KeyId = contract.KeyId;
pub const Signature = contract.Signature;
pub const Seed = [32]u8;

const Ed25519 = std.crypto.sign.Ed25519;
const protocol_version: u16 = 1;

pub const WitnessIdentity = contract.WitnessIdentity;
pub const SignedPrepareEvidence = contract.SignedPrepareEvidence;
pub const SignedCommitEvidence = contract.SignedCommitEvidence;
pub const SignedCommitCertificate = contract.SignedCommitCertificate;

/// Seed-owning Ed25519 signer. The caller retains responsibility for scrubbing
/// its source seed; this object never exposes private bytes and scrubs its copy.
pub const Signer = opaque {
    pub fn init(
        allocator: std.mem.Allocator,
        member_id: Id,
        node_id: Id,
        seed_input: Seed,
    ) !*Signer {
        if (isZero(&member_id) or isZero(&node_id) or isZero(&seed_input)) return error.InvalidSigningIdentity;
        var seed = seed_input;
        errdefer std.crypto.secureZero(u8, &seed);
        var key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&key_pair));
        const public_key = key_pair.public_key.toBytes();
        const witness_identity: WitnessIdentity = .{
            .member_id = member_id,
            .node_id = node_id,
            .key_id = keyId(public_key),
            .public_key = public_key,
        };
        try validateIdentity(witness_identity);
        const inner = try allocator.create(SignerInner);
        inner.* = .{ .allocator = allocator, .seed = seed, .identity = witness_identity };
        seed = @splat(0);
        return @ptrCast(inner);
    }

    pub fn deinit(self: *Signer) void {
        const inner: *SignerInner = @ptrCast(@alignCast(self));
        const allocator = inner.allocator;
        std.crypto.secureZero(u8, &inner.seed);
        inner.* = undefined;
        allocator.destroy(inner);
    }

    pub fn identity(self: *const Signer) WitnessIdentity {
        const inner: *const SignerInner = @ptrCast(@alignCast(self));
        return inner.identity;
    }

    pub fn signPrepare(
        self: *const Signer,
        write: write_service.WriteRequest,
        attestation: write_service.PrepareAttestation,
    ) !SignedPrepareEvidence {
        const inner: *const SignerInner = @ptrCast(@alignCast(self));
        try validatePrepareEnvelope(inner.identity, write, attestation);
        const transcript = prepareTranscript(inner.identity, write, attestation);
        return .{
            .attestation = attestation,
            .signer_node_id = inner.identity.node_id,
            .key_id = inner.identity.key_id,
            .signature = try inner.sign(&transcript),
        };
    }

    pub fn signCommit(
        self: *const Signer,
        write: write_service.WriteRequest,
        certificate: write_service.CommitCertificate,
        result: write_service.CommitResult,
    ) !SignedCommitEvidence {
        const inner: *const SignerInner = @ptrCast(@alignCast(self));
        try validateCommitEnvelope(inner.identity, write, certificate, result);
        const transcript = commitTranscript(inner.identity, write, certificate, result);
        return .{
            .member_id = inner.identity.member_id,
            .signer_node_id = inner.identity.node_id,
            .key_id = inner.identity.key_id,
            .result = result,
            .signature = try inner.sign(&transcript),
        };
    }
};

const SignerInner = struct {
    allocator: std.mem.Allocator,
    seed: Seed,
    identity: WitnessIdentity,

    fn sign(self: *const SignerInner, transcript: *const [64]u8) !Signature {
        var key_pair = try Ed25519.KeyPair.generateDeterministic(self.seed);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&key_pair));
        const signature = try key_pair.sign(transcript, null);
        return signature.toBytes();
    }
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
    var member_ids: [3]Id = undefined;
    for (identities, 0..) |identity, index| {
        try validateIdentity(identity);
        member_ids[index] = identity.member_id;
        for (identities[0..index]) |previous| {
            if (std.mem.eql(u8, &previous.node_id, &identity.node_id)) return error.DuplicateSignerNode;
            if (std.mem.eql(u8, &previous.key_id, &identity.key_id)) return error.DuplicateSigningKey;
            if (std.mem.eql(u8, &previous.public_key, &identity.public_key)) return error.DuplicateSigningKey;
        }
    }
    try write_service.validateCanonicalReplicaMembers(member_ids);
}

pub fn members(identities: [3]WitnessIdentity) [3]Id {
    return .{ identities[0].member_id, identities[1].member_id, identities[2].member_id };
}

pub fn identityForMember(identities: [3]WitnessIdentity, member_id: Id) ?WitnessIdentity {
    for (identities) |identity| if (std.mem.eql(u8, &identity.member_id, &member_id)) return identity;
    return null;
}

pub fn verifyPrepare(
    identity: WitnessIdentity,
    write: write_service.WriteRequest,
    evidence: SignedPrepareEvidence,
) !void {
    try validateIdentity(identity);
    if (!std.mem.eql(u8, &identity.node_id, &evidence.signer_node_id) or
        !std.mem.eql(u8, &identity.key_id, &evidence.key_id))
        return error.EvidenceIdentityMismatch;
    try validatePrepareEnvelope(identity, write, evidence.attestation);
    const transcript = prepareTranscript(identity, write, evidence.attestation);
    try verifySignature(identity.public_key, transcript, evidence.signature);
}

pub fn verifyCommit(
    identity: WitnessIdentity,
    write: write_service.WriteRequest,
    certificate: write_service.CommitCertificate,
    evidence: SignedCommitEvidence,
) !void {
    try validateIdentity(identity);
    if (!std.mem.eql(u8, &identity.member_id, &evidence.member_id) or
        !std.mem.eql(u8, &identity.node_id, &evidence.signer_node_id) or
        !std.mem.eql(u8, &identity.key_id, &evidence.key_id))
        return error.EvidenceIdentityMismatch;
    try validateCommitEnvelope(identity, write, certificate, evidence.result);
    const transcript = commitTranscript(identity, write, certificate, evidence.result);
    try verifySignature(identity.public_key, transcript, evidence.signature);
}

fn verifySignature(public_key_bytes: PublicKey, transcript: [64]u8, signature_bytes: Signature) !void {
    const public_key = Ed25519.PublicKey.fromBytes(public_key_bytes) catch return error.InvalidEvidencePublicKey;
    const signature = Ed25519.Signature.fromBytes(signature_bytes);
    signature.verifyStrict(&transcript, public_key) catch return error.InvalidEvidenceSignature;
}

fn validatePrepareEnvelope(
    identity: WitnessIdentity,
    write: write_service.WriteRequest,
    attestation: write_service.PrepareAttestation,
) !void {
    const transaction_digest = write_service.digestTransaction(write);
    const prepared_history_digest = write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest);
    if (isZero(&attestation.member_id) or isZero(&attestation.transaction_digest) or
        isZero(&attestation.prepare_digest) or isZero(&attestation.prepared_history_digest) or
        !std.mem.eql(u8, &identity.member_id, &attestation.member_id) or
        !std.mem.eql(u8, &transaction_digest, &attestation.transaction_digest) or
        !std.mem.eql(u8, &prepared_history_digest, &attestation.prepared_history_digest))
        return error.PrepareEvidenceMismatch;
}

fn validateCommitEnvelope(
    identity: WitnessIdentity,
    write: write_service.WriteRequest,
    certificate: write_service.CommitCertificate,
    result: write_service.CommitResult,
) !void {
    const transaction_digest = write_service.digestTransaction(write);
    const prepared_history_digest = write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest);
    const canonical = write_service.makeCommitCertificate(
        certificate.attestations,
        transaction_digest,
        prepared_history_digest,
        write.replica_members,
    ) catch return error.CommitEvidenceMismatch;
    if (!std.meta.eql(canonical, certificate)) return error.CommitEvidenceMismatch;
    var member_found = false;
    for (certificate.attestations) |attestation| if (std.mem.eql(u8, &attestation.member_id, &identity.member_id)) {
        member_found = true;
        break;
    };
    const expected_history = write_service.digestCommitHistory(prepared_history_digest, certificate);
    if (!member_found or isZero(&result.transaction_id) or result.sequence == 0 or isZero(&result.history_digest) or
        !std.mem.eql(u8, &result.transaction_id, &write.transaction_id) or result.sequence != write.sequence or
        !std.mem.eql(u8, &result.history_digest, &expected_history))
        return error.CommitEvidenceMismatch;
}

fn prepareTranscript(
    identity: WitnessIdentity,
    write: write_service.WriteRequest,
    attestation: write_service.PrepareAttestation,
) [64]u8 {
    return prepareTranscriptWithParameters(
        "zettide-write-prepare-evidence-v1",
        protocol_version,
        identity,
        write,
        attestation,
    );
}

fn prepareTranscriptWithParameters(
    domain: []const u8,
    version: u16,
    identity: WitnessIdentity,
    write: write_service.WriteRequest,
    attestation: write_service.PrepareAttestation,
) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha512.init(.{});
    hashField(&hasher, domain);
    hashU16(&hasher, version);
    hashIdentity(&hasher, identity);
    hashField(&hasher, &write_service.digestTransaction(write));
    hashAttestation(&hasher, attestation);
    var result: [64]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn commitTranscript(
    identity: WitnessIdentity,
    write: write_service.WriteRequest,
    certificate: write_service.CommitCertificate,
    result_value: write_service.CommitResult,
) [64]u8 {
    return commitTranscriptWithParameters(
        "zettide-write-commit-evidence-v1",
        protocol_version,
        identity,
        write,
        certificate,
        result_value,
    );
}

fn commitTranscriptWithParameters(
    domain: []const u8,
    version: u16,
    identity: WitnessIdentity,
    write: write_service.WriteRequest,
    certificate: write_service.CommitCertificate,
    result_value: write_service.CommitResult,
) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha512.init(.{});
    hashField(&hasher, domain);
    hashU16(&hasher, version);
    hashIdentity(&hasher, identity);
    hashField(&hasher, &write_service.digestTransaction(write));
    hashCertificate(&hasher, certificate);
    hashField(&hasher, &result_value.transaction_id);
    hashU64(&hasher, result_value.sequence);
    hashField(&hasher, &result_value.history_digest);
    var result: [64]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn hashIdentity(hasher: anytype, identity: WitnessIdentity) void {
    hashField(hasher, &identity.node_id);
    hashField(hasher, &identity.member_id);
    hashField(hasher, &identity.key_id);
    hashField(hasher, &identity.public_key);
}

fn hashAttestation(hasher: anytype, attestation: write_service.PrepareAttestation) void {
    hashField(hasher, &attestation.member_id);
    hashField(hasher, &attestation.transaction_digest);
    hashField(hasher, &attestation.prepare_digest);
    hashField(hasher, &attestation.prepared_history_digest);
}

fn hashCertificate(hasher: anytype, certificate: write_service.CommitCertificate) void {
    for (certificate.attestations) |attestation| hashAttestation(hasher, attestation);
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
    var combined: u8 = 0;
    for (bytes) |byte| combined |= byte;
    return combined == 0;
}

fn testId(value: u8) Id {
    var result: Id = @splat(0);
    result[15] = value;
    return result;
}

fn testWrite() write_service.WriteRequest {
    const member_a = testId(1);
    const member_b = testId(2);
    const member_c = testId(3);
    return .{
        .authority = .{
            .volume_id = testId(10),
            .primary_placement_id = testId(11),
            .primary_node_id = testId(12),
            .lease_id = testId(13),
            .holder_boot_id = testId(14),
            .authority_generation = 1,
            .write_epoch = 1,
            .placement_revision = 1,
            .activation_nonce = testId(15),
            .authority_digest = @splat(0x55),
        },
        .replica_members = .{ member_a, member_b, member_c },
        .sequence = 1,
        .transaction_id = testId(20),
        .previous_history_digest = @splat(0),
        .offset_bytes = 0,
        .length_bytes = 4096,
        .data_digest = @splat(0x44),
    };
}

fn testAttestation(write: write_service.WriteRequest, member_id: Id, salt: u8) write_service.PrepareAttestation {
    const transaction_digest = write_service.digestTransaction(write);
    return .{
        .member_id = member_id,
        .transaction_digest = transaction_digest,
        .prepare_digest = @splat(salt),
        .prepared_history_digest = write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest),
    };
}

fn testCertificate(write: write_service.WriteRequest) write_service.CommitCertificate {
    return write_service.makeCommitCertificate(
        .{ testAttestation(write, testId(1), 1), testAttestation(write, testId(2), 2) },
        write_service.digestTransaction(write),
        write_service.digestPreparedHistory(write.previous_history_digest, write_service.digestTransaction(write)),
        write.replica_members,
    ) catch unreachable;
}

const WriteField = enum {
    authority_volume_id,
    authority_primary_placement_id,
    authority_primary_node_id,
    authority_lease_id,
    authority_holder_boot_id,
    authority_generation,
    authority_write_epoch,
    authority_placement_revision,
    authority_activation_nonce,
    authority_digest,
    replica_member_0,
    replica_member_1,
    replica_member_2,
    sequence,
    transaction_id,
    previous_history_digest,
    offset_bytes,
    length_bytes,
    data_digest,
};

const IdentityField = enum { member_id, node_id, key_id, public_key };
const AttestationField = enum { member_id, transaction_digest, prepare_digest, prepared_history_digest };
const ResultField = enum { transaction_id, sequence, history_digest };

fn mutateIdentity(identity_input: WitnessIdentity, field: IdentityField) WitnessIdentity {
    var identity = identity_input;
    switch (field) {
        .member_id => identity.member_id[0] ^= 1,
        .node_id => identity.node_id[0] ^= 1,
        .key_id => identity.key_id[0] ^= 1,
        .public_key => identity.public_key[0] ^= 1,
    }
    return identity;
}

fn mutateAttestation(
    attestation_input: write_service.PrepareAttestation,
    field: AttestationField,
) write_service.PrepareAttestation {
    var attestation = attestation_input;
    switch (field) {
        .member_id => attestation.member_id[0] ^= 1,
        .transaction_digest => attestation.transaction_digest[0] ^= 1,
        .prepare_digest => attestation.prepare_digest[0] ^= 1,
        .prepared_history_digest => attestation.prepared_history_digest[0] ^= 1,
    }
    return attestation;
}

fn mutateResult(result_input: write_service.CommitResult, field: ResultField) write_service.CommitResult {
    var result = result_input;
    switch (field) {
        .transaction_id => result.transaction_id[0] ^= 1,
        .sequence => result.sequence += 1,
        .history_digest => result.history_digest[0] ^= 1,
    }
    return result;
}

fn mutateWrite(write_input: write_service.WriteRequest, field: WriteField) write_service.WriteRequest {
    var write = write_input;
    switch (field) {
        .authority_volume_id => write.authority.volume_id[0] ^= 1,
        .authority_primary_placement_id => write.authority.primary_placement_id[0] ^= 1,
        .authority_primary_node_id => write.authority.primary_node_id[0] ^= 1,
        .authority_lease_id => write.authority.lease_id[0] ^= 1,
        .authority_holder_boot_id => write.authority.holder_boot_id[0] ^= 1,
        .authority_generation => write.authority.authority_generation += 1,
        .authority_write_epoch => write.authority.write_epoch += 1,
        .authority_placement_revision => write.authority.placement_revision += 1,
        .authority_activation_nonce => write.authority.activation_nonce[0] ^= 1,
        .authority_digest => write.authority.authority_digest[0] ^= 1,
        .replica_member_0 => write.replica_members[0][0] ^= 1,
        .replica_member_1 => write.replica_members[1][0] ^= 1,
        .replica_member_2 => write.replica_members[2][0] ^= 1,
        .sequence => write.sequence += 1,
        .transaction_id => write.transaction_id[0] ^= 1,
        .previous_history_digest => write.previous_history_digest[0] ^= 1,
        .offset_bytes => write.offset_bytes += 4096,
        .length_bytes => write.length_bytes += 4096,
        .data_digest => write.data_digest[0] ^= 1,
    }
    return write;
}

fn testResult(write: write_service.WriteRequest, certificate: write_service.CommitCertificate) write_service.CommitResult {
    const prepared = write_service.digestPreparedHistory(write.previous_history_digest, write_service.digestTransaction(write));
    return .{
        .transaction_id = write.transaction_id,
        .sequence = write.sequence,
        .history_digest = write_service.digestCommitHistory(prepared, certificate),
    };
}

test "prepare transcript directly hashes every identity write and attestation field" {
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer signer.deinit();
    const identity = signer.identity();
    const write = testWrite();
    const attestation = testAttestation(write, identity.member_id, 1);
    const baseline = prepareTranscript(identity, write, attestation);

    inline for (std.meta.tags(IdentityField)) |field|
        try std.testing.expect(!std.mem.eql(u8, &baseline, &prepareTranscript(
            mutateIdentity(identity, field),
            write,
            attestation,
        )));
    inline for (std.meta.tags(WriteField)) |field|
        try std.testing.expect(!std.mem.eql(u8, &baseline, &prepareTranscript(
            identity,
            mutateWrite(write, field),
            attestation,
        )));
    inline for (std.meta.tags(AttestationField)) |field|
        try std.testing.expect(!std.mem.eql(u8, &baseline, &prepareTranscript(
            identity,
            write,
            mutateAttestation(attestation, field),
        )));
}

test "commit transcript directly hashes every identity write certificate and result field" {
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer signer.deinit();
    const identity = signer.identity();
    const write = testWrite();
    const certificate = testCertificate(write);
    const result = testResult(write, certificate);
    const baseline = commitTranscript(identity, write, certificate, result);

    inline for (std.meta.tags(IdentityField)) |field|
        try std.testing.expect(!std.mem.eql(u8, &baseline, &commitTranscript(
            mutateIdentity(identity, field),
            write,
            certificate,
            result,
        )));
    inline for (std.meta.tags(WriteField)) |field|
        try std.testing.expect(!std.mem.eql(u8, &baseline, &commitTranscript(
            identity,
            mutateWrite(write, field),
            certificate,
            result,
        )));
    inline for (0..2) |witness_index| inline for (std.meta.tags(AttestationField)) |field| {
        var mutated = certificate;
        mutated.attestations[witness_index] = mutateAttestation(mutated.attestations[witness_index], field);
        try std.testing.expect(!std.mem.eql(u8, &baseline, &commitTranscript(
            identity,
            write,
            mutated,
            result,
        )));
    };
    inline for (std.meta.tags(ResultField)) |field|
        try std.testing.expect(!std.mem.eql(u8, &baseline, &commitTranscript(
            identity,
            write,
            certificate,
            mutateResult(result, field),
        )));
}

test "parameterized prepare and commit transcripts bind phase domain and protocol version" {
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x51));
    defer signer.deinit();
    const identity = signer.identity();
    const write = testWrite();
    const attestation = testAttestation(write, identity.member_id, 1);
    const certificate = testCertificate(write);
    const result = testResult(write, certificate);

    const prepare = prepareTranscript(identity, write, attestation);
    try std.testing.expectEqualSlices(u8, &prepare, &prepareTranscriptWithParameters(
        "zettide-write-prepare-evidence-v1",
        protocol_version,
        identity,
        write,
        attestation,
    ));
    try std.testing.expect(!std.mem.eql(u8, &prepare, &prepareTranscriptWithParameters(
        "zettide-write-commit-evidence-v1",
        protocol_version,
        identity,
        write,
        attestation,
    )));
    try std.testing.expect(!std.mem.eql(u8, &prepare, &prepareTranscriptWithParameters(
        "zettide-write-prepare-evidence-v1",
        protocol_version + 1,
        identity,
        write,
        attestation,
    )));

    const commit = commitTranscript(identity, write, certificate, result);
    try std.testing.expectEqualSlices(u8, &commit, &commitTranscriptWithParameters(
        "zettide-write-commit-evidence-v1",
        protocol_version,
        identity,
        write,
        certificate,
        result,
    ));
    try std.testing.expect(!std.mem.eql(u8, &commit, &commitTranscriptWithParameters(
        "zettide-write-prepare-evidence-v1",
        protocol_version,
        identity,
        write,
        certificate,
        result,
    )));
    try std.testing.expect(!std.mem.eql(u8, &commit, &commitTranscriptWithParameters(
        "zettide-write-commit-evidence-v1",
        protocol_version + 1,
        identity,
        write,
        certificate,
        result,
    )));
}

test "deterministic Ed25519 prepare and commit evidence verifies strictly" {
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer signer.deinit();
    const write = testWrite();
    const attestation = testAttestation(write, testId(1), 1);
    const prepare = try signer.signPrepare(write, attestation);
    try verifyPrepare(signer.identity(), write, prepare);
    const certificate = testCertificate(write);
    const commit = try signer.signCommit(write, certificate, testResult(write, certificate));
    try verifyCommit(signer.identity(), write, certificate, commit);
    const prepare_again = try signer.signPrepare(write, attestation);
    try std.testing.expect(std.meta.eql(prepare, prepare_again));
}

test "prepare evidence exhaustively binds every identity write attestation and outer field" {
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer signer.deinit();
    const other = try Signer.init(std.testing.allocator, testId(2), testId(32), @splat(0x22));
    defer other.deinit();
    const write = testWrite();
    const prepare = try signer.signPrepare(write, testAttestation(write, testId(1), 1));

    inline for (std.meta.tags(WriteField)) |field| {
        try std.testing.expectError(
            error.PrepareEvidenceMismatch,
            verifyPrepare(signer.identity(), mutateWrite(write, field), prepare),
        );
    }

    inline for (std.meta.tags(IdentityField)) |field| {
        var identity = signer.identity();
        var evidence = prepare;
        const expected = switch (field) {
            .member_id => blk: {
                identity.member_id[0] ^= 1;
                break :blk error.PrepareEvidenceMismatch;
            },
            .node_id => blk: {
                identity.node_id[0] ^= 1;
                break :blk error.EvidenceIdentityMismatch;
            },
            .key_id => blk: {
                identity.key_id[0] ^= 1;
                break :blk error.InvalidWitnessIdentity;
            },
            .public_key => blk: {
                identity.public_key = other.identity().public_key;
                identity.key_id = other.identity().key_id;
                evidence.key_id = identity.key_id;
                break :blk error.InvalidEvidenceSignature;
            },
        };
        try std.testing.expectError(expected, verifyPrepare(identity, write, evidence));
    }

    inline for (std.meta.tags(AttestationField)) |field| {
        var evidence = prepare;
        switch (field) {
            .member_id => evidence.attestation.member_id[0] ^= 1,
            .transaction_digest => evidence.attestation.transaction_digest[0] ^= 1,
            .prepare_digest => evidence.attestation.prepare_digest[0] ^= 1,
            .prepared_history_digest => evidence.attestation.prepared_history_digest[0] ^= 1,
        }
        const expected = if (field == .prepare_digest) error.InvalidEvidenceSignature else error.PrepareEvidenceMismatch;
        try std.testing.expectError(expected, verifyPrepare(signer.identity(), write, evidence));
    }

    const OuterField = enum { signer_node_id, key_id, signature };
    inline for (std.meta.tags(OuterField)) |field| {
        var evidence = prepare;
        switch (field) {
            .signer_node_id => evidence.signer_node_id[0] ^= 1,
            .key_id => evidence.key_id[0] ^= 1,
            .signature => evidence.signature[0] ^= 1,
        }
        const expected = if (field == .signature) error.InvalidEvidenceSignature else error.EvidenceIdentityMismatch;
        try std.testing.expectError(expected, verifyPrepare(signer.identity(), write, evidence));
    }
}

test "commit evidence exhaustively binds every write certificate result and outer field" {
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer signer.deinit();
    const write = testWrite();
    const certificate = testCertificate(write);
    const commit = try signer.signCommit(write, certificate, testResult(write, certificate));

    inline for (std.meta.tags(WriteField)) |field| {
        try std.testing.expectError(
            error.CommitEvidenceMismatch,
            verifyCommit(signer.identity(), mutateWrite(write, field), certificate, commit),
        );
    }

    const CertificateField = enum { member_id, transaction_digest, prepare_digest, prepared_history_digest };
    inline for (0..2) |witness_index| inline for (std.meta.tags(CertificateField)) |field| {
        var mutated = certificate;
        switch (field) {
            .member_id => mutated.attestations[witness_index].member_id[0] ^= 1,
            .transaction_digest => mutated.attestations[witness_index].transaction_digest[0] ^= 1,
            .prepare_digest => mutated.attestations[witness_index].prepare_digest[0] ^= 1,
            .prepared_history_digest => mutated.attestations[witness_index].prepared_history_digest[0] ^= 1,
        }
        try std.testing.expectError(
            error.CommitEvidenceMismatch,
            verifyCommit(signer.identity(), write, mutated, commit),
        );
    };

    inline for (std.meta.tags(ResultField)) |field| {
        var evidence = commit;
        switch (field) {
            .transaction_id => evidence.result.transaction_id[0] ^= 1,
            .sequence => evidence.result.sequence += 1,
            .history_digest => evidence.result.history_digest[0] ^= 1,
        }
        try std.testing.expectError(
            error.CommitEvidenceMismatch,
            verifyCommit(signer.identity(), write, certificate, evidence),
        );
    }

    const OuterField = enum { member_id, signer_node_id, key_id, signature };
    inline for (std.meta.tags(OuterField)) |field| {
        var evidence = commit;
        switch (field) {
            .member_id => evidence.member_id[0] ^= 1,
            .signer_node_id => evidence.signer_node_id[0] ^= 1,
            .key_id => evidence.key_id[0] ^= 1,
            .signature => evidence.signature[0] ^= 1,
        }
        const expected = if (field == .signature) error.InvalidEvidenceSignature else error.EvidenceIdentityMismatch;
        try std.testing.expectError(expected, verifyCommit(signer.identity(), write, certificate, evidence));
    }
}

test "evidence rejects transcript identity key and cross-domain mutations" {
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer signer.deinit();
    const other = try Signer.init(std.testing.allocator, testId(2), testId(32), @splat(0x22));
    defer other.deinit();
    const write = testWrite();
    const attestation = testAttestation(write, testId(1), 1);
    const prepare = try signer.signPrepare(write, attestation);
    var mutated_write = write;
    mutated_write.offset_bytes = 4096;
    try std.testing.expectError(error.PrepareEvidenceMismatch, verifyPrepare(signer.identity(), mutated_write, prepare));
    try std.testing.expectError(error.EvidenceIdentityMismatch, verifyPrepare(other.identity(), write, prepare));
    var bad_key = signer.identity();
    bad_key.key_id[0] ^= 1;
    try std.testing.expectError(error.InvalidWitnessIdentity, verifyPrepare(bad_key, write, prepare));
    var wrong_public_key = signer.identity();
    wrong_public_key.public_key = other.identity().public_key;
    wrong_public_key.key_id = other.identity().key_id;
    var wrong_key_evidence = prepare;
    wrong_key_evidence.key_id = wrong_public_key.key_id;
    try std.testing.expectError(error.InvalidEvidenceSignature, verifyPrepare(wrong_public_key, write, wrong_key_evidence));
    var bad_evidence_key = prepare;
    bad_evidence_key.key_id[0] ^= 1;
    try std.testing.expectError(error.EvidenceIdentityMismatch, verifyPrepare(signer.identity(), write, bad_evidence_key));
    var changed_attestation = prepare;
    changed_attestation.attestation.prepare_digest[0] ^= 1;
    try std.testing.expectError(error.InvalidEvidenceSignature, verifyPrepare(signer.identity(), write, changed_attestation));
    var bad_signature = prepare;
    bad_signature.signature = @splat(0xff);
    try std.testing.expectError(error.InvalidEvidenceSignature, verifyPrepare(signer.identity(), write, bad_signature));
    var bad_node = prepare;
    bad_node.signer_node_id[0] ^= 1;
    try std.testing.expectError(error.EvidenceIdentityMismatch, verifyPrepare(signer.identity(), write, bad_node));
    var weak_identity = signer.identity();
    weak_identity.public_key = @splat(0);
    weak_identity.public_key[0] = 1;
    weak_identity.key_id = keyId(weak_identity.public_key);
    var weak_evidence = prepare;
    weak_evidence.key_id = weak_identity.key_id;
    try std.testing.expectError(error.InvalidWitnessIdentity, verifyPrepare(weak_identity, write, weak_evidence));

    const certificate = testCertificate(write);
    const result = testResult(write, certificate);
    const commit = try signer.signCommit(write, certificate, result);
    var changed_result = commit;
    changed_result.result.history_digest[0] ^= 1;
    try std.testing.expectError(error.CommitEvidenceMismatch, verifyCommit(signer.identity(), write, certificate, changed_result));
    var changed_certificate = certificate;
    changed_certificate.attestations[1].prepare_digest[0] ^= 1;
    try std.testing.expectError(error.CommitEvidenceMismatch, verifyCommit(signer.identity(), write, changed_certificate, commit));
    var cross_domain = commit;
    cross_domain.signature = prepare.signature;
    try std.testing.expectError(error.InvalidEvidenceSignature, verifyCommit(signer.identity(), write, certificate, cross_domain));
}

test "signer deinit scrubs owned seed bytes" {
    var backing: [2048]u8 = @splat(0xcc);
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const seed: Seed = @splat(0xab);
    const signer = try Signer.init(fixed.allocator(), testId(1), testId(31), seed);
    signer.deinit();
    try std.testing.expect(std.mem.indexOf(u8, &backing, &seed) == null);
}

test "identity binding rejects malformed identity low-order and non-prime subgroup keys" {
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer signer.deinit();
    var cases: [5]PublicKey = undefined;
    cases[0] = @splat(0xff); // Non-canonical compressed point.
    cases[1] = @splat(0);
    cases[1][0] = 1; // Edwards identity.
    cases[2] = @splat(0); // Order-four low-order point.
    cases[3] = @splat(0xff);
    cases[3][0] = 0xec;
    cases[3][31] = 0x7f; // Order-two point.
    _ = try std.fmt.hexToBytes(&cases[4], "4dc95e3c28d78c48a60531525e6327e259b7ba0d2f5c81b694052c766a14b625");
    for (cases) |public_key| {
        var identity = signer.identity();
        identity.public_key = public_key;
        identity.key_id = keyId(public_key);
        try std.testing.expectError(error.InvalidWitnessIdentity, validateIdentity(identity));
    }
}

test "zero signing identity and evidence fields fail closed" {
    try std.testing.expectError(
        error.InvalidSigningIdentity,
        Signer.init(std.testing.allocator, @splat(0), testId(31), @splat(0x11)),
    );
    const signer = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer signer.deinit();
    const write = testWrite();
    var attestation = testAttestation(write, testId(1), 1);
    attestation.prepare_digest = @splat(0);
    try std.testing.expectError(error.PrepareEvidenceMismatch, signer.signPrepare(write, attestation));
    const certificate = testCertificate(write);
    var result = testResult(write, certificate);
    result.history_digest = @splat(0);
    try std.testing.expectError(error.CommitEvidenceMismatch, signer.signCommit(write, certificate, result));
}

test "three witness identities are canonical distinct and key bound" {
    const first = try Signer.init(std.testing.allocator, testId(1), testId(31), @splat(0x11));
    defer first.deinit();
    const second = try Signer.init(std.testing.allocator, testId(2), testId(32), @splat(0x22));
    defer second.deinit();
    const third = try Signer.init(std.testing.allocator, testId(3), testId(33), @splat(0x33));
    defer third.deinit();
    const valid = [3]WitnessIdentity{ first.identity(), second.identity(), third.identity() };
    try validateIdentities(valid);
    var invalid = valid;
    std.mem.swap(WitnessIdentity, &invalid[0], &invalid[1]);
    try std.testing.expectError(error.InvalidReplicaSet, validateIdentities(invalid));
    invalid = valid;
    invalid[1].node_id = invalid[0].node_id;
    try std.testing.expectError(error.DuplicateSignerNode, validateIdentities(invalid));
    invalid = valid;
    invalid[1].public_key = invalid[0].public_key;
    invalid[1].key_id = invalid[0].key_id;
    try std.testing.expectError(error.DuplicateSigningKey, validateIdentities(invalid));
}
