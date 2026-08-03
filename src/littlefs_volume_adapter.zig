const backend = @import("filesystem_backend.zig");
const metadata = @import("metadata.zig");
const object_format = @import("object_format.zig");
const volume_mod = @import("volume.zig");

const c = volume_mod.c;

pub fn filesystem(volume: *volume_mod.Volume) backend.Filesystem {
    return .{
        .context = volume,
        .vtable = &filesystem_vtable,
    };
}

const FileContext = struct {
    volume: *volume_mod.Volume,
    handle: volume_mod.FileHandle,
};

const DirectoryContext = struct {
    volume: *volume_mod.Volume,
    handle: volume_mod.DirectoryHandle,
};

const filesystem_vtable: backend.Filesystem.VTable = .{
    .stat_path = statPath,
    .stat_file_id = statFileId,
    .pin_file = pinFile,
    .unpin_file = unpinFile,
    .set_metadata = setMetadata,
    .patch_metadata = patchMetadata,
    .make_directory = makeDirectory,
    .make_symlink = makeSymlink,
    .make_fifo = makeFifo,
    .link = link,
    .remove = remove,
    .rename = rename,
    .read_special = readSpecial,
    .open_file = openFileHandle,
    .open_file_id = openFileId,
    .open_directory = openDirectory,
    .sync = sync,
    .space_info = spaceInfo,
};

const file_vtable: backend.FileHandle.VTable = .{
    .stat = statFile,
    .file_id = fileId,
    .read = readFile,
    .write = writeFile,
    .truncate = truncateFile,
    .fallocate = fallocateFile,
    .sync = syncFile,
    .set_metadata = setFileMetadata,
    .patch_metadata = patchFileMetadata,
    .close = closeFile,
    .destroy = destroyFile,
};

const directory_vtable: backend.DirectoryHandle.VTable = .{
    .info = directoryInfo,
    .read = readDirectoryHandle,
    .seek = seekDirectory,
    .tell = tellDirectory,
    .sync = syncDirectory,
    .close = closeDirectory,
    .destroy = destroyDirectory,
};

fn nativeVolume(raw: *anyopaque) *volume_mod.Volume {
    return @ptrCast(@alignCast(raw));
}

fn fileContext(raw: *anyopaque) *FileContext {
    return @ptrCast(@alignCast(raw));
}

fn directoryContext(raw: *anyopaque) *DirectoryContext {
    return @ptrCast(@alignCast(raw));
}

fn nodeInfo(info: volume_mod.NodeInfo) backend.NodeInfo {
    return .{
        .size = info.size,
        .allocated_bytes = info.allocated_bytes,
        .metadata = info.metadata,
        .file_id = info.object_id,
        .identity = info.identity,
        .nlink = info.nlink,
    };
}

fn statPath(raw: *anyopaque, path: [*:0]const u8) !backend.NodeInfo {
    return nodeInfo(try nativeVolume(raw).stat(path));
}

fn statFileId(raw: *anyopaque, file_id: backend.FileId) !backend.NodeInfo {
    return nodeInfo(try nativeVolume(raw).statObject(file_id));
}

fn pinFile(raw: *anyopaque, file_id: backend.FileId) !void {
    return nativeVolume(raw).pinObject(file_id);
}

fn unpinFile(raw: *anyopaque, file_id: backend.FileId) !void {
    return nativeVolume(raw).unpinObject(file_id);
}

fn setMetadata(raw: *anyopaque, path: [*:0]const u8, value: metadata.Metadata) !void {
    return nativeVolume(raw).setMetadata(path, value);
}

fn patchMetadata(
    raw: *anyopaque,
    file_id: backend.FileId,
    patch: metadata.Patch,
) !metadata.Metadata {
    return (try nativeVolume(raw).patchObjectMetadata(file_id, patch)).metadata;
}

fn makeDirectory(raw: *anyopaque, path: [*:0]const u8, attributes: backend.CreateAttributes) !void {
    return nativeVolume(raw).makeDirectory(path, attributes.mode, attributes.uid, attributes.gid);
}

fn makeSymlink(raw: *anyopaque, path: [*:0]const u8, target: []const u8, uid: u32, gid: u32) !void {
    return nativeVolume(raw).makeSymlink(path, target, uid, gid);
}

fn makeFifo(raw: *anyopaque, path: [*:0]const u8, attributes: backend.CreateAttributes) !void {
    return nativeVolume(raw).makeFifo(path, attributes.mode, attributes.uid, attributes.gid);
}

fn link(raw: *anyopaque, old_path: [*:0]const u8, new_path: [*:0]const u8) !backend.NodeInfo {
    return nodeInfo(try nativeVolume(raw).linkWithInfo(old_path, new_path));
}

fn remove(raw: *anyopaque, path: [*:0]const u8) !void {
    return nativeVolume(raw).remove(path);
}

fn rename(
    raw: *anyopaque,
    old_path: [*:0]const u8,
    new_path: [*:0]const u8,
    no_replace: bool,
) !backend.RenameResult {
    const result = if (no_replace)
        try nativeVolume(raw).renameWithResultNoReplace(old_path, new_path)
    else
        try nativeVolume(raw).renameWithResult(old_path, new_path);
    return switch (result) {
        .renamed => .renamed,
        .same_object => .same_object,
    };
}

fn readSpecial(raw: *anyopaque, file_id: backend.FileId, buffer: []u8, offset: u64) !usize {
    return nativeVolume(raw).readObject(file_id, buffer, offset);
}

fn openFileHandle(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    path: [*:0]const u8,
    options: backend.OpenOptions,
    attributes: backend.CreateAttributes,
) !backend.FileHandle {
    const context = try allocator.create(FileContext);
    errdefer allocator.destroy(context);
    context.volume = nativeVolume(raw);
    try openFile(
        context.volume,
        &context.handle,
        path,
        options,
        attributes.mode,
        attributes.uid,
        attributes.gid,
    );
    return .{
        .context = context,
        .allocator = allocator,
        .vtable = &file_vtable,
    };
}

fn openFileId(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    file_id: backend.FileId,
    options: backend.OpenOptions,
) !backend.FileHandle {
    const context = try allocator.create(FileContext);
    errdefer allocator.destroy(context);
    context.volume = nativeVolume(raw);
    try openObject(context.volume, &context.handle, file_id, options);
    return .{
        .context = context,
        .allocator = allocator,
        .vtable = &file_vtable,
    };
}

fn openDirectory(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    path: [*:0]const u8,
) !backend.DirectoryHandle {
    const context = try allocator.create(DirectoryContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .volume = nativeVolume(raw),
        .handle = .{},
    };
    try context.volume.openDirectory(&context.handle, path);
    return .{
        .context = context,
        .allocator = allocator,
        .vtable = &directory_vtable,
    };
}

fn sync(raw: *anyopaque) !void {
    return nativeVolume(raw).sync();
}

fn spaceInfo(raw: *anyopaque) !backend.SpaceInfo {
    const value = nativeVolume(raw);
    const used = try value.usedBlocks();
    const free = @as(u64, value.header.block_count) - used;
    return .{
        .block_size = value.header.block_size,
        .total_blocks = value.header.block_count,
        .free_blocks = free,
        .available_blocks = free -| try value.reservedCapacityBlocks(),
        .name_max = value.header.name_max,
    };
}

fn statFile(raw: *anyopaque) !backend.NodeInfo {
    const context = fileContext(raw);
    return nodeInfo(try context.volume.statFile(&context.handle));
}

fn fileId(raw: *anyopaque) backend.FileId {
    return fileContext(raw).handle.object_id;
}

fn readFile(raw: *anyopaque, buffer: []u8, offset: u64) !usize {
    const context = fileContext(raw);
    return context.volume.readFile(&context.handle, buffer, offset);
}

fn writeFile(raw: *anyopaque, data: []const u8, offset: u64) !usize {
    const context = fileContext(raw);
    return context.volume.writeFile(&context.handle, data, offset);
}

fn truncateFile(raw: *anyopaque, size: u64) !void {
    const context = fileContext(raw);
    return context.volume.truncateFile(&context.handle, size);
}

fn fallocateFile(raw: *anyopaque, offset: u64, length: u64) !void {
    const context = fileContext(raw);
    return context.volume.fallocateFile(&context.handle, offset, length);
}

fn syncFile(raw: *anyopaque) !void {
    const context = fileContext(raw);
    return context.volume.syncFile(&context.handle);
}

fn setFileMetadata(raw: *anyopaque, value: metadata.Metadata) !void {
    const context = fileContext(raw);
    return context.volume.setObjectMetadata(context.handle.object_id, value);
}

fn patchFileMetadata(raw: *anyopaque, patch: metadata.Patch) !metadata.Metadata {
    const context = fileContext(raw);
    return (try context.volume.patchObjectMetadata(context.handle.object_id, patch)).metadata;
}

fn closeFile(raw: *anyopaque) !void {
    const context = fileContext(raw);
    return context.volume.closeFile(&context.handle);
}

fn destroyFile(raw: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(fileContext(raw));
}

fn directoryInfo(raw: *anyopaque) backend.NodeInfo {
    return nodeInfo(directoryContext(raw).handle.info);
}

fn readDirectoryHandle(raw: *anyopaque, entry: *backend.DirectoryEntry) !bool {
    const context = directoryContext(raw);
    return readDirectory(context.volume, &context.handle, entry);
}

fn seekDirectory(raw: *anyopaque, offset: u32) !void {
    const context = directoryContext(raw);
    return context.volume.seekDirectory(&context.handle, offset);
}

fn tellDirectory(raw: *anyopaque) !u32 {
    const context = directoryContext(raw);
    return context.volume.tellDirectory(&context.handle);
}

fn syncDirectory(raw: *anyopaque) !void {
    return directoryContext(raw).volume.sync();
}

fn closeDirectory(raw: *anyopaque) !void {
    const context = directoryContext(raw);
    return context.volume.closeDirectory(&context.handle);
}

fn destroyDirectory(raw: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(directoryContext(raw));
}

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

test "filesystem adapter round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/adapter.ddv", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    try volume_mod.Volume.create(std.testing.io, path, 1024 * 1024, "Adapter");
    var native = try volume_mod.Volume.open(std.testing.io, path, true);
    defer native.deinit();
    try native.mount();

    const fs = filesystem(&native);
    const root_info = try fs.statPath("/");
    try std.testing.expectEqual(metadata.Kind.directory, root_info.metadata.kind);

    var file = try fs.openFile(std.testing.allocator, "/hello", .{
        .access = .read_write,
        .create = true,
        .exclusive = true,
    }, .{
        .mode = 0o100644,
        .uid = 1000,
        .gid = 1000,
    });
    var file_open = true;
    defer if (file_open) file.close() catch {};
    try std.testing.expectEqual(@as(usize, 5), try file.write("hello", 0));
    var buffer: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try file.read(&buffer, 0));
    try std.testing.expectEqualStrings("hello", &buffer);
    const file_id = file.fileId();
    try std.testing.expectEqual(@as(u64, 5), (try file.stat()).size);
    try file.sync();
    try file.close();
    file_open = false;

    var reopened = try fs.openFileId(std.testing.allocator, file_id, .{ .access = .read_only });
    var reopened_open = true;
    defer if (reopened_open) reopened.close() catch {};
    buffer = undefined;
    try std.testing.expectEqual(@as(usize, 5), try reopened.read(&buffer, 0));
    try std.testing.expectEqualStrings("hello", &buffer);
    try reopened.close();
    reopened_open = false;

    var directory = try fs.openDirectory(std.testing.allocator, "/");
    var directory_open = true;
    defer if (directory_open) directory.close() catch {};
    try std.testing.expectEqual(root_info.identity, directory.info().identity);
    var found = false;
    while (true) {
        var entry: backend.DirectoryEntry = undefined;
        if (!try directory.read(&entry)) break;
        if (std.mem.eql(u8, entry.name(), "hello")) found = true;
    }
    try std.testing.expect(found);
    try directory.sync();
    try directory.close();
    directory_open = false;

    try fs.sync();
    const space = try fs.spaceInfo();
    try std.testing.expectEqual(native.header.block_size, space.block_size);
    try std.testing.expect(space.total_blocks > 0);
    try std.testing.expect(space.available_blocks <= space.free_blocks);
}
