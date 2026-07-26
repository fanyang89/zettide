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

test "block device program faults have deterministic side effects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var header = try devdrive.container.Header.init(std.testing.io, 1024 * 1024, "ProgramFaults");
    header.state = .ready;

    {
        const file = try tmp.dir.createFile(std.testing.io, "before.ddv", .{ .read = true });
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, header.payload_start + header.logical_size);
        var device = devdrive.block_device.FileBlockDevice.init(std.testing.io, file, header);
        var fault: devdrive.block_device.FaultController = .{
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
        var device = devdrive.block_device.FileBlockDevice.init(std.testing.io, file, header);
        var fault: devdrive.block_device.FaultController = .{ .fail_program_partial_at = 0 };
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
        var device = devdrive.block_device.FileBlockDevice.init(std.testing.io, file, header);
        var fault: devdrive.block_device.FaultController = .{ .fail_program_after_at = 0 };
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
    var header = try devdrive.container.Header.init(std.testing.io, 1024 * 1024, "RealFaults");
    header.state = .ready;

    {
        const setup = try tmp.dir.createFile(std.testing.io, "readonly.ddv", .{ .read = true });
        try setup.setLength(std.testing.io, header.payload_start + header.logical_size);
        setup.close(std.testing.io);
        const file = try tmp.dir.openFile(std.testing.io, "readonly.ddv", .{ .mode = .read_only });
        defer file.close(std.testing.io);
        var device = devdrive.block_device.FileBlockDevice.init(std.testing.io, file, header);
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
    var header = try devdrive.container.Header.init(std.testing.io, 1024 * 1024, "NonWriteFaults");
    header.state = .ready;
    try file.setLength(std.testing.io, header.payload_start + header.logical_size);
    var device = devdrive.block_device.FileBlockDevice.init(std.testing.io, file, header);

    try std.testing.expectError(error.OutOfBounds, device.program(header.block_count, 0, "data"));
    try std.testing.expect(!device.isWriteFrozen());
    var fault: devdrive.block_device.FaultController = .{ .fail_read_at = 0 };
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

        var fault: devdrive.block_device.FaultController = .{ .fail_sync_at = 0 };
        volume.device.fault = &fault;
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
        var fault: devdrive.block_device.FaultController = .{ .fail_sync_after_at = 0 };
        volume.device.fault = &fault;
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

        var fault: devdrive.block_device.FaultController = .{};
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
    const offset = devdrive.object_format.chunk_size - 2;
    _ = try volume.writeFile(&file, "abcd", offset);

    var fault: devdrive.block_device.FaultController = .{ .fail_sync_at = 1 };
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

        try std.testing.expectError(
            error.VolumeFrozen,
            volume.writeFile(&file, "safe", 2 * devdrive.object_format.chunk_size),
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

test "a direct store write does not publish chunks from a failed generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try createPath(&tmp, &path_buffer);
    try Volume.create(std.testing.io, path, 8 * 1024 * 1024, "DirectStoreFaultTest");
    const failed_offset = devdrive.object_format.chunk_size - 2;

    {
        var volume = try Volume.open(std.testing.io, path, true);
        defer volume.deinit();
        try volume.mount();
        var file: FileHandle = undefined;
        try volume.openFile(&file, "/data", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1, 1);
        _ = try volume.writeFile(&file, "abcd", failed_offset);

        var fault: devdrive.block_device.FaultController = .{ .fail_sync_at = 3 };
        volume.device.fault = &fault;
        try std.testing.expectError(error.InputOutput, volume.writeFile(&file, "WXYZ", failed_offset));
        fault.disable();

        const store: devdrive.object_store.Store = .{ .io = volume.io, .lfs = &volume.lfs };
        try std.testing.expectError(
            error.InputOutput,
            store.write(file.object_id, "safe", 2 * devdrive.object_format.chunk_size),
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
