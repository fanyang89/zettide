const std = @import("std");
const Io = std.Io;
const devdrive = @import("devdrive");

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
    } else {
        try stdout.print("Unknown command: {s}\n\n", .{command});
        try usage(stdout);
        return error.InvalidCommand;
    }
}

fn mountCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 2) return error.InvalidArguments;
    if (@import("builtin").os.tag != .linux) return error.MountNotImplemented;
    var volume = try devdrive.volume.Volume.open(io, args[0], true);
    defer volume.deinit();
    volume.setFallbackOwner(@intCast(std.os.linux.getuid()), @intCast(std.os.linux.getgid()));
    try volume.mount();
    try stdout.print("Mounted {s} at {s}; press Ctrl-C to stop\n", .{ args[0], args[1] });
    try stdout.flush();
    try devdrive.linux_fuse.mount(&volume, args[1]);
}

fn unmountCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    if (@import("builtin").os.tag != .linux) return error.UnmountNotImplemented;
    try devdrive.linux_fuse.unmount(allocator, io, args[0]);
    try stdout.print("Unmounted {s}\n", .{args[0]});
}

fn createCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0) return error.MissingContainerPath;
    const path = args[0];
    var size: ?u64 = null;
    var label: []const u8 = "DevDrive";
    var index: usize = 1;
    while (index < args.len) {
        const option = args[index];
        if (std.mem.eql(u8, option, "--size")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            size = try devdrive.size.parse(args[index]);
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
    try devdrive.volume.Volume.create(io, path, logical_size, label);
    try stdout.print("Created {s} ({Bi:.2})\n", .{ path, logical_size });
}

fn infoCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    var volume = try devdrive.volume.Volume.open(io, args[0], false);
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
    try stdout.print("Maximum file size: {Bi:.2}\n", .{volume.header.file_max});
    try stdout.writeAll("Case-sensitive: yes\nEncrypted: no\n");
}

fn checkCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    var volume = try devdrive.volume.Volume.open(io, args[0], false);
    defer volume.deinit();
    try volume.mount();
    const result = try volume.check();
    try stdout.print("Filesystem traversal succeeded: {d}/{d} blocks used\n", .{
        result.used_blocks,
        result.total_blocks,
    });
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  devdrive create <container> --size <size> [--label <label>]
        \\  devdrive info <container>
        \\  devdrive check <container>
        \\  devdrive mount <container> <mountpoint>
        \\  devdrive unmount <mountpoint>
        \\
        \\Sizes accept binary suffixes such as 512MiB and 16GiB.
        \\
    );
}
