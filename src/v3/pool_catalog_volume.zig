const std = @import("std");
const codec = @import("codec.zig");
const member_api = @import("member.zig");
const pool_catalog = @import("pool_catalog.zig");
const pool_catalog_graph = @import("pool_catalog_graph.zig");
const pool_catalog_page = @import("pool_catalog_page.zig");
const pool_member_set = @import("pool_member_set.zig");
const pool_topology = @import("pool_topology.zig");

pub const VolumeMap = struct {
    descriptor: pool_catalog.VolumeDescriptor,
    runs: [pool_catalog_page.max_extent_run_count]pool_catalog.ExtentRun = undefined,
    run_count: usize,

    pub const Span = union(enum) {
        zero: usize,
        mapped: MappedSpan,
    };

    pub const MappedSpan = struct {
        physical_offset: u64,
        length: usize,
        member_count: u16,
        member_slots: [3]u16,
    };

    pub fn init(
        catalog: *const pool_catalog_graph.ValidatedCatalog,
        volume_id: [16]u8,
    ) !VolumeMap {
        for (catalog.descriptorSlice(), 0..) |descriptor, index| {
            if (!std.mem.eql(u8, &descriptor.volume_id, &volume_id)) continue;
            if (descriptor.state != .ready) return error.VolumeNotReady;
            const source_runs = catalog.extentSlice(index);
            var result: VolumeMap = .{
                .descriptor = descriptor,
                .run_count = source_runs.len,
            };
            @memcpy(result.runs[0..source_runs.len], source_runs);
            return result;
        }
        return error.VolumeNotFound;
    }

    pub fn logicalSize(self: *const VolumeMap) u64 {
        return self.descriptor.logical_size;
    }

    pub fn nextSpan(self: *const VolumeMap, offset: u64, maximum_length: usize) !Span {
        if (maximum_length == 0) return .{ .zero = 0 };
        if (offset >= self.descriptor.logical_size) return error.OutOfBounds;
        const available = self.descriptor.logical_size - offset;
        const requested: u64 = @intCast(maximum_length);
        const length: usize = @intCast(@min(available, requested));
        const extent_size = @as(u64, self.descriptor.extent_size);
        const logical_extent = offset / extent_size;
        const extent_offset = offset % extent_size;
        const span_length: usize = @intCast(@min(
            @as(u64, length),
            extent_size - extent_offset,
        ));

        for (self.runs[0..self.run_count]) |run| {
            if (logical_extent < run.logical_start) break;
            const run_end = run.logical_start + run.extent_count;
            if (logical_extent >= run_end) continue;
            if (run.state == .reserved_zero) return .{ .zero = span_length };
            const physical_extent = run.physical_start + logical_extent - run.logical_start;
            return .{ .mapped = .{
                .physical_offset = physical_extent * extent_size + extent_offset,
                .length = span_length,
                .member_count = run.member_count,
                .member_slots = run.member_slots,
            } };
        }
        return .{ .zero = span_length };
    }
};

pub const CatalogVolumeBackend = struct {
    allocator: std.mem.Allocator,
    set: *pool_member_set.PoolMemberSet,
    generation: u64,
    authority_history_digest: codec.Digest,
    root_digest: codec.Digest,
    map: VolumeMap,

    /// The caller owns `set` and must serialize its use for the backend's lifetime.
    pub fn open(
        allocator: std.mem.Allocator,
        set: *pool_member_set.PoolMemberSet,
        volume_id: [16]u8,
    ) !CatalogVolumeBackend {
        const bound = try loadBoundCatalog(set);
        return .{
            .allocator = allocator,
            .set = set,
            .generation = bound.generation,
            .authority_history_digest = bound.authority_history_digest,
            .root_digest = bound.root_digest,
            .map = try VolumeMap.init(&bound.catalog, volume_id),
        };
    }

    pub fn openWritable(
        allocator: std.mem.Allocator,
        lease: *CatalogDataLease,
        volume_id: [16]u8,
    ) !CatalogVolumeBackend {
        try lease.validate();
        return .{
            .allocator = allocator,
            .set = lease.set,
            .generation = lease.generation,
            .authority_history_digest = lease.authority_history_digest,
            .root_digest = lease.root_digest,
            .map = try VolumeMap.init(&lease.catalog, volume_id),
        };
    }

    pub fn logicalSize(self: *const CatalogVolumeBackend) u64 {
        return self.map.logicalSize();
    }

    pub fn read(self: *CatalogVolumeBackend, offset: u64, buffer: []u8) !void {
        const end = std.math.add(u64, offset, buffer.len) catch return error.OutOfBounds;
        if (end > self.logicalSize()) return error.OutOfBounds;
        try self.validateAuthority();
        if (buffer.len == 0) return;

        var position = offset;
        var completed: usize = 0;
        while (completed < buffer.len) {
            const span = try self.map.nextSpan(position, buffer.len - completed);
            const length = switch (span) {
                .zero => |value| value: {
                    @memset(buffer[completed..][0..value], 0);
                    break :value value;
                },
                .mapped => |value| value: {
                    try self.readMapped(value, buffer[completed..][0..value.length]);
                    break :value value.length;
                },
            };
            completed += length;
            position += length;
        }
        try self.validateAuthority();
    }

    pub fn write(
        self: *CatalogVolumeBackend,
        lease: *CatalogDataLease,
        offset: u64,
        bytes: []const u8,
    ) !void {
        const end = std.math.add(u64, offset, bytes.len) catch return error.OutOfBounds;
        if (end > self.logicalSize()) return error.OutOfBounds;
        try lease.validateFor(self);
        if (bytes.len == 0) return;

        var position = offset;
        var checked: usize = 0;
        while (checked < bytes.len) {
            const span = try self.map.nextSpan(position, bytes.len - checked);
            const mapped = switch (span) {
                .zero => return error.ExtentNotMapped,
                .mapped => |value| value,
            };
            try lease.validateClaims(mapped.member_slots[0..mapped.member_count]);
            checked += mapped.length;
            position += mapped.length;
        }

        position = offset;
        var completed: usize = 0;
        while (completed < bytes.len) {
            const mapped = (try self.map.nextSpan(position, bytes.len - completed)).mapped;
            try lease.writeMapped(mapped, bytes[completed..][0..mapped.length]);
            completed += mapped.length;
            position += mapped.length;
        }
        try lease.validateFor(self);
    }

    pub fn flush(self: *CatalogVolumeBackend, lease: *CatalogDataLease) !void {
        try lease.validateFor(self);
        try lease.flush();
        try lease.validateFor(self);
    }

    fn validateAuthority(self: *const CatalogVolumeBackend) !void {
        const authority = self.set.authority() orelse return error.MissingAuthority;
        if (!std.mem.eql(u8, &authority.history_digest, &self.authority_history_digest) or
            authority.generation != self.generation or
            !std.mem.eql(u8, &authority.data_root_digest, &self.root_digest))
            return error.PoolAuthorityChanged;
        if (self.set.dataAccess() == .unavailable) return error.DataReadUnavailable;
    }

    fn readMapped(self: *CatalogVolumeBackend, span: VolumeMap.MappedSpan, buffer: []u8) !void {
        var readers: [3]DataReader = undefined;
        for (span.member_slots[0..span.member_count], 0..) |slot, index| {
            const data_member = self.set.dataMemberForRead(slot) catch {
                readers[index] = .{ .context = self, .read_fn = readUnavailable };
                continue;
            };
            readers[index] = memberReader(data_member.member);
        }
        try readReplicas(
            self.allocator,
            readers[0..span.member_count],
            span.physical_offset,
            buffer,
        );
    }
};

pub const CatalogDataLease = struct {
    set: *pool_member_set.PoolMemberSet,
    generation: u64,
    authority_history_digest: codec.Digest,
    root_digest: codec.Digest,
    catalog: pool_catalog_graph.ValidatedCatalog,
    claims: [pool_topology.max_member_count]?ClaimedMember = @splat(null),
    claim_count: usize = 0,
    frozen: bool = false,
    released: bool = false,

    const ClaimedMember = struct {
        slot: u16,
        claim: member_api.DataClaim,
    };

    /// The caller owns `set` and must serialize authority changes with this lease.
    pub fn acquire(set: *pool_member_set.PoolMemberSet) !CatalogDataLease {
        if (set.controlWriteReady() == null or set.dataAccess() != .read_write)
            return error.DataWriteUnavailable;
        const bound = try loadBoundCatalog(set);
        var result: CatalogDataLease = .{
            .set = set,
            .generation = bound.generation,
            .authority_history_digest = bound.authority_history_digest,
            .root_digest = bound.root_digest,
            .catalog = bound.catalog,
        };
        errdefer result.releaseClaims();

        var slots: [pool_topology.max_member_count]u16 = undefined;
        var slot_count: usize = 0;
        for (result.catalog.descriptorSlice(), 0..) |_, volume_index| {
            for (result.catalog.extentSlice(volume_index)) |run| {
                if (run.state != .mapped) continue;
                for (run.memberSlice()) |slot| try insertSlot(&slots, &slot_count, slot);
            }
        }
        for (slots[0..slot_count]) |slot| {
            const data_member = try set.dataMemberForWrite(slot);
            result.claims[result.claim_count] = .{
                .slot = slot,
                .claim = try data_member.member.claimData(),
            };
            result.claim_count += 1;
        }
        try result.validate();
        return result;
    }

    pub fn release(self: *CatalogDataLease) void {
        if (self.released) return;
        self.releaseClaims();
        self.released = true;
    }

    pub fn deinit(self: *CatalogDataLease) void {
        self.release();
    }

    fn releaseClaims(self: *CatalogDataLease) void {
        for (self.claims[0..self.claim_count]) |*maybe_claim| {
            if (maybe_claim.*) |*claimed| claimed.claim.release() catch unreachable;
            maybe_claim.* = null;
        }
        self.claim_count = 0;
    }

    fn validate(self: *const CatalogDataLease) !void {
        if (self.released) return error.DataLeaseReleased;
        if (self.frozen) return error.WriteFrozen;
        const authority = self.set.authority() orelse return error.MissingAuthority;
        if (!std.mem.eql(u8, &authority.history_digest, &self.authority_history_digest) or
            authority.generation != self.generation or
            !std.mem.eql(u8, &authority.data_root_digest, &self.root_digest))
            return error.PoolAuthorityChanged;
        if (self.set.controlWriteReady() == null or self.set.dataAccess() != .read_write)
            return error.DataWriteUnavailable;
    }

    fn validateFor(self: *const CatalogDataLease, backend: *const CatalogVolumeBackend) !void {
        try self.validate();
        if (self.set != backend.set or self.generation != backend.generation or
            !std.mem.eql(u8, &self.authority_history_digest, &backend.authority_history_digest) or
            !std.mem.eql(u8, &self.root_digest, &backend.root_digest))
            return error.DataLeaseMismatch;
    }

    fn validateClaims(self: *CatalogDataLease, slots: []const u16) !void {
        for (slots) |slot| _ = try self.claimForSlot(slot);
    }

    fn claimForSlot(self: *CatalogDataLease, slot: u16) !*member_api.DataClaim {
        for (self.claims[0..self.claim_count]) |*maybe_claim| {
            const claimed = if (maybe_claim.*) |*value| value else continue;
            if (claimed.slot == slot) return &claimed.claim;
        }
        return error.DataClaimUnavailable;
    }

    fn writeMapped(self: *CatalogDataLease, span: VolumeMap.MappedSpan, bytes: []const u8) !void {
        var first_error: ?anyerror = null;
        for (span.member_slots[0..span.member_count]) |slot| {
            const claim = self.claimForSlot(slot) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            claim.write(span.physical_offset, bytes) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| {
            self.freeze();
            return err;
        }
    }

    fn flush(self: *CatalogDataLease) !void {
        var first_error: ?anyerror = null;
        for (self.claims[0..self.claim_count]) |*maybe_claim| {
            const claimed = if (maybe_claim.*) |*value| value else continue;
            claimed.claim.sync() catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| {
            self.freeze();
            return err;
        }
    }

    fn freeze(self: *CatalogDataLease) void {
        self.frozen = true;
        self.set.revokeWriteReady();
        self.set.revokeDataAccess();
    }
};

const BoundCatalog = struct {
    generation: u64,
    authority_history_digest: codec.Digest,
    root_digest: codec.Digest,
    catalog: pool_catalog_graph.ValidatedCatalog,
};

fn loadBoundCatalog(set: *pool_member_set.PoolMemberSet) !BoundCatalog {
    const initial_authority = set.authority() orelse return error.MissingAuthority;
    if (initial_authority.generation == 0 or codec.isZero(&initial_authority.data_root_digest))
        return error.GenesisHasNoCatalogRoot;
    const catalog = try set.loadCatalog();
    const authority = set.authority() orelse return error.MissingAuthority;
    if (!std.mem.eql(u8, &initial_authority.history_digest, &authority.history_digest) or
        authority.generation != catalog.root.generation or
        !std.mem.eql(u8, &authority.data_root_digest, &(try pool_catalog.rootDigest(catalog.root))))
        return error.PoolAuthorityChanged;
    return .{
        .generation = authority.generation,
        .authority_history_digest = authority.history_digest,
        .root_digest = authority.data_root_digest,
        .catalog = catalog,
    };
}

fn insertSlot(slots: *[pool_topology.max_member_count]u16, count: *usize, slot: u16) !void {
    var index: usize = 0;
    while (index < count.* and slots[index] < slot) : (index += 1) {}
    if (index < count.* and slots[index] == slot) return;
    if (count.* == slots.len) return error.TooManyDataMembers;
    var move = count.*;
    while (move > index) : (move -= 1) slots[move] = slots[move - 1];
    slots[index] = slot;
    count.* += 1;
}

const DataReader = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, u64, []u8) anyerror!void,

    fn read(self: DataReader, offset: u64, buffer: []u8) !void {
        return self.read_fn(self.context, offset, buffer);
    }
};

fn memberReader(member: *member_api.Member) DataReader {
    return .{ .context = member, .read_fn = readMemberData };
}

fn readMemberData(context: *anyopaque, offset: u64, buffer: []u8) !void {
    const member: *member_api.Member = @ptrCast(@alignCast(context));
    return member.read(.data, offset, buffer);
}

fn readUnavailable(_: *anyopaque, _: u64, _: []u8) !void {
    return error.DataMemberUnavailable;
}

fn readReplicas(
    allocator: std.mem.Allocator,
    readers: []const DataReader,
    offset: u64,
    buffer: []u8,
) !void {
    if (readers.len != 1 and readers.len != 3) return error.InvalidExtentMemberCount;
    if (readers.len == 1) return readers[0].read(offset, buffer);

    const scratch_length = std.math.mul(usize, buffer.len, readers.len) catch return error.OutOfMemory;
    const scratch = try allocator.alloc(u8, scratch_length);
    defer allocator.free(scratch);
    var readable: [3]bool = @splat(false);
    for (readers, 0..) |reader, index| {
        const copy = scratch[index * buffer.len ..][0..buffer.len];
        reader.read(offset, copy) catch continue;
        readable[index] = true;
    }
    for (0..readers.len) |left| {
        if (!readable[left]) continue;
        const left_copy = scratch[left * buffer.len ..][0..buffer.len];
        for (left + 1..readers.len) |right| {
            if (!readable[right]) continue;
            const right_copy = scratch[right * buffer.len ..][0..buffer.len];
            if (std.mem.eql(u8, left_copy, right_copy)) {
                @memcpy(buffer, left_copy);
                return;
            }
        }
    }
    return error.ReplicaQuorumUnavailable;
}

fn testDescriptor(state: pool_catalog.VolumeState, provisioning: pool_catalog.Provisioning) !pool_catalog.VolumeDescriptor {
    return .{
        .volume_id = @splat(9),
        .state = state,
        .provisioning = provisioning,
        .created_ns = 1,
        .logical_size = 256 * 1024,
        .header_page = .{ .offset = 2 * pool_catalog.page_size, .digest = @splat(1) },
        .extent_map_root = .{ .offset = 3 * pool_catalog.page_size, .digest = @splat(2) },
        .allocated_extent_count = 2,
        .reserved_extent_count = 0,
        .extent_size = 4096,
        .name = try pool_catalog.Name.init("volume"),
    };
}

fn testCatalog(
    descriptor: pool_catalog.VolumeDescriptor,
    runs: []const pool_catalog.ExtentRun,
) pool_catalog_graph.ValidatedCatalog {
    var catalog: pool_catalog_graph.ValidatedCatalog = undefined;
    catalog.root.volume_count = 1;
    catalog.descriptors[0] = descriptor;
    catalog.extent_counts[0] = @intCast(runs.len);
    @memcpy(catalog.extent_runs[0][0..runs.len], runs);
    return catalog;
}

test "volume map resolves holes mapped extents and logical bounds" {
    const run: pool_catalog.ExtentRun = .{
        .logical_start = 1,
        .physical_start = 10,
        .extent_count = 2,
        .state = .mapped,
        .member_count = 3,
        .member_slots = .{ 2, 4, 7 },
    };
    const catalog = testCatalog(try testDescriptor(.ready, .thin), &.{run});
    const map = try VolumeMap.init(&catalog, @splat(9));

    const hole = try map.nextSpan(100, 8192);
    try std.testing.expectEqual(@as(usize, 3996), hole.zero);

    const mapped = (try map.nextSpan(4096 + 17, 8192)).mapped;
    try std.testing.expectEqual(@as(u64, 10 * 4096 + 17), mapped.physical_offset);
    try std.testing.expectEqual(@as(usize, 4096 - 17), mapped.length);
    try std.testing.expectEqual(@as(u16, 3), mapped.member_count);
    try std.testing.expectEqualSlices(u16, &.{ 2, 4, 7 }, mapped.member_slots[0..mapped.member_count]);

    const final = try map.nextSpan(map.logicalSize() - 100, 8192);
    try std.testing.expectEqual(@as(usize, 100), final.zero);
    try std.testing.expectError(error.OutOfBounds, map.nextSpan(map.logicalSize(), 1));
}

test "volume map treats reserved extents as zero" {
    var descriptor = try testDescriptor(.ready, .thick);
    descriptor.allocated_extent_count = 0;
    descriptor.reserved_extent_count = 64;
    const run: pool_catalog.ExtentRun = .{
        .logical_start = 0,
        .physical_start = 20,
        .extent_count = 64,
        .state = .reserved_zero,
        .member_count = 1,
        .member_slots = .{ 3, 0, 0 },
    };
    const catalog = testCatalog(descriptor, &.{run});
    const map = try VolumeMap.init(&catalog, @splat(9));
    try std.testing.expectEqual(@as(usize, 1024), (try map.nextSpan(512, 1024)).zero);
}

test "volume map requires a ready volume with matching identity" {
    const catalog = testCatalog(try testDescriptor(.creating, .thin), &.{});
    try std.testing.expectError(error.VolumeNotReady, VolumeMap.init(&catalog, @splat(9)));
    try std.testing.expectError(error.VolumeNotFound, VolumeMap.init(&catalog, @splat(8)));
}

const TestReader = struct {
    bytes: []const u8,
    fail: bool = false,

    fn dataReader(self: *TestReader) DataReader {
        return .{ .context = self, .read_fn = read };
    }

    fn read(context: *anyopaque, offset: u64, buffer: []u8) !void {
        const self: *TestReader = @ptrCast(@alignCast(context));
        if (self.fail) return error.InjectedFailure;
        const start = std.math.cast(usize, offset) orelse return error.OutOfBounds;
        if (start > self.bytes.len or buffer.len > self.bytes.len - start) return error.OutOfBounds;
        @memcpy(buffer, self.bytes[start..][0..buffer.len]);
    }
};

test "replicated read returns the matching pair" {
    var first: TestReader = .{ .bytes = "broken" };
    var second: TestReader = .{ .bytes = "stable" };
    var third: TestReader = .{ .bytes = "stable" };
    const readers = [_]DataReader{ first.dataReader(), second.dataReader(), third.dataReader() };
    var actual: [6]u8 = undefined;
    try readReplicas(std.testing.allocator, &readers, 0, &actual);
    try std.testing.expectEqualStrings("stable", &actual);
}

test "replicated read tolerates one unavailable copy" {
    var first: TestReader = .{ .bytes = "stable", .fail = true };
    var second: TestReader = .{ .bytes = "stable" };
    var third: TestReader = .{ .bytes = "stable" };
    const readers = [_]DataReader{ first.dataReader(), second.dataReader(), third.dataReader() };
    var actual: [4]u8 = undefined;
    try readReplicas(std.testing.allocator, &readers, 1, &actual);
    try std.testing.expectEqualStrings("tabl", &actual);
}

test "replicated read rejects disagreement without a quorum" {
    var first: TestReader = .{ .bytes = "first!" };
    var second: TestReader = .{ .bytes = "second" };
    var third: TestReader = .{ .bytes = "third!" };
    const readers = [_]DataReader{ first.dataReader(), second.dataReader(), third.dataReader() };
    var actual: [6]u8 = undefined;
    try std.testing.expectError(
        error.ReplicaQuorumUnavailable,
        readReplicas(std.testing.allocator, &readers, 0, &actual),
    );
}

test "unprotected read uses its sole member" {
    var source: TestReader = .{ .bytes = "payload" };
    const readers = [_]DataReader{source.dataReader()};
    var actual: [3]u8 = undefined;
    try readReplicas(std.testing.allocator, &readers, 2, &actual);
    try std.testing.expectEqualStrings("ylo", &actual);
}
