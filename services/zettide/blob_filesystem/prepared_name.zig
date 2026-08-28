const std = @import("std");
const filesystem_format = @import("../blob_filesystem_format.zig");
const name_profile = @import("../name_profile.zig");

pub const PreparedName = struct {
    spelling: []const u8,
    key: []const u8,
    portable: ?name_profile.PreparedComponent = null,

    pub fn init(allocator: std.mem.Allocator, profile: name_profile.Profile, input: []const u8) !PreparedName {
        return switch (profile) {
            .legacy_raw => legacy: {
                if (input.len == 0 or input.len > filesystem_format.max_name_bytes or
                    std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..") or
                    std.mem.indexOfAny(u8, input, &.{ 0, '/' }) != null)
                    return error.InvalidName;
                break :legacy .{ .spelling = input, .key = input };
            },
            .portable_v1 => portable: {
                const value = try name_profile.preparePortableV1(allocator, input);
                break :portable .{ .spelling = value.spelling, .key = value.key, .portable = value };
            },
        };
    }

    pub fn deinit(self: *PreparedName, allocator: std.mem.Allocator) void {
        if (self.portable) |value| value.deinit(allocator);
        self.* = undefined;
    }
};
