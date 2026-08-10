const std = @import("std");

pub const c = @import("spdk_c");

pub const Backend = struct {
    context: *anyopaque,
    submit: c.zettide_spdk_bdev_provider_submit,
    block_size: u32 = 4096,
    block_count: u64,
    write_unit_blocks: u32 = 1,
    max_io_blocks: u32 = 256,
};

/// Owns an SPDK bdev backed by an external asynchronous request provider.
/// Backend state must remain valid until close succeeds.
pub const ProviderBdev = struct {
    handle: ?*c.struct_zettide_spdk_bdev_provider,

    pub fn create(
        allocator: std.mem.Allocator,
        runtime: *anyopaque,
        backend: Backend,
        name: []const u8,
    ) !ProviderBdev {
        if (backend.submit == null or backend.block_count == 0) return error.InvalidBackend;
        const name_z = try allocator.dupeSentinel(u8, name, 0);
        defer allocator.free(name_z);

        var options: c.struct_zettide_spdk_bdev_provider_opts = undefined;
        c.zettide_spdk_bdev_provider_opts_init(&options, @sizeOf(@TypeOf(options)));
        options.name = name_z.ptr;
        options.block_size = backend.block_size;
        options.block_count = backend.block_count;
        options.write_unit_blocks = backend.write_unit_blocks;
        options.max_io_blocks = backend.max_io_blocks;
        options.backend_context = backend.context;
        options.submit = backend.submit;

        var handle: ?*c.struct_zettide_spdk_bdev_provider = null;
        try statusError(c.zettide_spdk_bdev_provider_create(@ptrCast(runtime), &options, &handle));
        return .{ .handle = handle orelse return error.UnexpectedProviderStatus };
    }

    /// Keeps ownership when unregister fails, so close is retryable.
    pub fn close(self: *ProviderBdev) !void {
        const handle = self.handle orelse return;
        try statusError(c.zettide_spdk_bdev_provider_delete_wait(handle));
        self.handle = null;
    }
};

fn statusError(status: c_int) !void {
    if (status == 0) return;
    return switch (-status) {
        c.EINVAL => error.InvalidExportOptions,
        c.ENOMEM => error.OutOfMemory,
        c.EEXIST => error.ExportAlreadyExists,
        c.EBUSY => error.ExportBusy,
        c.EDEADLK => error.SpdkThreadViolation,
        c.ESHUTDOWN => error.RuntimeStopped,
        c.ENAMETOOLONG => error.NameTooLong,
        else => error.UnexpectedSpdkStatus,
    };
}
