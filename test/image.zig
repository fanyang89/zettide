const std = @import("std");
const zettide = @import("zettide");
const Volume = zettide.volume.Volume;
const FileHandle = zettide.volume.FileHandle;
const DirectoryHandle = zettide.volume.DirectoryHandle;
const c = zettide.volume.c;

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

fn writeFileWorker(
    volume: *Volume,
    handle: *FileHandle,
    completed: *std.atomic.Value(bool),
) !usize {
    defer completed.store(true, .release);
    return volume.writeFile(handle, "serialized", 0);
}

fn readReservations(
    volume: *Volume,
    object_id: zettide.object_format.ObjectId,
) !struct {
    head: zettide.object_format.ObjectHead,
    intervals: []zettide.object_format.ReservationInterval,
} {
    const store: zettide.object_store.Store = .{ .io = volume.io, .lfs = &volume.lfs };
    const head = try store.readHead(object_id);
    return .{
        .head = head,
        .intervals = try store.readReservationsAlloc(head, std.testing.allocator),
    };
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

test "new small objects store chunks without a private chunk directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    const before = try volume.usedBlocks();
    var file: FileHandle = undefined;
    try volume.openFile(&file, "/compact", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    const after_create = try volume.usedBlocks();
    try std.testing.expectEqual(@as(u32, 2), after_create - before);
    try std.testing.expectEqual(@as(usize, 5), try volume.writeFile(&file, "small", 0));
    try std.testing.expectEqual(after_create, try volume.usedBlocks());

    var id_buffer: [32]u8 = undefined;
    var chunks_path: [128:0]u8 = @splat(0);
    const value = try std.fmt.bufPrint(
        chunks_path[0..128],
        "/system/objects/{s}/chunks",
        .{zettide.object_format.formatObjectId(file.object_id, &id_buffer)},
    );
    chunks_path[value.len] = 0;
    var info: c.struct_lfs_info = undefined;
    try std.testing.expectEqual(@as(c_int, c.LFS_ERR_NOENT), c.lfs_stat(&volume.lfs, &chunks_path, &info));
    try volume.closeFile(&file);
}

test "co-located reads fall back to older chunks but not corrupt exact chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/versions", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try std.testing.expectEqual(@as(usize, 5), try volume.writeFile(&file, "older", 0));
    try std.testing.expectEqual(
        @as(usize, 1),
        try volume.writeFile(&file, "x", 2 * zettide.object_format.chunk_size),
    );

    var actual: [5]u8 = undefined;
    try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, 0));
    try std.testing.expectEqualStrings("older", &actual);

    const store: zettide.object_store.Store = .{ .io = volume.io, .lfs = &volume.lfs };
    const head = try store.readHead(file.object_id);
    var id_buffer: [32]u8 = undefined;
    var exact_path: [160:0]u8 = @splat(0);
    const exact = try std.fmt.bufPrint(
        exact_path[0..160],
        "/system/objects/{s}/{x:0>16}-{x:0>16}",
        .{
            zettide.object_format.formatObjectId(file.object_id, &id_buffer),
            @as(u64, 0),
            head.data_generation,
        },
    );
    exact_path[exact.len] = 0;
    var raw_file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
    try zettide.volume.checkLfs(c.lfs_file_open(
        &volume.lfs,
        &raw_file,
        &exact_path,
        c.LFS_O_WRONLY | c.LFS_O_CREAT | c.LFS_O_TRUNC,
    ));
    const corrupt: [24]u8 = @splat(0xa5);
    try zettide.volume.checkLfs(c.lfs_file_write(&volume.lfs, &raw_file, &corrupt, corrupt.len));
    try zettide.volume.checkLfs(c.lfs_file_close(&volume.lfs, &raw_file));

    try std.testing.expectError(error.CorruptFilesystem, volume.readFile(&file, &actual, 0));
    try volume.closeFile(&file);
}

test "legacy private chunk directories remain readable and writable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/legacy", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        var id_buffer: [32]u8 = undefined;
        var chunks_path: [128:0]u8 = @splat(0);
        const value = try std.fmt.bufPrint(
            chunks_path[0..128],
            "/system/objects/{s}/chunks",
            .{zettide.object_format.formatObjectId(file.object_id, &id_buffer)},
        );
        chunks_path[value.len] = 0;
        try zettide.volume.checkLfs(c.lfs_mkdir(&volume.lfs, &chunks_path));
        try std.testing.expectEqual(@as(usize, 9), try volume.writeFile(&file, "persisted", 0));
        try std.testing.expectEqual(
            @as(usize, 1),
            try volume.writeFile(&file, "x", 2 * zettide.object_format.chunk_size),
        );
        try volume.syncFile(&file);
        try volume.closeFile(&file);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/legacy", c.LFS_O_RDWR, 0, 0, 0);
        var actual: [9]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, 0));
        try std.testing.expectEqualStrings("persisted", &actual);
        var hole: [8]u8 = undefined;
        try std.testing.expectEqual(
            hole.len,
            try volume.readFile(&file, &hole, zettide.object_format.chunk_size),
        );
        try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), &hole);
        try std.testing.expectEqual(@as(usize, 1), try volume.writeFile(&file, "!", actual.len));
        try volume.closeFile(&file);
    }
}

test "explicit close is idempotent and persists writable data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/closed", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "persisted", 0);
        try volume.closeFile(&file);
        try volume.close();
        try volume.close();
        try std.testing.expectError(error.VolumeClosed, volume.mount());
        try std.testing.expectError(error.VolumeClosed, volume.sync());
    }

    var reopened = try openVolume(path);
    defer reopened.deinit();
    try reopened.mount();
    var file: FileHandle = undefined;
    try reopened.openFile(&file, "/closed", c.LFS_O_RDONLY, 0, 0, 0);
    var actual: [9]u8 = undefined;
    try std.testing.expectEqual(actual.len, try reopened.readFile(&file, &actual, 0));
    try std.testing.expectEqualStrings("persisted", &actual);
    try reopened.closeFile(&file);
}

test "read-only close does not issue a write sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);

    var volume = try Volume.open(std.testing.io, path, false);
    defer volume.deinit();
    try volume.mount();
    var fault: zettide.block_device.FaultController = .{ .fail_sync_at = 0 };
    volume.device.fault = &fault;
    try volume.close();
    try std.testing.expectEqual(@as(u64, 0), fault.sync_count);
}

test "clean file sync avoids a redundant backing sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();
    var fault: zettide.block_device.FaultController = .{};
    volume.device.fault = &fault;

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/clean-sync", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    _ = try volume.writeFile(&file, "already durable", 0);
    const sync_count = fault.sync_count;
    fault.fail_sync_at = sync_count;
    try volume.syncFile(&file);
    try std.testing.expectEqual(sync_count, fault.sync_count);
    try volume.closeFile(&file);
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
        try std.testing.expect(info.allocated_bytes < 2 * zettide.object_format.chunk_size);

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

        try volume.truncateFile(&file, zettide.object_format.max_file_size);
        try std.testing.expectEqual(
            zettide.object_format.max_file_size,
            (try volume.statFile(&file)).size,
        );
        try std.testing.expectError(
            error.FileTooLarge,
            volume.writeFile(&file, "x", zettide.object_format.max_file_size),
        );
        try volume.syncFile(&file);
        try volume.closeFile(&file);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        const info = try volume.stat("/sparse");
        try std.testing.expectEqual(zettide.object_format.max_file_size, info.size);
        try std.testing.expect(info.allocated_bytes < 2 * zettide.object_format.chunk_size);
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
    var orphan_id: zettide.object_format.ObjectId = undefined;

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
        const id = zettide.object_format.formatObjectId(orphan_id, &id_buffer);
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

test "directory identity survives rename and container reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var expected_identity: zettide.object_format.ObjectId = undefined;

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        try volume.makeDirectory("/identity-old", 0o40750, 10, 20);
        const before = try volume.stat("/identity-old");
        expected_identity = before.identity;

        var directory: DirectoryHandle = .{};
        try volume.openDirectory(&directory, "/identity-old");
        try std.testing.expectEqualSlices(u8, &expected_identity, &directory.info.identity);
        try volume.rename("/identity-old", "/identity-new");
        try std.testing.expectEqualSlices(u8, &expected_identity, &(try volume.stat("/identity-new")).identity);
        try std.testing.expectEqualSlices(u8, &expected_identity, &directory.info.identity);
        try volume.closeDirectory(&directory);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        try std.testing.expectEqualSlices(u8, &expected_identity, &(try volume.stat("/identity-new")).identity);
    }
}

test "directories from old images receive a compatible persistent identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var expected_identity: zettide.object_format.ObjectId = undefined;

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        try volume.makeDirectory("/legacy-directory", 0o40755, 1, 2);
        try zettide.volume.checkLfs(c.lfs_removeattr(
            &volume.lfs,
            "/namespace/legacy-directory",
            zettide.metadata.directory_identity_attribute_type,
        ));
    }

    {
        var volume = try Volume.open(std.testing.io, path, false);
        defer volume.deinit();
        try volume.mount();
        _ = try volume.stat("/legacy-directory");
        var stored_identity: zettide.object_format.ObjectId = undefined;
        try std.testing.expectEqual(
            @as(c_int, c.LFS_ERR_NOATTR),
            c.lfs_getattr(
                &volume.lfs,
                "/namespace/legacy-directory",
                zettide.metadata.directory_identity_attribute_type,
                &stored_identity,
                stored_identity.len,
            ),
        );
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        expected_identity = (try volume.stat("/legacy-directory")).identity;
        var stored_identity: zettide.object_format.ObjectId = undefined;
        try std.testing.expectEqual(
            @as(c_int, stored_identity.len),
            c.lfs_getattr(
                &volume.lfs,
                "/namespace/legacy-directory",
                zettide.metadata.directory_identity_attribute_type,
                &stored_identity,
                stored_identity.len,
            ),
        );
        try std.testing.expectEqualSlices(u8, &expected_identity, &stored_identity);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        try std.testing.expectEqualSlices(u8, &expected_identity, &(try volume.stat("/legacy-directory")).identity);
    }
}

test "default relatime updates once without changing ctime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/relatime", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 2);
    _ = try volume.writeFile(&file, "x", 0);
    var baseline = file.metadata;
    baseline.atime_ns = 1;
    baseline.ctime_ns = 2;
    try volume.setObjectMetadata(file.object_id, baseline);

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try volume.readFile(&file, &byte, 0));
    const first = (try volume.statFile(&file)).metadata;
    try std.testing.expect(first.atime_ns > baseline.atime_ns);
    try std.testing.expectEqual(baseline.ctime_ns, first.ctime_ns);
    try std.testing.expectEqual(@as(usize, 1), try volume.readFile(&file, &byte, 0));
    const second = (try volume.statFile(&file)).metadata;
    try std.testing.expectEqual(first.atime_ns, second.atime_ns);
    try std.testing.expectEqual(baseline.ctime_ns, second.ctime_ns);
    try volume.closeFile(&file);
}

test "noatime suppresses automatic file access time updates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mountOptions(.{ .access_time = .noatime });

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/noatime", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 2);
    _ = try volume.writeFile(&file, "x", 0);
    var baseline = file.metadata;
    baseline.atime_ns = 1;
    baseline.ctime_ns = 2;
    try volume.setObjectMetadata(file.object_id, baseline);

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try volume.readFile(&file, &byte, 0));
    const after = (try volume.statFile(&file)).metadata;
    try std.testing.expectEqual(baseline.atime_ns, after.atime_ns);
    try std.testing.expectEqual(baseline.ctime_ns, after.ctime_ns);
    try volume.closeFile(&file);
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

    const corrupt: [zettide.object_format.ref_encoded_size]u8 = @splat(0xa5);
    var raw_file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
    try zettide.volume.checkLfs(c.lfs_file_open(
        &volume.lfs,
        &raw_file,
        "/namespace/corrupt",
        c.LFS_O_WRONLY | c.LFS_O_TRUNC,
    ));
    try zettide.volume.checkLfs(c.lfs_file_write(&volume.lfs, &raw_file, &corrupt, corrupt.len));
    try zettide.volume.checkLfs(c.lfs_file_close(&volume.lfs, &raw_file));
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

test "write waits for the object transaction lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/contended", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);

    try volume.object_transaction_mutex.lock(std.testing.io);
    var mutex_locked = true;
    defer if (mutex_locked) volume.object_transaction_mutex.unlock(std.testing.io);

    var completed: std.atomic.Value(bool) = .init(false);
    var future = std.testing.io.async(writeFileWorker, .{ &volume, &file, &completed });
    var future_pending = true;
    defer if (future_pending) {
        if (mutex_locked) {
            volume.object_transaction_mutex.unlock(std.testing.io);
            mutex_locked = false;
        }
        _ = future.cancel(std.testing.io) catch 0;
    };

    while (volume.object_transaction_mutex.state.load(.acquire) != .contended) {
        try std.testing.expect(!completed.load(.acquire));
        try std.Thread.yield();
    }
    try std.testing.expect(!completed.load(.acquire));

    volume.object_transaction_mutex.unlock(std.testing.io);
    mutex_locked = false;
    const result = future.await(std.testing.io);
    future_pending = false;
    try std.testing.expectEqual(@as(usize, "serialized".len), try result);

    var actual: ["serialized".len]u8 = undefined;
    try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, 0));
    try std.testing.expectEqualStrings("serialized", &actual);
    try volume.closeFile(&file);
}

test "metadata patches preserve two-handle write and truncate updates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var first: FileHandle = undefined;
    var second: FileHandle = undefined;
    try volume.openFile(&first, "/patched", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 2);
    try volume.openFile(&second, "/patched", c.LFS_O_RDWR, 0, 0, 0);

    const before_write = second.metadata;
    _ = try volume.writeFile(&first, "latest", 0);
    const write_mtime = first.metadata.mtime_ns;
    const write_ctime = first.metadata.ctime_ns;
    try std.testing.expectEqual(first.metadata, second.metadata);
    second.metadata = before_write;
    const chmod_head = try volume.patchObjectMetadata(second.object_id, .{ .mode = 0o600 });
    try std.testing.expectEqual(@as(u32, 0o100600), chmod_head.metadata.mode);
    try std.testing.expectEqual(write_mtime, chmod_head.metadata.mtime_ns);
    try std.testing.expect(chmod_head.metadata.ctime_ns > write_ctime);
    try std.testing.expectEqual(chmod_head.metadata, first.metadata);
    try std.testing.expectEqual(chmod_head.metadata, second.metadata);

    const before_truncate = second.metadata;
    try volume.truncateFile(&first, 3);
    const truncate_mtime = first.metadata.mtime_ns;
    const truncate_ctime = first.metadata.ctime_ns;
    try std.testing.expectEqual(first.metadata, second.metadata);
    second.metadata = before_truncate;
    const chown_head = try volume.patchObjectMetadata(second.object_id, .{ .uid = 7, .gid = 8 });
    try std.testing.expectEqual(@as(u32, 7), chown_head.metadata.uid);
    try std.testing.expectEqual(@as(u32, 8), chown_head.metadata.gid);
    try std.testing.expectEqual(truncate_mtime, chown_head.metadata.mtime_ns);
    try std.testing.expect(chown_head.metadata.ctime_ns > truncate_ctime);
    try std.testing.expectEqual(chown_head.metadata, first.metadata);
    try std.testing.expectEqual(chown_head.metadata, second.metadata);

    try volume.closeFile(&first);
    try volume.closeFile(&second);
}

test "futimens-style patch is visible to every open handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var first: FileHandle = undefined;
    var second: FileHandle = undefined;
    try volume.openFile(&first, "/times", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100640, 11, 12);
    try volume.openFile(&second, "/times", c.LFS_O_RDWR, 0, 0, 0);
    const birthtime = first.metadata.birthtime_ns;
    first.metadata.windows_attributes = 0xa5;
    try volume.persistMetadata(&first);
    const before_times = first.metadata;

    const times_head = try volume.patchObjectMetadata(first.object_id, .{
        .atime_ns = 1_000_000_123,
        .mtime_ns = 2_000_000_456,
    });
    try std.testing.expect(times_head.metadata.ctime_ns > before_times.ctime_ns);
    try std.testing.expectEqual(@as(i64, 1_000_000_123), second.metadata.atime_ns);
    try std.testing.expectEqual(@as(i64, 2_000_000_456), second.metadata.mtime_ns);
    second.metadata = before_times;
    const mode_head = try volume.patchObjectMetadata(second.object_id, .{ .mode = 0o620 });
    try std.testing.expectEqual(times_head.metadata.atime_ns, mode_head.metadata.atime_ns);
    try std.testing.expectEqual(times_head.metadata.mtime_ns, mode_head.metadata.mtime_ns);
    try std.testing.expectEqual(zettide.metadata.Kind.file, mode_head.metadata.kind);
    try std.testing.expectEqual(birthtime, mode_head.metadata.birthtime_ns);
    try std.testing.expectEqual(@as(u32, 0xa5), mode_head.metadata.windows_attributes);
    try std.testing.expect(mode_head.metadata.ctime_ns > times_head.metadata.ctime_ns);
    try std.testing.expectEqual(mode_head.metadata, first.metadata);
    try std.testing.expectEqual(mode_head.metadata, second.metadata);

    try volume.closeFile(&first);
    try volume.closeFile(&second);
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

test "high-offset fallocate reserves only its sparse interval" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 16 * 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    const offset = 8 * zettide.object_format.chunk_size;
    var file: FileHandle = undefined;
    try volume.openFile(&file, "/high-offset", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try volume.fallocateFile(&file, offset, 4096);
    const stored = try readReservations(&volume, file.object_id);
    defer std.testing.allocator.free(stored.intervals);
    try std.testing.expectEqual(@as(usize, 1), stored.intervals.len);
    try std.testing.expectEqual(@as(u64, offset), stored.intervals[0].start);
    try std.testing.expectEqual(@as(u64, offset + 4096), stored.intervals[0].end);
    try std.testing.expectEqual(@as(u64, 4096), stored.head.reservation_interval_bytes);
    try std.testing.expectEqual(@as(u64, 4096), stored.head.reservation_payload_bytes);
    try std.testing.expectEqual(@as(u64, 1), stored.head.reservation_chunk_count);
    try std.testing.expectEqual(@as(u64, offset + 4096), (try volume.statFile(&file)).size);
    try volume.closeFile(&file);
}

test "fallocate merges overlaps and keeps disjoint hole writes unreserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 32 * 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/intervals", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    const chunk = zettide.object_format.chunk_size;
    try volume.fallocateFile(&file, chunk + 4096, 4096);
    try volume.fallocateFile(&file, chunk, 4096);
    try volume.fallocateFile(&file, chunk + 2048, 8192);
    var index: u64 = 3;
    while (index < 15) : (index += 1) try volume.fallocateFile(&file, index * chunk, 4096);

    const stored = try readReservations(&volume, file.object_id);
    defer std.testing.allocator.free(stored.intervals);
    try std.testing.expectEqual(@as(usize, 13), stored.intervals.len);
    try std.testing.expectEqual(@as(u64, chunk), stored.intervals[0].start);
    try std.testing.expectEqual(@as(u64, chunk + 10 * 1024), stored.intervals[0].end);
    const store: zettide.object_store.Store = .{ .io = volume.io, .lfs = &volume.lfs };
    try std.testing.expect((try store.writeFootprint(file.object_id, chunk + 1024, 4096)).reserved);
    try std.testing.expect(!(try store.writeFootprint(file.object_id, 2 * chunk, 4096)).reserved);
    try std.testing.expect(!(try store.writeFootprint(file.object_id, chunk + 8192, 2 * chunk)).reserved);
    try volume.closeFile(&file);
}

test "reservation sidecar selection persists and recovery removes unselected versions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 8 * 1024 * 1024);
    var object_id: zettide.object_format.ObjectId = undefined;
    var selected_generation: u64 = 0;

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/persistent-reservation", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        object_id = file.object_id;
        try volume.fallocateFile(&file, 4096, 4096);
        try volume.fallocateFile(&file, 16384, 4096);
        const stored = try readReservations(&volume, object_id);
        defer std.testing.allocator.free(stored.intervals);
        selected_generation = stored.head.reservation_generation;

        var id_buffer: [32]u8 = undefined;
        var orphan_path: [160:0]u8 = @splat(0);
        const id = zettide.object_format.formatObjectId(object_id, &id_buffer);
        const value = try std.fmt.bufPrint(
            orphan_path[0..160],
            "/system/objects/{s}/reservation-{x:0>16}",
            .{ id, selected_generation + 1 },
        );
        orphan_path[value.len] = 0;
        var orphan: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try zettide.volume.checkLfs(c.lfs_file_open(
            &volume.lfs,
            &orphan,
            &orphan_path,
            c.LFS_O_WRONLY | c.LFS_O_CREAT | c.LFS_O_TRUNC,
        ));
        try zettide.volume.checkLfs(c.lfs_file_close(&volume.lfs, &orphan));
        try volume.closeFile(&file);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        const stored = try readReservations(&volume, object_id);
        defer std.testing.allocator.free(stored.intervals);
        try std.testing.expectEqual(selected_generation, stored.head.reservation_generation);
        try std.testing.expectEqual(@as(usize, 2), stored.intervals.len);

        var id_buffer: [32]u8 = undefined;
        var orphan_path: [160:0]u8 = @splat(0);
        const id = zettide.object_format.formatObjectId(object_id, &id_buffer);
        const value = try std.fmt.bufPrint(
            orphan_path[0..160],
            "/system/objects/{s}/reservation-{x:0>16}",
            .{ id, selected_generation + 1 },
        );
        orphan_path[value.len] = 0;
        var info: c.struct_lfs_info = undefined;
        try std.testing.expectEqual(@as(c_int, c.LFS_ERR_NOENT), c.lfs_stat(&volume.lfs, &orphan_path, &info));
    }
}

test "fallocate reservations persist, isolate space, share links, and release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 8 * 1024 * 1024);
    var expected_blocks: u64 = 0;

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/reserved-a", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "preserved", 0);
        try volume.fallocateFile(&file, 64 * 1024, 64 * 1024);
        const info = try volume.statFile(&file);
        try std.testing.expectEqual(@as(u64, 128 * 1024), info.size);
        var contents: [9]u8 = undefined;
        try std.testing.expectEqual(contents.len, try volume.readFile(&file, &contents, 0));
        try std.testing.expectEqualStrings("preserved", &contents);
        var zeroes: [32]u8 = undefined;
        try std.testing.expectEqual(zeroes.len, try volume.readFile(&file, &zeroes, 4096));
        for (zeroes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        expected_blocks = volume.reservedCapacityBlocks();
        try std.testing.expect(expected_blocks != 0);
        try volume.link("/reserved-a", "/reserved-b");
        try std.testing.expectEqual(expected_blocks, volume.reservedCapacityBlocks());
        try volume.syncFile(&file);
        try volume.closeFile(&file);
    }

    {
        var volume = try openVolume(path);
        defer volume.deinit();
        try volume.mount();
        try std.testing.expectEqual(expected_blocks, volume.reservedCapacityBlocks());
        try std.testing.expectEqualSlices(
            u8,
            &(try volume.stat("/reserved-a")).object_id.?,
            &(try volume.stat("/reserved-b")).object_id.?,
        );

        var hog: FileHandle = undefined;
        try volume.openFile(&hog, "/hog", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        const block: [4096]u8 = @splat(0x5a);
        var index: u64 = 0;
        while (index < 4096) : (index += 1) {
            _ = volume.writeFile(&hog, &block, index * zettide.object_format.chunk_size) catch |err| switch (err) {
                error.NoSpaceLeft => break,
                else => return err,
            };
        }
        try std.testing.expect(index < 4096);

        var directory_index: usize = 0;
        while (directory_index < 4096) : (directory_index += 1) {
            var name_buffer: [64:0]u8 = @splat(0);
            const name = try std.fmt.bufPrint(name_buffer[0..64], "/metadata-hog-{d}", .{directory_index});
            name_buffer[name.len] = 0;
            volume.makeDirectory(&name_buffer, 0o40755, 1, 1) catch |err| switch (err) {
                error.NoSpaceLeft => break,
                else => return err,
            };
        }
        try std.testing.expect(directory_index < 4096);

        var reserved: FileHandle = undefined;
        try volume.openFile(&reserved, "/reserved-b", c.LFS_O_RDWR, 0, 0, 0);
        try std.testing.expectError(error.NoSpaceLeft, volume.writeFile(&reserved, &block, 32 * 1024));
        try std.testing.expectEqual(block.len, try volume.writeFile(&reserved, &block, 96 * 1024));
        const post_write_blocks = volume.reservedCapacityBlocks();
        var actual: [9]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&reserved, &actual, 0));
        try std.testing.expectEqualStrings("preserved", &actual);

        try volume.remove("/reserved-a");
        try std.testing.expectEqual(post_write_blocks, volume.reservedCapacityBlocks());
        try volume.remove("/reserved-b");
        try std.testing.expectEqual(@as(u64, 0), (try volume.statFile(&reserved)).nlink);
        try std.testing.expectEqual(post_write_blocks, volume.reservedCapacityBlocks());
        try volume.closeFile(&reserved);
        try std.testing.expectEqual(@as(u64, 0), volume.reservedCapacityBlocks());

        var released: FileHandle = undefined;
        try volume.openFile(&released, "/released", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        try std.testing.expectEqual(block.len, try volume.writeFile(&released, &block, 0));
        try volume.closeFile(&released);
        try volume.closeFile(&hog);
    }
}

test "truncate and open truncation release fallocate reservations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 8 * 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/truncate-reservation", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try volume.fallocateFile(&file, 0, 128 * 1024);
    try volume.fallocateFile(&file, 256 * 1024, 128 * 1024);
    const full = volume.reservedCapacityBlocks();
    try volume.truncateFile(&file, 320 * 1024);
    var stored = try readReservations(&volume, file.object_id);
    try std.testing.expectEqual(@as(usize, 2), stored.intervals.len);
    try std.testing.expectEqual(@as(u64, 320 * 1024), stored.intervals[1].end);
    std.testing.allocator.free(stored.intervals);
    try volume.truncateFile(&file, 32 * 1024);
    stored = try readReservations(&volume, file.object_id);
    try std.testing.expectEqual(@as(usize, 1), stored.intervals.len);
    try std.testing.expectEqual(@as(u64, 32 * 1024), stored.intervals[0].end);
    std.testing.allocator.free(stored.intervals);
    try std.testing.expect(volume.reservedCapacityBlocks() < full);
    try std.testing.expect(volume.reservedCapacityBlocks() != 0);
    try volume.closeFile(&file);

    try volume.openFile(&file, "/truncate-reservation", c.LFS_O_RDWR | c.LFS_O_TRUNC, 0, 0, 0);
    try std.testing.expectEqual(@as(u64, 0), volume.reservedCapacityBlocks());
    try volume.closeFile(&file);
}

test "fallocate rejects ranges beyond the supported file size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createVolume(&tmp, &path_buffer, 1024 * 1024);
    var volume = try openVolume(path);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/invalid-reservation", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
    try std.testing.expectError(
        error.FileTooLarge,
        volume.fallocateFile(&file, zettide.object_format.max_file_size, 1),
    );
    try std.testing.expectEqual(@as(u64, 0), volume.reservedCapacityBlocks());
    try std.testing.expectError(error.InvalidArgument, volume.fallocateFile(&file, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), volume.reservedCapacityBlocks());
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
    var object_id: zettide.object_format.ObjectId = undefined;

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
        const id = zettide.object_format.formatObjectId(object_id, &id_buffer);
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
        try std.testing.expectEqual(zettide.metadata.Kind.fifo, info.metadata.kind);
        try std.testing.expectEqual(@as(u32, 0o010640), info.metadata.mode);
        try std.testing.expectEqual(@as(u32, 12), info.metadata.uid);
        try std.testing.expectEqual(@as(u32, 34), info.metadata.gid);
        try std.testing.expectEqual(@as(u64, 1), info.nlink);
        const legacy_link = try volume.stat("/legacy-link");
        try std.testing.expectEqual(zettide.metadata.Kind.symlink, legacy_link.metadata.kind);
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
        const object_ref: zettide.object_format.ObjectRef = .{
            .kind = .file,
            .object_id = file.object_id,
        };
        try volume.closeFile(&file);

        var id_buffer: [32]u8 = undefined;
        const id = zettide.object_format.formatObjectId(object_ref.object_id, &id_buffer);
        const value = try std.fmt.bufPrint(temporary_path[0..128], "/system/tmp/{s}.ref", .{id});
        temporary_path[value.len] = 0;
        const bytes = object_ref.encode();
        var raw_file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try zettide.volume.checkLfs(c.lfs_file_open(
            &volume.lfs,
            &raw_file,
            &temporary_path,
            c.LFS_O_WRONLY | c.LFS_O_CREAT | c.LFS_O_TRUNC,
        ));
        try zettide.volume.checkLfs(c.lfs_file_write(&volume.lfs, &raw_file, &bytes, bytes.len));
        try zettide.volume.checkLfs(c.lfs_file_close(&volume.lfs, &raw_file));
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
