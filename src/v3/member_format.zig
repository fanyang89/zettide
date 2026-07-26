const std = @import("std");
const codec = @import("codec.zig");

pub const encoded_size: usize = 4096;
pub const checksum_offset: usize = 0xffc;
pub const initial_member_count: u16 = 3;
pub const metadata_role: u32 = 1;
pub const data_role: u32 = 2;
pub const known_role_flags: u32 = metadata_role | data_role;
pub const checksum_crc32c: u16 = 1;
pub const digest_blake3_256: u16 = 1;
pub const supported_compat_features: u64 = 0;
pub const supported_ro_compat_features: u64 = 0;
pub const supported_incompat_features: u64 = 0;

const magic = [8]u8{ 'D', 'D', 'V', 'M', 'E', 'M', '3', 0 };

pub const Header = struct {
    header_sequence: u64,
    compat_features: u64 = 0,
    ro_compat_features: u64 = 0,
    incompat_features: u64 = 0,
    set_id: [16]u8,
    member_id: [16]u8,
    member_slot: u16,
    member_count: u16 = initial_member_count,
    role_flags: u32 = known_role_flags,
    created_ns: i64,
    member_bytes: u64,
    logical_capacity: u64,
    control: codec.Region,
    metadata: codec.Region,
    data: codec.Region,
    metadata_block_size: u32,
    metadata_read_size: u32,
    metadata_program_size: u32,
    chunk_size: u32,
    metadata_format_version: u16,
    object_format_version: u16,
    layout_format_version: u16,
    control_record_format_version: u16,
    checksum_algorithm: u16 = checksum_crc32c,
    digest_algorithm: u16 = digest_blake3_256,
    label: []const u8,
    genesis_topology_digest: codec.Digest,
    checkpoint_offset: u64 = 0,
    checkpoint_record_sequence: u64 = 0,
    checkpoint_record_digest: codec.Digest = @splat(0),
};

pub const OpenMode = enum { read_only, writable };

pub fn checkFeaturePolicy(header: Header, mode: OpenMode) !void {
    if (header.incompat_features & ~supported_incompat_features != 0)
        return error.UnsupportedIncompatFeature;
    if (mode == .writable and header.ro_compat_features & ~supported_ro_compat_features != 0)
        return error.UnsupportedReadOnlyFeature;
}

pub fn encode(header: Header) ![encoded_size]u8 {
    try validate(header);
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0x000..0x008], &magic);
    codec.putInt(u16, &bytes, 0x008, 3);
    codec.putInt(u16, &bytes, 0x00a, 0);
    codec.putInt(u32, &bytes, 0x00c, encoded_size);
    codec.putInt(u64, &bytes, 0x010, header.header_sequence);
    codec.putInt(u64, &bytes, 0x018, header.compat_features);
    codec.putInt(u64, &bytes, 0x020, header.ro_compat_features);
    codec.putInt(u64, &bytes, 0x028, header.incompat_features);
    @memcpy(bytes[0x030..0x040], &header.set_id);
    @memcpy(bytes[0x040..0x050], &header.member_id);
    codec.putInt(u16, &bytes, 0x050, header.member_slot);
    codec.putInt(u16, &bytes, 0x052, header.member_count);
    codec.putInt(u32, &bytes, 0x054, header.role_flags);
    codec.putInt(i64, &bytes, 0x058, header.created_ns);
    codec.putInt(u64, &bytes, 0x060, header.member_bytes);
    codec.putInt(u64, &bytes, 0x068, header.logical_capacity);
    putRegion(&bytes, 0x070, header.control);
    putRegion(&bytes, 0x080, header.metadata);
    putRegion(&bytes, 0x090, header.data);
    codec.putInt(u32, &bytes, 0x0a0, header.metadata_block_size);
    codec.putInt(u32, &bytes, 0x0a4, header.metadata_read_size);
    codec.putInt(u32, &bytes, 0x0a8, header.metadata_program_size);
    codec.putInt(u32, &bytes, 0x0ac, header.chunk_size);
    codec.putInt(u16, &bytes, 0x0b0, header.metadata_format_version);
    codec.putInt(u16, &bytes, 0x0b2, header.object_format_version);
    codec.putInt(u16, &bytes, 0x0b4, header.layout_format_version);
    codec.putInt(u16, &bytes, 0x0b6, header.control_record_format_version);
    codec.putInt(u16, &bytes, 0x0b8, header.checksum_algorithm);
    codec.putInt(u16, &bytes, 0x0ba, header.digest_algorithm);
    codec.putInt(u16, &bytes, 0x0bc, @intCast(header.label.len));
    @memcpy(bytes[0x0c0..][0..header.label.len], header.label);
    @memcpy(bytes[0x140..0x160], &header.genesis_topology_digest);
    codec.putInt(u64, &bytes, 0x160, header.checkpoint_offset);
    codec.putInt(u64, &bytes, 0x168, header.checkpoint_record_sequence);
    @memcpy(bytes[0x170..0x190], &header.checkpoint_record_digest);
    codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
    return bytes;
}

pub fn decode(bytes: *const [encoded_size]u8) !Header {
    if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
        return error.ChecksumMismatch;
    if (!std.mem.eql(u8, bytes[0x000..0x008], &magic)) return error.InvalidMagic;
    if (codec.getInt(u16, bytes, 0x008) != 3 or codec.getInt(u16, bytes, 0x00a) != 0)
        return error.UnsupportedFormatVersion;
    if (codec.getInt(u32, bytes, 0x00c) != encoded_size) return error.InvalidHeaderSize;
    if (!codec.isZero(bytes[0x190..checksum_offset])) return error.NonZeroReserved;
    if (codec.getInt(u16, bytes, 0x0be) != 0) return error.InvalidHeaderFlags;
    const label_length = codec.getInt(u16, bytes, 0x0bc);
    if (label_length > 127) return error.InvalidLabel;
    if (!codec.isZero(bytes[0x0c0 + label_length .. 0x140])) return error.NonZeroLabelPadding;
    const label = bytes[0x0c0..][0..label_length];
    if (!std.unicode.utf8ValidateSlice(label)) return error.InvalidLabel;

    const header: Header = .{
        .header_sequence = codec.getInt(u64, bytes, 0x010),
        .compat_features = codec.getInt(u64, bytes, 0x018),
        .ro_compat_features = codec.getInt(u64, bytes, 0x020),
        .incompat_features = codec.getInt(u64, bytes, 0x028),
        .set_id = bytes[0x030..0x040].*,
        .member_id = bytes[0x040..0x050].*,
        .member_slot = codec.getInt(u16, bytes, 0x050),
        .member_count = codec.getInt(u16, bytes, 0x052),
        .role_flags = codec.getInt(u32, bytes, 0x054),
        .created_ns = codec.getInt(i64, bytes, 0x058),
        .member_bytes = codec.getInt(u64, bytes, 0x060),
        .logical_capacity = codec.getInt(u64, bytes, 0x068),
        .control = getRegion(bytes, 0x070),
        .metadata = getRegion(bytes, 0x080),
        .data = getRegion(bytes, 0x090),
        .metadata_block_size = codec.getInt(u32, bytes, 0x0a0),
        .metadata_read_size = codec.getInt(u32, bytes, 0x0a4),
        .metadata_program_size = codec.getInt(u32, bytes, 0x0a8),
        .chunk_size = codec.getInt(u32, bytes, 0x0ac),
        .metadata_format_version = codec.getInt(u16, bytes, 0x0b0),
        .object_format_version = codec.getInt(u16, bytes, 0x0b2),
        .layout_format_version = codec.getInt(u16, bytes, 0x0b4),
        .control_record_format_version = codec.getInt(u16, bytes, 0x0b6),
        .checksum_algorithm = codec.getInt(u16, bytes, 0x0b8),
        .digest_algorithm = codec.getInt(u16, bytes, 0x0ba),
        .label = label,
        .genesis_topology_digest = bytes[0x140..0x160].*,
        .checkpoint_offset = codec.getInt(u64, bytes, 0x160),
        .checkpoint_record_sequence = codec.getInt(u64, bytes, 0x168),
        .checkpoint_record_digest = bytes[0x170..0x190].*,
    };
    try validate(header);
    return header;
}

fn validate(header: Header) !void {
    if (header.header_sequence == 0) return error.InvalidSequence;
    if (codec.isZero(&header.set_id) or codec.isZero(&header.member_id) or
        std.mem.eql(u8, &header.set_id, &header.member_id)) return error.InvalidIdentity;
    if (header.member_count != initial_member_count or header.member_slot >= initial_member_count)
        return error.InvalidMemberPlacement;
    if (header.role_flags != known_role_flags) return error.InvalidRoleFlags;
    if (header.checksum_algorithm != checksum_crc32c or header.digest_algorithm != digest_blake3_256)
        return error.UnsupportedAlgorithm;
    if (header.label.len > 127 or !std.unicode.utf8ValidateSlice(header.label)) return error.InvalidLabel;
    if (codec.isZero(&header.genesis_topology_digest)) return error.InvalidTopologyDigest;
    if (!std.math.isPowerOfTwo(header.metadata_block_size) or
        !std.math.isPowerOfTwo(header.metadata_read_size) or
        !std.math.isPowerOfTwo(header.metadata_program_size) or
        !std.math.isPowerOfTwo(header.chunk_size) or
        header.metadata_block_size % header.metadata_read_size != 0 or
        header.metadata_block_size % header.metadata_program_size != 0 or
        header.chunk_size % header.metadata_block_size != 0) return error.InvalidGeometry;

    try header.control.validate(4096);
    try header.metadata.validate(header.metadata_block_size);
    try header.data.validate(header.chunk_size);
    if (header.control.offset != 64 * 1024 or header.control.length < 4096) return error.InvalidGeometry;
    const control_end = try header.control.end();
    if (header.metadata.offset != try codec.alignForward(control_end, 1024 * 1024) or
        header.metadata.length < 256 * 1024) return error.InvalidGeometry;
    const block_count = header.metadata.length / header.metadata_block_size;
    if (block_count < 2 or block_count > std.math.maxInt(u32)) return error.InvalidGeometry;
    const metadata_end = try header.metadata.end();
    if (header.data.offset != try codec.alignForward(metadata_end, 1024 * 1024) or header.data.length == 0)
        return error.InvalidGeometry;
    const data_end = try header.data.end();
    if (header.member_bytes != data_end or header.logical_capacity == 0 or
        header.logical_capacity > header.data.length) return error.InvalidGeometry;
    try codec.validateOrdered(header.control, header.metadata);
    try codec.validateOrdered(header.metadata, header.data);

    const no_checkpoint = header.checkpoint_offset == 0;
    if (no_checkpoint != (header.checkpoint_record_sequence == 0) or
        no_checkpoint != codec.isZero(&header.checkpoint_record_digest)) return error.InvalidCheckpoint;
    if (!no_checkpoint and (header.checkpoint_offset % 4096 != 0 or
        header.checkpoint_offset < header.control.offset or header.checkpoint_offset >= control_end))
        return error.InvalidCheckpoint;
}

pub const Candidate = union(enum) {
    valid: Header,
    invalid: anyerror,
};

pub fn decodeCandidate(bytes: *const [encoded_size]u8) Candidate {
    return .{ .valid = decode(bytes) catch |err| return .{ .invalid = err } };
}

pub const SourceSlot = enum { a, b };
pub const Selection = struct {
    header: Header,
    source: SourceSlot,
    redundancy_degraded: bool,
};

pub fn select(a: Candidate, b: Candidate) !Selection {
    return switch (a) {
        .invalid => switch (b) {
            .invalid => error.NoValidMemberHeader,
            .valid => |header| .{ .header = header, .source = .b, .redundancy_degraded = true },
        },
        .valid => |a_header| switch (b) {
            .invalid => .{ .header = a_header, .source = .a, .redundancy_degraded = true },
            .valid => |b_header| selectValid(a_header, b_header),
        },
    };
}

fn selectValid(a: Header, b: Header) !Selection {
    if (!staticEqual(a, b)) return error.ConflictingMemberHeaders;
    if (a.header_sequence > b.header_sequence)
        return .{ .header = a, .source = .a, .redundancy_degraded = false };
    if (b.header_sequence > a.header_sequence)
        return .{ .header = b, .source = .b, .redundancy_degraded = false };
    if (!mutableEqual(a, b)) return error.AmbiguousMemberHeader;
    return .{ .header = a, .source = .a, .redundancy_degraded = false };
}

fn staticEqual(a: Header, b: Header) bool {
    var a_copy = a;
    var b_copy = b;
    a_copy.header_sequence = 1;
    b_copy.header_sequence = 1;
    a_copy.checkpoint_offset = 0;
    b_copy.checkpoint_offset = 0;
    a_copy.checkpoint_record_sequence = 0;
    b_copy.checkpoint_record_sequence = 0;
    a_copy.checkpoint_record_digest = @splat(0);
    b_copy.checkpoint_record_digest = @splat(0);
    return headerEqual(a_copy, b_copy);
}

fn mutableEqual(a: Header, b: Header) bool {
    return a.checkpoint_offset == b.checkpoint_offset and
        a.checkpoint_record_sequence == b.checkpoint_record_sequence and
        std.mem.eql(u8, &a.checkpoint_record_digest, &b.checkpoint_record_digest);
}

fn headerEqual(a: Header, b: Header) bool {
    inline for (std.meta.fields(Header)) |field| {
        if (field.type == []const u8) {
            if (!std.mem.eql(u8, @field(a, field.name), @field(b, field.name))) return false;
        } else if (!std.meta.eql(@field(a, field.name), @field(b, field.name))) return false;
    }
    return true;
}

fn putRegion(bytes: []u8, offset: usize, region: codec.Region) void {
    codec.putInt(u64, bytes, offset, region.offset);
    codec.putInt(u64, bytes, offset + 8, region.length);
}

fn getRegion(bytes: []const u8, offset: usize) codec.Region {
    return .{ .offset = codec.getInt(u64, bytes, offset), .length = codec.getInt(u64, bytes, offset + 8) };
}

fn testHeader() Header {
    return .{
        .header_sequence = 7,
        .set_id = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff },
        .member_id = .{ 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00 },
        .member_slot = 1,
        .created_ns = 1_700_000_000_123_456_789,
        .member_bytes = 0x41200000,
        .logical_capacity = 0x40000000,
        .control = .{ .offset = 0x10000, .length = 0x20000 },
        .metadata = .{ .offset = 0x100000, .length = 0x100000 },
        .data = .{ .offset = 0x200000, .length = 0x41000000 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = 1024 * 1024,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = 1,
        .control_record_format_version = 1,
        .label = "golden-member",
        .genesis_topology_digest = .{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f },
        .checkpoint_offset = 0x11000,
        .checkpoint_record_sequence = 9,
        .checkpoint_record_digest = .{ 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f },
    };
}

fn fixChecksum(bytes: *[encoded_size]u8) void {
    codec.putInt(u32, bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
}

test "exact offsets and canonical round trip" {
    var header = testHeader();
    header.compat_features = 0x0102030405060708;
    header.ro_compat_features = 0x1112131415161718;
    header.incompat_features = 0x2122232425262728;
    header.metadata_format_version = 0x3132;
    header.object_format_version = 0x3334;
    header.layout_format_version = 0x3536;
    header.control_record_format_version = 0x3738;
    const bytes = try encode(header);
    try std.testing.expectEqualSlices(u8, &magic, bytes[0x000..0x008]);
    try std.testing.expectEqual(@as(u16, 3), codec.getInt(u16, &bytes, 0x008));
    try std.testing.expectEqual(@as(u16, 0), codec.getInt(u16, &bytes, 0x00a));
    try std.testing.expectEqual(@as(u32, encoded_size), codec.getInt(u32, &bytes, 0x00c));
    try std.testing.expectEqual(@as(u64, 7), codec.getInt(u64, &bytes, 0x010));
    try std.testing.expectEqual(header.compat_features, codec.getInt(u64, &bytes, 0x018));
    try std.testing.expectEqual(header.ro_compat_features, codec.getInt(u64, &bytes, 0x020));
    try std.testing.expectEqual(header.incompat_features, codec.getInt(u64, &bytes, 0x028));
    try std.testing.expectEqualSlices(u8, &header.set_id, bytes[0x030..0x040]);
    try std.testing.expectEqualSlices(u8, &header.member_id, bytes[0x040..0x050]);
    try std.testing.expectEqual(header.member_slot, codec.getInt(u16, &bytes, 0x050));
    try std.testing.expectEqual(header.member_count, codec.getInt(u16, &bytes, 0x052));
    try std.testing.expectEqual(header.role_flags, codec.getInt(u32, &bytes, 0x054));
    try std.testing.expectEqual(@as(i64, 1_700_000_000_123_456_789), codec.getInt(i64, &bytes, 0x058));
    try std.testing.expectEqual(header.member_bytes, codec.getInt(u64, &bytes, 0x060));
    try std.testing.expectEqual(header.logical_capacity, codec.getInt(u64, &bytes, 0x068));
    try std.testing.expectEqual(@as(u64, 0x10000), codec.getInt(u64, &bytes, 0x070));
    try std.testing.expectEqual(header.control.length, codec.getInt(u64, &bytes, 0x078));
    try std.testing.expectEqual(header.metadata.offset, codec.getInt(u64, &bytes, 0x080));
    try std.testing.expectEqual(header.metadata.length, codec.getInt(u64, &bytes, 0x088));
    try std.testing.expectEqual(header.data.offset, codec.getInt(u64, &bytes, 0x090));
    try std.testing.expectEqual(header.data.length, codec.getInt(u64, &bytes, 0x098));
    try std.testing.expectEqual(@as(u32, 4096), codec.getInt(u32, &bytes, 0x0a0));
    try std.testing.expectEqual(header.metadata_read_size, codec.getInt(u32, &bytes, 0x0a4));
    try std.testing.expectEqual(header.metadata_program_size, codec.getInt(u32, &bytes, 0x0a8));
    try std.testing.expectEqual(header.chunk_size, codec.getInt(u32, &bytes, 0x0ac));
    try std.testing.expectEqual(header.metadata_format_version, codec.getInt(u16, &bytes, 0x0b0));
    try std.testing.expectEqual(header.object_format_version, codec.getInt(u16, &bytes, 0x0b2));
    try std.testing.expectEqual(header.layout_format_version, codec.getInt(u16, &bytes, 0x0b4));
    try std.testing.expectEqual(header.control_record_format_version, codec.getInt(u16, &bytes, 0x0b6));
    try std.testing.expectEqual(header.checksum_algorithm, codec.getInt(u16, &bytes, 0x0b8));
    try std.testing.expectEqual(header.digest_algorithm, codec.getInt(u16, &bytes, 0x0ba));
    try std.testing.expectEqual(@as(u16, 13), codec.getInt(u16, &bytes, 0x0bc));
    try std.testing.expectEqual(@as(u16, 0), codec.getInt(u16, &bytes, 0x0be));
    try std.testing.expectEqualSlices(u8, "golden-member", bytes[0x0c0..0x0cd]);
    try std.testing.expectEqualSlices(u8, &header.genesis_topology_digest, bytes[0x140..0x160]);
    try std.testing.expectEqual(@as(u64, 0x11000), codec.getInt(u64, &bytes, 0x160));
    try std.testing.expectEqual(header.checkpoint_record_sequence, codec.getInt(u64, &bytes, 0x168));
    try std.testing.expectEqualSlices(u8, &header.checkpoint_record_digest, bytes[0x170..0x190]);
    try std.testing.expect(codec.isZero(bytes[0x190..checksum_offset]));
    try std.testing.expectEqual(codec.crc32c(bytes[0..checksum_offset]), codec.getInt(u32, &bytes, checksum_offset));
    const decoded = try decode(&bytes);
    const reencoded = try encode(decoded);
    try std.testing.expectEqualSlices(u8, &bytes, &reencoded);
}

test "golden fixture and fingerprint" {
    const fixture_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/fixtures/v3/member-header.hex",
        std.testing.allocator,
        .limited(16 * 1024),
    );
    defer std.testing.allocator.free(fixture_text);
    var fixture: [encoded_size]u8 = @splat(0);
    var lines = std.mem.splitScalar(u8, fixture_text, '\n');
    while (lines.next()) |line| {
        const record = std.mem.trim(u8, line, " \t\r");
        if (record.len == 0 or record[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, record, " \t");
        const offset = try std.fmt.parseInt(usize, fields.next() orelse return error.InvalidFixture, 16);
        const hex = fields.next() orelse return error.InvalidFixture;
        if (fields.next() != null or hex.len % 2 != 0 or offset + hex.len / 2 > fixture.len)
            return error.InvalidFixture;
        _ = try std.fmt.hexToBytes(fixture[offset..], hex);
    }
    const canonical = try encode(testHeader());
    try std.testing.expectEqualSlices(u8, &fixture, &canonical);
    var expected_fingerprint: codec.Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_fingerprint,
        "ac09bf5b06bcc8bbdb092530a7a199032e10eefb917b593ddb4591c464db5946",
    );
    try std.testing.expectEqualSlices(u8, &expected_fingerprint, &codec.blake3(&canonical));
    const decoded = try decode(&fixture);
    try std.testing.expectEqualSlices(u8, &fixture, &(try encode(decoded)));
}

test "corrupt framing and padding are rejected" {
    const canonical = try encode(testHeader());
    const cases = [_]struct { offset: usize, expected: anyerror }{
        .{ .offset = 0, .expected = error.InvalidMagic },
        .{ .offset = 8, .expected = error.UnsupportedFormatVersion },
        .{ .offset = 12, .expected = error.InvalidHeaderSize },
        .{ .offset = 0x0ce, .expected = error.NonZeroLabelPadding },
        .{ .offset = 0x190, .expected = error.NonZeroReserved },
    };
    for (cases) |case| {
        var bytes = canonical;
        bytes[case.offset] ^= 1;
        fixChecksum(&bytes);
        try std.testing.expectError(case.expected, decode(&bytes));
    }
    var checksum_bad = canonical;
    checksum_bad[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&checksum_bad));
}

test "identity role algorithm label and geometry validation" {
    var header = testHeader();
    header.set_id = @splat(0);
    try std.testing.expectError(error.InvalidIdentity, encode(header));
    header = testHeader();
    header.member_id = header.set_id;
    try std.testing.expectError(error.InvalidIdentity, encode(header));
    header = testHeader();
    header.member_slot = 3;
    try std.testing.expectError(error.InvalidMemberPlacement, encode(header));
    header = testHeader();
    header.role_flags = metadata_role;
    try std.testing.expectError(error.InvalidRoleFlags, encode(header));
    header = testHeader();
    header.digest_algorithm = 2;
    try std.testing.expectError(error.UnsupportedAlgorithm, encode(header));
    header = testHeader();
    header.label = "\xff";
    try std.testing.expectError(error.InvalidLabel, encode(header));
    header = testHeader();
    header.metadata.offset += 4096;
    try std.testing.expectError(error.InvalidGeometry, encode(header));
    header = testHeader();
    header.data.length = std.math.maxInt(u64) - (@as(u64, header.chunk_size) - 1);
    try std.testing.expectError(error.RegionOverflow, encode(header));
    header = testHeader();
    header.metadata_block_size = 256 * 1024;
    header.metadata.length = 256 * 1024;
    try std.testing.expectError(error.InvalidGeometry, encode(header));
}

test "checkpoint combinations" {
    var header = testHeader();
    header.checkpoint_offset = 0;
    try std.testing.expectError(error.InvalidCheckpoint, encode(header));
    header = testHeader();
    header.checkpoint_offset = 0x30000;
    try std.testing.expectError(error.InvalidCheckpoint, encode(header));
    header = testHeader();
    header.checkpoint_offset = 0;
    header.checkpoint_record_sequence = 0;
    header.checkpoint_record_digest = @splat(0);
    _ = try encode(header);
}

test "feature policy matrix" {
    var header = testHeader();
    header.compat_features = 1;
    try checkFeaturePolicy(header, .read_only);
    try checkFeaturePolicy(header, .writable);
    header.ro_compat_features = 1;
    try checkFeaturePolicy(header, .read_only);
    try std.testing.expectError(error.UnsupportedReadOnlyFeature, checkFeaturePolicy(header, .writable));
    header.incompat_features = 1;
    try std.testing.expectError(error.UnsupportedIncompatFeature, checkFeaturePolicy(header, .read_only));
    try std.testing.expectError(error.UnsupportedIncompatFeature, checkFeaturePolicy(header, .writable));
    const bytes = try encode(header);
    _ = try decode(&bytes);
}

test "A/B selection preserves structural conflicts" {
    const a_bytes = try encode(testHeader());
    var corrupt = a_bytes;
    corrupt[0] ^= 1;
    const invalid = decodeCandidate(&corrupt);
    switch (invalid) {
        .invalid => |err| try std.testing.expectEqual(error.ChecksumMismatch, err),
        .valid => return error.ExpectedInvalidCandidate,
    }
    var selected = try select(decodeCandidate(&a_bytes), invalid);
    try std.testing.expectEqual(SourceSlot.a, selected.source);
    try std.testing.expect(selected.redundancy_degraded);

    var b_header = testHeader();
    b_header.member_slot = 2;
    const conflict = try encode(b_header);
    try std.testing.expectError(error.ConflictingMemberHeaders, select(decodeCandidate(&a_bytes), decodeCandidate(&conflict)));
    b_header = testHeader();
    b_header.header_sequence = 8;
    const newer = try encode(b_header);
    selected = try select(decodeCandidate(&a_bytes), decodeCandidate(&newer));
    try std.testing.expectEqual(SourceSlot.b, selected.source);
    b_header = testHeader();
    b_header.checkpoint_record_sequence = 10;
    const ambiguous = try encode(b_header);
    try std.testing.expectError(error.AmbiguousMemberHeader, select(decodeCandidate(&a_bytes), decodeCandidate(&ambiguous)));
    try std.testing.expectError(error.NoValidMemberHeader, select(decodeCandidate(&corrupt), decodeCandidate(&corrupt)));
}

test "all deterministic single byte mutations are detected without panic" {
    const canonical = try encode(testHeader());
    for (0..encoded_size) |offset| {
        var mutated = canonical;
        mutated[offset] ^= 0x80;
        try std.testing.expectError(error.ChecksumMismatch, decode(&mutated));
    }
}
