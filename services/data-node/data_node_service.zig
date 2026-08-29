const std = @import("std");

const grpc = @import("grpc_lite");
const pb = @import("data_node_proto");
const protocol = @import("zettide_data_service_contracts");
const file_member_backend = @import("file_member_backend.zig");
const lease = protocol.primary_lease;
const replica_service = protocol.replica_service;

pub const ReplicaFileStore = replica_service.FileStore;
pub const ReplicaCapacitySnapshot = replica_service.CapacitySnapshot;
pub const FileMemberBackend = file_member_backend.FileMemberBackend;

pub const Options = struct {
    replica_store: ?replica_service.Store = null,
    replica_backend: ?replica_service.Backend = null,
};

pub const DataNodeServer = struct {
    state: *State,
    server: grpc.Server,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
    ) !DataNodeServer {
        return initWithOptions(allocator, io, host, port, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        options: Options,
    ) !DataNodeServer {
        if ((options.replica_store == null) != (options.replica_backend == null))
            return error.IncompleteReplicaConfiguration;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = try State.init(allocator, io, options);
        errdefer state.deinit();
        var server = try grpc.Server.init(allocator, .{ .host = host, .port = port });
        errdefer server.deinit();
        try server.registerUnary(methodPath("EnsureReplica"), grpc.UnaryHandler.bind(State, state, State.ensureReplica));
        try server.registerUnary(methodPath("InspectReplica"), grpc.UnaryHandler.bind(State, state, State.inspectReplica));
        try server.registerUnary(methodPath("DeleteReplica"), grpc.UnaryHandler.bind(State, state, State.deleteReplica));
        try server.registerUnary(methodPath("IdentifyHolder"), grpc.UnaryHandler.bind(State, state, State.identifyHolder));
        try server.registerUnary(methodPath("StagePrimary"), grpc.UnaryHandler.bind(State, state, State.stagePrimary));
        try server.registerUnary(methodPath("InspectPrimary"), grpc.UnaryHandler.bind(State, state, State.inspectPrimary));
        return .{ .state = state, .server = server };
    }

    pub fn start(self: *DataNodeServer) !void {
        try self.server.start();
    }

    pub fn localAddress(self: *const DataNodeServer) !grpc.ServerLocalAddress {
        return self.server.localAddress();
    }

    pub fn shutdownGracefully(self: *DataNodeServer, timeout_ns: u64) void {
        self.server.shutdownGracefully(timeout_ns);
    }

    pub fn wait(self: *DataNodeServer) void {
        self.server.wait();
    }

    pub fn deinit(self: *DataNodeServer) void {
        const allocator = self.state.allocator;
        self.server.deinit();
        self.state.deinit();
        allocator.destroy(self.state);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    boot_id: protocol.Id,
    mutex: std.Io.Mutex = .init,
    // Blocks concurrent RPCs before the contract-level transaction lock so
    // filesystem I/O never causes another request to busy-spin.
    replica_mutex: std.Io.Mutex = .init,
    replicas: ?replica_service.Service,
    authorities: std.AutoHashMapUnmanaged(protocol.Id, Authority) = .empty,

    const Authority = struct {
        binding: protocol.AuthorityBinding,
        runtime: lease.Runtime,
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !State {
        return .{
            .allocator = allocator,
            .io = io,
            .boot_id = try createBootId(io),
            .replicas = if (options.replica_store) |store|
                replica_service.Service.init(store, options.replica_backend.?)
            else
                null,
        };
    }

    fn deinit(self: *State) void {
        self.authorities.deinit(self.allocator);
        self.* = undefined;
    }

    fn ensureReplica(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.EnsureReplicaRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid EnsureReplica request");
        defer request.deinit(allocator);
        return self.handleReplicaMutation(allocator, pb.EnsureReplicaResponse, replicaRequest(request), .ensure);
    }

    fn inspectReplica(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.InspectReplicaRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid InspectReplica request");
        defer request.deinit(allocator);
        return self.handleReplicaMutation(allocator, pb.InspectReplicaResponse, replicaRequest(request), .inspect);
    }

    fn deleteReplica(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.DeleteReplicaRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid DeleteReplica request");
        defer request.deinit(allocator);
        return self.handleReplicaMutation(allocator, pb.DeleteReplicaResponse, replicaRequest(request), .delete);
    }

    const ReplicaMethod = enum { ensure, inspect, delete };

    fn handleReplicaMutation(
        self: *State,
        allocator: std.mem.Allocator,
        comptime ResponseType: type,
        request: replica_service.Request,
        method: ReplicaMethod,
    ) !grpc.UnaryResponse {
        self.replica_mutex.lockUncancelable(self.io);
        defer self.replica_mutex.unlock(self.io);
        const service = if (self.replicas) |*replicas| replicas else return fail(allocator, .failed_precondition, "replica backend is not configured");
        const response = switch (method) {
            .ensure => service.ensureReplica(request),
            .inspect => service.inspectReplica(request),
            .delete => service.deleteReplica(request),
        } catch |err| return replicaFailure(allocator, err);
        return encodeReplicaResponse(allocator, ResponseType, response);
    }

    fn identifyHolder(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.IdentifyHolderRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid IdentifyHolder request");
        defer request.deinit(allocator);
        return encodeResponse(allocator, pb.IdentifyHolderResponse{ .holder_boot_id = &self.boot_id });
    }

    fn stagePrimary(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.StagePrimaryRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid StagePrimary request");
        defer request.deinit(allocator);
        const binding = parseAuthorityBinding(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid authority binding");
        if (request.lease_duration_ms != lease.duration_ms)
            return fail(allocator, .invalid_argument, "unsupported lease duration");
        if (!std.mem.eql(u8, &binding.holder_boot_id, &self.boot_id))
            return fail(allocator, .failed_precondition, "holder boot identity mismatch");

        self.stage(binding) catch |err| return switch (err) {
            error.OutOfMemory => fail(allocator, .resource_exhausted, "authority state exhausted"),
            error.AuthorityConflict,
            error.StaleAuthority,
            error.LeaseConflict,
            error.BootMismatch,
            => fail(allocator, .failed_precondition, "authority rejected"),
            else => fail(allocator, .internal, "authority stage failed"),
        };
        return encodeResponse(allocator, pb.StagePrimaryResponse{
            .binding = authorityProto(&binding),
            .lease_duration_ms = request.lease_duration_ms,
        });
    }

    fn inspectPrimary(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.InspectPrimaryRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid InspectPrimary request");
        defer request.deinit(allocator);
        const binding = parseAuthorityBinding(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid authority binding");
        const candidate_fresh = self.inspect(binding) catch |err| return switch (err) {
            error.NotFound => fail(allocator, .not_found, "authority not staged"),
            error.AuthorityConflict => fail(allocator, .failed_precondition, "authority binding mismatch"),
            else => fail(allocator, .internal, "authority inspection failed"),
        };
        return encodeResponse(allocator, pb.InspectPrimaryResponse{
            .binding = authorityProto(&binding),
            .current_active = false,
            .current_admitting = false,
            .candidate_fresh = candidate_fresh,
            .should_renew = false,
        });
    }

    fn stage(self: *State, binding: protocol.AuthorityBinding) !void {
        const token = authorityToken(binding);
        const now_ms = try nowAwakeMs(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = try self.authorities.getOrPut(self.allocator, binding.volume_id);
        if (!result.found_existing) {
            result.value_ptr.* = .{
                .binding = binding,
                .runtime = try lease.Runtime.init(self.boot_id),
            };
        } else if (std.mem.eql(u8, &result.value_ptr.binding.lease_id, &binding.lease_id) and
            !std.meta.eql(result.value_ptr.binding, binding))
        {
            return error.AuthorityConflict;
        }
        _ = try result.value_ptr.runtime.stage(token, now_ms);
        result.value_ptr.binding = binding;
    }

    fn inspect(self: *State, binding: protocol.AuthorityBinding) !bool {
        const now_ms = try nowAwakeMs(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const authority = self.authorities.get(binding.volume_id) orelse return error.NotFound;
        if (!std.meta.eql(authority.binding, binding)) return error.AuthorityConflict;
        return authority.runtime.canMarkReadyToken(authorityToken(binding), now_ms);
    }
};

fn createBootId(io: std.Io) !protocol.Id {
    var id: protocol.Id = undefined;
    try io.randomSecure(&id);
    const timestamp = std.math.cast(u64, std.Io.Timestamp.now(io, .real).toMilliseconds()) orelse
        return error.InvalidTimestamp;
    if (timestamp > 0x0000_ffff_ffff_ffff) return error.InvalidTimestamp;
    id[0] = @truncate(timestamp >> 40);
    id[1] = @truncate(timestamp >> 32);
    id[2] = @truncate(timestamp >> 24);
    id[3] = @truncate(timestamp >> 16);
    id[4] = @truncate(timestamp >> 8);
    id[5] = @truncate(timestamp);
    id[6] = (id[6] & 0x0f) | 0x70;
    id[8] = (id[8] & 0x3f) | 0x80;
    return id;
}

fn nowAwakeMs(io: std.Io) !u64 {
    return std.math.cast(u64, std.Io.Timestamp.now(io, .awake).toMilliseconds()) orelse
        error.InvalidTimestamp;
}

fn replicaRequest(request: anytype) replica_service.Request {
    return .{
        .operation_id = request.operation_id,
        .volume_id = request.volume_id,
        .placement_id = request.placement_id,
        .allocation_id = request.allocation_id,
        .generation = request.generation,
        .member_id = request.member_id,
        .offset_bytes = request.offset_bytes,
        .length_bytes = request.length_bytes,
    };
}

fn encodeReplicaResponse(
    allocator: std.mem.Allocator,
    comptime ResponseType: type,
    response: replica_service.Response,
) !grpc.UnaryResponse {
    const operation_id = uuidText(response.operation_id);
    const binding = response.replica.attestation.binding;
    const volume_id = uuidText(binding.volume_id);
    const placement_id = uuidText(binding.placement_id);
    const allocation_id = uuidText(binding.allocation_id);
    return encodeResponse(allocator, ResponseType{
        .operation_id = &operation_id,
        .replica = .{
            .state = switch (response.replica.state) {
                .active => .DATA_REPLICA_STATE_ACTIVE,
                .tombstoned => .DATA_REPLICA_STATE_TOMBSTONED,
            },
            .attestation = .{
                .volume_id = &volume_id,
                .placement_id = &placement_id,
                .allocation_id = &allocation_id,
                .generation = binding.generation,
                .member_id = &binding.member_id,
                .offset_bytes = binding.offset_bytes,
                .length_bytes = binding.length_bytes,
                .backend_digest = &response.replica.attestation.backend_digest,
            },
        },
    });
}

fn replicaFailure(allocator: std.mem.Allocator, err: anyerror) !grpc.UnaryResponse {
    return switch (err) {
        error.InvalidGeometry,
        error.InvalidMemberId,
        error.InvalidId,
        => fail(allocator, .invalid_argument, "invalid replica request"),
        error.ReplicaNotFound => fail(allocator, .not_found, "replica not found"),
        error.OperationConflict,
        error.OperationInProgress,
        error.BindingConflict,
        error.GenerationRegression,
        error.PlacementStillActive,
        error.AllocationOverlap,
        error.AllocationQuarantined,
        error.MemberMismatch,
        error.UnalignedAllocation,
        error.AllocationOutOfBounds,
        error.MemberGeometryChanged,
        => fail(allocator, .failed_precondition, "replica request rejected"),
        error.OutOfMemory, error.StoreFull => fail(allocator, .resource_exhausted, "replica state exhausted"),
        else => fail(allocator, .internal, "replica operation failed"),
    };
}

fn uuidText(id: protocol.Id) [36]u8 {
    const hex = "0123456789abcdef";
    var text: [36]u8 = undefined;
    var source_index: usize = 0;
    var target_index: usize = 0;
    while (source_index < id.len) : (source_index += 1) {
        if (target_index == 8 or target_index == 13 or target_index == 18 or target_index == 23) {
            text[target_index] = '-';
            target_index += 1;
        }
        text[target_index] = hex[id[source_index] >> 4];
        text[target_index + 1] = hex[id[source_index] & 0x0f];
        target_index += 2;
    }
    return text;
}

fn parseAuthorityBinding(binding: ?pb.DataAuthorityBinding) !protocol.AuthorityBinding {
    const value = binding orelse return error.MissingBinding;
    if (value.authority_generation == 0 or value.write_epoch == 0 or value.placement_revision == 0)
        return error.InvalidBinding;
    return .{
        .volume_id = try uuid(value.volume_id),
        .primary_placement_id = try uuid(value.primary_placement_id),
        .primary_node_id = try uuid(value.primary_node_id),
        .lease_id = try uuid(value.lease_id),
        .holder_boot_id = try uuid(value.holder_boot_id),
        .authority_generation = value.authority_generation,
        .write_epoch = value.write_epoch,
        .placement_revision = value.placement_revision,
        .activation_nonce = try uuid(value.activation_nonce),
        .authority_digest = try digest(value.authority_digest),
    };
}

fn authorityProto(binding: *const protocol.AuthorityBinding) pb.DataAuthorityBinding {
    return .{
        .volume_id = &binding.volume_id,
        .primary_placement_id = &binding.primary_placement_id,
        .primary_node_id = &binding.primary_node_id,
        .lease_id = &binding.lease_id,
        .holder_boot_id = &binding.holder_boot_id,
        .authority_generation = binding.authority_generation,
        .write_epoch = binding.write_epoch,
        .placement_revision = binding.placement_revision,
        .activation_nonce = &binding.activation_nonce,
        .authority_digest = &binding.authority_digest,
    };
}

fn authorityToken(binding: protocol.AuthorityBinding) lease.Token {
    return .{
        .lease_id = binding.lease_id,
        .holder_boot_id = binding.holder_boot_id,
        .authority_generation = binding.authority_generation,
        .write_epoch = binding.write_epoch,
    };
}

fn uuid(bytes: []const u8) !protocol.Id {
    if (bytes.len != 16) return error.InvalidUuid;
    const id = bytes[0..16].*;
    if (id[6] & 0xf0 != 0x70 or id[8] & 0xc0 != 0x80) return error.InvalidUuid;
    return id;
}

fn digest(bytes: []const u8) !protocol.Digest {
    if (bytes.len != 32) return error.InvalidDigest;
    const value = bytes[0..32].*;
    for (value) |byte| if (byte != 0) return value;
    return error.InvalidDigest;
}

fn encodeResponse(allocator: std.mem.Allocator, response_value: anytype) !grpc.UnaryResponse {
    var response = response_value;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try response.encode(&writer.writer, allocator);
    return grpc.UnaryResponse.ok(allocator, writer.written());
}

fn fail(allocator: std.mem.Allocator, code: grpc.StatusCode, message: []const u8) !grpc.UnaryResponse {
    return grpc.UnaryResponse.fail(allocator, .init(code, message));
}

fn methodPath(comptime method: []const u8) []const u8 {
    return "/zettide.controller.v1.DataService/" ++ method;
}

test "data-node service persists Replica lifecycle through gRPC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const member_file = try tmp.dir.createFile(std.testing.io, "member.img", .{ .read = true });
    try member_file.setLength(std.testing.io, 64 * 1024);
    member_file.close(std.testing.io);

    const member: protocol.Id = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 9 };
    var store = try ReplicaFileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer store.deinit();
    var backend = try FileMemberBackend.init(
        std.testing.io,
        tmp.dir,
        "member.img",
        "/test/member.img",
        member,
        64 * 1024,
        4096,
    );
    var server = try DataNodeServer.initWithOptions(std.testing.allocator, std.testing.io, "127.0.0.1", 0, .{
        .replica_store = store.store(),
        .replica_backend = backend.backend(),
    });
    defer server.deinit();
    try server.start();

    var endpoint_buffer: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "127.0.0.1:{d}", .{try server.server.port()});
    var channel = try grpc.Channel.init(std.testing.allocator, endpoint, .{});
    defer channel.deinit();

    var ensure_request: pb.EnsureReplicaRequest = .{
        .operation_id = "0198f54d-5c2a-7000-8000-000000000021",
        .volume_id = "0198f54d-5c2a-7000-8000-000000000022",
        .placement_id = "0198f54d-5c2a-7000-8000-000000000023",
        .allocation_id = "0198f54d-5c2a-7000-8000-000000000024",
        .generation = 1,
        .member_id = &member,
        .offset_bytes = 4096,
        .length_bytes = 8192,
    };
    var invalid_request = ensure_request;
    invalid_request.operation_id = "0198f54d-5c2a-7000-8000-000000000027";
    invalid_request.offset_bytes = 64 * 1024;
    var invalid_result = try testCallUnary(&channel, methodPath("EnsureReplica"), &invalid_request);
    defer invalid_result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.failed_precondition, invalid_result.status.code);

    var ensure_result = try testCallUnary(&channel, methodPath("EnsureReplica"), &ensure_request);
    defer ensure_result.deinit();
    try std.testing.expect(ensure_result.status.isOk());
    var ensure_reader: std.Io.Reader = .fixed(ensure_result.payload);
    var ensured = try pb.EnsureReplicaResponse.decode(&ensure_reader, std.testing.allocator);
    defer ensured.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(ensure_request.operation_id, ensured.operation_id);
    try std.testing.expectEqual(pb.DataReplicaState.DATA_REPLICA_STATE_ACTIVE, ensured.replica.?.state);
    try std.testing.expectEqual(@as(usize, 32), ensured.replica.?.attestation.?.backend_digest.len);

    var inspect_request: pb.InspectReplicaRequest = .{
        .operation_id = "0198f54d-5c2a-7000-8000-000000000025",
        .volume_id = ensure_request.volume_id,
        .placement_id = ensure_request.placement_id,
        .allocation_id = ensure_request.allocation_id,
        .generation = ensure_request.generation,
        .member_id = ensure_request.member_id,
        .offset_bytes = ensure_request.offset_bytes,
        .length_bytes = ensure_request.length_bytes,
    };
    var inspect_result = try testCallUnary(&channel, methodPath("InspectReplica"), &inspect_request);
    defer inspect_result.deinit();
    try std.testing.expect(inspect_result.status.isOk());

    var delete_request: pb.DeleteReplicaRequest = .{
        .operation_id = "0198f54d-5c2a-7000-8000-000000000026",
        .volume_id = ensure_request.volume_id,
        .placement_id = ensure_request.placement_id,
        .allocation_id = ensure_request.allocation_id,
        .generation = ensure_request.generation,
        .member_id = ensure_request.member_id,
        .offset_bytes = ensure_request.offset_bytes,
        .length_bytes = ensure_request.length_bytes,
    };
    const drifted_file = try tmp.dir.openFile(std.testing.io, "member.img", .{ .mode = .read_write });
    try drifted_file.setLength(std.testing.io, 32 * 1024);
    drifted_file.close(std.testing.io);
    var rejected_delete = delete_request;
    rejected_delete.operation_id = "0198f54d-5c2a-7000-8000-000000000028";
    var rejected_delete_result = try testCallUnary(&channel, methodPath("DeleteReplica"), &rejected_delete);
    defer rejected_delete_result.deinit();
    try std.testing.expectEqual(grpc.StatusCode.failed_precondition, rejected_delete_result.status.code);

    const restored_file = try tmp.dir.openFile(std.testing.io, "member.img", .{ .mode = .read_write });
    try restored_file.setLength(std.testing.io, 64 * 1024);
    restored_file.close(std.testing.io);
    var delete_result = try testCallUnary(&channel, methodPath("DeleteReplica"), &delete_request);
    defer delete_result.deinit();
    try std.testing.expect(delete_result.status.isOk());
    var delete_reader: std.Io.Reader = .fixed(delete_result.payload);
    var deleted = try pb.DeleteReplicaResponse.decode(&delete_reader, std.testing.allocator);
    defer deleted.deinit(std.testing.allocator);
    try std.testing.expectEqual(pb.DataReplicaState.DATA_REPLICA_STATE_TOMBSTONED, deleted.replica.?.state);
}

fn testCallUnary(channel: *grpc.Channel, path: []const u8, request: anytype) !grpc.CallResult {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try request.encode(&writer.writer, std.testing.allocator);
    return channel.callUnary(std.testing.allocator, path, writer.written(), .{});
}

test "data-node service stages and inspects a fresh candidate without claiming readiness" {
    var service = try DataNodeServer.init(std.testing.allocator, std.testing.io, "127.0.0.1", 0);
    defer service.deinit();
    try service.start();

    var endpoint_buffer: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "127.0.0.1:{d}", .{try service.server.port()});
    var channel = try grpc.Channel.init(std.testing.allocator, endpoint, .{});
    defer channel.deinit();

    var identify_request: pb.IdentifyHolderRequest = .{};
    var identify_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer identify_writer.deinit();
    try identify_request.encode(&identify_writer.writer, std.testing.allocator);
    var identify_result = try channel.callUnary(std.testing.allocator, methodPath("IdentifyHolder"), identify_writer.written(), .{});
    defer identify_result.deinit();
    try std.testing.expect(identify_result.status.isOk());
    var identify_reader: std.Io.Reader = .fixed(identify_result.payload);
    var identified = try pb.IdentifyHolderResponse.decode(&identify_reader, std.testing.allocator);
    defer identified.deinit(std.testing.allocator);

    const boot_id = try uuid(identified.holder_boot_id);
    const base: protocol.Id = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 1 };
    var binding: protocol.AuthorityBinding = .{
        .volume_id = base,
        .primary_placement_id = base,
        .primary_node_id = base,
        .lease_id = base,
        .holder_boot_id = boot_id,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 1,
        .activation_nonce = base,
        .authority_digest = @splat(0x55),
    };
    binding.primary_placement_id[15] = 2;
    binding.primary_node_id[15] = 3;
    binding.lease_id[15] = 4;
    binding.activation_nonce[15] = 5;

    var stage_request: pb.StagePrimaryRequest = .{
        .binding = authorityProto(&binding),
        .lease_duration_ms = lease.duration_ms,
    };
    var stage_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stage_writer.deinit();
    try stage_request.encode(&stage_writer.writer, std.testing.allocator);
    var stage_result = try channel.callUnary(std.testing.allocator, methodPath("StagePrimary"), stage_writer.written(), .{});
    defer stage_result.deinit();
    try std.testing.expect(stage_result.status.isOk());

    var inspect_request: pb.InspectPrimaryRequest = .{ .binding = authorityProto(&binding) };
    var inspect_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer inspect_writer.deinit();
    try inspect_request.encode(&inspect_writer.writer, std.testing.allocator);
    var inspect_result = try channel.callUnary(std.testing.allocator, methodPath("InspectPrimary"), inspect_writer.written(), .{});
    defer inspect_result.deinit();
    try std.testing.expect(inspect_result.status.isOk());
    var inspect_reader: std.Io.Reader = .fixed(inspect_result.payload);
    var inspected = try pb.InspectPrimaryResponse.decode(&inspect_reader, std.testing.allocator);
    defer inspected.deinit(std.testing.allocator);
    try std.testing.expect(inspected.candidate_fresh);
    try std.testing.expect(!inspected.current_active);
    try std.testing.expect(!inspected.current_admitting);

    var unconfigured = try channel.callUnary(std.testing.allocator, methodPath("EnsureReplica"), "", .{});
    defer unconfigured.deinit();
    try std.testing.expectEqual(grpc.StatusCode.failed_precondition, unconfigured.status.code);
}

test {
    _ = file_member_backend;
}
