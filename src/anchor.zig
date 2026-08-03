//! Stable encoding for the conditionally published filesystem anchor.

const std = @import("std");
const store = @import("store.zig");

pub const format_version: u16 = 1;

pub const State = struct {
    generation: u64,
    transaction_id: store.TransactionId,
    head: ?store.ObjectRef,
};

pub const Error = error{
    InvalidMagic,
    UnsupportedFormatVersion,
    InvalidFlags,
    NonCanonicalEncoding,
    ChecksumMismatch,
};

const magic = "ZCAWFS\x00\x00";
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
const head_start = transaction_id_end;
const head_end = head_start + store.object_ref_size;
const checksum_start = head_end;
const checksum_end = checksum_start + std.crypto.hash.sha2.Sha256.digest_length;
pub const encoded_size = checksum_end;
const has_head: u16 = 1 << 0;
const known_flags = has_head;

comptime {
    std.debug.assert(@sizeOf(store.ObjectRef) == store.object_ref_size);
    std.debug.assert(checksum_end <= store.anchor_size);
}

pub fn encode(state: State) store.Anchor {
    var encoded: store.Anchor = @splat(0);
    @memcpy(encoded[magic_start..magic_end], magic);
    std.mem.writeInt(u16, encoded[version_start..version_end], format_version, .big);
    std.mem.writeInt(u64, encoded[generation_start..generation_end], state.generation, .big);
    @memcpy(encoded[transaction_id_start..transaction_id_end], &state.transaction_id);
    if (state.head) |head| {
        std.mem.writeInt(u16, encoded[flags_start..flags_end], has_head, .big);
        @memcpy(encoded[head_start..head_end], &head.bytes);
    }
    seal(&encoded);
    return encoded;
}

pub fn decode(encoded: *const store.Anchor) Error!State {
    if (!std.mem.eql(u8, encoded[magic_start..magic_end], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, encoded[version_start..version_end], .big) != format_version)
        return error.UnsupportedFormatVersion;

    const flags = std.mem.readInt(u16, encoded[flags_start..flags_end], .big);
    if (flags & ~known_flags != 0) return error.InvalidFlags;
    if (flags & has_head == 0 and !allZero(encoded[head_start..head_end]))
        return error.NonCanonicalEncoding;
    if (!allZero(encoded[checksum_end..])) return error.NonCanonicalEncoding;

    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    checksum(encoded, &expected);
    if (!std.mem.eql(u8, encoded[checksum_start..checksum_end], &expected))
        return error.ChecksumMismatch;

    var head: ?store.ObjectRef = null;
    if (flags & has_head != 0) {
        var object_ref: store.ObjectRef = .{};
        @memcpy(&object_ref.bytes, encoded[head_start..head_end]);
        head = object_ref;
    }
    return .{
        .generation = std.mem.readInt(u64, encoded[generation_start..generation_end], .big),
        .transaction_id = encoded[transaction_id_start..transaction_id_end].*,
        .head = head,
    };
}

fn seal(encoded: *store.Anchor) void {
    checksum(encoded, encoded[checksum_start..checksum_end]);
}

fn checksum(encoded: *const store.Anchor, result: *[std.crypto.hash.sha2.Sha256.digest_length]u8) void {
    var canonical = encoded.*;
    @memset(canonical[checksum_start..checksum_end], 0);
    std.crypto.hash.sha2.Sha256.hash(&canonical, result, .{});
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

test "anchor state round trips" {
    var object_ref: store.ObjectRef = .{};
    for (&object_ref.bytes, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3);
    const transaction_id: store.TransactionId = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    const encoded = encode(.{
        .generation = 42,
        .transaction_id = transaction_id,
        .head = object_ref,
    });
    const decoded = try decode(&encoded);

    try std.testing.expectEqual(@as(u64, 42), decoded.generation);
    try std.testing.expectEqual(transaction_id, decoded.transaction_id);
    try std.testing.expect(store.ObjectRef.eql(object_ref, decoded.head.?));
}

test "anchor v1 encoding matches the golden vector" {
    const transaction_id: store.TransactionId = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var object_ref: store.ObjectRef = .{};
    for (&object_ref.bytes, 64..) |*byte, value| byte.* = @intCast(value);

    const encoded = encode(.{
        .generation = 0x0102030405060708,
        .transaction_id = transaction_id,
        .head = object_ref,
    });
    const expected_prefix = [_]u8{
        'Z', 'C', 'A', 'W', 'F', 'S', 0,   0,
        0,   1,   0,   1,   1,   2,   3,   4,
        5,   6,   7,   8,   0,   1,   2,   3,
        4,   5,   6,   7,   8,   9,   10,  11,
        12,  13,  14,  15,  64,  65,  66,  67,
        68,  69,  70,  71,  72,  73,  74,  75,
        76,  77,  78,  79,  80,  81,  82,  83,
        84,  85,  86,  87,  88,  89,  90,  91,
        92,  93,  94,  95,  96,  97,  98,  99,
        100, 101, 102, 103, 104, 105, 106, 107,
        108, 109, 110, 111, 112, 113, 114, 115,
        116, 117, 118, 119, 120, 121, 122, 123,
        124, 125, 126, 127,
    };
    const expected_checksum = [_]u8{
        0xe8, 0xca, 0x41, 0xe3, 0xab, 0x06, 0x8d, 0xd8,
        0x3c, 0x59, 0x55, 0x0f, 0xb4, 0xd0, 0x64, 0xe3,
        0x31, 0x40, 0x7e, 0x37, 0xd2, 0x17, 0xd5, 0x66,
        0x88, 0x5d, 0xf3, 0x1f, 0xcc, 0xbb, 0x44, 0x0b,
    };
    var expected: store.Anchor = @splat(0);
    @memcpy(expected[0..100], &expected_prefix);
    @memcpy(expected[100..132], &expected_checksum);

    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    const decoded = try decode(&expected);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), decoded.generation);
    try std.testing.expectEqual(transaction_id, decoded.transaction_id);
    try std.testing.expect(store.ObjectRef.eql(object_ref, decoded.head.?));
}

test "anchor without a head round trips canonically" {
    const encoded = encode(.{ .generation = 0, .transaction_id = @splat(0), .head = null });
    const decoded = try decode(&encoded);

    try std.testing.expectEqual(@as(u64, 0), decoded.generation);
    try std.testing.expectEqual(@as(?store.ObjectRef, null), decoded.head);
    try std.testing.expect(allZero(encoded[head_start..head_end]));
}

test "generation changes the physical anchor" {
    const first = encode(.{ .generation = 1, .transaction_id = @splat(0), .head = null });
    const second = encode(.{ .generation = 2, .transaction_id = @splat(0), .head = null });

    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "anchor rejects corruption" {
    var encoded = encode(.{ .generation = 7, .transaction_id = @splat(0), .head = null });
    encoded[generation_start] ^= 1;

    try std.testing.expectError(error.ChecksumMismatch, decode(&encoded));
}

test "anchor rejects unknown flags" {
    var encoded = encode(.{ .generation = 7, .transaction_id = @splat(0), .head = null });
    std.mem.writeInt(u16, encoded[flags_start..flags_end], 1 << 15, .big);
    seal(&encoded);

    try std.testing.expectError(error.InvalidFlags, decode(&encoded));
}

test "anchor rejects unsupported versions" {
    var encoded = encode(.{ .generation = 7, .transaction_id = @splat(0), .head = null });
    std.mem.writeInt(u16, encoded[version_start..version_end], format_version + 1, .big);
    seal(&encoded);

    try std.testing.expectError(error.UnsupportedFormatVersion, decode(&encoded));
}

test "anchor without a head rejects reference bytes" {
    var encoded = encode(.{ .generation = 7, .transaction_id = @splat(0), .head = null });
    encoded[head_start] = 1;
    seal(&encoded);

    try std.testing.expectError(error.NonCanonicalEncoding, decode(&encoded));
}

test "anchor rejects nonzero reserved bytes" {
    var encoded = encode(.{ .generation = 7, .transaction_id = @splat(0), .head = null });
    encoded[store.anchor_size - 1] = 1;
    seal(&encoded);

    try std.testing.expectError(error.NonCanonicalEncoding, decode(&encoded));
}
