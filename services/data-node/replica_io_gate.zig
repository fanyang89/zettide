const std = @import("std");

const protocol = @import("zettide_data_service_contracts");
const fence_service = protocol.fence_service;
const write_service = protocol.write_service;

/// Validates an exact live authority while the placement gate is held.
/// Production validation must combine the process-local lease window with the
/// durable ready authority record.
pub const AuthorityValidator = struct {
    context: *anyopaque,
    validate_fn: *const fn (*anyopaque, protocol.AuthorityBinding) anyerror!void,

    pub fn validate(self: AuthorityValidator, authority: protocol.AuthorityBinding) !void {
        try self.validate_fn(self.context, authority);
    }
};

/// One placement-scoped exclusion gate shared by normal write admission,
/// certified replay, Replica retirement, and durable fencing. A fence caller
/// must hold beginExclusive/end around the complete fence_service.accept call,
/// including the fence-ledger append.
pub const ReplicaIoGate = struct {
    io: std.Io,
    replica: protocol.ReplicaBinding,
    replicas: *protocol.replica_service.FileStore,
    fences: *fence_service.FileStore,
    authority_validator: AuthorityValidator,
    mutex: std.Io.Mutex = .init,

    pub fn init(
        io: std.Io,
        replica: protocol.ReplicaBinding,
        replicas: *protocol.replica_service.FileStore,
        fences: *fence_service.FileStore,
        authority_validator: AuthorityValidator,
    ) ReplicaIoGate {
        return .{
            .io = io,
            .replica = replica,
            .replicas = replicas,
            .fences = fences,
            .authority_validator = authority_validator,
        };
    }

    pub fn admission(self: *ReplicaIoGate) write_service.Admission {
        return .{
            .context = self,
            .begin_fn = beginWriteOpaque,
            .begin_replay_fn = beginReplayOpaque,
            .end_fn = endOpaque,
        };
    }

    pub fn beginExclusive(self: *ReplicaIoGate) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn end(self: *ReplicaIoGate) void {
        self.mutex.unlock(self.io);
    }

    fn beginWriteOpaque(context: *anyopaque, authority: protocol.AuthorityBinding) !void {
        const self: *ReplicaIoGate = @ptrCast(@alignCast(context));
        self.beginExclusive();
        errdefer self.end();
        try self.authority_validator.validate(authority);
        try self.validateFence(authority);
    }

    fn beginReplayOpaque(context: *anyopaque, authority: protocol.AuthorityBinding) !void {
        const self: *ReplicaIoGate = @ptrCast(@alignCast(context));
        self.beginExclusive();
        errdefer self.end();
        // A certified replay bypasses the expired live lease, but never the
        // durable fence that authorized the decision.
        try self.validateFence(authority);
    }

    fn endOpaque(context: *anyopaque) void {
        const self: *ReplicaIoGate = @ptrCast(@alignCast(context));
        self.end();
    }

    fn validateFence(self: *ReplicaIoGate, authority: protocol.AuthorityBinding) !void {
        _ = try self.replicas.validateActive(self.replica);
        if (!std.mem.eql(u8, &authority.volume_id, &self.replica.volume_id))
            return error.VolumeMismatch;
        const latest = (try self.fences.latest(self.replica.volume_id, self.replica.placement_id)) orelse
            return error.FenceRequired;
        const fence = latest.binding;
        if (fence.replica_generation != self.replica.generation)
            return error.FenceGenerationMismatch;
        // The durable fence is an epoch/primary barrier. Lease and authority
        // digest rotate during same-primary renewal and must not strand an
        // already-durable exact replay. Normal admission has already passed
        // the exact READY AuthorityBinding validator above.
        if (fence.write_epoch != authority.write_epoch or
            !std.mem.eql(u8, &fence.primary_node_id, &authority.primary_node_id))
            return error.AuthorityFenced;
    }
};

const FakeReplicaBackend = struct {
    fn backend(self: *FakeReplicaBackend) protocol.replica_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn ensureOpaque(_: *anyopaque, _: protocol.ReplicaBinding) !protocol.Digest {
        return @splat(0x33);
    }

    fn deleteOpaque(_: *anyopaque, _: protocol.ReplicaBinding) !void {}

    const vtable: protocol.replica_service.Backend.VTable = .{
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
    };
};

const FakeFenceBackend = struct {
    fn backend(self: *FakeFenceBackend) fence_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn quiesceDrainFlushOpaque(_: *anyopaque, binding: fence_service.Binding) !protocol.Digest {
        var digest: protocol.Digest = @splat(0x5a);
        digest[0] = @truncate(binding.write_epoch);
        return digest;
    }

    const vtable: fence_service.Backend.VTable = .{ .quiesceDrainFlush = quiesceDrainFlushOpaque };
};

const FakeAuthorityValidator = struct {
    expected: protocol.AuthorityBinding,
    active: bool = true,

    fn validator(self: *FakeAuthorityValidator) AuthorityValidator {
        return .{ .context = self, .validate_fn = validateOpaque };
    }

    fn validateOpaque(context: *anyopaque, authority: protocol.AuthorityBinding) !void {
        const self: *FakeAuthorityValidator = @ptrCast(@alignCast(context));
        if (!self.active or !std.meta.eql(self.expected, authority)) return error.AuthorityRejected;
    }
};

fn testId(byte: u8) protocol.Id {
    var id: protocol.Id = @splat(byte);
    id[6] = 0x70 | (byte & 0x0f);
    id[8] = 0x80 | (byte & 0x3f);
    return id;
}

const test_member_id = testId(5);

fn replicaRequest() protocol.ReplicaRequest {
    return .{
        .operation_id = "0198f54d-5c2a-7000-8000-000000000014",
        .volume_id = "0198f54d-5c2a-7000-8000-000000000011",
        .placement_id = "0198f54d-5c2a-7000-8000-000000000012",
        .allocation_id = "0198f54d-5c2a-7000-8000-000000000013",
        .generation = 4,
        .member_id = &test_member_id,
        .offset_bytes = 4096,
        .length_bytes = 8192,
    };
}

fn testAuthority(volume_id: protocol.Id, epoch: u64) protocol.AuthorityBinding {
    return .{
        .volume_id = volume_id,
        .primary_placement_id = testId(6),
        .primary_node_id = testId(7),
        .lease_id = testId(@truncate(10 + epoch)),
        .holder_boot_id = testId(8),
        .authority_generation = epoch,
        .write_epoch = epoch,
        .placement_revision = epoch,
        .activation_nonce = testId(9),
        .authority_digest = @splat(@as(u8, @truncate(epoch))),
    };
}

fn testFence(
    operation: u8,
    replica: protocol.ReplicaBinding,
    authority: protocol.AuthorityBinding,
) fence_service.Binding {
    return .{
        .operation_id = testId(operation),
        .volume_id = replica.volume_id,
        .placement_id = replica.placement_id,
        .replica_generation = replica.generation,
        .write_epoch = authority.write_epoch,
        .primary_node_id = authority.primary_node_id,
        .lease_id = authority.lease_id,
        .authority_digest = authority.authority_digest,
    };
}

test "placement gate admits renewal writes and old exact replay under epoch primary barrier" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var replicas = try protocol.replica_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer replicas.deinit();
    var replica_backend: FakeReplicaBackend = .{};
    var replica_engine = protocol.replica_service.Service.init(replicas.store(), replica_backend.backend());
    const replica = (try replica_engine.ensureReplica(replicaRequest())).replica.attestation.binding;
    var fences = try fence_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences.state");
    defer fences.deinit();
    var fence_backend: FakeFenceBackend = .{};
    var fence_engine = fence_service.Service.init(fences.store(), fence_backend.backend());
    const authority = testAuthority(replica.volume_id, 7);
    _ = try fence_engine.accept(testFence(20, replica, authority));

    var validator: FakeAuthorityValidator = .{ .expected = authority };
    var gate = ReplicaIoGate.init(std.testing.io, replica, &replicas, &fences, validator.validator());
    const admission = gate.admission();
    try admission.begin_fn(admission.context, authority);
    admission.end_fn(admission.context);

    var renewal = authority;
    renewal.lease_id = testId(30);
    renewal.authority_generation += 1;
    renewal.authority_digest = @splat(0x9a);
    validator.expected = renewal;
    try std.testing.expectError(
        error.AuthorityRejected,
        admission.begin_fn(admission.context, authority),
    );
    try admission.begin_fn(admission.context, renewal);
    admission.end_fn(admission.context);
    // A payload durably prepared under the old lease may finish after renewal.
    try admission.begin_replay_fn(admission.context, authority);
    admission.end_fn(admission.context);

    const next = testAuthority(replica.volume_id, 8);
    gate.beginExclusive();
    _ = fence_engine.accept(testFence(21, replica, next)) catch |err| {
        gate.end();
        return err;
    };
    gate.end();
    try std.testing.expectError(
        error.AuthorityFenced,
        admission.begin_replay_fn(admission.context, authority),
    );
}
