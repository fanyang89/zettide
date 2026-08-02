const std = @import("std");
const Io = std.Io;
const File = Io.File;
const container = @import("container.zig");

pub const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("lfs.h");
});

pub const FileBlockDevice = struct {
    io: Io,
    file: File,
    payload_start: u64,
    block_size: u32,
    block_count: u32,
    mutex: Io.Mutex = .init,
    fault: ?*FaultController = null,
    dirty: std.atomic.Value(bool) = .init(false),
    write_frozen: std.atomic.Value(bool) = .init(false),

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
        self.file.writePositionalAll(self.io, write_data, file_offset) catch |err| {
            self.freezeWrites();
            return err;
        };
        self.dirty.store(true, .release);
        if (action == .partial or action == .after) {
            self.freezeWrites();
            return error.InjectedFault;
        }
    }

    pub fn sync(self: *FileBlockDevice) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (!self.dirty.load(.acquire)) return;
        const action = if (self.fault) |fault| fault.action(.sync) else .none;
        if (action == .before) {
            self.freezeWrites();
            return error.InjectedFault;
        }
        self.file.sync(self.io) catch |err| {
            self.freezeWrites();
            return err;
        };
        self.dirty.store(false, .release);
        if (action == .after) {
            self.freezeWrites();
            return error.InjectedFault;
        }
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

test "lookahead size is aligned and bounded" {
    try std.testing.expectEqual(@as(u32, 8), lookaheadSize(1));
    try std.testing.expectEqual(@as(u32, 16), lookaheadSize(65));
    try std.testing.expectEqual(@as(u32, 4096), lookaheadSize(std.math.maxInt(u32)));
}
