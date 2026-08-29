const std = @import("std");

pub fn parse(text: []const u8) !u64 {
    const suffixes = [_]struct { text: []const u8, multiplier: u64 }{
        .{ .text = "KiB", .multiplier = 1024 },
        .{ .text = "MiB", .multiplier = 1024 * 1024 },
        .{ .text = "GiB", .multiplier = 1024 * 1024 * 1024 },
        .{ .text = "TiB", .multiplier = 1024 * 1024 * 1024 * 1024 },
        .{ .text = "KB", .multiplier = 1000 },
        .{ .text = "MB", .multiplier = 1000 * 1000 },
        .{ .text = "GB", .multiplier = 1000 * 1000 * 1000 },
        .{ .text = "TB", .multiplier = 1000 * 1000 * 1000 * 1000 },
    };
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, text, suffix.text)) {
            const number = try std.fmt.parseInt(u64, text[0 .. text.len - suffix.text.len], 10);
            return std.math.mul(u64, number, suffix.multiplier) catch error.SizeOverflow;
        }
    }
    return std.fmt.parseInt(u64, text, 10);
}

test "parse sizes and reject invalid input" {
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), try parse("16GiB"));
    try std.testing.expectEqual(@as(u64, 2_000_000), try parse("2MB"));
    try std.testing.expectEqual(@as(u64, 4096), try parse("4096"));
    try std.testing.expectError(error.InvalidCharacter, parse("1XB"));
    try std.testing.expectError(error.InvalidCharacter, parse(""));
    try std.testing.expectError(error.SizeOverflow, parse("18446744073709551615TiB"));
}
