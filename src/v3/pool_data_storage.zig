const std = @import("std");
const blob_format_api = @import("../blob_format.zig");
const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const pool_authority = @import("pool_authority.zig");
const pool_block_device = @import("pool_block_device.zig");
const pool_member_set = @import("pool_member_set.zig");
const pool_policy = @import("pool_policy.zig");
const pool_topology = @import("pool_topology.zig");
const ReplicaEndpoint = @import("replica_endpoint.zig").ReplicaEndpoint;
const storage_api = @import("storage.zig");

const Io = std.Io;
const max_replica_count = 3;
const io_alignment = 4096;

const Context = struct {
    allocator: std.mem.Allocator,
    set: pool_member_set.PoolMemberSet,
    device: pool_block_device.PoolBlockDevice,
    endpoint_contexts: [max_replica_count]ClaimedReplicaContext,
    data_claims: [max_replica_count]member_api.DataClaim,
    data_claim_count: usize,
    identity: [16]u8,
    writable: bool,
    coordinator_claimed: bool,
    mutex: Io.Mutex = .init,
};

const ClaimedReplicaContext = struct {
    member: *member_api.Member,
    data_claim: ?*member_api.DataClaim,
};

/// Takes set_source only on success. On failure, the caller still owns it.
pub fn create(
    allocator: std.mem.Allocator,
    io: Io,
    set_source: *pool_member_set.PoolMemberSet,
    writable: bool,
) !storage_api.Storage {
    const validated = try validateSet(set_source, writable);
    try rejectActiveCoordinator(set_source);
    const context = try allocator.create(Context);
    context.* = .{
        .allocator = allocator,
        .set = set_source.take(),
        .device = undefined,
        .endpoint_contexts = undefined,
        .data_claims = undefined,
        .data_claim_count = 0,
        .identity = validated.identity,
        .writable = writable,
        .coordinator_claimed = false,
    };
    errdefer rollbackConstruction(context, set_source);

    try context.set.claimCoordinator();
    context.coordinator_claimed = true;

    var replicas: [max_replica_count]ReplicaEndpoint = undefined;
    for (
        validated.slots[0..validated.member_count],
        context.endpoint_contexts[0..validated.member_count],
        replicas[0..validated.member_count],
    ) |slot, *endpoint_context, *replica| {
        const data_member = context.set.dataMemberForRead(slot) catch unreachable;
        endpoint_context.* = .{ .member = data_member.member, .data_claim = null };
        if (writable) {
            context.data_claims[context.data_claim_count] = try data_member.member.claimData();
            endpoint_context.data_claim = &context.data_claims[context.data_claim_count];
            context.data_claim_count += 1;
        }
        const header = data_member.member.header();
        replica.* = ReplicaEndpoint.init(endpoint_context, .{
            .logical_capacity = header.logical_capacity,
            .data_length = header.data.length,
        }, &claimed_replica_vtable);
    }
    context.device = try pool_block_device.PoolBlockDevice.initBytes(
        io,
        replicas[0..validated.member_count],
        validated.layout,
        validated.capacity,
    );

    return storage_api.Storage.initBackend(
        context,
        &storage_vtable,
        validated.capacity,
        .pool_data,
        io_alignment,
    );
}

fn rejectActiveCoordinator(set: *pool_member_set.PoolMemberSet) !void {
    try set.claimCoordinator();
    set.releaseCoordinator();
}

fn rollbackConstruction(context: *Context, set_source: *pool_member_set.PoolMemberSet) void {
    releaseDataClaims(context, null);
    if (context.coordinator_claimed) {
        context.set.releaseCoordinator();
        context.coordinator_claimed = false;
    }
    set_source.* = context.set.take();
    context.allocator.destroy(context);
}

const ValidatedSet = struct {
    identity: [16]u8,
    capacity: u64,
    layout: @import("pool_layout.zig").Layout,
    slots: [max_replica_count]u16,
    member_count: usize,
};

fn validateSet(set: *pool_member_set.PoolMemberSet, writable: bool) !ValidatedSet {
    if (set.isClosed()) return error.MemberSetClosed;
    if (set.isRecoveryOnly()) return error.RecoveryPoolUnsupported;
    const authority = set.authority() orelse return error.MissingAuthority;
    if (authority.kind != pool_authority.Kind.genesis or authority.generation != 0 or
        authority.topology.epoch != 1 or authority.layout.layout_epoch != 1 or
        authority.layout.topology_epoch != authority.topology.epoch)
        return error.NonGenesisPoolUnsupported;

    const required_count: usize = switch (authority.layout.kind) {
        .unprotected => 1,
        .replicated => max_replica_count,
        .erasure_coded => return error.ErasureCodingNotImplemented,
    };
    if (authority.topology.member_count != required_count or
        set.suppliedCount() != required_count)
        return error.UnsupportedPoolWidth;
    if (writable) {
        if (set.dataAccess() != pool_policy.DataAccess.read_write)
            return error.DataWriteUnavailable;
    } else if (set.dataAccess() == .unavailable) {
        return error.DataReadUnavailable;
    }

    var result: ValidatedSet = .{
        .identity = authority.topology.set_id,
        .capacity = 0,
        .layout = authority.layout,
        .slots = undefined,
        .member_count = required_count,
    };
    var canonical: ?member_format.Header = null;
    for (authority.topology.memberSlice(), 0..) |descriptor, index| {
        if (descriptor.state != pool_topology.MemberState.active)
            return error.TransitionalPoolTopology;
        const data_member = try set.dataMemberForRead(descriptor.slot);
        const member = data_member.member;
        if ((member.mode() == .writable) != writable)
            return error.PoolAccessModeMismatch;
        const header = member.header();
        if (member_format.poolFilesystem(header) != .blob)
            return error.PoolDataRequiresBlobFilesystem;
        if (member_format.hasCatalogData(header)) return error.CatalogPoolUnsupported;
        if (!std.mem.eql(u8, &header.set_id, &authority.topology.set_id) or
            !std.mem.eql(u8, &header.member_id, &descriptor.member_id) or
            header.member_slot != descriptor.slot or
            header.member_count != authority.topology.member_count or
            header.chunk_size != authority.layout.chunk_size)
            return error.InconsistentMemberGeometry;
        if (header.logical_capacity < blob_format_api.minimum_device_size or
            header.logical_capacity % blob_format_api.blob_size != 0 or
            header.data.length < header.logical_capacity)
            return error.InvalidPoolDataGeometry;
        if (canonical) |expected| {
            if (!sameLogicalGeometry(expected, header)) return error.InconsistentMemberGeometry;
        } else {
            canonical = header;
            result.capacity = header.logical_capacity;
        }
        result.slots[index] = descriptor.slot;
    }
    return result;
}

fn sameLogicalGeometry(a: member_format.Header, b: member_format.Header) bool {
    return member_format.poolFilesystem(a) == member_format.poolFilesystem(b) and
        a.logical_capacity == b.logical_capacity and
        a.control.offset == b.control.offset and a.control.length == b.control.length and
        a.metadata.offset == b.metadata.offset and a.metadata.length == b.metadata.length and
        a.data.offset == b.data.offset and
        a.metadata_block_size == b.metadata_block_size and
        a.metadata_read_size == b.metadata_read_size and
        a.metadata_program_size == b.metadata_program_size and
        a.chunk_size == b.chunk_size;
}

fn contextFromOpaque(context_ptr: *anyopaque) *Context {
    return @ptrCast(@alignCast(context_ptr));
}

fn sameIdentity(context_ptr: *anyopaque, other_context_ptr: *anyopaque) bool {
    const context = contextFromOpaque(context_ptr);
    const other = contextFromOpaque(other_context_ptr);
    return std.mem.eql(u8, &context.identity, &other.identity);
}

fn readAt(context_ptr: *anyopaque, io: Io, buffer: []u8, offset: u64) !usize {
    const context = contextFromOpaque(context_ptr);
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    return context.device.readAt(buffer, offset);
}

fn writeAllAt(context_ptr: *anyopaque, io: Io, bytes: []const u8, offset: u64) !void {
    const context = contextFromOpaque(context_ptr);
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    if (!context.writable) return error.ReadOnlyPoolData;
    try context.device.writeAllAt(bytes, offset);
}

fn syncData(context_ptr: *anyopaque, io: Io) !void {
    const context = contextFromOpaque(context_ptr);
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    try context.device.sync();
}

fn sync(context_ptr: *anyopaque, io: Io) !void {
    const context = contextFromOpaque(context_ptr);
    try context.mutex.lock(io);
    defer context.mutex.unlock(io);
    try context.device.sync();
}

fn close(context_ptr: *anyopaque, _: Io) !void {
    const context = contextFromOpaque(context_ptr);
    const allocator = context.allocator;
    defer allocator.destroy(context);

    var first_error: ?anyerror = null;
    context.device.sync() catch |err| {
        first_error = err;
    };
    releaseDataClaims(context, &first_error);
    if (context.coordinator_claimed) {
        context.set.releaseCoordinator();
        context.coordinator_claimed = false;
    }
    context.set.close() catch |err| if (first_error == null) {
        first_error = err;
    };
    if (first_error) |err| return err;
}

fn releaseDataClaims(context: *Context, first_error: ?*?anyerror) void {
    while (context.data_claim_count != 0) {
        context.data_claim_count -= 1;
        context.data_claims[context.data_claim_count].release() catch |err| {
            if (first_error) |result| {
                if (result.* == null) result.* = err;
            } else unreachable;
        };
    }
}

fn claimedReplicaContext(context_ptr: *anyopaque) *ClaimedReplicaContext {
    return @ptrCast(@alignCast(context_ptr));
}

fn claimedReadMetadata(context_ptr: *anyopaque, offset: u64, buffer: []u8) !void {
    try claimedReplicaContext(context_ptr).member.read(.metadata, offset, buffer);
}

fn claimedReadData(context_ptr: *anyopaque, offset: u64, buffer: []u8) !void {
    try claimedReplicaContext(context_ptr).member.read(.data, offset, buffer);
}

fn claimedReadDataMany(
    context_ptr: *anyopaque,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
) !void {
    try claimedReplicaContext(context_ptr).member.readMany(.data, reads, results);
}

fn claimedWriteData(context_ptr: *anyopaque, offset: u64, bytes: []const u8) !void {
    const claim = claimedReplicaContext(context_ptr).data_claim orelse return error.ReadOnlyPoolData;
    try claim.write(offset, bytes);
}

fn claimedWriteMetadataDurable(_: *anyopaque, _: u64, _: []const u8) !void {
    return error.UnsupportedPoolDataOperation;
}

fn claimedSync(context_ptr: *anyopaque) !void {
    const claim = claimedReplicaContext(context_ptr).data_claim orelse return error.ReadOnlyPoolData;
    try claim.sync();
}

const claimed_replica_vtable: ReplicaEndpoint.VTable = .{
    .read_metadata = claimedReadMetadata,
    .read_data = claimedReadData,
    .read_data_many = claimedReadDataMany,
    .write_data = claimedWriteData,
    .write_metadata_durable = claimedWriteMetadataDurable,
    .sync = claimedSync,
};

fn transportKind(_: *anyopaque) storage_api.TransportKind {
    return .custom;
}

fn transportStats(context_ptr: *anyopaque, _: Io) storage_api.TransportStats {
    const context = contextFromOpaque(context_ptr);
    var total: storage_api.TransportStats = .{};
    for (0..context.set.suppliedCount()) |index| {
        const member = (context.set.memberAt(index) catch continue) orelse continue;
        addStats(&total, member.transportStats());
    }
    return total;
}

fn resetTransportStats(context_ptr: *anyopaque, _: Io) void {
    const context = contextFromOpaque(context_ptr);
    for (0..context.set.suppliedCount()) |index| {
        const member = (context.set.memberAt(index) catch continue) orelse continue;
        member.resetTransportStats();
    }
}

fn addStats(total: *storage_api.TransportStats, value: storage_api.TransportStats) void {
    // max_inflight is the sum of each member's peak, not a time-correlated Pool peak.
    inline for (std.meta.fields(storage_api.TransportStats)) |field| {
        @field(total, field.name) = std.math.add(
            u64,
            @field(total, field.name),
            @field(value, field.name),
        ) catch std.math.maxInt(u64);
    }
}

const storage_vtable: storage_api.Storage.VTable = .{
    .same_identity = sameIdentity,
    .read_at = readAt,
    .write_all_at = writeAllAt,
    .sync_data = syncData,
    .sync = sync,
    .close = close,
    .transport_kind = transportKind,
    .transport_stats = transportStats,
    .reset_transport_stats = resetTransportStats,
};

const test_member_names = [_][]const u8{ "member-a", "member-b", "member-c" };

fn provisionTestPool(
    dir: Io.Dir,
    protection: pool_policy.Protection,
    filesystem: member_format.PoolFilesystem,
) !usize {
    const pool_provision = @import("pool_provision.zig");
    const member_count = try protection.fullWidth();
    var storages: [max_replica_count]storage_api.Storage = undefined;
    for (test_member_names[0..member_count], storages[0..member_count]) |name, *storage|
        storage.* = try storage_api.Storage.createFile(std.testing.io, dir, name, 32 * 1024 * 1024);
    const outcome = try pool_provision.create(
        std.testing.io,
        std.testing.allocator,
        storages[0..member_count],
        .{ .protection = protection, .filesystem = filesystem },
    );
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    try provisioned.close();
    return member_count;
}

fn openTestSet(dir: Io.Dir, member_count: usize, intent: pool_member_set.OpenIntent) !pool_member_set.PoolMemberSet {
    var locations: [max_replica_count]pool_member_set.Location = undefined;
    for (test_member_names[0..member_count], locations[0..member_count]) |name, *location|
        location.* = .{ .parent = dir, .basename = name };
    return pool_member_set.open(std.testing.io, std.testing.allocator, locations[0..member_count], intent);
}

test "Pool data storage supports aligned byte IO across protection modes" {
    inline for (.{ pool_policy.Protection.unprotected, pool_policy.Protection.replicated }) |protection| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const member_count = try provisionTestPool(tmp.dir, protection, .blob);
        var set = try openTestSet(tmp.dir, member_count, .writable);
        var storage = try create(std.testing.allocator, std.testing.io, &set, true);
        defer storage.close(std.testing.io) catch {};

        try std.testing.expectEqual(storage_api.Kind.pool_data, storage.kind);
        try std.testing.expectEqual(@as(u32, io_alignment), storage.minimum_io_size);
        try std.testing.expectEqual(storage_api.TransportKind.custom, storage.transportKind());
        try std.testing.expect(storage.sameIdentity(&storage));

        const block = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(io_alignment), io_alignment);
        defer std.testing.allocator.free(block);
        @memset(block, 0x11);
        try storage.writeAllAt(std.testing.io, block, 0);
        @memset(block, 0);
        try std.testing.expectEqual(block.len, try storage.readAt(std.testing.io, block, 0));
        try std.testing.expect(std.mem.allEqual(u8, block, 0x11));

        const large = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(io_alignment), 1024 * 1024);
        defer std.testing.allocator.free(large);
        @memset(large, 0x22);
        try storage.writeAllAt(std.testing.io, large, 2 * 1024 * 1024);
        @memset(large, 0);
        try std.testing.expectEqual(large.len, try storage.readAt(std.testing.io, large, 2 * 1024 * 1024));
        try std.testing.expect(std.mem.allEqual(u8, large, 0x22));

        const crossing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(io_alignment), 2 * io_alignment);
        defer std.testing.allocator.free(crossing);
        @memset(crossing, 0x33);
        const crossing_offset = 1024 * 1024 - io_alignment;
        try storage.writeAllAt(std.testing.io, crossing, crossing_offset);
        try storage.sync(std.testing.io);
        _ = storage.transportStats(std.testing.io);
        storage.resetTransportStats(std.testing.io);
        @memset(crossing, 0);
        try std.testing.expectEqual(crossing.len, try storage.readAt(std.testing.io, crossing, crossing_offset));
        try std.testing.expect(std.mem.allEqual(u8, crossing, 0x33));
        try std.testing.expectError(error.InvalidPoolDataIo, storage.readAt(std.testing.io, crossing[0..io_alignment], 1));
        try std.testing.expectError(error.InvalidPoolDataIo, storage.writeAllAt(std.testing.io, crossing[0..1], 0));
        try std.testing.expectError(
            error.InvalidPoolDataIo,
            storage.writeAllAt(std.testing.io, crossing[0..io_alignment], storage.capacity()),
        );
    }
}

test "replicated Pool data reads require a matching majority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const member_count = try provisionTestPool(tmp.dir, .replicated, .blob);
    const buffer = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(io_alignment), io_alignment);
    defer std.testing.allocator.free(buffer);

    var set = try openTestSet(tmp.dir, member_count, .writable);
    for (0..member_count) |index| {
        @memset(buffer, if (index == 0) 0x11 else 0x22);
        try (try set.memberAt(index)).?.writeDurable(.data, 0, buffer);
    }
    var storage = try create(std.testing.allocator, std.testing.io, &set, true);
    @memset(buffer, 0);
    try std.testing.expectEqual(buffer.len, try storage.readAt(std.testing.io, buffer, 0));
    try std.testing.expect(std.mem.allEqual(u8, buffer, 0x22));
    try storage.close(std.testing.io);

    set = try openTestSet(tmp.dir, member_count, .writable);
    for (0..member_count) |index| {
        @memset(buffer, @intCast(index + 1));
        try (try set.memberAt(index)).?.writeDurable(.data, 0, buffer);
    }
    storage = try create(std.testing.allocator, std.testing.io, &set, true);
    defer storage.close(std.testing.io) catch {};
    try std.testing.expectError(error.ReplicaDivergence, storage.readAt(std.testing.io, buffer, 0));
}

test "Pool data write and sync failures freeze writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const member_count = try provisionTestPool(tmp.dir, .replicated, .blob);
    const buffer = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(io_alignment), io_alignment);
    defer std.testing.allocator.free(buffer);
    @memset(buffer, 0x44);

    var set = try openTestSet(tmp.dir, member_count, .writable);
    var write_fault: member_api.FaultController = .{ .fail_write_at = 0 };
    (try set.memberAt(2)).?.setFaultController(&write_fault);
    var storage = try create(std.testing.allocator, std.testing.io, &set, true);
    try std.testing.expectError(error.InjectedFault, storage.writeAllAt(std.testing.io, buffer, 0));
    try std.testing.expectError(error.WriteFrozen, storage.writeAllAt(std.testing.io, buffer, io_alignment));
    try std.testing.expectError(error.WriteFrozen, storage.close(std.testing.io));
    var reopened = try openTestSet(tmp.dir, member_count, .read_only);
    reopened.deinit();

    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    const second_count = try provisionTestPool(second_tmp.dir, .unprotected, .blob);
    set = try openTestSet(second_tmp.dir, second_count, .writable);
    var sync_fault: member_api.FaultController = .{ .fail_sync_at = 0 };
    (try set.memberAt(0)).?.setFaultController(&sync_fault);
    storage = try create(std.testing.allocator, std.testing.io, &set, true);
    try storage.writeAllAt(std.testing.io, buffer, 0);
    try std.testing.expectError(error.InjectedFault, storage.sync(std.testing.io));
    try std.testing.expectError(error.WriteFrozen, storage.writeAllAt(std.testing.io, buffer, io_alignment));
    try std.testing.expectError(error.WriteFrozen, storage.close(std.testing.io));
    reopened = try openTestSet(second_tmp.dir, second_count, .read_only);
    reopened.deinit();
}

test "Pool data construction ownership and read-only access are explicit" {
    var littlefs_tmp = std.testing.tmpDir(.{});
    defer littlefs_tmp.cleanup();
    const littlefs_count = try provisionTestPool(littlefs_tmp.dir, .unprotected, .littlefs);
    var littlefs_set = try openTestSet(littlefs_tmp.dir, littlefs_count, .writable);
    defer littlefs_set.deinit();
    try std.testing.expectError(
        error.PoolDataRequiresBlobFilesystem,
        create(std.testing.allocator, std.testing.io, &littlefs_set, true),
    );
    try std.testing.expect((try littlefs_set.memberAt(0)) != null);

    var blob_tmp = std.testing.tmpDir(.{});
    defer blob_tmp.cleanup();
    const blob_count = try provisionTestPool(blob_tmp.dir, .unprotected, .blob);
    var blob_set = try openTestSet(blob_tmp.dir, blob_count, .read_only);
    var storage = try create(std.testing.allocator, std.testing.io, &blob_set, false);
    const buffer = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(io_alignment), io_alignment);
    defer std.testing.allocator.free(buffer);
    try std.testing.expectError(error.ReadOnlyPoolData, storage.writeAllAt(std.testing.io, buffer, 0));
    const alias = storage;
    try std.testing.expect(storage.sameIdentity(&alias));
    var copies = [_]storage_api.Storage{ storage, alias };
    try storage_api.closeAll(&copies, std.testing.io);

    var partial_tmp = std.testing.tmpDir(.{});
    defer partial_tmp.cleanup();
    _ = try provisionTestPool(partial_tmp.dir, .replicated, .blob);
    var partial_set = try openTestSet(partial_tmp.dir, 2, .read_only);
    defer partial_set.deinit();
    try std.testing.expectError(
        error.UnsupportedPoolWidth,
        create(std.testing.allocator, std.testing.io, &partial_set, false),
    );
    try std.testing.expect((try partial_set.memberAt(0)) != null);
}

test "Pool data construction rejects existing ownership claims and restores the set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const member_count = try provisionTestPool(tmp.dir, .replicated, .blob);
    var set = try openTestSet(tmp.dir, member_count, .writable);
    defer set.deinit();

    try set.claimCoordinator();
    try std.testing.expectError(
        error.CoordinatorAlreadyOpen,
        create(std.testing.allocator, std.testing.io, &set, true),
    );
    try std.testing.expect((try set.memberAt(0)) != null);
    set.releaseCoordinator();

    var existing_claim = try (try set.memberAt(1)).?.claimData();
    try std.testing.expectError(
        error.DataAlreadyClaimed,
        create(std.testing.allocator, std.testing.io, &set, true),
    );
    try std.testing.expect((try set.memberAt(0)) != null);
    try std.testing.expectError(error.DataClaimed, (try set.memberAt(1)).?.write(.data, 0, "claimed"));
    var rollback_claim = try (try set.memberAt(0)).?.claimData();
    try rollback_claim.release();
    try existing_claim.release();

    var storage = try create(std.testing.allocator, std.testing.io, &set, true);
    const block = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(io_alignment), io_alignment);
    defer std.testing.allocator.free(block);
    @memset(block, 0x5a);
    try storage.writeAllAt(std.testing.io, block, 0);
    try storage.sync(std.testing.io);
    try storage.close(std.testing.io);
}

fn rewriteTestLogicalCapacity(dir: Io.Dir, member_count: usize, logical_capacity: u64) !void {
    for (test_member_names[0..member_count]) |name| {
        var member = try member_api.openAt(std.testing.io, dir, name, .writable);
        var header = member.header();
        try member.close();
        header.logical_capacity = logical_capacity;
        const encoded = try member_format.encode(header);
        const file = try dir.openFile(std.testing.io, name, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, &encoded, 0);
        try file.writePositionalAll(std.testing.io, &encoded, member_format.encoded_size);
        try file.sync(std.testing.io);
    }
}

test "Pool data validates Blob geometry before taking the member set" {
    for ([_]u64{
        blob_format_api.blob_size,
        blob_format_api.minimum_device_size + io_alignment,
    }) |invalid_capacity| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const member_count = try provisionTestPool(tmp.dir, .unprotected, .blob);
        try rewriteTestLogicalCapacity(tmp.dir, member_count, invalid_capacity);
        var set = try openTestSet(tmp.dir, member_count, .writable);
        defer set.deinit();

        try std.testing.expectError(
            error.InvalidPoolDataGeometry,
            create(std.testing.allocator, std.testing.io, &set, true),
        );
        try std.testing.expect((try set.memberAt(0)) != null);
    }
}

const TestReplicaOperation = enum { first_write, second_write, sync };

const OrderedReplica = struct {
    io: Io,
    first_write_count: *std.atomic.Value(u32),
    second_write_count: *std.atomic.Value(u32),
    sync_count: *std.atomic.Value(u32),
    first_writes_entered: *Io.Event,
    release_first_writes: *Io.Event,
    operations: [3]TestReplicaOperation = undefined,
    operation_count: std.atomic.Value(u32) = .init(0),
    fail_first_write: bool = false,

    const vtable: ReplicaEndpoint.VTable = .{
        .read_metadata = read,
        .read_data = read,
        .write_data = write,
        .write_metadata_durable = write,
        .sync = syncReplica,
    };

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn record(self: *@This(), operation: TestReplicaOperation) void {
        const index = self.operation_count.fetchAdd(1, .acq_rel);
        self.operations[index] = operation;
    }

    fn read(_: *anyopaque, _: u64, buffer: []u8) !void {
        @memset(buffer, 0);
    }

    fn write(context: *anyopaque, _: u64, bytes: []const u8) !void {
        const self = fromContext(context);
        if (bytes[0] == 0x11) {
            self.record(.first_write);
            if (self.first_write_count.fetchAdd(1, .acq_rel) + 1 == max_replica_count)
                self.first_writes_entered.set(self.io);
            self.release_first_writes.waitUncancelable(self.io);
            if (self.fail_first_write) return error.InjectedFault;
        } else {
            self.record(.second_write);
            _ = self.second_write_count.fetchAdd(1, .acq_rel);
        }
    }

    fn syncReplica(context: *anyopaque) !void {
        const self = fromContext(context);
        self.record(.sync);
        _ = self.sync_count.fetchAdd(1, .acq_rel);
    }
};

fn initOrderedTestContext(context: *Context, replicas: *[max_replica_count]OrderedReplica) !void {
    var endpoints: [max_replica_count]ReplicaEndpoint = undefined;
    for (replicas, &endpoints) |*replica, *endpoint| endpoint.* = .init(replica, .{
        .logical_capacity = blob_format_api.minimum_device_size,
        .data_length = blob_format_api.minimum_device_size,
    }, &OrderedReplica.vtable);
    const layout = try @import("pool_layout.zig").Layout.init(
        .replicated,
        1,
        1,
        blob_format_api.blob_size,
    );
    context.* = .{
        .allocator = std.testing.allocator,
        .set = .{},
        .device = try .initBytes(std.testing.io, &endpoints, layout, blob_format_api.minimum_device_size),
        .endpoint_contexts = undefined,
        .data_claims = undefined,
        .data_claim_count = 0,
        .identity = @splat(0),
        .writable = true,
        .coordinator_claimed = false,
    };
}

fn testWriteWorker(
    context: *Context,
    bytes: []const u8,
    offset: u64,
    started: *std.atomic.Value(bool),
) !void {
    started.store(true, .release);
    try writeAllAt(context, std.testing.io, bytes, offset);
}

fn testSyncWorker(context: *Context, started: *std.atomic.Value(bool)) !void {
    started.store(true, .release);
    try sync(context, std.testing.io);
}

fn waitForContended(mutex: *Io.Mutex, started: *std.atomic.Value(bool)) !void {
    while (!started.load(.acquire) or mutex.state.load(.acquire) != .contended)
        try std.Thread.yield();
}

fn expectReplicaOperations(
    replicas: *const [max_replica_count]OrderedReplica,
    expected: []const TestReplicaOperation,
) !void {
    for (replicas) |*replica| {
        const count: usize = @intCast(replica.operation_count.load(.acquire));
        try std.testing.expectEqualSlices(TestReplicaOperation, expected, replica.operations[0..count]);
    }
}

test "Pool data serializes write ordering across replicas" {
    var first_write_count: std.atomic.Value(u32) = .init(0);
    var second_write_count: std.atomic.Value(u32) = .init(0);
    var sync_count: std.atomic.Value(u32) = .init(0);
    var first_writes_entered: Io.Event = .unset;
    var release_first_writes: Io.Event = .unset;
    var replicas: [max_replica_count]OrderedReplica = undefined;
    for (&replicas) |*replica| replica.* = .{
        .io = std.testing.io,
        .first_write_count = &first_write_count,
        .second_write_count = &second_write_count,
        .sync_count = &sync_count,
        .first_writes_entered = &first_writes_entered,
        .release_first_writes = &release_first_writes,
    };
    var context: Context = undefined;
    try initOrderedTestContext(&context, &replicas);
    const first: [io_alignment]u8 = @splat(0x11);
    const second: [io_alignment]u8 = @splat(0x22);
    var first_started: std.atomic.Value(bool) = .init(false);
    var first_future = try std.testing.io.concurrent(testWriteWorker, .{ &context, &first, 0, &first_started });
    var first_pending = true;
    defer if (first_pending) {
        _ = first_future.cancel(std.testing.io) catch {};
    };
    first_writes_entered.waitUncancelable(std.testing.io);

    var second_started: std.atomic.Value(bool) = .init(false);
    var second_future = try std.testing.io.concurrent(testWriteWorker, .{
        &context,
        &second,
        io_alignment,
        &second_started,
    });
    var second_pending = true;
    defer if (second_pending) {
        _ = second_future.cancel(std.testing.io) catch {};
    };
    try waitForContended(&context.mutex, &second_started);
    try std.testing.expectEqual(@as(u32, 0), second_write_count.load(.acquire));

    release_first_writes.set(std.testing.io);
    try first_future.await(std.testing.io);
    first_pending = false;
    try second_future.await(std.testing.io);
    second_pending = false;
    try expectReplicaOperations(&replicas, &.{ .first_write, .second_write });
}

test "Pool data serializes dirty write before sync" {
    var first_write_count: std.atomic.Value(u32) = .init(0);
    var second_write_count: std.atomic.Value(u32) = .init(0);
    var sync_count: std.atomic.Value(u32) = .init(0);
    var first_writes_entered: Io.Event = .unset;
    var release_first_writes: Io.Event = .unset;
    var replicas: [max_replica_count]OrderedReplica = undefined;
    for (&replicas) |*replica| replica.* = .{
        .io = std.testing.io,
        .first_write_count = &first_write_count,
        .second_write_count = &second_write_count,
        .sync_count = &sync_count,
        .first_writes_entered = &first_writes_entered,
        .release_first_writes = &release_first_writes,
    };
    var context: Context = undefined;
    try initOrderedTestContext(&context, &replicas);
    const first: [io_alignment]u8 = @splat(0x11);
    var write_started: std.atomic.Value(bool) = .init(false);
    var write_future = try std.testing.io.concurrent(testWriteWorker, .{ &context, &first, 0, &write_started });
    var write_pending = true;
    defer if (write_pending) {
        _ = write_future.cancel(std.testing.io) catch {};
    };
    first_writes_entered.waitUncancelable(std.testing.io);

    var sync_started: std.atomic.Value(bool) = .init(false);
    var sync_future = try std.testing.io.concurrent(testSyncWorker, .{ &context, &sync_started });
    var sync_pending = true;
    defer if (sync_pending) {
        _ = sync_future.cancel(std.testing.io) catch {};
    };
    try waitForContended(&context.mutex, &sync_started);
    try std.testing.expectEqual(@as(u32, 0), sync_count.load(.acquire));

    release_first_writes.set(std.testing.io);
    try write_future.await(std.testing.io);
    write_pending = false;
    try sync_future.await(std.testing.io);
    sync_pending = false;
    try expectReplicaOperations(&replicas, &.{ .first_write, .sync });
}

test "Pool data failure freezes a queued write" {
    var first_write_count: std.atomic.Value(u32) = .init(0);
    var second_write_count: std.atomic.Value(u32) = .init(0);
    var sync_count: std.atomic.Value(u32) = .init(0);
    var first_writes_entered: Io.Event = .unset;
    var release_first_writes: Io.Event = .unset;
    var replicas: [max_replica_count]OrderedReplica = undefined;
    for (&replicas, 0..) |*replica, index| replica.* = .{
        .io = std.testing.io,
        .first_write_count = &first_write_count,
        .second_write_count = &second_write_count,
        .sync_count = &sync_count,
        .first_writes_entered = &first_writes_entered,
        .release_first_writes = &release_first_writes,
        .fail_first_write = index == replicas.len - 1,
    };
    var context: Context = undefined;
    try initOrderedTestContext(&context, &replicas);
    const first: [io_alignment]u8 = @splat(0x11);
    const second: [io_alignment]u8 = @splat(0x22);
    var first_started: std.atomic.Value(bool) = .init(false);
    var first_future = try std.testing.io.concurrent(testWriteWorker, .{ &context, &first, 0, &first_started });
    var first_pending = true;
    defer if (first_pending) {
        _ = first_future.cancel(std.testing.io) catch {};
    };
    first_writes_entered.waitUncancelable(std.testing.io);

    var second_started: std.atomic.Value(bool) = .init(false);
    var second_future = try std.testing.io.concurrent(testWriteWorker, .{
        &context,
        &second,
        io_alignment,
        &second_started,
    });
    var second_pending = true;
    defer if (second_pending) {
        _ = second_future.cancel(std.testing.io) catch {};
    };
    try waitForContended(&context.mutex, &second_started);
    release_first_writes.set(std.testing.io);

    try std.testing.expectError(error.InjectedFault, first_future.await(std.testing.io));
    first_pending = false;
    try std.testing.expectError(error.WriteFrozen, second_future.await(std.testing.io));
    second_pending = false;
    try std.testing.expectEqual(@as(u32, 0), second_write_count.load(.acquire));
    try expectReplicaOperations(&replicas, &.{.first_write});
}

test "Blob Store and Filesystem reopen over Pool data storage" {
    const blob_device = @import("../blob_device.zig");
    const blob_filesystem = @import("../blob_filesystem.zig");
    const blob_format = @import("../blob_format.zig");
    const blob_store = @import("../blob_store.zig");
    const name_profile = @import("../name_profile.zig");

    var store_tmp = std.testing.tmpDir(.{});
    defer store_tmp.cleanup();
    const store_count = try provisionTestPool(store_tmp.dir, .unprotected, .blob);
    var set = try openTestSet(store_tmp.dir, store_count, .writable);
    var storage = try create(std.testing.allocator, std.testing.io, &set, true);
    const capacity = storage.capacity();
    var device = try blob_device.Device.init(storage, 0, capacity, blob_format.allocation_unit);
    var store = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    const reference = try store.put(std.testing.io, "Pool-backed blob");
    try store.commit(std.testing.io);
    try store.close(std.testing.io);

    set = try openTestSet(store_tmp.dir, store_count, .read_only);
    storage = try create(std.testing.allocator, std.testing.io, &set, false);
    device = try blob_device.Device.init(storage, 0, storage.capacity(), blob_format.allocation_unit);
    store = try blob_store.Store.open(std.testing.allocator, std.testing.io, device);
    const output = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(io_alignment), blob_format.blob_size);
    defer std.testing.allocator.free(output);
    const amount = try store.read(std.testing.io, reference, output);
    try std.testing.expectEqualStrings("Pool-backed blob", output[0..amount]);
    try store.close(std.testing.io);

    var filesystem_tmp = std.testing.tmpDir(.{});
    defer filesystem_tmp.cleanup();
    const filesystem_count = try provisionTestPool(filesystem_tmp.dir, .unprotected, .blob);
    set = try openTestSet(filesystem_tmp.dir, filesystem_count, .writable);
    storage = try create(std.testing.allocator, std.testing.io, &set, true);
    device = try blob_device.Device.init(storage, 0, storage.capacity(), blob_format.allocation_unit);
    store = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var filesystem = try blob_filesystem.Filesystem.format(
        std.testing.allocator,
        std.testing.io,
        store,
        name_profile.Profile.legacy_raw,
    );
    const inode = try filesystem.createFile(std.testing.io, 1, "small", 0o644, 0, 0);
    _ = try filesystem.write(std.testing.io, inode, "data", 0);
    try filesystem.close(std.testing.io);

    set = try openTestSet(filesystem_tmp.dir, filesystem_count, .read_only);
    storage = try create(std.testing.allocator, std.testing.io, &set, false);
    device = try blob_device.Device.init(storage, 0, storage.capacity(), blob_format.allocation_unit);
    store = try blob_store.Store.open(std.testing.allocator, std.testing.io, device);
    filesystem = try blob_filesystem.Filesystem.open(std.testing.allocator, std.testing.io, store, false);
    defer filesystem.close(std.testing.io) catch {};
    try std.testing.expectEqual(inode, try filesystem.resolvePath(std.testing.io, "/small"));
}
