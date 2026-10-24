const std = @import("std");
const catalog_nvmf_export = @import("catalog_nvmf_export.zig");
const endpoint_registry = @import("../endpoint_registry.zig");
const runtime_api = @import("runtime.zig");
const storage_engine = @import("zettide_storage");
const pool_member_set = storage_engine.v3.pool_member_set;

pub const name_length = 36;

pub fn bdevNameFor(endpoint_id: endpoint_registry.EndpointId) [name_length]u8 {
    var result: [name_length]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "zvb-{x}", .{endpoint_id}) catch unreachable;
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
/// allocator must be thread-safe; configs and locations must outlive this source.
pub const ConfiguredPoolSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    configs: []const Config,

    pub const Config = struct {
        pool_id: endpoint_registry.PoolId,
        locations: []const pool_member_set.Location,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configs: []const Config) !ConfiguredPoolSource {
        for (configs, 0..) |config, index| {
            if (isZero(&config.pool_id)) return error.InvalidPoolId;
            if (config.locations.len == 0) return error.MissingPoolLocations;
            if (config.locations.len > pool_member_set.max_member_count) return error.TooManyPoolLocations;
            for (configs[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.pool_id, &config.pool_id)) return error.DuplicatePoolConfig;
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
        set.* = try pool_member_set.PoolMemberSet.open(self.io, self.allocator, config.locations, .writable);
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
            if (!set.isClosed()) std.debug.panic("failed to abort opened pool: {s}", .{@errorName(err)});
        };
        self.allocator.destroy(set);
    }

    const vtable: PoolSource.VTable = .{ .open = openOpaque, .close = closeOpaque, .abort = abortOpaque };
};

pub const Options = struct {
    block_size: u32 = 4096,
    write_unit_blocks: u32 = 1,
    max_io_blocks: u32 = 256,
    nvme_of_tcp: NvmeOfOptions = .{},
};

pub const NvmeOfOptions = struct {
    target_name: ?[]const u8 = null,
    traddr: ?[]const u8 = null,
    trsvcid: []const u8 = "4420",
    host_nqn: ?[]const u8 = null,
    allow_any_host: bool = false,
};

/// Owns complete Catalog TCP exports. The allocator must be thread-safe; this
/// object, io, runtime, source, and option strings must outlive every endpoint.
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
        nqn: [nqn_length]u8,
    };
    const nqn_prefix = "nqn.2026-08.io.zettide:";
    const nqn_length = nqn_prefix.len + 32;
    const serial_number_length = 20;
    const model_number = "Zettide Catalog Volume";

    pub fn init(allocator: std.mem.Allocator, io: std.Io, runtime: *runtime_api.Runtime, source: PoolSource, options: Options) CatalogEndpointBackend {
        return initWithDriver(allocator, io, runtime, source, options, catalog_driver);
    }

    fn initWithDriver(allocator: std.mem.Allocator, io: std.Io, runtime: *runtime_api.Runtime, source: PoolSource, options: Options, driver: ExportDriver) CatalogEndpointBackend {
        return .{ .allocator = allocator, .io = io, .runtime = runtime, .source = source, .options = options, .driver = driver };
    }

    pub fn endpointBackend(self: *CatalogEndpointBackend) endpoint_registry.Backend {
        return .{ .context = self, .vtable = &backend_vtable };
    }

    fn startOpaque(context: *anyopaque, spec: endpoint_registry.Spec) !endpoint_registry.Backend.Instance {
        const self: *CatalogEndpointBackend = @ptrCast(@alignCast(context));
        const options = self.options.nvme_of_tcp;
        const traddr = options.traddr orelse return error.UnsupportedFrontend;
        const name = bdevNameFor(spec.endpoint_id);
        const instance = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(instance);
        const opened = try self.source.open(spec.pool_id);
        errdefer self.source.abort(opened.set);
        if (!std.mem.eql(u8, &opened.pool_id, &spec.pool_id)) return error.PoolIdentityMismatch;
        instance.* = .{ .set = opened.set, .export_handle = null, .nqn = undefined };
        writeNqn(&instance.nqn, spec.endpoint_id);
        var serial_number: [serial_number_length]u8 = undefined;
        writeHex(&serial_number, spec.endpoint_id[0 .. serial_number_length / 2]);
        instance.export_handle = try self.driver.create(self.allocator, self.io, self.runtime, opened.set, spec.volume_id, .{
            .bdev_name = &name,
            .nqn = &instance.nqn,
            .serial_number = &serial_number,
            .model_number = model_number,
            .host_nqn = options.host_nqn,
            .traddr = traddr,
            .trsvcid = options.trsvcid,
            .nsid = 1,
            .allow_any_host = options.allow_any_host,
            .target_name = options.target_name,
            .block_size = self.options.block_size,
            .write_unit_blocks = self.options.write_unit_blocks,
            .max_io_blocks = self.options.max_io_blocks,
        });
        return .{ .handle = instance, .locator = .{ .nvme_of_tcp = .{
            .traddr = traddr,
            .trsvcid = options.trsvcid,
            .nqn = &instance.nqn,
            .nsid = 1,
        } } };
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

    const backend_vtable: endpoint_registry.Backend.VTable = .{ .start = startOpaque, .stop = stopOpaque };
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
    const VTable = struct {
        create: *const fn (?*anyopaque, std.mem.Allocator, std.Io, *runtime_api.Runtime, *pool_member_set.PoolMemberSet, endpoint_registry.VolumeId, catalog_nvmf_export.Options) anyerror!*anyopaque,
        close: *const fn (?*anyopaque, std.mem.Allocator, *anyopaque) anyerror!void,
    };

    fn create(self: ExportDriver, allocator: std.mem.Allocator, io: std.Io, runtime: *runtime_api.Runtime, set: *pool_member_set.PoolMemberSet, volume_id: endpoint_registry.VolumeId, options: catalog_nvmf_export.Options) !*anyopaque {
        return self.vtable.create(self.context, allocator, io, runtime, set, volume_id, options);
    }

    fn close(self: ExportDriver, allocator: std.mem.Allocator, handle: *anyopaque) !void {
        return self.vtable.close(self.context, allocator, handle);
    }
};

fn createCatalogExport(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, runtime: *runtime_api.Runtime, set: *pool_member_set.PoolMemberSet, volume_id: endpoint_registry.VolumeId, options: catalog_nvmf_export.Options) !*anyopaque {
    const handle = try allocator.create(catalog_nvmf_export.CatalogNvmfExport);
    errdefer allocator.destroy(handle);
    handle.* = try catalog_nvmf_export.CatalogNvmfExport.create(allocator, io, runtime, set, volume_id, options);
    return handle;
}

fn closeCatalogExport(_: ?*anyopaque, allocator: std.mem.Allocator, handle: *anyopaque) !void {
    const export_handle: *catalog_nvmf_export.CatalogNvmfExport = @ptrCast(@alignCast(handle));
    try export_handle.close();
    allocator.destroy(export_handle);
}

const catalog_driver: ExportDriver = .{ .context = null, .vtable = &.{ .create = createCatalogExport, .close = closeCatalogExport } };

const Events = struct {
    values: [16]u8 = @splat(0),
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
    volume_id: endpoint_registry.VolumeId = @splat(0),
    bdev_name: [name_length]u8 = @splat(0),
    nqn: [CatalogEndpointBackend.nqn_length]u8 = @splat(0),
    serial_number: [CatalogEndpointBackend.serial_number_length]u8 = @splat(0),
    fn exportDriver(self: *FakeExportDriver) ExportDriver {
        return .{ .context = self, .vtable = &vtable };
    }
    fn create(context: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: *runtime_api.Runtime, set: *pool_member_set.PoolMemberSet, volume_id: endpoint_registry.VolumeId, options: catalog_nvmf_export.Options) !*anyopaque {
        const self: *FakeExportDriver = @ptrCast(@alignCast(context.?));
        std.debug.assert(set == self.expected_set);
        self.creates += 1;
        self.events.add(2);
        if (self.fail_create) return error.ExportCreateFailed;
        try std.testing.expectEqualStrings("nvmf0", options.target_name.?);
        try std.testing.expectEqualStrings("192.0.2.1", options.traddr);
        try std.testing.expectEqualStrings("4420", options.trsvcid);
        try std.testing.expectEqualStrings("nqn.2014-08.org.nvmexpress:host", options.host_nqn.?);
        try std.testing.expectEqualStrings(CatalogEndpointBackend.model_number, options.model_number.?);
        try std.testing.expect(!options.allow_any_host);
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
fn testOptions() Options {
    return .{ .block_size = 8192, .write_unit_blocks = 2, .max_io_blocks = 128, .nvme_of_tcp = .{
        .target_name = "nvmf0",
        .traddr = "192.0.2.1",
        .host_nqn = "nqn.2014-08.org.nvmexpress:host",
    } };
}
const test_spec: endpoint_registry.Spec = .{ .endpoint_id = testId(1), .pool_id = testId(2), .volume_id = testId(3), .frontend = .nvme_of_tcp };

test "configured pool source validates routing entries" {
    const location = pool_member_set.Location{ .parent = std.Io.Dir.cwd(), .basename = "member" };
    const valid = ConfiguredPoolSource.Config{ .pool_id = testId(1), .locations = &.{location} };
    var configs = [_]ConfiguredPoolSource.Config{ valid, valid };
    try std.testing.expectError(error.DuplicatePoolConfig, ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs));
    configs[1].pool_id = @splat(0);
    try std.testing.expectError(error.InvalidPoolId, ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs));
    configs[1] = .{ .pool_id = testId(2), .locations = &.{} };
    try std.testing.expectError(error.MissingPoolLocations, ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs));
    configs[1] = .{ .pool_id = testId(2), .locations = &.{location} };
    try std.testing.expectError(error.DuplicatePoolLocation, ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs));
    configs[1] = .{ .pool_id = testId(2), .locations = &.{.{ .parent = std.Io.Dir.cwd(), .basename = "" }} };
    try std.testing.expectError(error.InvalidPoolLocation, ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs));
    const too_many: [pool_member_set.max_member_count + 1]pool_member_set.Location = @splat(location);
    configs[1] = .{ .pool_id = testId(2), .locations = &too_many };
    try std.testing.expectError(error.TooManyPoolLocations, ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &configs));
}

test "configured pool source opens and releases a real Catalog pool" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const storage_api = storage_engine.v3.storage;
    var storages = [_]storage_api.Storage{try storage_api.Storage.createFile(std.testing.io, tmp.dir, "member", 8 * 1024 * 1024)};
    const outcome = try storage_engine.v3.pool_provision.create(std.testing.io, std.testing.allocator, &storages, .{ .protection = .unprotected, .data_mode = .catalog });
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    const pool_id = provisioned.genesis.topology.set_id;
    try provisioned.close();
    var configured = try ConfiguredPoolSource.init(std.testing.allocator, std.testing.io, &.{.{ .pool_id = pool_id, .locations = &.{.{ .parent = tmp.dir, .basename = "member" }} }});
    const source = configured.poolSource();
    try std.testing.expectError(error.PoolNotConfigured, source.open(testId(99)));
    const opened = try source.open(pool_id);
    try std.testing.expectEqualSlices(u8, &pool_id, &opened.pool_id);
    try std.testing.expectEqual(.catalog, try opened.set.dataMode());
    try source.close(opened.set);
    const reopened = try source.open(pool_id);
    source.abort(reopened.set);
}

test "NVMe identities preserve deterministic lowercase endpoint hex" {
    const endpoint_id: endpoint_registry.EndpointId = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };
    try std.testing.expectEqualStrings("zvb-000000000000000000000000000000ab", &bdevNameFor(testId(0xab)));
    var nqn: [CatalogEndpointBackend.nqn_length]u8 = undefined;
    var serial: [CatalogEndpointBackend.serial_number_length]u8 = undefined;
    writeNqn(&nqn, endpoint_id);
    writeHex(&serial, endpoint_id[0 .. serial.len / 2]);
    try std.testing.expectEqualStrings("nqn.2026-08.io.zettide:0123456789abcdeffedcba9876543210", &nqn);
    try std.testing.expectEqualStrings("0123456789abcdeffedc", &serial);
}

test "TCP endpoint composes pool export locator and global options" {
    var events: Events = .{};
    var source: FakePoolSource = .{ .events = &events, .actual_pool_id = testId(2) };
    var driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDriver(std.testing.allocator, std.testing.io, &runtime, source.poolSource(), .{}, driver.exportDriver());
    const backend = adapter.endpointBackend();
    try std.testing.expectError(error.UnsupportedFrontend, backend.start(test_spec));
    try std.testing.expectEqual(@as(usize, 0), source.opens);
    adapter.options = testOptions();
    const instance = try backend.start(test_spec);
    try std.testing.expectEqualSlices(u8, &test_spec.volume_id, &driver.volume_id);
    try std.testing.expectEqualStrings(&bdevNameFor(test_spec.endpoint_id), &driver.bdev_name);
    try std.testing.expectEqualStrings("192.0.2.1", instance.locator.nvme_of_tcp.traddr);
    try std.testing.expectEqualStrings("4420", instance.locator.nvme_of_tcp.trsvcid);
    try std.testing.expectEqualStrings(&driver.nqn, instance.locator.nvme_of_tcp.nqn);
    try std.testing.expectEqual(@as(u32, 1), instance.locator.nvme_of_tcp.nsid);
    try backend.stop(instance.handle);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, events.values[0..events.len]);
    try std.testing.expectEqual(@as(usize, 0), source.aborts);
}

test "TCP endpoint aborts mismatched pools and failed export creation" {
    var events: Events = .{};
    var source: FakePoolSource = .{ .events = &events, .actual_pool_id = testId(9) };
    var driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDriver(std.testing.allocator, std.testing.io, &runtime, source.poolSource(), testOptions(), driver.exportDriver());
    const backend = adapter.endpointBackend();
    try std.testing.expectError(error.PoolIdentityMismatch, backend.start(test_spec));
    try std.testing.expectEqual(@as(usize, 1), source.aborts);
    try std.testing.expectEqual(@as(usize, 0), driver.creates);
    source.actual_pool_id = test_spec.pool_id;
    driver.fail_create = true;
    try std.testing.expectError(error.ExportCreateFailed, backend.start(test_spec));
    try std.testing.expectEqual(@as(usize, 2), source.aborts);
    try std.testing.expectEqualSlices(u8, &.{ 1, 5, 1, 2, 5 }, events.values[0..events.len]);
}

test "TCP endpoint retries export close before pool and never recloses a released export" {
    var events: Events = .{};
    var source: FakePoolSource = .{ .events = &events, .actual_pool_id = testId(2), .fail_close = true };
    var driver: FakeExportDriver = .{ .events = &events, .expected_set = &source.set };
    var runtime: runtime_api.Runtime = .{ .handle = null };
    var adapter = CatalogEndpointBackend.initWithDriver(std.testing.allocator, std.testing.io, &runtime, source.poolSource(), testOptions(), driver.exportDriver());
    const backend = adapter.endpointBackend();
    const instance = try backend.start(test_spec);
    driver.fail_close = true;
    try std.testing.expectError(error.ExportCloseFailed, backend.stop(instance.handle));
    try std.testing.expectEqual(@as(usize, 0), source.closes);
    driver.fail_close = false;
    try std.testing.expectError(error.PoolCloseFailed, backend.stop(instance.handle));
    source.fail_close = false;
    try backend.stop(instance.handle);
    try std.testing.expectEqual(@as(usize, 2), driver.closes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 3, 4, 4 }, events.values[0..events.len]);
}
