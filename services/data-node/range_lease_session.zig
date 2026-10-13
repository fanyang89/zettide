const std = @import("std");
const grpc = @import("grpc_lite");
const pb = @import("controller_proto");
const contract = @import("data_node_service").range_lease;

/// Explicit data-service lease client and synchronized admission gate. A frontend
/// must call beginIo/finishIo around real backend I/O and schedule renewal and
/// pollRevocation. It must still check Replica/primary authority and readiness.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: []const u8,
    gate: contract.Gate,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8, node_id: [16]u8, boot_id: [16]u8) !Session {
        return .{ .allocator = allocator, .io = io, .endpoint = endpoint, .gate = try contract.Gate.init(allocator, node_id, boot_id) };
    }
    /// Stop/join all callers and drain all I/O before deinitialization.
    pub fn deinit(self: *Session) void {
        self.gate.deinit();
    }

    pub fn acquire(self: *Session, request: pb.RangeLeaseRequest) !pb.RangeLease {
        return self.grant(request, false);
    }
    pub fn renew(self: *Session, request: pb.RangeLeaseRequest) !pb.RangeLease {
        return self.grant(request, true);
    }
    fn grant(self: *Session, request: pb.RangeLeaseRequest, comptime renewing: bool) !pb.RangeLease {
        // Retries are explicit and must retain request_id and all request fields.
        const holder = try parseId(request.holder_node_id);
        if (!std.mem.eql(u8, &holder, &self.gate.node_id) or !std.mem.eql(u8, request.holder_boot_id, &self.gate.boot_id)) return error.HolderMismatch;
        if ((renewing and request.expected_resource_version == 0) or (!renewing and request.expected_resource_version != 0)) return error.InvalidVersion;
        const started = try self.now();
        var response = try self.call(if (renewing) "RenewLease" else "AcquireLease", request);
        defer response.deinit(self.allocator);
        const lease = response.lease orelse return error.MissingLease;
        const token = try tokenFromLease(lease);
        if (!matches(lease, request) or lease.state != .RANGE_LEASE_STATE_ACTIVE or
            lease.token_revision != lease.resource_version or (renewing and lease.resource_version <= request.expected_resource_version)) return error.LeaseResponseMismatch;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.gate.install(token, started, try self.now());
        response.lease = null;
        return lease;
    }

    pub fn beginIo(self: *Session, lease: pb.RangeLease, volume_id: [16]u8, offset: u64, length: u64, mode: contract.Mode) !contract.Ticket {
        const token = try tokenFromLease(lease);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.gate.begin(token, volume_id, offset, length, mode, try self.now());
    }
    pub fn finishIo(self: *Session, ticket: contract.Ticket) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.gate.finish(ticket, try self.now());
    }

    pub fn revoke(self: *Session, request: pb.RangeLeaseRequest) !pb.RangeLease {
        var response = try self.call("RevokeLease", request);
        defer response.deinit(self.allocator);
        const lease = response.lease orelse return error.MissingLease;
        if (!matches(lease, request) or lease.state != .RANGE_LEASE_STATE_REVOKING) return error.LeaseResponseMismatch;
        const token = try tokenFromLease(lease);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.gate.revoke(token, lease.resource_version);
        response.lease = null;
        return lease;
    }

    /// Returns false until revoked and drained. Never ACKs merely because the
    /// controller marked REVOKING or a local timer elapsed. The caller supplies
    /// a stable ACK request ID, distinct from the Revoke request ID.
    pub fn pollRevocation(self: *Session, lease_id: []const u8, ack_request_id: []const u8) !bool {
        var response = try self.call("GetLease", pb.GetRangeLeaseRequest{ .lease_id = lease_id });
        defer response.deinit(self.allocator);
        const lease = response.lease orelse return error.MissingLease;
        if (!std.mem.eql(u8, lease.lease_id, lease_id)) return error.LeaseResponseMismatch;
        const token = try tokenFromLease(lease);
        if (lease.state == .RANGE_LEASE_STATE_ACTIVE) return false;
        if (lease.state != .RANGE_LEASE_STATE_REVOKING and lease.state != .RANGE_LEASE_STATE_REVOKED) return error.LeaseResponseMismatch;
        self.mutex.lockUncancelable(self.io);
        const drained = blk: {
            defer self.mutex.unlock(self.io);
            try self.gate.revoke(token, lease.resource_version);
            break :blk self.gate.drained(token.lease_id, lease.resource_version);
        };
        if (!drained) return false;
        if (lease.state == .RANGE_LEASE_STATE_REVOKED) return true;
        var completed = try self.call("CompleteRevoke", pb.RangeLeaseRequest{
            .request_id = ack_request_id,
            .lease_id = lease.lease_id,
            .volume_id = lease.volume_id,
            .holder_node_id = lease.holder_node_id,
            .holder_boot_id = lease.holder_boot_id,
            .offset_bytes = lease.offset_bytes,
            .length_bytes = lease.length_bytes,
            .mode = lease.mode,
            .expected_resource_version = lease.resource_version,
        });
        defer completed.deinit(self.allocator);
        const terminal = completed.lease orelse return error.MissingLease;
        if (terminal.state != .RANGE_LEASE_STATE_REVOKED or !std.meta.eql(token, try tokenFromLease(terminal)) or terminal.resource_version <= lease.resource_version) return error.LeaseResponseMismatch;
        return true;
    }

    fn now(self: *Session) !u64 {
        return std.math.cast(u64, std.Io.Timestamp.now(self.io, .boot).toMilliseconds()) orelse error.InvalidClock;
    }
    fn call(self: *Session, comptime method: []const u8, request: anytype) !pb.RangeLeaseResponse {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try request.encode(&writer.writer, self.allocator);
        var channel = try grpc.Channel.init(self.allocator, self.endpoint, .{});
        defer channel.deinit();
        var result = try channel.callUnary(self.allocator, "/zettide.controller.v1.RangeLeaseService/" ++ method, writer.written(), .{ .timeout_ns = 5 * std.time.ns_per_s });
        defer result.deinit();
        if (!result.status.isOk()) return error.ControllerRejectedRequest;
        var reader: std.Io.Reader = .fixed(result.payload);
        return pb.RangeLeaseResponse.decode(&reader, self.allocator);
    }
};

pub fn tokenFromLease(lease: pb.RangeLease) !contract.Token {
    if (lease.holder_boot_id.len != 16 or lease.duration_ms != contract.duration_ms or lease.token_revision == 0 or lease.created_revision == 0 or
        lease.token_revision < lease.created_revision or lease.resource_version < lease.token_revision or
        (lease.mode != .RANGE_LEASE_MODE_READ and lease.mode != .RANGE_LEASE_MODE_WRITE) or
        !contract.validRange(lease.offset_bytes, lease.length_bytes, std.math.maxInt(u64))) return error.LeaseResponseMismatch;
    return .{ .lease_id = try parseId(lease.lease_id), .volume_id = try parseId(lease.volume_id), .holder_node_id = try parseId(lease.holder_node_id), .holder_boot_id = lease.holder_boot_id[0..16].*, .offset = lease.offset_bytes, .length = lease.length_bytes, .mode = if (lease.mode == .RANGE_LEASE_MODE_READ) .read else .write, .revision = lease.token_revision };
}

fn parseId(text: []const u8) ![16]u8 {
    if (text.len != 36 or text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-' or text[14] != '7' or std.mem.indexOfScalar(u8, "89ab", text[19]) == null) return error.InvalidIdentity;
    var hex: [32]u8 = undefined;
    var index: usize = 0;
    for (text, 0..) |byte, offset| {
        if (offset == 8 or offset == 13 or offset == 18 or offset == 23) continue;
        if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return error.InvalidIdentity;
        hex[index] = byte;
        index += 1;
    }
    var result: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&result, &hex);
    return result;
}
fn matches(lease: pb.RangeLease, request: pb.RangeLeaseRequest) bool {
    return std.mem.eql(u8, lease.lease_id, request.lease_id) and std.mem.eql(u8, lease.volume_id, request.volume_id) and
        std.mem.eql(u8, lease.holder_node_id, request.holder_node_id) and std.mem.eql(u8, lease.holder_boot_id, request.holder_boot_id) and
        lease.offset_bytes == request.offset_bytes and lease.length_bytes == request.length_bytes and lease.mode == request.mode;
}

test "data-service session exposes all lease and I/O entry points" {
    std.testing.refAllDecls(Session);
    try std.testing.expectError(error.InvalidIdentity, parseId("invalid"));
    const id = try parseId("0198f54d-5c2a-7000-8000-000000000001");
    try std.testing.expectEqual(@as(u8, 1), id[15]);
}

const test_lease_id = "0198f54d-5c2a-7000-8000-000000000001";
const test_volume_id = "0198f54d-5c2a-7000-8000-000000000002";
const test_node_id = "0198f54d-5c2a-7000-8000-000000000003";
const test_boot_id: [16]u8 = @splat(4);
const FakeLeaseController = struct {
    revoking: std.atomic.Value(bool) = .init(false),
    completes: std.atomic.Value(usize) = .init(0),
    fn active(_: *FakeLeaseController, allocator: std.mem.Allocator, _: *grpc.ServerContext, _: []const u8) !grpc.UnaryResponse {
        return reply(allocator, .RANGE_LEASE_STATE_ACTIVE, 10, 10);
    }
    fn renew(_: *FakeLeaseController, allocator: std.mem.Allocator, _: *grpc.ServerContext, _: []const u8) !grpc.UnaryResponse {
        return reply(allocator, .RANGE_LEASE_STATE_ACTIVE, 11, 11);
    }
    fn revoke(self: *FakeLeaseController, allocator: std.mem.Allocator, _: *grpc.ServerContext, _: []const u8) !grpc.UnaryResponse {
        self.revoking.store(true, .release);
        return reply(allocator, .RANGE_LEASE_STATE_REVOKING, 11, 12);
    }
    fn get(self: *FakeLeaseController, allocator: std.mem.Allocator, _: *grpc.ServerContext, _: []const u8) !grpc.UnaryResponse {
        if (self.completes.load(.acquire) != 0) return reply(allocator, .RANGE_LEASE_STATE_REVOKED, 11, 13);
        if (self.revoking.load(.acquire)) return reply(allocator, .RANGE_LEASE_STATE_REVOKING, 11, 12);
        return reply(allocator, .RANGE_LEASE_STATE_ACTIVE, 11, 11);
    }
    fn complete(self: *FakeLeaseController, allocator: std.mem.Allocator, _: *grpc.ServerContext, payload: []const u8) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(payload);
        var request = try pb.RangeLeaseRequest.decode(&reader, allocator);
        defer request.deinit(allocator);
        try std.testing.expectEqual(@as(u64, 12), request.expected_resource_version);
        try std.testing.expectEqualStrings("drain-ack", request.request_id);
        _ = self.completes.fetchAdd(1, .acq_rel);
        return reply(allocator, .RANGE_LEASE_STATE_REVOKED, 11, 13);
    }
    fn reply(allocator: std.mem.Allocator, state: pb.RangeLeaseState, token: u64, version: u64) !grpc.UnaryResponse {
        var response = pb.RangeLeaseResponse{ .lease = .{ .lease_id = test_lease_id, .volume_id = test_volume_id, .holder_node_id = test_node_id, .holder_boot_id = &test_boot_id, .length_bytes = 4096, .mode = .RANGE_LEASE_MODE_READ, .created_revision = 10, .token_revision = token, .resource_version = version, .duration_ms = contract.duration_ms, .state = state } };
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try response.encode(&writer.writer, allocator);
        return grpc.UnaryResponse.ok(allocator, writer.written());
    }
};

test "data-service range session applies grants and never ACKs revocation before I/O drains" {
    var fake: FakeLeaseController = .{};
    var server = try grpc.Server.init(std.testing.allocator, .{ .host = "127.0.0.1", .port = 0 });
    defer server.deinit();
    const prefix = "/zettide.controller.v1.RangeLeaseService/";
    try server.registerUnary(prefix ++ "AcquireLease", grpc.UnaryHandler.bind(FakeLeaseController, &fake, FakeLeaseController.active));
    try server.registerUnary(prefix ++ "RenewLease", grpc.UnaryHandler.bind(FakeLeaseController, &fake, FakeLeaseController.renew));
    try server.registerUnary(prefix ++ "RevokeLease", grpc.UnaryHandler.bind(FakeLeaseController, &fake, FakeLeaseController.revoke));
    try server.registerUnary(prefix ++ "GetLease", grpc.UnaryHandler.bind(FakeLeaseController, &fake, FakeLeaseController.get));
    try server.registerUnary(prefix ++ "CompleteRevoke", grpc.UnaryHandler.bind(FakeLeaseController, &fake, FakeLeaseController.complete));
    try server.start();
    var endpoint_buffer: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "127.0.0.1:{d}", .{try server.port()});
    var session = try Session.init(std.testing.allocator, std.testing.io, endpoint, try parseId(test_node_id), test_boot_id);
    defer session.deinit();
    var request = pb.RangeLeaseRequest{ .request_id = "acquire", .lease_id = test_lease_id, .volume_id = test_volume_id, .holder_node_id = test_node_id, .holder_boot_id = &test_boot_id, .length_bytes = 4096, .mode = .RANGE_LEASE_MODE_READ };
    var granted = try session.acquire(request);
    defer granted.deinit(std.testing.allocator);
    request.request_id = "renew";
    request.expected_resource_version = granted.resource_version;
    var renewed = try session.renew(request);
    defer renewed.deinit(std.testing.allocator);
    try std.testing.expectError(error.ReadOnly, session.beginIo(renewed, try parseId(test_volume_id), 0, 4096, .write));
    const read = try session.beginIo(renewed, try parseId(test_volume_id), 0, 4096, .read);
    request.request_id = "revoke";
    request.expected_resource_version = renewed.resource_version;
    var revoking = try session.revoke(request);
    defer revoking.deinit(std.testing.allocator);
    try std.testing.expect(!try session.pollRevocation(test_lease_id, "drain-ack"));
    try std.testing.expectEqual(@as(usize, 0), fake.completes.load(.acquire));
    try std.testing.expectError(error.LeaseRevoked, session.beginIo(renewed, try parseId(test_volume_id), 0, 4096, .read));
    try session.finishIo(read);
    try std.testing.expect(try session.pollRevocation(test_lease_id, "drain-ack"));
    try std.testing.expectEqual(@as(usize, 1), fake.completes.load(.acquire));
    request.request_id = "acquire";
    request.expected_resource_version = 0;
    try std.testing.expectError(error.LeaseRevoked, session.acquire(request));
    try std.testing.expect(try session.pollRevocation(test_lease_id, "drain-ack"));
    try std.testing.expectEqual(@as(usize, 1), fake.completes.load(.acquire));
}
