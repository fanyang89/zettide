const std = @import("std");

pub const pb = @import("control_proto");
pub const grpc = @import("grpc_lite");
pub const raft = @import("raftz");
pub const uuid = @import("uuid");
pub const config = @import("config.zig");
pub const runtime = @import("runtime.zig");
pub const Runtime = runtime.Runtime;
pub const protobuf_wire = @import("protobuf_wire.zig");
pub const heartbeat = @import("heartbeat.zig");
pub const HeartbeatStore = heartbeat.HeartbeatStore;
pub const state_machine = @import("state_machine.zig");
pub const PoolStateMachine = state_machine.PoolStateMachine;
pub const service = @import("service.zig");
pub const PoolService = service.PoolService;
pub const PoolRpc = service.PoolRpc;

test "protobuf model round trips" {
    var pool: pb.Pool = .{
        .id = "0198f54d-5c2a-7000-8000-000000000001",
        .name = "primary",
        .description = "Primary storage pool",
        .created_at_unix_ms = 1_753_744_000_000,
        .created_revision = 7,
    };
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try pool.encode(&writer.writer, std.testing.allocator);

    var reader: std.Io.Reader = .fixed(writer.written());
    var decoded = try pb.Pool.decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(pool.id, decoded.id);
    try std.testing.expectEqualStrings(pool.name, decoded.name);
    try std.testing.expectEqual(pool.created_revision, decoded.created_revision);
}

test "Volume model round trips" {
    var volume: pb.Volume = .{
        .id = "0198f54d-5c2a-7000-8000-000000000011",
        .pool_id = "0198f54d-5c2a-7000-8000-000000000001",
        .name = "database",
        .description = "Database volume",
        .size_bytes = 1024 * 1024,
        .protection_kind = .VOLUME_PROTECTION_KIND_REPLICATED,
        .target_replica_count = 3,
        .write_quorum = 2,
        .read_quorum = 1,
        .lifecycle_state = .VOLUME_LIFECYCLE_STATE_PROVISIONING,
        .availability_state = .VOLUME_AVAILABILITY_STATE_UNKNOWN,
        .operation_phase = .VOLUME_OPERATION_PHASE_NONE,
        .generation = 1,
        .write_epoch = 1,
        .created_at_unix_ms = 1_753_744_000_000,
        .created_revision = 8,
        .resource_version = 8,
    };
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try volume.encode(&writer.writer, std.testing.allocator);

    var reader: std.Io.Reader = .fixed(writer.written());
    var decoded = try pb.Volume.decode(&reader, std.testing.allocator);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(volume.id, decoded.id);
    try std.testing.expectEqualStrings(volume.pool_id, decoded.pool_id);
    try std.testing.expectEqual(volume.size_bytes, decoded.size_bytes);
    try std.testing.expectEqual(volume.lifecycle_state, decoded.lifecycle_state);
    try std.testing.expectEqual(volume.resource_version, decoded.resource_version);
}

test "uuid dependency generates version seven identifiers" {
    const id = uuid.v7.new(std.testing.io);
    const encoded = uuid.urn.serialize(id);
    try std.testing.expectEqual(id, try uuid.urn.deserialize(&encoded));
    try std.testing.expectEqual(@as(u8, '7'), encoded[14]);
}

test {
    _ = grpc;
    _ = raft;
    _ = config;
    _ = runtime;
    _ = protobuf_wire;
    _ = heartbeat;
    _ = state_machine;
    _ = service;
    _ = @import("integration_test.zig");
    _ = @import("runtime_integration_test.zig");
}
