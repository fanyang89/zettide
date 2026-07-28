const std = @import("std");

const pb = @import("control_proto");
const raft = @import("raft_zig");
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

test "single-node WAL restores a Pool snapshot before replaying its suffix" {
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

    var snapshot_index: u64 = 0;
    var final_applied_index: u64 = 0;
    {
        var machine = state_machine.PoolStateMachine.init(allocator);
        defer machine.deinit();
        const raftor = try raft.Raftor.create(allocator, config, machine.stateMachine());
        defer raftor.destroy();
        try raftor.campaign();
        try std.testing.expect(raftor.isLeader());

        try proposePool(allocator, raftor, &machine, 1, command(
            "request-primary",
            "0198f54d-5c2a-7000-8000-000000000001",
            "primary",
            1_753_744_000_000,
        ));
        try raftor.takeSnapshot();
        snapshot_index = raftor.getStatus().applied_index;

        try proposePool(allocator, raftor, &machine, 2, command(
            "request-secondary",
            "0198f54d-5c2a-7000-8000-000000000002",
            "secondary",
            1_753_744_000_001,
        ));
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
        var primary = (try machine.getPoolByName(allocator, "primary")).?;
        defer primary.deinit(allocator);

        for (0..32) |_| {
            if (machine.poolCount() == 2) break;
            _ = try raftor.tick();
        }
        try std.testing.expectEqual(@as(usize, 2), machine.poolCount());
        try std.testing.expectEqual(final_applied_index, raftor.getStatus().applied_index);

        try raftor.campaign();
        try proposePool(allocator, raftor, &machine, 3, command(
            "request-archive",
            "0198f54d-5c2a-7000-8000-000000000003",
            "archive",
            1_753_744_000_002,
        ));
    }
}
