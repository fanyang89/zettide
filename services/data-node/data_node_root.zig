pub const storage = @import("zettide_storage");

pub const data_service = @import("data_node_service.zig");
pub const replica_io_gate = @import("replica_io_gate.zig");
pub const replica_rpc_auth = @import("replica_rpc_auth.zig");
pub const replica_rpc_client = @import("replica_rpc_client.zig");
pub const write_participant_manager = @import("write_participant_manager.zig");
pub const member_generation_store = @import("member_generation_store.zig");
pub const endpoint_registry = @import("endpoint_registry.zig");
pub const endpoint_control = if (@import("builtin").os.tag == .linux) @import("endpoint_control.zig") else struct {};
pub const endpoint_daemon = if (@import("builtin").os.tag == .linux) @import("endpoint_daemon.zig") else struct {};

pub const size = @import("size.zig");
pub const filesystem_target = if (@import("builtin").os.tag == .linux) @import("filesystem_target.zig") else struct {};
pub const file_storage = @import("v3/file_storage.zig");
pub const linux_block_device = if (@import("builtin").os.tag == .linux) @import("v3/linux_block_device.zig") else struct {};

pub const spdk_catalog_endpoint_backend = if (@import("builtin").os.tag == .linux) @import("spdk/catalog_endpoint_backend.zig") else struct {};
pub const spdk_catalog_iscsi_export = if (@import("builtin").os.tag == .linux) @import("spdk/catalog_iscsi_export.zig") else struct {};
pub const spdk_catalog_nvmf_export = if (@import("builtin").os.tag == .linux) @import("spdk/catalog_nvmf_export.zig") else struct {};
pub const spdk_catalog_volume_backend = if (@import("builtin").os.tag == .linux) @import("spdk/catalog_volume_backend.zig") else struct {};
pub const spdk_catalog_vhost_export = if (@import("builtin").os.tag == .linux) @import("spdk/catalog_vhost_export.zig") else struct {};
pub const spdk_iscsi_export = if (@import("builtin").os.tag == .linux) @import("spdk/iscsi_export.zig") else struct {};
pub const spdk_nvme_controller = if (@import("builtin").os.tag == .linux) @import("spdk/nvme_controller.zig") else struct {};
pub const spdk_nvmf_tcp_export = if (@import("builtin").os.tag == .linux) @import("spdk/nvmf_tcp_export.zig") else struct {};
pub const spdk_provider_bdev = if (@import("builtin").os.tag == .linux) @import("spdk/provider_bdev.zig") else struct {};
pub const spdk_runtime = if (@import("builtin").os.tag == .linux) @import("spdk/runtime.zig") else struct {};
pub const spdk_storage = if (@import("builtin").os.tag == .linux) @import("spdk/storage.zig") else struct {};
pub const spdk_vhost_block_export = if (@import("builtin").os.tag == .linux) @import("spdk/vhost_block_export.zig") else struct {};
