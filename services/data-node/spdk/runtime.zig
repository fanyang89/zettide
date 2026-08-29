const std = @import("std");
const storage_api = @import("storage.zig");
const storage_engine = @import("zettide_storage");
const v3_storage = storage_engine.v3.storage;

const c = @import("spdk_c");

pub const Runtime = struct {
    handle: ?*c.struct_zettide_spdk_runtime,

    pub const Options = struct {
        name: []const u8 = "zettide",
        reactor_mask: ?[]const u8 = null,
        json_data: []const u8 = &.{},
        mem_size_mb: c_int = 0,
        no_pci: bool = false,
        no_huge: bool = false,
        disable_cpumask_locks: bool = false,
        vhost_socket_path: ?[]const u8 = null,
    };

    pub fn start(allocator: std.mem.Allocator, options: Options) !Runtime {
        const name_z = try allocator.dupeSentinel(u8, options.name, 0);
        defer allocator.free(name_z);
        const reactor_mask_z = if (options.reactor_mask) |value| try allocator.dupeSentinel(u8, value, 0) else null;
        defer if (reactor_mask_z) |value| allocator.free(value);
        const vhost_socket_path_z = if (options.vhost_socket_path) |value| try allocator.dupeSentinel(u8, value, 0) else null;
        defer if (vhost_socket_path_z) |value| allocator.free(value);

        var c_options: c.struct_zettide_spdk_runtime_opts = undefined;
        c.zettide_spdk_runtime_opts_init(&c_options, @sizeOf(@TypeOf(c_options)));
        c_options.name = name_z.ptr;
        c_options.reactor_mask = if (reactor_mask_z) |value| value.ptr else null;
        c_options.json_data = if (options.json_data.len == 0) null else options.json_data.ptr;
        c_options.json_data_size = options.json_data.len;
        c_options.mem_size_mb = options.mem_size_mb;
        c_options.no_pci = options.no_pci;
        c_options.no_huge = options.no_huge;
        c_options.disable_cpumask_locks = options.disable_cpumask_locks;
        c_options.vhost_socket_path = if (vhost_socket_path_z) |value| value.ptr else null;
        var handle: ?*c.struct_zettide_spdk_runtime = null;
        try statusError(c.zettide_spdk_runtime_start(&c_options, &handle));
        return .{ .handle = handle orelse return error.UnexpectedRuntimeStatus };
    }

    pub fn openStorage(
        self: *Runtime,
        allocator: std.mem.Allocator,
        name: []const u8,
        writable: bool,
    ) !v3_storage.Storage {
        const handle = self.handle orelse return error.RuntimeStopped;
        return storage_api.open(allocator, @ptrCast(handle), name, writable);
    }

    pub fn stop(self: *Runtime) !void {
        try statusError(c.zettide_spdk_runtime_stop(self.handle orelse return));
    }

    pub fn deinit(self: *Runtime) void {
        const handle = self.handle orelse return;
        statusError(c.zettide_spdk_runtime_stop(handle)) catch |err|
            std.debug.panic("failed to stop SPDK runtime: {s}", .{@errorName(err)});
        statusError(c.zettide_spdk_runtime_destroy(handle)) catch |err|
            std.debug.panic("failed to destroy SPDK runtime: {s}", .{@errorName(err)});
        self.handle = null;
    }
};

fn statusError(status: c_int) !void {
    if (status == 0) return;
    return switch (-status) {
        c.EINVAL => error.InvalidRuntimeOptions,
        c.ENOMEM => error.OutOfMemory,
        c.EBUSY => error.RuntimeBusy,
        c.EALREADY => error.RuntimeStopping,
        c.EDEADLK => error.SpdkThreadViolation,
        c.ESHUTDOWN => error.RuntimeStopped,
        c.EIO => error.RuntimeStartFailed,
        else => error.UnexpectedRuntimeStatus,
    };
}
