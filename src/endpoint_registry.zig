const std = @import("std");

pub const EndpointId = [16]u8;
pub const PoolId = [16]u8;
pub const VolumeId = [16]u8;
pub const name_length = 36;
pub const max_endpoint_count = 1024;

pub const Spec = struct {
    endpoint_id: EndpointId,
    pool_id: PoolId,
    volume_id: VolumeId,
};

pub const Names = struct {
    bdev: [name_length]u8,
    controller: [name_length]u8,

    pub fn bdevSlice(self: *const Names) []const u8 {
        return &self.bdev;
    }

    pub fn controllerSlice(self: *const Names) []const u8 {
        return &self.controller;
    }
};

pub fn namesFor(endpoint_id: EndpointId) Names {
    var result: Names = undefined;
    _ = std.fmt.bufPrint(&result.bdev, "zvb-{x}", .{endpoint_id}) catch unreachable;
    _ = std.fmt.bufPrint(&result.controller, "zvh-{x}", .{endpoint_id}) catch unreachable;
    return result;
}

pub const DesiredStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, std.mem.Allocator) anyerror![]Spec,
        replace: *const fn (*anyopaque, []const Spec) anyerror!void,
    };

    pub fn load(self: DesiredStore, allocator: std.mem.Allocator) ![]Spec {
        return self.vtable.load(self.context, allocator);
    }

    pub fn replace(self: DesiredStore, specs: []const Spec) !void {
        return self.vtable.replace(self.context, specs);
    }
};

pub const Backend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Instance = struct {
        handle: *anyopaque,
        /// This path remains valid until stop succeeds.
        socket_path: []const u8,
    };

    pub const VTable = struct {
        /// Runtime resources are process-owned. On error, start must leave no
        /// resources behind; a successful instance lives until stop succeeds.
        start: *const fn (*anyopaque, Spec, Names) anyerror!Instance,
        stop: *const fn (*anyopaque, *anyopaque) anyerror!void,
    };

    pub fn start(self: Backend, spec: Spec, names: Names) !Instance {
        return self.vtable.start(self.context, spec, names);
    }

    pub fn stop(self: Backend, handle: *anyopaque) !void {
        return self.vtable.stop(self.context, handle);
    }
};

pub const State = enum {
    pending,
    active,
    failed,
};

/// Borrowed registry state. socket_path is valid until the endpoint is stopped.
pub const View = struct {
    spec: Spec,
    names: Names,
    state: State,
    socket_path: ?[]const u8,
};

pub const ReconcileResult = struct {
    started: usize = 0,
    failed: usize = 0,
};

/// A single owner must serialize calls to Registry. This is the state machine
/// intended to sit behind the daemon's request actor.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    store: DesiredStore,
    backend: Backend,
    entries: std.ArrayList(Entry) = .empty,

    const Phase = enum { pending, active, failed, stopping };

    const Entry = struct {
        spec: Spec,
        desired: bool = true,
        phase: Phase = .pending,
        runtime: ?Backend.Instance = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        store: DesiredStore,
        backend: Backend,
    ) !Registry {
        const specs = try store.load(allocator);
        defer allocator.free(specs);
        if (specs.len > max_endpoint_count) return error.InvalidDesiredState;

        var result: Registry = .{
            .allocator = allocator,
            .store = store,
            .backend = backend,
        };
        errdefer result.entries.deinit(allocator);
        try result.entries.ensureTotalCapacity(allocator, specs.len);
        for (specs, 0..) |spec, index| {
            validateSpec(spec) catch return error.InvalidDesiredState;
            for (specs[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.endpoint_id, &spec.endpoint_id) or
                    std.mem.eql(u8, &previous.pool_id, &spec.pool_id))
                    return error.InvalidDesiredState;
            }
            result.entries.appendAssumeCapacity(.{ .spec = spec });
        }
        return result;
    }

    /// All runtime instances must be stopped before deinit. Desired state is
    /// deliberately not removed by shutdown or deinit.
    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |entry| std.debug.assert(entry.runtime == null);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensure(self: *Registry, spec: Spec) !View {
        try validateSpec(spec);
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.spec.endpoint_id, &spec.endpoint_id)) {
                if (!entry.desired) return error.EndpointStopping;
                if (!std.meta.eql(entry.spec, spec)) return error.EndpointConflict;
                if (entry.runtime == null) try self.startEntry(entry);
                return viewOf(entry);
            }
            if ((entry.desired or entry.runtime != null) and
                std.mem.eql(u8, &entry.spec.pool_id, &spec.pool_id))
                return error.PoolBusy;
        }
        if (self.desiredCount() == max_endpoint_count) return error.TooManyEndpoints;

        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        var desired = try self.allocator.alloc(Spec, self.desiredCount() + 1);
        defer self.allocator.free(desired);
        const count = self.copyDesired(desired);
        desired[count] = spec;
        try self.store.replace(desired);

        self.entries.appendAssumeCapacity(.{ .spec = spec });
        const entry = &self.entries.items[self.entries.items.len - 1];
        try self.startEntry(entry);
        return viewOf(entry);
    }

    pub fn inspect(self: *const Registry, endpoint_id: EndpointId) !View {
        for (self.entries.items) |*entry| {
            if (entry.desired and std.mem.eql(u8, &entry.spec.endpoint_id, &endpoint_id))
                return viewOf(entry);
        }
        return error.EndpointNotFound;
    }

    pub fn list(self: *const Registry, allocator: std.mem.Allocator) ![]View {
        const result = try allocator.alloc(View, self.desiredCount());
        var index: usize = 0;
        for (self.entries.items) |*entry| {
            if (!entry.desired) continue;
            result[index] = viewOf(entry);
            index += 1;
        }
        return result;
    }

    pub fn release(self: *Registry, endpoint_id: EndpointId) !void {
        var index: usize = 0;
        while (index < self.entries.items.len) : (index += 1) {
            const entry = &self.entries.items[index];
            if (!std.mem.eql(u8, &entry.spec.endpoint_id, &endpoint_id)) continue;

            if (entry.desired) {
                var desired = try self.allocator.alloc(Spec, self.desiredCount() - 1);
                defer self.allocator.free(desired);
                var output: usize = 0;
                for (self.entries.items, 0..) |candidate, candidate_index| {
                    if (!candidate.desired or candidate_index == index) continue;
                    desired[output] = candidate.spec;
                    output += 1;
                }
                try self.store.replace(desired);
                entry.desired = false;
                entry.phase = .stopping;
            }

            if (entry.runtime) |runtime| {
                self.backend.stop(runtime.handle) catch |err| {
                    entry.phase = .stopping;
                    return err;
                };
                entry.runtime = null;
            }
            _ = self.entries.orderedRemove(index);
            return;
        }
    }

    pub fn reconcile(self: *Registry) ReconcileResult {
        var result: ReconcileResult = .{};
        for (self.entries.items) |*entry| {
            if (!entry.desired or entry.runtime != null) continue;
            self.startEntry(entry) catch {
                result.failed += 1;
                continue;
            };
            result.started += 1;
        }
        return result;
    }

    /// Stops runtime resources while preserving every desired endpoint for the
    /// next process startup and reconciliation.
    pub fn shutdown(self: *Registry) !void {
        var first_error: ?anyerror = null;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = &self.entries.items[index];
            if (entry.runtime) |runtime| {
                self.backend.stop(runtime.handle) catch |err| {
                    if (first_error == null) first_error = err;
                    entry.phase = if (entry.desired) .failed else .stopping;
                    index += 1;
                    continue;
                };
                entry.runtime = null;
            }
            if (!entry.desired) {
                _ = self.entries.orderedRemove(index);
                continue;
            }
            entry.phase = .pending;
            index += 1;
        }
        if (first_error) |err| return err;
    }

    fn startEntry(self: *Registry, entry: *Entry) !void {
        entry.phase = .pending;
        const runtime = self.backend.start(entry.spec, namesFor(entry.spec.endpoint_id)) catch |err| {
            entry.phase = .failed;
            return err;
        };
        entry.runtime = runtime;
        entry.phase = .active;
    }

    fn desiredCount(self: *const Registry) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| count += @intFromBool(entry.desired);
        return count;
    }

    fn copyDesired(self: *const Registry, output: []Spec) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (!entry.desired) continue;
            output[count] = entry.spec;
            count += 1;
        }
        return count;
    }

    fn viewOf(entry: *const Entry) View {
        return .{
            .spec = entry.spec,
            .names = namesFor(entry.spec.endpoint_id),
            .state = switch (entry.phase) {
                .pending => .pending,
                .active => .active,
                .failed, .stopping => .failed,
            },
            .socket_path = if (entry.phase == .active) entry.runtime.?.socket_path else null,
        };
    }
};

pub const FileStore = struct {
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,

    const magic = "ZETENDP1".*;
    const version: u16 = 1;
    const header_size = 20;
    const record_size = 48;
    const max_state_bytes = header_size + max_endpoint_count * record_size;

    pub fn init(io: std.Io, parent: std.Io.Dir, basename: []const u8) FileStore {
        return .{ .io = io, .parent = parent, .basename = basename };
    }

    pub fn desiredStore(self: *FileStore) DesiredStore {
        return .{ .context = self, .vtable = &vtable };
    }

    fn loadOpaque(context: *anyopaque, allocator: std.mem.Allocator) ![]Spec {
        const self: *FileStore = @ptrCast(@alignCast(context));
        const bytes = self.parent.readFileAlloc(
            self.io,
            self.basename,
            allocator,
            .limited(max_state_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(Spec, 0),
            else => return err,
        };
        defer allocator.free(bytes);
        return decode(allocator, bytes);
    }

    fn replaceOpaque(context: *anyopaque, specs: []const Spec) !void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        const bytes = try encode(std.heap.page_allocator, specs);
        defer std.heap.page_allocator.free(bytes);

        var atomic_file = try self.parent.createFileAtomic(self.io, self.basename, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        try atomic_file.file.writeStreamingAll(self.io, bytes);
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
        const parent_file = try self.parent.openFile(self.io, ".", .{ .mode = .read_only });
        defer parent_file.close(self.io);
        try parent_file.sync(self.io);
    }

    const vtable: DesiredStore.VTable = .{
        .load = loadOpaque,
        .replace = replaceOpaque,
    };

    fn encode(allocator: std.mem.Allocator, specs: []const Spec) ![]u8 {
        if (specs.len > max_endpoint_count) return error.TooManyEndpoints;
        const bytes = try allocator.alloc(u8, header_size + specs.len * record_size);
        @memset(bytes, 0);
        @memcpy(bytes[0..magic.len], &magic);
        std.mem.writeInt(u16, bytes[8..10], version, .little);
        std.mem.writeInt(u16, bytes[10..12], record_size, .little);
        std.mem.writeInt(u32, bytes[12..16], @intCast(specs.len), .little);
        for (specs, 0..) |spec, index| {
            const record = bytes[header_size + index * record_size ..][0..record_size];
            @memcpy(record[0..16], &spec.endpoint_id);
            @memcpy(record[16..32], &spec.pool_id);
            @memcpy(record[32..48], &spec.volume_id);
        }
        std.mem.writeInt(u32, bytes[16..20], std.hash.crc.Crc32Iscsi.hash(bytes[header_size..]), .little);
        return bytes;
    }

    fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Spec {
        if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..8], &magic))
            return error.InvalidDesiredState;
        if (std.mem.readInt(u16, bytes[8..10], .little) != version or
            std.mem.readInt(u16, bytes[10..12], .little) != record_size)
            return error.InvalidDesiredState;
        const count = std.mem.readInt(u32, bytes[12..16], .little);
        if (count > max_endpoint_count or bytes.len != header_size + @as(usize, count) * record_size)
            return error.InvalidDesiredState;
        if (std.mem.readInt(u32, bytes[16..20], .little) != std.hash.crc.Crc32Iscsi.hash(bytes[header_size..]))
            return error.InvalidDesiredState;

        const specs = try allocator.alloc(Spec, count);
        for (specs, 0..) |*spec, index| {
            const record = bytes[header_size + index * record_size ..][0..record_size];
            spec.* = .{
                .endpoint_id = record[0..16].*,
                .pool_id = record[16..32].*,
                .volume_id = record[32..48].*,
            };
        }
        return specs;
    }
};

fn validateSpec(spec: Spec) !void {
    if (isZero(&spec.endpoint_id) or isZero(&spec.pool_id) or isZero(&spec.volume_id))
        return error.InvalidEndpointSpec;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const MemoryStore = struct {
    allocator: std.mem.Allocator,
    specs: []Spec,
    fail_replace: bool = false,

    fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{ .allocator = allocator, .specs = &.{} };
    }

    fn deinit(self: *MemoryStore) void {
        if (self.specs.len != 0) self.allocator.free(self.specs);
    }

    fn desiredStore(self: *MemoryStore) DesiredStore {
        return .{ .context = self, .vtable = &vtable };
    }

    fn load(context: *anyopaque, allocator: std.mem.Allocator) ![]Spec {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return allocator.dupe(Spec, self.specs);
    }

    fn replace(context: *anyopaque, specs: []const Spec) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        if (self.fail_replace) return error.StoreUnavailable;
        const replacement = try self.allocator.dupe(Spec, specs);
        if (self.specs.len != 0) self.allocator.free(self.specs);
        self.specs = replacement;
    }

    const vtable: DesiredStore.VTable = .{ .load = load, .replace = replace };
};

const FakeBackend = struct {
    slots: [8]Slot = @splat(.{}),
    starts: usize = 0,
    stops: usize = 0,
    fail_start: bool = false,
    fail_stop: bool = false,

    const Slot = struct {
        active: bool = false,
        socket_path: [64]u8 = @splat(0),
        socket_path_len: usize = 0,
    };

    fn backend(self: *FakeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn start(context: *anyopaque, spec: Spec, names: Names) !Backend.Instance {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_start) return error.StartFailed;
        for (&self.slots) |*slot| {
            if (slot.active) continue;
            slot.active = true;
            const path = try std.fmt.bufPrint(&slot.socket_path, "/run/zettide/{s}", .{names.controllerSlice()});
            slot.socket_path_len = path.len;
            self.starts += 1;
            _ = spec;
            return .{ .handle = slot, .socket_path = slot.socket_path[0..slot.socket_path_len] };
        }
        return error.NoBackendSlots;
    }

    fn stop(context: *anyopaque, handle: *anyopaque) !void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_stop) return error.StopFailed;
        const slot: *Slot = @ptrCast(@alignCast(handle));
        std.debug.assert(slot.active);
        slot.active = false;
        self.stops += 1;
    }

    const vtable: Backend.VTable = .{ .start = start, .stop = stop };
};

fn testId(value: u8) [16]u8 {
    var result: [16]u8 = @splat(0);
    result[15] = value;
    return result;
}

fn testSpec(endpoint: u8, pool: u8, volume: u8) Spec {
    return .{
        .endpoint_id = testId(endpoint),
        .pool_id = testId(pool),
        .volume_id = testId(volume),
    };
}

test "stable endpoint names use the endpoint id" {
    const names = namesFor(testId(0xab));
    try std.testing.expectEqualStrings("zvb-000000000000000000000000000000ab", names.bdevSlice());
    try std.testing.expectEqualStrings("zvh-000000000000000000000000000000ab", names.controllerSlice());
}

test "ensure is durable idempotent and limited to one endpoint per pool" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }

    const spec = testSpec(1, 2, 3);
    const created = try registry.ensure(spec);
    try std.testing.expectEqual(State.active, created.state);
    try std.testing.expectEqual(@as(usize, 1), store.specs.len);
    try std.testing.expectEqual(@as(usize, 1), backend.starts);
    const listed = try registry.list(std.testing.allocator);
    defer std.testing.allocator.free(listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expect(std.meta.eql(spec, listed[0].spec));
    try std.testing.expectEqualStrings(created.socket_path.?, listed[0].socket_path.?);

    _ = try registry.ensure(spec);
    try std.testing.expectEqual(@as(usize, 1), backend.starts);
    try std.testing.expectError(error.EndpointConflict, registry.ensure(testSpec(1, 2, 4)));
    try std.testing.expectError(error.PoolBusy, registry.ensure(testSpec(5, 2, 6)));
}

test "ensure persists before start and retains failed desired state" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{ .fail_start = true };
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }

    const spec = testSpec(1, 2, 3);
    try std.testing.expectError(error.StartFailed, registry.ensure(spec));
    try std.testing.expectEqual(@as(usize, 1), store.specs.len);
    try std.testing.expectEqual(State.failed, (try registry.inspect(spec.endpoint_id)).state);

    backend.fail_start = false;
    try std.testing.expectEqual(State.active, (try registry.ensure(spec)).state);
}

test "store failure prevents start and release persists before stop" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        store.fail_replace = false;
        registry.shutdown() catch unreachable;
        registry.deinit();
    }

    const spec = testSpec(1, 2, 3);
    store.fail_replace = true;
    try std.testing.expectError(error.StoreUnavailable, registry.ensure(spec));
    try std.testing.expectEqual(@as(usize, 0), backend.starts);
    try std.testing.expectError(error.EndpointNotFound, registry.inspect(spec.endpoint_id));

    store.fail_replace = false;
    _ = try registry.ensure(spec);
    store.fail_replace = true;
    try std.testing.expectError(error.StoreUnavailable, registry.release(spec.endpoint_id));
    try std.testing.expectEqual(@as(usize, 0), backend.stops);
    try std.testing.expectEqual(State.active, (try registry.inspect(spec.endpoint_id)).state);

    store.fail_replace = false;
    try registry.release(spec.endpoint_id);
    try std.testing.expectEqual(@as(usize, 1), backend.stops);
    try std.testing.expectError(error.EndpointNotFound, registry.inspect(spec.endpoint_id));
    try registry.release(spec.endpoint_id);
}

test "release retries a failed runtime stop without restoring desire" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        backend.fail_stop = false;
        registry.shutdown() catch unreachable;
        registry.deinit();
    }

    const spec = testSpec(1, 2, 3);
    _ = try registry.ensure(spec);
    backend.fail_stop = true;
    try std.testing.expectError(error.StopFailed, registry.release(spec.endpoint_id));
    try std.testing.expectEqual(@as(usize, 0), store.specs.len);
    try std.testing.expectError(error.EndpointNotFound, registry.inspect(spec.endpoint_id));
    try std.testing.expectError(error.EndpointStopping, registry.ensure(spec));
    try std.testing.expectError(error.PoolBusy, registry.ensure(testSpec(4, 2, 5)));

    backend.fail_stop = false;
    try registry.release(spec.endpoint_id);
    try std.testing.expectEqual(@as(usize, 1), backend.stops);
}

test "startup reconciliation recreates persisted endpoints" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const spec = testSpec(1, 2, 3);

    {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var crashed_backend: FakeBackend = .{};
        var registry = try Registry.init(arena.allocator(), store.desiredStore(), crashed_backend.backend());
        _ = try registry.ensure(spec);
        // Dropping the process skips Registry shutdown; runtime resources die
        // with that process while desired state remains in the external store.
    }
    try std.testing.expectEqual(@as(usize, 1), store.specs.len);

    var backend: FakeBackend = .{};
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }
    try std.testing.expectEqual(State.pending, (try registry.inspect(spec.endpoint_id)).state);
    const result = registry.reconcile();
    try std.testing.expectEqual(@as(usize, 1), result.started);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(State.active, (try registry.inspect(spec.endpoint_id)).state);
    try std.testing.expectEqual(@as(usize, 1), backend.starts);
}

test "registry rejects duplicate pools loaded from persistent state" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    const specs = [_]Spec{ testSpec(1, 2, 3), testSpec(4, 2, 5) };
    try store.desiredStore().replace(&specs);
    var backend: FakeBackend = .{};
    try std.testing.expectError(
        error.InvalidDesiredState,
        Registry.init(std.testing.allocator, store.desiredStore(), backend.backend()),
    );
}

test "file store atomically replaces and validates desired state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store = FileStore.init(std.testing.io, tmp.dir, "endpoints.state");
    const desired_store = file_store.desiredStore();
    const specs = [_]Spec{ testSpec(1, 2, 3), testSpec(4, 5, 6) };

    try desired_store.replace(&specs);
    const loaded = try desired_store.load(std.testing.allocator);
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualSlices(Spec, &specs, loaded);

    const file = try tmp.dir.openFile(std.testing.io, "endpoints.state", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "X", FileStore.header_size);
    try std.testing.expectError(error.InvalidDesiredState, desired_store.load(std.testing.allocator));
}
