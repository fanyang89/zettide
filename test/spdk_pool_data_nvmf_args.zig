const std = @import("std");

pub const ReadPolicy = enum { first_available, quorum };
pub const max_reactor_count = 16;
pub const max_batch_wait_us = 100;

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

pub fn parseBatchWaitUs(text: ?[]const u8) !usize {
    const value = text orelse return 0;
    if (value.len == 0) return error.InvalidBatchWaitUs;
    var wait_us: usize = 0;
    for (value) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidBatchWaitUs;
        wait_us = std.math.mul(usize, wait_us, 10) catch return error.InvalidBatchWaitUs;
        wait_us = std.math.add(usize, wait_us, digit - '0') catch return error.InvalidBatchWaitUs;
    }
    if (wait_us > max_batch_wait_us) return error.InvalidBatchWaitUs;
    return wait_us;
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

test "batch wait defaults to zero and accepts strict decimal microseconds" {
    try std.testing.expectEqual(@as(usize, 0), try parseBatchWaitUs(null));
    for ([_]usize{ 0, 10, 25, 50, 100 }) |wait_us| {
        var buffer: [3]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{wait_us});
        try std.testing.expectEqual(wait_us, try parseBatchWaitUs(text));
    }
}

test "batch wait rejects invalid values" {
    for ([_][]const u8{ "", "101", "+1", " 1", "1 ", "1x" }) |value| {
        try std.testing.expectError(error.InvalidBatchWaitUs, parseBatchWaitUs(value));
    }
}
