//! Stable encoding for the conditionally published filesystem anchor.

const std = @import("std");
const store = @import("store.zig");

pub const format_version: u16 = 2;

pub const Mode = enum(u8) {
    active = 1,
    quiescing = 2,
    maintenance = 3,
    blocked = 4,
};

pub const State = struct {
    revision: u64,
    generation: u64,
    transaction_id: store.TransactionId,
    head: ?store.ObjectRef,
    mode: Mode,
    mode_epoch: u64,
    control_operation_id: store.TransactionId = @splat(0),
    control_ref: ?store.ObjectRef = null,
};

pub const Error = error{
    InvalidMagic,
    UnsupportedFormatVersion,
    InvalidFlags,
    NonCanonicalEncoding,
    ChecksumMismatch,
    InvalidMode,
    InvalidModeEpoch,
    InvalidControlState,
    InvalidRevision,
    InvalidGenerationState,
};

const magic = "ZCAWFS\x00\x00";
const magic_start = 0;
const magic_end = magic_start + magic.len;
const version_start = magic_end;
const version_end = version_start + @sizeOf(u16);
const flags_start = version_end;
const flags_end = flags_start + @sizeOf(u16);
const mode_start = flags_end;
const mode_end = mode_start + @sizeOf(u8);
const revision_start = 16;
const revision_end = revision_start + @sizeOf(u64);
const generation_start = revision_end;
const generation_end = generation_start + @sizeOf(u64);
const mode_epoch_start = generation_end;
const mode_epoch_end = mode_epoch_start + @sizeOf(u64);
const transaction_id_start = mode_epoch_end;
const transaction_id_end = transaction_id_start + @sizeOf(store.TransactionId);
const control_operation_id_start = transaction_id_end;
const control_operation_id_end = control_operation_id_start + @sizeOf(store.TransactionId);
const head_start = control_operation_id_end;
const head_end = head_start + store.object_ref_size;
const control_start = head_end;
const control_end = control_start + store.object_ref_size;
const checksum_start = control_end;
const checksum_end = checksum_start + std.crypto.hash.sha2.Sha256.digest_length;
pub const encoded_size = checksum_end;
const has_head: u16 = 1 << 0;
const has_control: u16 = 1 << 1;
const known_flags = has_head | has_control;

comptime {
    std.debug.assert(@sizeOf(store.ObjectRef) == store.object_ref_size);
    std.debug.assert(checksum_end <= store.anchor_size);
}

pub fn encode(state: State) store.Anchor {
    var encoded: store.Anchor = @splat(0);
    @memcpy(encoded[magic_start..magic_end], magic);
    std.mem.writeInt(u16, encoded[version_start..version_end], format_version, .big);
    encoded[mode_start] = @backingInt(state.mode);
    std.mem.writeInt(u64, encoded[revision_start..revision_end], state.revision, .big);
    std.mem.writeInt(u64, encoded[generation_start..generation_end], state.generation, .big);
    std.mem.writeInt(u64, encoded[mode_epoch_start..mode_epoch_end], state.mode_epoch, .big);
    @memcpy(encoded[transaction_id_start..transaction_id_end], &state.transaction_id);
    @memcpy(
        encoded[control_operation_id_start..control_operation_id_end],
        &state.control_operation_id,
    );
    var flags: u16 = 0;
    if (state.head) |head| {
        flags |= has_head;
        @memcpy(encoded[head_start..head_end], &head.bytes);
    }
    if (state.control_ref) |control| {
        flags |= has_control;
        @memcpy(encoded[control_start..control_end], &control.bytes);
    }
    std.mem.writeInt(u16, encoded[flags_start..flags_end], flags, .big);
    seal(&encoded);
    return encoded;
}

pub fn decode(encoded: *const store.Anchor) Error!State {
    if (!std.mem.eql(u8, encoded[magic_start..magic_end], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, encoded[version_start..version_end], .big) != format_version)
        return error.UnsupportedFormatVersion;

    const flags = std.mem.readInt(u16, encoded[flags_start..flags_end], .big);
    if (flags & ~known_flags != 0) return error.InvalidFlags;
    const mode = std.enums.fromInt(Mode, encoded[mode_start]) orelse return error.InvalidMode;
    if (!allZero(encoded[mode_end..revision_start])) return error.NonCanonicalEncoding;
    if (flags & has_head == 0 and !allZero(encoded[head_start..head_end]))
        return error.NonCanonicalEncoding;
    if (flags & has_control == 0 and !allZero(encoded[control_start..control_end]))
        return error.NonCanonicalEncoding;
    if (!allZero(encoded[checksum_end..])) return error.NonCanonicalEncoding;

    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    checksum(encoded, &expected);
    if (!std.mem.eql(u8, encoded[checksum_start..checksum_end], &expected))
        return error.ChecksumMismatch;

    var head: ?store.ObjectRef = null;
    if (flags & has_head != 0) {
        head = objectRef(encoded[head_start..head_end]);
    }
    var control: ?store.ObjectRef = null;
    if (flags & has_control != 0) control = objectRef(encoded[control_start..control_end]);
    const mode_epoch = std.mem.readInt(u64, encoded[mode_epoch_start..mode_epoch_end], .big);
    const control_operation_id = encoded[control_operation_id_start..control_operation_id_end].*;
    const state = State{
        .revision = std.mem.readInt(u64, encoded[revision_start..revision_end], .big),
        .generation = std.mem.readInt(u64, encoded[generation_start..generation_end], .big),
        .transaction_id = encoded[transaction_id_start..transaction_id_end].*,
        .head = head,
        .mode = mode,
        .mode_epoch = mode_epoch,
        .control_operation_id = control_operation_id,
        .control_ref = control,
    };
    try validate(state);
    return state;
}

pub fn validate(state: State) Error!void {
    if (state.revision < state.generation) return error.InvalidRevision;
    if (state.mode_epoch == 0) return error.InvalidModeEpoch;
    const initial = state.generation == 0;
    if (initial != (state.head == null) or initial != allZero(&state.transaction_id))
        return error.InvalidGenerationState;

    const has_operation = !allZero(&state.control_operation_id);
    if (state.mode == .active) {
        if (has_operation) return error.InvalidControlState;
    } else {
        if (!has_operation or state.control_ref == null or
            state.revision == state.generation or state.mode_epoch == 1)
        {
            return error.InvalidControlState;
        }
    }
}

fn objectRef(bytes: *const [store.object_ref_size]u8) store.ObjectRef {
    return .{ .bytes = bytes.* };
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

fn activeState(
    revision: u64,
    generation: u64,
    transaction_id: store.TransactionId,
    head: ?store.ObjectRef,
) State {
    return .{
        .revision = revision,
        .generation = generation,
        .transaction_id = transaction_id,
        .head = head,
        .mode = .active,
        .mode_epoch = 1,
    };
}

test "active anchor may retain control ancestry" {
    const control = objectRef(&@as([store.object_ref_size]u8, @splat(0x52)));
    const encoded = encode(.{
        .revision = 9,
        .generation = 7,
        .transaction_id = @splat(0x31),
        .head = objectRef(&@as([store.object_ref_size]u8, @splat(0x32))),
        .mode = .active,
        .mode_epoch = 2,
        .control_ref = control,
    });

    const decoded = try decode(&encoded);
    try std.testing.expect(store.ObjectRef.eql(control, decoded.control_ref.?));
    try std.testing.expectEqual(@as(store.TransactionId, @splat(0)), decoded.control_operation_id);
}

test "anchor state round trips" {
    var object_ref: store.ObjectRef = .{};
    for (&object_ref.bytes, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3);
    const transaction_id: store.TransactionId = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

    const encoded = encode(activeState(47, 42, transaction_id, object_ref));
    const decoded = try decode(&encoded);

    try std.testing.expectEqual(@as(u64, 47), decoded.revision);
    try std.testing.expectEqual(@as(u64, 42), decoded.generation);
    try std.testing.expectEqual(transaction_id, decoded.transaction_id);
    try std.testing.expect(store.ObjectRef.eql(object_ref, decoded.head.?));
    try std.testing.expectEqual(Mode.active, decoded.mode);
    try std.testing.expectEqual(@as(u64, 1), decoded.mode_epoch);
}

test "anchor v2 encoding matches the golden vector" {
    const transaction_id: store.TransactionId = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var object_ref: store.ObjectRef = .{};
    for (&object_ref.bytes, 64..) |*byte, value| byte.* = @intCast(value);

    const encoded = encode(activeState(
        0x1112131415161718,
        0x0102030405060708,
        transaction_id,
        object_ref,
    ));
    var expected: store.Anchor = @splat(0);
    @memcpy(expected[0..8], magic);
    expected[9] = 2;
    expected[11] = 1;
    expected[12] = @backingInt(Mode.active);
    expected[16..24].* = .{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 };
    expected[24..32].* = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    expected[39] = 1;
    @memcpy(expected[40..56], &transaction_id);
    @memcpy(expected[72..136], &object_ref.bytes);
    @memcpy(expected[200..232], &[_]u8{
        0x35, 0x44, 0x4e, 0xb3, 0x2f, 0x1f, 0x92, 0x1b,
        0x05, 0xb2, 0x45, 0xdd, 0x32, 0x8f, 0x86, 0x54,
        0x3c, 0xa1, 0x61, 0x4d, 0x24, 0xae, 0xdd, 0xfc,
        0x7d, 0xb8, 0x3a, 0xbd, 0x2f, 0xb4, 0x69, 0x6b,
    });

    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    const decoded = try decode(&expected);
    try std.testing.expectEqual(@as(u64, 0x1112131415161718), decoded.revision);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), decoded.generation);
    try std.testing.expectEqual(transaction_id, decoded.transaction_id);
    try std.testing.expect(store.ObjectRef.eql(object_ref, decoded.head.?));
}

test "anchor without a head round trips canonically" {
    const encoded = encode(activeState(0, 0, @splat(0), null));
    const decoded = try decode(&encoded);

    try std.testing.expectEqual(@as(u64, 0), decoded.generation);
    try std.testing.expectEqual(@as(?store.ObjectRef, null), decoded.head);
    try std.testing.expect(allZero(encoded[head_start..head_end]));
}

test "generation changes the physical anchor" {
    const first = encode(activeState(1, 1, @splat(0), null));
    const second = encode(activeState(2, 2, @splat(0), null));

    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "anchor rejects corruption" {
    var encoded = encode(activeState(7, 7, @splat(0), null));
    encoded[generation_start] ^= 1;

    try std.testing.expectError(error.ChecksumMismatch, decode(&encoded));
}

test "anchor rejects unknown flags" {
    var encoded = encode(activeState(7, 7, @splat(0), null));
    std.mem.writeInt(u16, encoded[flags_start..flags_end], 1 << 15, .big);
    seal(&encoded);

    try std.testing.expectError(error.InvalidFlags, decode(&encoded));
}

test "anchor rejects unsupported versions" {
    var encoded = encode(activeState(7, 7, @splat(0), null));
    std.mem.writeInt(u16, encoded[version_start..version_end], format_version - 1, .big);
    seal(&encoded);

    try std.testing.expectError(error.UnsupportedFormatVersion, decode(&encoded));
}

test "anchor without a head rejects reference bytes" {
    var encoded = encode(activeState(7, 7, @splat(0), null));
    encoded[head_start] = 1;
    seal(&encoded);

    try std.testing.expectError(error.NonCanonicalEncoding, decode(&encoded));
}

test "anchor rejects nonzero reserved bytes" {
    var encoded = encode(activeState(7, 7, @splat(0), null));
    encoded[store.anchor_size - 1] = 1;
    seal(&encoded);

    try std.testing.expectError(error.NonCanonicalEncoding, decode(&encoded));
}

test "maintenance anchor requires durable control identity" {
    const operation_id: store.TransactionId = @splat(0x41);
    const control = objectRef(&@as([store.object_ref_size]u8, @splat(0x52)));
    const encoded = encode(.{
        .revision = 8,
        .generation = 7,
        .transaction_id = @splat(0x31),
        .head = objectRef(&@as([store.object_ref_size]u8, @splat(0x32))),
        .mode = .maintenance,
        .mode_epoch = 2,
        .control_operation_id = operation_id,
        .control_ref = control,
    });
    const decoded = try decode(&encoded);
    try std.testing.expectEqual(Mode.maintenance, decoded.mode);
    try std.testing.expectEqual(@as(u64, 2), decoded.mode_epoch);
    try std.testing.expectEqual(operation_id, decoded.control_operation_id);
    try std.testing.expect(store.ObjectRef.eql(control, decoded.control_ref.?));

    var missing_operation = encoded;
    @memset(missing_operation[control_operation_id_start..control_operation_id_end], 0);
    seal(&missing_operation);
    try std.testing.expectError(error.InvalidControlState, decode(&missing_operation));

    var zero_epoch = encoded;
    @memset(zero_epoch[mode_epoch_start..mode_epoch_end], 0);
    seal(&zero_epoch);
    try std.testing.expectError(error.InvalidModeEpoch, decode(&zero_epoch));

    var unchanged_revision = encoded;
    std.mem.writeInt(u64, unchanged_revision[revision_start..revision_end], 7, .big);
    seal(&unchanged_revision);
    try std.testing.expectError(error.InvalidControlState, decode(&unchanged_revision));
}
