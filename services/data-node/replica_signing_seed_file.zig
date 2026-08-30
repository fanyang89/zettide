const std = @import("std");
const linux = std.os.linux;
const max_file_size: usize = 65;

pub const SigningSeed = struct {
    seed: [32]u8,

    pub fn deinit(self: *SigningSeed) void {
        std.crypto.secureZero(u8, &self.seed);
        self.* = undefined;
    }
};

/// Loads one canonical 32-byte Ed25519 seed encoded as 64 lowercase hex
/// characters, optionally followed by exactly one LF. The file must be a
/// non-symlink regular file owned by the effective user with no group/world
/// permission bits. Owner read/write/execute bits are intentionally unrestricted.
pub fn load(io: std.Io, parent: std.Io.Dir, basename: []const u8) !SigningSeed {
    const file = try parent.openFile(io, basename, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .lock = .shared,
    });
    defer file.close(io);
    var metadata: linux.Statx = undefined;
    const metadata_result = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &metadata);
    if (linux.errno(metadata_result) != .SUCCESS) return error.SigningSeedMetadataUnavailable;
    if (!linux.S.ISREG(metadata.mode) or metadata.uid != std.c.geteuid())
        return error.SigningSeedOwnerMismatch;
    if (metadata.mode & 0o077 != 0) return error.InsecureSigningSeedFile;
    if (metadata.size != 64 and metadata.size != 65) return error.InvalidSigningSeedFile;

    var bytes: [max_file_size]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &bytes);
    const length: usize = @intCast(metadata.size);
    if (try file.readPositionalAll(io, bytes[0..length], 0) != length)
        return error.InvalidSigningSeedFile;
    if (length == 65 and bytes[64] != '\n') return error.InvalidSigningSeedFile;

    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    for (&seed, 0..) |*byte, index| {
        byte.* = (try hexNibble(bytes[index * 2])) << 4 |
            try hexNibble(bytes[index * 2 + 1]);
    }
    var nonzero = false;
    for (seed) |byte| nonzero = nonzero or byte != 0;
    if (!nonzero) return error.InvalidSigningSeedFile;
    return .{ .seed = seed };
}

fn hexNibble(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        else => error.InvalidSigningSeedFile,
    };
}

const valid_seed = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";

fn writeSecure(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = data,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
}

test "loads and scrubs canonical signing seed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSecure(tmp.dir, "seed", valid_seed ++ "\n");
    var loaded = try load(std.testing.io, tmp.dir, "seed");
    try std.testing.expectEqual(@as(u8, 1), loaded.seed[0]);
    try std.testing.expectEqual(@as(u8, 0x20), loaded.seed[31]);
    loaded.deinit();
}

test "rejects malformed zero duplicate trailing and oversized signing seeds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "empty", .data = "" },
        .{ .name = "short", .data = "01" },
        .{ .name = "upper", .data = "0102030405060708090A0b0c0d0e0f101112131415161718191a1b1c1d1e1f20" },
        .{ .name = "zero", .data = "0000000000000000000000000000000000000000000000000000000000000000" },
        .{ .name = "duplicate", .data = valid_seed ++ "\n" ++ valid_seed },
        .{ .name = "trailing", .data = valid_seed ++ " " },
        .{ .name = "oversized", .data = valid_seed ++ "\n0" },
    };
    for (cases) |case| {
        try writeSecure(tmp.dir, case.name, case.data);
        try std.testing.expectError(error.InvalidSigningSeedFile, load(std.testing.io, tmp.dir, case.name));
    }
}

test "accepts owner-only signing seed permission variants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]u16{ 0o400, 0o600, 0o700 }, 0..) |mode, index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "seed-{d}", .{index});
        try writeSecure(tmp.dir, name, valid_seed);
        const file = try tmp.dir.openFile(std.testing.io, name, .{});
        try file.setPermissions(std.testing.io, @enumFromInt(mode));
        file.close(std.testing.io);
        var loaded = try load(std.testing.io, tmp.dir, name);
        loaded.deinit();
    }
}

test "rejects group accessible signing seed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSecure(tmp.dir, "seed", valid_seed);
    const file = try tmp.dir.openFile(std.testing.io, "seed", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, @enumFromInt(0o640));
    try std.testing.expectError(error.InsecureSigningSeedFile, load(std.testing.io, tmp.dir, "seed"));
}

test "rejects signing seed symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSecure(tmp.dir, "target", valid_seed);
    try tmp.dir.symLink(std.testing.io, "target", "seed", .{});
    try std.testing.expectError(error.SymLinkLoop, load(std.testing.io, tmp.dir, "seed"));
}
