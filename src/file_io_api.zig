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
        data_sync: *const fn (?*anyopaque, File, Io, Lane) anyerror!void,
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

    pub fn dataSync(self: FileIo, io: Io, lane: Lane) !void {
        try self.borrow().dataSync(io, lane);
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

    pub fn dataSync(self: BorrowedFileIo, io: Io, lane: Lane) !void {
        try self.vtable.data_sync(self.context, self.file, io, lane);
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

fn posixDataSync(_: ?*anyopaque, file: File, io: Io, _: Lane) !void {
    if (@import("builtin").os.tag == .linux)
        try std.posix.fdatasync(file.handle)
    else
        try file.sync(io);
}

fn posixDeinit(_: ?*anyopaque) void {}

const posix_vtable: FileIo.VTable = .{
    .read_all_at = posixReadAllAt,
    .write_all_at = posixWriteAllAt,
    .write_all_many_at = posixWriteAllManyAt,
    .data_sync = posixDataSync,
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
    try backend.dataSync(std.testing.io, .foreground);
    var actual: [7]u8 = undefined;
    try backend.readAllAt(std.testing.io, .foreground, &actual, 1024);
    try std.testing.expectEqualStrings("payload", &actual);
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        backend.readAllAt(std.testing.io, .foreground, &actual, 4095),
    );
}
