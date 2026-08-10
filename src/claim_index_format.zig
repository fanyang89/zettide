//! Stable full-block global claim-index page format.

const std = @import("std");
const allocation = @import("allocation_format.zig");
const store = @import("store.zig");

pub const format_version: u16 = 1;
pub const header_size: usize = 64;
pub const entry_size: usize = 96;
pub const checksum_size = std.crypto.hash.sha2.Sha256.digest_length;
pub const max_entries_per_page: usize = (4096 - header_size - checksum_size) / entry_size;

const magic = "ZCAWCI\x00\x00";

pub const State = enum(u8) {
    empty = 0,
    bound = 1,
    tombstone = 2,
};

pub const Entry = struct {
    state: State = .empty,
    kind: allocation.Kind = .none,
    claim_id: [16]u8 = @splat(0),
    owner_id: [16]u8 = @splat(0),
    owner_incarnation: [16]u8 = @splat(0),
    base_generation: u64 = 0,
    owner_epoch: u64 = 0,
    claim_epoch: u64 = 0,
    extent_index: u64 = 0,

    pub fn empty() Entry {
        return .{};
    }

    pub fn tombstone() Entry {
        return .{ .state = .tombstone };
    }

    pub fn validate(self: Entry, extent_count: u64) !void {
        switch (self.state) {
            .empty => if (!std.meta.eql(self, Entry.empty())) return error.InvalidEmptyEntry,
            .tombstone => if (!std.meta.eql(self, Entry.tombstone()))
                return error.InvalidTombstoneEntry,
            .bound => {
                if (self.kind == .none or allZero(&self.claim_id) or allZero(&self.owner_id) or
                    allZero(&self.owner_incarnation) or self.owner_epoch == 0 or
                    self.claim_epoch == 0 or self.base_generation == std.math.maxInt(u64) or
                    self.extent_index >= extent_count)
                {
                    return error.InvalidBoundEntry;
                }
            },
        }
    }
};

pub const View = struct {
    bytes: []const u8,
    volume_id: [16]u8,
    page_index: u64,
    generation: u64,
    first_slot: u64,
    entry_count: u32,
    extent_count: u64,

    pub fn entry(self: View, index: usize) !Entry {
        if (index >= self.entry_count) return error.EntryOutOfRange;
        return decodeEntry(self.bytes[entryOffset(index)..][0..entry_size], self.extent_count);
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
    volume_id: [16]u8,
    page_index: u64,
    generation: u64,
    total_slot_count: u64,
    extent_count: u64,
    entries: []const Entry,
) !store.OwnedBytes {
    if (allZero(&volume_id)) return error.InvalidVolumeId;
    const range = try rangeForPage(logical_block_size, page_index, total_slot_count);
    if (entries.len != range.count) return error.InvalidEntryCount;
    const bytes = try allocator.alloc(u8, logical_block_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], magic);
    putInt(u16, bytes, 8, format_version);
    putInt(u16, bytes, 12, header_size);
    putInt(u16, bytes, 14, entry_size);
    putInt(u64, bytes, 16, page_index);
    putInt(u64, bytes, 24, generation);
    putInt(u64, bytes, 32, range.first);
    putInt(u32, bytes, 40, @intCast(entries.len));
    @memcpy(bytes[44..60], &volume_id);
    for (entries, 0..) |entry, index| {
        try entry.validate(extent_count);
        encodeEntry(bytes[entryOffset(index)..][0..entry_size], entry);
    }
    seal(bytes);
    return .{ .allocator = allocator, .bytes = bytes };
}

pub fn decodePage(
    bytes: []const u8,
    expected_volume_id: [16]u8,
    expected_page_index: u64,
    total_slot_count: u64,
    extent_count: u64,
) !View {
    if (allZero(&expected_volume_id)) return error.InvalidVolumeId;
    const block_size = std.math.cast(u32, bytes.len) orelse
        return error.UnsupportedLogicalBlockSize;
    const range = try rangeForPage(block_size, expected_page_index, total_slot_count);
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidMagic;
    if (getInt(u16, bytes, 8) != format_version) return error.UnsupportedFormatVersion;
    if (getInt(u16, bytes, 10) != 0 or getInt(u16, bytes, 12) != header_size or
        getInt(u16, bytes, 14) != entry_size or !allZero(bytes[60..header_size]))
    {
        return error.NonCanonicalEncoding;
    }
    if (!verifyChecksum(bytes)) return error.ChecksumMismatch;
    const count = getInt(u32, bytes, 40);
    if (!std.mem.eql(u8, bytes[44..60], &expected_volume_id) or
        getInt(u64, bytes, 16) != expected_page_index or
        getInt(u64, bytes, 32) != range.first or count != range.count)
    {
        return error.IndexPagePositionMismatch;
    }
    if (!allZero(bytes[entryOffset(count)..checksumOffset(bytes.len)]))
        return error.NonCanonicalEncoding;
    const view = View{
        .bytes = bytes,
        .volume_id = bytes[44..60].*,
        .page_index = expected_page_index,
        .generation = getInt(u64, bytes, 24),
        .first_slot = range.first,
        .entry_count = count,
        .extent_count = extent_count,
    };
    for (0..count) |index| _ = try view.entry(index);
    return view;
}

pub const PageRange = struct {
    first: u64,
    count: u32,
};

pub fn rangeForPage(block_size: u32, page_index: u64, total_slots: u64) !PageRange {
    if (total_slots == 0) return error.InvalidSlotCount;
    const capacity = try entriesPerPage(block_size);
    const first = std.math.mul(u64, page_index, capacity) catch
        return error.IndexPageOutOfRange;
    if (first >= total_slots) return error.IndexPageOutOfRange;
    return .{ .first = first, .count = @intCast(@min(capacity, total_slots - first)) };
}

fn encodeEntry(output: []u8, entry: Entry) void {
    output[0] = @backingInt(entry.state);
    output[1] = @backingInt(entry.kind);
    @memcpy(output[8..24], &entry.claim_id);
    @memcpy(output[24..40], &entry.owner_id);
    @memcpy(output[40..56], &entry.owner_incarnation);
    putInt(u64, output, 56, entry.base_generation);
    putInt(u64, output, 64, entry.owner_epoch);
    putInt(u64, output, 72, entry.claim_epoch);
    putInt(u64, output, 80, entry.extent_index);
}

fn decodeEntry(input: []const u8, extent_count: u64) !Entry {
    if (!allZero(input[2..8]) or getInt(u64, input, 88) != 0)
        return error.NonCanonicalEncoding;
    const entry = Entry{
        .state = std.enums.fromInt(State, input[0]) orelse return error.InvalidEntryState,
        .kind = std.enums.fromInt(allocation.Kind, input[1]) orelse return error.InvalidEntryKind,
        .claim_id = input[8..24].*,
        .owner_id = input[24..40].*,
        .owner_incarnation = input[40..56].*,
        .base_generation = getInt(u64, input, 56),
        .owner_epoch = getInt(u64, input, 64),
        .claim_epoch = getInt(u64, input, 72),
        .extent_index = getInt(u64, input, 80),
    };
    try entry.validate(extent_count);
    return entry;
}

fn entryOffset(index: usize) usize {
    return header_size + index * entry_size;
}

fn checksumOffset(size: usize) usize {
    return size - checksum_size;
}

fn seal(bytes: []u8) void {
    const offset = checksumOffset(bytes.len);
    std.crypto.hash.sha2.Sha256.hash(bytes[0..offset], bytes[offset..][0..checksum_size], .{});
}

fn verifyChecksum(bytes: []const u8) bool {
    const offset = checksumOffset(bytes.len);
    var expected: [checksum_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..offset], &expected, .{});
    return std.mem.eql(u8, bytes[offset..], &expected);
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

test "claim index pages round trip and bind their physical position" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        const volume_id = patternedId(1);
        const capacity = try entriesPerPage(block_size);
        var entries: [max_entries_per_page]Entry = undefined;
        for (entries[0..capacity]) |*entry| entry.* = .empty();
        entries[0] = .{
            .state = .bound,
            .kind = .data,
            .claim_id = patternedId(17),
            .owner_id = patternedId(33),
            .owner_incarnation = patternedId(49),
            .owner_epoch = 1,
            .claim_epoch = 2,
            .extent_index = 3,
        };
        var encoded = try encodePage(
            std.testing.allocator,
            block_size,
            volume_id,
            1,
            4,
            capacity * 2,
            10,
            entries[0..capacity],
        );
        defer encoded.deinit();
        const view = try decodePage(encoded.bytes, volume_id, 1, capacity * 2, 10);
        try std.testing.expectEqual(entries[0], try view.entry(0));
        try std.testing.expectError(
            error.IndexPagePositionMismatch,
            decodePage(encoded.bytes, volume_id, 0, capacity * 2, 10),
        );
    }
}

test "claim index golden vector and canonical validation" {
    const volume_id = patternedId(1);
    var entries: [4]Entry = @splat(Entry.empty());
    var encoded = try encodePage(std.testing.allocator, 512, volume_id, 0, 0, 4, 1, &entries);
    defer encoded.deinit();
    try std.testing.expectEqualSlices(u8, "ZCAWCI\x00\x00", encoded.bytes[0..8]);
    try std.testing.expectEqual(@as(u8, 1), encoded.bytes[9]);
    try std.testing.expectEqual(@as(u8, 64), encoded.bytes[13]);
    try std.testing.expectEqual(@as(u8, 96), encoded.bytes[15]);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xb4, 0xbf, 0xe8, 0x62, 0x73, 0x22, 0x8e, 0x20,
        0xcc, 0x1e, 0xd9, 0x99, 0x1c, 0x8d, 0x2b, 0x1e,
        0xf1, 0x12, 0x8b, 0xbe, 0xe1, 0xe5, 0x49, 0xbf,
        0x31, 0x1b, 0x29, 0x22, 0xe8, 0xd5, 0x87, 0x4f,
    }, encoded.bytes[480..512]);
    encoded.bytes[2] ^= 1;
    try std.testing.expectError(
        error.InvalidMagic,
        decodePage(encoded.bytes, volume_id, 0, 4, 1),
    );

    encoded.bytes[2] ^= 1;
    encoded.bytes[64] = @backingInt(State.tombstone);
    encoded.bytes[72] = 1;
    seal(encoded.bytes);
    try std.testing.expectError(
        error.InvalidTombstoneEntry,
        decodePage(encoded.bytes, volume_id, 0, 4, 1),
    );
}
