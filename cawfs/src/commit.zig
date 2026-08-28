//! Stable encoding for immutable commit records.

const std = @import("std");
const store = @import("store.zig");

pub const record_size = 256;
pub const format_version: u16 = 1;
pub const Encoded = [record_size]u8;

pub const State = struct {
    generation: u64,
    transaction_id: store.TransactionId,
    /// The previous immutable commit, or null for the first commit.
    parent: ?store.ObjectRef,
    /// The immutable filesystem state published by this commit.
    root: store.ObjectRef,
};

pub const Error = error{
    InvalidSize,
    InvalidMagic,
    UnsupportedFormatVersion,
    InvalidFlags,
    NonCanonicalEncoding,
    ChecksumMismatch,
};

const magic = "ZCAWCM\x00\x00";
const magic_start = 0;
const magic_end = magic_start + magic.len;
const version_start = magic_end;
const version_end = version_start + @sizeOf(u16);
const flags_start = version_end;
const flags_end = flags_start + @sizeOf(u16);
const generation_start = flags_end;
const generation_end = generation_start + @sizeOf(u64);
const transaction_id_start = generation_end;
const transaction_id_end = transaction_id_start + @sizeOf(store.TransactionId);
const parent_start = transaction_id_end;
const parent_end = parent_start + store.object_ref_size;
const root_start = parent_end;
const root_end = root_start + store.object_ref_size;
const checksum_start = root_end;
const checksum_end = checksum_start + std.crypto.hash.sha2.Sha256.digest_length;
const has_parent: u16 = 1 << 0;
const known_flags = has_parent;

comptime {
    std.debug.assert(@sizeOf(store.ObjectRef) == store.object_ref_size);
    std.debug.assert(checksum_end <= record_size);
}

pub fn encode(state: State) Encoded {
    var encoded: Encoded = @splat(0);
    @memcpy(encoded[magic_start..magic_end], magic);
    std.mem.writeInt(u16, encoded[version_start..version_end], format_version, .big);
    std.mem.writeInt(u64, encoded[generation_start..generation_end], state.generation, .big);
    @memcpy(encoded[transaction_id_start..transaction_id_end], &state.transaction_id);
    if (state.parent) |parent| {
        std.mem.writeInt(u16, encoded[flags_start..flags_end], has_parent, .big);
        @memcpy(encoded[parent_start..parent_end], &parent.bytes);
    }
    @memcpy(encoded[root_start..root_end], &state.root.bytes);
    seal(&encoded);
    return encoded;
}

pub fn decode(bytes: []const u8) Error!State {
    if (bytes.len != record_size) return error.InvalidSize;
    const encoded: *const Encoded = @ptrCast(bytes.ptr);

    if (!std.mem.eql(u8, encoded[magic_start..magic_end], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, encoded[version_start..version_end], .big) != format_version)
        return error.UnsupportedFormatVersion;

    const flags = std.mem.readInt(u16, encoded[flags_start..flags_end], .big);
    if (flags & ~known_flags != 0) return error.InvalidFlags;
    if (flags & has_parent == 0 and !allZero(encoded[parent_start..parent_end]))
        return error.NonCanonicalEncoding;
    if (!allZero(encoded[checksum_end..])) return error.NonCanonicalEncoding;

    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    checksum(encoded, &expected);
    if (!std.mem.eql(u8, encoded[checksum_start..checksum_end], &expected))
        return error.ChecksumMismatch;

    var parent: ?store.ObjectRef = null;
    if (flags & has_parent != 0) parent = objectRef(encoded[parent_start..parent_end]);
    return .{
        .generation = std.mem.readInt(u64, encoded[generation_start..generation_end], .big),
        .transaction_id = encoded[transaction_id_start..transaction_id_end].*,
        .parent = parent,
        .root = objectRef(encoded[root_start..root_end]),
    };
}

fn objectRef(bytes: *const [store.object_ref_size]u8) store.ObjectRef {
    return .{ .bytes = bytes.* };
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

test "commit record round trips" {
    const transaction_id: store.TransactionId = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const parent = patternedRef(3);
    const root = patternedRef(9);
    const encoded = encode(.{
        .generation = 42,
        .transaction_id = transaction_id,
        .parent = parent,
        .root = root,
    });
    const decoded = try decode(&encoded);

    try std.testing.expectEqual(@as(u64, 42), decoded.generation);
    try std.testing.expectEqual(transaction_id, decoded.transaction_id);
    try std.testing.expect(store.ObjectRef.eql(parent, decoded.parent.?));
    try std.testing.expect(store.ObjectRef.eql(root, decoded.root));
}

test "commit v1 encoding matches the golden vector" {
    const transaction_id: store.TransactionId = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var parent: store.ObjectRef = .{};
    var root: store.ObjectRef = .{};
    for (&parent.bytes, 64..) |*byte, value| byte.* = @intCast(value);
    for (&root.bytes, 128..) |*byte, value| byte.* = @intCast(value);
    const encoded = encode(.{
        .generation = 0x0102030405060708,
        .transaction_id = transaction_id,
        .parent = parent,
        .root = root,
    });

    var expected: Encoded = @splat(0);
    @memcpy(expected[0..8], "ZCAWCM\x00\x00");
    expected[9] = 1;
    expected[11] = 1;
    @memcpy(expected[12..20], &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    @memcpy(expected[20..36], &transaction_id);
    @memcpy(expected[36..100], &parent.bytes);
    @memcpy(expected[100..164], &root.bytes);
    @memcpy(expected[164..196], &[_]u8{
        0x28, 0x8e, 0x52, 0xb1, 0x82, 0x5f, 0xbe, 0xa8,
        0x96, 0x8a, 0xdd, 0xfe, 0xa6, 0x6b, 0x1c, 0x7a,
        0x4b, 0xa0, 0xad, 0xcb, 0xfb, 0x63, 0xa6, 0xa8,
        0x3f, 0x3c, 0xfe, 0xac, 0xa9, 0x9c, 0xb0, 0x76,
    });

    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    const decoded = try decode(&expected);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), decoded.generation);
    try std.testing.expectEqual(transaction_id, decoded.transaction_id);
    try std.testing.expect(store.ObjectRef.eql(parent, decoded.parent.?));
    try std.testing.expect(store.ObjectRef.eql(root, decoded.root));
}

test "first commit omits its parent canonically" {
    const encoded = encode(.{
        .generation = 1,
        .transaction_id = @splat(1),
        .parent = null,
        .root = patternedRef(5),
    });
    const decoded = try decode(&encoded);

    try std.testing.expectEqual(@as(?store.ObjectRef, null), decoded.parent);
    try std.testing.expect(allZero(encoded[parent_start..parent_end]));
}

test "commit rejects invalid size and corruption" {
    var encoded = encode(.{
        .generation = 1,
        .transaction_id = @splat(1),
        .parent = null,
        .root = patternedRef(5),
    });
    try std.testing.expectError(error.InvalidSize, decode(encoded[0 .. record_size - 1]));

    encoded[generation_start] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&encoded));
}

test "commit rejects noncanonical parent and reserved bytes" {
    var parent = encode(.{
        .generation = 1,
        .transaction_id = @splat(1),
        .parent = null,
        .root = patternedRef(5),
    });
    parent[parent_start] = 1;
    seal(&parent);
    try std.testing.expectError(error.NonCanonicalEncoding, decode(&parent));

    var reserved = encode(.{
        .generation = 1,
        .transaction_id = @splat(1),
        .parent = null,
        .root = patternedRef(5),
    });
    reserved[record_size - 1] = 1;
    seal(&reserved);
    try std.testing.expectError(error.NonCanonicalEncoding, decode(&reserved));
}

fn patternedRef(seed: u8) store.ObjectRef {
    var result: store.ObjectRef = .{};
    for (&result.bytes, 0..) |*byte, index| byte.* = seed +% @as(u8, @truncate(index * 17));
    return result;
}
