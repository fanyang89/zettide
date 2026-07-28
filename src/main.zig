const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");

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
    if (std.mem.eql(u8, command, "create")) {
        try createCommand(init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "info")) {
        try infoCommand(init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "check")) {
        try checkCommand(init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "mount")) {
        try mountCommand(init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "unmount")) {
        try unmountCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "device")) {
        try deviceCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "pool")) {
        try poolCommand(allocator, init.io, args[2..], stdout);
    } else {
        try stdout.print("Unknown command: {s}\n\n", .{command});
        try usage(stdout);
        return error.InvalidCommand;
    }
    try stdout.flush();
}

fn poolCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (@import("builtin").os.tag != .linux) return error.RawPoolNotImplemented;
    if (args.len == 0) return error.InvalidArguments;
    const operation = args[0];
    const planning = std.mem.eql(u8, operation, "plan-create");
    const creating = std.mem.eql(u8, operation, "create");
    if (!planning and !creating) return error.InvalidArguments;

    var paths: [zettide.v3.pool_topology.max_member_count][]const u8 = undefined;
    var path_count: usize = 0;
    var protection: zettide.v3.pool_policy.Protection = .replicated;
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

fn mountCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len < 2 or args.len > 3) return error.InvalidArguments;
    const allow_other = args.len == 3 and std.mem.eql(u8, args[2], "--allow-other");
    if (args.len == 3 and !allow_other) return error.UnknownOption;
    if (@import("builtin").os.tag != .linux) return error.MountNotImplemented;
    var volume = try zettide.volume.Volume.open(io, args[0], true);
    defer volume.deinit();
    volume.setFallbackOwner(@intCast(std.os.linux.getuid()), @intCast(std.os.linux.getgid()));
    try volume.mount();
    try stdout.print("Mounted {s} at {s}; press Ctrl-C to stop\n", .{ args[0], args[1] });
    try stdout.flush();
    try zettide.linux_fuse.mount(&volume, args[1], allow_other);
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
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }

    const logical_size = size orelse return error.MissingSize;
    try zettide.volume.Volume.create(io, path, logical_size, label);
    try stdout.print("Created {s} ({Bi:.2})\n", .{ path, logical_size });
}

fn infoCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    var volume = try zettide.volume.Volume.open(io, args[0], false);
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
    try stdout.writeAll("Case-sensitive: yes\nEncrypted: no\n");
    try volume.close();
}

fn checkCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    var volume = try zettide.volume.Volume.open(io, args[0], false);
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
        \\  zettide create <container> --size <size> [--label <label>]
        \\  zettide info <container>
        \\  zettide check <container>
        \\  zettide mount <container> <mountpoint> [--allow-other]
        \\  zettide unmount <mountpoint>
        \\  zettide device inspect <device>
        \\  zettide pool plan-create --device <device>... [--profile replicated|unprotected] [--label <label>]
        \\  zettide pool create --device <device>... [--profile replicated|unprotected] [--label <label>] --confirm <token>
        \\
        \\Sizes accept binary suffixes such as 512MiB and 16GiB.
        \\
    );
}
