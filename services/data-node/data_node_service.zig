const std = @import("std");

const authority_file_store = @import("authority_file_store.zig");
const grpc = @import("grpc_lite");
const pb = @import("data_node_proto");
const protocol = @import("zettide_data_service_contracts");
const file_member_backend = @import("file_member_backend.zig");
const fence_service = protocol.fence_service;
const lease = protocol.primary_lease;
const replica_service = protocol.replica_service;
const write_service = protocol.write_service;
const replica_io_gate = @import("replica_io_gate.zig");
const replica_rpc_auth = @import("replica_rpc_auth.zig");
const replica_rpc_client = @import("replica_rpc_client.zig");
const write_participant_manager = @import("write_participant_manager.zig");

pub const ReplicaFileStore = replica_service.FileStore;
pub const ReplicaCapacitySnapshot = replica_service.CapacitySnapshot;
pub const FenceFileStore = fence_service.FileStore;
pub const AuthorityFileStore = authority_file_store.FileStore;
pub const FileMemberBackend = file_member_backend.FileMemberBackend;
pub const FileFenceBackend = file_member_backend.FileFenceBackend;
pub const FileWriteBackend = file_member_backend.FileWriteBackend;
pub const WriteParticipantManager = write_participant_manager.WriteParticipantManager;
pub const ReplicaRpcPeerKey = replica_rpc_auth.PeerKey;

pub const ReplicaTransportOptions = struct {
    host: []const u8,
    port: u16,
    local_node_id: protocol.Id,
    // Receiver-scoped pairwise keys indexed by authenticated source node.
    peer_keys: []const ReplicaRpcPeerKey,
};

pub const Options = struct {
    replica_store: ?replica_service.Store = null,
    replica_backend: ?replica_service.Backend = null,
    fence_store: ?fence_service.Store = null,
    fence_backend: ?fence_service.Backend = null,
    authority_store: ?*authority_file_store.FileStore = null,
    write_parent: ?std.Io.Dir = null,
    write_replica_store: ?*replica_service.FileStore = null,
    write_fence_store: ?*fence_service.FileStore = null,
    write_backend: ?write_service.Backend = null,
    replica_transport: ?ReplicaTransportOptions = null,
};

pub const DataNodeServer = struct {
    state: *State,
    server: grpc.Server,
    replica_server: ?grpc.Server,

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
        if ((options.replica_store == null) != (options.replica_backend == null) or
            (options.fence_store == null) != (options.fence_backend == null))
            return error.IncompleteReplicaConfiguration;
        const write_configured = options.write_parent != null;
        if (write_configured != (options.write_replica_store != null) or
            write_configured != (options.write_fence_store != null) or
            write_configured != (options.write_backend != null) or
            (write_configured and (options.authority_store == null or
                options.replica_store == null or options.replica_backend == null or
                options.fence_store == null or options.fence_backend == null)))
            return error.IncompleteWriteConfiguration;
        if (options.replica_transport != null and !write_configured)
            return error.IncompleteReplicaTransportConfiguration;
        if (write_configured) {
            const expected_replica_store = options.write_replica_store.?.store();
            const expected_fence_store = options.write_fence_store.?.store();
            if (options.replica_store.?.context != expected_replica_store.context or
                options.replica_store.?.vtable != expected_replica_store.vtable or
                options.fence_store.?.context != expected_fence_store.context or
                options.fence_store.?.vtable != expected_fence_store.vtable)
                return error.MismatchedWriteConfiguration;
        }
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = try State.init(allocator, io, options);
        errdefer state.deinit();
        if (write_configured) try state.initWrites(options);
        var server = try grpc.Server.init(allocator, .{ .host = host, .port = port });
        errdefer server.deinit();
        try server.registerUnary(methodPath("EnsureReplica"), grpc.UnaryHandler.bind(State, state, State.ensureReplica));
        try server.registerUnary(methodPath("InspectReplica"), grpc.UnaryHandler.bind(State, state, State.inspectReplica));
        try server.registerUnary(methodPath("DeleteReplica"), grpc.UnaryHandler.bind(State, state, State.deleteReplica));
        try server.registerUnary(methodPath("ConfigureWriteParticipant"), grpc.UnaryHandler.bind(State, state, State.configureWriteParticipant));
        try server.registerUnary(methodPath("IdentifyHolder"), grpc.UnaryHandler.bind(State, state, State.identifyHolder));
        try server.registerUnary(methodPath("StagePrimary"), grpc.UnaryHandler.bind(State, state, State.stagePrimary));
        try server.registerUnary(methodPath("FenceReplica"), grpc.UnaryHandler.bind(State, state, State.fenceReplica));
        try server.registerUnary(methodPath("RecoverPrimary"), grpc.UnaryHandler.bind(State, state, State.recoverPrimary));
        try server.registerUnary(methodPath("MarkPrimaryReady"), grpc.UnaryHandler.bind(State, state, State.markPrimaryReady));
        try server.registerUnary(methodPath("InspectPrimary"), grpc.UnaryHandler.bind(State, state, State.inspectPrimary));
        var replica_server: ?grpc.Server = null;
        errdefer if (replica_server) |*value| value.deinit();
        if (options.replica_transport) |transport| {
            var value = try grpc.Server.init(allocator, .{ .host = transport.host, .port = transport.port });
            errdefer value.deinit();
            try value.registerUnary(replicaMethodPath("Prepare"), grpc.UnaryHandler.bind(State, state, State.prepareReplicaWrite));
            try value.registerUnary(replicaMethodPath("Commit"), grpc.UnaryHandler.bind(State, state, State.commitReplicaWrite));
            try value.registerUnary(replicaMethodPath("Inspect"), grpc.UnaryHandler.bind(State, state, State.inspectReplicaWrite));
            replica_server = value;
        }
        return .{ .state = state, .server = server, .replica_server = replica_server };
    }

    pub fn start(self: *DataNodeServer) !void {
        if (self.replica_server) |*server| try server.start();
        self.server.start() catch |err| {
            if (self.replica_server) |*server| {
                server.shutdownGracefully(0);
                server.wait();
            }
            return err;
        };
    }

    pub fn localAddress(self: *const DataNodeServer) !grpc.ServerLocalAddress {
        return self.server.localAddress();
    }

    pub fn replicaLocalAddress(self: *const DataNodeServer) !grpc.ServerLocalAddress {
        const server = if (self.replica_server) |*value| value else return error.ReplicaTransportDisabled;
        return server.localAddress();
    }

    pub fn shutdownGracefully(self: *DataNodeServer, timeout_ns: u64) void {
        self.server.shutdownGracefully(timeout_ns);
        if (self.replica_server) |*server| server.shutdownGracefully(timeout_ns);
    }

    pub fn wait(self: *DataNodeServer) void {
        self.server.wait();
        if (self.replica_server) |*server| server.wait();
    }

    pub fn deinit(self: *DataNodeServer) void {
        const allocator = self.state.allocator;
        if (self.replica_server) |*server| server.deinit();
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
    fences: ?fence_service.Service,
    authority_store: ?*authority_file_store.FileStore,
    authorities: std.AutoHashMapUnmanaged(protocol.Id, Authority) = .empty,
    writes: ?write_participant_manager.WriteParticipantManager = null,
    replica_authenticator: ?replica_rpc_auth.Authenticator = null,

    const Authority = struct {
        binding: protocol.AuthorityBinding,
        runtime: lease.Runtime,
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !State {
        var authenticator: ?replica_rpc_auth.Authenticator = null;
        errdefer if (authenticator) |*value| value.deinit();
        if (options.replica_transport) |transport|
            authenticator = try .init(allocator, transport.local_node_id, transport.peer_keys);
        return .{
            .allocator = allocator,
            .io = io,
            .boot_id = try createBootId(io),
            .replicas = if (options.replica_store) |store|
                replica_service.Service.init(store, options.replica_backend.?)
            else
                null,
            .fences = if (options.fence_store) |store|
                fence_service.Service.init(store, options.fence_backend.?)
            else
                null,
            .authority_store = options.authority_store,
            .replica_authenticator = authenticator,
        };
    }

    fn initWrites(self: *State, options: Options) !void {
        self.writes = try write_participant_manager.WriteParticipantManager.init(
            self.allocator,
            self.io,
            options.write_parent.?,
            options.write_replica_store.?,
            &self.replicas.?,
            options.write_fence_store.?,
            options.write_backend.?,
            self.authorityValidator(),
        );
    }

    fn deinit(self: *State) void {
        if (self.writes) |*writes| writes.deinit();
        if (self.replica_authenticator) |*authenticator| authenticator.deinit();
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

    fn configureWriteParticipant(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.ConfigureWriteParticipantRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid ConfigureWriteParticipant request");
        defer request.deinit(allocator);
        const configuration = parseWriteParticipantConfiguration(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid write participant binding");
        self.replica_mutex.lockUncancelable(self.io);
        defer self.replica_mutex.unlock(self.io);
        const writes = if (self.writes) |*value| value else return fail(allocator, .failed_precondition, "write participant manager is not configured");
        writes.configure(configuration.binding, configuration.backend_digest) catch |err|
            return writeConfigurationFailure(allocator, err);
        return encodeResponse(allocator, pb.ConfigureWriteParticipantResponse{ .binding = request.binding });
    }

    const ReplicaMethod = enum { ensure, inspect, delete };

    fn handleReplicaMutation(
        self: *State,
        allocator: std.mem.Allocator,
        comptime ResponseType: type,
        request: replica_service.Request,
        method: ReplicaMethod,
    ) !grpc.UnaryResponse {
        const service = if (self.replicas) |*replicas| replicas else return fail(allocator, .failed_precondition, "replica backend is not configured");
        const binding = replica_service.parseBinding(request) catch
            return fail(allocator, .invalid_argument, "invalid Replica binding");
        self.replica_mutex.lockUncancelable(self.io);
        defer self.replica_mutex.unlock(self.io);
        var control_guard: ?write_participant_manager.WriteParticipantManager.ControlGuard = if (method != .inspect)
            if (self.writes) |*writes|
                writes.beginControl(binding.placement_id, binding.generation, method == .delete) catch |err|
                    return writeControlFailure(allocator, err)
            else
                null
        else
            null;
        defer if (control_guard) |*guard| guard.end();
        const response = switch (method) {
            .ensure => service.ensureReplica(request),
            .inspect => service.inspectReplica(request),
            .delete => service.deleteReplica(request),
        } catch |err| return replicaFailure(allocator, err);
        if (method == .delete) if (control_guard) |*guard|
            guard.retire() catch |err| return writeControlFailure(allocator, err);
        return encodeReplicaResponse(allocator, ResponseType, response);
    }

    fn prepareReplicaWrite(
        self: *State,
        allocator: std.mem.Allocator,
        context: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        const method_path = replicaMethodPath("Prepare");
        const verified = self.authenticateReplicaCall(context, method_path, request_bytes) catch
            return fail(allocator, .unauthenticated, "Replica RPC authentication failed");
        var response = try self.handlePrepareReplicaWrite(allocator, verified.source_node_id, request_bytes);
        errdefer response.deinit();
        try self.authenticateReplicaResponse(context, verified, method_path, request_bytes, &response);
        return response;
    }

    fn handlePrepareReplicaWrite(
        self: *State,
        allocator: std.mem.Allocator,
        source_node_id: protocol.Id,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.ReplicaPrepareRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid Replica PREPARE request");
        defer request.deinit(allocator);
        const configuration = parseWriteParticipantConfiguration(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid Replica PREPARE binding");
        const write = parseWriteRequest(request.write) catch
            return fail(allocator, .invalid_argument, "invalid Replica PREPARE metadata");
        if (!std.mem.eql(u8, &source_node_id, &write.authority.primary_node_id))
            return fail(allocator, .permission_denied, "Replica coordinator identity mismatch");
        const writes = if (self.writes) |*value| value else return fail(allocator, .failed_precondition, "write participant manager is not configured");
        const attestation = writes.prepareConfigured(
            configuration.binding,
            configuration.backend_digest,
            .{ .write = write, .data = request.data },
        ) catch |err| return replicaWriteFailure(allocator, err, "Replica PREPARE rejected");
        return encodeResponse(allocator, pb.ReplicaPrepareResponse{
            .attestation = attestationProto(&attestation),
        });
    }

    fn commitReplicaWrite(
        self: *State,
        allocator: std.mem.Allocator,
        context: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        const method_path = replicaMethodPath("Commit");
        const verified = self.authenticateReplicaCall(context, method_path, request_bytes) catch
            return fail(allocator, .unauthenticated, "Replica RPC authentication failed");
        var response = try self.handleCommitReplicaWrite(allocator, verified.source_node_id, request_bytes);
        errdefer response.deinit();
        try self.authenticateReplicaResponse(context, verified, method_path, request_bytes, &response);
        return response;
    }

    fn handleCommitReplicaWrite(
        self: *State,
        allocator: std.mem.Allocator,
        source_node_id: protocol.Id,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.ReplicaCommitRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid Replica COMMIT request");
        defer request.deinit(allocator);
        const configuration = parseWriteParticipantConfiguration(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid Replica COMMIT binding");
        const authority = parseAuthorityBinding(request.authority) catch
            return fail(allocator, .invalid_argument, "invalid Replica COMMIT authority");
        const transaction_id = fixedId(request.transaction_id) catch
            return fail(allocator, .invalid_argument, "invalid Replica COMMIT transaction");
        if (request.sequence == 0)
            return fail(allocator, .invalid_argument, "invalid Replica COMMIT sequence");
        const certificate = parseCommitCertificate(request.attestations.items) catch
            return fail(allocator, .invalid_argument, "invalid Replica COMMIT certificate");
        if (!std.mem.eql(u8, &source_node_id, &authority.primary_node_id))
            return fail(allocator, .permission_denied, "Replica coordinator identity mismatch");
        const writes = if (self.writes) |*value| value else return fail(allocator, .failed_precondition, "write participant manager is not configured");
        const result = writes.commitConfigured(
            configuration.binding,
            configuration.backend_digest,
            authority,
            transaction_id,
            request.sequence,
            certificate,
        ) catch |err| return replicaWriteFailure(allocator, err, "Replica COMMIT rejected");
        return encodeResponse(allocator, commitResultProto(&result));
    }

    fn inspectReplicaWrite(
        self: *State,
        allocator: std.mem.Allocator,
        context: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        const method_path = replicaMethodPath("Inspect");
        const verified = self.authenticateReplicaCall(context, method_path, request_bytes) catch
            return fail(allocator, .unauthenticated, "Replica RPC authentication failed");
        var response = try self.handleInspectReplicaWrite(allocator, verified.source_node_id, request_bytes);
        errdefer response.deinit();
        try self.authenticateReplicaResponse(context, verified, method_path, request_bytes, &response);
        return response;
    }

    fn handleInspectReplicaWrite(
        self: *State,
        allocator: std.mem.Allocator,
        source_node_id: protocol.Id,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.ReplicaWriteInspectRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid Replica INSPECT request");
        defer request.deinit(allocator);
        const configuration = parseWriteParticipantConfiguration(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid Replica INSPECT binding");
        const authority = parseAuthorityBinding(request.authority) catch
            return fail(allocator, .invalid_argument, "invalid Replica INSPECT authority");
        if (!std.mem.eql(u8, &source_node_id, &authority.primary_node_id))
            return fail(allocator, .permission_denied, "Replica coordinator identity mismatch");
        const writes = if (self.writes) |*value| value else return fail(allocator, .failed_precondition, "write participant manager is not configured");
        const inspection = writes.inspectConfigured(
            configuration.binding,
            configuration.backend_digest,
        ) catch |err|
            return replicaWriteFailure(allocator, err, "Replica INSPECT rejected");
        return encodeWriteInspection(allocator, inspection);
    }

    fn authenticateReplicaCall(
        self: *State,
        context: *grpc.ServerContext,
        method_path: []const u8,
        request_bytes: []const u8,
    ) !replica_rpc_auth.VerifiedRequest {
        const authenticator = if (self.replica_authenticator) |*value| value else return error.ReplicaAuthenticationUnavailable;
        return authenticator.verify(context.request_metadata.items(), method_path, request_bytes) catch
            return error.ReplicaAuthenticationFailed;
    }

    fn authenticateReplicaResponse(
        self: *State,
        context: *grpc.ServerContext,
        verified: replica_rpc_auth.VerifiedRequest,
        method_path: []const u8,
        request_bytes: []const u8,
        response: *const grpc.UnaryResponse,
    ) !void {
        const authenticator = if (self.replica_authenticator) |*value| value else return error.ReplicaAuthenticationUnavailable;
        const tag = try authenticator.responseTag(
            verified.source_node_id,
            verified.challenge,
            method_path,
            request_bytes,
            @intFromEnum(response.status.code),
            response.status.message,
            response.payload,
        );
        try context.addTrailingMetadata(replica_rpc_auth.response_authentication_metadata, &tag);
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
        if (self.authority_store == null)
            return fail(allocator, .failed_precondition, "durable authority state is not configured");
        if (!std.mem.eql(u8, &binding.holder_boot_id, &self.boot_id))
            return fail(allocator, .failed_precondition, "holder boot identity mismatch");

        self.stage(binding) catch |err| return switch (err) {
            error.OutOfMemory, error.StoreFull => fail(allocator, .resource_exhausted, "authority state exhausted"),
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

    fn fenceReplica(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.FenceReplicaRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid FenceReplica request");
        defer request.deinit(allocator);
        const binding = parseFenceBinding(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid fence binding");
        self.replica_mutex.lockUncancelable(self.io);
        defer self.replica_mutex.unlock(self.io);
        var control_guard: ?write_participant_manager.WriteParticipantManager.ControlGuard = if (self.writes) |*writes|
            writes.beginControl(binding.placement_id, binding.replica_generation, false) catch |err|
                return writeControlFailure(allocator, err)
        else
            null;
        defer if (control_guard) |*guard| guard.end();
        const service = if (self.fences) |*fences| fences else return fail(allocator, .failed_precondition, "fence backend is not configured");
        const result = service.accept(binding) catch |err| return fenceFailure(allocator, err);
        return encodeResponse(allocator, pb.FenceReplicaResponse{
            .binding = fenceProto(&result.binding),
            .fence_digest = &result.fence_digest,
        });
    }

    fn recoverPrimary(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.RecoverPrimaryRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid RecoverPrimary request");
        defer request.deinit(allocator);
        const binding = parseAuthorityBinding(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid authority binding");
        if (self.authority_store == null)
            return fail(allocator, .failed_precondition, "durable authority state is not configured");
        if (!std.mem.eql(u8, &binding.holder_boot_id, &self.boot_id))
            return fail(allocator, .failed_precondition, "holder boot identity mismatch");
        const recovered = self.recover(binding) catch |err| return authorityFailure(allocator, err, "primary recovery failed");
        return encodeResponse(allocator, pb.RecoverPrimaryResponse{
            .binding = authorityProto(&binding),
            .certified_sequence = recovered.certified_sequence,
            .history_digest = &recovered.history_digest,
            .empty_frontier = recovered.empty_frontier,
        });
    }

    fn markPrimaryReady(
        self: *State,
        allocator: std.mem.Allocator,
        _: *grpc.ServerContext,
        request_bytes: []const u8,
    ) !grpc.UnaryResponse {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var request = pb.MarkPrimaryReadyRequest.decode(&reader, allocator) catch
            return fail(allocator, .invalid_argument, "invalid MarkPrimaryReady request");
        defer request.deinit(allocator);
        const binding = parseAuthorityBinding(request.binding) catch
            return fail(allocator, .invalid_argument, "invalid authority binding");
        if (self.authority_store == null)
            return fail(allocator, .failed_precondition, "durable authority state is not configured");
        if (!std.mem.eql(u8, &binding.holder_boot_id, &self.boot_id))
            return fail(allocator, .failed_precondition, "holder boot identity mismatch");
        self.markReady(binding) catch |err| return authorityFailure(allocator, err, "primary readiness failed");
        return encodeResponse(allocator, pb.MarkPrimaryReadyResponse{ .binding = authorityProto(&binding) });
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
        const status = self.inspect(binding) catch
            return fail(allocator, .internal, "authority inspection failed");
        return encodeResponse(allocator, pb.InspectPrimaryResponse{
            .binding = authorityProto(&binding),
            .current_active = status.current_active,
            .current_admitting = status.current_admitting,
            .candidate_fresh = status.candidate_fresh,
            .should_renew = status.should_renew,
        });
    }

    fn authorityValidator(self: *State) replica_io_gate.AuthorityValidator {
        return .{ .context = self, .validate_fn = validateWriteAuthorityOpaque };
    }

    fn validateWriteAuthorityOpaque(context: *anyopaque, binding: protocol.AuthorityBinding) !void {
        const self: *State = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now_ms = try nowAwakeMs(self.io);
        const store = self.authority_store orelse return error.AuthorityStoreRequired;
        const durable = (try store.validate(binding, .ready)) orelse return error.AuthorityNotReady;
        if (durable.phase != .ready or !std.meta.eql(durable.binding, binding))
            return error.AuthorityNotReady;
        const authority = self.authorities.get(binding.volume_id) orelse return error.AuthorityNotStaged;
        if (!std.meta.eql(authority.binding, binding)) return error.AuthorityConflict;
        if (!authority.runtime.canAdmit(authorityToken(binding), now_ms)) return error.LeaseExpired;
    }

    fn stage(self: *State, binding: protocol.AuthorityBinding) !void {
        const token = authorityToken(binding);
        const now_ms = try nowAwakeMs(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const store = self.authority_store orelse return error.AuthorityStoreRequired;
        const durable_existing = try store.validate(binding, .staged);
        const existing = self.authorities.get(binding.volume_id);
        var next: Authority = if (existing) |authority| authority else .{
            .binding = binding,
            .runtime = try lease.Runtime.init(self.boot_id),
        };
        if (std.mem.eql(u8, &next.binding.lease_id, &binding.lease_id) and
            !std.meta.eql(next.binding, binding)) return error.AuthorityConflict;
        _ = try next.runtime.stage(token, now_ms);
        next.binding = binding;

        if (existing == null) try self.authorities.ensureUnusedCapacity(self.allocator, 1);
        if (durable_existing == null)
            try store.append(.{ .binding = binding, .phase = .staged });
        if (self.authorities.getPtr(binding.volume_id)) |authority| {
            authority.* = next;
        } else {
            self.authorities.putAssumeCapacity(binding.volume_id, next);
        }
    }

    fn recover(self: *State, binding: protocol.AuthorityBinding) !authority_file_store.Record {
        if (self.writes) |*writes|
            if (try writes.hasWriteHistory(binding.volume_id))
                return error.RecoveryQuorumRequired;
        const now_ms = try nowAwakeMs(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const authority = self.authorities.get(binding.volume_id) orelse return error.AuthorityNotStaged;
        if (!std.meta.eql(authority.binding, binding)) return error.AuthorityConflict;
        if (!authority.runtime.canMarkReadyToken(authorityToken(binding), now_ms)) return error.CandidateNotFresh;
        if (self.authority_store) |store| {
            if (try store.validate(binding, .recovered)) |existing| {
                if (existing.phase == .recovered or (existing.phase == .ready and !isZero(&existing.history_digest)))
                    return existing;
                return error.RecoveryEvidenceUnavailable;
            }
        }
        const record: authority_file_store.Record = .{
            .binding = binding,
            .phase = .recovered,
            .certified_sequence = 0,
            .history_digest = recoveryDigest(binding),
            .empty_frontier = true,
        };
        if (self.authority_store) |store| try store.append(record);
        return record;
    }

    fn markReady(self: *State, binding: protocol.AuthorityBinding) !void {
        if (try self.currentlyAdmitting(binding)) return;
        if (self.writes) |*writes|
            if (try writes.hasWriteHistory(binding.volume_id))
                return error.RecoveryQuorumRequired;
        const token = authorityToken(binding);
        const now_ms = try nowAwakeMs(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const authority = self.authorities.getPtr(binding.volume_id) orelse return error.AuthorityNotStaged;
        if (!std.meta.eql(authority.binding, binding)) return error.AuthorityConflict;
        if (authority.runtime.canAdmit(token, now_ms)) return;
        if (!authority.runtime.canMarkReadyToken(token, now_ms)) return error.CandidateNotFresh;
        if (self.authority_store) |store| {
            if (try store.validate(binding, .ready) == null) {
                const existing = store.latest(binding.volume_id);
                try store.append(.{
                    .binding = binding,
                    .phase = .ready,
                    .certified_sequence = if (existing) |value| value.certified_sequence else 0,
                    .history_digest = if (existing) |value| value.history_digest else @splat(0),
                    .empty_frontier = if (existing) |value| value.empty_frontier else false,
                });
            }
        }
        try authority.runtime.markReady(binding.lease_id, now_ms);
    }

    fn currentlyAdmitting(self: *State, binding: protocol.AuthorityBinding) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const authority = self.authorities.get(binding.volume_id) orelse return false;
        if (!std.meta.eql(authority.binding, binding)) return false;
        const now_ms = try nowAwakeMs(self.io);
        return authority.runtime.canAdmit(authorityToken(binding), now_ms);
    }

    fn inspect(self: *State, binding: protocol.AuthorityBinding) !protocol.PrimaryLeaseStatus {
        const now_ms = try nowAwakeMs(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const authority = self.authorities.get(binding.volume_id) orelse return .{
            .request = .{ .binding = binding },
            .current_active = false,
            .current_admitting = false,
            .candidate_fresh = false,
            .should_renew = false,
        };
        const token = authorityToken(binding);
        return .{
            .request = .{ .binding = binding },
            .current_active = authority.runtime.canComplete(token, now_ms),
            .current_admitting = authority.runtime.canAdmit(token, now_ms),
            .candidate_fresh = authority.runtime.canMarkReadyToken(token, now_ms),
            .should_renew = authority.runtime.shouldRenew(token, now_ms),
        };
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

fn fenceFailure(allocator: std.mem.Allocator, err: anyerror) !grpc.UnaryResponse {
    return switch (err) {
        error.InvalidBinding => fail(allocator, .invalid_argument, "invalid fence request"),
        error.OperationConflict,
        error.EpochRegression,
        error.AuthorityConflict,
        error.ReplicaNotFound,
        error.OperationInProgress,
        error.ReplicaNotActive,
        error.FenceBindingMismatch,
        => fail(allocator, .failed_precondition, "fence request rejected"),
        error.OutOfMemory, error.StoreFull => fail(allocator, .resource_exhausted, "fence state exhausted"),
        else => fail(allocator, .internal, "fence operation failed"),
    };
}

fn writeConfigurationFailure(allocator: std.mem.Allocator, err: anyerror) !grpc.UnaryResponse {
    return switch (err) {
        error.ReplicaNotFound => fail(allocator, .not_found, "participant Replica not found"),
        error.InvalidReplicaSet,
        error.MemberNotInReplicaSet,
        error.ReplicaStateMismatch,
        error.ReplicaRetired,
        error.ReplicaNotActive,
        error.MemberBackendIdentityMismatch,
        => fail(allocator, .failed_precondition, "write participant configuration rejected"),
        error.OutOfMemory, error.StoreFull => fail(allocator, .resource_exhausted, "participant state exhausted"),
        else => fail(allocator, .internal, "write participant configuration failed"),
    };
}

fn replicaWriteFailure(
    allocator: std.mem.Allocator,
    err: anyerror,
    message: []const u8,
) !grpc.UnaryResponse {
    return switch (err) {
        error.ParticipantNotConfigured => fail(allocator, .not_found, "write participant is not configured"),
        error.InvalidWrite,
        error.InvalidAuthority,
        error.InvalidCertificate,
        error.InvalidReplicaSet,
        error.MemberNotInReplicaSet,
        error.DataDigestMismatch,
        error.WriteOutOfBounds,
        error.VolumeMismatch,
        => fail(allocator, .invalid_argument, message),
        error.AuthorityFenced,
        error.FenceRequired,
        error.FenceGenerationMismatch,
        error.AuthorityConflict,
        error.StaleAuthority,
        error.LeaseExpired,
        error.LeaseMismatch,
        error.ReplicaNotFound,
        error.ReplicaNotActive,
        error.ReplicaRetired,
        error.ReplicaStateMismatch,
        error.MemberBackendIdentityMismatch,
        error.BackendInspectionUnavailable,
        error.ReplicaBackendNotActive,
        error.MemberIdentityMismatch,
        error.MemberMismatch,
        error.UnalignedAllocation,
        error.AllocationOutOfBounds,
        error.MemberGeometryChanged,
        error.SequenceMismatch,
        error.HistoryMismatch,
        error.TransactionConflict,
        error.TransactionNotFound,
        error.WriteInProgress,
        error.DuplicateWitness,
        error.NonCanonicalCertificate,
        error.CertificateMemberNotEligible,
        error.CertificateMismatch,
        error.LocalAttestationRequired,
        => fail(allocator, .failed_precondition, message),
        error.OutOfMemory, error.StoreFull => fail(allocator, .resource_exhausted, "write participant state exhausted"),
        else => fail(allocator, .internal, message),
    };
}

fn writeControlFailure(allocator: std.mem.Allocator, err: anyerror) !grpc.UnaryResponse {
    return switch (err) {
        error.WriteInProgress,
        error.ReplicaRetired,
        error.AuthorityFenced,
        error.FenceRequired,
        error.FenceGenerationMismatch,
        error.ReplicaNotActive,
        => fail(allocator, .failed_precondition, "participant control barrier rejected"),
        error.OutOfMemory, error.StoreFull => fail(allocator, .resource_exhausted, "participant state exhausted"),
        else => fail(allocator, .internal, "participant control barrier failed"),
    };
}

fn authorityFailure(allocator: std.mem.Allocator, err: anyerror, message: []const u8) !grpc.UnaryResponse {
    return switch (err) {
        error.AuthorityConflict,
        error.StaleAuthority,
        error.AuthorityNotStaged,
        error.CandidateNotFresh,
        error.RecoveryEvidenceUnavailable,
        error.RecoveryQuorumRequired,
        error.LeaseConflict,
        error.LeaseMismatch,
        error.NoCandidate,
        error.InsufficientWindow,
        error.BootMismatch,
        => fail(allocator, .failed_precondition, message),
        error.OutOfMemory, error.StoreFull => fail(allocator, .resource_exhausted, "authority state exhausted"),
        else => fail(allocator, .internal, message),
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

const WriteParticipantConfiguration = struct {
    binding: write_service.ParticipantBinding,
    backend_digest: protocol.Digest,
};

fn parseWriteParticipantConfiguration(value: ?pb.DataWriteParticipantBinding) !WriteParticipantConfiguration {
    const binding = value orelse return error.MissingBinding;
    if (binding.generation == 0 or binding.length_bytes == 0 or
        binding.replica_member_ids.items.len != 3)
        return error.InvalidReplicaSet;
    _ = std.math.add(u64, binding.offset_bytes, binding.length_bytes) catch return error.InvalidReplicaSet;
    const parsed: protocol.ReplicaBinding = .{
        .volume_id = try uuid(binding.volume_id),
        .placement_id = try uuid(binding.placement_id),
        .allocation_id = try uuid(binding.allocation_id),
        .generation = binding.generation,
        .member_id = try fixedId(binding.member_id),
        .offset_bytes = binding.offset_bytes,
        .length_bytes = binding.length_bytes,
    };
    const members: [3]protocol.Id = .{
        try fixedId(binding.replica_member_ids.items[0]),
        try fixedId(binding.replica_member_ids.items[1]),
        try fixedId(binding.replica_member_ids.items[2]),
    };
    if (isZero(&members[0]) or isZero(&members[1]) or isZero(&members[2]) or
        std.mem.order(u8, &members[0], &members[1]) != .lt or
        std.mem.order(u8, &members[1], &members[2]) != .lt)
        return error.InvalidReplicaSet;
    var contains_local = false;
    for (members) |member| if (std.mem.eql(u8, &member, &parsed.member_id)) {
        contains_local = true;
        break;
    };
    if (!contains_local) return error.MemberNotInReplicaSet;
    return .{
        .binding = .{ .replica = parsed, .replica_members = members },
        .backend_digest = try digest(binding.backend_digest),
    };
}

fn parseWriteRequest(value: ?pb.DataWriteRequest) !write_service.WriteRequest {
    const write = value orelse return error.MissingWrite;
    if (write.replica_member_ids.items.len != 3) return error.InvalidReplicaSet;
    return .{
        .authority = try parseAuthorityBinding(write.authority),
        .replica_members = .{
            try fixedId(write.replica_member_ids.items[0]),
            try fixedId(write.replica_member_ids.items[1]),
            try fixedId(write.replica_member_ids.items[2]),
        },
        .sequence = write.sequence,
        .transaction_id = try fixedId(write.transaction_id),
        .previous_history_digest = try fixedDigest(write.previous_history_digest),
        .offset_bytes = write.offset_bytes,
        .length_bytes = write.length_bytes,
        .data_digest = try digest(write.data_digest),
    };
}

fn parseCommitCertificate(values: []const pb.DataPrepareAttestation) !write_service.CommitCertificate {
    if (values.len != write_service.certificate_witness_count) return error.InvalidCertificate;
    return .{ .attestations = .{
        try parseAttestation(values[0]),
        try parseAttestation(values[1]),
    } };
}

fn parseAttestation(value: pb.DataPrepareAttestation) !write_service.PrepareAttestation {
    return .{
        .member_id = try fixedId(value.member_id),
        .transaction_digest = try digest(value.transaction_digest),
        .prepare_digest = try digest(value.prepare_digest),
        .prepared_history_digest = try digest(value.prepared_history_digest),
    };
}

fn attestationProto(value: *const write_service.PrepareAttestation) pb.DataPrepareAttestation {
    return .{
        .member_id = &value.member_id,
        .transaction_digest = &value.transaction_digest,
        .prepare_digest = &value.prepare_digest,
        .prepared_history_digest = &value.prepared_history_digest,
    };
}

fn commitResultProto(value: *const write_service.CommitResult) pb.ReplicaCommitResponse {
    return .{
        .transaction_id = &value.transaction_id,
        .sequence = value.sequence,
        .history_digest = &value.history_digest,
    };
}

fn encodeWriteInspection(
    allocator: std.mem.Allocator,
    inspection: write_service.Inspection,
) !grpc.UnaryResponse {
    var stable = inspection;
    var member_ids: std.ArrayList([]const u8) = .empty;
    defer member_ids.deinit(allocator);
    var pending: ?pb.DataPendingWrite = null;
    if (stable.pending) |*value| {
        for (&value.write.replica_members) |*member_id| try member_ids.append(allocator, member_id);
        pending = .{
            .write = .{
                .authority = authorityProto(&value.write.authority),
                .replica_member_ids = member_ids,
                .sequence = value.write.sequence,
                .transaction_id = &value.write.transaction_id,
                .previous_history_digest = &value.write.previous_history_digest,
                .offset_bytes = value.write.offset_bytes,
                .length_bytes = value.write.length_bytes,
                .data_digest = &value.write.data_digest,
            },
            .attestation = attestationProto(&value.attestation),
            .commit_decided = value.commit_decided,
        };
    }
    const last_completed = if (stable.last_completed) |*value| commitResultProto(value) else null;
    return encodeResponse(allocator, pb.ReplicaWriteInspectResponse{
        .frontier_sequence = stable.frontier.sequence,
        .frontier_history_digest = &stable.frontier.history_digest,
        .pending = pending,
        .last_completed = last_completed,
    });
}

fn parseFenceBinding(binding: ?pb.DataReplicaFenceBinding) !fence_service.Binding {
    const value = binding orelse return error.MissingBinding;
    if (value.replica_generation == 0 or value.write_epoch == 0) return error.InvalidBinding;
    return .{
        .operation_id = try uuid(value.operation_id),
        .volume_id = try uuid(value.volume_id),
        .placement_id = try uuid(value.placement_id),
        .replica_generation = value.replica_generation,
        .write_epoch = value.write_epoch,
        .primary_node_id = try uuid(value.primary_node_id),
        .lease_id = try uuid(value.lease_id),
        .authority_digest = try digest(value.authority_digest),
    };
}

fn fenceProto(binding: *const fence_service.Binding) pb.DataReplicaFenceBinding {
    return .{
        .operation_id = &binding.operation_id,
        .volume_id = &binding.volume_id,
        .placement_id = &binding.placement_id,
        .replica_generation = binding.replica_generation,
        .write_epoch = binding.write_epoch,
        .primary_node_id = &binding.primary_node_id,
        .lease_id = &binding.lease_id,
        .authority_digest = &binding.authority_digest,
    };
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

fn recoveryDigest(binding: protocol.AuthorityBinding) protocol.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("zettide-file-recovery-v1");
    hasher.update(&binding.volume_id);
    hasher.update(&binding.primary_placement_id);
    hasher.update(&binding.primary_node_id);
    hasher.update(&binding.lease_id);
    hasher.update(&binding.holder_boot_id);
    var integer: [8]u8 = undefined;
    std.mem.writeInt(u64, &integer, binding.authority_generation, .little);
    hasher.update(&integer);
    std.mem.writeInt(u64, &integer, binding.write_epoch, .little);
    hasher.update(&integer);
    std.mem.writeInt(u64, &integer, binding.placement_revision, .little);
    hasher.update(&integer);
    hasher.update(&binding.activation_nonce);
    hasher.update(&binding.authority_digest);
    var result: protocol.Digest = undefined;
    hasher.final(&result);
    return result;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn fixedId(bytes: []const u8) !protocol.Id {
    if (bytes.len != 16) return error.InvalidFixedId;
    return bytes[0..16].*;
}

fn uuid(bytes: []const u8) !protocol.Id {
    if (bytes.len != 16) return error.InvalidUuid;
    const id = bytes[0..16].*;
    if (id[6] & 0xf0 != 0x70 or id[8] & 0xc0 != 0x80) return error.InvalidUuid;
    return id;
}

fn fixedDigest(bytes: []const u8) !protocol.Digest {
    if (bytes.len != 32) return error.InvalidDigest;
    return bytes[0..32].*;
}

fn digest(bytes: []const u8) !protocol.Digest {
    const value = try fixedDigest(bytes);
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

fn replicaMethodPath(comptime method: []const u8) []const u8 {
    return "/zettide.controller.v1.ReplicaTransport/" ++ method;
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
        @splat(0x6a),
        64 * 1024,
        4096,
    );
    defer backend.deinit();
    var fence_store = try FenceFileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences.state");
    defer fence_store.deinit();
    var authority_store = try AuthorityFileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "authority.state");
    defer authority_store.deinit();
    var fence_backend = FileFenceBackend.init(&backend, &store);
    var write_backend = FileWriteBackend.init(&backend, &store);
    var other_store = try ReplicaFileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "other-replicas.state");
    defer other_store.deinit();
    var local_node = member;
    local_node[15] = 0x40;
    var coordinator_node = member;
    coordinator_node[15] = 0x41;
    const coordinator_key: replica_rpc_auth.Key = @splat(0x9b);
    const replica_peers = [_]ReplicaRpcPeerKey{.{
        .node_id = coordinator_node,
        .key = coordinator_key,
    }};
    try std.testing.expectError(
        error.MismatchedWriteConfiguration,
        DataNodeServer.initWithOptions(std.testing.allocator, std.testing.io, "127.0.0.1", 0, .{
            .replica_store = store.store(),
            .replica_backend = backend.backend(),
            .fence_store = fence_store.store(),
            .fence_backend = fence_backend.backend(),
            .authority_store = &authority_store,
            .write_parent = tmp.dir,
            .write_replica_store = &other_store,
            .write_fence_store = &fence_store,
            .write_backend = write_backend.backend(),
        }),
    );
    const cloned_replica_vtable = store.store().vtable.*;
    var forged_replica_store = store.store();
    forged_replica_store.vtable = &cloned_replica_vtable;
    try std.testing.expectError(
        error.MismatchedWriteConfiguration,
        DataNodeServer.initWithOptions(std.testing.allocator, std.testing.io, "127.0.0.1", 0, .{
            .replica_store = forged_replica_store,
            .replica_backend = backend.backend(),
            .fence_store = fence_store.store(),
            .fence_backend = fence_backend.backend(),
            .authority_store = &authority_store,
            .write_parent = tmp.dir,
            .write_replica_store = &store,
            .write_fence_store = &fence_store,
            .write_backend = write_backend.backend(),
        }),
    );
    var server = try DataNodeServer.initWithOptions(std.testing.allocator, std.testing.io, "127.0.0.1", 0, .{
        .replica_store = store.store(),
        .replica_backend = backend.backend(),
        .fence_store = fence_store.store(),
        .fence_backend = fence_backend.backend(),
        .authority_store = &authority_store,
        .write_parent = tmp.dir,
        .write_replica_store = &store,
        .write_fence_store = &fence_store,
        .write_backend = write_backend.backend(),
        .replica_transport = .{
            .host = "127.0.0.1",
            .port = 0,
            .local_node_id = local_node,
            .peer_keys = &replica_peers,
        },
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

    const replica_binding = try replica_service.parseBinding(replicaRequest(ensure_request));
    var participant_members: [3]protocol.Id = .{ member, member, member };
    participant_members[1][15] = 10;
    participant_members[2][15] = 11;
    var participant_member_views: [3][]const u8 = .{
        &participant_members[0],
        &participant_members[1],
        &participant_members[2],
    };
    var configure_request: pb.ConfigureWriteParticipantRequest = .{ .binding = .{
        .volume_id = &replica_binding.volume_id,
        .placement_id = &replica_binding.placement_id,
        .allocation_id = &replica_binding.allocation_id,
        .generation = replica_binding.generation,
        .member_id = &replica_binding.member_id,
        .offset_bytes = replica_binding.offset_bytes,
        .length_bytes = replica_binding.length_bytes,
        .backend_digest = ensured.replica.?.attestation.?.backend_digest,
        .replica_member_ids = .{ .items = &participant_member_views, .capacity = participant_member_views.len },
    } };
    var configure_result = try testCallUnary(&channel, methodPath("ConfigureWriteParticipant"), &configure_request);
    defer configure_result.deinit();
    try std.testing.expect(configure_result.status.isOk());
    var configure_retry = try testCallUnary(&channel, methodPath("ConfigureWriteParticipant"), &configure_request);
    defer configure_retry.deinit();
    try std.testing.expect(configure_retry.status.isOk());
    participant_member_views[1] = &participant_members[0];
    var invalid_configuration = try testCallUnary(&channel, methodPath("ConfigureWriteParticipant"), &configure_request);
    defer invalid_configuration.deinit();
    try std.testing.expectEqual(grpc.StatusCode.invalid_argument, invalid_configuration.status.code);
    participant_member_views[1] = &participant_members[1];

    var replica_endpoint_buffer: [32]u8 = undefined;
    const replica_address = try server.replicaLocalAddress();
    const replica_endpoint = try std.fmt.bufPrint(
        &replica_endpoint_buffer,
        "{s}:{d}",
        .{ replica_address.host, replica_address.port },
    );
    var replica_channel = try grpc.Channel.init(std.testing.allocator, replica_endpoint, .{});
    defer replica_channel.deinit();
    const authority_digest_for_inspect: protocol.Digest = @splat(0x77);
    var authority_placement = coordinator_node;
    authority_placement[15] = 0x42;
    var authority_lease = coordinator_node;
    authority_lease[15] = 0x43;
    var authority_boot = coordinator_node;
    authority_boot[15] = 0x44;
    var authority_nonce = coordinator_node;
    authority_nonce[15] = 0x45;
    var replica_inspect_request: pb.ReplicaWriteInspectRequest = .{
        .binding = configure_request.binding,
        .authority = .{
            .volume_id = &replica_binding.volume_id,
            .primary_placement_id = &authority_placement,
            .primary_node_id = &coordinator_node,
            .lease_id = &authority_lease,
            .holder_boot_id = &authority_boot,
            .authority_generation = 1,
            .write_epoch = 1,
            .placement_revision = 1,
            .activation_nonce = &authority_nonce,
            .authority_digest = &authority_digest_for_inspect,
        },
    };
    var unsigned_inspect = try testCallUnary(&replica_channel, replicaMethodPath("Inspect"), &replica_inspect_request);
    defer unsigned_inspect.deinit();
    try std.testing.expectEqual(grpc.StatusCode.unauthenticated, unsigned_inspect.status.code);
    var authenticated_inspect = try testCallUnaryAuthenticated(
        &replica_channel,
        replicaMethodPath("Inspect"),
        &replica_inspect_request,
        coordinator_node,
        local_node,
        coordinator_key,
    );
    defer authenticated_inspect.deinit();
    try std.testing.expect(authenticated_inspect.status.isOk());
    var replica_client = try replica_rpc_client.Client.init(
        std.testing.allocator,
        std.testing.io,
        coordinator_node,
        local_node,
        coordinator_key,
        .{},
    );
    defer replica_client.deinit();
    const remote_inspection = try replica_client.inspect(
        replica_endpoint,
        .{
            .participant = .{
                .replica = replica_binding,
                .replica_members = participant_members,
            },
            .backend_digest = ensured.replica.?.attestation.?.backend_digest[0..32].*,
        },
        try parseAuthorityBinding(replica_inspect_request.authority),
    );
    try std.testing.expectEqual(@as(u64, 0), remote_inspection.frontier.sequence);
    try std.testing.expect(remote_inspection.pending == null);
    var wrong_coordinator_authority = try parseAuthorityBinding(replica_inspect_request.authority);
    wrong_coordinator_authority.primary_node_id = local_node;
    try std.testing.expectError(
        error.PermissionDenied,
        replica_client.inspect(
            replica_endpoint,
            .{
                .participant = .{
                    .replica = replica_binding,
                    .replica_members = participant_members,
                },
                .backend_digest = ensured.replica.?.attestation.?.backend_digest[0..32].*,
            },
            wrong_coordinator_authority,
        ),
    );
    var wrong_backend_binding: replica_rpc_client.Binding = .{
        .participant = .{
            .replica = replica_binding,
            .replica_members = participant_members,
        },
        .backend_digest = ensured.replica.?.attestation.?.backend_digest[0..32].*,
    };
    wrong_backend_binding.backend_digest[0] ^= 0xff;
    try std.testing.expectError(
        error.FailedPrecondition,
        replica_client.inspect(
            replica_endpoint,
            wrong_backend_binding,
            try parseAuthorityBinding(replica_inspect_request.authority),
        ),
    );
    const drifted_before_inspect = try tmp.dir.openFile(std.testing.io, "member.img", .{ .mode = .read_write });
    try drifted_before_inspect.setLength(std.testing.io, 32 * 1024);
    drifted_before_inspect.close(std.testing.io);
    try std.testing.expectError(
        error.FailedPrecondition,
        replica_client.inspect(
            replica_endpoint,
            .{
                .participant = .{
                    .replica = replica_binding,
                    .replica_members = participant_members,
                },
                .backend_digest = ensured.replica.?.attestation.?.backend_digest[0..32].*,
            },
            try parseAuthorityBinding(replica_inspect_request.authority),
        ),
    );
    const restored_after_inspect = try tmp.dir.openFile(std.testing.io, "member.img", .{ .mode = .read_write });
    try restored_after_inspect.setLength(std.testing.io, 64 * 1024);
    restored_after_inspect.close(std.testing.io);
    var wrong_listener = try testCallUnaryAuthenticated(
        &channel,
        replicaMethodPath("Inspect"),
        &replica_inspect_request,
        coordinator_node,
        local_node,
        coordinator_key,
    );
    defer wrong_listener.deinit();
    try std.testing.expectEqual(grpc.StatusCode.unimplemented, wrong_listener.status.code);
    var management_on_replica = try testCallUnary(&replica_channel, methodPath("InspectReplica"), &pb.InspectReplicaRequest{});
    defer management_on_replica.deinit();
    try std.testing.expectEqual(grpc.StatusCode.unimplemented, management_on_replica.status.code);

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

    var volume_bytes = member;
    volume_bytes[15] = 0x22;
    var placement_bytes = member;
    placement_bytes[15] = 0x23;
    var operation_bytes = member;
    operation_bytes[15] = 0x31;
    const primary_node = coordinator_node;
    var lease_id = member;
    lease_id[15] = 0x33;
    const authority_digest: protocol.Digest = @splat(0x44);
    var identify_holder_request: pb.IdentifyHolderRequest = .{};
    var identify_holder_result = try testCallUnary(&channel, methodPath("IdentifyHolder"), &identify_holder_request);
    defer identify_holder_result.deinit();
    try std.testing.expect(identify_holder_result.status.isOk());
    var identify_holder_reader: std.Io.Reader = .fixed(identify_holder_result.payload);
    var identified_holder = try pb.IdentifyHolderResponse.decode(&identify_holder_reader, std.testing.allocator);
    defer identified_holder.deinit(std.testing.allocator);
    var activation_nonce = member;
    activation_nonce[15] = 0x34;
    const authority_binding: pb.DataAuthorityBinding = .{
        .volume_id = &volume_bytes,
        .primary_placement_id = &placement_bytes,
        .primary_node_id = &primary_node,
        .lease_id = &lease_id,
        .holder_boot_id = identified_holder.holder_boot_id,
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 1,
        .activation_nonce = &activation_nonce,
        .authority_digest = &authority_digest,
    };
    var stage_request: pb.StagePrimaryRequest = .{
        .binding = authority_binding,
        .lease_duration_ms = lease.duration_ms,
    };
    var stage_result = try testCallUnary(&channel, methodPath("StagePrimary"), &stage_request);
    defer stage_result.deinit();
    try std.testing.expect(stage_result.status.isOk());
    var fence_request: pb.FenceReplicaRequest = .{ .binding = .{
        .operation_id = &operation_bytes,
        .volume_id = &volume_bytes,
        .placement_id = &placement_bytes,
        .replica_generation = 1,
        .write_epoch = 1,
        .primary_node_id = &primary_node,
        .lease_id = &lease_id,
        .authority_digest = &authority_digest,
    } };
    var fence_result = try testCallUnary(&channel, methodPath("FenceReplica"), &fence_request);
    defer fence_result.deinit();
    try std.testing.expect(fence_result.status.isOk());
    var fence_reader: std.Io.Reader = .fixed(fence_result.payload);
    var fenced = try pb.FenceReplicaResponse.decode(&fence_reader, std.testing.allocator);
    defer fenced.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 32), fenced.fence_digest.len);

    var recover_request: pb.RecoverPrimaryRequest = .{ .binding = authority_binding };
    var recover_result = try testCallUnary(&channel, methodPath("RecoverPrimary"), &recover_request);
    defer recover_result.deinit();
    try std.testing.expect(recover_result.status.isOk());
    var ready_request: pb.MarkPrimaryReadyRequest = .{ .binding = authority_binding };
    var ready_result = try testCallUnary(&channel, methodPath("MarkPrimaryReady"), &ready_request);
    defer ready_result.deinit();
    try std.testing.expect(ready_result.status.isOk());

    const payload: [4096]u8 = @splat(0xa7);
    var transaction_id = member;
    transaction_id[15] = 0x51;
    const participant_binding: replica_rpc_client.Binding = .{
        .participant = .{
            .replica = replica_binding,
            .replica_members = participant_members,
        },
        .backend_digest = ensured.replica.?.attestation.?.backend_digest[0..32].*,
    };
    const write_request: write_service.WriteRequest = .{
        .authority = try parseAuthorityBinding(authority_binding),
        .replica_members = participant_members,
        .sequence = 1,
        .transaction_id = transaction_id,
        .previous_history_digest = @splat(0),
        .offset_bytes = 0,
        .length_bytes = payload.len,
        .data_digest = write_service.digestData(&payload),
    };
    const drifted_before_prepare = try tmp.dir.openFile(std.testing.io, "member.img", .{ .mode = .read_write });
    try drifted_before_prepare.setLength(std.testing.io, 32 * 1024);
    drifted_before_prepare.close(std.testing.io);
    try std.testing.expectError(
        error.FailedPrecondition,
        replica_client.prepare(replica_endpoint, participant_binding, .{
            .write = write_request,
            .data = &payload,
        }),
    );
    const restored_before_prepare = try tmp.dir.openFile(std.testing.io, "member.img", .{ .mode = .read_write });
    try restored_before_prepare.setLength(std.testing.io, 64 * 1024);
    restored_before_prepare.close(std.testing.io);
    const local_attestation = try replica_client.prepare(replica_endpoint, participant_binding, .{
        .write = write_request,
        .data = &payload,
    });
    var remote_attestation = local_attestation;
    remote_attestation.member_id = participant_members[1];
    remote_attestation.prepare_digest = @splat(0x88);
    try std.testing.expectError(
        error.FailedPrecondition,
        replica_client.commit(
            replica_endpoint,
            participant_binding,
            write_request.authority,
            transaction_id,
            write_request.sequence + 1,
            .{ .attestations = .{ local_attestation, remote_attestation } },
        ),
    );
    const drifted_before_commit = try tmp.dir.openFile(std.testing.io, "member.img", .{ .mode = .read_write });
    try drifted_before_commit.setLength(std.testing.io, 32 * 1024);
    drifted_before_commit.close(std.testing.io);
    try std.testing.expectError(
        error.FailedPrecondition,
        replica_client.commit(
            replica_endpoint,
            participant_binding,
            write_request.authority,
            transaction_id,
            write_request.sequence,
            .{ .attestations = .{ local_attestation, remote_attestation } },
        ),
    );
    const restored_before_commit = try tmp.dir.openFile(std.testing.io, "member.img", .{ .mode = .read_write });
    try restored_before_commit.setLength(std.testing.io, 64 * 1024);
    restored_before_commit.close(std.testing.io);
    const committed = try replica_client.commit(
        replica_endpoint,
        participant_binding,
        write_request.authority,
        transaction_id,
        write_request.sequence,
        .{ .attestations = .{ local_attestation, remote_attestation } },
    );
    try std.testing.expectEqual(@as(u64, 1), committed.sequence);
    try std.testing.expectEqual(
        committed,
        try replica_client.commit(
            replica_endpoint,
            participant_binding,
            write_request.authority,
            transaction_id,
            write_request.sequence,
            .{ .attestations = .{ local_attestation, remote_attestation } },
        ),
    );
    const committed_inspection = try replica_client.inspect(
        replica_endpoint,
        participant_binding,
        write_request.authority,
    );
    try std.testing.expectEqual(@as(u64, 1), committed_inspection.frontier.sequence);
    try std.testing.expectEqual(committed, committed_inspection.last_completed.?);

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

fn testCallUnaryAuthenticated(
    channel: *grpc.Channel,
    path: []const u8,
    request: anytype,
    source_node_id: protocol.Id,
    target_node_id: protocol.Id,
    key: replica_rpc_auth.Key,
) !grpc.CallResult {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try request.encode(&writer.writer, std.testing.allocator);
    const challenge: replica_rpc_auth.Challenge = @splat(0x7e);
    const signed = replica_rpc_auth.signedMetadata(
        source_node_id,
        target_node_id,
        challenge,
        key,
        path,
        writer.written(),
    );
    const entries = signed.entries();
    const metadata_entries = [_]grpc.MetadataEntry{
        .{ .key = entries[0].key, .value = entries[0].value },
        .{ .key = entries[1].key, .value = entries[1].value },
        .{ .key = entries[2].key, .value = entries[2].value },
    };
    return channel.callUnary(std.testing.allocator, path, writer.written(), .{
        .metadata = &metadata_entries,
    });
}

test "data-node service recovers and marks a staged primary ready" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var authority_store = try AuthorityFileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "authority.state");
    defer authority_store.deinit();
    var service = try DataNodeServer.initWithOptions(std.testing.allocator, std.testing.io, "127.0.0.1", 0, .{
        .authority_store = &authority_store,
    });
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

    var recover_request: pb.RecoverPrimaryRequest = .{ .binding = authorityProto(&binding) };
    var recover_result = try testCallUnary(&channel, methodPath("RecoverPrimary"), &recover_request);
    defer recover_result.deinit();
    try std.testing.expect(recover_result.status.isOk());
    var recover_reader: std.Io.Reader = .fixed(recover_result.payload);
    var recovered = try pb.RecoverPrimaryResponse.decode(&recover_reader, std.testing.allocator);
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expect(recovered.empty_frontier);
    try std.testing.expectEqual(@as(u64, 0), recovered.certified_sequence);
    try std.testing.expectEqual(@as(usize, 32), recovered.history_digest.len);

    var ready_request: pb.MarkPrimaryReadyRequest = .{ .binding = authorityProto(&binding) };
    var ready_result = try testCallUnary(&channel, methodPath("MarkPrimaryReady"), &ready_request);
    defer ready_result.deinit();
    try std.testing.expect(ready_result.status.isOk());
    var ready_replay = try testCallUnary(&channel, methodPath("MarkPrimaryReady"), &ready_request);
    defer ready_replay.deinit();
    try std.testing.expect(ready_replay.status.isOk());

    var active_result = try testCallUnary(&channel, methodPath("InspectPrimary"), &inspect_request);
    defer active_result.deinit();
    try std.testing.expect(active_result.status.isOk());
    var active_reader: std.Io.Reader = .fixed(active_result.payload);
    var active = try pb.InspectPrimaryResponse.decode(&active_reader, std.testing.allocator);
    defer active.deinit(std.testing.allocator);
    try std.testing.expect(!active.candidate_fresh);
    try std.testing.expect(active.current_active);
    try std.testing.expect(active.current_admitting);
    try service.state.authorityValidator().validate(binding);
    var stale_binding = binding;
    stale_binding.write_epoch += 1;
    try std.testing.expectError(
        error.AuthorityNotStaged,
        service.state.authorityValidator().validate(stale_binding),
    );

    var unconfigured = try channel.callUnary(std.testing.allocator, methodPath("EnsureReplica"), "", .{});
    defer unconfigured.deinit();
    try std.testing.expectEqual(grpc.StatusCode.failed_precondition, unconfigured.status.code);
}

test {
    _ = file_member_backend;
}
