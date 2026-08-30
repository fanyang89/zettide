const std = @import("std");

const generation_size = 32;
const checksum_size = 4;
const encoded_size = generation_size + checksum_size;

/// Loads or creates the durable physical-object generation mixed into the file
/// Member backend digest. It prevents inode/path reuse from aliasing a different
/// backing object across daemon restarts.
pub fn loadOrCreate(io: std.Io, parent: std.Io.Dir, basename: []const u8) ![generation_size]u8 {
    const bytes = parent.readFileAlloc(io, basename, std.heap.page_allocator, .limited(encoded_size + 1)) catch |err| switch (err) {
        error.FileNotFound => return create(io, parent, basename),
        error.StreamTooLong => return error.StoreCorrupt,
        else => return err,
    };
    defer std.heap.page_allocator.free(bytes);
    if (bytes.len != encoded_size or
        std.mem.readInt(u32, bytes[generation_size..encoded_size], .little) !=
            std.hash.crc.Crc32Iscsi.hash(bytes[0..generation_size]))
        return error.StoreCorrupt;
    const generation = bytes[0..generation_size].*;
    if (isZero(&generation)) return error.StoreCorrupt;
    return generation;
}

fn create(io: std.Io, parent: std.Io.Dir, basename: []const u8) ![generation_size]u8 {
    var generation: [generation_size]u8 = undefined;
    while (true) {
        try io.randomSecure(&generation);
        if (!isZero(&generation)) break;
    }
    var bytes: [encoded_size]u8 = undefined;
    @memcpy(bytes[0..generation_size], &generation);
    std.mem.writeInt(
        u32,
        bytes[generation_size..encoded_size],
        std.hash.crc.Crc32Iscsi.hash(&generation),
        .little,
    );
    var atomic_file = try parent.createFileAtomic(io, basename, .{ .replace = false });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, &bytes);
    try atomic_file.file.sync(io);
    try atomic_file.link(io);
    const parent_file = try parent.openFile(io, ".", .{ .mode = .read_only });
    defer parent_file.close(io);
    try parent_file.sync(io);
    return generation;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

test "member generation is durable and corruption fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try loadOrCreate(std.testing.io, tmp.dir, "member-generation.state");
    const second = try loadOrCreate(std.testing.io, tmp.dir, "member-generation.state");
    try std.testing.expectEqual(first, second);
    const file = try tmp.dir.openFile(std.testing.io, "member-generation.state", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "X", 0);
    try std.testing.expectError(
        error.StoreCorrupt,
        loadOrCreate(std.testing.io, tmp.dir, "member-generation.state"),
    );
}
