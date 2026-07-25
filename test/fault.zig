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

test "a failed multi-chunk write leaves the published generation unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 8 * 1024 * 1024, "CowFaultTest");

    var volume = try Volume.open(std.testing.io, path, true);
    defer volume.deinit();
    try volume.mount();
    var file: FileHandle = undefined;
    try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    const offset = devdrive.object_format.chunk_size - 2;
    _ = try volume.writeFile(&file, "abcd", offset);

    var fault: devdrive.block_device.FaultController = .{ .fail_sync_at = 1 };
    volume.device.fault = &fault;
    try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "WXYZ", offset));
    fault.disable();

    var unchanged: [4]u8 = undefined;
    try std.testing.expectEqual(unchanged.len, try volume.readFile(&file, &unchanged, offset));
    try std.testing.expectEqualStrings("abcd", &unchanged);

    _ = try volume.writeFile(&file, "WXYZ", offset);
    var updated: [4]u8 = undefined;
    try std.testing.expectEqual(updated.len, try volume.readFile(&file, &updated, offset));
    try std.testing.expectEqualStrings("WXYZ", &updated);
    try volume.closeFile(&file);
}

test "a disjoint write does not publish chunks from a failed generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 8 * 1024 * 1024, "DisjointFaultTest");
    const failed_offset = devdrive.object_format.chunk_size - 2;

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "abcd", failed_offset);

        var fault: devdrive.block_device.FaultController = .{ .fail_sync_at = 1 };
        volume.device.fault = &fault;
        try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "WXYZ", failed_offset));
        fault.disable();

        _ = try volume.writeFile(&file, "safe", 2 * devdrive.object_format.chunk_size);
        var actual: [4]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, failed_offset));
        try std.testing.expectEqualStrings("abcd", &actual);
        try volume.closeFile(&file);
    }

    {
        var volume = try Volume.open(std.testing.io, path, false);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_RDONLY, 0, 0, 0);
        var actual: [4]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, failed_offset));
        try std.testing.expectEqualStrings("abcd", &actual);
        try volume.closeFile(&file);
    }
}

test "a no-op truncate does not publish chunks from a failed generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 8 * 1024 * 1024, "TruncateFaultTest");
    const failed_offset = devdrive.object_format.chunk_size - 2;
    const logical_size = devdrive.object_format.chunk_size + 2;

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "abcd", failed_offset);

        var fault: devdrive.block_device.FaultController = .{ .fail_sync_at = 1 };
        volume.device.fault = &fault;
        try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "WXYZ", failed_offset));
        fault.disable();

        try volume.truncateFile(&file, logical_size);
        var actual: [4]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, failed_offset));
        try std.testing.expectEqualStrings("abcd", &actual);
        try volume.closeFile(&file);
    }

    {
        var volume = try Volume.open(std.testing.io, path, false);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_RDONLY, 0, 0, 0);
        var actual: [4]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, failed_offset));
        try std.testing.expectEqualStrings("abcd", &actual);
        try volume.closeFile(&file);
    }
}
