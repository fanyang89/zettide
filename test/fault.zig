const std = @import("std");
const devdrive = @import("devdrive");
const Volume = devdrive.volume.Volume;
const FileHandle = devdrive.volume.FileHandle;
const c = devdrive.volume.c;

fn createPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const root_length = try tmp.dir.realPath(std.testing.io, buffer);
    const suffix = try std.fmt.bufPrint(buffer[root_length..], "/fault.ddv", .{});
    return buffer[0 .. root_length + suffix.len];
}

test "a failed sync can be retried without losing committed data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 1024 * 1024, "FaultTest");

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "durable", 0);

        var fault: devdrive.block_device.FaultController = .{ .fail_sync_at = 0 };
        volume.device.fault = &fault;
        try std.testing.expectError(error.InputOutput, volume.syncFile(&file));
        try std.testing.expect(file.open);
        fault.disable();
        try volume.syncFile(&file);
        try volume.closeFile(&file);
    }

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_RDONLY, 0, 0, 0);
        var actual: [7]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, 0));
        try std.testing.expectEqualStrings("durable", &actual);
        try volume.closeFile(&file);
    }
}
