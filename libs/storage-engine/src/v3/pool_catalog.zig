const std = @import("std");
const codec = @import("codec.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const root_encoded_size: usize = 4096;
pub const volume_encoded_size: usize = 512;
pub const extent_run_encoded_size: usize = 64;
pub const page_size: u64 = 4096;
pub const max_volume_name_len: usize = 127;
pub const max_leaf_volume_count: u32 = 7;

const root_magic = [8]u8{ 'D', 'D', 'V', 'P', 'R', 'O', 'O', 'T' };
const volume_magic = [8]u8{ 'D', 'D', 'V', 'V', 'O', 'L', '1', 0 };
const root_format_version: u16 = 1;
const volume_format_version: u16 = 1;
const root_checksum_offset = root_encoded_size - @sizeOf(u32);
const volume_checksum_offset = volume_encoded_size - @sizeOf(u32);
const extent_checksum_offset = extent_run_encoded_size - @sizeOf(u32);
const root_reserved_offset: usize = 0x128;
const volume_name_offset: usize = 0x0a0;
const volume_name_end: usize = volume_name_offset + max_volume_name_len;
const extent_reserved_offset: usize = 0x024;

comptime {
    std.debug.assert(volume_name_end <= volume_checksum_offset);
    std.debug.assert(root_reserved_offset <= root_checksum_offset);
    std.debug.assert(extent_reserved_offset <= extent_checksum_offset);
}

pub const PageReference = struct {
    offset: u64 = 0,
    digest: codec.Digest = @splat(0),

    pub fn isNull(self: PageReference) bool {
        return self.offset == 0;
    }

    pub fn validate(self: PageReference) !void {
        const digest_is_zero = codec.isZero(&self.digest);
        if (self.offset == 0) {
            if (!digest_is_zero) return error.InvalidNullPageReference;
            return;
        }
        if (self.offset < 2 * page_size or self.offset % page_size != 0 or digest_is_zero)
            return error.InvalidPageReference;
        _ = std.math.add(u64, self.offset, page_size) catch return error.PageReferenceOverflow;
    }
};

pub const Root = struct {
    set_id: [16]u8,
    generation: u64,
    sequence: u64,
    previous_root_digest: codec.Digest,
    volume_tree_root: PageReference = .{},
    name_index_root: PageReference = .{},
    allocator_root: PageReference,
    retired_extent_root: PageReference = .{},
    metadata_allocator_root: PageReference,
    volume_count: u32 = 0,
    extent_size: u32,
    extent_format_version: u16 = 1,
    extent_entry_size: u16 = extent_run_encoded_size,
    flags: u32 = 0,
};

pub const VolumeState = enum(u16) {
    creating = 1,
    ready = 2,
    deleting = 3,
};

pub const Provisioning = enum(u16) {
    thin = 1,
    thick = 2,
};

pub const Name = struct {
    bytes: [max_volume_name_len]u8 = @splat(0),
    length: u8 = 0,

    pub fn init(value: []const u8) !Name {
        if (value.len == 0 or value.len > max_volume_name_len or !std.unicode.utf8ValidateSlice(value))
            return error.InvalidVolumeName;
        var result: Name = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.length = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.length];
    }

    pub fn validate(self: *const Name) !void {
        if (self.length == 0 or self.length > max_volume_name_len or
            !std.unicode.utf8ValidateSlice(self.slice()) or
            !codec.isZero(self.bytes[self.length..])) return error.InvalidVolumeName;
    }
};

pub const VolumeDescriptor = struct {
    volume_id: [16]u8,
    state: VolumeState,
    provisioning: Provisioning,
    created_ns: i64,
    logical_size: u64,
    header_page: PageReference,
    extent_map_root: PageReference = .{},
    allocated_extent_count: u64 = 0,
    reserved_extent_count: u64 = 0,
    extent_size: u32,
    name: Name,
    flags: u32 = 0,
};

pub const ExtentState = enum(u16) {
    reserved_zero = 1,
    mapped = 2,
};

pub const ExtentRun = struct {
    logical_start: u64,
    physical_start: u64,
    extent_count: u32,
    state: ExtentState,
    member_count: u16,
    member_slots: [3]u16,
    flags: u32 = 0,

    pub fn memberSlice(self: *const ExtentRun) []const u16 {
        return self.member_slots[0..self.member_count];
    }

    pub fn canMerge(left: ExtentRun, right: ExtentRun) bool {
        validateExtentRun(left) catch return false;
        validateExtentRun(right) catch return false;
        const logical_end = std.math.add(u64, left.logical_start, left.extent_count) catch return false;
        const physical_end = std.math.add(u64, left.physical_start, left.extent_count) catch return false;
        if (@as(u64, left.extent_count) + right.extent_count > std.math.maxInt(u32)) return false;
        return logical_end == right.logical_start and
            physical_end == right.physical_start and
            left.state == right.state and
            left.member_count == right.member_count and
            std.mem.eql(u16, left.memberSlice(), right.memberSlice()) and
            left.flags == right.flags;
    }
};

pub const MemberDataGeometry = struct {
    slot: u16,
    data_length: u64,
};

pub fn encodeRoot(root: Root) ![root_encoded_size]u8 {
    try validateRoot(root);
    var bytes: [root_encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &root_magic);
    codec.putInt(u16, &bytes, 0x008, root_format_version);
    codec.putInt(u16, &bytes, 0x00a, 0);
    codec.putInt(u32, &bytes, 0x00c, root_encoded_size);
    @memcpy(bytes[0x010..0x020], &root.set_id);
    codec.putInt(u64, &bytes, 0x020, root.generation);
    codec.putInt(u64, &bytes, 0x028, root.sequence);
    @memcpy(bytes[0x030..0x050], &root.previous_root_digest);
    putPageReference(&bytes, 0x050, root.volume_tree_root);
    putPageReference(&bytes, 0x078, root.name_index_root);
    putPageReference(&bytes, 0x0a0, root.allocator_root);
    putPageReference(&bytes, 0x0c8, root.retired_extent_root);
    putPageReference(&bytes, 0x0f0, root.metadata_allocator_root);
    codec.putInt(u32, &bytes, 0x118, root.volume_count);
    codec.putInt(u32, &bytes, 0x11c, root.extent_size);
    codec.putInt(u32, &bytes, 0x120, root.flags);
    codec.putInt(u16, &bytes, 0x124, root.extent_format_version);
    codec.putInt(u16, &bytes, 0x126, root.extent_entry_size);
    codec.putInt(u32, &bytes, root_checksum_offset, codec.crc32c(bytes[0..root_checksum_offset]));
    return bytes;
}

pub fn decodeRoot(bytes: *const [root_encoded_size]u8) !Root {
    if (codec.getInt(u32, bytes, root_checksum_offset) != codec.crc32c(bytes[0..root_checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &root_magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != root_format_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u16, bytes, 0x00a) != 0 or
        codec.getInt(u32, bytes, 0x00c) != root_encoded_size) return error.InvalidRootHeader;
    if (!codec.isZero(bytes[root_reserved_offset..root_checksum_offset])) return error.NonZeroReserved;
    const root: Root = .{
        .set_id = bytes[0x010..0x020].*,
        .generation = codec.getInt(u64, bytes, 0x020),
        .sequence = codec.getInt(u64, bytes, 0x028),
        .previous_root_digest = bytes[0x030..0x050].*,
        .volume_tree_root = getPageReference(bytes, 0x050),
        .name_index_root = getPageReference(bytes, 0x078),
        .allocator_root = getPageReference(bytes, 0x0a0),
        .retired_extent_root = getPageReference(bytes, 0x0c8),
        .metadata_allocator_root = getPageReference(bytes, 0x0f0),
        .volume_count = codec.getInt(u32, bytes, 0x118),
        .extent_size = codec.getInt(u32, bytes, 0x11c),
        .flags = codec.getInt(u32, bytes, 0x120),
        .extent_format_version = codec.getInt(u16, bytes, 0x124),
        .extent_entry_size = codec.getInt(u16, bytes, 0x126),
    };
    try validateRoot(root);
    return root;
}

pub fn rootDigest(root: Root) !codec.Digest {
    const bytes = try encodeRoot(root);
    return codec.blake3(bytes[0..root_checksum_offset]);
}

pub fn validateRoot(root: Root) !void {
    if (codec.isZero(&root.set_id)) return error.InvalidSetId;
    if (root.generation == 0 or root.sequence == 0) return error.InvalidRootSequence;
    if ((root.generation == 1) != codec.isZero(&root.previous_root_digest))
        return error.InvalidPreviousRootDigest;
    if (!std.math.isPowerOfTwo(root.extent_size) or root.extent_size < page_size)
        return error.InvalidExtentSize;
    if (root.extent_format_version != 1 or root.extent_entry_size != extent_run_encoded_size)
        return error.UnsupportedExtentFormat;
    try root.volume_tree_root.validate();
    try root.name_index_root.validate();
    try root.allocator_root.validate();
    try root.retired_extent_root.validate();
    try root.metadata_allocator_root.validate();
    const references = [_]PageReference{
        root.volume_tree_root,
        root.name_index_root,
        root.allocator_root,
        root.retired_extent_root,
        root.metadata_allocator_root,
    };
    for (references, 0..) |reference_value, index| {
        if (reference_value.isNull()) continue;
        for (references[0..index]) |previous| {
            if (!previous.isNull() and previous.offset == reference_value.offset)
                return error.AliasedRootPageReference;
        }
    }
    if (root.allocator_root.isNull() or root.metadata_allocator_root.isNull())
        return error.MissingAllocatorRoot;
    if (root.volume_count == 0) {
        if (!root.volume_tree_root.isNull() or !root.name_index_root.isNull()) return error.InvalidVolumeRoots;
    } else if (root.volume_tree_root.isNull() or root.name_index_root.isNull()) {
        return error.InvalidVolumeRoots;
    }
    if (root.volume_count > max_leaf_volume_count) return error.VolumePageCapacityExceeded;
    if (root.flags != 0) return error.InvalidRootFlags;
}

pub fn encodeVolume(descriptor: VolumeDescriptor) ![volume_encoded_size]u8 {
    try validateVolume(descriptor);
    var bytes: [volume_encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &volume_magic);
    codec.putInt(u16, &bytes, 0x008, volume_format_version);
    codec.putInt(u16, &bytes, 0x00a, @intFromEnum(descriptor.state));
    codec.putInt(u16, &bytes, 0x00c, @intFromEnum(descriptor.provisioning));
    codec.putInt(u16, &bytes, 0x00e, volume_name_offset);
    @memcpy(bytes[0x010..0x020], &descriptor.volume_id);
    codec.putInt(i64, &bytes, 0x020, descriptor.created_ns);
    codec.putInt(u64, &bytes, 0x028, descriptor.logical_size);
    putPageReference(&bytes, 0x030, descriptor.header_page);
    putPageReference(&bytes, 0x058, descriptor.extent_map_root);
    codec.putInt(u64, &bytes, 0x080, descriptor.allocated_extent_count);
    codec.putInt(u64, &bytes, 0x088, descriptor.reserved_extent_count);
    codec.putInt(u16, &bytes, 0x090, descriptor.name.length);
    codec.putInt(u16, &bytes, 0x092, 0);
    codec.putInt(u32, &bytes, 0x094, descriptor.flags);
    codec.putInt(u32, &bytes, 0x098, descriptor.extent_size);
    @memcpy(bytes[volume_name_offset..][0..descriptor.name.length], descriptor.name.slice());
    codec.putInt(u32, &bytes, volume_checksum_offset, codec.crc32c(bytes[0..volume_checksum_offset]));
    return bytes;
}

pub fn decodeVolume(bytes: *const [volume_encoded_size]u8) !VolumeDescriptor {
    if (codec.getInt(u32, bytes, volume_checksum_offset) != codec.crc32c(bytes[0..volume_checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &volume_magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != volume_format_version) return error.UnsupportedFormatVersion;
    if (codec.getInt(u16, bytes, 0x00e) != volume_name_offset or
        codec.getInt(u16, bytes, 0x092) != 0) return error.InvalidVolumeHeader;
    const name_length = codec.getInt(u16, bytes, 0x090);
    if (name_length == 0 or name_length > max_volume_name_len) return error.InvalidVolumeName;
    if (!codec.isZero(bytes[0x09c..volume_name_offset]) or
        !codec.isZero(bytes[volume_name_offset + name_length .. volume_checksum_offset]))
        return error.NonZeroReserved;
    const state = std.enums.fromInt(VolumeState, codec.getInt(u16, bytes, 0x00a)) orelse
        return error.InvalidVolumeState;
    const provisioning = std.enums.fromInt(Provisioning, codec.getInt(u16, bytes, 0x00c)) orelse
        return error.InvalidProvisioning;
    const descriptor: VolumeDescriptor = .{
        .volume_id = bytes[0x010..0x020].*,
        .state = state,
        .provisioning = provisioning,
        .created_ns = codec.getInt(i64, bytes, 0x020),
        .logical_size = codec.getInt(u64, bytes, 0x028),
        .header_page = getPageReference(bytes, 0x030),
        .extent_map_root = getPageReference(bytes, 0x058),
        .allocated_extent_count = codec.getInt(u64, bytes, 0x080),
        .reserved_extent_count = codec.getInt(u64, bytes, 0x088),
        .extent_size = codec.getInt(u32, bytes, 0x098),
        .name = try Name.init(bytes[volume_name_offset..][0..name_length]),
        .flags = codec.getInt(u32, bytes, 0x094),
    };
    try validateVolume(descriptor);
    return descriptor;
}

pub fn validateVolume(descriptor: VolumeDescriptor) !void {
    if (codec.isZero(&descriptor.volume_id)) return error.InvalidVolumeId;
    const maximum_size = @as(u64, std.math.maxInt(u32)) * page_size;
    if (descriptor.logical_size < 256 * 1024 or descriptor.logical_size > maximum_size or
        descriptor.logical_size % page_size != 0)
        return error.InvalidVolumeSize;
    if (!std.math.isPowerOfTwo(descriptor.extent_size) or descriptor.extent_size < page_size)
        return error.InvalidExtentSize;
    const logical_extent_count = try std.math.divCeil(u64, descriptor.logical_size, descriptor.extent_size);
    const committed_extent_count = std.math.add(
        u64,
        descriptor.allocated_extent_count,
        descriptor.reserved_extent_count,
    ) catch return error.ExtentCountOverflow;
    if (committed_extent_count > logical_extent_count) return error.InvalidExtentCount;
    if (descriptor.provisioning == .thick and committed_extent_count != logical_extent_count)
        return error.IncompleteThickReservation;
    try descriptor.header_page.validate();
    try descriptor.extent_map_root.validate();
    if (descriptor.header_page.isNull()) return error.MissingVolumeHeader;
    if ((descriptor.provisioning == .thick or descriptor.allocated_extent_count != 0) and
        descriptor.extent_map_root.isNull()) return error.MissingExtentMap;
    if (descriptor.provisioning == .thin and descriptor.allocated_extent_count == 0 and
        !descriptor.extent_map_root.isNull()) return error.UnexpectedExtentMap;
    try descriptor.name.validate();
    if (descriptor.flags != 0) return error.InvalidVolumeFlags;
}

pub fn encodeExtentRun(run: ExtentRun) ![extent_run_encoded_size]u8 {
    try validateExtentRun(run);
    var bytes: [extent_run_encoded_size]u8 = @splat(0);
    codec.putInt(u64, &bytes, 0x000, run.logical_start);
    codec.putInt(u64, &bytes, 0x008, run.physical_start);
    codec.putInt(u32, &bytes, 0x010, run.extent_count);
    codec.putInt(u16, &bytes, 0x014, @intFromEnum(run.state));
    codec.putInt(u16, &bytes, 0x016, run.member_count);
    for (run.memberSlice(), 0..) |slot, index|
        codec.putInt(u16, &bytes, 0x018 + index * @sizeOf(u16), slot);
    codec.putInt(u32, &bytes, 0x020, run.flags);
    codec.putInt(u32, &bytes, extent_checksum_offset, codec.crc32c(bytes[0..extent_checksum_offset]));
    return bytes;
}

pub fn decodeExtentRun(bytes: *const [extent_run_encoded_size]u8) !ExtentRun {
    if (codec.getInt(u32, bytes, extent_checksum_offset) != codec.crc32c(bytes[0..extent_checksum_offset]))
        return error.ChecksumMismatch;
    if (!codec.isZero(bytes[extent_reserved_offset..extent_checksum_offset])) return error.NonZeroReserved;
    const state = std.enums.fromInt(ExtentState, codec.getInt(u16, bytes, 0x014)) orelse
        return error.InvalidExtentState;
    const member_count = codec.getInt(u16, bytes, 0x016);
    if (member_count != 1 and member_count != 3) return error.InvalidExtentMemberCount;
    const used_slots_end = 0x018 + @as(usize, member_count) * @sizeOf(u16);
    if (!codec.isZero(bytes[used_slots_end..0x020]) or
        !codec.isZero(bytes[extent_reserved_offset..extent_checksum_offset]))
        return error.NonZeroReserved;
    var slots: [3]u16 = @splat(0);
    for (slots[0..member_count], 0..) |*slot, index|
        slot.* = codec.getInt(u16, bytes, 0x018 + index * @sizeOf(u16));
    const run: ExtentRun = .{
        .logical_start = codec.getInt(u64, bytes, 0x000),
        .physical_start = codec.getInt(u64, bytes, 0x008),
        .extent_count = codec.getInt(u32, bytes, 0x010),
        .state = state,
        .member_count = member_count,
        .member_slots = slots,
        .flags = codec.getInt(u32, bytes, 0x020),
    };
    try validateExtentRun(run);
    return run;
}

pub fn validateExtentRun(run: ExtentRun) !void {
    if (run.extent_count == 0) return error.EmptyExtentRun;
    _ = std.math.add(u64, run.logical_start, run.extent_count) catch return error.ExtentRunOverflow;
    _ = std.math.add(u64, run.physical_start, run.extent_count) catch return error.ExtentRunOverflow;
    if (run.member_count != 1 and run.member_count != 3) return error.InvalidExtentMemberCount;
    for (run.memberSlice(), 0..) |slot, index| {
        if (index != 0 and slot <= run.member_slots[index - 1]) return error.NonCanonicalMemberSlots;
    }
    for (run.member_slots[run.member_count..]) |slot| {
        if (slot != 0) return error.NonZeroMemberSlotPadding;
    }
    if (run.flags != 0) return error.InvalidExtentFlags;
}

pub fn validateExtentRuns(descriptor: VolumeDescriptor, runs: []const ExtentRun) !void {
    try validateVolume(descriptor);
    const logical_extent_count = try std.math.divCeil(u64, descriptor.logical_size, descriptor.extent_size);
    var allocated: u64 = 0;
    var reserved: u64 = 0;
    var logical_frontier: u64 = 0;
    for (runs, 0..) |run, index| {
        try validateExtentRun(run);
        const logical_end = try std.math.add(u64, run.logical_start, run.extent_count);
        if (logical_end > logical_extent_count) return error.ExtentOutsideVolume;
        if (index != 0 and run.logical_start < logical_frontier) return error.OverlappingLogicalExtents;
        if (index != 0 and ExtentRun.canMerge(runs[index - 1], run)) return error.NonCanonicalExtentRuns;
        for (runs[0..index]) |previous| {
            const previous_end = try std.math.add(u64, previous.physical_start, previous.extent_count);
            const physical_end = try std.math.add(u64, run.physical_start, run.extent_count);
            if (run.physical_start < previous_end and previous.physical_start < physical_end and
                shareMemberSlot(previous, run))
                return error.OverlappingPhysicalExtents;
        }
        switch (run.state) {
            .mapped => allocated = try std.math.add(u64, allocated, run.extent_count),
            .reserved_zero => {
                if (descriptor.provisioning == .thin) return error.ThinReservedZeroExtent;
                reserved = try std.math.add(u64, reserved, run.extent_count);
            },
        }
        if (descriptor.provisioning == .thick and run.logical_start != logical_frontier)
            return error.IncompleteThickExtentMap;
        logical_frontier = logical_end;
    }
    if (allocated != descriptor.allocated_extent_count) return error.AllocatedExtentCountMismatch;
    if (descriptor.provisioning == .thick) {
        if (reserved != descriptor.reserved_extent_count or logical_frontier != logical_extent_count)
            return error.ReservedExtentCountMismatch;
    }
}

pub fn validateVolumeForPool(
    root: Root,
    descriptor: VolumeDescriptor,
    runs: []const ExtentRun,
    layout: pool_layout.Layout,
    topology: pool_topology.Topology,
    member_geometry: []const MemberDataGeometry,
) !void {
    try validateRoot(root);
    try validateVolume(descriptor);
    try validateExtentRuns(descriptor, runs);
    try pool_layout.validate(layout);
    try pool_topology.validate(topology);
    _ = try pool_layout.dataAccess(layout, topology);
    if (!std.mem.eql(u8, &root.set_id, &topology.set_id)) return error.CatalogSetMismatch;
    if (root.extent_size != descriptor.extent_size or root.extent_size != layout.chunk_size)
        return error.ExtentSizeMismatch;

    const required_member_count: usize = switch (layout.kind) {
        .unprotected => 1,
        .replicated => 3,
        .erasure_coded => return error.ErasureCodingNotImplemented,
    };

    for (member_geometry, 0..) |geometry, index| {
        if (geometry.data_length % root.extent_size != 0) return error.InvalidMemberDataGeometry;
        for (member_geometry[0..index]) |previous| {
            if (previous.slot == geometry.slot) return error.DuplicateMemberGeometry;
        }
    }
    for (runs) |run| {
        if (run.member_count != required_member_count) return error.ExtentPlacementMismatch;
        const physical_end = try std.math.add(u64, run.physical_start, run.extent_count);
        const physical_end_bytes = std.math.mul(u64, physical_end, root.extent_size) catch
            return error.PhysicalExtentOverflow;
        for (run.memberSlice()) |slot| {
            const topology_member = findTopologyMember(&topology, slot) orelse
                return error.ExtentPlacementMismatch;
            if (topology_member.state == .joining) return error.ExtentPlacementMismatch;
            const geometry = findMemberGeometry(member_geometry, slot) orelse
                return error.MissingMemberGeometry;
            if (physical_end_bytes > geometry.data_length) return error.ExtentOutsideMemberData;
        }
    }
}

fn putPageReference(bytes: []u8, offset: usize, page_reference: PageReference) void {
    codec.putInt(u64, bytes, offset, page_reference.offset);
    @memcpy(bytes[offset + 8 ..][0..page_reference.digest.len], &page_reference.digest);
}

fn getPageReference(bytes: []const u8, offset: usize) PageReference {
    return .{
        .offset = codec.getInt(u64, bytes, offset),
        .digest = bytes[offset + 8 ..][0..@sizeOf(codec.Digest)].*,
    };
}

fn findMemberGeometry(geometry: []const MemberDataGeometry, slot: u16) ?MemberDataGeometry {
    for (geometry) |item| if (item.slot == slot) return item;
    return null;
}

fn findTopologyMember(topology: *const pool_topology.Topology, slot: u16) ?pool_topology.Member {
    for (topology.memberSlice()) |member| if (member.slot == slot) return member;
    return null;
}

fn shareMemberSlot(left: ExtentRun, right: ExtentRun) bool {
    for (left.memberSlice()) |left_slot| {
        for (right.memberSlice()) |right_slot| {
            if (left_slot == right_slot) return true;
        }
    }
    return false;
}

fn reference(offset: u64, value: u8) PageReference {
    return .{ .offset = offset, .digest = @splat(value) };
}

fn fixChecksum(bytes: anytype) void {
    const length = bytes.len;
    codec.putInt(u32, bytes, length - @sizeOf(u32), codec.crc32c(bytes[0 .. length - @sizeOf(u32)]));
}

test "catalog root round trips canonically and binds its digest" {
    const root: Root = .{
        .set_id = @splat(1),
        .generation = 7,
        .sequence = 9,
        .previous_root_digest = @splat(2),
        .volume_tree_root = reference(0x2000, 3),
        .name_index_root = reference(0x3000, 4),
        .allocator_root = reference(0x4000, 5),
        .retired_extent_root = reference(0x5000, 6),
        .metadata_allocator_root = reference(0x6000, 7),
        .volume_count = 2,
        .extent_size = 1024 * 1024,
    };
    const encoded = try encodeRoot(root);
    var expected_digest: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected_digest, "d7e23346b9f37e16ab11c79b25f03f7993b11a6ec43a3c40d4daf4dc247fd05e");
    try std.testing.expectEqualSlices(u8, &expected_digest, &codec.blake3(&encoded));
    try std.testing.expectEqualSlices(u8, &root_magic, encoded[0x000..0x008]);
    try std.testing.expectEqual(@as(u64, 7), codec.getInt(u64, &encoded, 0x020));
    try std.testing.expectEqual(@as(u64, 0x4000), codec.getInt(u64, &encoded, 0x0a0));
    try std.testing.expectEqual(@as(u32, 1024 * 1024), codec.getInt(u32, &encoded, 0x11c));
    try std.testing.expectEqual(@as(u16, 1), codec.getInt(u16, &encoded, 0x124));
    try std.testing.expectEqual(@as(u16, extent_run_encoded_size), codec.getInt(u16, &encoded, 0x126));
    try std.testing.expectEqual(root, try decodeRoot(&encoded));
    try std.testing.expectEqualSlices(u8, &codec.blake3(encoded[0..root_checksum_offset]), &(try rootDigest(root)));

    var corrupt = encoded;
    corrupt[root_reserved_offset] = 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeRoot(&corrupt));
    fixChecksum(&corrupt);
    try std.testing.expectError(error.NonZeroReserved, decodeRoot(&corrupt));
    corrupt = encoded;
    codec.putInt(u16, &corrupt, 0x124, 2);
    fixChecksum(&corrupt);
    try std.testing.expectError(error.UnsupportedExtentFormat, decodeRoot(&corrupt));
    corrupt = encoded;
    codec.putInt(u16, &corrupt, 0x126, 128);
    fixChecksum(&corrupt);
    try std.testing.expectError(error.UnsupportedExtentFormat, decodeRoot(&corrupt));
}

test "empty catalog root requires allocator roots" {
    const root: Root = .{
        .set_id = @splat(1),
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .allocator_root = reference(0x2000, 2),
        .metadata_allocator_root = reference(0x3000, 3),
        .extent_size = 1024 * 1024,
    };
    _ = try encodeRoot(root);
    var invalid = root;
    invalid.volume_count = 1;
    try std.testing.expectError(error.InvalidVolumeRoots, encodeRoot(invalid));
    invalid = root;
    invalid.allocator_root = .{};
    try std.testing.expectError(error.MissingAllocatorRoot, encodeRoot(invalid));
    invalid = root;
    invalid.volume_count = 1;
    invalid.volume_tree_root = reference(0x4000, 4);
    try std.testing.expectError(error.InvalidVolumeRoots, encodeRoot(invalid));
    invalid.name_index_root = reference(0x5000, 5);
    invalid.volume_count = max_leaf_volume_count + 1;
    try std.testing.expectError(error.VolumePageCapacityExceeded, encodeRoot(invalid));
    invalid = root;
    invalid.metadata_allocator_root = invalid.allocator_root;
    try std.testing.expectError(error.AliasedRootPageReference, encodeRoot(invalid));
    const overflowing_reference = reference(std.math.maxInt(u64) & ~(page_size - 1), 5);
    try std.testing.expectError(error.PageReferenceOverflow, overflowing_reference.validate());
}

test "volume descriptor round trips and rejects padding" {
    const descriptor: VolumeDescriptor = .{
        .volume_id = @splat(9),
        .state = .ready,
        .provisioning = .thin,
        .created_ns = 123,
        .logical_size = 16 * 1024 * 1024,
        .header_page = reference(0x7000, 7),
        .extent_map_root = reference(0x8000, 8),
        .allocated_extent_count = 4,
        .reserved_extent_count = 2,
        .extent_size = 1024 * 1024,
        .name = try Name.init("workspace"),
    };
    const encoded = try encodeVolume(descriptor);
    var expected_digest: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected_digest, "80e1959f338e52ab5446013837b6961f5b4a6ab20e970cdd84ae3f4f070f7878");
    try std.testing.expectEqualSlices(u8, &expected_digest, &codec.blake3(&encoded));
    try std.testing.expectEqualSlices(u8, &volume_magic, encoded[0x000..0x008]);
    try std.testing.expectEqual(@as(u16, @intFromEnum(Provisioning.thin)), codec.getInt(u16, &encoded, 0x00c));
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), codec.getInt(u64, &encoded, 0x028));
    try std.testing.expectEqual(@as(u32, 1024 * 1024), codec.getInt(u32, &encoded, 0x098));
    try std.testing.expectEqualStrings("workspace", encoded[volume_name_offset..][0.."workspace".len]);
    const decoded = try decodeVolume(&encoded);
    try std.testing.expectEqual(descriptor, decoded);
    try std.testing.expectEqualStrings("workspace", decoded.name.slice());

    var bytes = encoded;
    bytes[volume_name_end] = 1;
    fixChecksum(&bytes);
    try std.testing.expectError(error.NonZeroReserved, decodeVolume(&bytes));
    bytes = encoded;
    codec.putInt(u16, &bytes, 0x00c, 99);
    fixChecksum(&bytes);
    try std.testing.expectError(error.InvalidProvisioning, decodeVolume(&bytes));

    var invalid_name = descriptor;
    invalid_name.name.length = 128;
    try std.testing.expectError(error.InvalidVolumeName, encodeVolume(invalid_name));
}

test "volume extent runs enforce provisioning accounting and ownership" {
    var descriptor: VolumeDescriptor = .{
        .volume_id = @splat(9),
        .state = .ready,
        .provisioning = .thick,
        .created_ns = 123,
        .logical_size = 4 * 1024 * 1024,
        .header_page = reference(0x7000, 7),
        .extent_map_root = reference(0x8000, 8),
        .allocated_extent_count = 1,
        .reserved_extent_count = 3,
        .extent_size = 1024 * 1024,
        .name = try Name.init("thick"),
    };
    const thick_runs = [_]ExtentRun{
        .{
            .logical_start = 0,
            .physical_start = 10,
            .extent_count = 1,
            .state = .mapped,
            .member_count = 1,
            .member_slots = .{ 0, 0, 0 },
        },
        .{
            .logical_start = 1,
            .physical_start = 20,
            .extent_count = 3,
            .state = .reserved_zero,
            .member_count = 1,
            .member_slots = .{ 0, 0, 0 },
        },
    };
    try validateExtentRuns(descriptor, &thick_runs);

    descriptor.provisioning = .thin;
    descriptor.reserved_extent_count = 0;
    try std.testing.expectError(error.ThinReservedZeroExtent, validateExtentRuns(descriptor, &thick_runs));
    descriptor.allocated_extent_count = 4;
    const overlapping = [_]ExtentRun{
        .{
            .logical_start = 0,
            .physical_start = 10,
            .extent_count = 2,
            .state = .mapped,
            .member_count = 1,
            .member_slots = .{ 0, 0, 0 },
        },
        .{
            .logical_start = 2,
            .physical_start = 11,
            .extent_count = 2,
            .state = .mapped,
            .member_count = 1,
            .member_slots = .{ 0, 0, 0 },
        },
    };
    try std.testing.expectError(error.OverlappingPhysicalExtents, validateExtentRuns(descriptor, &overlapping));
    var disjoint = overlapping;
    disjoint[1].member_slots = .{ 1, 0, 0 };
    try validateExtentRuns(descriptor, &disjoint);
}

test "extent runs round trip merge and reject noncanonical slots" {
    const left: ExtentRun = .{
        .logical_start = 4,
        .physical_start = 20,
        .extent_count = 3,
        .state = .reserved_zero,
        .member_count = 3,
        .member_slots = .{ 1, 4, 9 },
    };
    const encoded = try encodeExtentRun(left);
    var expected_digest: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(&expected_digest, "abf259ab746b6646388226098ccca5a5901813ed0d3706355e178e83800c3895");
    try std.testing.expectEqualSlices(u8, &expected_digest, &codec.blake3(&encoded));
    try std.testing.expectEqual(@as(u64, 4), codec.getInt(u64, &encoded, 0x000));
    try std.testing.expectEqual(@as(u64, 20), codec.getInt(u64, &encoded, 0x008));
    try std.testing.expectEqual(@as(u16, 9), codec.getInt(u16, &encoded, 0x01c));
    try std.testing.expectEqual(left, try decodeExtentRun(&encoded));
    var right = left;
    right.logical_start = 7;
    right.physical_start = 23;
    right.extent_count = 2;
    try std.testing.expect(ExtentRun.canMerge(left, right));
    right.state = .mapped;
    try std.testing.expect(!ExtentRun.canMerge(left, right));
    var maximum = left;
    maximum.extent_count = std.math.maxInt(u32);
    right.logical_start = @as(u64, maximum.logical_start) + maximum.extent_count;
    right.physical_start = @as(u64, maximum.physical_start) + maximum.extent_count;
    right.extent_count = 1;
    right.state = maximum.state;
    try std.testing.expect(!ExtentRun.canMerge(maximum, right));

    var bytes = encoded;
    codec.putInt(u16, &bytes, 0x01a, 1);
    fixChecksum(&bytes);
    try std.testing.expectError(error.NonCanonicalMemberSlots, decodeExtentRun(&bytes));
    bytes = encoded;
    codec.putInt(u32, &bytes, 0x010, 0);
    fixChecksum(&bytes);
    try std.testing.expectError(error.EmptyExtentRun, decodeExtentRun(&bytes));
}

test "pool context binds extent geometry placement and capacity" {
    const member_format = @import("member_format.zig");
    const members = [_]pool_topology.Member{
        .{ .member_id = @splat(4), .slot = 9, .control_role = pool_topology.voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = @splat(5), .slot = 12, .role_flags = member_format.data_role },
        .{ .member_id = @splat(2), .slot = 1, .control_role = pool_topology.voter_role, .role_flags = member_format.known_role_flags },
        .{ .member_id = @splat(3), .slot = 4, .control_role = pool_topology.voter_role, .role_flags = member_format.known_role_flags },
    };
    const topology = try pool_topology.Topology.init(@splat(1), 1, @splat(0), &members);
    const layout = try pool_layout.Layout.init(.replicated, 1, 1, 1024 * 1024);
    const root: Root = .{
        .set_id = @splat(1),
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .volume_tree_root = reference(0x2000, 2),
        .name_index_root = reference(0x3000, 3),
        .allocator_root = reference(0x4000, 4),
        .metadata_allocator_root = reference(0x5000, 5),
        .volume_count = 1,
        .extent_size = 1024 * 1024,
    };
    const descriptor: VolumeDescriptor = .{
        .volume_id = @splat(9),
        .state = .ready,
        .provisioning = .thick,
        .created_ns = 123,
        .logical_size = 2 * 1024 * 1024,
        .header_page = reference(0x6000, 6),
        .extent_map_root = reference(0x7000, 7),
        .allocated_extent_count = 2,
        .extent_size = 1024 * 1024,
        .name = try Name.init("replicated"),
    };
    var run: ExtentRun = .{
        .logical_start = 0,
        .physical_start = 10,
        .extent_count = 2,
        .state = .mapped,
        .member_count = 3,
        .member_slots = .{ 1, 4, 9 },
    };
    const geometry = [_]MemberDataGeometry{
        .{ .slot = 1, .data_length = 64 * 1024 * 1024 },
        .{ .slot = 4, .data_length = 64 * 1024 * 1024 },
        .{ .slot = 9, .data_length = 64 * 1024 * 1024 },
        .{ .slot = 12, .data_length = 64 * 1024 * 1024 },
    };
    try validateVolumeForPool(root, descriptor, &.{run}, layout, topology, &geometry);
    var mismatched_descriptor = descriptor;
    mismatched_descriptor.provisioning = .thin;
    mismatched_descriptor.extent_size = 4096;
    try std.testing.expectError(
        error.ExtentSizeMismatch,
        validateVolumeForPool(root, mismatched_descriptor, &.{run}, layout, topology, &geometry),
    );
    run.member_slots = .{ 1, 4, 8 };
    try std.testing.expectError(
        error.ExtentPlacementMismatch,
        validateVolumeForPool(root, descriptor, &.{run}, layout, topology, &geometry),
    );
    run.member_slots = .{ 1, 4, 9 };
    run.physical_start = 63;
    try std.testing.expectError(
        error.ExtentOutsideMemberData,
        validateVolumeForPool(root, descriptor, &.{run}, layout, topology, &geometry),
    );
}
