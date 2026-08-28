const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");
const common = @import("common.zig");

const PoolProfile = enum {
    replicated,
    unprotected,
    scheduled_replicated,

    fn parse(value: []const u8) !PoolProfile {
        if (std.mem.eql(u8, value, "replicated")) return .replicated;
        if (std.mem.eql(u8, value, "unprotected")) return .unprotected;
        if (std.mem.eql(u8, value, "scheduled-replicated")) return .scheduled_replicated;
        return error.InvalidProfile;
    }
};

pub fn command(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (@import("builtin").os.tag != .linux) return error.RawPoolNotImplemented;
    if (args.len == 0) return error.InvalidArguments;
    const operation = args[0];
    if (std.mem.eql(u8, operation, "inspect"))
        return poolInspectCommand(allocator, io, args[1..], stdout);
    if (std.mem.eql(u8, operation, "mount"))
        return poolMountCommand(allocator, io, args[1..], stdout);
    const planning = std.mem.eql(u8, operation, "plan-create");
    const creating = std.mem.eql(u8, operation, "create");
    if (!planning and !creating) return error.InvalidArguments;

    var paths: [zettide.v3.pool_topology.max_member_count][]const u8 = undefined;
    var path_count: usize = 0;
    var profile: PoolProfile = .replicated;
    var label: []const u8 = "Zettide";
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var confirmation: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const option = args[index];
        if (std.mem.eql(u8, option, "--device")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            if (path_count == paths.len) return error.TooManyDevices;
            paths[path_count] = args[index];
            path_count += 1;
        } else if (std.mem.eql(u8, option, "--profile")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            profile = try .parse(args[index]);
        } else if (std.mem.eql(u8, option, "--label")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            label = args[index];
        } else if (std.mem.eql(u8, option, "--name-profile")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            name_profile = try zettide.name_profile.Profile.parse(args[index]);
        } else if (std.mem.eql(u8, option, "--confirm")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            if (confirmation != null) return error.DuplicateOption;
            confirmation = args[index];
        } else {
            return error.UnknownOption;
        }
    }
    const scheduled_blob = profile == .scheduled_replicated;
    const protection: zettide.v3.pool_policy.Protection = switch (profile) {
        .replicated, .scheduled_replicated => .replicated,
        .unprotected => .unprotected,
    };
    if (planning and confirmation != null) return error.UnknownOption;
    if (creating and confirmation == null) return error.MissingConfirmation;

    const options: zettide.v3.linux_pool_plan.Options = .{
        .protection = protection,
        .label = label,
        .name_profile = name_profile,
        .data_mode = .blob,
        .scheduled_blob = scheduled_blob,
    };
    if (planning) {
        var plan = try zettide.v3.linux_pool_plan.inspect(io, allocator, paths[0..path_count], options);
        defer plan.deinit();
        try printPoolPlan(&plan, stdout);
        if (!plan.ready()) return;
        var token_buffer: [64]u8 = undefined;
        const token = zettide.v3.linux_pool_plan.formatToken(plan.token, &token_buffer);
        try stdout.print("Confirm token: {s}\n", .{token});
        return;
    }

    var acquired = try zettide.v3.linux_pool_plan.acquireCurrent(io, allocator, paths[0..path_count], options);
    defer acquired.deinit();
    try printPoolPlan(&acquired.plan, stdout);
    if (!acquired.plan.ready()) return error.PlanNotReady;
    var token_buffer: [64]u8 = undefined;
    const token = zettide.v3.linux_pool_plan.formatToken(acquired.plan.token, &token_buffer);
    if (!std.mem.eql(u8, confirmation.?, token)) return error.ConfirmationMismatch;

    const storages = acquired.takeStorages();
    defer allocator.free(storages);
    const outcome = try zettide.v3.pool_provision.create(io, allocator, storages, .{
        .protection = protection,
        .data_mode = .blob,
        .label = label,
        .scheduled_blob = scheduled_blob,
    });
    switch (outcome) {
        .complete => |value| {
            var provisioned = value;
            defer provisioned.deinit();
            const pool_id = provisioned.genesis.topology.set_id;
            const owner = common.currentOwner();
            var native = zettide.filesystem_target.formatProvisionedBlobPool(
                allocator,
                io,
                &provisioned,
                name_profile,
                .{ .root_uid = owner.uid, .root_gid = owner.gid },
            ) catch |cause| {
                try stdout.print("Blob initialization failed for Pool ID {x}: {s}\n", .{ pool_id, @errorName(cause) });
                try stdout.flush();
                return cause;
            };
            native.close(io) catch |cause| {
                try stdout.print("Blob initialization failed for Pool ID {x}: {s}\n", .{ pool_id, @errorName(cause) });
                try stdout.flush();
                return cause;
            };
            try stdout.print("Created pool: {x}\n", .{pool_id});
        },
        .partial => |partial| {
            try stdout.print("Partial pool: {x}\n", .{partial.set_id});
            try stdout.print("Completed members: {d}\n", .{partial.completed_member_count});
            try stdout.print("Failed member: {d} ({s})\n", .{ partial.failed_member_index, @errorName(partial.cause) });
            try stdout.flush();
            return error.PartialPoolCreation;
        },
    }
}

fn poolInspectCommand(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    stdout: *Io.Writer,
) !void {
    var paths: [zettide.v3.pool_topology.max_member_count][]const u8 = undefined;
    var path_count: usize = 0;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--device")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            if (path_count == paths.len) return error.TooManyDevices;
            paths[path_count] = args[index];
            path_count += 1;
        } else {
            return error.UnknownOption;
        }
    }
    if (path_count == 0) return error.InvalidMemberCount;

    var set = try openRawPoolSet(allocator, io, paths[0..path_count], false, false, .read_only);
    defer set.deinit();
    const authority = set.authority() orelse return error.MissingAuthority;
    const data_mode = try set.dataMode();
    var statuses: [zettide.v3.pool_topology.max_member_count]zettide.v3.pool_member_set.MemberStatus = undefined;
    for (statuses[0..path_count], 0..) |*status, member_index|
        status.* = try set.statusAt(member_index);
    try stdout.print("Pool: {x}\n", .{authority.topology.set_id});
    try stdout.print("Data mode: {s}\n", .{@tagName(data_mode)});
    try stdout.print("Authority: {s}\n", .{@tagName(authority.kind)});
    try stdout.print("Generation: {d}\n", .{authority.generation});
    try stdout.print("Topology epoch: {d}\n", .{authority.topology.epoch});
    try stdout.print("Layout epoch: {d}\n", .{authority.layout.layout_epoch});
    try stdout.print("Profile: {s}\n", .{if (authority.layout.scheduled_blob != null)
        "scheduled-replicated"
    else
        @tagName(authority.layout.kind)});
    try stdout.print("Members: {d}/{d}\n", .{ path_count, authority.topology.member_count });
    try stdout.print("Data policy: {s}\n", .{@tagName(set.dataAccess())});
    const mountable = switch (data_mode) {
        .blob => mountable: {
            var native = zettide.filesystem_target.openBlobPoolFilesystem(
                allocator,
                io,
                &set,
                false,
            ) catch break :mountable false;
            native.close(io) catch break :mountable false;
            break :mountable true;
        },
        .catalog, .legacy_unsupported => false,
    };
    try stdout.print("Mountable: {s}\n", .{if (mountable) "yes" else "no"});
    for (paths[0..path_count], 0..) |path, member_index| {
        try stdout.print("Member: {s} ({s})\n", .{ path, memberStatusName(statuses[member_index]) });
    }
}

fn poolMountCommand(
    _: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    stdout: *Io.Writer,
) !void {
    if (args.len == 0) return error.MissingMountpoint;
    const mountpoint = args[0];
    var paths: [zettide.v3.pool_topology.max_member_count][]const u8 = undefined;
    var path_count: usize = 0;
    var writable = true;
    var allow_other = false;
    var metrics = false;
    var update_access_time = true;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--device")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            if (path_count == paths.len) return error.TooManyDevices;
            paths[path_count] = args[index];
            path_count += 1;
        } else if (std.mem.eql(u8, args[index], "--read-only")) {
            writable = false;
        } else if (std.mem.eql(u8, args[index], "--allow-other")) {
            allow_other = true;
        } else if (std.mem.eql(u8, args[index], "--metrics")) {
            metrics = true;
        } else if (std.mem.eql(u8, args[index], "--noatime")) {
            update_access_time = false;
        } else {
            return error.UnknownOption;
        }
    }
    if (path_count == 0) return error.InvalidMemberCount;

    const intent: zettide.v3.pool_member_set.OpenIntent = if (writable) .writable else .read_only;
    const pool_allocator = std.heap.c_allocator;
    var set = try openRawPoolSet(pool_allocator, io, paths[0..path_count], writable, true, intent);
    defer set.deinit();
    const detected_data_mode = try set.dataMode();
    switch (detected_data_mode) {
        .catalog => return error.CatalogPoolUnsupported,
        .legacy_unsupported => return error.LegacyPoolDataModeUnsupported,
        .blob => {},
    }
    {
        var native = try zettide.filesystem_target.openBlobPoolFilesystem(
            pool_allocator,
            io,
            &set,
            writable,
        );
        var native_open = true;
        defer if (native_open) native.close(io) catch {};
        var adapter = zettide.blob_filesystem_adapter.Adapter.init(&native, io);
        if (metrics) native.blobs.resetTransportStats(io);
        var fuse_metrics: zettide.linux_fuse.Metrics = .{};
        try stdout.print("Mounted pool at {s}; press Ctrl-C to stop\n", .{mountpoint});
        try stdout.flush();
        try zettide.linux_fuse.mount(
            adapter.filesystem(),
            io,
            mountpoint,
            .{
                .allow_other = allow_other,
                .read_only = !writable,
                .update_access_time = update_access_time,
                .async_read_size = if (!update_access_time)
                    zettide.blob_format.allocation_unit
                else
                    null,
                .metrics = if (metrics) &fuse_metrics else null,
            },
        );
        if (metrics) {
            try common.printFuseMetrics(stdout, fuse_metrics);
            try common.printPoolTransportMetrics(stdout, native.blobs.transportStats(io));
            try stdout.flush();
        }
        native_open = false;
        try native.close(io);
        return;
    }
}

fn openRawPoolSet(
    allocator: std.mem.Allocator,
    io: Io,
    paths: []const []const u8,
    writable: bool,
    exclusive: bool,
    intent: zettide.v3.pool_member_set.OpenIntent,
) !zettide.v3.pool_member_set.PoolMemberSet {
    if (paths.len == 0) return error.InvalidMemberCount;
    const storages = try allocator.alloc(zettide.v3.storage.Storage, paths.len);
    defer allocator.free(storages);
    var opened_count: usize = 0;
    errdefer for (storages[0..opened_count]) |*storage| storage.close(io) catch {};
    var device_ids: [zettide.v3.pool_topology.max_member_count]zettide.v3.linux_block_device.DeviceId = undefined;
    for (paths, 0..) |path, member_index| {
        const opened = try zettide.v3.linux_block_device.openStorageOptions(
            io,
            allocator,
            path,
            writable,
            exclusive,
        );
        for (device_ids[0..member_index]) |previous| {
            if (zettide.v3.linux_block_device.DeviceId.eql(previous, opened.info.id)) {
                var duplicate = opened.storage;
                duplicate.close(io) catch {};
                return error.DuplicateDevice;
            }
        }
        device_ids[member_index] = opened.info.id;
        storages[member_index] = opened.storage;
        opened_count += 1;
    }
    // PoolMemberSet consumes every supplied storage on both success and failure.
    opened_count = 0;
    return zettide.v3.pool_member_set.openStorages(io, allocator, storages, intent);
}

fn memberStatusName(status: zettide.v3.pool_member_set.MemberStatus) []const u8 {
    return switch (status) {
        .absent => "absent",
        .open_failed => "open-failed",
        .scan_failed => "scan-failed",
        .legacy => "legacy",
        .removed => "removed",
        .stale => "stale",
        .catalog_failed => "catalog-failed",
        .authority => "authority",
        .active_voter => "active-voter",
    };
}

fn printPoolPlan(plan: *const zettide.v3.linux_pool_plan.Plan, stdout: *Io.Writer) !void {
    for (plan.paths, plan.devices, plan.contains_data) |path, device, has_data| {
        try stdout.print("Device: {s} ({d}:{d}, sequence {d}, {Bi:.2})\n", .{
            path,
            device.id.major,
            device.id.minor,
            device.disk_sequence,
            device.capacity_bytes,
        });
        try stdout.print("Status: {s}\n", .{
            if (!device.preflightEligible())
                "rejected"
            else if (has_data)
                "contains data"
            else if (!zettide.v3.linux_pool_plan.deviceReadyForDataMode(device, plan.options.data_mode))
                "unsupported geometry"
            else
                "ready",
        });
    }
    try stdout.print("Profile: {s}\n", .{if (plan.options.scheduled_blob)
        "scheduled-replicated"
    else
        @tagName(std.meta.activeTag(plan.options.protection))});
    if (plan.options.scheduled_blob)
        try stdout.print("Devices: {d}\n", .{plan.paths.len});
    try stdout.print("Data mode: {s}\n", .{@tagName(plan.options.data_mode)});
    try stdout.print("Name profile: {s}\n", .{plan.options.name_profile.name()});
    try stdout.print("Plan: {s}\n", .{if (plan.ready()) "ready" else "rejected"});
}
