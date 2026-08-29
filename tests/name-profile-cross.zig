const std = @import("std");
const storage_engine = @import("zettide_storage");

test "portable name profile compiles for the target" {
    var prepared = try storage_engine.name_profile.preparePortableV1(std.testing.allocator, "CrossTarget");
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("crosstarget", prepared.key);
}
