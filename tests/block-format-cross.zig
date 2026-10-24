const std = @import("std");
const storage = @import("zettide_storage");

test "Catalog Volume descriptors round trip without filesystem dependencies" {
    const catalog = storage.v3.pool_catalog;
    const volume: catalog.VolumeDescriptor = .{
        .volume_id = @splat(1),
        .state = .ready,
        .provisioning = .thin,
        .created_ns = 1,
        .logical_size = 16 * 1024 * 1024,
        .header_page = .{ .offset = 8192, .digest = @splat(2) },
        .extent_size = 1024 * 1024,
        .name = try catalog.Name.init("vm-disk"),
    };
    const bytes = try catalog.encodeVolume(volume);
    const decoded = try catalog.decodeVolume(&bytes);
    try std.testing.expectEqualSlices(u8, &volume.volume_id, &decoded.volume_id);
    try std.testing.expectEqual(volume.logical_size, decoded.logical_size);
    try std.testing.expectEqualStrings("vm-disk", decoded.name.slice());
}
