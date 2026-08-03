//! Stable full-block extent allocator page format.

const std = @import("std");
const store = @import("store.zig");

pub const format_version: u16 = 1;
pub const header_size: usize = 64;
pub const entry_size: usize = 96;
pub const checksum_size = std.crypto.hash.sha2.Sha256.digest_length;

const magic = "ZCAWAL\x00\x00";
const checksum_seed: [checksum_size]u8 = @splat(0);

pub const State = enum(u8) {
    free = 0,
    claimed = 1,
    live = 2,
    retired = 3,
};

pub const Kind = enum(u8) {
    none = 0,
    immutable = 1,
    data = 2,
};

pub const Entry = struct {
    state: State,
    kind: Kind,
    extent_index: u64,
    claim_id: [16]u8 = @splat(0),
    owner_id: [16]u8 = @splat(0),
    owner_incarnation: [16]u8 = @splat(0),
    base_generation: u64 = 0,
    owner_epoch: u64 = 0,
    transition_generation: u64 = 0,

    pub fn free(extent_index: u64) Entry {
        return .{ .state = .free, .kind = .none, .extent_index = extent_index };
    }

    pub fn validate(self: Entry) !void {
        const identity_present = !allZero(&self.claim_id) and
            !allZero(&self.owner_id) and
            !allZero(&self.owner_incarnation);
        switch (self.state) {
            .free => {
                if (self.kind != .none or
                    !allZero(&self.claim_id) or
                    !allZero(&self.owner_id) or
                    !allZero(&self.owner_incarnation) or
                    self.base_generation != 0 or
                    self.owner_epoch != 0 or
                    self.transition_generation != 0)
                {
                    return error.InvalidFreeEntry;
                }
            },
            .claimed => {
                if (self.kind == .none or
                    !identity_present or
                    self.owner_epoch == 0 or
                    self.base_generation == std.math.maxInt(u64) or
                    self.transition_generation != 0)
                {
                    return error.InvalidClaimedEntry;
                }
            },
            .live => {
                if (self.kind == .none or
                    !identity_present or
                    self.owner_epoch == 0 or
                    self.transition_generation <= self.base_generation)
                {
                    return error.InvalidLiveEntry;
                }
            },
            .retired => {
                if (self.kind == .none or
                    !identity_present or
                    self.owner_epoch == 0 or
                    self.transition_generation <= self.base_generation)
                {
                    return error.InvalidRetiredEntry;
                }
            },
        }
    }
};

pub fn validateTransition(previous: Entry, next: Entry) !void {
    try previous.validate();
    try next.validate();
    if (previous.extent_index != next.extent_index) return error.ExtentIndexChanged;
    switch (previous.state) {
        .free => if (next.state != .claimed) return error.InvalidEntryTransition,
        .claimed => switch (next.state) {
            .live, .retired => {
                try sameAllocation(previous, next);
                if (next.transition_generation <= previous.base_generation)
                    return error.InvalidEntryTransition;
            },
            else => return error.InvalidEntryTransition,
        },
        .live => {
            if (next.state != .retired) return error.InvalidEntryTransition;
            try sameAllocation(previous, next);
            if (next.transition_generation <= previous.transition_generation)
                return error.InvalidEntryTransition;
        },
        .retired => if (next.state != .free) return error.InvalidEntryTransition,
    }
}

pub const View = struct {
    bytes: []const u8,
    page_index: u64,
    generation: u64,
    first_extent: u64,
    entry_count: u32,

    pub fn entry(self: View, index: usize) !Entry {
        if (index >= self.entry_count) return error.EntryOutOfRange;
        return decodeEntry(self.bytes[entryOffset(index)..][0..entry_size]);
    }
};

pub fn entriesPerPage(logical_block_size: u32) !u32 {
    if (logical_block_size != 512 and logical_block_size != 4096)
        return error.UnsupportedLogicalBlockSize;
    return @intCast((logical_block_size - header_size - checksum_size) / entry_size);
}

pub fn encodePage(
    allocator: std.mem.Allocator,
    logical_block_size: u32,
    page_index: u64,
    generation: u64,
    total_extent_count: u64,
    entries: []const Entry,
) !store.OwnedBytes {
    const page_range = try pageRange(logical_block_size, page_index, total_extent_count);
    if (entries.len != page_range.count) return error.InvalidEntryCount;

    const bytes = try allocator.alloc(u8, logical_block_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], magic);
    putInt(u16, bytes, 8, format_version);
    putInt(u16, bytes, 12, header_size);
    putInt(u16, bytes, 14, entry_size);
    putInt(u64, bytes, 16, page_index);
    putInt(u64, bytes, 24, generation);
    putInt(u64, bytes, 32, page_range.first_extent);
    putInt(u32, bytes, 40, @intCast(entries.len));
    for (entries, 0..) |entry, index| {
        const expected = std.math.add(u64, page_range.first_extent, index) catch
            return error.ExtentIndexOverflow;
        if (entry.extent_index != expected) return error.NonCanonicalExtentIndex;
        try entry.validate();
        encodeEntry(bytes[entryOffset(index)..][0..entry_size], entry);
    }
    seal(bytes);
    return .{ .allocator = allocator, .bytes = bytes };
}

pub fn decodePage(
    bytes: []const u8,
    expected_page_index: u64,
    total_extent_count: u64,
) !View {
    const view = try decodeInternal(bytes);
    const page_range = try pageRange(
        @intCast(bytes.len),
        expected_page_index,
        total_extent_count,
    );
    if (view.page_index != expected_page_index or
        view.first_extent != page_range.first_extent or
        view.entry_count != page_range.count)
    {
        return error.AllocatorPagePositionMismatch;
    }
    return view;
}

fn decodeInternal(bytes: []const u8) !View {
    const logical_block_size = std.math.cast(u32, bytes.len) orelse
        return error.UnsupportedLogicalBlockSize;
    const capacity = try entriesPerPage(logical_block_size);
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidMagic;
    if (getInt(u16, bytes, 8) != format_version) return error.UnsupportedFormatVersion;
    if (getInt(u16, bytes, 10) != 0 or
        getInt(u16, bytes, 12) != header_size or
        getInt(u16, bytes, 14) != entry_size or
        !allZero(bytes[44..header_size]))
    {
        return error.NonCanonicalEncoding;
    }
    const count = getInt(u32, bytes, 40);
    if (count == 0 or count > capacity) return error.InvalidEntryCount;
    if (!verifyChecksum(bytes)) return error.ChecksumMismatch;
    const entries_end = entryOffset(count);
    if (!allZero(bytes[entries_end..checksumOffset(bytes.len)]))
        return error.NonCanonicalEncoding;

    const first_extent = getInt(u64, bytes, 32);
    for (0..count) |index| {
        const entry = try decodeEntry(bytes[entryOffset(index)..][0..entry_size]);
        const expected = std.math.add(u64, first_extent, index) catch
            return error.ExtentIndexOverflow;
        if (entry.extent_index != expected) return error.NonCanonicalExtentIndex;
    }
    return .{
        .bytes = bytes,
        .page_index = getInt(u64, bytes, 16),
        .generation = getInt(u64, bytes, 24),
        .first_extent = first_extent,
        .entry_count = count,
    };
}

const PageRange = struct {
    first_extent: u64,
    count: u32,
};

fn pageRange(
    logical_block_size: u32,
    page_index: u64,
    total_extent_count: u64,
) !PageRange {
    if (total_extent_count == 0) return error.InvalidExtentCount;
    const capacity = try entriesPerPage(logical_block_size);
    const first_extent = std.math.mul(u64, page_index, capacity) catch
        return error.AllocatorPageOutOfRange;
    if (first_extent >= total_extent_count) return error.AllocatorPageOutOfRange;
    return .{
        .first_extent = first_extent,
        .count = @intCast(@min(@as(u64, capacity), total_extent_count - first_extent)),
    };
}

fn sameAllocation(previous: Entry, next: Entry) !void {
    if (previous.kind != next.kind or
        !std.mem.eql(u8, &previous.claim_id, &next.claim_id) or
        !std.mem.eql(u8, &previous.owner_id, &next.owner_id) or
        !std.mem.eql(u8, &previous.owner_incarnation, &next.owner_incarnation) or
        previous.base_generation != next.base_generation or
        previous.owner_epoch != next.owner_epoch)
    {
        return error.AllocationIdentityChanged;
    }
}

fn encodeEntry(output: []u8, entry: Entry) void {
    output[0] = @intFromEnum(entry.state);
    output[1] = @intFromEnum(entry.kind);
    putInt(u64, output, 8, entry.extent_index);
    @memcpy(output[16..32], &entry.claim_id);
    @memcpy(output[32..48], &entry.owner_id);
    @memcpy(output[48..64], &entry.owner_incarnation);
    putInt(u64, output, 64, entry.base_generation);
    putInt(u64, output, 72, entry.owner_epoch);
    putInt(u64, output, 80, entry.transition_generation);
}

fn decodeEntry(input: []const u8) !Entry {
    if (getInt(u16, input, 2) != 0 or
        getInt(u32, input, 4) != 0 or
        getInt(u64, input, 88) != 0)
    {
        return error.NonCanonicalEncoding;
    }
    const entry = Entry{
        .state = std.enums.fromInt(State, input[0]) orelse return error.InvalidEntryState,
        .kind = std.enums.fromInt(Kind, input[1]) orelse return error.InvalidEntryKind,
        .extent_index = getInt(u64, input, 8),
        .claim_id = input[16..32].*,
        .owner_id = input[32..48].*,
        .owner_incarnation = input[48..64].*,
        .base_generation = getInt(u64, input, 64),
        .owner_epoch = getInt(u64, input, 72),
        .transition_generation = getInt(u64, input, 80),
    };
    try entry.validate();
    return entry;
}

fn entryOffset(index: usize) usize {
    return header_size + index * entry_size;
}

fn checksumOffset(size: usize) usize {
    return size - checksum_size;
}

fn seal(bytes: []u8) void {
    const start = checksumOffset(bytes.len);
    std.crypto.hash.sha2.Sha256.hash(bytes[0..start], bytes[start..][0..checksum_size], .{});
}

fn verifyChecksum(bytes: []const u8) bool {
    const start = checksumOffset(bytes.len);
    var expected = checksum_seed;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..start], &expected, .{});
    return std.mem.eql(u8, bytes[start..], &expected);
}

fn putInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
}

fn getInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn patternedId(seed: u8) [16]u8 {
    var id: [16]u8 = undefined;
    for (&id, seed..) |*byte, value| byte.* = @intCast(value);
    return id;
}

test "allocator pages round trip for both logical block sizes" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        const first_extent = @as(u64, try entriesPerPage(block_size)) * 5;
        const entries = [_]Entry{
            Entry.free(first_extent),
            .{
                .state = .claimed,
                .kind = .data,
                .extent_index = first_extent + 1,
                .claim_id = patternedId(1),
                .owner_id = patternedId(17),
                .owner_incarnation = patternedId(33),
                .base_generation = 8,
                .owner_epoch = 3,
            },
        };
        const total_extent_count = first_extent + 2;
        var encoded = try encodePage(
            std.testing.allocator,
            block_size,
            5,
            7,
            total_extent_count,
            &entries,
        );
        defer encoded.deinit();
        const view = try decodePage(encoded.bytes, 5, total_extent_count);
        try std.testing.expectEqual(@as(u64, 5), view.page_index);
        try std.testing.expectEqual(@as(u64, 7), view.generation);
        try std.testing.expectEqual(@as(u32, 2), view.entry_count);
        try std.testing.expectEqual(entries[0], try view.entry(0));
        try std.testing.expectEqual(entries[1], try view.entry(1));
    }
}

test "allocator page rejects corruption and noncanonical padding" {
    const entries = [_]Entry{Entry.free(0)};
    var encoded = try encodePage(std.testing.allocator, 512, 0, 0, 1, &entries);
    defer encoded.deinit();
    encoded.bytes[100] = 1;
    try std.testing.expectError(error.ChecksumMismatch, decodePage(encoded.bytes, 0, 1));
    encoded.bytes[100] = 0;
    encoded.bytes[200] = 1;
    seal(encoded.bytes);
    try std.testing.expectError(error.NonCanonicalEncoding, decodePage(encoded.bytes, 0, 1));
}

test "allocator entry state requires complete ownership" {
    var entry = Entry.free(1);
    entry.state = .claimed;
    entry.kind = .data;
    try std.testing.expectError(error.InvalidClaimedEntry, entry.validate());

    entry.claim_id = patternedId(1);
    entry.owner_id = patternedId(17);
    entry.owner_incarnation = patternedId(33);
    entry.owner_epoch = 1;
    try entry.validate();
}

test "allocator page position determines its complete extent range" {
    const capacity = try entriesPerPage(512);
    var first_entries: [4]Entry = undefined;
    for (&first_entries, 0..) |*entry, index| entry.* = Entry.free(index);
    var encoded = try encodePage(std.testing.allocator, 512, 0, 0, capacity + 1, &first_entries);
    defer encoded.deinit();
    try std.testing.expectError(
        error.AllocatorPagePositionMismatch,
        decodePage(encoded.bytes, 1, capacity + 1),
    );
    try std.testing.expectError(
        error.InvalidEntryCount,
        encodePage(std.testing.allocator, 512, 0, 0, capacity + 1, first_entries[0..3]),
    );
}

test "allocator page v1 encoding matches the golden vector" {
    const entries = [_]Entry{.{
        .state = .claimed,
        .kind = .data,
        .extent_index = 0,
        .claim_id = patternedId(1),
        .owner_id = patternedId(17),
        .owner_incarnation = patternedId(33),
        .base_generation = 8,
        .owner_epoch = 3,
    }};
    var encoded = try encodePage(std.testing.allocator, 512, 0, 7, 1, &entries);
    defer encoded.deinit();
    var expected: [512]u8 = @splat(0);
    @memcpy(expected[0..8], "ZCAWAL\x00\x00");
    expected[9] = 1;
    expected[13] = 64;
    expected[15] = 96;
    expected[31] = 7;
    expected[43] = 1;
    expected[64] = 1;
    expected[65] = 2;
    @memcpy(expected[80..96], &patternedId(1));
    @memcpy(expected[96..112], &patternedId(17));
    @memcpy(expected[112..128], &patternedId(33));
    expected[135] = 8;
    expected[143] = 3;
    @memcpy(expected[480..512], &[_]u8{
        0xb2, 0x53, 0x58, 0xe1, 0x62, 0x71, 0x0d, 0xc8,
        0xd6, 0x11, 0x11, 0xc4, 0x10, 0x89, 0x66, 0x32,
        0xd9, 0x0b, 0x89, 0x3d, 0xaf, 0xc1, 0xeb, 0x07,
        0xa7, 0xbf, 0x84, 0xf5, 0xf4, 0x2a, 0x77, 0xbb,
    });
    try std.testing.expectEqualSlices(u8, &expected, encoded.bytes);
    _ = try decodePage(&expected, 0, 1);
}

test "allocator transitions preserve ownership and advance generations" {
    const claimed = Entry{
        .state = .claimed,
        .kind = .data,
        .extent_index = 1,
        .claim_id = patternedId(1),
        .owner_id = patternedId(17),
        .owner_incarnation = patternedId(33),
        .base_generation = 8,
        .owner_epoch = 2,
    };
    var live = claimed;
    live.state = .live;
    live.transition_generation = 9;
    try validateTransition(claimed, live);
    var retired = live;
    retired.state = .retired;
    retired.transition_generation = 10;
    try validateTransition(live, retired);
    try validateTransition(retired, Entry.free(1));

    var changed = live;
    changed.owner_id = patternedId(49);
    try std.testing.expectError(error.AllocationIdentityChanged, validateTransition(claimed, changed));
}
