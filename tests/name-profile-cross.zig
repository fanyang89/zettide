const std = @import("std");
const zettide = @import("zettide");

test "portable name profile compiles for the target" {
    var prepared = try zettide.name_profile.preparePortableV1(std.testing.allocator, "CrossTarget");
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("crosstarget", prepared.key);
}
