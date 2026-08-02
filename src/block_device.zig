const std = @import("std");
const Io = std.Io;
const File = Io.File;
const container = @import("container.zig");
const file_io = @import("file_io.zig");
const redo_runtime = @import("redo_runtime.zig");

pub const Durability = union(enum) {
    durable,
    writeback: Writeback,

    pub const Writeback = struct {
        max_delay_ns: u64 = std.time.ns_per_ms,
    };
};

pub const FileIoKind = file_io.Kind;

const FlushResult = anyerror!void;

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
    file_io: file_io.FileIo,
    payload_start: u64,
    block_size: u32,
    block_count: u32,
    mutex: Io.Mutex = .init,
    redo_mutex: Io.Mutex = .init,
    fault: ?*FaultController = null,
    dirty: std.atomic.Value(bool) = .init(false),
    write_frozen: std.atomic.Value(bool) = .init(false),
    redo: ?redo_runtime.Runtime = null,
    durability: Durability = .durable,
    lifecycle_mutex: Io.Mutex = .init,
    group_mutex: Io.Mutex = .init,
    group_condition: Io.Condition = .init,
    flush_future: ?Io.Future(FlushResult) = null,
    flush_requested: bool = false,
    force_flush: bool = false,
    delay_elapsed: bool = false,
    closing: bool = false,
    accepting_writeback: bool = true,
    writeback_error: ?anyerror = null,
    accepted_epoch: std.atomic.Value(u64) = .init(0),
    durable_epoch: std.atomic.Value(u64) = .init(0),

    pub fn init(io: Io, file: File, header: container.Header) FileBlockDevice {
        var backend = file_io.FileIo.posix(file);
        return initWithFileIo(io, &backend, header);
    }

    pub fn initWithFileIo(io: Io, backend: *file_io.FileIo, header: container.Header) FileBlockDevice {
        const result: FileBlockDevice = .{
            .io = io,
            .file_io = backend.*,
            .payload_start = header.payload_start,
            .block_size = header.block_size,
            .block_count = header.block_count,
        };
        backend.* = undefined;
        return result;
    }

    pub fn read(self: *FileBlockDevice, block: u32, offset: u32, buffer: []u8) !void {
        if (self.fault) |fault| if (fault.action(.read) == .before) return error.InjectedFault;
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            defer self.redo_mutex.unlock(self.io);
            return redo.read(block, offset, buffer);
        }
        const file_offset = try self.position(block, offset, buffer.len);
        try self.file_io.readAllAt(self.io, .foreground, buffer, file_offset);
    }

    pub fn program(self: *FileBlockDevice, block: u32, offset: u32, data: []const u8) !void {
        try self.checkWritebackError();
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
        } else self.file_io.writeAllAt(self.io, .foreground, write_data, file_offset) catch |err| {
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
        try self.checkWritebackError();
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            redo.logicalSync() catch |err| {
                self.redo_mutex.unlock(self.io);
                return err;
            };
            const active = redo.hasActiveTransaction();
            self.redo_mutex.unlock(self.io);
            if (active) return;
            if (self.durability == .writeback) try self.flushWriteback();
            while (true) {
                try self.redo_mutex.lock(self.io);
                if (redo.hasPendingWrites()) {
                    self.redo_mutex.unlock(self.io);
                    try self.flushWriteback();
                    continue;
                }
                const recommended = redo.checkpointRecommended() catch |err| {
                    self.redo_mutex.unlock(self.io);
                    return err;
                };
                if (!recommended) {
                    self.redo_mutex.unlock(self.io);
                    break;
                }
                redo.checkpoint(self.redoSync()) catch |err| {
                    self.redo_mutex.unlock(self.io);
                    self.freezeWrites();
                    return err;
                };
                self.redo_mutex.unlock(self.io);
                break;
            }
            return;
        }
        if (!self.dirty.load(.acquire)) return;
        try self.durableSync();
        self.dirty.store(false, .release);
    }

    pub fn enableRedo(self: *FileBlockDevice, allocator: std.mem.Allocator, header: container.Header) !void {
        if (self.redo != null) return error.RedoAlreadyEnabled;
        self.redo = try redo_runtime.Runtime.initWithFileIo(
            allocator,
            self.io,
            self.file_io.borrow(),
            header,
        );
    }

    pub fn setDurability(self: *FileBlockDevice, durability: Durability) !void {
        try self.lifecycle_mutex.lock(self.io);
        defer self.lifecycle_mutex.unlock(self.io);
        try self.checkWritebackError();
        self.group_mutex.lockUncancelable(self.io);
        const closing = self.closing;
        self.group_mutex.unlock(self.io);
        if (closing) return error.WritebackClosed;
        if (self.flush_future != null) return error.DurabilityAlreadyConfigured;
        if (self.redo == null) {
            if (durability == .writeback) return error.WritebackRequiresRedoJournal;
            self.durability = durability;
            return;
        }
        self.durability = durability;
        if (durability == .writeback) {
            self.flush_future = self.io.concurrent(writebackLoop, .{self}) catch |err| {
                self.durability = .durable;
                return err;
            };
        }
    }

    pub fn deinit(self: *FileBlockDevice) void {
        self.finishWriteback() catch {};
        if (self.redo) |*redo| {
            redo.deinit();
            self.redo = null;
        }
        self.file_io.deinit();
    }

    pub fn beginTransaction(self: *FileBlockDevice) !void {
        try self.checkWritebackError();
        if (self.isWriteFrozen()) return error.WriteFrozen;
        const redo = &(self.redo orelse return);
        while (true) {
            try self.redo_mutex.lock(self.io);
            if (self.durability == .writeback and !self.accepting_writeback) {
                self.redo_mutex.unlock(self.io);
                return error.WritebackClosed;
            }
            const needs_checkpoint = redo.needsCheckpoint() catch |err| {
                self.redo_mutex.unlock(self.io);
                return err;
            };
            if (!needs_checkpoint) {
                defer self.redo_mutex.unlock(self.io);
                return redo.begin();
            }
            self.redo_mutex.unlock(self.io);
            if (self.durability == .writeback) try self.flushWriteback();
            try self.redo_mutex.lock(self.io);
            if (redo.hasPendingWrites()) {
                self.redo_mutex.unlock(self.io);
                continue;
            }
            redo.checkpoint(self.redoSync()) catch |err| {
                self.redo_mutex.unlock(self.io);
                self.freezeWrites();
                return err;
            };
            self.redo_mutex.unlock(self.io);
        }
    }

    pub fn commitTransaction(self: *FileBlockDevice) !void {
        try self.checkWritebackError();
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            if (self.durability == .writeback and !self.accepting_writeback) {
                self.redo_mutex.unlock(self.io);
                return error.WritebackClosed;
            }
            if (self.durability == .writeback and
                self.accepted_epoch.load(.monotonic) == std.math.maxInt(u64))
            {
                self.redo_mutex.unlock(self.io);
                self.freezeWrites();
                return error.EpochOverflow;
            }

            const staged = redo.stage() catch |err| {
                self.redo_mutex.unlock(self.io);
                self.freezeWrites();
                return err;
            };
            switch (self.durability) {
                .durable => {
                    var prepared = (redo.seal() catch |err| {
                        self.redo_mutex.unlock(self.io);
                        self.freezeWrites();
                        return err;
                    }) orelse {
                        self.redo_mutex.unlock(self.io);
                        return;
                    };
                    self.redo_mutex.unlock(self.io);
                    defer prepared.deinit();
                    prepared.execute(self.io, self.file_io.borrow(), self.redoSync()) catch |err| {
                        self.freezeWrites();
                        return err;
                    };
                    try self.redo_mutex.lock(self.io);
                    redo.completeFlush(prepared.flush) catch |err| {
                        self.redo_mutex.unlock(self.io);
                        self.freezeWrites();
                        return err;
                    };
                    self.redo_mutex.unlock(self.io);
                },
                .writeback => {
                    if (staged != null) {
                        self.accepted_epoch.store(self.accepted_epoch.load(.monotonic) + 1, .release);
                    }
                    self.redo_mutex.unlock(self.io);
                    if (staged != null) self.requestFlush();
                },
            }
        }
    }

    pub fn abortTransaction(self: *FileBlockDevice) !bool {
        if (self.redo) |*redo| {
            try self.redo_mutex.lock(self.io);
            defer self.redo_mutex.unlock(self.io);
            const had_writes = switch (self.durability) {
                .durable => redo.hasUndurableWrites(),
                .writeback => redo.hasActiveWrites(),
            };
            redo.abort();
            if (had_writes) self.freezeWrites();
            return had_writes;
        }
        return false;
    }

    pub fn checkpointRedo(self: *FileBlockDevice) !void {
        try self.checkWritebackError();
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (self.redo) |*redo| {
            while (true) {
                if (self.durability == .writeback) try self.flushWriteback();
                try self.redo_mutex.lock(self.io);
                if (redo.hasPendingWrites()) {
                    self.redo_mutex.unlock(self.io);
                    continue;
                }
                redo.checkpoint(self.redoSync()) catch |err| {
                    self.redo_mutex.unlock(self.io);
                    self.freezeWrites();
                    return err;
                };
                self.redo_mutex.unlock(self.io);
                break;
            }
        }
    }

    pub fn isJournaled(self: *const FileBlockDevice) bool {
        return self.redo != null;
    }

    pub fn fileIoKind(self: *const FileBlockDevice) FileIoKind {
        return self.file_io.kind;
    }

    pub fn finishWriteback(self: *FileBlockDevice) !void {
        try self.lifecycle_mutex.lock(self.io);
        defer self.lifecycle_mutex.unlock(self.io);
        const future = if (self.flush_future) |*value| value else {
            try self.checkWritebackError();
            return;
        };
        self.redo_mutex.lockUncancelable(self.io);
        self.accepting_writeback = false;
        self.redo_mutex.unlock(self.io);
        var first_error: ?anyerror = null;
        self.group_mutex.lockUncancelable(self.io);
        self.closing = true;
        self.force_flush = true;
        self.flush_requested = true;
        self.group_condition.broadcast(self.io);
        self.group_mutex.unlock(self.io);
        self.flushWriteback() catch |err| {
            first_error = err;
        };
        future.await(self.io) catch |err| {
            if (first_error == null) first_error = err;
        };
        self.flush_future = null;
        if (first_error) |err| return err;
    }

    fn requestFlush(self: *FileBlockDevice) void {
        self.group_mutex.lockUncancelable(self.io);
        self.flush_requested = true;
        self.group_condition.signal(self.io);
        self.group_mutex.unlock(self.io);
    }

    fn flushWriteback(self: *FileBlockDevice) !void {
        try self.checkWritebackError();
        if (self.flush_future == null) return;
        const target = self.accepted_epoch.load(.acquire);
        if (self.durable_epoch.load(.acquire) >= target) return;
        try self.group_mutex.lock(self.io);
        defer self.group_mutex.unlock(self.io);
        if (self.writeback_error) |err| return err;
        self.flush_requested = true;
        self.force_flush = true;
        self.group_condition.signal(self.io);
        while (self.durable_epoch.load(.acquire) < target) {
            if (self.writeback_error) |err| return err;
            try self.group_condition.wait(self.io, &self.group_mutex);
        }
    }

    fn writebackLoop(self: *FileBlockDevice) FlushResult {
        while (true) {
            self.group_mutex.lockUncancelable(self.io);
            while (!self.flush_requested and !self.closing and self.writeback_error == null)
                self.group_condition.waitUncancelable(self.io, &self.group_mutex);
            if (self.writeback_error) |err| {
                self.group_mutex.unlock(self.io);
                return err;
            }
            if (self.closing and
                self.durable_epoch.load(.acquire) >= self.accepted_epoch.load(.acquire))
            {
                self.group_mutex.unlock(self.io);
                return;
            }
            self.flush_requested = false;
            const immediate = self.closing or self.force_flush;
            self.force_flush = false;
            const delay_ns = switch (self.durability) {
                .durable => 0,
                .writeback => |options| options.max_delay_ns,
            };
            self.group_mutex.unlock(self.io);

            if (!immediate and delay_ns != 0)
                self.waitForBatchDelay(delay_ns) catch |err| {
                    self.recordWritebackError(err);
                    return err;
                };
            self.flushCohort() catch |err| {
                self.recordWritebackError(err);
                return err;
            };
        }
    }

    fn waitForBatchDelay(self: *FileBlockDevice, delay_ns: u64) !void {
        self.group_mutex.lockUncancelable(self.io);
        if (self.force_flush or self.closing) {
            self.force_flush = false;
            self.group_mutex.unlock(self.io);
            return;
        }
        self.delay_elapsed = false;
        self.group_mutex.unlock(self.io);

        var timer = try self.io.concurrent(batchDelay, .{ self, delay_ns });
        self.group_mutex.lockUncancelable(self.io);
        while (!self.delay_elapsed and !self.force_flush and !self.closing)
            self.group_condition.waitUncancelable(self.io, &self.group_mutex);
        const cancel_timer = !self.delay_elapsed;
        self.force_flush = false;
        self.group_mutex.unlock(self.io);

        if (cancel_timer)
            timer.cancel(self.io) catch {}
        else
            try timer.await(self.io);
    }

    fn batchDelay(self: *FileBlockDevice, delay_ns: u64) Io.Cancelable!void {
        try self.io.sleep(.fromNanoseconds(delay_ns), .awake);
        self.group_mutex.lockUncancelable(self.io);
        self.delay_elapsed = true;
        self.group_condition.broadcast(self.io);
        self.group_mutex.unlock(self.io);
    }

    fn flushCohort(self: *FileBlockDevice) !void {
        try self.redo_mutex.lock(self.io);
        const redo = &(self.redo orelse {
            self.redo_mutex.unlock(self.io);
            return error.MissingRedoJournal;
        });
        var prepared = (redo.seal() catch |err| {
            self.redo_mutex.unlock(self.io);
            return err;
        }) orelse {
            self.redo_mutex.unlock(self.io);
            return;
        };
        defer prepared.deinit();
        const target_epoch = self.accepted_epoch.load(.acquire);
        self.redo_mutex.unlock(self.io);

        try prepared.execute(self.io, self.file_io.borrow(), self.redoSync());
        try self.redo_mutex.lock(self.io);
        redo.completeFlush(prepared.flush) catch |err| {
            self.redo_mutex.unlock(self.io);
            self.freezeWrites();
            return err;
        };
        const more_pending = redo.hasPendingWrites();
        self.redo_mutex.unlock(self.io);
        self.durable_epoch.store(target_epoch, .release);
        self.group_mutex.lockUncancelable(self.io);
        self.group_condition.broadcast(self.io);
        self.group_mutex.unlock(self.io);
        if (more_pending) self.requestFlush();
    }

    fn recordWritebackError(self: *FileBlockDevice, err: anyerror) void {
        self.freezeWrites();
        self.group_mutex.lockUncancelable(self.io);
        if (self.writeback_error == null) self.writeback_error = err;
        self.group_condition.broadcast(self.io);
        self.group_mutex.unlock(self.io);
    }

    fn checkWritebackError(self: *FileBlockDevice) !void {
        self.group_mutex.lockUncancelable(self.io);
        defer self.group_mutex.unlock(self.io);
        if (self.writeback_error) |err| return err;
    }

    fn durableSync(self: *FileBlockDevice) !void {
        const action = if (self.fault) |fault| fault.action(.sync) else .none;
        if (action == .before) {
            self.freezeWrites();
            return error.InjectedFault;
        }
        self.file_io.dataSync(self.io, if (self.redo == null) .foreground else .writeback) catch |err| {
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
    mutex: std.atomic.Mutex = .unlocked,
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
        self.lock();
        defer self.mutex.unlock();
        self.fail_read_at = null;
        self.fail_program_at = null;
        self.fail_program_partial_at = null;
        self.fail_program_after_at = null;
        self.fail_sync_at = null;
        self.fail_sync_after_at = null;
    }

    pub fn syncCalls(self: *FaultController) u64 {
        self.lock();
        defer self.mutex.unlock();
        return self.sync_count;
    }

    fn action(self: *FaultController, operation: enum { read, program, sync }) FaultAction {
        self.lock();
        defer self.mutex.unlock();
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

    fn lock(self: *FaultController) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
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
    try std.testing.expectEqual(@as(u64, 0), fault.syncCalls());
    try device.commitTransaction();
    try std.testing.expectEqual(@as(u64, 1), fault.syncCalls());

    var actual: [11]u8 = undefined;
    try device.read(4, 32, &actual);
    try std.testing.expectEqualStrings("transaction", &actual);
    try device.checkpointRedo();
    try std.testing.expectEqual(@as(u64, 3), fault.syncCalls());
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
    try std.testing.expectEqual(@as(u64, 1), fault.syncCalls());
    try device.sync();
    try std.testing.expectEqual(@as(u64, 3), fault.syncCalls());

    var home: [11]u8 = undefined;
    _ = try file.readPositionalAll(
        std.testing.io,
        &home,
        header.payload_start + 4 * header.block_size + 32,
    );
    try std.testing.expectEqualStrings("transaction", &home);
}

test "writeback groups staged transactions into one sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "writeback.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "Writeback");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var device = FileBlockDevice.init(std.testing.io, file, header);
    defer device.deinit();
    try device.enableRedo(std.testing.allocator, header);
    try device.setDurability(.{ .writeback = .{ .max_delay_ns = std.time.ns_per_min } });
    var fault: FaultController = .{};
    device.fault = &fault;

    try device.beginTransaction();
    try device.program(1, 0, "first");
    try device.commitTransaction();
    try device.beginTransaction();
    try device.program(2, 0, "second");
    try device.commitTransaction();
    try std.testing.expectEqual(@as(u64, 0), fault.syncCalls());

    var visible: [6]u8 = undefined;
    try device.read(2, 0, &visible);
    try std.testing.expectEqualStrings("second", &visible);
    try device.sync();
    try std.testing.expectEqual(@as(u64, 1), fault.syncCalls());
}

test "writeback flushes a pending cohort while a transaction is active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "writeback-active.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "WritebackActive");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var device = FileBlockDevice.init(std.testing.io, file, header);
    defer device.deinit();
    try device.enableRedo(std.testing.allocator, header);
    try device.setDurability(.{ .writeback = .{} });
    var fault: FaultController = .{};
    device.fault = &fault;

    device.redo_mutex.lockUncancelable(std.testing.io);
    var redo_locked = true;
    defer if (redo_locked) device.redo_mutex.unlock(std.testing.io);
    const redo = &device.redo.?;
    try redo.begin();
    try redo.program(1, 0, "first");
    _ = try redo.stage();
    device.accepted_epoch.store(1, .release);
    try redo.begin();
    try redo.program(2, 0, "second");
    device.redo_mutex.unlock(std.testing.io);
    redo_locked = false;

    try device.flushWriteback();
    try std.testing.expectEqual(@as(u64, 1), fault.syncCalls());
    try device.commitTransaction();
    try device.sync();
    try std.testing.expectEqual(@as(u64, 2), fault.syncCalls());
}

test "finishing writeback drains writes and closes acceptance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "writeback-finish.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "WritebackFinish");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var device = FileBlockDevice.init(std.testing.io, file, header);
    defer device.deinit();
    try device.enableRedo(std.testing.allocator, header);
    try device.setDurability(.{ .writeback = .{} });
    var fault: FaultController = .{};
    device.fault = &fault;

    try device.beginTransaction();
    try device.program(1, 0, "transaction");
    try device.commitTransaction();
    try device.finishWriteback();
    try std.testing.expectEqual(@as(u64, 1), fault.syncCalls());
    try std.testing.expectError(error.WritebackClosed, device.beginTransaction());
    try std.testing.expectError(error.WritebackClosed, device.setDurability(.{ .writeback = .{} }));
}

test "aborting an empty transaction preserves an older writeback cohort" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "writeback-abort.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "WritebackAbort");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var device = FileBlockDevice.init(std.testing.io, file, header);
    defer device.deinit();
    try device.enableRedo(std.testing.allocator, header);
    try device.setDurability(.{ .writeback = .{ .max_delay_ns = std.time.ns_per_min } });

    try device.beginTransaction();
    try device.program(1, 0, "transaction");
    try device.commitTransaction();
    try device.beginTransaction();
    try std.testing.expect(!try device.abortTransaction());
    try std.testing.expect(!device.isWriteFrozen());
    try device.sync();
}

test "writeback preserves an asynchronous sync error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "writeback-error.ddv", .{ .read = true });
    defer file.close(std.testing.io);

    var header = try container.Header.init(std.testing.io, 1024 * 1024, "WritebackError");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var device = FileBlockDevice.init(std.testing.io, file, header);
    defer device.deinit();
    try device.enableRedo(std.testing.allocator, header);
    try device.setDurability(.{ .writeback = .{} });
    var fault: FaultController = .{ .fail_sync_at = 0 };
    device.fault = &fault;

    try device.beginTransaction();
    try device.program(1, 0, "transaction");
    try device.commitTransaction();
    try std.testing.expectError(error.InjectedFault, device.sync());
    try std.testing.expectError(error.InjectedFault, device.beginTransaction());
    try std.testing.expectError(error.InjectedFault, device.finishWriteback());
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
