const std = @import("std");
const catalog_volume_backend = @import("catalog_volume_backend.zig");
const runtime_api = @import("runtime.zig");
const vhost_block_export = @import("vhost_block_export.zig");
const storage_engine = @import("zettide_storage");
const pool_member_set = storage_engine.v3.pool_member_set;

pub const Options = struct {
    bdev_name: []const u8,
    controller_name: []const u8,
    cpumask: ?[]const u8 = null,
    block_size: u32 = 4096,
    write_unit_blocks: u32 = 1,
    max_io_blocks: u32 = 256,
};

/// Owns the complete catalog volume export data path. The allocator must be
/// thread-safe. The allocator, io, and pinned set must remain valid, and the
/// caller must not use set, until close succeeds.
pub const CatalogVhostExport = struct {
    worker: ?*catalog_volume_backend.Worker,
    block_export: vhost_block_export.VhostBlockExport,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        set: *pool_member_set.PoolMemberSet,
        volume_id: [16]u8,
        options: Options,
    ) !CatalogVhostExport {
        if (options.block_size == 0) return error.InvalidBlockSize;
        const runtime_handle = runtime.handle orelse return error.RuntimeStopped;
        const worker = try catalog_volume_backend.Worker.create(allocator, io, set, volume_id);
        errdefer worker.close();
        const logical_size = worker.logicalSize();
        if (logical_size % options.block_size != 0) return error.UnalignedLogicalSize;
        return .{
            .worker = worker,
            .block_export = try vhost_block_export.VhostBlockExport.create(
                allocator,
                @ptrCast(runtime_handle),
                .{
                    .context = worker,
                    .submit = catalog_volume_backend.submit_callback,
                    .block_size = options.block_size,
                    .block_count = logical_size / options.block_size,
                    .write_unit_blocks = options.write_unit_blocks,
                    .max_io_blocks = options.max_io_blocks,
                },
                .{
                    .bdev_name = options.bdev_name,
                    .controller_name = options.controller_name,
                    .cpumask = options.cpumask,
                },
            ),
        };
    }

    pub fn socketPath(self: *const CatalogVhostExport) []const u8 {
        return self.block_export.socketPath();
    }

    pub fn close(self: *CatalogVhostExport) !void {
        try self.block_export.close();
        const worker = self.worker orelse return;
        self.worker = null;
        worker.close();
    }
};
