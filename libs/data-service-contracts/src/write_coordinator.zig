const std = @import("std");
const model = @import("model.zig");
const write_service = @import("write_service.zig");

pub const Id = model.Id;
pub const Digest = model.Digest;
pub const WriteRequest = write_service.WriteRequest;
pub const PrepareAttestation = write_service.PrepareAttestation;
pub const CommitCertificate = write_service.CommitCertificate;
pub const CommitResult = write_service.CommitResult;
pub const Frontier = write_service.Frontier;

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

pub const EvidenceVerifier = struct {
    context: *anyopaque,
    verify_prepare_fn: *const fn (*anyopaque, WriteRequest, Id, PrepareAttestation) anyerror!void,
    verify_commit_fn: *const fn (*anyopaque, WriteRequest, Id, CommitCertificate, CommitResult) anyerror!void,

    pub fn verifyPrepare(self: EvidenceVerifier, write: WriteRequest, witness: Id, attestation: PrepareAttestation) !void {
        try self.verify_prepare_fn(self.context, write, witness, attestation);
    }

    pub fn verifyCommit(
        self: EvidenceVerifier,
        write: WriteRequest,
        witness: Id,
        certificate: CommitCertificate,
        result: CommitResult,
    ) !void {
        try self.verify_commit_fn(self.context, write, witness, certificate, result);
    }
};

pub const PendingInspection = struct {
    write: WriteRequest,
    data: []const u8,
    witnesses: [write_service.certificate_witness_count]Id,
    attestations: [write_service.certificate_witness_count]?PrepareAttestation,
    certificate: ?CommitCertificate,
    commit_results: [write_service.certificate_witness_count]?CommitResult,
};

pub const CompletedInspection = struct {
    write: WriteRequest,
    witnesses: [write_service.certificate_witness_count]Id,
    certificate: CommitCertificate,
    result: CommitResult,
};

pub const Inspection = struct {
    replica_members: [3]Id,
    frontier: Frontier,
    pending: ?PendingInspection,
    last_completed: ?CompletedInspection,
};

const Intent = struct {
    write: WriteRequest,
    data: []const u8,
    witnesses: [write_service.certificate_witness_count]Id,
    attestations: [write_service.certificate_witness_count]?PrepareAttestation = .{ null, null },
};

const Decision = struct {
    certificate: CommitCertificate,
    commit_results: [write_service.certificate_witness_count]?CommitResult = .{ null, null },
};

const Completed = struct {
    write: WriteRequest,
    witnesses: [write_service.certificate_witness_count]Id,
    certificate: CommitCertificate,
    result: CommitResult,
};

const State = struct {
    replica_members: ?[3]Id = null,
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
        replica_members: [3]Id,
        file_store: *FileStore,
        verifier: EvidenceVerifier,
    ) !*Coordinator {
        try file_store.claim();
        errdefer file_store.release();
        try file_store.bind(replica_members);
        const managed = try allocator.create(ManagedCoordinator);
        errdefer allocator.destroy(managed);
        managed.* = .{
            .allocator = allocator,
            .file_store = file_store,
            .core = try CoordinatorCore.init(replica_members, file_store.store(), verifier),
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

    pub fn recordPrepared(self: *Coordinator, witness: Id, attestation: PrepareAttestation) !void {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        managed.lock();
        defer managed.mutex.unlock();
        try managed.core.recordPrepared(witness, attestation);
    }

    pub fn decide(self: *Coordinator) !CommitCertificate {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        managed.lock();
        defer managed.mutex.unlock();
        return managed.core.decide();
    }

    pub fn recordCommitted(self: *Coordinator, witness: Id, result: CommitResult) !?CommitResult {
        const managed: *ManagedCoordinator = @ptrCast(@alignCast(self));
        managed.lock();
        defer managed.mutex.unlock();
        return managed.core.recordCommitted(witness, result);
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
    replica_members: [3]Id,
    store: Store,
    verifier: EvidenceVerifier,

    fn init(replica_members: [3]Id, store: Store, verifier: EvidenceVerifier) !CoordinatorCore {
        try write_service.validateCanonicalReplicaMembers(replica_members);
        try store.checkHealthy();
        const state = store.current();
        try validateStoredState(state);
        const stored_members = state.replica_members orelse return error.CoordinatorNotBound;
        if (!std.meta.eql(stored_members, replica_members)) return error.CoordinatorBindingMismatch;
        return .{ .replica_members = replica_members, .store = store, .verifier = verifier };
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
        next.intent = .{
            .write = request.write,
            .data = request.data,
            .witnesses = witnesses,
        };
        next.decision = null;
        try validateStoredState(next);
        try self.store.save(next);
        return .started;
    }

    fn recordPrepared(self: *CoordinatorCore, witness: Id, attestation: PrepareAttestation) !void {
        try self.store.checkHealthy();
        const current = self.store.current();
        try validateStoredState(current);
        const intent = current.intent orelse return error.NoWriteInProgress;
        const index = witnessIndex(intent.witnesses, witness) orelse return error.WitnessNotSelected;
        try validateAttestation(intent.write, witness, attestation);
        if (intent.attestations[index]) |existing| {
            if (!std.meta.eql(existing, attestation)) return error.EvidenceConflict;
            return;
        }
        if (current.decision != null) return error.DecisionStateCorrupt;
        try self.verifier.verifyPrepare(intent.write, witness, attestation);
        var next = current;
        next.intent.?.attestations[index] = attestation;
        try validateStoredState(next);
        try self.store.save(next);
    }

    fn decide(self: *CoordinatorCore) !CommitCertificate {
        try self.store.checkHealthy();
        const current = self.store.current();
        try validateStoredState(current);
        const intent = current.intent orelse return error.NoWriteInProgress;
        if (current.decision) |decision| return decision.certificate;
        const first = intent.attestations[0] orelse return error.PrepareQuorumMissing;
        const second = intent.attestations[1] orelse return error.PrepareQuorumMissing;
        const certificate = try write_service.makeCommitCertificate(
            .{ first, second },
            write_service.digestTransaction(intent.write),
            write_service.digestPreparedHistory(intent.write.previous_history_digest, write_service.digestTransaction(intent.write)),
            self.replica_members,
        );
        var next = current;
        next.decision = .{ .certificate = certificate };
        try validateStoredState(next);
        try self.store.save(next);
        return certificate;
    }

    fn recordCommitted(self: *CoordinatorCore, witness: Id, result: CommitResult) !?CommitResult {
        try self.store.checkHealthy();
        const current = self.store.current();
        try validateStoredState(current);
        const intent = current.intent orelse {
            if (current.last_completed) |completed| {
                const index = witnessIndex(completed.witnesses, witness) orelse return error.WitnessNotSelected;
                _ = index;
                if (!std.meta.eql(completed.result, result)) return error.CommitResultConflict;
                return completed.result;
            }
            return error.NoWriteInProgress;
        };
        const decision = current.decision orelse return error.CommitNotDecided;
        const index = witnessIndex(intent.witnesses, witness) orelse return error.WitnessNotSelected;
        try validateCommitResult(intent, decision.certificate, result);
        if (decision.commit_results[index]) |existing| {
            if (!std.meta.eql(existing, result)) return error.CommitResultConflict;
            return if (decision.commit_results[1 - index] != null) result else null;
        }
        try self.verifier.verifyCommit(intent.write, witness, decision.certificate, result);

        var next = current;
        next.decision.?.commit_results[index] = result;
        if (next.decision.?.commit_results[0] != null and next.decision.?.commit_results[1] != null) {
            const first = next.decision.?.commit_results[0].?;
            const second = next.decision.?.commit_results[1].?;
            if (!std.meta.eql(first, second)) return error.CommitResultConflict;
            next.frontier = .{ .sequence = result.sequence, .history_digest = result.history_digest };
            next.last_completed = .{
                .write = intent.write,
                .witnesses = intent.witnesses,
                .certificate = decision.certificate,
                .result = result,
            };
            next.intent = null;
            next.decision = null;
        }
        try validateStoredState(next);
        try self.store.save(next);
        return if (next.intent == null) result else null;
    }

    fn inspect(self: *CoordinatorCore) !Inspection {
        try self.store.checkHealthy();
        const current = self.store.current();
        try validateStoredState(current);
        return inspectionFromState(current);
    }
};

fn inspectionFromState(state: State) Inspection {
    const pending: ?PendingInspection = if (state.intent) |intent| .{
        .write = intent.write,
        .data = intent.data,
        .witnesses = intent.witnesses,
        .attestations = intent.attestations,
        .certificate = if (state.decision) |decision| decision.certificate else null,
        .commit_results = if (state.decision) |decision| decision.commit_results else .{ null, null },
    } else null;
    const completed: ?CompletedInspection = if (state.last_completed) |value| .{
        .write = value.write,
        .witnesses = value.witnesses,
        .certificate = value.certificate,
        .result = value.result,
    } else null;
    return .{
        .replica_members = state.replica_members.?,
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

fn validateAttestation(write: WriteRequest, witness: Id, attestation: PrepareAttestation) !void {
    const transaction_digest = write_service.digestTransaction(write);
    const prepared_history = write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest);
    if (!std.mem.eql(u8, &attestation.member_id, &witness) or
        !std.mem.eql(u8, &attestation.transaction_digest, &transaction_digest) or
        !std.mem.eql(u8, &attestation.prepared_history_digest, &prepared_history) or
        isZero(&attestation.prepare_digest))
        return error.EvidenceMismatch;
}

fn validateCommitResult(intent: Intent, certificate: CommitCertificate, result: CommitResult) !void {
    if (!std.mem.eql(u8, &result.transaction_id, &intent.write.transaction_id) or
        result.sequence != intent.write.sequence or isZero(&result.history_digest))
        return error.CommitResultMismatch;
    const transaction_digest = write_service.digestTransaction(intent.write);
    const prepared_history = write_service.digestPreparedHistory(intent.write.previous_history_digest, transaction_digest);
    const expected_history = write_service.digestCommitHistory(prepared_history, certificate);
    if (!std.mem.eql(u8, &result.history_digest, &expected_history)) return error.CommitResultMismatch;
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
    const replica_members = state.replica_members orelse {
        if (state.intent != null or state.decision != null or state.last_completed != null or
            state.frontier.sequence != 0 or !isZero(&state.frontier.history_digest))
            return error.StoreCorrupt;
        return;
    };
    write_service.validateCanonicalReplicaMembers(replica_members) catch return error.StoreCorrupt;
    if ((state.frontier.sequence == 0) != isZero(&state.frontier.history_digest)) return error.StoreCorrupt;
    // A decision cannot exist without its exact intent.
    if (state.intent == null and state.decision != null) return error.StoreCorrupt;
    if (state.intent) |intent| {
        validateBeginRequest(replica_members, state.frontier, .{
            .write = intent.write,
            .data = intent.data,
            .witnesses = intent.witnesses,
        }) catch return error.StoreCorrupt;
        for (intent.attestations, 0..) |attestation, index| if (attestation) |value| {
            validateAttestation(intent.write, intent.witnesses[index], value) catch return error.StoreCorrupt;
        };
        if (state.decision) |decision| {
            const first = intent.attestations[0] orelse return error.StoreCorrupt;
            const second = intent.attestations[1] orelse return error.StoreCorrupt;
            const expected = write_service.makeCommitCertificate(
                .{ first, second },
                write_service.digestTransaction(intent.write),
                write_service.digestPreparedHistory(intent.write.previous_history_digest, write_service.digestTransaction(intent.write)),
                replica_members,
            ) catch return error.StoreCorrupt;
            if (!std.meta.eql(expected, decision.certificate)) return error.StoreCorrupt;
            for (decision.commit_results) |result| if (result) |value|
                validateCommitResult(intent, decision.certificate, value) catch return error.StoreCorrupt;
            // The second durable acknowledgement atomically completes the
            // transaction, so an in-flight snapshot may never retain both.
            if (decision.commit_results[0] != null and decision.commit_results[1] != null)
                return error.StoreCorrupt;
        }
    } else if (state.decision != null) return error.StoreCorrupt;

    if (state.last_completed) |completed| {
        validateWriteMetadata(replica_members, completed.write) catch return error.StoreCorrupt;
        const normalized_witnesses = normalizeWitnesses(completed.witnesses, replica_members) catch return error.StoreCorrupt;
        if (!std.meta.eql(normalized_witnesses, completed.witnesses) or
            !std.mem.eql(u8, &completed.certificate.attestations[0].member_id, &completed.witnesses[0]) or
            !std.mem.eql(u8, &completed.certificate.attestations[1].member_id, &completed.witnesses[1]) or
            !std.meta.eql(completed.write.replica_members, replica_members) or
            completed.write.sequence != state.frontier.sequence or
            !std.mem.eql(u8, &completed.result.transaction_id, &completed.write.transaction_id) or
            completed.result.sequence != completed.write.sequence or
            !std.mem.eql(u8, &completed.result.history_digest, &state.frontier.history_digest))
            return error.StoreCorrupt;
        const expected = write_service.makeCommitCertificate(
            completed.certificate.attestations,
            write_service.digestTransaction(completed.write),
            write_service.digestPreparedHistory(completed.write.previous_history_digest, write_service.digestTransaction(completed.write)),
            replica_members,
        ) catch return error.StoreCorrupt;
        if (!std.meta.eql(expected, completed.certificate)) return error.StoreCorrupt;
        const intent: Intent = .{ .write = completed.write, .data = &.{}, .witnesses = completed.witnesses };
        validateCommitResult(intent, completed.certificate, completed.result) catch return error.StoreCorrupt;
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

    fn bind(self: *FileStore, replica_members: [3]Id) !void {
        const inner: *FileStoreInner = @ptrCast(@alignCast(self));
        try inner.bind(replica_members);
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
    claimed: std.atomic.Value(bool) = .init(false),
    faults: ?*Faults = null,

    const magic = "ZETCOOR1".*;
    const version: u16 = 1;
    const metadata_size: usize = 2048;
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

    fn bind(self: *FileStoreInner, replica_members: [3]Id) !void {
        if (self.poisoned) return error.StorePoisoned;
        try write_service.validateCanonicalReplicaMembers(replica_members);
        if (self.state.replica_members) |existing| {
            if (!std.meta.eql(existing, replica_members)) return error.CoordinatorBindingMismatch;
            return;
        }
        var next = self.state;
        next.replica_members = replica_members;
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
        if (state.replica_members) |members| {
            for (members) |member| putBytes(bytes, &offset, &member);
        } else {
            offset += members_encoded_size;
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
            .replica_members = .{ getArray(16, bytes, &offset), getArray(16, bytes, &offset), getArray(16, bytes, &offset) },
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

    fn snapshotPayload(bytes: []u8) []u8 {
        return bytes[metadata_size .. bytes.len - checksum_size];
    }
};

const authority_encoded_size: usize = 152;
const write_encoded_size: usize = authority_encoded_size + 3 * @sizeOf(Id) + 104;
const attestation_encoded_size: usize = 112;
const certificate_encoded_size: usize = 2 * attestation_encoded_size;
const result_encoded_size: usize = 56;
const members_encoded_size: usize = 3 * @sizeOf(Id);
const intent_encoded_size: usize = write_encoded_size + 2 * @sizeOf(Id) + 2 + 2 * attestation_encoded_size + 1 + certificate_encoded_size + 2 + 2 * result_encoded_size;
const completed_encoded_size: usize = write_encoded_size + 2 * @sizeOf(Id) + certificate_encoded_size + result_encoded_size;

fn putIntent(bytes: []u8, offset: *usize, intent: Intent, decision: ?Decision) void {
    putWrite(bytes, offset, intent.write);
    for (intent.witnesses) |witness| putBytes(bytes, offset, &witness);
    for (intent.attestations) |attestation| {
        bytes[offset.*] = @intFromBool(attestation != null);
        offset.* += 1;
    }
    for (intent.attestations) |attestation| {
        if (attestation) |value| {
            putAttestation(bytes, offset, value);
        } else {
            offset.* += attestation_encoded_size;
        }
    }
    bytes[offset.*] = @intFromBool(decision != null);
    offset.* += 1;
    if (decision) |value| putCertificate(bytes, offset, value.certificate) else offset.* += certificate_encoded_size;
    for (0..2) |index| {
        bytes[offset.*] = @intFromBool(decision != null and decision.?.commit_results[index] != null);
        offset.* += 1;
    }
    for (0..2) |index| {
        if (decision != null and decision.?.commit_results[index] != null) {
            putResult(bytes, offset, decision.?.commit_results[index].?);
        } else {
            offset.* += result_encoded_size;
        }
    }
}

const DecodedIntent = struct { intent: Intent, decision: ?Decision };

fn getIntent(bytes: []const u8, offset: *usize) !DecodedIntent {
    var intent: Intent = .{
        .write = getWrite(bytes, offset),
        .data = &.{},
        .witnesses = .{ getArray(16, bytes, offset), getArray(16, bytes, offset) },
    };
    const attestation_flags: [2]u8 = .{ bytes[offset.*], bytes[offset.* + 1] };
    offset.* += 2;
    for (attestation_flags) |flag| if (flag > 1) return error.StoreCorrupt;
    for (&intent.attestations, 0..) |*attestation, index| {
        const start = offset.*;
        const value = getAttestation(bytes, offset);
        if (attestation_flags[index] == 1) {
            attestation.* = value;
        } else {
            if (!isZero(bytes[start..][0..attestation_encoded_size])) return error.StoreCorrupt;
            attestation.* = null;
        }
    }
    const has_decision = bytes[offset.*];
    offset.* += 1;
    if (has_decision > 1) return error.StoreCorrupt;
    const certificate_start = offset.*;
    const certificate = getCertificate(bytes, offset);
    if (has_decision == 0 and !isZero(bytes[certificate_start..][0..certificate_encoded_size]))
        return error.StoreCorrupt;
    const result_flags: [2]u8 = .{ bytes[offset.*], bytes[offset.* + 1] };
    offset.* += 2;
    for (result_flags) |flag| if (flag > 1) return error.StoreCorrupt;
    if (has_decision == 0 and (result_flags[0] != 0 or result_flags[1] != 0)) return error.StoreCorrupt;
    var results: [2]?CommitResult = .{ null, null };
    for (&results, 0..) |*result, index| {
        const start = offset.*;
        const value = getResult(bytes, offset);
        if (result_flags[index] == 1) {
            result.* = value;
        } else if (!isZero(bytes[start..][0..result_encoded_size])) {
            return error.StoreCorrupt;
        }
    }
    const decision: ?Decision = if (has_decision == 1) .{ .certificate = certificate, .commit_results = results } else null;
    return .{ .intent = intent, .decision = decision };
}

fn putCompleted(bytes: []u8, offset: *usize, completed: Completed) void {
    putWrite(bytes, offset, completed.write);
    for (completed.witnesses) |witness| putBytes(bytes, offset, &witness);
    putCertificate(bytes, offset, completed.certificate);
    putResult(bytes, offset, completed.result);
}

fn getCompleted(bytes: []const u8, offset: *usize) Completed {
    return .{
        .write = getWrite(bytes, offset),
        .witnesses = .{ getArray(16, bytes, offset), getArray(16, bytes, offset) },
        .certificate = getCertificate(bytes, offset),
        .result = getResult(bytes, offset),
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
const TestVerifier = struct {
    reject_prepare: bool = false,
    reject_commit: bool = false,
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    last_commit_witness: ?Id = null,
    last_commit_certificate: ?CommitCertificate = null,
    last_commit_result: ?CommitResult = null,

    fn verifier(self: *TestVerifier) EvidenceVerifier {
        return .{
            .context = self,
            .verify_prepare_fn = verifyPrepare,
            .verify_commit_fn = verifyCommit,
        };
    }

    fn verifyPrepare(context: *anyopaque, write: WriteRequest, witness: Id, attestation: PrepareAttestation) !void {
        const self: *TestVerifier = @ptrCast(@alignCast(context));
        self.prepare_calls += 1;
        if (self.reject_prepare) return error.UnverifiedPrepareEvidence;
        try validateAttestation(write, witness, attestation);
    }

    fn verifyCommit(
        context: *anyopaque,
        write: WriteRequest,
        witness: Id,
        certificate: CommitCertificate,
        result: CommitResult,
    ) !void {
        const self: *TestVerifier = @ptrCast(@alignCast(context));
        self.commit_calls += 1;
        self.last_commit_witness = witness;
        self.last_commit_certificate = certificate;
        self.last_commit_result = result;
        if (self.reject_commit) return error.UnverifiedCommitEvidence;
        const expected = try write_service.makeCommitCertificate(
            certificate.attestations,
            write_service.digestTransaction(write),
            write_service.digestPreparedHistory(write.previous_history_digest, write_service.digestTransaction(write)),
            write.replica_members,
        );
        if (!std.meta.eql(expected, certificate)) return error.SpoofedCommitCertificate;
        const witnesses: [2]Id = .{
            certificate.attestations[0].member_id,
            certificate.attestations[1].member_id,
        };
        if (witnessIndex(witnesses, witness) == null) return error.SpoofedCommitWitness;
        try validateCommitResult(.{ .write = write, .data = &.{}, .witnesses = witnesses }, certificate, result);
    }
};

fn testId(value: u8) Id {
    var result: Id = @splat(0);
    result[15] = value;
    return result;
}

fn testMembers() [3]Id {
    return .{ testId(1), testId(2), testId(3) };
}

fn testAuthority() model.AuthorityBinding {
    return .{
        .volume_id = testId(10),
        .primary_placement_id = testId(11),
        .primary_node_id = testId(12),
        .lease_id = testId(13),
        .holder_boot_id = testId(14),
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 1,
        .activation_nonce = testId(15),
        .authority_digest = @splat(0x44),
    };
}

fn testBegin(sequence: u64, previous: Digest, transaction: u8, data: []const u8, witnesses: [2]Id) BeginRequest {
    return .{
        .write = .{
            .authority = testAuthority(),
            .replica_members = testMembers(),
            .sequence = sequence,
            .transaction_id = testId(transaction),
            .previous_history_digest = previous,
            .offset_bytes = 0,
            .length_bytes = data.len,
            .data_digest = write_service.digestData(data),
        },
        .data = data,
        .witnesses = witnesses,
    };
}

fn testAttestation(write: WriteRequest, member: Id, prepare_byte: u8) PrepareAttestation {
    const transaction_digest = write_service.digestTransaction(write);
    return .{
        .member_id = member,
        .transaction_digest = transaction_digest,
        .prepare_digest = @splat(prepare_byte),
        .prepared_history_digest = write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest),
    };
}

fn testCommitResult(write: WriteRequest, certificate: CommitCertificate) CommitResult {
    const transaction_digest = write_service.digestTransaction(write);
    return .{
        .transaction_id = write.transaction_id,
        .sequence = write.sequence,
        .history_digest = write_service.digestCommitHistory(
            write_service.digestPreparedHistory(write.previous_history_digest, transaction_digest),
            certificate,
        ),
    };
}

const TestHarness = struct {
    tmp: std.testing.TmpDir,
    store: *FileStore,
    coordinator: *Coordinator,
    verifier: *TestVerifier,

    fn init() !TestHarness {
        var result: TestHarness = undefined;
        result.tmp = std.testing.tmpDir(.{});
        errdefer result.tmp.cleanup();
        result.verifier = try std.testing.allocator.create(TestVerifier);
        errdefer std.testing.allocator.destroy(result.verifier);
        result.verifier.* = .{};
        result.store = try FileStore.init(std.testing.allocator, std.testing.io, result.tmp.dir, "coordinator.state");
        errdefer result.store.deinit();
        result.coordinator = try Coordinator.initFile(std.testing.allocator, testMembers(), result.store, result.verifier.verifier());
        return result;
    }

    fn deinit(self: *TestHarness) void {
        self.coordinator.deinit();
        self.store.deinit();
        std.testing.allocator.destroy(self.verifier);
        self.tmp.cleanup();
    }

    fn reopen(self: *TestHarness) !void {
        self.coordinator.deinit();
        self.store.deinit();
        self.store = try FileStore.init(std.testing.allocator, std.testing.io, self.tmp.dir, "coordinator.state");
        self.coordinator = try Coordinator.initFile(std.testing.allocator, testMembers(), self.store, self.verifier.verifier());
    }
};

const MutationStage = enum {
    intent,
    first_prepare,
    second_prepare,
    decision,
    partial_commit,
    completion,
};

const FaultKind = enum {
    write,
    file_sync,
    directory_sync,
};

fn setupBeforeMutation(coordinator: *Coordinator, request: BeginRequest, stage: MutationStage) !void {
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.intent))
        _ = try coordinator.begin(request);
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.first_prepare))
        try coordinator.recordPrepared(testId(1), testAttestation(request.write, testId(1), 1));
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.second_prepare))
        try coordinator.recordPrepared(testId(2), testAttestation(request.write, testId(2), 2));
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.decision))
        _ = try coordinator.decide();
    if (@intFromEnum(stage) > @intFromEnum(MutationStage.partial_commit)) {
        const certificate = (try coordinator.inspect()).pending.?.certificate.?;
        _ = try coordinator.recordCommitted(testId(1), testCommitResult(request.write, certificate));
    }
}

fn applyMutation(coordinator: *Coordinator, request: BeginRequest, stage: MutationStage) !void {
    switch (stage) {
        .intent => _ = try coordinator.begin(request),
        .first_prepare => try coordinator.recordPrepared(testId(1), testAttestation(request.write, testId(1), 1)),
        .second_prepare => try coordinator.recordPrepared(testId(2), testAttestation(request.write, testId(2), 2)),
        .decision => _ = try coordinator.decide(),
        .partial_commit => {
            const certificate = (try coordinator.inspect()).pending.?.certificate.?;
            _ = try coordinator.recordCommitted(testId(1), testCommitResult(request.write, certificate));
        },
        .completion => {
            const certificate = (try coordinator.inspect()).pending.?.certificate.?;
            _ = try coordinator.recordCommitted(testId(2), testCommitResult(request.write, certificate));
        },
    }
}

fn mutationReached(coordinator: *Coordinator, stage: MutationStage) !bool {
    const inspection = try coordinator.inspect();
    return switch (stage) {
        .intent => inspection.pending != null,
        .first_prepare => inspection.pending.?.attestations[0] != null,
        .second_prepare => inspection.pending.?.attestations[1] != null,
        .decision => inspection.pending.?.certificate != null,
        .partial_commit => inspection.pending.?.commit_results[0] != null,
        .completion => inspection.pending == null and inspection.frontier.sequence == 1,
    };
}

test "canonical replica members and fixed witnesses are validated" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{1} ** 4096;
    var invalid = testBegin(1, @splat(0), 20, &data, .{ testId(1), testId(1) });
    try std.testing.expectError(error.InvalidWitnessSet, harness.coordinator.begin(invalid));
    invalid.witnesses = .{ testId(1), testId(4) };
    try std.testing.expectError(error.WitnessNotEligible, harness.coordinator.begin(invalid));
    var bad_members = testMembers();
    std.mem.swap(Id, &bad_members[0], &bad_members[1]);
    var bad_write = testBegin(1, @splat(0), 20, &data, .{ testId(1), testId(2) });
    bad_write.write.replica_members = bad_members;
    try std.testing.expectError(error.ReplicaSetMismatch, harness.coordinator.begin(bad_write));
}

test "one FileStore permits only one live Coordinator attachment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var verifier: TestVerifier = .{};
    const store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state");
    defer store.deinit();
    const first = try Coordinator.initFile(std.testing.allocator, testMembers(), store, verifier.verifier());
    try std.testing.expectError(
        error.CoordinatorAlreadyAttached,
        Coordinator.initFile(std.testing.allocator, testMembers(), store, verifier.verifier()),
    );
    first.deinit();

    var wrong_members = testMembers();
    wrong_members[2] = testId(4);
    try std.testing.expectError(
        error.CoordinatorBindingMismatch,
        Coordinator.initFile(std.testing.allocator, wrong_members, store, verifier.verifier()),
    );
    const second = try Coordinator.initFile(std.testing.allocator, testMembers(), store, verifier.verifier());
    second.deinit();
}

test "intent is durable before evidence and exact retries cannot switch witnesses" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    var data = [_]u8{2} ** 4096;
    const expected = data;
    const request = testBegin(1, @splat(0), 21, &data, .{ testId(2), testId(1) });
    try std.testing.expectEqual(BeginResult.started, try harness.coordinator.begin(request));
    @memset(&data, 9);
    const inspection = try harness.coordinator.inspect();
    try std.testing.expectEqualSlices(u8, &expected, inspection.pending.?.data);
    try std.testing.expectEqualSlices(u8, &testId(1), &inspection.pending.?.witnesses[0]);
    try harness.reopen();
    var retry = request;
    retry.data = &expected;
    try std.testing.expectEqual(BeginResult.retry, try harness.coordinator.begin(retry));
    var switched = retry;
    switched.witnesses = .{ testId(1), testId(3) };
    try std.testing.expectError(error.WriteInProgress, harness.coordinator.begin(switched));
    var conflict = retry;
    conflict.write.offset_bytes = 4096;
    try std.testing.expectError(error.WriteInProgress, harness.coordinator.begin(conflict));
}

test "evidence verifier rejection and evidence mismatch fail closed" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{3} ** 4096;
    const request = testBegin(1, @splat(0), 22, &data, .{ testId(1), testId(2) });
    _ = try harness.coordinator.begin(request);
    var evidence = testAttestation(request.write, testId(1), 1);
    evidence.transaction_digest[0] ^= 1;
    try std.testing.expectError(error.EvidenceMismatch, harness.coordinator.recordPrepared(testId(1), evidence));
    harness.verifier.reject_prepare = true;
    try std.testing.expectError(
        error.UnverifiedPrepareEvidence,
        harness.coordinator.recordPrepared(testId(1), testAttestation(request.write, testId(1), 1)),
    );
    try std.testing.expectEqual(@as(usize, 1), harness.verifier.prepare_calls);
    try std.testing.expect((try harness.coordinator.inspect()).pending.?.attestations[0] == null);
}

test "two durable attestations create one canonical durable decision" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{4} ** 4096;
    const request = testBegin(1, @splat(0), 23, &data, .{ testId(2), testId(1) });
    _ = try harness.coordinator.begin(request);
    try harness.coordinator.recordPrepared(testId(2), testAttestation(request.write, testId(2), 2));
    try std.testing.expectError(error.PrepareQuorumMissing, harness.coordinator.decide());
    try harness.reopen();
    try harness.coordinator.recordPrepared(testId(1), testAttestation(request.write, testId(1), 1));
    const certificate = try harness.coordinator.decide();
    try std.testing.expect(std.mem.order(u8, &certificate.attestations[0].member_id, &certificate.attestations[1].member_id) == .lt);
    try harness.reopen();
    try std.testing.expect(std.meta.eql(certificate, try harness.coordinator.decide()));
    try std.testing.expect((try harness.coordinator.inspect()).pending.?.certificate != null);
}

test "commit progress is idempotent and converges before advancing frontier" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{5} ** 4096;
    var request = testBegin(1, @splat(0), 24, &data, .{ testId(1), testId(2) });
    request.write.authority.write_epoch = 2;
    _ = try harness.coordinator.begin(request);
    try harness.coordinator.recordPrepared(testId(1), testAttestation(request.write, testId(1), 1));
    try harness.coordinator.recordPrepared(testId(2), testAttestation(request.write, testId(2), 2));
    const certificate = try harness.coordinator.decide();
    const result = testCommitResult(request.write, certificate);
    try std.testing.expectError(error.WitnessNotSelected, harness.coordinator.recordCommitted(testId(3), result));
    var spoofed = result;
    spoofed.history_digest[0] ^= 1;
    try std.testing.expectError(error.CommitResultMismatch, harness.coordinator.recordCommitted(testId(1), spoofed));
    try std.testing.expectEqual(@as(usize, 0), harness.verifier.commit_calls);
    harness.verifier.reject_commit = true;
    try std.testing.expectError(
        error.UnverifiedCommitEvidence,
        harness.coordinator.recordCommitted(testId(1), result),
    );
    try std.testing.expectEqual(@as(usize, 1), harness.verifier.commit_calls);
    try std.testing.expect(std.meta.eql(certificate, harness.verifier.last_commit_certificate.?));
    try std.testing.expect(std.meta.eql(result, harness.verifier.last_commit_result.?));
    try std.testing.expectEqualSlices(u8, &testId(1), &harness.verifier.last_commit_witness.?);
    try std.testing.expect((try harness.coordinator.inspect()).pending.?.commit_results[0] == null);
    harness.verifier.reject_commit = false;
    try std.testing.expect((try harness.coordinator.recordCommitted(testId(1), result)) == null);
    try std.testing.expectEqual(@as(usize, 2), harness.verifier.commit_calls);
    try harness.reopen();
    try std.testing.expect((try harness.coordinator.recordCommitted(testId(1), result)) == null);
    try std.testing.expectEqual(@as(usize, 2), harness.verifier.commit_calls);
    var mismatch = result;
    mismatch.history_digest[0] ^= 1;
    try std.testing.expectError(error.CommitResultMismatch, harness.coordinator.recordCommitted(testId(2), mismatch));
    const completed = (try harness.coordinator.recordCommitted(testId(2), result)).?;
    try std.testing.expect(std.meta.eql(result, completed));
    const inspection = try harness.coordinator.inspect();
    try std.testing.expectEqual(@as(u64, 1), inspection.frontier.sequence);
    try std.testing.expect(inspection.pending == null);
    try std.testing.expect(inspection.last_completed != null);
    try std.testing.expectEqual(BeginResult.completed, try harness.coordinator.begin(request));

    const next_data = [_]u8{6} ** 4096;
    var wrong_volume = testBegin(2, result.history_digest, 25, &next_data, .{ testId(1), testId(2) });
    wrong_volume.write.authority.volume_id = testId(99);
    try std.testing.expectError(error.VolumeMismatch, harness.coordinator.begin(wrong_volume));
    const regressed = testBegin(2, result.history_digest, 25, &next_data, .{ testId(1), testId(2) });
    try std.testing.expectError(error.AuthorityRegression, harness.coordinator.begin(regressed));
    var conflicting_authority = testBegin(2, result.history_digest, 25, &next_data, .{ testId(1), testId(2) });
    conflicting_authority.write.authority.write_epoch = 2;
    conflicting_authority.write.authority.lease_id = testId(98);
    try std.testing.expectError(error.AuthorityConflict, harness.coordinator.begin(conflicting_authority));
    const unchanged = try harness.coordinator.inspect();
    try std.testing.expectEqual(@as(u64, 1), unchanged.frontier.sequence);
    try std.testing.expect(unchanged.pending == null);
    var next = testBegin(2, result.history_digest, 25, &next_data, .{ testId(1), testId(2) });
    next.write.authority.write_epoch = 2;
    try std.testing.expectEqual(BeginResult.started, try harness.coordinator.begin(next));
}

test "reopen preserves preparing decided partially committed and completed phases" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const data = [_]u8{7} ** 4096;
    const request = testBegin(1, @splat(0), 26, &data, .{ testId(1), testId(2) });
    _ = try harness.coordinator.begin(request);
    try harness.reopen();
    try std.testing.expect((try harness.coordinator.inspect()).pending != null);
    try harness.coordinator.recordPrepared(testId(1), testAttestation(request.write, testId(1), 1));
    try harness.reopen();
    try std.testing.expect((try harness.coordinator.inspect()).pending.?.attestations[0] != null);
    try harness.coordinator.recordPrepared(testId(2), testAttestation(request.write, testId(2), 2));
    const certificate = try harness.coordinator.decide();
    try harness.reopen();
    try std.testing.expect((try harness.coordinator.inspect()).pending.?.certificate != null);
    const result = testCommitResult(request.write, certificate);
    _ = try harness.coordinator.recordCommitted(testId(1), result);
    try harness.reopen();
    try std.testing.expect((try harness.coordinator.inspect()).pending.?.commit_results[0] != null);
    _ = try harness.coordinator.recordCommitted(testId(2), result);
    try harness.reopen();
    try std.testing.expectEqual(@as(u64, 1), (try harness.coordinator.inspect()).frontier.sequence);
}

test "file store rejects corruption truncation and concurrent ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var verifier: TestVerifier = .{};
    const first = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state");
    var first_open = true;
    defer if (first_open) first.deinit();
    const coordinator = try Coordinator.initFile(std.testing.allocator, testMembers(), first, verifier.verifier());
    coordinator.deinit();
    try std.testing.expectError(
        error.StateFileLocked,
        FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state"),
    );
    const valid_bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        "coordinator.state",
        std.testing.allocator,
        .limited(FileStoreInner.max_file_size),
    );
    defer std.testing.allocator.free(valid_bytes);
    valid_bytes[32] ^= 1;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "corrupt.state", .data = valid_bytes });
    try std.testing.expectError(
        error.StoreCorrupt,
        FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "corrupt.state"),
    );
    first.deinit();
    first_open = false;
    var file = try tmp.dir.openFile(std.testing.io, "coordinator.state", .{ .mode = .read_write });
    try file.setLength(std.testing.io, 10);
    file.close(std.testing.io);
    try std.testing.expectError(
        error.StoreCorrupt,
        FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state"),
    );
}

test "reopen validates complete payload-independent last-completed metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var verifier: TestVerifier = .{};
    const store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state");
    const coordinator = try Coordinator.initFile(std.testing.allocator, testMembers(), store, verifier.verifier());
    const data = [_]u8{9} ** 4096;
    const request = testBegin(1, @splat(0), 30, &data, .{ testId(1), testId(2) });
    _ = try coordinator.begin(request);
    try coordinator.recordPrepared(testId(1), testAttestation(request.write, testId(1), 1));
    try coordinator.recordPrepared(testId(2), testAttestation(request.write, testId(2), 2));
    const certificate = try coordinator.decide();
    const result = testCommitResult(request.write, certificate);
    _ = try coordinator.recordCommitted(testId(1), result);
    _ = try coordinator.recordCommitted(testId(2), result);
    coordinator.deinit();
    store.deinit();

    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        "coordinator.state",
        std.testing.allocator,
        .limited(FileStoreInner.max_file_size),
    );
    defer std.testing.allocator.free(bytes);
    const completed_offset = 24 + members_encoded_size + 40 + intent_encoded_size;
    const data_digest_offset = completed_offset + authority_encoded_size + 3 * @sizeOf(Id) + 8 + 16 + 32 + 8 + 8;
    @memset(bytes[data_digest_offset..][0..@sizeOf(Digest)], 0);
    std.mem.writeInt(
        u32,
        bytes[bytes.len - FileStoreInner.checksum_size ..][0..FileStoreInner.checksum_size],
        std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - FileStoreInner.checksum_size]),
        .little,
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "coordinator.state", .data = bytes });
    try std.testing.expectError(
        error.StoreCorrupt,
        FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "coordinator.state"),
    );
}

test "durability faults preserve or poison every coordinator mutation boundary" {
    const stages = [_]MutationStage{ .intent, .first_prepare, .second_prepare, .decision, .partial_commit, .completion };
    const fault_kinds = [_]FaultKind{ .write, .file_sync, .directory_sync };
    for (fault_kinds) |fault_kind| {
        for (stages) |stage| {
            var harness = try TestHarness.init();
            defer harness.deinit();
            const data = [_]u8{8} ** 4096;
            const request = testBegin(1, @splat(0), 27, &data, .{ testId(1), testId(2) });
            try setupBeforeMutation(harness.coordinator, request, stage);
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
            var rejected = false;
            applyMutation(harness.coordinator, request, stage) catch |err| {
                rejected = true;
                try std.testing.expectEqual(expected_error, err);
            };
            try std.testing.expect(rejected);

            if (fault_kind == .directory_sync) {
                try std.testing.expect(harness.store.isPoisoned());
                try std.testing.expectError(error.StorePoisoned, harness.coordinator.inspect());
                try harness.reopen();
                try std.testing.expect(try mutationReached(harness.coordinator, stage));
            } else {
                try std.testing.expect(!harness.store.isPoisoned());
                try std.testing.expect(!try mutationReached(harness.coordinator, stage));
                try applyMutation(harness.coordinator, request, stage);
                try std.testing.expect(try mutationReached(harness.coordinator, stage));
            }
        }
    }
}

test "payload bounds are enforced" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const too_large = try std.testing.allocator.alloc(u8, write_service.max_payload_size + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 9);
    try std.testing.expectError(
        error.InvalidWrite,
        harness.coordinator.begin(testBegin(1, @splat(0), 28, too_large, .{ testId(1), testId(2) })),
    );
    try std.testing.expectError(
        error.InvalidWrite,
        harness.coordinator.begin(testBegin(1, @splat(0), 28, &.{}, .{ testId(1), testId(2) })),
    );
    try std.testing.expectEqual(
        BeginResult.started,
        try harness.coordinator.begin(testBegin(
            1,
            @splat(0),
            29,
            too_large[0..write_service.max_payload_size],
            .{ testId(1), testId(2) },
        )),
    );
}
