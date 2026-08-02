const std = @import("std");
const zettide = @import("zettide");
const Volume = zettide.volume.Volume;
const FileHandle = zettide.volume.FileHandle;
const c = zettide.volume.c;

fn createPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const root_length = try tmp.dir.realPath(std.testing.io, buffer);
    const suffix = try std.fmt.bufPrint(buffer[root_length..], "/fault.ddv", .{});
    return buffer[0 .. root_length + suffix.len];
}

fn failLfsLock(_: ?*const c.struct_lfs_config) callconv(.c) c_int {
    return c.LFS_ERR_CORRUPT;
}

fn expectReopen(path: []const u8) !void {
    var reopened = try Volume.open(std.testing.io, path, true);
    defer reopened.deinit();
    try reopened.mount();
}

fn objectCount(volume: *Volume) !usize {
    var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
    try zettide.volume.checkLfs(c.lfs_dir_open(&volume.lfs, &directory, "/system/objects"));
    defer _ = c.lfs_dir_close(&volume.lfs, &directory);
    var count: usize = 0;
    while (true) {
        var info: c.struct_lfs_info = undefined;
        const result = c.lfs_dir_read(&volume.lfs, &directory, &info);
        try zettide.volume.checkLfs(result);
        if (result == 0) return count;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) count += 1;
    }
}

test "a failed initial head write leaves a recoverable orphan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 1024 * 1024, "CreateFaultTest");

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        var fault: zettide.block_device.FaultController = .{ .fail_sync_at = 2 };
        volume.device.fault = &fault;
        try std.testing.expectError(
            error.InputOutput,
            volume.openFile(&file, "/failed", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1),
        );
        try std.testing.expect(volume.isWriteFrozen());
        fault.disable();
    }

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        try std.testing.expectEqual(@as(usize, 0), try objectCount(&volume));
        try std.testing.expectError(error.FileNotFound, volume.stat("/failed"));
    }
}

test "block device program faults have deterministic side effects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var header = try zettide.container.Header.init(std.testing.io, 1024 * 1024, "ProgramFaults");
    header.state = .ready;

    {
        const file = try tmp.dir.createFile(std.testing.io, "before.ddv", .{ .read = true });
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, header.payload_start + header.logical_size);
        var device = zettide.block_device.FileBlockDevice.init(std.testing.io, file, header);
        var fault: zettide.block_device.FaultController = .{
            .fail_program_at = 0,
            .fail_program_partial_at = 0,
            .fail_program_after_at = 0,
        };
        device.fault = &fault;
        try std.testing.expectError(error.InjectedFault, device.program(0, 0, "abcde"));
        try std.testing.expectEqual(@as(u64, 1), fault.program_count);
        try std.testing.expect(device.isWriteFrozen());
        var actual: [5]u8 = undefined;
        try device.read(0, 0, &actual);
        try std.testing.expectEqualSlices(u8, &@as([5]u8, @splat(0)), &actual);
    }

    {
        const file = try tmp.dir.createFile(std.testing.io, "partial.ddv", .{ .read = true });
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, header.payload_start + header.logical_size);
        var device = zettide.block_device.FileBlockDevice.init(std.testing.io, file, header);
        var fault: zettide.block_device.FaultController = .{ .fail_program_partial_at = 0 };
        device.fault = &fault;
        try std.testing.expectError(error.InjectedFault, device.program(0, 0, "abcde"));
        try std.testing.expect(device.isWriteFrozen());
        var actual: [5]u8 = undefined;
        try device.read(0, 0, &actual);
        try std.testing.expectEqualSlices(u8, "ab\x00\x00\x00", &actual);
        fault.disable();
        try std.testing.expectError(error.WriteFrozen, device.program(0, 0, "other"));
        try std.testing.expectEqual(@as(u64, 1), fault.program_count);
    }

    {
        const file = try tmp.dir.createFile(std.testing.io, "after.ddv", .{ .read = true });
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, header.payload_start + header.logical_size);
        var device = zettide.block_device.FileBlockDevice.init(std.testing.io, file, header);
        var fault: zettide.block_device.FaultController = .{ .fail_program_after_at = 0 };
        device.fault = &fault;
        try std.testing.expectError(error.InjectedFault, device.program(0, 0, "abcde"));
        try std.testing.expect(device.isWriteFrozen());
        var actual: [5]u8 = undefined;
        try device.read(0, 0, &actual);
        try std.testing.expectEqualStrings("abcde", &actual);
    }
}

test "a real block device program error freezes writes but permits reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var header = try zettide.container.Header.init(std.testing.io, 1024 * 1024, "RealFaults");
    header.state = .ready;

    {
        const setup = try tmp.dir.createFile(std.testing.io, "readonly.ddv", .{ .read = true });
        try setup.setLength(std.testing.io, header.payload_start + header.logical_size);
        setup.close(std.testing.io);
        const file = try tmp.dir.openFile(std.testing.io, "readonly.ddv", .{ .mode = .read_only });
        defer file.close(std.testing.io);
        var device = zettide.block_device.FileBlockDevice.init(std.testing.io, file, header);
        device.program(0, 0, "data") catch {};
        try std.testing.expect(device.isWriteFrozen());
        var actual: [4]u8 = undefined;
        try device.read(0, 0, &actual);
        try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &actual);
    }
}

test "caller and read failures do not freeze writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "non-write-faults.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try zettide.container.Header.init(std.testing.io, 1024 * 1024, "NonWriteFaults");
    header.state = .ready;
    try file.setLength(std.testing.io, header.payload_start + header.logical_size);
    var device = zettide.block_device.FileBlockDevice.init(std.testing.io, file, header);

    try std.testing.expectError(error.OutOfBounds, device.program(header.block_count, 0, "data"));
    try std.testing.expect(!device.isWriteFrozen());
    var fault: zettide.block_device.FaultController = .{ .fail_read_at = 0 };
    device.fault = &fault;
    var actual: [4]u8 = undefined;
    try std.testing.expectError(error.InjectedFault, device.read(0, 0, &actual));
    try std.testing.expect(!device.isWriteFrozen());
    try device.program(0, 0, "data");
}

test "a failed sync freezes writes until the volume is reopened" {
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

        var fault: zettide.block_device.FaultController = .{ .fail_sync_at = 0 };
        volume.device.fault = &fault;
        volume.device.dirty.store(true, .release);
        try std.testing.expectError(error.InputOutput, volume.syncFile(&file));
        try std.testing.expect(file.open);
        try std.testing.expect(volume.isWriteFrozen());
        fault.disable();
        try std.testing.expectError(error.VolumeFrozen, volume.syncFile(&file));
        var actual: [7]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, 0));
        try std.testing.expectEqualStrings("durable", &actual);
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
        try volume.syncFile(&file);
        try volume.closeFile(&file);
    }
}

test "an after-side-effect sync is durable but freezes the volume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 1024 * 1024, "AfterSyncTest");

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "durable", 0);
        var fault: zettide.block_device.FaultController = .{ .fail_sync_after_at = 0 };
        volume.device.fault = &fault;
        volume.device.dirty.store(true, .release);
        try std.testing.expectError(error.InputOutput, volume.syncFile(&file));
        try std.testing.expect(volume.isWriteFrozen());
        fault.disable();
        try std.testing.expectError(error.VolumeFrozen, volume.writeFile(&file, "x", 0));
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
        try volume.sync();
        try volume.closeFile(&file);
    }
}

test "close releases resources after before and after sync failures" {
    const after_side_effects = [_]bool{ false, true };
    for (after_side_effects) |after_side_effect| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try createPath(&tmp, &path_buffer);
        try Volume.create(std.testing.io, path, 1024 * 1024, "CloseSyncFault");

        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var fault: zettide.block_device.FaultController = .{};
        if (after_side_effect) {
            fault.fail_sync_after_at = fault.sync_count;
        } else {
            fault.fail_sync_at = fault.sync_count;
            volume.config.lock = failLfsLock;
        }
        volume.device.fault = &fault;
        volume.device.dirty.store(true, .release);
        try std.testing.expectError(error.InputOutput, volume.close());
        try std.testing.expect(volume.closed);
        try std.testing.expect(!volume.mounted);
        try expectReopen(path);
    }
}

test "frozen close reports the first error and releases resources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 1024 * 1024, "FrozenClose");

    var volume = try Volume.open(std.testing.io, path, true);
    defer volume.deinit();
    try volume.mount();
    var fault: zettide.block_device.FaultController = .{ .fail_sync_at = 0 };
    volume.device.fault = &fault;
    volume.device.dirty.store(true, .release);
    try std.testing.expectError(error.InputOutput, volume.sync());
    fault.disable();
    const sync_count = fault.sync_count;
    try std.testing.expectError(error.VolumeFrozen, volume.close());
    try std.testing.expectEqual(sync_count, fault.sync_count);
    try std.testing.expect(volume.isWriteFrozen());
    try expectReopen(path);
}

test "unmount failure does not retain maps or the container lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 1024 * 1024, "UnmountCloseFault");

    var volume = try Volume.open(std.testing.io, path, true);
    defer volume.deinit();
    try volume.mount();
    volume.config.lock = failLfsLock;
    try std.testing.expectError(error.CorruptFilesystem, volume.close());
    try std.testing.expect(volume.closed);
    try std.testing.expect(!volume.mounted);
    try expectReopen(path);
}

test "partial and after-side-effect programs freeze all volume mutations" {
    const actions = [_]enum { partial, after }{ .partial, .after };
    for (actions) |action| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try createPath(&tmp, &path_buffer);
        try Volume.create(std.testing.io, path, 1024 * 1024, "ProgramVolumeFault");

        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "original", 0);
        try volume.syncFile(&file);

        var fault: zettide.block_device.FaultController = .{};
        switch (action) {
            .partial => fault.fail_program_partial_at = 0,
            .after => fault.fail_program_after_at = 0,
        }
        volume.device.fault = &fault;
        try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "changed", 0));
        try std.testing.expect(volume.isWriteFrozen());
        try std.testing.expectEqual(@as(u64, 1), fault.program_count);
        fault.disable();

        var actual: [8]u8 = undefined;
        _ = try volume.readFile(&file, &actual, 0);
        try std.testing.expectError(error.VolumeFrozen, volume.truncateFile(&file, 0));
        try std.testing.expectError(error.VolumeFrozen, volume.fallocateFile(&file, 0, 1));
        try std.testing.expectError(error.VolumeFrozen, volume.persistMetadata(&file));
        try std.testing.expectError(error.InputOutput, volume.makeDirectory("/blocked", 0o40755, 1, 1));
        try std.testing.expectEqual(@as(u64, 1), fault.program_count);
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
    const offset = zettide.object_format.chunk_size - 2;
    _ = try volume.writeFile(&file, "abcd", offset);

    var fault: zettide.block_device.FaultController = .{ .fail_sync_at = 1 };
    volume.device.fault = &fault;
    try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "WXYZ", offset));
    try std.testing.expect(volume.isWriteFrozen());
    fault.disable();

    var unchanged: [4]u8 = undefined;
    try std.testing.expectEqual(unchanged.len, try volume.readFile(&file, &unchanged, offset));
    try std.testing.expectEqualStrings("abcd", &unchanged);

    try std.testing.expectError(error.VolumeFrozen, volume.writeFile(&file, "WXYZ", offset));
    try volume.closeFile(&file);
}

test "a disjoint write does not publish chunks from a failed generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 8 * 1024 * 1024, "DisjointFaultTest");
    const failed_offset = zettide.object_format.chunk_size - 2;

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "abcd", failed_offset);

        var fault: zettide.block_device.FaultController = .{ .fail_sync_at = 1 };
        volume.device.fault = &fault;
        try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "WXYZ", failed_offset));
        fault.disable();

        try std.testing.expectError(
            error.VolumeFrozen,
            volume.writeFile(&file, "safe", 2 * zettide.object_format.chunk_size),
        );
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

test "a frozen device rejects direct store writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 8 * 1024 * 1024, "DirectStoreFaultTest");
    const failed_offset = zettide.object_format.chunk_size - 2;

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "abcd", failed_offset);

        var fault: zettide.block_device.FaultController = .{ .fail_sync_at = 3 };
        volume.device.fault = &fault;
        try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "WXYZ", failed_offset));
        fault.disable();

        const store: zettide.object_store.Store = .{ .io = volume.io, .lfs = &volume.lfs };
        try std.testing.expectError(
            error.InputOutput,
            store.write(file.object_id, "safe", 2 * zettide.object_format.chunk_size),
        );
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

test "a direct store write removes rolled-back future chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 8 * 1024 * 1024, "DirectStoreRecoveryTest");
    const future_offset = 0;
    const disjoint_offset = 2 * zettide.object_format.chunk_size;
    const committed_offset = 3 * zettide.object_format.chunk_size;

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "committed", committed_offset);
        try volume.syncFile(&file);

        const store: zettide.object_store.Store = .{ .io = volume.io, .lfs = &volume.lfs };
        const old_head = try store.readHead(file.object_id);
        const future = try store.write(file.object_id, "future", future_offset);
        try std.testing.expect(future.head.data_generation > old_head.data_generation);
        var future_actual: [6]u8 = undefined;
        try std.testing.expectEqual(future_actual.len, try store.read(file.object_id, &future_actual, future_offset));
        try std.testing.expectEqualStrings("future", &future_actual);
        try store.writeHead(old_head);
        _ = try store.write(file.object_id, "safe", disjoint_offset);

        var actual: [6]u8 = undefined;
        try std.testing.expectEqual(actual.len, try store.read(file.object_id, &actual, future_offset));
        try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &actual);
        var committed: [9]u8 = undefined;
        try std.testing.expectEqual(committed.len, try store.read(file.object_id, &committed, committed_offset));
        try std.testing.expectEqualStrings("committed", &committed);
        try volume.sync();
        try volume.closeFile(&file);
    }

    {
        var volume = try Volume.open(std.testing.io, path, false);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_RDONLY, 0, 0, 0);
        var actual: [6]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, future_offset));
        try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &actual);
        var committed: [9]u8 = undefined;
        try std.testing.expectEqual(committed.len, try volume.readFile(&file, &committed, committed_offset));
        try std.testing.expectEqualStrings("committed", &committed);
        try volume.closeFile(&file);
    }
}

test "a no-op truncate does not publish chunks from a failed generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 8 * 1024 * 1024, "TruncateFaultTest");
    const failed_offset = zettide.object_format.chunk_size - 2;
    const logical_size = zettide.object_format.chunk_size + 2;

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "abcd", failed_offset);

        var fault: zettide.block_device.FaultController = .{ .fail_sync_at = 1 };
        volume.device.fault = &fault;
        try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "WXYZ", failed_offset));
        fault.disable();

        try std.testing.expectError(error.VolumeFrozen, volume.truncateFile(&file, logical_size));
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
