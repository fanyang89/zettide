const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");

const PoolProfile = enum {
    replicated,
    unprotected,

    fn parse(value: []const u8) !PoolProfile {
        if (std.mem.eql(u8, value, "replicated")) return .replicated;
        if (std.mem.eql(u8, value, "unprotected")) return .unprotected;
        return error.InvalidProfile;
    }
};

pub fn command(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (@import("builtin").os.tag != .linux) return error.RawPoolNotImplemented;
    if (args.len == 0) return error.InvalidArguments;
    const operation = args[0];
    if (std.mem.eql(u8, operation, "inspect"))
        return poolInspectCommand(allocator, io, args[1..], stdout);
    const planning = std.mem.eql(u8, operation, "plan-create");
    const creating = std.mem.eql(u8, operation, "create");
    if (!planning and !creating) return error.InvalidArguments;

    var paths: [zettide.v3.pool_topology.max_member_count][]const u8 = undefined;
    var path_count: usize = 0;
    var profile: PoolProfile = .replicated;
    var label: []const u8 = "Zettide";
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
        } else if (std.mem.eql(u8, option, "--confirm")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            if (confirmation != null) return error.DuplicateOption;
            confirmation = args[index];
        } else {
            return error.UnknownOption;
        }
    }
    const protection: zettide.v3.pool_policy.Protection = switch (profile) {
        .replicated => .replicated,
        .unprotected => .unprotected,
    };
    if (planning and confirmation != null) return error.UnknownOption;
    if (creating and confirmation == null) return error.MissingConfirmation;

    const options: zettide.v3.linux_pool_plan.Options = .{
        .protection = protection,
        .label = label,
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
        .data_mode = .catalog,
        .label = label,
    });
    switch (outcome) {
        .complete => |value| {
            var provisioned = value;
            defer provisioned.deinit();
            const pool_id = provisioned.genesis.topology.set_id;
            try provisioned.close();
            try stdout.print("Created pool: {x}\nData mode: catalog\nCatalog: uninitialized\n", .{pool_id});
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

fn poolInspectCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
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

    var set = try openRawPoolSet(allocator, io, paths[0..path_count]);
    defer set.deinit();
    const authority = set.authority() orelse return error.MissingAuthority;
    const data_mode = try set.dataMode();
    try stdout.print("Pool: {x}\n", .{authority.topology.set_id});
    try stdout.print("Data mode: {s}\n", .{@tagName(data_mode)});
    try stdout.print("Authority: {s}\n", .{@tagName(authority.kind)});
    try stdout.print("Generation: {d}\n", .{authority.generation});
    try stdout.print("Topology epoch: {d}\n", .{authority.topology.epoch});
    try stdout.print("Layout epoch: {d}\n", .{authority.layout.layout_epoch});
    try stdout.print("Profile: {s}\n", .{@tagName(authority.layout.kind)});
    try stdout.print("Members: {d}/{d}\n", .{ path_count, authority.topology.member_count });
    try stdout.print("Data policy: {s}\n", .{@tagName(set.dataAccess())});
    try stdout.print("Catalog: {s}\n", .{if (data_mode != .catalog)
        "unsupported data mode"
    else if (authority.generation == 0)
        "uninitialized"
    else
        "committed"});
    for (paths[0..path_count], 0..) |path, member_index| {
        try stdout.print("Member: {s} ({s})\n", .{ path, @tagName(try set.statusAt(member_index)) });
    }
}

fn openRawPoolSet(allocator: std.mem.Allocator, io: Io, paths: []const []const u8) !zettide.v3.pool_member_set.PoolMemberSet {
    const storages = try allocator.alloc(zettide.v3.storage.Storage, paths.len);
    defer allocator.free(storages);
    var opened_count: usize = 0;
    errdefer for (storages[0..opened_count]) |*storage| storage.close(io) catch {};
    var device_ids: [zettide.v3.pool_topology.max_member_count]zettide.v3.linux_block_device.DeviceId = undefined;
    for (paths, 0..) |path, member_index| {
        const opened = try zettide.v3.linux_block_device.openStorageOptions(io, allocator, path, false, false);
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
    return zettide.v3.pool_member_set.openStorages(io, allocator, storages, .read_only);
}

fn printPoolPlan(plan: *const zettide.v3.linux_pool_plan.Plan, stdout: *Io.Writer) !void {
    for (plan.paths, plan.devices, plan.contains_data) |path, device, has_data| {
        try stdout.print("Device: {s} ({d}:{d}, sequence {d}, {Bi:.2})\n", .{
            path, device.id.major, device.id.minor, device.disk_sequence, device.capacity_bytes,
        });
        try stdout.print("Status: {s}\n", .{if (!device.preflightEligible())
            "rejected"
        else if (has_data)
            "contains data"
        else if (!zettide.v3.linux_pool_plan.deviceReadyForDataMode(device, plan.options.data_mode))
            "unsupported geometry"
        else
            "ready"});
    }
    try stdout.print("Profile: {s}\n", .{@tagName(std.meta.activeTag(plan.options.protection))});
    try stdout.print("Data mode: {s}\n", .{@tagName(plan.options.data_mode)});
    try stdout.print("Plan: {s}\n", .{if (plan.ready()) "ready" else "rejected"});
}
