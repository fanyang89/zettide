const std = @import("std");
const provider_bdev = @import("provider_bdev.zig");

pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("spdk/bdev_provider.h");
    @cInclude("spdk/vhost_blk_controller.h");
});

pub const Backend = provider_bdev.Backend;

pub const Options = struct {
    bdev_name: []const u8,
    controller_name: []const u8,
    cpumask: ?[]const u8 = null,
};

/// Owns an SPDK provider bdev and the vhost-blk controller consuming it. Backend
/// context and submit callback state must remain valid until close succeeds.
pub const VhostBlockExport = struct {
    allocator: std.mem.Allocator,
    bdev: provider_bdev.ProviderBdev,
    controller: ?*c.struct_zettide_spdk_vhost_blk_controller,
    socket_path: []u8,

    pub fn create(
        allocator: std.mem.Allocator,
        runtime: *anyopaque,
        backend: Backend,
        options: Options,
    ) !VhostBlockExport {
        const bdev_name = try allocator.dupeZ(u8, options.bdev_name);
        defer allocator.free(bdev_name);
        const controller_name = try allocator.dupeZ(u8, options.controller_name);
        defer allocator.free(controller_name);
        const cpumask = if (options.cpumask) |value| try allocator.dupeZ(u8, value) else null;
        defer if (cpumask) |value| allocator.free(value);
        const socket_directory_raw = c.zettide_spdk_runtime_get_vhost_socket_path(@ptrCast(runtime));
        const socket_directory = std.mem.span(socket_directory_raw orelse return error.VhostNotConfigured);
        const separator = if (std.mem.endsWith(u8, socket_directory, "/")) "" else "/";
        const socket_path = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s}",
            .{ socket_directory, separator, options.controller_name },
        );
        errdefer allocator.free(socket_path);

        var bdev = try provider_bdev.ProviderBdev.create(allocator, runtime, backend, options.bdev_name);

        var controller_options: c.struct_zettide_spdk_vhost_blk_controller_opts = undefined;
        c.zettide_spdk_vhost_blk_controller_opts_init(
            &controller_options,
            @sizeOf(@TypeOf(controller_options)),
        );
        controller_options.name = controller_name.ptr;
        controller_options.bdev_name = bdev_name.ptr;
        controller_options.cpumask = if (cpumask) |value| value.ptr else null;
        var controller: ?*c.struct_zettide_spdk_vhost_blk_controller = null;
        const create_status = c.zettide_spdk_vhost_blk_controller_create(
            @ptrCast(runtime),
            &controller_options,
            &controller,
        );
        if (create_status != 0) {
            rollbackBdev(&bdev);
            statusError(create_status) catch |err| return err;
            unreachable;
        }
        const controller_handle = controller orelse {
            rollbackBdev(&bdev);
            return error.UnexpectedControllerStatus;
        };
        return .{
            .allocator = allocator,
            .bdev = bdev,
            .controller = controller_handle,
            .socket_path = socket_path,
        };
    }

    pub fn socketPath(self: *const VhostBlockExport) []const u8 {
        return self.socket_path;
    }

    /// Keeps all remaining state valid when a teardown step fails, so close is retryable.
    pub fn close(self: *VhostBlockExport) !void {
        if (self.controller) |controller| {
            try statusError(c.zettide_spdk_vhost_blk_controller_remove(controller));
            self.controller = null;
        }
        try self.bdev.close();
        self.allocator.free(self.socket_path);
        self.socket_path = &.{};
    }
};

fn rollbackBdev(bdev: *provider_bdev.ProviderBdev) void {
    bdev.close() catch @panic("failed to roll back SPDK bdev provider");
}

fn statusError(status: c_int) !void {
    if (status == 0) return;
    return switch (-status) {
        c.EINVAL => error.InvalidExportOptions,
        c.ENOMEM => error.OutOfMemory,
        c.EEXIST => error.ExportAlreadyExists,
        c.ENODEV => error.BdevNotFound,
        c.EBUSY => error.ExportBusy,
        c.EDEADLK => error.SpdkThreadViolation,
        c.ESHUTDOWN => error.RuntimeStopped,
        c.ENAMETOOLONG => error.NameTooLong,
        else => error.UnexpectedSpdkStatus,
    };
}
