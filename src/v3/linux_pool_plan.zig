const std = @import("std");
const linux_block = @import("linux_block_device.zig");
const member_format = @import("member_format.zig");
const pool_blob_schedule = @import("pool_blob_schedule.zig");
const pool_policy = @import("pool_policy.zig");
const pool_provision = @import("pool_provision.zig");
const storage_api = @import("storage.zig");
const name_profile = @import("../name_profile.zig");

pub const Options = struct {
    protection: pool_policy.Protection,
    label: []const u8,
    name_profile: name_profile.Profile = .legacy_raw,
    data_mode: member_format.PoolDataMode = .blob,
    scheduled_blob: bool = false,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    devices: []linux_block.DeviceInfo,
    contains_data: []bool,
    options: Options,
    token: [32]u8,

    pub fn ready(self: *const Plan) bool {
        for (self.devices, self.contains_data) |device, contains_data| {
            if (!deviceReadyForDataMode(device, self.options.data_mode) or contains_data) return false;
        }
        return true;
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.devices);
        self.allocator.free(self.contains_data);
        self.devices = &.{};
        self.contains_data = &.{};
    }
};

pub const AcquiredPlan = struct {
    plan: Plan,
    storages: []storage_api.Storage,
    io: std.Io,

    pub fn deinit(self: *AcquiredPlan) void {
        for (self.storages) |*storage| storage.close(self.io) catch {};
        if (self.storages.len != 0) self.plan.allocator.free(self.storages);
        self.plan.deinit();
        self.storages = &.{};
    }

    pub fn takeStorages(self: *AcquiredPlan) []storage_api.Storage {
        const storages = self.storages;
        self.storages = &.{};
        return storages;
    }
};

pub fn inspect(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    options: Options,
) !Plan {
    try validateRequest(paths, options);

    const devices = try allocator.alloc(linux_block.DeviceInfo, paths.len);
    errdefer allocator.free(devices);
    const contains_data = try allocator.alloc(bool, paths.len);
    errdefer allocator.free(contains_data);
    for (paths, 0..) |path, index| {
        devices[index] = try linux_block.inspect(io, allocator, path);
        for (devices[0..index]) |previous| {
            if (linux_block.DeviceId.eql(devices[index].id, previous.id)) return error.DuplicateDevice;
        }
        contains_data[index] = try linux_block.pathHasData(io, allocator, path);
    }
    const plan: Plan = .{
        .allocator = allocator,
        .paths = paths,
        .devices = devices,
        .contains_data = contains_data,
        .options = options,
        .token = computeToken(devices, contains_data, options),
    };
    return plan;
}

pub fn acquireCurrent(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    options: Options,
) !AcquiredPlan {
    try validateRequest(paths, options);
    const devices = try allocator.alloc(linux_block.DeviceInfo, paths.len);
    errdefer allocator.free(devices);
    const contains_data = try allocator.alloc(bool, paths.len);
    errdefer allocator.free(contains_data);
    const storages = try allocator.alloc(storage_api.Storage, paths.len);
    var acquired: usize = 0;
    errdefer {
        for (storages[0..acquired]) |*storage| storage.close(io) catch {};
        allocator.free(storages);
    }

    for (paths, 0..) |path, index| {
        var opened = try linux_block.openStorage(io, allocator, path, true);
        errdefer opened.storage.close(io) catch {};
        devices[index] = opened.info;
        for (devices[0..index]) |previous| {
            if (linux_block.DeviceId.eql(devices[index].id, previous.id)) return error.DuplicateDevice;
        }
        storages[index] = opened.storage;
        acquired += 1;
    }
    for (storages, 0..) |*storage, index|
        contains_data[index] = try linux_block.hasData(storage, io, allocator);

    return .{
        .plan = .{
            .allocator = allocator,
            .paths = paths,
            .devices = devices,
            .contains_data = contains_data,
            .options = options,
            .token = computeToken(devices, contains_data, options),
        },
        .storages = storages,
        .io = io,
    };
}

pub fn acquire(plan: *const Plan, io: std.Io, allocator: std.mem.Allocator) ![]storage_api.Storage {
    if (!plan.ready()) return error.PlanNotReady;
    const storages = try allocator.alloc(storage_api.Storage, plan.paths.len);
    var acquired: usize = 0;
    errdefer {
        for (storages[0..acquired]) |*storage| storage.close(io) catch {};
        allocator.free(storages);
    }
    for (plan.paths, 0..) |path, index| {
        var opened = try linux_block.openStorage(io, allocator, path, true);
        errdefer opened.storage.close(io) catch {};
        const expected = plan.devices[index];
        if (!linux_block.DeviceId.eql(expected.id, opened.info.id) or
            expected.disk_sequence != opened.info.disk_sequence or
            expected.capacity_bytes != opened.info.capacity_bytes or
            expected.logical_sector_size != opened.info.logical_sector_size)
            return error.DeviceChanged;
        if (try linux_block.hasData(&opened.storage, io, allocator)) return error.DeviceContainsData;
        storages[index] = opened.storage;
        acquired += 1;
    }
    return storages;
}

pub fn deviceReady(device: linux_block.DeviceInfo) bool {
    return deviceReadyForDataMode(device, .blob);
}

pub fn deviceReadyForDataMode(device: linux_block.DeviceInfo, data_mode: member_format.PoolDataMode) bool {
    const minimum_capacity = pool_provision.minimumMemberBytes(.{ .data_mode = data_mode }) catch return false;
    return device.preflightEligible() and
        std.math.isPowerOfTwo(device.logical_sector_size) and
        device.logical_sector_size <= 4096 and
        4096 % device.logical_sector_size == 0 and
        device.capacity_bytes >= minimum_capacity;
}

fn validateRequest(paths: []const []const u8, options: Options) !void {
    if (paths.len == 0 or paths.len > @import("pool_topology.zig").max_member_count)
        return error.InvalidMemberCount;
    if (options.scheduled_blob) {
        if (options.data_mode != .blob or
            options.protection != .replicated or
            paths.len < pool_blob_schedule.replica_count or
            paths.len > pool_blob_schedule.max_member_count)
            return error.InvalidScheduledBlobOptions;
    }
    if (options.protection == .erasure_coded) return error.ErasureCodingNotImplemented;
    if (!options.scheduled_blob and paths.len != try options.protection.fullWidth())
        return error.UnsupportedPoolWidth;
    _ = try @import("member_format.zig").Label.init(options.label);
}

fn computeToken(devices: []const linux_block.DeviceInfo, contains_data: []const bool, options: Options) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("zettide-linux-pool-plan-v4\x00");
    hasher.update(@tagName(options.data_mode));
    hasher.update("\x00");
    hasher.update(&.{@intFromBool(options.scheduled_blob)});
    var plan_header: [10]u8 = undefined;
    std.mem.writeInt(u64, plan_header[0..8], options.label.len, .little);
    plan_header[8] = @intFromEnum(std.meta.activeTag(options.protection));
    plan_header[9] = @intCast(devices.len);
    hasher.update(&plan_header);
    hasher.update(options.label);
    if (options.name_profile != .legacy_raw) {
        hasher.update("zettide-name-profile\x00");
        hasher.update(options.name_profile.name());
    }
    for (devices, contains_data) |device, has_data| {
        var bytes: [29]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], device.id.major, .little);
        std.mem.writeInt(u32, bytes[4..8], device.id.minor, .little);
        std.mem.writeInt(u64, bytes[8..16], device.disk_sequence, .little);
        std.mem.writeInt(u64, bytes[16..24], device.capacity_bytes, .little);
        std.mem.writeInt(u32, bytes[24..28], device.logical_sector_size, .little);
        bytes[28] = @intFromBool(has_data);
        hasher.update(&bytes);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

pub fn formatToken(token: [32]u8, output: *[64]u8) []const u8 {
    return std.fmt.bufPrint(output, "{x}", .{token}) catch unreachable;
}

test "plan token binds device order geometry and options" {
    const first: linux_block.DeviceInfo = .{
        .id = .{ .major = 8, .minor = 0 },
        .disk_sequence = 10,
        .capacity_bytes = 1024,
        .logical_sector_size = 512,
        .sysfs_path = undefined,
        .sysfs_path_len = 0,
        .eligibility = .{},
    };
    var second = first;
    second.id.minor = 16;
    const devices = [_]linux_block.DeviceInfo{ first, second };
    const reversed = [_]linux_block.DeviceInfo{ second, first };
    const contains_data = [_]bool{ false, false };
    const options: Options = .{ .protection = .unprotected, .label = "pool" };
    const blob_token = computeToken(&devices, &contains_data, options);
    try std.testing.expectEqualSlices(
        u8,
        &blob_token,
        &computeToken(&devices, &contains_data, .{
            .protection = .unprotected,
            .label = "pool",
            .data_mode = .blob,
        }),
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &computeToken(&devices, &contains_data, options),
        &computeToken(&reversed, &contains_data, options),
    ));
    const catalog_options: Options = .{
        .protection = .unprotected,
        .label = "pool",
        .data_mode = .catalog,
    };
    try std.testing.expect(!std.mem.eql(
        u8,
        &blob_token,
        &computeToken(&devices, &contains_data, catalog_options),
    ));
    try std.testing.expectEqualSlices(
        u8,
        &computeToken(&devices, &contains_data, catalog_options),
        &computeToken(&devices, &contains_data, .{
            .protection = .unprotected,
            .label = "pool",
            .data_mode = .catalog,
        }),
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &computeToken(&devices, &contains_data, options),
        &computeToken(&devices, &contains_data, .{ .protection = .unprotected, .label = "other" }),
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &computeToken(&devices, &contains_data, options),
        &computeToken(&devices, &contains_data, .{ .protection = .replicated, .label = "pool" }),
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &computeToken(&devices, &contains_data, options),
        &computeToken(&devices, &contains_data, .{
            .protection = .unprotected,
            .label = "pool",
            .name_profile = .portable_v1,
        }),
    ));
    const scheduled_options: Options = .{
        .protection = .replicated,
        .label = "pool",
        .data_mode = .blob,
        .scheduled_blob = true,
    };
    try std.testing.expect(!std.mem.eql(
        u8,
        &computeToken(&devices, &contains_data, options),
        &computeToken(&devices, &contains_data, scheduled_options),
    ));
    var changed = devices;
    changed[0].disk_sequence += 1;
    try std.testing.expect(!std.mem.eql(
        u8,
        &computeToken(&devices, &contains_data, options),
        &computeToken(&changed, &contains_data, options),
    ));
    changed = devices;
    changed[0].capacity_bytes += 512;
    try std.testing.expect(!std.mem.eql(
        u8,
        &computeToken(&devices, &contains_data, options),
        &computeToken(&changed, &contains_data, options),
    ));
    const found_data = [_]bool{ true, false };
    try std.testing.expect(!std.mem.eql(
        u8,
        &computeToken(&devices, &contains_data, options),
        &computeToken(&devices, &found_data, options),
    ));
}

test "scheduled Blob request validates profile and member count" {
    const scheduled: Options = .{
        .protection = .replicated,
        .label = "pool",
        .data_mode = .blob,
        .scheduled_blob = true,
    };
    const paths: [pool_blob_schedule.max_member_count][]const u8 = @splat("device");
    const too_many_paths: [pool_blob_schedule.max_member_count + 1][]const u8 = @splat("device");

    try validateRequest(paths[0..pool_blob_schedule.replica_count], scheduled);
    try validateRequest(&paths, scheduled);
    try std.testing.expectError(
        error.InvalidScheduledBlobOptions,
        validateRequest(paths[0 .. pool_blob_schedule.replica_count - 1], scheduled),
    );
    try std.testing.expectError(
        error.InvalidScheduledBlobOptions,
        validateRequest(&too_many_paths, scheduled),
    );
    try std.testing.expectError(error.InvalidMemberCount, validateRequest(&.{}, scheduled));
    try std.testing.expectError(error.InvalidScheduledBlobOptions, validateRequest(paths[0..3], .{
        .protection = .unprotected,
        .label = "pool",
        .data_mode = .blob,
        .scheduled_blob = true,
    }));
    try std.testing.expectError(error.InvalidScheduledBlobOptions, validateRequest(paths[0..3], .{
        .protection = .replicated,
        .label = "pool",
        .data_mode = .catalog,
        .scheduled_blob = true,
    }));
    try std.testing.expectError(error.UnsupportedPoolWidth, validateRequest(paths[0..4], .{
        .protection = .replicated,
        .label = "pool",
        .data_mode = .blob,
    }));
}

test "device readiness rejects unsupported geometry" {
    var device: linux_block.DeviceInfo = .{
        .id = .{ .major = 8, .minor = 0 },
        .disk_sequence = 10,
        .capacity_bytes = 3 * 1024 * 1024,
        .logical_sector_size = 512,
        .sysfs_path = undefined,
        .sysfs_path_len = 0,
        .eligibility = .{},
    };
    try std.testing.expect(deviceReadyForDataMode(device, .catalog));
    try std.testing.expect(!deviceReady(device));
    device.capacity_bytes -= 1;
    try std.testing.expect(!deviceReadyForDataMode(device, .catalog));
    device.capacity_bytes += 1;
    device.logical_sector_size = 8192;
    try std.testing.expect(!deviceReady(device));
}

test "Blob device readiness enforces Blob logical capacity" {
    var device: linux_block.DeviceInfo = .{
        .id = .{ .major = 8, .minor = 0 },
        .disk_sequence = 10,
        .capacity_bytes = try pool_provision.minimumMemberBytes(.{ .data_mode = .blob }),
        .logical_sector_size = 512,
        .sysfs_path = undefined,
        .sysfs_path_len = 0,
        .eligibility = .{},
    };
    try std.testing.expect(deviceReadyForDataMode(device, .blob));
    device.capacity_bytes -= 1;
    try std.testing.expect(!deviceReadyForDataMode(device, .blob));
    try std.testing.expect(deviceReadyForDataMode(device, .catalog));
}
