const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");
const build_options = @import("build_options");
const common = @import("cli/common.zig");
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
    if (std.mem.eql(u8, command, "format")) {
        try formatCommand(allocator, init.io, args[2..], stdout);
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
        try pool.command(allocator, init.io, args[2..], stdout);
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
    var update_access_time = true;
    var dufs_args: []const []const u8 = &.{};
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--read-only")) {
            read_only = true;
        } else if (std.mem.eql(u8, args[index], "--noatime")) {
            update_access_time = false;
        } else if (std.mem.eql(u8, args[index], "--")) {
            dufs_args = args[index + 1 ..];
            break;
        } else {
            return error.UnknownOption;
        }
    }
    try common.requireBlobPath(io, path);
    var native = try zettide.filesystem_target.openBlobFilesystem(allocator, io, path, !read_only);
    defer native.close(io) catch {};
    var adapter = zettide.blob_filesystem_adapter.Adapter.init(&native, io);
    return zettide.dufs_server.serve(
        allocator,
        io,
        adapter.filesystem(),
        path,
        read_only,
        update_access_time,
        dufs_args,
        stdout,
    );
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

fn mountCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len < 2) return error.InvalidArguments;
    var allow_other = false;
    var metrics = false;
    var writable = true;
    var update_access_time = true;
    for (args[2..]) |option| {
        if (std.mem.eql(u8, option, "--allow-other")) {
            allow_other = true;
        } else if (std.mem.eql(u8, option, "--metrics")) {
            metrics = true;
        } else if (std.mem.eql(u8, option, "--read-only")) {
            writable = false;
        } else if (std.mem.eql(u8, option, "--noatime")) {
            update_access_time = false;
        } else {
            return error.UnknownOption;
        }
    }
    if (@import("builtin").os.tag != .linux) return error.MountNotImplemented;
    try common.requireBlobPath(io, args[0]);
    const native = try allocator.create(zettide.blob_filesystem.Filesystem);
    defer allocator.destroy(native);
    native.* = try zettide.filesystem_target.openBlobFilesystem(allocator, io, args[0], writable);
    var native_open = true;
    defer if (native_open) native.close(io) catch {};
    const adapter = try allocator.create(zettide.blob_filesystem_adapter.Adapter);
    defer allocator.destroy(adapter);
    adapter.* = .init(native, io);
    var fuse_metrics: zettide.linux_fuse.Metrics = .{};
    try stdout.print("Mounted {s} at {s}; press Ctrl-C to stop\n", .{ args[0], args[1] });
    try stdout.flush();
    try zettide.linux_fuse.mount(
        adapter.filesystem(),
        io,
        args[1],
        .{
            .allow_other = allow_other,
            .read_only = !writable,
            .update_access_time = update_access_time,
            .metrics = if (metrics) &fuse_metrics else null,
        },
    );
    native_open = false;
    try native.close(io);
    if (metrics) {
        try common.printFuseMetrics(stdout, fuse_metrics);
        try stdout.flush();
    }
}

fn unmountCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    if (@import("builtin").os.tag != .linux) return error.UnmountNotImplemented;
    try zettide.linux_fuse.unmount(allocator, io, args[0]);
    try stdout.print("Unmounted {s}\n", .{args[0]});
}

fn formatCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0) return error.MissingTargetPath;
    const path = args[0];
    var size: ?u64 = null;
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var confirmation: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--size")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            size = try zettide.size.parse(args[index]);
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
    return blobFormatCommand(allocator, io, path, size, name_profile, confirmation, stdout);
}

fn blobFormatCommand(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    size: ?u64,
    name_profile: zettide.name_profile.Profile,
    confirmation: ?[]const u8,
    stdout: *Io.Writer,
) !void {
    const owner = common.currentOwner();
    const format_options: zettide.blob_filesystem.Filesystem.FormatOptions = .{
        .root_uid = owner.uid,
        .root_gid = owner.gid,
    };
    if (confirmation) |supplied| {
        var acquired = zettide.filesystem_target.acquireBlobFormat(
            io,
            allocator,
            path,
            name_profile,
            format_options,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.UnexpectedConfirmation,
            else => return err,
        };
        defer acquired.deinit();
        try printBlobFormatPlan(&acquired.plan, stdout);
        if (size != null) return error.SizeOnlyValidForNewFile;
        try acquired.apply(allocator, supplied, name_profile, format_options);
        try stdout.print("Formatted {s}\n", .{path});
        return;
    }

    const plan = zettide.filesystem_target.inspectBlobFormat(
        io,
        allocator,
        path,
        name_profile,
        format_options,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            const target_size = size orelse return error.MissingSize;
            try zettide.filesystem_target.formatNewBlobFile(
                io,
                allocator,
                path,
                target_size,
                name_profile,
                format_options,
            );
            try stdout.print("Formatted {s} ({Bi:.2})\n", .{ path, target_size });
            return;
        },
        else => return err,
    };
    if (size != null) return error.SizeOnlyValidForNewFile;
    try printBlobFormatPlan(&plan, stdout);
    var token_buffer: [64]u8 = undefined;
    if (plan.eligible)
        try stdout.print("Confirm token: {s}\n", .{plan.tokenText(&token_buffer)});
}

fn printBlobFormatPlan(plan: *const zettide.filesystem_target.BlobFormatPlan, stdout: *Io.Writer) !void {
    const target_plan = &plan.target_plan;
    try stdout.print("Target: {s}\n", .{target_plan.path});
    try stdout.writeAll("Filesystem: blob\n");
    try stdout.print("Type: {s}\n", .{@tagName(target_plan.kind)});
    try stdout.print("Capacity: {Bi:.2}\n", .{target_plan.capacity_bytes});
    try stdout.print("Contains data: {s}\n", .{if (target_plan.contains_data) "yes" else "no"});
    try stdout.print("Name profile: {s}\n", .{target_plan.name_profile.name()});
    try stdout.print("Plan: {s}\n", .{if (plan.eligible) "ready" else "rejected"});
}

fn infoCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    try common.requireBlobPath(io, args[0]);
    var filesystem = try zettide.filesystem_target.openBlobFilesystem(allocator, io, args[0], false);
    defer filesystem.close(io) catch {};
    const header = filesystem.blobs.header;
    try stdout.print("Path: {s}\n", .{args[0]});
    try stdout.writeAll("Data mode: blob\nUUID: ");
    try common.printUuid(stdout, header.uuid);
    try stdout.print("\nCapacity: {Bi:.2}\n", .{header.device_size});
    try stdout.print("Block size: {d}\n", .{zettide.blob_format.allocation_unit});
    try stdout.print("Blocks: {d}\n", .{header.unit_count});
    try stdout.print("Name profile: {s}\n", .{filesystem.root.name_profile.name()});
    try stdout.writeAll("Case-sensitive: yes\n");
}

fn checkCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    try common.requireBlobPath(io, args[0]);
    var filesystem = try zettide.filesystem_target.openBlobFilesystem(allocator, io, args[0], false);
    defer filesystem.close(io) catch {};
    try stdout.print("Filesystem traversal succeeded: {d} records\n", .{filesystem.root.record_count});
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zettide format <file> [--size <size>] [--name-profile <profile>] [--confirm <token>]
        \\  zettide info <file>
        \\  zettide check <file>
        \\  zettide mount <file> <mountpoint> [--read-only] [--allow-other] [--metrics] [--noatime]
        \\  zettide unmount <mountpoint>
        \\  zettide device inspect <device>
        \\  zettide pool inspect --device <device>...
        \\  zettide pool mount <mountpoint> --device <device>... [--read-only] [--allow-other] [--metrics] [--noatime]
        \\  zettide pool plan-create --device <device>... [--profile replicated|unprotected|scheduled-replicated] [--label <label>] [--name-profile <profile>]
        \\  zettide pool create --device <device>... [--profile replicated|unprotected|scheduled-replicated] [--label <label>] [--name-profile <profile>] --confirm <token>
        \\  zettide serve dufs <file> [--read-only] [--noatime] [-- <dufs-options>...]
        \\  zettide endpoint serve --runtime-dir <dir> [--reactor-mask <mask>] [--pool-member <pool-id> <path>]... [--nvmf-traddr <address> [--nvmf-trsvcid <port>] (--nvmf-host-nqn <nqn>|--nvmf-allow-any-host)] [--nvmf-rdma-traddr <address> [--nvmf-rdma-trsvcid <port>] (--nvmf-rdma-host-nqn <nqn>|--nvmf-rdma-allow-any-host)] [--iscsi-traddr <address> [--iscsi-trsvcid <port>] --iscsi-netmask <cidr> (--iscsi-initiator-name <iqn>|--iscsi-allow-any-initiator)]
        \\
        \\Sizes accept binary suffixes such as 512MiB and 16GiB.
        \\Pool commands require Blob data mode; scheduled-replicated requires 3..12 devices.
        \\Name profiles are legacy-raw and portable-v1; legacy-raw is the default.
        \\
    );
}
