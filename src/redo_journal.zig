const std = @import("std");
const google_crc32c = @import("crc32c");

pub const alignment: usize = 512;
pub const block_size: usize = 4096;
pub const data_record_size: usize = alignment + block_size;
pub const max_blocks_per_transaction: u32 = 4096;
pub const Digest = [32]u8;
pub const zero_digest: Digest = @splat(0);

const magic = [8]u8{ 'Z', 'R', 'E', 'D', 'O', '0', '1', 0 };
const format_version: u16 = 1;
const checksum_offset = alignment - @sizeOf(u32);
const digest_domain = "zettide-redo-transaction-v1\x00";

const RecordKind = enum(u8) {
    begin = 1,
    data = 2,
    commit = 3,
};

pub const BlockImage = struct {
    block: u32,
    bytes: []const u8,
};

pub const Metadata = struct {
    sequence: u64,
    previous_digest: Digest = zero_digest,
};

pub const DecodedTransaction = struct {
    sequence: u64,
    previous_digest: Digest,
    transaction_digest: Digest,
    encoded_digest: Digest,
    encoded_length: usize,
    blocks: []BlockImage,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedTransaction) void {
        self.allocator.free(self.blocks);
        self.* = undefined;
    }
};

pub const ScanResult = struct {
    transaction_count: u64 = 0,
    consumed: usize = 0,
    tail_sequence: ?u64 = null,
    tail_digest: Digest = zero_digest,
    unresolved_tail_damage: bool = false,
};

const Header = struct {
    kind: RecordKind,
    record_length: u32,
    sequence: u64,
    record_index: u32,
    record_count: u32,
    target_block: u32,
    payload_length: u32,
    previous_digest: Digest,
    payload_digest: Digest,
    transaction_digest: Digest,
};

pub fn encodedSize(block_count: usize) !usize {
    if (block_count > max_blocks_per_transaction) return error.TransactionTooLarge;
    const data_size = std.math.mul(usize, block_count, data_record_size) catch
        return error.TransactionTooLarge;
    return std.math.add(usize, 2 * alignment, data_size) catch
        error.TransactionTooLarge;
}

pub fn encode(
    allocator: std.mem.Allocator,
    metadata: Metadata,
    blocks: []const BlockImage,
) ![]u8 {
    if (metadata.sequence == 0) return error.InvalidSequence;
    try validateBlocks(blocks);
    const size = try encodedSize(blocks.len);
    const encoded = try allocator.alloc(u8, size);
    errdefer allocator.free(encoded);
    @memset(encoded, 0);

    const transaction_digest = computeTransactionDigest(metadata, blocks);
    encodeHeader(encoded[0..alignment], .{
        .kind = .begin,
        .record_length = alignment,
        .sequence = metadata.sequence,
        .record_index = 0,
        .record_count = @intCast(blocks.len),
        .target_block = std.math.maxInt(u32),
        .payload_length = 0,
        .previous_digest = metadata.previous_digest,
        .payload_digest = zero_digest,
        .transaction_digest = zero_digest,
    });

    var offset: usize = alignment;
    for (blocks, 0..) |block, index| {
        const payload = encoded[offset + alignment ..][0..block_size];
        @memcpy(payload, block.bytes);
        encodeHeader(encoded[offset..][0..alignment], .{
            .kind = .data,
            .record_length = data_record_size,
            .sequence = metadata.sequence,
            .record_index = @intCast(index),
            .record_count = @intCast(blocks.len),
            .target_block = block.block,
            .payload_length = block_size,
            .previous_digest = metadata.previous_digest,
            .payload_digest = hash(payload),
            .transaction_digest = zero_digest,
        });
        offset += data_record_size;
    }

    encodeHeader(encoded[offset..][0..alignment], .{
        .kind = .commit,
        .record_length = alignment,
        .sequence = metadata.sequence,
        .record_index = @intCast(blocks.len),
        .record_count = @intCast(blocks.len),
        .target_block = std.math.maxInt(u32),
        .payload_length = 0,
        .previous_digest = metadata.previous_digest,
        .payload_digest = zero_digest,
        .transaction_digest = transaction_digest,
    });
    return encoded;
}

pub fn decode(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    target_block_count: u32,
) !DecodedTransaction {
    if (encoded.len < alignment) return error.TruncatedTransaction;
    const begin = try decodeHeader(encoded[0..alignment]);
    if (begin.kind != .begin or begin.record_length != alignment or
        begin.record_index != 0 or begin.target_block != std.math.maxInt(u32) or
        begin.payload_length != 0 or begin.sequence == 0 or
        !std.mem.eql(u8, &begin.payload_digest, &zero_digest) or
        !std.mem.eql(u8, &begin.transaction_digest, &zero_digest))
        return error.InvalidBeginRecord;
    if (begin.record_count > max_blocks_per_transaction) return error.TransactionTooLarge;
    const length = try encodedSize(begin.record_count);
    if (encoded.len < length) return error.TruncatedTransaction;

    const blocks = try allocator.alloc(BlockImage, begin.record_count);
    errdefer allocator.free(blocks);
    var offset: usize = alignment;
    for (blocks, 0..) |*block, index| {
        const header = try decodeHeader(encoded[offset..][0..alignment]);
        if (header.kind != .data or header.record_length != data_record_size or
            header.sequence != begin.sequence or header.record_index != index or
            header.record_count != begin.record_count or header.payload_length != block_size or
            !std.mem.eql(u8, &header.previous_digest, &begin.previous_digest) or
            !std.mem.eql(u8, &header.transaction_digest, &zero_digest))
            return error.InvalidDataRecord;
        if (header.target_block >= target_block_count) return error.TargetBlockOutOfBounds;
        if (index != 0 and blocks[index - 1].block >= header.target_block)
            return error.UnorderedTargetBlocks;
        const payload = encoded[offset + alignment ..][0..block_size];
        if (!std.mem.eql(u8, &header.payload_digest, &hash(payload)))
            return error.InvalidPayloadDigest;
        block.* = .{ .block = header.target_block, .bytes = payload };
        offset += data_record_size;
    }

    const commit = try decodeHeader(encoded[offset..][0..alignment]);
    if (commit.kind != .commit or commit.record_length != alignment or
        commit.sequence != begin.sequence or commit.record_index != begin.record_count or
        commit.record_count != begin.record_count or commit.target_block != std.math.maxInt(u32) or
        commit.payload_length != 0 or
        !std.mem.eql(u8, &commit.previous_digest, &begin.previous_digest) or
        !std.mem.eql(u8, &commit.payload_digest, &zero_digest))
        return error.InvalidCommitRecord;
    const metadata: Metadata = .{
        .sequence = begin.sequence,
        .previous_digest = begin.previous_digest,
    };
    const expected_digest = computeTransactionDigest(metadata, blocks);
    if (!std.mem.eql(u8, &commit.transaction_digest, &expected_digest))
        return error.InvalidTransactionDigest;

    return .{
        .sequence = begin.sequence,
        .previous_digest = begin.previous_digest,
        .transaction_digest = commit.transaction_digest,
        .encoded_digest = hash(encoded[0..length]),
        .encoded_length = length,
        .blocks = blocks,
        .allocator = allocator,
    };
}

pub fn scanLinear(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    target_block_count: u32,
) !ScanResult {
    if (encoded.len % alignment != 0) return error.UnalignedJournal;
    var result: ScanResult = .{};
    while (result.consumed < encoded.len) {
        const remaining = encoded[result.consumed..];
        if (isZero(remaining[0..alignment])) break;
        var transaction = decode(allocator, remaining, target_block_count) catch {
            result.unresolved_tail_damage = true;
            break;
        };
        defer transaction.deinit();
        if (result.tail_sequence) |sequence| {
            if (transaction.sequence != std.math.add(u64, sequence, 1) catch
                return error.SequenceOverflow)
                return error.TransactionSequenceGap;
            if (!std.mem.eql(u8, &transaction.previous_digest, &result.tail_digest))
                return error.PreviousTransactionDigestMismatch;
        } else if (!std.mem.eql(u8, &transaction.previous_digest, &zero_digest)) {
            return error.MissingJournalPrefix;
        }
        result.transaction_count = std.math.add(u64, result.transaction_count, 1) catch
            return error.TransactionCountOverflow;
        result.consumed += transaction.encoded_length;
        result.tail_sequence = transaction.sequence;
        result.tail_digest = transaction.encoded_digest;
    }
    return result;
}

fn validateBlocks(blocks: []const BlockImage) !void {
    if (blocks.len > max_blocks_per_transaction) return error.TransactionTooLarge;
    for (blocks, 0..) |block, index| {
        if (block.bytes.len != block_size) return error.InvalidBlockSize;
        if (index != 0 and blocks[index - 1].block >= block.block)
            return error.UnorderedTargetBlocks;
    }
}

fn computeTransactionDigest(metadata: Metadata, blocks: []const BlockImage) Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(digest_domain);
    var scalar: [8]u8 = undefined;
    std.mem.writeInt(u64, &scalar, metadata.sequence, .little);
    hasher.update(&scalar);
    hasher.update(&metadata.previous_digest);
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, @intCast(blocks.len), .little);
    hasher.update(&count);
    for (blocks) |block| {
        var target: [4]u8 = undefined;
        std.mem.writeInt(u32, &target, block.block, .little);
        hasher.update(&target);
        hasher.update(block.bytes);
    }
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

fn encodeHeader(bytes: []u8, header: Header) void {
    std.debug.assert(bytes.len == alignment);
    @memset(bytes, 0);
    @memcpy(bytes[0..magic.len], &magic);
    putInt(u16, bytes, 8, format_version);
    bytes[10] = @intFromEnum(header.kind);
    putInt(u32, bytes, 12, header.record_length);
    putInt(u64, bytes, 16, header.sequence);
    putInt(u32, bytes, 24, header.record_index);
    putInt(u32, bytes, 28, header.record_count);
    putInt(u32, bytes, 32, header.target_block);
    putInt(u32, bytes, 36, header.payload_length);
    @memcpy(bytes[40..72], &header.previous_digest);
    @memcpy(bytes[72..104], &header.payload_digest);
    @memcpy(bytes[104..136], &header.transaction_digest);
    putInt(u32, bytes, checksum_offset, google_crc32c.value(bytes[0..checksum_offset]));
}

fn decodeHeader(bytes: []const u8) !Header {
    if (bytes.len != alignment) return error.TruncatedRecord;
    if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidRecordMagic;
    if (getInt(u16, bytes, 8) != format_version) return error.UnsupportedRecordFormat;
    if (getInt(u32, bytes, checksum_offset) != google_crc32c.value(bytes[0..checksum_offset]))
        return error.InvalidRecordChecksum;
    return .{
        .kind = std.enums.fromInt(RecordKind, bytes[10]) orelse return error.InvalidRecordKind,
        .record_length = getInt(u32, bytes, 12),
        .sequence = getInt(u64, bytes, 16),
        .record_index = getInt(u32, bytes, 24),
        .record_count = getInt(u32, bytes, 28),
        .target_block = getInt(u32, bytes, 32),
        .payload_length = getInt(u32, bytes, 36),
        .previous_digest = bytes[40..72].*,
        .payload_digest = bytes[72..104].*,
        .transaction_digest = bytes[104..136].*,
    };
}

fn hash(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.Blake3.hash(bytes, &result, .{});
    return result;
}

fn isZero(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0);
}

fn putInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn getInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "redo transaction round trip" {
    var first: [block_size]u8 = @splat(0x11);
    var second: [block_size]u8 = @splat(0x22);
    const blocks = [_]BlockImage{
        .{ .block = 2, .bytes = &first },
        .{ .block = 9, .bytes = &second },
    };
    const encoded = try encode(std.testing.allocator, .{ .sequence = 7 }, &blocks);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(try encodedSize(blocks.len), encoded.len);

    var decoded = try decode(std.testing.allocator, encoded, 16);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 7), decoded.sequence);
    try std.testing.expectEqualSlices(u8, &zero_digest, &decoded.previous_digest);
    try std.testing.expectEqual(@as(usize, 2), decoded.blocks.len);
    try std.testing.expectEqual(@as(u32, 2), decoded.blocks[0].block);
    try std.testing.expectEqualSlices(u8, &first, decoded.blocks[0].bytes);
    try std.testing.expectEqual(@as(u32, 9), decoded.blocks[1].block);
    try std.testing.expectEqualSlices(u8, &second, decoded.blocks[1].bytes);
}

test "redo transaction rejects damaged records and payloads" {
    var payload: [block_size]u8 = @splat(0x5a);
    const blocks = [_]BlockImage{.{ .block = 1, .bytes = &payload }};
    const original = try encode(std.testing.allocator, .{ .sequence = 1 }, &blocks);
    defer std.testing.allocator.free(original);

    var damaged = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(damaged);
    damaged[16] ^= 1;
    try std.testing.expectError(error.InvalidRecordChecksum, decode(std.testing.allocator, damaged, 8));

    @memcpy(damaged, original);
    damaged[alignment + alignment + 17] ^= 1;
    try std.testing.expectError(error.InvalidPayloadDigest, decode(std.testing.allocator, damaged, 8));

    @memcpy(damaged, original);
    const commit_offset = alignment + data_record_size;
    damaged[commit_offset + 104] ^= 1;
    putInt(
        u32,
        damaged[commit_offset..][0..alignment],
        checksum_offset,
        google_crc32c.value(damaged[commit_offset..][0..checksum_offset]),
    );
    try std.testing.expectError(error.InvalidTransactionDigest, decode(std.testing.allocator, damaged, 8));
}

test "redo transaction validates block ordering and bounds" {
    var payload: [block_size]u8 = @splat(0x33);
    const unordered = [_]BlockImage{
        .{ .block = 4, .bytes = &payload },
        .{ .block = 4, .bytes = &payload },
    };
    try std.testing.expectError(
        error.UnorderedTargetBlocks,
        encode(std.testing.allocator, .{ .sequence = 1 }, &unordered),
    );

    const blocks = [_]BlockImage{.{ .block = 7, .bytes = &payload }};
    const encoded = try encode(std.testing.allocator, .{ .sequence = 1 }, &blocks);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.TargetBlockOutOfBounds, decode(std.testing.allocator, encoded, 7));
}

test "linear scan accepts a digest chain and ignores a torn tail" {
    var first_payload: [block_size]u8 = @splat(0x41);
    const first_blocks = [_]BlockImage{.{ .block = 1, .bytes = &first_payload }};
    const first = try encode(std.testing.allocator, .{ .sequence = 1 }, &first_blocks);
    defer std.testing.allocator.free(first);
    const first_digest = hash(first);

    var second_payload: [block_size]u8 = @splat(0x42);
    const second_blocks = [_]BlockImage{.{ .block = 2, .bytes = &second_payload }};
    const second = try encode(std.testing.allocator, .{
        .sequence = 2,
        .previous_digest = first_digest,
    }, &second_blocks);
    defer std.testing.allocator.free(second);

    var third_payload: [block_size]u8 = @splat(0x43);
    const third_blocks = [_]BlockImage{.{ .block = 3, .bytes = &third_payload }};
    const third = try encode(std.testing.allocator, .{
        .sequence = 3,
        .previous_digest = hash(second),
    }, &third_blocks);
    defer std.testing.allocator.free(third);

    const torn_length = alignment + 2 * alignment;
    const journal = try std.testing.allocator.alloc(u8, first.len + second.len + torn_length + alignment);
    defer std.testing.allocator.free(journal);
    @memcpy(journal[0..first.len], first);
    @memcpy(journal[first.len..][0..second.len], second);
    @memcpy(journal[first.len + second.len ..][0..torn_length], third[0..torn_length]);
    @memset(journal[first.len + second.len + torn_length ..], 0);

    const result = try scanLinear(std.testing.allocator, journal, 16);
    try std.testing.expectEqual(@as(u64, 2), result.transaction_count);
    try std.testing.expectEqual(first.len + second.len, result.consumed);
    try std.testing.expectEqual(@as(?u64, 2), result.tail_sequence);
    try std.testing.expect(result.unresolved_tail_damage);
}

test "linear scan rejects a broken digest chain" {
    var payload: [block_size]u8 = @splat(0x70);
    const blocks = [_]BlockImage{.{ .block = 0, .bytes = &payload }};
    const first = try encode(std.testing.allocator, .{ .sequence = 1 }, &blocks);
    defer std.testing.allocator.free(first);
    const second = try encode(std.testing.allocator, .{
        .sequence = 2,
        .previous_digest = @splat(0xaa),
    }, &blocks);
    defer std.testing.allocator.free(second);
    const journal = try std.testing.allocator.alloc(u8, first.len + second.len);
    defer std.testing.allocator.free(journal);
    @memcpy(journal[0..first.len], first);
    @memcpy(journal[first.len..], second);
    try std.testing.expectError(
        error.PreviousTransactionDigestMismatch,
        scanLinear(std.testing.allocator, journal, 4),
    );
}
