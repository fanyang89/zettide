const backend = @import("filesystem_backend.zig");
const object_format = @import("object_format.zig");
const volume_mod = @import("volume.zig");

const c = volume_mod.c;

pub fn openFile(
    volume: *volume_mod.Volume,
    handle: *volume_mod.FileHandle,
    path: [*:0]const u8,
    options: backend.OpenOptions,
    mode: u32,
    uid: u32,
    gid: u32,
) !void {
    return volume.openFile(handle, path, flags(options), mode, uid, gid);
}

pub fn openObject(
    volume: *volume_mod.Volume,
    handle: *volume_mod.FileHandle,
    object_id: object_format.ObjectId,
    options: backend.OpenOptions,
) !void {
    return volume.openObject(handle, object_id, flags(options));
}

pub fn readDirectory(
    volume: *volume_mod.Volume,
    handle: *volume_mod.DirectoryHandle,
    entry: *backend.DirectoryEntry,
) !bool {
    var info: c.struct_lfs_info = undefined;
    if (!try volume.readDirectory(handle, &info)) return false;

    entry.* = .{
        .kind = if (info.type == c.LFS_TYPE_DIR) .directory else .file,
        .name_buffer = @splat(0),
    };
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
    if (name.len >= backend.name_capacity) return error.NameTooLong;
    @memcpy(entry.name_buffer[0..name.len], name);
    return true;
}

fn flags(options: backend.OpenOptions) c_int {
    var result: c_int = switch (options.access) {
        .read_only => c.LFS_O_RDONLY,
        .read_write => c.LFS_O_RDWR,
    };
    if (options.create) result |= c.LFS_O_CREAT;
    if (options.exclusive) result |= c.LFS_O_EXCL;
    if (options.truncate) result |= c.LFS_O_TRUNC;
    if (options.append) result |= c.LFS_O_APPEND;
    return result;
}

const std = @import("std");
