const std = @import("std");
const storage_engine = @import("zettide_storage");
const node = @import("zettide_node");

const nvmf = node.spdk_nvmf_tcp_export;

pub export fn zettide_spdk_catalog_nvmf_export_compile_test(
    io: *std.Io,
    runtime: *node.spdk_runtime.Runtime,
    set: *storage_engine.v3.pool_member_set.PoolMemberSet,
    volume_id: *const [16]u8,
) c_int {
    var export_handle = node.spdk_catalog_nvmf_export.CatalogNvmfExport.create(
        std.heap.c_allocator,
        io.*,
        runtime,
        set,
        volume_id.*,
        .{
            .bdev_name = "CatalogNvmfCompileTest",
            .nqn = "nqn.2026-08.io.zettide:catalog-compile-test",
            .traddr = "127.0.0.1",
            .allow_any_host = true,
        },
    ) catch return 1;
    export_handle.close() catch return 1;
    return 0;
}

pub export fn zettide_spdk_nvmf_zig_export_test(runtime: *anyopaque) c_int {
    var export_handle = nvmf.NvmfTcpExport.create(
        std.heap.c_allocator,
        runtime,
        .{
            .nqn = "nqn.2026-08.io.zettide:zig-managed-test",
            .bdev_name = "NvmfExportBdev",
            .serial_number = "ZETTIDEZIGTEST001",
            .model_number = "Zettide Zig Managed Test",
            .host_nqn = "nqn.2026-08.io.zettide:test-host",
            .traddr = "127.0.0.1",
            .trsvcid = "44230",
        },
    ) catch return 1;
    export_handle.close() catch return 1;
    return 0;
}
