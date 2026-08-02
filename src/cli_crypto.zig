const std = @import("std");
const builtin = @import("builtin");
const volume_crypto = @import("zettide").volume_crypto;

const max_passphrase_length = 1024;

const Passphrase = struct {
    bytes: [max_passphrase_length]u8,
    len: usize,
};

pub const Source = union(enum) {
    key_file: []const u8,
    passphrase,
};

pub const Secret = union(enum) {
    raw_key: [volume_crypto.master_key_length]u8,
    passphrase: Passphrase,

    pub fn credential(self: *const Secret) volume_crypto.Credential {
        return switch (self.*) {
            .raw_key => .{ .raw_key = &self.raw_key },
            .passphrase => .{ .argon2id = self.passphrase.bytes[0..self.passphrase.len] },
        };
    }

    pub fn deinit(self: *Secret) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

pub fn loadInto(result: *Secret, io: std.Io, source: Source, confirm_passphrase: bool) !void {
    result.* = switch (source) {
        .key_file => .{ .raw_key = undefined },
        .passphrase => .{ .passphrase = undefined },
    };
    errdefer result.deinit();
    switch (source) {
        .key_file => |path| try readKeyFileInto(&result.raw_key, io, path),
        .passphrase => try readPassphraseInto(&result.passphrase, io, confirm_passphrase),
    }
}

pub fn generateKeyFile(io: std.Io, path: []const u8) !void {
    if (path.len == 0) return error.InvalidKeyFilePath;
    var key: [volume_crypto.master_key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try io.randomSecure(&key);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .exclusive = true,
        .permissions = keyFilePermissions(),
    });
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer file.close(io);
    try file.writePositionalAll(io, &key, 0);
    try file.sync(io);
    try syncParentDirectory(io, path);
}

fn keyFilePermissions() std.Io.File.Permissions {
    if (comptime std.Io.File.Permissions.has_executable_bit)
        return std.Io.File.Permissions.fromMode(0o600);
    return .default_file;
}

fn syncParentDirectory(io: std.Io, path: []const u8) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const dirname = std.fs.path.dirname(path) orelse ".";
    const parent = try std.Io.Dir.cwd().openDir(io, dirname, .{});
    defer parent.close(io);
    const syncable = try parent.openDir(io, ".", .{ .iterate = true });
    defer syncable.close(io);
    const directory_file: std.Io.File = .{
        .handle = syncable.handle,
        .flags = .{ .nonblocking = false },
    };
    try directory_file.sync(io);
}

fn readKeyFileInto(
    result: *[volume_crypto.master_key_length]u8,
    io: std.Io,
    path: []const u8,
) !void {
    const file = if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) opened: {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .NONBLOCK = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0);
        break :opened std.Io.File{ .handle = fd, .flags = .{ .nonblocking = true } };
    } else try std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsafeKeyFileType;
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureKeyFilePermissions;
    }
    if (stat.size != volume_crypto.master_key_length) return error.InvalidKeyFileLength;
    if (try file.readPositionalAll(io, result, 0) != result.len) return error.InvalidKeyFileLength;
}

fn readPassphraseInto(result: *Passphrase, io: std.Io, confirm: bool) !void {
    try readHiddenLineInto(result, io, "Passphrase: ");
    if (result.len == 0) return error.EmptyPassphrase;
    if (confirm) {
        var second: Passphrase = undefined;
        defer std.crypto.secureZero(u8, &second.bytes);
        try readHiddenLineInto(&second, io, "Confirm passphrase: ");
        const contents_match = std.crypto.timing_safe.eql(
            [max_passphrase_length]u8,
            result.bytes,
            second.bytes,
        );
        if (result.len != second.len or !contents_match)
            return error.PassphraseMismatch;
    }
}

fn readHiddenLineInto(result: *Passphrase, io: std.Io, prompt: []const u8) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi)
        return error.PassphraseInputNotSupported;

    const tty = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{
        .mode = .read_write,
        .allow_directory = false,
    });
    defer tty.close(io);

    if (zettide_terminal_hide_echo(tty.handle) != 0) return error.TerminalEchoSetupFailed;
    var echo_restored = false;
    defer if (!echo_restored) {
        _ = zettide_terminal_restore_echo();
    };
    try tty.writeStreamingAll(io, prompt);

    var reader_buffer: [max_passphrase_length + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &reader_buffer);
    var reader = tty.readerStreaming(io, &reader_buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            try tty.writeStreamingAll(io, "\n");
            return error.PassphraseTooLong;
        },
        error.EndOfStream => return error.PassphraseInputEnded,
        else => return err,
    };
    try tty.writeStreamingAll(io, "\n");
    result.* = .{ .bytes = @splat(0), .len = line.len };
    @memcpy(result.bytes[0..line.len], line);
    if (zettide_terminal_restore_echo() != 0) return error.TerminalEchoRestoreFailed;
    echo_restored = true;
}

extern fn zettide_terminal_hide_echo(fd: c_int) c_int;
extern fn zettide_terminal_restore_echo() c_int;
