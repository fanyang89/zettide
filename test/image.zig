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
        try std.testing.expectEqual(@as(u64, expected.len), info.size);
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
    try std.testing.expectEqual(@as(u64, 2), (try volume.statFile(&file)).size);
    try volume.truncateFile(&file, 513);
    var extension: [511]u8 = undefined;
    try std.testing.expectEqual(extension.len, try volume.readFile(&file, &extension, 2));
    for (extension) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try volume.closeFile(&file);
}

test "files support 63-bit sparse offsets without allocating holes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 8 * 1024 * 1024);

    const distant_offset: u64 = @as(u64, 4) * 1024 * 1024 * 1024 + 123;
    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();

        var file: FileHandle = undefined;
        try volume.openFile(&file, "/sparse", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        try std.testing.expectEqual(@as(usize, 4), try volume.writeFile(&file, "left", 0));
        try std.testing.expectEqual(@as(usize, 5), try volume.writeFile(&file, "right", distant_offset));

        const info = try volume.statFile(&file);
        try std.testing.expectEqual(distant_offset + 5, info.size);
        try std.testing.expect(info.allocated_bytes < 2 * devdrive.object_format.chunk_size);

        var boundary: [8]u8 = undefined;
        try std.testing.expectEqual(boundary.len, try volume.readFile(&file, &boundary, distant_offset - 3));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 'r', 'i', 'g', 'h', 't' }, &boundary);

        const huge_size: u64 = @as(u64, 8) * 1024 * 1024 * 1024 * 1024;
        try volume.truncateFile(&file, huge_size);
        try std.testing.expectEqual(huge_size, (try volume.statFile(&file)).size);
        try volume.truncateFile(&file, distant_offset + 2);
        try volume.truncateFile(&file, distant_offset + 5);
        var regrown: [5]u8 = undefined;
        try std.testing.expectEqual(regrown.len, try volume.readFile(&file, &regrown, distant_offset));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 'r', 'i', 0, 0, 0 }, &regrown);

        try volume.truncateFile(&file, devdrive.object_format.max_file_size);
        try std.testing.expectEqual(
            devdrive.object_format.max_file_size,
            (try volume.statFile(&file)).size,
        );
        try std.testing.expectError(
            error.FileTooLarge,
            volume.writeFile(&file, "x", devdrive.object_format.max_file_size),
        );
        try volume.syncFile(&file);
        try volume.closeFile(&file);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        const info = try volume.stat("/sparse");
        try std.testing.expectEqual(devdrive.object_format.max_file_size, info.size);
        try std.testing.expect(info.allocated_bytes < 2 * devdrive.object_format.chunk_size);
    }
}

test "append handle keeps object identity across rename and unlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var old_file: FileHandle = undefined;
    try volume.openFile(
        &old_file,
        "/append-old",
        c.LFS_O_CREAT | c.LFS_O_RDWR | c.LFS_O_APPEND,
        0o100644,
        1,
        1,
    );
    _ = try volume.writeFile(&old_file, "A", 999);
    try volume.rename("/append-old", "/append-renamed");
    _ = try volume.writeFile(&old_file, "B", 0);
    try volume.remove("/append-renamed");

    var replacement: FileHandle = undefined;
    try volume.openFile(&replacement, "/append-renamed", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    _ = try volume.writeFile(&replacement, "new", 0);
    _ = try volume.writeFile(&old_file, "C", 0);

    var old_data: [3]u8 = undefined;
    var new_data: [3]u8 = undefined;
    try std.testing.expectEqual(old_data.len, try volume.readFile(&old_file, &old_data, 0));
    try std.testing.expectEqual(new_data.len, try volume.readFile(&replacement, &new_data, 0));
    try std.testing.expectEqualStrings("ABC", &old_data);
    try std.testing.expectEqualStrings("new", &new_data);
    try volume.closeFile(&old_file);
    try volume.closeFile(&replacement);
}

test "writable mount reclaims objects orphaned by a crashed open handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var orphan_id: devdrive.object_format.ObjectId = undefined;

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/orphan", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        orphan_id = file.object_id;
        _ = try volume.writeFile(&file, "orphaned", 0);
        try volume.remove("/orphan");
        // Simulate daemon death: the in-memory handle disappears without close.
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var id_buffer: [32]u8 = undefined;
        var internal_path: [128:0]u8 = @splat(0);
        const id = devdrive.object_format.formatObjectId(orphan_id, &id_buffer);
        const value = try std.fmt.bufPrint(internal_path[0..128], "/system/objects/{s}", .{id});
        internal_path[value.len] = 0;
        var info: c.struct_lfs_info = undefined;
        try std.testing.expectEqual(
            @as(c_int, c.LFS_ERR_NOENT),
            c.lfs_stat(&volume.lfs, &internal_path, &info),
        );
    }
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
    try std.testing.expectEqual(@as(u64, 1), (try volume.stat("/dir/b")).size);

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

test "an unlinked open handle accepts subsequent writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/unlinked", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try volume.remove("/unlinked");
    _ = try volume.writeFile(&file, "after unlink", 0);

    const info = try volume.statFile(&file);
    try std.testing.expectEqual(@as(u64, 12), info.size);
    var actual: [12]u8 = undefined;
    try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, 0));
    try std.testing.expectEqualStrings("after unlink", &actual);
    try volume.closeFile(&file);
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

    const corrupt: [devdrive.object_format.ref_encoded_size]u8 = @splat(0xa5);
    var raw_file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
    try devdrive.volume.checkLfs(c.lfs_file_open(
        &volume.lfs,
        &raw_file,
        "/namespace/corrupt",
        c.LFS_O_WRONLY | c.LFS_O_TRUNC,
    ));
    try devdrive.volume.checkLfs(c.lfs_file_write(&volume.lfs, &raw_file, &corrupt, corrupt.len));
    try devdrive.volume.checkLfs(c.lfs_file_close(&volume.lfs, &raw_file));
    try std.testing.expectError(error.InvalidObjectRef, volume.stat("/corrupt"));
    try std.testing.expectError(
        error.InvalidObjectRef,
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

test "hard links persist and keep objects alive through final unlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var object_id: devdrive.object_format.ObjectId = undefined;

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/link-a", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100640, 1, 2);
        object_id = file.object_id;
        _ = try volume.writeFile(&file, "linked", 0);
        try volume.closeFile(&file);
        try volume.link("/link-a", "/link-b");
        const first = try volume.stat("/link-a");
        const second = try volume.stat("/link-b");
        try std.testing.expectEqual(@as(u64, 2), first.nlink);
        try std.testing.expectEqual(@as(u64, 2), second.nlink);
        try std.testing.expectEqualSlices(u8, &first.object_id.?, &second.object_id.?);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        try std.testing.expectEqual(@as(u64, 2), (try volume.stat("/link-a")).nlink);
        try std.testing.expectEqualSlices(u8, &object_id, &(try volume.stat("/link-b")).object_id.?);

        var file: FileHandle = undefined;
        try volume.openFile(&file, "/link-a", c.LFS_O_RDWR, 0, 0, 0);
        try volume.remove("/link-a");
        try std.testing.expectEqual(@as(u64, 1), (try volume.statFile(&file)).nlink);
        try std.testing.expectEqual(@as(u64, 1), (try volume.stat("/link-b")).nlink);
        try volume.remove("/link-b");
        try std.testing.expectEqual(@as(u64, 0), (try volume.statFile(&file)).nlink);
        _ = try volume.writeFile(&file, "!", 6);
        try volume.closeFile(&file);

        var id_buffer: [32]u8 = undefined;
        var object_path: [128:0]u8 = @splat(0);
        const id = devdrive.object_format.formatObjectId(object_id, &id_buffer);
        const value = try std.fmt.bufPrint(object_path[0..128], "/system/objects/{s}", .{id});
        object_path[value.len] = 0;
        var info: c.struct_lfs_info = undefined;
        try std.testing.expectEqual(@as(c_int, c.LFS_ERR_NOENT), c.lfs_stat(&volume.lfs, &object_path, &info));
    }
}

test "same-object rename is a no-op and rename preserves an open victim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var source: FileHandle = undefined;
    try volume.openFile(&source, "/source", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    _ = try volume.writeFile(&source, "source", 0);
    try volume.closeFile(&source);
    try volume.link("/source", "/alias");
    try volume.rename("/source", "/alias");
    try std.testing.expectEqual(@as(u64, 2), (try volume.stat("/source")).nlink);
    try std.testing.expectEqual(@as(u64, 2), (try volume.stat("/alias")).nlink);

    var victim: FileHandle = undefined;
    try volume.openFile(&victim, "/victim", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    _ = try volume.writeFile(&victim, "victim", 0);
    try volume.rename("/source", "/victim");
    try std.testing.expectError(error.FileNotFound, volume.stat("/source"));
    try std.testing.expectEqual(@as(u64, 2), (try volume.stat("/alias")).nlink);
    try std.testing.expectEqual(@as(u64, 2), (try volume.stat("/victim")).nlink);
    try std.testing.expectEqual(@as(u64, 0), (try volume.statFile(&victim)).nlink);
    var contents: [6]u8 = undefined;
    try std.testing.expectEqual(contents.len, try volume.readFile(&victim, &contents, 0));
    try std.testing.expectEqualStrings("victim", &contents);
    try volume.closeFile(&victim);
}

test "directory link counts and FIFO metadata persist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        try std.testing.expectEqual(@as(u64, 2), (try volume.stat("/")).nlink);
        try volume.makeDirectory("/parent", 0o40755, 1, 1);
        try volume.makeDirectory("/parent/child", 0o40755, 1, 1);
        try std.testing.expectEqual(@as(u64, 3), (try volume.stat("/")).nlink);
        try std.testing.expectEqual(@as(u64, 3), (try volume.stat("/parent")).nlink);
        try std.testing.expectError(error.PermissionDenied, volume.link("/parent", "/directory-link"));
        try volume.makeFifo("/pipe", 0o010640, 12, 34);

        // Images made by older adapters stored symlink metadata behind a file-kind ObjectRef.
        var legacy_link: FileHandle = undefined;
        try volume.openFile(&legacy_link, "/legacy-link", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o120777, 1, 1);
        legacy_link.metadata.kind = .symlink;
        try volume.persistMetadata(&legacy_link);
        _ = try volume.writeFile(&legacy_link, "target", 0);
        try volume.closeFile(&legacy_link);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        const info = try volume.stat("/pipe");
        try std.testing.expectEqual(devdrive.metadata.Kind.fifo, info.metadata.kind);
        try std.testing.expectEqual(@as(u32, 0o010640), info.metadata.mode);
        try std.testing.expectEqual(@as(u32, 12), info.metadata.uid);
        try std.testing.expectEqual(@as(u32, 34), info.metadata.gid);
        try std.testing.expectEqual(@as(u64, 1), info.nlink);
        const legacy_link = try volume.stat("/legacy-link");
        try std.testing.expectEqual(devdrive.metadata.Kind.symlink, legacy_link.metadata.kind);
        var target: [6]u8 = undefined;
        try std.testing.expectEqual(target.len, try volume.readObject(legacy_link.object_id.?, &target, 0));
        try std.testing.expectEqualStrings("target", &target);
        try std.testing.expectEqual(@as(u64, 3), (try volume.stat("/parent")).nlink);
        try volume.remove("/parent/child");
        try std.testing.expectEqual(@as(u64, 2), (try volume.stat("/parent")).nlink);
    }
}

test "object pins retain zero-link objects and reclamation drops tracking state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/pinned", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    const object_id = file.object_id;
    _ = try volume.writeFile(&file, "pinned", 0);
    try volume.closeFile(&file);

    var object_metadata = (try volume.statObject(object_id)).metadata;
    object_metadata.ctime_ns = 1;
    try volume.setObjectMetadata(object_id, object_metadata);
    try volume.pinObject(object_id);
    try std.testing.expectEqual(@as(u64, 1), volume.objectPinCount(object_id));
    try volume.remove("/pinned");
    const unlinked = try volume.statObject(object_id);
    try std.testing.expectEqual(@as(u64, 0), unlinked.nlink);
    try std.testing.expect(unlinked.metadata.ctime_ns > 1);
    try std.testing.expectEqual(@as(usize, 1), volume.trackedObjectCount());

    try volume.unpinObject(object_id);
    try std.testing.expectEqual(@as(u64, 0), volume.objectPinCount(object_id));
    try std.testing.expectEqual(@as(usize, 0), volume.trackedObjectCount());
    try std.testing.expectError(error.FileNotFound, volume.statObject(object_id));
    try std.testing.expectError(error.CorruptFilesystem, volume.linkCount(object_id));
    try std.testing.expectError(error.InvalidArgument, volume.unpinObject(object_id));
}

test "link count changes update object ctime including rename victims" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/links", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    const linked_id = file.object_id;
    try volume.closeFile(&file);
    var object_metadata = (try volume.statObject(linked_id)).metadata;
    object_metadata.ctime_ns = 1;
    try volume.setObjectMetadata(linked_id, object_metadata);
    try std.testing.expectError(error.FileNotFound, volume.link("/links", "/missing/alias"));
    try std.testing.expectEqual(@as(i64, 1), (try volume.statObject(linked_id)).metadata.ctime_ns);
    try volume.link("/links", "/links-alias");
    try std.testing.expect((try volume.statObject(linked_id)).metadata.ctime_ns > 1);
    object_metadata = (try volume.statObject(linked_id)).metadata;
    object_metadata.ctime_ns = 1;
    try volume.setObjectMetadata(linked_id, object_metadata);
    try volume.remove("/links-alias");
    try std.testing.expect((try volume.statObject(linked_id)).metadata.ctime_ns > 1);
    object_metadata = (try volume.statObject(linked_id)).metadata;
    object_metadata.ctime_ns = 1;
    try volume.setObjectMetadata(linked_id, object_metadata);
    try std.testing.expectError(error.FileNotFound, volume.rename("/links", "/missing/links"));
    try std.testing.expectEqual(@as(i64, 1), (try volume.statObject(linked_id)).metadata.ctime_ns);

    try volume.openFile(&file, "/victim", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    const victim_id = file.object_id;
    try volume.closeFile(&file);
    try volume.pinObject(victim_id);
    object_metadata = (try volume.statObject(victim_id)).metadata;
    object_metadata.ctime_ns = 1;
    try volume.setObjectMetadata(victim_id, object_metadata);
    try volume.rename("/links", "/victim");
    const victim = try volume.statObject(victim_id);
    try std.testing.expectEqual(@as(u64, 0), victim.nlink);
    try std.testing.expect(victim.metadata.ctime_ns > 1);
    try volume.unpinObject(victim_id);
}

test "writable mount removes stale temporary ObjectRef files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var temporary_path: [128:0]u8 = @splat(0);

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/persistent", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        const object_ref: devdrive.object_format.ObjectRef = .{
            .kind = .file,
            .object_id = file.object_id,
        };
        try volume.closeFile(&file);

        var id_buffer: [32]u8 = undefined;
        const id = devdrive.object_format.formatObjectId(object_ref.object_id, &id_buffer);
        const value = try std.fmt.bufPrint(temporary_path[0..128], "/system/tmp/{s}.ref", .{id});
        temporary_path[value.len] = 0;
        const bytes = object_ref.encode();
        var raw_file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try devdrive.volume.checkLfs(c.lfs_file_open(
            &volume.lfs,
            &raw_file,
            &temporary_path,
            c.LFS_O_WRONLY | c.LFS_O_CREAT | c.LFS_O_TRUNC,
        ));
        try devdrive.volume.checkLfs(c.lfs_file_write(&volume.lfs, &raw_file, &bytes, bytes.len));
        try devdrive.volume.checkLfs(c.lfs_file_close(&volume.lfs, &raw_file));
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var info: c.struct_lfs_info = undefined;
        try std.testing.expectEqual(
            @as(c_int, c.LFS_ERR_NOENT),
            c.lfs_stat(&volume.lfs, &temporary_path, &info),
        );
        _ = try volume.stat("/persistent");
    }
}
