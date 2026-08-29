const std = @import("std");
const storage_engine = @import("zettide_storage");
const node = @import("zettide_node");

test "storage module exposes engine contracts without product adapters" {
    _ = storage_engine.v3.storage.Storage;
    _ = storage_engine.v3.pool_member_set.PoolMemberSet;
    _ = storage_engine.blob_filesystem.Filesystem;
    _ = storage_engine.filesystem_backend.Filesystem;
    _ = storage_engine.nfs_filesystem.Filesystem;

    try std.testing.expectEqual(
        storage_engine.name_profile.Profile.portable_v1,
        try storage_engine.name_profile.Profile.parse("portable-v1"),
    );
    try std.testing.expect(!@hasDecl(storage_engine, "filesystem_target"));
    try std.testing.expect(!@hasDecl(storage_engine, "linux_fuse"));
    try std.testing.expect(!@hasDecl(storage_engine, "endpoint_registry"));
    try std.testing.expect(!@hasDecl(storage_engine, "spdk_runtime"));
    try std.testing.expect(!@hasDecl(storage_engine.v3, "file_storage"));
    try std.testing.expect(!@hasDecl(storage_engine.v3, "linux_block_device"));
    try std.testing.expect(!@hasDecl(storage_engine.v3, "linux_pool_plan"));
}

test "node module owns product lifecycle and borrows the storage module" {
    _ = node.storage.v3.storage.Storage;
    _ = node.endpoint_registry.Spec;

    try std.testing.expect(@hasDecl(node, "endpoint_control"));
    try std.testing.expect(@hasDecl(node, "endpoint_daemon"));
    try std.testing.expect(!@hasDecl(node, "linux_fuse"));
    try std.testing.expect(!@hasDecl(node, "dufs_server"));
    try std.testing.expect(!@hasDecl(node, "nfs_backend"));
}
