const std = @import("std");
const google_crc32c = @import("crc32c");

pub const EndpointId = [16]u8;
pub const PoolId = [16]u8;
pub const VolumeId = [16]u8;
pub const max_endpoint_count = 1024;
pub const max_locator_component_len = 256;

pub const Frontend = enum(u8) {
    vhost_user_blk = 1,
    iscsi = 2,
    nvme_of_tcp = 3,
    nvme_of_rdma = 4,
};

pub const Spec = struct {
    endpoint_id: EndpointId,
    pool_id: PoolId,
    volume_id: VolumeId,
    frontend: Frontend,
};

pub const NvmeOfLocator = struct {
    traddr: []const u8,
    trsvcid: []const u8,
    nqn: []const u8,
    nsid: u32,
};

pub const Locator = union(Frontend) {
    vhost_user_blk: struct {
        socket_path: []const u8,
    },
    iscsi: struct {
        portal: []const u8,
        target_name: []const u8,
        lun: u64,
    },
    nvme_of_tcp: NvmeOfLocator,
    nvme_of_rdma: NvmeOfLocator,
};

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
        /// Borrowed locator strings remain valid until stop succeeds.
        locator: Locator,
    };

    pub const VTable = struct {
        /// Runtime resources are process-owned. On error, start must leave no
        /// resources behind. A successful locator tag must match Spec.frontend,
        /// its strings must be non-empty valid UTF-8 within the component limit,
        /// and the instance lives until stop succeeds.
        start: *const fn (*anyopaque, Spec) anyerror!Instance,
        stop: *const fn (*anyopaque, *anyopaque) anyerror!void,
    };

    pub fn start(self: Backend, spec: Spec) !Instance {
        return self.vtable.start(self.context, spec);
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

/// Borrowed registry state. Locator strings are valid while state is active.
pub const View = struct {
    spec: Spec,
    state: State,
    locator: ?Locator,
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
        const runtime = self.backend.start(entry.spec) catch |err| {
            entry.phase = .failed;
            return err;
        };
        if (std.meta.activeTag(runtime.locator) != entry.spec.frontend) {
            self.rollbackRuntime(runtime);
            entry.phase = .failed;
            return error.FrontendMismatch;
        }
        validateLocator(runtime.locator) catch |err| {
            self.rollbackRuntime(runtime);
            entry.phase = .failed;
            return err;
        };
        entry.runtime = runtime;
        entry.phase = .active;
    }

    fn rollbackRuntime(self: *Registry, runtime: Backend.Instance) void {
        self.backend.stop(runtime.handle) catch |err|
            std.debug.panic("failed to roll back invalid endpoint runtime: {s}", .{@errorName(err)});
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
            .state = switch (entry.phase) {
                .pending => .pending,
                .active => .active,
                .failed, .stopping => .failed,
            },
            .locator = if (entry.phase == .active) entry.runtime.?.locator else null,
        };
    }
};

pub const FileStore = struct {
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,

    const magic = "ZETENDP1".*;
    const version: u16 = 2;
    const header_size = 20;
    const legacy_record_size = 48;
    const record_size = 52;
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
            record[48] = @backingInt(spec.frontend);
        }
        std.mem.writeInt(u32, bytes[16..20], google_crc32c.value(bytes[header_size..]), .little);
        return bytes;
    }

    fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Spec {
        if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..8], &magic))
            return error.InvalidDesiredState;
        const encoded_version = std.mem.readInt(u16, bytes[8..10], .little);
        const encoded_record_size = std.mem.readInt(u16, bytes[10..12], .little);
        const actual_record_size: usize = switch (encoded_version) {
            1 => if (encoded_record_size == legacy_record_size)
                legacy_record_size
            else
                return error.InvalidDesiredState,
            version => if (encoded_record_size == record_size) record_size else return error.InvalidDesiredState,
            else => return error.InvalidDesiredState,
        };
        const count = std.mem.readInt(u32, bytes[12..16], .little);
        if (count > max_endpoint_count or bytes.len != header_size + @as(usize, count) * actual_record_size)
            return error.InvalidDesiredState;
        if (std.mem.readInt(u32, bytes[16..20], .little) != google_crc32c.value(bytes[header_size..]))
            return error.InvalidDesiredState;

        const specs = try allocator.alloc(Spec, count);
        errdefer allocator.free(specs);
        for (specs, 0..) |*spec, index| {
            const record = bytes[header_size + index * actual_record_size ..][0..actual_record_size];
            const frontend: Frontend = if (encoded_version == 1)
                .vhost_user_blk
            else blk: {
                if (!isZero(record[49..52])) return error.InvalidDesiredState;
                break :blk std.enums.fromInt(Frontend, record[48]) orelse
                    return error.InvalidDesiredState;
            };
            spec.* = .{
                .endpoint_id = record[0..16].*,
                .pool_id = record[16..32].*,
                .volume_id = record[32..48].*,
                .frontend = frontend,
            };
        }
        return specs;
    }
};

fn validateSpec(spec: Spec) !void {
    if (isZero(&spec.endpoint_id) or isZero(&spec.pool_id) or isZero(&spec.volume_id))
        return error.InvalidEndpointSpec;
}

fn validateLocator(locator: Locator) !void {
    switch (locator) {
        .vhost_user_blk => |vhost| try validateLocatorString(vhost.socket_path),
        .iscsi => |iscsi| {
            try validateLocatorString(iscsi.portal);
            try validateLocatorString(iscsi.target_name);
        },
        .nvme_of_tcp, .nvme_of_rdma => |nvme| {
            try validateLocatorString(nvme.traddr);
            try validateLocatorString(nvme.trsvcid);
            try validateLocatorString(nvme.nqn);
            if (nvme.nsid == 0) return error.InvalidLocator;
        },
    }
}

fn validateLocatorString(value: []const u8) !void {
    if (value.len == 0 or value.len > max_locator_component_len or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidLocator;
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
    mismatch_frontend: bool = false,
    invalid_locator: bool = false,

    const Slot = struct {
        active: bool = false,
        socket_path: [64]u8 = @splat(0),
        socket_path_len: usize = 0,
    };

    fn backend(self: *FakeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn start(context: *anyopaque, spec: Spec) !Backend.Instance {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_start) return error.StartFailed;
        for (&self.slots) |*slot| {
            if (slot.active) continue;
            slot.active = true;
            const path = try std.fmt.bufPrint(&slot.socket_path, "/run/zettide/{x}", .{spec.endpoint_id});
            slot.socket_path_len = path.len;
            self.starts += 1;
            const locator_frontend: Frontend = if (self.mismatch_frontend) switch (spec.frontend) {
                .vhost_user_blk => .iscsi,
                .iscsi => .vhost_user_blk,
                .nvme_of_tcp => .vhost_user_blk,
                .nvme_of_rdma => .vhost_user_blk,
            } else spec.frontend;
            const locator: Locator = switch (locator_frontend) {
                .vhost_user_blk => .{ .vhost_user_blk = .{
                    .socket_path = if (self.invalid_locator) "" else slot.socket_path[0..slot.socket_path_len],
                } },
                .iscsi => .{ .iscsi = .{
                    .portal = "127.0.0.1:3260",
                    .target_name = "iqn.2026-08.io.zettide:test",
                    .lun = 0,
                } },
                .nvme_of_tcp => .{ .nvme_of_tcp = .{
                    .traddr = "127.0.0.1",
                    .trsvcid = "4420",
                    .nqn = "nqn.2026-08.io.zettide:test",
                    .nsid = 1,
                } },
                .nvme_of_rdma => .{ .nvme_of_rdma = .{
                    .traddr = "192.0.2.2",
                    .trsvcid = "4420",
                    .nqn = "nqn.2026-08.io.zettide:test",
                    .nsid = 1,
                } },
            };
            return .{ .handle = slot, .locator = locator };
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
        .frontend = .vhost_user_blk,
    };
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
    try std.testing.expectEqualStrings(
        created.locator.?.vhost_user_blk.socket_path,
        listed[0].locator.?.vhost_user_blk.socket_path,
    );

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

test "registry returns a typed iSCSI locator" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }

    var spec = testSpec(1, 2, 3);
    spec.frontend = .iscsi;
    const view = try registry.ensure(spec);
    try std.testing.expectEqual(Frontend.iscsi, std.meta.activeTag(view.locator.?));
    try std.testing.expectEqualStrings("127.0.0.1:3260", view.locator.?.iscsi.portal);
    try std.testing.expectEqual(@as(u64, 0), view.locator.?.iscsi.lun);
}

test "registry returns a typed NVMe over TCP locator" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }

    var spec = testSpec(1, 2, 3);
    spec.frontend = .nvme_of_tcp;
    const view = try registry.ensure(spec);
    try std.testing.expectEqual(Frontend.nvme_of_tcp, std.meta.activeTag(view.locator.?));
    try std.testing.expectEqualStrings("127.0.0.1", view.locator.?.nvme_of_tcp.traddr);
    try std.testing.expectEqualStrings("4420", view.locator.?.nvme_of_tcp.trsvcid);
    try std.testing.expectEqualStrings("nqn.2026-08.io.zettide:test", view.locator.?.nvme_of_tcp.nqn);
    try std.testing.expectEqual(@as(u32, 1), view.locator.?.nvme_of_tcp.nsid);
}

test "registry returns a typed NVMe over RDMA locator" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }

    var spec = testSpec(1, 2, 3);
    spec.frontend = .nvme_of_rdma;
    const view = try registry.ensure(spec);
    try std.testing.expectEqual(Frontend.nvme_of_rdma, std.meta.activeTag(view.locator.?));
    try std.testing.expectEqualStrings("192.0.2.2", view.locator.?.nvme_of_rdma.traddr);
    try std.testing.expectEqualStrings("4420", view.locator.?.nvme_of_rdma.trsvcid);
    try std.testing.expectEqualStrings("nqn.2026-08.io.zettide:test", view.locator.?.nvme_of_rdma.nqn);
    try std.testing.expectEqual(@as(u32, 1), view.locator.?.nvme_of_rdma.nsid);
}

test "registry rolls back a mismatched backend locator" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{ .mismatch_frontend = true };
    var registry = try Registry.init(std.testing.allocator, store.desiredStore(), backend.backend());
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }

    const spec = testSpec(1, 2, 3);
    try std.testing.expectError(error.FrontendMismatch, registry.ensure(spec));
    try std.testing.expectEqual(@as(usize, 1), backend.starts);
    try std.testing.expectEqual(@as(usize, 1), backend.stops);
    try std.testing.expectEqual(State.failed, (try registry.inspect(spec.endpoint_id)).state);

    backend.mismatch_frontend = false;
    backend.invalid_locator = true;
    try std.testing.expectError(error.InvalidLocator, registry.ensure(spec));
    try std.testing.expectEqual(@as(usize, 2), backend.stops);
    backend.invalid_locator = false;
    try std.testing.expectEqual(State.active, (try registry.ensure(spec)).state);
}

test "registry rejects oversized and invalid UTF-8 locators" {
    var oversized: [max_locator_component_len + 1]u8 = @splat('a');
    try std.testing.expectError(
        error.InvalidLocator,
        validateLocator(.{ .vhost_user_blk = .{ .socket_path = &oversized } }),
    );
    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(
        error.InvalidLocator,
        validateLocator(.{ .iscsi = .{
            .portal = &invalid_utf8,
            .target_name = "iqn.2026-08.io.zettide:test",
            .lun = 0,
        } }),
    );
    try std.testing.expectError(
        error.InvalidLocator,
        validateLocator(.{ .nvme_of_tcp = .{
            .traddr = "127.0.0.1",
            .trsvcid = "4420",
            .nqn = "nqn.2026-08.io.zettide:test",
            .nsid = 0,
        } }),
    );
    try std.testing.expectError(
        error.InvalidLocator,
        validateLocator(.{ .nvme_of_tcp = .{
            .traddr = "",
            .trsvcid = "4420",
            .nqn = "nqn.2026-08.io.zettide:test",
            .nsid = 1,
        } }),
    );
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
    var iscsi_spec = testSpec(4, 5, 6);
    iscsi_spec.frontend = .iscsi;
    var nvme_spec = testSpec(7, 8, 9);
    nvme_spec.frontend = .nvme_of_tcp;
    var rdma_spec = testSpec(10, 11, 12);
    rdma_spec.frontend = .nvme_of_rdma;
    const specs = [_]Spec{ testSpec(1, 2, 3), iscsi_spec, nvme_spec, rdma_spec };

    try desired_store.replace(&specs);
    const loaded = try desired_store.load(std.testing.allocator);
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualSlices(Spec, &specs, loaded);
    try std.testing.expectEqual(@as(u8, 3), @backingInt(Frontend.nvme_of_tcp));
    try std.testing.expectEqual(@as(u8, 4), @backingInt(Frontend.nvme_of_rdma));

    const file = try tmp.dir.openFile(std.testing.io, "endpoints.state", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "X", FileStore.header_size);
    try std.testing.expectError(error.InvalidDesiredState, desired_store.load(std.testing.allocator));
}

test "file store reads v1 state as vhost and rejects unknown frontend" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file_store = FileStore.init(std.testing.io, tmp.dir, "endpoints.state");
    const desired_store = file_store.desiredStore();
    const spec = testSpec(1, 2, 3);

    var v1_bytes: [FileStore.header_size + FileStore.legacy_record_size]u8 = @splat(0);
    @memcpy(v1_bytes[0..FileStore.magic.len], &FileStore.magic);
    std.mem.writeInt(u16, v1_bytes[8..10], 1, .little);
    std.mem.writeInt(u16, v1_bytes[10..12], FileStore.legacy_record_size, .little);
    std.mem.writeInt(u32, v1_bytes[12..16], 1, .little);
    @memcpy(v1_bytes[20..36], &spec.endpoint_id);
    @memcpy(v1_bytes[36..52], &spec.pool_id);
    @memcpy(v1_bytes[52..68], &spec.volume_id);
    std.mem.writeInt(u32, v1_bytes[16..20], google_crc32c.value(v1_bytes[20..]), .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "endpoints.state", .data = &v1_bytes });

    const migrated = try desired_store.load(std.testing.allocator);
    defer std.testing.allocator.free(migrated);
    try std.testing.expectEqual(@as(usize, 1), migrated.len);
    try std.testing.expectEqual(Frontend.vhost_user_blk, migrated[0].frontend);
    try desired_store.replace(migrated);

    const bytes = try tmp.dir.readFileAlloc(
        std.testing.io,
        "endpoints.state",
        std.testing.allocator,
        .limited(FileStore.max_state_bytes),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(FileStore.version, std.mem.readInt(u16, bytes[8..10], .little));
    bytes[FileStore.header_size + 48] = 99;
    std.mem.writeInt(u32, bytes[16..20], google_crc32c.value(bytes[FileStore.header_size..]), .little);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "endpoints.state", .data = bytes });
    try std.testing.expectError(error.InvalidDesiredState, desired_store.load(std.testing.allocator));
}
