const std = @import("std");
const block_device = @import("../block_device.zig");
const container = @import("../container.zig");
const member_api = @import("member.zig");
const pool_layout = @import("pool_layout.zig");

const c = block_device.c;
const max_replica_count = 3;

pub const PoolBlockDevice = struct {
    io: std.Io,
    members: [max_replica_count]*member_api.Member,
    member_count: usize,
    kind: pool_layout.Kind,
    volume_header: container.Header,
    block_size: u32,
    block_count: u32,
    mutex: std.Io.Mutex = .init,
    write_frozen: std.atomic.Value(bool) = .init(false),

    pub fn init(
        io: std.Io,
        members: []const *member_api.Member,
        layout: pool_layout.Layout,
        header: container.Header,
    ) !PoolBlockDevice {
        const required_count: usize = switch (layout.kind) {
            .unprotected => 1,
            .replicated => max_replica_count,
            .erasure_coded => return error.ErasureCodingNotImplemented,
        };
        if (members.len != required_count) return error.UnsupportedPoolWidth;
        if (header.logical_size > members[0].header().logical_capacity)
            return error.TruncatedPoolData;
        var result: PoolBlockDevice = .{
            .io = io,
            .members = undefined,
            .member_count = members.len,
            .kind = layout.kind,
            .volume_header = header,
            .block_size = header.block_size,
            .block_count = header.block_count,
        };
        for (members, 0..) |member, index| {
            if (header.logical_size > member.header().logical_capacity)
                return error.InconsistentPoolCapacity;
            result.members[index] = member;
        }
        return result;
    }

    pub fn initHeaderReader(
        io: std.Io,
        members: []const *member_api.Member,
        layout: pool_layout.Layout,
    ) !PoolBlockDevice {
        var header: container.Header = undefined;
        header.logical_size = container.default_block_size;
        header.block_size = container.default_block_size;
        header.block_count = 1;
        return init(io, members, layout, header);
    }

    pub fn read(self: *PoolBlockDevice, block: u32, offset: u32, buffer: []u8) !void {
        const data_offset = try self.position(block, offset, buffer.len);
        if (self.kind == .unprotected)
            return self.members[0].read(.data, data_offset, buffer);
        if (buffer.len > container.default_block_size) return error.OutOfBounds;

        var copies: [max_replica_count][container.default_block_size]u8 = undefined;
        var readable: [max_replica_count]bool = @splat(false);
        for (self.members[0..self.member_count], 0..) |member, index| {
            member.read(.data, data_offset, copies[index][0..buffer.len]) catch continue;
            readable[index] = true;
        }
        for (0..self.member_count) |left| {
            if (!readable[left]) continue;
            for (left + 1..self.member_count) |right| {
                if (readable[right] and std.mem.eql(
                    u8,
                    copies[left][0..buffer.len],
                    copies[right][0..buffer.len],
                )) {
                    @memcpy(buffer, copies[left][0..buffer.len]);
                    return;
                }
            }
        }
        return error.ReplicaQuorumUnavailable;
    }

    pub fn program(self: *PoolBlockDevice, block: u32, offset: u32, data: []const u8) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        const data_offset = try self.position(block, offset, data.len);
        var first_error: ?anyerror = null;
        for (self.members[0..self.member_count]) |member| {
            member.write(.data, data_offset, data) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        if (first_error) |err| {
            self.freezeWrites();
            return err;
        }
    }

    pub fn sync(self: *PoolBlockDevice) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        var first_error: ?anyerror = null;
        for (self.members[0..self.member_count]) |member| {
            member.sync() catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        if (first_error) |err| {
            self.freezeWrites();
            return err;
        }
    }

    pub fn writeHeaderDurable(self: *PoolBlockDevice, offset: u64, header: container.Header) !void {
        if (offset != container.header_a_offset and offset != container.header_b_offset)
            return error.InvalidHeaderOffset;
        if (self.isWriteFrozen()) return error.WriteFrozen;
        const encoded = header.encode();
        var first_error: ?anyerror = null;
        for (self.members[0..self.member_count]) |member| {
            member.writeDurable(.metadata, offset, &encoded) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        if (first_error) |err| {
            self.freezeWrites();
            return err;
        }
    }

    pub fn readHeader(self: *PoolBlockDevice) !container.Header {
        var headers: [max_replica_count]?container.Header = @splat(null);
        for (self.members[0..self.member_count], 0..) |member, index|
            headers[index] = readMemberHeader(member) catch null;
        if (self.kind == .unprotected) return headers[0] orelse error.NoValidPoolVolumeHeader;
        for (0..self.member_count) |left| {
            const left_header = headers[left] orelse continue;
            const left_identity = volumeIdentity(left_header);
            for (left + 1..self.member_count) |right| {
                const right_header = headers[right] orelse continue;
                if (std.mem.eql(u8, &left_identity, &volumeIdentity(right_header)))
                    return if (right_header.sequence > left_header.sequence) right_header else left_header;
            }
        }
        for (headers, 0..) |maybe_header, ready_index| {
            const header = maybe_header orelse continue;
            const identity = volumeIdentity(header);
            for (self.members[0..self.member_count], 0..) |member, member_index| {
                if (member_index == ready_index) continue;
                if (try memberHeaderState(member, identity) != .creating) break;
            } else return header;
        }
        return error.VolumeHeaderQuorumUnavailable;
    }

    pub fn canInitializeVolume(self: *PoolBlockDevice, allocator: std.mem.Allocator) !bool {
        var bytes: [container.header_size]u8 = undefined;
        var volume_identity: ?[container.header_size]u8 = null;
        var creating_found = false;
        var invalid_found = false;
        var ready_members: usize = 0;
        for (self.members[0..self.member_count]) |member| {
            var member_ready = false;
            for ([_]u64{ container.header_a_offset, container.header_b_offset }) |offset| {
                try member.read(.metadata, offset, &bytes);
                if (std.mem.allEqual(u8, &bytes, 0)) continue;
                const header = container.Header.decode(&bytes) catch {
                    invalid_found = true;
                    continue;
                };
                const identity = volumeIdentity(header);
                if (volume_identity) |expected| {
                    if (!std.mem.eql(u8, &expected, &identity)) return false;
                } else {
                    volume_identity = identity;
                }
                switch (header.state) {
                    .creating => creating_found = true,
                    .ready => member_ready = true,
                }
            }
            ready_members += @intFromBool(member_ready);
        }
        if (ready_members != 0) return false;
        if (creating_found) return true;
        if (invalid_found) return false;

        const buffer = try allocator.alloc(u8, 1024 * 1024);
        defer allocator.free(buffer);
        for (self.members[0..self.member_count]) |member| {
            var offset: u64 = 0;
            while (offset < member.header().data.length) {
                const amount: usize = @intCast(@min(
                    @as(u64, buffer.len),
                    member.header().data.length - offset,
                ));
                try member.read(.data, offset, buffer[0..amount]);
                if (!std.mem.allEqual(u8, buffer[0..amount], 0)) return false;
                offset += amount;
            }
        }
        return true;
    }

    pub fn prepareWritableReplicas(self: *PoolBlockDevice, allocator: std.mem.Allocator) !void {
        if (self.kind == .unprotected) return;
        const expected_header = self.volume_header;
        const expected_header_identity = volumeIdentity(expected_header);
        var header_states: [max_replica_count]MemberHeaderState = undefined;
        for (self.members[0..self.member_count], 0..) |member, index|
            header_states[index] = try memberHeaderState(member, expected_header_identity);
        const buffers = try allocator.alloc([1024 * 1024]u8, self.member_count);
        defer allocator.free(buffers);
        const logical_size = @as(u64, self.block_size) * self.block_count;
        var offset: u64 = 0;
        while (offset < logical_size) {
            const amount: usize = @intCast(@min(@as(u64, 1024 * 1024), logical_size - offset));
            for (self.members[0..self.member_count], 0..) |member, index|
                try member.read(.data, offset, buffers[index][0..amount]);
            for (buffers[1..self.member_count]) |buffer| {
                if (!std.mem.eql(u8, buffers[0][0..amount], buffer[0..amount]))
                    return error.ReplicaDivergence;
            }
            offset += amount;
        }
        var repaired_header = expected_header;
        repaired_header.state = .ready;
        repaired_header.sequence = 2;
        for (self.members[0..self.member_count], header_states[0..self.member_count]) |member, state| {
            if (state == .ready) continue;
            try member.writeDurable(.metadata, container.header_b_offset, &repaired_header.encode());
            repaired_header.sequence = 3;
            try member.writeDurable(.metadata, container.header_a_offset, &repaired_header.encode());
            repaired_header.sequence = 2;
        }
    }

    pub fn isWriteFrozen(self: *const PoolBlockDevice) bool {
        return self.write_frozen.load(.acquire);
    }

    pub fn configure(self: *PoolBlockDevice, header: container.Header) c.struct_lfs_config {
        var config: c.struct_lfs_config = std.mem.zeroes(c.struct_lfs_config);
        config.context = self;
        config.read = readCallback;
        config.prog = programCallback;
        config.erase = eraseCallback;
        config.sync = syncCallback;
        config.lock = lockCallback;
        config.unlock = unlockCallback;
        config.read_size = header.read_size;
        config.prog_size = header.prog_size;
        config.block_size = header.block_size;
        config.block_count = header.block_count;
        config.block_cycles = -1;
        config.cache_size = header.block_size;
        config.lookahead_size = lookaheadSize(header.block_count);
        config.name_max = header.name_max;
        config.file_max = header.file_max;
        config.attr_max = header.attr_max;
        return config;
    }

    fn freezeWrites(self: *PoolBlockDevice) void {
        self.write_frozen.store(true, .release);
    }

    fn position(self: *const PoolBlockDevice, block: u32, offset: u32, len: usize) !u64 {
        if (block >= self.block_count or offset > self.block_size) return error.OutOfBounds;
        if (len > self.block_size - offset) return error.OutOfBounds;
        const block_offset = std.math.mul(u64, block, self.block_size) catch return error.OutOfBounds;
        return std.math.add(u64, block_offset, offset) catch return error.OutOfBounds;
    }

    fn fromConfig(config: *const c.struct_lfs_config) *PoolBlockDevice {
        return @ptrCast(@alignCast(config.context.?));
    }

    fn readCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t, offset: c.lfs_off_t, raw: ?*anyopaque, size: c.lfs_size_t) callconv(.c) c_int {
        const buffer = @as([*]u8, @ptrCast(raw.?))[0..size];
        fromConfig(config.?).read(block, offset, buffer) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn programCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t, offset: c.lfs_off_t, raw: ?*const anyopaque, size: c.lfs_size_t) callconv(.c) c_int {
        const data = @as([*]const u8, @ptrCast(raw.?))[0..size];
        fromConfig(config.?).program(block, offset, data) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn eraseCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t) callconv(.c) c_int {
        const self = fromConfig(config.?);
        if (block >= self.block_count) return c.LFS_ERR_IO;
        return 0;
    }

    fn syncCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        fromConfig(config.?).sync() catch return c.LFS_ERR_IO;
        return 0;
    }

    fn lockCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        const self = fromConfig(config.?);
        self.mutex.lock(self.io) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn unlockCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        const self = fromConfig(config.?);
        self.mutex.unlock(self.io);
        return 0;
    }
};

fn readMemberHeader(member: *member_api.Member) !container.Header {
    var a_bytes: [container.header_size]u8 = undefined;
    var b_bytes: [container.header_size]u8 = undefined;
    try member.read(.metadata, container.header_a_offset, &a_bytes);
    try member.read(.metadata, container.header_b_offset, &b_bytes);
    const a = container.Header.decode(&a_bytes) catch null;
    const b = container.Header.decode(&b_bytes) catch null;
    const selected = if (a) |a_header|
        if (b) |b_header| if (b_header.sequence > a_header.sequence) b_header else a_header else a_header
    else if (b) |b_header|
        b_header
    else
        return error.NoValidPoolVolumeHeader;
    if (selected.state != .ready) return error.IncompletePoolVolume;
    if (selected.logical_size > member.header().logical_capacity) return error.TruncatedPoolData;
    return selected;
}

const MemberHeaderState = enum { creating, ready };

fn memberHeaderState(member: *member_api.Member, expected_identity: [container.header_size]u8) !MemberHeaderState {
    var bytes: [container.header_size]u8 = undefined;
    var creating_found = false;
    var ready_found = false;
    for ([_]u64{ container.header_a_offset, container.header_b_offset }) |offset| {
        try member.read(.metadata, offset, &bytes);
        if (std.mem.allEqual(u8, &bytes, 0)) continue;
        const header = container.Header.decode(&bytes) catch continue;
        if (!std.mem.eql(u8, &expected_identity, &volumeIdentity(header)))
            return error.ReplicaHeaderDivergence;
        switch (header.state) {
            .creating => creating_found = true,
            .ready => ready_found = true,
        }
    }
    if (ready_found) return .ready;
    if (creating_found) return .creating;
    return error.NoValidPoolVolumeHeader;
}

fn volumeIdentity(source: container.Header) [container.header_size]u8 {
    var header = source;
    header.sequence = 0;
    header.state = .creating;
    return header.encode();
}

fn lookaheadSize(block_count: u32) u32 {
    const bytes = std.math.divCeil(u32, block_count, 8) catch unreachable;
    return @max(8, @min(4096, std.mem.alignForward(u32, bytes, 8)));
}

test "replicated reads require two matching members" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storages: [3]member_api.Storage = undefined;
    for (&storages, 0..) |*storage, index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "member-{d}", .{index});
        storage.* = try member_api.Storage.createFile(std.testing.io, tmp.dir, name, 4 * 1024 * 1024);
    }
    const outcome = try @import("pool_provision.zig").create(
        std.testing.io,
        std.testing.allocator,
        &storages,
        .{ .protection = .replicated, .label = "block-device" },
    );
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.PartialPoolCreation,
    };
    defer provisioned.deinit();
    var members: [3]*member_api.Member = undefined;
    for (&members, 0..) |*member, index| member.* = &provisioned.members[index];
    const header = try container.Header.init(std.testing.io, 1024 * 1024, "Pool");
    var device = try PoolBlockDevice.init(std.testing.io, &members, provisioned.genesis.layout, header);
    try std.testing.expect(try device.canInitializeVolume(std.testing.allocator));
    try provisioned.members[0].writeDurable(.data, 0, "existing");
    try std.testing.expect(!try device.canInitializeVolume(std.testing.allocator));
    try provisioned.members[0].writeDurable(.data, 0, &@as([8]u8, @splat(0)));
    try std.testing.expect(try device.canInitializeVolume(std.testing.allocator));
    try provisioned.members[0].writeDurable(.metadata, container.header_a_offset, &header.encode());
    try std.testing.expect(try device.canInitializeVolume(std.testing.allocator));
    var ready_header = header;
    ready_header.state = .ready;
    try provisioned.members[0].writeDurable(.metadata, container.header_a_offset, &ready_header.encode());
    try std.testing.expect(!try device.canInitializeVolume(std.testing.allocator));
    try provisioned.members[1].writeDurable(.metadata, container.header_a_offset, &header.encode());
    try provisioned.members[2].writeDurable(.metadata, container.header_a_offset, &header.encode());
    try std.testing.expect(!try device.canInitializeVolume(std.testing.allocator));
    try std.testing.expectEqualSlices(u8, &volumeIdentity(ready_header), &volumeIdentity(try device.readHeader()));
    try device.prepareWritableReplicas(std.testing.allocator);
    for (provisioned.members) |*member| {
        try member.writeDurable(.metadata, container.header_a_offset, &ready_header.encode());
        try member.writeDurable(.metadata, container.header_b_offset, &ready_header.encode());
    }
    try device.program(0, 0, "replicated");
    try device.program(0, 128, "offset");
    try device.sync();
    var newer_header = ready_header;
    newer_header.sequence += 1;
    try provisioned.members[2].writeDurable(.metadata, container.header_a_offset, &newer_header.encode());
    try device.prepareWritableReplicas(std.testing.allocator);
    var divergent_header = newer_header;
    divergent_header.uuid[0] ^= 1;
    try provisioned.members[2].writeDurable(.metadata, container.header_a_offset, &divergent_header.encode());
    try provisioned.members[2].writeDurable(.metadata, container.header_b_offset, &divergent_header.encode());
    try std.testing.expectError(error.ReplicaHeaderDivergence, device.prepareWritableReplicas(std.testing.allocator));
    try provisioned.members[2].writeDurable(.metadata, container.header_a_offset, &ready_header.encode());
    try provisioned.members[2].writeDurable(.metadata, container.header_b_offset, &ready_header.encode());
    var fault: member_api.FaultController = .{ .fail_write_at = 0 };
    provisioned.members[2].setFaultController(&fault);
    try std.testing.expectError(error.InjectedFault, device.program(1, 0, "failed-write"));
    try std.testing.expect(device.isWriteFrozen());
    try std.testing.expectError(error.WriteFrozen, device.program(2, 0, "frozen"));
    var failed_write_actual: [12]u8 = undefined;
    try device.read(1, 0, &failed_write_actual);
    try std.testing.expectEqualStrings("failed-write", &failed_write_actual);
    try provisioned.members[0].writeDurable(.data, 0, "corruption");
    var actual: [10]u8 = undefined;
    try device.read(0, 0, &actual);
    try std.testing.expectEqualStrings("replicated", &actual);
    var offset_actual: [6]u8 = undefined;
    try device.read(0, 128, &offset_actual);
    try std.testing.expectEqualStrings("offset", &offset_actual);
    try std.testing.expectError(error.ReplicaDivergence, device.prepareWritableReplicas(std.testing.allocator));
    var sync_device = try PoolBlockDevice.init(std.testing.io, &members, provisioned.genesis.layout, ready_header);
    try std.testing.expectError(error.WriteFrozen, sync_device.sync());
    try std.testing.expect(sync_device.isWriteFrozen());
}
