const std = @import("std");
const storage_engine = @import("zettide_storage");
const data_node = @import("zettide_data_node");

test "storage module exposes engine contracts without product adapters" {
    _ = storage_engine.v3.storage.Storage;
    _ = storage_engine.v3.pool_member_set.PoolMemberSet;
    _ = storage_engine.v3.pool_catalog_volume.CatalogVolumeBackend;
    _ = storage_engine.v3.pool_catalog_volume.CatalogDataLease;
    try std.testing.expect(!@hasDecl(storage_engine.v3, "pool_data_storage"));
    try std.testing.expect(!@hasDecl(storage_engine.v3, "pool_data_device"));
    try std.testing.expect(!@hasDecl(storage_engine.v3, "pool_scheduled_data_device"));
    try std.testing.expect(!@hasDecl(storage_engine, "blob_filesystem"));
    try std.testing.expect(!@hasDecl(storage_engine, "filesystem_backend"));
    try std.testing.expect(!@hasDecl(storage_engine, "nfs_filesystem"));
    try std.testing.expect(!@hasDecl(storage_engine, "name_profile"));
    try std.testing.expect(!@hasDecl(storage_engine, "filesystem_target"));
    try std.testing.expect(!@hasDecl(storage_engine, "linux_fuse"));
    try std.testing.expect(!@hasDecl(storage_engine, "endpoint_registry"));
    try std.testing.expect(!@hasDecl(storage_engine, "spdk_runtime"));
    try std.testing.expect(!@hasDecl(storage_engine.v3, "file_storage"));
    try std.testing.expect(!@hasDecl(storage_engine.v3, "linux_block_device"));
    try std.testing.expect(!@hasDecl(storage_engine.v3, "linux_pool_plan"));
}

test "data-node module owns product lifecycle and borrows the storage module" {
    _ = data_node.storage.v3.storage.Storage;
    _ = data_node.endpoint_registry.Spec;

    try std.testing.expect(@hasDecl(data_node, "endpoint_control"));
    try std.testing.expect(@hasDecl(data_node, "endpoint_daemon"));
    try std.testing.expect(!@hasDecl(data_node, "linux_fuse"));
    try std.testing.expect(!@hasDecl(data_node, "dufs_server"));
    try std.testing.expect(!@hasDecl(data_node, "nfs_backend"));
    try std.testing.expect(!@hasDecl(data_node, "filesystem_target"));
    try std.testing.expect(!@hasDecl(data_node, "spdk_catalog_iscsi_export"));
    try std.testing.expect(!@hasDecl(data_node, "spdk_catalog_vhost_export"));
    try std.testing.expect(!@hasDecl(data_node, "spdk_iscsi_export"));
    try std.testing.expect(!@hasDecl(data_node, "spdk_vhost_block_export"));
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(data_node.endpoint_registry.Frontend).@"enum".field_names.len);
    try std.testing.expect(!@hasDecl(data_node, "data_service"));
    try std.testing.expect(!@hasDecl(data_node, "replica_rpc_client"));
    try std.testing.expect(!@hasDecl(data_node, "write_coordinator_manager"));
}
