const std = @import("std");
const devdrive = @import("devdrive");
const Volume = devdrive.volume.Volume;
const FileHandle = devdrive.volume.FileHandle;
const DirectoryHandle = devdrive.volume.DirectoryHandle;
const c = devdrive.volume.c;

fn fullImagePath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const root_length = try tmp.dir.realPath(std.testing.io, buffer);
    const suffix = try std.fmt.bufPrint(buffer[root_length..], "/image.ddv", .{});
    return buffer[0 .. root_length + suffix.len];
}

fn createVolume(tmp: *std.testing.TmpDir, path_buffer: []u8, size: u64) ![]const u8 {
    const path = try fullImagePath(tmp, path_buffer);
    try Volume.create(std.testing.io, path, size, "ImageTest");
    return path;
}

fn openVolume(path: []const u8) !Volume {
    return Volume.open(std.testing.io, path, true);
}

test "data and metadata survive a real container reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);

    var expected: [8193]u8 = undefined;
    for (&expected, 0..) |*byte, index| byte.* = @truncate(index *% 37);

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/payload", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100640, 123, 456);
        try std.testing.expectEqual(expected.len, try volume.writeFile(&file, &expected, 0));
        try volume.syncFile(&file);
        try volume.closeFile(&file);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        const info = try volume.stat("/payload");
        try std.testing.expectEqual(@as(u32, expected.len), info.size);
        try std.testing.expectEqual(@as(u32, 0o100640), info.metadata.mode);
        try std.testing.expectEqual(@as(u32, 123), info.metadata.uid);
        try std.testing.expectEqual(@as(u32, 456), info.metadata.gid);

        var file: FileHandle = undefined;
        try volume.openFile(&file, "/payload", c.LFS_O_RDONLY, 0, 0, 0);
        var actual: [expected.len]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, 0));
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try volume.closeFile(&file);
    }
}

test "read write and truncate preserve boundary data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/boundary", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try std.testing.expectEqual(@as(usize, 3), try volume.writeFile(&file, "abc", 0));
    try std.testing.expectEqual(@as(usize, 3), try volume.writeFile(&file, "XYZ", 4097));

    var gap: [4094]u8 = undefined;
    try std.testing.expectEqual(gap.len, try volume.readFile(&file, &gap, 3));
    for (gap) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    try volume.truncateFile(&file, 2);
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(c.lfs_file_size(&volume.lfs, &file.file))));
    try volume.truncateFile(&file, 513);
    var extension: [511]u8 = undefined;
    try std.testing.expectEqual(extension.len, try volume.readFile(&file, &extension, 2));
    for (extension) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try volume.closeFile(&file);
}

test "namespace operations and directory cookies are stable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    try volume.makeDirectory("/dir", 0o40755, 10, 20);
    var file: FileHandle = undefined;
    try volume.openFile(&file, "/dir/a", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 10, 20);
    _ = try volume.writeFile(&file, "A", 0);
    try volume.closeFile(&file);
    try volume.rename("/dir/a", "/dir/b");
    try std.testing.expectError(error.FileNotFound, volume.stat("/dir/a"));
    try std.testing.expectEqual(@as(u32, 1), (try volume.stat("/dir/b")).size);

    var directory: DirectoryHandle = .{};
    try volume.openDirectory(&directory, "/dir");
    var saw_file = false;
    var entries: usize = 0;
    while (true) {
        var info: c.struct_lfs_info = undefined;
        if (!try volume.readDirectory(&directory, &info)) break;
        entries += 1;
        if (std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&info.name))), "b")) saw_file = true;
    }
    try std.testing.expect(entries >= 3);
    try std.testing.expect(saw_file);
    try volume.closeDirectory(&directory);

    try volume.remove("/dir/b");
    try volume.remove("/dir");
    try std.testing.expectError(error.FileNotFound, volume.stat("/dir"));
}

test "an unlinked open handle stays isolated from a replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var old_file: FileHandle = undefined;
    try volume.openFile(&old_file, "/same", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    _ = try volume.writeFile(&old_file, "old", 0);
    try volume.syncFile(&old_file);
    try volume.remove("/same");

    var new_file: FileHandle = undefined;
    try volume.openFile(&new_file, "/same", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    _ = try volume.writeFile(&new_file, "new", 0);
    try volume.syncFile(&new_file);

    var old_data: [3]u8 = undefined;
    var new_data: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try volume.readFile(&old_file, &old_data, 0));
    try std.testing.expectEqual(@as(usize, 3), try volume.readFile(&new_file, &new_data, 0));
    try std.testing.expectEqualStrings("old", &old_data);
    try std.testing.expectEqualStrings("new", &new_data);
    try volume.closeFile(&old_file);
    try volume.closeFile(&new_file);
}

test "container writer lock excludes another opener" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var first = try Volume.open(std.testing.io, path, true);
    defer first.deinit();
    try std.testing.expectError(error.WouldBlock, Volume.open(std.testing.io, path, true));
    try std.testing.expectError(error.WouldBlock, Volume.open(std.testing.io, path, false));
}

test "closing another writable handle does not revert path metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var created: FileHandle = undefined;
    try volume.openFile(&created, "/metadata", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try volume.closeFile(&created);

    var first: FileHandle = undefined;
    var second: FileHandle = undefined;
    try volume.openFile(&first, "/metadata", c.LFS_O_RDWR, 0, 0, 0);
    try volume.openFile(&second, "/metadata", c.LFS_O_RDWR, 0, 0, 0);
    var changed = try volume.getMetadata("/metadata");
    changed.mode = 0o100600;
    try volume.setMetadata("/metadata", changed);
    try volume.closeFile(&first);
    try volume.closeFile(&second);

    try std.testing.expectEqual(@as(u32, 0o100600), (try volume.stat("/metadata")).metadata.mode);
}

test "corrupt metadata is reported instead of replaced with defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/corrupt", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try volume.closeFile(&file);

    var corrupt: [devdrive.metadata.encoded_size]u8 = @splat(0xa5);
    try devdrive.volume.checkLfs(c.lfs_setattr(
        &volume.lfs,
        "/corrupt",
        devdrive.metadata.attribute_type,
        &corrupt,
        corrupt.len,
    ));
    try std.testing.expectError(error.UnsupportedMetadata, volume.stat("/corrupt"));
    try std.testing.expectError(
        error.UnsupportedMetadata,
        volume.openFile(&file, "/corrupt", c.LFS_O_RDWR, 0, 0, 0),
    );
}

test "two writable handles preserve non-overlapping writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var created: FileHandle = undefined;
    try volume.openFile(&created, "/shared", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    _ = try volume.writeFile(&created, "0000", 0);
    try volume.closeFile(&created);

    var first: FileHandle = undefined;
    var second: FileHandle = undefined;
    try volume.openFile(&first, "/shared", c.LFS_O_RDWR, 0, 0, 0);
    try volume.openFile(&second, "/shared", c.LFS_O_RDWR, 0, 0, 0);
    _ = try volume.writeFile(&first, "AA", 0);
    try volume.syncFile(&first);
    _ = try volume.writeFile(&second, "BB", 2);
    try volume.syncFile(&second);
    try volume.closeFile(&first);
    try volume.closeFile(&second);

    var reader: FileHandle = undefined;
    try volume.openFile(&reader, "/shared", c.LFS_O_RDONLY, 0, 0, 0);
    var actual: [4]u8 = undefined;
    try std.testing.expectEqual(actual.len, try volume.readFile(&reader, &actual, 0));
    try std.testing.expectEqualStrings("AABB", &actual);
    try volume.closeFile(&reader);
}

test "full volume reports no space and recovers after deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 256 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/large", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    const block: [4096]u8 = @splat(0x5a);
    var offset: u32 = 0;
    var exhausted = false;
    while (offset < 1024 * 1024) : (offset += block.len) {
        _ = volume.writeFile(&file, &block, offset) catch |err| switch (err) {
            error.NoSpaceLeft => {
                exhausted = true;
                break;
            },
            else => return err,
        };
    }
    try std.testing.expect(exhausted);
    try volume.closeFile(&file);
    try volume.remove("/large");

    try volume.openFile(&file, "/recovered", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try std.testing.expectEqual(block.len, try volume.writeFile(&file, &block, 0));
    try volume.closeFile(&file);
}

test "file name length boundary is enforced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var valid_path: [257:0]u8 = @splat(0);
    valid_path[0] = '/';
    @memset(valid_path[1..256], 'a');
    var file: FileHandle = undefined;
    try volume.openFile(&file, &valid_path, c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try volume.closeFile(&file);

    var invalid_path: [258:0]u8 = @splat(0);
    invalid_path[0] = '/';
    @memset(invalid_path[1..257], 'b');
    try std.testing.expectError(
        error.NameTooLong,
        volume.openFile(&file, &invalid_path, c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1),
    );
}
