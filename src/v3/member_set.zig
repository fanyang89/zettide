const std = @import("std");
const genesis_payload_format = @import("genesis_payload.zig");
const layout_format = @import("layout.zig");
const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const topology_format = @import("topology.zig");

pub const member_count = topology_format.member_count;

pub const Location = struct {
    parent: std.Io.Dir,
    basename: []const u8,
};

pub const CreateOptions = struct {
    member_options: [member_count]member_api.CreateOptions = .{ .{}, .{}, .{} },
};

pub const MemberSet = struct {
    members: [member_count]member_api.Member,

    pub fn create(
        io: std.Io,
        locations: [member_count]Location,
        headers: [member_count]member_format.Header,
        genesis_payload: genesis_payload_format.GenesisPayload,
        options: CreateOptions,
    ) !MemberSet {
        try validateCreate(locations, headers, genesis_payload);

        var members: [member_count]member_api.Member = undefined;
        var initialized: usize = 0;
        errdefer for (members[0..initialized]) |*member| member.deinit();

        for (0..member_count) |slot| {
            members[slot] = try member_api.createAt(
                io,
                locations[slot].parent,
                locations[slot].basename,
                headers[slot],
                genesis_payload,
                options.member_options[slot],
            );
            initialized += 1;
        }
        return .{ .members = members };
    }

    pub fn memberAt(self: *MemberSet, slot: u16) !*member_api.Member {
        if (slot >= member_count) return error.InvalidMemberSlot;
        return &self.members[slot];
    }

    pub fn close(self: *MemberSet) !void {
        var first_error: ?anyerror = null;
        for (&self.members) |*member| {
            member.close() catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        if (first_error) |err| return err;
    }

    pub fn deinit(self: *MemberSet) void {
        self.close() catch {};
    }
};

pub fn create(
    io: std.Io,
    locations: [member_count]Location,
    headers: [member_count]member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
    options: CreateOptions,
) !MemberSet {
    return MemberSet.create(io, locations, headers, genesis_payload, options);
}

pub fn validateCreate(
    locations: [member_count]Location,
    headers: [member_count]member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
) !void {
    for (locations, 0..) |location, index| {
        for (locations[0..index]) |previous| {
            if (location.parent.handle == previous.parent.handle and
                std.mem.eql(u8, location.basename, previous.basename))
                return error.DuplicateMemberLocation;
        }
    }
    for (0..member_count) |slot| {
        if (headers[slot].member_slot != slot) return error.MemberPathSlotMismatch;
        try member_api.validateCreateAt(locations[slot].basename, headers[slot], genesis_payload);
    }
    const genesis_topology_digest = try topology_format.digest(genesis_payload.topology);
    try topology_format.validateMemberSet(genesis_payload.topology, genesis_topology_digest, &headers);
    try layout_format.validateAgainstTopology(genesis_payload.layout, genesis_payload.topology);
    try layout_format.validateAgainstHeaders(genesis_payload.layout, &headers);
}

fn testPayload() genesis_payload_format.GenesisPayload {
    return .{
        .topology = .{
            .set_id = @splat(0x10),
            .epoch = 1,
            .parent_digest = @splat(0),
            .members = .{
                .{ .member_id = @splat(0x20), .slot = 0 },
                .{ .member_id = @splat(0x30), .slot = 1 },
                .{ .member_id = @splat(0x40), .slot = 2 },
            },
        },
        .layout = .{ .layout_epoch = 1, .topology_epoch = 1, .chunk_size = 1024 * 1024 },
    };
}

fn testHeaders(payload: genesis_payload_format.GenesisPayload) ![member_count]member_format.Header {
    const data_offset = 2 * 1024 * 1024;
    var headers: [member_count]member_format.Header = undefined;
    for (&headers, 0..) |*header, slot| {
        header.* = .{
            .header_sequence = 1,
            .set_id = payload.topology.set_id,
            .member_id = payload.topology.members[slot].member_id,
            .member_slot = @intCast(slot),
            .created_ns = 1,
            .member_bytes = data_offset + 1024 * 1024,
            .logical_capacity = 1024 * 1024,
            .control = .{ .offset = 64 * 1024, .length = 4 * 4096 },
            .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
            .data = .{ .offset = data_offset, .length = 1024 * 1024 },
            .metadata_block_size = 4096,
            .metadata_read_size = 512,
            .metadata_program_size = 512,
            .chunk_size = 1024 * 1024,
            .metadata_format_version = 1,
            .object_format_version = 1,
            .layout_format_version = 1,
            .control_record_format_version = 1,
            .label = try member_format.Label.init("member-set-test"),
            .genesis_topology_digest = try topology_format.digest(payload.topology),
        };
    }
    return headers;
}

fn testLocations(dir: std.Io.Dir) [member_count]Location {
    return .{
        .{ .parent = dir, .basename = "member0" },
        .{ .parent = dir, .basename = "member1" },
        .{ .parent = dir, .basename = "member2" },
    };
}

test "create publishes three slot-indexed members and closes every lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    var set = try create(std.testing.io, testLocations(tmp.dir), headers, payload, .{});

    for (0..member_count) |slot| {
        const created = try set.memberAt(@intCast(slot));
        try std.testing.expectEqual(@as(u16, @intCast(slot)), created.header().member_slot);
        try std.testing.expectEqualSlices(u8, &headers[slot].member_id, &created.header().member_id);
    }
    try std.testing.expectError(error.InvalidMemberSlot, set.memberAt(member_count));
    try set.close();
    try set.close();

    for (testLocations(tmp.dir)) |location| {
        var reopened = try member_api.openAt(std.testing.io, location.parent, location.basename, .writable);
        try reopened.close();
    }
}

test "set validation rejects every input before creating a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    var locations = testLocations(tmp.dir);
    var headers = try testHeaders(payload);
    locations[2] = locations[0];

    try std.testing.expectError(error.DuplicateMemberLocation, create(std.testing.io, locations, headers, payload, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "member0", .{}));

    locations = testLocations(tmp.dir);
    headers[2].member_slot = 1;

    try std.testing.expectError(error.MemberPathSlotMismatch, create(std.testing.io, locations, headers, payload, .{}));
    for (locations) |location|
        try std.testing.expectError(error.FileNotFound, location.parent.openFile(std.testing.io, location.basename, .{}));

    headers = try testHeaders(payload);
    locations[2].basename = "bad/name";
    try std.testing.expectError(error.InvalidBasename, create(std.testing.io, locations, headers, payload, .{}));
    locations = testLocations(tmp.dir);
    for (locations) |location|
        try std.testing.expectError(error.FileNotFound, location.parent.openFile(std.testing.io, location.basename, .{}));

    headers = try testHeaders(payload);
    headers[2].created_ns += 1;
    try std.testing.expectError(error.StaticSetFieldsMismatch, create(std.testing.io, locations, headers, payload, .{}));
    for (locations) |location|
        try std.testing.expectError(error.FileNotFound, location.parent.openFile(std.testing.io, location.basename, .{}));
}

test "partial set creation closes members and retains only attempted files" {
    for ([_]usize{ 1, 2 }) |failed_slot| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const payload = testPayload();
        const headers = try testHeaders(payload);
        const locations = testLocations(tmp.dir);
        var fault: member_api.CreateFaultController = .{
            .fail = .{ .point = .genesis_write, .action = .before },
        };
        var options: CreateOptions = .{};
        options.member_options[failed_slot].fault = &fault;

        try std.testing.expectError(error.InjectedCreateFault, create(std.testing.io, locations, headers, payload, options));
        for (locations[0..failed_slot]) |location| {
            var reopened = try member_api.openAt(std.testing.io, location.parent, location.basename, .writable);
            try reopened.close();
        }
        const retained = try locations[failed_slot].parent.openFile(
            std.testing.io,
            locations[failed_slot].basename,
            .{},
        );
        retained.close(std.testing.io);
        for (locations[failed_slot + 1 ..]) |location|
            try std.testing.expectError(error.FileNotFound, location.parent.openFile(std.testing.io, location.basename, .{}));
    }
}

test "close reports the first error after releasing every member" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    const headers = try testHeaders(payload);
    const locations = testLocations(tmp.dir);
    var set = try create(std.testing.io, locations, headers, payload, .{});
    var fault: member_api.FaultController = .{ .fail_sync_at = 0 };
    set.members[0].setFaultController(&fault);
    try set.members[0].write(.metadata, 0, &.{1});

    try std.testing.expectError(error.InjectedFault, set.close());
    try set.close();
    for (locations) |location| {
        var reopened = try member_api.openAt(std.testing.io, location.parent, location.basename, .writable);
        try reopened.close();
    }
}
