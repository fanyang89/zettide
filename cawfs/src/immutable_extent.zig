//! Stable one-object-per-extent encoding for immutable store objects.

const std = @import("std");
const store = @import("store.zig");

pub const format_version: u16 = 1;
pub const header_size: usize = 144;
pub const digest_size = std.crypto.hash.sha2.Sha256.digest_length;

const magic = "ZCAWIM\x00\x00";
const volume_id_start: usize = 96;
const checksum_start: usize = 112;

pub const Identity = struct {
    extent_index: u64,
    claim_epoch: u64,
    claim_id: [16]u8,
    payload_sha256: [digest_size]u8,
};

pub const View = struct {
    identity: Identity,
    payload: []const u8,
};

pub fn objectRef(identity: Identity) !store.ObjectRef {
    try validateIdentity(identity);
    var result: store.ObjectRef = .{};
    std.mem.writeInt(u64, result.bytes[0..8], identity.extent_index, .big);
    std.mem.writeInt(u64, result.bytes[8..16], identity.claim_epoch, .big);
    @memcpy(result.bytes[16..32], &identity.claim_id);
    @memcpy(result.bytes[32..64], &identity.payload_sha256);
    return result;
}

pub fn decodeObjectRef(reference: store.ObjectRef) !Identity {
    const identity = Identity{
        .extent_index = std.mem.readInt(u64, reference.bytes[0..8], .big),
        .claim_epoch = std.mem.readInt(u64, reference.bytes[8..16], .big),
        .claim_id = reference.bytes[16..32].*,
        .payload_sha256 = reference.bytes[32..64].*,
    };
    try validateIdentity(identity);
    return identity;
}

pub fn identityFor(
    extent_index: u64,
    claim_epoch: u64,
    claim_id: [16]u8,
    payload: []const u8,
) !Identity {
    var digest: [digest_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const identity = Identity{
        .extent_index = extent_index,
        .claim_epoch = claim_epoch,
        .claim_id = claim_id,
        .payload_sha256 = digest,
    };
    try validateIdentity(identity);
    return identity;
}

/// Encodes one object and canonical zero padding into a complete extent.
pub fn encode(output: []u8, volume_id: [16]u8, identity: Identity, payload: []const u8) !void {
    try validateIdentity(identity);
    if (allZero(&volume_id)) return error.InvalidVolumeId;
    if (output.len < header_size) return error.ExtentTooSmall;
    if (payload.len > output.len - header_size) return error.ObjectTooLarge;

    var digest: [digest_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    if (!std.mem.eql(u8, &digest, &identity.payload_sha256))
        return error.PayloadDigestMismatch;

    @memset(output, 0);
    @memcpy(output[0..magic.len], magic);
    std.mem.writeInt(u16, output[8..10], format_version, .big);
    std.mem.writeInt(u16, output[10..12], header_size, .big);
    std.mem.writeInt(u64, output[16..24], identity.extent_index, .big);
    std.mem.writeInt(u64, output[24..32], identity.claim_epoch, .big);
    @memcpy(output[32..48], &identity.claim_id);
    std.mem.writeInt(u64, output[48..56], @intCast(payload.len), .big);
    @memcpy(output[64..96], &identity.payload_sha256);
    @memcpy(output[volume_id_start..checksum_start], &volume_id);
    sealHeader(output[0..header_size]);
    @memcpy(output[header_size..][0..payload.len], payload);
}

pub fn decode(extent: []const u8, volume_id: [16]u8, expected: store.ObjectRef) !View {
    if (extent.len < header_size) return error.ExtentTooSmall;
    if (allZero(&volume_id)) return error.InvalidVolumeId;
    const identity = try decodeObjectRef(expected);
    if (!std.mem.eql(u8, extent[0..magic.len], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, extent[8..10], .big) != format_version)
        return error.UnsupportedFormatVersion;
    if (std.mem.readInt(u16, extent[10..12], .big) != header_size or
        !allZero(extent[12..16]) or
        !allZero(extent[56..64]))
    {
        return error.NonCanonicalEncoding;
    }
    if (!verifyHeader(extent[0..header_size])) return error.HeaderChecksumMismatch;
    if (!std.mem.eql(u8, extent[volume_id_start..checksum_start], &volume_id))
        return error.VolumeMismatch;

    const payload_len_u64 = std.mem.readInt(u64, extent[48..56], .big);
    const payload_len = std.math.cast(usize, payload_len_u64) orelse
        return error.InvalidPayloadLength;
    if (payload_len > extent.len - header_size) return error.InvalidPayloadLength;
    const observed = Identity{
        .extent_index = std.mem.readInt(u64, extent[16..24], .big),
        .claim_epoch = std.mem.readInt(u64, extent[24..32], .big),
        .claim_id = extent[32..48].*,
        .payload_sha256 = extent[64..96].*,
    };
    if (!std.meta.eql(observed, identity)) return error.ObjectReferenceMismatch;

    const payload = extent[header_size..][0..payload_len];
    var digest: [digest_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    if (!std.mem.eql(u8, &digest, &identity.payload_sha256))
        return error.PayloadDigestMismatch;
    if (!allZero(extent[header_size + payload_len ..]))
        return error.NonCanonicalPadding;
    return .{ .identity = identity, .payload = payload };
}

fn validateIdentity(identity: Identity) !void {
    if (identity.claim_epoch == 0) return error.InvalidClaimEpoch;
    if (allZero(&identity.claim_id)) return error.InvalidClaimId;
}

fn sealHeader(header: []u8) void {
    var checksum: [digest_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(header[0..checksum_start], &checksum, .{});
    @memcpy(header[checksum_start..header_size], &checksum);
}

fn verifyHeader(header: []const u8) bool {
    var checksum: [digest_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(header[0..checksum_start], &checksum, .{});
    return std.mem.eql(u8, header[checksum_start..header_size], &checksum);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn testId(seed: u8) [16]u8 {
    var result: [16]u8 = undefined;
    for (&result, seed..) |*byte, value| byte.* = @intCast(value);
    return result;
}

test "immutable extents and object references round trip" {
    for ([_]usize{ 512, 4096 }) |extent_size| {
        const payload = "immutable payload";
        const identity = try identityFor(9, 7, testId(1), payload);
        const reference = try objectRef(identity);
        const bytes = try std.testing.allocator.alloc(u8, extent_size);
        defer std.testing.allocator.free(bytes);
        try encode(bytes, testId(0x80), identity, payload);
        const view = try decode(bytes, testId(0x80), reference);
        try std.testing.expectEqual(identity, view.identity);
        try std.testing.expectEqualStrings(payload, view.payload);
    }
}

test "immutable extent rejects header payload and padding corruption" {
    const payload = "payload";
    const identity = try identityFor(1, 2, testId(3), payload);
    const reference = try objectRef(identity);
    var bytes: [512]u8 = undefined;
    try encode(&bytes, testId(0x80), identity, payload);

    bytes[20] ^= 1;
    try std.testing.expectError(error.HeaderChecksumMismatch, decode(&bytes, testId(0x80), reference));
    try encode(&bytes, testId(0x80), identity, payload);
    bytes[header_size] ^= 1;
    try std.testing.expectError(error.PayloadDigestMismatch, decode(&bytes, testId(0x80), reference));
    try encode(&bytes, testId(0x80), identity, payload);
    bytes[bytes.len - 1] = 1;
    try std.testing.expectError(error.NonCanonicalPadding, decode(&bytes, testId(0x80), reference));
}

test "immutable extent is bound to its volume" {
    const identity = try identityFor(1, 2, testId(3), "payload");
    const reference = try objectRef(identity);
    var bytes: [512]u8 = undefined;
    try encode(&bytes, testId(0x80), identity, "payload");
    try std.testing.expectError(error.VolumeMismatch, decode(&bytes, testId(0x90), reference));
}

test "object reference encoding is stable" {
    const identity = Identity{
        .extent_index = 0x0102030405060708,
        .claim_epoch = 0x1112131415161718,
        .claim_id = testId(0x20),
        .payload_sha256 = @splat(0x55),
    };
    const reference = try objectRef(identity);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }, reference.bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 }, reference.bytes[8..16]);
    try std.testing.expectEqual(identity, try decodeObjectRef(reference));
}
