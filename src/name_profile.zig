const std = @import("std");

const c = @cImport({
    @cDefine("UTF8PROC_STATIC", "1");
    @cInclude("stdlib.h");
    @cInclude("utf8proc.h");
});

pub const Profile = enum {
    legacy_raw,
    portable_v1,

    pub fn parse(value: []const u8) !Profile {
        if (std.mem.eql(u8, value, "legacy-raw")) return .legacy_raw;
        if (std.mem.eql(u8, value, "portable-v1")) return .portable_v1;
        return error.InvalidNameProfile;
    }

    pub fn name(self: Profile) []const u8 {
        return switch (self) {
            .legacy_raw => "legacy-raw",
            .portable_v1 => "portable-v1",
        };
    }

    pub fn persistedId(self: Profile) u16 {
        return switch (self) {
            .legacy_raw => 0,
            .portable_v1 => 1,
        };
    }

    pub fn persistedVersion(self: Profile) u16 {
        return switch (self) {
            .legacy_raw => 0,
            .portable_v1 => 1,
        };
    }

    pub fn fromPersisted(id: u16, version: u16) !Profile {
        if (id == 0 and version == 0) return .legacy_raw;
        if (id == 1 and version == 1) return .portable_v1;
        return error.UnsupportedNameProfile;
    }
};

pub const portable_v1_unicode_version = "17.0.0";
pub const portable_v1_utf8proc_version = "2.11.3";
pub const max_utf8_bytes: usize = 255;
pub const max_utf16_code_units: usize = 255;
const max_input_bytes: usize = 4 * max_utf8_bytes;

pub const PreparedComponent = struct {
    spelling: []u8,
    key: []u8,

    pub fn deinit(self: PreparedComponent, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.spelling);
    }
};

pub fn preparePortableV1(allocator: std.mem.Allocator, input: []const u8) !PreparedComponent {
    if (input.len == 0) return error.InvalidName;
    if (input.len > max_input_bytes) return error.NameTooLong;

    const spelling = try map(allocator, input, c.UTF8PROC_STABLE | c.UTF8PROC_COMPOSE | c.UTF8PROC_REJECTNA);
    errdefer allocator.free(spelling);
    try validatePortableSpelling(spelling);

    const key = try map(
        allocator,
        spelling,
        c.UTF8PROC_STABLE | c.UTF8PROC_COMPOSE | c.UTF8PROC_REJECTNA | c.UTF8PROC_CASEFOLD,
    );
    return .{ .spelling = spelling, .key = key };
}

pub fn unicodeVersion() []const u8 {
    return std.mem.span(c.utf8proc_unicode_version());
}

pub fn utf8procVersion() []const u8 {
    return std.mem.span(c.utf8proc_version());
}

fn map(allocator: std.mem.Allocator, input: []const u8, options: c.utf8proc_option_t) ![]u8 {
    const input_len = std.math.cast(c.utf8proc_ssize_t, input.len) orelse return error.NameTooLong;
    var output: [*c]c.utf8proc_uint8_t = null;
    const result = c.utf8proc_map(input.ptr, input_len, &output, options);
    if (result < 0) return switch (result) {
        c.UTF8PROC_ERROR_NOMEM => error.OutOfMemory,
        c.UTF8PROC_ERROR_OVERFLOW => error.NameTooLong,
        c.UTF8PROC_ERROR_INVALIDUTF8 => error.InvalidUtf8,
        c.UTF8PROC_ERROR_NOTASSIGNED => error.UnassignedCodepoint,
        else => error.InvalidName,
    };
    defer c.free(output);
    return allocator.dupe(u8, output[0..@intCast(result)]);
}

fn validatePortableSpelling(spelling: []const u8) !void {
    if (spelling.len == 0 or spelling.len > max_utf8_bytes) return error.NameTooLong;
    if (std.mem.eql(u8, spelling, ".") or std.mem.eql(u8, spelling, ".."))
        return error.InvalidName;
    if (spelling[spelling.len - 1] == ' ' or spelling[spelling.len - 1] == '.')
        return error.InvalidName;

    var utf16_units: usize = 0;
    var iterator = std.unicode.Utf8View.initUnchecked(spelling).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0x1f or codepoint == 0x7f or isForbiddenAscii(codepoint))
            return error.InvalidName;
        utf16_units += try std.unicode.utf16CodepointSequenceLength(codepoint);
        if (utf16_units > max_utf16_code_units) return error.NameTooLong;
    }
    if (isWindowsDeviceName(spelling)) return error.ReservedName;
}

fn isForbiddenAscii(codepoint: u21) bool {
    return switch (codepoint) {
        '<', '>', ':', '"', '/', '\\', '|', '?', '*' => true,
        else => false,
    };
}

fn isWindowsDeviceName(spelling: []const u8) bool {
    const extension = std.mem.indexOfScalar(u8, spelling, '.') orelse spelling.len;
    const base = std.mem.trimEnd(u8, spelling[0..extension], " .");
    if (std.ascii.eqlIgnoreCase(base, "CON") or
        std.ascii.eqlIgnoreCase(base, "PRN") or
        std.ascii.eqlIgnoreCase(base, "AUX") or
        std.ascii.eqlIgnoreCase(base, "NUL") or
        std.ascii.eqlIgnoreCase(base, "CONIN$") or
        std.ascii.eqlIgnoreCase(base, "CONOUT$") or
        std.ascii.eqlIgnoreCase(base, "CLOCK$"))
        return true;
    return hasNumberedDevicePrefix(base, "COM") or hasNumberedDevicePrefix(base, "LPT");
}

fn hasNumberedDevicePrefix(base: []const u8, prefix: []const u8) bool {
    if (base.len <= prefix.len or !std.ascii.eqlIgnoreCase(base[0..prefix.len], prefix)) return false;
    const suffix = base[prefix.len..];
    return (suffix.len == 1 and suffix[0] >= '1' and suffix[0] <= '9') or
        std.mem.eql(u8, suffix, "¹") or
        std.mem.eql(u8, suffix, "²") or
        std.mem.eql(u8, suffix, "³");
}

fn expectSamePortableKey(left: []const u8, right: []const u8) !void {
    const allocator = std.testing.allocator;
    var left_prepared = try preparePortableV1(allocator, left);
    defer left_prepared.deinit(allocator);
    var right_prepared = try preparePortableV1(allocator, right);
    defer right_prepared.deinit(allocator);
    try std.testing.expectEqualStrings(left_prepared.key, right_prepared.key);
}

test "portable v1 uses pinned Unicode data" {
    try std.testing.expectEqualStrings(portable_v1_unicode_version, unicodeVersion());
    try std.testing.expectEqualStrings(portable_v1_utf8proc_version, utf8procVersion());
}

test "profile names and persisted identifiers round trip" {
    for ([_]Profile{ .legacy_raw, .portable_v1 }) |profile| {
        try std.testing.expectEqual(profile, try Profile.parse(profile.name()));
        try std.testing.expectEqual(
            profile,
            try Profile.fromPersisted(profile.persistedId(), profile.persistedVersion()),
        );
    }
    try std.testing.expectError(error.InvalidNameProfile, Profile.parse("portable"));
    try std.testing.expectError(error.UnsupportedNameProfile, Profile.fromPersisted(1, 2));
}

test "portable v1 normalizes spelling and folds lookup keys" {
    const allocator = std.testing.allocator;
    var composed = try preparePortableV1(allocator, "e\u{301}.TXT");
    defer composed.deinit(allocator);
    try std.testing.expectEqualStrings("é.TXT", composed.spelling);
    try std.testing.expectEqualStrings("é.txt", composed.key);

    var folded = try preparePortableV1(allocator, "Straße");
    defer folded.deinit(allocator);
    try std.testing.expectEqualStrings("Straße", folded.spelling);
    try std.testing.expectEqualStrings("strasse", folded.key);

    var kelvin = try preparePortableV1(allocator, "Kelvin");
    defer kelvin.deinit(allocator);
    try std.testing.expectEqualStrings("Kelvin", kelvin.spelling);
    try std.testing.expectEqualStrings("kelvin", kelvin.key);

    try expectSamePortableKey("A", "a");
    try expectSamePortableKey("é", "e\u{301}");
    try expectSamePortableKey("Σ", "ς");
    try expectSamePortableKey("I", "i");

    var dotted_i = try preparePortableV1(allocator, "İ");
    defer dotted_i.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, dotted_i.key, "i"));
}

test "portable v1 rejects invalid and unportable names" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUtf8, preparePortableV1(allocator, &.{0xff}));
    try std.testing.expectError(error.UnassignedCodepoint, preparePortableV1(allocator, "\u{378}"));
    for ([_][]const u8{ "", ".", "..", "trailing ", "trailing.", "a/b", "a\\b", "a:b", "a?b", "a\x1fb" }) |name| {
        try std.testing.expectError(error.InvalidName, preparePortableV1(allocator, name));
    }
    for ([_][]const u8{ "CON", "con.txt", "NUL.tar", "CLOCK$", "CONIN$", "conout$.txt", "COM1", "com¹.log", "LPT9" }) |name| {
        try std.testing.expectError(error.ReservedName, preparePortableV1(allocator, name));
    }
}

test "portable v1 permits non-device prefixes and enforces byte length" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "com0", "company", "lpt10" }) |name| {
        var prepared = try preparePortableV1(allocator, name);
        prepared.deinit(allocator);
    }

    const valid = "a" ** max_utf8_bytes;
    var prepared = try preparePortableV1(allocator, valid);
    prepared.deinit(allocator);
    try std.testing.expectError(error.NameTooLong, preparePortableV1(allocator, valid ++ "a"));
    try std.testing.expectError(error.NameTooLong, preparePortableV1(allocator, "a" ** (max_input_bytes + 1)));
}
