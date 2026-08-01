const std = @import("std");
const endpoint_control = @import("endpoint_control.zig");
const endpoint_registry = @import("endpoint_registry.zig");
const catalog_endpoint_backend = @import("spdk/catalog_endpoint_backend.zig");
const runtime_api = @import("spdk/runtime.zig");

const bdev_config =
    "{\"subsystems\":[{\"subsystem\":\"bdev\",\"config\":[" ++
    "{\"method\":\"bdev_set_options\",\"params\":{\"bdev_io_pool_size\":1024," ++
    "\"bdev_io_cache_size\":32}}]}]}";

const PoolMember = struct {
    pool_id: endpoint_registry.PoolId,
    path: []const u8,
};

const Options = struct {
    allocator: std.mem.Allocator,
    runtime_dir: []const u8,
    reactor_mask: []const u8 = "0x1",
    pool_members: []PoolMember,

    fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Options {
        var runtime_dir: ?[]const u8 = null;
        var reactor_mask: ?[]const u8 = null;
        var pool_members: std.ArrayList(PoolMember) = .empty;
        errdefer pool_members.deinit(allocator);

        var index: usize = 0;
        while (index < args.len) {
            const option = args[index];
            if (std.mem.eql(u8, option, "--runtime-dir")) {
                if (runtime_dir != null) return error.DuplicateOption;
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                runtime_dir = args[index];
            } else if (std.mem.eql(u8, option, "--reactor-mask")) {
                if (reactor_mask != null) return error.DuplicateOption;
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                reactor_mask = args[index];
            } else if (std.mem.eql(u8, option, "--pool-member")) {
                if (index + 2 >= args.len) return error.MissingOptionValue;
                try pool_members.append(allocator, .{
                    .pool_id = try parseId(args[index + 1]),
                    .path = args[index + 2],
                });
                index += 2;
            } else {
                return error.UnknownOption;
            }
            index += 1;
        }

        const directory = runtime_dir orelse return error.MissingRuntimeDirectory;
        if (!std.fs.path.isAbsolute(directory)) return error.InvalidRuntimeDirectory;
        const mask = reactor_mask orelse "0x1";
        if (mask.len == 0) return error.InvalidReactorMask;
        return .{
            .allocator = allocator,
            .runtime_dir = directory,
            .reactor_mask = mask,
            .pool_members = try pool_members.toOwnedSlice(allocator),
        };
    }

    fn deinit(self: *Options) void {
        self.allocator.free(self.pool_members);
        self.* = undefined;
    }
};

const PoolTable = struct {
    allocator: std.mem.Allocator,
    groups: std.ArrayList(Group) = .empty,
    configs: []catalog_endpoint_backend.ConfiguredPoolSource.Config = &.{},

    const Group = struct {
        pool_id: endpoint_registry.PoolId,
        locations: std.ArrayList(@import("v3/pool_member_set.zig").Location) = .empty,
    };

    fn init(allocator: std.mem.Allocator, members: []const PoolMember) !PoolTable {
        var result: PoolTable = .{ .allocator = allocator };
        errdefer result.deinit();
        for (members) |member| {
            const group = for (result.groups.items) |*candidate| {
                if (std.mem.eql(u8, &candidate.pool_id, &member.pool_id)) break candidate;
            } else blk: {
                try result.groups.append(allocator, .{ .pool_id = member.pool_id });
                break :blk &result.groups.items[result.groups.items.len - 1];
            };
            if (member.path.len == 0) return error.InvalidPoolLocation;
            try group.locations.append(allocator, .{
                .parent = std.Io.Dir.cwd(),
                .basename = member.path,
            });
        }

        result.configs = try allocator.alloc(
            catalog_endpoint_backend.ConfiguredPoolSource.Config,
            result.groups.items.len,
        );
        for (result.groups.items, result.configs) |*group, *config| {
            config.* = .{ .pool_id = group.pool_id, .locations = group.locations.items };
        }
        return result;
    }

    fn deinit(self: *PoolTable) void {
        if (self.configs.len != 0) self.allocator.free(self.configs);
        for (self.groups.items) |*group| group.locations.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.* = undefined;
    }
};

const TerminationSignals = struct {
    set: std.c.sigset_t,
    previous: std.c.sigset_t,

    fn block() !TerminationSignals {
        var result: TerminationSignals = undefined;
        if (std.c.sigemptyset(&result.set) != 0 or
            std.c.sigaddset(&result.set, .INT) != 0 or
            std.c.sigaddset(&result.set, .TERM) != 0)
            return error.SignalSetupFailed;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &result.set, &result.previous);
        return result;
    }

    fn wait(self: *TerminationSignals) !void {
        var signal_number: c_int = 0;
        if (std.c.sigwait(&self.set, &signal_number) != 0) return error.SignalWaitFailed;
    }

    fn restore(self: *TerminationSignals) void {
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.previous, null);
    }
};

const DynamicModules = struct {
    handles: [names.len]*anyopaque,

    const names = [_][:0]const u8{
        "librte_mempool_ring.so",
        "libspdk_event_bdev.so",
        "libspdk_event_vhost_blk.so",
    };

    fn load() !DynamicModules {
        var result: DynamicModules = undefined;
        var loaded: usize = 0;
        errdefer while (loaded > 0) {
            loaded -= 1;
            _ = std.c.dlclose(result.handles[loaded]);
        };
        for (names, &result.handles) |name, *handle| {
            handle.* = std.c.dlopen(name, .{ .NOW = true, .GLOBAL = true }) orelse
                return error.SpdkModuleUnavailable;
            loaded += 1;
        }
        return result;
    }

    fn deinit(self: *DynamicModules) void {
        var index = self.handles.len;
        while (index > 0) {
            index -= 1;
            _ = std.c.dlclose(self.handles[index]);
        }
        self.* = undefined;
    }
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
) !void {
    var options = try Options.parse(allocator, args);
    defer options.deinit();
    var signals = try TerminationSignals.block();
    defer signals.restore();
    var modules = try DynamicModules.load();
    defer modules.deinit();

    var runtime = try runtime_api.Runtime.start(allocator, .{
        .name = "zettide-endpointd",
        .reactor_mask = options.reactor_mask,
        .json_data = bdev_config,
        .mem_size_mb = 320,
        .no_pci = true,
        .no_huge = true,
        .disable_cpumask_locks = true,
        .vhost_socket_path = options.runtime_dir,
    });
    errdefer runtime.deinit();
    const runtime_dir = try std.Io.Dir.cwd().openDir(io, options.runtime_dir, .{});
    defer runtime_dir.close(io);
    try endpoint_control.validateControlDirectory(runtime_dir);
    const runtime_path = try runtime_dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(runtime_path);
    var pools = try PoolTable.init(allocator, options.pool_members);
    defer pools.deinit();
    var source = try catalog_endpoint_backend.ConfiguredPoolSource.init(allocator, io, pools.configs);
    var backend = catalog_endpoint_backend.CatalogEndpointBackend.init(
        allocator,
        io,
        &runtime,
        source.poolSource(),
        .{ .cpumask = options.reactor_mask },
    );
    var store = endpoint_registry.FileStore.init(io, runtime_dir, "endpoints.state");
    var registry = try endpoint_registry.Registry.init(allocator, store.desiredStore(), backend.endpointBackend());
    errdefer {
        registry.shutdown() catch |err|
            std.debug.panic("failed to clean up endpoint registry: {s}", .{@errorName(err)});
        registry.deinit();
    }
    const reconciled = registry.reconcile();
    {
        const server = try endpoint_control.Server.start(
            allocator,
            io,
            runtime_dir,
            "control.sock",
            &registry,
        );
        defer server.deinit();
        try stdout.print("Endpoint daemon ready: {s}/control.sock\n", .{runtime_path});
        try stdout.print("Reconciled endpoints: {d} active, {d} failed\n", .{
            reconciled.started,
            reconciled.failed,
        });
        try stdout.flush();

        try signals.wait();
    }
    try registry.shutdown();
    registry.deinit();
    runtime.deinit();
}

fn parseId(text: []const u8) ![16]u8 {
    if (text.len != 32) return error.InvalidPoolId;
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return error.InvalidPoolId;
    for (result) |byte| if (byte != 0) return result;
    return error.InvalidPoolId;
}

test "endpoint daemon parses runtime and grouped pool options" {
    var options = try Options.parse(std.testing.allocator, &.{
        "--runtime-dir",
        "/run/zettide",
        "--reactor-mask",
        "0x2",
        "--pool-member",
        "00000000000000000000000000000001",
        "/dev/first",
        "--pool-member",
        "00000000000000000000000000000001",
        "/dev/second",
    });
    defer options.deinit();
    try std.testing.expectEqualStrings("/run/zettide", options.runtime_dir);
    try std.testing.expectEqualStrings("0x2", options.reactor_mask);
    try std.testing.expectEqual(@as(usize, 2), options.pool_members.len);

    var pools = try PoolTable.init(std.testing.allocator, options.pool_members);
    defer pools.deinit();
    try std.testing.expectEqual(@as(usize, 1), pools.configs.len);
    try std.testing.expectEqual(@as(usize, 2), pools.configs[0].locations.len);
}

test "endpoint daemon rejects incomplete options" {
    try std.testing.expectError(
        error.MissingRuntimeDirectory,
        Options.parse(std.testing.allocator, &.{}),
    );
    try std.testing.expectError(
        error.InvalidPoolId,
        Options.parse(std.testing.allocator, &.{
            "--runtime-dir",
            "/run/zettide",
            "--pool-member",
            "bad",
            "/dev/member",
        }),
    );
}
