const engine = @import("zettide_storage").v3;

pub const codec = engine.codec;
pub const catalog_volume_header = engine.catalog_volume_header;
pub const control_record = engine.control_record;
pub const genesis_payload = engine.genesis_payload;
pub const journal = engine.journal;
pub const layout = engine.layout;
pub const member = engine.member;
pub const member_format = engine.member_format;
pub const member_bootstrap = engine.member_bootstrap;
pub const member_set = engine.member_set;
pub const membership = engine.membership;
pub const pool_policy = engine.pool_policy;
pub const pool_provision = engine.pool_provision;
pub const pool_replicated_journal = engine.pool_replicated_journal;
pub const pool_layout = engine.pool_layout;
pub const pool_member_set = engine.pool_member_set;
pub const pool_evidence = engine.pool_evidence;
pub const pool_certificate = engine.pool_certificate;
pub const pool_authority = engine.pool_authority;
pub const pool_authority_checkpoint = engine.pool_authority_checkpoint;
pub const pool_blob_schedule = engine.pool_blob_schedule;
pub const pool_data_storage = engine.pool_data_storage;
pub const pool_data_device = engine.pool_data_device;
pub const pool_scheduled_data_device = engine.pool_scheduled_data_device;
pub const pool_catalog = engine.pool_catalog;
pub const pool_catalog_mutation = engine.pool_catalog_mutation;
pub const pool_catalog_volume = engine.pool_catalog_volume;
pub const pool_catalog_graph = engine.pool_catalog_graph;
pub const pool_catalog_page = engine.pool_catalog_page;
pub const pool_genesis_payload = engine.pool_genesis_payload;
pub const pool_topology = engine.pool_topology;
pub const replica_endpoint = engine.replica_endpoint;
pub const replicated_journal = engine.replicated_journal;
pub const storage = engine.storage;
pub const storage_window = engine.storage_window;
pub const topology = engine.topology;

pub const file_storage = @import("file_storage.zig");
pub const linux_block_device = if (@import("builtin").os.tag == .linux) @import("linux_block_device.zig") else struct {};
pub const linux_pool_plan = if (@import("builtin").os.tag == .linux) @import("linux_pool_plan.zig") else struct {};

test {
    _ = engine;
    _ = file_storage;
    _ = linux_block_device;
    _ = linux_pool_plan;
}
