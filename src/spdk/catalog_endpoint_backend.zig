const std = @import("std");
const catalog_nvmf_export = @import("catalog_nvmf_export.zig");
const catalog_vhost_export = @import("catalog_vhost_export.zig");
const endpoint_registry = @import("../endpoint_registry.zig");
const nvmf_export = @import("nvmf_tcp_export.zig");
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
    nvme_of_tcp: NvmeOfOptions = .{},
    nvme_of_rdma: NvmeOfOptions = .{},
};

pub const NvmeOfOptions = struct {
    target_name: ?[]const u8 = null,
    traddr: ?[]const u8 = null,
    trsvcid: []const u8 = "4420",
    host_nqn: ?[]const u8 = null,
    allow_any_host: bool = false,
};

/// Adapts registry lifecycle operations to complete catalog exports. The
/// allocator must be thread-safe. This object, allocator, io, runtime, source,
/// and option strings must remain valid until every endpoint is stopped.
pub const CatalogEndpointBackend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *runtime_api.Runtime,
    source: PoolSource,
    options: Options,
    vhost_driver: ExportDriver,
    nvmf_driver: NvmfExportDriver,

    const Instance = struct {
        set: *pool_member_set.PoolMemberSet,
        frontend: endpoint_registry.Frontend,
        export_handle: ?*anyopaque,
        socket_path: [socket_path_capacity]u8,
        socket_path_len: usize,
        nqn: [nqn_length]u8,
    };

    const socket_path_capacity = 108;
    const nqn_prefix = "nqn.2026-08.io.zettide:";
    const nqn_length = nqn_prefix.len + 32;
    const serial_number_length = 20;
    const model_number = "Zettide Catalog Volume";

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        source: PoolSource,
        options: Options,
    ) CatalogEndpointBackend {
        return initWithDrivers(
            allocator,
            io,
            runtime,
            source,
            options,
            catalog_driver,
            catalog_nvmf_driver,
        );
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
        return initWithDrivers(
            allocator,
            io,
            runtime,
            source,
            options,
            driver,
            unsupported_nvmf_driver,
        );
    }

    fn initWithDrivers(
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        source: PoolSource,
        options: Options,
        vhost_driver: ExportDriver,
        nvmf_driver: NvmfExportDriver,
    ) CatalogEndpointBackend {
        return .{
            .allocator = allocator,
            .io = io,
            .runtime = runtime,
            .source = source,
            .options = options,
            .vhost_driver = vhost_driver,
            .nvmf_driver = nvmf_driver,
        };
    }

    fn startOpaque(
        context: *anyopaque,
        spec: endpoint_registry.Spec,
    ) !endpoint_registry.Backend.Instance {
        const self: *CatalogEndpointBackend = @ptrCast(@alignCast(context));
        const nvmf_options: ?NvmeOfOptions = switch (spec.frontend) {
            .vhost_user_blk => null,
            .nvme_of_tcp => self.options.nvme_of_tcp,
            .nvme_of_rdma => self.options.nvme_of_rdma,
            .iscsi => return error.UnsupportedFrontend,
        };
        const traddr = if (nvmf_options) |options|
            options.traddr orelse return error.UnsupportedFrontend
        else
            null;
        const names = namesFor(spec.endpoint_id);
        const instance = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(instance);

        const opened = try self.source.open(spec.pool_id);
        errdefer self.source.abort(opened.set);
        if (!std.mem.eql(u8, &opened.pool_id, &spec.pool_id)) return error.PoolIdentityMismatch;

        instance.* = .{
            .set = opened.set,
            .frontend = spec.frontend,
            .export_handle = null,
            .socket_path = undefined,
            .socket_path_len = 0,
            .nqn = undefined,
        };
        switch (spec.frontend) {
            .vhost_user_blk => {
                const export_instance = try self.vhost_driver.create(
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
                instance.export_handle = export_instance.handle;
                instance.socket_path_len = export_instance.socket_path.len;
                @memcpy(instance.socket_path[0..instance.socket_path_len], export_instance.socket_path);
                return .{
                    .handle = instance,
                    .locator = .{ .vhost_user_blk = .{
                        .socket_path = instance.socket_path[0..instance.socket_path_len],
                    } },
                };
            },
            .nvme_of_tcp, .nvme_of_rdma => {
                const options = nvmf_options.?;
                writeNqn(&instance.nqn, spec.endpoint_id);
                var serial_number: [serial_number_length]u8 = undefined;
                writeHex(&serial_number, spec.endpoint_id[0 .. serial_number_length / 2]);
                instance.export_handle = try self.nvmf_driver.create(
                    self.allocator,
                    self.io,
                    self.runtime,
                    opened.set,
                    spec.volume_id,
                    .{
                        .bdev_name = names.bdevSlice(),
                        .nqn = &instance.nqn,
                        .serial_number = &serial_number,
                        .model_number = model_number,
                        .host_nqn = options.host_nqn,
                        .traddr = traddr.?,
                        .trsvcid = options.trsvcid,
                        .nsid = 1,
                        .allow_any_host = options.allow_any_host,
                        .transport = if (spec.frontend == .nvme_of_rdma) .rdma else .tcp,
                        .target_name = options.target_name,
                        .block_size = self.options.block_size,
                        .write_unit_blocks = self.options.write_unit_blocks,
                        .max_io_blocks = self.options.max_io_blocks,
                    },
                );
                return .{
                    .handle = instance,
                    .locator = switch (spec.frontend) {
                        .nvme_of_tcp => .{ .nvme_of_tcp = .{
                            .traddr = traddr.?,
                            .trsvcid = options.trsvcid,
                            .nqn = &instance.nqn,
                            .nsid = 1,
                        } },
                        .nvme_of_rdma => .{ .nvme_of_rdma = .{
                            .traddr = traddr.?,
                            .trsvcid = options.trsvcid,
                            .nqn = &instance.nqn,
                            .nsid = 1,
                        } },
                        else => unreachable,
                    },
                };
            },
            .iscsi => unreachable,
        }
    }

    fn stopOpaque(context: *anyopaque, handle: *anyopaque) !void {
        const self: *CatalogEndpointBackend = @ptrCast(@alignCast(context));
        const instance: *Instance = @ptrCast(@alignCast(handle));
        if (instance.export_handle) |export_handle| {
            switch (instance.frontend) {
                .vhost_user_blk => try self.vhost_driver.close(self.allocator, export_handle),
                .nvme_of_tcp, .nvme_of_rdma => try self.nvmf_driver.close(self.allocator, export_handle),
                .iscsi => unreachable,
            }
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

fn writeNqn(destination: *[CatalogEndpointBackend.nqn_length]u8, endpoint_id: endpoint_registry.EndpointId) void {
    @memcpy(destination[0..CatalogEndpointBackend.nqn_prefix.len], CatalogEndpointBackend.nqn_prefix);
    writeHex(destination[CatalogEndpointBackend.nqn_prefix.len..], &endpoint_id);
}

fn writeHex(destination: []u8, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    std.debug.assert(destination.len == bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        destination[index * 2] = digits[byte >> 4];
        destination[index * 2 + 1] = digits[byte & 0x0f];
    }
}

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

const NvmfExportDriver = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        create: *const fn (
            ?*anyopaque,
            std.mem.Allocator,
            std.Io,
            *runtime_api.Runtime,
            *pool_member_set.PoolMemberSet,
            endpoint_registry.VolumeId,
            catalog_nvmf_export.Options,
        ) anyerror!*anyopaque,
        close: *const fn (?*anyopaque, std.mem.Allocator, *anyopaque) anyerror!void,
    };

    fn create(
        self: NvmfExportDriver,
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        set: *pool_member_set.PoolMemberSet,
        volume_id: endpoint_registry.VolumeId,
        options: catalog_nvmf_export.Options,
    ) !*anyopaque {
        return self.vtable.create(self.context, allocator, io, runtime, set, volume_id, options);
    }

    fn close(self: NvmfExportDriver, allocator: std.mem.Allocator, handle: *anyopaque) !void {
        return self.vtable.close(self.context, allocator, handle);
    }
};

fn createCatalogNvmfExport(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: *runtime_api.Runtime,
    set: *pool_member_set.PoolMemberSet,
    volume_id: endpoint_registry.VolumeId,
    options: catalog_nvmf_export.Options,
) !*anyopaque {
    const export_handle = try allocator.create(catalog_nvmf_export.CatalogNvmfExport);
    errdefer allocator.destroy(export_handle);
    export_handle.* = try catalog_nvmf_export.CatalogNvmfExport.create(
        allocator,
        io,
        runtime,
        set,
        volume_id,
        options,
    );
    return export_handle;
}

fn closeCatalogNvmfExport(_: ?*anyopaque, allocator: std.mem.Allocator, handle: *anyopaque) !void {
    const export_handle: *catalog_nvmf_export.CatalogNvmfExport = @ptrCast(@alignCast(handle));
    try export_handle.close();
    allocator.destroy(export_handle);
}

const catalog_nvmf_driver: NvmfExportDriver = .{
    .context = null,
    .vtable = &.{
        .create = createCatalogNvmfExport,
        .close = closeCatalogNvmfExport,
    },
};

fn unsupportedNvmfCreate(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: std.Io,
    _: *runtime_api.Runtime,
    _: *pool_member_set.PoolMemberSet,
    _: endpoint_registry.VolumeId,
    _: catalog_nvmf_export.Options,
) !*anyopaque {
    return error.UnsupportedFrontend;
}

fn unsupportedNvmfClose(_: ?*anyopaque, _: std.mem.Allocator, _: *anyopaque) !void {
    unreachable;
}

const unsupported_nvmf_driver: NvmfExportDriver = .{
    .context = null,
    .vtable = &.{
        .create = unsupportedNvmfCreate,
        .close = unsupportedNvmfClose,
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

const FakeNvmfExportDriver = struct {
    events: *Events,
    expected_set: *pool_member_set.PoolMemberSet,
    fail_create: bool = false,
    fail_close: bool = false,
    creates: usize = 0,
    closes: usize = 0,
    volume_id: endpoint_registry.VolumeId = @splat(0),
    bdev_name: [name_length]u8 = @splat(0),
    nqn: [CatalogEndpointBackend.nqn_length]u8 = @splat(0),
    serial_number: [CatalogEndpointBackend.serial_number_length]u8 = @splat(0),
    expected_transport: nvmf_export.Transport = .tcp,
    expected_traddr: []const u8 = "192.0.2.1",
    expected_trsvcid: []const u8 = "4420",

    fn exportDriver(self: *FakeNvmfExportDriver) NvmfExportDriver {
        return .{ .context = self, .vtable = &vtable };
    }

    fn create(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        _: std.Io,
        _: *runtime_api.Runtime,
        set: *pool_member_set.PoolMemberSet,
        volume_id: endpoint_registry.VolumeId,
        options: catalog_nvmf_export.Options,
    ) !*anyopaque {
        const self: *FakeNvmfExportDriver = @ptrCast(@alignCast(context.?));
        std.debug.assert(set == self.expected_set);
        self.creates += 1;
        self.events.add(6);
        if (self.fail_create) return error.ExportCreateFailed;
        try std.testing.expectEqualStrings("nvmf0", options.target_name.?);
        try std.testing.expectEqual(self.expected_transport, options.transport);
        try std.testing.expectEqualStrings(self.expected_traddr, options.traddr);
        try std.testing.expectEqualStrings(self.expected_trsvcid, options.trsvcid);
        try std.testing.expectEqualStrings("nqn.2014-08.org.nvmexpress:host", options.host_nqn.?);
        try std.testing.expectEqualStrings(CatalogEndpointBackend.model_number, options.model_number.?);
        try std.testing.expect(options.allow_any_host);
        try std.testing.expectEqual(@as(u32, 1), options.nsid);
        try std.testing.expectEqual(@as(u32, 8192), options.block_size);
        try std.testing.expectEqual(@as(u32, 2), options.write_unit_blocks);
        try std.testing.expectEqual(@as(u32, 128), options.max_io_blocks);
        self.volume_id = volume_id;
        @memcpy(&self.bdev_name, options.bdev_name);
        @memcpy(&self.nqn, options.nqn);
        @memcpy(&self.serial_number, options.serial_number.?);
        return self;
    }

    fn close(context: ?*anyopaque, _: std.mem.Allocator, handle: *anyopaque) !void {
        const self: *FakeNvmfExportDriver = @ptrCast(@alignCast(context.?));
        std.debug.assert(handle == @as(*anyopaque, @ptrCast(self)));
        self.closes += 1;
        self.events.add(7);
        if (self.fail_close) return error.ExportCloseFailed;
    }

    const vtable: NvmfExportDriver.VTable = .{ .create = create, .close = close };
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

test "NVMe identities use deterministic lowercase endpoint hex" {
    const endpoint_id: endpoint_registry.EndpointId = .{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
    };
    var nqn: [CatalogEndpointBackend.nqn_length]u8 = undefined;
    var serial_number: [CatalogEndpointBackend.serial_number_length]u8 = undefined;
    writeNqn(&nqn, endpoint_id);
    writeHex(&serial_number, endpoint_id[0 .. serial_number.len / 2]);

    try std.testing.expectEqualStrings(
        "nqn.2026-08.io.zettide:0123456789abcdeffedcba9876543210",
        &nqn,
    );
    try std.testing.expectEqualStrings("0123456789abcdeffedc", &serial_number);
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
    spec.frontend = .nvme_of_tcp;
    try std.testing.expectError(error.UnsupportedFrontend, backend.start(spec));
    try std.testing.expectEqual(@as(usize, 0), source.opens);
    spec.frontend = .nvme_of_rdma;
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

test "catalog endpoint backend creates an NVMe-oF locator with global options" {
    var events: Events = .{};
    var source: FakePoolSource = .{ .events = &events, .actual_pool_id = testId(2) };
    var vhost_driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var nvmf_driver: FakeNvmfExportDriver = .{ .events = &events, .expected_set = &source.set };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDrivers(
        std.testing.allocator,
        std.testing.io,
        &runtime,
        source.poolSource(),
        .{
            .block_size = 8192,
            .write_unit_blocks = 2,
            .max_io_blocks = 128,
            .nvme_of_tcp = .{
                .target_name = "nvmf0",
                .traddr = "192.0.2.1",
                .host_nqn = "nqn.2014-08.org.nvmexpress:host",
                .allow_any_host = true,
            },
            .nvme_of_rdma = .{
                .target_name = "nvmf0",
                .traddr = "192.0.2.2",
                .host_nqn = "nqn.2014-08.org.nvmexpress:host",
                .allow_any_host = true,
            },
        },
        vhost_driver.exportDriver(),
        nvmf_driver.exportDriver(),
    );
    const backend = adapter.endpointBackend();
    var spec: endpoint_registry.Spec = .{
        .endpoint_id = testId(0xab),
        .pool_id = testId(2),
        .volume_id = testId(3),
        .frontend = .nvme_of_tcp,
    };
    const instance = try backend.start(spec);

    try std.testing.expectEqual(@as(usize, 0), vhost_driver.creates);
    try std.testing.expectEqualSlices(u8, &spec.volume_id, &nvmf_driver.volume_id);
    try std.testing.expectEqualStrings(namesFor(spec.endpoint_id).bdevSlice(), &nvmf_driver.bdev_name);
    try std.testing.expectEqualStrings(
        "nqn.2026-08.io.zettide:000000000000000000000000000000ab",
        &nvmf_driver.nqn,
    );
    try std.testing.expectEqualStrings("00000000000000000000", &nvmf_driver.serial_number);
    try std.testing.expectEqualStrings("192.0.2.1", instance.locator.nvme_of_tcp.traddr);
    try std.testing.expectEqualStrings("4420", instance.locator.nvme_of_tcp.trsvcid);
    try std.testing.expectEqualStrings(&nvmf_driver.nqn, instance.locator.nvme_of_tcp.nqn);
    try std.testing.expectEqual(@as(u32, 1), instance.locator.nvme_of_tcp.nsid);
    try backend.stop(instance.handle);

    nvmf_driver.expected_transport = .rdma;
    nvmf_driver.expected_traddr = "192.0.2.2";
    spec.frontend = .nvme_of_rdma;
    const rdma_instance = try backend.start(spec);
    try std.testing.expectEqualStrings("192.0.2.2", rdma_instance.locator.nvme_of_rdma.traddr);
    try std.testing.expectEqualStrings("4420", rdma_instance.locator.nvme_of_rdma.trsvcid);
    try std.testing.expectEqualStrings(&nvmf_driver.nqn, rdma_instance.locator.nvme_of_rdma.nqn);
    try std.testing.expectEqual(@as(u32, 1), rdma_instance.locator.nvme_of_rdma.nsid);
    try backend.stop(rdma_instance.handle);
    try std.testing.expectEqualSlices(u8, &.{ 1, 6, 7, 4, 1, 6, 7, 4 }, events.values[0..events.len]);
}

test "catalog endpoint backend retries NVMe export before pool teardown" {
    var events: Events = .{};
    var source: FakePoolSource = .{
        .events = &events,
        .actual_pool_id = testId(2),
        .fail_close = true,
    };
    var vhost_driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var nvmf_driver: FakeNvmfExportDriver = .{
        .events = &events,
        .expected_set = &source.set,
        .expected_trsvcid = "4421",
    };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDrivers(
        std.testing.allocator,
        std.testing.io,
        &runtime,
        source.poolSource(),
        .{ .nvme_of_tcp = .{
            .target_name = "nvmf0",
            .traddr = "192.0.2.1",
            .trsvcid = "4421",
            .host_nqn = "nqn.2014-08.org.nvmexpress:host",
            .allow_any_host = true,
        }, .block_size = 8192, .write_unit_blocks = 2, .max_io_blocks = 128 },
        vhost_driver.exportDriver(),
        nvmf_driver.exportDriver(),
    );
    const backend = adapter.endpointBackend();
    const spec: endpoint_registry.Spec = .{
        .endpoint_id = testId(1),
        .pool_id = testId(2),
        .volume_id = testId(3),
        .frontend = .nvme_of_tcp,
    };
    const instance = try backend.start(spec);

    nvmf_driver.fail_close = true;
    try std.testing.expectError(error.ExportCloseFailed, backend.stop(instance.handle));
    try std.testing.expectEqual(@as(usize, 0), source.closes);
    nvmf_driver.fail_close = false;
    try std.testing.expectError(error.PoolCloseFailed, backend.stop(instance.handle));
    try std.testing.expectEqual(@as(usize, 2), nvmf_driver.closes);
    source.fail_close = false;
    try backend.stop(instance.handle);
    try std.testing.expectEqual(@as(usize, 2), nvmf_driver.closes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 6, 7, 7, 4, 4 }, events.values[0..events.len]);
}
