const std = @import("std");

const Io = std.Io;
const File = Io.File;

pub const Kind = enum {
    regular_file,
    linux_block_device,
};

/// Owned durable random-access storage used by a v3 member.
pub const Storage = struct {
    file: File,
    capacity_bytes: u64,
    kind: Kind,

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
            .file = file,
            .capacity_bytes = capacity_bytes,
            .kind = .regular_file,
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
            .file = file,
            .capacity_bytes = try file.length(io),
            .kind = .regular_file,
        };
    }

    pub fn initOwned(file: File, capacity_bytes: u64, kind: Kind) Storage {
        return .{
            .file = file,
            .capacity_bytes = capacity_bytes,
            .kind = kind,
        };
    }

    pub fn capacity(self: *const Storage) u64 {
        return self.capacity_bytes;
    }

    pub fn readAt(self: *Storage, io: Io, buffer: []u8, offset: u64) !usize {
        return self.file.readPositionalAll(io, buffer, offset);
    }

    pub fn writeAllAt(self: *Storage, io: Io, bytes: []const u8, offset: u64) !void {
        try self.file.writePositionalAll(io, bytes, offset);
    }

    pub fn sync(self: *Storage, io: Io) !void {
        try self.file.sync(io);
    }

    pub fn close(self: *Storage, io: Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};

test "file storage reports capacity and supports positional IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var storage = try Storage.createFile(std.testing.io, tmp.dir, "storage", 4096);
    defer storage.close(std.testing.io);

    try std.testing.expectEqual(Kind.regular_file, storage.kind);
    try std.testing.expectEqual(@as(u64, 4096), storage.capacity());
    try storage.writeAllAt(std.testing.io, "data", 2048);
    try storage.sync(std.testing.io);

    var actual: [4]u8 = undefined;
    try std.testing.expectEqual(actual.len, try storage.readAt(std.testing.io, &actual, 2048));
    try std.testing.expectEqualStrings("data", &actual);
}
