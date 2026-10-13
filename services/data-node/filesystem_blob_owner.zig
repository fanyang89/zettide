const std = @import("std");
const storage = @import("zettide_storage");
const fence = @import("zettide_data_service_contracts").filesystem_fence;

pub const Binding = fence.Binding;
pub const Identity = fence.Identity;
pub const Recovery = fence.Recovery;
pub const Digest = fence.Digest;
const Native = storage.blob_filesystem.Filesystem;

/// Trusted control-plane adapter, not a payload-supplied callback. It must check
/// ReadIndex-backed exact PREPARING/READY bindings and the live lease window.
pub const Authorization = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque, Binding, fence.Phase, ?Digest) anyerror!void,
};

/// Local regular-file prototype only. This digest domain intentionally differs
/// from raw Pool/Member identity. Copies retaining the Blob UUID are treated as
/// one identity; a clone must never be used to bypass fencing history.
pub fn probe(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, path: []const u8) !Digest {
    var blobs = try openBlobs(allocator, io, parent, path, false);
    defer blobs.close(io) catch {};
    return physicalDigest(&blobs);
}

fn openBlobs(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, path: []const u8, writable: bool) !storage.blob_store.Store {
    var backing = try storage.v3.storage.Storage.openFile(io, parent, path, writable);
    const device = device: {
        errdefer backing.close(io) catch {};
        if ((try backing.backend.file.file.stat(io)).kind != .file) return error.NotRegularFile;
        break :device try storage.blob_device.Device.init(backing, 0, backing.capacity(), storage.blob_format.allocation_unit);
    };
    return storage.blob_store.Store.open(allocator, io, device);
}
fn physicalDigest(blobs: *const storage.blob_store.Store) !Digest {
    if (std.mem.allEqual(u8, &blobs.header.uuid, 0)) return error.InvalidBlobIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zettide/filesystem/local-blob-file/v1");
    hash.update(&blobs.header.uuid);
    var capacity: [8]u8 = undefined;
    std.mem.writeInt(u64, &capacity, blobs.header.device_size, .little);
    hash.update(&capacity);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// Explicit bootstrap, not recovery. The stable sidecar inode locks a journal
/// whose data inode is replaced atomically. Never unlink/recreate a live lock.
pub fn createJournal(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, name: []const u8) !void {
    const lock_name = try std.fmt.allocPrint(allocator, "{s}.owner", .{name});
    defer allocator.free(lock_name);
    const lock = try parent.createFile(io, lock_name, .{ .exclusive = true, .lock = .exclusive, .lock_nonblocking = true });
    defer lock.close(io);
    try lock.sync(io);
    try fence.Gate.createLedger(io, parent, name);
}

/// Stable-address owner. Stop/join all callers before deinit. All exported file
/// operations take the same fence guard; never access native/blobs/gate directly.
/// No daemon, RPC, FUSE or NFS frontend instantiates this prototype yet.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    journal_name: []u8,
    journal_lock: std.Io.File,
    blobs: ?storage.blob_store.Store,
    native: ?Native = null,
    identity: Identity,
    observed_digest: Digest,
    authorization: Authorization,
    gate: fence.Gate,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, path: []const u8, journal: []const u8, binding: Binding, holder: fence.Owner, authorization: Authorization) !*Owner {
        // Even opening the backend is reserved to a committed, non-cancellable
        // preparation. Neither CANDIDATE nor a historical READY reply suffices.
        if (!std.meta.eql(binding.owner, holder)) return error.OwnerMismatch;
        try authorization.check(authorization.context, binding, .prepare, null);
        const identity = binding.identity;
        const name = try allocator.dupe(u8, journal);
        errdefer allocator.free(name);
        const lock_name = try std.fmt.allocPrint(allocator, "{s}.owner", .{journal});
        defer allocator.free(lock_name);
        const lock = try parent.openFile(io, lock_name, .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true });
        errdefer lock.close(io);
        const self = try allocator.create(Owner);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .journal_name = name, .journal_lock = lock, .blobs = try openBlobs(allocator, io, parent, path, true), .identity = identity, .observed_digest = undefined, .authorization = authorization, .gate = undefined };
        errdefer if (self.blobs) |*blobs| blobs.close(io) catch {};
        self.observed_digest = try physicalDigest(&self.blobs.?);
        self.gate = try fence.Gate.open(allocator, io, parent, name, identity, holder, .{ .context = self, .verify_identity = verify, .authorize = authorize, .drain_flush = drain, .recover = recoverBackend });
        return self;
    }

    /// Never let teardown commit an old owner's dirty cache after lease loss or
    /// an uncertain fence. Call sync while authorized for graceful persistence.
    pub fn deinit(self: *Owner) void {
        self.gate.deinit();
        if (self.native) |*native| native.abort(self.io) catch {} else if (self.blobs) |*blobs| blobs.close(self.io) catch {};
        self.journal_lock.close(self.io);
        self.allocator.free(self.journal_name);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    pub fn prepare(self: *Owner, binding: Binding) !fence.Receipt {
        return self.gate.prepare(binding);
    }
    pub fn recover(self: *Owner, binding: Binding) !Recovery {
        return self.gate.recover(binding);
    }
    pub fn activate(self: *Owner, recovery: Recovery) !void {
        try self.gate.activate(recovery);
    }
    pub fn createFile(self: *Owner, binding: Binding, parent: u64, name: []const u8, mode: u32, uid: u32, gid: u32) !u64 {
        var guard = try self.gate.begin(binding);
        defer guard.end();
        return self.native.?.createFile(self.io, parent, name, mode, uid, gid);
    }
    pub fn statPath(self: *Owner, binding: Binding, path: []const u8) !Native.InodeRecord {
        var guard = try self.gate.begin(binding);
        defer guard.end();
        return self.native.?.statPath(self.io, path);
    }
    pub fn write(self: *Owner, binding: Binding, inode: u64, data: []const u8, offset: u64) !usize {
        var guard = try self.gate.begin(binding);
        defer guard.end();
        return self.native.?.write(self.io, inode, data, offset);
    }
    pub fn read(self: *Owner, binding: Binding, inode: u64, data: []u8, offset: u64) !usize {
        var guard = try self.gate.begin(binding);
        defer guard.end();
        return self.native.?.read(self.io, inode, data, offset);
    }
    pub fn sync(self: *Owner, binding: Binding) !void {
        var guard = try self.gate.begin(binding);
        defer guard.end();
        self.native.?.sync(self.io) catch |err| {
            guard.failClosed();
            return err;
        };
        self.native.?.blobs.device.sync(self.io) catch |err| {
            guard.failClosed();
            return err;
        };
    }
    fn verify(context: *anyopaque, identity: Identity) !void {
        const self: *Owner = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, &identity.backend_digest, &self.observed_digest)) return error.BackendIdentityMismatch;
    }
    fn authorize(context: *anyopaque, binding: Binding, phase: fence.Phase, digest: ?Digest) !void {
        const self: *Owner = @ptrCast(@alignCast(context));
        try self.authorization.check(self.authorization.context, binding, phase, digest);
    }
    fn drain(context: *anyopaque, binding: Binding) !Digest {
        const self: *Owner = @ptrCast(@alignCast(context));
        // Exclusive kernel file ownership excludes cooperating local owners;
        // synchronous guarded calls have completed before this callback runs.
        if (self.native) |*native| {
            try native.sync(self.io);
            try native.blobs.device.sync(self.io);
        } else if (self.blobs) |*blobs| try blobs.device.sync(self.io) else return error.BackendClosed;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zettide/filesystem/local-drain/v1");
        hash.update(&self.observed_digest);
        var epoch: [8]u8 = undefined;
        std.mem.writeInt(u64, &epoch, binding.epoch, .little);
        hash.update(&epoch);
        var result: Digest = undefined;
        hash.final(&result);
        return result;
    }
    fn recoverBackend(context: *anyopaque, receipt: fence.Receipt) !Digest {
        const self: *Owner = @ptrCast(@alignCast(context));
        if (self.native == null) {
            const blobs = self.blobs orelse return error.BackendClosed;
            self.blobs = null;
            self.native = try Native.openExpectedProfile(self.allocator, self.io, blobs, true, switch (self.identity.name_profile) {
                .legacy_raw => .legacy_raw,
                .portable_v1 => .portable_v1,
            });
        }
        try self.native.?.sync(self.io);
        try self.native.?.blobs.device.sync(self.io);
        const root = try storage.blob_filesystem_format.encodeRoot(self.native.?.root);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zettide/filesystem/local-recovery/v1");
        hash.update(&self.observed_digest);
        hash.update(&receipt.drain_digest);
        hash.update(&root);
        var result: Digest = undefined;
        hash.final(&result);
        return result;
    }
};

fn testId(value: u8) fence.Id {
    var id: fence.Id = @splat(value);
    id[6] = 0x70;
    id[8] = 0x80;
    return id;
}
fn formatTestFile(parent: std.Io.Dir, path: []const u8, profile: storage.name_profile.Profile, orphan: bool) !void {
    const device = try storage.blob_device.Device.createFile(std.testing.io, parent, path, 16 * 1024 * 1024, storage.blob_format.allocation_unit);
    const blobs = try storage.blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var fs = try Native.format(std.testing.allocator, std.testing.io, blobs, profile);
    defer fs.close(std.testing.io) catch {};
    if (orphan) {
        const inode = try fs.createFile(std.testing.io, 1, "orphan", 0o600, 0, 0);
        try fs.retainInode(std.testing.io, inode);
        try fs.unlink(std.testing.io, 1, "orphan");
        try fs.sync(std.testing.io);
        try std.testing.expectEqual(@as(u64, 1), fs.root.orphan_count);
    }
}
fn testBinding(digest: Digest) Binding {
    return .{ .identity = .{ .cluster_id = testId(1), .pool_id = testId(2), .filesystem_id = testId(3), .backend_digest = digest, .name_profile = .legacy_raw }, .owner = .{ .node_id = testId(4), .boot_id = testId(5) }, .placement_generation = 6, .epoch = 4 };
}
const TestAuthorization = struct {
    binding: Binding,
    ready: ?Digest = null,
    live: bool = true,
    allow_preparation: bool = true,
    fn interface(self: *TestAuthorization) Authorization {
        return .{ .context = self, .check = check };
    }
    fn check(context: *anyopaque, binding: Binding, phase: fence.Phase, digest: ?Digest) !void {
        const self: *TestAuthorization = @ptrCast(@alignCast(context));
        if (!std.meta.eql(binding, self.binding)) return error.NotAuthorized;
        switch (phase) {
            .prepare, .recover => if (self.ready != null or !self.allow_preparation) return error.NotAuthorized,
            .activate, .payload => if (!self.live or self.ready == null or digest == null or !std.mem.eql(u8, &self.ready.?, &digest.?)) return error.NotAuthorized,
        }
    }
    fn start(self: *TestAuthorization, owner: *Owner) !void {
        _ = try owner.prepare(self.binding);
        const recovered = try owner.recover(self.binding);
        self.ready = recovered.digest;
        try owner.activate(recovered);
    }
};
fn openTestOwner(parent: std.Io.Dir, authorization: *TestAuthorization) !*Owner {
    return Owner.open(std.testing.allocator, std.testing.io, parent, "blob", "journal", authorization.binding, authorization.binding.owner, authorization.interface());
}

test "local Blob owner gates real file IO and rejects simultaneous owners and stale boots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try formatTestFile(tmp.dir, "blob", .legacy_raw, false);
    const digest = try probe(std.testing.allocator, std.testing.io, tmp.dir, "blob");
    var authorization = TestAuthorization{ .binding = testBinding(digest) };
    authorization.allow_preparation = false;
    try std.testing.expectError(error.NotAuthorized, openTestOwner(tmp.dir, &authorization));
    authorization.allow_preparation = true;
    var wrong_holder = authorization.binding.owner;
    wrong_holder.boot_id = testId(20);
    try std.testing.expectError(error.OwnerMismatch, Owner.open(std.testing.allocator, std.testing.io, tmp.dir, "blob", "journal", authorization.binding, wrong_holder, authorization.interface()));
    try createJournal(std.testing.allocator, std.testing.io, tmp.dir, "journal");
    var inode: u64 = 0;
    const old = authorization.binding;
    {
        const owner = try openTestOwner(tmp.dir, &authorization);
        defer owner.deinit();
        try std.testing.expectError(error.NotPrepared, owner.createFile(old, 1, "early", 0o600, 0, 0));
        _ = try owner.prepare(old);
        try std.testing.expectError(error.NotReady, owner.statPath(old, "/"));
        try authorization.start(owner);
        var competing = TestAuthorization{ .binding = old };
        try std.testing.expectError(error.WouldBlock, openTestOwner(tmp.dir, &competing));
        try std.testing.expectError(error.WouldBlock, probe(std.testing.allocator, std.testing.io, tmp.dir, "blob"));
        try createJournal(std.testing.allocator, std.testing.io, tmp.dir, "other-journal");
        try std.testing.expectError(error.WouldBlock, Owner.open(std.testing.allocator, std.testing.io, tmp.dir, "blob", "other-journal", old, old.owner, competing.interface()));
        inode = try owner.createFile(old, 1, "file", 0o600, 0, 0);
        try std.testing.expectEqual(@as(usize, 7), try owner.write(old, inode, "durable", 0));
        try owner.sync(old);
        authorization.live = false;
        var data: [16]u8 = undefined;
        try std.testing.expectError(error.NotAuthorized, owner.read(old, inode, &data, 0));
        try std.testing.expectError(error.NotAuthorized, owner.write(old, inode, "late", 0));
    }
    // Normal file/root mutations do not change the physical identity digest.
    try std.testing.expectEqualSlices(u8, &digest, &try probe(std.testing.allocator, std.testing.io, tmp.dir, "blob"));
    authorization.binding.owner.boot_id = testId(7);
    authorization.ready = null;
    authorization.live = true;
    const owner = try openTestOwner(tmp.dir, &authorization);
    defer owner.deinit();
    try std.testing.expectError(error.OwnerMismatch, owner.prepare(old));
    try std.testing.expectError(error.BindingConflict, owner.prepare(authorization.binding));
    authorization.binding.epoch = 10;
    try authorization.start(owner);
    var data: [16]u8 = undefined;
    const n = try owner.read(authorization.binding, inode, &data, 0);
    try std.testing.expectEqualStrings("durable", data[0..n]);
    try std.testing.expectError(error.OwnerMismatch, owner.read(old, inode, &data, 0));
}

test "local Blob owner teardown cannot flush unauthorized dirty data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try formatTestFile(tmp.dir, "blob", .legacy_raw, false);
    var authorization = TestAuthorization{ .binding = testBinding(try probe(std.testing.allocator, std.testing.io, tmp.dir, "blob")) };
    try createJournal(std.testing.allocator, std.testing.io, tmp.dir, "journal");
    var inode: u64 = 0;
    {
        const owner = try openTestOwner(tmp.dir, &authorization);
        defer owner.deinit();
        try authorization.start(owner);
        inode = try owner.createFile(authorization.binding, 1, "file", 0o600, 0, 0);
        _ = try owner.write(authorization.binding, inode, "old", 0);
        try owner.sync(authorization.binding);
        _ = try owner.write(authorization.binding, inode, "new", 0);
        authorization.live = false;
        try std.testing.expectError(error.NotAuthorized, owner.sync(authorization.binding));
    }
    authorization.ready = null;
    authorization.live = true;
    authorization.binding.owner.boot_id = testId(8);
    authorization.binding.epoch += 1;
    const owner = try openTestOwner(tmp.dir, &authorization);
    defer owner.deinit();
    try authorization.start(owner);
    var data: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try owner.read(authorization.binding, inode, &data, 0));
    try std.testing.expectEqualStrings("old", &data);
}

test "local Blob recovery validates profile before orphan mutation and recovers under fence" {
    for ([_]bool{ false, true }) |matching| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try formatTestFile(tmp.dir, "blob", .portable_v1, true);
        var authorization = TestAuthorization{ .binding = testBinding(try probe(std.testing.allocator, std.testing.io, tmp.dir, "blob")) };
        if (matching) authorization.binding.identity.name_profile = .portable_v1;
        try createJournal(std.testing.allocator, std.testing.io, tmp.dir, "journal");
        const before = try tmp.dir.readFileAlloc(std.testing.io, "blob", std.testing.allocator, .limited(16 * 1024 * 1024 + 1));
        defer std.testing.allocator.free(before);
        {
            const owner = try openTestOwner(tmp.dir, &authorization);
            defer owner.deinit();
            _ = try owner.prepare(authorization.binding);
            if (matching) {
                const recovered = try owner.recover(authorization.binding);
                try std.testing.expectEqual(@as(u64, 0), owner.native.?.root.orphan_count);
                try std.testing.expectError(error.NotReady, owner.statPath(authorization.binding, "/"));
                authorization.ready = recovered.digest;
                try owner.activate(recovered);
                _ = try owner.statPath(authorization.binding, "/");
            } else {
                try std.testing.expectError(error.FilesystemProfileMismatch, owner.recover(authorization.binding));
                try std.testing.expectError(error.FilesystemGateFailed, owner.statPath(authorization.binding, "/"));
            }
        }
        if (!matching) {
            const after = try tmp.dir.readFileAlloc(std.testing.io, "blob", std.testing.allocator, .limited(16 * 1024 * 1024 + 1));
            defer std.testing.allocator.free(after);
            try std.testing.expectEqualSlices(u8, before, after);
        }
    }
}

test "local Blob owner rejects replaced media and missing journal without bootstrapping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try formatTestFile(tmp.dir, "blob", .legacy_raw, false);
    var authorization = TestAuthorization{ .binding = testBinding(try probe(std.testing.allocator, std.testing.io, tmp.dir, "blob")) };
    try std.testing.expectError(error.FileNotFound, openTestOwner(tmp.dir, &authorization));
    try createJournal(std.testing.allocator, std.testing.io, tmp.dir, "journal");
    try std.testing.expectError(error.PathAlreadyExists, createJournal(std.testing.allocator, std.testing.io, tmp.dir, "journal"));
    try formatTestFile(tmp.dir, "replacement", .legacy_raw, false);
    try std.testing.expectError(error.BackendIdentityMismatch, Owner.open(std.testing.allocator, std.testing.io, tmp.dir, "replacement", "journal", authorization.binding, authorization.binding.owner, authorization.interface()));
    // Failure released both locks; the original physical backend still opens.
    const owner = try openTestOwner(tmp.dir, &authorization);
    owner.deinit();
    try tmp.dir.deleteFile(std.testing.io, "journal");
    try std.testing.expectError(error.FileNotFound, openTestOwner(tmp.dir, &authorization));
}

test "local Blob owner allocation failures release backend and journal locks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try formatTestFile(tmp.dir, "blob", .legacy_raw, false);
    var authorization = TestAuthorization{ .binding = testBinding(try probe(std.testing.allocator, std.testing.io, tmp.dir, "blob")) };
    try createJournal(std.testing.allocator, std.testing.io, tmp.dir, "journal");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, parent: std.Io.Dir, auth: *TestAuthorization) !void {
            const owner = try Owner.open(allocator, std.testing.io, parent, "blob", "journal", auth.binding, auth.binding.owner, auth.interface());
            owner.deinit();
        }
    }.run, .{ tmp.dir, &authorization });
    const owner = try openTestOwner(tmp.dir, &authorization);
    owner.deinit();
}

test "local Blob owner failed sync poisons subsequent payload admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try formatTestFile(tmp.dir, "blob", .legacy_raw, false);
    var authorization = TestAuthorization{ .binding = testBinding(try probe(std.testing.allocator, std.testing.io, tmp.dir, "blob")) };
    try createJournal(std.testing.allocator, std.testing.io, tmp.dir, "journal");
    const owner = try openTestOwner(tmp.dir, &authorization);
    defer owner.deinit();
    try authorization.start(owner);
    // Model the engine's frozen state after an uncertain storage commit.
    owner.native.?.frozen = true;
    try std.testing.expectError(error.BlobFilesystemFrozen, owner.sync(authorization.binding));
    try std.testing.expectError(error.FilesystemGateFailed, owner.statPath(authorization.binding, "/"));
}
