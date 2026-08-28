const std = @import("std");
const pb = @import("controller_proto");
const raft = @import("raftz");

pub fn decodeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.ApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.ApplyResponse.decode(&reader, allocator);
}

pub fn decodeRegisterNodeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.RegisterNodeApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.RegisterNodeApplyResponse.decode(&reader, allocator);
}

pub fn decodeRegisterMemberApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.RegisterMemberApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.RegisterMemberApplyResponse.decode(&reader, allocator);
}

pub fn decodeCreateVolumeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.CreateVolumeApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.CreateVolumeApplyResponse.decode(&reader, allocator);
}

pub fn decodeDeleteVolumeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.DeleteVolumeApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.DeleteVolumeApplyResponse.decode(&reader, allocator);
}

pub fn decodeUpdateVolumeApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.UpdateVolumeApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.UpdateVolumeApplyResponse.decode(&reader, allocator);
}

pub fn decodeReserveVolumeResourcesApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.ReserveVolumeResourcesApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.ReserveVolumeResourcesApplyResponse.decode(&reader, allocator);
}

pub fn decodeActivateReplicaApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.ActivateReplicaApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.ActivateReplicaApplyResponse.decode(&reader, allocator);
}

pub fn decodeFinalizeVolumeDeletionApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.FinalizeVolumeDeletionApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.FinalizeVolumeDeletionApplyResponse.decode(&reader, allocator);
}

pub fn decodePrimaryAuthorityApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.PrimaryAuthorityApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.PrimaryAuthorityApplyResponse.decode(&reader, allocator);
}

pub fn decodePrimaryFailoverApplyResponse(allocator: std.mem.Allocator, bytes: []const u8) !pb.PrimaryFailoverApplyResponse {
    var reader: std.Io.Reader = .fixed(bytes);
    return pb.PrimaryFailoverApplyResponse.decode(&reader, allocator);
}

pub fn deinitPoolList(allocator: std.mem.Allocator, pools: []pb.Pool) void {
    for (pools) |*pool| pool.deinit(allocator);
    allocator.free(pools);
}

pub fn deinitNodeList(allocator: std.mem.Allocator, nodes: []pb.Node) void {
    for (nodes) |*node| node.deinit(allocator);
    allocator.free(nodes);
}

pub fn deinitMemberList(allocator: std.mem.Allocator, members: []pb.Member) void {
    for (members) |*member| member.deinit(allocator);
    allocator.free(members);
}

pub fn deinitVolumeList(allocator: std.mem.Allocator, volumes: []pb.Volume) void {
    for (volumes) |*volume| volume.deinit(allocator);
    allocator.free(volumes);
}

pub fn deinitReplicaReservations(allocator: std.mem.Allocator, reservations: []pb.ReplicaReservation) void {
    for (reservations) |*reservation| reservation.deinit(allocator);
    allocator.free(reservations);
}

pub fn encodeMessage(allocator: std.mem.Allocator, message: anytype) raft.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    message.encode(&output.writer, allocator) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

pub fn mapDecodeError(err: anyerror) raft.Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.PayloadParseFailed;
}
