const std = @import("std");

const pb = @import("control_proto");
const grpc = @import("grpc_lite");
const raft = @import("raft_zig");
const config_mod = @import("config.zig");
const runtime_mod = @import("runtime.zig");

const config_allocator = std.testing.allocator;
const runtime_allocator = std.heap.smp_allocator;

const node_control_endpoint = "127.0.0.1:9000";
const node_nvmf_endpoint = "127.0.0.1:4420";
const node_failure_domain = "rack-a";
const node_capability_bits: u64 = 5;
const node_protocol_version: u32 = 1;

const test_options: runtime_mod.Options = .{
    .tick_interval_ms = 5,
    .election_tick = 20,
    .heartbeat_tick = 2,
    .proposal_timeout_ticks = 400,
    .read_index_timeout_ticks = 400,
    .snapshot_entries_threshold = 2,
    .management_graceful_timeout_ns = 100 * std.time.ns_per_ms,
    .transport_reconnect_initial_delay_ns = std.time.ns_per_ms,
    .transport_reconnect_max_delay_ns = 20 * std.time.ns_per_ms,
    .transport_graceful_timeout_ns = 100 * std.time.ns_per_ms,
};

const CreatedPool = struct {
    id: []u8,
    revision: u64,

    fn deinit(self: *CreatedPool) void {
        config_allocator.free(self.id);
        self.* = undefined;
    }
};

const RegisteredNode = struct {
    id: []u8,
    revision: u64,

    fn deinit(self: *RegisteredNode) void {
        config_allocator.free(self.id);
        self.* = undefined;
    }
};

test "runtime restores Pool snapshot and WAL suffix through RPC" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", config_allocator);
    defer config_allocator.free(root_path);
    const data_dir = try std.fmt.allocPrintSentinel(config_allocator, "{s}/node-1", .{root_path}, 0);
    defer config_allocator.free(data_dir);
    const ports = try reserveUniquePorts(1);
    const address = try std.fmt.allocPrint(config_allocator, "127.0.0.1:{}", .{ports[0]});
    defer config_allocator.free(address);
    const addresses = [_][]const u8{address};
    var config = try makeConfig(1, .{1} ++ .{0} ** 15, &addresses, data_dir);
    defer config.deinit();

    var primary: CreatedPool = undefined;
    var secondary: CreatedPool = undefined;
    var snapshot_node: RegisteredNode = undefined;
    var suffix_node: RegisteredNode = undefined;
    {
        const runtime = try runtime_mod.Runtime.create(runtime_allocator, std.testing.io, &config, test_options);
        defer destroyRuntime(runtime);
        _ = try waitForStableLeader(&.{runtime});
        primary = try createPool(runtime, "request-primary", "primary");
        errdefer primary.deinit();
        secondary = try createPool(runtime, "request-secondary", "secondary");
        errdefer secondary.deinit();
        snapshot_node = try registerNode(
            runtime,
            &config,
            "request-snapshot-node",
            "0198f54d-5c2a-7000-8000-000000000101",
        );
        errdefer snapshot_node.deinit();
        suffix_node = try registerNode(
            runtime,
            &config,
            "request-suffix-node",
            "0198f54d-5c2a-7000-8000-000000000102",
        );
        errdefer suffix_node.deinit();
        try std.testing.expectEqual(@as(u64, 2), primary.revision);
        try std.testing.expectEqual(@as(u64, 3), secondary.revision);
        try std.testing.expectEqual(@as(u64, 4), snapshot_node.revision);
        try std.testing.expectEqual(@as(u64, 5), suffix_node.revision);
        try expectList(runtime, 2);
        try expectNodeList(runtime, &.{ snapshot_node, suffix_node });
        try runtime.shutdown();
    }
    defer primary.deinit();
    defer secondary.deinit();
    defer snapshot_node.deinit();
    defer suffix_node.deinit();

    {
        const runtime = try runtime_mod.Runtime.create(runtime_allocator, std.testing.io, &config, test_options);
        defer destroyRuntime(runtime);
        _ = try waitForStableLeader(&.{runtime});
        try expectPool(runtime, "primary", primary.id);
        try expectPool(runtime, "secondary", secondary.id);
        try expectList(runtime, 2);
        try expectNode(runtime, &config, snapshot_node);
        try expectNode(runtime, &config, suffix_node);
        try expectNodeList(runtime, &.{ snapshot_node, suffix_node });
        var replayed = try createPool(runtime, "request-primary", "primary");
        defer replayed.deinit();
        try std.testing.expectEqualStrings(primary.id, replayed.id);
        try std.testing.expectEqual(primary.revision, replayed.revision);
        var replayed_snapshot_node = try registerNode(
            runtime,
            &config,
            "request-snapshot-node",
            "0198f54d-5c2a-7000-8000-000000000101",
        );
        defer replayed_snapshot_node.deinit();
        try std.testing.expectEqualStrings(snapshot_node.id, replayed_snapshot_node.id);
        try std.testing.expectEqual(snapshot_node.revision, replayed_snapshot_node.revision);
    }
}

test "three-voter runtime survives leader failover and restart" {
    const node_count = 3;
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", config_allocator);
    defer config_allocator.free(root_path);
    const ports = try reserveUniquePorts(node_count);

    var addresses: [node_count][]u8 = undefined;
    var address_count: usize = 0;
    defer for (addresses[0..address_count]) |address| config_allocator.free(address);
    for (&addresses, ports) |*address, port| {
        address.* = try std.fmt.allocPrint(config_allocator, "127.0.0.1:{}", .{port});
        address_count += 1;
    }
    const address_views: [node_count][]const u8 = addresses;

    var data_dirs: [node_count][:0]u8 = undefined;
    var data_dir_count: usize = 0;
    defer for (data_dirs[0..data_dir_count]) |data_dir| config_allocator.free(data_dir);
    for (&data_dirs, 0..) |*data_dir, index| {
        data_dir.* = try std.fmt.allocPrintSentinel(config_allocator, "{s}/node-{}", .{ root_path, index + 1 }, 0);
        data_dir_count += 1;
    }

    const cluster_id: raft.ClusterId = .{2} ++ .{0} ** 15;
    var configs: [node_count]config_mod.Config = undefined;
    var config_count: usize = 0;
    defer for (configs[0..config_count]) |*config| config.deinit();
    for (&configs, 0..) |*config, index| {
        config.* = try makeConfig(index + 1, cluster_id, &address_views, data_dirs[index]);
        config_count += 1;
    }

    var runtimes: [node_count]?*runtime_mod.Runtime = .{null} ** node_count;
    defer for (&runtimes) |*runtime| if (runtime.*) |value| destroyRuntime(value);
    for (&runtimes, 0..) |*runtime, index| {
        runtime.* = try runtime_mod.Runtime.create(runtime_allocator, std.testing.io, &configs[index], test_options);
    }

    const initial_leader = try waitForStableLeader(&runtimes);
    var created = try createPool(runtimes[initial_leader].?, "request-failover", "failover");
    defer created.deinit();
    try waitForApplied(&runtimes, created.revision);
    var registered = try registerNode(
        runtimes[initial_leader].?,
        &configs[initial_leader],
        "request-node-failover",
        "0198f54d-5c2a-7000-8000-000000000201",
    );
    defer registered.deinit();
    try waitForApplied(&runtimes, registered.revision);

    try runtimes[initial_leader].?.shutdown();
    runtimes[initial_leader].?.deinit();
    runtimes[initial_leader] = null;
    const replacement_leader = try waitForStableLeader(&runtimes);
    try std.testing.expect(replacement_leader != initial_leader);
    try expectPool(runtimes[replacement_leader].?, "failover", created.id);
    try expectList(runtimes[replacement_leader].?, 1);
    try expectNode(runtimes[replacement_leader].?, &configs[replacement_leader], registered);
    try expectNodeList(runtimes[replacement_leader].?, &.{registered});
    var replayed = try createPool(runtimes[replacement_leader].?, "request-failover", "failover");
    defer replayed.deinit();
    try std.testing.expectEqualStrings(created.id, replayed.id);
    try std.testing.expectEqual(created.revision, replayed.revision);
    var replayed_node = try registerNode(
        runtimes[replacement_leader].?,
        &configs[replacement_leader],
        "request-node-failover",
        "0198f54d-5c2a-7000-8000-000000000201",
    );
    defer replayed_node.deinit();
    try std.testing.expectEqualStrings(registered.id, replayed_node.id);
    try std.testing.expectEqual(registered.revision, replayed_node.revision);

    runtimes[initial_leader] = try runtime_mod.Runtime.create(
        runtime_allocator,
        std.testing.io,
        &configs[initial_leader],
        test_options,
    );
    _ = try waitForStableLeader(&runtimes);
    try waitForApplied(&runtimes, replayed.revision);
    try waitForApplied(&runtimes, registered.revision);
}

fn makeConfig(
    node_id: u64,
    cluster_id: raft.ClusterId,
    addresses: []const []const u8,
    data_dir_source: []const u8,
) !config_mod.Config {
    const management_host = try config_allocator.dupe(u8, "127.0.0.1");
    errdefer config_allocator.free(management_host);
    const raft_listen = try config_allocator.dupe(u8, addresses[node_id - 1]);
    errdefer config_allocator.free(raft_listen);
    const raft_advertise = try config_allocator.dupe(u8, addresses[node_id - 1]);
    errdefer config_allocator.free(raft_advertise);
    const data_dir = try config_allocator.dupe(u8, data_dir_source);
    errdefer config_allocator.free(data_dir);
    const peers = try config_allocator.alloc(raft.Peer, addresses.len);
    errdefer config_allocator.free(peers);
    var initialized: usize = 0;
    errdefer for (peers[0..initialized]) |peer| config_allocator.free(peer.context.?);
    for (peers, addresses, 0..) |*peer, address, index| {
        peer.* = .{
            .id = index + 1,
            .context = try config_allocator.dupe(u8, address),
        };
        initialized += 1;
    }
    return .{
        .allocator = config_allocator,
        .node_id = node_id,
        .cluster_id = cluster_id,
        .management_host = management_host,
        .management_port = 0,
        .raft_listen = raft_listen,
        .raft_advertise = raft_advertise,
        .data_dir = data_dir,
        .peers = peers,
    };
}

fn destroyRuntime(runtime: *runtime_mod.Runtime) void {
    if (runtime.running) runtime.shutdown() catch unreachable;
    runtime.deinit();
}

fn waitForStableLeader(runtimes: []const ?*runtime_mod.Runtime) !usize {
    var stable_leader: ?usize = null;
    var stable_rounds: usize = 0;
    for (0..4000) |_| {
        var leader: ?usize = null;
        var multiple = false;
        for (runtimes, 0..) |runtime, index| {
            const value = runtime orelse continue;
            const status = value.status();
            if (status.role != .leader or status.leader_id != status.id) continue;
            if (leader != null) multiple = true else leader = index;
        }
        if (!multiple and leader != null) {
            const leader_id = runtimes[leader.?].?.status().id;
            var all_agree = true;
            for (runtimes) |runtime| {
                const value = runtime orelse continue;
                if (value.status().leader_id != leader_id) all_agree = false;
            }
            if (all_agree and stable_leader == leader) {
                stable_rounds += 1;
            } else if (all_agree) {
                stable_leader = leader;
                stable_rounds = 1;
            } else {
                stable_leader = null;
                stable_rounds = 0;
            }
            if (stable_rounds >= 10) return leader.?;
        } else {
            stable_leader = null;
            stable_rounds = 0;
        }
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.TestTimeout;
}

fn waitForApplied(runtimes: []const ?*runtime_mod.Runtime, revision: u64) !void {
    for (0..2000) |_| {
        var applied = true;
        for (runtimes) |runtime| {
            const value = runtime orelse continue;
            if (value.status().applied_index < revision) applied = false;
        }
        if (applied) return;
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.TestTimeout;
}

fn createPool(runtime: *runtime_mod.Runtime, request_id: []const u8, name: []const u8) !CreatedPool {
    const request = try encodeMessage(pb.CreatePoolRequest{
        .request_id = request_id,
        .name = name,
    });
    defer runtime_allocator.free(request);
    var result = try call(runtime, "/zettide.control.v1.PoolService/CreatePool", request);
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, result.status.code);
    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try pb.CreatePoolResponse.decode(&reader, runtime_allocator);
    defer response.deinit(runtime_allocator);
    const pool = response.pool orelse return error.MissingPool;
    return .{
        .id = try config_allocator.dupe(u8, pool.id),
        .revision = pool.created_revision,
    };
}

fn registerNode(
    runtime: *runtime_mod.Runtime,
    config: *const config_mod.Config,
    request_id: []const u8,
    node_id: []const u8,
) !RegisteredNode {
    const request = try encodeMessage(pb.RegisterNodeRequest{
        .request_id = request_id,
        .node_id = node_id,
        .cluster_id = &config.cluster_id,
        .control_endpoint = node_control_endpoint,
        .nvmf_endpoint = node_nvmf_endpoint,
        .failure_domain = node_failure_domain,
        .capability_bits = node_capability_bits,
        .protocol_version = node_protocol_version,
    });
    defer runtime_allocator.free(request);
    var result = try call(runtime, "/zettide.control.v1.NodeService/RegisterNode", request);
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, result.status.code);
    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try pb.RegisterNodeResponse.decode(&reader, runtime_allocator);
    defer response.deinit(runtime_allocator);
    const node = response.node orelse return error.MissingNode;
    return .{
        .id = try config_allocator.dupe(u8, node.id),
        .revision = node.registered_revision,
    };
}

fn expectPool(runtime: *runtime_mod.Runtime, name: []const u8, expected_id: []const u8) !void {
    const request = try encodeMessage(pb.GetPoolRequest{ .selector = .{ .name = name } });
    defer runtime_allocator.free(request);
    var result = try call(runtime, "/zettide.control.v1.PoolService/GetPool", request);
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, result.status.code);
    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try pb.GetPoolResponse.decode(&reader, runtime_allocator);
    defer response.deinit(runtime_allocator);
    try std.testing.expectEqualStrings(expected_id, response.pool.?.id);
    try std.testing.expectEqualStrings(name, response.pool.?.name);
}

fn expectList(runtime: *runtime_mod.Runtime, expected_count: usize) !void {
    const request = try encodeMessage(pb.ListPoolsRequest{});
    defer runtime_allocator.free(request);
    var result = try call(runtime, "/zettide.control.v1.PoolService/ListPools", request);
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, result.status.code);
    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try pb.ListPoolsResponse.decode(&reader, runtime_allocator);
    defer response.deinit(runtime_allocator);
    try std.testing.expectEqual(expected_count, response.pools.items.len);
}

fn expectNode(
    runtime: *runtime_mod.Runtime,
    config: *const config_mod.Config,
    expected: RegisteredNode,
) !void {
    const request = try encodeMessage(pb.GetNodeRequest{ .node_id = expected.id });
    defer runtime_allocator.free(request);
    var result = try call(runtime, "/zettide.control.v1.NodeService/GetNode", request);
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, result.status.code);
    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try pb.GetNodeResponse.decode(&reader, runtime_allocator);
    defer response.deinit(runtime_allocator);
    const node = response.node orelse return error.MissingNode;
    try std.testing.expectEqualStrings(expected.id, node.id);
    try std.testing.expectEqualSlices(u8, &config.cluster_id, node.cluster_id);
    try std.testing.expectEqualStrings(node_control_endpoint, node.control_endpoint);
    try std.testing.expectEqualStrings(node_nvmf_endpoint, node.nvmf_endpoint);
    try std.testing.expectEqualStrings(node_failure_domain, node.failure_domain);
    try std.testing.expectEqual(node_capability_bits, node.capability_bits);
    try std.testing.expectEqual(node_protocol_version, node.protocol_version);
    try std.testing.expect(node.registered_at_unix_ms > 0);
    try std.testing.expectEqual(expected.revision, node.registered_revision);
}

fn expectNodeList(runtime: *runtime_mod.Runtime, expected_nodes: []const RegisteredNode) !void {
    const request = try encodeMessage(pb.ListNodesRequest{});
    defer runtime_allocator.free(request);
    var result = try call(runtime, "/zettide.control.v1.NodeService/ListNodes", request);
    defer result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.ok, result.status.code);
    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try pb.ListNodesResponse.decode(&reader, runtime_allocator);
    defer response.deinit(runtime_allocator);
    try std.testing.expectEqual(expected_nodes.len, response.nodes.items.len);
    for (expected_nodes) |expected| {
        var found = false;
        for (response.nodes.items) |node| {
            if (!std.mem.eql(u8, expected.id, node.id)) continue;
            try std.testing.expectEqual(expected.revision, node.registered_revision);
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
}

fn call(runtime: *runtime_mod.Runtime, method: []const u8, request: []const u8) !grpc.CallResult {
    const address = try runtime.managementAddress();
    const target = try std.fmt.allocPrint(runtime_allocator, "{s}:{}", .{ address.host, address.port });
    defer runtime_allocator.free(target);
    var channel = try grpc.Channel.init(runtime_allocator, target, .{});
    defer channel.deinit();
    return channel.callUnary(runtime_allocator, method, request, .{ .timeout_ns = 5 * std.time.ns_per_s });
}

fn encodeMessage(message: anytype) ![]u8 {
    var value = message;
    var writer: std.Io.Writer.Allocating = .init(runtime_allocator);
    errdefer writer.deinit();
    try value.encode(&writer.writer, runtime_allocator);
    return writer.toOwnedSlice();
}

fn reserveUniquePorts(comptime count: usize) ![count]u16 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listeners: [count]std.Io.net.Server = undefined;
    var listener_count: usize = 0;
    defer for (listeners[0..listener_count]) |*listener| listener.deinit(std.testing.io);

    var ports: [count]u16 = undefined;
    for (&listeners, 0..) |*listener, index| {
        listener.* = try address.listen(std.testing.io, .{});
        listener_count += 1;
        var local_address: std.posix.sockaddr.in = undefined;
        var address_length: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        if (std.posix.errno(std.posix.system.getsockname(
            listener.socket.handle,
            @ptrCast(&local_address),
            &address_length,
        )) != .SUCCESS) return error.AddressQueryFailed;
        ports[index] = std.mem.bigToNative(u16, local_address.port);
        for (ports[0..index]) |port| try std.testing.expect(port != ports[index]);
    }
    return ports;
}
