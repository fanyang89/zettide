const std = @import("std");
const zettide = @import("zettide");

const runtime_api = zettide.spdk_runtime;
const catalog_endpoint_backend = zettide.spdk_catalog_endpoint_backend;
const export_api = zettide.spdk_vhost_block_export;
const c = export_api.c;

const block_size = 4096;
const block_count = 64;

const bdev_config =
    "{\"subsystems\":[{\"subsystem\":\"bdev\",\"config\":[" ++
    "{\"method\":\"bdev_set_options\",\"params\":{\"bdev_io_pool_size\":1024," ++
    "\"bdev_io_cache_size\":32}}]}]}";

const Backend = struct {
    data: [block_size * block_count]u8 = @splat(0),

    fn submit(
        context_raw: ?*anyopaque,
        operation: c.enum_zettide_spdk_bdev_provider_operation,
        offset: u64,
        buffer: ?*anyopaque,
        length: u64,
        complete: c.zettide_spdk_bdev_provider_complete,
        complete_context: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Backend = @ptrCast(@alignCast(context_raw.?));
        const end = std.math.add(u64, offset, length) catch {
            complete.?(complete_context, -c.ERANGE);
            return 0;
        };
        if (end > self.data.len or length > std.math.maxInt(usize)) {
            complete.?(complete_context, -c.ERANGE);
            return 0;
        }
        const size: usize = @intCast(length);
        const start: usize = @intCast(offset);
        switch (operation) {
            c.ZETTIDE_SPDK_BDEV_PROVIDER_READ => @memcpy(@as([*]u8, @ptrCast(buffer.?))[0..size], self.data[start..][0..size]),
            c.ZETTIDE_SPDK_BDEV_PROVIDER_WRITE => @memcpy(self.data[start..][0..size], @as([*]const u8, @ptrCast(buffer.?))[0..size]),
            c.ZETTIDE_SPDK_BDEV_PROVIDER_FLUSH, c.ZETTIDE_SPDK_BDEV_PROVIDER_RESET => {},
            else => {
                complete.?(complete_context, -c.EINVAL);
                return 0;
            },
        }
        complete.?(complete_context, 0);
        return 0;
    }
};

const UnusedPoolSource = struct {
    fn open(_: *anyopaque, _: [16]u8) !catalog_endpoint_backend.PoolSource.Opened {
        return error.UnusedPoolSource;
    }

    fn close(_: *anyopaque, _: *zettide.v3.pool_member_set.PoolMemberSet) !void {
        unreachable;
    }

    fn abort(_: *anyopaque, _: *zettide.v3.pool_member_set.PoolMemberSet) void {
        unreachable;
    }

    const vtable: catalog_endpoint_backend.PoolSource.VTable = .{
        .open = open,
        .close = close,
        .abort = abort,
    };
};

pub export fn zettide_spdk_vhost_export_test_main(socket_directory: [*:0]const u8) c_int {
    run(socket_directory) catch |err| {
        std.debug.print("SPDK vhost export test failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(socket_directory: [*:0]const u8) !void {
    var runtime = try runtime_api.Runtime.start(std.heap.c_allocator, .{
        .name = "zettide_spdk_vhost_export_test",
        .reactor_mask = "0x1",
        .json_data = bdev_config,
        .mem_size_mb = 320,
        .no_pci = true,
        .no_huge = true,
        .disable_cpumask_locks = true,
        .vhost_socket_path = std.mem.span(socket_directory),
    });
    defer runtime.deinit();
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var unused_source_context: u8 = 0;
    var endpoint_backend = catalog_endpoint_backend.CatalogEndpointBackend.init(
        std.heap.c_allocator,
        threaded.io(),
        &runtime,
        .{ .context = &unused_source_context, .vtable = &UnusedPoolSource.vtable },
        .{},
    );
    _ = endpoint_backend.endpointBackend();
    var backend: Backend = .{};
    const provider_backend: export_api.Backend = .{
        .context = &backend,
        .submit = Backend.submit,
        .block_count = block_count,
    };
    const runtime_handle: *anyopaque = @ptrCast(runtime.handle.?);
    var first = try export_api.VhostBlockExport.create(
        std.heap.c_allocator,
        runtime_handle,
        provider_backend,
        .{
            .bdev_name = "ZettideExport0",
            .controller_name = "zettide-export-0",
            .cpumask = "0x1",
        },
    );
    defer first.close() catch unreachable;
    try std.testing.expect(first.socketPath().len != 0);
    try std.testing.expectError(error.InvalidExportOptions, first.setCoalescing(4, 99));
    try first.setCoalescing(4, 10_000);

    try std.testing.expectError(error.ExportAlreadyExists, export_api.VhostBlockExport.create(
        std.heap.c_allocator,
        runtime_handle,
        provider_backend,
        .{
            .bdev_name = "ZettideRollback",
            .controller_name = "zettide-export-0",
            .cpumask = "0x1",
        },
    ));
    var second = try export_api.VhostBlockExport.create(
        std.heap.c_allocator,
        runtime_handle,
        provider_backend,
        .{
            .bdev_name = "ZettideRollback",
            .controller_name = "zettide-export-1",
            .cpumask = "0x1",
            .readonly = true,
        },
    );
    try second.close();
}
