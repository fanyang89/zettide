const std = @import("std");
const model = @import("model.zig");

pub const Id = model.Id;
pub const Digest = model.Digest;
pub const ReplicaBinding = model.ReplicaBinding;
pub const AuthorityBinding = model.AuthorityBinding;

pub const max_payload_size: usize = 1024 * 1024;
pub const certificate_witness_count: usize = 2;

pub const Frontier = struct {
    sequence: u64 = 0,
    history_digest: Digest = @splat(0),
};

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

pub const PrepareRequest = struct {
    write: WriteRequest,
    data: []const u8,
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

const PreparedRecord = struct {
    replica: ReplicaBinding,
    write: WriteRequest,
    attestation: PrepareAttestation,
    data: []const u8,
};

pub const CommitResult = struct {
    transaction_id: Id,
    sequence: u64,
    history_digest: Digest,
};

const CompletedRecord = struct {
    replica: ReplicaBinding,
    write: WriteRequest,
    attestation: PrepareAttestation,
    certificate: CommitCertificate,
    result: CommitResult,
};

pub const ParticipantBinding = struct {
    replica: ReplicaBinding,
    replica_members: [3]Id,
};

pub fn validateParticipantBinding(binding: ParticipantBinding) !void {
    try validateReplica(binding.replica);
    try validateReplicaSet(binding.replica_members, binding.replica.member_id);
}

const State = struct {
    binding: ?ParticipantBinding = null,
    frontier: Frontier = .{},
    pending: ?PreparedRecord = null,
    certificate: ?CommitCertificate = null,
    last_completed: ?CompletedRecord = null,
};

pub const PendingInspection = struct {
    write: WriteRequest,
    attestation: PrepareAttestation,
    commit_decided: bool,
};

pub const Inspection = struct {
    frontier: Frontier,
    pending: ?PendingInspection,
    last_completed: ?CommitResult,
    // Retained for authenticated COMMIT retry authorization. This exposes only
    // write metadata; payload bytes remain private to the durable participant.
    last_completed_write: ?WriteRequest,
};

const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        check_healthy: *const fn (*anyopaque) anyerror!void,
        current: *const fn (*anyopaque) State,
        save_prepared: *const fn (*anyopaque, PreparedRecord) anyerror!void,
        save_committed: *const fn (*anyopaque, CommitCertificate) anyerror!void,
        save_applied: *const fn (*anyopaque, CompletedRecord) anyerror!void,
    };

    fn checkHealthy(self: Store) !void {
        try self.vtable.check_healthy(self.context);
    }

    fn current(self: Store) State {
        return self.vtable.current(self.context);
    }

    fn savePrepared(self: Store, prepared: PreparedRecord) !void {
        try self.vtable.save_prepared(self.context, prepared);
    }

    fn saveCommitted(self: Store, certificate: CommitCertificate) !void {
        try self.vtable.save_committed(self.context, certificate);
    }

    fn saveApplied(self: Store, completed: CompletedRecord) !void {
        try self.vtable.save_applied(self.context, completed);
    }
};

pub const Backend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Apply and synchronize one payload as a single fence-drain critical section.
        apply: *const fn (*anyopaque, ReplicaBinding, u64, []const u8) anyerror!void,
    };

    pub fn apply(self: Backend, replica: ReplicaBinding, offset_bytes: u64, data: []const u8) !void {
        try self.vtable.apply(self.context, replica, offset_bytes, data);
    }
};

/// Admission remains process-local and must validate the currently accepted
/// authority. begin/end is a guard, not a point check: a production implementation
/// must share it with higher-epoch fencing so PREPARE and the complete
/// prepared-to-COMMIT-to-apply transition cannot cross fence evidence. Persisted
/// COMMIT recovery intentionally bypasses the live-authority check because the
/// quorum decision already happened before the process failed; fencing must drain
/// such replay before publishing its higher-epoch evidence. beginReplay uses the
/// same drain guard without reviving or validating the expired authority.
pub const Admission = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, AuthorityBinding) anyerror!void,
    begin_replay_fn: *const fn (*anyopaque, AuthorityBinding) anyerror!void,
    end_fn: *const fn (*anyopaque) void,

    fn begin(self: Admission, authority: AuthorityBinding) !void {
        try self.begin_fn(self.context, authority);
    }

    fn beginReplay(self: Admission, authority: AuthorityBinding) !void {
        try self.begin_replay_fn(self.context, authority);
    }

    fn end(self: Admission) void {
        self.end_fn(self.context);
    }
};

pub const Participant = opaque {
    pub fn initFile(
        allocator: std.mem.Allocator,
        replica: ReplicaBinding,
        replica_members: [3]Id,
        file_store: *FileStore,
        backend: Backend,
        admission: Admission,
    ) !*Participant {
        try file_store.bind(.{ .replica = replica, .replica_members = replica_members });
        const managed = try allocator.create(ManagedParticipant);
        errdefer allocator.destroy(managed);
        managed.* = .{
            .allocator = allocator,
            .core = try ParticipantCore.init(replica, replica_members, file_store.store(), backend, admission),
        };
        return @ptrCast(managed);
    }

    pub fn deinit(self: *Participant) void {
        const managed: *ManagedParticipant = @ptrCast(@alignCast(self));
        const allocator = managed.allocator;
        managed.* = undefined;
        allocator.destroy(managed);
    }

    pub fn prepare(self: *Participant, request: PrepareRequest) !PrepareAttestation {
        const managed: *ManagedParticipant = @ptrCast(@alignCast(self));
        return managed.core.prepare(request);
    }

    pub fn commit(self: *Participant, transaction_id: Id, certificate: CommitCertificate) !CommitResult {
        const managed: *ManagedParticipant = @ptrCast(@alignCast(self));
        return managed.core.commit(transaction_id, certificate);
    }

    pub fn recover(self: *Participant) !?CommitResult {
        const managed: *ManagedParticipant = @ptrCast(@alignCast(self));
        return managed.core.recover();
    }

    pub fn inspect(self: *Participant) !Inspection {
        const managed: *ManagedParticipant = @ptrCast(@alignCast(self));
        return managed.core.inspect();
    }

    fn init(
        replica: ReplicaBinding,
        replica_members: [3]Id,
        store: Store,
        backend: Backend,
        admission: Admission,
    ) !ParticipantCore {
        return ParticipantCore.init(replica, replica_members, store, backend, admission);
    }
};

const ManagedParticipant = struct {
    allocator: std.mem.Allocator,
    core: ParticipantCore,
};

const ParticipantCore = struct {
    replica: ReplicaBinding,
    replica_members: [3]Id,
    store: Store,
    backend: Backend,
    admission: Admission,
    transaction_lock: std.atomic.Mutex = .unlocked,

    fn init(
        replica: ReplicaBinding,
        replica_members: [3]Id,
        store: Store,
        backend: Backend,
        admission: Admission,
    ) !ParticipantCore {
        try validateReplica(replica);
        try validateReplicaSet(replica_members, replica.member_id);
        try store.checkHealthy();
        try validateParticipantState(replica, replica_members, store.current());
        return .{
            .replica = replica,
            .replica_members = replica_members,
            .store = store,
            .backend = backend,
            .admission = admission,
        };
    }

    fn lock(self: *ParticipantCore) void {
        while (!self.transaction_lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn prepare(self: *ParticipantCore, request: PrepareRequest) !PrepareAttestation {
        self.lock();
        defer self.transaction_lock.unlock();
        try self.store.checkHealthy();
        try self.admission.begin(request.write.authority);
        defer self.admission.end();
        try validatePrepareRequest(self.replica, self.replica_members, request);

        const state = self.store.current();
        try validateParticipantState(self.replica, self.replica_members, state);
        if (state.last_completed) |completed| {
            if (std.mem.eql(u8, &completed.write.transaction_id, &request.write.transaction_id)) {
                if (!sameWrite(completed.write, request.write)) return error.OperationConflict;
                return completed.attestation;
            }
        }
        if (state.pending) |pending| {
            if (!std.mem.eql(u8, &pending.write.transaction_id, &request.write.transaction_id))
                return error.WriteInProgress;
            if (!sameWrite(pending.write, request.write)) return error.OperationConflict;
            return pending.attestation;
        }
        try validateNextWrite(state.frontier, request.write);

        const transaction_digest = digestTransaction(request.write);
        const attestation: PrepareAttestation = .{
            .member_id = self.replica.member_id,
            .transaction_digest = transaction_digest,
            .prepare_digest = digestPrepare(transaction_digest, self.replica),
            .prepared_history_digest = digestPreparedHistory(
                request.write.previous_history_digest,
                transaction_digest,
            ),
        };
        try self.store.savePrepared(.{
            .replica = self.replica,
            .write = request.write,
            .attestation = attestation,
            .data = request.data,
        });
        return attestation;
    }

    pub fn commit(self: *ParticipantCore, transaction_id: Id, certificate_input: CommitCertificate) !CommitResult {
        self.lock();
        defer self.transaction_lock.unlock();
        try self.store.checkHealthy();
        const certificate = try normalizeCertificate(certificate_input);
        var state = self.store.current();
        try validateParticipantState(self.replica, self.replica_members, state);

        if (state.last_completed) |completed| {
            if (std.mem.eql(u8, &completed.write.transaction_id, &transaction_id)) {
                if (!std.meta.eql(completed.certificate, certificate)) return error.CertificateConflict;
                return completed.result;
            }
        }

        const pending = state.pending orelse return error.TransactionNotFound;
        if (!std.mem.eql(u8, &pending.write.transaction_id, &transaction_id)) return error.TransactionNotFound;
        try validateCertificate(certificate, pending.attestation, self.replica_members);
        if (state.certificate) |existing| {
            if (!std.meta.eql(existing, certificate)) return error.CertificateConflict;
            try self.admission.beginReplay(pending.write.authority);
            defer self.admission.end();
            return self.applyCommitted(state);
        }

        try self.admission.begin(pending.write.authority);
        defer self.admission.end();
        try self.store.saveCommitted(certificate);
        state = self.store.current();
        return self.applyCommitted(state);
    }

    /// Finish a durably decided write after a crash. No live lease is required:
    /// refusing to apply an already-certified decision would strand a committed
    /// sequence and make recovery less safe, not more safe.
    pub fn recover(self: *ParticipantCore) !?CommitResult {
        self.lock();
        defer self.transaction_lock.unlock();
        try self.store.checkHealthy();
        const state = self.store.current();
        try validateParticipantState(self.replica, self.replica_members, state);
        if (state.pending == null or state.certificate == null) return null;
        const pending = state.pending.?;
        try self.admission.beginReplay(pending.write.authority);
        defer self.admission.end();
        return try self.applyCommitted(state);
    }

    pub fn inspect(self: *ParticipantCore) !Inspection {
        self.lock();
        defer self.transaction_lock.unlock();
        try self.store.checkHealthy();
        const state = self.store.current();
        try validateParticipantState(self.replica, self.replica_members, state);
        return .{
            .frontier = state.frontier,
            .pending = if (state.pending) |pending| .{
                .write = pending.write,
                .attestation = pending.attestation,
                .commit_decided = state.certificate != null,
            } else null,
            .last_completed = if (state.last_completed) |completed| completed.result else null,
            .last_completed_write = if (state.last_completed) |completed| completed.write else null,
        };
    }

    fn applyCommitted(self: *ParticipantCore, state: State) !CommitResult {
        try validateParticipantState(self.replica, self.replica_members, state);
        const pending = state.pending orelse return error.StoreCorrupt;
        const certificate = state.certificate orelse return error.StoreCorrupt;
        try validateCertificate(certificate, pending.attestation, self.replica_members);
        try self.backend.apply(pending.replica, pending.write.offset_bytes, pending.data);
        const result: CommitResult = .{
            .transaction_id = pending.write.transaction_id,
            .sequence = pending.write.sequence,
            .history_digest = digestCommitHistory(pending.attestation.prepared_history_digest, certificate),
        };
        try self.store.saveApplied(.{
            .replica = pending.replica,
            .write = pending.write,
            .attestation = pending.attestation,
            .certificate = certificate,
            .result = result,
        });
        return result;
    }
};

fn validateReplica(replica: ReplicaBinding) !void {
    if (isZero(&replica.volume_id) or isZero(&replica.placement_id) or isZero(&replica.allocation_id) or
        isZero(&replica.member_id) or replica.generation == 0 or replica.length_bytes == 0)
        return error.InvalidReplica;
    _ = std.math.add(u64, replica.offset_bytes, replica.length_bytes) catch return error.InvalidReplica;
}

pub fn validateCanonicalReplicaMembers(replica_members: [3]Id) !void {
    for (replica_members, 0..) |member, index| {
        if (isZero(&member)) return error.InvalidReplicaSet;
        if (index != 0 and std.mem.order(u8, &replica_members[index - 1], &member) != .lt)
            return error.InvalidReplicaSet;
    }
}

fn validateReplicaSet(replica_members: [3]Id, local_member: Id) !void {
    try validateCanonicalReplicaMembers(replica_members);
    for (replica_members) |member|
        if (std.mem.eql(u8, &member, &local_member)) return;
    return error.InvalidReplicaSet;
}

fn validateParticipantState(replica: ReplicaBinding, replica_members: [3]Id, state: State) !void {
    if (state.binding) |binding|
        if (!std.meta.eql(replica, binding.replica) or !std.meta.eql(replica_members, binding.replica_members))
            return error.ReplicaStateMismatch;
    if (state.pending) |pending| {
        if (!std.meta.eql(replica, pending.replica) or !std.meta.eql(replica_members, pending.write.replica_members))
            return error.ReplicaStateMismatch;
    }
    if (state.last_completed) |completed| {
        if (!std.meta.eql(replica, completed.replica) or !std.meta.eql(replica_members, completed.write.replica_members))
            return error.ReplicaStateMismatch;
    }
}

fn validateWriteMetadata(replica: ReplicaBinding, replica_members: [3]Id, write: WriteRequest) !void {
    try validateReplicaSet(replica_members, replica.member_id);
    if (!std.meta.eql(replica_members, write.replica_members) or write.length_bytes == 0 or
        write.length_bytes > max_payload_size or write.sequence == 0 or
        (write.sequence == 1) != isZero(&write.previous_history_digest) or
        isZero(&write.transaction_id) or isZero(&write.data_digest))
        return error.InvalidWrite;
    if (isZero(&write.authority.volume_id) or isZero(&write.authority.primary_placement_id) or
        isZero(&write.authority.primary_node_id) or isZero(&write.authority.lease_id) or
        isZero(&write.authority.holder_boot_id) or write.authority.authority_generation == 0 or
        write.authority.write_epoch == 0 or write.authority.placement_revision == 0 or
        isZero(&write.authority.activation_nonce) or isZero(&write.authority.authority_digest))
        return error.InvalidAuthority;
    if (!std.mem.eql(u8, &write.authority.volume_id, &replica.volume_id)) return error.VolumeMismatch;
    const end = std.math.add(u64, write.offset_bytes, write.length_bytes) catch return error.WriteOutOfBounds;
    if (end > replica.length_bytes) return error.WriteOutOfBounds;
}

fn validatePrepareRequest(replica: ReplicaBinding, replica_members: [3]Id, request: PrepareRequest) !void {
    try validateWriteMetadata(replica, replica_members, request.write);
    if (request.data.len == 0 or request.write.length_bytes != request.data.len)
        return error.InvalidWrite;
    if (!std.mem.eql(u8, &request.write.data_digest, &digestData(request.data))) return error.DataDigestMismatch;
}

fn validateNextWrite(frontier: Frontier, write: WriteRequest) !void {
    const expected_sequence = std.math.add(u64, frontier.sequence, 1) catch return error.SequenceOverflow;
    if (write.sequence != expected_sequence) return error.SequenceMismatch;
    if (!std.mem.eql(u8, &write.previous_history_digest, &frontier.history_digest))
        return error.HistoryMismatch;
}

fn validateCertificate(
    certificate: CommitCertificate,
    local: PrepareAttestation,
    replica_members: [3]Id,
) !void {
    const first = certificate.attestations[0];
    const second = certificate.attestations[1];
    if (isZero(&first.member_id) or isZero(&second.member_id) or
        isZero(&first.transaction_digest) or isZero(&second.transaction_digest) or
        isZero(&first.prepare_digest) or isZero(&second.prepare_digest) or
        isZero(&first.prepared_history_digest) or isZero(&second.prepared_history_digest))
        return error.InvalidCertificate;
    if (std.mem.eql(u8, &first.member_id, &second.member_id)) return error.DuplicateWitness;
    if (std.mem.order(u8, &first.member_id, &second.member_id) != .lt) return error.NonCanonicalCertificate;
    var local_found = false;
    for (certificate.attestations) |attestation| {
        var eligible = false;
        for (replica_members) |member| if (std.mem.eql(u8, &member, &attestation.member_id)) {
            eligible = true;
            break;
        };
        if (!eligible) return error.CertificateMemberNotEligible;
        if (!std.mem.eql(u8, &attestation.transaction_digest, &local.transaction_digest) or
            !std.mem.eql(u8, &attestation.prepared_history_digest, &local.prepared_history_digest))
            return error.CertificateMismatch;
        if (std.mem.eql(u8, &attestation.member_id, &local.member_id)) {
            local_found = true;
            if (!std.meta.eql(attestation, local)) return error.CertificateMismatch;
        }
    }
    if (!local_found) return error.LocalWitnessMissing;
}

fn normalizeCertificate(input: CommitCertificate) !CommitCertificate {
    var result = input;
    if (std.mem.order(u8, &result.attestations[1].member_id, &result.attestations[0].member_id) == .lt)
        std.mem.swap(PrepareAttestation, &result.attestations[0], &result.attestations[1]);
    return result;
}

/// Construct canonical coordinator evidence from two already authenticated
/// PREPARE responses. The responses are transport-authenticated evidence only;
/// this helper does not turn them into independently signed third-party proof.
pub fn makeCommitCertificate(
    attestations: [certificate_witness_count]PrepareAttestation,
    transaction_digest: Digest,
    prepared_history_digest: Digest,
    replica_members: [3]Id,
) !CommitCertificate {
    try validateCanonicalReplicaMembers(replica_members);
    var certificate = CommitCertificate{ .attestations = attestations };
    certificate = try normalizeCertificate(certificate);
    const first = certificate.attestations[0];
    const second = certificate.attestations[1];
    if (isZero(&transaction_digest) or isZero(&prepared_history_digest) or
        isZero(&first.member_id) or isZero(&second.member_id) or
        isZero(&first.prepare_digest) or isZero(&second.prepare_digest) or
        std.mem.eql(u8, &first.member_id, &second.member_id))
        return error.InvalidCertificate;
    for (certificate.attestations) |attestation| {
        var eligible = false;
        for (replica_members) |member| if (std.mem.eql(u8, &member, &attestation.member_id)) {
            eligible = true;
            break;
        };
        if (!eligible) return error.CertificateMemberNotEligible;
        if (!std.mem.eql(u8, &attestation.transaction_digest, &transaction_digest) or
            !std.mem.eql(u8, &attestation.prepared_history_digest, &prepared_history_digest))
            return error.CertificateMismatch;
    }
    return certificate;
}

fn sameWrite(a: WriteRequest, b: WriteRequest) bool {
    return std.meta.eql(a, b);
}

pub fn digestData(data: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &result, .{});
    return result;
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

fn digestPrepare(transaction_digest: Digest, replica: ReplicaBinding) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-replica-write-prepare-v1");
    hashField(&hasher, &transaction_digest);
    hashField(&hasher, &replica.placement_id);
    hashField(&hasher, &replica.allocation_id);
    hashU64(&hasher, replica.generation);
    hashField(&hasher, &replica.member_id);
    hashU64(&hasher, replica.offset_bytes);
    hashU64(&hasher, replica.length_bytes);
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn digestPreparedHistory(previous: Digest, transaction_digest: Digest) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-replica-write-prepared-history-v1");
    hashField(&hasher, &previous);
    hashField(&hasher, &transaction_digest);
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

fn hashAuthority(hasher: *std.crypto.hash.sha2.Sha256, authority: AuthorityBinding) void {
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

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    hasher.update(&length);
    hasher.update(value);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const MemoryStore = struct {
    allocator: std.mem.Allocator,
    state: State = .{},
    payload: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryStore) void {
        if (self.payload.len != 0) self.allocator.free(self.payload);
        self.* = undefined;
    }

    pub fn store(self: *MemoryStore) Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn checkHealthyOpaque(_: *anyopaque) !void {}

    fn currentOpaque(context: *anyopaque) State {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn savePreparedOpaque(context: *anyopaque, prepared: PreparedRecord) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        const payload = try self.allocator.dupe(u8, prepared.data);
        errdefer self.allocator.free(payload);
        if (self.payload.len != 0) self.allocator.free(self.payload);
        self.payload = payload;
        self.state.pending = prepared;
        self.state.pending.?.data = payload;
        self.state.certificate = null;
    }

    fn saveCommittedOpaque(context: *anyopaque, certificate: CommitCertificate) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        if (self.state.pending == null or self.state.certificate != null) return error.StoreConflict;
        self.state.certificate = certificate;
    }

    fn saveAppliedOpaque(context: *anyopaque, completed: CompletedRecord) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        if (self.state.pending == null or self.state.certificate == null) return error.StoreConflict;
        if (self.payload.len != 0) self.allocator.free(self.payload);
        self.payload = &.{};
        self.state = .{
            .binding = self.state.binding,
            .frontier = .{ .sequence = completed.result.sequence, .history_digest = completed.result.history_digest },
            .last_completed = completed,
        };
    }

    const vtable: Store.VTable = .{
        .check_healthy = checkHealthyOpaque,
        .current = currentOpaque,
        .save_prepared = savePreparedOpaque,
        .save_committed = saveCommittedOpaque,
        .save_applied = saveAppliedOpaque,
    };
};

pub const FileStore = opaque {
    pub const Faults = FileStoreInner.Faults;

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        basename: []const u8,
    ) !*FileStore {
        const inner = try allocator.create(FileStoreInner);
        errdefer allocator.destroy(inner);
        inner.* = try FileStoreInner.init(allocator, io, parent, basename);
        return @ptrCast(inner);
    }

    pub fn deinit(self: *FileStore) void {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        const allocator = inner.allocator;
        inner.deinit();
        allocator.destroy(inner);
    }

    pub fn setFaults(self: *FileStore, faults: ?*Faults) void {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        inner.faults = faults;
    }

    pub fn isPoisoned(self: *const FileStore) bool {
        const inner: *const FileStoreInner = @ptrCast(@alignCast(self));
        return inner.poisoned;
    }

    pub fn binding(self: *FileStore) !?ParticipantBinding {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        if (inner.poisoned) return error.StorePoisoned;
        try validateStoredState(inner.state);
        return inner.state.binding;
    }

    fn bind(self: *FileStore, expected: ParticipantBinding) !void {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        try inner.bind(expected);
    }

    fn store(self: *FileStore) Store {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        return inner.store();
    }
};

const FileStoreInner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    lock_basename: []u8,
    lock_file: std.Io.File,
    state: State = .{},
    storage: []u8 = &.{},
    poisoned: bool = false,
    faults: ?*Faults = null,

    const magic = "ZETWRIT1".*;
    const version: u16 = 1;
    const metadata_size: usize = 2048;
    const checksum_size: usize = 4;
    const max_file_size: usize = metadata_size + max_payload_size + checksum_size;

    pub const Faults = struct {
        fail_replace_once: bool = false,
        fail_directory_sync_once: bool = false,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        basename: []const u8,
    ) !FileStoreInner {
        const lock_basename = try std.fmt.allocPrint(allocator, "{s}.lock", .{basename});
        errdefer allocator.free(lock_basename);
        const lock_file = try parent.createFile(io, lock_basename, .{ .truncate = false });
        errdefer lock_file.close(io);
        const locked = try lock_file.tryLock(io, .exclusive);
        if (!locked) return error.StateFileLocked;

        const bytes = parent.readFileAlloc(io, basename, allocator, .limited(max_file_size + 1)) catch |err| switch (err) {
            error.FileNotFound => return .{
                .allocator = allocator,
                .io = io,
                .parent = parent,
                .basename = basename,
                .lock_basename = lock_basename,
                .lock_file = lock_file,
            },
            error.StreamTooLong => return error.StoreCorrupt,
            else => return err,
        };
        errdefer allocator.free(bytes);
        const state = try decodeSnapshot(bytes);
        return .{
            .allocator = allocator,
            .io = io,
            .parent = parent,
            .basename = basename,
            .lock_basename = lock_basename,
            .lock_file = lock_file,
            .state = state,
            .storage = bytes,
        };
    }

    pub fn deinit(self: *FileStoreInner) void {
        if (self.storage.len != 0) self.allocator.free(self.storage);
        self.lock_file.close(self.io);
        self.allocator.free(self.lock_basename);
        self.* = undefined;
    }

    pub fn store(self: *FileStoreInner) Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn bind(self: *FileStoreInner, expected: ParticipantBinding) !void {
        if (self.poisoned) return error.StorePoisoned;
        try validateReplica(expected.replica);
        try validateReplicaSet(expected.replica_members, expected.replica.member_id);
        if (self.state.binding) |existing| {
            if (!std.meta.eql(existing, expected)) return error.ReplicaStateMismatch;
            return;
        }
        if (self.state.pending) |pending| {
            if (!std.meta.eql(pending.replica, expected.replica) or
                !std.meta.eql(pending.write.replica_members, expected.replica_members))
                return error.ReplicaStateMismatch;
        }
        if (self.state.last_completed) |completed| {
            if (!std.meta.eql(completed.replica, expected.replica) or
                !std.meta.eql(completed.write.replica_members, expected.replica_members))
                return error.ReplicaStateMismatch;
        }
        var next = self.state;
        next.binding = expected;
        try self.install(next);
    }

    fn checkHealthyOpaque(context: *anyopaque) !void {
        const self: *FileStoreInner = @ptrCast(@alignCast(context));
        if (self.poisoned) return error.StorePoisoned;
    }

    fn currentOpaque(context: *anyopaque) State {
        const self: *FileStoreInner = @ptrCast(@alignCast(context));
        return self.state;
    }

    fn savePreparedOpaque(context: *anyopaque, prepared: PreparedRecord) !void {
        const self: *FileStoreInner = @ptrCast(@alignCast(context));
        if (self.poisoned) return error.StorePoisoned;
        if (self.state.pending != null) return error.StoreConflict;
        var next = self.state;
        next.pending = prepared;
        next.certificate = null;
        try validateStoredState(next);
        try self.install(next);
    }

    fn saveCommittedOpaque(context: *anyopaque, certificate: CommitCertificate) !void {
        const self: *FileStoreInner = @ptrCast(@alignCast(context));
        if (self.poisoned) return error.StorePoisoned;
        if (self.state.pending == null or self.state.certificate != null) return error.StoreConflict;
        var next = self.state;
        next.certificate = certificate;
        try validateStoredState(next);
        try self.install(next);
    }

    fn saveAppliedOpaque(context: *anyopaque, completed: CompletedRecord) !void {
        const self: *FileStoreInner = @ptrCast(@alignCast(context));
        if (self.poisoned) return error.StorePoisoned;
        if (self.state.pending == null or self.state.certificate == null) return error.StoreConflict;
        const next: State = .{
            .binding = self.state.binding,
            .frontier = .{ .sequence = completed.result.sequence, .history_digest = completed.result.history_digest },
            .last_completed = completed,
        };
        try validateStoredState(next);
        try self.install(next);
    }

    fn install(self: *FileStoreInner, next_input: State) !void {
        const bytes = try encodeSnapshot(self.allocator, next_input);
        var installed = false;
        errdefer if (!installed) self.allocator.free(bytes);
        if (self.faults) |faults| {
            if (faults.fail_replace_once) {
                faults.fail_replace_once = false;
                return error.InjectedReplaceFailure;
            }
        }
        var atomic_file = try self.parent.createFileAtomic(self.io, self.basename, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        try atomic_file.file.writeStreamingAll(self.io, bytes);
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
        self.syncParent() catch |err| {
            self.poisoned = true;
            return err;
        };

        var next = next_input;
        if (next.pending) |*pending| pending.data = snapshotPayload(bytes);
        const previous = self.storage;
        self.storage = bytes;
        self.state = next;
        installed = true;
        if (previous.len != 0) self.allocator.free(previous);
    }

    fn syncParent(self: *FileStoreInner) !void {
        if (self.faults) |faults| {
            if (faults.fail_directory_sync_once) {
                faults.fail_directory_sync_once = false;
                return error.InjectedDirectorySyncFailure;
            }
        }
        const parent_file = try self.parent.openFile(self.io, ".", .{ .mode = .read_only });
        defer parent_file.close(self.io);
        try parent_file.sync(self.io);
    }

    const vtable: Store.VTable = .{
        .check_healthy = checkHealthyOpaque,
        .current = currentOpaque,
        .save_prepared = savePreparedOpaque,
        .save_committed = saveCommittedOpaque,
        .save_applied = saveAppliedOpaque,
    };

    fn encodeSnapshot(allocator: std.mem.Allocator, state: State) ![]u8 {
        try validateStoredState(state);
        const payload = if (state.pending) |pending| pending.data else &.{};
        const bytes = try allocator.alloc(u8, metadata_size + payload.len + checksum_size);
        @memset(bytes, 0);
        @memcpy(bytes[0..8], &magic);
        std.mem.writeInt(u16, bytes[8..10], version, .little);
        bytes[10] = if (state.pending == null) 0 else if (state.certificate == null) 1 else 2;
        bytes[11] = @intFromBool(state.last_completed != null);
        std.mem.writeInt(u32, bytes[12..16], metadata_size, .little);
        std.mem.writeInt(u32, bytes[16..20], @intCast(payload.len), .little);
        var offset: usize = 24;
        putFrontier(bytes, &offset, state.frontier);
        if (state.pending) |pending| putPrepared(bytes, &offset, pending) else offset += prepared_encoded_size;
        if (state.certificate) |certificate| putCertificate(bytes, &offset, certificate) else offset += certificate_encoded_size;
        if (state.last_completed) |completed| putCompleted(bytes, &offset, completed) else offset += completed_encoded_size;
        bytes[offset] = @intFromBool(state.binding != null);
        offset += 1;
        if (state.binding) |binding| {
            putReplica(bytes, &offset, binding.replica);
            for (binding.replica_members) |member| putBytes(bytes, &offset, &member);
        } else offset += participant_binding_encoded_size;
        if (offset > metadata_size) return error.StoreEncodingOverflow;
        @memcpy(bytes[metadata_size..][0..payload.len], payload);
        std.mem.writeInt(u32, bytes[bytes.len - checksum_size ..][0..checksum_size], std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - checksum_size]), .little);
        return bytes;
    }

    fn decodeSnapshot(bytes: []u8) !State {
        if (bytes.len < metadata_size + checksum_size or !std.mem.eql(u8, bytes[0..8], &magic) or
            std.mem.readInt(u16, bytes[8..10], .little) != version or
            std.mem.readInt(u32, bytes[12..16], .little) != metadata_size or !isZero(bytes[20..24]))
            return error.StoreCorrupt;
        const phase = bytes[10];
        const has_last = bytes[11];
        if (phase > 2 or has_last > 1) return error.StoreCorrupt;
        const payload_len = std.mem.readInt(u32, bytes[16..20], .little);
        if (payload_len > max_payload_size or bytes.len != metadata_size + @as(usize, payload_len) + checksum_size)
            return error.StoreCorrupt;
        if (std.mem.readInt(u32, bytes[bytes.len - checksum_size ..][0..checksum_size], .little) !=
            std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - checksum_size])) return error.StoreCorrupt;

        var offset: usize = 24;
        var state: State = .{ .frontier = getFrontier(bytes, &offset) };
        if (phase != 0) {
            state.pending = getPrepared(bytes, &offset);
            state.pending.?.data = snapshotPayload(bytes);
        } else offset += prepared_encoded_size;
        if (phase == 2) state.certificate = getCertificate(bytes, &offset) else offset += certificate_encoded_size;
        if (has_last == 1) state.last_completed = getCompleted(bytes, &offset) else offset += completed_encoded_size;
        const has_binding = bytes[offset];
        offset += 1;
        if (has_binding > 1) return error.StoreCorrupt;
        if (has_binding == 1) {
            state.binding = .{
                .replica = getReplica(bytes, &offset),
                .replica_members = .{
                    getArray(16, bytes, &offset),
                    getArray(16, bytes, &offset),
                    getArray(16, bytes, &offset),
                },
            };
        } else offset += participant_binding_encoded_size;
        if (!isZero(bytes[offset..metadata_size])) return error.StoreCorrupt;
        try validateStoredState(state);
        return state;
    }

    fn snapshotPayload(bytes: []u8) []u8 {
        return bytes[metadata_size .. bytes.len - checksum_size];
    }
};

const replica_encoded_size: usize = 88;
const participant_binding_encoded_size: usize = replica_encoded_size + 3 * @sizeOf(Id);
const authority_encoded_size: usize = 152;
const write_encoded_size: usize = authority_encoded_size + 3 * @sizeOf(Id) + 104;
const attestation_encoded_size: usize = 112;
const certificate_encoded_size: usize = certificate_witness_count * attestation_encoded_size;
const prepared_encoded_size: usize = replica_encoded_size + write_encoded_size + attestation_encoded_size;
const result_encoded_size: usize = 56;
const completed_encoded_size: usize = replica_encoded_size + write_encoded_size + attestation_encoded_size + certificate_encoded_size + result_encoded_size;

fn putFrontier(bytes: []u8, offset: *usize, frontier: Frontier) void {
    putU64(bytes, offset, frontier.sequence);
    putBytes(bytes, offset, &frontier.history_digest);
}

fn getFrontier(bytes: []const u8, offset: *usize) Frontier {
    return .{ .sequence = getU64(bytes, offset), .history_digest = getArray(32, bytes, offset) };
}

fn putReplica(bytes: []u8, offset: *usize, replica: ReplicaBinding) void {
    putBytes(bytes, offset, &replica.volume_id);
    putBytes(bytes, offset, &replica.placement_id);
    putBytes(bytes, offset, &replica.allocation_id);
    putU64(bytes, offset, replica.generation);
    putBytes(bytes, offset, &replica.member_id);
    putU64(bytes, offset, replica.offset_bytes);
    putU64(bytes, offset, replica.length_bytes);
}

fn getReplica(bytes: []const u8, offset: *usize) ReplicaBinding {
    return .{
        .volume_id = getArray(16, bytes, offset),
        .placement_id = getArray(16, bytes, offset),
        .allocation_id = getArray(16, bytes, offset),
        .generation = getU64(bytes, offset),
        .member_id = getArray(16, bytes, offset),
        .offset_bytes = getU64(bytes, offset),
        .length_bytes = getU64(bytes, offset),
    };
}

fn putAuthority(bytes: []u8, offset: *usize, authority: AuthorityBinding) void {
    putBytes(bytes, offset, &authority.volume_id);
    putBytes(bytes, offset, &authority.primary_placement_id);
    putBytes(bytes, offset, &authority.primary_node_id);
    putBytes(bytes, offset, &authority.lease_id);
    putBytes(bytes, offset, &authority.holder_boot_id);
    putU64(bytes, offset, authority.authority_generation);
    putU64(bytes, offset, authority.write_epoch);
    putU64(bytes, offset, authority.placement_revision);
    putBytes(bytes, offset, &authority.activation_nonce);
    putBytes(bytes, offset, &authority.authority_digest);
}

fn getAuthority(bytes: []const u8, offset: *usize) AuthorityBinding {
    return .{
        .volume_id = getArray(16, bytes, offset),
        .primary_placement_id = getArray(16, bytes, offset),
        .primary_node_id = getArray(16, bytes, offset),
        .lease_id = getArray(16, bytes, offset),
        .holder_boot_id = getArray(16, bytes, offset),
        .authority_generation = getU64(bytes, offset),
        .write_epoch = getU64(bytes, offset),
        .placement_revision = getU64(bytes, offset),
        .activation_nonce = getArray(16, bytes, offset),
        .authority_digest = getArray(32, bytes, offset),
    };
}

fn putWrite(bytes: []u8, offset: *usize, write: WriteRequest) void {
    putAuthority(bytes, offset, write.authority);
    for (write.replica_members) |member| putBytes(bytes, offset, &member);
    putU64(bytes, offset, write.sequence);
    putBytes(bytes, offset, &write.transaction_id);
    putBytes(bytes, offset, &write.previous_history_digest);
    putU64(bytes, offset, write.offset_bytes);
    putU64(bytes, offset, write.length_bytes);
    putBytes(bytes, offset, &write.data_digest);
}

fn getWrite(bytes: []const u8, offset: *usize) WriteRequest {
    return .{
        .authority = getAuthority(bytes, offset),
        .replica_members = .{
            getArray(16, bytes, offset),
            getArray(16, bytes, offset),
            getArray(16, bytes, offset),
        },
        .sequence = getU64(bytes, offset),
        .transaction_id = getArray(16, bytes, offset),
        .previous_history_digest = getArray(32, bytes, offset),
        .offset_bytes = getU64(bytes, offset),
        .length_bytes = getU64(bytes, offset),
        .data_digest = getArray(32, bytes, offset),
    };
}

fn putAttestation(bytes: []u8, offset: *usize, attestation: PrepareAttestation) void {
    putBytes(bytes, offset, &attestation.member_id);
    putBytes(bytes, offset, &attestation.transaction_digest);
    putBytes(bytes, offset, &attestation.prepare_digest);
    putBytes(bytes, offset, &attestation.prepared_history_digest);
}

fn getAttestation(bytes: []const u8, offset: *usize) PrepareAttestation {
    return .{
        .member_id = getArray(16, bytes, offset),
        .transaction_digest = getArray(32, bytes, offset),
        .prepare_digest = getArray(32, bytes, offset),
        .prepared_history_digest = getArray(32, bytes, offset),
    };
}

fn putCertificate(bytes: []u8, offset: *usize, certificate: CommitCertificate) void {
    for (certificate.attestations) |attestation| putAttestation(bytes, offset, attestation);
}

fn getCertificate(bytes: []const u8, offset: *usize) CommitCertificate {
    var result: CommitCertificate = undefined;
    for (&result.attestations) |*attestation| attestation.* = getAttestation(bytes, offset);
    return result;
}

fn putPrepared(bytes: []u8, offset: *usize, prepared: PreparedRecord) void {
    putReplica(bytes, offset, prepared.replica);
    putWrite(bytes, offset, prepared.write);
    putAttestation(bytes, offset, prepared.attestation);
}

fn getPrepared(bytes: []const u8, offset: *usize) PreparedRecord {
    return .{
        .replica = getReplica(bytes, offset),
        .write = getWrite(bytes, offset),
        .attestation = getAttestation(bytes, offset),
        .data = &.{},
    };
}

fn putResult(bytes: []u8, offset: *usize, result: CommitResult) void {
    putBytes(bytes, offset, &result.transaction_id);
    putU64(bytes, offset, result.sequence);
    putBytes(bytes, offset, &result.history_digest);
}

fn getResult(bytes: []const u8, offset: *usize) CommitResult {
    return .{
        .transaction_id = getArray(16, bytes, offset),
        .sequence = getU64(bytes, offset),
        .history_digest = getArray(32, bytes, offset),
    };
}

fn putCompleted(bytes: []u8, offset: *usize, completed: CompletedRecord) void {
    putReplica(bytes, offset, completed.replica);
    putWrite(bytes, offset, completed.write);
    putAttestation(bytes, offset, completed.attestation);
    putCertificate(bytes, offset, completed.certificate);
    putResult(bytes, offset, completed.result);
}

fn getCompleted(bytes: []const u8, offset: *usize) CompletedRecord {
    return .{
        .replica = getReplica(bytes, offset),
        .write = getWrite(bytes, offset),
        .attestation = getAttestation(bytes, offset),
        .certificate = getCertificate(bytes, offset),
        .result = getResult(bytes, offset),
    };
}

fn putBytes(bytes: []u8, offset: *usize, value: []const u8) void {
    @memcpy(bytes[offset.*..][0..value.len], value);
    offset.* += value.len;
}

fn putU64(bytes: []u8, offset: *usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset.*..][0..8], value, .little);
    offset.* += 8;
}

fn getArray(comptime size: usize, bytes: []const u8, offset: *usize) [size]u8 {
    const result = bytes[offset.*..][0..size].*;
    offset.* += size;
    return result;
}

fn getU64(bytes: []const u8, offset: *usize) u64 {
    const result = std.mem.readInt(u64, bytes[offset.*..][0..8], .little);
    offset.* += 8;
    return result;
}

fn validateStoredState(state: State) !void {
    if (state.binding) |binding| {
        validateReplica(binding.replica) catch return error.StoreCorrupt;
        validateReplicaSet(binding.replica_members, binding.replica.member_id) catch return error.StoreCorrupt;
    }
    if ((state.frontier.sequence == 0) != isZero(&state.frontier.history_digest)) return error.StoreCorrupt;
    if (state.certificate != null and state.pending == null) return error.StoreCorrupt;
    if (state.pending) |pending| {
        if (state.binding) |binding|
            if (!std.meta.eql(binding.replica, pending.replica) or
                !std.meta.eql(binding.replica_members, pending.write.replica_members))
                return error.StoreCorrupt;
        validateReplica(pending.replica) catch return error.StoreCorrupt;
        validatePrepareRequest(pending.replica, pending.write.replica_members, .{ .write = pending.write, .data = pending.data }) catch return error.StoreCorrupt;
        validateNextWrite(state.frontier, pending.write) catch return error.StoreCorrupt;
        const transaction_digest = digestTransaction(pending.write);
        const expected: PrepareAttestation = .{
            .member_id = pending.replica.member_id,
            .transaction_digest = transaction_digest,
            .prepare_digest = digestPrepare(transaction_digest, pending.replica),
            .prepared_history_digest = digestPreparedHistory(pending.write.previous_history_digest, transaction_digest),
        };
        if (!std.meta.eql(expected, pending.attestation)) return error.StoreCorrupt;
        if (state.certificate) |certificate|
            validateCertificate(certificate, pending.attestation, pending.write.replica_members) catch return error.StoreCorrupt;
    }
    if (state.last_completed) |completed| {
        if (state.binding) |binding|
            if (!std.meta.eql(binding.replica, completed.replica) or
                !std.meta.eql(binding.replica_members, completed.write.replica_members))
                return error.StoreCorrupt;
        validateReplica(completed.replica) catch return error.StoreCorrupt;
        validateWriteMetadata(completed.replica, completed.write.replica_members, completed.write) catch return error.StoreCorrupt;
        if (!std.mem.eql(u8, &completed.replica.volume_id, &completed.write.authority.volume_id) or
            !std.mem.eql(u8, &completed.attestation.member_id, &completed.replica.member_id) or
            completed.write.sequence != completed.result.sequence or
            !std.mem.eql(u8, &completed.write.transaction_id, &completed.result.transaction_id) or
            !std.mem.eql(u8, &completed.attestation.transaction_digest, &digestTransaction(completed.write)) or
            !std.mem.eql(u8, &completed.attestation.prepare_digest, &digestPrepare(completed.attestation.transaction_digest, completed.replica)) or
            !std.mem.eql(u8, &completed.attestation.prepared_history_digest, &digestPreparedHistory(completed.write.previous_history_digest, completed.attestation.transaction_digest)))
            return error.StoreCorrupt;
        validateCertificate(completed.certificate, completed.attestation, completed.write.replica_members) catch return error.StoreCorrupt;
        const expected_history = digestCommitHistory(completed.attestation.prepared_history_digest, completed.certificate);
        if (!std.mem.eql(u8, &completed.result.history_digest, &expected_history) or
            state.frontier.sequence != completed.result.sequence or
            !std.mem.eql(u8, &state.frontier.history_digest, &expected_history)) return error.StoreCorrupt;
    } else if (state.frontier.sequence != 0) return error.StoreCorrupt;
    if (state.pending != null and state.last_completed != null) {
        const pending = state.pending.?;
        const completed = state.last_completed.?;
        if (!std.meta.eql(pending.replica, completed.replica) or
            !std.meta.eql(pending.write.replica_members, completed.write.replica_members) or
            pending.write.authority.write_epoch < completed.write.authority.write_epoch or
            pending.write.authority.authority_generation < completed.write.authority.authority_generation or
            pending.write.authority.placement_revision < completed.write.authority.placement_revision)
            return error.StoreCorrupt;
    }
}

const FakeBackend = struct {
    bytes: [64]u8 = @splat(0),
    writes: usize = 0,
    syncs: usize = 0,
    fail_sync_once: bool = false,

    fn backend(self: *FakeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn applyOpaque(context: *anyopaque, _: ReplicaBinding, offset: u64, data: []const u8) !void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        @memcpy(self.bytes[start..][0..data.len], data);
        self.writes += 1;
        self.syncs += 1;
        if (self.fail_sync_once) {
            self.fail_sync_once = false;
            return error.InjectedSyncFailure;
        }
    }

    const vtable: Backend.VTable = .{ .apply = applyOpaque };
};

const FakeAdmission = struct {
    expected: AuthorityBinding,
    active: bool = true,

    fn admission(self: *FakeAdmission) Admission {
        return .{
            .context = self,
            .begin_fn = beginOpaque,
            .begin_replay_fn = beginReplayOpaque,
            .end_fn = endOpaque,
        };
    }

    fn beginOpaque(context: *anyopaque, authority: AuthorityBinding) !void {
        const self: *FakeAdmission = @ptrCast(@alignCast(context));
        if (!self.active) return error.LeaseNotAdmitting;
        if (!std.meta.eql(self.expected, authority)) return error.StaleAuthority;
    }

    fn beginReplayOpaque(context: *anyopaque, authority: AuthorityBinding) !void {
        const self: *FakeAdmission = @ptrCast(@alignCast(context));
        if (!std.meta.eql(self.expected, authority)) return error.AuthorityRejected;
    }

    fn endOpaque(_: *anyopaque) void {}
};

fn testId(value: u8) Id {
    var result: Id = @splat(0);
    result[0] = value;
    return result;
}

fn testAuthority() AuthorityBinding {
    return .{
        .volume_id = testId(1),
        .primary_placement_id = testId(2),
        .primary_node_id = testId(3),
        .lease_id = testId(4),
        .holder_boot_id = testId(5),
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 1,
        .activation_nonce = testId(6),
        .authority_digest = @splat(0x44),
    };
}

fn testReplica(member: u8) ReplicaBinding {
    return .{
        .volume_id = testId(1),
        .placement_id = testId(10 + member),
        .allocation_id = testId(20 + member),
        .generation = 1,
        .member_id = testId(member),
        .offset_bytes = 4096,
        .length_bytes = 64,
    };
}

fn testReplicaMembers() [3]Id {
    return .{ testId(1), testId(2), testId(3) };
}

fn testPrepare(authority: AuthorityBinding, data: []const u8) PrepareRequest {
    return .{ .write = .{
        .authority = authority,
        .replica_members = testReplicaMembers(),
        .sequence = 1,
        .transaction_id = testId(30),
        .previous_history_digest = @splat(0),
        .offset_bytes = 8,
        .length_bytes = data.len,
        .data_digest = digestData(data),
    }, .data = data };
}

fn structuralCertificate(local: PrepareAttestation) CommitCertificate {
    var remote = local;
    remote.member_id = testId(2);
    remote.prepare_digest[0] ^= 1;
    return .{ .attestations = .{ local, remote } };
}

fn testParticipant(
    member: u8,
    store: *MemoryStore,
    backend: *FakeBackend,
    admission: *FakeAdmission,
) !ParticipantCore {
    return Participant.init(
        testReplica(member),
        testReplicaMembers(),
        store.store(),
        backend.backend(),
        admission.admission(),
    );
}

test "opaque public Participant exposes metadata without Store state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
    defer store.deinit();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    const participant = try Participant.initFile(
        std.testing.allocator,
        testReplica(1),
        testReplicaMembers(),
        store,
        backend.backend(),
        admission.admission(),
    );
    defer participant.deinit();
    _ = try participant.prepare(testPrepare(testAuthority(), "opaque"));
    const inspection = try participant.inspect();
    try std.testing.expect(inspection.pending != null);
    try std.testing.expect(!inspection.pending.?.commit_decided);
}

test "public Participant persists immutable binding before the first PREPARE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    {
        const store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        const participant = try Participant.initFile(
            std.testing.allocator,
            testReplica(1),
            testReplicaMembers(),
            store,
            backend.backend(),
            admission.admission(),
        );
        defer participant.deinit();
        try std.testing.expectEqual(
            ParticipantBinding{ .replica = testReplica(1), .replica_members = testReplicaMembers() },
            (try store.binding()).?,
        );
        try std.testing.expect((try participant.inspect()).pending == null);
    }
    {
        const store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        try std.testing.expectEqual(
            ParticipantBinding{ .replica = testReplica(1), .replica_members = testReplicaMembers() },
            (try store.binding()).?,
        );
        try std.testing.expectError(
            error.ReplicaStateMismatch,
            Participant.initFile(
                std.testing.allocator,
                testReplica(2),
                testReplicaMembers(),
                store,
                backend.backend(),
                admission.admission(),
            ),
        );
    }
}

test "FileStore persists prepare apply and idempotent completion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    const request = testPrepare(testAuthority(), "persist");
    var prepared: PrepareAttestation = undefined;
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        var participant = try Participant.init(testReplica(1), testReplicaMembers(), store.store(), backend.backend(), admission.admission());
        prepared = try participant.prepare(request);
        try std.testing.expect((try participant.inspect()).pending != null);
    }
    var result: CommitResult = undefined;
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        var participant = try Participant.init(testReplica(1), testReplicaMembers(), store.store(), backend.backend(), admission.admission());
        result = try participant.commit(request.write.transaction_id, structuralCertificate(prepared));
        try std.testing.expectEqualStrings("persist", backend.bytes[8..15]);
    }
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        var participant = try Participant.init(testReplica(1), testReplicaMembers(), store.store(), backend.backend(), admission.admission());
        const inspection = try participant.inspect();
        try std.testing.expect(inspection.pending == null);
        try std.testing.expectEqual(result, inspection.last_completed.?);
        try std.testing.expectEqual(result, try participant.commit(request.write.transaction_id, structuralCertificate(prepared)));
        try std.testing.expectEqual(prepared, try participant.prepare(request));
    }
}

test "two FileStores persist prepare and certificate quorum evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend_a: FakeBackend = .{};
    var backend_b: FakeBackend = .{};
    var admission_a: FakeAdmission = .{ .expected = testAuthority() };
    var admission_b: FakeAdmission = .{ .expected = testAuthority() };
    const request = testPrepare(testAuthority(), "quorum");
    var result: CommitResult = undefined;
    {
        var store_a = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "a.state");
        defer store_a.deinit();
        var store_b = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "b.state");
        defer store_b.deinit();
        var a = try Participant.init(testReplica(1), testReplicaMembers(), store_a.store(), backend_a.backend(), admission_a.admission());
        var b = try Participant.init(testReplica(2), testReplicaMembers(), store_b.store(), backend_b.backend(), admission_b.admission());
        const prepared_a = try a.prepare(request);
        const prepared_b = try b.prepare(request);
        const certificate: CommitCertificate = .{ .attestations = .{ prepared_a, prepared_b } };
        result = try a.commit(request.write.transaction_id, certificate);
        try std.testing.expectEqual(result, try b.commit(request.write.transaction_id, certificate));
    }
    {
        var store_a = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "a.state");
        defer store_a.deinit();
        var store_b = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "b.state");
        defer store_b.deinit();
        var a = try Participant.init(testReplica(1), testReplicaMembers(), store_a.store(), backend_a.backend(), admission_a.admission());
        var b = try Participant.init(testReplica(2), testReplicaMembers(), store_b.store(), backend_b.backend(), admission_b.admission());
        const inspection_a = try a.inspect();
        const inspection_b = try b.inspect();
        try std.testing.expectEqual(result, inspection_a.last_completed.?);
        try std.testing.expectEqual(result, inspection_b.last_completed.?);
        try std.testing.expectEqual(inspection_a.frontier, inspection_b.frontier);
    }
}

test "FileStore binds persisted state and ownership to one Replica" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    const request = testPrepare(testAuthority(), "binding");
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        try std.testing.expectError(
            error.StateFileLocked,
            FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state"),
        );
        var participant = try Participant.init(testReplica(1), testReplicaMembers(), store.store(), backend.backend(), admission.admission());
        _ = try participant.prepare(request);
    }
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        try std.testing.expectError(
            error.ReplicaStateMismatch,
            Participant.init(testReplica(2), testReplicaMembers(), store.store(), backend.backend(), admission.admission()),
        );
    }
}

test "FileStore retries a durable certificate after lease expiry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{ .fail_sync_once = true };
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    const request = testPrepare(testAuthority(), "recover");
    var certificate: CommitCertificate = undefined;
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        var participant = try Participant.init(testReplica(1), testReplicaMembers(), store.store(), backend.backend(), admission.admission());
        const prepared = try participant.prepare(request);
        certificate = structuralCertificate(prepared);
        try std.testing.expectError(
            error.InjectedSyncFailure,
            participant.commit(request.write.transaction_id, certificate),
        );
        try std.testing.expect((try participant.inspect()).pending.?.commit_decided);
    }
    admission.active = false;
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        var participant = try Participant.init(testReplica(1), testReplicaMembers(), store.store(), backend.backend(), admission.admission());
        const recovered = try participant.commit(request.write.transaction_id, certificate);
        try std.testing.expectEqual(@as(u64, 1), recovered.sequence);
        try std.testing.expectEqualStrings("recover", backend.bytes[8..15]);
    }
}

test "FileStore poisons uncertain directory sync and validates corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    {
        var faults: FileStore.Faults = .{ .fail_directory_sync_once = true };
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        store.setFaults(&faults);
        var participant = try Participant.init(testReplica(1), testReplicaMembers(), store.store(), backend.backend(), admission.admission());
        try std.testing.expectError(
            error.InjectedDirectorySyncFailure,
            participant.prepare(testPrepare(testAuthority(), "poison")),
        );
        try std.testing.expect(store.isPoisoned());
        try std.testing.expectError(error.StorePoisoned, participant.inspect());
    }
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state");
        defer store.deinit();
        var participant = try Participant.init(testReplica(1), testReplicaMembers(), store.store(), backend.backend(), admission.admission());
        try std.testing.expect((try participant.inspect()).pending != null);
    }
    const file = try tmp.dir.openFile(std.testing.io, "writes.state", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "X", 100);
    try std.testing.expectError(
        error.StoreCorrupt,
        FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "writes.state"),
    );
}

test "two distinct in-memory prepares certify and apply one write" {
    var store_a = MemoryStore.init(std.testing.allocator);
    defer store_a.deinit();
    var store_b = MemoryStore.init(std.testing.allocator);
    defer store_b.deinit();
    var backend_a: FakeBackend = .{};
    var backend_b: FakeBackend = .{};
    var admission_a: FakeAdmission = .{ .expected = testAuthority() };
    var admission_b: FakeAdmission = .{ .expected = testAuthority() };
    var a = try testParticipant(1, &store_a, &backend_a, &admission_a);
    var b = try testParticipant(2, &store_b, &backend_b, &admission_b);
    const request = testPrepare(testAuthority(), "durable");

    const prepared_a = try a.prepare(request);
    const prepared_b = try b.prepare(request);
    const certificate: CommitCertificate = .{ .attestations = .{ prepared_b, prepared_a } };
    const result_a = try a.commit(request.write.transaction_id, certificate);
    const result_b = try b.commit(request.write.transaction_id, certificate);

    try std.testing.expectEqual(@as(u64, 1), result_a.sequence);
    try std.testing.expectEqual(result_a, result_b);
    try std.testing.expectEqualStrings("durable", backend_a.bytes[8..15]);
    try std.testing.expectEqualStrings("durable", backend_b.bytes[8..15]);
    try std.testing.expectEqual(@as(usize, 1), backend_a.syncs);
    try std.testing.expectEqual(result_a, try a.commit(request.write.transaction_id, certificate));
    try std.testing.expectEqual(prepared_a, try a.prepare(request));
    try std.testing.expectEqual(@as(usize, 1), backend_a.syncs);

    var next = testPrepare(testAuthority(), "ordered");
    next.write.sequence = 2;
    next.write.transaction_id = testId(31);
    next.write.previous_history_digest = result_a.history_digest;
    next.write.data_digest = digestData(next.data);
    const next_a = try a.prepare(next);
    const next_b = try b.prepare(next);
    const next_certificate: CommitCertificate = .{ .attestations = .{ next_a, next_b } };
    const next_result = try a.commit(next.write.transaction_id, next_certificate);
    _ = try b.commit(next.write.transaction_id, next_certificate);
    try std.testing.expectEqual(@as(u64, 2), next_result.sequence);
    try std.testing.expect(!std.mem.eql(u8, &next_result.history_digest, &result_a.history_digest));
}

test "prepare enforces admission digest sequence and allocation bounds" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    var participant = try testParticipant(1, &store, &backend, &admission);

    var request = testPrepare(testAuthority(), "payload");
    request.write.data_digest[0] ^= 1;
    try std.testing.expectError(error.DataDigestMismatch, participant.prepare(request));
    request = testPrepare(testAuthority(), "payload");
    request.write.sequence = 2;
    request.write.previous_history_digest = @splat(1);
    try std.testing.expectError(error.SequenceMismatch, participant.prepare(request));
    request = testPrepare(testAuthority(), "payload");
    request.write.offset_bytes = 60;
    try std.testing.expectError(error.WriteOutOfBounds, participant.prepare(request));
    request = testPrepare(testAuthority(), "payload");
    admission.active = false;
    try std.testing.expectError(error.LeaseNotAdmitting, participant.prepare(request));
}

test "committed decision recovers without reviving the expired lease" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{ .fail_sync_once = true };
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    var participant = try testParticipant(1, &store, &backend, &admission);
    const request = testPrepare(testAuthority(), "recover");
    const local = try participant.prepare(request);
    var remote = local;
    remote.member_id = testId(2);
    remote.prepare_digest[0] ^= 1;
    const certificate: CommitCertificate = .{ .attestations = .{ local, remote } };

    try std.testing.expectError(
        error.InjectedSyncFailure,
        participant.commit(request.write.transaction_id, certificate),
    );
    try std.testing.expect(store.state.certificate != null);
    admission.active = false;
    const recovered = (try participant.recover()).?;
    try std.testing.expectEqual(@as(u64, 1), recovered.sequence);
    try std.testing.expectEqualStrings("recover", backend.bytes[8..15]);
    try std.testing.expectEqual(@as(usize, 2), backend.syncs);
}

test "certificate requires two distinct matching witnesses" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    var participant = try testParticipant(1, &store, &backend, &admission);
    const request = testPrepare(testAuthority(), "certify");
    const local = try participant.prepare(request);

    try std.testing.expectError(
        error.DuplicateWitness,
        participant.commit(request.write.transaction_id, .{ .attestations = .{ local, local } }),
    );
    var mismatched = local;
    mismatched.member_id = testId(2);
    mismatched.transaction_digest[0] ^= 1;
    try std.testing.expectError(
        error.CertificateMismatch,
        participant.commit(request.write.transaction_id, .{ .attestations = .{ local, mismatched } }),
    );

    var ineligible = local;
    ineligible.member_id = testId(4);
    ineligible.prepare_digest[0] ^= 1;
    try std.testing.expectError(
        error.CertificateMemberNotEligible,
        participant.commit(request.write.transaction_id, .{ .attestations = .{ local, ineligible } }),
    );

    var second = local;
    second.member_id = testId(2);
    second.prepare_digest[0] ^= 1;
    var third = local;
    third.member_id = testId(3);
    third.prepare_digest[0] ^= 2;
    try std.testing.expectError(
        error.LocalWitnessMissing,
        participant.commit(request.write.transaction_id, .{ .attestations = .{ second, third } }),
    );
}

test "completed state binds its local attestation to the Replica member" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    var participant = try testParticipant(1, &store, &backend, &admission);
    const request = testPrepare(testAuthority(), "member");
    const local = try participant.prepare(request);
    _ = try participant.commit(request.write.transaction_id, structuralCertificate(local));
    store.state.last_completed.?.attestation.member_id = testId(2);
    try std.testing.expectError(error.StoreCorrupt, validateStoredState(store.state));
}

test "apply rejects store state rebound after Participant initialization" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var admission: FakeAdmission = .{ .expected = testAuthority() };
    var participant = try testParticipant(1, &store, &backend, &admission);
    const request = testPrepare(testAuthority(), "binding");
    const local = try participant.prepare(request);
    store.state.pending.?.replica = testReplica(2);
    try std.testing.expectError(
        error.ReplicaStateMismatch,
        participant.commit(request.write.transaction_id, structuralCertificate(local)),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
}
