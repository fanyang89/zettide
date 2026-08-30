const std = @import("std");
const model = @import("model.zig");
const write_service = @import("write_service.zig");
const write_evidence = @import("write_evidence.zig");

pub const Id = model.Id;
pub const Digest = model.Digest;
pub const WriteRequest = write_service.WriteRequest;
pub const PrepareAttestation = write_service.PrepareAttestation;
pub const CommitCertificate = write_service.CommitCertificate;
pub const CommitResult = write_service.CommitResult;
pub const Frontier = write_service.Frontier;
pub const WitnessIdentity = write_evidence.WitnessIdentity;
pub const SignedPrepareEvidence = write_evidence.SignedPrepareEvidence;
pub const SignedCommitEvidence = write_evidence.SignedCommitEvidence;
pub const SignedCommitCertificate = write_evidence.SignedCommitCertificate;

pub const BeginRequest = struct {
    write: WriteRequest,
    data: []const u8,
    witnesses: [write_service.certificate_witness_count]Id,
};

pub const BeginResult = enum {
    started,
    retry,
    completed,
};

pub const PendingInspection = struct {
    write: WriteRequest,
    data: []const u8,
    witnesses: [write_service.certificate_witness_count]Id,
    prepare_evidence: [write_service.certificate_witness_count]?SignedPrepareEvidence,
    signed_certificate: ?SignedCommitCertificate,
    commit_evidence: [write_service.certificate_witness_count]?SignedCommitEvidence,
};

pub const CompletedInspection = struct {
    write: WriteRequest,
    witnesses: [write_service.certificate_witness_count]Id,
    prepare_evidence: [write_service.certificate_witness_count]SignedPrepareEvidence,
    signed_certificate: SignedCommitCertificate,
    commit_evidence: [write_service.certificate_witness_count]SignedCommitEvidence,
    result: CommitResult,
};

pub const Inspection = struct {
    identities: [3]WitnessIdentity,
    replica_members: [3]Id,
    frontier: Frontier,
    pending: ?PendingInspection,
    last_completed: ?CompletedInspection,
};

const Intent = struct {
    write: WriteRequest,
    data: []const u8,
    witnesses: [write_service.certificate_witness_count]Id,
    prepare_evidence: [write_service.certificate_witness_count]?SignedPrepareEvidence = .{ null, null },
};

const Decision = struct {
    certificate: CommitCertificate,
    commit_evidence: [write_service.certificate_witness_count]?SignedCommitEvidence = .{ null, null },
};

const Completed = struct {
    write: WriteRequest,
    witnesses: [write_service.certificate_witness_count]Id,
    prepare_evidence: [write_service.certificate_witness_count]SignedPrepareEvidence,
    certificate: CommitCertificate,
    commit_evidence: [write_service.certificate_witness_count]SignedCommitEvidence,
    result: CommitResult,
};

const State = struct {
    identities: ?[3]WitnessIdentity = null,
    frontier: Frontier = .{},
    intent: ?Intent = null,
    decision: ?Decision = null,
    last_completed: ?Completed = null,
};

const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        check_healthy: *const fn (*anyopaque) anyerror!void,
        current: *const fn (*anyopaque) State,
        save: *const fn (*anyopaque, State) anyerror!void,
    };

    fn checkHealthy(self: Store) !void {
        try self.vtable.check_healthy(self.context);
    }

    fn current(self: Store) State {
        return self.vtable.current(self.context);
    }

    fn save(self: Store, state: State) !void {
        try self.vtable.save(self.context, state);
    }
};

pub const Coordinator = opaque {
    pub fn initFile(
        allocator: std.mem.Allocator,
        identities: [3]WitnessIdentity,
        file_store: *FileStore,
    ) !*Coordinator {
        try write_evidence.validateIdentities(identities);
        try file_store.claim();
        errdefer file_store.release();
        try file_store.bind(identities);
        const managed = try allocator.create(ManagedCoordinator);
        errdefer allocator.destroy(managed);
        managed.* = .{
            .allocator = allocator,
            .file_store = file_store,
            .core = try CoordinatorCore.init(identities, file_store.store()),
        };
        return @ptrCast(managed);
    }

    pub fn deinit(self: *Coordinator) void {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        const allocator = managed.allocator;
        managed.file_store.release();
        managed.* = undefined;
        allocator.destroy(managed);
    }

    pub fn begin(self: *Coordinator, request: BeginRequest) !BeginResult {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        managed.lock();
        defer managed.mutex.unlock();
        return managed.core.begin(request);
    }

    pub fn recordPrepared(self: *Coordinator, evidence: SignedPrepareEvidence) !void {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        managed.lock();
        defer managed.mutex.unlock();
        try managed.core.recordPrepared(evidence);
    }

    pub fn decide(self: *Coordinator) !SignedCommitCertificate {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        managed.lock();
        defer managed.mutex.unlock();
        return managed.core.decide();
    }

    pub fn recordCommitted(self: *Coordinator, evidence: SignedCommitEvidence) !?CommitResult {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        managed.lock();
        defer managed.mutex.unlock();
        return managed.core.recordCommitted(evidence);
    }

    /// Returned payload storage is borrowed until the next mutation or deinit.
    pub fn inspect(self: *Coordinator) !Inspection {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        managed.lock();
        defer managed.mutex.unlock();
        return managed.core.inspect();
    }
};

const ManagedCoordinator = struct {
    allocator: std.mem.Allocator,
    file_store: *FileStore,
    mutex: std.atomic.Mutex = .unlocked,
    core: CoordinatorCore,

    fn lock(self: *ManagedCoordinator) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

const CoordinatorCore = struct {
    identities: [3]WitnessIdentity,
    replica_members: [3]Id,
    store: Store,

    fn init(identities: [3]WitnessIdentity, store: Store) !CoordinatorCore {
        try write_evidence.validateIdentities(identities);
        try store.checkHealthy();
        const state = store.current();
        try validateStoredState(state);
        const stored_identities = state.identities orelse return error.CoordinatorNotBound;
        if (!std.meta.eql(stored_identities, identities)) return error.CoordinatorBindingMismatch;
        return .{
            .identities = identities,
            .replica_members = write_evidence.members(identities),
            .store = store,
        };
    }

    fn begin(self: *CoordinatorCore, request_input: BeginRequest) !BeginResult {
        try self.store.checkHealthy();
        const witnesses = try normalizeWitnesses(request_input.witnesses, self.replica_members);
        const request: BeginRequest = .{ .write = request_input.write, .data = request_input.data, .witnesses = witnesses };
        try validateWriteEnvelope(self.replica_members, request.write, request.data);
        const current = self.store.current();
        try validateStoredState(current);

        if (current.intent) |intent| {
            if (sameIntent(intent, request)) return .retry;
            return error.WriteInProgress;
        }
        if (current.last_completed) |completed| {
            if (std.mem.eql(u8, &completed.write.transaction_id, &request.write.transaction_id)) {
                if (std.meta.eql(completed.write, request.write) and std.meta.eql(completed.witnesses, witnesses))
                    return .completed;
                return error.TransactionConflict;
            }
        }
        if (current.last_completed) |completed|
            try validateAuthorityProgression(completed.write.authority, request.write.authority);
        try validateBeginRequest(self.replica_members, current.frontier, request);
        var next = current;
        next.intent = .{ .write = request.write, .data = request.data, .witnesses = witnesses };
        next.decision = null;
        try validateStoredState(next);
        try self.store.save(next);
        return .started;
    }

    fn recordPrepared(self: *CoordinatorCore, evidence: SignedPrepareEvidence) !void {
        try self.store.checkHealthy();
        const current = self.store.current();
        try validateStoredState(current);
        const intent = current.intent orelse return error.NoWriteInProgress;
        const witness = evidence.attestation.member_id;
        const index = witnessIndex(intent.witnesses, witness) orelse return error.WitnessNotSelected;
        const identity = write_evidence.identityForMember(self.identities, witness) orelse return error.WitnessNotEligible;
        write_evidence.verifyPrepare(identity, intent.write, evidence) catch return error.UnverifiedPrepareEvidence;
        if (intent.prepare_evidence[index]) |existing| {
            if (!std.meta.eql(existing, evidence)) return error.EvidenceConflict;
            return;
        }
        if (current.decision != null) return error.DecisionStateCorrupt;
        var next = current;
        next.intent.?.prepare_evidence[index] = evidence;
        try validateStoredState(next);
        try self.store.save(next);
    }

    fn decide(self: *CoordinatorCore) !SignedCommitCertificate {
        try self.store.checkHealthy();
        const current = self.store.current();
        try validateStoredState(current);
        const intent = current.intent orelse return error.NoWriteInProgress;
        if (current.decision != null) return signedCertificateFromIntent(intent);
        const first = (intent.prepare_evidence[0] orelse return error.PrepareQuorumMissing).attestation;
        const second = (intent.prepare_evidence[1] orelse return error.PrepareQuorumMissing).attestation;
        const transaction_digest = write_service.digestTransaction(intent.write);
        // The journal retains the signed evidence, but the current participant
        // certificate still contains only its unsigned attestation projection.
        const certificate = try write_service.makeCommitCertificate(
            .{ first, second },
            transaction_digest,
            write_service.digestPreparedHistory(intent.write.previous_history_digest, transaction_digest),
            self.replica_members,
        );
        var next = current;
        next.decision = .{ .certificate = certificate };
        try validateStoredState(next);
        try self.store.save(next);
        return signedCertificateFromIntent(intent);
    }

    fn recordCommitted(self: *CoordinatorCore, evidence: SignedCommitEvidence) !?CommitResult {
        try self.store.checkHealthy();
        const current = self.store.current();
        try validateStoredState(current);
        const witness = evidence.member_id;
        const intent = current.intent orelse {
            if (current.last_completed) |completed| {
                const index = witnessIndex(completed.witnesses, witness) orelse return error.WitnessNotSelected;
                if (!std.meta.eql(completed.commit_evidence[index], evidence)) return error.CommitResultConflict;
                return completed.result;
            }
            return error.NoWriteInProgress;
        };
        const decision = current.decision orelse return error.CommitNotDecided;
        const index = witnessIndex(intent.witnesses, witness) orelse return error.WitnessNotSelected;
        const identity = write_evidence.identityForMember(self.identities, witness) orelse return error.WitnessNotEligible;
        write_evidence.verifyCommit(identity, intent.write, decision.certificate, evidence) catch
            return error.UnverifiedCommitEvidence;
        if (decision.commit_evidence[index]) |existing| {
            if (!std.meta.eql(existing, evidence)) return error.CommitResultConflict;
            return if (decision.commit_evidence[1 - index] != null) evidence.result else null;
        }

        var next = current;
        next.decision.?.commit_evidence[index] = evidence;
        if (next.decision.?.commit_evidence[0] != null and next.decision.?.commit_evidence[1] != null) {
            const first = next.decision.?.commit_evidence[0].?;
            const second = next.decision.?.commit_evidence[1].?;
            if (!std.meta.eql(first.result, second.result)) return error.CommitResultConflict;
            next.frontier = .{ .sequence = evidence.result.sequence, .history_digest = evidence.result.history_digest };
            next.last_completed = .{
                .write = intent.write,
                .witnesses = intent.witnesses,
                .prepare_evidence = .{ intent.prepare_evidence[0].?, intent.prepare_evidence[1].? },
                .certificate = decision.certificate,
                .commit_evidence = .{ first, second },
                .result = evidence.result,
            };
            next.intent = null;
            next.decision = null;
        }
        try validateStoredState(next);
        try self.store.save(next);
        return if (next.intent == null) evidence.result else null;
    }

    fn inspect(self: *CoordinatorCore) !Inspection {
        try self.store.checkHealthy();
        const current = self.store.current();
        try validateStoredState(current);
        return inspectionFromState(current);
    }
};

fn signedCertificateFromIntent(intent: Intent) !SignedCommitCertificate {
    const signed: SignedCommitCertificate = .{ .prepare_evidence = .{
        intent.prepare_evidence[0] orelse return error.PrepareQuorumMissing,
        intent.prepare_evidence[1] orelse return error.PrepareQuorumMissing,
    } };
    return write_evidence.normalizeSignedCertificate(signed);
}

fn inspectionFromState(state: State) Inspection {
    const identities = state.identities.?;
    const pending: ?PendingInspection = if (state.intent) |intent| .{
        .write = intent.write,
        .data = intent.data,
        .witnesses = intent.witnesses,
        .prepare_evidence = intent.prepare_evidence,
        .signed_certificate = if (state.decision != null) signedCertificateFromIntent(intent) catch unreachable else null,
        .commit_evidence = if (state.decision) |decision| decision.commit_evidence else .{ null, null },
    } else null;
    const completed: ?CompletedInspection = if (state.last_completed) |value| .{
        .write = value.write,
        .witnesses = value.witnesses,
        .prepare_evidence = value.prepare_evidence,
        .signed_certificate = .{ .prepare_evidence = value.prepare_evidence },
        .commit_evidence = value.commit_evidence,
        .result = value.result,
    } else null;
    return .{
        .identities = identities,
        .replica_members = write_evidence.members(identities),
        .frontier = state.frontier,
        .pending = pending,
        .last_completed = completed,
    };
}

fn validateWriteMetadata(replica_members: [3]Id, write: WriteRequest) !void {
    try write_service.validateCanonicalReplicaMembers(replica_members);
    if (!std.meta.eql(replica_members, write.replica_members)) return error.ReplicaSetMismatch;
    if (write.sequence == 0 or (write.sequence == 1) != isZero(&write.previous_history_digest) or
        isZero(&write.transaction_id) or isZero(&write.data_digest) or
        write.length_bytes == 0 or write.length_bytes > write_service.max_payload_size)
        return error.InvalidWrite;
    _ = std.math.add(u64, write.offset_bytes, write.length_bytes) catch return error.WriteOutOfBounds;
    try validateAuthority(write.authority);
}

fn validateWriteEnvelope(replica_members: [3]Id, write: WriteRequest, data: []const u8) !void {
    try validateWriteMetadata(replica_members, write);
    if (write.length_bytes != data.len or
        !std.mem.eql(u8, &write.data_digest, &write_service.digestData(data)))
        return error.InvalidWrite;
}

fn validateBeginRequest(replica_members: [3]Id, frontier: Frontier, request: BeginRequest) !void {
    try validateWriteEnvelope(replica_members, request.write, request.data);
    if (request.write.sequence == 0 or request.write.sequence != std.math.add(u64, frontier.sequence, 1) catch return error.SequenceOverflow)
        return error.SequenceMismatch;
    if (!std.mem.eql(u8, &request.write.previous_history_digest, &frontier.history_digest)) return error.HistoryMismatch;
    _ = try normalizeWitnesses(request.witnesses, replica_members);
}

fn validateAuthorityProgression(previous: model.AuthorityBinding, next: model.AuthorityBinding) !void {
    if (!std.mem.eql(u8, &previous.volume_id, &next.volume_id)) return error.VolumeMismatch;
    if (next.write_epoch < previous.write_epoch or
        next.authority_generation < previous.authority_generation or
        next.placement_revision < previous.placement_revision)
        return error.AuthorityRegression;
    if (next.write_epoch == previous.write_epoch and
        next.authority_generation == previous.authority_generation and
        next.placement_revision == previous.placement_revision and
        !std.meta.eql(previous, next))
        return error.AuthorityConflict;
}

fn validateAuthority(authority: model.AuthorityBinding) !void {
    if (isZero(&authority.volume_id) or isZero(&authority.primary_placement_id) or
        isZero(&authority.primary_node_id) or isZero(&authority.lease_id) or
        isZero(&authority.holder_boot_id) or authority.authority_generation == 0 or
        authority.write_epoch == 0 or authority.placement_revision == 0 or
        isZero(&authority.activation_nonce) or isZero(&authority.authority_digest))
        return error.InvalidAuthority;
}

fn normalizeWitnesses(input: [write_service.certificate_witness_count]Id, replica_members: [3]Id) ![write_service.certificate_witness_count]Id {
    var result = input;
    if (isZero(&result[0]) or isZero(&result[1]) or std.mem.eql(u8, &result[0], &result[1]))
        return error.InvalidWitnessSet;
    for (result) |witness| {
        var eligible = false;
        for (replica_members) |member| if (std.mem.eql(u8, &member, &witness)) {
            eligible = true;
            break;
        };
        if (!eligible) return error.WitnessNotEligible;
    }
    if (std.mem.order(u8, &result[1], &result[0]) == .lt) std.mem.swap(Id, &result[0], &result[1]);
    return result;
}

fn witnessIndex(witnesses: [write_service.certificate_witness_count]Id, witness: Id) ?usize {
    for (witnesses, 0..) |candidate, index| if (std.mem.eql(u8, &candidate, &witness)) return index;
    return null;
}

fn sameIntent(intent: Intent, request: BeginRequest) bool {
    return std.meta.eql(intent.write, request.write) and
        std.meta.eql(intent.witnesses, request.witnesses) and
        std.mem.eql(u8, intent.data, request.data);
}

fn validateStoredState(state: State) !void {
    const identities = state.identities orelse {
        if (state.intent != null or state.decision != null or state.last_completed != null or
            state.frontier.sequence != 0 or !isZero(&state.frontier.history_digest))
            return error.StoreCorrupt;
        return;
    };
    write_evidence.validateIdentities(identities) catch return error.StoreCorrupt;
    const replica_members = write_evidence.members(identities);
    if ((state.frontier.sequence == 0) != isZero(&state.frontier.history_digest)) return error.StoreCorrupt;
    if (state.intent == null and state.decision != null) return error.StoreCorrupt;
    if (state.intent) |intent| {
        validateBeginRequest(replica_members, state.frontier, .{
            .write = intent.write,
            .data = intent.data,
            .witnesses = intent.witnesses,
        }) catch return error.StoreCorrupt;
        for (intent.prepare_evidence, 0..) |evidence, index| if (evidence) |value| {
            const identity = write_evidence.identityForMember(identities, intent.witnesses[index]) orelse return error.StoreCorrupt;
            write_evidence.verifyPrepare(identity, intent.write, value) catch return error.StoreCorrupt;
        };
        if (state.decision) |decision| {
            const first = (intent.prepare_evidence[0] orelse return error.StoreCorrupt).attestation;
            const second = (intent.prepare_evidence[1] orelse return error.StoreCorrupt).attestation;
            const transaction_digest = write_service.digestTransaction(intent.write);
            const expected = write_service.makeCommitCertificate(
                .{ first, second },
                transaction_digest,
                write_service.digestPreparedHistory(intent.write.previous_history_digest, transaction_digest),
                replica_members,
            ) catch return error.StoreCorrupt;
            if (!std.meta.eql(expected, decision.certificate)) return error.StoreCorrupt;
            for (decision.commit_evidence, 0..) |evidence, index| if (evidence) |value| {
                const identity = write_evidence.identityForMember(identities, intent.witnesses[index]) orelse return error.StoreCorrupt;
                write_evidence.verifyCommit(identity, intent.write, decision.certificate, value) catch return error.StoreCorrupt;
            };
            if (decision.commit_evidence[0] != null and decision.commit_evidence[1] != null)
                return error.StoreCorrupt;
        }
    } else if (state.decision != null) return error.StoreCorrupt;

    if (state.last_completed) |completed| {
        validateWriteMetadata(replica_members, completed.write) catch return error.StoreCorrupt;
        const normalized_witnesses = normalizeWitnesses(completed.witnesses, replica_members) catch return error.StoreCorrupt;
        if (!std.meta.eql(normalized_witnesses, completed.witnesses) or
            !std.meta.eql(completed.write.replica_members, replica_members) or
            completed.write.sequence != state.frontier.sequence or
            !std.mem.eql(u8, &completed.result.transaction_id, &completed.write.transaction_id) or
            completed.result.sequence != completed.write.sequence or
            !std.mem.eql(u8, &completed.result.history_digest, &state.frontier.history_digest))
            return error.StoreCorrupt;
        const transaction_digest = write_service.digestTransaction(completed.write);
        const expected = write_service.makeCommitCertificate(
            .{ completed.prepare_evidence[0].attestation, completed.prepare_evidence[1].attestation },
            transaction_digest,
            write_service.digestPreparedHistory(completed.write.previous_history_digest, transaction_digest),
            replica_members,
        ) catch return error.StoreCorrupt;
        if (!std.meta.eql(expected, completed.certificate)) return error.StoreCorrupt;
        for (completed.prepare_evidence, 0..) |evidence, index| {
            if (!std.mem.eql(u8, &evidence.attestation.member_id, &completed.witnesses[index])) return error.StoreCorrupt;
            const identity = write_evidence.identityForMember(identities, completed.witnesses[index]) orelse return error.StoreCorrupt;
            write_evidence.verifyPrepare(identity, completed.write, evidence) catch return error.StoreCorrupt;
        }
        for (completed.commit_evidence, 0..) |evidence, index| {
            if (!std.mem.eql(u8, &evidence.member_id, &completed.witnesses[index]) or
                !std.meta.eql(evidence.result, completed.result)) return error.StoreCorrupt;
            const identity = write_evidence.identityForMember(identities, completed.witnesses[index]) orelse return error.StoreCorrupt;
            write_evidence.verifyCommit(identity, completed.write, completed.certificate, evidence) catch return error.StoreCorrupt;
        }
    } else if (state.frontier.sequence != 0) return error.StoreCorrupt;
    if (state.intent != null and state.last_completed != null)
        validateAuthorityProgression(state.last_completed.?.write.authority, state.intent.?.write.authority) catch return error.StoreCorrupt;
}

pub const FileStore = opaque {
    pub const Faults = FileStoreInner.Faults;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, basename: []const u8) !*FileStore {
        const inner = try allocator.create(FileStoreInner);
        errdefer allocator.destroy(inner);
        inner.* = try FileStoreInner.init(allocator, io, parent, basename);
        return @ptrCast(inner);
    }

    pub fn deinit(self: *FileStore) void {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        std.debug.assert(!inner.claimed.load(.acquire));
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

    fn claim(self: *FileStore) !void {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        if (inner.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
            return error.CoordinatorAlreadyAttached;
    }

    fn release(self: *FileStore) void {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        inner.claimed.store(false, .release);
    }

    fn bind(self: *FileStore, identities: [3]WitnessIdentity) !void {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        try inner.bind(identities);
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
    legacy_members: ?[3]Id = null,
    storage: []u8 = &.{},
    poisoned: bool = false,
    claimed: std.atomic.Value(bool) = .init(false),
    faults: ?*Faults = null,

    const magic = "ZETCOOR1".*;
    const version: u16 = 2;
    const legacy_version: u16 = 1;
    const metadata_size: usize = 4096;
    const legacy_metadata_size: usize = 2048;
    const checksum_size: usize = 4;
    const max_file_size: usize = metadata_size + write_service.max_payload_size + checksum_size;

    pub const Faults = struct {
        fail_write_once: bool = false,
        fail_file_sync_once: bool = false,
        fail_directory_sync_once: bool = false,
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, basename: []const u8) !FileStoreInner {
        const lock_basename = try std.fmt.allocPrint(allocator, "{s}.lock", .{basename});
        errdefer allocator.free(lock_basename);
        const lock_file = try parent.createFile(io, lock_basename, .{ .truncate = false });
        errdefer lock_file.close(io);
        if (!try lock_file.tryLock(io, .exclusive)) return error.StateFileLocked;
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
        if (bytes.len < 10 or !std.mem.eql(u8, bytes[0..8], &magic)) return error.StoreCorrupt;
        const file_version = std.mem.readInt(u16, bytes[8..10], .little);
        if (file_version == legacy_version) {
            const legacy_members = try decodePristineV1(bytes);
            return .{
                .allocator = allocator,
                .io = io,
                .parent = parent,
                .basename = basename,
                .lock_basename = lock_basename,
                .lock_file = lock_file,
                .legacy_members = legacy_members,
                .storage = bytes,
            };
        }
        if (file_version != version) return error.StoreCorrupt;
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

    fn deinit(self: *FileStoreInner) void {
        if (self.storage.len != 0) self.allocator.free(self.storage);
        self.lock_file.close(self.io);
        self.allocator.free(self.lock_basename);
        self.* = undefined;
    }

    fn store(self: *FileStoreInner) Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn bind(self: *FileStoreInner, identities: [3]WitnessIdentity) !void {
        if (self.poisoned) return error.StorePoisoned;
        try write_evidence.validateIdentities(identities);
        const replica_members = write_evidence.members(identities);
        if (self.legacy_members) |legacy| {
            if (!std.meta.eql(legacy, replica_members)) return error.CoordinatorBindingMismatch;
            const migrated = State{ .identities = identities };
            try validateStoredState(migrated);
            try self.install(migrated);
            self.legacy_members = null;
            return;
        }
        if (self.state.identities) |existing| {
            if (!std.meta.eql(existing, identities)) return error.CoordinatorBindingMismatch;
            return;
        }
        var next = self.state;
        next.identities = identities;
        try validateStoredState(next);
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

    fn saveOpaque(context: *anyopaque, state: State) !void {
        const self: *FileStoreInner = @ptrCast(@alignCast(context));
        if (self.poisoned) return error.StorePoisoned;
        if (self.legacy_members != null) return error.UnsignedCoordinatorState;
        try validateStoredState(state);
        try self.install(state);
    }

    const vtable: Store.VTable = .{
        .check_healthy = checkHealthyOpaque,
        .current = currentOpaque,
        .save = saveOpaque,
    };

    fn install(self: *FileStoreInner, state_input: State) !void {
        const bytes = try encodeSnapshot(self.allocator, state_input);
        var installed = false;
        errdefer if (!installed) self.allocator.free(bytes);
        var atomic_file = try self.parent.createFileAtomic(self.io, self.basename, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        if (self.faults) |faults| if (faults.fail_write_once) {
            faults.fail_write_once = false;
            return error.InjectedWriteFailure;
        };
        try atomic_file.file.writeStreamingAll(self.io, bytes);
        if (self.faults) |faults| if (faults.fail_file_sync_once) {
            faults.fail_file_sync_once = false;
            return error.InjectedFileSyncFailure;
        };
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
        self.syncParent() catch |err| {
            self.poisoned = true;
            return err;
        };
        var state = state_input;
        if (state.intent) |*intent| intent.data = snapshotPayload(bytes);
        const previous = self.storage;
        self.storage = bytes;
        self.state = state;
        installed = true;
        if (previous.len != 0) self.allocator.free(previous);
    }

    fn syncParent(self: *FileStoreInner) !void {
        if (self.faults) |faults| if (faults.fail_directory_sync_once) {
            faults.fail_directory_sync_once = false;
            return error.InjectedDirectorySyncFailure;
        };
        const parent_file = try self.parent.openFile(self.io, ".", .{ .mode = .read_only });
        defer parent_file.close(self.io);
        try parent_file.sync(self.io);
    }

    fn encodeSnapshot(allocator: std.mem.Allocator, state: State) ![]u8 {
        try validateStoredState(state);
        const payload = if (state.intent) |intent| intent.data else &.{};
        const bytes = try allocator.alloc(u8, metadata_size + payload.len + checksum_size);
        @memset(bytes, 0);
        @memcpy(bytes[0..8], &magic);
        std.mem.writeInt(u16, bytes[8..10], version, .little);
        bytes[10] = @intFromBool(state.intent != null);
        bytes[11] = @intFromBool(state.last_completed != null);
        std.mem.writeInt(u32, bytes[12..16], @intCast(payload.len), .little);
        std.mem.writeInt(u32, bytes[16..20], metadata_size, .little);
        var offset: usize = 24;
        if (state.identities) |identities| {
            for (identities) |identity| putIdentity(bytes, &offset, identity);
        } else {
            offset += identities_encoded_size;
        }
        putFrontier(bytes, &offset, state.frontier);
        if (state.intent) |intent| putIntent(bytes, &offset, intent, state.decision) else offset += intent_encoded_size;
        if (state.last_completed) |completed| putCompleted(bytes, &offset, completed) else offset += completed_encoded_size;
        if (offset > metadata_size) return error.StoreEncodingOverflow;
        @memcpy(bytes[metadata_size..][0..payload.len], payload);
        std.mem.writeInt(u32, bytes[bytes.len - checksum_size ..][0..checksum_size], std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - checksum_size]), .little);
        return bytes;
    }

    fn decodeSnapshot(bytes: []u8) !State {
        if (bytes.len < metadata_size + checksum_size or !std.mem.eql(u8, bytes[0..8], &magic) or
            std.mem.readInt(u16, bytes[8..10], .little) != version or
            std.mem.readInt(u32, bytes[16..20], .little) != metadata_size or !isZero(bytes[20..24]))
            return error.StoreCorrupt;
        const has_intent = bytes[10];
        const has_last = bytes[11];
        if (has_intent > 1 or has_last > 1) return error.StoreCorrupt;
        const payload_len = std.mem.readInt(u32, bytes[12..16], .little);
        if (payload_len > write_service.max_payload_size or bytes.len != metadata_size + @as(usize, payload_len) + checksum_size or
            (has_intent == 0 and payload_len != 0))
            return error.StoreCorrupt;
        if (std.mem.readInt(u32, bytes[bytes.len - checksum_size ..][0..checksum_size], .little) !=
            std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - checksum_size])) return error.StoreCorrupt;
        var offset: usize = 24;
        var state: State = .{
            .identities = .{ getIdentity(bytes, &offset), getIdentity(bytes, &offset), getIdentity(bytes, &offset) },
            .frontier = getFrontier(bytes, &offset),
        };
        if (has_intent == 1) {
            const decoded = try getIntent(bytes, &offset);
            state.intent = decoded.intent;
            state.intent.?.data = snapshotPayload(bytes);
            state.decision = decoded.decision;
        } else {
            if (!isZero(bytes[offset..][0..intent_encoded_size])) return error.StoreCorrupt;
            offset += intent_encoded_size;
        }
        if (has_last == 1) {
            state.last_completed = getCompleted(bytes, &offset);
        } else {
            if (!isZero(bytes[offset..][0..completed_encoded_size])) return error.StoreCorrupt;
            offset += completed_encoded_size;
        }
        if (!isZero(bytes[offset..metadata_size])) return error.StoreCorrupt;
        try validateStoredState(state);
        return state;
    }

    fn decodePristineV1(bytes: []u8) ![3]Id {
        const decoded = try decodeLegacyV1(bytes);
        if (!decoded.pristine) return error.UnsignedCoordinatorState;
        return decoded.replica_members;
    }

    fn snapshotPayload(bytes: []u8) []u8 {
        return bytes[metadata_size .. bytes.len - checksum_size];
    }
};

const authority_encoded_size: usize = 152;
const write_encoded_size: usize = authority_encoded_size + 3 * @sizeOf(Id) + 104;
const attestation_encoded_size: usize = 112;
const certificate_encoded_size: usize = 2 * attestation_encoded_size;
const result_encoded_size: usize = 56;
const identity_encoded_size: usize = 16 + 16 + 32 + 32;
const identities_encoded_size: usize = 3 * identity_encoded_size;
const prepare_evidence_encoded_size: usize = attestation_encoded_size + 16 + 32 + 64;
const commit_evidence_encoded_size: usize = 16 + 16 + 32 + result_encoded_size + 64;
const intent_encoded_size: usize = write_encoded_size + 2 * @sizeOf(Id) + 2 + 2 * prepare_evidence_encoded_size + 1 + certificate_encoded_size + 2 + 2 * commit_evidence_encoded_size;
const completed_encoded_size: usize = write_encoded_size + 2 * @sizeOf(Id) + 2 * prepare_evidence_encoded_size + certificate_encoded_size + 2 * commit_evidence_encoded_size + result_encoded_size;
const legacy_intent_encoded_size: usize = write_encoded_size + 2 * @sizeOf(Id) + 2 + 2 * attestation_encoded_size + 1 + certificate_encoded_size + 2 + 2 * result_encoded_size;
const legacy_completed_encoded_size: usize = write_encoded_size + 2 * @sizeOf(Id) + certificate_encoded_size + result_encoded_size;

fn putIntent(bytes: []u8, offset: *usize, intent: Intent, decision: ?Decision) void {
    putWrite(bytes, offset, intent.write);
    for (intent.witnesses) |witness| putBytes(bytes, offset, &witness);
    for (intent.prepare_evidence) |evidence| {
        bytes[offset.*] = @intFromBool(evidence != null);
        offset.* += 1;
    }
    for (intent.prepare_evidence) |evidence| {
        if (evidence) |value| putPrepareEvidence(bytes, offset, value) else offset.* += prepare_evidence_encoded_size;
    }
    bytes[offset.*] = @intFromBool(decision != null);
    offset.* += 1;
    if (decision) |value| putCertificate(bytes, offset, value.certificate) else offset.* += certificate_encoded_size;
    for (0..2) |index| {
        bytes[offset.*] = @intFromBool(decision != null and decision.?.commit_evidence[index] != null);
        offset.* += 1;
    }
    for (0..2) |index| {
        if (decision != null and decision.?.commit_evidence[index] != null)
            putCommitEvidence(bytes, offset, decision.?.commit_evidence[index].?)
        else
            offset.* += commit_evidence_encoded_size;
    }
}

const DecodedIntent = struct { intent: Intent, decision: ?Decision };

fn getIntent(bytes: []const u8, offset: *usize) !DecodedIntent {
    var intent: Intent = .{
        .write = getWrite(bytes, offset),
        .data = &.{},
        .witnesses = .{ getArray(16, bytes, offset), getArray(16, bytes, offset) },
    };
    const prepare_flags: [2]u8 = .{ bytes[offset.*], bytes[offset.* + 1] };
    offset.* += 2;
    for (prepare_flags) |flag| if (flag > 1) return error.StoreCorrupt;
    for (&intent.prepare_evidence, 0..) |*evidence, index| {
        const start = offset.*;
        const value = getPrepareEvidence(bytes, offset);
        if (prepare_flags[index] == 1) evidence.* = value else {
            if (!isZero(bytes[start..][0..prepare_evidence_encoded_size])) return error.StoreCorrupt;
            evidence.* = null;
        }
    }
    const has_decision = bytes[offset.*];
    offset.* += 1;
    if (has_decision > 1) return error.StoreCorrupt;
    const certificate_start = offset.*;
    const certificate = getCertificate(bytes, offset);
    if (has_decision == 0 and !isZero(bytes[certificate_start..][0..certificate_encoded_size])) return error.StoreCorrupt;
    const commit_flags: [2]u8 = .{ bytes[offset.*], bytes[offset.* + 1] };
    offset.* += 2;
    for (commit_flags) |flag| if (flag > 1) return error.StoreCorrupt;
    if (has_decision == 0 and (commit_flags[0] != 0 or commit_flags[1] != 0)) return error.StoreCorrupt;
    var commit_evidence: [2]?SignedCommitEvidence = .{ null, null };
    for (&commit_evidence, 0..) |*evidence, index| {
        const start = offset.*;
        const value = getCommitEvidence(bytes, offset);
        if (commit_flags[index] == 1) evidence.* = value else if (!isZero(bytes[start..][0..commit_evidence_encoded_size])) return error.StoreCorrupt;
    }
    const decision: ?Decision = if (has_decision == 1) .{ .certificate = certificate, .commit_evidence = commit_evidence } else null;
    return .{ .intent = intent, .decision = decision };
}

fn putCompleted(bytes: []u8, offset: *usize, completed: Completed) void {
    putWrite(bytes, offset, completed.write);
    for (completed.witnesses) |witness| putBytes(bytes, offset, &witness);
    for (completed.prepare_evidence) |evidence| putPrepareEvidence(bytes, offset, evidence);
    putCertificate(bytes, offset, completed.certificate);
    for (completed.commit_evidence) |evidence| putCommitEvidence(bytes, offset, evidence);
    putResult(bytes, offset, completed.result);
}

fn getCompleted(bytes: []const u8, offset: *usize) Completed {
    return .{
        .write = getWrite(bytes, offset),
        .witnesses = .{ getArray(16, bytes, offset), getArray(16, bytes, offset) },
        .prepare_evidence = .{ getPrepareEvidence(bytes, offset), getPrepareEvidence(bytes, offset) },
        .certificate = getCertificate(bytes, offset),
        .commit_evidence = .{ getCommitEvidence(bytes, offset), getCommitEvidence(bytes, offset) },
        .result = getResult(bytes, offset),
    };
}

fn putIdentity(bytes: []u8, offset: *usize, identity: WitnessIdentity) void {
    putBytes(bytes, offset, &identity.member_id);
    putBytes(bytes, offset, &identity.node_id);
    putBytes(bytes, offset, &identity.key_id);
    putBytes(bytes, offset, &identity.public_key);
}

fn getIdentity(bytes: []const u8, offset: *usize) WitnessIdentity {
    return .{
        .member_id = getArray(16, bytes, offset),
        .node_id = getArray(16, bytes, offset),
        .key_id = getArray(32, bytes, offset),
        .public_key = getArray(32, bytes, offset),
    };
}

fn putPrepareEvidence(bytes: []u8, offset: *usize, evidence: SignedPrepareEvidence) void {
    putAttestation(bytes, offset, evidence.attestation);
    putBytes(bytes, offset, &evidence.signer_node_id);
    putBytes(bytes, offset, &evidence.key_id);
    putBytes(bytes, offset, &evidence.signature);
}

fn getPrepareEvidence(bytes: []const u8, offset: *usize) SignedPrepareEvidence {
    return .{
        .attestation = getAttestation(bytes, offset),
        .signer_node_id = getArray(16, bytes, offset),
        .key_id = getArray(32, bytes, offset),
        .signature = getArray(64, bytes, offset),
    };
}

fn putCommitEvidence(bytes: []u8, offset: *usize, evidence: SignedCommitEvidence) void {
    putBytes(bytes, offset, &evidence.member_id);
    putBytes(bytes, offset, &evidence.signer_node_id);
    putBytes(bytes, offset, &evidence.key_id);
    putResult(bytes, offset, evidence.result);
    putBytes(bytes, offset, &evidence.signature);
}

fn getCommitEvidence(bytes: []const u8, offset: *usize) SignedCommitEvidence {
    return .{
        .member_id = getArray(16, bytes, offset),
        .signer_node_id = getArray(16, bytes, offset),
        .key_id = getArray(32, bytes, offset),
        .result = getResult(bytes, offset),
        .signature = getArray(64, bytes, offset),
    };
}

fn putFrontier(bytes: []u8, offset: *usize, frontier: Frontier) void {
    putU64(bytes, offset, frontier.sequence);
    putBytes(bytes, offset, &frontier.history_digest);
}

fn getFrontier(bytes: []const u8, offset: *usize) Frontier {
    return .{ .sequence = getU64(bytes, offset), .history_digest = getArray(32, bytes, offset) };
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
        .replica_members = .{ getArray(16, bytes, offset), getArray(16, bytes, offset), getArray(16, bytes, offset) },
        .sequence = getU64(bytes, offset),
        .transaction_id = getArray(16, bytes, offset),
        .previous_history_digest = getArray(32, bytes, offset),
        .offset_bytes = getU64(bytes, offset),
        .length_bytes = getU64(bytes, offset),
        .data_digest = getArray(32, bytes, offset),
    };
}

fn putAuthority(bytes: []u8, offset: *usize, authority: model.AuthorityBinding) void {
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

fn getAuthority(bytes: []const u8, offset: *usize) model.AuthorityBinding {
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
    return .{ .attestations = .{ getAttestation(bytes, offset), getAttestation(bytes, offset) } };
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

const DecodedLegacyV1 = struct {
    replica_members: [3]Id,
    pristine: bool,
};

fn decodeLegacyV1(bytes: []const u8) !DecodedLegacyV1 {
    if (bytes.len < FileStoreInner.legacy_metadata_size + FileStoreInner.checksum_size or
        std.mem.readInt(u16, bytes[8..10], .little) != FileStoreInner.legacy_version or
        std.mem.readInt(u32, bytes[16..20], .little) != FileStoreInner.legacy_metadata_size or
        !isZero(bytes[20..24])) return error.StoreCorrupt;
    const has_intent = bytes[10];
    const has_last = bytes[11];
    if (has_intent > 1 or has_last > 1) return error.StoreCorrupt;
    const payload_len: usize = std.mem.readInt(u32, bytes[12..16], .little);
    if (payload_len > write_service.max_payload_size or
        bytes.len != FileStoreInner.legacy_metadata_size + payload_len + FileStoreInner.checksum_size) return error.StoreCorrupt;
    if (std.mem.readInt(u32, bytes[bytes.len - FileStoreInner.checksum_size ..][0..FileStoreInner.checksum_size], .little) !=
        std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - FileStoreInner.checksum_size])) return error.StoreCorrupt;

    var offset: usize = 24;
    const replica_members: [3]Id = .{ getArray(16, bytes, &offset), getArray(16, bytes, &offset), getArray(16, bytes, &offset) };
    const frontier = getFrontier(bytes, &offset);
    write_service.validateCanonicalReplicaMembers(replica_members) catch return error.StoreCorrupt;
    const payload = bytes[FileStoreInner.legacy_metadata_size .. FileStoreInner.legacy_metadata_size + payload_len];

    var intent_write: ?WriteRequest = null;
    if (has_intent == 1) {
        const write = getWrite(bytes, &offset);
        const witnesses: [2]Id = .{ getArray(16, bytes, &offset), getArray(16, bytes, &offset) };
        validateLegacyWrite(replica_members, write, payload) catch return error.StoreCorrupt;
        validateLegacyWitnesses(replica_members, witnesses) catch return error.StoreCorrupt;
        const prepare_flags: [2]u8 = .{ bytes[offset], bytes[offset + 1] };
        offset += 2;
        if (prepare_flags[0] > 1 or prepare_flags[1] > 1) return error.StoreCorrupt;
        var attestations: [2]?PrepareAttestation = .{ null, null };
        for (&attestations, 0..) |*attestation, index| {
            const start = offset;
            const value = getAttestation(bytes, &offset);
            if (prepare_flags[index] == 1) {
                validateLegacyAttestation(write, witnesses[index], value) catch return error.StoreCorrupt;
                attestation.* = value;
            } else if (!isZero(bytes[start..offset])) return error.StoreCorrupt;
        }
        const has_decision = bytes[offset];
        offset += 1;
        if (has_decision > 1) return error.StoreCorrupt;
        const certificate_start = offset;
        const certificate = getCertificate(bytes, &offset);
        const commit_flags: [2]u8 = .{ bytes[offset], bytes[offset + 1] };
        offset += 2;
        if (commit_flags[0] > 1 or commit_flags[1] > 1 or
            (has_decision == 0 and (commit_flags[0] != 0 or commit_flags[1] != 0)) or
            (commit_flags[0] == 1 and commit_flags[1] == 1)) return error.StoreCorrupt;
        if (has_decision == 1) {
            if (attestations[0] == null or attestations[1] == null) return error.StoreCorrupt;
            const expected = write_service.makeCommitCertificate(
                .{ attestations[0].?, attestations[1].? },
                write_service.digestTransaction(write),
                write_service.digestPreparedHistory(write.previous_history_digest, write_service.digestTransaction(write)),
                replica_members,
            ) catch return error.StoreCorrupt;
            if (!std.meta.eql(expected, certificate)) return error.StoreCorrupt;
        } else if (!isZero(bytes[certificate_start..][0..certificate_encoded_size])) return error.StoreCorrupt;
        for (commit_flags) |flag| {
            const start = offset;
            const result = getResult(bytes, &offset);
            if (flag == 1) {
                if (has_decision == 0) return error.StoreCorrupt;
                validateLegacyResult(write, certificate, result) catch return error.StoreCorrupt;
            } else if (!isZero(bytes[start..offset])) return error.StoreCorrupt;
        }
        intent_write = write;
    } else {
        if (payload_len != 0 or !isZero(bytes[offset..][0..legacy_intent_encoded_size])) return error.StoreCorrupt;
        offset += legacy_intent_encoded_size;
    }

    var completed_write: ?WriteRequest = null;
    var completed_result: ?CommitResult = null;
    if (has_last == 1) {
        const write = getWrite(bytes, &offset);
        const witnesses: [2]Id = .{ getArray(16, bytes, &offset), getArray(16, bytes, &offset) };
        const certificate = getCertificate(bytes, &offset);
        const result = getResult(bytes, &offset);
        validateLegacyWriteMetadata(replica_members, write) catch return error.StoreCorrupt;
        validateLegacyWitnesses(replica_members, witnesses) catch return error.StoreCorrupt;
        if (!std.mem.eql(u8, &certificate.attestations[0].member_id, &witnesses[0]) or
            !std.mem.eql(u8, &certificate.attestations[1].member_id, &witnesses[1])) return error.StoreCorrupt;
        _ = write_service.makeCommitCertificate(
            certificate.attestations,
            write_service.digestTransaction(write),
            write_service.digestPreparedHistory(write.previous_history_digest, write_service.digestTransaction(write)),
            replica_members,
        ) catch return error.StoreCorrupt;
        validateLegacyResult(write, certificate, result) catch return error.StoreCorrupt;
        completed_write = write;
        completed_result = result;
    } else {
        if (!isZero(bytes[offset..][0..legacy_completed_encoded_size])) return error.StoreCorrupt;
        offset += legacy_completed_encoded_size;
    }
    if (offset > FileStoreInner.legacy_metadata_size or !isZero(bytes[offset..FileStoreInner.legacy_metadata_size])) return error.StoreCorrupt;
    if (completed_result) |result| {
        if (frontier.sequence != result.sequence or !std.mem.eql(u8, &frontier.history_digest, &result.history_digest)) return error.StoreCorrupt;
    } else if (frontier.sequence != 0 or !isZero(&frontier.history_digest)) return error.StoreCorrupt;
    if (intent_write) |write| {
        const expected_sequence = std.math.add(u64, frontier.sequence, 1) catch return error.StoreCorrupt;
        if (write.sequence != expected_sequence or
            !std.mem.eql(u8, &write.previous_history_digest, &frontier.history_digest)) return error.StoreCorrupt;
        if (completed_write) |completed|
            validateAuthorityProgression(completed.authority, write.authority) catch return error.StoreCorrupt;
    }
    return .{ .replica_members = replica_members, .pristine = has_intent == 0 and has_last == 0 };
}

fn validateLegacyWitnesses(replica_members: [3]Id, witnesses: [2]Id) !void {
    const normalized = normalizeWitnesses(witnesses, replica_members) catch return error.StoreCorrupt;
    if (!std.meta.eql(normalized, witnesses)) return error.StoreCorrupt;
}

fn validateLegacyWriteMetadata(replica_members: [3]Id, write: WriteRequest) !void {
    validateWriteMetadata(replica_members, write) catch return error.StoreCorrupt;
}

fn validateLegacyWrite(replica_members: [3]Id, write: WriteRequest, payload: []const u8) !void {
    try validateLegacyWriteMetadata(replica_members, write);
    if (payload.len == 0 or payload.len != write.length_bytes or
        !std.mem.eql(u8, &write.data_digest, &write_service.digestData(payload))) return error.StoreCorrupt;
}

fn validateLegacyAttestation(write: WriteRequest, witness: Id, attestation: PrepareAttestation) !void {
    const transaction_digest = write_service.digestTransaction(write);
    if (!std.mem.eql(u8, &attestation.member_id, &witness) or
        !std.mem.eql(u8, &attestation.transaction_digest, &transaction_digest) or
        isZero(&attestation.prepare_digest) or
        !std.mem.eql(u8, &attestation.prepared_history_digest, &write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest))) return error.StoreCorrupt;
}

fn validateLegacyResult(write: WriteRequest, certificate: CommitCertificate, result: CommitResult) !void {
    const prepared_history = write_service.digestPreparedHistory(write.previous_history_digest, write_service.digestTransaction(write));
    if (!std.mem.eql(u8, &result.transaction_id, &write.transaction_id) or result.sequence != write.sequence or
        !std.mem.eql(u8, &result.history_digest, &write_service.digestCommitHistory(prepared_history, certificate))) return error.StoreCorrupt;
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

fn isZero(value: []const u8) bool {
    for (value) |byte| if (byte != 0) return false;
    return true;
}

// Tests intentionally use only FileStore: it is both the durable baseline and
// exercises that the public coordinator never retains caller-owned payload.
fn testId(value: u8) Id {
    var result: Id = @splat(0);
    result[15] = value;
    return result;
}

fn testMembers() [3]Id {
    return .{ testId(1), testId(2), testId(3) };
}

const TestSigners = struct {
    values: [3]*write_evidence.Signer,
    identities: [3]WitnessIdentity,

    fn init() !TestSigners {
        var result: TestSigners = undefined;
        var initialized: usize = 0;
        errdefer for (result.values[0..initialized]) |signer| signer.deinit();
        for (&result.values, 0..) |*signer, index| {
            signer.* = try write_evidence.Signer.init(
                std.testing.allocator,
                testId(@intCast(index + 1)),
                testId(@intCast(index + 31)),
                &@as(write_evidence.Seed, @splat(@intCast(index + 17))),
            );
            initialized += 1;
            result.identities[index] = signer.*.identity();
        }
        return result;
    }

    fn deinit(self: *TestSigners) void {
        for (self.values) |signer| signer.deinit();
        self.* = undefined;
    }

    fn prepare(self: *TestSigners, index: usize, write: WriteRequest, salt: u8) !SignedPrepareEvidence {
        return self.values[index].signPrepare(write, testAttestation(write, testId(@intCast(index + 1)), salt));
    }

    fn commit(self: *TestSigners, index: usize, write: WriteRequest, signed_certificate: SignedCommitCertificate) !SignedCommitEvidence {
        const certificate = try write_evidence.certificateProjection(signed_certificate);
        return self.values[index].signCommit(write, certificate, testCommitResult(write, certificate));
    }
};

fn testBegin(
    sequence: u64,
    previous_history_digest: Digest,
    transaction_salt: u8,
    data: []const u8,
    witnesses: [2]Id,
) BeginRequest {
    return .{
        .write = .{
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
            .replica_members = testMembers(),
            .sequence = sequence,
            .transaction_id = testId(transaction_salt),
            .previous_history_digest = previous_history_digest,
            .offset_bytes = 0,
            .length_bytes = data.len,
            .data_digest = write_service.digestData(data),
        },
        .data = data,
        .witnesses = witnesses,
    };
}

fn testAttestation(write: WriteRequest, member_id: Id, salt: u8) PrepareAttestation {
    const transaction_digest = write_service.digestTransaction(write);
    return .{
        .member_id = member_id,
        .transaction_digest = transaction_digest,
        .prepare_digest = @splat(salt),
        .prepared_history_digest = write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest),
    };
}

fn testCommitResult(write: WriteRequest, certificate: CommitCertificate) CommitResult {
    return .{
        .transaction_id = write.transaction_id,
        .sequence = write.sequence,
        .history_digest = write_service.digestCommitHistory(
            write_service.digestPreparedHistory(write.previous_history_digest, write_service.digestTransaction(write)),
            certificate,
        ),
    };
}

const TestHarness = struct {
    tmp: std.testing.TmpDir,
    signers: TestSigners,
    store: *FileStore,
    coordinator: *Coordinator,

    fn init() !TestHarness {
        var result: TestHarness = undefined;
        result.tmp = std.testing.tmpDir(.{});
        errdefer result.tmp.cleanup();
        result.signers = try TestSigners.init();
        errdefer result.signers.deinit();
        result.store = try FileStore.init(std.testing.allocator, std.testing.io, result.tmp.dir, "coordinator.state");
        errdefer result.store.deinit();
        result.coordinator = try Coordinator.initFile(std.testing.allocator, result.signers.identities, result.store);
        return result;
    }

    fn deinit(self: *TestHarness) void {
        self.coordinator.deinit();
        self.store.deinit();
        self.signers.deinit();
        self.tmp.cleanup();
    }

    fn reopen(self: *TestHarness) !void {
        self.coordinator.deinit();
        self.store.deinit();
        self.store = try FileStore.init(std.testing.allocator, std.testing.io, self.tmp.dir, "coordinator.state");
        self.coordinator = try Coordinator.initFile(std.testing.allocator, self.signers.identities, self.store);
    }
};

const MutationStage = enum { intent, first_prepare, second_prepare, decision, partial_commit, completion };
const FaultKind = enum { write, file_sync, directory_sync };

fn setupBeforeMutation(harness: *TestHarness, request: BeginRequest, stage: MutationStage) !void {
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.intent)) _ = try harness.coordinator.begin(request);
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.first_prepare))
        try harness.coordinator.recordPrepared(try harness.signers.prepare(0, request.write, 1));
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.second_prepare))
        try harness.coordinator.recordPrepared(try harness.signers.prepare(1, request.write, 2));
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.decision)) _ = try harness.coordinator.decide();
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.partial_commit)) {
        const certificate = (try harness.coordinator.inspect()).pending.?.signed_certificate.?;
        _ = try harness.coordinator.recordCommitted(try harness.signers.commit(0, request.write, certificate));
    }
}

fn applyMutation(harness: *TestHarness, request: BeginRequest, stage: MutationStage) !void {
    switch (stage) {
        .intent => _ = try harness.coordinator.begin(request),
        .first_prepare => try harness.coordinator.recordPrepared(try harness.signers.prepare(0, request.write, 1)),
        .second_prepare => try harness.coordinator.recordPrepared(try harness.signers.prepare(1, request.write, 2)),
        .decision => _ = try harness.coordinator.decide(),
        .partial_commit => {
            const certificate = (try harness.coordinator.inspect()).pending.?.signed_certificate.?;
            _ = try harness.coordinator.recordCommitted(try harness.signers.commit(0, request.write, certificate));
        },
        .completion => {
            const certificate = (try harness.coordinator.inspect()).pending.?.signed_certificate.?;
            _ = try harness.coordinator.recordCommitted(try harness.signers.commit(1, request.write, certificate));
        },
    }
}

fn mutationReached(coordinator: *Coordinator, stage: MutationStage) !bool {
    const inspection = try coordinator.inspect();
    return switch (stage) {
        .intent => inspection.pending != null,
        .first_prepare => inspection.pending.?.prepare_evidence[0] != null,
        .second_prepare => inspection.pending.?.prepare_evidence[1] != null,
        .decision => inspection.pending.?.signed_certificate != null,
        .partial_commit => inspection.pending.?.commit_evidence[0] != null,
        .completion => inspection.pending == null and inspection.frontier.sequence == 1,
    };
}

test "canonical signed identities and fixed witnesses are validated" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{1} ** 4096;
    var invalid = testBegin(1, @splat(0), 20, &data, .{ testId(1), testId(1) });
    try std.testing.expectError(error.InvalidWitnessSet, harness.coordinator.begin(invalid));
    invalid.witnesses = .{ testId(1), testId(4) };
    try std.testing.expectError(error.WitnessNotEligible, harness.coordinator.begin(invalid));
    var wrong = harness.signers.identities;
    wrong[1].node_id = wrong[0].node_id;
    const tmp_store = try FileStore.init(std.testing.allocator, std.testing.io, harness.tmp.dir, "other.state");
    defer tmp_store.deinit();
    try std.testing.expectError(error.DuplicateSignerNode, Coordinator.initFile(std.testing.allocator, wrong, tmp_store));
    var weak = harness.signers.identities;
    weak[1].public_key = @splat(0);
    weak[1].public_key[0] = 1;
    weak[1].key_id = write_evidence.keyId(weak[1].public_key);
    try std.testing.expectError(error.InvalidWitnessIdentity, Coordinator.initFile(std.testing.allocator, weak, tmp_store));
}

test "one FileStore permits only one live Coordinator attachment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var signers = try TestSigners.init();
    defer signers.deinit();
    const store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state");
    defer store.deinit();
    const first = try Coordinator.initFile(std.testing.allocator, signers.identities, store);
    try std.testing.expectError(error.CoordinatorAlreadyAttached, Coordinator.initFile(std.testing.allocator, signers.identities, store));
    first.deinit();
    var wrong = signers.identities;
    wrong[2] = wrong[1];
    try std.testing.expectError(error.DuplicateSignerNode, Coordinator.initFile(std.testing.allocator, wrong, store));
    const second = try Coordinator.initFile(std.testing.allocator, signers.identities, store);
    second.deinit();
}

test "signed intent evidence decision and completion persist exact retries" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    var data = [_]u8{2} ** 4096;
    const expected = data;
    var request = testBegin(1, @splat(0), 21, &data, .{ testId(2), testId(1) });
    request.write.authority.write_epoch = 2;
    try std.testing.expectEqual(BeginResult.started, try harness.coordinator.begin(request));
    @memset(&data, 9);
    try std.testing.expectEqualSlices(u8, &expected, (try harness.coordinator.inspect()).pending.?.data);
    var retry = request;
    retry.data = &expected;
    try std.testing.expectEqual(BeginResult.retry, try harness.coordinator.begin(retry));
    var switched = retry;
    switched.witnesses = .{ testId(1), testId(3) };
    try std.testing.expectError(error.WriteInProgress, harness.coordinator.begin(switched));
    var conflict = retry;
    conflict.write.offset_bytes = 4096;
    try std.testing.expectError(error.WriteInProgress, harness.coordinator.begin(conflict));
    try harness.reopen();
    const prepare_a = try harness.signers.prepare(0, request.write, 1);
    try harness.coordinator.recordPrepared(prepare_a);
    try harness.coordinator.recordPrepared(prepare_a);
    const valid_conflicting_prepare = try harness.signers.prepare(0, request.write, 9);
    try std.testing.expectError(error.EvidenceConflict, harness.coordinator.recordPrepared(valid_conflicting_prepare));
    var conflicting_prepare = prepare_a;
    conflicting_prepare.signature[0] ^= 1;
    try std.testing.expectError(error.UnverifiedPrepareEvidence, harness.coordinator.recordPrepared(conflicting_prepare));
    try harness.coordinator.recordPrepared(try harness.signers.prepare(1, request.write, 2));
    const certificate = try harness.coordinator.decide();
    try std.testing.expectEqualDeep(certificate, (try harness.coordinator.inspect()).pending.?.signed_certificate.?);
    try harness.reopen();
    try std.testing.expectEqualDeep(certificate, (try harness.coordinator.inspect()).pending.?.signed_certificate.?);
    const commit_a = try harness.signers.commit(0, request.write, certificate);
    try std.testing.expect((try harness.coordinator.recordCommitted(commit_a)) == null);
    try std.testing.expect((try harness.coordinator.recordCommitted(commit_a)) == null);
    var conflicting_commit = commit_a;
    conflicting_commit.signature[0] ^= 1;
    try std.testing.expectError(error.UnverifiedCommitEvidence, harness.coordinator.recordCommitted(conflicting_commit));
    const commit_b = try harness.signers.commit(1, request.write, certificate);
    _ = (try harness.coordinator.recordCommitted(commit_b)).?;
    try harness.reopen();
    const completed = (try harness.coordinator.inspect()).last_completed.?;
    try std.testing.expect(std.meta.eql(completed.prepare_evidence[0], prepare_a));
    try std.testing.expect(std.meta.eql(completed.commit_evidence[0], commit_a));
    try std.testing.expect(std.meta.eql(completed.commit_evidence[1], commit_b));
    try write_evidence.verifyPrepare(harness.signers.identities[0], request.write, completed.prepare_evidence[0]);
    try write_evidence.verifyPrepare(harness.signers.identities[1], request.write, completed.prepare_evidence[1]);
    const projected_certificate = try write_evidence.certificateProjection(certificate);
    try write_evidence.verifyCommit(harness.signers.identities[0], request.write, projected_certificate, completed.commit_evidence[0]);
    try write_evidence.verifyCommit(harness.signers.identities[1], request.write, projected_certificate, completed.commit_evidence[1]);
    try std.testing.expect(std.meta.eql(completed.result, (try harness.coordinator.recordCommitted(commit_a)).?));
    var completed_conflict = commit_a;
    completed_conflict.signature[0] ^= 1;
    try std.testing.expectError(error.CommitResultConflict, harness.coordinator.recordCommitted(completed_conflict));
    try std.testing.expectEqual(BeginResult.completed, try harness.coordinator.begin(.{
        .write = request.write,
        .data = &expected,
        .witnesses = request.witnesses,
    }));
    const next_data = [_]u8{6} ** 4096;
    var wrong_volume = testBegin(2, completed.result.history_digest, 25, &next_data, .{ testId(1), testId(2) });
    wrong_volume.write.authority.volume_id = testId(99);
    try std.testing.expectError(error.VolumeMismatch, harness.coordinator.begin(wrong_volume));
    const regressed = testBegin(2, completed.result.history_digest, 25, &next_data, .{ testId(1), testId(2) });
    try std.testing.expectError(error.AuthorityRegression, harness.coordinator.begin(regressed));
    var conflicting_authority = testBegin(2, completed.result.history_digest, 25, &next_data, .{ testId(1), testId(2) });
    conflicting_authority.write.authority.write_epoch = 2;
    conflicting_authority.write.authority.lease_id = testId(98);
    try std.testing.expectError(error.AuthorityConflict, harness.coordinator.begin(conflicting_authority));
    var next = testBegin(2, completed.result.history_digest, 25, &next_data, .{ testId(1), testId(2) });
    next.write.authority.write_epoch = 2;
    try std.testing.expectEqual(BeginResult.started, try harness.coordinator.begin(next));
}

test "last completed signed evidence is replaced by the latest transaction" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const first_data = [_]u8{0x31} ** 4096;
    const first = testBegin(1, @splat(0), 70, &first_data, .{ testId(1), testId(2) });
    _ = try harness.coordinator.begin(first);
    try harness.coordinator.recordPrepared(try harness.signers.prepare(0, first.write, 1));
    try harness.coordinator.recordPrepared(try harness.signers.prepare(1, first.write, 2));
    const first_certificate = try harness.coordinator.decide();
    _ = try harness.coordinator.recordCommitted(try harness.signers.commit(0, first.write, first_certificate));
    _ = try harness.coordinator.recordCommitted(try harness.signers.commit(1, first.write, first_certificate));
    const first_result = (try harness.coordinator.inspect()).last_completed.?.result;

    const second_data = [_]u8{0x32} ** 4096;
    const second = testBegin(2, first_result.history_digest, 71, &second_data, .{ testId(1), testId(2) });
    _ = try harness.coordinator.begin(second);
    try harness.coordinator.recordPrepared(try harness.signers.prepare(0, second.write, 3));
    try harness.coordinator.recordPrepared(try harness.signers.prepare(1, second.write, 4));
    const second_certificate = try harness.coordinator.decide();
    _ = try harness.coordinator.recordCommitted(try harness.signers.commit(0, second.write, second_certificate));
    _ = try harness.coordinator.recordCommitted(try harness.signers.commit(1, second.write, second_certificate));
    const inspection = try harness.coordinator.inspect();
    try std.testing.expectEqual(@as(u64, 2), inspection.frontier.sequence);
    try std.testing.expect(std.mem.eql(u8, &inspection.last_completed.?.write.transaction_id, &second.write.transaction_id));
    try std.testing.expect(!std.mem.eql(u8, &inspection.last_completed.?.write.transaction_id, &first.write.transaction_id));
}

test "wrong signed witness write and certificate fail closed" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{3} ** 4096;
    const request = testBegin(1, @splat(0), 22, &data, .{ testId(1), testId(2) });
    _ = try harness.coordinator.begin(request);
    try std.testing.expectError(
        error.WitnessNotSelected,
        harness.coordinator.recordPrepared(try harness.signers.prepare(2, request.write, 3)),
    );
    var wrong_write = request.write;
    wrong_write.offset_bytes = 4096;
    try std.testing.expectError(
        error.UnverifiedPrepareEvidence,
        harness.coordinator.recordPrepared(try harness.signers.prepare(0, wrong_write, 1)),
    );
    try harness.coordinator.recordPrepared(try harness.signers.prepare(0, request.write, 1));
    try harness.coordinator.recordPrepared(try harness.signers.prepare(1, request.write, 2));
    const certificate = try harness.coordinator.decide();
    var wrong_certificate = try write_evidence.certificateProjection(certificate);
    wrong_certificate.attestations[1].prepare_digest[0] ^= 1;
    const bad_commit = try harness.signers.values[0].signCommit(
        request.write,
        wrong_certificate,
        testCommitResult(request.write, wrong_certificate),
    );
    try std.testing.expectError(error.UnverifiedCommitEvidence, harness.coordinator.recordCommitted(bad_commit));
}

test "coordinator v2 completed snapshot binary golden" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{0x6d} ** 4096;
    const request = testBegin(1, @splat(0), 29, &data, .{ testId(1), testId(2) });
    _ = try harness.coordinator.begin(request);
    try harness.coordinator.recordPrepared(try harness.signers.prepare(0, request.write, 1));
    try harness.coordinator.recordPrepared(try harness.signers.prepare(1, request.write, 2));
    const certificate = try harness.coordinator.decide();
    _ = try harness.coordinator.recordCommitted(try harness.signers.commit(0, request.write, certificate));
    _ = try harness.coordinator.recordCommitted(try harness.signers.commit(1, request.write, certificate));
    const bytes = try harness.tmp.dir.readFileAlloc(
        std.testing.io,
        "coordinator.state",
        std.testing.allocator,
        .limited(FileStoreInner.max_file_size),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, FileStoreInner.metadata_size + FileStoreInner.checksum_size), bytes.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("3db1192eb5cb0015ca3ce96e8d43859294d681cc0b36d7edbabd327811d34b73", &hex);
}

test "v2 reopen preserves every signed phase" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{7} ** 4096;
    const request = testBegin(1, @splat(0), 26, &data, .{ testId(1), testId(2) });
    _ = try harness.coordinator.begin(request);
    try harness.reopen();
    try harness.coordinator.recordPrepared(try harness.signers.prepare(0, request.write, 1));
    try harness.reopen();
    try harness.coordinator.recordPrepared(try harness.signers.prepare(1, request.write, 2));
    const certificate = try harness.coordinator.decide();
    try harness.reopen();
    _ = try harness.coordinator.recordCommitted(try harness.signers.commit(0, request.write, certificate));
    try harness.reopen();
    _ = try harness.coordinator.recordCommitted(try harness.signers.commit(1, request.write, certificate));
    try harness.reopen();
    try std.testing.expectEqual(@as(u64, 1), (try harness.coordinator.inspect()).frontier.sequence);
}

const LegacyPhase = enum { pristine, intent, first_prepare, second_prepare, decision, partial_commit, completed_frontier };

fn writeLegacyV1(dir: std.Io.Dir, phase: LegacyPhase) !void {
    const data = [_]u8{0x4a} ** 4096;
    const has_intent = switch (phase) {
        .intent, .first_prepare, .second_prepare, .decision, .partial_commit => true,
        .pristine, .completed_frontier => false,
    };
    const payload_len: usize = if (has_intent) data.len else 0;
    const metadata_size: usize = FileStoreInner.legacy_metadata_size;
    const bytes = try std.testing.allocator.alloc(u8, metadata_size + payload_len + FileStoreInner.checksum_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], &FileStoreInner.magic);
    std.mem.writeInt(u16, bytes[8..10], FileStoreInner.legacy_version, .little);
    bytes[10] = @intFromBool(has_intent);
    bytes[11] = @intFromBool(phase == .completed_frontier);
    std.mem.writeInt(u32, bytes[12..16], @intCast(payload_len), .little);
    std.mem.writeInt(u32, bytes[16..20], metadata_size, .little);
    var offset: usize = 24;
    for (testMembers()) |member| putBytes(bytes, &offset, &member);

    var request = testBegin(1, @splat(0), 60, &data, .{ testId(1), testId(2) });
    request.write.authority.write_epoch = 2;
    const first = testAttestation(request.write, testId(1), 1);
    const second = testAttestation(request.write, testId(2), 2);
    const certificate = try write_service.makeCommitCertificate(
        .{ first, second },
        write_service.digestTransaction(request.write),
        write_service.digestPreparedHistory(request.write.previous_history_digest, write_service.digestTransaction(request.write)),
        request.write.replica_members,
    );
    const result = testCommitResult(request.write, certificate);
    putFrontier(bytes, &offset, if (phase == .completed_frontier) .{
        .sequence = result.sequence,
        .history_digest = result.history_digest,
    } else .{});

    if (has_intent) {
        putWrite(bytes, &offset, request.write);
        for (request.witnesses) |witness| putBytes(bytes, &offset, &witness);
        const prepare_count: usize = switch (phase) {
            .intent => 0,
            .first_prepare => 1,
            .second_prepare, .decision, .partial_commit => 2,
            else => unreachable,
        };
        bytes[offset] = @intFromBool(prepare_count >= 1);
        bytes[offset + 1] = @intFromBool(prepare_count >= 2);
        offset += 2;
        if (prepare_count >= 1) putAttestation(bytes, &offset, first) else offset += attestation_encoded_size;
        if (prepare_count >= 2) putAttestation(bytes, &offset, second) else offset += attestation_encoded_size;
        const decided = phase == .decision or phase == .partial_commit;
        bytes[offset] = @intFromBool(decided);
        offset += 1;
        if (decided) putCertificate(bytes, &offset, certificate) else offset += certificate_encoded_size;
        bytes[offset] = @intFromBool(phase == .partial_commit);
        bytes[offset + 1] = 0;
        offset += 2;
        if (phase == .partial_commit) putResult(bytes, &offset, result) else offset += result_encoded_size;
        offset += result_encoded_size;
    } else {
        offset += legacy_intent_encoded_size;
    }

    if (phase == .completed_frontier) {
        putWrite(bytes, &offset, request.write);
        for (request.witnesses) |witness| putBytes(bytes, &offset, &witness);
        putCertificate(bytes, &offset, certificate);
        putResult(bytes, &offset, result);
    } else {
        offset += legacy_completed_encoded_size;
    }
    try std.testing.expect(offset <= metadata_size);
    @memcpy(bytes[metadata_size..][0..payload_len], data[0..payload_len]);
    std.mem.writeInt(u32, bytes[bytes.len - FileStoreInner.checksum_size ..][0..FileStoreInner.checksum_size], std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - FileStoreInner.checksum_size]), .little);
    try dir.writeFile(std.testing.io, .{ .sub_path = "legacy.state", .data = bytes });
}

test "only pristine unsigned v1 coordinator state migrates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var signers = try TestSigners.init();
    defer signers.deinit();
    try writeLegacyV1(tmp.dir, .pristine);
    const store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "legacy.state");
    const replacement = try write_evidence.Signer.init(
        std.testing.allocator,
        testId(4),
        testId(34),
        &@as(write_evidence.Seed, @splat(0x44)),
    );
    defer replacement.deinit();
    var wrong_identities = signers.identities;
    wrong_identities[2] = replacement.identity();
    try std.testing.expectError(
        error.CoordinatorBindingMismatch,
        Coordinator.initFile(std.testing.allocator, wrong_identities, store),
    );
    const coordinator = try Coordinator.initFile(std.testing.allocator, signers.identities, store);
    coordinator.deinit();
    store.deinit();
    const migrated = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "legacy.state");
    const current = try Coordinator.initFile(std.testing.allocator, signers.identities, migrated);
    current.deinit();
    migrated.deinit();

    for ([_]LegacyPhase{ .intent, .first_prepare, .second_prepare, .decision, .partial_commit, .completed_frontier }) |phase| {
        try writeLegacyV1(tmp.dir, phase);
        try std.testing.expectError(error.UnsignedCoordinatorState, FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "legacy.state"));
    }

    const LegacyCorruption = enum { header, flags, reserved, payload_length, body, checksum, truncated };
    inline for (std.meta.tags(LegacyCorruption)) |corruption| {
        try writeLegacyV1(tmp.dir, if (corruption == .body) .first_prepare else .intent);
        const legacy_bytes = try tmp.dir.readFileAlloc(
            std.testing.io,
            "legacy.state",
            std.testing.allocator,
            .limited(write_service.max_payload_size + FileStoreInner.legacy_metadata_size + FileStoreInner.checksum_size),
        );
        defer std.testing.allocator.free(legacy_bytes);
        switch (corruption) {
            .header => std.mem.writeInt(u32, legacy_bytes[16..20], FileStoreInner.legacy_metadata_size + 1, .little),
            .flags => legacy_bytes[10] = 2,
            .reserved => legacy_bytes[20] = 1,
            .payload_length => std.mem.writeInt(u32, legacy_bytes[12..16], 4095, .little),
            .body => legacy_bytes[24 + 3 * @sizeOf(Id) + 40 + write_encoded_size + 15] = 4,
            .checksum => legacy_bytes[legacy_bytes.len - 1] ^= 1,
            .truncated => {},
        }
        if (corruption != .checksum and corruption != .truncated)
            std.mem.writeInt(u32, legacy_bytes[legacy_bytes.len - FileStoreInner.checksum_size ..][0..FileStoreInner.checksum_size], std.hash.crc.Crc32Iscsi.hash(legacy_bytes[0 .. legacy_bytes.len - FileStoreInner.checksum_size]), .little);
        const contents = if (corruption == .truncated) legacy_bytes[0 .. legacy_bytes.len - 1] else legacy_bytes;
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "legacy.state", .data = contents });
        try std.testing.expectError(error.StoreCorrupt, FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "legacy.state"));
    }
}

test "corrupt v2 identity and signed prepare with recomputed checksum fail reopen" {
    var harness = try TestHarness.init();
    const data = [_]u8{8} ** 4096;
    const request = testBegin(1, @splat(0), 27, &data, .{ testId(1), testId(2) });
    _ = try harness.coordinator.begin(request);
    try harness.coordinator.recordPrepared(try harness.signers.prepare(0, request.write, 1));
    harness.coordinator.deinit();
    harness.store.deinit();
    var bytes = try harness.tmp.dir.readFileAlloc(std.testing.io, "coordinator.state", std.testing.allocator, .limited(FileStoreInner.max_file_size));
    defer std.testing.allocator.free(bytes);
    bytes[24 + 16 + 16] ^= 1;
    std.mem.writeInt(u32, bytes[bytes.len - 4 ..][0..4], std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - 4]), .little);
    try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad-identity.state", .data = bytes });
    try std.testing.expectError(error.StoreCorrupt, FileStore.init(std.testing.allocator, std.testing.io, harness.tmp.dir, "bad-identity.state"));
    bytes[24 + 16 + 16] ^= 1;
    const signature_offset = 24 + identities_encoded_size + 40 + write_encoded_size + 2 * @sizeOf(Id) + 2 + attestation_encoded_size + 16 + 32;
    bytes[signature_offset] ^= 1;
    std.mem.writeInt(u32, bytes[bytes.len - 4 ..][0..4], std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - 4]), .little);
    try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad-signature.state", .data = bytes });
    try std.testing.expectError(error.StoreCorrupt, FileStore.init(std.testing.allocator, std.testing.io, harness.tmp.dir, "bad-signature.state"));
    harness.signers.deinit();
    harness.tmp.cleanup();
}

test "file store rejects corruption truncation and concurrent ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var signers = try TestSigners.init();
    defer signers.deinit();
    const first = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state");
    var first_open = true;
    defer if (first_open) first.deinit();
    const coordinator = try Coordinator.initFile(std.testing.allocator, signers.identities, first);
    coordinator.deinit();
    try std.testing.expectError(error.StateFileLocked, FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state"));
    first.deinit();
    first_open = false;
    var file = try tmp.dir.openFile(std.testing.io, "coordinator.state", .{ .mode = .read_write });
    try file.setLength(std.testing.io, 10);
    file.close(std.testing.io);
    try std.testing.expectError(error.StoreCorrupt, FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state"));
}

test "durability faults preserve or poison every signed mutation boundary" {
    const stages = [_]MutationStage{ .intent, .first_prepare, .second_prepare, .decision, .partial_commit, .completion };
    const fault_kinds = [_]FaultKind{ .write, .file_sync, .directory_sync };
    for (fault_kinds) |fault_kind| for (stages) |stage| {
        var harness = try TestHarness.init();
        defer harness.deinit();
        const data = [_]u8{9} ** 4096;
        const request = testBegin(1, @splat(0), 28, &data, .{ testId(1), testId(2) });
        try setupBeforeMutation(&harness, request, stage);
        try std.testing.expect(!try mutationReached(harness.coordinator, stage));
        var faults: FileStore.Faults = .{};
        const expected_error: anyerror = switch (fault_kind) {
            .write => blk: {
                faults.fail_write_once = true;
                break :blk error.InjectedWriteFailure;
            },
            .file_sync => blk: {
                faults.fail_file_sync_once = true;
                break :blk error.InjectedFileSyncFailure;
            },
            .directory_sync => blk: {
                faults.fail_directory_sync_once = true;
                break :blk error.InjectedDirectorySyncFailure;
            },
        };
        harness.store.setFaults(&faults);
        try std.testing.expectError(expected_error, applyMutation(&harness, request, stage));
        if (fault_kind == .directory_sync) {
            try std.testing.expect(harness.store.isPoisoned());
            try std.testing.expectError(error.StorePoisoned, harness.coordinator.inspect());
            try harness.reopen();
            try std.testing.expect(try mutationReached(harness.coordinator, stage));
        } else {
            try std.testing.expect(!try mutationReached(harness.coordinator, stage));
            try applyMutation(&harness, request, stage);
            try std.testing.expect(try mutationReached(harness.coordinator, stage));
        }
    };
}

test "payload bounds are enforced" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const too_large = try std.testing.allocator.alloc(u8, write_service.max_payload_size + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 9);
    try std.testing.expectError(error.InvalidWrite, harness.coordinator.begin(testBegin(1, @splat(0), 29, too_large, .{ testId(1), testId(2) })));
    try std.testing.expectError(error.InvalidWrite, harness.coordinator.begin(testBegin(1, @splat(0), 29, &.{}, .{ testId(1), testId(2) })));
    try std.testing.expectEqual(
        BeginResult.started,
        try harness.coordinator.begin(testBegin(
            1,
            @splat(0),
            30,
            too_large[0..write_service.max_payload_size],
            .{ testId(1), testId(2) },
        )),
    );
}
