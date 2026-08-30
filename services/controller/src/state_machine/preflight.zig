const std = @import("std");
const wire = @import("../protobuf_wire.zig");
const schema = @import("schema.zig");

const Fingerprint = schema.Fingerprint;
const RequestKind = schema.RequestKind;
const command_format_version = schema.command_format_version;
const snapshot_format_version = schema.snapshot_format_version;
const max_name_bytes = schema.max_name_bytes;
const max_description_bytes = schema.max_description_bytes;
const max_request_id_bytes = schema.max_request_id_bytes;
const max_node_endpoint_bytes = schema.max_node_endpoint_bytes;
const max_failure_domain_bytes = schema.max_failure_domain_bytes;
const max_consumer_id_bytes = schema.max_consumer_id_bytes;
const max_pools = schema.max_pools;
const max_nodes = schema.max_nodes;
const max_members = schema.max_members;
const volume_target_replica_count = schema.volume_target_replica_count;
const volume_write_quorum = schema.volume_write_quorum;
const volume_read_quorum = schema.volume_read_quorum;
const max_volumes = schema.max_volumes;
const max_volume_tombstones = schema.max_volume_tombstones;
const max_replica_placements = schema.max_replica_placements;
const max_replica_allocations = schema.max_replica_allocations;
const max_volume_attachments = schema.max_volume_attachments;
const max_primary_authorities = schema.max_primary_authorities;
const max_requests = schema.max_requests;
const max_snapshot_bytes = schema.max_snapshot_bytes;
const max_pool_wire_bytes = schema.max_pool_wire_bytes;
const max_node_wire_bytes = schema.max_node_wire_bytes;
const max_member_wire_bytes = schema.max_member_wire_bytes;
const max_volume_wire_bytes = schema.max_volume_wire_bytes;
const max_volume_tombstone_wire_bytes = schema.max_volume_tombstone_wire_bytes;
const max_replica_placement_wire_bytes = schema.max_replica_placement_wire_bytes;
const max_replica_allocation_wire_bytes = schema.max_replica_allocation_wire_bytes;
const max_volume_attachment_wire_bytes = schema.max_volume_attachment_wire_bytes;
const max_primary_authority_wire_bytes = schema.max_primary_authority_wire_bytes;
const max_command_wire_bytes = schema.max_command_wire_bytes;
const max_response_wire_bytes = schema.max_response_wire_bytes;
const max_request_wire_bytes = schema.max_request_wire_bytes;
const validVolumeSize = schema.validVolumeSize;
const validClusterId = schema.validClusterId;
const validFixedNonzero = schema.validFixedNonzero;
const validText = schema.validText;
const validUuidV7 = schema.validUuidV7;
const validUuidV7Bytes = schema.validUuidV7Bytes;

const WireError = wire.Error;
const WireCursor = wire.Cursor;

pub fn preflightCommand(bytes: []const u8) WireError!void {
    _ = try preflightCommandKind(bytes);
}

fn preflightCommandKind(bytes: []const u8) WireError!RequestKind {
    if (bytes.len > max_command_wire_bytes) return error.InvalidWire;
    var cursor = WireCursor{ .bytes = bytes };
    var seen_format = false;
    var format_version: u64 = 0;
    var kind: ?RequestKind = null;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_format) return error.InvalidWire;
            seen_format = true;
            format_version = try cursor.readVarint();
            if (format_version < 1 or format_version > command_format_version) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .create_pool;
            try preflightCreatePool(try cursor.readBytes(max_pool_wire_bytes));
        },
        3 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .register_node;
            try preflightRegisterNode(try cursor.readBytes(max_node_wire_bytes));
        },
        4 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .register_member;
            try preflightRegisterMember(try cursor.readBytes(max_member_wire_bytes));
        },
        5 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .create_volume;
            try preflightCreateVolumeCommand(try cursor.readBytes(max_volume_wire_bytes));
        },
        6 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .delete_volume;
            try preflightDeleteVolumeCommand(try cursor.readBytes(max_volume_wire_bytes));
        },
        7 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .update_volume;
            try preflightUpdateVolumeCommand(try cursor.readBytes(max_volume_wire_bytes));
        },
        8 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .reserve_volume_resources;
            try preflightReserveVolumeResourcesCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        9 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .activate_replica;
            try preflightActivateReplicaCommand(try cursor.readBytes(max_volume_wire_bytes), format_version >= 4);
        },
        10 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .finalize_volume_deletion;
            try preflightFinalizeVolumeDeletionCommand(try cursor.readBytes(max_volume_wire_bytes));
        },
        11 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .propose_primary_authority;
            try preflightProposePrimaryAuthorityCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        12 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .activate_primary_authority;
            try preflightActivatePrimaryAuthorityCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        13 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .commit_primary_authority_ready;
            try preflightCommitPrimaryAuthorityReadyCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        14 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .commit_primary_authority_renewal_ready;
            try preflightCommitPrimaryAuthorityRenewalReadyCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        15 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .abort_primary_authority_candidate;
            try preflightAbortPrimaryAuthorityCandidateCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        16 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .begin_primary_failover;
            try preflightBeginPrimaryFailoverCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        17 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .commit_primary_authority_failover_ready;
            try preflightCommitPrimaryAuthorityFailoverReadyCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        18 => {
            if (field.wire_type != 2 or kind != null) return error.InvalidWire;
            kind = .complete_primary_failover_lease_wait;
            try preflightCompletePrimaryFailoverLeaseWaitCommand(try cursor.readBytes(max_command_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_format) return error.InvalidWire;
    const result = kind orelse return error.InvalidWire;
    if ((result == .create_volume or result == .delete_volume) and format_version < 2) return error.InvalidWire;
    if ((result == .update_volume or result == .reserve_volume_resources or result == .activate_replica or result == .finalize_volume_deletion) and format_version < 3) return error.InvalidWire;
    if ((result == .propose_primary_authority or result == .activate_primary_authority or result == .commit_primary_authority_ready) and format_version < 5) return error.InvalidWire;
    if (result == .commit_primary_authority_renewal_ready and format_version < 6) return error.InvalidWire;
    if (result == .abort_primary_authority_candidate and format_version < 7) return error.InvalidWire;
    if ((result == .begin_primary_failover or result == .commit_primary_authority_failover_ready or result == .complete_primary_failover_lease_wait) and format_version < 8) return error.InvalidWire;
    return result;
}

fn preflightCreatePool(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [6]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 5 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            },
            3 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_name_bytes), max_name_bytes, false)) return error.InvalidWire;
            },
            4 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire;
            },
            5 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5]) return error.InvalidWire;
}

fn preflightRegisterNode(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [11]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 10 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            4, 5 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_node_endpoint_bytes), max_node_endpoint_bytes, false)) return error.InvalidWire,
            6 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_failure_domain_bytes), max_failure_domain_bytes, false)) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            8 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const version = try cursor.readVarint();
                if (version == 0 or version > std.math.maxInt(u32)) return error.InvalidWire;
            },
            9 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            10 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_node_endpoint_bytes), max_node_endpoint_bytes, true)) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5] or !seen[6] or !seen[8] or !seen[9]) return error.InvalidWire;
}

fn preflightRegisterMember(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [13]bool = @splat(false);
    var member_id: ?[]const u8 = null;
    var local_set_id: ?[]const u8 = null;
    while (try cursor.next()) |field| {
        if (field.number > 12 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            3 => {
                if (field.wire_type != 2) return error.InvalidWire;
                member_id = try cursor.readBytes(16);
                if (!validFixedNonzero(member_id.?, 16)) return error.InvalidWire;
            },
            4, 5 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            6 => {
                if (field.wire_type != 2) return error.InvalidWire;
                local_set_id = try cursor.readBytes(16);
                if (!validFixedNonzero(local_set_id.?, 16)) return error.InvalidWire;
            },
            7 => if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u16)) return error.InvalidWire,
            8 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            9, 10 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            11 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const extent_size = try cursor.readVarint();
                if (extent_size == 0 or extent_size > std.math.maxInt(u32)) return error.InvalidWire;
            },
            12 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5] or !seen[6] or
        !seen[8] or !seen[9] or !seen[10] or !seen[11] or !seen[12] or
        std.mem.eql(u8, member_id.?, local_set_id.?)) return error.InvalidWire;
}

fn preflightCreateVolumeCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [8]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 7 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_name_bytes), max_name_bytes, false)) return error.InvalidWire,
            5 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire,
            6 => if (field.wire_type != 0 or !validVolumeSize(try cursor.readVarint())) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[6] or !seen[7]) return error.InvalidWire;
}

fn preflightDeleteVolumeCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [5]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 4 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4]) return error.InvalidWire;
}

fn preflightUpdateVolumeCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [5]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 4 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire,
            4 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[4]) return error.InvalidWire;
}

fn preflightReservation(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [3]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 2 or seen[field.number] or field.wire_type != 2) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => try preflightReservationPlacement(try cursor.readBytes(max_replica_placement_wire_bytes)),
            2 => try preflightReservationAllocation(try cursor.readBytes(max_replica_allocation_wire_bytes)),
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2]) return error.InvalidWire;
}

fn preflightReservationPlacement(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [7]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 6 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => if (field.wire_type != 0 or try cursor.readVarint() >= volume_target_replica_count) return error.InvalidWire,
            5 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            6 => if (field.wire_type != 0 or try cursor.readVarint() != 1) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5] or !seen[6]) return error.InvalidWire;
}

fn preflightReservationAllocation(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [8]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 7 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            5, 6 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            7 => if (field.wire_type != 0 or try cursor.readVarint() != 1) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5] or !seen[6] or !seen[7]) return error.InvalidWire;
}

fn preflightReserveVolumeResourcesCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_volume = false;
    var seen_version = false;
    var count: usize = 0;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 2 or seen_volume or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            seen_volume = true;
        },
        2 => {
            if (field.wire_type != 0 or seen_version or try cursor.readVarint() == 0) return error.InvalidWire;
            seen_version = true;
        },
        3 => {
            if (field.wire_type != 2 or count == volume_target_replica_count) return error.InvalidWire;
            count += 1;
            try preflightReservation(try cursor.readBytes(max_replica_placement_wire_bytes + max_replica_allocation_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_volume or !seen_version or count != volume_target_replica_count) return error.InvalidWire;
}

fn preflightActivateReplicaCommand(bytes: []const u8, require_attestation: bool) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [8]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 7 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        if (field.number <= 3) {
            if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
        } else if (field.number <= 6) {
            if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire;
        } else {
            if (field.wire_type != 2) return error.InvalidWire;
            try preflightReplicaAttestation(try cursor.readBytes(max_replica_placement_wire_bytes));
        }
    }
    for (1..7) |index| if (!seen[index]) return error.InvalidWire;
    if (require_attestation and !seen[7]) return error.InvalidWire;
}

fn preflightReplicaAttestation(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [9]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 8 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4, 7 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            5 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            6 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            8 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4, 5, 7, 8 }) |index| if (!seen[index]) return error.InvalidWire;
}

fn preflightFinalizeVolumeDeletionCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_volume = false;
    var seen_version = false;
    var seen_timestamp = false;
    var placement_count: usize = 0;
    var allocation_count: usize = 0;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 2 or seen_volume or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            seen_volume = true;
        },
        2 => {
            if (field.wire_type != 0 or seen_version or try cursor.readVarint() == 0) return error.InvalidWire;
            seen_version = true;
        },
        3, 4 => {
            if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            if (field.number == 3) placement_count += 1 else allocation_count += 1;
            if (placement_count > volume_target_replica_count or allocation_count > volume_target_replica_count) return error.InvalidWire;
        },
        5 => {
            if (field.wire_type != 0 or seen_timestamp) return error.InvalidWire;
            const timestamp = try cursor.readVarint();
            if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            seen_timestamp = true;
        },
        else => return error.InvalidWire,
    };
    if (!seen_volume or !seen_version or !seen_timestamp) return error.InvalidWire;
}

fn preflightProposePrimaryAuthorityCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [5]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 4 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightPrimaryAuthority(try cursor.readBytes(max_primary_authority_wire_bytes), false);
            },
            2, 4 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validUuidV7Bytes(try cursor.readBytes(16))) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or seen[3] != seen[4]) return error.InvalidWire;
}

fn preflightActivatePrimaryAuthorityCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [9]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 8 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2, 3 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            4...8 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    for (1..9) |index| if (!seen[index]) return error.InvalidWire;
}

fn preflightCommitPrimaryAuthorityReadyCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [11]bool = @splat(false);
    var fence_count: usize = 0;
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 10 or (field.number != 9 and seen[field.number])) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            3 => if (field.wire_type != 2 or (try cursor.readBytes(32)).len != 32) return error.InvalidWire,
            4...8 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            9 => {
                if (field.wire_type != 2 or fence_count == volume_target_replica_count) return error.InvalidWire;
                fence_count += 1;
                try preflightReplicaFenceEvidence(try cursor.readBytes(max_primary_authority_wire_bytes));
            },
            10 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightRecoveryEvidence(try cursor.readBytes(max_primary_authority_wire_bytes));
            },
            else => unreachable,
        }
    }
    for (1..9) |index| if (!seen[index]) return error.InvalidWire;
    if (fence_count != volume_target_replica_count or !seen[10]) return error.InvalidWire;
}

fn preflightCommitPrimaryAuthorityRenewalReadyCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [9]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 8 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            3...8 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    for (1..9) |index| if (!seen[index]) return error.InvalidWire;
}

fn preflightAbortPrimaryAuthorityCandidateCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [7]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 6 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            3...5 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            6 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            else => unreachable,
        }
    }
    for (1..6) |index| if (!seen[index]) return error.InvalidWire;
}

fn preflightBeginPrimaryFailoverCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [8]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 7 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            5 => if (field.wire_type != 2 or !validUuidV7Bytes(try cursor.readBytes(16))) return error.InvalidWire,
            3, 4, 6, 7 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    for (1..8) |index| if (!seen[index]) return error.InvalidWire;
}

fn preflightCompletePrimaryFailoverLeaseWaitCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [9]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 8 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7Bytes(try cursor.readBytes(16))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            4...8 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    for (1..9) |index| if (!seen[index]) return error.InvalidWire;
}

fn preflightCommitPrimaryAuthorityFailoverReadyCommand(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [14]bool = @splat(false);
    var fence_count: usize = 0;
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 13 or (field.number != 12 and seen[field.number])) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7Bytes(try cursor.readBytes(16))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            5...11 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            12 => {
                if (field.wire_type != 2 or fence_count == volume_target_replica_count) return error.InvalidWire;
                fence_count += 1;
                try preflightReplicaFenceEvidence(try cursor.readBytes(max_primary_authority_wire_bytes));
            },
            13 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightRecoveryEvidence(try cursor.readBytes(max_primary_authority_wire_bytes));
            },
            else => unreachable,
        }
    }
    for (1..12) |index| if (!seen[index]) return error.InvalidWire;
    if (fence_count != volume_target_replica_count or !seen[13]) return error.InvalidWire;
}

pub fn preflightSnapshot(bytes: []const u8) WireError!void {
    if (bytes.len > max_snapshot_bytes) return error.InvalidWire;
    var cursor = WireCursor{ .bytes = bytes };
    var seen_format = false;
    var snapshot_version: u32 = 0;
    var pool_count: usize = 0;
    var request_count: usize = 0;
    var node_count: usize = 0;
    var member_count: usize = 0;
    var volume_count: usize = 0;
    var tombstone_count: usize = 0;
    var replica_count: usize = 0;
    var allocation_count: usize = 0;
    var attachment_count: usize = 0;
    var authority_count: usize = 0;
    var authority_candidate_count: usize = 0;
    var failover_count: usize = 0;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_format) return error.InvalidWire;
            seen_format = true;
            const version = try cursor.readVarint();
            if (version < 2 or version > snapshot_format_version) return error.InvalidWire;
            snapshot_version = @intCast(version);
        },
        2 => {
            if (field.wire_type != 2 or pool_count == max_pools) return error.InvalidWire;
            pool_count += 1;
            _ = try cursor.readBytes(max_pool_wire_bytes);
        },
        3 => {
            if (field.wire_type != 2 or request_count == max_requests) return error.InvalidWire;
            request_count += 1;
            _ = try cursor.readBytes(max_request_wire_bytes);
        },
        4 => {
            if (field.wire_type != 2 or node_count == max_nodes) return error.InvalidWire;
            node_count += 1;
            _ = try cursor.readBytes(max_node_wire_bytes);
        },
        5 => {
            if (field.wire_type != 2 or member_count == max_members) return error.InvalidWire;
            member_count += 1;
            _ = try cursor.readBytes(max_member_wire_bytes);
        },
        6 => {
            if (field.wire_type != 2 or volume_count == max_volumes) return error.InvalidWire;
            volume_count += 1;
            _ = try cursor.readBytes(max_volume_wire_bytes);
        },
        7 => {
            if (field.wire_type != 2 or tombstone_count == max_volume_tombstones) return error.InvalidWire;
            tombstone_count += 1;
            _ = try cursor.readBytes(max_volume_tombstone_wire_bytes);
        },
        8 => {
            if (field.wire_type != 2 or replica_count == max_replica_placements) return error.InvalidWire;
            replica_count += 1;
            _ = try cursor.readBytes(max_replica_placement_wire_bytes);
        },
        9 => {
            if (field.wire_type != 2 or allocation_count == max_replica_allocations) return error.InvalidWire;
            allocation_count += 1;
            _ = try cursor.readBytes(max_replica_allocation_wire_bytes);
        },
        10 => {
            if (field.wire_type != 2 or attachment_count == max_volume_attachments) return error.InvalidWire;
            attachment_count += 1;
            _ = try cursor.readBytes(max_volume_attachment_wire_bytes);
        },
        11 => {
            if (field.wire_type != 2 or authority_count == max_primary_authorities) return error.InvalidWire;
            authority_count += 1;
            _ = try cursor.readBytes(max_primary_authority_wire_bytes);
        },
        12 => {
            if (field.wire_type != 2 or authority_candidate_count == max_primary_authorities) return error.InvalidWire;
            authority_candidate_count += 1;
            _ = try cursor.readBytes(max_primary_authority_wire_bytes);
        },
        13 => {
            if (field.wire_type != 2 or failover_count == max_primary_authorities) return error.InvalidWire;
            failover_count += 1;
            _ = try cursor.readBytes(max_primary_authority_wire_bytes);
        },
        else => return error.InvalidWire,
    };
    if (!seen_format or (snapshot_version == 2 and node_count != 0) or
        (snapshot_version < 4 and member_count != 0) or
        (snapshot_version < 5 and (volume_count != 0 or tombstone_count != 0 or replica_count != 0 or allocation_count != 0 or attachment_count != 0)) or
        (snapshot_version < 9 and authority_count != 0) or
        (snapshot_version < 10 and authority_candidate_count != 0) or
        (snapshot_version < 11 and failover_count != 0)) return error.InvalidWire;

    cursor = .{ .bytes = bytes };
    while (try cursor.next()) |field| switch (field.number) {
        1 => _ = try cursor.readVarint(),
        2 => try preflightPool(try cursor.readBytes(max_pool_wire_bytes)),
        3 => try preflightRequest(try cursor.readBytes(max_request_wire_bytes), snapshot_version),
        4 => try preflightNode(try cursor.readBytes(max_node_wire_bytes)),
        5 => try preflightMember(try cursor.readBytes(max_member_wire_bytes)),
        6 => try preflightVolume(try cursor.readBytes(max_volume_wire_bytes)),
        7 => try preflightVolumeTombstone(try cursor.readBytes(max_volume_tombstone_wire_bytes)),
        8 => try preflightReplicaPlacement(try cursor.readBytes(max_replica_placement_wire_bytes)),
        9 => try preflightReplicaAllocation(try cursor.readBytes(max_replica_allocation_wire_bytes)),
        10 => try preflightVolumeAttachment(try cursor.readBytes(max_volume_attachment_wire_bytes)),
        11 => try preflightPrimaryAuthority(try cursor.readBytes(max_primary_authority_wire_bytes), true),
        12 => try preflightPrimaryAuthority(try cursor.readBytes(max_primary_authority_wire_bytes), true),
        13 => try preflightPrimaryFailover(try cursor.readBytes(max_primary_authority_wire_bytes)),
        else => unreachable,
    };
}

fn preflightPrimaryFailover(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [10]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 9 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7Bytes(try cursor.readBytes(16))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            4...6, 8, 9 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const state = try cursor.readVarint();
                if (state < 1 or state > 3) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    for (1..10) |index| if (!seen[index]) return error.InvalidWire;
}

fn preflightPool(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [6]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 5 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_name_bytes), max_name_bytes, false)) return error.InvalidWire;
            },
            3 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire;
            },
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            5 => {
                if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[4] or !seen[5]) return error.InvalidWire;
}

fn preflightNode(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [11]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 10 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            3, 4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_node_endpoint_bytes), max_node_endpoint_bytes, false)) return error.InvalidWire,
            5 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_failure_domain_bytes), max_failure_domain_bytes, false)) return error.InvalidWire,
            6 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const version = try cursor.readVarint();
                if (version == 0 or version > std.math.maxInt(u32)) return error.InvalidWire;
            },
            8 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            9 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            10 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_node_endpoint_bytes), max_node_endpoint_bytes, true)) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5] or !seen[7] or !seen[8] or !seen[9]) return error.InvalidWire;
}

fn preflightMember(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [12]bool = @splat(false);
    var member_id: ?[]const u8 = null;
    var local_set_id: ?[]const u8 = null;
    while (try cursor.next()) |field| {
        if (field.number > 11 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2) return error.InvalidWire;
                member_id = try cursor.readBytes(16);
                if (!validFixedNonzero(member_id.?, 16)) return error.InvalidWire;
            },
            2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => {
                if (field.wire_type != 2) return error.InvalidWire;
                local_set_id = try cursor.readBytes(16);
                if (!validFixedNonzero(local_set_id.?, 16)) return error.InvalidWire;
            },
            5 => if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u16)) return error.InvalidWire,
            6 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            7, 8 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            9 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const extent_size = try cursor.readVarint();
                if (extent_size == 0 or extent_size > std.math.maxInt(u32)) return error.InvalidWire;
            },
            10 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            11 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[6] or !seen[7] or
        !seen[8] or !seen[9] or !seen[10] or !seen[11] or
        std.mem.eql(u8, member_id.?, local_set_id.?)) return error.InvalidWire;
}

fn preflightVolume(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [19]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 18 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_name_bytes), max_name_bytes, false)) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_description_bytes), max_description_bytes, true)) return error.InvalidWire,
            5 => if (field.wire_type != 0 or !validVolumeSize(try cursor.readVarint())) return error.InvalidWire,
            6 => if (field.wire_type != 0 or try cursor.readVarint() != 1) return error.InvalidWire,
            7 => if (field.wire_type != 0 or try cursor.readVarint() != volume_target_replica_count) return error.InvalidWire,
            8 => if (field.wire_type != 0 or try cursor.readVarint() != volume_write_quorum) return error.InvalidWire,
            9 => if (field.wire_type != 0 or try cursor.readVarint() != volume_read_quorum) return error.InvalidWire,
            10 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 4) return error.InvalidWire;
            },
            11, 12 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 5) return error.InvalidWire;
            },
            13, 14 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            15 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            16 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            17, 18 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5] or !seen[6] or !seen[7] or !seen[8] or !seen[9] or
        !seen[10] or !seen[11] or !seen[12] or !seen[13] or !seen[14] or !seen[16] or !seen[17] or !seen[18]) return error.InvalidWire;
}

fn preflightVolumeTombstone(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [4]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 3 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightVolume(try cursor.readBytes(max_volume_wire_bytes));
            },
            2 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            3 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3]) return error.InvalidWire;
}

fn preflightReplicaPlacement(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [11]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 10 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => if (field.wire_type != 0 or try cursor.readVarint() >= volume_target_replica_count) return error.InvalidWire,
            5, 7, 8 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            6 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 3) return error.InvalidWire;
            },
            9 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            10 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5] or !seen[6] or !seen[7] or !seen[8]) return error.InvalidWire;
}

fn preflightReplicaAllocation(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [10]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 9 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            5, 6, 8, 9 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 3) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[5] or !seen[6] or !seen[7] or !seen[8] or !seen[9]) return error.InvalidWire;
}

fn preflightVolumeAttachment(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [10]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 9 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(max_consumer_id_bytes), max_consumer_id_bytes, false)) return error.InvalidWire,
            5 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 2) return error.InvalidWire;
            },
            6 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 4) return error.InvalidWire;
            },
            7, 8, 9 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5] or !seen[6] or !seen[7] or !seen[8] or !seen[9]) return error.InvalidWire;
}

fn preflightPrimaryAuthority(bytes: []const u8, persisted: bool) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [20]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 19 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1, 2, 3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            4, 5, 9 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            6, 7, 8, 13...17 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            10 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > std.math.maxInt(u32)) return error.InvalidWire;
            },
            11 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const value = try cursor.readVarint();
                if (value == 0 or value > 3) return error.InvalidWire;
            },
            12, 18 => if (field.wire_type != 2 or (try cursor.readBytes(32)).len != 32) return error.InvalidWire,
            19 => if (field.wire_type != 0 or try cursor.readVarint() != 1) return error.InvalidWire,
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }) |index| if (!seen[index]) return error.InvalidWire;
    if (persisted != (seen[13] and seen[16])) return error.InvalidWire;
}

fn preflightReplicaFenceEvidence(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [7]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 6 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2, 3 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            5, 6 => if (field.wire_type != 2 or (try cursor.readBytes(32)).len != 32) return error.InvalidWire,
            else => unreachable,
        }
    }
    for (1..7) |index| if (!seen[index]) return error.InvalidWire;
}

fn preflightRecoveryEvidence(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [6]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number == 0 or field.number > 5 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            3 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            4 => if (field.wire_type != 2 or (try cursor.readBytes(32)).len != 32) return error.InvalidWire,
            5 => if (field.wire_type != 0 or try cursor.readVarint() != 1) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[4]) return error.InvalidWire;
}

fn preflightRequest(bytes: []const u8, snapshot_version: u32) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [6]bool = @splat(false);
    var response_bytes: ?[]const u8 = null;
    var command_bytes: ?[]const u8 = null;
    while (try cursor.next()) |field| {
        if (field.number > 5 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2 or !validText(try cursor.readBytes(max_request_id_bytes), max_request_id_bytes, false)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or (try cursor.readBytes(@sizeOf(Fingerprint))).len != @sizeOf(Fingerprint)) return error.InvalidWire;
            },
            3 => {
                if (field.wire_type != 2) return error.InvalidWire;
                response_bytes = try cursor.readBytes(max_response_wire_bytes);
            },
            4 => {
                if (field.wire_type != 2) return error.InvalidWire;
                command_bytes = try cursor.readBytes(max_command_wire_bytes);
            },
            5 => {
                if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[3] or !seen[4] or !seen[5]) return error.InvalidWire;
    const kind = try preflightCommandKind(command_bytes.?);
    if ((snapshot_version == 2 and kind != .create_pool) or
        (snapshot_version < 4 and kind == .register_member) or
        (snapshot_version < 5 and (kind == .create_volume or kind == .delete_volume)) or
        kind == .reserve_volume_resources or kind == .activate_replica or kind == .finalize_volume_deletion or
        kind == .propose_primary_authority or kind == .activate_primary_authority or kind == .commit_primary_authority_ready or
        kind == .commit_primary_authority_renewal_ready or
        kind == .abort_primary_authority_candidate or
        kind == .begin_primary_failover or kind == .commit_primary_authority_failover_ready or
        kind == .complete_primary_failover_lease_wait or
        (kind == .update_volume and snapshot_version < 6)) return error.InvalidWire;
    switch (kind) {
        .create_pool => try preflightApplyResponse(response_bytes.?),
        .register_node => try preflightRegisterNodeApplyResponse(response_bytes.?),
        .register_member => try preflightRegisterMemberApplyResponse(response_bytes.?),
        .create_volume => try preflightCreateVolumeApplyResponse(response_bytes.?),
        .delete_volume => try preflightDeleteVolumeApplyResponse(response_bytes.?),
        .update_volume => try preflightUpdateVolumeApplyResponse(response_bytes.?),
        .reserve_volume_resources,
        .activate_replica,
        .finalize_volume_deletion,
        .propose_primary_authority,
        .activate_primary_authority,
        .commit_primary_authority_ready,
        .commit_primary_authority_renewal_ready,
        .abort_primary_authority_candidate,
        .begin_primary_failover,
        .commit_primary_authority_failover_ready,
        .complete_primary_failover_lease_wait,
        => unreachable,
    }
}

fn preflightUpdateVolumeApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_volume = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code > 6) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_volume) return error.InvalidWire;
            seen_volume = true;
            try preflightVolume(try cursor.readBytes(max_volume_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn preflightApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_pool = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code == 2 or code > 7) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_pool) return error.InvalidWire;
            seen_pool = true;
            try preflightPool(try cursor.readBytes(max_pool_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn preflightRegisterNodeApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_node = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code > 6) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_node) return error.InvalidWire;
            seen_node = true;
            try preflightNode(try cursor.readBytes(max_node_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn preflightRegisterMemberApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_member = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code > 10) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_member) return error.InvalidWire;
            seen_member = true;
            try preflightMember(try cursor.readBytes(max_member_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn preflightCreateVolumeApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen_code = false;
    var seen_volume = false;
    while (try cursor.next()) |field| switch (field.number) {
        1 => {
            if (field.wire_type != 0 or seen_code) return error.InvalidWire;
            seen_code = true;
            const code = try cursor.readVarint();
            if (code == 0 or code > 7) return error.InvalidWire;
        },
        2 => {
            if (field.wire_type != 2 or seen_volume) return error.InvalidWire;
            seen_volume = true;
            try preflightVolume(try cursor.readBytes(max_volume_wire_bytes));
        },
        else => return error.InvalidWire,
    };
    if (!seen_code) return error.InvalidWire;
}

fn preflightDeleteVolumeApplyResponse(bytes: []const u8) WireError!void {
    var cursor = WireCursor{ .bytes = bytes };
    var seen: [7]bool = @splat(false);
    var code: u64 = 0;
    while (try cursor.next()) |field| {
        if (field.number > 6 or seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 0) return error.InvalidWire;
                code = try cursor.readVarint();
                if (code == 0 or code > 8) return error.InvalidWire;
            },
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const timestamp = try cursor.readVarint();
                if (timestamp == 0 or timestamp > std.math.maxInt(i64)) return error.InvalidWire;
            },
            4 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            5 => if (field.wire_type != 0 or try cursor.readVarint() != 1) return error.InvalidWire,
            6 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightVolume(try cursor.readBytes(max_volume_wire_bytes));
            },
            else => unreachable,
        }
    }
    if (!seen[1]) return error.InvalidWire;
    if (seen[2] != seen[3] or seen[2] != seen[4]) return error.InvalidWire;
    if (code == 8) {
        if (!seen[2] or !seen[5] or !seen[6]) return error.InvalidWire;
    } else if (seen[5] or seen[6]) return error.InvalidWire;
}
