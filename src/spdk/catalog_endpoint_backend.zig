const std = @import("std");
const catalog_vhost_export = @import("catalog_vhost_export.zig");
const endpoint_registry = @import("../endpoint_registry.zig");
const pool_member_set = @import("../v3/pool_member_set.zig");
const runtime_api = @import("runtime.zig");

pub const name_length = 36;

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

pub fn namesFor(endpoint_id: endpoint_registry.EndpointId) Names {
    var result: Names = undefined;
    _ = std.fmt.bufPrint(&result.bdev, "zvb-{x}", .{endpoint_id}) catch unreachable;
    _ = std.fmt.bufPrint(&result.controller, "zvh-{x}", .{endpoint_id}) catch unreachable;
    return result;
}

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

/// Opens pools from an immutable table of explicit member locations. The
/// allocator must be thread-safe, and configs and their locations must remain
/// valid while this source can be used.
pub const ConfiguredPoolSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    configs: []const Config,

    pub const Config = struct {
        pool_id: endpoint_registry.PoolId,
        locations: []const pool_member_set.Location,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        configs: []const Config,
    ) !ConfiguredPoolSource {
        for (configs, 0..) |config, index| {
            if (isZero(&config.pool_id)) return error.InvalidPoolId;
            if (config.locations.len == 0) return error.MissingPoolLocations;
            if (config.locations.len > pool_member_set.max_member_count)
                return error.TooManyPoolLocations;
            for (configs[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.pool_id, &config.pool_id))
                    return error.DuplicatePoolConfig;
            }
            for (config.locations, 0..) |location, location_index| {
                if (location.basename.len == 0) return error.InvalidPoolLocation;
                for (config.locations[0..location_index]) |previous| {
                    if (sameLocation(previous, location)) return error.DuplicatePoolLocation;
                }
                for (configs[0..index]) |previous_config| {
                    for (previous_config.locations) |previous| {
                        if (sameLocation(previous, location)) return error.DuplicatePoolLocation;
                    }
                }
            }
        }
        return .{ .allocator = allocator, .io = io, .configs = configs };
    }

    pub fn poolSource(self: *ConfiguredPoolSource) PoolSource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn openOpaque(context: *anyopaque, pool_id: endpoint_registry.PoolId) !PoolSource.Opened {
        const self: *ConfiguredPoolSource = @ptrCast(@alignCast(context));
        const config = for (self.configs) |candidate| {
            if (std.mem.eql(u8, &candidate.pool_id, &pool_id)) break candidate;
        } else return error.PoolNotConfigured;

        const set = try self.allocator.create(pool_member_set.PoolMemberSet);
        errdefer self.allocator.destroy(set);
        set.* = try pool_member_set.PoolMemberSet.open(
            self.io,
            self.allocator,
            config.locations,
            .writable,
        );
        errdefer set.deinit();
        const authority = set.authority() orelse return error.MissingPoolAuthority;
        return .{ .set = set, .pool_id = authority.topology.set_id };
    }

    fn closeOpaque(context: *anyopaque, set: *pool_member_set.PoolMemberSet) !void {
        const self: *ConfiguredPoolSource = @ptrCast(@alignCast(context));
        try set.close();
        self.allocator.destroy(set);
    }

    fn abortOpaque(context: *anyopaque, set: *pool_member_set.PoolMemberSet) void {
        const self: *ConfiguredPoolSource = @ptrCast(@alignCast(context));
        set.close() catch |err| {
            if (!set.isClosed())
                std.debug.panic("failed to abort opened pool: {s}", .{@errorName(err)});
        };
        self.allocator.destroy(set);
    }

    const vtable: PoolSource.VTable = .{
        .open = openOpaque,
        .close = closeOpaque,
        .abort = abortOpaque,
    };
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
    ) !endpoint_registry.Backend.Instance {
        const self: *CatalogEndpointBackend = @ptrCast(@alignCast(context));
        if (spec.frontend != .vhost_user_blk) return error.UnsupportedFrontend;
        const names = namesFor(spec.endpoint_id);
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
            .locator = .{ .vhost_user_blk = .{
                .socket_path = instance.socket_path[0..instance.socket_path_len],
            } },
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
    bdev_name: [name_length]u8 = @splat(0),
    controller_name: [name_length]u8 = @splat(0),

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

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn sameLocation(a: pool_member_set.Location, b: pool_member_set.Location) bool {
    return a.parent.handle == b.parent.handle and std.mem.eql(u8, a.basename, b.basename);
}

test "configured pool source validates routing entries" {
    const location = pool_member_set.Location{ .parent = std.Io.Dir.cwd(), .basename = "member" };
    const valid = ConfiguredPoolSource.Config{ .pool_id = testId(1), .locations = &.{location} };
    var configs = [_]ConfiguredPoolSource.Config{ valid, valid };

    try std.testing.expectError(
        error.DuplicatePoolConfig,
        ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs),
    );
    configs[1].pool_id = @splat(0);
    try std.testing.expectError(
        error.InvalidPoolId,
        ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs),
    );
    configs[1] = .{ .pool_id = testId(2), .locations = &.{} };
    try std.testing.expectError(
        error.MissingPoolLocations,
        ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs),
    );

    configs[1] = .{ .pool_id = testId(2), .locations = &.{location} };
    try std.testing.expectError(
        error.DuplicatePoolLocation,
        ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs),
    );
    const empty_location = pool_member_set.Location{ .parent = std.Io.Dir.cwd(), .basename = "" };
    configs[1] = .{ .pool_id = testId(2), .locations = &.{empty_location} };
    try std.testing.expectError(
        error.InvalidPoolLocation,
        ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs),
    );
    const too_many: [pool_member_set.max_member_count + 1]pool_member_set.Location = @splat(location);
    configs[1] = .{ .pool_id = testId(2), .locations = &too_many };
    try std.testing.expectError(
        error.TooManyPoolLocations,
        ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs),
    );
}

test "configured pool source opens and releases a real pool" {
    const pool_provision = @import("../v3/pool_provision.zig");
    const storage_api = @import("../v3/storage.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storages = [_]storage_api.Storage{
        try storage_api.Storage.createFile(std.testing.io, tmp.dir, "member", 8 * 1024 * 1024),
    };
    const outcome = try pool_provision.create(std.testing.io, std.testing.allocator, &storages, .{
        .protection = .unprotected,
    });
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    const pool_id = provisioned.genesis.topology.set_id;
    try provisioned.close();

    const locations = [_]pool_member_set.Location{.{ .parent = tmp.dir, .basename = "member" }};
    const configs = [_]ConfiguredPoolSource.Config{.{
        .pool_id = pool_id,
        .locations = &locations,
    }};
    var configured = try ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs);
    const source = configured.poolSource();
    try std.testing.expectError(error.PoolNotConfigured, source.open(testId(99)));

    const opened = try source.open(pool_id);
    try std.testing.expectEqualSlices(u8, &pool_id, &opened.pool_id);
    try std.testing.expectEqualSlices(u8, &pool_id, &opened.set.authority().?.topology.set_id);
    try source.close(opened.set);

    const reopened = try source.open(pool_id);
    source.abort(reopened.set);
}

test "stable vhost names use the endpoint id" {
    const names = namesFor(testId(0xab));
    try std.testing.expectEqualStrings("zvb-000000000000000000000000000000ab", names.bdevSlice());
    try std.testing.expectEqualStrings("zvh-000000000000000000000000000000ab", names.controllerSlice());
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
    var spec: endpoint_registry.Spec = .{
        .endpoint_id = testId(1),
        .pool_id = testId(2),
        .volume_id = testId(3),
        .frontend = .vhost_user_blk,
    };
    const names = namesFor(spec.endpoint_id);

    spec.frontend = .iscsi;
    try std.testing.expectError(error.UnsupportedFrontend, backend.start(spec));
    try std.testing.expectEqual(@as(usize, 0), source.opens);
    spec.frontend = .vhost_user_blk;
    const instance = try backend.start(spec);
    try std.testing.expectEqualStrings(
        driver.socket_path,
        instance.locator.vhost_user_blk.socket_path,
    );
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
        .frontend = .vhost_user_blk,
    };

    try std.testing.expectError(error.PoolIdentityMismatch, backend.start(spec));
    try std.testing.expectEqual(@as(usize, 1), source.aborts);
    try std.testing.expectEqual(@as(usize, 0), driver.creates);

    source.actual_pool_id = spec.pool_id;
    driver.fail_create = true;
    try std.testing.expectError(error.ExportCreateFailed, backend.start(spec));
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
        .frontend = .vhost_user_blk,
    };
    const instance = try backend.start(spec);

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
        .frontend = .vhost_user_blk,
    };
    const instance = try backend.start(spec);

    try std.testing.expectError(error.PoolCloseFailed, backend.stop(instance.handle));
    source.fail_close = false;
    try backend.stop(instance.handle);
    try std.testing.expectEqual(@as(usize, 1), driver.closes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 4 }, events.values[0..events.len]);
}
