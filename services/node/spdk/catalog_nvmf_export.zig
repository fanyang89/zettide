const std = @import("std");
const catalog_volume_backend = @import("catalog_volume_backend.zig");
const nvmf_tcp_export = @import("nvmf_tcp_export.zig");
const provider_bdev = @import("provider_bdev.zig");
const runtime_api = @import("runtime.zig");
const storage_engine = @import("zettide_storage");
const pool_member_set = storage_engine.v3.pool_member_set;

pub const Options = struct {
    bdev_name: []const u8,
    nqn: []const u8,
    serial_number: ?[]const u8 = null,
    model_number: ?[]const u8 = null,
    host_nqn: ?[]const u8 = null,
    traddr: []const u8,
    trsvcid: []const u8 = "4420",
    nsid: u32 = 1,
    allow_any_host: bool = false,
    transport: nvmf_tcp_export.Transport = .tcp,
    target_name: ?[]const u8 = null,
    block_size: u32 = 4096,
    write_unit_blocks: u32 = 1,
    max_io_blocks: u32 = 256,
};

/// Owns the complete Catalog Volume to NVMe-oF data path. The runtime JSON
/// configuration must create the named target and selected transport first.
pub const CatalogNvmfExport = struct {
    worker: ?*catalog_volume_backend.Worker,
    bdev: provider_bdev.ProviderBdev,
    nvmf_export: nvmf_tcp_export.NvmfExport,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        runtime: *runtime_api.Runtime,
        set: *pool_member_set.PoolMemberSet,
        volume_id: [16]u8,
        options: Options,
    ) !CatalogNvmfExport {
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
            .nvmf_export = try nvmf_tcp_export.NvmfExport.create(
                allocator,
                @ptrCast(runtime_handle),
                .{
                    .target_name = options.target_name,
                    .nqn = options.nqn,
                    .bdev_name = options.bdev_name,
                    .serial_number = options.serial_number,
                    .model_number = options.model_number,
                    .host_nqn = options.host_nqn,
                    .traddr = options.traddr,
                    .trsvcid = options.trsvcid,
                    .nsid = options.nsid,
                    .allow_any_host = options.allow_any_host,
                    .transport = options.transport,
                },
            ),
        };
    }

    pub fn close(self: *CatalogNvmfExport) !void {
        try self.nvmf_export.close();
        try self.bdev.close();
        const worker = self.worker orelse return;
        self.worker = null;
        worker.close();
    }
};
