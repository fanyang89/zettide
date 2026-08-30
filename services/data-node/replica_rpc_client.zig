const std = @import("std");

const grpc = @import("grpc_lite");
const pb = @import("data_node_proto");
const protocol = @import("zettide_data_service_contracts");
const replica_rpc_auth = @import("replica_rpc_auth.zig");
const write_service = protocol.write_service;

pub const Binding = struct {
    participant: write_service.ParticipantBinding,
    backend_digest: protocol.Digest,
};

pub const RemoteInspection = struct {
    frontier: write_service.Frontier,
    pending: ?write_service.PendingInspection,
    last_completed: ?write_service.CommitResult,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    source_node_id: protocol.Id,
    target_node_id: protocol.Id,
    key: replica_rpc_auth.Key,
    options: Options,

    pub const Options = struct {
        timeout_ns: u64 = 5 * std.time.ns_per_s,
        max_response_size: usize = 1024 * 1024,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        source_node_id: protocol.Id,
        target_node_id: protocol.Id,
        key: replica_rpc_auth.Key,
        options: Options,
    ) !Client {
        if (isZero(&source_node_id) or isZero(&target_node_id) or isZero(&key) or
            std.mem.eql(u8, &source_node_id, &target_node_id) or
            options.timeout_ns == 0 or options.max_response_size == 0)
            return error.InvalidOptions;
        return .{
            .allocator = allocator,
            .io = io,
            .source_node_id = source_node_id,
            .target_node_id = target_node_id,
            .key = key,
            .options = options,
        };
    }

    pub fn deinit(self: *Client) void {
        std.crypto.secureZero(u8, &self.key);
        self.* = undefined;
    }

    pub fn prepare(
        self: *Client,
        endpoint: []const u8,
        binding: Binding,
        request: write_service.PrepareRequest,
    ) !write_service.PrepareAttestation {
        var binding_views: BindingProtoViews = undefined;
        var write_member_views: [3][]const u8 = undefined;
        var response = try self.unary(
            endpoint,
            "Prepare",
            pb.ReplicaPrepareRequest{
                .binding = bindingProto(&binding, &binding_views),
                .write = writeProto(&request.write, &write_member_views),
                .data = request.data,
            },
            pb.ReplicaPrepareResponse,
        );
        defer response.deinit(self.allocator);
        const attestation = try parseAttestation(response.attestation orelse return error.MissingResponseField);
        if (!std.mem.eql(u8, &attestation.member_id, &binding.participant.replica.member_id) or
            !std.mem.eql(u8, &attestation.transaction_digest, &write_service.digestTransaction(request.write)))
            return error.ResponseBindingMismatch;
        return attestation;
    }

    pub fn commit(
        self: *Client,
        endpoint: []const u8,
        binding: Binding,
        authority: protocol.AuthorityBinding,
        transaction_id: protocol.Id,
        expected_sequence: u64,
        certificate: write_service.CommitCertificate,
    ) !write_service.CommitResult {
        if (expected_sequence == 0) return error.InvalidArgument;
        var binding_views: BindingProtoViews = undefined;
        var stable_certificate = certificate;
        var attestations: [write_service.certificate_witness_count]pb.DataPrepareAttestation = undefined;
        for (&attestations, &stable_certificate.attestations) |*target, *value|
            target.* = attestationProto(value);
        var response = try self.unary(
            endpoint,
            "Commit",
            pb.ReplicaCommitRequest{
                .binding = bindingProto(&binding, &binding_views),
                .authority = authorityProto(&authority),
                .transaction_id = &transaction_id,
                .attestations = .{ .items = &attestations, .capacity = attestations.len },
                .sequence = expected_sequence,
            },
            pb.ReplicaCommitResponse,
        );
        defer response.deinit(self.allocator);
        const result = try parseCommitResult(response);
        if (!std.mem.eql(u8, &result.transaction_id, &transaction_id) or
            result.sequence != expected_sequence)
            return error.ResponseBindingMismatch;
        return result;
    }

    pub fn inspect(
        self: *Client,
        endpoint: []const u8,
        binding: Binding,
        authority: protocol.AuthorityBinding,
    ) !RemoteInspection {
        var binding_views: BindingProtoViews = undefined;
        var response = try self.unary(
            endpoint,
            "Inspect",
            pb.ReplicaWriteInspectRequest{
                .binding = bindingProto(&binding, &binding_views),
                .authority = authorityProto(&authority),
            },
            pb.ReplicaWriteInspectResponse,
        );
        defer response.deinit(self.allocator);
        const inspection: RemoteInspection = .{
            .frontier = .{
                .sequence = response.frontier_sequence,
                .history_digest = try fixedDigest(response.frontier_history_digest),
            },
            .pending = if (response.pending) |value| .{
                .write = try parseWrite(value.write),
                .attestation = try parseAttestation(value.attestation orelse return error.MissingResponseField),
                .commit_decided = value.commit_decided,
            } else null,
            .last_completed = if (response.last_completed) |value| try parseCommitResult(value) else null,
        };
        try validateInspection(binding.participant, inspection);
        return inspection;
    }

    fn unary(
        self: *Client,
        endpoint: []const u8,
        comptime method: []const u8,
        request: anytype,
        comptime Response: type,
    ) !Response {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try request.encode(&writer.writer, self.allocator);
        const path = replicaMethodPath(method);
        var challenge: replica_rpc_auth.Challenge = undefined;
        try self.io.randomSecure(&challenge);
        const signed = replica_rpc_auth.signedMetadata(
            self.source_node_id,
            self.target_node_id,
            challenge,
            self.key,
            path,
            writer.written(),
        );
        const entries = signed.entries();
        const metadata = [_]grpc.MetadataEntry{
            .{ .key = entries[0].key, .value = entries[0].value },
            .{ .key = entries[1].key, .value = entries[1].value },
            .{ .key = entries[2].key, .value = entries[2].value },
        };
        var channel = try grpc.Channel.init(self.allocator, endpoint, .{});
        defer channel.deinit();
        var result = try channel.callUnary(self.allocator, path, writer.written(), .{
            .metadata = &metadata,
            .timeout_ns = self.options.timeout_ns,
            .max_response_size = self.options.max_response_size,
        });
        defer result.deinit();
        replica_rpc_auth.verifyResponse(
            self.source_node_id,
            self.target_node_id,
            challenge,
            self.key,
            result.trailing_metadata.items(),
            path,
            writer.written(),
            @intFromEnum(result.status.code),
            result.status.message,
            result.payload,
        ) catch return error.ResponseAuthenticationFailed;
        try requireOk(result.status.code);
        var reader: std.Io.Reader = .fixed(result.payload);
        return Response.decode(&reader, self.allocator) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidProtobufResponse,
        };
    }
};

const BindingProtoViews = struct {
    members: [3][]const u8,
    identities: [3]pb.DataWitnessIdentity,
};

fn bindingProto(binding: *const Binding, views: *BindingProtoViews) pb.DataWriteParticipantBinding {
    for (&binding.participant.replica_members, &views.members) |*member_id, *view| view.* = member_id;
    for (&binding.participant.witness_identities, &views.identities) |*identity, *view| view.* = .{
        .member_id = &identity.member_id,
        .node_id = &identity.node_id,
        .key_id = &identity.key_id,
        .public_key = &identity.public_key,
    };
    const replica = &binding.participant.replica;
    return .{
        .volume_id = &replica.volume_id,
        .placement_id = &replica.placement_id,
        .allocation_id = &replica.allocation_id,
        .generation = replica.generation,
        .member_id = &replica.member_id,
        .offset_bytes = replica.offset_bytes,
        .length_bytes = replica.length_bytes,
        .backend_digest = &binding.backend_digest,
        .replica_member_ids = .{ .items = &views.members, .capacity = views.members.len },
        .witness_identities = .{ .items = &views.identities, .capacity = views.identities.len },
    };
}

fn writeProto(write: *const write_service.WriteRequest, member_views: *[3][]const u8) pb.DataWriteRequest {
    for (&write.replica_members, 0..) |*member_id, index| member_views[index] = member_id;
    return .{
        .authority = authorityProto(&write.authority),
        .replica_member_ids = .{ .items = member_views, .capacity = member_views.len },
        .sequence = write.sequence,
        .transaction_id = &write.transaction_id,
        .previous_history_digest = &write.previous_history_digest,
        .offset_bytes = write.offset_bytes,
        .length_bytes = write.length_bytes,
        .data_digest = &write.data_digest,
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

fn attestationProto(value: *const write_service.PrepareAttestation) pb.DataPrepareAttestation {
    return .{
        .member_id = &value.member_id,
        .transaction_digest = &value.transaction_digest,
        .prepare_digest = &value.prepare_digest,
        .prepared_history_digest = &value.prepared_history_digest,
    };
}

fn parseWrite(value: ?pb.DataWriteRequest) !write_service.WriteRequest {
    const write = value orelse return error.MissingResponseField;
    if (write.replica_member_ids.items.len != 3) return error.InvalidProtobufResponse;
    return .{
        .authority = try parseAuthority(write.authority),
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
        .data_digest = try nonzeroDigest(write.data_digest),
    };
}

fn parseAuthority(value: ?pb.DataAuthorityBinding) !protocol.AuthorityBinding {
    const authority = value orelse return error.MissingResponseField;
    return .{
        .volume_id = try fixedId(authority.volume_id),
        .primary_placement_id = try fixedId(authority.primary_placement_id),
        .primary_node_id = try fixedId(authority.primary_node_id),
        .lease_id = try fixedId(authority.lease_id),
        .holder_boot_id = try fixedId(authority.holder_boot_id),
        .authority_generation = authority.authority_generation,
        .write_epoch = authority.write_epoch,
        .placement_revision = authority.placement_revision,
        .activation_nonce = try fixedId(authority.activation_nonce),
        .authority_digest = try nonzeroDigest(authority.authority_digest),
    };
}

fn parseAttestation(value: pb.DataPrepareAttestation) !write_service.PrepareAttestation {
    return .{
        .member_id = try fixedId(value.member_id),
        .transaction_digest = try nonzeroDigest(value.transaction_digest),
        .prepare_digest = try nonzeroDigest(value.prepare_digest),
        .prepared_history_digest = try nonzeroDigest(value.prepared_history_digest),
    };
}

fn parseCommitResult(value: pb.ReplicaCommitResponse) !write_service.CommitResult {
    return .{
        .transaction_id = try fixedId(value.transaction_id),
        .sequence = value.sequence,
        .history_digest = try nonzeroDigest(value.history_digest),
    };
}

fn validateInspection(
    binding: write_service.ParticipantBinding,
    inspection: RemoteInspection,
) !void {
    if ((inspection.frontier.sequence == 0) != isZero(&inspection.frontier.history_digest))
        return error.InvalidProtobufResponse;
    if (inspection.pending) |pending| {
        const expected_sequence = std.math.add(u64, inspection.frontier.sequence, 1) catch
            return error.InvalidProtobufResponse;
        const end = std.math.add(u64, pending.write.offset_bytes, pending.write.length_bytes) catch
            return error.InvalidProtobufResponse;
        if (pending.write.sequence != expected_sequence or
            !std.meta.eql(pending.write.replica_members, binding.replica_members) or
            !std.mem.eql(u8, &pending.write.previous_history_digest, &inspection.frontier.history_digest) or
            !std.mem.eql(u8, &pending.write.authority.volume_id, &binding.replica.volume_id) or
            end > binding.replica.length_bytes)
            return error.ResponseBindingMismatch;
    }
    if (inspection.last_completed) |completed| {
        if (completed.sequence != inspection.frontier.sequence or
            !std.mem.eql(u8, &completed.history_digest, &inspection.frontier.history_digest))
            return error.ResponseBindingMismatch;
    } else if (inspection.frontier.sequence != 0) return error.InvalidProtobufResponse;
}

fn fixedId(bytes: []const u8) !protocol.Id {
    if (bytes.len != @sizeOf(protocol.Id)) return error.InvalidProtobufResponse;
    return bytes[0..@sizeOf(protocol.Id)].*;
}

fn fixedDigest(bytes: []const u8) !protocol.Digest {
    if (bytes.len != @sizeOf(protocol.Digest)) return error.InvalidProtobufResponse;
    return bytes[0..@sizeOf(protocol.Digest)].*;
}

fn nonzeroDigest(bytes: []const u8) !protocol.Digest {
    const value = try fixedDigest(bytes);
    if (isZero(&value)) return error.InvalidProtobufResponse;
    return value;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

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

fn replicaMethodPath(comptime method: []const u8) []const u8 {
    return "/zettide.controller.v1.ReplicaTransport/" ++ method;
}

test "client rejects invalid peer identities and call limits" {
    var source: protocol.Id = @splat(0);
    source[0] = 1;
    var target: protocol.Id = @splat(0);
    target[0] = 2;
    try std.testing.expectError(
        error.InvalidOptions,
        Client.init(std.testing.allocator, std.testing.io, @splat(0), target, @splat(1), .{}),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        Client.init(std.testing.allocator, std.testing.io, source, source, @splat(1), .{}),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        Client.init(std.testing.allocator, std.testing.io, source, target, @splat(0), .{}),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        Client.init(std.testing.allocator, std.testing.io, source, target, @splat(1), .{ .timeout_ns = 0 }),
    );
}
