const std = @import("std");
const Io = std.Io;
const File = Io.File;
const container = @import("container.zig");
const redo_runtime = @import("redo_runtime.zig");

pub const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("lfs.h");
});

const libdeflate = @cImport({
    @cInclude("libdeflate.h");
});

pub export fn lfs_crc(initial: u32, raw: ?*const anyopaque, size: usize) callconv(.c) u32 {
    if (size == 0) return initial;
    // littlefs stores the raw register; libdeflate complements both ends.
    return ~libdeflate.libdeflate_crc32(~initial, raw.?, size);
}

pub const FileBlockDevice = struct {
    io: Io,
    file: File,
    payload_start: u64,
    block_size: u32,
    block_count: u32,
    mutex: Io.Mutex = .init,
    redo_mutex: Io.Mutex = .init,
    fault: ?*FaultController = null,
    dirty: std.atomic.Value(bool) = .init(false),
    write_frozen: std.atomic.Value(bool) = .init(false),
    redo: ?redo_runtime.Runtime = null,

    pub fn init(io: Io, file: File, header: container.Header) FileBlockDevice {
        return .{
            .io = io,
            .file = file,
            .payload_start = header.payload_start,
            .block_size = header.block_size,
            .block_count = header.block_count,
        };
    }

    pub fn read(self: *FileBlockDevice, block: u32, offset: u32, buffer: []u8) !void {
        if (self.fault) |fault| if (fault.action(.read) == .before) return error.InjectedFault;
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            defer self.redo_mutex.unlock(self.io);
            return redo.read(block, offset, buffer);
        }
        const file_offset = try self.position(block, offset, buffer.len);
        const amount = try self.file.readPositionalAll(self.io, buffer, file_offset);
        if (amount != buffer.len) return error.UnexpectedEndOfFile;
    }

    pub fn program(self: *FileBlockDevice, block: u32, offset: u32, data: []const u8) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        const file_offset = try self.position(block, offset, data.len);
        const action = if (self.fault) |fault| fault.action(.program) else .none;
        if (action == .before or (action == .partial and data.len < 2)) {
            self.freezeWrites();
            return error.InjectedFault;
        }
        const write_data = if (action == .partial) data[0 .. data.len / 2] else data;
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            defer self.redo_mutex.unlock(self.io);
            redo.program(block, offset, write_data) catch |err| {
                self.freezeWrites();
                return err;
            };
        } else self.file.writePositionalAll(self.io, write_data, file_offset) catch |err| {
            self.freezeWrites();
            return err;
        };
        if (self.redo == null) self.dirty.store(true, .release);
        if (action == .partial or action == .after) {
            self.freezeWrites();
            return error.InjectedFault;
        }
    }

    pub fn sync(self: *FileBlockDevice) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            defer self.redo_mutex.unlock(self.io);
            try redo.logicalSync();
            if (!redo.hasActiveTransaction() and try redo.checkpointRecommended())
                redo.checkpoint(self.redoSync()) catch |err| {
                    self.freezeWrites();
                    return err;
                };
            return;
        }
        if (!self.dirty.load(.acquire)) return;
        try self.durableSync();
        self.dirty.store(false, .release);
    }

    pub fn enableRedo(self: *FileBlockDevice, allocator: std.mem.Allocator, header: container.Header) !void {
        if (self.redo != null) return error.RedoAlreadyEnabled;
        self.redo = try redo_runtime.Runtime.init(allocator, self.io, self.file, header);
    }

    pub fn deinit(self: *FileBlockDevice) void {
        if (self.redo) |*redo| {
            redo.deinit();
            self.redo = null;
        }
    }

    pub fn beginTransaction(self: *FileBlockDevice) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        const redo = &(self.redo orelse return);
        try self.redo_mutex.lock(self.io);
        defer self.redo_mutex.unlock(self.io);
        if (try redo.needsCheckpoint()) try redo.checkpoint(self.redoSync());
        try redo.begin();
    }

    pub fn commitTransaction(self: *FileBlockDevice) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            defer self.redo_mutex.unlock(self.io);
            redo.commit(self.redoSync()) catch |err| {
                self.freezeWrites();
                return err;
            };
        }
    }

    pub fn abortTransaction(self: *FileBlockDevice) !bool {
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            defer self.redo_mutex.unlock(self.io);
            const had_writes = redo.hasActiveWrites();
            redo.abort();
            if (had_writes) self.freezeWrites();
            return had_writes;
        }
        return false;
    }

    pub fn checkpointRedo(self: *FileBlockDevice) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            defer self.redo_mutex.unlock(self.io);
            redo.checkpoint(self.redoSync()) catch |err| {
                self.freezeWrites();
                return err;
            };
        }
    }

    pub fn isJournaled(self: *const FileBlockDevice) bool {
        return self.redo != null;
    }

    fn durableSync(self: *FileBlockDevice) !void {
        const action = if (self.fault) |fault| fault.action(.sync) else .none;
        if (action == .before) {
            self.freezeWrites();
            return error.InjectedFault;
        }
        self.file.sync(self.io) catch |err| {
            self.freezeWrites();
            return err;
        };
        if (action == .after) {
            self.freezeWrites();
            return error.InjectedFault;
        }
    }

    fn redoSync(self: *FileBlockDevice) redo_runtime.DurableSync {
        return .{ .context = self, .runFn = redoSyncCallback };
    }

    fn redoSyncCallback(raw: *anyopaque) !void {
        const self: *FileBlockDevice = @ptrCast(@alignCast(raw));
        try self.durableSync();
    }

    pub fn isWriteFrozen(self: *const FileBlockDevice) bool {
        return self.write_frozen.load(.acquire);
    }

    fn freezeWrites(self: *FileBlockDevice) void {
        self.write_frozen.store(true, .release);
    }

    fn position(self: *const FileBlockDevice, block: u32, offset: u32, len: usize) !u64 {
        if (block >= self.block_count or offset > self.block_size) return error.OutOfBounds;
        if (len > self.block_size - offset) return error.OutOfBounds;
        const block_offset = std.math.mul(u64, block, self.block_size) catch return error.OutOfBounds;
        return std.math.add(u64, self.payload_start, block_offset + offset) catch error.OutOfBounds;
    }

    pub fn configure(self: *FileBlockDevice, header: container.Header) c.struct_lfs_config {
        var config: c.struct_lfs_config = std.mem.zeroes(c.struct_lfs_config);
        config.context = self;
        config.read = readCallback;
        config.prog = programCallback;
        config.erase = eraseCallback;
        config.sync = syncCallback;
        config.lock = lockCallback;
        config.unlock = unlockCallback;
        config.read_size = header.read_size;
        config.prog_size = header.prog_size;
        config.block_size = header.block_size;
        config.block_count = header.block_count;
        config.block_cycles = -1;
        config.cache_size = header.block_size;
        config.lookahead_size = lookaheadSize(header.block_count);
        config.name_max = header.name_max;
        config.file_max = header.file_max;
        config.attr_max = header.attr_max;
        return config;
    }

    fn fromConfig(config: *const c.struct_lfs_config) *FileBlockDevice {
        return @ptrCast(@alignCast(config.context.?));
    }

    fn readCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t, offset: c.lfs_off_t, raw: ?*anyopaque, size: c.lfs_size_t) callconv(.c) c_int {
        const buffer = @as([*]u8, @ptrCast(raw.?))[0..size];
        fromConfig(config.?).read(block, offset, buffer) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn programCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t, offset: c.lfs_off_t, raw: ?*const anyopaque, size: c.lfs_size_t) callconv(.c) c_int {
        const data = @as([*]const u8, @ptrCast(raw.?))[0..size];
        fromConfig(config.?).program(block, offset, data) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn eraseCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t) callconv(.c) c_int {
        const self = fromConfig(config.?);
        if (block >= self.block_count) return c.LFS_ERR_IO;
        return 0;
    }

    fn syncCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        fromConfig(config.?).sync() catch return c.LFS_ERR_IO;
        return 0;
    }

    fn lockCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        const self = fromConfig(config.?);
        self.mutex.lock(self.io) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn unlockCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        const self = fromConfig(config.?);
        self.mutex.unlock(self.io);
        return 0;
    }
};

pub const FaultController = struct {
    fail_read_at: ?u64 = null,
    fail_program_at: ?u64 = null,
    fail_program_partial_at: ?u64 = null,
    fail_program_after_at: ?u64 = null,
    fail_sync_at: ?u64 = null,
    fail_sync_after_at: ?u64 = null,
    read_count: u64 = 0,
    program_count: u64 = 0,
    sync_count: u64 = 0,

    pub fn disable(self: *FaultController) void {
        self.fail_read_at = null;
        self.fail_program_at = null;
        self.fail_program_partial_at = null;
        self.fail_program_after_at = null;
        self.fail_sync_at = null;
        self.fail_sync_after_at = null;
    }

    fn action(self: *FaultController, operation: enum { read, program, sync }) FaultAction {
        const count = switch (operation) {
            .read => &self.read_count,
            .program => &self.program_count,
            .sync => &self.sync_count,
        };
        const current = count.*;
        count.* += 1;
        return switch (operation) {
            .read => if (matches(self.fail_read_at, current)) .before else .none,
            .program => if (matches(self.fail_program_at, current))
                .before
            else if (matches(self.fail_program_partial_at, current))
                .partial
            else if (matches(self.fail_program_after_at, current))
                .after
            else
                .none,
            .sync => if (matches(self.fail_sync_at, current))
                .before
            else if (matches(self.fail_sync_after_at, current))
                .after
            else
                .none,
        };
    }
};

const FaultAction = enum { none, before, partial, after };

fn matches(target: ?u64, current: u64) bool {
    return target != null and target.? == current;
}

fn lookaheadSize(block_count: u32) u32 {
    const bytes = std.math.divCeil(u32, block_count, 8) catch unreachable;
    return @max(8, @min(4096, std.mem.alignForward(u32, bytes, 8)));
}

test "block device enforces payload boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "device.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "BlockTest");
    header.state = .ready;
    try file.setLength(std.testing.io, header.payload_start + header.logical_size);
    var device = FileBlockDevice.init(std.testing.io, file, header);

    const data = [_]u8{ 1, 2, 3, 4 };
    const last_offset = header.block_size - @as(u32, data.len);
    try device.program(header.block_count - 1, last_offset, &data);
    var actual: [data.len]u8 = undefined;
    try device.read(header.block_count - 1, last_offset, &actual);
    try std.testing.expectEqualSlices(u8, &data, &actual);

    try std.testing.expectError(error.OutOfBounds, device.read(header.block_count, 0, &actual));
    try std.testing.expectError(error.OutOfBounds, device.read(0, header.block_size - 1, &actual));
    try std.testing.expectError(error.OutOfBounds, device.program(0, header.block_size, &data));
}

test "block device reports a truncated payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "truncated.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "Truncated");
    header.state = .ready;
    try file.setLength(std.testing.io, header.payload_start + 2);
    var device = FileBlockDevice.init(std.testing.io, file, header);
    var buffer: [4]u8 = undefined;
    try std.testing.expectError(error.UnexpectedEndOfFile, device.read(0, 0, &buffer));
}

test "journaled block device syncs once per committed transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "journaled.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "JournaledBlock");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var device = FileBlockDevice.init(std.testing.io, file, header);
    defer device.deinit();
    try device.enableRedo(std.testing.allocator, header);
    var fault: FaultController = .{};
    device.fault = &fault;

    try device.beginTransaction();
    try device.program(4, 32, "transaction");
    try device.sync();
    try std.testing.expectEqual(@as(u64, 0), fault.sync_count);
    try device.commitTransaction();
    try std.testing.expectEqual(@as(u64, 1), fault.sync_count);

    var actual: [11]u8 = undefined;
    try device.read(4, 32, &actual);
    try std.testing.expectEqualStrings("transaction", &actual);
    try device.checkpointRedo();
    try std.testing.expectEqual(@as(u64, 3), fault.sync_count);
}

test "journaled block device checkpoints low space on explicit sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "journal-pressure.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "JournalPressure");
    try header.enableRedoJournal(20 * 1024, 1);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var device = FileBlockDevice.init(std.testing.io, file, header);
    defer device.deinit();
    try device.enableRedo(std.testing.allocator, header);
    var fault: FaultController = .{};
    device.fault = &fault;

    try device.beginTransaction();
    try device.program(4, 32, "transaction");
    try device.commitTransaction();
    try std.testing.expectEqual(@as(u64, 1), fault.sync_count);
    try device.sync();
    try std.testing.expectEqual(@as(u64, 3), fault.sync_count);

    var home: [11]u8 = undefined;
    _ = try file.readPositionalAll(
        std.testing.io,
        &home,
        header.payload_start + 4 * header.block_size + 32,
    );
    try std.testing.expectEqualStrings("transaction", &home);
}

test "lookahead size is aligned and bounded" {
    try std.testing.expectEqual(@as(u32, 8), lookaheadSize(1));
    try std.testing.expectEqual(@as(u32, 16), lookaheadSize(65));
    try std.testing.expectEqual(@as(u32, 4096), lookaheadSize(std.math.maxInt(u32)));
}

test "littlefs CRC preserves raw streaming state" {
    const first = lfs_crc(0xffffffff, "1234".ptr, 4);
    try std.testing.expectEqual(@as(u32, 0x641c1f5c), first);
    try std.testing.expectEqual(@as(u32, 0x340bc6d9), lfs_crc(first, "56789".ptr, 5));
    try std.testing.expectEqual(@as(u32, 0x340bc6d9), lfs_crc(0xffffffff, "123456789".ptr, 9));
    try std.testing.expectEqual(@as(u32, 0x5dd2af4d), lfs_crc(0x12345678, "abc".ptr, 3));
    try std.testing.expectEqual(@as(u32, 0x2dfd2d88), lfs_crc(0, "123456789".ptr, 9));
    try std.testing.expectEqual(@as(u32, 0x12345678), lfs_crc(0x12345678, null, 0));
}

test "littlefs CRC matches the reference for arbitrary states and lengths" {
    var bytes: [1024]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index *% 37 +% index / 7);
    const initials = [_]u32{ 0, 1, 0x12345678, 0xffffffff };
    const lengths = [_]usize{ 1, 3, 4, 7, 8, 15, 16, 31, 64, 255, 256, 511, 512, 1024 };
    for (initials) |initial| {
        for (lengths) |length| {
            var reference: std.hash.crc.Crc32Jamcrc = .{ .crc = initial };
            reference.update(bytes[0..length]);
            try std.testing.expectEqual(reference.final(), lfs_crc(initial, bytes[0..length].ptr, length));
        }
    }
}
