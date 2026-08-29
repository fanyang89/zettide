const std = @import("std");

const pb = @import("controller_proto");
const data_node = @import("data_node_service");
const grpc = @import("grpc_lite");

const registration_attempts = 60;
const retry_interval_ms: u32 = 1_000;
const rpc_timeout_ns = 5 * std.time.ns_per_s;

pub const MemberConfig = struct {
    controller_endpoint: []const u8,
    request_id: [36]u8,
    node_id: []const u8,
    cluster_id: [16]u8,
    pool_id: []const u8,
    member_id: [16]u8,
    local_set_id: [16]u8,
    birth_topology_digest: [32]u8,
    metadata_capacity_bytes: u64,
    data_capacity_bytes: u64,
    extent_size_bytes: u32,
    member_slot: u32 = 0,

    pub fn init(
        controller_endpoint: []const u8,
        request_id: []const u8,
        node_id: []const u8,
        cluster_id: [16]u8,
        pool_id: []const u8,
        member_id: [16]u8,
        failure_domain: []const u8,
        metadata_capacity_bytes: u64,
        data_capacity_bytes: u64,
        extent_size_bytes: u32,
    ) !MemberConfig {
        if (controller_endpoint.len == 0 or request_id.len == 0 or node_id.len == 0 or pool_id.len == 0 or
            metadata_capacity_bytes == 0 or data_capacity_bytes == 0 or extent_size_bytes == 0 or
            data_capacity_bytes % extent_size_bytes != 0)
            return error.InvalidMemberConfiguration;
        const local_set_id = localSetId(member_id, node_id);
        return .{
            .controller_endpoint = controller_endpoint,
            .request_id = try derivedRequestId(request_id),
            .node_id = node_id,
            .cluster_id = cluster_id,
            .pool_id = pool_id,
            .member_id = member_id,
            .local_set_id = local_set_id,
            .birth_topology_digest = birthTopologyDigest(
                cluster_id,
                pool_id,
                node_id,
                member_id,
                local_set_id,
                failure_domain,
                metadata_capacity_bytes,
                data_capacity_bytes,
                extent_size_bytes,
            ),
            .metadata_capacity_bytes = metadata_capacity_bytes,
            .data_capacity_bytes = data_capacity_bytes,
            .extent_size_bytes = extent_size_bytes,
        };
    }
};

pub fn registerMemberWithRetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: MemberConfig,
) !void {
    var attempt: usize = 1;
    while (attempt <= registration_attempts) : (attempt += 1) {
        registerMember(allocator, config) catch |err| {
            if (attempt == registration_attempts) return err;
            std.log.warn(
                "member registration attempt {d}/{d} failed: {s}",
                .{ attempt, registration_attempts, @errorName(err) },
            );
            try io.sleep(.fromMilliseconds(retry_interval_ms), .awake);
            continue;
        };
        return;
    }
    unreachable;
}

fn registerMember(allocator: std.mem.Allocator, config: MemberConfig) !void {
    var request: pb.RegisterMemberRequest = .{
        .request_id = &config.request_id,
        .cluster_id = &config.cluster_id,
        .member_id = &config.member_id,
        .pool_id = config.pool_id,
        .node_id = config.node_id,
        .local_set_id = &config.local_set_id,
        .member_slot = config.member_slot,
        .birth_topology_digest = &config.birth_topology_digest,
        .metadata_capacity_bytes = config.metadata_capacity_bytes,
        .data_capacity_bytes = config.data_capacity_bytes,
        .extent_size_bytes = config.extent_size_bytes,
    };
    var response = try unary(
        allocator,
        config.controller_endpoint,
        "/zettide.controller.v1.MemberService/RegisterMember",
        &request,
        pb.RegisterMemberResponse,
    );
    defer response.deinit(allocator);
    const member = response.member orelse return error.MissingRegisteredMember;
    if (!std.mem.eql(u8, member.id, &config.member_id) or
        !std.mem.eql(u8, member.pool_id, config.pool_id) or
        !std.mem.eql(u8, member.node_id, config.node_id) or
        !std.mem.eql(u8, member.local_set_id, &config.local_set_id) or
        member.member_slot != config.member_slot or
        !std.mem.eql(u8, member.birth_topology_digest, &config.birth_topology_digest) or
        member.metadata_capacity_bytes != config.metadata_capacity_bytes or
        member.data_capacity_bytes != config.data_capacity_bytes or
        member.extent_size_bytes != config.extent_size_bytes)
        return error.RegisteredMemberMismatch;
}

pub const HeartbeatWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: MemberConfig,
    store: *data_node.ReplicaFileStore,
    incarnation: u64,
    stopping: std.atomic.Value(bool) = .init(false),
    event: std.Io.Event = .unset,
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: MemberConfig,
        store: *data_node.ReplicaFileStore,
        incarnation: u64,
    ) !HeartbeatWorker {
        if (incarnation == 0) return error.InvalidIncarnation;
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .store = store,
            .incarnation = incarnation,
        };
    }

    pub fn start(self: *HeartbeatWorker) !void {
        if (self.thread != null) return error.AlreadyStarted;
        self.stopping.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stopAndJoin(self: *HeartbeatWorker) void {
        self.stopping.store(true, .release);
        self.event.set(self.io);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn run(self: *HeartbeatWorker) void {
        var sequence: u64 = 1;
        var interval_ms: u32 = retry_interval_ms;
        while (!self.stopping.load(.acquire)) {
            const capacity = self.store.capacitySnapshot() catch |err| {
                std.log.warn("capacity snapshot failed: {s}", .{@errorName(err)});
                if (!self.wait(retry_interval_ms)) return;
                continue;
            };
            while (!self.stopping.load(.acquire)) {
                interval_ms = self.report(sequence, capacity) catch |err| {
                    std.log.warn(
                        "heartbeat incarnation={d} sequence={d} failed: {s}",
                        .{ self.incarnation, sequence, @errorName(err) },
                    );
                    if (!self.wait(retry_interval_ms)) return;
                    continue;
                };
                break;
            }
            if (self.stopping.load(.acquire)) return;
            sequence = std.math.add(u64, sequence, 1) catch {
                std.log.err("heartbeat sequence exhausted", .{});
                return;
            };
            if (!self.wait(interval_ms)) return;
        }
    }

    fn report(self: *HeartbeatWorker, sequence: u64, capacity: data_node.ReplicaCapacitySnapshot) !u32 {
        var members = [_]pb.MemberHeartbeat{.{
            .member_id = &self.config.member_id,
            .local_set_id = &self.config.local_set_id,
            .member_slot = self.config.member_slot,
            .state = .MEMBER_HEARTBEAT_STATE_PRESENT,
            .capacity = .{
                .free_extent_count = capacity.free_extent_count,
                .allocated_extent_count = capacity.allocated_extent_count,
                .reserved_extent_count = capacity.reserved_extent_count,
                .retired_extent_count = capacity.retired_extent_count,
            },
        }};
        var request: pb.ReportHeartbeatRequest = .{
            .cluster_id = &self.config.cluster_id,
            .node_id = self.config.node_id,
            .incarnation = self.incarnation,
            .sequence = sequence,
            .members = .{ .items = &members, .capacity = members.len },
        };
        var response = try unary(
            self.allocator,
            self.config.controller_endpoint,
            "/zettide.controller.v1.HeartbeatService/ReportHeartbeat",
            &request,
            pb.ReportHeartbeatResponse,
        );
        defer response.deinit(self.allocator);
        const observation = response.observation orelse return error.MissingHeartbeatObservation;
        if (!std.mem.eql(u8, observation.node_id, self.config.node_id) or
            observation.incarnation != self.incarnation or observation.sequence != sequence or
            observation.members.items.len != 1)
            return error.HeartbeatObservationMismatch;
        const echoed = observation.members.items[0];
        const echoed_capacity = echoed.capacity orelse return error.HeartbeatObservationMismatch;
        if (!std.mem.eql(u8, echoed.member_id, &self.config.member_id) or
            !std.mem.eql(u8, echoed.local_set_id, &self.config.local_set_id) or
            echoed.member_slot != self.config.member_slot or
            echoed.state != .MEMBER_HEARTBEAT_STATE_PRESENT or
            echoed_capacity.free_extent_count != capacity.free_extent_count or
            echoed_capacity.allocated_extent_count != capacity.allocated_extent_count or
            echoed_capacity.reserved_extent_count != capacity.reserved_extent_count or
            echoed_capacity.retired_extent_count != capacity.retired_extent_count)
            return error.HeartbeatObservationMismatch;
        if (response.recommended_interval_ms == 0 or response.stale_after_ms <= response.recommended_interval_ms)
            return error.InvalidHeartbeatInterval;
        return response.recommended_interval_ms;
    }

    fn wait(self: *HeartbeatWorker, interval_ms: u32) bool {
        if (self.stopping.load(.acquire)) return false;
        self.event.reset();
        if (self.stopping.load(.acquire)) return false;
        self.event.waitTimeout(self.io, .{ .duration = .{
            .raw = .fromMilliseconds(interval_ms),
            .clock = .awake,
        } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return false,
        };
        return !self.stopping.load(.acquire);
    }
};

fn unary(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    path: []const u8,
    request: anytype,
    comptime Response: type,
) !Response {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try request.encode(&writer.writer, allocator);
    var channel = try grpc.Channel.init(allocator, endpoint, .{});
    defer channel.deinit();
    var result = try channel.callUnary(allocator, path, writer.written(), .{ .timeout_ns = rpc_timeout_ns });
    defer result.deinit();
    if (!result.status.isOk()) return error.ControllerRejectedRequest;
    var reader: std.Io.Reader = .fixed(result.payload);
    return Response.decode(&reader, allocator);
}

fn derivedRequestId(source: []const u8) ![36]u8 {
    if (source.len != 36 or source[8] != '-' or source[13] != '-' or source[18] != '-' or source[23] != '-' or
        source[14] != '7' or std.mem.indexOfScalar(u8, "89ab", source[19]) == null)
        return error.InvalidRequestId;
    var result = source[0..36].*;
    for (result, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) continue;
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidRequestId;
    }
    const last = result[35];
    const value: u8 = if (std.ascii.isDigit(last)) last - '0' else last - 'a' + 10;
    const changed = value ^ 1;
    result[35] = if (changed < 10) '0' + changed else 'a' + changed - 10;
    return result;
}

fn localSetId(member_id: [16]u8, node_id: []const u8) [16]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-file-local-set-v1");
    hashField(&hasher, &member_id);
    hashField(&hasher, node_id);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var result = digest[0..16].*;
    if (allZero(&result) or std.mem.eql(u8, &result, &member_id)) result[15] ^= 1;
    return result;
}

fn birthTopologyDigest(
    cluster_id: [16]u8,
    pool_id: []const u8,
    node_id: []const u8,
    member_id: [16]u8,
    local_set_id: [16]u8,
    failure_domain: []const u8,
    metadata_capacity_bytes: u64,
    data_capacity_bytes: u64,
    extent_size_bytes: u32,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-file-member-topology-v1");
    hashField(&hasher, &cluster_id);
    hashField(&hasher, pool_id);
    hashField(&hasher, node_id);
    hashField(&hasher, &member_id);
    hashField(&hasher, &local_set_id);
    hashField(&hasher, failure_domain);
    hashInt(&hasher, u64, metadata_capacity_bytes);
    hashInt(&hasher, u64, data_capacity_bytes);
    hashInt(&hasher, u32, extent_size_bytes);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    hasher.update(&length);
    hasher.update(value);
}

fn hashInt(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    hashField(hasher, &encoded);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const test_id: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 1 };

const FakeController = struct {
    reported: std.Io.Event = .unset,
    heartbeat_count: std.atomic.Value(usize) = .init(0),
    corrupt_heartbeat: std.atomic.Value(bool) = .init(false),

    fn register(self: *FakeController, server: *grpc.Server) !void {
        try server.registerUnary(
            "/zettide.controller.v1.MemberService/RegisterMember",
            grpc.UnaryHandler.bind(FakeController, self, registerMemberHandler),
        );
        try server.registerUnary(
            "/zettide.controller.v1.HeartbeatService/ReportHeartbeat",
            grpc.UnaryHandler.bind(FakeController, self, reportHeartbeatHandler),
        );
    }

    fn registerMemberHandler(
        _: *FakeController,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        payload: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(payload);
        var request = try pb.RegisterMemberRequest.decode(&reader, allocator);
        defer request.deinit(allocator);
        return encodeResponse(allocator, pb.RegisterMemberResponse{ .member = .{
            .id = request.member_id,
            .pool_id = request.pool_id,
            .node_id = request.node_id,
            .local_set_id = request.local_set_id,
            .member_slot = request.member_slot,
            .birth_topology_digest = request.birth_topology_digest,
            .metadata_capacity_bytes = request.metadata_capacity_bytes,
            .data_capacity_bytes = request.data_capacity_bytes,
            .extent_size_bytes = request.extent_size_bytes,
        } });
    }

    fn reportHeartbeatHandler(
        self: *FakeController,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        payload: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(payload);
        var request = try pb.ReportHeartbeatRequest.decode(&reader, allocator);
        defer request.deinit(allocator);
        _ = self.heartbeat_count.fetchAdd(1, .acq_rel);
        if (self.corrupt_heartbeat.load(.acquire)) request.members.items[0].member_slot += 1;
        self.reported.set(std.testing.io);
        return encodeResponse(allocator, pb.ReportHeartbeatResponse{
            .observation = .{
                .node_id = request.node_id,
                .incarnation = request.incarnation,
                .sequence = request.sequence,
                .members = request.members,
            },
            .recommended_interval_ms = 100,
            .stale_after_ms = 500,
        });
    }
};

fn encodeResponse(allocator: std.mem.Allocator, value: anytype) !grpc.UnaryResponse {
    var response = value;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try response.encode(&writer.writer, allocator);
    return grpc.UnaryResponse.ok(allocator, writer.written());
}

test "member topology identities are deterministic and distinct" {
    const first = try MemberConfig.init(
        "controller:50051",
        "0198f54d-5c2a-7000-8000-000000000001",
        "0198f54d-5c2a-7000-8000-000000000002",
        test_id,
        "0198f54d-5c2a-7000-8000-000000000003",
        test_id,
        "rack-a",
        4096,
        1024 * 1024,
        4096,
    );
    const second = try MemberConfig.init(
        "controller:50051",
        "0198f54d-5c2a-7000-8000-000000000001",
        "0198f54d-5c2a-7000-8000-000000000002",
        test_id,
        "0198f54d-5c2a-7000-8000-000000000003",
        test_id,
        "rack-a",
        4096,
        1024 * 1024,
        4096,
    );
    try std.testing.expectEqualStrings("0198f54d-5c2a-7000-8000-000000000000", &first.request_id);
    try std.testing.expectEqual(first.local_set_id, second.local_set_id);
    try std.testing.expectEqual(first.birth_topology_digest, second.birth_topology_digest);
    try std.testing.expect(!std.mem.eql(u8, &first.local_set_id, &first.member_id));
}

test "member registration and heartbeat use controller gRPC contracts" {
    var fake: FakeController = .{};
    var server = try grpc.Server.init(std.testing.allocator, .{ .host = "127.0.0.1", .port = 0 });
    defer server.deinit();
    try fake.register(&server);
    try server.start();

    var endpoint_buffer: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "127.0.0.1:{d}", .{try server.port()});
    const config = try MemberConfig.init(
        endpoint,
        "0198f54d-5c2a-7000-8000-000000000001",
        "0198f54d-5c2a-7000-8000-000000000002",
        test_id,
        "0198f54d-5c2a-7000-8000-000000000003",
        test_id,
        "rack-a",
        4096,
        1024 * 1024,
        4096,
    );
    try registerMemberWithRetry(std.testing.allocator, std.testing.io, config);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try data_node.ReplicaFileStore.init(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "replicas.state",
    );
    defer store.deinit();
    try store.configureCapacity(test_id, 1024 * 1024, 4096);
    var worker = try HeartbeatWorker.init(std.testing.allocator, std.testing.io, config, &store, 1);
    defer worker.stopAndJoin();
    try worker.start();
    fake.reported.waitTimeout(std.testing.io, .{ .duration = .{
        .raw = .fromSeconds(3),
        .clock = .awake,
    } }) catch |err| switch (err) {
        error.Timeout => return error.HeartbeatNotObserved,
        error.Canceled => return error.HeartbeatWaitCanceled,
    };
    worker.stopAndJoin();
    try std.testing.expect(fake.heartbeat_count.load(.acquire) >= 1);

    fake.corrupt_heartbeat.store(true, .release);
    try std.testing.expectError(
        error.HeartbeatObservationMismatch,
        worker.report(2, try store.capacitySnapshot()),
    );
}
