const std = @import("std");

const pb = @import("control_proto");
const raft = @import("raftz");
const state_machine = @import("state_machine.zig");

const ProposalProbe = struct {
    machine: *state_machine.PoolStateMachine,
    completed: bool = false,
    visible_pool_count: usize = 0,
    failure: ?raft.Error = null,

    fn callback(self: *ProposalProbe) raft.ProposalCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn complete(ctx: *anyopaque, result: raft.ProposalResult) void {
        const self: *ProposalProbe = @ptrCast(@alignCast(ctx));
        self.completed = true;
        switch (result) {
            .ok => self.visible_pool_count = self.machine.poolCount(),
            .err => |err| self.failure = err,
        }
    }
};

const ResponseProbe = struct {
    allocator: std.mem.Allocator,
    completed: bool = false,
    response: ?[]u8 = null,
    failure: ?raft.Error = null,
    allocation_failed: bool = false,

    fn deinit(self: *ResponseProbe) void {
        if (self.response) |response| self.allocator.free(response);
        self.* = undefined;
    }

    fn callback(self: *ResponseProbe) raft.ProposalCallback {
        return .{ .ctx = self, .function = complete };
    }

    fn complete(ctx: *anyopaque, result: raft.ProposalResult) void {
        const self: *ResponseProbe = @ptrCast(@alignCast(ctx));
        switch (result) {
            .ok => |response| self.response = self.allocator.dupe(u8, response) catch {
                self.allocation_failed = true;
                self.completed = true;
                return;
            },
            .err => |err| self.failure = err,
        }
        self.completed = true;
    }
};

fn command(request_id: []const u8, pool_id: []const u8, name: []const u8, timestamp: i64) pb.CreatePoolCommand {
    return .{
        .request_id = request_id,
        .proposed_pool_id = pool_id,
        .name = name,
        .proposed_created_at_unix_ms = timestamp,
    };
}

fn proposePool(
    allocator: std.mem.Allocator,
    raftor: *raft.Raftor,
    machine: *state_machine.PoolStateMachine,
    expected_pool_count: usize,
    pool_command: pb.CreatePoolCommand,
) !void {
    const encoded = try state_machine.encodeCreatePoolCommand(allocator, pool_command);
    defer allocator.free(encoded);
    var probe = ProposalProbe{ .machine = machine };
    try raftor.propose(encoded, probe.callback());
    for (0..32) |_| {
        if (probe.completed) break;
        _ = try raftor.tick();
    }
    try std.testing.expect(probe.completed);
    try std.testing.expectEqual(@as(?raft.Error, null), probe.failure);
    try std.testing.expectEqual(expected_pool_count, probe.visible_pool_count);
}

fn proposeCommand(allocator: std.mem.Allocator, raftor: *raft.Raftor, encoded: []const u8) ![]u8 {
    var probe = ResponseProbe{ .allocator = allocator };
    defer probe.deinit();
    try raftor.propose(encoded, probe.callback());
    for (0..32) |_| {
        if (probe.completed) break;
        _ = try raftor.tick();
    }
    try std.testing.expect(probe.completed);
    try std.testing.expectEqual(@as(?raft.Error, null), probe.failure);
    if (probe.allocation_failed) return error.OutOfMemory;
    const response = probe.response orelse return error.MissingResponse;
    probe.response = null;
    return response;
}

test "single-node WAL restores Pool and Volume snapshot before replaying its suffix" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_path);
    const data_dir = try std.fmt.allocPrintSentinel(allocator, "{s}/wal", .{root_path}, 0);
    defer allocator.free(data_dir);

    var config: raft.RaftorConfig = .{};
    config.raft.id = 1;
    config.raft.election_timeout_seed = 42;
    config.cluster_id = .{1} ++ .{0} ** 15;
    config.advertise_addr = "test://node-1";
    config.data_dir = data_dir;
    config.snapshot_entries_threshold = 0;

    const pool_id = "0198f54d-5c2a-7000-8000-000000000001";
    const volume_id = "0198f54d-5c2a-7000-8000-000000000011";
    const create_volume_command = pb.CreateVolumeCommand{
        .request_id = "request-volume",
        .proposed_volume_id = volume_id,
        .pool_id = pool_id,
        .name = "database",
        .description = "primary data",
        .size_bytes = state_machine.min_volume_size_bytes,
        .proposed_created_at_unix_ms = 1_753_744_000_001,
    };
    var snapshot_index: u64 = 0;
    var final_applied_index: u64 = 0;
    var volume_revision: u64 = 0;
    var original_create_response: ?[]u8 = null;
    defer if (original_create_response) |response| allocator.free(response);
    var original_delete_response: ?[]u8 = null;
    defer if (original_delete_response) |response| allocator.free(response);
    {
        var machine = state_machine.PoolStateMachine.init(allocator);
        defer machine.deinit();
        const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
        defer raftor.destroy();
        try raftor.campaign();
        try std.testing.expect(raftor.isLeader());

        try proposePool(allocator, raftor, &machine, 1, command(
            "request-primary",
            pool_id,
            "primary",
            1_753_744_000_000,
        ));

        const encoded_create = try state_machine.encodeCreateVolumeCommand(allocator, create_volume_command);
        defer allocator.free(encoded_create);
        original_create_response = try proposeCommand(allocator, raftor, encoded_create);
        var created = try state_machine.decodeCreateVolumeApplyResponse(allocator, original_create_response.?);
        defer created.deinit(allocator);
        try std.testing.expectEqual(pb.CreateVolumeApplyCode.CREATE_VOLUME_APPLY_CODE_CREATED, created.code);
        const volume = created.volume orelse return error.MissingVolume;
        volume_revision = volume.resource_version;
        try std.testing.expect(volume_revision > 0);
        try std.testing.expectEqual(@as(usize, 1), machine.volumeCount());

        try raftor.takeSnapshot();
        snapshot_index = raftor.getStatus().applied_index;

        try proposePool(allocator, raftor, &machine, 2, command(
            "request-secondary",
            "0198f54d-5c2a-7000-8000-000000000002",
            "secondary",
            1_753_744_000_001,
        ));

        const delete_volume_command = pb.DeleteVolumeCommand{
            .request_id = "request-delete-volume",
            .volume_id = volume_id,
            .expected_resource_version = volume_revision,
            .proposed_deleted_at_unix_ms = 1_753_744_000_002,
        };
        const encoded_delete = try state_machine.encodeDeleteVolumeCommand(allocator, delete_volume_command);
        defer allocator.free(encoded_delete);
        original_delete_response = try proposeCommand(allocator, raftor, encoded_delete);
        var deleted = try state_machine.decodeDeleteVolumeApplyResponse(allocator, original_delete_response.?);
        defer deleted.deinit(allocator);
        try std.testing.expectEqual(pb.DeleteVolumeApplyCode.DELETE_VOLUME_APPLY_CODE_DELETED, deleted.code);
        try std.testing.expect(deleted.accepted_revision > volume_revision);
        try std.testing.expect(!deleted.deletion_pending);
        try std.testing.expectEqual(@as(usize, 0), machine.volumeCount());
        try std.testing.expectEqual(@as(usize, 1), machine.volumeTombstoneCount());

        final_applied_index = raftor.getStatus().applied_index;
        try std.testing.expect(final_applied_index > snapshot_index);
    }

    {
        var machine = state_machine.PoolStateMachine.init(allocator);
        defer machine.deinit();
        const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
        defer raftor.destroy();
        try std.testing.expectEqual(snapshot_index, raftor.getStatus().applied_index);
        try std.testing.expectEqual(@as(usize, 1), machine.poolCount());
        try std.testing.expectEqual(@as(usize, 1), machine.volumeCount());
        try std.testing.expectEqual(@as(usize, 0), machine.volumeTombstoneCount());
        var primary = (try machine.getPoolByName(allocator, "primary")).?;
        defer primary.deinit(allocator);
        var volume = (try machine.getVolumeById(allocator, volume_id)).?;
        defer volume.deinit(allocator);
        try std.testing.expectEqualStrings(pool_id, volume.pool_id);
        try std.testing.expectEqualStrings("database", volume.name);
        try std.testing.expectEqual(volume_revision, volume.resource_version);

        for (0..32) |_| {
            if (machine.poolCount() == 2 and machine.volumeTombstoneCount() == 1) break;
            _ = try raftor.tick();
        }
        try std.testing.expectEqual(@as(usize, 2), machine.poolCount());
        try std.testing.expectEqual(@as(usize, 0), machine.volumeCount());
        try std.testing.expectEqual(@as(usize, 1), machine.volumeTombstoneCount());
        try std.testing.expectEqual(@as(?pb.Volume, null), try machine.getVolumeById(allocator, volume_id));
        try std.testing.expectEqual(final_applied_index, raftor.getStatus().applied_index);

        try raftor.campaign();
        const encoded_create = try state_machine.encodeCreateVolumeCommand(allocator, create_volume_command);
        defer allocator.free(encoded_create);
        const replayed_create = try proposeCommand(allocator, raftor, encoded_create);
        defer allocator.free(replayed_create);
        try std.testing.expectEqualSlices(u8, original_create_response.?, replayed_create);

        const encoded_delete = try state_machine.encodeDeleteVolumeCommand(allocator, .{
            .request_id = "request-delete-volume",
            .volume_id = volume_id,
            .expected_resource_version = volume_revision,
            .proposed_deleted_at_unix_ms = 1_753_744_000_002,
        });
        defer allocator.free(encoded_delete);
        const replayed_delete = try proposeCommand(allocator, raftor, encoded_delete);
        defer allocator.free(replayed_delete);
        try std.testing.expectEqualSlices(u8, original_delete_response.?, replayed_delete);
        try std.testing.expectEqual(@as(usize, 0), machine.volumeCount());
        try std.testing.expectEqual(@as(usize, 1), machine.volumeTombstoneCount());

        try proposePool(allocator, raftor, &machine, 3, command(
            "request-archive",
            "0198f54d-5c2a-7000-8000-000000000003",
            "archive",
            1_753_744_000_002,
        ));
    }
}
