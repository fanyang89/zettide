const std = @import("std");

const controller_pb = @import("controller_proto");
const controller_agent = @import("controller_agent.zig");
const data_node = @import("data_node_service");
const grpc = @import("grpc_lite");
const incarnation_store = @import("incarnation_store.zig");
const member_generation_store = @import("member_generation_store.zig");
const replica_rpc_key_file = @import("replica_rpc_key_file.zig");

const registration_attempts = 60;
const registration_retry_delay = std.Io.Duration.fromSeconds(1);

const ReplicaConfig = struct {
    state_dir: []const u8,
    member_file: []const u8,
    member_id: [16]u8,
    pool_id: []const u8,
    metadata_capacity_bytes: u64,
    capacity_bytes: u64,
    extent_size_bytes: u64,
};

const ReplicaRpcConfig = struct {
    listen_host: []const u8,
    listen_port: u16,
    advertise_endpoint: []const u8,
    key_file: []const u8,
};

const Config = struct {
    listen_host: []const u8,
    listen_port: u16,
    advertise_endpoint: []const u8,
    controller_endpoint: []const u8,
    request_id: []const u8,
    node_id: []const u8,
    node_id_bytes: [16]u8,
    cluster_id: [16]u8,
    iscsi_endpoint: []const u8,
    failure_domain: []const u8,
    // M11c supplies this from an owner-only signing seed file.
    signing_public_key: []const u8 = "",
    replica: ?ReplicaConfig,
    replica_rpc: ?ReplicaRpcConfig,
};

const Signals = struct {
    set: std.c.sigset_t,
    previous: std.c.sigset_t,

    fn block() !Signals {
        var result: Signals = undefined;
        if (std.c.sigemptyset(&result.set) != 0 or
            std.c.sigaddset(&result.set, .INT) != 0 or
            std.c.sigaddset(&result.set, .TERM) != 0)
            return error.SignalSetupFailed;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &result.set, &result.previous);
        return result;
    }

    fn wait(self: *Signals) !void {
        var signal_number: c_int = 0;
        if (std.c.sigwait(&self.set, &signal_number) != 0) return error.SignalWaitFailed;
    }

    fn restore(self: *Signals) void {
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.previous, null);
    }
};

pub fn main(init: std.process.Init) !void {
    const config_allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(config_allocator);
    const config = parseArgs(args) catch |err| {
        writeUsage();
        return err;
    };

    const allocator = std.heap.smp_allocator;
    var signals = try Signals.block();
    defer signals.restore();

    var state_dir: ?std.Io.Dir = null;
    defer if (state_dir) |dir| dir.close(init.io);
    var state_lock: ?std.Io.File = null;
    defer if (state_lock) |file| {
        file.unlock(init.io);
        file.close(init.io);
    };
    var replica_store: ?data_node.ReplicaFileStore = null;
    defer if (replica_store) |*store| store.deinit();
    var fence_store: ?data_node.FenceFileStore = null;
    defer if (fence_store) |*store| store.deinit();
    var authority_store: ?data_node.AuthorityFileStore = null;
    defer if (authority_store) |*store| store.deinit();
    var replica_backend: ?data_node.FileMemberBackend = null;
    defer if (replica_backend) |*backend| backend.deinit();
    var fence_backend: ?data_node.FileFenceBackend = null;
    var write_backend: ?data_node.FileWriteBackend = null;
    var replica_peer_keys: ?replica_rpc_key_file.PeerKeys = null;
    defer if (replica_peer_keys) |*keys| keys.deinit();
    var server_options: data_node.Options = .{};
    if (config.replica) |replica| {
        state_dir = try std.Io.Dir.cwd().openDir(init.io, replica.state_dir, .{});
        state_lock = try acquireStateLock(init.io, state_dir.?);
        replica_store = try data_node.ReplicaFileStore.init(
            allocator,
            init.io,
            state_dir.?,
            "replicas.state",
        );
        try replica_store.?.configureCapacity(
            replica.member_id,
            replica.capacity_bytes,
            replica.extent_size_bytes,
        );
        const member_generation = try member_generation_store.loadOrCreate(
            init.io,
            state_dir.?,
            "member-generation.state",
        );
        replica_backend = try data_node.FileMemberBackend.init(
            init.io,
            std.Io.Dir.cwd(),
            replica.member_file,
            replica.member_file,
            replica.member_id,
            member_generation,
            replica.capacity_bytes,
            replica.extent_size_bytes,
        );
        try replica_store.?.validateBackendDigest(replica_backend.?.backend_digest);
        fence_store = try data_node.FenceFileStore.init(
            allocator,
            init.io,
            state_dir.?,
            "fences.state",
        );
        authority_store = try data_node.AuthorityFileStore.init(
            allocator,
            init.io,
            state_dir.?,
            "authority.state",
        );
        fence_backend = data_node.FileFenceBackend.init(&replica_backend.?, &replica_store.?);
        write_backend = data_node.FileWriteBackend.init(&replica_backend.?, &replica_store.?);
        server_options = .{
            .replica_store = replica_store.?.store(),
            .replica_backend = replica_backend.?.backend(),
            .fence_store = fence_store.?.store(),
            .fence_backend = fence_backend.?.backend(),
            .authority_store = &authority_store.?,
            .write_parent = state_dir.?,
            .write_replica_store = &replica_store.?,
            .write_fence_store = &fence_store.?,
            .write_backend = write_backend.?.backend(),
        };
    }
    if (config.replica_rpc) |replica_rpc| {
        replica_peer_keys = try replica_rpc_key_file.load(
            allocator,
            init.io,
            std.Io.Dir.cwd(),
            replica_rpc.key_file,
        );
        server_options.replica_transport = .{
            .host = replica_rpc.listen_host,
            .port = replica_rpc.listen_port,
            .local_node_id = config.node_id_bytes,
            .peer_keys = replica_peer_keys.?.values,
        };
        std.log.warn(
            "Replica RPC plaintext development transport enabled at {s}; payload confidentiality is disabled",
            .{replica_rpc.advertise_endpoint},
        );
    }
    var server = try data_node.DataNodeServer.initWithOptions(
        allocator,
        init.io,
        config.listen_host,
        config.listen_port,
        server_options,
    );
    defer server.deinit();
    if (replica_peer_keys) |*keys| {
        keys.deinit();
        replica_peer_keys = null;
    }
    try server.start();

    try registerNodeWithRetry(allocator, init.io, config);
    var heartbeat_worker: ?*controller_agent.HeartbeatWorker = null;
    defer if (heartbeat_worker) |worker| {
        worker.stopAndJoin();
        allocator.destroy(worker);
    };
    if (config.replica) |replica| {
        const member_config = try controller_agent.MemberConfig.init(
            config.controller_endpoint,
            config.request_id,
            config.node_id,
            config.cluster_id,
            replica.pool_id,
            replica.member_id,
            config.failure_domain,
            replica.metadata_capacity_bytes,
            replica.capacity_bytes,
            @intCast(replica.extent_size_bytes),
        );
        try controller_agent.registerMemberWithRetry(allocator, init.io, member_config);
        const incarnation = try incarnation_store.next(init.io, state_dir.?, "incarnation.state");
        const worker = try allocator.create(controller_agent.HeartbeatWorker);
        errdefer allocator.destroy(worker);
        worker.* = try controller_agent.HeartbeatWorker.init(
            allocator,
            init.io,
            member_config,
            &replica_store.?,
            incarnation,
        );
        try worker.start();
        heartbeat_worker = worker;
    }
    std.log.info(
        "zettide data-node ready control={s} replica={s} iscsi={s} controller={s}",
        .{
            config.advertise_endpoint,
            if (config.replica_rpc) |value| value.advertise_endpoint else "disabled",
            config.iscsi_endpoint,
            config.controller_endpoint,
        },
    );

    try signals.wait();
    if (heartbeat_worker) |worker| worker.stopAndJoin();
    server.shutdownGracefully(5 * std.time.ns_per_s);
    server.wait();
}

fn parseArgs(args: []const []const u8) !Config {
    var listen: ?[]const u8 = null;
    var advertise: ?[]const u8 = null;
    var controller: ?[]const u8 = null;
    var request_id: ?[]const u8 = null;
    var node_id: ?[]const u8 = null;
    var cluster_id: ?[16]u8 = null;
    var iscsi_endpoint: ?[]const u8 = null;
    var failure_domain: []const u8 = "local/docker";
    var state_dir: ?[]const u8 = null;
    var member_file: ?[]const u8 = null;
    var member_id: ?[16]u8 = null;
    var pool_id: ?[]const u8 = null;
    var metadata_capacity: ?u64 = null;
    var member_capacity: ?u64 = null;
    var extent_size: ?u64 = null;
    var replica_listen: ?[]const u8 = null;
    var replica_advertise: ?[]const u8 = null;
    var replica_key_file: ?[]const u8 = null;
    var replica_allow_plaintext = false;

    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.InvalidArguments;
        const name = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, name, "--listen")) {
            listen = value;
        } else if (std.mem.eql(u8, name, "--advertise")) {
            advertise = value;
        } else if (std.mem.eql(u8, name, "--controller")) {
            controller = value;
        } else if (std.mem.eql(u8, name, "--request-id")) {
            request_id = value;
        } else if (std.mem.eql(u8, name, "--node-id")) {
            node_id = value;
        } else if (std.mem.eql(u8, name, "--cluster-id")) {
            var parsed_cluster_id = try parseUuid(value);
            // Match controller.config: uuid.urn.deserialize packs textual bytes
            // least-significant first before the controller writes the u128 in
            // big-endian order.
            std.mem.reverse(u8, &parsed_cluster_id);
            cluster_id = parsed_cluster_id;
        } else if (std.mem.eql(u8, name, "--iscsi-endpoint")) {
            iscsi_endpoint = value;
        } else if (std.mem.eql(u8, name, "--failure-domain")) {
            failure_domain = value;
        } else if (std.mem.eql(u8, name, "--state-dir")) {
            state_dir = value;
        } else if (std.mem.eql(u8, name, "--member-file")) {
            member_file = value;
        } else if (std.mem.eql(u8, name, "--member-id")) {
            member_id = try parseUuid(value);
        } else if (std.mem.eql(u8, name, "--pool-id")) {
            _ = try parseUuid(value);
            pool_id = value;
        } else if (std.mem.eql(u8, name, "--member-metadata-capacity")) {
            metadata_capacity = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, name, "--member-capacity")) {
            member_capacity = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, name, "--extent-size")) {
            extent_size = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, name, "--replica-listen")) {
            replica_listen = value;
        } else if (std.mem.eql(u8, name, "--replica-advertise")) {
            replica_advertise = value;
        } else if (std.mem.eql(u8, name, "--replica-key-file")) {
            replica_key_file = value;
        } else if (std.mem.eql(u8, name, "--replica-allow-plaintext")) {
            if (!std.mem.eql(u8, value, "true")) return error.InvalidArguments;
            replica_allow_plaintext = true;
        } else {
            return error.InvalidArguments;
        }
    }

    const listen_endpoint = listen orelse return error.ListenRequired;
    const parsed_listen = try parseEndpoint(listen_endpoint);
    const advertise_endpoint = advertise orelse return error.AdvertiseRequired;
    _ = try parseEndpoint(advertise_endpoint);
    const controller_endpoint = controller orelse return error.ControllerRequired;
    _ = try parseEndpoint(controller_endpoint);
    const registration_request_id = request_id orelse return error.RequestIdRequired;
    _ = try parseUuid(registration_request_id);
    const stable_node_id = node_id orelse return error.NodeIdRequired;
    const stable_node_id_bytes = try parseUuid(stable_node_id);
    const target_endpoint = iscsi_endpoint orelse return error.IscsiEndpointRequired;
    if (target_endpoint.len == 0 or failure_domain.len == 0) return error.InvalidArguments;

    const replica_field_count: u8 = @as(u8, @intFromBool(state_dir != null)) +
        @as(u8, @intFromBool(member_file != null)) +
        @as(u8, @intFromBool(member_id != null)) +
        @as(u8, @intFromBool(pool_id != null)) +
        @as(u8, @intFromBool(metadata_capacity != null)) +
        @as(u8, @intFromBool(member_capacity != null)) +
        @as(u8, @intFromBool(extent_size != null));
    if (replica_field_count != 0 and replica_field_count != 7) return error.IncompleteReplicaConfiguration;
    if (metadata_capacity == 0 or member_capacity == 0 or extent_size == 0 or
        (extent_size != null and extent_size.? > std.math.maxInt(u32)) or
        (member_capacity != null and extent_size != null and member_capacity.? % extent_size.? != 0))
        return error.InvalidArguments;

    const replica_rpc_field_count: u8 = @as(u8, @intFromBool(replica_listen != null)) +
        @as(u8, @intFromBool(replica_advertise != null)) +
        @as(u8, @intFromBool(replica_key_file != null)) +
        @as(u8, @intFromBool(replica_allow_plaintext));
    if (replica_rpc_field_count != 0 and replica_rpc_field_count != 4)
        return error.IncompleteReplicaRpcConfiguration;
    if (replica_rpc_field_count == 4 and replica_field_count != 7)
        return error.ReplicaRpcRequiresReplicaConfiguration;
    const parsed_replica_listen = if (replica_listen) |value| try parseEndpoint(value) else null;
    if (replica_advertise) |value| _ = try parseEndpoint(value);
    if (replica_key_file) |value| if (value.len == 0) return error.InvalidArguments;

    return .{
        .listen_host = parsed_listen.host,
        .listen_port = parsed_listen.port,
        .advertise_endpoint = advertise_endpoint,
        .controller_endpoint = controller_endpoint,
        .request_id = registration_request_id,
        .node_id = stable_node_id,
        .node_id_bytes = stable_node_id_bytes,
        .cluster_id = cluster_id orelse return error.ClusterIdRequired,
        .iscsi_endpoint = target_endpoint,
        .failure_domain = failure_domain,
        .replica = if (replica_field_count == 7) .{
            .state_dir = state_dir.?,
            .member_file = member_file.?,
            .member_id = member_id.?,
            .pool_id = pool_id.?,
            .metadata_capacity_bytes = metadata_capacity.?,
            .capacity_bytes = member_capacity.?,
            .extent_size_bytes = extent_size.?,
        } else null,
        .replica_rpc = if (replica_rpc_field_count == 4) .{
            .listen_host = parsed_replica_listen.?.host,
            .listen_port = parsed_replica_listen.?.port,
            .advertise_endpoint = replica_advertise.?,
            .key_file = replica_key_file.?,
        } else null,
    };
}

fn acquireStateLock(io: std.Io, state_dir: std.Io.Dir) !std.Io.File {
    const file = try state_dir.createFile(io, "daemon.lock", .{ .truncate = false });
    const locked = file.tryLock(io, .exclusive) catch |err| {
        file.close(io);
        return err;
    };
    if (!locked) {
        file.close(io);
        return error.StateDirectoryLocked;
    }
    return file;
}

const Endpoint = struct {
    host: []const u8,
    port: u16,
};

fn parseEndpoint(value: []const u8) !Endpoint {
    const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidEndpoint;
    const host = value[0..separator];
    if (host.len == 0 or separator + 1 == value.len) return error.InvalidEndpoint;
    const port = std.fmt.parseUnsigned(u16, value[separator + 1 ..], 10) catch
        return error.InvalidEndpoint;
    if (port == 0) return error.InvalidEndpoint;
    return .{ .host = host, .port = port };
}

fn parseUuid(value: []const u8) ![16]u8 {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-')
        return error.InvalidUuid;
    var result: [16]u8 = undefined;
    var source: usize = 0;
    var destination: usize = 0;
    while (destination < result.len) : (destination += 1) {
        while (value[source] == '-') source += 1;
        result[destination] = (try hexNibble(value[source])) << 4 | try hexNibble(value[source + 1]);
        source += 2;
    }
    if (result[6] & 0xf0 != 0x70 or result[8] & 0xc0 != 0x80) return error.InvalidUuid;
    return result;
}

fn hexNibble(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidUuid,
    };
}

fn registerNodeWithRetry(allocator: std.mem.Allocator, io: std.Io, config: Config) !void {
    var attempt: usize = 1;
    while (attempt <= registration_attempts) : (attempt += 1) {
        registerNode(allocator, config) catch |err| {
            if (attempt == registration_attempts) return err;
            std.log.warn(
                "controller registration attempt {d}/{d} failed: {s}",
                .{ attempt, registration_attempts, @errorName(err) },
            );
            try io.sleep(registration_retry_delay, .awake);
            continue;
        };
        return;
    }
    unreachable;
}

fn registerNode(allocator: std.mem.Allocator, config: Config) !void {
    try submitNodeRegistration(allocator, config);
    var current_response = try callGetNode(allocator, config.controller_endpoint, config.node_id);
    defer current_response.deinit(allocator);
    const current = current_response.node orelse return error.MissingRegisteredNode;
    try validateRegisteredNode(config, current);
    const desired_replica_endpoint = if (config.replica_rpc) |value| value.advertise_endpoint else "";
    if (!std.mem.eql(u8, current.replica_endpoint, desired_replica_endpoint) or
        !std.mem.eql(u8, current.signing_public_key, config.signing_public_key))
        return error.RegisteredNodeMismatch;
}

fn submitNodeRegistration(allocator: std.mem.Allocator, config: Config) !void {
    const desired_replica_endpoint = if (config.replica_rpc) |value| value.advertise_endpoint else "";
    var request = controller_pb.RegisterNodeRequest{
        .request_id = config.request_id,
        .node_id = config.node_id,
        .cluster_id = &config.cluster_id,
        .control_endpoint = config.advertise_endpoint,
        // The current controller schema has one data-plane endpoint field. The
        // local E2E profile publishes its iSCSI URL through that field.
        .nvmf_endpoint = config.iscsi_endpoint,
        // Preserve the legacy request only while no signing identity is
        // supplied. M11c enrollment repeats the exact desired endpoint so an
        // existing endpoint and empty key can be safely identity-matched.
        .replica_endpoint = if (config.signing_public_key.len == 0) "" else desired_replica_endpoint,
        .signing_public_key = config.signing_public_key,
        .failure_domain = config.failure_domain,
        .capability_bits = 1,
        .protocol_version = 1,
    };
    var response = try callRegisterNode(allocator, config.controller_endpoint, request);
    defer response.deinit(allocator);
    const registered = response.node orelse return error.MissingRegisteredNode;
    try validateRegisteredNode(config, registered);

    if (desired_replica_endpoint.len == 0) {
        if (registered.replica_endpoint.len != 0) return error.RegisteredNodeMismatch;
        return;
    }
    if (std.mem.eql(u8, registered.replica_endpoint, desired_replica_endpoint)) return;
    if (registered.replica_endpoint.len != 0) return error.RegisteredNodeMismatch;

    const update_request_id = try derivedReplicaEndpointRequestId(config.request_id);
    request.request_id = &update_request_id;
    request.replica_endpoint = desired_replica_endpoint;
    var updated_response = try callRegisterNode(allocator, config.controller_endpoint, request);
    defer updated_response.deinit(allocator);
    const updated = updated_response.node orelse return error.MissingRegisteredNode;
    try validateRegisteredNode(config, updated);
    if (!std.mem.eql(u8, updated.replica_endpoint, desired_replica_endpoint) or
        !std.mem.eql(u8, updated.signing_public_key, config.signing_public_key))
        return error.RegisteredNodeMismatch;
}

fn callGetNode(
    allocator: std.mem.Allocator,
    controller_endpoint: []const u8,
    node_id: []const u8,
) !controller_pb.GetNodeResponse {
    var request = controller_pb.GetNodeRequest{ .node_id = node_id };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try request.encode(&writer.writer, allocator);
    var channel = try grpc.Channel.init(allocator, controller_endpoint, .{});
    defer channel.deinit();
    var result = try channel.callUnary(
        allocator,
        "/zettide.controller.v1.NodeService/GetNode",
        writer.written(),
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer result.deinit();
    if (!result.status.isOk()) return error.ControllerRejectedRegistration;
    var reader: std.Io.Reader = .fixed(result.payload);
    return controller_pb.GetNodeResponse.decode(&reader, allocator);
}

fn callRegisterNode(
    allocator: std.mem.Allocator,
    controller_endpoint: []const u8,
    request: controller_pb.RegisterNodeRequest,
) !controller_pb.RegisterNodeResponse {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try request.encode(&writer.writer, allocator);
    var channel = try grpc.Channel.init(allocator, controller_endpoint, .{});
    defer channel.deinit();
    var result = try channel.callUnary(
        allocator,
        "/zettide.controller.v1.NodeService/RegisterNode",
        writer.written(),
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer result.deinit();
    if (!result.status.isOk()) return error.ControllerRejectedRegistration;
    var reader: std.Io.Reader = .fixed(result.payload);
    return controller_pb.RegisterNodeResponse.decode(&reader, allocator);
}

fn validateRegisteredNode(config: Config, registered: controller_pb.Node) !void {
    if (!std.mem.eql(u8, registered.id, config.node_id) or
        !std.mem.eql(u8, registered.cluster_id, &config.cluster_id) or
        !std.mem.eql(u8, registered.control_endpoint, config.advertise_endpoint) or
        !std.mem.eql(u8, registered.nvmf_endpoint, config.iscsi_endpoint) or
        !std.mem.eql(u8, registered.failure_domain, config.failure_domain) or
        registered.capability_bits != 1 or registered.protocol_version != 1)
        return error.RegisteredNodeMismatch;
}

fn derivedReplicaEndpointRequestId(source: []const u8) ![36]u8 {
    if (source.len != 36) return error.InvalidRequestId;
    _ = try parseUuid(source);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("zettide-node-replica-endpoint-request-v1");
    hasher.update(source);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var id = digest[0..16].*;
    id[6] = (id[6] & 0x0f) | 0x70;
    id[8] = (id[8] & 0x3f) | 0x80;
    return formatUuid(id);
}

fn formatUuid(id: [16]u8) [36]u8 {
    const hex = "0123456789abcdef";
    var result: [36]u8 = undefined;
    var source: usize = 0;
    var destination: usize = 0;
    while (source < id.len) : (source += 1) {
        if (destination == 8 or destination == 13 or destination == 18 or destination == 23) {
            result[destination] = '-';
            destination += 1;
        }
        result[destination] = hex[id[source] >> 4];
        result[destination + 1] = hex[id[source] & 0x0f];
        destination += 2;
    }
    return result;
}

test "replica state directory is lifetime locked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try acquireStateLock(std.testing.io, tmp.dir);
    defer {
        first.unlock(std.testing.io);
        first.close(std.testing.io);
    }
    try std.testing.expectError(error.StateDirectoryLocked, acquireStateLock(std.testing.io, tmp.dir));
}

test "replica file backend arguments are all-or-none" {
    const base = [_][]const u8{
        "zettide-data-node",
        "--listen",
        "127.0.0.1:50052",
        "--advertise",
        "data-node:50052",
        "--controller",
        "controller:50051",
        "--request-id",
        "0198f54d-5c2a-7000-8000-000000000001",
        "--node-id",
        "0198f54d-5c2a-7000-8000-000000000002",
        "--cluster-id",
        "0198f54d-5c2a-7000-8000-000000000003",
        "--iscsi-endpoint",
        "iscsi://data-node/iqn.test/0",
    };
    const unconfigured = try parseArgs(&base);
    try std.testing.expect(unconfigured.replica == null);

    const configured = base ++ [_][]const u8{
        "--state-dir",
        "/state",
        "--member-file",
        "/data/member.img",
        "--member-id",
        "0198f54d-5c2a-7000-8000-000000000004",
        "--pool-id",
        "0198f54d-5c2a-7000-8000-000000000005",
        "--member-metadata-capacity",
        "65536",
        "--member-capacity",
        "1048576",
        "--extent-size",
        "4096",
    };
    const parsed = try parseArgs(&configured);
    try std.testing.expectEqualStrings("/state", parsed.replica.?.state_dir);
    try std.testing.expectEqualStrings(
        "0198f54d-5c2a-7000-8000-000000000005",
        parsed.replica.?.pool_id,
    );
    try std.testing.expectEqual(@as(u64, 65_536), parsed.replica.?.metadata_capacity_bytes);
    try std.testing.expectEqual(@as(u64, 1_048_576), parsed.replica.?.capacity_bytes);
    try std.testing.expectEqual(@as(u64, 4096), parsed.replica.?.extent_size_bytes);

    const with_replica_rpc = configured ++ [_][]const u8{
        "--replica-listen",
        "127.0.0.1:7443",
        "--replica-advertise",
        "data-node:7443",
        "--replica-key-file",
        "/run/secrets/replica.keys",
        "--replica-allow-plaintext",
        "true",
    };
    const parsed_rpc = try parseArgs(&with_replica_rpc);
    try std.testing.expectEqualStrings("127.0.0.1", parsed_rpc.replica_rpc.?.listen_host);
    try std.testing.expectEqual(@as(u16, 7443), parsed_rpc.replica_rpc.?.listen_port);
    try std.testing.expectEqualStrings("data-node:7443", parsed_rpc.replica_rpc.?.advertise_endpoint);

    const incomplete = base ++ [_][]const u8{ "--state-dir", "/state" };
    try std.testing.expectError(error.IncompleteReplicaConfiguration, parseArgs(&incomplete));
    const incomplete_rpc = configured ++ [_][]const u8{ "--replica-listen", "127.0.0.1:7443" };
    try std.testing.expectError(error.IncompleteReplicaRpcConfiguration, parseArgs(&incomplete_rpc));
    const rpc_without_replica = base ++ [_][]const u8{
        "--replica-listen",
        "127.0.0.1:7443",
        "--replica-advertise",
        "data-node:7443",
        "--replica-key-file",
        "/run/secrets/replica.keys",
        "--replica-allow-plaintext",
        "true",
    };
    try std.testing.expectError(
        error.ReplicaRpcRequiresReplicaConfiguration,
        parseArgs(&rpc_without_replica),
    );
}

test "Replica endpoint migration request ID is distinct from node and member registration" {
    const source = "0198f54d-5c2a-7000-8000-000000000003";
    const endpoint_request = try derivedReplicaEndpointRequestId(source);
    const member_config = try controller_agent.MemberConfig.init(
        "127.0.0.1:8001",
        source,
        "0198f54d-5c2a-7000-8000-000000000011",
        @splat(0x11),
        "0198f54d-5c2a-7000-8000-000000000001",
        @splat(0x22),
        "rack-a",
        4096,
        8192,
        4096,
    );
    try std.testing.expect(!std.mem.eql(u8, &endpoint_request, source));
    try std.testing.expect(!std.mem.eql(u8, &endpoint_request, &member_config.request_id));
    try std.testing.expect(!std.mem.eql(u8, &endpoint_request, "0198f54d-5c2a-7000-8000-000000000001"));
    _ = try parseUuid(&endpoint_request);
}

fn writeUsage() void {
    std.debug.print(
        \\usage: zettide-data-node
        \\  --listen HOST:PORT --advertise HOST:PORT --controller HOST:PORT
        \\  --request-id UUIDv7 --node-id UUIDv7 --cluster-id UUIDv7
        \\  --iscsi-endpoint URL [--failure-domain TEXT]
        \\  [--state-dir PATH --member-file PATH --member-id UUIDv7 --pool-id UUIDv7
        \\   --member-metadata-capacity BYTES --member-capacity BYTES --extent-size BYTES]
        \\  [--replica-listen HOST:PORT --replica-advertise HOST:PORT
        \\   --replica-key-file PATH --replica-allow-plaintext true]
        \\
    , .{});
}

test {
    _ = controller_agent;
    _ = incarnation_store;
}
