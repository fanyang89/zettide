const std = @import("std");

pub const ReadPolicy = enum { first_available, quorum };

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
