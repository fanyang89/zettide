const std = @import("std");
const blob_format = @import("../blob_format.zig");
const codec = @import("codec.zig");
const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const pool_genesis = @import("pool_genesis_payload.zig");
const pool_layout = @import("pool_layout.zig");
const pool_policy = @import("pool_policy.zig");
const pool_topology = @import("pool_topology.zig");
const storage_api = @import("storage.zig");

const default_control_bytes: u64 = 960 * 1024;
const minimum_control_bytes: u64 = 5 * 4096;
const default_metadata_bytes: u64 = 1024 * 1024;
const default_chunk_size: u32 = 1024 * 1024;
const region_alignment: u64 = 1024 * 1024;

pub const Options = struct {
    protection: pool_policy.Protection = .replicated,
    filesystem: member_format.PoolFilesystem = .littlefs,
    label: []const u8 = "Zettide",
    chunk_size: u32 = default_chunk_size,
    control_bytes: u64 = default_control_bytes,
    metadata_bytes: u64 = default_metadata_bytes,
    member_create_options: []const member_api.CreateOptions = &.{},
};

pub fn minimumMemberBytes(options: Options) !u64 {
    const data_offset = try dataOffset(options);
    const minimum_logical_capacity: u64 = switch (options.filesystem) {
        .littlefs => 1,
        .blob => blob_format.minimum_device_size,
    };
    const required_bytes = std.math.add(u64, data_offset, minimum_logical_capacity) catch
        return error.InvalidGeometry;
    return codec.alignForward(required_bytes, options.chunk_size);
}

fn dataOffset(options: Options) !u64 {
    const control: codec.Region = .{ .offset = 64 * 1024, .length = options.control_bytes };
    const metadata_offset = try codec.alignForward(try control.end(), region_alignment);
    const metadata_end = std.math.add(u64, metadata_offset, options.metadata_bytes) catch
        return error.InvalidGeometry;
    return codec.alignForward(metadata_end, region_alignment);
}

pub const ProvisionedPool = struct {
    allocator: std.mem.Allocator,
    members: []member_api.Member,
    genesis: pool_genesis.GenesisPayload,

    pub fn close(self: *ProvisionedPool) !void {
        if (self.members.len == 0) return;
        var first_error: ?anyerror = null;
        for (self.members) |*member| member.close() catch |err| if (first_error == null) {
            first_error = err;
        };
        var all_closed = true;
        for (self.members) |*member| all_closed = all_closed and member.isClosed();
        if (all_closed) {
            self.allocator.free(self.members);
            self.members = &.{};
        }
        if (first_error) |err| return err;
    }

    pub fn deinit(self: *ProvisionedPool) void {
        self.close() catch {};
    }
};

pub const PartialCreation = struct {
    set_id: [16]u8,
    genesis: pool_genesis.GenesisPayload,
    completed_member_count: u16,
    failed_member_index: u16,
    cause: anyerror,
};

pub const CreateOutcome = union(enum) {
    complete: ProvisionedPool,
    partial: PartialCreation,
};

pub fn create(
    io: std.Io,
    allocator: std.mem.Allocator,
    storages: []storage_api.Storage,
    options: Options,
) !CreateOutcome {
    var consumed_count: usize = 0;
    errdefer storage_api.closeAll(storages[consumed_count..], io) catch {};
    if (storages.len == 0 or storages.len > pool_topology.max_member_count)
        return error.InvalidMemberCount;
    if (options.member_create_options.len != 0 and options.member_create_options.len != storages.len)
        return error.InvalidCreateOptions;
    if (options.protection == .erasure_coded)
        return error.ErasureCodingNotImplemented;
    if (storages.len < try options.protection.fullWidth())
        return error.InsufficientMembers;
    if ((try pool_policy.controlPolicy(storages.len)).voter_count == 2)
        return error.InvalidMemberCount;
    if (!std.math.isPowerOfTwo(options.chunk_size) or options.chunk_size % 4096 != 0 or
        options.control_bytes < minimum_control_bytes or options.control_bytes % 4096 != 0 or
        options.metadata_bytes < 256 * 1024 or options.metadata_bytes % 4096 != 0)
        return error.InvalidGeometry;
    const label = try member_format.Label.init(options.label);

    const control: codec.Region = .{ .offset = 64 * 1024, .length = options.control_bytes };
    const metadata: codec.Region = .{
        .offset = try codec.alignForward(try control.end(), region_alignment),
        .length = options.metadata_bytes,
    };
    const data_offset = try dataOffset(options);
    if (data_offset % options.chunk_size != 0) return error.InvalidGeometry;
    const minimum_member_bytes = try minimumMemberBytes(options);
    var member_bytes: [pool_topology.max_member_count]u64 = undefined;
    var minimum_data_bytes: u64 = std.math.maxInt(u64);
    var minimum_io_size: u32 = 512;
    for (storages, 0..) |storage, index| {
        for (storages[0..index]) |previous| {
            if (storage.sameIdentity(&previous)) return error.DuplicateStorage;
        }
        if (!std.math.isPowerOfTwo(storage.minimum_io_size) or storage.minimum_io_size > 4096 or
            4096 % storage.minimum_io_size != 0) return error.UnsupportedStorageAlignment;
        minimum_io_size = @max(minimum_io_size, storage.minimum_io_size);
        member_bytes[index] = storage.capacity() / options.chunk_size * options.chunk_size;
        if (storage.kind == .regular_file and member_bytes[index] != storage.capacity())
            return error.UnexpectedMemberLength;
        if (member_bytes[index] < minimum_member_bytes)
            return error.StorageTooSmall;
        minimum_data_bytes = @min(minimum_data_bytes, member_bytes[index] - data_offset);
    }
    const logical_capacity = switch (options.filesystem) {
        .littlefs => minimum_data_bytes,
        .blob => minimum_data_bytes / blob_format.blob_size * blob_format.blob_size,
    };
    if (options.filesystem == .blob and logical_capacity < blob_format.minimum_device_size)
        return error.StorageTooSmall;

    var set_id: [16]u8 = undefined;
    try randomNonZeroId(io, &set_id);
    var descriptors: [pool_topology.max_member_count]pool_topology.Member = undefined;
    const control_policy = try pool_policy.controlPolicy(storages.len);
    for (descriptors[0..storages.len], 0..) |*descriptor, index| {
        var member_id: [16]u8 = undefined;
        while (true) {
            try randomNonZeroId(io, &member_id);
            if (!std.mem.eql(u8, &member_id, &set_id) and !containsMemberId(descriptors[0..index], member_id)) break;
        }
        const voter = index < control_policy.voter_count;
        descriptor.* = .{
            .member_id = member_id,
            .slot = @intCast(index),
            .control_role = if (voter) pool_topology.voter_role else pool_topology.non_voter_role,
            .role_flags = if (voter) member_format.known_role_flags else member_format.data_role,
        };
    }
    const genesis: pool_genesis.GenesisPayload = .{
        .topology = try pool_topology.Topology.init(set_id, 1, @splat(0), descriptors[0..storages.len]),
        .layout = try pool_layout.Layout.init(options.protection, 1, 1, options.chunk_size),
    };
    const topology_digest = try pool_topology.digest(genesis.topology);
    const created_ns: i64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);

    var headers: [pool_topology.max_member_count]member_format.Header = undefined;
    for (headers[0..storages.len], 0..) |*header, index| {
        const descriptor = descriptors[index];
        header.* = .{
            .header_sequence = 1,
            .incompat_features = member_format.dynamic_pool_incompat_feature |
                (if (options.filesystem == .blob) member_format.blob_filesystem_incompat_feature else 0),
            .set_id = set_id,
            .member_id = descriptor.member_id,
            .member_slot = descriptor.slot,
            .member_count = @intCast(storages.len),
            .role_flags = descriptor.role_flags,
            .created_ns = created_ns,
            .member_bytes = member_bytes[index],
            .logical_capacity = logical_capacity,
            .control = control,
            .metadata = metadata,
            .data = .{ .offset = data_offset, .length = member_bytes[index] - data_offset },
            .metadata_block_size = 4096,
            .metadata_read_size = minimum_io_size,
            .metadata_program_size = minimum_io_size,
            .chunk_size = options.chunk_size,
            .metadata_format_version = member_format.supported_metadata_format_version,
            .object_format_version = member_format.supported_object_format_version,
            .layout_format_version = member_format.dynamic_layout_format_version,
            .control_record_format_version = member_format.supported_control_record_format_version,
            .label = label,
            .genesis_topology_digest = topology_digest,
        };
        try member_api.validateCreatePoolStorage(header.*, genesis);
    }

    for (storages) |*storage| try storage.sync(io);

    const members = try allocator.alloc(member_api.Member, storages.len);
    var created_count: usize = 0;
    while (consumed_count < storages.len) {
        const index = consumed_count;
        consumed_count += 1;
        const create_options = if (options.member_create_options.len == 0)
            member_api.CreateOptions{}
        else
            options.member_create_options[index];
        members[index] = member_api.createPoolStorage(io, storages[index], headers[index], genesis, create_options) catch |cause| {
            for (members[0..created_count]) |*member| member.deinit();
            storage_api.closeAll(storages[consumed_count..], io) catch {};
            allocator.free(members);
            consumed_count = storages.len;
            return .{ .partial = .{
                .set_id = set_id,
                .genesis = genesis,
                .completed_member_count = @intCast(created_count),
                .failed_member_index = @intCast(index),
                .cause = cause,
            } };
        };
        created_count += 1;
    }
    return .{ .complete = .{ .allocator = allocator, .members = members, .genesis = genesis } };
}

fn randomNonZeroId(io: std.Io, id: *[16]u8) !void {
    while (true) {
        try io.randomSecure(id);
        if (!codec.isZero(id)) return;
    }
}

fn containsMemberId(members: []const pool_topology.Member, id: [16]u8) bool {
    for (members) |member| if (std.mem.eql(u8, &member.member_id, &id)) return true;
    return false;
}

test "provisioning validates all file storages then creates a reopenable pool" {
    try std.testing.expectEqual(member_format.PoolFilesystem.littlefs, (Options{}).filesystem);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "a", "b", "c" };
    var storages: [names.len]storage_api.Storage = undefined;
    for (names, 0..) |name, index|
        storages[index] = try storage_api.Storage.createFile(std.testing.io, tmp.dir, name, 8 * 1024 * 1024);

    const outcome = try create(std.testing.io, std.testing.allocator, &storages, .{});
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    try std.testing.expectEqual(@as(usize, 3), provisioned.members.len);
    try std.testing.expectEqual(member_format.PoolFilesystem.littlefs, member_format.poolFilesystem(provisioned.members[0].header()));
    try std.testing.expectEqual(pool_layout.Kind.replicated, provisioned.genesis.layout.kind);
    try std.testing.expectEqual(@as(u64, 240 * 4096), provisioned.members[0].header().control.length);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), provisioned.members[0].header().metadata.offset);
    try provisioned.close();

    var reopened_storages: [names.len]storage_api.Storage = undefined;
    for (names, 0..) |name, index|
        reopened_storages[index] = try storage_api.Storage.openFile(std.testing.io, tmp.dir, name, true);
    var reopened = try @import("pool_member_set.zig").openStorages(
        std.testing.io,
        std.testing.allocator,
        &reopened_storages,
        .writable,
    );
    defer reopened.deinit();
    try std.testing.expect(reopened.controlWriteReady() != null);
    try std.testing.expectEqual(pool_policy.DataAccess.read_write, reopened.dataAccess());
}

test "provisioning marks every Blob Pool member" {
    inline for (.{
        .{ .protection = pool_policy.Protection.unprotected, .member_count = 1 },
        .{ .protection = pool_policy.Protection.replicated, .member_count = 3 },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const names = [_][]const u8{ "a", "b", "c" };
        var storages: [case.member_count]storage_api.Storage = undefined;
        for (names[0..case.member_count], 0..) |name, index|
            storages[index] = try storage_api.Storage.createFile(std.testing.io, tmp.dir, name, 8 * 1024 * 1024);

        const outcome = try create(std.testing.io, std.testing.allocator, &storages, .{
            .protection = case.protection,
            .filesystem = .blob,
        });
        var provisioned = switch (outcome) {
            .complete => |value| value,
            .partial => return error.UnexpectedPartialCreation,
        };
        defer provisioned.deinit();
        for (provisioned.members) |*member|
            try std.testing.expectEqual(member_format.PoolFilesystem.blob, member_format.poolFilesystem(member.header()));
        try provisioned.close();

        for (names[0..case.member_count]) |name| {
            const file = try tmp.dir.openFile(std.testing.io, name, .{ .mode = .read_only });
            defer file.close(std.testing.io);
            for ([_]u64{ 0, member_format.encoded_size }) |offset| {
                var bytes: [member_format.encoded_size]u8 = undefined;
                _ = try file.readPositionalAll(std.testing.io, &bytes, offset);
                const header = try member_format.decode(&bytes);
                try std.testing.expectEqual(member_format.PoolFilesystem.blob, member_format.poolFilesystem(header));
            }
        }
    }
}

test "Blob Pool provisioning requires minimum Blob logical capacity" {
    try std.testing.expectEqual(@as(u64, 3 * 1024 * 1024), try minimumMemberBytes(.{}));
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024), try minimumMemberBytes(.{ .filesystem = .blob }));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storages = [_]storage_api.Storage{
        try storage_api.Storage.createFile(std.testing.io, tmp.dir, "member", 3 * 1024 * 1024),
    };
    try std.testing.expectError(
        error.StorageTooSmall,
        create(std.testing.io, std.testing.allocator, &storages, .{
            .protection = .unprotected,
            .filesystem = .blob,
        }),
    );
}

test "Blob Pool logical capacity is common and Blob-aligned with 4KiB chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "a", "b", "c" };
    const sizes = [_]u64{
        4 * 1024 * 1024 + 4096,
        5 * 1024 * 1024 + 2 * 4096,
        6 * 1024 * 1024 + 3 * 4096,
    };
    var storages: [names.len]storage_api.Storage = undefined;
    for (names, sizes, 0..) |name, size, index|
        storages[index] = try storage_api.Storage.createFile(std.testing.io, tmp.dir, name, size);

    const outcome = try create(std.testing.io, std.testing.allocator, &storages, .{
        .filesystem = .blob,
        .chunk_size = 4096,
    });
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    for (provisioned.members, sizes) |*member, size| {
        try std.testing.expectEqual(size, member.header().member_bytes);
        try std.testing.expectEqual(blob_format.minimum_device_size, member.header().logical_capacity);
        try std.testing.expectEqual(@as(u64, 0), member.header().logical_capacity % blob_format.blob_size);
    }
}

test "Blob minimum member geometry reports overflow" {
    try std.testing.expectError(error.RegionOverflow, minimumMemberBytes(.{
        .filesystem = .blob,
        .control_bytes = std.math.maxInt(u64) - 4095,
    }));
}

test "provisioning reserves genesis plus one control transaction" {
    inline for (.{ 4096, 2 * 4096, 3 * 4096, 4 * 4096 }) |control_bytes| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storages = [_]storage_api.Storage{
            try storage_api.Storage.createFile(std.testing.io, tmp.dir, "member", 8 * 1024 * 1024),
        };
        try std.testing.expectError(
            error.InvalidGeometry,
            create(std.testing.io, std.testing.allocator, &storages, .{
                .protection = .unprotected,
                .control_bytes = control_bytes,
            }),
        );
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storages = [_]storage_api.Storage{
        try storage_api.Storage.createFile(std.testing.io, tmp.dir, "member", 8 * 1024 * 1024),
    };
    const outcome = try create(std.testing.io, std.testing.allocator, &storages, .{
        .protection = .unprotected,
        .control_bytes = minimum_control_bytes,
    });
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    try std.testing.expectEqual(minimum_control_bytes, provisioned.members[0].header().control.length);
}

test "provisioning rejects every target before the first write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "a", "small", "c" };
    const sizes = [_]u64{ 8 * 1024 * 1024, 1024 * 1024, 8 * 1024 * 1024 };
    var storages: [names.len]storage_api.Storage = undefined;
    for (names, sizes, 0..) |name, size, index|
        storages[index] = try storage_api.Storage.createFile(std.testing.io, tmp.dir, name, size);

    try std.testing.expectError(
        error.StorageTooSmall,
        create(std.testing.io, std.testing.allocator, &storages, .{}),
    );
    const offsets = [_]u64{ 0, member_format.encoded_size, 64 * 1024 };
    for (names) |name| {
        const file = try tmp.dir.openFile(std.testing.io, name, .{ .mode = .read_only });
        defer file.close(std.testing.io);
        for (offsets) |offset| {
            var bytes: [member_format.encoded_size]u8 = undefined;
            _ = try file.readPositionalAll(std.testing.io, &bytes, offset);
            try std.testing.expect(codec.isZero(&bytes));
        }
    }
}

test "publication failure returns explicit partial pool identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "a", "b", "c" };
    var storages: [names.len]storage_api.Storage = undefined;
    for (names, 0..) |name, index|
        storages[index] = try storage_api.Storage.createFile(std.testing.io, tmp.dir, name, 8 * 1024 * 1024);
    var fault: member_api.CreateFaultController = .{ .fail = .{
        .point = .header_a_sync,
        .action = .before,
    } };
    const create_options = [_]member_api.CreateOptions{ .{}, .{}, .{ .fault = &fault } };

    const outcome = try create(std.testing.io, std.testing.allocator, &storages, .{
        .member_create_options = &create_options,
    });
    const partial = switch (outcome) {
        .complete => return error.ExpectedPartialCreation,
        .partial => |value| value,
    };
    try std.testing.expectEqual(@as(u16, 2), partial.completed_member_count);
    try std.testing.expectEqual(@as(u16, 2), partial.failed_member_index);
    try std.testing.expectEqual(error.InjectedCreateFault, partial.cause);

    var reopened_storages: [2]storage_api.Storage = undefined;
    for (names[0..2], 0..) |name, index|
        reopened_storages[index] = try storage_api.Storage.openFile(std.testing.io, tmp.dir, name, true);
    var reopened = try @import("pool_member_set.zig").openStorages(
        std.testing.io,
        std.testing.allocator,
        &reopened_storages,
        .writable,
    );
    defer reopened.deinit();
    try std.testing.expect(reopened.controlWriteReady() != null);
    try std.testing.expectEqualSlices(u8, &partial.set_id, &reopened.authority().?.topology.set_id);
}
