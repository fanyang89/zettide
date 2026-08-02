const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help")) {
        try usage(stdout);
        try stdout.flush();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "format")) {
        try formatCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "create")) {
        try createCommand(init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "info")) {
        try infoCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "check")) {
        try checkCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "mount")) {
        try mountCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "unmount")) {
        try unmountCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "device")) {
        try deviceCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "pool")) {
        try poolCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "serve")) {
        try serveCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "endpoint")) {
        try endpointCommand(init.io, args[2..], stdout);
    } else {
        try stdout.print("Unknown command: {s}\n\n", .{command});
        try usage(stdout);
        return error.InvalidCommand;
    }
    try stdout.flush();
}

fn serveCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len < 2 or !std.mem.eql(u8, args[0], "dufs")) return error.InvalidArguments;
    if (@import("builtin").os.tag != .linux) return error.ServeNotImplemented;
    const path = args[1];
    var read_only = false;
    var access_time: zettide.volume.AccessTimePolicy = .relatime;
    var dufs_args: []const []const u8 = &.{};
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--read-only")) {
            read_only = true;
        } else if (std.mem.eql(u8, args[index], "--noatime")) {
            access_time = .noatime;
        } else if (std.mem.eql(u8, args[index], "--")) {
            dufs_args = args[index + 1 ..];
            break;
        } else {
            return error.UnknownOption;
        }
    }
    return zettide.dufs_server.serve(allocator, io, path, read_only, access_time, dufs_args, stdout);
}

fn endpointCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "serve")) return error.InvalidArguments;
    if (comptime @import("builtin").os.tag == .linux and build_options.spdk) {
        return zettide.endpoint_daemon.serve(std.heap.c_allocator, io, args[1..], stdout);
    }
    return error.SpdkSupportNotEnabled;
}

fn poolCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (@import("builtin").os.tag != .linux) return error.RawPoolNotImplemented;
    if (args.len == 0) return error.InvalidArguments;
    const operation = args[0];
    if (std.mem.eql(u8, operation, "inspect"))
        return poolInspectCommand(allocator, io, args[1..], stdout);
    if (std.mem.eql(u8, operation, "mount"))
        return poolMountCommand(allocator, io, args[1..], stdout);
    if (std.mem.eql(u8, operation, "initialize"))
        return poolInitializeCommand(allocator, io, args[1..], stdout);
    const planning = std.mem.eql(u8, operation, "plan-create");
    const creating = std.mem.eql(u8, operation, "create");
    if (!planning and !creating) return error.InvalidArguments;

    var paths: [zettide.v3.pool_topology.max_member_count][]const u8 = undefined;
    var path_count: usize = 0;
    var protection: zettide.v3.pool_policy.Protection = .replicated;
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
            protection = if (std.mem.eql(u8, args[index], "replicated"))
                .replicated
            else if (std.mem.eql(u8, args[index], "unprotected"))
                .unprotected
            else
                return error.InvalidProfile;
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
    if (planning and confirmation != null) return error.UnknownOption;
    if (creating and confirmation == null) return error.MissingConfirmation;

    var plan = try zettide.v3.linux_pool_plan.inspect(io, allocator, paths[0..path_count], .{
        .protection = protection,
        .label = label,
        .name_profile = name_profile,
    });
    defer plan.deinit();
    try printPoolPlan(&plan, stdout);
    if (!plan.ready()) {
        if (creating) return error.PlanNotReady;
        return;
    }
    var token_buffer: [64]u8 = undefined;
    const token = zettide.v3.linux_pool_plan.formatToken(plan.token, &token_buffer);
    if (planning) {
        try stdout.print("Confirm token: {s}\n", .{token});
        return;
    }
    if (!std.mem.eql(u8, confirmation.?, token)) return error.ConfirmationMismatch;

    const storages = try zettide.v3.linux_pool_plan.acquire(&plan, io, allocator);
    defer allocator.free(storages);
    const outcome = try zettide.v3.pool_provision.create(io, allocator, storages, .{
        .protection = protection,
        .label = label,
    });
    switch (outcome) {
        .complete => |value| {
            var provisioned = value;
            defer provisioned.deinit();
            zettide.volume.Volume.initializePoolOptions(io, &provisioned, label, .{
                .name_profile = name_profile,
            }) catch |cause| {
                try stdout.print("Pool created but volume initialization failed: {x} ({s})\n", .{
                    provisioned.genesis.topology.set_id,
                    @errorName(cause),
                });
                try stdout.flush();
                return cause;
            };
            try stdout.print("Created pool: {x}\n", .{provisioned.genesis.topology.set_id});
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
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--device")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            if (path_count == paths.len) return error.TooManyDevices;
            paths[path_count] = args[index];
            path_count += 1;
        } else if (std.mem.eql(u8, args[index], "--name-profile")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            name_profile = try zettide.name_profile.Profile.parse(args[index]);
        } else {
            return error.UnknownOption;
        }
    }
    if (path_count == 0) return error.InvalidMemberCount;

    var set = try openRawPoolSet(allocator, io, paths[0..path_count], false, false, .read_only);
    defer set.deinit();
    const authority = set.authority() orelse return error.MissingAuthority;
    try stdout.print("Pool: {x}\n", .{authority.topology.set_id});
    try stdout.print("Authority: {s}\n", .{@tagName(authority.kind)});
    try stdout.print("Generation: {d}\n", .{authority.generation});
    try stdout.print("Topology epoch: {d}\n", .{authority.topology.epoch});
    try stdout.print("Layout epoch: {d}\n", .{authority.layout.layout_epoch});
    try stdout.print("Profile: {s}\n", .{@tagName(authority.layout.kind)});
    try stdout.print("Members: {d}/{d}\n", .{ path_count, authority.topology.member_count });
    try stdout.print("Data policy: {s}\n", .{@tagName(set.dataAccess())});
    const mountable = zettide.volume.Volume.inspectPoolHeader(io, &set) catch null;
    try stdout.print("Mountable: {s}\n", .{if (mountable != null) "yes" else "no"});
    const can_initialize = zettide.volume.Volume.canInitializePool(io, &set) catch false;
    if (can_initialize) {
        try stdout.print("Initialize name profile: {s}\n", .{name_profile.name()});
        var token_buffer: [96]u8 = undefined;
        try stdout.print("Initialize token: {s}\n", .{
            poolInitializeToken(&token_buffer, authority.topology.set_id, name_profile),
        });
    }
    for (paths[0..path_count], 0..) |path, member_index| {
        try stdout.print("Member: {s} ({s})\n", .{ path, memberStatusName(try set.statusAt(member_index)) });
    }
}

fn poolInitializeCommand(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    stdout: *Io.Writer,
) !void {
    var paths: [zettide.v3.pool_topology.max_member_count][]const u8 = undefined;
    var path_count: usize = 0;
    var label: []const u8 = "Zettide";
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var confirmation: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--device")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            if (path_count == paths.len) return error.TooManyDevices;
            paths[path_count] = args[index];
            path_count += 1;
        } else if (std.mem.eql(u8, args[index], "--label")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            label = args[index];
        } else if (std.mem.eql(u8, args[index], "--name-profile")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            name_profile = try zettide.name_profile.Profile.parse(args[index]);
        } else if (std.mem.eql(u8, args[index], "--confirm")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            if (confirmation != null) return error.DuplicateOption;
            confirmation = args[index];
        } else {
            return error.UnknownOption;
        }
    }
    if (path_count == 0) return error.InvalidMemberCount;
    const supplied_confirmation = confirmation orelse return error.MissingConfirmation;
    var set = try openRawPoolSet(allocator, io, paths[0..path_count], true, true, .writable);
    defer set.deinit();
    const authority = set.authority() orelse return error.MissingAuthority;
    var expected_buffer: [96]u8 = undefined;
    const expected = poolInitializeToken(&expected_buffer, authority.topology.set_id, name_profile);
    if (!std.mem.eql(u8, supplied_confirmation, expected)) return error.ConfirmationMismatch;
    try zettide.volume.Volume.initializePoolSetOptions(io, &set, label, .{
        .name_profile = name_profile,
    });
    try stdout.print("Initialized pool: {x}\n", .{authority.topology.set_id});
}

fn poolMountCommand(
    allocator: std.mem.Allocator,
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
    var access_time: zettide.volume.AccessTimePolicy = .relatime;
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
        } else if (std.mem.eql(u8, args[index], "--noatime")) {
            access_time = .noatime;
        } else {
            return error.UnknownOption;
        }
    }
    if (path_count == 0) return error.InvalidMemberCount;

    const intent: zettide.v3.pool_member_set.OpenIntent = if (writable) .writable else .read_only;
    var set = try openRawPoolSet(allocator, io, paths[0..path_count], writable, true, intent);
    defer set.deinit();
    var volume = try zettide.volume.Volume.openPool(io, allocator, &set, writable);
    defer volume.deinit();
    volume.setFallbackOwner(@intCast(std.os.linux.getuid()), @intCast(std.os.linux.getgid()));
    try volume.mountOptions(.{ .access_time = access_time });
    try stdout.print("Mounted pool at {s}; press Ctrl-C to stop\n", .{mountpoint});
    try stdout.flush();
    try zettide.linux_fuse.mount(&volume, mountpoint, allow_other, !writable);
    try volume.close();
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

fn poolInitializeToken(
    buffer: *[96]u8,
    set_id: [16]u8,
    name_profile: zettide.name_profile.Profile,
) []const u8 {
    return if (name_profile == .legacy_raw)
        std.fmt.bufPrint(buffer, "initialize-empty-volume:{x}", .{set_id}) catch unreachable
    else
        std.fmt.bufPrint(buffer, "initialize-empty-volume:{x}:{s}", .{
            set_id,
            name_profile.name(),
        }) catch unreachable;
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
            else if (!zettide.v3.linux_pool_plan.deviceReady(device))
                "unsupported geometry"
            else
                "ready",
        });
    }
    try stdout.print("Name profile: {s}\n", .{plan.options.name_profile.name()});
    try stdout.print("Plan: {s}\n", .{if (plan.ready()) "ready" else "rejected"});
}

fn deviceCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "inspect")) return error.InvalidArguments;
    if (@import("builtin").os.tag != .linux) return error.DeviceInspectionNotImplemented;
    const path = args[1];
    const info = try zettide.v3.linux_block_device.inspect(io, allocator, path);
    try stdout.print("Path: {s}\n", .{path});
    try stdout.print("Device: {d}:{d}\n", .{ info.id.major, info.id.minor });
    try stdout.print("Capacity: {Bi:.2}\n", .{info.capacity_bytes});
    try stdout.print("Logical sector: {d}\n", .{info.logical_sector_size});
    try stdout.print("Preflight: {s}\n", .{if (info.preflightEligible()) "eligible" else "rejected"});
    if (!info.preflightEligible()) {
        try stdout.writeAll("Reasons:");
        if (info.eligibility.partition) try stdout.writeAll(" partition");
        if (info.eligibility.read_only) try stdout.writeAll(" read-only");
        if (info.eligibility.mounted) try stdout.writeAll(" mounted");
        if (info.eligibility.swap) try stdout.writeAll(" swap");
        if (info.eligibility.held) try stdout.writeAll(" held");
        try stdout.writeByte('\n');
    }
}

fn mountCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len < 2) return error.InvalidArguments;
    var allow_other = false;
    var access_time: zettide.volume.AccessTimePolicy = .relatime;
    for (args[2..]) |option| {
        if (std.mem.eql(u8, option, "--allow-other")) {
            allow_other = true;
        } else if (std.mem.eql(u8, option, "--noatime")) {
            access_time = .noatime;
        } else {
            return error.UnknownOption;
        }
    }
    if (@import("builtin").os.tag != .linux) return error.MountNotImplemented;
    const volume = try allocator.create(zettide.volume.Volume);
    defer allocator.destroy(volume);
    try zettide.target.openVolumeInto(volume, io, allocator, args[0], true);
    defer volume.deinit();
    volume.setFallbackOwner(@intCast(std.os.linux.getuid()), @intCast(std.os.linux.getgid()));
    try volume.mountOptions(.{ .access_time = access_time });
    try stdout.print("Mounted {s} at {s}; press Ctrl-C to stop\n", .{ args[0], args[1] });
    try stdout.flush();
    try zettide.linux_fuse.mount(volume, args[1], allow_other, false);
    try volume.close();
}

fn unmountCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    if (@import("builtin").os.tag != .linux) return error.UnmountNotImplemented;
    try zettide.linux_fuse.unmount(allocator, io, args[0]);
    try stdout.print("Unmounted {s}\n", .{args[0]});
}

fn createCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0) return error.MissingContainerPath;
    const path = args[0];
    var size: ?u64 = null;
    var label: []const u8 = "Zettide";
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var index: usize = 1;
    while (index < args.len) {
        const option = args[index];
        if (std.mem.eql(u8, option, "--size")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            size = try zettide.size.parse(args[index]);
        } else if (std.mem.eql(u8, option, "--label")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            label = args[index];
        } else if (std.mem.eql(u8, option, "--name-profile")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            name_profile = try zettide.name_profile.Profile.parse(args[index]);
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }

    const logical_size = size orelse return error.MissingSize;
    try zettide.volume.Volume.createOptions(io, path, logical_size, label, .{
        .name_profile = name_profile,
    });
    try stdout.print("Created {s} ({Bi:.2})\n", .{ path, logical_size });
}

fn formatCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0) return error.MissingTargetPath;
    const path = args[0];
    var size: ?u64 = null;
    var label: []const u8 = "Zettide";
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var confirmation: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--size")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            size = try zettide.size.parse(args[index]);
        } else if (std.mem.eql(u8, args[index], "--label")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            label = args[index];
        } else if (std.mem.eql(u8, args[index], "--name-profile")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            name_profile = try zettide.name_profile.Profile.parse(args[index]);
        } else if (std.mem.eql(u8, args[index], "--confirm")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            confirmation = args[index];
        } else {
            return error.UnknownOption;
        }
    }

    const plan = zettide.target.inspectFormatOptions(io, allocator, path, label, .{
        .name_profile = name_profile,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            if (confirmation != null) return error.UnexpectedConfirmation;
            const target_size = size orelse return error.MissingSize;
            const result = try zettide.target.formatNewFileOptions(io, allocator, path, target_size, label, .{
                .name_profile = name_profile,
            });
            try finishFormat(result, path, target_size, stdout);
            return;
        },
        else => return err,
    };
    if (size != null) return error.SizeOnlyValidForNewFile;
    try stdout.print("Target: {s}\n", .{path});
    try stdout.print("Type: {s}\n", .{@tagName(plan.kind)});
    try stdout.print("Capacity: {Bi:.2}\n", .{plan.capacity_bytes});
    try stdout.print("Contains data: {s}\n", .{if (plan.contains_data) "yes" else "no"});
    try stdout.print("Name profile: {s}\n", .{plan.name_profile.name()});
    try stdout.print("Plan: {s}\n", .{if (plan.eligible) "ready" else "rejected"});
    var token_buffer: [64]u8 = undefined;
    if (confirmation) |supplied| {
        const result = try zettide.target.applyFormat(io, allocator, &plan, supplied);
        try finishFormat(result, path, null, stdout);
    } else if (plan.eligible) {
        try stdout.print("Confirm token: {s}\n", .{plan.tokenText(&token_buffer)});
    }
}

fn finishFormat(
    result: zettide.target.FormatResult,
    path: []const u8,
    size: ?u64,
    stdout: *Io.Writer,
) !void {
    switch (result) {
        .complete => if (size) |value|
            try stdout.print("Formatted {s} ({Bi:.2})\n", .{ path, value })
        else
            try stdout.print("Formatted {s}\n", .{path}),
        .pool_created => |failure| {
            try stdout.print("Pool {x} created but volume initialization failed: {s}\n", .{
                failure.set_id,
                @errorName(failure.cause),
            });
            try stdout.flush();
            return failure.cause;
        },
        .partial => |failure| {
            try stdout.print("Partial format {x}: member {d} failed after {d} completed ({s})\n", .{
                failure.set_id,
                failure.failed_member_index,
                failure.completed_member_count,
                @errorName(failure.cause),
            });
            try stdout.flush();
            return error.PartialTargetFormat;
        },
    }
}

fn infoCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    const volume = try allocator.create(zettide.volume.Volume);
    defer allocator.destroy(volume);
    try zettide.target.openVolumeInto(volume, io, allocator, args[0], false);
    defer volume.deinit();

    try stdout.print("Path: {s}\n", .{args[0]});
    try stdout.print("Label: {s}\n", .{volume.header.labelSlice()});
    try stdout.writeAll("UUID: ");
    for (volume.header.uuid, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) try stdout.writeByte('-');
        try stdout.print("{x:0>2}", .{byte});
    }
    try stdout.print("\nCapacity: {Bi:.2}\n", .{volume.header.logical_size});
    try stdout.print("Block size: {d}\n", .{volume.header.block_size});
    try stdout.print("Blocks: {d}\n", .{volume.header.block_count});
    try stdout.print("Maximum file size: {Bi:.2}\n", .{volume.header.user_file_max});
    try stdout.print("Name profile: {s}\n", .{volume.header.name_profile.name()});
    try stdout.writeAll("Case-sensitive: yes\nEncrypted: no\n");
    try volume.close();
}

fn checkCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    const volume = try allocator.create(zettide.volume.Volume);
    defer allocator.destroy(volume);
    try zettide.target.openVolumeInto(volume, io, allocator, args[0], false);
    defer volume.deinit();
    try volume.mount();
    const result = try volume.check();
    try stdout.print("Filesystem traversal succeeded: {d}/{d} blocks used\n", .{
        result.used_blocks,
        result.total_blocks,
    });
    try volume.close();
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zettide format <file|device> [--size <size>] [--label <label>] [--name-profile <profile>] [--confirm <token>]
        \\  zettide create <container> --size <size> [--label <label>] [--name-profile <profile>]
        \\  zettide info <container>
        \\  zettide check <container>
        \\  zettide mount <container> <mountpoint> [--allow-other] [--noatime]
        \\  zettide unmount <mountpoint>
        \\  zettide device inspect <device>
        \\  zettide pool inspect --device <device>... [--name-profile <profile>]
        \\  zettide pool initialize --device <device>... [--label <label>] [--name-profile <profile>] --confirm <token>
        \\  zettide pool mount <mountpoint> --device <device>... [--read-only] [--allow-other] [--noatime]
        \\  zettide pool plan-create --device <device>... [--profile replicated|unprotected] [--label <label>] [--name-profile <profile>]
        \\  zettide pool create --device <device>... [--profile replicated|unprotected] [--label <label>] [--name-profile <profile>] --confirm <token>
        \\  zettide serve dufs <file|device> [--read-only] [--noatime] [-- <dufs-options>...]
        \\  zettide endpoint serve --runtime-dir <dir> [--reactor-mask <mask>] [--pool-member <pool-id> <path>]...
        \\
        \\Sizes accept binary suffixes such as 512MiB and 16GiB.
        \\Name profiles are legacy-raw and portable-v1; legacy-raw is the default.
        \\
    );
}
