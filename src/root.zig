const std = @import("std");

pub const pb = @import("control_proto");
pub const grpc = @import("grpc_lite");
pub const raft = @import("raft_zig");
pub const uuid = @import("uuid");

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

test "uuid dependency generates version seven identifiers" {
    const id = uuid.v7.new(std.testing.io);
    const encoded = uuid.urn.serialize(id);
    try std.testing.expectEqual(id, try uuid.urn.deserialize(&encoded));
    try std.testing.expectEqual(@as(u8, '7'), encoded[14]);
}

test {
    _ = grpc;
    _ = raft;
}
