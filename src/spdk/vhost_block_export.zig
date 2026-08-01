const std = @import("std");

pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("spdk/bdev_provider.h");
    @cInclude("spdk/vhost_blk_controller.h");
});

pub const Backend = struct {
    context: *anyopaque,
    submit: c.zettide_spdk_bdev_provider_submit,
    block_size: u32 = 4096,
    block_count: u64,
    write_unit_blocks: u32 = 1,
    max_io_blocks: u32 = 256,
};

pub const Options = struct {
    bdev_name: []const u8,
    controller_name: []const u8,
    cpumask: ?[]const u8 = null,
};

/// Owns an SPDK provider and the vhost-blk controller consuming it. Backend
/// context and submit callback state must remain valid until close succeeds.
pub const VhostBlockExport = struct {
    allocator: std.mem.Allocator,
    provider: ?*c.struct_zettide_spdk_bdev_provider,
    controller: ?*c.struct_zettide_spdk_vhost_blk_controller,
    socket_path: []u8,

    pub fn create(
        allocator: std.mem.Allocator,
        runtime: *anyopaque,
        backend: Backend,
        options: Options,
    ) !VhostBlockExport {
        if (backend.submit == null or backend.block_count == 0) return error.InvalidBackend;
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

        var provider_options: c.struct_zettide_spdk_bdev_provider_opts = undefined;
        c.zettide_spdk_bdev_provider_opts_init(&provider_options, @sizeOf(@TypeOf(provider_options)));
        provider_options.name = bdev_name.ptr;
        provider_options.block_size = backend.block_size;
        provider_options.block_count = backend.block_count;
        provider_options.write_unit_blocks = backend.write_unit_blocks;
        provider_options.max_io_blocks = backend.max_io_blocks;
        provider_options.backend_context = backend.context;
        provider_options.submit = backend.submit;
        var provider: ?*c.struct_zettide_spdk_bdev_provider = null;
        try statusError(c.zettide_spdk_bdev_provider_create(@ptrCast(runtime), &provider_options, &provider));
        const provider_handle = provider orelse return error.UnexpectedProviderStatus;

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
            rollbackProvider(provider_handle);
            statusError(create_status) catch |err| return err;
            unreachable;
        }
        const controller_handle = controller orelse {
            rollbackProvider(provider_handle);
            return error.UnexpectedControllerStatus;
        };
        return .{
            .allocator = allocator,
            .provider = provider_handle,
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
        if (self.provider) |provider| {
            try statusError(c.zettide_spdk_bdev_provider_delete_wait(provider));
            self.provider = null;
        }
        self.allocator.free(self.socket_path);
        self.socket_path = &.{};
    }
};

fn rollbackProvider(provider: *c.struct_zettide_spdk_bdev_provider) void {
    if (c.zettide_spdk_bdev_provider_delete_wait(provider) != 0)
        @panic("failed to roll back SPDK bdev provider");
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
