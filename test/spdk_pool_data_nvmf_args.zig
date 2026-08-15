const std = @import("std");

pub const ReadPolicy = enum { first_available, quorum };
pub const max_reactor_count = 16;
pub const max_vhost_controller_count = 4;

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

test "reactor mask selects one core" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("[0]", try reactorMaskAt("[0,2,7,9]", 0, &buffer));
    try std.testing.expectEqualStrings("[7]", try reactorMaskAt("[0,2,7,9]", 2, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("[0,2]", 2, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("0,2", 0, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("[0,,2]", 2, &buffer));
}
