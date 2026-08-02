const std = @import("std");
const Io = std.Io;
const File = Io.File;
const name_profile = @import("name_profile.zig");
const volume_crypto = @import("volume_crypto.zig");
const google_crc32c = @import("crc32c");

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
pub const feature_name_profile: u32 = 1 << 1;
pub const feature_encryption: u32 = 1 << 2;
pub const supported_features: u32 = feature_object_store;
pub const supported_feature_mask: u32 = supported_features | feature_name_profile | feature_encryption;
pub const object_format_version: u32 = 1;
pub const max_label_len: usize = 127;
pub const min_volume_size: u64 = 256 * 1024;

const magic = [8]u8{ 'L', 'F', 'S', 'D', 'R', 'V', '2', 0 };
const format_major: u16 = 2;
const format_minor_legacy: u16 = 0;
const format_minor_name_profile: u16 = 1;
const format_minor_encryption: u16 = 2;
const format_minor_current: u16 = format_minor_encryption;
const checksum_offset = header_size - @sizeOf(u32);
const encryption_offset: usize = 256;
const encryption_magic = [8]u8{ 'D', 'D', 'V', 'E', 'N', 'C', '1', 0 };

pub const State = enum(u8) {
    creating = 1,
    ready = 2,
};

pub const Header = struct {
    sequence: u64,
    state: State,
    features: u32 = feature_object_store,
    name_profile: name_profile.Profile = .legacy_raw,
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
    encryption: ?volume_crypto.Config = null,
    label: [max_label_len]u8 = @splat(0),
    label_len: u8 = 0,

    pub fn init(io: Io, logical_size: u64, label: []const u8) !Header {
        return initWithNameProfile(io, logical_size, label, .legacy_raw);
    }

    pub fn initWithNameProfile(
        io: Io,
        logical_size: u64,
        label: []const u8,
        profile: name_profile.Profile,
    ) !Header {
        if (logical_size < min_volume_size or logical_size % default_block_size != 0)
            return error.InvalidVolumeSize;
        const count = logical_size / default_block_size;
        if (count > std.math.maxInt(u32)) return error.VolumeTooLarge;
        if (label.len > max_label_len or !std.unicode.utf8ValidateSlice(label))
            return error.InvalidLabel;

        var result: Header = .{
            .sequence = 1,
            .state = .creating,
            .features = featuresFor(profile, false),
            .name_profile = profile,
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

    pub fn setEncryption(header: *Header, config: volume_crypto.Config) void {
        header.encryption = config;
        header.features = featuresFor(header.name_profile, true);
    }

    pub fn isEncrypted(header: *const Header) bool {
        return header.encryption != null;
    }

    pub fn encode(header: Header) [header_size]u8 {
        var bytes: [header_size]u8 = @splat(0);
        @memcpy(bytes[0..magic.len], &magic);
        putInt(u16, &bytes, 8, format_major);
        putInt(u16, &bytes, 10, formatMinor(header.name_profile, header.isEncrypted()));
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
        if (header.name_profile != .legacy_raw) {
            putInt(u16, &bytes, 248, header.name_profile.persistedId());
            putInt(u16, &bytes, 250, header.name_profile.persistedVersion());
        }
        if (header.encryption) |encryption| encodeEncryption(&bytes, encryption);
        putInt(u32, &bytes, checksum_offset, checksum(bytes[0..checksum_offset]));
        return bytes;
    }

    pub fn decode(bytes: *const [header_size]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.InvalidMagic;
        if (getInt(u32, bytes, 12) != header_size) return error.InvalidHeader;
        if (getInt(u32, bytes, checksum_offset) != checksum(bytes[0..checksum_offset]))
            return error.InvalidChecksum;
        if (getInt(u16, bytes, 8) != format_major) return error.UnsupportedFormat;
        const format_minor = getInt(u16, bytes, 10);
        if (format_minor > format_minor_current) return error.UnsupportedFormat;

        const label_len = bytes[100];
        if (label_len > max_label_len) return error.InvalidHeader;
        const state = std.enums.fromInt(State, bytes[24]) orelse return error.InvalidHeader;
        const features = getInt(u32, bytes, 28);
        const profile: name_profile.Profile = if (features & feature_name_profile != 0)
            try .fromPersisted(getInt(u16, bytes, 248), getInt(u16, bytes, 250))
        else if (format_minor == format_minor_legacy or format_minor == format_minor_encryption)
            .legacy_raw
        else
            return error.InvalidHeader;
        const encrypted = features & feature_encryption != 0;
        if ((format_minor == format_minor_encryption) != encrypted) return error.InvalidHeader;
        var result: Header = .{
            .sequence = getInt(u64, bytes, 16),
            .state = state,
            .features = features,
            .name_profile = profile,
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
            .encryption = if (encrypted) try decodeEncryption(bytes) else null,
            .label_len = label_len,
        };
        @memcpy(result.label[0..label_len], bytes[104 .. 104 + label_len]);
        try result.validate();
        return result;
    }

    pub fn validate(header: Header) !void {
        if (header.features != featuresFor(header.name_profile, header.isEncrypted()))
            return error.UnsupportedFeatures;
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
        if (header.encryption) |encryption| try encryption.validate();
    }
};

fn featuresFor(profile: name_profile.Profile, encrypted: bool) u32 {
    const base = switch (profile) {
        .legacy_raw => feature_object_store,
        .portable_v1 => feature_object_store | feature_name_profile,
    };
    return base | if (encrypted) feature_encryption else 0;
}

fn formatMinor(profile: name_profile.Profile, encrypted: bool) u16 {
    if (encrypted) return format_minor_encryption;
    return switch (profile) {
        .legacy_raw => format_minor_legacy,
        .portable_v1 => format_minor_name_profile,
    };
}

pub fn read(file: File, io: Io) !Header {
    var a_bytes: [header_size]u8 = undefined;
    var b_bytes: [header_size]u8 = undefined;
    const a_read = try file.readPositionalAll(io, &a_bytes, header_a_offset);
    const b_read = try file.readPositionalAll(io, &b_bytes, header_b_offset);
    const a = decodeCandidate(&a_bytes, a_read);
    const b = decodeCandidate(&b_bytes, b_read);
    const selected = if (a.sequence()) |a_sequence|
        if (b.sequence()) |b_sequence|
            if (b_sequence > a_sequence) try b.resolve() else try a.resolve()
        else
            try a.resolve()
    else if (b.sequence() != null)
        try b.resolve()
    else
        return error.NoValidHeader;

    if (selected.state != .ready) return error.IncompleteContainer;
    const expected_len = std.math.add(u64, selected.payload_start, selected.logical_size) catch
        return error.InvalidHeader;
    if (try file.length(io) < expected_len) return error.TruncatedContainer;
    return selected;
}

const HeaderCandidate = union(enum) {
    valid: Header,
    unsupported: struct {
        sequence: u64,
        cause: anyerror,
    },
    invalid,

    fn sequence(candidate: HeaderCandidate) ?u64 {
        return switch (candidate) {
            .valid => |header| header.sequence,
            .unsupported => |failure| failure.sequence,
            .invalid => null,
        };
    }

    fn resolve(candidate: HeaderCandidate) !Header {
        return switch (candidate) {
            .valid => |header| header,
            .unsupported => |failure| failure.cause,
            .invalid => error.NoValidHeader,
        };
    }
};

fn decodeCandidate(bytes: *const [header_size]u8, bytes_read: usize) HeaderCandidate {
    if (bytes_read != header_size) return .invalid;
    const header = Header.decode(bytes) catch |err| return switch (err) {
        error.UnsupportedFormat,
        error.UnsupportedFeatures,
        error.UnsupportedNameProfile,
        error.UnsupportedEncryptionConfig,
        => .{ .unsupported = .{
            .sequence = getInt(u64, bytes, 16),
            .cause = err,
        } },
        else => .invalid,
    };
    return .{ .valid = header };
}

pub fn write(file: File, io: Io, offset: u64, header: Header) !void {
    const bytes = header.encode();
    try file.writePositionalAll(io, &bytes, offset);
}

fn checksum(bytes: []const u8) u32 {
    return google_crc32c.value(bytes);
}

fn encodeEncryption(bytes: *[header_size]u8, config: volume_crypto.Config) void {
    @memcpy(bytes[encryption_offset..][0..encryption_magic.len], &encryption_magic);
    putInt(u16, bytes, encryption_offset + 8, 1);
    putInt(u16, bytes, encryption_offset + 10, @intFromEnum(config.cipher));
    putInt(u16, bytes, encryption_offset + 12, @intFromEnum(config.kdf));
    putInt(u32, bytes, encryption_offset + 16, config.data_unit_size);
    putInt(u32, bytes, encryption_offset + 20, config.argon_time);
    putInt(u32, bytes, encryption_offset + 24, config.argon_memory_kib);
    putInt(u32, bytes, encryption_offset + 28, config.argon_parallelism);
    @memcpy(bytes[encryption_offset + 32 ..][0..volume_crypto.salt_length], &config.salt);
    @memcpy(bytes[encryption_offset + 64 ..][0..volume_crypto.verifier_length], &config.verifier);
}

fn decodeEncryption(bytes: *const [header_size]u8) !volume_crypto.Config {
    if (!std.mem.eql(u8, bytes[encryption_offset..][0..encryption_magic.len], &encryption_magic) or
        getInt(u16, bytes, encryption_offset + 8) != 1 or
        getInt(u16, bytes, encryption_offset + 14) != 0)
        return error.UnsupportedEncryptionConfig;
    const config: volume_crypto.Config = .{
        .cipher = std.enums.fromInt(volume_crypto.Cipher, getInt(u16, bytes, encryption_offset + 10)) orelse
            return error.UnsupportedEncryptionConfig,
        .kdf = std.enums.fromInt(volume_crypto.Kdf, getInt(u16, bytes, encryption_offset + 12)) orelse
            return error.UnsupportedEncryptionConfig,
        .data_unit_size = getInt(u32, bytes, encryption_offset + 16),
        .argon_time = getInt(u32, bytes, encryption_offset + 20),
        .argon_memory_kib = getInt(u32, bytes, encryption_offset + 24),
        .argon_parallelism = @intCast(getInt(u32, bytes, encryption_offset + 28)),
        .salt = bytes[encryption_offset + 32 ..][0..volume_crypto.salt_length].*,
        .verifier = bytes[encryption_offset + 64 ..][0..volume_crypto.verifier_length].*,
    };
    try config.validate();
    return config;
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
    try std.testing.expectEqual(name_profile.Profile.legacy_raw, decoded.name_profile);
    try std.testing.expectEqualStrings("Workspace", decoded.labelSlice());
    try std.testing.expectEqualSlices(u8, &header.uuid, &decoded.uuid);
}

test "portable name profile uses the versioned header extension" {
    const header = try Header.initWithNameProfile(
        std.testing.io,
        1024 * 1024,
        "Portable",
        .portable_v1,
    );
    const bytes = header.encode();
    try std.testing.expectEqual(format_minor_name_profile, getInt(u16, &bytes, 10));
    try std.testing.expectEqual(feature_object_store | feature_name_profile, getInt(u32, &bytes, 28));
    try std.testing.expectEqual(@as(u16, 1), getInt(u16, &bytes, 248));
    try std.testing.expectEqual(@as(u16, 1), getInt(u16, &bytes, 250));
    const decoded = try Header.decode(&bytes);
    try std.testing.expectEqual(name_profile.Profile.portable_v1, decoded.name_profile);
}

test "encrypted header round trip uses the versioned extension" {
    const key: [volume_crypto.master_key_length]u8 = @splat(0x5a);
    var prepared = try volume_crypto.prepare(std.testing.allocator, std.testing.io, .{ .raw_key = &key });
    defer prepared.context.deinit();
    var header = try Header.initWithNameProfile(std.testing.io, 1024 * 1024, "Encrypted", .portable_v1);
    header.setEncryption(prepared.config);
    const bytes = header.encode();
    try std.testing.expectEqual(format_minor_encryption, getInt(u16, &bytes, 10));
    try std.testing.expectEqual(
        feature_object_store | feature_name_profile | feature_encryption,
        getInt(u32, &bytes, 28),
    );
    const decoded = try Header.decode(&bytes);
    try std.testing.expect(decoded.isEncrypted());
    try std.testing.expectEqual(volume_crypto.Kdf.raw_key, decoded.encryption.?.kdf);
    var context = try volume_crypto.Context.open(
        std.testing.allocator,
        std.testing.io,
        decoded.encryption.?,
        .{ .raw_key = &key },
    );
    context.deinit();
}

test "legacy headers retain the v2.0 encoding" {
    const header = try Header.init(std.testing.io, 1024 * 1024, "Legacy");
    const bytes = header.encode();
    try std.testing.expectEqual(format_minor_legacy, getInt(u16, &bytes, 10));
    try std.testing.expectEqual(feature_object_store, getInt(u32, &bytes, 28));
    try std.testing.expectEqual(@as(u16, 0), getInt(u16, &bytes, 248));
    try std.testing.expectEqual(@as(u16, 0), getInt(u16, &bytes, 250));
}

test "header rejects unknown name profile versions" {
    const header = try Header.initWithNameProfile(
        std.testing.io,
        1024 * 1024,
        "Future",
        .portable_v1,
    );
    var bytes = header.encode();
    putInt(u16, &bytes, 250, 2);
    putInt(u32, &bytes, checksum_offset, checksum(bytes[0..checksum_offset]));
    try std.testing.expectError(error.UnsupportedNameProfile, Header.decode(&bytes));
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

test "reader rejects a newer unsupported header copy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "newer.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var legacy = try Header.init(std.testing.io, 1024 * 1024, "Legacy");
    legacy.state = .ready;
    try file.setLength(std.testing.io, legacy.payload_start + legacy.logical_size);
    try write(file, std.testing.io, header_a_offset, legacy);

    var portable = try Header.initWithNameProfile(std.testing.io, 1024 * 1024, "Portable", .portable_v1);
    portable.state = .ready;
    portable.sequence = legacy.sequence + 1;
    var bytes = portable.encode();
    putInt(u16, &bytes, 250, 2);
    putInt(u32, &bytes, checksum_offset, checksum(bytes[0..checksum_offset]));
    try file.writePositionalAll(std.testing.io, &bytes, header_b_offset);

    try std.testing.expectError(error.UnsupportedNameProfile, read(file, std.testing.io));
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

    header.features = feature_object_store;
    try write(file, std.testing.io, header_a_offset, header);
    try write(file, std.testing.io, header_b_offset, header);
    try file.setLength(std.testing.io, header.payload_start + header.logical_size - 1);
    try std.testing.expectError(error.TruncatedContainer, read(file, std.testing.io));
}
