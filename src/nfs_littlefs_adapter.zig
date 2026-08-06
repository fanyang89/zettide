const std = @import("std");
const metadata = @import("metadata.zig");
const nfs_filesystem = @import("nfs_filesystem.zig");
const nfs_handle = @import("nfs_handle.zig");
const volume_mod = @import("volume.zig");

const DirectoryContext = struct {
    volume: *volume_mod.Volume,
    handle: volume_mod.DirectoryHandle,
};

pub fn filesystem(value: *volume_mod.Volume) nfs_filesystem.Filesystem {
    return .{
        .context = value,
        .filesystem_id = value.volumeUuid(),
        .vtable = &filesystem_vtable,
    };
}

const filesystem_vtable: nfs_filesystem.Filesystem.VTable = .{
    .space_info = spaceInfo,
    .root = root,
    .stat = stat,
    .set_metadata = setMetadata,
    .truncate = truncate,
    .lookup = lookup,
    .parent = parent,
    .read = read,
    .write = write,
    .create_file = createFile,
    .make_directory = makeDirectory,
    .make_symlink = makeSymlink,
    .readlink = readlink,
    .link = link,
    .remove = remove,
    .rename = rename,
    .open_directory = openDirectory,
    .sync = sync,
};

const directory_vtable: nfs_filesystem.Directory.VTable = .{
    .read = readDirectory,
    .close = closeDirectory,
    .destroy = destroyDirectory,
};

fn nativeVolume(raw: *anyopaque) *volume_mod.Volume {
    return @ptrCast(@alignCast(raw));
}

fn directory(raw: *anyopaque) *DirectoryContext {
    return @ptrCast(@alignCast(raw));
}

fn nativeNode(node: nfs_filesystem.Node) nfs_handle.Handle {
    return .{ .kind = node.kind, .identity = node.identity };
}

fn nodeInfo(info: volume_mod.NodeInfo) nfs_filesystem.NodeInfo {
    return .{
        .size = info.size,
        .allocated_bytes = info.allocated_bytes,
        .metadata = info.metadata,
        .identity = info.identity,
        .nlink = info.nlink,
    };
}

fn spaceInfo(raw: *anyopaque) !nfs_filesystem.SpaceInfo {
    const value = nativeVolume(raw);
    const available = try value.availableBlocks();
    return .{
        .block_size = value.header.block_size,
        .total_blocks = value.header.block_count,
        .free_blocks = available,
        .available_blocks = available,
    };
}

fn root(raw: *anyopaque) !nfs_filesystem.NodeInfo {
    const value = nativeVolume(raw);
    return nodeInfo(try value.statDirectoryIdentity(try value.rootDirectoryIdentity()));
}

fn stat(raw: *anyopaque, node: nfs_filesystem.Node) !nfs_filesystem.NodeInfo {
    return nodeInfo(try nativeVolume(raw).statIdentity(nativeNode(node)));
}

fn setMetadata(
    raw: *anyopaque,
    node: nfs_filesystem.Node,
    value: metadata.Metadata,
) !nfs_filesystem.NodeInfo {
    return nodeInfo(try nativeVolume(raw).setMetadataIdentity(nativeNode(node), value));
}

fn truncate(raw: *anyopaque, node: nfs_filesystem.Node, size: u64) !nfs_filesystem.NodeInfo {
    const value = nativeVolume(raw);
    if (node.kind != .file) return error.InvalidArgument;
    var file: volume_mod.FileHandle = undefined;
    try value.openObject(&file, node.identity, volume_mod.c.LFS_O_RDWR);
    value.truncateFile(&file, size) catch |err| {
        value.closeFile(&file) catch {};
        return err;
    };
    const info = value.statFile(&file) catch |err| {
        value.closeFile(&file) catch {};
        return err;
    };
    try value.closeFile(&file);
    return nodeInfo(info);
}

fn lookup(raw: *anyopaque, parent_node: nfs_filesystem.Node, name: []const u8) !nfs_filesystem.NodeInfo {
    if (parent_node.kind != .directory) return error.NotDirectory;
    return nodeInfo(try nativeVolume(raw).lookupAt(parent_node.identity, name));
}

fn parent(raw: *anyopaque, node: nfs_filesystem.Node) !nfs_filesystem.NodeInfo {
    if (node.kind != .directory) return error.NotDirectory;
    const value = nativeVolume(raw);
    return nodeInfo(try value.statDirectoryIdentity(try value.parentDirectoryIdentity(node.identity)));
}

fn read(raw: *anyopaque, node: nfs_filesystem.Node, output: []u8, offset: u64) !usize {
    if (node.kind == .directory) return error.IsDirectory;
    if (node.kind != .file) return error.InvalidArgument;
    const value = nativeVolume(raw);
    var file: volume_mod.FileHandle = undefined;
    try value.openObject(&file, node.identity, volume_mod.c.LFS_O_RDONLY);
    defer value.closeFile(&file) catch {};
    return value.readFile(&file, output, offset);
}

fn write(raw: *anyopaque, node: nfs_filesystem.Node, data: []const u8, offset: u64) !usize {
    if (node.kind == .directory) return error.IsDirectory;
    if (node.kind != .file) return error.InvalidArgument;
    const value = nativeVolume(raw);
    var file: volume_mod.FileHandle = undefined;
    try value.openObject(&file, node.identity, volume_mod.c.LFS_O_RDWR);
    defer value.closeFile(&file) catch {};
    return value.writeFile(&file, data, offset);
}

fn createFile(
    raw: *anyopaque,
    parent_node: nfs_filesystem.Node,
    name: []const u8,
    attributes: nfs_filesystem.CreateAttributes,
) !nfs_filesystem.NodeInfo {
    if (parent_node.kind != .directory) return error.NotDirectory;
    const value = nativeVolume(raw);
    var file: volume_mod.FileHandle = undefined;
    try value.openFileAt(
        &file,
        parent_node.identity,
        name,
        volume_mod.c.LFS_O_CREAT | volume_mod.c.LFS_O_EXCL | volume_mod.c.LFS_O_RDWR,
        0o100000 | (attributes.mode & 0o7777),
        attributes.uid,
        attributes.gid,
    );
    const info = value.statFile(&file) catch |err| {
        value.closeFile(&file) catch {};
        return err;
    };
    try value.closeFile(&file);
    return nodeInfo(info);
}

fn makeDirectory(
    raw: *anyopaque,
    parent_node: nfs_filesystem.Node,
    name: []const u8,
    attributes: nfs_filesystem.CreateAttributes,
) !nfs_filesystem.NodeInfo {
    if (parent_node.kind != .directory) return error.NotDirectory;
    return nodeInfo(try nativeVolume(raw).makeDirectoryAt(
        parent_node.identity,
        name,
        0o40000 | (attributes.mode & 0o7777),
        attributes.uid,
        attributes.gid,
    ));
}

fn makeSymlink(
    raw: *anyopaque,
    parent_node: nfs_filesystem.Node,
    name: []const u8,
    target: []const u8,
    uid: u32,
    gid: u32,
) !nfs_filesystem.NodeInfo {
    if (parent_node.kind != .directory) return error.NotDirectory;
    return nodeInfo(try nativeVolume(raw).makeSymlinkAt(parent_node.identity, name, target, uid, gid));
}

fn readlink(raw: *anyopaque, node: nfs_filesystem.Node, output: []u8) !usize {
    if (node.kind != .symlink) return error.InvalidArgument;
    return nativeVolume(raw).readObject(node.identity, output, 0);
}

fn link(
    raw: *anyopaque,
    source: nfs_filesystem.Node,
    parent_node: nfs_filesystem.Node,
    name: []const u8,
) !nfs_filesystem.NodeInfo {
    if (source.kind == .directory) return error.IsDirectory;
    if (parent_node.kind != .directory) return error.NotDirectory;
    return nodeInfo(try nativeVolume(raw).linkObjectAt(source.identity, parent_node.identity, name));
}

fn remove(raw: *anyopaque, parent_node: nfs_filesystem.Node, name: []const u8) !void {
    if (parent_node.kind != .directory) return error.NotDirectory;
    return nativeVolume(raw).removeAt(parent_node.identity, name);
}

fn rename(
    raw: *anyopaque,
    old_parent: nfs_filesystem.Node,
    old_name: []const u8,
    new_parent: nfs_filesystem.Node,
    new_name: []const u8,
    no_replace: bool,
) !void {
    if (old_parent.kind != .directory or new_parent.kind != .directory) return error.NotDirectory;
    _ = try nativeVolume(raw).renameAt(old_parent.identity, old_name, new_parent.identity, new_name, no_replace);
}

fn openDirectory(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    node: nfs_filesystem.Node,
    cookie: u32,
) !nfs_filesystem.Directory {
    if (node.kind != .directory) return error.NotDirectory;
    const value = nativeVolume(raw);
    const context = try allocator.create(DirectoryContext);
    errdefer allocator.destroy(context);
    context.* = .{ .volume = value, .handle = .{} };
    try value.openDirectoryIdentity(&context.handle, node.identity);
    errdefer value.closeDirectory(&context.handle) catch {};
    if (cookie != 0) try value.seekDirectory(&context.handle, cookie);
    return .{ .context = context, .allocator = allocator, .vtable = &directory_vtable };
}

fn sync(raw: *anyopaque) !void {
    return nativeVolume(raw).sync();
}

fn readDirectory(raw: *anyopaque, output: *nfs_filesystem.DirectoryEntry) !bool {
    const context = directory(raw);
    var entry: volume_mod.DirectoryEntry = undefined;
    if (!try context.volume.readDirectoryEntry(&context.handle, &entry)) return false;
    output.* = .{
        .name_buffer = @splat(0),
        .next_cookie = entry.next_cookie,
        .info = nodeInfo(entry.info),
    };
    const name = entry.nameSlice();
    @memcpy(output.name_buffer[0..name.len], name);
    return true;
}

fn closeDirectory(raw: *anyopaque) !void {
    const context = directory(raw);
    return context.volume.closeDirectory(&context.handle);
}

fn destroyDirectory(raw: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(directory(raw));
}
