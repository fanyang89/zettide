const std = @import("std");
const Io = std.Io;
const File = Io.File;

pub const header_size: usize = 4096;
pub const header_a_offset: u64 = 0;
pub const header_b_offset: u64 = header_size;
pub const payload_offset: u64 = 64 * 1024;
pub const default_block_size: u32 = 4096;
pub const default_read_size: u32 = 512;
pub const default_prog_size: u32 = 512;
pub const default_chunk_size: u32 = 1024 * 1024;
pub const virtual_file_max: u64 = std.math.maxInt(i64);
pub const feature_object_store: u32 = 1 << 0;
pub const supported_features: u32 = feature_object_store;
pub const object_format_version: u32 = 1;
pub const max_label_len: usize = 127;
pub const min_volume_size: u64 = 256 * 1024;

const magic = [8]u8{ 'L', 'F', 'S', 'D', 'R', 'V', '2', 0 };
const format_major: u16 = 2;
const format_minor: u16 = 0;
const checksum_offset = header_size - @sizeOf(u32);

pub const State = enum(u8) {
    creating = 1,
    ready = 2,
};

pub const Header = struct {
    sequence: u64,
    state: State,
    features: u32 = supported_features,
    uuid: [16]u8,
    created_ns: i64,
    logical_size: u64,
    payload_start: u64 = payload_offset,
    block_size: u32 = default_block_size,
    block_count: u32,
    read_size: u32 = default_read_size,
    prog_size: u32 = default_prog_size,
    name_max: u32 = 255,
    file_max: u32 = 2_147_483_647,
    attr_max: u32 = 1022,
    user_file_max: u64 = virtual_file_max,
    object_version: u32 = object_format_version,
    chunk_size: u32 = default_chunk_size,
    label: [max_label_len]u8 = @splat(0),
    label_len: u8 = 0,

    pub fn init(io: Io, logical_size: u64, label: []const u8) !Header {
        if (logical_size < min_volume_size or logical_size % default_block_size != 0)
            return error.InvalidVolumeSize;
        const count = logical_size / default_block_size;
        if (count > std.math.maxInt(u32)) return error.VolumeTooLarge;
        if (label.len > max_label_len or !std.unicode.utf8ValidateSlice(label))
            return error.InvalidLabel;

        var result: Header = .{
            .sequence = 1,
            .state = .creating,
            .uuid = undefined,
            .created_ns = @intCast(Io.Clock.real.now(io).nanoseconds),
            .logical_size = logical_size,
            .block_count = @intCast(count),
        };
        try io.randomSecure(&result.uuid);
        @memcpy(result.label[0..label.len], label);
        result.label_len = @intCast(label.len);
        return result;
    }

    pub fn labelSlice(header: *const Header) []const u8 {
        return header.label[0..header.label_len];
    }

    pub fn encode(header: Header) [header_size]u8 {
        var bytes: [header_size]u8 = @splat(0);
        @memcpy(bytes[0..magic.len], &magic);
        putInt(u16, &bytes, 8, format_major);
        putInt(u16, &bytes, 10, format_minor);
        putInt(u32, &bytes, 12, header_size);
        putInt(u64, &bytes, 16, header.sequence);
        bytes[24] = @intFromEnum(header.state);
        putInt(u32, &bytes, 28, header.features);
        @memcpy(bytes[32..48], &header.uuid);
        putInt(i64, &bytes, 48, header.created_ns);
        putInt(u64, &bytes, 56, header.logical_size);
        putInt(u64, &bytes, 64, header.payload_start);
        putInt(u32, &bytes, 72, header.block_size);
        putInt(u32, &bytes, 76, header.block_count);
        putInt(u32, &bytes, 80, header.read_size);
        putInt(u32, &bytes, 84, header.prog_size);
        putInt(u32, &bytes, 88, header.name_max);
        putInt(u32, &bytes, 92, header.file_max);
        putInt(u32, &bytes, 96, header.attr_max);
        bytes[100] = header.label_len;
        @memcpy(bytes[104 .. 104 + header.label_len], header.label[0..header.label_len]);
        putInt(u64, &bytes, 232, header.user_file_max);
        putInt(u32, &bytes, 240, header.object_version);
        putInt(u32, &bytes, 244, header.chunk_size);
        putInt(u32, &bytes, checksum_offset, checksum(bytes[0..checksum_offset]));
        return bytes;
    }

    pub fn decode(bytes: *const [header_size]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
        if (getInt(u16, bytes, 8) != format_major) return error.UnsupportedFormat;
        if (getInt(u16, bytes, 10) > format_minor) return error.UnsupportedFormat;
        if (getInt(u32, bytes, 12) != header_size) return error.InvalidHeader;
        if (getInt(u32, bytes, checksum_offset) != checksum(bytes[0..checksum_offset]))
            return error.InvalidChecksum;

        const label_len = bytes[100];
        if (label_len > max_label_len) return error.InvalidHeader;
        const state = std.enums.fromInt(State, bytes[24]) orelse return error.InvalidHeader;
        var result: Header = .{
            .sequence = getInt(u64, bytes, 16),
            .state = state,
            .features = getInt(u32, bytes, 28),
            .uuid = bytes[32..48].*,
            .created_ns = getInt(i64, bytes, 48),
            .logical_size = getInt(u64, bytes, 56),
            .payload_start = getInt(u64, bytes, 64),
            .block_size = getInt(u32, bytes, 72),
            .block_count = getInt(u32, bytes, 76),
            .read_size = getInt(u32, bytes, 80),
            .prog_size = getInt(u32, bytes, 84),
            .name_max = getInt(u32, bytes, 88),
            .file_max = getInt(u32, bytes, 92),
            .attr_max = getInt(u32, bytes, 96),
            .user_file_max = getInt(u64, bytes, 232),
            .object_version = getInt(u32, bytes, 240),
            .chunk_size = getInt(u32, bytes, 244),
            .label_len = label_len,
        };
        @memcpy(result.label[0..label_len], bytes[104 .. 104 + label_len]);
        try result.validate();
        return result;
    }

    pub fn validate(header: Header) !void {
        if (header.features != supported_features) return error.UnsupportedFeatures;
        if (header.payload_start < payload_offset or header.payload_start % header_size != 0)
            return error.InvalidHeader;
        if (header.block_size == 0 or header.logical_size % header.block_size != 0)
            return error.InvalidHeader;
        if (header.logical_size < min_volume_size or header.block_count == 0)
            return error.InvalidHeader;
        if (header.logical_size / header.block_size != header.block_count)
            return error.InvalidHeader;
        if (header.read_size == 0 or header.prog_size == 0) return error.InvalidHeader;
        if (header.block_size % header.read_size != 0 or header.block_size % header.prog_size != 0)
            return error.InvalidHeader;
        if (header.name_max == 0 or header.name_max > 255) return error.InvalidHeader;
        if (header.file_max == 0 or header.file_max > 2_147_483_647) return error.InvalidHeader;
        if (header.attr_max < 64 or header.attr_max > 1022) return error.InvalidHeader;
        if (header.user_file_max != virtual_file_max) return error.InvalidHeader;
        if (header.object_version != object_format_version) return error.UnsupportedFormat;
        if (header.chunk_size == 0 or header.chunk_size > header.file_max or
            header.chunk_size % header.block_size != 0)
            return error.InvalidHeader;
        if (!std.unicode.utf8ValidateSlice(header.labelSlice())) return error.InvalidHeader;
    }
};

pub fn read(file: File, io: Io) !Header {
    var a_bytes: [header_size]u8 = undefined;
    var b_bytes: [header_size]u8 = undefined;
    const a_read = try file.readPositionalAll(io, &a_bytes, header_a_offset);
    const b_read = try file.readPositionalAll(io, &b_bytes, header_b_offset);
    const a = if (a_read == header_size) Header.decode(&a_bytes) catch null else null;
    const b = if (b_read == header_size) Header.decode(&b_bytes) catch null else null;

    const selected = if (a) |a_header|
        if (b) |b_header| if (b_header.sequence > a_header.sequence) b_header else a_header else a_header
    else if (b) |b_header|
        b_header
    else
        return error.NoValidHeader;

    if (selected.state != .ready) return error.IncompleteContainer;
    const expected_len = std.math.add(u64, selected.payload_start, selected.logical_size) catch
        return error.InvalidHeader;
    if (try file.length(io) < expected_len) return error.TruncatedContainer;
    return selected;
}

pub fn write(file: File, io: Io, offset: u64, header: Header) !void {
    const bytes = header.encode();
    try file.writePositionalAll(io, &bytes, offset);
}

fn checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32Iscsi.hash(bytes);
}

fn putInt(comptime T: type, bytes: *[header_size]u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn getInt(comptime T: type, bytes: *const [header_size]u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "header round trip" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    const header = try Header.init(io, 1024 * 1024, "Workspace");
    const decoded = try Header.decode(&header.encode());
    try std.testing.expectEqual(header.logical_size, decoded.logical_size);
    try std.testing.expectEqual(virtual_file_max, decoded.user_file_max);
    try std.testing.expectEqual(default_chunk_size, decoded.chunk_size);
    try std.testing.expectEqualStrings("Workspace", decoded.labelSlice());
    try std.testing.expectEqualSlices(u8, &header.uuid, &decoded.uuid);
}

test "header checksum detects corruption" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    const header = try Header.init(io, 1024 * 1024, "Test");
    var bytes = header.encode();
    bytes[64] ^= 1;
    try std.testing.expectError(error.InvalidChecksum, Header.decode(&bytes));
}

test "reader falls back to the valid header copy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "container.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try Header.init(std.testing.io, 1024 * 1024, "Redundant");
    header.state = .ready;
    try file.setLength(std.testing.io, header.payload_start + header.logical_size);
    try write(file, std.testing.io, header_a_offset, header);
    header.sequence += 1;
    try write(file, std.testing.io, header_b_offset, header);
    try file.writePositionalAll(std.testing.io, "X", header_a_offset);

    const selected = try read(file, std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), selected.sequence);
    try std.testing.expectEqualStrings("Redundant", selected.labelSlice());
}

test "header rejects invalid geometry and labels" {
    try std.testing.expectError(error.InvalidVolumeSize, Header.init(std.testing.io, min_volume_size - 1, "small"));
    try std.testing.expectError(error.InvalidVolumeSize, Header.init(std.testing.io, min_volume_size + 1, "unaligned"));
    var long_label: [max_label_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidLabel, Header.init(std.testing.io, min_volume_size, &long_label));
    const invalid_utf8 = [_]u8{0xff};
    try std.testing.expectError(error.InvalidLabel, Header.init(std.testing.io, min_volume_size, &invalid_utf8));
}

test "header rejects unknown features and truncated containers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "bad.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try Header.init(std.testing.io, 1024 * 1024, "Bad");
    header.state = .ready;
    header.features |= 1 << 31;
    const bytes = header.encode();
    try std.testing.expectError(error.UnsupportedFeatures, Header.decode(&bytes));

    header.features = supported_features;
    try write(file, std.testing.io, header_a_offset, header);
    try write(file, std.testing.io, header_b_offset, header);
    try file.setLength(std.testing.io, header.payload_start + header.logical_size - 1);
    try std.testing.expectError(error.TruncatedContainer, read(file, std.testing.io));
}
