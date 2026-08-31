const std = @import("std");

const data_service = @import("zettide_data_service_contracts").replica_service;
const pb = @import("data_node_proto");
const reconciler = @import("reconciler.zig");
const replica_fence = @import("replica_fence.zig");

pub fn ensureReplicaRequest(request: data_service.Request) pb.EnsureReplicaRequest {
    return dataRequest(pb.EnsureReplicaRequest, request);
}

pub fn inspectReplicaRequest(request: data_service.Request) pb.InspectReplicaRequest {
    return dataRequest(pb.InspectReplicaRequest, request);
}

pub fn deleteReplicaRequest(request: data_service.Request) pb.DeleteReplicaRequest {
    return dataRequest(pb.DeleteReplicaRequest, request);
}

fn dataRequest(comptime T: type, request: data_service.Request) T {
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

pub fn dataResponse(response: anytype) !data_service.Response {
    const operation_id = try parseUuidText(response.operation_id);
    const replica = response.replica orelse return error.MissingReplica;
    const attestation = replica.attestation orelse return error.MissingAttestation;
    const state: data_service.ReplicaState = switch (replica.state) {
        .DATA_REPLICA_STATE_ACTIVE => .active,
        .DATA_REPLICA_STATE_TOMBSTONED => .tombstoned,
        else => return error.InvalidReplicaState,
    };
    if (attestation.generation == 0 or attestation.length_bytes == 0) return error.InvalidReplicaBinding;
    _ = std.math.add(u64, attestation.offset_bytes, attestation.length_bytes) catch
        return error.InvalidReplicaBinding;
    return .{
        .operation_id = operation_id,
        .replica = .{
            .state = state,
            .attestation = .{
                .binding = .{
                    .volume_id = try parseUuidText(attestation.volume_id),
                    .placement_id = try parseUuidText(attestation.placement_id),
                    .allocation_id = try parseUuidText(attestation.allocation_id),
                    .generation = attestation.generation,
                    .member_id = try fixedBytes(16, attestation.member_id),
                    .offset_bytes = attestation.offset_bytes,
                    .length_bytes = attestation.length_bytes,
                },
                .backend_digest = try nonzeroBytes(32, attestation.backend_digest),
            },
        },
    };
}

pub fn configureWriteParticipantRequest(
    configuration: *const reconciler.WriteParticipantConfiguration,
    member_views: *[3][]const u8,
    identity_views: *[3]pb.DataWitnessIdentity,
) pb.ConfigureWriteParticipantRequest {
    const replica = &configuration.binding.replica;
    for (&configuration.binding.replica_members, member_views) |*member, *view| view.* = member;
    for (&configuration.binding.witness_identities, identity_views) |*identity, *view| view.* = .{
        .member_id = &identity.member_id,
        .node_id = &identity.node_id,
        .key_id = &identity.key_id,
        .public_key = &identity.public_key,
    };
    return .{ .binding = .{
        .volume_id = &replica.volume_id,
        .placement_id = &replica.placement_id,
        .allocation_id = &replica.allocation_id,
        .generation = replica.generation,
        .member_id = &replica.member_id,
        .offset_bytes = replica.offset_bytes,
        .length_bytes = replica.length_bytes,
        .backend_digest = &configuration.backend_digest,
        .replica_member_ids = .{ .items = member_views, .capacity = member_views.len },
        .witness_identities = .{ .items = identity_views, .capacity = identity_views.len },
    } };
}

pub const CoordinatorWireViews = struct {
    member_views: [3][3][]const u8 = undefined,
    identity_views: [3][3]pb.DataWitnessIdentity = undefined,
    binding_views: [3]pb.DataWriteParticipantBinding = undefined,
    route_views: [3]pb.DataWriteCoordinatorRoute = undefined,
};

pub fn configureWriteCoordinatorRequest(
    configuration: *const reconciler.WriteCoordinatorConfiguration,
    views: *CoordinatorWireViews,
) pb.ConfigureWriteCoordinatorRequest {
    for (&configuration.routes, 0..) |*route, index| {
        const participant = configureWriteParticipantRequest(
            &route.configuration,
            &views.member_views[index],
            &views.identity_views[index],
        );
        views.binding_views[index] = participant.binding.?;
        views.route_views[index] = .{
            .binding = views.binding_views[index],
            .node_id = &route.node_id,
            .replica_endpoint = route.replica_endpoint,
        };
    }
    return .{ .topology = .{
        .local_member_id = &configuration.local_member_id,
        .routes = .{ .items = &views.route_views, .capacity = views.route_views.len },
    } };
}

pub fn parseWriteCoordinatorResponse(response: pb.ConfigureWriteCoordinatorResponse) !reconciler.WriteCoordinatorConfiguration {
    const topology = response.topology orelse return error.MissingCoordinatorTopology;
    if (topology.routes.items.len != 3) return error.InvalidCoordinatorTopology;
    var routes: [3]reconciler.WriteCoordinatorRoute = undefined;
    for (topology.routes.items, &routes) |route, *result| {
        if (route.binding == null or route.replica_endpoint.len == 0 or route.replica_endpoint.len > 255)
            return error.InvalidCoordinatorTopology;
        result.* = .{
            .configuration = try parseWriteParticipantResponse(.{ .binding = route.binding }),
            .node_id = try nonzeroBytes(16, route.node_id),
            .replica_endpoint = route.replica_endpoint,
        };
    }
    return .{
        .local_member_id = try nonzeroBytes(16, topology.local_member_id),
        .routes = routes,
    };
}

pub fn parseWriteParticipantResponse(response: pb.ConfigureWriteParticipantResponse) !reconciler.WriteParticipantConfiguration {
    const binding = response.binding orelse return error.MissingParticipantBinding;
    if (binding.generation == 0 or binding.length_bytes == 0 or
        binding.replica_member_ids.items.len != 3 or binding.witness_identities.items.len != 3)
        return error.InvalidParticipantBinding;
    _ = std.math.add(u64, binding.offset_bytes, binding.length_bytes) catch
        return error.InvalidParticipantBinding;
    const members: [3]reconciler.Id = .{
        try nonzeroBytes(16, binding.replica_member_ids.items[0]),
        try nonzeroBytes(16, binding.replica_member_ids.items[1]),
        try nonzeroBytes(16, binding.replica_member_ids.items[2]),
    };
    var identities: [3]@import("zettide_data_service_contracts").write_service.WitnessIdentity = undefined;
    for (binding.witness_identities.items, &identities) |source, *identity| identity.* = .{
        .member_id = try nonzeroBytes(16, source.member_id),
        .node_id = try nonzeroBytes(16, source.node_id),
        .key_id = try nonzeroBytes(32, source.key_id),
        .public_key = try nonzeroBytes(32, source.public_key),
    };
    const local_member = try nonzeroBytes(16, binding.member_id);
    const participant_binding: @import("zettide_data_service_contracts").write_service.ParticipantBinding = .{
        .replica = .{
            .volume_id = try uuidBytes(binding.volume_id),
            .placement_id = try uuidBytes(binding.placement_id),
            .allocation_id = try uuidBytes(binding.allocation_id),
            .generation = binding.generation,
            .member_id = local_member,
            .offset_bytes = binding.offset_bytes,
            .length_bytes = binding.length_bytes,
        },
        .replica_members = members,
        .witness_identities = identities,
    };
    @import("zettide_data_service_contracts").write_service.validateParticipantBinding(participant_binding) catch
        return error.InvalidParticipantBinding;
    return .{
        .binding = participant_binding,
        .backend_digest = try nonzeroBytes(32, binding.backend_digest),
    };
}

pub fn authorityBinding(binding: *const reconciler.AuthorityBinding) pb.DataAuthorityBinding {
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

pub fn parseAuthorityBinding(binding: ?pb.DataAuthorityBinding) !reconciler.AuthorityBinding {
    const value = binding orelse return error.MissingAuthorityBinding;
    if (value.authority_generation == 0 or value.write_epoch == 0 or value.placement_revision == 0)
        return error.InvalidAuthorityBinding;
    return .{
        .volume_id = try uuidBytes(value.volume_id),
        .primary_placement_id = try uuidBytes(value.primary_placement_id),
        .primary_node_id = try uuidBytes(value.primary_node_id),
        .lease_id = try uuidBytes(value.lease_id),
        .holder_boot_id = try uuidBytes(value.holder_boot_id),
        .authority_generation = value.authority_generation,
        .write_epoch = value.write_epoch,
        .placement_revision = value.placement_revision,
        .activation_nonce = try uuidBytes(value.activation_nonce),
        .authority_digest = try nonzeroBytes(32, value.authority_digest),
    };
}

pub fn stageRequest(request: *const reconciler.StageRequest) pb.StagePrimaryRequest {
    return .{ .binding = authorityBinding(&request.binding), .lease_duration_ms = request.lease_duration_ms };
}

pub fn parseStageResponse(response: pb.StagePrimaryResponse) !reconciler.StageAck {
    if (response.lease_duration_ms == 0) return error.InvalidLeaseDuration;
    return .{ .request = .{
        .binding = try parseAuthorityBinding(response.binding),
        .lease_duration_ms = response.lease_duration_ms,
    } };
}

pub fn fenceRequest(binding: *const replica_fence.Binding) pb.FenceReplicaRequest {
    return .{ .binding = .{
        .operation_id = &binding.operation_id,
        .volume_id = &binding.volume_id,
        .placement_id = &binding.placement_id,
        .replica_generation = binding.replica_generation,
        .write_epoch = binding.write_epoch,
        .primary_node_id = &binding.primary_node_id,
        .lease_id = &binding.lease_id,
        .authority_digest = &binding.authority_digest,
    } };
}

pub fn parseFenceResponse(response: pb.FenceReplicaResponse) !replica_fence.Result {
    const binding = response.binding orelse return error.MissingFenceBinding;
    if (binding.replica_generation == 0 or binding.write_epoch == 0) return error.InvalidFenceBinding;
    return .{
        .binding = .{
            .operation_id = try uuidBytes(binding.operation_id),
            .volume_id = try uuidBytes(binding.volume_id),
            .placement_id = try uuidBytes(binding.placement_id),
            .replica_generation = binding.replica_generation,
            .write_epoch = binding.write_epoch,
            .primary_node_id = try uuidBytes(binding.primary_node_id),
            .lease_id = try uuidBytes(binding.lease_id),
            .authority_digest = try nonzeroBytes(32, binding.authority_digest),
        },
        .fence_digest = try nonzeroBytes(32, response.fence_digest),
    };
}

pub fn recoveryRequest(request: *const reconciler.RecoveryRequest) pb.RecoverPrimaryRequest {
    return .{ .binding = authorityBinding(&request.binding) };
}

pub fn parseRecoveryResponse(response: pb.RecoverPrimaryResponse) !reconciler.RecoveryResult {
    if ((response.certified_sequence == 0) != response.empty_frontier) return error.InvalidRecoveryEvidence;
    return .{
        .request = .{ .binding = try parseAuthorityBinding(response.binding) },
        .certified_sequence = response.certified_sequence,
        .history_digest = try nonzeroBytes(32, response.history_digest),
        .empty_frontier = response.empty_frontier,
    };
}

pub fn markReadyRequest(request: *const reconciler.MarkReadyRequest) pb.MarkPrimaryReadyRequest {
    return .{ .binding = authorityBinding(&request.binding) };
}

pub fn parseMarkReadyResponse(response: pb.MarkPrimaryReadyResponse) !reconciler.MarkReadyRequest {
    return .{ .binding = try parseAuthorityBinding(response.binding) };
}

pub fn inspectPrimaryRequest(request: *const reconciler.MarkReadyRequest) pb.InspectPrimaryRequest {
    return .{ .binding = authorityBinding(&request.binding) };
}

pub fn parseInspectPrimaryResponse(response: pb.InspectPrimaryResponse) !reconciler.PrimaryLeaseStatus {
    if (response.current_admitting and !response.current_active) return error.InvalidLeaseStatus;
    return .{
        .request = .{ .binding = try parseAuthorityBinding(response.binding) },
        .current_active = response.current_active,
        .current_admitting = response.current_admitting,
        .candidate_fresh = response.candidate_fresh,
        .should_renew = response.should_renew,
    };
}

pub fn parseHolder(response: pb.IdentifyHolderResponse) !reconciler.Id {
    return uuidBytes(response.holder_boot_id);
}

pub fn methodPath(comptime method: []const u8) []const u8 {
    return "/zettide.controller.v1.DataService/" ++ method;
}

fn parseUuidText(text: []const u8) ![16]u8 {
    const uuid = @import("uuid");
    const parsed = uuid.urn.deserialize(text) catch return error.InvalidUuid;
    const canonical = uuid.urn.serialize(parsed);
    if (canonical[14] != '7' or !std.mem.eql(u8, text, &canonical)) return error.InvalidUuid;
    var id: [16]u8 = undefined;
    std.mem.writeInt(u128, &id, parsed, .little);
    if (!validUuidV7(id)) return error.InvalidUuid;
    return id;
}

fn uuidBytes(bytes: []const u8) ![16]u8 {
    const id = try fixedBytes(16, bytes);
    if (!validUuidV7(id)) return error.InvalidUuid;
    return id;
}

fn fixedBytes(comptime len: usize, bytes: []const u8) ![len]u8 {
    if (bytes.len != len) return error.InvalidFixedBytes;
    return bytes[0..len].*;
}

fn nonzeroBytes(comptime len: usize, bytes: []const u8) ![len]u8 {
    const value = try fixedBytes(len, bytes);
    for (value) |byte| if (byte != 0) return value;
    return error.ZeroFixedBytes;
}

fn validUuidV7(id: [16]u8) bool {
    return id[6] & 0xf0 == 0x70 and id[8] & 0xc0 == 0x80;
}

const id_a: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 1 };
const id_b: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 2 };
const id_c: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 3 };
const id_d: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 4 };
const id_e: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 5 };
const id_f: [16]u8 = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 6 };
const digest: [32]u8 = @splat(0x44);

test "Replica UUID text parses to canonical wire bytes" {
    try std.testing.expectEqual(id_a, try parseUuidText("0198f54d-5c2a-7000-8000-000000000001"));
    try std.testing.expectError(error.InvalidUuid, parseUuidText("0198F54D-5C2A-7000-8000-000000000001"));
    try std.testing.expectError(error.InvalidUuid, parseUuidText("0198f54d-5c2a-7000-0000-000000000001"));
}

fn testIdentity(member_id: [16]u8, node_id: [16]u8, seed: u8) @import("zettide_data_service_contracts").write_service.WitnessIdentity {
    var key_pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(seed)) catch unreachable;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&key_pair));
    const public_key = key_pair.public_key.toBytes();
    return .{
        .member_id = member_id,
        .node_id = node_id,
        .key_id = @import("zettide_data_service_contracts").write_evidence_contract.keyId(public_key),
        .public_key = public_key,
    };
}

fn testAuthority() reconciler.AuthorityBinding {
    return .{
        .volume_id = id_a,
        .primary_placement_id = id_b,
        .primary_node_id = id_c,
        .lease_id = id_d,
        .holder_boot_id = id_e,
        .authority_generation = 7,
        .write_epoch = 9,
        .placement_revision = 11,
        .activation_nonce = id_f,
        .authority_digest = digest,
    };
}

test "write participant wire model preserves immutable canonical binding" {
    const configuration: reconciler.WriteParticipantConfiguration = .{
        .binding = .{
            .replica = .{
                .volume_id = id_a,
                .placement_id = id_b,
                .allocation_id = id_c,
                .generation = 3,
                .member_id = id_d,
                .offset_bytes = 4096,
                .length_bytes = 8192,
            },
            .replica_members = .{ id_d, id_e, id_f },
            .witness_identities = .{
                testIdentity(id_d, id_a, 1),
                testIdentity(id_e, id_b, 2),
                testIdentity(id_f, id_c, 3),
            },
        },
        .backend_digest = digest,
    };
    var member_views: [3][]const u8 = undefined;
    var identity_views: [3]pb.DataWitnessIdentity = undefined;
    const request = configureWriteParticipantRequest(&configuration, &member_views, &identity_views);
    try std.testing.expectEqual(@intFromPtr(&configuration.binding.replica.volume_id), @intFromPtr(request.binding.?.volume_id.ptr));
    try std.testing.expectEqual(@intFromPtr(&configuration.binding.replica.placement_id), @intFromPtr(request.binding.?.placement_id.ptr));
    try std.testing.expectEqual(@intFromPtr(&configuration.binding.replica.allocation_id), @intFromPtr(request.binding.?.allocation_id.ptr));
    try std.testing.expectEqual(@intFromPtr(&configuration.binding.replica.member_id), @intFromPtr(request.binding.?.member_id.ptr));
    try std.testing.expectEqual(@intFromPtr(&configuration.backend_digest), @intFromPtr(request.binding.?.backend_digest.ptr));
    for (&configuration.binding.witness_identities, request.binding.?.witness_identities.items) |*identity, view| {
        try std.testing.expectEqual(@intFromPtr(&identity.member_id), @intFromPtr(view.member_id.ptr));
        try std.testing.expectEqual(@intFromPtr(&identity.node_id), @intFromPtr(view.node_id.ptr));
        try std.testing.expectEqual(@intFromPtr(&identity.key_id), @intFromPtr(view.key_id.ptr));
        try std.testing.expectEqual(@intFromPtr(&identity.public_key), @intFromPtr(view.public_key.ptr));
    }
    const parsed = try parseWriteParticipantResponse(.{ .binding = request.binding });
    try std.testing.expectEqual(configuration, parsed);

    var malformed = request.binding.?;
    malformed.replica_member_ids.items[1] = malformed.replica_member_ids.items[0];
    try std.testing.expectError(error.InvalidParticipantBinding, parseWriteParticipantResponse(.{ .binding = malformed }));
}

test "coordinator route wire preserves borrowed canonical topology" {
    const identities: [3]@import("zettide_data_service_contracts").write_service.WitnessIdentity = .{
        testIdentity(id_d, id_a, 1), testIdentity(id_e, id_b, 2), testIdentity(id_f, id_c, 3),
    };
    var routes: [3]reconciler.WriteCoordinatorRoute = undefined;
    const endpoints = [_][]const u8{ "node-a:7443", "node-b:7443", "node-c:7443" };
    const members = [_][16]u8{ id_d, id_e, id_f };
    const nodes = [_][16]u8{ id_a, id_b, id_c };
    for (&routes, 0..) |*route, index| route.* = .{
        .configuration = .{
            .binding = .{
                .replica = .{
                    .volume_id = id_a,
                    .placement_id = nodes[index],
                    .allocation_id = members[index],
                    .generation = 3,
                    .member_id = members[index],
                    .offset_bytes = @as(u64, index) * 8192,
                    .length_bytes = 8192,
                },
                .replica_members = members,
                .witness_identities = identities,
            },
            .backend_digest = digest,
        },
        .node_id = nodes[index],
        .replica_endpoint = endpoints[index],
    };
    const configuration: reconciler.WriteCoordinatorConfiguration = .{ .local_member_id = id_d, .routes = routes };
    var views: CoordinatorWireViews = .{};
    const request = configureWriteCoordinatorRequest(&configuration, &views);
    try std.testing.expectEqual(@intFromPtr(&configuration.local_member_id), @intFromPtr(request.topology.?.local_member_id.ptr));
    for (&configuration.routes, request.topology.?.routes.items) |*expected, actual| {
        try std.testing.expectEqual(@intFromPtr(&expected.node_id), @intFromPtr(actual.node_id.ptr));
        try std.testing.expectEqual(@intFromPtr(expected.replica_endpoint.ptr), @intFromPtr(actual.replica_endpoint.ptr));
    }
    const parsed = try parseWriteCoordinatorResponse(.{ .topology = request.topology });
    try std.testing.expectEqual(configuration.local_member_id, parsed.local_member_id);
    for (configuration.routes, parsed.routes) |expected, actual| {
        try std.testing.expectEqual(expected.configuration, actual.configuration);
        try std.testing.expectEqual(expected.node_id, actual.node_id);
        try std.testing.expectEqualStrings(expected.replica_endpoint, actual.replica_endpoint);
    }
}

test "authority lifecycle wire models preserve complete bindings" {
    const authority = testAuthority();
    try std.testing.expectEqual(authority, try parseAuthorityBinding(authorityBinding(&authority)));

    const stage = try parseStageResponse(.{ .binding = authorityBinding(&authority), .lease_duration_ms = 30_000 });
    try std.testing.expectEqual(authority, stage.request.binding);
    try std.testing.expectEqual(@as(u32, 30_000), stage.request.lease_duration_ms);

    const recovery = try parseRecoveryResponse(.{
        .binding = authorityBinding(&authority),
        .history_digest = &digest,
        .empty_frontier = true,
    });
    try std.testing.expectEqual(authority, recovery.request.binding);
    try std.testing.expect(recovery.empty_frontier);

    const status = try parseInspectPrimaryResponse(.{
        .binding = authorityBinding(&authority),
        .current_active = true,
        .current_admitting = true,
        .should_renew = true,
    });
    try std.testing.expect(status.current_active);
    try std.testing.expect(status.current_admitting);
    try std.testing.expect(status.should_renew);
}

test "fence wire model rejects malformed fixed-width evidence" {
    const binding: replica_fence.Binding = .{
        .operation_id = id_a,
        .volume_id = id_b,
        .placement_id = id_c,
        .replica_generation = 3,
        .write_epoch = 9,
        .primary_node_id = id_d,
        .lease_id = id_e,
        .authority_digest = digest,
    };
    const request = fenceRequest(&binding);
    const parsed = try parseFenceResponse(.{ .binding = request.binding, .fence_digest = &digest });
    try std.testing.expectEqual(binding, parsed.binding);
    try std.testing.expectEqual(digest, parsed.fence_digest);

    var malformed = request.binding.?;
    malformed.lease_id = malformed.lease_id[0..15];
    try std.testing.expectError(error.InvalidFixedBytes, parseFenceResponse(.{
        .binding = malformed,
        .fence_digest = &digest,
    }));
}

test "DataService authority method paths are stable" {
    try std.testing.expectEqualStrings("/zettide.controller.v1.DataService/ConfigureWriteParticipant", methodPath("ConfigureWriteParticipant"));
    try std.testing.expectEqualStrings("/zettide.controller.v1.DataService/ConfigureWriteCoordinator", methodPath("ConfigureWriteCoordinator"));
    try std.testing.expectEqualStrings("/zettide.controller.v1.DataService/IdentifyHolder", methodPath("IdentifyHolder"));
    try std.testing.expectEqualStrings("/zettide.controller.v1.DataService/StagePrimary", methodPath("StagePrimary"));
    try std.testing.expectEqualStrings("/zettide.controller.v1.DataService/FenceReplica", methodPath("FenceReplica"));
    try std.testing.expectEqualStrings("/zettide.controller.v1.DataService/RecoverPrimary", methodPath("RecoverPrimary"));
    try std.testing.expectEqualStrings("/zettide.controller.v1.DataService/MarkPrimaryReady", methodPath("MarkPrimaryReady"));
    try std.testing.expectEqualStrings("/zettide.controller.v1.DataService/InspectPrimary", methodPath("InspectPrimary"));
}
