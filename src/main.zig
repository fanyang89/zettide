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
    } else {
        try stdout.print("Unknown command: {s}\n\n", .{command});
        try usage(stdout);
        return error.InvalidCommand;
    }
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
        \\
        \\Sizes accept binary suffixes such as 512MiB and 16GiB.
        \\
    );
}
