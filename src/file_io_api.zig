const std = @import("std");

const Io = std.Io;
const File = Io.File;

pub const Kind = enum {
    posix,
    io_uring,
};

pub const Lane = enum {
    foreground,
    writeback,
};

pub const SyncMode = enum {
    data,
    full,
};

pub const LaneStats = struct {
    submitted_sqes: u64 = 0,
    submit_calls: u64 = 0,
    completions: u64 = 0,
    max_inflight: u64 = 0,
};

pub const Stats = struct {
    foreground: LaneStats = .{},
    writeback: LaneStats = .{},
};

pub const Write = struct {
    bytes: []const u8,
    offset: u64,
};

pub const FileIo = struct {
    file: File,
    context: ?*anyopaque = null,
    vtable: *const VTable = &posix_vtable,
    kind: Kind = .posix,

    pub const VTable = struct {
        read_all_at: *const fn (?*anyopaque, File, Io, Lane, []u8, u64) anyerror!void,
        write_all_at: *const fn (?*anyopaque, File, Io, Lane, []const u8, u64) anyerror!void,
        write_all_many_at: *const fn (?*anyopaque, File, Io, Lane, []const Write) anyerror!void,
        sync: *const fn (?*anyopaque, File, Io, Lane, SyncMode) anyerror!void,
        stats: *const fn (?*anyopaque, Io) Stats,
        reset_stats: *const fn (?*anyopaque, Io) void,
        deinit: *const fn (?*anyopaque) void,
    };

    pub fn posix(file: File) FileIo {
        return .{ .file = file };
    }

    pub fn readAllAt(self: FileIo, io: Io, lane: Lane, buffer: []u8, offset: u64) !void {
        try self.borrow().readAllAt(io, lane, buffer, offset);
    }

    pub fn writeAllAt(self: FileIo, io: Io, lane: Lane, bytes: []const u8, offset: u64) !void {
        try self.borrow().writeAllAt(io, lane, bytes, offset);
    }

    pub fn writeAllManyAt(self: FileIo, io: Io, lane: Lane, writes: []const Write) !void {
        try self.borrow().writeAllManyAt(io, lane, writes);
    }

    pub fn sync(self: FileIo, io: Io, lane: Lane, mode: SyncMode) !void {
        try self.borrow().sync(io, lane, mode);
    }

    pub fn stats(self: FileIo, io: Io) Stats {
        return self.vtable.stats(self.context, io);
    }

    pub fn resetStats(self: FileIo, io: Io) void {
        self.vtable.reset_stats(self.context, io);
    }

    pub fn borrow(self: FileIo) BorrowedFileIo {
        return .{
            .file = self.file,
            .context = self.context,
            .vtable = self.vtable,
            .kind = self.kind,
        };
    }

    pub fn deinit(self: *FileIo) void {
        self.vtable.deinit(self.context);
        self.* = undefined;
    }
};

pub const BorrowedFileIo = struct {
    file: File,
    context: ?*anyopaque,
    vtable: *const FileIo.VTable,
    kind: Kind,

    pub fn readAllAt(self: BorrowedFileIo, io: Io, lane: Lane, buffer: []u8, offset: u64) !void {
        try self.vtable.read_all_at(self.context, self.file, io, lane, buffer, offset);
    }

    pub fn writeAllAt(self: BorrowedFileIo, io: Io, lane: Lane, bytes: []const u8, offset: u64) !void {
        try self.vtable.write_all_at(self.context, self.file, io, lane, bytes, offset);
    }

    /// Writes must not overlap; execution order is backend-dependent.
    pub fn writeAllManyAt(self: BorrowedFileIo, io: Io, lane: Lane, writes: []const Write) !void {
        try self.vtable.write_all_many_at(self.context, self.file, io, lane, writes);
    }

    pub fn sync(self: BorrowedFileIo, io: Io, lane: Lane, mode: SyncMode) !void {
        try self.vtable.sync(self.context, self.file, io, lane, mode);
    }

    pub fn stats(self: BorrowedFileIo, io: Io) Stats {
        return self.vtable.stats(self.context, io);
    }

    pub fn resetStats(self: BorrowedFileIo, io: Io) void {
        self.vtable.reset_stats(self.context, io);
    }
};

fn posixReadAllAt(_: ?*anyopaque, file: File, io: Io, _: Lane, buffer: []u8, offset: u64) !void {
    const amount = try file.readPositionalAll(io, buffer, offset);
    if (amount != buffer.len) return error.UnexpectedEndOfFile;
}

fn posixWriteAllAt(_: ?*anyopaque, file: File, io: Io, _: Lane, bytes: []const u8, offset: u64) !void {
    try file.writePositionalAll(io, bytes, offset);
}

fn posixWriteAllManyAt(_: ?*anyopaque, file: File, io: Io, _: Lane, writes: []const Write) !void {
    for (writes) |write| try file.writePositionalAll(io, write.bytes, write.offset);
}

fn posixSync(_: ?*anyopaque, file: File, io: Io, _: Lane, mode: SyncMode) !void {
    if (mode == .data and @import("builtin").os.tag == .linux)
        try std.posix.fdatasync(file.handle)
    else
        try file.sync(io);
}

fn posixDeinit(_: ?*anyopaque) void {}
fn posixStats(_: ?*anyopaque, _: Io) Stats {
    return .{};
}
fn posixResetStats(_: ?*anyopaque, _: Io) void {}

const posix_vtable: FileIo.VTable = .{
    .read_all_at = posixReadAllAt,
    .write_all_at = posixWriteAllAt,
    .write_all_many_at = posixWriteAllManyAt,
    .sync = posixSync,
    .stats = posixStats,
    .reset_stats = posixResetStats,
    .deinit = posixDeinit,
};

test "POSIX file IO reads writes and syncs borrowed files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "file-io", .{ .read = true });
    defer file.close(std.testing.io);
    try file.setLength(std.testing.io, 4096);

    var backend = FileIo.posix(file);
    defer backend.deinit();
    try backend.writeAllAt(std.testing.io, .foreground, "payload", 1024);
    try backend.sync(std.testing.io, .foreground, .data);
    var actual: [7]u8 = undefined;
    try backend.readAllAt(std.testing.io, .foreground, &actual, 1024);
    try std.testing.expectEqualStrings("payload", &actual);
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        backend.readAllAt(std.testing.io, .foreground, &actual, 4095),
    );
}
