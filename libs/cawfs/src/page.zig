//! Stable immutable B+tree page encoding.

const std = @import("std");
const store = @import("store.zig");

pub const page_size = 4096;
pub const header_size = 128;
pub const format_version: u16 = 1;
pub const Encoded = [page_size]u8;

pub const Kind = enum(u8) {
    leaf = 1,
    internal = 2,
};

pub const LeafEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const InternalEntry = struct {
    key: []const u8,
    child: store.ObjectRef,
};

pub const Route = struct {
    child: store.ObjectRef,
    child_index: usize,
};

pub const Error = error{
    InvalidSize,
    InvalidMagic,
    UnsupportedFormatVersion,
    InvalidKind,
    InvalidFlags,
    InvalidLevel,
    EmptyInternalPage,
    KeyTooLarge,
    ValueTooLarge,
    TooManyEntries,
    PageFull,
    TruncatedEntry,
    KeysNotSorted,
    NonCanonicalEncoding,
    ChecksumMismatch,
    WrongPageKind,
    IndexOutOfBounds,
};

const magic = "ZCAWPG\x00\x00";
const magic_start = 0;
const magic_end = magic_start + magic.len;
const version_start = magic_end;
const version_end = version_start + @sizeOf(u16);
const kind_offset = version_end;
const flags_offset = kind_offset + @sizeOf(u8);
const entry_count_start = flags_offset + @sizeOf(u8);
const entry_count_end = entry_count_start + @sizeOf(u16);
const level_start = entry_count_end;
const level_end = level_start + @sizeOf(u16);
const payload_end_start = level_end;
const payload_end_end = payload_end_start + @sizeOf(u16);
const header_reserved_start = payload_end_end;
const header_reserved_end = header_reserved_start + @sizeOf(u16);
const first_child_start = header_reserved_end;
const first_child_end = first_child_start + store.object_ref_size;
const checksum_start = first_child_end;
const checksum_end = checksum_start + std.crypto.hash.sha2.Sha256.digest_length;

comptime {
    std.debug.assert(@sizeOf(store.ObjectRef) == store.object_ref_size);
    std.debug.assert(checksum_end <= header_size);
    std.debug.assert(page_size <= std.math.maxInt(u16));
}

pub const View = struct {
    encoded: *const Encoded,
    kind: Kind,
    level: u16,
    entry_count: u16,
    payload_end: u16,

    pub fn leafEntry(self: View, index: usize) Error!LeafEntry {
        if (self.kind != .leaf) return error.WrongPageKind;
        if (index >= self.entry_count) return error.IndexOutOfBounds;
        var cursor: usize = header_size;
        for (0..self.entry_count) |current| {
            const entry = parseLeafEntry(self.encoded, &cursor, self.payload_end) catch unreachable;
            if (current == index) return entry;
        }
        unreachable;
    }

    pub fn internalEntry(self: View, index: usize) Error!InternalEntry {
        if (self.kind != .internal) return error.WrongPageKind;
        if (index >= self.entry_count) return error.IndexOutOfBounds;
        var cursor: usize = header_size;
        for (0..self.entry_count) |current| {
            const entry = parseInternalEntry(self.encoded, &cursor, self.payload_end) catch unreachable;
            if (current == index) return entry;
        }
        unreachable;
    }

    pub fn find(self: View, key: []const u8) Error!?[]const u8 {
        if (self.kind != .leaf) return error.WrongPageKind;
        var cursor: usize = header_size;
        for (0..self.entry_count) |_| {
            const entry = parseLeafEntry(self.encoded, &cursor, self.payload_end) catch unreachable;
            switch (std.mem.order(u8, key, entry.key)) {
                .lt => return null,
                .eq => return entry.value,
                .gt => {},
            }
        }
        return null;
    }

    pub fn lowerBound(self: View, key: []const u8) Error!usize {
        if (self.kind != .leaf) return error.WrongPageKind;
        var cursor: usize = header_size;
        for (0..self.entry_count) |index| {
            const entry = parseLeafEntry(self.encoded, &cursor, self.payload_end) catch unreachable;
            if (std.mem.order(u8, entry.key, key) != .lt) return index;
        }
        return self.entry_count;
    }

    pub fn childFor(self: View, key: []const u8) Error!store.ObjectRef {
        return (try self.route(key)).child;
    }

    pub fn firstChild(self: View) Error!store.ObjectRef {
        if (self.kind != .internal) return error.WrongPageKind;
        return objectRef(self.encoded[first_child_start..first_child_end]);
    }

    pub fn route(self: View, key: []const u8) Error!Route {
        var child = try self.firstChild();
        var child_index: usize = 0;
        var cursor: usize = header_size;
        for (0..self.entry_count) |_| {
            const entry = parseInternalEntry(self.encoded, &cursor, self.payload_end) catch unreachable;
            if (std.mem.order(u8, key, entry.key) == .lt) return .{ .child = child, .child_index = child_index };
            child = entry.child;
            child_index += 1;
        }
        return .{ .child = child, .child_index = child_index };
    }
};

pub fn encodeLeaf(entries: []const LeafEntry) Error!Encoded {
    if (entries.len > std.math.maxInt(u16)) return error.TooManyEntries;
    var encoded = init(.leaf, 0, @intCast(entries.len));
    var cursor: usize = header_size;
    var previous: ?[]const u8 = null;
    for (entries) |entry| {
        try validateKeyOrder(previous, entry.key);
        if (entry.key.len > std.math.maxInt(u16)) return error.KeyTooLarge;
        if (entry.value.len > std.math.maxInt(u32)) return error.ValueTooLarge;
        const size = std.math.add(usize, 6, entry.key.len) catch return error.PageFull;
        const total = std.math.add(usize, size, entry.value.len) catch return error.PageFull;
        if (total > page_size - cursor) return error.PageFull;

        std.mem.writeInt(u16, encoded[cursor..][0..2], @intCast(entry.key.len), .big);
        std.mem.writeInt(u32, encoded[cursor + 2 ..][0..4], @intCast(entry.value.len), .big);
        cursor += 6;
        @memcpy(encoded[cursor..][0..entry.key.len], entry.key);
        cursor += entry.key.len;
        @memcpy(encoded[cursor..][0..entry.value.len], entry.value);
        cursor += entry.value.len;
        previous = entry.key;
    }
    finish(&encoded, cursor);
    return encoded;
}

pub fn encodeInternal(
    level: u16,
    first_child: store.ObjectRef,
    entries: []const InternalEntry,
) Error!Encoded {
    if (level == 0) return error.InvalidLevel;
    if (entries.len == 0) return error.EmptyInternalPage;
    if (entries.len > std.math.maxInt(u16)) return error.TooManyEntries;
    var encoded = init(.internal, level, @intCast(entries.len));
    @memcpy(encoded[first_child_start..first_child_end], &first_child.bytes);
    var cursor: usize = header_size;
    var previous: ?[]const u8 = null;
    for (entries) |entry| {
        try validateKeyOrder(previous, entry.key);
        if (entry.key.len > std.math.maxInt(u16)) return error.KeyTooLarge;
        const total = std.math.add(usize, 2 + store.object_ref_size, entry.key.len) catch
            return error.PageFull;
        if (total > page_size - cursor) return error.PageFull;

        std.mem.writeInt(u16, encoded[cursor..][0..2], @intCast(entry.key.len), .big);
        cursor += 2;
        @memcpy(encoded[cursor..][0..store.object_ref_size], &entry.child.bytes);
        cursor += store.object_ref_size;
        @memcpy(encoded[cursor..][0..entry.key.len], entry.key);
        cursor += entry.key.len;
        previous = entry.key;
    }
    finish(&encoded, cursor);
    return encoded;
}

pub fn decode(bytes: []const u8) Error!View {
    if (bytes.len != page_size) return error.InvalidSize;
    const encoded: *const Encoded = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, encoded[magic_start..magic_end], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, encoded[version_start..version_end], .big) != format_version)
        return error.UnsupportedFormatVersion;
    const kind = std.enums.fromInt(Kind, encoded[kind_offset]) orelse return error.InvalidKind;
    if (encoded[flags_offset] != 0) return error.InvalidFlags;
    if (!allZero(encoded[header_reserved_start..header_reserved_end]) or
        !allZero(encoded[checksum_end..header_size]))
        return error.NonCanonicalEncoding;

    const level = std.mem.readInt(u16, encoded[level_start..level_end], .big);
    const entry_count = std.mem.readInt(u16, encoded[entry_count_start..entry_count_end], .big);
    const payload_end = std.mem.readInt(u16, encoded[payload_end_start..payload_end_end], .big);
    if (payload_end < header_size or payload_end > page_size) return error.TruncatedEntry;
    switch (kind) {
        .leaf => {
            if (level != 0) return error.InvalidLevel;
            if (!allZero(encoded[first_child_start..first_child_end]))
                return error.NonCanonicalEncoding;
        },
        .internal => {
            if (level == 0) return error.InvalidLevel;
            if (entry_count == 0) return error.EmptyInternalPage;
        },
    }
    if (!allZero(encoded[payload_end..])) return error.NonCanonicalEncoding;

    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    checksum(encoded, &expected);
    if (!std.mem.eql(u8, encoded[checksum_start..checksum_end], &expected))
        return error.ChecksumMismatch;

    var cursor: usize = header_size;
    var previous: ?[]const u8 = null;
    for (0..entry_count) |_| {
        const key = switch (kind) {
            .leaf => (try parseLeafEntry(encoded, &cursor, payload_end)).key,
            .internal => (try parseInternalEntry(encoded, &cursor, payload_end)).key,
        };
        try validateKeyOrder(previous, key);
        previous = key;
    }
    if (cursor != payload_end) return error.NonCanonicalEncoding;

    return .{
        .encoded = encoded,
        .kind = kind,
        .level = level,
        .entry_count = entry_count,
        .payload_end = payload_end,
    };
}

fn init(kind: Kind, level: u16, entry_count: u16) Encoded {
    var encoded: Encoded = @splat(0);
    @memcpy(encoded[magic_start..magic_end], magic);
    std.mem.writeInt(u16, encoded[version_start..version_end], format_version, .big);
    encoded[kind_offset] = @intFromEnum(kind);
    std.mem.writeInt(u16, encoded[entry_count_start..entry_count_end], entry_count, .big);
    std.mem.writeInt(u16, encoded[level_start..level_end], level, .big);
    return encoded;
}

fn finish(encoded: *Encoded, payload_end: usize) void {
    std.mem.writeInt(u16, encoded[payload_end_start..payload_end_end], @intCast(payload_end), .big);
    seal(encoded);
}

fn parseLeafEntry(encoded: *const Encoded, cursor: *usize, payload_end: usize) Error!LeafEntry {
    if (payload_end - cursor.* < 6) return error.TruncatedEntry;
    const key_len = std.mem.readInt(u16, encoded[cursor.*..][0..2], .big);
    const value_len = std.mem.readInt(u32, encoded[cursor.* + 2 ..][0..4], .big);
    cursor.* += 6;
    const total = std.math.add(usize, key_len, value_len) catch return error.TruncatedEntry;
    if (total > payload_end - cursor.*) return error.TruncatedEntry;
    const key = encoded[cursor.*..][0..key_len];
    cursor.* += key_len;
    const value = encoded[cursor.*..][0..value_len];
    cursor.* += value_len;
    return .{ .key = key, .value = value };
}

fn parseInternalEntry(encoded: *const Encoded, cursor: *usize, payload_end: usize) Error!InternalEntry {
    const fixed_size = 2 + store.object_ref_size;
    if (payload_end - cursor.* < fixed_size) return error.TruncatedEntry;
    const key_len = std.mem.readInt(u16, encoded[cursor.*..][0..2], .big);
    cursor.* += 2;
    const child = objectRef(encoded[cursor.*..][0..store.object_ref_size]);
    cursor.* += store.object_ref_size;
    if (key_len > payload_end - cursor.*) return error.TruncatedEntry;
    const key = encoded[cursor.*..][0..key_len];
    cursor.* += key_len;
    return .{ .key = key, .child = child };
}

fn objectRef(bytes: *const [store.object_ref_size]u8) store.ObjectRef {
    return .{ .bytes = bytes.* };
}

fn validateKeyOrder(previous: ?[]const u8, key: []const u8) Error!void {
    if (previous) |value| {
        if (std.mem.order(u8, value, key) != .lt) return error.KeysNotSorted;
    }
}

fn seal(encoded: *Encoded) void {
    checksum(encoded, encoded[checksum_start..checksum_end]);
}

fn checksum(encoded: *const Encoded, result: *[std.crypto.hash.sha2.Sha256.digest_length]u8) void {
    var canonical = encoded.*;
    @memset(canonical[checksum_start..checksum_end], 0);
    std.crypto.hash.sha2.Sha256.hash(&canonical, result, .{});
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

test "empty leaf matches the v1 golden vector" {
    const encoded = try encodeLeaf(&.{});
    var expected: Encoded = @splat(0);
    @memcpy(expected[0..8], "ZCAWPG\x00\x00");
    expected[9] = 1;
    expected[10] = 1;
    expected[17] = 128;
    @memcpy(expected[84..116], &[_]u8{
        0x59, 0xeb, 0x6e, 0xbd, 0xe8, 0x80, 0xc4, 0x2d,
        0xe7, 0x48, 0x5c, 0x82, 0x32, 0x3c, 0xb6, 0x13,
        0x5e, 0x97, 0x63, 0xe9, 0x27, 0x97, 0x6f, 0xb8,
        0xbc, 0x04, 0x42, 0x40, 0x49, 0xc4, 0xe0, 0xb4,
    });

    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    const view = try decode(&expected);
    try std.testing.expectEqual(Kind.leaf, view.kind);
    try std.testing.expectEqual(@as(u16, 0), view.entry_count);
}

test "leaf entries round trip and support lookup" {
    const encoded = try encodeLeaf(&.{
        .{ .key = "alpha", .value = "one" },
        .{ .key = "beta", .value = "two" },
        .{ .key = "delta", .value = "three" },
    });
    const view = try decode(&encoded);

    try std.testing.expectEqualStrings("beta", (try view.leafEntry(1)).key);
    try std.testing.expectEqualStrings("two", (try view.find("beta")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try view.find("charlie"));
    try std.testing.expectEqual(@as(usize, 0), try view.lowerBound("a"));
    try std.testing.expectEqual(@as(usize, 1), try view.lowerBound("beta"));
    try std.testing.expectEqual(@as(usize, 2), try view.lowerBound("charlie"));
    try std.testing.expectEqual(@as(usize, 3), try view.lowerBound("zulu"));
    try std.testing.expectError(error.IndexOutOfBounds, view.leafEntry(3));
    try std.testing.expectError(error.WrongPageKind, view.childFor("beta"));
}

test "nonempty leaf matches the v1 golden vector" {
    const encoded = try encodeLeaf(&.{
        .{ .key = "a", .value = "x" },
        .{ .key = "bb", .value = "yz" },
    });
    var expected: Encoded = @splat(0);
    @memcpy(expected[0..8], "ZCAWPG\x00\x00");
    expected[9] = 1;
    expected[10] = 1;
    expected[13] = 2;
    expected[17] = 146;
    @memcpy(expected[128..146], &[_]u8{
        0,   1,   0, 0, 0, 1, 'a', 'x',
        0,   2,   0, 0, 0, 2, 'b', 'b',
        'y', 'z',
    });
    @memcpy(expected[84..116], &[_]u8{
        0xfe, 0x63, 0x34, 0x21, 0x5f, 0xf4, 0x22, 0x29,
        0x74, 0xe7, 0x86, 0x74, 0x4c, 0xad, 0xfe, 0x31,
        0x16, 0xd3, 0x7b, 0xd5, 0x38, 0x8f, 0x36, 0xb5,
        0x63, 0x1a, 0x99, 0xfb, 0xfa, 0xfa, 0x74, 0x9a,
    });

    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    try std.testing.expectEqualStrings("yz", (try (try decode(&expected)).find("bb")).?);
}

test "internal page routes separator boundaries" {
    const left = patternedRef(1);
    const middle = patternedRef(2);
    const right = patternedRef(3);
    const encoded = try encodeInternal(1, left, &.{
        .{ .key = "m", .child = middle },
        .{ .key = "t", .child = right },
    });
    const view = try decode(&encoded);

    try std.testing.expect(store.ObjectRef.eql(left, try view.firstChild()));
    const before = try view.route("a");
    try std.testing.expect(store.ObjectRef.eql(left, before.child));
    try std.testing.expectEqual(@as(usize, 0), before.child_index);
    const boundary = try view.route("m");
    try std.testing.expect(store.ObjectRef.eql(middle, boundary.child));
    try std.testing.expectEqual(@as(usize, 1), boundary.child_index);
    try std.testing.expect(store.ObjectRef.eql(middle, try view.childFor("s")));
    try std.testing.expect(store.ObjectRef.eql(right, try view.childFor("t")));
    try std.testing.expectEqualStrings("t", (try view.internalEntry(1)).key);
    try std.testing.expectError(error.WrongPageKind, view.find("m"));
}

test "internal page matches the v1 golden vector" {
    var first: store.ObjectRef = .{};
    var middle: store.ObjectRef = .{};
    var right: store.ObjectRef = .{};
    for (&first.bytes, 0..) |*byte, value| byte.* = @intCast(value);
    for (&middle.bytes, 64..) |*byte, value| byte.* = @intCast(value);
    for (&right.bytes, 128..) |*byte, value| byte.* = @intCast(value);
    const encoded = try encodeInternal(2, first, &.{
        .{ .key = "m", .child = middle },
        .{ .key = "t", .child = right },
    });

    var expected: Encoded = @splat(0);
    @memcpy(expected[0..8], "ZCAWPG\x00\x00");
    expected[9] = 1;
    expected[10] = 2;
    expected[13] = 2;
    expected[15] = 2;
    expected[16] = 1;
    expected[17] = 6;
    @memcpy(expected[20..84], &first.bytes);
    @memcpy(expected[128..130], &[_]u8{ 0, 1 });
    @memcpy(expected[130..194], &middle.bytes);
    expected[194] = 'm';
    @memcpy(expected[195..197], &[_]u8{ 0, 1 });
    @memcpy(expected[197..261], &right.bytes);
    expected[261] = 't';
    @memcpy(expected[84..116], &[_]u8{
        0x88, 0x9c, 0x25, 0x45, 0xf8, 0x14, 0x1f, 0xdd,
        0x0c, 0x12, 0xce, 0xe5, 0x34, 0x5a, 0x42, 0xb2,
        0xf1, 0x52, 0x6a, 0xcf, 0x30, 0x5e, 0x02, 0xcb,
        0x75, 0x4c, 0xe6, 0xd1, 0x81, 0xfd, 0xc7, 0x91,
    });

    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    const view = try decode(&expected);
    try std.testing.expect(store.ObjectRef.eql(right, try view.childFor("z")));
}

test "page encoder requires strictly sorted keys" {
    try std.testing.expectError(error.KeysNotSorted, encodeLeaf(&.{
        .{ .key = "b", .value = "one" },
        .{ .key = "a", .value = "two" },
    }));
    try std.testing.expectError(error.KeysNotSorted, encodeInternal(1, .{}, &.{
        .{ .key = "a", .child = .{} },
        .{ .key = "a", .child = .{} },
    }));
}

test "page encoder enforces capacity and internal level" {
    try std.testing.expectError(error.PageFull, encodeLeaf(&.{.{
        .key = "key",
        .value = "x" ** page_size,
    }}));
    try std.testing.expectError(error.InvalidLevel, encodeInternal(0, .{}, &.{.{
        .key = "key",
        .child = .{},
    }}));
    try std.testing.expectError(error.EmptyInternalPage, encodeInternal(1, .{}, &.{}));
}

test "page decoder rejects corruption and noncanonical bytes" {
    var corrupt = try encodeLeaf(&.{.{ .key = "key", .value = "value" }});
    corrupt[header_size] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&corrupt));

    var trailing = try encodeLeaf(&.{});
    trailing[page_size - 1] = 1;
    seal(&trailing);
    try std.testing.expectError(error.NonCanonicalEncoding, decode(&trailing));
    try std.testing.expectError(error.InvalidSize, decode(trailing[0 .. page_size - 1]));
}

fn patternedRef(seed: u8) store.ObjectRef {
    var result: store.ObjectRef = .{};
    for (&result.bytes, 0..) |*byte, index| byte.* = seed +% @as(u8, @truncate(index * 13));
    return result;
}
