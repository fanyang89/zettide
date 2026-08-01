const std = @import("std");
const catalog_vhost_export = @import("catalog_vhost_export.zig");
const endpoint_registry = @import("../endpoint_registry.zig");
const pool_member_set = @import("../v3/pool_member_set.zig");
const runtime_api = @import("runtime.zig");

pub const PoolSource = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Opened = struct {
        set: *pool_member_set.PoolMemberSet,
        /// The authenticated identity read from the opened pool.
        pool_id: endpoint_registry.PoolId,
    };

    pub const VTable = struct {
        open: *const fn (*anyopaque, endpoint_registry.PoolId) anyerror!Opened,
        /// On success, closes and invalidates set. Failure must be retryable.
        close: *const fn (*anyopaque, *pool_member_set.PoolMemberSet) anyerror!void,
        /// Fail-stop cleanup for an opened set that was never exported.
        abort: *const fn (*anyopaque, *pool_member_set.PoolMemberSet) void,
    };

    pub fn open(self: PoolSource, pool_id: endpoint_registry.PoolId) !Opened {
        return self.vtable.open(self.context, pool_id);
    }

    pub fn close(self: PoolSource, set: *pool_member_set.PoolMemberSet) !void {
        return self.vtable.close(self.context, set);
    }

    pub fn abort(self: PoolSource, set: *pool_member_set.PoolMemberSet) void {
        self.vtable.abort(self.context, set);
    }
};

pub const Options = struct {
    cpumask: ?[]const u8 = null,
    block_size: u32 = 4096,
    write_unit_blocks: u32 = 1,
    max_io_blocks: u32 = 256,
};

/// Adapts registry lifecycle operations to complete catalog vhost exports. The
/// allocator must be thread-safe. This object, allocator, io, runtime, source,
/// and option strings must remain valid until every endpoint is stopped.
pub const CatalogEndpointBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *runtime_api.Runtime,
    source: PoolSource,
    options: Options,
    driver: ExportDriver,

    const Instance = struct {
        set: *pool_member_set.PoolMemberSet,
        export_handle: ?*anyopaque,
        socket_path: [socket_path_capacity]u8,
        socket_path_len: usize,
    };

    const socket_path_capacity = 108;

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        source: PoolSource,
        options: Options,
    ) CatalogEndpointBackend {
        return initWithDriver(allocator, io, runtime, source, options, catalog_driver);
    }

    pub fn endpointBackend(self: *CatalogEndpointBackend) endpoint_registry.Backend {
        return .{ .context = self, .vtable = &backend_vtable };
    }

    fn initWithDriver(
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        source: PoolSource,
        options: Options,
        driver: ExportDriver,
    ) CatalogEndpointBackend {
        return .{
            .allocator = allocator,
            .io = io,
            .runtime = runtime,
            .source = source,
            .options = options,
            .driver = driver,
        };
    }

    fn startOpaque(
        context: *anyopaque,
        spec: endpoint_registry.Spec,
        names: endpoint_registry.Names,
    ) !endpoint_registry.Backend.Instance {
        const self: *CatalogEndpointBackend = @ptrCast(@alignCast(context));
        const instance = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(instance);

        const opened = try self.source.open(spec.pool_id);
        errdefer self.source.abort(opened.set);
        if (!std.mem.eql(u8, &opened.pool_id, &spec.pool_id)) return error.PoolIdentityMismatch;

        const export_instance = try self.driver.create(
            self.allocator,
            self.io,
            self.runtime,
            opened.set,
            spec.volume_id,
            .{
                .bdev_name = names.bdevSlice(),
                .controller_name = names.controllerSlice(),
                .cpumask = self.options.cpumask,
                .block_size = self.options.block_size,
                .write_unit_blocks = self.options.write_unit_blocks,
                .max_io_blocks = self.options.max_io_blocks,
            },
        );
        std.debug.assert(export_instance.socket_path.len <= socket_path_capacity);
        instance.* = .{
            .set = opened.set,
            .export_handle = export_instance.handle,
            .socket_path = undefined,
            .socket_path_len = export_instance.socket_path.len,
        };
        @memcpy(instance.socket_path[0..instance.socket_path_len], export_instance.socket_path);
        return .{
            .handle = instance,
            .socket_path = instance.socket_path[0..instance.socket_path_len],
        };
    }

    fn stopOpaque(context: *anyopaque, handle: *anyopaque) !void {
        const self: *CatalogEndpointBackend = @ptrCast(@alignCast(context));
        const instance: *Instance = @ptrCast(@alignCast(handle));
        if (instance.export_handle) |export_handle| {
            try self.driver.close(self.allocator, export_handle);
            instance.export_handle = null;
        }
        try self.source.close(instance.set);
        self.allocator.destroy(instance);
    }

    const backend_vtable: endpoint_registry.Backend.VTable = .{
        .start = startOpaque,
        .stop = stopOpaque,
    };
};

const ExportDriver = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    const Instance = struct {
        handle: *anyopaque,
        socket_path: []const u8,
    };

    const VTable = struct {
        create: *const fn (
            ?*anyopaque,
            std.mem.Allocator,
            std.Io,
            *runtime_api.Runtime,
            *pool_member_set.PoolMemberSet,
            endpoint_registry.VolumeId,
            catalog_vhost_export.Options,
        ) anyerror!Instance,
        close: *const fn (?*anyopaque, std.mem.Allocator, *anyopaque) anyerror!void,
    };

    fn create(
        self: ExportDriver,
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        set: *pool_member_set.PoolMemberSet,
        volume_id: endpoint_registry.VolumeId,
        options: catalog_vhost_export.Options,
    ) !Instance {
        return self.vtable.create(self.context, allocator, io, runtime, set, volume_id, options);
    }

    fn close(self: ExportDriver, allocator: std.mem.Allocator, handle: *anyopaque) !void {
        return self.vtable.close(self.context, allocator, handle);
    }
};

fn createCatalogExport(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *runtime_api.Runtime,
    set: *pool_member_set.PoolMemberSet,
    volume_id: endpoint_registry.VolumeId,
    options: catalog_vhost_export.Options,
) !ExportDriver.Instance {
    const export_handle = try allocator.create(catalog_vhost_export.CatalogVhostExport);
    errdefer allocator.destroy(export_handle);
    export_handle.* = try catalog_vhost_export.CatalogVhostExport.create(
        allocator,
        io,
        runtime,
        set,
        volume_id,
        options,
    );
    return .{ .handle = export_handle, .socket_path = export_handle.socketPath() };
}

fn closeCatalogExport(_: ?*anyopaque, allocator: std.mem.Allocator, handle: *anyopaque) !void {
    const export_handle: *catalog_vhost_export.CatalogVhostExport = @ptrCast(@alignCast(handle));
    try export_handle.close();
    allocator.destroy(export_handle);
}

const catalog_driver: ExportDriver = .{
    .context = null,
    .vtable = &.{
        .create = createCatalogExport,
        .close = closeCatalogExport,
    },
};

const Events = struct {
    values: [8]u8 = @splat(0),
    len: usize = 0,

    fn add(self: *Events, value: u8) void {
        self.values[self.len] = value;
        self.len += 1;
    }
};

const FakePoolSource = struct {
    events: *Events,
    set: pool_member_set.PoolMemberSet = .{},
    actual_pool_id: endpoint_registry.PoolId,
    opens: usize = 0,
    closes: usize = 0,
    aborts: usize = 0,
    fail_close: bool = false,

    fn poolSource(self: *FakePoolSource) PoolSource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn open(context: *anyopaque, _: endpoint_registry.PoolId) !PoolSource.Opened {
        const self: *FakePoolSource = @ptrCast(@alignCast(context));
        self.opens += 1;
        self.events.add(1);
        return .{ .set = &self.set, .pool_id = self.actual_pool_id };
    }

    fn close(context: *anyopaque, set: *pool_member_set.PoolMemberSet) !void {
        const self: *FakePoolSource = @ptrCast(@alignCast(context));
        std.debug.assert(set == &self.set);
        self.closes += 1;
        self.events.add(4);
        if (self.fail_close) return error.PoolCloseFailed;
    }

    fn abort(context: *anyopaque, set: *pool_member_set.PoolMemberSet) void {
        const self: *FakePoolSource = @ptrCast(@alignCast(context));
        std.debug.assert(set == &self.set);
        self.aborts += 1;
        self.events.add(5);
    }

    const vtable: PoolSource.VTable = .{ .open = open, .close = close, .abort = abort };
};

const FakeExportDriver = struct {
    events: *Events,
    expected_set: *pool_member_set.PoolMemberSet,
    fail_create: bool = false,
    fail_close: bool = false,
    creates: usize = 0,
    closes: usize = 0,
    socket_path: []const u8 = "/run/zettide/zvh-test",
    volume_id: endpoint_registry.VolumeId = @splat(0),
    bdev_name: [endpoint_registry.name_length]u8 = @splat(0),
    controller_name: [endpoint_registry.name_length]u8 = @splat(0),

    fn exportDriver(self: *FakeExportDriver) ExportDriver {
        return .{ .context = self, .vtable = &vtable };
    }

    fn create(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        _: std.Io,
        _: *runtime_api.Runtime,
        set: *pool_member_set.PoolMemberSet,
        volume_id: endpoint_registry.VolumeId,
        options: catalog_vhost_export.Options,
    ) !ExportDriver.Instance {
        const self: *FakeExportDriver = @ptrCast(@alignCast(context.?));
        std.debug.assert(set == self.expected_set);
        self.creates += 1;
        self.events.add(2);
        if (self.fail_create) return error.ExportCreateFailed;
        self.volume_id = volume_id;
        @memcpy(&self.bdev_name, options.bdev_name);
        @memcpy(&self.controller_name, options.controller_name);
        return .{ .handle = self, .socket_path = self.socket_path };
    }

    fn close(context: ?*anyopaque, _: std.mem.Allocator, handle: *anyopaque) !void {
        const self: *FakeExportDriver = @ptrCast(@alignCast(context.?));
        std.debug.assert(handle == @as(*anyopaque, @ptrCast(self)));
        self.closes += 1;
        self.events.add(3);
        if (self.fail_close) return error.ExportCloseFailed;
    }

    const vtable: ExportDriver.VTable = .{ .create = create, .close = close };
};

fn testId(value: u8) [16]u8 {
    var result: [16]u8 = @splat(0);
    result[15] = value;
    return result;
}

test "catalog endpoint backend composes pool and export lifetimes" {
    var events: Events = .{};
    var source: FakePoolSource = .{ .events = &events, .actual_pool_id = testId(2) };
    var driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDriver(
        std.testing.allocator,
        std.testing.io,
        &runtime,
        source.poolSource(),
        .{},
        driver.exportDriver(),
    );
    const backend = adapter.endpointBackend();
    const spec: endpoint_registry.Spec = .{
        .endpoint_id = testId(1),
        .pool_id = testId(2),
        .volume_id = testId(3),
    };
    const names = endpoint_registry.namesFor(spec.endpoint_id);

    const instance = try backend.start(spec, names);
    try std.testing.expectEqualStrings(driver.socket_path, instance.socket_path);
    try std.testing.expectEqualSlices(u8, &spec.volume_id, &driver.volume_id);
    try std.testing.expectEqualStrings(names.bdevSlice(), &driver.bdev_name);
    try std.testing.expectEqualStrings(names.controllerSlice(), &driver.controller_name);
    try backend.stop(instance.handle);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, events.values[0..events.len]);
    try std.testing.expectEqual(@as(usize, 1), source.opens);
    try std.testing.expectEqual(@as(usize, 1), source.closes);
    try std.testing.expectEqual(@as(usize, 0), source.aborts);
}

test "catalog endpoint backend rejects a mismatched pool and rolls back create failure" {
    var events: Events = .{};
    var source: FakePoolSource = .{ .events = &events, .actual_pool_id = testId(9) };
    var driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDriver(
        std.testing.allocator,
        std.testing.io,
        &runtime,
        source.poolSource(),
        .{},
        driver.exportDriver(),
    );
    const backend = adapter.endpointBackend();
    const spec: endpoint_registry.Spec = .{
        .endpoint_id = testId(1),
        .pool_id = testId(2),
        .volume_id = testId(3),
    };

    try std.testing.expectError(error.PoolIdentityMismatch, backend.start(spec, endpoint_registry.namesFor(spec.endpoint_id)));
    try std.testing.expectEqual(@as(usize, 1), source.aborts);
    try std.testing.expectEqual(@as(usize, 0), driver.creates);

    source.actual_pool_id = spec.pool_id;
    driver.fail_create = true;
    try std.testing.expectError(error.ExportCreateFailed, backend.start(spec, endpoint_registry.namesFor(spec.endpoint_id)));
    try std.testing.expectEqual(@as(usize, 2), source.aborts);
    try std.testing.expectEqual(@as(usize, 1), driver.creates);
}

test "catalog endpoint backend retries export close before releasing the pool" {
    var events: Events = .{};
    var source: FakePoolSource = .{ .events = &events, .actual_pool_id = testId(2) };
    var driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDriver(
        std.testing.allocator,
        std.testing.io,
        &runtime,
        source.poolSource(),
        .{},
        driver.exportDriver(),
    );
    const backend = adapter.endpointBackend();
    const spec: endpoint_registry.Spec = .{
        .endpoint_id = testId(1),
        .pool_id = testId(2),
        .volume_id = testId(3),
    };
    const instance = try backend.start(spec, endpoint_registry.namesFor(spec.endpoint_id));

    driver.fail_close = true;
    try std.testing.expectError(error.ExportCloseFailed, backend.stop(instance.handle));
    try std.testing.expectEqual(@as(usize, 0), source.closes);
    driver.fail_close = false;
    try backend.stop(instance.handle);
    try std.testing.expectEqual(@as(usize, 1), source.closes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 3, 4 }, events.values[0..events.len]);
}

test "catalog endpoint backend does not reclose export when pool close retries" {
    var events: Events = .{};
    var source: FakePoolSource = .{
        .events = &events,
        .actual_pool_id = testId(2),
        .fail_close = true,
    };
    var driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDriver(
        std.testing.allocator,
        std.testing.io,
        &runtime,
        source.poolSource(),
        .{},
        driver.exportDriver(),
    );
    const backend = adapter.endpointBackend();
    const spec: endpoint_registry.Spec = .{
        .endpoint_id = testId(1),
        .pool_id = testId(2),
        .volume_id = testId(3),
    };
    const instance = try backend.start(spec, endpoint_registry.namesFor(spec.endpoint_id));

    try std.testing.expectError(error.PoolCloseFailed, backend.stop(instance.handle));
    source.fail_close = false;
    try backend.stop(instance.handle);
    try std.testing.expectEqual(@as(usize, 1), driver.closes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 4 }, events.values[0..events.len]);
}
