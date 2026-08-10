const std = @import("std");

const data_service = @import("data_service.zig");
const grpc = @import("grpc_lite");
const pb = @import("control_proto");
const reconciler = @import("reconciler.zig");
const replica_fence = @import("replica_fence.zig");
const wire = @import("data_service_wire.zig");

pub const RpcClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    mutex: std.Io.Mutex = .init,
    active: ?*grpc.Channel = null,
    canceled: bool = false,

    pub const Options = struct {
        timeout_ns: u64 = 5 * std.time.ns_per_s,
        max_response_size: usize = 1024 * 1024,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !RpcClient {
        if (options.timeout_ns == 0 or options.max_response_size == 0) return error.InvalidOptions;
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn deinit(self: *RpcClient) void {
        self.cancel();
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.active == null);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    pub fn interface(self: *RpcClient) reconciler.DataServiceClient {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn inspectReplica(self: *RpcClient, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        var response = try self.unary(
            endpoint,
            "InspectReplica",
            wire.inspectReplicaRequest(request),
            pb.InspectReplicaResponse,
        );
        defer response.deinit(self.allocator);
        return wire.dataResponse(response);
    }

    pub fn cancel(self: *RpcClient) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.canceled = true;
        if (self.active) |channel| channel.shutdown();
    }

    fn ensure(context: *anyopaque, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        var response = try self.unary(
            endpoint,
            "EnsureReplica",
            wire.ensureReplicaRequest(request),
            pb.EnsureReplicaResponse,
        );
        defer response.deinit(self.allocator);
        return wire.dataResponse(response);
    }

    fn delete(context: *anyopaque, endpoint: []const u8, request: data_service.Request) !data_service.Response {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        var response = try self.unary(
            endpoint,
            "DeleteReplica",
            wire.deleteReplicaRequest(request),
            pb.DeleteReplicaResponse,
        );
        defer response.deinit(self.allocator);
        return wire.dataResponse(response);
    }

    fn identifyHolder(context: *anyopaque, endpoint: []const u8) !reconciler.Id {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        var response = try self.unary(endpoint, "IdentifyHolder", pb.IdentifyHolderRequest{}, pb.IdentifyHolderResponse);
        defer response.deinit(self.allocator);
        return wire.parseHolder(response);
    }

    fn stagePrimary(context: *anyopaque, endpoint: []const u8, request: reconciler.StageRequest) !reconciler.StageAck {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        var response = try self.unary(endpoint, "StagePrimary", wire.stageRequest(&request), pb.StagePrimaryResponse);
        defer response.deinit(self.allocator);
        return wire.parseStageResponse(response);
    }

    fn fenceReplica(context: *anyopaque, endpoint: []const u8, binding: replica_fence.Binding) !replica_fence.Result {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        var response = try self.unary(endpoint, "FenceReplica", wire.fenceRequest(&binding), pb.FenceReplicaResponse);
        defer response.deinit(self.allocator);
        return wire.parseFenceResponse(response);
    }

    fn recoverPrimary(context: *anyopaque, endpoint: []const u8, request: reconciler.RecoveryRequest) !reconciler.RecoveryResult {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        var response = try self.unary(endpoint, "RecoverPrimary", wire.recoveryRequest(&request), pb.RecoverPrimaryResponse);
        defer response.deinit(self.allocator);
        return wire.parseRecoveryResponse(response);
    }

    fn markPrimaryReady(context: *anyopaque, endpoint: []const u8, request: reconciler.MarkReadyRequest) !void {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        var response = try self.unary(endpoint, "MarkPrimaryReady", wire.markReadyRequest(&request), pb.MarkPrimaryReadyResponse);
        defer response.deinit(self.allocator);
        if (!std.meta.eql(request, try wire.parseMarkReadyResponse(response))) return error.ResponseBindingMismatch;
    }

    fn inspectPrimary(context: *anyopaque, endpoint: []const u8, request: reconciler.MarkReadyRequest) !reconciler.PrimaryLeaseStatus {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        var response = try self.unary(endpoint, "InspectPrimary", wire.inspectPrimaryRequest(&request), pb.InspectPrimaryResponse);
        defer response.deinit(self.allocator);
        return wire.parseInspectPrimaryResponse(response);
    }

    fn cancelOpaque(context: *anyopaque) void {
        const self: *RpcClient = @ptrCast(@alignCast(context));
        self.cancel();
    }

    fn unary(
        self: *RpcClient,
        endpoint: []const u8,
        comptime method: []const u8,
        request_value: anytype,
        comptime Response: type,
    ) !Response {
        var request = request_value;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try request.encode(&writer.writer, self.allocator);

        const channel = try self.allocator.create(grpc.Channel);
        channel.* = grpc.Channel.init(self.allocator, endpoint, .{}) catch |err| {
            self.allocator.destroy(channel);
            return err;
        };
        var active_registered = false;
        defer {
            if (active_registered) {
                self.mutex.lockUncancelable(self.io);
                std.debug.assert(self.active == channel);
                self.active = null;
                self.mutex.unlock(self.io);
            }
            channel.deinit();
            self.allocator.destroy(channel);
        }

        self.mutex.lockUncancelable(self.io);
        if (self.canceled or self.active != null) {
            const canceled = self.canceled;
            self.mutex.unlock(self.io);
            return if (canceled) error.Canceled else error.ConcurrentCall;
        }
        self.active = channel;
        active_registered = true;
        self.mutex.unlock(self.io);

        var result = try channel.callUnary(self.allocator, wire.methodPath(method), writer.written(), .{
            .timeout_ns = self.options.timeout_ns,
            .max_response_size = self.options.max_response_size,
        });
        defer result.deinit();
        self.mutex.lockUncancelable(self.io);
        const canceled = self.canceled;
        self.mutex.unlock(self.io);
        if (canceled) return error.Canceled;
        try requireOk(result.status.code);

        var reader: std.Io.Reader = .fixed(result.payload);
        return Response.decode(&reader, self.allocator) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidProtobufResponse,
        };
    }

    const vtable: reconciler.DataServiceClient.VTable = .{
        .ensure = ensure,
        .delete = delete,
        .identify_holder = identifyHolder,
        .stage_primary = stagePrimary,
        .fence_replica = fenceReplica,
        .recover_primary = recoverPrimary,
        .mark_primary_ready = markPrimaryReady,
        .inspect_primary = inspectPrimary,
        .cancel = cancelOpaque,
    };
};

fn requireOk(code: grpc.StatusCode) !void {
    return switch (code) {
        .ok => {},
        .cancelled => error.Canceled,
        .unknown => error.RemoteUnknown,
        .invalid_argument => error.InvalidArgument,
        .deadline_exceeded => error.DeadlineExceeded,
        .not_found => error.NotFound,
        .already_exists => error.AlreadyExists,
        .permission_denied => error.PermissionDenied,
        .resource_exhausted => error.ResourceExhausted,
        .failed_precondition => error.FailedPrecondition,
        .aborted => error.Aborted,
        .out_of_range => error.OutOfRange,
        .unimplemented => error.Unimplemented,
        .internal => error.RemoteInternal,
        .unavailable => error.Unavailable,
        .data_loss => error.DataLoss,
        .unauthenticated => error.Unauthenticated,
    };
}

const id_a: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 1 };
const id_b: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 2 };
const id_c: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 3 };
const id_d: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 4 };
const id_e: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 5 };
const id_f: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 6 };
const digest: [32]u8 = @splat(0x55);

fn testStageRequest() reconciler.StageRequest {
    return .{
        .binding = .{
            .volume_id = id_a,
            .primary_placement_id = id_b,
            .primary_node_id = id_c,
            .lease_id = id_d,
            .holder_boot_id = id_e,
            .authority_generation = 3,
            .write_epoch = 5,
            .placement_revision = 7,
            .activation_nonce = id_f,
            .authority_digest = digest,
        },
        .lease_duration_ms = 30_000,
    };
}

test "RPC client reaches canonical StagePrimary endpoint" {
    const Handler = struct {
        fn stage(
            _: *@This(),
            allocator: std.mem.Allocator,
            _: *grpc.ServerContext,
            request_bytes: []const u8,
        ) !grpc.UnaryResponse {
            var reader: std.Io.Reader = .fixed(request_bytes);
            var request = try pb.StagePrimaryRequest.decode(&reader, allocator);
            defer request.deinit(allocator);
            var response: pb.StagePrimaryResponse = .{
                .binding = request.binding,
                .lease_duration_ms = request.lease_duration_ms,
            };
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            try response.encode(&writer.writer, allocator);
            return grpc.UnaryResponse.ok(allocator, writer.written());
        }
    };

    var handler: Handler = .{};
    var server = try grpc.Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.registerUnary(
        wire.methodPath("StagePrimary"),
        grpc.UnaryHandler.bind(Handler, &handler, Handler.stage),
    );
    try server.start();

    var endpoint_buffer: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "127.0.0.1:{d}", .{try server.port()});
    var client = try RpcClient.init(std.testing.allocator, std.testing.io, .{});
    defer client.deinit();
    const request = testStageRequest();
    const response = try RpcClient.stagePrimary(&client, endpoint, request);
    try std.testing.expectEqual(request, response.request);
}

test "RPC status codes retain retry and precondition semantics" {
    try std.testing.expectError(error.FailedPrecondition, requireOk(.failed_precondition));
    try std.testing.expectError(error.Unavailable, requireOk(.unavailable));
    try std.testing.expectError(error.DeadlineExceeded, requireOk(.deadline_exceeded));
    try requireOk(.ok);
}

test "cancel promptly unblocks an in-flight RPC" {
    const Handler = struct {
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,

        fn identify(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: *grpc.ServerContext,
            _: []const u8,
        ) !grpc.UnaryResponse {
            self.entered.set(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
            var response: pb.IdentifyHolderResponse = .{ .holder_boot_id = &id_a };
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            try response.encode(&writer.writer, allocator);
            return grpc.UnaryResponse.ok(allocator, writer.written());
        }
    };
    const Call = struct {
        client: *RpcClient,
        endpoint: []const u8,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            _ = RpcClient.identifyHolder(self.client, self.endpoint) catch |err| {
                self.result = err;
                return;
            };
        }
    };

    var handler: Handler = .{};
    var server = try grpc.Server.init(std.testing.allocator, .{});
    defer server.deinit();
    try server.registerUnary(
        wire.methodPath("IdentifyHolder"),
        grpc.UnaryHandler.bind(Handler, &handler, Handler.identify),
    );
    try server.start();

    var endpoint_buffer: [32]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "127.0.0.1:{d}", .{try server.port()});
    var client = try RpcClient.init(std.testing.allocator, std.testing.io, .{ .timeout_ns = 30 * std.time.ns_per_s });
    defer client.deinit();
    var call: Call = .{ .client = &client, .endpoint = endpoint };
    const thread = try std.Thread.spawn(.{}, Call.run, .{&call});
    handler.entered.waitUncancelable(std.testing.io);
    client.cancel();
    thread.join();
    handler.release.set(std.testing.io);
    try std.testing.expectEqual(error.Canceled, call.result.?);
}
