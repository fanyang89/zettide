const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");
const build_options = @import("build_options");
const cli_crypto = @import("cli_crypto.zig");

const FilesystemKind = enum {
    littlefs,
    blob,
};

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
    } else if (std.mem.eql(u8, command, "key")) {
        try keyCommand(init.io, args[2..], stdout);
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
    var credential_source: ?cli_crypto.Source = null;
    var dufs_args: []const []const u8 = &.{};
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--read-only")) {
            read_only = true;
        } else if (std.mem.eql(u8, args[index], "--noatime")) {
            access_time = .noatime;
        } else if (std.mem.eql(u8, args[index], "--key-file")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            try setCredentialSource(&credential_source, .{ .key_file = args[index] });
        } else if (std.mem.eql(u8, args[index], "--passphrase")) {
            try setCredentialSource(&credential_source, .passphrase);
        } else if (std.mem.eql(u8, args[index], "--")) {
            dufs_args = args[index + 1 ..];
            break;
        } else {
            return error.UnknownOption;
        }
    }
    if (try zettide.filesystem_target.classifyPath(io, path) == .blob)
        return error.UnsupportedFilesystemBackend;
    var secret: cli_crypto.Secret = undefined;
    var secret_loaded = false;
    if (credential_source) |source| {
        try cli_crypto.loadInto(&secret, io, source, false);
        secret_loaded = true;
    }
    defer if (secret_loaded) secret.deinit();
    const volume = try allocator.create(zettide.volume.Volume);
    defer allocator.destroy(volume);
    try zettide.target.openVolumeIntoOptions(volume, io, allocator, path, !read_only, .{
        .encryption_credential = if (secret_loaded) secret.credential() else null,
    });
    defer volume.deinit();
    if (secret_loaded) {
        secret.deinit();
        secret_loaded = false;
    }
    return zettide.dufs_server.serve(
        allocator,
        io,
        volume,
        path,
        read_only,
        access_time,
        dufs_args,
        stdout,
    );
}

fn keyCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "generate")) return error.InvalidArguments;
    try cli_crypto.generateKeyFile(io, args[1]);
    try stdout.print("Generated key: {s}\n", .{args[1]});
}

fn setCredentialSource(current: *?cli_crypto.Source, source: cli_crypto.Source) !void {
    if (current.* != null) return error.DuplicateEncryptionCredential;
    current.* = source;
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
    var profile: PoolProfile = .replicated;
    var label: []const u8 = "Zettide";
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var filesystem: zettide.v3.member_format.PoolFilesystem = .littlefs;
    var filesystem_explicit = false;
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
        } else if (std.mem.eql(u8, option, "--filesystem")) {
            if (filesystem_explicit) return error.DuplicateOption;
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            filesystem = try parsePoolFilesystem(args[index]);
            filesystem_explicit = true;
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
    if (scheduled_blob) {
        if (filesystem_explicit and filesystem != .blob)
            return error.InvalidScheduledBlobOptions;
        filesystem = .blob;
    }
    if (planning and confirmation != null) return error.UnknownOption;
    if (creating and confirmation == null) return error.MissingConfirmation;

    const options: zettide.v3.linux_pool_plan.Options = .{
        .protection = protection,
        .label = label,
        .name_profile = name_profile,
        .filesystem = filesystem,
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
        .filesystem = filesystem,
        .label = label,
        .scheduled_blob = scheduled_blob,
    });
    switch (outcome) {
        .complete => |value| {
            var provisioned = value;
            defer provisioned.deinit();
            if (filesystem == .blob) {
                const pool_id = provisioned.genesis.topology.set_id;
                const owner = currentOwner();
                var native = zettide.filesystem_target.formatProvisionedBlobPool(
                    allocator,
                    io,
                    &provisioned,
                    name_profile,
                    .{
                        .root_uid = owner.uid,
                        .root_gid = owner.gid,
                    },
                ) catch |cause| {
                    try stdout.print("Blob initialization failed for Pool ID {x}: {s}\n", .{
                        pool_id,
                        @errorName(cause),
                    });
                    try stdout.flush();
                    return cause;
                };
                native.close(io) catch |cause| {
                    try stdout.print("Blob initialization failed for Pool ID {x}: {s}\n", .{
                        pool_id,
                        @errorName(cause),
                    });
                    try stdout.flush();
                    return cause;
                };
                try stdout.print("Created pool: {x}\n", .{pool_id});
                return;
            }
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
    const filesystem = try set.filesystem();
    var statuses: [zettide.v3.pool_topology.max_member_count]zettide.v3.pool_member_set.MemberStatus = undefined;
    for (statuses[0..path_count], 0..) |*status, member_index|
        status.* = try set.statusAt(member_index);
    try stdout.print("Pool: {x}\n", .{authority.topology.set_id});
    try stdout.print("Filesystem: {s}\n", .{@tagName(filesystem)});
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
    const mountable = switch (filesystem) {
        .littlefs => (zettide.volume.Volume.inspectPoolHeader(io, &set) catch null) != null,
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
    };
    try stdout.print("Mountable: {s}\n", .{if (mountable) "yes" else "no"});
    const can_initialize = filesystem == .littlefs and
        (zettide.volume.Volume.canInitializePool(io, &set) catch false);
    if (can_initialize) {
        try stdout.print("Initialize name profile: {s}\n", .{name_profile.name()});
        var token_buffer: [96]u8 = undefined;
        try stdout.print("Initialize token: {s}\n", .{
            poolInitializeToken(&token_buffer, authority.topology.set_id, name_profile),
        });
    }
    for (paths[0..path_count], 0..) |path, member_index| {
        try stdout.print("Member: {s} ({s})\n", .{ path, memberStatusName(statuses[member_index]) });
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
    if (try set.filesystem() == .blob)
        return error.BlobPoolInitializationUnsupported;
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
    var metrics = false;
    var filesystem: ?zettide.v3.member_format.PoolFilesystem = null;
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
        } else if (std.mem.eql(u8, args[index], "--metrics")) {
            metrics = true;
        } else if (std.mem.eql(u8, args[index], "--noatime")) {
            access_time = .noatime;
        } else if (std.mem.eql(u8, args[index], "--filesystem")) {
            if (filesystem != null) return error.DuplicateOption;
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            filesystem = try parsePoolFilesystem(args[index]);
        } else {
            return error.UnknownOption;
        }
    }
    if (path_count == 0) return error.InvalidMemberCount;

    const intent: zettide.v3.pool_member_set.OpenIntent = if (writable) .writable else .read_only;
    const pool_allocator = std.heap.c_allocator;
    var set = try openRawPoolSet(pool_allocator, io, paths[0..path_count], writable, true, intent);
    defer set.deinit();
    const detected_filesystem = try set.filesystem();
    if (filesystem) |selected| {
        if (selected != detected_filesystem) return error.PoolFilesystemMismatch;
    }
    if (detected_filesystem == .blob) {
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
                .update_access_time = access_time == .relatime,
                .async_read_size = if (access_time == .noatime)
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
    var volume = try zettide.volume.Volume.openPool(io, allocator, &set, writable);
    defer volume.deinit();
    volume.setFallbackOwner(@intCast(std.os.linux.getuid()), @intCast(std.os.linux.getgid()));
    try volume.mountOptions(.{ .access_time = .noatime });
    if (metrics) volume.resetPipelineMetrics();
    var fuse_metrics: zettide.linux_fuse.Metrics = .{};
    try stdout.print("Mounted pool at {s}; press Ctrl-C to stop\n", .{mountpoint});
    try stdout.flush();
    try zettide.linux_fuse.mount(
        zettide.littlefs_volume_adapter.filesystem(&volume),
        io,
        mountpoint,
        .{
            .allow_other = allow_other,
            .read_only = !writable,
            .update_access_time = access_time == .relatime,
            .metrics = if (metrics) &fuse_metrics else null,
        },
    );
    if (metrics) {
        try volume.sync();
        try printFuseMetrics(stdout, fuse_metrics);
        try printPipelineMetrics(stdout, volume.pipelineMetrics());
        try stdout.flush();
    }
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
            else if (!zettide.v3.linux_pool_plan.deviceReadyForFilesystem(device, plan.options.filesystem))
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
    try stdout.print("Filesystem: {s}\n", .{@tagName(plan.options.filesystem)});
    try stdout.print("Name profile: {s}\n", .{plan.options.name_profile.name()});
    try stdout.print("Plan: {s}\n", .{if (plan.ready()) "ready" else "rejected"});
}

fn parsePoolFilesystem(value: []const u8) !zettide.v3.member_format.PoolFilesystem {
    if (std.mem.eql(u8, value, "littlefs")) return .littlefs;
    if (std.mem.eql(u8, value, "blob")) return .blob;
    return error.InvalidFilesystem;
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
    var access_time: zettide.volume.AccessTimePolicy = .relatime;
    for (args[2..]) |option| {
        if (std.mem.eql(u8, option, "--allow-other")) {
            allow_other = true;
        } else if (std.mem.eql(u8, option, "--metrics")) {
            metrics = true;
        } else if (std.mem.eql(u8, option, "--read-only")) {
            writable = false;
        } else if (std.mem.eql(u8, option, "--noatime")) {
            access_time = .noatime;
        } else {
            return error.UnknownOption;
        }
    }
    if (@import("builtin").os.tag != .linux) return error.MountNotImplemented;
    if (try zettide.filesystem_target.classifyPath(io, args[0]) == .blob) {
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
                .update_access_time = access_time == .relatime,
                .metrics = if (metrics) &fuse_metrics else null,
            },
        );
        native_open = false;
        try native.close(io);
        if (metrics) {
            try printFuseMetrics(stdout, fuse_metrics);
            try stdout.flush();
        }
        return;
    }
    const volume = try allocator.create(zettide.volume.Volume);
    defer allocator.destroy(volume);
    try zettide.target.openVolumeInto(volume, io, allocator, args[0], writable);
    defer volume.deinit();
    volume.setFallbackOwner(@intCast(std.os.linux.getuid()), @intCast(std.os.linux.getgid()));
    try volume.mountOptions(.{ .access_time = .noatime });
    if (metrics) volume.resetPipelineMetrics();
    var fuse_metrics: zettide.linux_fuse.Metrics = .{};
    try stdout.print("Mounted {s} at {s}; press Ctrl-C to stop\n", .{ args[0], args[1] });
    try stdout.flush();
    try zettide.linux_fuse.mount(
        zettide.littlefs_volume_adapter.filesystem(volume),
        io,
        args[1],
        .{
            .allow_other = allow_other,
            .read_only = !writable,
            .update_access_time = access_time == .relatime,
            .metrics = if (metrics) &fuse_metrics else null,
        },
    );
    if (metrics) {
        try volume.sync();
        try printFuseMetrics(stdout, fuse_metrics);
        try printPipelineMetrics(stdout, volume.pipelineMetrics());
        try stdout.flush();
    }
    try volume.close();
}

fn printPipelineMetrics(writer: *Io.Writer, metrics: zettide.volume.PipelineMetrics) !void {
    const block = metrics.block_device;
    try writer.print(
        "pipeline_metrics logical_read_calls={} logical_read_bytes={} logical_read_elapsed_ns={} logical_read_max_ns={} logical_write_calls={} logical_write_bytes={} logical_write_elapsed_ns={} logical_write_max_ns={} journaled={} littlefs_read_calls={} littlefs_read_bytes={} littlefs_read_elapsed_ns={} littlefs_read_max_ns={} littlefs_program_calls={} littlefs_program_bytes={} littlefs_program_elapsed_ns={} littlefs_program_max_ns={} direct_program_bytes={} redo_transactions={} redo_flushes={} redo_record_bytes={} redo_anchor_bytes={} checkpoints={} checkpoint_home_bytes={} backing_write_bytes={} logical_sync_calls={} backing_sync_calls={} backing_sync_elapsed_ns={} backing_sync_max_ns={}\n",
        .{
            metrics.logical_read_calls,
            metrics.logical_read_bytes,
            metrics.logical_read_elapsed_ns,
            metrics.logical_read_max_ns,
            metrics.logical_write_calls,
            metrics.logical_write_bytes,
            metrics.logical_write_elapsed_ns,
            metrics.logical_write_max_ns,
            metrics.journaled,
            block.littlefs_read_calls,
            block.littlefs_read_bytes,
            block.littlefs_read_elapsed_ns,
            block.littlefs_read_max_ns,
            block.littlefs_program_calls,
            block.littlefs_program_bytes,
            block.littlefs_program_elapsed_ns,
            block.littlefs_program_max_ns,
            block.direct_program_bytes,
            block.redo_transactions,
            block.redo_flushes,
            block.redo_record_bytes,
            block.redo_anchor_bytes,
            block.checkpoints,
            block.checkpoint_home_bytes,
            block.backing_write_bytes,
            block.logical_sync_calls,
            block.backing_sync_calls,
            block.backing_sync_elapsed_ns,
            block.backing_sync_max_ns,
        },
    );
    for (metrics.members[0..metrics.member_count], 0..) |member, index| {
        const stats = member.stats;
        try writer.print(
            "member_transport_metrics index={} kind={s} queue_capacity={} submitted_sqes={} submit_calls={} completions={} current_inflight={} max_inflight={}\n",
            .{
                index,
                @tagName(member.kind),
                stats.queue_capacity,
                stats.submitted_sqes,
                stats.submit_calls,
                stats.completions,
                stats.current_inflight,
                stats.max_inflight,
            },
        );
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

fn createCommand(io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0) return error.MissingContainerPath;
    const path = args[0];
    var size: ?u64 = null;
    var redo_journal_size: ?u64 = null;
    var label: []const u8 = "Zettide";
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var index: usize = 1;
    while (index < args.len) {
        const option = args[index];
        if (std.mem.eql(u8, option, "--size")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            size = try zettide.size.parse(args[index]);
        } else if (std.mem.eql(u8, option, "--redo-journal-size")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            redo_journal_size = try zettide.size.parse(args[index]);
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
        .redo_journal = if (redo_journal_size) |journal_size| .{
            .length = journal_size,
            .max_transaction_blocks = zettide.redo_journal.max_blocks_per_transaction,
        } else null,
    });
    try stdout.print("Created {s} ({Bi:.2})\n", .{ path, logical_size });
}

fn formatCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len == 0) return error.MissingTargetPath;
    const path = args[0];
    var size: ?u64 = null;
    var label: []const u8 = "Zettide";
    var label_explicit = false;
    var filesystem: FilesystemKind = .littlefs;
    var filesystem_explicit = false;
    var name_profile: zettide.name_profile.Profile = .legacy_raw;
    var confirmation: ?[]const u8 = null;
    var encrypt = false;
    var credential_source: ?cli_crypto.Source = null;
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
            label_explicit = true;
        } else if (std.mem.eql(u8, args[index], "--filesystem")) {
            if (filesystem_explicit) return error.DuplicateOption;
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            filesystem = if (std.mem.eql(u8, args[index], "littlefs"))
                .littlefs
            else if (std.mem.eql(u8, args[index], "blob"))
                .blob
            else
                return error.InvalidFilesystem;
            filesystem_explicit = true;
        } else if (std.mem.eql(u8, args[index], "--name-profile")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            name_profile = try zettide.name_profile.Profile.parse(args[index]);
        } else if (std.mem.eql(u8, args[index], "--confirm")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            confirmation = args[index];
        } else if (std.mem.eql(u8, args[index], "--encrypt")) {
            if (encrypt) return error.DuplicateOption;
            encrypt = true;
        } else if (std.mem.eql(u8, args[index], "--key-file")) {
            index += 1;
            if (index == args.len) return error.MissingOptionValue;
            try setCredentialSource(&credential_source, .{ .key_file = args[index] });
        } else if (std.mem.eql(u8, args[index], "--passphrase")) {
            try setCredentialSource(&credential_source, .passphrase);
        } else {
            return error.UnknownOption;
        }
    }
    if (filesystem == .blob) {
        if (label_explicit) return error.BlobLabelNotSupported;
        if (encrypt or credential_source != null) return error.BlobEncryptionNotSupported;
        return blobFormatCommand(allocator, io, path, size, name_profile, confirmation, stdout);
    }
    if (encrypt != (credential_source != null))
        return if (encrypt) error.EncryptionCredentialRequired else error.EncryptionOptionRequiresEncrypt;

    const hint_key: [zettide.volume_crypto.master_key_length]u8 = @splat(0);
    const credential_hint: ?zettide.volume_crypto.Credential = if (credential_source) |source| switch (source) {
        .key_file => .{ .raw_key = &hint_key },
        .passphrase => .{ .argon2id = "" },
    } else null;

    if (confirmation) |supplied| {
        var acquired = zettide.target.acquireFormatOptions(io, allocator, path, label, .{
            .name_profile = name_profile,
            .encryption_credential = credential_hint,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.UnexpectedConfirmation,
            else => return err,
        };
        defer acquired.deinit();
        try printFormatPlan(&acquired.plan, stdout);
        if (size != null) return error.SizeOnlyValidForNewFile;
        var secret: cli_crypto.Secret = undefined;
        var secret_loaded = false;
        if (credential_source) |source| {
            try cli_crypto.loadInto(&secret, io, source, true);
            secret_loaded = true;
        }
        defer if (secret_loaded) secret.deinit();
        const result = try acquired.apply(allocator, supplied, .{
            .name_profile = name_profile,
            .encryption_credential = if (secret_loaded) secret.credential() else null,
        });
        try finishFormat(result, path, null, stdout);
        return;
    }

    const plan = zettide.target.inspectFormatOptions(io, allocator, path, label, .{
        .name_profile = name_profile,
        .encryption_credential = credential_hint,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            const target_size = size orelse return error.MissingSize;
            var secret: cli_crypto.Secret = undefined;
            var secret_loaded = false;
            if (credential_source) |source| {
                try cli_crypto.loadInto(&secret, io, source, true);
                secret_loaded = true;
            }
            defer if (secret_loaded) secret.deinit();
            const result = try zettide.target.formatNewFileOptions(io, allocator, path, target_size, label, .{
                .name_profile = name_profile,
                .encryption_credential = if (secret_loaded) secret.credential() else null,
            });
            try finishFormat(result, path, target_size, stdout);
            return;
        },
        else => return err,
    };
    if (size != null) return error.SizeOnlyValidForNewFile;
    try printFormatPlan(&plan, stdout);
    var token_buffer: [64]u8 = undefined;
    if (plan.eligible) {
        try stdout.print("Confirm token: {s}\n", .{plan.tokenText(&token_buffer)});
    }
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

fn printFormatPlan(plan: *const zettide.target.FormatPlan, stdout: *Io.Writer) !void {
    try stdout.print("Target: {s}\n", .{plan.path});
    try stdout.print("Type: {s}\n", .{@tagName(plan.kind)});
    try stdout.print("Capacity: {Bi:.2}\n", .{plan.capacity_bytes});
    try stdout.print("Contains data: {s}\n", .{if (plan.contains_data) "yes" else "no"});
    try stdout.print("Name profile: {s}\n", .{plan.name_profile.name()});
    try stdout.print("Plan: {s}\n", .{if (plan.eligible) "ready" else "rejected"});
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
    if (try zettide.filesystem_target.classifyPath(io, args[0]) == .blob) {
        var filesystem = try zettide.filesystem_target.openBlobFilesystem(allocator, io, args[0], false);
        defer filesystem.close(io) catch {};
        const header = filesystem.blobs.header;
        try stdout.print("Path: {s}\n", .{args[0]});
        try stdout.writeAll("Filesystem: blob\nUUID: ");
        try printUuid(stdout, header.uuid);
        try stdout.print("\nCapacity: {Bi:.2}\n", .{header.device_size});
        try stdout.print("Block size: {d}\n", .{zettide.blob_format.allocation_unit});
        try stdout.print("Blocks: {d}\n", .{header.unit_count});
        try stdout.print("Name profile: {s}\n", .{filesystem.root.name_profile.name()});
        try stdout.writeAll("Case-sensitive: yes\nEncrypted: no\n");
        return;
    }
    const header = try zettide.target.inspectVolumeHeader(io, allocator, args[0]);

    try stdout.print("Path: {s}\n", .{args[0]});
    try stdout.print("Label: {s}\n", .{header.labelSlice()});
    try stdout.writeAll("UUID: ");
    try printUuid(stdout, header.uuid);
    try stdout.print("\nCapacity: {Bi:.2}\n", .{header.logical_size});
    try stdout.print("Block size: {d}\n", .{header.block_size});
    try stdout.print("Blocks: {d}\n", .{header.block_count});
    try stdout.print("Maximum file size: {Bi:.2}\n", .{header.user_file_max});
    try stdout.print("Name profile: {s}\n", .{header.name_profile.name()});
    try stdout.print("Case-sensitive: yes\nEncrypted: {s}\n", .{if (header.isEncrypted()) "yes" else "no"});
}

fn checkCommand(allocator: std.mem.Allocator, io: Io, args: []const []const u8, stdout: *Io.Writer) !void {
    if (args.len != 1) return error.InvalidArguments;
    if (try zettide.filesystem_target.classifyPath(io, args[0]) == .blob) {
        var filesystem = try zettide.filesystem_target.openBlobFilesystem(allocator, io, args[0], false);
        defer filesystem.close(io) catch {};
        try stdout.print("Filesystem traversal succeeded: {d} records\n", .{filesystem.root.record_count});
        return;
    }
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

fn printUuid(writer: *Io.Writer, uuid: [16]u8) !void {
    for (uuid, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) try writer.writeByte('-');
        try writer.print("{x:0>2}", .{byte});
    }
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zettide key generate <path>
        \\  zettide format <file|device> [--filesystem littlefs|blob] [--size <size>] [--label <label>] [--name-profile <profile>] [--encrypt (--key-file <path>|--passphrase)] [--confirm <token>]
        \\  zettide create <container> --size <size> [--label <label>] [--name-profile <profile>] [--redo-journal-size <size>]
        \\  zettide info <container>
        \\  zettide check <container>
        \\  zettide mount <container> <mountpoint> [--read-only] [--allow-other] [--metrics] [--noatime]
        \\  zettide unmount <mountpoint>
        \\  zettide device inspect <device>
        \\  zettide pool inspect --device <device>... [--name-profile <profile>]
        \\  zettide pool initialize --device <device>... [--label <label>] [--name-profile <profile>] --confirm <token>
        \\  zettide pool mount <mountpoint> --device <device>... [--filesystem littlefs|blob] [--read-only] [--allow-other] [--metrics] [--noatime]
        \\  zettide pool plan-create --device <device>... [--filesystem littlefs|blob] [--profile replicated|unprotected|scheduled-replicated] [--label <label>] [--name-profile <profile>]
        \\  zettide pool create --device <device>... [--filesystem littlefs|blob] [--profile replicated|unprotected|scheduled-replicated] [--label <label>] [--name-profile <profile>] --confirm <token>
        \\  zettide serve dufs <file|device> [--read-only] [--noatime] [--key-file <path>|--passphrase] [-- <dufs-options>...]
        \\  zettide endpoint serve --runtime-dir <dir> [--reactor-mask <mask>] [--pool-member <pool-id> <path>]... [--nvmf-traddr <address> [--nvmf-trsvcid <port>] (--nvmf-host-nqn <nqn>|--nvmf-allow-any-host)]
        \\
        \\Sizes accept binary suffixes such as 512MiB and 16GiB.
        \\Blob file targets do not support labels, encryption, or transport metrics.
        \\scheduled-replicated requires Blob and 3..12 devices.
        \\Name profiles are legacy-raw and portable-v1; legacy-raw is the default.
        \\
    );
}
