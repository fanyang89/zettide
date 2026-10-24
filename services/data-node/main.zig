const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");
const build_options = @import("build_options");
const pool = @import("cli/pool.zig");

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
    if (std.mem.eql(u8, command, "device")) {
        try deviceCommand(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "pool")) {
        try pool.command(allocator, init.io, args[2..], stdout);
    } else if (std.mem.eql(u8, command, "endpoint")) {
        try endpointCommand(init.io, args[2..], stdout);
    } else {
        try stdout.print("Unknown command: {s}\n\n", .{command});
        try usage(stdout);
        return error.InvalidCommand;
    }
    try stdout.flush();
}

fn endpointCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "serve")) return error.InvalidArguments;
    if (comptime @import("builtin").os.tag == .linux and build_options.spdk) {
        return zettide.endpoint_daemon.serve(std.heap.c_allocator, io, args[1..], stdout);
    }
    return error.SpdkSupportNotEnabled;
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

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zettide device inspect <device>
        \\  zettide pool inspect --device <device>...
        \\  zettide pool plan-create --device <device>... [--profile replicated|unprotected] [--label <label>]
        \\  zettide pool create --device <device>... [--profile replicated|unprotected] [--label <label>] --confirm <token>
        \\  zettide endpoint serve --runtime-dir <dir> [--reactor-mask <mask>] [--pool-member <pool-id> <path>]... [--nvmf-traddr <address> [--nvmf-trsvcid <port>] (--nvmf-host-nqn <nqn>|--nvmf-allow-any-host)] [--nvmf-rdma-traddr <address> [--nvmf-rdma-trsvcid <port>] (--nvmf-rdma-host-nqn <nqn>|--nvmf-rdma-allow-any-host)] [--iscsi-traddr <address> [--iscsi-trsvcid <port>] --iscsi-netmask <cidr> (--iscsi-initiator-name <iqn>|--iscsi-allow-any-initiator)]
        \\
        \\Pool creation uses Catalog data mode: replicated requires three devices;
        \\unprotected requires one. Creating a Pool does not initialize a Volume.
        \\
    );
}
