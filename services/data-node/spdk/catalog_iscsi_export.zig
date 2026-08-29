const std = @import("std");
const catalog_volume_backend = @import("catalog_volume_backend.zig");
const iscsi_export = @import("iscsi_export.zig");
const provider_bdev = @import("provider_bdev.zig");
const runtime_api = @import("runtime.zig");
const storage_engine = @import("zettide_storage");
const pool_member_set = storage_engine.v3.pool_member_set;

pub const Options = struct {
    bdev_name: []const u8,
    target_name: []const u8,
    lun: i32 = 0,
    queue_depth: i32 = 64,
    block_size: u32 = 4096,
    write_unit_blocks: u32 = 1,
    max_io_blocks: u32 = 256,
};

/// Owns the same Catalog Volume backend used by NVMe-oF with an iSCSI frontend.
pub const CatalogIscsiExport = struct {
    worker: ?*catalog_volume_backend.Worker,
    bdev: provider_bdev.ProviderBdev,
    iscsi_export: iscsi_export.IscsiExport,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        service: *iscsi_export.IscsiService,
        set: *pool_member_set.PoolMemberSet,
        volume_id: [16]u8,
        options: Options,
    ) !CatalogIscsiExport {
        if (options.block_size == 0) return error.InvalidBlockSize;
        const runtime_handle = runtime.handle orelse return error.RuntimeStopped;
        const worker = try catalog_volume_backend.Worker.create(allocator, io, set, volume_id);
        errdefer worker.close();
        const logical_size = worker.logicalSize();
        if (logical_size % options.block_size != 0) return error.UnalignedLogicalSize;
        var bdev = try provider_bdev.ProviderBdev.create(
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
            options.bdev_name,
        );
        errdefer bdev.close() catch @panic("failed to roll back SPDK provider bdev");
        return .{
            .worker = worker,
            .bdev = bdev,
            .iscsi_export = try iscsi_export.IscsiExport.create(allocator, service, .{
                .target_name = options.target_name,
                .bdev_name = options.bdev_name,
                .lun = options.lun,
                .queue_depth = options.queue_depth,
            }),
        };
    }

    pub fn close(self: *CatalogIscsiExport) !void {
        try self.iscsi_export.close();
        try self.bdev.close();
        const worker = self.worker orelse return;
        self.worker = null;
        worker.close();
    }
};
