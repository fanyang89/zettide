const std = @import("std");

pub const ReadPolicy = enum { first_available, quorum };
pub const max_reactor_count = 16;
pub const max_vhost_controller_count = 4;
pub const default_concurrent_group_count = 8;
pub const max_concurrent_group_count = 64;

pub const WindowSpec = struct {
    device_index: usize,
    offset: u64,
    length: u64,
};

pub fn parseReadPolicy(raw: c_int) !ReadPolicy {
    return switch (raw) {
        0 => .first_available,
        1 => .quorum,
        else => error.InvalidReadPolicy,
    };
}

pub fn parsePoolId(text: []const u8) ![16]u8 {
    if (text.len != 32) return error.InvalidExpectedPoolId;
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return error.InvalidExpectedPoolId;
    return result;
}

pub fn parseReactorCount(text: ?[]const u8) !usize {
    const value = text orelse return 1;
    if (value.len == 0) return error.InvalidReactorCount;
    var count: usize = 0;
    for (value) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidReactorCount;
        count = std.math.mul(usize, count, 10) catch return error.InvalidReactorCount;
        count = std.math.add(usize, count, digit - '0') catch return error.InvalidReactorCount;
    }
    if (count == 0 or count > max_reactor_count) return error.InvalidReactorCount;
    return count;
}

pub fn parseVhostControllerCount(text: ?[]const u8, reactor_count: usize) !usize {
    const count = if (text) |value|
        parseReactorCount(value) catch return error.InvalidVhostControllerCount
    else
        reactor_count;
    if (count == 0 or count > max_vhost_controller_count or count > reactor_count)
        return error.InvalidVhostControllerCount;
    return count;
}

pub fn parseConcurrentGroupCount(text: ?[]const u8) !usize {
    const value = text orelse return default_concurrent_group_count;
    const count = parseDecimal(usize, value) catch return error.InvalidConcurrentGroupCount;
    if (count == 0 or count > max_concurrent_group_count)
        return error.InvalidConcurrentGroupCount;
    return count;
}

pub fn parseOptionalCpuBase(text: ?[]const u8) !?u32 {
    const value = text orelse return null;
    if (value.len == 0) return null;
    return parseDecimal(u32, value) catch error.InvalidCpuBase;
}

pub fn reactorMaskAt(mask: []const u8, index: usize, buffer: []u8) ![]const u8 {
    if (mask.len < 3 or mask[0] != '[' or mask[mask.len - 1] != ']')
        return error.InvalidReactorMask;
    var cores = std.mem.splitScalar(u8, mask[1 .. mask.len - 1], ',');
    var current: usize = 0;
    while (cores.next()) |core| : (current += 1) {
        if (core.len == 0) return error.InvalidReactorMask;
        if (current == index) return std.fmt.bufPrint(buffer, "[{s}]", .{core});
    }
    return error.InvalidReactorMask;
}

pub fn parseWindowSpecs(text: ?[]const u8, output: []WindowSpec) ![]const WindowSpec {
    const value = text orelse return output[0..0];
    if (value.len == 0) return output[0..0];
    var specs = std.mem.splitScalar(u8, value, ',');
    var count: usize = 0;
    while (specs.next()) |spec| {
        if (count == output.len) return error.TooManyStorageWindows;
        var fields = std.mem.splitScalar(u8, spec, ':');
        const device_index = try parseDecimal(usize, fields.next() orelse return error.InvalidStorageWindow);
        const offset = try parseDecimal(u64, fields.next() orelse return error.InvalidStorageWindow);
        const length = try parseDecimal(u64, fields.next() orelse return error.InvalidStorageWindow);
        if (fields.next() != null or length == 0)
            return error.InvalidStorageWindow;
        _ = std.math.add(u64, offset, length) catch return error.InvalidStorageWindow;
        output[count] = .{ .device_index = device_index, .offset = offset, .length = length };
        count += 1;
    }
    return output[0..count];
}

fn parseDecimal(comptime T: type, text: []const u8) !T {
    if (text.len == 0) return error.InvalidStorageWindow;
    var result: T = 0;
    for (text) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidStorageWindow;
        result = std.math.mul(T, result, 10) catch return error.InvalidStorageWindow;
        result = std.math.add(T, result, digit - '0') catch return error.InvalidStorageWindow;
    }
    return result;
}

test "read policy accepts only supported values" {
    try std.testing.expectEqual(ReadPolicy.first_available, try parseReadPolicy(0));
    try std.testing.expectEqual(ReadPolicy.quorum, try parseReadPolicy(1));
    try std.testing.expectError(error.InvalidReadPolicy, parseReadPolicy(2));
}

test "Pool ID requires 16 hexadecimal bytes" {
    try std.testing.expectEqual(@as([16]u8, @splat(0xab)), try parsePoolId("abababababababababababababababab"));
    try std.testing.expectError(error.InvalidExpectedPoolId, parsePoolId("ab"));
    try std.testing.expectError(error.InvalidExpectedPoolId, parsePoolId("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
}

test "reactor count defaults to one and accepts strict decimal values" {
    try std.testing.expectEqual(@as(usize, 1), try parseReactorCount(null));
    try std.testing.expectEqual(@as(usize, 1), try parseReactorCount("1"));
    try std.testing.expectEqual(max_reactor_count, try parseReactorCount("16"));
}

test "reactor count rejects invalid values" {
    for ([_][]const u8{ "", "0", "17", "+1", " 1", "1 ", "1x" }) |value| {
        try std.testing.expectError(error.InvalidReactorCount, parseReactorCount(value));
    }
}

test "vhost controller count defaults to reactors and stays bounded" {
    try std.testing.expectEqual(@as(usize, 4), try parseVhostControllerCount(null, 4));
    try std.testing.expectEqual(@as(usize, 2), try parseVhostControllerCount("2", 4));
    for ([_][]const u8{ "", "0", "5", "+1", "x" }) |value| {
        try std.testing.expectError(error.InvalidVhostControllerCount, parseVhostControllerCount(value, 4));
    }
    try std.testing.expectError(error.InvalidVhostControllerCount, parseVhostControllerCount("4", 2));
}

test "concurrent group count is strict and bounded" {
    try std.testing.expectEqual(default_concurrent_group_count, try parseConcurrentGroupCount(null));
    try std.testing.expectEqual(@as(usize, 16), try parseConcurrentGroupCount("16"));
    for ([_][]const u8{ "", "0", "65", "+1", "x" }) |value| {
        try std.testing.expectError(error.InvalidConcurrentGroupCount, parseConcurrentGroupCount(value));
    }
}

test "optional CPU base accepts strict decimal values" {
    try std.testing.expectEqual(@as(?u32, null), try parseOptionalCpuBase(null));
    try std.testing.expectEqual(@as(?u32, null), try parseOptionalCpuBase(""));
    try std.testing.expectEqual(@as(?u32, 4), try parseOptionalCpuBase("4"));
    for ([_][]const u8{ "+1", "-1", "x" }) |value| {
        try std.testing.expectError(error.InvalidCpuBase, parseOptionalCpuBase(value));
    }
}

test "reactor mask selects one core" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("[0]", try reactorMaskAt("[0,2,7,9]", 0, &buffer));
    try std.testing.expectEqualStrings("[7]", try reactorMaskAt("[0,2,7,9]", 2, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("[0,2]", 2, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("0,2", 0, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("[0,,2]", 2, &buffer));
}

test "storage window specs parse strict device ranges" {
    var output: [4]WindowSpec = undefined;
    const specs = try parseWindowSpecs("0:0:1024,1:1024:2048", &output);
    try std.testing.expectEqual(@as(usize, 2), specs.len);
    try std.testing.expectEqualDeep(WindowSpec{ .device_index = 0, .offset = 0, .length = 1024 }, specs[0]);
    try std.testing.expectEqualDeep(WindowSpec{ .device_index = 1, .offset = 1024, .length = 2048 }, specs[1]);
    try std.testing.expectEqual(@as(usize, 0), (try parseWindowSpecs(null, &output)).len);
    for ([_][]const u8{ "0:0", "0:0:0", "0:0:1:", "0::1", "+0:0:1", "0:18446744073709551615:2", "0:0:1," }) |value| {
        try std.testing.expectError(error.InvalidStorageWindow, parseWindowSpecs(value, &output));
    }
}
