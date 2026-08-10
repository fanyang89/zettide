const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");
const build_options = @import("build_options");

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
    try requireBlobPath(io, path);
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

fn poolCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
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
            const owner = currentOwner();
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
            try printFuseMetrics(stdout, fuse_metrics);
            try printPoolTransportMetrics(stdout, native.blobs.transportStats(io));
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
    try requireBlobPath(io, args[0]);
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
        try printFuseMetrics(stdout, fuse_metrics);
        try stdout.flush();
    }
}

fn printFuseMetrics(writer: *Io.Writer, metrics: zettide.linux_fuse.Metrics) !void {
    try writer.print(
        "fuse_metrics read_calls={} read_bytes={} read_errors={} read_elapsed_ns={} read_max_ns={} write_calls={} write_bytes={} write_errors={} write_elapsed_ns={} write_max_ns={} flush_calls={} flush_errors={} flush_elapsed_ns={} flush_max_ns={} fsync_calls={} fsync_errors={} fsync_elapsed_ns={} fsync_max_ns={} release_calls={} release_errors={} release_elapsed_ns={} release_max_ns={}\n",
        .{
            metrics.read.calls,
            metrics.read.bytes,
            metrics.read.errors,
            metrics.read.elapsed_ns,
            metrics.read.max_ns,
            metrics.write.calls,
            metrics.write.bytes,
            metrics.write.errors,
            metrics.write.elapsed_ns,
            metrics.write.max_ns,
            metrics.flush.calls,
            metrics.flush.errors,
            metrics.flush.elapsed_ns,
            metrics.flush.max_ns,
            metrics.fsync.calls,
            metrics.fsync.errors,
            metrics.fsync.elapsed_ns,
            metrics.fsync.max_ns,
            metrics.release.calls,
            metrics.release.errors,
            metrics.release.elapsed_ns,
            metrics.release.max_ns,
        },
    );
}

fn printPoolTransportMetrics(writer: *Io.Writer, stats: zettide.v3.storage.TransportStats) !void {
    try writer.print(
        "pool_transport_metrics queue_capacity={} submitted_sqes={} submit_calls={} completions={} current_inflight={} max_inflight={}\n",
        .{
            stats.queue_capacity,
            stats.submitted_sqes,
            stats.submit_calls,
            stats.completions,
            stats.current_inflight,
            stats.max_inflight,
        },
    );
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
    const owner = currentOwner();
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

fn currentOwner() struct { uid: u32, gid: u32 } {
    if (comptime @import("builtin").os.tag == .linux) return .{
        .uid = @intCast(std.os.linux.getuid()),
        .gid = @intCast(std.os.linux.getgid()),
    };
    return .{ .uid = 0, .gid = 0 };
}

fn requireBlobPath(io: Io, path: []const u8) !void {
    switch (try zettide.filesystem_target.classifyPath(io, path)) {
        .blob => {},
        .littlefs_container => return error.UnsupportedLegacyFormat,
        .pool_member => return error.PoolTargetRequiresPoolCommand,
        .unknown => return error.UnsupportedFilesystemFormat,
    }
}

fn infoCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    try requireBlobPath(io, args[0]);
    var filesystem = try zettide.filesystem_target.openBlobFilesystem(allocator, io, args[0], false);
    defer filesystem.close(io) catch {};
    const header = filesystem.blobs.header;
    try stdout.print("Path: {s}\n", .{args[0]});
    try stdout.writeAll("Data mode: blob\nUUID: ");
    try printUuid(stdout, header.uuid);
    try stdout.print("\nCapacity: {Bi:.2}\n", .{header.device_size});
    try stdout.print("Block size: {d}\n", .{zettide.blob_format.allocation_unit});
    try stdout.print("Blocks: {d}\n", .{header.unit_count});
    try stdout.print("Name profile: {s}\n", .{filesystem.root.name_profile.name()});
    try stdout.writeAll("Case-sensitive: yes\n");
}

fn checkCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    try requireBlobPath(io, args[0]);
    var filesystem = try zettide.filesystem_target.openBlobFilesystem(allocator, io, args[0], false);
    defer filesystem.close(io) catch {};
    try stdout.print("Filesystem traversal succeeded: {d} records\n", .{filesystem.root.record_count});
}

fn printUuid(writer: *Io.Writer, uuid: [16]u8) !void {
    for (uuid, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) try writer.writeByte('-');
        try writer.print("{x:0>2}", .{byte});
    }
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
