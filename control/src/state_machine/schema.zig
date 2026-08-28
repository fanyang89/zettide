const std = @import("std");
const uuid = @import("uuid");

pub const command_format_version: u32 = 8;
pub const snapshot_format_version: u32 = 11;
pub const max_name_bytes: usize = 127;
pub const max_description_bytes: usize = 1024;
pub const max_request_id_bytes: usize = 127;
pub const max_node_endpoint_bytes: usize = 1024;
pub const max_failure_domain_bytes: usize = 255;
pub const max_pools: usize = 25_000;
pub const max_nodes: usize = 10_000;
pub const max_members: usize = 10_000;
pub const min_volume_size_bytes: u64 = 256 * 1024;
pub const volume_block_size_bytes: u64 = 4096;
pub const max_volume_size_bytes: u64 = @as(u64, std.math.maxInt(u32)) * volume_block_size_bytes;
pub const volume_target_replica_count: u32 = 3;
pub const volume_write_quorum: u32 = 2;
pub const volume_read_quorum: u32 = 1;
pub const max_volumes: usize = 25_000;
pub const max_volume_tombstones: usize = 25_000;
pub const max_replica_placements: usize = max_volumes * @as(usize, volume_target_replica_count);
pub const max_replica_allocations: usize = max_replica_placements;
pub const max_volume_attachments: usize = max_volumes;
pub const max_primary_authorities: usize = max_volumes;
pub const max_consumer_id_bytes: usize = 255;
pub const max_requests: usize = 50_000;
pub const max_snapshot_bytes: usize = 256 * 1024 * 1024;

pub const max_pool_wire_bytes: usize = 2048;
pub const max_node_wire_bytes: usize = 4096;
pub const max_member_wire_bytes: usize = 4096;
pub const max_volume_wire_bytes: usize = 4096;
pub const max_volume_tombstone_wire_bytes: usize = 8192;
pub const max_replica_placement_wire_bytes: usize = 2048;
pub const max_replica_allocation_wire_bytes: usize = 2048;
pub const max_volume_attachment_wire_bytes: usize = 4096;
pub const max_primary_authority_wire_bytes: usize = 4096;
pub const max_command_wire_bytes: usize = 8192;
pub const max_response_wire_bytes: usize = 8192;
pub const max_request_wire_bytes: usize = max_request_id_bytes + @sizeOf(Fingerprint) + max_response_wire_bytes + max_command_wire_bytes + 40;

pub const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const RequestKind = enum {
    create_pool,
    register_node,
    register_member,
    create_volume,
    update_volume,
    delete_volume,
    reserve_volume_resources,
    activate_replica,
    finalize_volume_deletion,
    propose_primary_authority,
    activate_primary_authority,
    commit_primary_authority_ready,
    commit_primary_authority_renewal_ready,
    abort_primary_authority_candidate,
    begin_primary_failover,
    commit_primary_authority_failover_ready,
    complete_primary_failover_lease_wait,
};

pub fn validVolumeSize(size_bytes: u64) bool {
    return size_bytes >= min_volume_size_bytes and size_bytes <= max_volume_size_bytes and size_bytes % volume_block_size_bytes == 0;
}

pub fn validClusterId(value: []const u8) bool {
    return validFixedNonzero(value, 16);
}

pub fn validFixedNonzero(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (byte != 0) return true;
    return false;
}

pub fn validText(value: []const u8, max_bytes: usize, allow_empty: bool) bool {
    return (allow_empty or value.len != 0) and value.len <= max_bytes and std.unicode.utf8ValidateSlice(value);
}

pub fn validUuidV7(value: []const u8) bool {
    const parsed = uuid.urn.deserialize(value) catch return false;
    const canonical = uuid.urn.serialize(parsed);
    return canonical[14] == '7' and std.mem.eql(u8, value, &canonical);
}

pub fn validUuidV7Bytes(value: []const u8) bool {
    return value.len == 16 and value[6] >> 4 == 7 and value[8] >> 6 == 2;
}
