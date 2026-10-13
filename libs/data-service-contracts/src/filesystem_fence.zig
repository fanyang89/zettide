const std = @import("std");
const model = @import("model.zig");
const durable = @import("fence_service.zig");

pub const Id = model.Id;
pub const Digest = model.Digest;
pub const NameProfile = enum(u8) { legacy_raw = 1, portable_v1 = 2 };

/// Immutable, storage-verified identity. A path, mountpoint or management name
/// is not an identity. backend_digest must cover the durable physical Pool,
/// Members and root Blob object; its derivation belongs to the storage adapter.
pub const Identity = struct {
    cluster_id: Id,
    pool_id: Id,
    filesystem_id: Id,
    backend_digest: Digest,
    root_format: u32 = 1,
    name_profile: NameProfile,
};
pub const Owner = struct { node_id: Id, boot_id: Id };
pub const Binding = struct {
    identity: Identity,
    owner: Owner,
    placement_generation: u64,
    epoch: u64,
};
pub const Receipt = struct { binding: Binding, drain_digest: Digest };
pub const Recovery = struct { binding: Binding, digest: Digest };
pub const Phase = enum { prepare, recover, activate, payload };

/// Trusted adapters, never callbacks supplied by a filesystem client.
/// These calls run under the gate except verify_identity; none may reenter it.
pub const Backend = struct {
    context: *anyopaque,
    verify_identity: *const fn (*anyopaque, Identity) anyerror!void,
    /// Verify exact controller authorization. prepare/recover require committed
    /// non-cancellable PREPARING, NOT CANDIDATE. activate/payload require matching
    /// committed readiness and a current, conservative local lease window.
    /// When present, recovery_digest must match committed readiness too.
    authorize: *const fn (*anyopaque, Binding, Phase, ?Digest) anyerror!void,
    /// Drain ALL old routes, deferred writes and replay, then sync media. A
    /// local mutex or elapsed lease timeout alone does not prove this barrier.
    drain_flush: *const fn (*anyopaque, Binding) anyerror!Digest,
    /// Validate root format/profile and resolve backend transactional/orphan
    /// state. This may touch storage only after the durable epoch barrier.
    recover: *const fn (*anyopaque, Receipt) anyerror!Digest,
};

/// One gate/ledger per physical filesystem. Caller must hold exclusive process
/// ownership of both backend and ledger for its entire lifetime. This module
/// does not supply that lock, a controller adapter, or a remote fencing protocol.
/// All actual I/O (including reads) must retain Guard until real completion.
pub const Gate = struct {
    ledger: durable.FileStore,
    identity: Identity,
    owner: Owner,
    backend: Backend,
    mutex: std.Io.Mutex = .init,
    failed: bool = false,
    recovered: ?Recovery = null,
    ready: bool = false,

    pub const Guard = struct {
        gate: *Gate,
        /// After actual I/O completion, fail admission closed on an uncertain
        /// payload error. The guard remains held and must still be ended.
        pub fn failClosed(self: *Guard) void {
            self.gate.poison();
        }
        pub fn end(self: *Guard) void {
            self.gate.mutex.unlock(self.gate.ledger.io);
            self.* = undefined;
        }
    };

    /// Explicit initial provisioning only. Missing recovery history is fatal.
    pub fn createLedger(io: std.Io, parent: std.Io.Dir, basename: []const u8) !void {
        try durable.FileStore.createEmpty(io, parent, basename);
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, basename: []const u8, identity: Identity, owner: Owner, backend: Backend) !Gate {
        try validateIdentity(identity);
        try validateOwner(owner);
        try backend.verify_identity(backend.context, identity);
        var ledger = try durable.FileStore.openRequired(allocator, io, parent, basename);
        errdefer ledger.deinit();
        const key = identityKey(identity);
        var generation: u64 = 0;
        for (ledger.records) |record| {
            if (!std.mem.eql(u8, &record.binding.volume_id, &identity.filesystem_id) or
                !std.mem.eql(u8, &record.binding.placement_id, &identity.filesystem_id) or
                !std.mem.eql(u8, &record.binding.lease_id, &key)) return error.LedgerIdentityMismatch;
            if (record.binding.replica_generation < generation or
                !std.mem.eql(u8, &record.binding.operation_id, &keyFromDigest(record.binding.authority_digest))) return error.InvalidLedgerHistory;
            generation = record.binding.replica_generation;
        }
        // A durable fence is NOT readiness. Reopening never restores admission.
        return .{ .ledger = ledger, .identity = identity, .owner = owner, .backend = backend };
    }

    /// Stop and join all callers before closing. Names and parent remain borrowed.
    pub fn deinit(self: *Gate) void {
        self.ledger.deinit();
        self.* = undefined;
    }

    pub fn prepare(self: *Gate, binding: Binding) !Receipt {
        self.mutex.lockUncancelable(self.ledger.io);
        defer self.mutex.unlock(self.ledger.io);
        try self.check(binding);
        const encoded = fenceBinding(binding);
        if (try self.ledger.latest(self.identity.filesystem_id, self.identity.filesystem_id)) |current| {
            // Check latest BEFORE the generic journal's historical retry lookup.
            if (binding.epoch < current.binding.write_epoch) return error.StaleEpoch;
            if (binding.placement_generation < current.binding.replica_generation) return error.PlacementRegression;
            if (binding.epoch == current.binding.write_epoch and
                !std.meta.eql(encoded, current.binding)) return error.BindingConflict;
        }
        try self.backend.authorize(self.backend.context, binding, .prepare, null);
        // An identical retry must not erase an already recovered/ready state.
        if (self.recovered) |value| {
            if (!sameBinding(value.binding, binding)) {
                self.ready = false;
                self.recovered = null;
            }
        }
        var adapter = FlushAdapter{ .gate = self, .binding = binding };
        var service = durable.Service.init(self.ledger.store(), .{ .context = &adapter, .vtable = &FlushAdapter.vtable });
        const result = service.accept(encoded) catch |err| {
            self.poison();
            return err;
        };
        return .{ .binding = binding, .drain_digest = result.fence_digest };
    }

    pub fn recover(self: *Gate, binding: Binding) !Recovery {
        self.mutex.lockUncancelable(self.ledger.io);
        defer self.mutex.unlock(self.ledger.io);
        const current = try self.requireCurrent(binding);
        try self.backend.authorize(self.backend.context, binding, .recover, null);
        if (self.ready) return error.AlreadyReady;
        if (self.recovered) |value| return value;
        const digest = self.backend.recover(self.backend.context, .{ .binding = binding, .drain_digest = current.fence_digest }) catch |err| {
            self.poison();
            return err;
        };
        if (std.mem.allEqual(u8, &digest, 0)) {
            self.poison();
            return error.InvalidRecoveryDigest;
        }
        const result = Recovery{ .binding = binding, .digest = digest };
        self.recovered = result;
        return result;
    }

    pub fn activate(self: *Gate, recovery: Recovery) !void {
        self.mutex.lockUncancelable(self.ledger.io);
        defer self.mutex.unlock(self.ledger.io);
        _ = try self.requireCurrent(recovery.binding);
        const local = self.recovered orelse return error.NotRecovered;
        if (!sameBinding(local.binding, recovery.binding) or !std.mem.eql(u8, &local.digest, &recovery.digest)) return error.RecoveryMismatch;
        try self.backend.authorize(self.backend.context, recovery.binding, .activate, recovery.digest);
        self.ready = true;
    }

    pub fn begin(self: *Gate, binding: Binding) !Guard {
        self.mutex.lockUncancelable(self.ledger.io);
        errdefer self.mutex.unlock(self.ledger.io);
        _ = try self.requireCurrent(binding);
        if (!self.ready) return error.NotReady;
        try self.backend.authorize(self.backend.context, binding, .payload, self.recovered.?.digest);
        return .{ .gate = self };
    }

    fn check(self: *Gate, binding: Binding) !void {
        if (self.failed) return error.FilesystemGateFailed;
        try validateIdentity(binding.identity);
        try validateOwner(binding.owner);
        if (binding.epoch == 0 or binding.placement_generation == 0) return error.InvalidBinding;
        if (!std.mem.eql(u8, &identityDigest(binding.identity), &identityDigest(self.identity))) return error.IdentityMismatch;
        if (!std.mem.eql(u8, &binding.owner.node_id, &self.owner.node_id) or
            !std.mem.eql(u8, &binding.owner.boot_id, &self.owner.boot_id)) return error.OwnerMismatch;
    }
    fn requireCurrent(self: *Gate, binding: Binding) !durable.Result {
        try self.check(binding);
        const result = (try self.ledger.latest(self.identity.filesystem_id, self.identity.filesystem_id)) orelse return error.NotPrepared;
        const wanted = fenceBinding(binding);
        if (!std.meta.eql(result.binding, wanted)) return error.BindingConflict;
        return result;
    }
    fn poison(self: *Gate) void {
        self.failed = true;
        self.ready = false;
        self.recovered = null;
    }
    const FlushAdapter = struct {
        gate: *Gate,
        binding: Binding,
        fn flush(context: *anyopaque, _: durable.Binding) !Digest {
            const self: *FlushAdapter = @ptrCast(@alignCast(context));
            return self.gate.backend.drain_flush(self.gate.backend.context, self.binding);
        }
        const vtable = durable.Backend.VTable{ .quiesceDrainFlush = flush };
    };
};

fn validateIdentity(identity: Identity) !void {
    if (std.mem.allEqual(u8, &identity.cluster_id, 0) or !validId(identity.pool_id) or !validId(identity.filesystem_id) or
        std.mem.allEqual(u8, &identity.backend_digest, 0) or identity.root_format != 1) return error.InvalidIdentity;
}
fn validateOwner(owner: Owner) !void {
    if (!validId(owner.node_id) or std.mem.allEqual(u8, &owner.boot_id, 0)) return error.InvalidOwner;
}
fn validId(id: Id) bool {
    return id[6] & 0xf0 == 0x70 and id[8] & 0xc0 == 0x80;
}
fn hashInt(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
fn identityDigest(identity: Identity) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zettide/filesystem/storage-identity/v1");
    for ([_][]const u8{ &identity.cluster_id, &identity.pool_id, &identity.filesystem_id, &identity.backend_digest }) |field| hash.update(field);
    hashInt(&hash, identity.root_format);
    hashInt(&hash, @intFromEnum(identity.name_profile));
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}
fn bindingDigest(binding: Binding) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zettide/filesystem/fence-binding/v1");
    hash.update(&identityDigest(binding.identity));
    hash.update(&binding.owner.node_id);
    hash.update(&binding.owner.boot_id);
    hashInt(&hash, binding.placement_generation);
    hashInt(&hash, binding.epoch);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}
fn sameBinding(a: Binding, b: Binding) bool {
    return std.mem.eql(u8, &bindingDigest(a), &bindingDigest(b));
}
/// UUID-shaped internal keys for the generic journal, not public UUID timestamps.
fn keyFromDigest(digest: Digest) Id {
    var result = digest[0..16].*;
    result[6] = (result[6] & 0x0f) | 0x70;
    result[8] = (result[8] & 0x3f) | 0x80;
    return result;
}
fn identityKey(identity: Identity) Id {
    return keyFromDigest(identityDigest(identity));
}
/// Reuse the checksummed/fsync journal ONLY in a separate filesystem ledger.
/// The high-water key stays constant across epochs/boots/placement generations.
fn fenceBinding(binding: Binding) durable.Binding {
    const digest = bindingDigest(binding);
    return .{ .operation_id = keyFromDigest(digest), .volume_id = binding.identity.filesystem_id, .placement_id = binding.identity.filesystem_id, .replica_generation = binding.placement_generation, .write_epoch = binding.epoch, .primary_node_id = binding.owner.node_id, .lease_id = identityKey(binding.identity), .authority_digest = digest };
}

fn testId(byte: u8) Id {
    var id: Id = @splat(byte);
    id[6] = 0x70;
    id[8] = 0x80;
    return id;
}
fn testBinding() Binding {
    return .{ .identity = .{ .cluster_id = testId(1), .pool_id = testId(2), .filesystem_id = testId(3), .backend_digest = @splat(4), .name_profile = .legacy_raw }, .owner = .{ .node_id = testId(5), .boot_id = testId(6) }, .placement_generation = 1, .epoch = 10 };
}
const TestBackend = struct {
    allowed: Binding = testBinding(),
    state: enum { candidate, preparing, ready } = .preparing,
    lease_live: bool = true,
    flushes: usize = 0,
    recoveries: usize = 0,
    fail_flush: bool = false,
    fail_recovery: bool = false,
    recovery_digest: Digest = @splat(0x33),
    file: ?std.Io.File = null,

    fn interface(self: *TestBackend) Backend {
        return .{ .context = self, .verify_identity = verify, .authorize = authorize, .drain_flush = flush, .recover = recoverBackend };
    }
    fn verify(context: *anyopaque, identity: Identity) !void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, &identityDigest(identity), &identityDigest(self.allowed.identity))) return error.PhysicalIdentityMismatch;
    }
    fn authorize(context: *anyopaque, binding: Binding, phase: Phase, digest: ?Digest) !void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        if (!sameBinding(binding, self.allowed)) return error.NotAuthorized;
        switch (phase) {
            .prepare => if (self.state != .preparing) return error.NotAuthorized,
            .recover => if (self.state != .preparing) return error.NotAuthorized,
            .activate, .payload => {
                if (self.state != .ready or !self.lease_live or digest == null or
                    !std.mem.eql(u8, &digest.?, &self.recovery_digest)) return error.NotAuthorized;
            },
        }
    }
    fn flush(context: *anyopaque, _: Binding) !Digest {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.flushes += 1;
        if (self.fail_flush) return error.FlushFailed;
        if (self.file) |file| try file.sync(std.testing.io);
        return @splat(0x22);
    }
    fn recoverBackend(context: *anyopaque, receipt: Receipt) !Digest {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.recoveries += 1;
        if (self.fail_recovery) return error.RecoveryFailed;
        if (!sameBinding(receipt.binding, self.allowed) or std.mem.allEqual(u8, &receipt.drain_digest, 0)) return error.InvalidReceipt;
        return self.recovery_digest;
    }
};

fn testOpen(tmp: std.Io.Dir, backend: *TestBackend) !Gate {
    return Gate.open(std.testing.allocator, std.testing.io, tmp, "filesystem-fence", backend.allowed.identity, backend.allowed.owner, backend.interface());
}
fn testReady(gate: *Gate, backend: *TestBackend) !Recovery {
    _ = try gate.prepare(backend.allowed);
    const recovery = try gate.recover(backend.allowed);
    backend.state = .ready;
    try gate.activate(recovery);
    return recovery;
}

test "filesystem gate separates candidate preparation recovery and committed readiness" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: TestBackend = .{ .state = .candidate };
    try Gate.createLedger(std.testing.io, tmp.dir, "filesystem-fence");
    var gate = try testOpen(tmp.dir, &backend);
    defer gate.deinit();
    const binding = backend.allowed;
    try std.testing.expectError(error.NotPrepared, gate.begin(binding));
    try std.testing.expectError(error.NotPrepared, gate.recover(binding));
    try std.testing.expectError(error.NotAuthorized, gate.prepare(binding));
    try std.testing.expectEqual(@as(usize, 0), backend.flushes);
    backend.state = .preparing;
    _ = try gate.prepare(binding);
    _ = try gate.prepare(binding);
    try std.testing.expectEqual(@as(usize, 1), backend.flushes);
    try std.testing.expectError(error.NotReady, gate.begin(binding));
    try std.testing.expectError(error.NotRecovered, gate.activate(.{ .binding = binding, .digest = backend.recovery_digest }));
    const recovery = try gate.recover(binding);
    try std.testing.expectEqualDeep(recovery, try gate.recover(binding));
    try std.testing.expectEqual(@as(usize, 1), backend.recoveries);
    try std.testing.expectError(error.NotAuthorized, gate.activate(recovery));
    var wrong = recovery;
    wrong.digest[0] ^= 1;
    try std.testing.expectError(error.RecoveryMismatch, gate.activate(wrong));
    backend.state = .ready;
    try gate.activate(recovery);
    try std.testing.expectError(error.NotAuthorized, gate.prepare(binding));
    var guard = try gate.begin(binding);
    guard.end();
    backend.lease_live = false;
    try std.testing.expectError(error.NotAuthorized, gate.begin(binding));
}

test "filesystem durable high-water rejects old epochs boots generations and late activation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: TestBackend = .{};
    try Gate.createLedger(std.testing.io, tmp.dir, "filesystem-fence");
    const first = backend.allowed;
    var old_recovery: Recovery = undefined;
    {
        var gate = try testOpen(tmp.dir, &backend);
        defer gate.deinit();
        old_recovery = try testReady(&gate, &backend);
    }
    // Even a matching persisted READY control record cannot reopen admission.
    {
        var gate = try testOpen(tmp.dir, &backend);
        defer gate.deinit();
        try std.testing.expectError(error.NotReady, gate.begin(first));
        try std.testing.expectError(error.NotRecovered, gate.activate(old_recovery));
    }
    backend.allowed.owner.boot_id = testId(7);
    backend.state = .preparing;
    {
        var gate = try testOpen(tmp.dir, &backend);
        defer gate.deinit();
        try std.testing.expectError(error.OwnerMismatch, gate.begin(first));
        try std.testing.expectError(error.BindingConflict, gate.prepare(backend.allowed));
        backend.allowed.epoch = 20;
        backend.allowed.placement_generation = 2;
        _ = try testReady(&gate, &backend);
        try std.testing.expectError(error.OwnerMismatch, gate.activate(old_recovery));
        var forged = backend.allowed;
        forged.epoch = 21;
        try std.testing.expectError(error.NotAuthorized, gate.prepare(forged));
        forged.placement_generation = 1;
        try std.testing.expectError(error.PlacementRegression, gate.prepare(forged));
    }
    // The historical operation ID still exists, but cannot acknowledge an old fence.
    backend.allowed = first;
    var gate = try testOpen(tmp.dir, &backend);
    defer gate.deinit();
    try std.testing.expectError(error.StaleEpoch, gate.prepare(first));
    try std.testing.expectError(error.BindingConflict, gate.begin(first));
    try std.testing.expectError(error.BindingConflict, gate.recover(first));
}

test "filesystem ledger rejects missing corrupt and foreign backend history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: TestBackend = .{};
    try std.testing.expectError(error.FileNotFound, testOpen(tmp.dir, &backend));
    try Gate.createLedger(std.testing.io, tmp.dir, "filesystem-fence");
    try std.testing.expectError(error.PathAlreadyExists, Gate.createLedger(std.testing.io, tmp.dir, "filesystem-fence"));
    {
        var gate = try testOpen(tmp.dir, &backend);
        defer gate.deinit();
        _ = try gate.prepare(backend.allowed);
        var wrong = backend.allowed;
        wrong.identity.backend_digest[0] ^= 1;
        try std.testing.expectError(error.IdentityMismatch, gate.prepare(wrong));
        try std.testing.expectError(error.PhysicalIdentityMismatch, Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "filesystem-fence", wrong.identity, wrong.owner, backend.interface()));
    }
    for (0..5) |field| {
        backend.allowed = testBinding();
        switch (field) {
            0 => backend.allowed.identity.cluster_id = testId(10),
            1 => backend.allowed.identity.pool_id = testId(10),
            2 => backend.allowed.identity.filesystem_id = testId(10),
            3 => backend.allowed.identity.backend_digest[0] ^= 1,
            else => backend.allowed.identity.name_profile = .portable_v1,
        }
        try std.testing.expectError(error.LedgerIdentityMismatch, testOpen(tmp.dir, &backend));
    }
    backend.allowed = testBinding();
    const file = try tmp.dir.openFile(std.testing.io, "filesystem-fence", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "broken", 0);
    try std.testing.expectError(error.StoreCorrupt, testOpen(tmp.dir, &backend));
    try tmp.dir.deleteFile(std.testing.io, "filesystem-fence");
    try std.testing.expectError(error.FileNotFound, testOpen(tmp.dir, &backend));
}

test "filesystem uncertain drain replace directory sync and recovery poison admission" {
    for (0..5) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var backend: TestBackend = .{};
        try Gate.createLedger(std.testing.io, tmp.dir, "filesystem-fence");
        {
            var gate = try testOpen(tmp.dir, &backend);
            defer gate.deinit();
            _ = try testReady(&gate, &backend);
            backend.allowed.epoch = 20;
            backend.state = .preparing;
            var faults = durable.FileStore.Faults{};
            if (failure == 0) backend.fail_flush = true;
            if (failure == 1) faults.fail_replace_once_at_record_count = 2;
            if (failure == 2) faults.fail_directory_sync_once_at_record_count = 2;
            gate.ledger.faults = &faults;
            if (failure < 3) {
                const expected: anyerror = switch (failure) {
                    0 => error.FlushFailed,
                    1 => error.InjectedReplaceFailure,
                    else => error.InjectedDirectorySyncFailure,
                };
                try std.testing.expectError(expected, gate.prepare(backend.allowed));
            } else {
                _ = try gate.prepare(backend.allowed);
                if (failure == 3) backend.fail_recovery = true else backend.recovery_digest = @splat(0);
                try std.testing.expectError(if (failure == 3) error.RecoveryFailed else error.InvalidRecoveryDigest, gate.recover(backend.allowed));
            }
            try std.testing.expectError(error.FilesystemGateFailed, gate.begin(backend.allowed));
            try std.testing.expectError(error.FilesystemGateFailed, gate.prepare(backend.allowed));
        }
        backend.fail_flush = false;
        backend.fail_recovery = false;
        backend.recovery_digest = @splat(0x33);
        var reopened = try testOpen(tmp.dir, &backend);
        defer reopened.deinit();
        const flushes = backend.flushes;
        _ = try testReady(&reopened, &backend);
        // Rename+failed directory fsync is repaired by openRequired. Do not
        // falsely acknowledge before repair, or unnecessarily repeat that drain.
        if (failure == 2) try std.testing.expectEqual(flushes, backend.flushes);
        var guard = try reopened.begin(backend.allowed);
        guard.end();
    }
}

test "filesystem fence waits for real guarded file completion before syncing and advancing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "payload", .{ .read = true });
    defer file.close(std.testing.io);
    var backend: TestBackend = .{ .file = file };
    try Gate.createLedger(std.testing.io, tmp.dir, "filesystem-fence");
    var gate = try testOpen(tmp.dir, &backend);
    defer gate.deinit();
    _ = try testReady(&gate, &backend);
    const old = backend.allowed;
    var guard = try gate.begin(old);
    backend.allowed.epoch = 20;
    backend.state = .preparing;
    const Worker = struct {
        gate: *Gate,
        binding: Binding,
        started: std.Io.Event = .unset,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.started.set(std.testing.io);
            _ = self.gate.prepare(self.binding) catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
    };
    var worker = Worker{ .gate = &gate, .binding = backend.allowed };
    const thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch |err| {
        guard.end();
        return err;
    };
    worker.started.waitUncancelable(std.testing.io);
    const early = worker.done.load(.acquire);
    const flushes_before = backend.flushes;
    file.writePositionalAll(std.testing.io, "completed", 0) catch |err| {
        guard.end();
        thread.join();
        return err;
    };
    guard.end();
    thread.join();
    try std.testing.expect(!early);
    try std.testing.expectEqual(@as(usize, 1), flushes_before);
    try std.testing.expect(worker.failure == null);
    try std.testing.expectEqual(@as(usize, 2), backend.flushes);
    try std.testing.expectError(error.BindingConflict, gate.begin(old));
    try std.testing.expectError(error.NotReady, gate.begin(backend.allowed));
    const data = try tmp.dir.readFileAlloc(std.testing.io, "payload", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("completed", data);
}

test "filesystem reopen validates domain-specific journal history beyond generic checksums" {
    for (0..2) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var backend: TestBackend = .{};
        backend.allowed.placement_generation = 2;
        try Gate.createLedger(std.testing.io, tmp.dir, "filesystem-fence");
        {
            var gate = try testOpen(tmp.dir, &backend);
            defer gate.deinit();
            _ = try gate.prepare(backend.allowed);
            var damaged = backend.allowed;
            if (corruption == 0) {
                damaged.epoch += 1;
                damaged.placement_generation = 1;
            }
            var encoded = fenceBinding(damaged);
            if (corruption == 1) encoded.operation_id = testId(50);
            // A valid generic fence journal can still violate filesystem rules.
            var adapter = Gate.FlushAdapter{ .gate = &gate, .binding = damaged };
            var service = durable.Service.init(gate.ledger.store(), .{ .context = &adapter, .vtable = &Gate.FlushAdapter.vtable });
            _ = try service.accept(encoded);
        }
        try std.testing.expectError(error.InvalidLedgerHistory, testOpen(tmp.dir, &backend));
    }
}
