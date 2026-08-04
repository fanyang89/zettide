const std = @import("std");

const Io = std.Io;
const File = Io.File;

pub const Kind = enum {
    regular_file,
    linux_block_device,
    spdk_bdev,
};

pub const Read = struct {
    buffer: []u8,
    offset: u64,
};

pub const ReadResult = struct {
    amount: usize = 0,
    failure: ?anyerror = null,
};

pub const Write = struct {
    bytes: []const u8,
    offset: u64,
};

/// Owned durable random-access storage used by a v3 member.
pub const Storage = struct {
    backend: Backend,
    capacity_bytes: u64,
    kind: Kind,
    minimum_io_size: u32,

    pub const VTable = struct {
        same_identity: *const fn (context: *anyopaque, other_context: *anyopaque) bool,
        read_at: *const fn (context: *anyopaque, io: Io, buffer: []u8, offset: u64) anyerror!usize,
        read_many_at: ?*const fn (context: *anyopaque, io: Io, reads: []const Read, results: []ReadResult) anyerror!void = null,
        write_all_at: *const fn (context: *anyopaque, io: Io, bytes: []const u8, offset: u64) anyerror!void,
        write_all_many_at: ?*const fn (context: *anyopaque, io: Io, writes: []const Write) anyerror!void = null,
        sync_data: ?*const fn (context: *anyopaque, io: Io) anyerror!void = null,
        sync: *const fn (context: *anyopaque, io: Io) anyerror!void,
        close: *const fn (context: *anyopaque, io: Io) anyerror!void,
    };

    const FileBackend = struct {
        file: File,
        unlock_on_close: bool,
    };

    const CustomBackend = struct {
        context: *anyopaque,
        vtable: *const VTable,
    };

    const Backend = union(enum) {
        file: FileBackend,
        custom: CustomBackend,
    };

    pub fn createFile(
        io: Io,
        parent: Io.Dir,
        basename: []const u8,
        capacity_bytes: u64,
    ) !Storage {
        const file = try parent.createFile(io, basename, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        errdefer {
            file.unlock(io);
            file.close(io);
        }
        try file.setLength(io, capacity_bytes);
        return .{
            .backend = .{ .file = .{ .file = file, .unlock_on_close = true } },
            .capacity_bytes = capacity_bytes,
            .kind = .regular_file,
            .minimum_io_size = 1,
        };
    }

    pub fn openFile(
        io: Io,
        parent: Io.Dir,
        basename: []const u8,
        writable: bool,
    ) !Storage {
        const file = try parent.openFile(io, basename, .{
            .mode = if (writable) .read_write else .read_only,
            .lock = if (writable) .exclusive else .shared,
            .lock_nonblocking = true,
        });
        errdefer {
            file.unlock(io);
            file.close(io);
        }
        return .{
            .backend = .{ .file = .{ .file = file, .unlock_on_close = true } },
            .capacity_bytes = try file.length(io),
            .kind = .regular_file,
            .minimum_io_size = 1,
        };
    }

    pub fn initOwned(
        file: File,
        capacity_bytes: u64,
        kind: Kind,
        minimum_io_size: u32,
        unlock_on_close: bool,
    ) Storage {
        return .{
            .backend = .{ .file = .{ .file = file, .unlock_on_close = unlock_on_close } },
            .capacity_bytes = capacity_bytes,
            .kind = kind,
            .minimum_io_size = minimum_io_size,
        };
    }

    pub fn initBackend(
        context: *anyopaque,
        vtable: *const VTable,
        capacity_bytes: u64,
        kind: Kind,
        minimum_io_size: u32,
    ) Storage {
        return .{
            .backend = .{ .custom = .{ .context = context, .vtable = vtable } },
            .capacity_bytes = capacity_bytes,
            .kind = kind,
            .minimum_io_size = minimum_io_size,
        };
    }

    pub fn capacity(self: *const Storage) u64 {
        return self.capacity_bytes;
    }

    pub fn sameIdentity(self: *const Storage, other: *const Storage) bool {
        return switch (self.backend) {
            .file => |self_file| switch (other.backend) {
                .file => |other_file| self_file.file.handle == other_file.file.handle,
                .custom => false,
            },
            .custom => |self_custom| switch (other.backend) {
                .file => false,
                .custom => |other_custom| self_custom.vtable == other_custom.vtable and
                    self_custom.vtable.same_identity(self_custom.context, other_custom.context),
            },
        };
    }

    fn sameOwner(self: *const Storage, other: *const Storage) bool {
        return switch (self.backend) {
            .file => |self_file| switch (other.backend) {
                .file => |other_file| self_file.file.handle == other_file.file.handle,
                .custom => false,
            },
            .custom => |self_custom| switch (other.backend) {
                .file => false,
                .custom => |other_custom| self_custom.context == other_custom.context,
            },
        };
    }

    pub fn readAt(self: *Storage, io: Io, buffer: []u8, offset: u64) !usize {
        return switch (self.backend) {
            .file => |backend| backend.file.readPositionalAll(io, buffer, offset),
            .custom => |backend| backend.vtable.read_at(backend.context, io, buffer, offset),
        };
    }

    pub fn readManyAt(self: *Storage, io: Io, reads: []const Read, results: []ReadResult) !void {
        if (reads.len != results.len) return error.InvalidReadBatch;
        for (results) |*result| result.* = .{};
        if (self.backend == .custom) {
            const backend = self.backend.custom;
            if (backend.vtable.read_many_at) |read_many|
                return read_many(backend.context, io, reads, results);
        }
        for (reads, results) |read, *result| {
            result.amount = self.readAt(io, read.buffer, read.offset) catch |err| {
                result.failure = err;
                continue;
            };
        }
    }

    pub fn writeAllAt(self: *Storage, io: Io, bytes: []const u8, offset: u64) !void {
        switch (self.backend) {
            .file => |backend| try backend.file.writePositionalAll(io, bytes, offset),
            .custom => |backend| try backend.vtable.write_all_at(backend.context, io, bytes, offset),
        }
    }

    /// Writes must not overlap; execution order is backend-dependent.
    pub fn writeAllManyAt(self: *Storage, io: Io, writes: []const Write) !void {
        if (self.backend == .custom) {
            const backend = self.backend.custom;
            if (backend.vtable.write_all_many_at) |write_many|
                return write_many(backend.context, io, writes);
        }
        for (writes) |write| try self.writeAllAt(io, write.bytes, write.offset);
    }

    pub fn syncData(self: *Storage, io: Io) !void {
        switch (self.backend) {
            .file => |backend| if (@import("builtin").os.tag == .linux)
                try std.posix.fdatasync(backend.file.handle)
            else
                try backend.file.sync(io),
            .custom => |backend| if (backend.vtable.sync_data) |sync_data|
                try sync_data(backend.context, io)
            else
                try backend.vtable.sync(backend.context, io),
        }
    }

    pub fn sync(self: *Storage, io: Io) !void {
        switch (self.backend) {
            .file => |backend| try backend.file.sync(io),
            .custom => |backend| try backend.vtable.sync(backend.context, io),
        }
    }

    /// The owner must ensure no operation is active or waiting before close.
    pub fn close(self: *Storage, io: Io) !void {
        switch (self.backend) {
            .file => |backend| {
                if (backend.unlock_on_close) backend.file.unlock(io);
                backend.file.close(io);
            },
            .custom => |backend| try backend.vtable.close(backend.context, io),
        }
    }
};

/// Closes each owned backend once even if the slice contains copied Storage values.
pub fn closeAll(storages: []Storage, io: Io) !void {
    var first_error: ?anyerror = null;
    for (storages, 0..) |*storage, index| {
        var copied_later = false;
        for (storages[index + 1 ..]) |*later| {
            if (storage.sameOwner(later)) {
                copied_later = true;
                break;
            }
        }
        if (!copied_later) storage.close(io) catch |err| if (first_error == null) {
            first_error = err;
        };
    }
    if (first_error) |err| return err;
}

test "file storage reports capacity and supports positional IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var storage = try Storage.createFile(std.testing.io, tmp.dir, "storage", 4096);
    defer storage.close(std.testing.io) catch {};

    try std.testing.expectEqual(Kind.regular_file, storage.kind);
    try std.testing.expectEqual(@as(u64, 4096), storage.capacity());
    const writes = [_]Write{
        .{ .bytes = "da", .offset = 2048 },
        .{ .bytes = "ta", .offset = 2050 },
    };
    try storage.writeAllManyAt(std.testing.io, &writes);
    try storage.syncData(std.testing.io);

    var actual: [4]u8 = undefined;
    try std.testing.expectEqual(actual.len, try storage.readAt(std.testing.io, &actual, 2048));
    try std.testing.expectEqualStrings("data", &actual);
    var first: [2]u8 = undefined;
    var second: [2]u8 = undefined;
    const reads = [_]Read{
        .{ .buffer = &first, .offset = 2048 },
        .{ .buffer = &second, .offset = 2050 },
    };
    var results: [reads.len]ReadResult = undefined;
    try storage.readManyAt(std.testing.io, &reads, &results);
    try std.testing.expectEqual(@as(usize, 2), results[0].amount);
    try std.testing.expectEqual(@as(usize, 2), results[1].amount);
    try std.testing.expectEqualStrings("da", &first);
    try std.testing.expectEqualStrings("ta", &second);
}

test "custom storage delegates operations and preserves identity" {
    const MemoryBackend = struct {
        bytes: [4096]u8 = @splat(0),
        synced: bool = false,
        closed: bool = false,

        fn readAt(context: *anyopaque, _: Io, buffer: []u8, offset: u64) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            const start = std.math.cast(usize, offset) orelse return error.OutOfBounds;
            if (start > self.bytes.len or buffer.len > self.bytes.len - start) return error.OutOfBounds;
            @memcpy(buffer, self.bytes[start..][0..buffer.len]);
            return buffer.len;
        }

        fn sameIdentity(context: *anyopaque, other_context: *anyopaque) bool {
            return context == other_context;
        }

        fn writeAllAt(context: *anyopaque, _: Io, bytes: []const u8, offset: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const start = std.math.cast(usize, offset) orelse return error.OutOfBounds;
            if (start > self.bytes.len or bytes.len > self.bytes.len - start) return error.OutOfBounds;
            @memcpy(self.bytes[start..][0..bytes.len], bytes);
        }

        fn sync(context: *anyopaque, _: Io) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.synced = true;
        }

        fn close(context: *anyopaque, _: Io) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed = true;
        }

        const vtable: Storage.VTable = .{
            .same_identity = sameIdentity,
            .read_at = readAt,
            .write_all_at = writeAllAt,
            .sync = sync,
            .close = close,
        };
    };

    var backend: MemoryBackend = .{};
    var other_backend: MemoryBackend = .{};
    var storage = Storage.initBackend(&backend, &MemoryBackend.vtable, backend.bytes.len, .spdk_bdev, 4096);
    const alias = Storage.initBackend(&backend, &MemoryBackend.vtable, backend.bytes.len, .spdk_bdev, 4096);
    const other = Storage.initBackend(&other_backend, &MemoryBackend.vtable, other_backend.bytes.len, .spdk_bdev, 4096);

    try std.testing.expect(storage.sameIdentity(&alias));
    try std.testing.expect(!storage.sameIdentity(&other));
    try storage.writeAllAt(std.testing.io, "data", 2048);
    var actual: [4]u8 = undefined;
    try std.testing.expectEqual(actual.len, try storage.readAt(std.testing.io, &actual, 2048));
    try std.testing.expectEqualStrings("data", &actual);
    try storage.sync(std.testing.io);
    var copies = [_]Storage{ storage, alias };
    try closeAll(&copies, std.testing.io);
    try std.testing.expect(backend.synced);
    try std.testing.expect(backend.closed);
}
