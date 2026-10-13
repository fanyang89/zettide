const std = @import("std");
const lease = @import("range_lease.zig");
const durable = @import("fence_service.zig");
const model = @import("model.zig");

pub const Barrier = struct {
    token: lease.Token,
    /// The committed REVOKING revision, strictly greater than the grant token.
    revision: u64,
};

/// Trusted storage adapters, never supplied by a payload caller.
pub const Backend = struct {
    context: *anyopaque,
    /// Verify controller-issued binding and current authorization. A client-
    /// supplied integer is NOT proof of a grant. Also enforce primary readiness.
    authorize: *const fn (*anyopaque, lease.Token) anyerror!void,
    /// Resolve durable pending/replay work and flush physical media. A caller
    /// timeout is not a drain. Called under the same gate as normal physical I/O.
    drain_flush: *const fn (*anyopaque, Barrier) anyerror!model.Digest,
};

/// Storage-side fence, distinct from the holder's expiring admission window.
/// All payload AND recovery paths must use this gate or be drained by Backend.
/// One owner per ledger; the enclosing storage service must hold its process
/// ownership lock. A fence acknowledgement covers this storage target only.
pub const Gate = struct {
    ledger: durable.FileStore,
    backend: Backend,
    mutex: std.Io.Mutex = .init,
    failed: bool = false,

    pub const Guard = struct {
        gate: *Gate,
        /// Call only after actual backend completion or cancellation drain.
        pub fn end(self: *Guard) void {
            self.gate.mutex.unlock(self.gate.ledger.io);
            self.* = undefined;
        }
    };

    /// Bootstrap is explicit and exclusive. Never call this as a recovery fallback.
    pub fn createLedger(io: std.Io, parent: std.Io.Dir, basename: []const u8) !void {
        try durable.FileStore.createEmpty(io, parent, basename);
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, basename: []const u8, backend: Backend) !Gate {
        return .{ .ledger = try durable.FileStore.openRequired(allocator, io, parent, basename), .backend = backend };
    }

    /// Stop/join all callers before deinitialization.
    pub fn deinit(self: *Gate) void {
        self.ledger.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Gate, token: lease.Token, volume_id: model.Id, offset: u64, length: u64, mode: lease.Mode) !Guard {
        self.mutex.lockUncancelable(self.ledger.io);
        errdefer self.mutex.unlock(self.ledger.io);
        if (self.failed) return error.FenceGateFailed;
        try validateToken(token);
        if (!std.mem.eql(u8, &volume_id, &token.volume_id)) return error.VolumeMismatch;
        if (mode == .write and token.mode != .write) return error.ReadOnly;
        if (!lease.validRange(offset, length, std.math.maxInt(u64)) or offset < token.offset or
            offset - token.offset > token.length or length > token.length - (offset - token.offset)) return error.OutOfRange;
        // Lease IDs are never reused. Reject even a forged larger revision or
        // a delayed renewal: terminal fencing cannot resurrect the same ID.
        if (try self.ledger.latest(token.volume_id, token.lease_id) != null) return error.RangeLeaseFenced;
        try self.backend.authorize(self.backend.context, token);
        return .{ .gate = self };
    }

    pub fn fence(self: *Gate, barrier: Barrier) !Barrier {
        try validateToken(barrier.token);
        if (barrier.revision <= barrier.token.revision) return error.StaleFence;
        self.mutex.lockUncancelable(self.ledger.io);
        defer self.mutex.unlock(self.ledger.io);
        if (self.failed) return error.FenceGateFailed;
        var adapter = FlushAdapter{ .gate = self, .barrier = barrier };
        var service = durable.Service.init(self.ledger.store(), .{ .context = &adapter, .vtable = &FlushAdapter.vtable });
        // Any uncertain drain or persistence failure poisons admission until
        // recovery. In particular, no success is returned after a failed fsync.
        _ = service.accept(binding(barrier)) catch |err| {
            self.failed = true;
            return err;
        };
        return barrier;
    }

    const FlushAdapter = struct {
        gate: *Gate,
        barrier: Barrier,
        fn flush(context: *anyopaque, _: durable.Binding) !model.Digest {
            const self: *FlushAdapter = @ptrCast(@alignCast(context));
            return self.gate.backend.drain_flush(self.gate.backend.context, self.barrier);
        }
        const vtable = durable.Backend.VTable{ .quiesceDrainFlush = flush };
    };
};

fn validateToken(token: lease.Token) !void {
    for ([_]model.Id{ token.lease_id, token.volume_id, token.holder_node_id }) |id| {
        if (id[6] & 0xf0 != 0x70 or id[8] & 0xc0 != 0x80) return error.InvalidToken;
    }
    if (std.mem.allEqual(u8, &token.holder_boot_id, 0) or token.revision == 0 or
        !lease.validRange(token.offset, token.length, std.math.maxInt(u64))) return error.InvalidToken;
}

/// Reuse the proven durable fence record format, in a SEPARATE range ledger.
/// The placement key is the lease ID, not a physical Replica placement. Hash
/// every remaining immutable binding field with an explicit domain separator.
fn binding(barrier: Barrier) durable.Binding {
    const token = barrier.token;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zettide/range-fence/v1");
    hash.update(&token.holder_boot_id);
    for ([_]u64{ token.offset, token.length, @intFromEnum(token.mode), token.revision }) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        hash.update(&bytes);
    }
    var digest: model.Digest = undefined;
    hash.final(&digest);
    return .{ .operation_id = token.lease_id, .volume_id = token.volume_id, .placement_id = token.lease_id, .replica_generation = 1, .write_epoch = barrier.revision, .primary_node_id = token.holder_node_id, .lease_id = token.lease_id, .authority_digest = digest };
}

fn testId(byte: u8) model.Id {
    var id: model.Id = @splat(byte);
    id[6] = 0x70;
    id[8] = 0x80;
    return id;
}
fn testToken() lease.Token {
    return .{ .lease_id = testId(1), .volume_id = testId(2), .holder_node_id = testId(3), .holder_boot_id = testId(4), .offset = 0, .length = 8192, .mode = .read, .revision = 10 };
}
const TestBackend = struct {
    flushes: usize = 0,
    fail_flush: bool = false,
    fn backend(self: *TestBackend) Backend {
        return .{ .context = self, .authorize = authorize, .drain_flush = flush };
    }
    fn authorize(_: *anyopaque, token: lease.Token) !void {
        if (token.revision != 10) return error.InvalidGrant;
    }
    fn flush(context: *anyopaque, _: Barrier) !model.Digest {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.flushes += 1;
        if (self.fail_flush) return error.InjectedFlushFailure;
        return @splat(1);
    }
};

test "range fence survives restart, blocks stale renewal, and preserves another reader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: TestBackend = .{};
    const token = testToken();
    const barrier = Barrier{ .token = token, .revision = 11 };
    try std.testing.expectError(error.FileNotFound, Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "ranges", backend.backend()));
    try Gate.createLedger(std.testing.io, tmp.dir, "ranges");
    try std.testing.expectError(error.PathAlreadyExists, Gate.createLedger(std.testing.io, tmp.dir, "ranges"));
    {
        var gate = try Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "ranges", backend.backend());
        defer gate.deinit();
        var guard = try gate.begin(token, token.volume_id, 0, 4096, .read);
        guard.end();
        try std.testing.expectError(error.ReadOnly, gate.begin(token, token.volume_id, 0, 4096, .write));
        try std.testing.expectEqualDeep(barrier, try gate.fence(barrier));
        try std.testing.expectEqualDeep(barrier, try gate.fence(barrier));
        try std.testing.expectEqual(@as(usize, 1), backend.flushes);
    }
    var gate = try Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "ranges", backend.backend());
    defer gate.deinit();
    try std.testing.expectError(error.RangeLeaseFenced, gate.begin(token, token.volume_id, 0, 4096, .read));
    var stale_renewal = token;
    stale_renewal.revision = 100;
    try std.testing.expectError(error.RangeLeaseFenced, gate.begin(stale_renewal, token.volume_id, 0, 4096, .read));
    var other = token;
    other.lease_id = testId(5);
    var guard = try gate.begin(other, other.volume_id, 0, 4096, .read);
    guard.end();
    var forged = other;
    forged.revision += 1;
    try std.testing.expectError(error.InvalidGrant, gate.begin(forged, forged.volume_id, 0, 4096, .read));
}

test "failed drain or persistence never acknowledges a fence and poisons admission" {
    for (0..3) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var backend = TestBackend{ .fail_flush = failure == 0 };
        try Gate.createLedger(std.testing.io, tmp.dir, "ranges");
        var gate = try Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "ranges", backend.backend());
        defer gate.deinit();
        var faults = durable.FileStore.Faults{};
        if (failure == 1) faults.fail_replace_once_at_record_count = 1;
        if (failure == 2) faults.fail_directory_sync_once_at_record_count = 1;
        gate.ledger.faults = &faults;
        const token = testToken();
        const expected: anyerror = switch (failure) {
            0 => error.InjectedFlushFailure,
            1 => error.InjectedReplaceFailure,
            else => error.InjectedDirectorySyncFailure,
        };
        try std.testing.expectError(expected, gate.fence(.{ .token = token, .revision = 11 }));
        try std.testing.expectError(error.FenceGateFailed, gate.begin(token, token.volume_id, 0, 4096, .read));
    }
}

test "lost or corrupt range history fails closed and uncertain rename is repaired on recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: TestBackend = .{};
    try Gate.createLedger(std.testing.io, tmp.dir, "ranges");
    const barrier = Barrier{ .token = testToken(), .revision = 11 };
    {
        var gate = try Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "ranges", backend.backend());
        defer gate.deinit();
        var faults = durable.FileStore.Faults{ .fail_directory_sync_once_at_record_count = 1 };
        gate.ledger.faults = &faults;
        try std.testing.expectError(error.InjectedDirectorySyncFailure, gate.fence(barrier));
    }
    {
        var recovered = try Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "ranges", backend.backend());
        defer recovered.deinit();
        try std.testing.expectEqualDeep(barrier, try recovered.fence(barrier));
        try std.testing.expectEqual(@as(usize, 1), backend.flushes);
        try std.testing.expectError(error.RangeLeaseFenced, recovered.begin(barrier.token, barrier.token.volume_id, 0, 4096, .read));
    }
    const file = try tmp.dir.openFile(std.testing.io, "ranges", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "broken", 0);
    try std.testing.expectError(error.StoreCorrupt, Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "ranges", backend.backend()));
    try tmp.dir.deleteFile(std.testing.io, "ranges");
    try std.testing.expectError(error.FileNotFound, Gate.open(std.testing.allocator, std.testing.io, tmp.dir, "ranges", backend.backend()));
}
