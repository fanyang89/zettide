const std = @import("std");
const codec = @import("codec.zig");
const pool_catalog = @import("pool_catalog.zig");

pub const encoded_size: usize = pool_catalog.page_size;
pub const header_size: usize = 64;
pub const checksum_offset: usize = encoded_size - @sizeOf(u32);
pub const name_entry_size: usize = 160;
pub const physical_interval_entry_size: usize = 32;
pub const metadata_interval_entry_size: usize = 32;

const magic = [8]u8{ 'D', 'D', 'V', 'P', 'G', '0', '0', '1' };
const format_version: u16 = 1;

pub const Kind = enum(u16) {
    volume_index = 1,
    name_index = 2,
    extent_map = 3,
    physical_allocator = 4,
    retired_extents = 5,
    metadata_allocator = 6,
};

pub const Header = struct {
    kind: Kind,
    entry_count: u16,
    entry_size: u16,
    generation: u64,
    owner_id: [16]u8 = @splat(0),
};

pub const NameEntry = struct {
    volume_id: [16]u8,
    name: pool_catalog.Name,
};

pub const PhysicalInterval = struct {
    member_slot: u16,
    physical_start: u64,
    extent_count: u64,
    retired_generation: u64 = 0,
};

pub const MetadataInterval = struct {
    page_start: u64,
    page_count: u32,
    state: MetadataIntervalState = .free,
    retired_generation: u64 = 0,
};

pub const MetadataIntervalState = enum(u16) {
    free = 1,
    retired = 2,
};

pub const VolumeExtentMap = struct {
    volume_id: [16]u8,
    runs: []const pool_catalog.ExtentRun,
};

pub fn encodeVolumeIndex(
    generation: u64,
    descriptors: []const pool_catalog.VolumeDescriptor,
) ![encoded_size]u8 {
    var bytes = try beginPage(.volume_index, generation, @splat(0), pool_catalog.volume_encoded_size, descriptors.len);
    for (descriptors, 0..) |descriptor, index| {
        if (index != 0 and !lessId(descriptors[index - 1].volume_id, descriptor.volume_id))
            return error.NonCanonicalVolumeOrder;
        const encoded = try pool_catalog.encodeVolume(descriptor);
        @memcpy(entrySlice(&bytes, pool_catalog.volume_encoded_size, index), &encoded);
    }
    finishPage(&bytes);
    return bytes;
}

pub fn decodeVolumeIndex(
    bytes: *const [encoded_size]u8,
    output: []pool_catalog.VolumeDescriptor,
) ![]pool_catalog.VolumeDescriptor {
    const header = try decodeHeader(bytes, .volume_index);
    if (output.len < header.entry_count) return error.OutputTooSmall;
    for (output[0..header.entry_count], 0..) |*descriptor, index| {
        var encoded: [pool_catalog.volume_encoded_size]u8 = undefined;
        @memcpy(&encoded, entrySliceConst(bytes, header.entry_size, index));
        descriptor.* = try pool_catalog.decodeVolume(&encoded);
        if (index != 0 and !lessId(output[index - 1].volume_id, descriptor.volume_id))
            return error.NonCanonicalVolumeOrder;
    }
    return output[0..header.entry_count];
}

pub fn encodeNameIndex(generation: u64, entries: []const NameEntry) ![encoded_size]u8 {
    var bytes = try beginPage(.name_index, generation, @splat(0), name_entry_size, entries.len);
    for (entries, 0..) |entry, index| {
        try validateNameEntry(entry);
        if (index != 0 and !lessName(entries[index - 1].name.slice(), entry.name.slice()))
            return error.NonCanonicalNameOrder;
        encodeNameEntry(entrySlice(&bytes, name_entry_size, index), entry);
    }
    finishPage(&bytes);
    return bytes;
}

pub fn decodeNameIndex(bytes: *const [encoded_size]u8, output: []NameEntry) ![]NameEntry {
    const header = try decodeHeader(bytes, .name_index);
    if (output.len < header.entry_count) return error.OutputTooSmall;
    for (output[0..header.entry_count], 0..) |*entry, index| {
        entry.* = try decodeNameEntry(entrySliceConst(bytes, header.entry_size, index));
        if (index != 0 and !lessName(output[index - 1].name.slice(), entry.name.slice()))
            return error.NonCanonicalNameOrder;
    }
    return output[0..header.entry_count];
}

pub fn encodeExtentMap(
    generation: u64,
    volume_id: [16]u8,
    runs: []const pool_catalog.ExtentRun,
) ![encoded_size]u8 {
    if (codec.isZero(&volume_id)) return error.InvalidPageOwner;
    var bytes = try beginPage(.extent_map, generation, volume_id, pool_catalog.extent_run_encoded_size, runs.len);
    var logical_end: u64 = 0;
    for (runs, 0..) |run, index| {
        try pool_catalog.validateExtentRun(run);
        if (index != 0) {
            if (run.logical_start < logical_end) return error.OverlappingLogicalExtents;
            if (pool_catalog.ExtentRun.canMerge(runs[index - 1], run)) return error.NonCanonicalExtentRuns;
        }
        logical_end = try std.math.add(u64, run.logical_start, run.extent_count);
        const encoded = try pool_catalog.encodeExtentRun(run);
        @memcpy(entrySlice(&bytes, pool_catalog.extent_run_encoded_size, index), &encoded);
    }
    finishPage(&bytes);
    return bytes;
}

pub fn decodeExtentMap(
    bytes: *const [encoded_size]u8,
    volume_id: [16]u8,
    output: []pool_catalog.ExtentRun,
) ![]pool_catalog.ExtentRun {
    const header = try decodeHeader(bytes, .extent_map);
    if (!std.mem.eql(u8, &header.owner_id, &volume_id)) return error.PageOwnerMismatch;
    if (output.len < header.entry_count) return error.OutputTooSmall;
    var logical_end: u64 = 0;
    for (output[0..header.entry_count], 0..) |*run, index| {
        var encoded: [pool_catalog.extent_run_encoded_size]u8 = undefined;
        @memcpy(&encoded, entrySliceConst(bytes, header.entry_size, index));
        run.* = try pool_catalog.decodeExtentRun(&encoded);
        if (index != 0) {
            if (run.logical_start < logical_end) return error.OverlappingLogicalExtents;
            if (pool_catalog.ExtentRun.canMerge(output[index - 1], run.*)) return error.NonCanonicalExtentRuns;
        }
        logical_end = try std.math.add(u64, run.logical_start, run.extent_count);
    }
    return output[0..header.entry_count];
}

pub fn encodePhysicalIntervals(
    kind: Kind,
    generation: u64,
    intervals: []const PhysicalInterval,
) ![encoded_size]u8 {
    if (kind != .physical_allocator and kind != .retired_extents) return error.InvalidPageKind;
    var bytes = try beginPage(kind, generation, @splat(0), physical_interval_entry_size, intervals.len);
    for (intervals, 0..) |interval, index| {
        try validatePhysicalInterval(kind, generation, interval);
        if (index != 0) try validatePhysicalOrder(kind, intervals[index - 1], interval);
        encodePhysicalInterval(entrySlice(&bytes, physical_interval_entry_size, index), interval);
    }
    finishPage(&bytes);
    return bytes;
}

pub fn decodePhysicalIntervals(
    bytes: *const [encoded_size]u8,
    kind: Kind,
    output: []PhysicalInterval,
) ![]PhysicalInterval {
    if (kind != .physical_allocator and kind != .retired_extents) return error.InvalidPageKind;
    const header = try decodeHeader(bytes, kind);
    if (output.len < header.entry_count) return error.OutputTooSmall;
    for (output[0..header.entry_count], 0..) |*interval, index| {
        interval.* = try decodePhysicalInterval(kind, header.generation, entrySliceConst(bytes, header.entry_size, index));
        if (index != 0) try validatePhysicalOrder(kind, output[index - 1], interval.*);
    }
    return output[0..header.entry_count];
}

pub fn encodeMetadataAllocator(
    generation: u64,
    intervals: []const MetadataInterval,
) ![encoded_size]u8 {
    var bytes = try beginPage(.metadata_allocator, generation, @splat(0), metadata_interval_entry_size, intervals.len);
    for (intervals, 0..) |interval, index| {
        try validateMetadataInterval(generation, interval);
        if (index != 0) try validateMetadataOrder(intervals[index - 1], interval);
        encodeMetadataInterval(entrySlice(&bytes, metadata_interval_entry_size, index), interval);
    }
    finishPage(&bytes);
    return bytes;
}

pub fn decodeMetadataAllocator(
    bytes: *const [encoded_size]u8,
    output: []MetadataInterval,
) ![]MetadataInterval {
    const header = try decodeHeader(bytes, .metadata_allocator);
    if (output.len < header.entry_count) return error.OutputTooSmall;
    for (output[0..header.entry_count], 0..) |*interval, index| {
        interval.* = try decodeMetadataInterval(header.generation, entrySliceConst(bytes, header.entry_size, index));
        if (index != 0) try validateMetadataOrder(output[index - 1], interval.*);
    }
    return output[0..header.entry_count];
}

pub fn validateCatalogIndexes(
    root: pool_catalog.Root,
    descriptors: []const pool_catalog.VolumeDescriptor,
    names: []const NameEntry,
) !void {
    try pool_catalog.validateRoot(root);
    if (descriptors.len != @as(usize, root.volume_count) or names.len != @as(usize, root.volume_count))
        return error.CatalogIndexCountMismatch;
    for (names, 0..) |name, index| {
        try validateNameEntry(name);
        if (index != 0 and !lessName(names[index - 1].name.slice(), name.name.slice()))
            return error.NonCanonicalNameOrder;
    }
    for (descriptors, 0..) |descriptor, index| {
        _ = try pool_catalog.encodeVolume(descriptor);
        if (index != 0 and !lessId(descriptors[index - 1].volume_id, descriptor.volume_id))
            return error.NonCanonicalVolumeOrder;
        var match_count: usize = 0;
        for (names) |name| {
            if (std.mem.eql(u8, &descriptor.volume_id, &name.volume_id)) {
                if (!std.mem.eql(u8, descriptor.name.slice(), name.name.slice()))
                    return error.CatalogNameMismatch;
                match_count += 1;
            }
        }
        if (match_count != 1) return error.CatalogNameMismatch;
    }
}

pub fn validatePhysicalIntervalsForMembers(
    intervals: []const PhysicalInterval,
    extent_size: u32,
    members: []const pool_catalog.MemberDataGeometry,
) !void {
    if (!std.math.isPowerOfTwo(extent_size) or extent_size < pool_catalog.page_size)
        return error.InvalidExtentSize;
    for (members, 0..) |member, index| {
        if (member.data_length % extent_size != 0) return error.InvalidMemberDataGeometry;
        for (members[0..index]) |previous| {
            if (previous.slot == member.slot) return error.DuplicateMemberGeometry;
        }
    }
    for (intervals) |interval| {
        const member = findMemberGeometry(members, interval.member_slot) orelse
            return error.MissingMemberGeometry;
        const physical_end = try std.math.add(u64, interval.physical_start, interval.extent_count);
        const physical_end_bytes = std.math.mul(u64, physical_end, extent_size) catch
            return error.PhysicalExtentOverflow;
        if (physical_end_bytes > member.data_length) return error.ExtentOutsideMemberData;
    }
}

pub fn validateMetadataIntervalsForMembers(
    intervals: []const MetadataInterval,
    current_pages: []const pool_catalog.PageReference,
    recoverable_pages: []const pool_catalog.PageReference,
    member_metadata_lengths: []const u64,
) !void {
    if (member_metadata_lengths.len == 0) return error.MissingMemberGeometry;
    for (member_metadata_lengths) |metadata_length| {
        if (metadata_length < 3 * pool_catalog.page_size or metadata_length % pool_catalog.page_size != 0)
            return error.InvalidMemberMetadataGeometry;
    }
    for ([_][]const pool_catalog.PageReference{ current_pages, recoverable_pages }) |references| {
        for (references) |reference| {
            try reference.validate();
            if (reference.isNull()) continue;
            for (member_metadata_lengths) |metadata_length| {
                if (reference.offset + pool_catalog.page_size > metadata_length)
                    return error.MetadataPageOutsideMember;
            }
        }
    }
    for (intervals, 0..) |interval, index| {
        try validateMetadataInterval(std.math.maxInt(u64), interval);
        if (index != 0) try validateMetadataOrder(intervals[index - 1], interval);
        const page_end = try std.math.add(u64, interval.page_start, interval.page_count);
        const byte_end = try std.math.mul(u64, page_end, pool_catalog.page_size);
        for (member_metadata_lengths) |metadata_length| {
            if (byte_end > metadata_length) return error.MetadataIntervalOutsideMember;
        }
        for (current_pages) |reference| {
            if (reference.isNull()) continue;
            const current_page = reference.offset / pool_catalog.page_size;
            if (current_page >= interval.page_start and current_page < page_end)
                return error.MetadataPageStillReferenced;
        }
        if (interval.state == .free) {
            for (recoverable_pages) |reference| {
                if (reference.isNull()) continue;
                const recoverable_page = reference.offset / pool_catalog.page_size;
                if (recoverable_page >= interval.page_start and recoverable_page < page_end)
                    return error.MetadataPageStillReferenced;
            }
        }
    }
}

pub fn validatePhysicalOwnership(
    maps: []const VolumeExtentMap,
    free: []const PhysicalInterval,
    retired: []const PhysicalInterval,
) !void {
    for (free, 0..) |interval, index| {
        try validatePhysicalInterval(.physical_allocator, std.math.maxInt(u64), interval);
        if (index != 0) try validatePhysicalOrder(.physical_allocator, free[index - 1], interval);
    }
    for (retired, 0..) |interval, index| {
        try validatePhysicalInterval(.retired_extents, std.math.maxInt(u64), interval);
        if (index != 0) try validatePhysicalOrder(.retired_extents, retired[index - 1], interval);
    }
    for (maps, 0..) |map, map_index| {
        if (codec.isZero(&map.volume_id)) return error.InvalidVolumeId;
        for (maps[0..map_index]) |previous| {
            if (std.mem.eql(u8, &map.volume_id, &previous.volume_id)) return error.DuplicateVolumeExtentMap;
        }
        for (map.runs, 0..) |run, run_index| {
            try pool_catalog.validateExtentRun(run);
            for (map.runs[0..run_index]) |previous| {
                if (runsOverlap(previous, run)) return error.OverlappingPhysicalOwnership;
            }
            for (maps[0..map_index]) |previous_map| {
                for (previous_map.runs) |previous| {
                    if (runsOverlap(previous, run)) return error.OverlappingPhysicalOwnership;
                }
            }
            for (free) |interval| {
                if (runOverlapsInterval(run, interval)) return error.OverlappingPhysicalOwnership;
            }
            for (retired) |interval| {
                if (runOverlapsInterval(run, interval)) return error.OverlappingPhysicalOwnership;
            }
        }
    }
    for (free) |free_interval| {
        for (retired) |retired_interval| {
            if (intervalsOverlap(free_interval, retired_interval))
                return error.OverlappingPhysicalOwnership;
        }
    }
}

pub fn decodeHeader(bytes: *const [encoded_size]u8, expected_kind: Kind) !Header {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != format_version) return error.UnsupportedFormatVersion;
    const kind = std.enums.fromInt(Kind, codec.getInt(u16, bytes, 0x00a)) orelse
        return error.InvalidPageKind;
    if (kind != expected_kind) return error.UnexpectedPageKind;
    if (codec.getInt(u16, bytes, 0x00c) != 0 or codec.getInt(u16, bytes, 0x012) != header_size or
        codec.getInt(u32, bytes, 0x014) != 0 or !codec.isZero(bytes[0x030..header_size]))
        return error.InvalidPageHeader;
    const header: Header = .{
        .kind = kind,
        .entry_count = codec.getInt(u16, bytes, 0x00e),
        .entry_size = codec.getInt(u16, bytes, 0x010),
        .generation = codec.getInt(u64, bytes, 0x018),
        .owner_id = bytes[0x020..0x030].*,
    };
    if (header.generation == 0 or header.entry_size != entrySize(kind)) return error.InvalidPageHeader;
    if ((kind == .extent_map) != !codec.isZero(&header.owner_id)) return error.InvalidPageOwner;
    const used_end = try usedEnd(header.entry_size, header.entry_count);
    if (!codec.isZero(bytes[used_end..checksum_offset])) return error.NonZeroPagePadding;
    return header;
}

pub fn pageReference(offset: u64, bytes: *const [encoded_size]u8) !pool_catalog.PageReference {
    const reference: pool_catalog.PageReference = .{ .offset = offset, .digest = codec.blake3(bytes) };
    try reference.validate();
    return reference;
}

fn beginPage(
    kind: Kind,
    generation: u64,
    owner_id: [16]u8,
    entry_size: usize,
    entry_count: usize,
) ![encoded_size]u8 {
    if (generation == 0) return error.InvalidPageGeneration;
    if (entry_size != entrySize(kind)) return error.InvalidEntrySize;
    if ((kind == .extent_map) != !codec.isZero(&owner_id)) return error.InvalidPageOwner;
    if (entry_count > std.math.maxInt(u16)) return error.TooManyPageEntries;
    _ = try usedEnd(@intCast(entry_size), @intCast(entry_count));
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, format_version);
    codec.putInt(u16, &bytes, 0x00a, @intFromEnum(kind));
    codec.putInt(u16, &bytes, 0x00c, 0);
    codec.putInt(u16, &bytes, 0x00e, @intCast(entry_count));
    codec.putInt(u16, &bytes, 0x010, @intCast(entry_size));
    codec.putInt(u16, &bytes, 0x012, header_size);
    codec.putInt(u32, &bytes, 0x014, 0);
    codec.putInt(u64, &bytes, 0x018, generation);
    @memcpy(bytes[0x020..0x030], &owner_id);
    return bytes;
}

fn finishPage(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

fn entrySize(kind: Kind) u16 {
    return switch (kind) {
        .volume_index => pool_catalog.volume_encoded_size,
        .name_index => name_entry_size,
        .extent_map => pool_catalog.extent_run_encoded_size,
        .physical_allocator, .retired_extents => physical_interval_entry_size,
        .metadata_allocator => metadata_interval_entry_size,
    };
}

fn usedEnd(entry_size: u16, entry_count: u16) !usize {
    const body_size = std.math.mul(usize, entry_size, entry_count) catch return error.PageCapacityExceeded;
    const end = std.math.add(usize, header_size, body_size) catch return error.PageCapacityExceeded;
    if (end > checksum_offset) return error.PageCapacityExceeded;
    return end;
}

fn entrySlice(bytes: *[encoded_size]u8, size: usize, index: usize) []u8 {
    const start = header_size + size * index;
    return bytes[start..][0..size];
}

fn entrySliceConst(bytes: *const [encoded_size]u8, size: usize, index: usize) []const u8 {
    const start = header_size + size * index;
    return bytes[start..][0..size];
}

fn validateNameEntry(entry: NameEntry) !void {
    if (codec.isZero(&entry.volume_id)) return error.InvalidVolumeId;
    try entry.name.validate();
}

fn encodeNameEntry(bytes: []u8, entry: NameEntry) void {
    @memcpy(bytes[0x000..0x010], &entry.volume_id);
    codec.putInt(u16, bytes, 0x010, entry.name.length);
    @memcpy(bytes[0x020..][0..entry.name.length], entry.name.slice());
}

fn decodeNameEntry(bytes: []const u8) !NameEntry {
    const name_length = codec.getInt(u16, bytes, 0x010);
    if (name_length == 0 or name_length > pool_catalog.max_volume_name_len or
        !codec.isZero(bytes[0x012..0x020]) or !codec.isZero(bytes[0x020 + name_length ..]))
        return error.InvalidNameEntry;
    const entry: NameEntry = .{
        .volume_id = bytes[0x000..0x010].*,
        .name = try pool_catalog.Name.init(bytes[0x020..][0..name_length]),
    };
    try validateNameEntry(entry);
    return entry;
}

fn validatePhysicalInterval(kind: Kind, generation: u64, interval: PhysicalInterval) !void {
    if (interval.extent_count == 0) return error.EmptyPhysicalInterval;
    _ = std.math.add(u64, interval.physical_start, interval.extent_count) catch
        return error.PhysicalIntervalOverflow;
    switch (kind) {
        .physical_allocator => if (interval.retired_generation != 0) return error.InvalidRetiredGeneration,
        .retired_extents => if (interval.retired_generation == 0 or interval.retired_generation > generation)
            return error.InvalidRetiredGeneration,
        else => unreachable,
    }
}

fn validatePhysicalOrder(kind: Kind, previous: PhysicalInterval, current: PhysicalInterval) !void {
    if (current.member_slot < previous.member_slot) return error.NonCanonicalPhysicalIntervalOrder;
    if (current.member_slot != previous.member_slot) return;
    const previous_end = try std.math.add(u64, previous.physical_start, previous.extent_count);
    if (current.physical_start < previous_end) return error.OverlappingPhysicalIntervals;
    if (current.physical_start == previous_end and
        (kind == .physical_allocator or current.retired_generation == previous.retired_generation))
        return error.NonCanonicalPhysicalIntervals;
}

fn encodePhysicalInterval(bytes: []u8, interval: PhysicalInterval) void {
    codec.putInt(u16, bytes, 0x000, interval.member_slot);
    codec.putInt(u64, bytes, 0x008, interval.physical_start);
    codec.putInt(u64, bytes, 0x010, interval.extent_count);
    codec.putInt(u64, bytes, 0x018, interval.retired_generation);
}

fn decodePhysicalInterval(kind: Kind, generation: u64, bytes: []const u8) !PhysicalInterval {
    if (!codec.isZero(bytes[0x002..0x008])) return error.NonZeroReserved;
    const interval: PhysicalInterval = .{
        .member_slot = codec.getInt(u16, bytes, 0x000),
        .physical_start = codec.getInt(u64, bytes, 0x008),
        .extent_count = codec.getInt(u64, bytes, 0x010),
        .retired_generation = codec.getInt(u64, bytes, 0x018),
    };
    try validatePhysicalInterval(kind, generation, interval);
    return interval;
}

fn validateMetadataInterval(generation: u64, interval: MetadataInterval) !void {
    if (interval.page_start < 2 or interval.page_count == 0) return error.InvalidMetadataInterval;
    const page_end = std.math.add(u64, interval.page_start, interval.page_count) catch
        return error.MetadataIntervalOverflow;
    _ = std.math.mul(u64, page_end, pool_catalog.page_size) catch return error.MetadataIntervalOverflow;
    switch (interval.state) {
        .free => if (interval.retired_generation != 0) return error.InvalidRetiredGeneration,
        .retired => if (interval.retired_generation == 0 or interval.retired_generation > generation)
            return error.InvalidRetiredGeneration,
    }
}

fn validateMetadataOrder(previous: MetadataInterval, current: MetadataInterval) !void {
    const previous_end = try std.math.add(u64, previous.page_start, previous.page_count);
    if (current.page_start < previous_end) return error.OverlappingMetadataIntervals;
    if (current.page_start == previous_end and current.state == previous.state and
        current.retired_generation == previous.retired_generation)
        return error.NonCanonicalMetadataIntervals;
}

fn encodeMetadataInterval(bytes: []u8, interval: MetadataInterval) void {
    codec.putInt(u64, bytes, 0x000, interval.page_start);
    codec.putInt(u32, bytes, 0x008, interval.page_count);
    codec.putInt(u16, bytes, 0x00c, @intFromEnum(interval.state));
    codec.putInt(u64, bytes, 0x010, interval.retired_generation);
}

fn decodeMetadataInterval(generation: u64, bytes: []const u8) !MetadataInterval {
    const state = std.enums.fromInt(MetadataIntervalState, codec.getInt(u16, bytes, 0x00c)) orelse
        return error.InvalidMetadataIntervalState;
    if (!codec.isZero(bytes[0x00e..0x010]) or !codec.isZero(bytes[0x018..0x020]))
        return error.NonZeroReserved;
    const interval: MetadataInterval = .{
        .page_start = codec.getInt(u64, bytes, 0x000),
        .page_count = codec.getInt(u32, bytes, 0x008),
        .state = state,
        .retired_generation = codec.getInt(u64, bytes, 0x010),
    };
    try validateMetadataInterval(generation, interval);
    return interval;
}

fn lessId(left: [16]u8, right: [16]u8) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}

fn lessName(left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn findMemberGeometry(
    members: []const pool_catalog.MemberDataGeometry,
    slot: u16,
) ?pool_catalog.MemberDataGeometry {
    for (members) |member| {
        if (member.slot == slot) return member;
    }
    return null;
}

fn runsOverlap(left: pool_catalog.ExtentRun, right: pool_catalog.ExtentRun) bool {
    if (!rangesOverlap(left.physical_start, left.extent_count, right.physical_start, right.extent_count))
        return false;
    for (left.memberSlice()) |left_slot| {
        for (right.memberSlice()) |right_slot| {
            if (left_slot == right_slot) return true;
        }
    }
    return false;
}

fn runOverlapsInterval(run: pool_catalog.ExtentRun, interval: PhysicalInterval) bool {
    if (!rangesOverlap(run.physical_start, run.extent_count, interval.physical_start, interval.extent_count))
        return false;
    return std.mem.indexOfScalar(u16, run.memberSlice(), interval.member_slot) != null;
}

fn intervalsOverlap(left: PhysicalInterval, right: PhysicalInterval) bool {
    return left.member_slot == right.member_slot and
        rangesOverlap(left.physical_start, left.extent_count, right.physical_start, right.extent_count);
}

fn rangesOverlap(left_start: u64, left_count: anytype, right_start: u64, right_count: anytype) bool {
    const left_end = std.math.add(u64, left_start, @intCast(left_count)) catch return true;
    const right_end = std.math.add(u64, right_start, @intCast(right_count)) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn testDescriptor(value: u8, name: []const u8) !pool_catalog.VolumeDescriptor {
    return .{
        .volume_id = @splat(value),
        .state = .ready,
        .provisioning = .thin,
        .created_ns = value,
        .logical_size = 1024 * 1024,
        .header_page = .{ .offset = 0x2000, .digest = @splat(value) },
        .extent_size = 1024 * 1024,
        .name = try pool_catalog.Name.init(name),
    };
}

fn testRoot(volume_count: u32) pool_catalog.Root {
    return .{
        .set_id = @splat(1),
        .generation = 3,
        .sequence = 3,
        .previous_root_digest = @splat(2),
        .volume_tree_root = if (volume_count == 0) .{} else .{ .offset = 0x2000, .digest = @splat(3) },
        .name_index_root = if (volume_count == 0) .{} else .{ .offset = 0x3000, .digest = @splat(4) },
        .allocator_root = .{ .offset = 0x4000, .digest = @splat(5) },
        .metadata_allocator_root = .{ .offset = 0x5000, .digest = @splat(6) },
        .volume_count = volume_count,
        .extent_size = 1024 * 1024,
    };
}

test "catalog leaf pages round trip canonical entries" {
    const descriptors = [_]pool_catalog.VolumeDescriptor{
        try testDescriptor(1, "alpha"),
        try testDescriptor(2, "beta"),
    };
    const volume_page = try encodeVolumeIndex(3, &descriptors);
    var decoded_descriptors: [2]pool_catalog.VolumeDescriptor = undefined;
    try std.testing.expectEqualSlices(
        pool_catalog.VolumeDescriptor,
        &descriptors,
        try decodeVolumeIndex(&volume_page, &decoded_descriptors),
    );

    const names = [_]NameEntry{
        .{ .volume_id = @splat(1), .name = try pool_catalog.Name.init("alpha") },
        .{ .volume_id = @splat(2), .name = try pool_catalog.Name.init("beta") },
    };
    const name_page = try encodeNameIndex(3, &names);
    var decoded_names: [2]NameEntry = undefined;
    const actual_names = try decodeNameIndex(&name_page, &decoded_names);
    try std.testing.expectEqualStrings("alpha", actual_names[0].name.slice());
    try std.testing.expectEqualStrings("beta", actual_names[1].name.slice());

    const runs = [_]pool_catalog.ExtentRun{.{
        .logical_start = 0,
        .physical_start = 4,
        .extent_count = 2,
        .state = .mapped,
        .member_count = 1,
        .member_slots = .{ 7, 0, 0 },
    }};
    const extent_page = try encodeExtentMap(3, @splat(1), &runs);
    var decoded_runs: [1]pool_catalog.ExtentRun = undefined;
    try std.testing.expectEqualSlices(
        pool_catalog.ExtentRun,
        &runs,
        try decodeExtentMap(&extent_page, @splat(1), &decoded_runs),
    );
    try std.testing.expectEqualSlices(u8, &codec.blake3(&extent_page), &(try pageReference(0x2000, &extent_page)).digest);
}

test "allocator pages enforce canonical nonadjacent intervals" {
    const physical = [_]PhysicalInterval{
        .{ .member_slot = 1, .physical_start = 0, .extent_count = 4 },
        .{ .member_slot = 1, .physical_start = 8, .extent_count = 2 },
        .{ .member_slot = 3, .physical_start = 0, .extent_count = 10 },
    };
    const physical_page = try encodePhysicalIntervals(.physical_allocator, 1, &physical);
    var decoded_physical: [3]PhysicalInterval = undefined;
    try std.testing.expectEqualSlices(
        PhysicalInterval,
        &physical,
        try decodePhysicalIntervals(&physical_page, .physical_allocator, &decoded_physical),
    );
    var adjacent = physical;
    adjacent[1].physical_start = 4;
    try std.testing.expectError(
        error.NonCanonicalPhysicalIntervals,
        encodePhysicalIntervals(.physical_allocator, 1, &adjacent),
    );

    const metadata = [_]MetadataInterval{
        .{ .page_start = 2, .page_count = 3 },
        .{ .page_start = 5, .page_count = 2, .state = .retired, .retired_generation = 1 },
        .{ .page_start = 8, .page_count = 2 },
    };
    const metadata_page = try encodeMetadataAllocator(1, &metadata);
    var decoded_metadata: [3]MetadataInterval = undefined;
    try std.testing.expectEqualSlices(
        MetadataInterval,
        &metadata,
        try decodeMetadataAllocator(&metadata_page, &decoded_metadata),
    );

    const retired = [_]PhysicalInterval{
        .{ .member_slot = 1, .physical_start = 0, .extent_count = 4, .retired_generation = 2 },
        .{ .member_slot = 1, .physical_start = 4, .extent_count = 2, .retired_generation = 3 },
    };
    const retired_page = try encodePhysicalIntervals(.retired_extents, 3, &retired);
    var decoded_retired: [2]PhysicalInterval = undefined;
    try std.testing.expectEqualSlices(
        PhysicalInterval,
        &retired,
        try decodePhysicalIntervals(&retired_page, .retired_extents, &decoded_retired),
    );
    try std.testing.expectError(
        error.InvalidRetiredGeneration,
        encodePhysicalIntervals(.retired_extents, 1, &retired),
    );

    var invalid_metadata = metadata;
    invalid_metadata[1].retired_generation = 2;
    try std.testing.expectError(
        error.InvalidRetiredGeneration,
        encodeMetadataAllocator(1, &invalid_metadata),
    );
}

test "catalog indexes and physical ownership validate globally" {
    const descriptors = [_]pool_catalog.VolumeDescriptor{
        try testDescriptor(1, "alpha"),
        try testDescriptor(2, "beta"),
    };
    var names = [_]NameEntry{
        .{ .volume_id = @splat(1), .name = try pool_catalog.Name.init("alpha") },
        .{ .volume_id = @splat(2), .name = try pool_catalog.Name.init("beta") },
    };
    try validateCatalogIndexes(testRoot(2), &descriptors, &names);
    names[1].volume_id = @splat(1);
    try std.testing.expectError(error.CatalogNameMismatch, validateCatalogIndexes(testRoot(2), &descriptors, &names));

    const runs = [_]pool_catalog.ExtentRun{.{
        .logical_start = 0,
        .physical_start = 4,
        .extent_count = 2,
        .state = .mapped,
        .member_count = 1,
        .member_slots = .{ 1, 0, 0 },
    }};
    const maps = [_]VolumeExtentMap{.{ .volume_id = @splat(1), .runs = &runs }};
    const free = [_]PhysicalInterval{.{ .member_slot = 1, .physical_start = 8, .extent_count = 2 }};
    try validatePhysicalOwnership(&maps, &free, &.{});
    var overlapping_free = free;
    overlapping_free[0].physical_start = 5;
    try std.testing.expectError(
        error.OverlappingPhysicalOwnership,
        validatePhysicalOwnership(&maps, &overlapping_free, &.{}),
    );
}

test "allocator geometry rejects byte overflow and out of bounds ranges" {
    const members = [_]pool_catalog.MemberDataGeometry{.{
        .slot = 1,
        .data_length = 10 * 1024 * 1024,
    }};
    const outside = [_]PhysicalInterval{.{ .member_slot = 1, .physical_start = 9, .extent_count = 2 }};
    try std.testing.expectError(
        error.ExtentOutsideMemberData,
        validatePhysicalIntervalsForMembers(&outside, 1024 * 1024, &members),
    );
    const overflowing = [_]PhysicalInterval{.{
        .member_slot = 1,
        .physical_start = std.math.maxInt(u64) / (1024 * 1024),
        .extent_count = 1,
    }};
    try std.testing.expectError(
        error.PhysicalExtentOverflow,
        validatePhysicalIntervalsForMembers(&overflowing, 1024 * 1024, &members),
    );

    const metadata_overflow = [_]MetadataInterval{.{
        .page_start = std.math.maxInt(u64) / pool_catalog.page_size,
        .page_count = 2,
    }};
    try std.testing.expectError(
        error.MetadataIntervalOverflow,
        encodeMetadataAllocator(1, &metadata_overflow),
    );

    const current_pages = [_]pool_catalog.PageReference{.{ .offset = 3 * pool_catalog.page_size, .digest = @splat(1) }};
    const metadata_lengths = [_]u64{10 * pool_catalog.page_size};
    const metadata_free = [_]MetadataInterval{.{ .page_start = 2, .page_count = 2 }};
    try std.testing.expectError(
        error.MetadataPageStillReferenced,
        validateMetadataIntervalsForMembers(&metadata_free, &current_pages, &.{}, &metadata_lengths),
    );
    const metadata_retired = [_]MetadataInterval{.{
        .page_start = 3,
        .page_count = 1,
        .state = .retired,
        .retired_generation = 1,
    }};
    try validateMetadataIntervalsForMembers(&metadata_retired, &.{}, &current_pages, &metadata_lengths);
    try std.testing.expectError(
        error.MetadataIntervalOutsideMember,
        validateMetadataIntervalsForMembers(
            &.{.{ .page_start = 9, .page_count = 2 }},
            &.{},
            &.{},
            &metadata_lengths,
        ),
    );
}

test "catalog pages reject capacity corruption and wrong owner" {
    var descriptors: [8]pool_catalog.VolumeDescriptor = undefined;
    for (&descriptors, 0..) |*descriptor, index|
        descriptor.* = try testDescriptor(@intCast(index + 1), "volume");
    try std.testing.expectError(error.PageCapacityExceeded, encodeVolumeIndex(1, &descriptors));

    const extent_page = try encodeExtentMap(1, @splat(1), &.{});
    var runs: [1]pool_catalog.ExtentRun = undefined;
    try std.testing.expectError(error.PageOwnerMismatch, decodeExtentMap(&extent_page, @splat(2), &runs));
    var corrupt = extent_page;
    corrupt[checksum_offset] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeHeader(&corrupt, .extent_map));

    var invalid_name = try pool_catalog.Name.init("valid");
    invalid_name.length = pool_catalog.max_volume_name_len + 1;
    try std.testing.expectError(
        error.InvalidVolumeName,
        encodeNameIndex(1, &.{.{ .volume_id = @splat(1), .name = invalid_name }}),
    );
    invalid_name = try pool_catalog.Name.init("valid");
    invalid_name.bytes[invalid_name.length] = 1;
    try std.testing.expectError(
        error.InvalidVolumeName,
        encodeNameIndex(1, &.{.{ .volume_id = @splat(1), .name = invalid_name }}),
    );
}
