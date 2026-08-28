const std = @import("std");
const pb = @import("control_proto");
const uuid = @import("uuid");
const heartbeat = @import("../heartbeat.zig");
const state_machine = @import("../state_machine.zig");
const wire = @import("../protobuf_wire.zig");

pub const max_request_wire_bytes: usize = 4096;
pub const max_heartbeat_request_wire_bytes: usize = 32768;

pub fn preflightCreatePoolRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [4]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 3) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (field.wire_type != 2) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (!validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (!validText(try cursor.readBytes(state_machine.max_name_bytes), state_machine.max_name_bytes, false)) return error.InvalidWire,
            3 => if (!validText(try cursor.readBytes(state_machine.max_description_bytes), state_machine.max_description_bytes, true)) return error.InvalidWire,
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2]) return error.InvalidWire;
}

pub fn preflightGetPoolRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_selector = false;
    while (try cursor.next()) |field| {
        if (field.number > 2) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (field.wire_type != 2) return error.InvalidWire;
        seen_selector = true;
        switch (field.number) {
            1 => if (!validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (!validText(try cursor.readBytes(state_machine.max_name_bytes), state_machine.max_name_bytes, false)) return error.InvalidWire,
            else => return error.InvalidWire,
        }
    }
    if (!seen_selector) return error.InvalidWire;
}

pub fn preflightListPoolsRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [3]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 2) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u32)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
}

pub fn preflightCreateVolumeRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [6]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 5) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_name_bytes), state_machine.max_name_bytes, false)) return error.InvalidWire,
            4 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_description_bytes), state_machine.max_description_bytes, true)) return error.InvalidWire,
            5 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const size_bytes = try cursor.readVarint();
                if (size_bytes < state_machine.min_volume_size_bytes or
                    size_bytes > state_machine.max_volume_size_bytes or
                    size_bytes % state_machine.volume_block_size_bytes != 0)
                {
                    return error.InvalidWire;
                }
            },
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 5 }) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
}

pub fn preflightGetVolumeRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_volume_id = false;
    while (try cursor.next()) |field| {
        if (field.number != 1) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen_volume_id or field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
        seen_volume_id = true;
    }
    if (!seen_volume_id) return error.InvalidWire;
}

pub fn preflightUpdateVolumeRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [5]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 4) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_description_bytes), state_machine.max_description_bytes, true)) return error.InvalidWire,
            4 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 4 }) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
}

pub fn preflightListVolumesRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [4]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 3) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            2 => if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u32)) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            else => unreachable,
        }
    }
}

pub fn preflightDeleteVolumeRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [4]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 3) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            else => unreachable,
        }
    }
    for (1..4) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
}

pub fn preflightRegisterNodeRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [9]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 8) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            4, 5 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_node_endpoint_bytes), state_machine.max_node_endpoint_bytes, false)) return error.InvalidWire,
            6 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_failure_domain_bytes), state_machine.max_failure_domain_bytes, false)) return error.InvalidWire,
            7 => {
                if (field.wire_type != 0) return error.InvalidWire;
                _ = try cursor.readVarint();
            },
            8 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const version = try cursor.readVarint();
                if (version == 0 or version > std.math.maxInt(u32)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 8 }) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
}

pub fn preflightGetNodeRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_node_id = false;
    while (try cursor.next()) |field| {
        if (field.number != 1) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen_node_id or field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
        seen_node_id = true;
    }
    if (!seen_node_id) return error.InvalidWire;
}

pub fn preflightListNodesRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [3]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 2) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u32)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
}

pub fn preflightRegisterMemberRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [12]bool = @splat(false);
    var member_id: []const u8 = &.{};
    var local_set_id: []const u8 = &.{};
    while (try cursor.next()) |field| {
        if (field.number > 11) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validText(try cursor.readBytes(state_machine.max_request_id_bytes), state_machine.max_request_id_bytes, false)) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            3 => {
                if (field.wire_type != 2) return error.InvalidWire;
                member_id = try cursor.readBytes(16);
                if (!validFixedNonzero(member_id, 16)) return error.InvalidWire;
            },
            4, 5 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            6 => {
                if (field.wire_type != 2) return error.InvalidWire;
                local_set_id = try cursor.readBytes(16);
                if (!validFixedNonzero(local_set_id, 16)) return error.InvalidWire;
            },
            7 => {
                if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u16)) return error.InvalidWire;
            },
            8 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(32), 32)) return error.InvalidWire,
            9, 10 => {
                if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire;
            },
            11 => {
                if (field.wire_type != 0) return error.InvalidWire;
                const extent_size = try cursor.readVarint();
                if (extent_size == 0 or extent_size > std.math.maxInt(u32)) return error.InvalidWire;
            },
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 8, 9, 10, 11 }) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
    if (std.mem.eql(u8, member_id, local_set_id)) return error.InvalidWire;
}

pub fn preflightGetMemberRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_member_id = false;
    while (try cursor.next()) |field| {
        if (field.number != 1) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen_member_id or field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire;
        seen_member_id = true;
    }
    if (!seen_member_id) return error.InvalidWire;
}

pub fn preflightListMembersRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [3]bool = @splat(false);
    while (try cursor.next()) |field| {
        if (field.number > 2) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u32)) return error.InvalidWire;
            },
            2 => if (field.wire_type != 2 or !validFixedNonzero(try cursor.readBytes(16), 16)) return error.InvalidWire,
            else => unreachable,
        }
    }
}

pub fn preflightReportHeartbeatRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_heartbeat_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [5]bool = @splat(false);
    var member_ids: [heartbeat.max_members_per_report][]const u8 = undefined;
    var member_count: usize = 0;
    while (try cursor.next()) |field| {
        if (field.number > 5) {
            try cursor.skip(field, max_heartbeat_request_wire_bytes);
            continue;
        }
        if (field.number != 5) {
            if (seen[field.number]) return error.InvalidWire;
            seen[field.number] = true;
        }
        switch (field.number) {
            1 => if (field.wire_type != 2 or !validClusterId(try cursor.readBytes(16))) return error.InvalidWire,
            2 => if (field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire,
            3, 4 => if (field.wire_type != 0 or try cursor.readVarint() == 0) return error.InvalidWire,
            5 => {
                if (field.wire_type != 2 or member_count == heartbeat.max_members_per_report) return error.InvalidWire;
                const member_id = try preflightMemberHeartbeat(try cursor.readBytes(max_heartbeat_request_wire_bytes));
                for (member_ids[0..member_count]) |previous| {
                    if (std.mem.eql(u8, previous, member_id)) return error.InvalidWire;
                }
                member_ids[member_count] = member_id;
                member_count += 1;
            },
            else => unreachable,
        }
    }
    for ([_]usize{ 1, 2, 3, 4 }) |field| {
        if (!seen[field]) return error.InvalidWire;
    }
}

pub fn preflightMemberHeartbeat(payload: []const u8) wire.Error![]const u8 {
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [6]bool = @splat(false);
    var member_id: []const u8 = &.{};
    var local_set_id: []const u8 = &.{};
    var state: u64 = 0;
    while (try cursor.next()) |field| {
        if (field.number > 5) {
            try cursor.skip(field, max_heartbeat_request_wire_bytes);
            continue;
        }
        if (seen[field.number]) return error.InvalidWire;
        seen[field.number] = true;
        switch (field.number) {
            1 => {
                if (field.wire_type != 2) return error.InvalidWire;
                member_id = try cursor.readBytes(16);
                if (!validFixedNonzero(member_id, 16)) return error.InvalidWire;
            },
            2 => {
                if (field.wire_type != 2) return error.InvalidWire;
                local_set_id = try cursor.readBytes(16);
                if (!validFixedNonzero(local_set_id, 16)) return error.InvalidWire;
            },
            3 => if (field.wire_type != 0 or try cursor.readVarint() > std.math.maxInt(u16)) return error.InvalidWire,
            4 => {
                if (field.wire_type != 0) return error.InvalidWire;
                state = try cursor.readVarint();
                if (state != @intFromEnum(pb.MemberHeartbeatState.MEMBER_HEARTBEAT_STATE_PRESENT) and
                    state != @intFromEnum(pb.MemberHeartbeatState.MEMBER_HEARTBEAT_STATE_UNAVAILABLE))
                {
                    return error.InvalidWire;
                }
            },
            5 => {
                if (field.wire_type != 2) return error.InvalidWire;
                try preflightMemberCapacity(try cursor.readBytes(max_heartbeat_request_wire_bytes));
            },
            else => unreachable,
        }
    }
    if (!seen[1] or !seen[2] or !seen[4] or
        std.mem.eql(u8, member_id, local_set_id) or
        (state == @intFromEnum(pb.MemberHeartbeatState.MEMBER_HEARTBEAT_STATE_UNAVAILABLE) and seen[5]))
    {
        return error.InvalidWire;
    }
    return member_id;
}

pub fn preflightMemberCapacity(payload: []const u8) wire.Error!void {
    var cursor = wire.Cursor{ .bytes = payload };
    var seen: [5]bool = @splat(false);
    var total: u64 = 0;
    while (try cursor.next()) |field| {
        if (field.number > 4) {
            try cursor.skip(field, max_heartbeat_request_wire_bytes);
            continue;
        }
        if (seen[field.number] or field.wire_type != 0) return error.InvalidWire;
        seen[field.number] = true;
        total = std.math.add(u64, total, try cursor.readVarint()) catch return error.InvalidWire;
    }
}

pub fn preflightGetHeartbeatRequest(payload: []const u8) wire.Error!void {
    if (payload.len > max_request_wire_bytes) return error.InvalidWire;
    var cursor = wire.Cursor{ .bytes = payload };
    var seen_node_id = false;
    while (try cursor.next()) |field| {
        if (field.number != 1) {
            try cursor.skip(field, max_request_wire_bytes);
            continue;
        }
        if (seen_node_id or field.wire_type != 2 or !validUuidV7(try cursor.readBytes(36))) return error.InvalidWire;
        seen_node_id = true;
    }
    if (!seen_node_id) return error.InvalidWire;
}

fn validText(value: []const u8, max_bytes: usize, allow_empty: bool) bool {
    return (allow_empty or value.len != 0) and value.len <= max_bytes and std.unicode.utf8ValidateSlice(value);
}

fn validClusterId(value: []const u8) bool {
    return validFixedNonzero(value, 16);
}

fn validFixedNonzero(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (byte != 0) return true;
    return false;
}

fn validUuidV7(value: []const u8) bool {
    const parsed = uuid.urn.deserialize(value) catch return false;
    const canonical = uuid.urn.serialize(parsed);
    return canonical[14] == '7' and std.mem.eql(u8, value, &canonical);
}
