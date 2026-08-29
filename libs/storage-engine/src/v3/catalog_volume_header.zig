const std = @import("std");
const codec = @import("codec.zig");

pub const encoded_size: usize = 4096;
pub const payload_offset: u64 = 64 * 1024;
pub const default_block_size: u32 = 4096;
pub const default_read_size: u32 = 512;
pub const default_program_size: u32 = 512;
pub const default_extent_size: u32 = 1024 * 1024;
pub const minimum_volume_size: u64 = 256 * 1024;
pub const max_label_length: usize = 127;

const magic = [8]u8{ 'L', 'F', 'S', 'D', 'R', 'V', '2', 0 };
const checksum_offset = encoded_size - @sizeOf(u32);

pub const State = enum(u8) { creating = 1, ready = 2 };

pub const Header = struct {
    sequence: u64,
    state: State,
    uuid: [16]u8,
    created_ns: i64,
    logical_size: u64,
    payload_start: u64 = payload_offset,
    block_size: u32 = default_block_size,
    block_count: u32,
    read_size: u32 = default_read_size,
    program_size: u32 = default_program_size,
    name_max: u32 = 255,
    file_max: u32 = 2_147_483_647,
    attr_max: u32 = 1022,
    user_file_max: u64 = std.math.maxInt(i64),
    object_version: u32 = 1,
    extent_size: u32 = default_extent_size,
    label: [max_label_length]u8 = @splat(0),
    label_length: u8 = 0,

    pub fn init(io: std.Io, logical_size: u64, label: []const u8) !Header {
        if (logical_size < minimum_volume_size or logical_size % default_block_size != 0)
            return error.InvalidVolumeSize;
        const block_count = logical_size / default_block_size;
        if (block_count > std.math.maxInt(u32)) return error.VolumeTooLarge;
        if (label.len > max_label_length or !std.unicode.utf8ValidateSlice(label))
            return error.InvalidLabel;
        var result: Header = .{
            .sequence = 1,
            .state = .creating,
            .uuid = undefined,
            .created_ns = @intCast(std.Io.Clock.real.now(io).nanoseconds),
            .logical_size = logical_size,
            .block_count = @intCast(block_count),
        };
        try io.randomSecure(&result.uuid);
        @memcpy(result.label[0..label.len], label);
        result.label_length = @intCast(label.len);
        return result;
    }

    pub fn labelSlice(self: *const Header) []const u8 {
        return self.label[0..self.label_length];
    }

    pub fn encode(self: Header) [encoded_size]u8 {
        var bytes: [encoded_size]u8 = @splat(0);
        @memcpy(bytes[0..magic.len], &magic);
        codec.putInt(u16, &bytes, 8, 2);
        codec.putInt(u16, &bytes, 10, 0);
        codec.putInt(u32, &bytes, 12, encoded_size);
        codec.putInt(u64, &bytes, 16, self.sequence);
        bytes[24] = @intFromEnum(self.state);
        codec.putInt(u32, &bytes, 28, 1);
        @memcpy(bytes[32..48], &self.uuid);
        codec.putInt(i64, &bytes, 48, self.created_ns);
        codec.putInt(u64, &bytes, 56, self.logical_size);
        codec.putInt(u64, &bytes, 64, self.payload_start);
        codec.putInt(u32, &bytes, 72, self.block_size);
        codec.putInt(u32, &bytes, 76, self.block_count);
        codec.putInt(u32, &bytes, 80, self.read_size);
        codec.putInt(u32, &bytes, 84, self.program_size);
        codec.putInt(u32, &bytes, 88, self.name_max);
        codec.putInt(u32, &bytes, 92, self.file_max);
        codec.putInt(u32, &bytes, 96, self.attr_max);
        bytes[100] = self.label_length;
        @memcpy(bytes[104..][0..self.label_length], self.label[0..self.label_length]);
        codec.putInt(u64, &bytes, 232, self.user_file_max);
        codec.putInt(u32, &bytes, 240, self.object_version);
        codec.putInt(u32, &bytes, 244, self.extent_size);
        codec.putInt(u32, &bytes, checksum_offset, codec.crc32c(bytes[0..checksum_offset]));
        return bytes;
    }

    pub fn decode(bytes: *const [encoded_size]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
        if (codec.getInt(u32, bytes, checksum_offset) != codec.crc32c(bytes[0..checksum_offset]))
            return error.InvalidChecksum;
        if (codec.getInt(u16, bytes, 8) != 2 or codec.getInt(u16, bytes, 10) != 0)
            return error.UnsupportedFormat;
        if (codec.getInt(u32, bytes, 12) != encoded_size or codec.getInt(u32, bytes, 28) != 1)
            return error.InvalidHeader;
        const label_length = bytes[100];
        if (label_length > max_label_length) return error.InvalidHeader;
        var result: Header = .{
            .sequence = codec.getInt(u64, bytes, 16),
            .state = std.enums.fromInt(State, bytes[24]) orelse return error.InvalidHeader,
            .uuid = bytes[32..48].*,
            .created_ns = codec.getInt(i64, bytes, 48),
            .logical_size = codec.getInt(u64, bytes, 56),
            .payload_start = codec.getInt(u64, bytes, 64),
            .block_size = codec.getInt(u32, bytes, 72),
            .block_count = codec.getInt(u32, bytes, 76),
            .read_size = codec.getInt(u32, bytes, 80),
            .program_size = codec.getInt(u32, bytes, 84),
            .name_max = codec.getInt(u32, bytes, 88),
            .file_max = codec.getInt(u32, bytes, 92),
            .attr_max = codec.getInt(u32, bytes, 96),
            .user_file_max = codec.getInt(u64, bytes, 232),
            .object_version = codec.getInt(u32, bytes, 240),
            .extent_size = codec.getInt(u32, bytes, 244),
            .label_length = label_length,
        };
        @memcpy(result.label[0..label_length], bytes[104..][0..label_length]);
        try result.validate();
        return result;
    }

    fn validate(self: Header) !void {
        if (self.payload_start < payload_offset or self.payload_start % encoded_size != 0 or
            self.block_size == 0 or self.logical_size < minimum_volume_size or
            self.logical_size % self.block_size != 0 or self.logical_size / self.block_size != self.block_count or
            self.read_size == 0 or self.program_size == 0 or
            self.block_size % self.read_size != 0 or self.block_size % self.program_size != 0 or
            self.name_max == 0 or self.name_max > 255 or self.file_max == 0 or
            self.file_max > 2_147_483_647 or self.attr_max < 64 or self.attr_max > 1022 or
            self.user_file_max != std.math.maxInt(i64) or self.object_version != 1 or
            self.extent_size == 0 or self.extent_size > self.file_max or self.extent_size % self.block_size != 0 or
            !std.unicode.utf8ValidateSlice(self.labelSlice()))
            return error.InvalidHeader;
    }
};

test "base LFSDRV2 header round trips" {
    const header: Header = .{
        .sequence = 7,
        .state = .ready,
        .uuid = @splat(3),
        .created_ns = 123,
        .logical_size = 1024 * 1024,
        .block_count = 256,
        .label = .{ 'p', 'o', 'o', 'l' } ++ @as([123]u8, @splat(0)),
        .label_length = 4,
    };
    const bytes = header.encode();
    try std.testing.expectEqualSlices(u8, "LFSDRV2\x00", bytes[0..8]);
    try std.testing.expectEqualDeep(header, try Header.decode(&bytes));
}
