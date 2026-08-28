//! Stable full-block claim-operation gate format.

const std = @import("std");
const store = @import("store.zig");

pub const format_version: u16 = 1;
pub const header_size: usize = 64;
pub const descriptor_size: usize = 112;
pub const checksum_size = std.crypto.hash.sha2.Sha256.digest_length;

const magic = "ZCAWCG\x00\x00";

pub const Operation = enum(u8) {
    idle = 0,
    claim = 1,
    release = 2,
};

pub const Phase = enum(u8) {
    idle = 0,
    claim_lookup = 1,
    claim_extent = 2,
    claim_index = 3,
    release_lookup = 4,
    release_index = 5,
    release_extent = 6,
};

pub const TargetState = enum(u8) {
    none = 0,
    index_empty = 1,
    index_tombstone = 2,
    index_bound = 3,
    extent_free = 4,
    extent_retired = 5,
};

pub const Descriptor = struct {
    operation: Operation = .idle,
    phase: Phase = .idle,
    kind: u8 = 0,
    expected_target_state: TargetState = .none,
    claim_id: [16]u8 = @splat(0),
    owner_id: [16]u8 = @splat(0),
    owner_incarnation: [16]u8 = @splat(0),
    base_generation: u64 = 0,
    owner_epoch: u64 = 0,
    claim_epoch: u64 = 0,
    extent_index: u64 = std.math.maxInt(u64),
    index_slot: u64 = std.math.maxInt(u64),
    target_page_generation: u64 = 0,
    transition_generation: u64 = 0,

    pub fn idle() Descriptor {
        return .{
            .extent_index = 0,
            .index_slot = 0,
        };
    }

    pub fn validate(self: Descriptor) !void {
        if (self.operation == .idle) {
            if (!std.meta.eql(self, Descriptor.idle())) return error.InvalidIdleDescriptor;
            return;
        }
        if (allZero(&self.claim_id) or allZero(&self.owner_id) or
            allZero(&self.owner_incarnation) or self.owner_epoch == 0 or
            self.claim_epoch == 0 or self.base_generation == std.math.maxInt(u64) or
            (self.kind != 1 and self.kind != 2))
        {
            return error.InvalidOperationIdentity;
        }
        switch (self.operation) {
            .idle => unreachable,
            .claim => {
                if (self.transition_generation != 0) return error.InvalidOperationPhase;
                switch (self.phase) {
                    .claim_lookup => if (self.expected_target_state != .none or
                        self.extent_index != std.math.maxInt(u64) or
                        self.index_slot != std.math.maxInt(u64) or
                        self.target_page_generation != 0)
                        return error.InvalidOperationPhase,
                    .claim_extent => if (self.expected_target_state != .extent_free or
                        self.extent_index == std.math.maxInt(u64) or
                        self.index_slot != std.math.maxInt(u64))
                        return error.InvalidOperationPhase,
                    .claim_index => if ((self.expected_target_state != .index_empty and
                        self.expected_target_state != .index_tombstone) or
                        self.extent_index == std.math.maxInt(u64) or
                        self.index_slot == std.math.maxInt(u64))
                        return error.InvalidOperationPhase,
                    else => return error.InvalidOperationPhase,
                }
            },
            .release => {
                if (self.extent_index == std.math.maxInt(u64) or
                    self.transition_generation <= self.base_generation)
                    return error.InvalidOperationPhase;
                switch (self.phase) {
                    .release_lookup => if (self.expected_target_state != .none or
                        self.index_slot != std.math.maxInt(u64) or
                        self.target_page_generation != 0)
                        return error.InvalidOperationPhase,
                    .release_index => if (self.expected_target_state != .index_bound or
                        self.index_slot == std.math.maxInt(u64))
                        return error.InvalidOperationPhase,
                    .release_extent => if (self.expected_target_state != .extent_retired)
                        return error.InvalidOperationPhase,
                    else => return error.InvalidOperationPhase,
                }
            },
        }
    }
};

pub const View = struct {
    bytes: []const u8,
    volume_id: [16]u8,
    stripe_index: u64,
    stripe_count: u32,
    generation: u64,
    descriptor: Descriptor,
};

pub fn encode(
    allocator: std.mem.Allocator,
    logical_block_size: u32,
    volume_id: [16]u8,
    stripe_index: u64,
    stripe_count: u32,
    generation: u64,
    descriptor: Descriptor,
) !store.OwnedBytes {
    try validateGeometry(logical_block_size, volume_id, stripe_index, stripe_count);
    try descriptor.validate();
    const bytes = try allocator.alloc(u8, logical_block_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], magic);
    putInt(u16, bytes, 8, format_version);
    putInt(u16, bytes, 12, header_size);
    putInt(u16, bytes, 14, descriptor_size);
    putInt(u64, bytes, 16, stripe_index);
    putInt(u64, bytes, 24, generation);
    putInt(u32, bytes, 32, stripe_count);
    @memcpy(bytes[40..56], &volume_id);
    encodeDescriptor(bytes[header_size..][0..descriptor_size], descriptor);
    seal(bytes);
    return .{ .allocator = allocator, .bytes = bytes };
}

pub fn decode(
    bytes: []const u8,
    expected_volume_id: [16]u8,
    expected_stripe_index: u64,
    expected_stripe_count: u32,
) !View {
    const block_size = std.math.cast(u32, bytes.len) orelse
        return error.UnsupportedLogicalBlockSize;
    try validateGeometry(
        block_size,
        expected_volume_id,
        expected_stripe_index,
        expected_stripe_count,
    );
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidMagic;
    if (getInt(u16, bytes, 8) != format_version) return error.UnsupportedFormatVersion;
    if (getInt(u16, bytes, 10) != 0 or
        getInt(u16, bytes, 12) != header_size or
        getInt(u16, bytes, 14) != descriptor_size or
        getInt(u32, bytes, 36) != 0 or
        !allZero(bytes[56..header_size]))
    {
        return error.NonCanonicalEncoding;
    }
    if (!verifyChecksum(bytes)) return error.ChecksumMismatch;
    if (!allZero(bytes[header_size + descriptor_size .. checksumOffset(bytes.len)]))
        return error.NonCanonicalEncoding;
    if (!std.mem.eql(u8, bytes[40..56], &expected_volume_id) or
        getInt(u64, bytes, 16) != expected_stripe_index or
        getInt(u32, bytes, 32) != expected_stripe_count)
    {
        return error.GatePositionMismatch;
    }
    const descriptor = try decodeDescriptor(bytes[header_size..][0..descriptor_size]);
    return .{
        .bytes = bytes,
        .volume_id = bytes[40..56].*,
        .stripe_index = getInt(u64, bytes, 16),
        .stripe_count = getInt(u32, bytes, 32),
        .generation = getInt(u64, bytes, 24),
        .descriptor = descriptor,
    };
}

fn validateGeometry(block_size: u32, volume_id: [16]u8, stripe: u64, count: u32) !void {
    if (block_size != 512 and block_size != 4096) return error.UnsupportedLogicalBlockSize;
    if (allZero(&volume_id)) return error.InvalidVolumeId;
    if (count == 0 or !std.math.isPowerOfTwo(count) or stripe >= count)
        return error.InvalidStripeGeometry;
}

fn encodeDescriptor(output: []u8, descriptor: Descriptor) void {
    output[0] = @intFromEnum(descriptor.operation);
    output[1] = @intFromEnum(descriptor.phase);
    output[2] = descriptor.kind;
    output[3] = @intFromEnum(descriptor.expected_target_state);
    @memcpy(output[8..24], &descriptor.claim_id);
    @memcpy(output[24..40], &descriptor.owner_id);
    @memcpy(output[40..56], &descriptor.owner_incarnation);
    putInt(u64, output, 56, descriptor.base_generation);
    putInt(u64, output, 64, descriptor.owner_epoch);
    putInt(u64, output, 72, descriptor.claim_epoch);
    putInt(u64, output, 80, descriptor.extent_index);
    putInt(u64, output, 88, descriptor.index_slot);
    putInt(u64, output, 96, descriptor.target_page_generation);
    putInt(u64, output, 104, descriptor.transition_generation);
}

fn decodeDescriptor(input: []const u8) !Descriptor {
    if (!allZero(input[4..8])) return error.NonCanonicalEncoding;
    const descriptor = Descriptor{
        .operation = std.enums.fromInt(Operation, input[0]) orelse return error.InvalidOperation,
        .phase = std.enums.fromInt(Phase, input[1]) orelse return error.InvalidPhase,
        .kind = input[2],
        .expected_target_state = std.enums.fromInt(TargetState, input[3]) orelse
            return error.InvalidTargetState,
        .claim_id = input[8..24].*,
        .owner_id = input[24..40].*,
        .owner_incarnation = input[40..56].*,
        .base_generation = getInt(u64, input, 56),
        .owner_epoch = getInt(u64, input, 64),
        .claim_epoch = getInt(u64, input, 72),
        .extent_index = getInt(u64, input, 80),
        .index_slot = getInt(u64, input, 88),
        .target_page_generation = getInt(u64, input, 96),
        .transition_generation = getInt(u64, input, 104),
    };
    try descriptor.validate();
    return descriptor;
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

test "claim gate round trips and binds its physical position" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        const volume_id = patternedId(1);
        const descriptor = Descriptor{
            .operation = .claim,
            .phase = .claim_extent,
            .kind = 2,
            .expected_target_state = .extent_free,
            .claim_id = patternedId(17),
            .owner_id = patternedId(33),
            .owner_incarnation = patternedId(49),
            .base_generation = 3,
            .owner_epoch = 4,
            .claim_epoch = 5,
            .extent_index = 6,
            .target_page_generation = 7,
        };
        var encoded = try encode(std.testing.allocator, block_size, volume_id, 2, 4, 9, descriptor);
        defer encoded.deinit();
        const view = try decode(encoded.bytes, volume_id, 2, 4);
        try std.testing.expectEqual(@as(u64, 9), view.generation);
        try std.testing.expectEqual(descriptor, view.descriptor);
        try std.testing.expectError(error.GatePositionMismatch, decode(encoded.bytes, volume_id, 1, 4));
    }
}

test "claim gate golden vector and validation" {
    const volume_id = patternedId(1);
    var encoded = try encode(std.testing.allocator, 512, volume_id, 0, 1, 0, Descriptor.idle());
    defer encoded.deinit();
    try std.testing.expectEqualSlices(u8, "ZCAWCG\x00\x00", encoded.bytes[0..8]);
    try std.testing.expectEqual(@as(u8, 1), encoded.bytes[9]);
    try std.testing.expectEqual(@as(u8, 64), encoded.bytes[13]);
    try std.testing.expectEqual(@as(u8, 112), encoded.bytes[15]);
    try std.testing.expectEqualSlices(u8, &volume_id, encoded.bytes[40..56]);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x56, 0xa2, 0x0d, 0x9c, 0xe6, 0x44, 0x0b, 0x5d,
        0x53, 0x7f, 0x0b, 0x3e, 0xed, 0x01, 0xb8, 0x8f,
        0xc8, 0x11, 0xf0, 0x7b, 0xb2, 0xb7, 0xf4, 0x4a,
        0x45, 0xf3, 0x8f, 0x0d, 0x5b, 0x2c, 0x1a, 0x18,
    }, encoded.bytes[480..512]);
    encoded.bytes[200] = 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(encoded.bytes, volume_id, 0, 1));

    encoded.bytes[200] = 0;
    encoded.bytes[64] = @intFromEnum(Operation.claim);
    seal(encoded.bytes);
    try std.testing.expectError(error.InvalidOperationIdentity, decode(encoded.bytes, volume_id, 0, 1));
}
