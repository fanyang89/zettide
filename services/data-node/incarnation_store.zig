const std = @import("std");

const magic = "ZETINC01".*;
const version: u16 = 1;
const encoded_size: usize = 32;

/// Advances a durable monotonic heartbeat incarnation before the caller may
/// publish observations for a new process lifetime.
pub fn next(io: std.Io, parent: std.Io.Dir, basename: []const u8) !u64 {
    const current = read(io, parent, basename) catch |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    const value = std.math.add(u64, current, 1) catch return error.IncarnationExhausted;
    var bytes: [encoded_size]u8 = @splat(0);
    @memcpy(bytes[0..8], &magic);
    std.mem.writeInt(u16, bytes[8..10], version, .little);
    std.mem.writeInt(u64, bytes[16..24], value, .little);
    std.mem.writeInt(u32, bytes[24..28], std.hash.crc.Crc32Iscsi.hash(bytes[0..24]), .little);

    var atomic_file = try parent.createFileAtomic(io, basename, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, &bytes);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
    const parent_file = try parent.openFile(io, ".", .{ .mode = .read_only });
    defer parent_file.close(io);
    try parent_file.sync(io);
    return value;
}

fn read(io: std.Io, parent: std.Io.Dir, basename: []const u8) !u64 {
    const bytes = try parent.readFileAlloc(io, basename, std.heap.page_allocator, .limited(encoded_size + 1));
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len != encoded_size or !std.mem.eql(u8, bytes[0..8], &magic) or
        std.mem.readInt(u16, bytes[8..10], .little) != version or
        !allZero(bytes[10..16]) or !allZero(bytes[28..32]) or
        std.mem.readInt(u32, bytes[24..28], .little) != std.hash.crc.Crc32Iscsi.hash(bytes[0..24]))
        return error.IncarnationStoreCorrupt;
    const value = std.mem.readInt(u64, bytes[16..24], .little);
    if (value == 0) return error.IncarnationStoreCorrupt;
    return value;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

test "heartbeat incarnation advances durably" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(u64, 1), try next(std.testing.io, tmp.dir, "incarnation.state"));
    try std.testing.expectEqual(@as(u64, 2), try next(std.testing.io, tmp.dir, "incarnation.state"));
}

test "heartbeat incarnation rejects corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try next(std.testing.io, tmp.dir, "incarnation.state");
    const file = try tmp.dir.openFile(std.testing.io, "incarnation.state", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "X", 0);
    try std.testing.expectError(
        error.IncarnationStoreCorrupt,
        next(std.testing.io, tmp.dir, "incarnation.state"),
    );
}
