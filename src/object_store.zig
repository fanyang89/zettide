const std = @import("std");
const Io = std.Io;
const c = @import("block_device.zig").c;
const metadata = @import("metadata.zig");
const format = @import("object_format.zig");

pub const max_path_bytes: usize = 4096;
pub const namespace_root = "/namespace";
const system_root = "/system";
const objects_root = system_root ++ "/objects";
const temporary_root = system_root ++ "/tmp";

pub const Store = struct {
    io: Io,
    lfs: *c.lfs_t,

    pub fn initialize(self: Store) !void {
        try makeDirectory(self.lfs, namespace_root);
        try makeDirectory(self.lfs, system_root);
        try makeDirectory(self.lfs, objects_root);
        try makeDirectory(self.lfs, temporary_root);
    }

    pub fn translateUserPath(path: [*:0]const u8, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
        const value = std.mem.span(path);
        if (value.len == 0 or value[0] != '/') return error.InvalidArgument;
        if (std.mem.eql(u8, value, "/")) return formatPath(buffer, "{s}", .{namespace_root});
        return formatPath(buffer, "{s}{s}", .{ namespace_root, value });
    }

    pub fn createObject(
        self: Store,
        kind: format.RefKind,
        object_metadata: metadata.Metadata,
    ) !format.ObjectRef {
        var id: format.ObjectId = undefined;
        try self.io.randomSecure(&id);
        const object_ref: format.ObjectRef = .{ .kind = kind, .object_id = id };

        var object_path_buffer: [max_path_bytes:0]u8 = @splat(0);
        const object_path = try objectPath(id, &object_path_buffer);
        try checkLfs(c.lfs_mkdir(self.lfs, object_path));
        errdefer self.removeObject(id) catch {};

        var chunks_path_buffer: [max_path_bytes:0]u8 = @splat(0);
        try checkLfs(c.lfs_mkdir(self.lfs, try chunksPath(id, &chunks_path_buffer)));
        const head: format.ObjectHead = .{
            .object_id = id,
            .generation = 1,
            .logical_size = 0,
            .allocated_bytes = 0,
            .metadata = object_metadata,
        };
        try self.writeHead(head);
        return object_ref;
    }

    pub fn publishRef(
        self: Store,
        path: [*:0]const u8,
        object_ref: format.ObjectRef,
        exclusive: bool,
    ) !void {
        var translated_buffer: [max_path_bytes:0]u8 = @splat(0);
        const translated = try translateUserPath(path, &translated_buffer);
        const flags = c.LFS_O_WRONLY | c.LFS_O_CREAT | c.LFS_O_TRUNC |
            (if (exclusive) c.LFS_O_EXCL else 0);
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try checkLfs(c.lfs_file_open(self.lfs, &file, translated, flags));
        var open = true;
        errdefer if (open) {
            _ = c.lfs_file_close(self.lfs, &file);
        };
        const bytes = object_ref.encode();
        const written = c.lfs_file_write(self.lfs, &file, &bytes, bytes.len);
        try checkLfs(written);
        if (written != bytes.len) return error.InputOutput;
        try checkLfs(c.lfs_file_close(self.lfs, &file));
        open = false;
    }

    pub fn readRef(self: Store, path: [*:0]const u8) !format.ObjectRef {
        var translated_buffer: [max_path_bytes:0]u8 = @splat(0);
        return self.readRefInternal(try translateUserPath(path, &translated_buffer));
    }

    pub fn readHead(self: Store, id: format.ObjectId) !format.ObjectHead {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        const path = try headPath(id, &path_buffer);
        var bytes: [format.head_encoded_size]u8 = undefined;
        try readExact(self.lfs, path, &bytes);
        const head = try format.ObjectHead.decode(&bytes);
        if (!std.mem.eql(u8, &head.object_id, &id)) return error.InvalidObjectHead;
        return head;
    }

    pub fn writeHead(self: Store, head: format.ObjectHead) !void {
        var temporary_buffer: [max_path_bytes:0]u8 = @splat(0);
        var final_buffer: [max_path_bytes:0]u8 = @splat(0);
        const temporary = try temporaryHeadPath(head.object_id, &temporary_buffer);
        const final = try headPath(head.object_id, &final_buffer);
        const bytes = head.encode();
        try writeExact(self.lfs, temporary, &bytes);
        try checkLfs(c.lfs_rename(self.lfs, temporary, final));
    }

    pub fn read(
        self: Store,
        id: format.ObjectId,
        buffer: []u8,
        offset: u64,
    ) !usize {
        const head = try self.readHead(id);
        if (offset >= head.logical_size or buffer.len == 0) return 0;
        const available = head.logical_size - offset;
        const amount: usize = @intCast(@min(@as(u64, buffer.len), available));
        @memset(buffer[0..amount], 0);

        var consumed: usize = 0;
        while (consumed < amount) {
            const position = offset + consumed;
            const index = position / head.stored_chunk_size;
            const chunk_offset: u32 = @intCast(position % head.stored_chunk_size);
            const part = @min(amount - consumed, head.stored_chunk_size - chunk_offset);
            try self.readChunk(id, index, buffer[consumed..][0..part], chunk_offset);
            consumed += part;
        }
        return amount;
    }

    pub fn write(
        self: Store,
        id: format.ObjectId,
        data: []const u8,
        offset: u64,
    ) !usize {
        const end = std.math.add(u64, offset, data.len) catch return error.FileTooLarge;
        if (end > format.max_file_size) return error.FileTooLarge;
        if (data.len == 0) return 0;

        var head = try self.readHead(id);
        var consumed: usize = 0;
        while (consumed < data.len) {
            const position = offset + consumed;
            const index = position / head.stored_chunk_size;
            const chunk_offset: u32 = @intCast(position % head.stored_chunk_size);
            const part = @min(data.len - consumed, head.stored_chunk_size - chunk_offset);
            try self.writeChunk(id, index, data[consumed..][0..part], chunk_offset);
            consumed += part;
        }

        head.logical_size = @max(head.logical_size, end);
        head.allocated_bytes = try self.allocatedBytes(id);
        head.generation +%= 1;
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head.metadata.mtime_ns = now;
        head.metadata.ctime_ns = now;
        try self.writeHead(head);
        return data.len;
    }

    pub fn truncate(self: Store, id: format.ObjectId, size: u64) !void {
        if (size > format.max_file_size) return error.FileTooLarge;
        var head = try self.readHead(id);
        if (size < head.logical_size) {
            try self.discardChunksAfter(id, size, head.stored_chunk_size);
        }
        head.logical_size = size;
        head.allocated_bytes = try self.allocatedBytes(id);
        head.generation +%= 1;
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head.metadata.mtime_ns = now;
        head.metadata.ctime_ns = now;
        try self.writeHead(head);
    }

    pub fn updateMetadata(self: Store, id: format.ObjectId, value: metadata.Metadata) !void {
        var head = try self.readHead(id);
        head.metadata = value;
        head.generation +%= 1;
        try self.writeHead(head);
    }

    pub fn removeObject(self: Store, id: format.ObjectId) !void {
        while (try self.firstChunkName(id)) |name| {
            var path_buffer: [max_path_bytes:0]u8 = @splat(0);
            try checkLfs(c.lfs_remove(self.lfs, try namedChunkPath(id, name, &path_buffer)));
        }

        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        removeIfPresent(self.lfs, try temporaryHeadPath(id, &path_buffer)) catch {};
        path_buffer = @splat(0);
        removeIfPresent(self.lfs, try headPath(id, &path_buffer)) catch {};
        path_buffer = @splat(0);
        removeIfPresent(self.lfs, try chunksPath(id, &path_buffer)) catch {};
        path_buffer = @splat(0);
        try removeIfPresent(self.lfs, try objectPath(id, &path_buffer));
    }

    fn readRefInternal(self: Store, path: [*:0]const u8) !format.ObjectRef {
        var bytes: [format.ref_encoded_size]u8 = undefined;
        try readExact(self.lfs, path, &bytes);
        return format.ObjectRef.decode(&bytes);
    }

    fn readChunk(
        self: Store,
        id: format.ObjectId,
        index: u64,
        buffer: []u8,
        offset: u32,
    ) !void {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        const path = try chunkPath(id, index, &path_buffer);
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        const result = c.lfs_file_open(self.lfs, &file, path, c.LFS_O_RDONLY);
        if (result == c.LFS_ERR_NOENT) return;
        try checkLfs(result);
        defer _ = c.lfs_file_close(self.lfs, &file);
        try checkLfs(c.lfs_file_seek(self.lfs, &file, @intCast(offset), c.LFS_SEEK_SET));
        const read_amount = c.lfs_file_read(self.lfs, &file, buffer.ptr, @intCast(buffer.len));
        try checkLfs(read_amount);
    }

    fn writeChunk(
        self: Store,
        id: format.ObjectId,
        index: u64,
        data: []const u8,
        offset: u32,
    ) !void {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        const path = try chunkPath(id, index, &path_buffer);
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try checkLfs(c.lfs_file_open(self.lfs, &file, path, c.LFS_O_RDWR | c.LFS_O_CREAT));
        var open = true;
        errdefer if (open) {
            _ = c.lfs_file_close(self.lfs, &file);
        };
        try checkLfs(c.lfs_file_seek(self.lfs, &file, @intCast(offset), c.LFS_SEEK_SET));
        const written = c.lfs_file_write(self.lfs, &file, data.ptr, @intCast(data.len));
        try checkLfs(written);
        if (written != data.len) return error.InputOutput;
        try checkLfs(c.lfs_file_close(self.lfs, &file));
        open = false;
    }

    fn discardChunksAfter(self: Store, id: format.ObjectId, size: u64, stored_chunk_size: u32) !void {
        const keep_index = if (size == 0) null else (size - 1) / stored_chunk_size;
        while (try self.firstChunkAtOrAfter(id, if (size == 0) 0 else size / stored_chunk_size +
            @intFromBool(size % stored_chunk_size != 0))) |name|
        {
            var path_buffer: [max_path_bytes:0]u8 = @splat(0);
            try checkLfs(c.lfs_remove(self.lfs, try namedChunkPath(id, name, &path_buffer)));
        }

        if (keep_index) |index| {
            const tail: u32 = @intCast(size % stored_chunk_size);
            if (tail != 0) {
                var path_buffer: [max_path_bytes:0]u8 = @splat(0);
                var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
                const result = c.lfs_file_open(self.lfs, &file, try chunkPath(id, index, &path_buffer), c.LFS_O_RDWR);
                if (result != c.LFS_ERR_NOENT) {
                    try checkLfs(result);
                    var open = true;
                    errdefer if (open) {
                        _ = c.lfs_file_close(self.lfs, &file);
                    };
                    try checkLfs(c.lfs_file_truncate(self.lfs, &file, tail));
                    try checkLfs(c.lfs_file_close(self.lfs, &file));
                    open = false;
                }
            }
        }
    }

    fn allocatedBytes(self: Store, id: format.ObjectId) !u64 {
        var total: u64 = 0;
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try chunksPath(id, &path_buffer)));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) break;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            total = std.math.add(u64, total, info.size) catch return error.CorruptFilesystem;
        }
        return total;
    }

    fn firstChunkName(self: Store, id: format.ObjectId) !?[16]u8 {
        return self.firstChunkAtOrAfter(id, 0);
    }

    fn firstChunkAtOrAfter(self: Store, id: format.ObjectId, minimum: u64) !?[16]u8 {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try chunksPath(id, &path_buffer)));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return null;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (name.len != 16) continue;
            const index = std.fmt.parseInt(u64, name, 16) catch continue;
            if (index < minimum) continue;
            var copy: [16]u8 = undefined;
            @memcpy(&copy, name);
            return copy;
        }
    }
};

fn makeDirectory(lfs: *c.lfs_t, path: [*:0]const u8) !void {
    const result = c.lfs_mkdir(lfs, path);
    if (result != c.LFS_ERR_EXIST) try checkLfs(result);
}

fn readExact(lfs: *c.lfs_t, path: [*:0]const u8, buffer: []u8) !void {
    var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
    try checkLfs(c.lfs_file_open(lfs, &file, path, c.LFS_O_RDONLY));
    defer _ = c.lfs_file_close(lfs, &file);
    const amount = c.lfs_file_read(lfs, &file, buffer.ptr, @intCast(buffer.len));
    try checkLfs(amount);
    if (amount != buffer.len) return error.InvalidObjectFormat;
}

fn writeExact(lfs: *c.lfs_t, path: [*:0]const u8, data: []const u8) !void {
    var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
    try checkLfs(c.lfs_file_open(lfs, &file, path, c.LFS_O_WRONLY | c.LFS_O_CREAT | c.LFS_O_TRUNC));
    var open = true;
    errdefer if (open) {
        _ = c.lfs_file_close(lfs, &file);
    };
    const amount = c.lfs_file_write(lfs, &file, data.ptr, @intCast(data.len));
    try checkLfs(amount);
    if (amount != data.len) return error.InputOutput;
    try checkLfs(c.lfs_file_close(lfs, &file));
    open = false;
}

fn removeIfPresent(lfs: *c.lfs_t, path: [*:0]const u8) !void {
    const result = c.lfs_remove(lfs, path);
    if (result != c.LFS_ERR_NOENT) try checkLfs(result);
}

fn objectPath(id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}", .{ objects_root, format.formatObjectId(id, &id_buffer) });
}

fn chunksPath(id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/chunks", .{ objects_root, format.formatObjectId(id, &id_buffer) });
}

fn headPath(id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/head", .{ objects_root, format.formatObjectId(id, &id_buffer) });
}

fn temporaryHeadPath(id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/head.tmp", .{ objects_root, format.formatObjectId(id, &id_buffer) });
}

fn chunkPath(id: format.ObjectId, index: u64, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/chunks/{x:0>16}", .{
        objects_root,
        format.formatObjectId(id, &id_buffer),
        index,
    });
}

fn namedChunkPath(id: format.ObjectId, name: [16]u8, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/chunks/{s}", .{
        objects_root,
        format.formatObjectId(id, &id_buffer),
        name,
    });
}

fn formatPath(buffer: *[max_path_bytes:0]u8, comptime pattern: []const u8, args: anytype) ![*:0]const u8 {
    @memset(buffer, 0);
    _ = std.fmt.bufPrint(buffer[0..max_path_bytes], pattern, args) catch return error.NameTooLong;
    return @ptrCast(buffer);
}

fn checkLfs(result: anytype) !void {
    if (result >= 0) return;
    return switch (result) {
        c.LFS_ERR_IO => error.InputOutput,
        c.LFS_ERR_CORRUPT => error.CorruptFilesystem,
        c.LFS_ERR_NOENT => error.FileNotFound,
        c.LFS_ERR_EXIST => error.PathAlreadyExists,
        c.LFS_ERR_NOTDIR => error.NotDirectory,
        c.LFS_ERR_ISDIR => error.IsDirectory,
        c.LFS_ERR_NOTEMPTY => error.DirectoryNotEmpty,
        c.LFS_ERR_FBIG => error.FileTooLarge,
        c.LFS_ERR_INVAL => error.InvalidArgument,
        c.LFS_ERR_NOSPC => error.NoSpaceLeft,
        c.LFS_ERR_NOMEM => error.OutOfMemory,
        c.LFS_ERR_NAMETOOLONG => error.NameTooLong,
        else => error.LittleFsFailure,
    };
}

test "user paths are isolated below the namespace root" {
    var buffer: [max_path_bytes:0]u8 = @splat(0);
    try std.testing.expectEqualStrings(namespace_root, std.mem.span(try Store.translateUserPath("/", &buffer)));
    try std.testing.expectEqualStrings("/namespace/a/b", std.mem.span(try Store.translateUserPath("/a/b", &buffer)));
}
