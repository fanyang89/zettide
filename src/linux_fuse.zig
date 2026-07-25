const std = @import("std");
const Io = std.Io;
const volume_mod = @import("volume.zig");
const metadata = @import("metadata.zig");
const lfs = volume_mod.c;

const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("fuse_shim.h");
});

const path_capacity = 4096;
const name_capacity = 256;
const cache_timeout = 1.0;

const Inode = struct {
    id: c.fuse_ino_t,
    parent: ?*Inode,
    name: [name_capacity:0]u8,
    path: [path_capacity:0]u8,
    kind: metadata.Kind,
    cached_info: ?volume_mod.NodeInfo,
    lookup_count: u64,
    open_count: u64,
    linked: bool,
    next: ?*Inode,
};

const MountState = struct {
    volume: *volume_mod.Volume,
    nodes: ?*Inode = null,
    open_files: ?*FuseFileHandle = null,
    next_id: c.fuse_ino_t = c.FUSE_ROOT_ID + 1,

    fn init(volume: *volume_mod.Volume) !MountState {
        var state = MountState{ .volume = volume };
        const root = try std.heap.c_allocator.create(Inode);
        root.* = .{
            .id = c.FUSE_ROOT_ID,
            .parent = null,
            .name = @splat(0),
            .path = @splat(0),
            .kind = .directory,
            .cached_info = null,
            .lookup_count = 1,
            .open_count = 0,
            .linked = true,
            .next = null,
        };
        root.path[0] = '/';
        state.nodes = root;
        return state;
    }

    fn deinit(self: *MountState) void {
        var current = self.nodes;
        while (current) |node| {
            const next = node.next;
            std.heap.c_allocator.destroy(node);
            current = next;
        }
        self.nodes = null;
    }

    fn find(self: *MountState, id: c.fuse_ino_t) ?*Inode {
        var current = self.nodes;
        while (current) |node| : (current = node.next) {
            if (node.id == id) return node;
        }
        return null;
    }

    fn findChild(self: *MountState, parent: *Inode, name: []const u8) ?*Inode {
        var current = self.nodes;
        while (current) |node| : (current = node.next) {
            if (node.linked and node.parent == parent and
                std.mem.eql(u8, std.mem.sliceTo(&node.name, 0), name)) return node;
        }
        return null;
    }

    fn addNode(self: *MountState, parent: *Inode, name: []const u8, kind: metadata.Kind) !*Inode {
        if (name.len >= name_capacity) return error.NameTooLong;
        const node = try std.heap.c_allocator.create(Inode);
        errdefer std.heap.c_allocator.destroy(node);
        node.* = .{
            .id = self.next_id,
            .parent = parent,
            .name = @splat(0),
            .path = @splat(0),
            .kind = kind,
            .cached_info = null,
            .lookup_count = 0,
            .open_count = 0,
            .linked = true,
            .next = self.nodes,
        };
        self.next_id += 1;
        @memcpy(node.name[0..name.len], name);
        try setNodePath(node);
        self.nodes = node;
        return node;
    }

    fn maybeRemove(self: *MountState, target: *Inode) void {
        if (target.id == c.FUSE_ROOT_ID or target.linked or
            target.lookup_count != 0 or target.open_count != 0) return;
        var child = self.nodes;
        while (child) |node| : (child = node.next) {
            if (node.parent == target) return;
        }
        var link = &self.nodes;
        while (link.*) |node| {
            if (node == target) {
                const parent = node.parent;
                link.* = node.next;
                std.heap.c_allocator.destroy(node);
                if (parent) |value| self.maybeRemove(value);
                return;
            }
            link = &node.next;
        }
    }

    fn updateDescendantPaths(self: *MountState, parent: *Inode) !void {
        var current = self.nodes;
        while (current) |node| : (current = node.next) {
            if (node.linked and node.parent == parent) {
                try setNodePath(node);
                try self.updateDescendantPaths(node);
            }
        }
    }

    fn validateDescendantPaths(self: *MountState, source: *Inode, new_path: []const u8) !void {
        const old_path_length = std.mem.sliceTo(&source.path, 0).len;
        var current = self.nodes;
        while (current) |node| : (current = node.next) {
            if (!node.linked or node == source or !isDescendant(node, source)) continue;
            const path_length = std.mem.sliceTo(&node.path, 0).len;
            if (new_path.len + path_length - old_path_length >= path_capacity)
                return error.NameTooLong;
        }
    }

    fn findOpenFile(self: *MountState, inode: *Inode) ?*FuseFileHandle {
        var current = self.open_files;
        while (current) |handle| : (current = handle.next) {
            if (handle.inode == inode) return handle;
        }
        return null;
    }

    fn unregisterOpenFile(self: *MountState, target: *FuseFileHandle) void {
        var link = &self.open_files;
        while (link.*) |handle| {
            if (handle == target) {
                link.* = handle.next;
                return;
            }
            link = &handle.next;
        }
    }
};

const FuseFileHandle = struct {
    file: volume_mod.FileHandle,
    inode: *Inode,
    append: bool,
    next: ?*FuseFileHandle,
};

const FuseDirectoryHandle = struct {
    directory: volume_mod.DirectoryHandle,
    inode: *Inode,
};

pub fn mount(volume: *volume_mod.Volume, mountpoint: []const u8) !void {
    const allocator = std.heap.c_allocator;
    const program = try allocator.dupeZ(u8, "devdrive");
    defer allocator.free(program);
    const foreground = try allocator.dupeZ(u8, "-f");
    defer allocator.free(foreground);
    const single_thread = try allocator.dupeZ(u8, "-s");
    defer allocator.free(single_thread);
    const option = try allocator.dupeZ(u8, "-o");
    defer allocator.free(option);
    const permissions = try allocator.dupeZ(u8, "default_permissions");
    defer allocator.free(permissions);
    const mountpoint_z = try allocator.dupeZ(u8, mountpoint);
    defer allocator.free(mountpoint_z);

    var state = try MountState.init(volume);
    defer state.deinit();
    var argv = [_][*c]u8{
        program.ptr,
        foreground.ptr,
        single_thread.ptr,
        option.ptr,
        permissions.ptr,
        mountpoint_z.ptr,
    };
    var operations: c.struct_fuse_lowlevel_ops = std.mem.zeroes(c.struct_fuse_lowlevel_ops);
    operations.lookup = lookup;
    operations.forget = forget;
    operations.getattr = getAttr;
    operations.setattr = setAttr;
    operations.readlink = readLink;
    operations.mkdir = makeDirectory;
    operations.unlink = unlink;
    operations.rmdir = removeDirectory;
    operations.symlink = makeSymlink;
    operations.rename = rename;
    operations.open = open;
    operations.read = read;
    operations.write = write;
    operations.statfs = statFs;
    operations.flush = flush;
    operations.release = release;
    operations.fsync = fsync;
    operations.opendir = openDirectory;
    operations.readdir = readDirectory;
    operations.releasedir = releaseDirectory;
    operations.create = create;

    const result = c.devdrive_fuse_main(argv.len, &argv, &operations, &state);
    if (result != 0) return error.FuseMountFailed;
}

pub fn unmount(allocator: std.mem.Allocator, io: Io, mountpoint: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "fusermount3", "-u", mountpoint },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.FuseUnmountFailed,
        else => return error.FuseUnmountFailed,
    }
}

fn stateFor(req: c.fuse_req_t) *MountState {
    return @ptrCast(@alignCast(c.fuse_req_userdata(req).?));
}

fn lookup(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    joinPath(&path, parent, name) catch |err| return replyError(req, errnoValue(err));
    const info = state.volume.stat(&path) catch |err| return replyError(req, errnoValue(err));
    const node = state.findChild(parent, name) orelse
        state.addNode(parent, name, info.metadata.kind) catch |err| return replyError(req, errnoValue(err));
    node.kind = info.metadata.kind;
    node.cached_info = info;
    node.lookup_count += 1;
    replyEntry(req, node, info);
}

fn forget(req: c.fuse_req_t, id: c.fuse_ino_t, count: u64) callconv(.c) void {
    const state = stateFor(req);
    if (state.find(id)) |node| {
        node.lookup_count = node.lookup_count -| count;
        state.maybeRemove(node);
    }
    c.fuse_reply_none(req);
}

fn getAttr(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    const info = if (fi) |file_info| value: {
        if (node.kind == .file) {
            const handle = fuseFileHandle(file_info);
            break :value state.volume.statFile(&handle.file) catch |err| return replyError(req, errnoValue(err));
        }
        if (!node.linked)
            break :value node.cached_info orelse return replyError(req, c.ENOENT);
        break :value state.volume.stat(&node.path) catch |err| return replyError(req, errnoValue(err));
    } else value: {
        if (!node.linked) {
            if (state.findOpenFile(node)) |handle|
                break :value state.volume.statFile(&handle.file) catch |err| return replyError(req, errnoValue(err));
            break :value node.cached_info orelse return replyError(req, c.ENOENT);
        }
        break :value state.volume.stat(&node.path) catch |err| return replyError(req, errnoValue(err));
    };
    node.kind = info.metadata.kind;
    node.cached_info = info;
    var stat: c.struct_stat = undefined;
    fillStat(&stat, node, info);
    _ = c.fuse_reply_attr(req, &stat, cache_timeout);
}

fn setAttr(req: c.fuse_req_t, id: c.fuse_ino_t, attr: ?*c.struct_stat, to_set: c_int, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    const value = attr.?;
    const metadata_mask = c.FUSE_SET_ATTR_MODE | c.FUSE_SET_ATTR_UID | c.FUSE_SET_ATTR_GID |
        c.FUSE_SET_ATTR_ATIME | c.FUSE_SET_ATTR_MTIME | c.FUSE_SET_ATTR_ATIME_NOW | c.FUSE_SET_ATTR_MTIME_NOW;

    if (fi) |file_info| {
        if (node.kind != .file) return replyError(req, c.EISDIR);
        const handle = fuseFileHandle(file_info);
        if (to_set & c.FUSE_SET_ATTR_SIZE != 0) {
            if (value.st_size < 0) return replyError(req, c.EINVAL);
            state.volume.truncateFile(&handle.file, @intCast(value.st_size)) catch |err|
                return replyError(req, errnoValue(err));
        }
        if (to_set & metadata_mask != 0) {
            applyMetadata(&handle.file.metadata, value, to_set, state.volume.io);
            state.volume.persistMetadata(&handle.file) catch |err| return replyError(req, errnoValue(err));
        }
        if (to_set & c.FUSE_SET_ATTR_SIZE != 0)
            state.volume.syncFile(&handle.file) catch |err| return replyError(req, errnoValue(err));
        const info = state.volume.statFile(&handle.file) catch |err| return replyError(req, errnoValue(err));
        node.cached_info = info;
        var stat: c.struct_stat = undefined;
        fillStat(&stat, node, info);
        _ = c.fuse_reply_attr(req, &stat, cache_timeout);
        return;
    }

    if (!node.linked) return replyError(req, c.ENOENT);
    if (to_set & c.FUSE_SET_ATTR_SIZE != 0) {
        if (value.st_size < 0) return replyError(req, c.EINVAL);
        var handle: volume_mod.FileHandle = undefined;
        state.volume.openFile(&handle, &node.path, lfs.LFS_O_RDWR, 0, 0, 0) catch |err|
            return replyError(req, errnoValue(err));
        var open_handle = true;
        defer if (open_handle) state.volume.closeFile(&handle) catch {};
        state.volume.truncateFile(&handle, @intCast(value.st_size)) catch |err|
            return replyError(req, errnoValue(err));
        if (to_set & metadata_mask != 0) {
            applyMetadata(&handle.metadata, value, to_set, state.volume.io);
            state.volume.persistMetadata(&handle) catch |err| return replyError(req, errnoValue(err));
        }
        state.volume.syncFile(&handle) catch |err| return replyError(req, errnoValue(err));
        state.volume.closeFile(&handle) catch |err| return replyError(req, errnoValue(err));
        open_handle = false;
    } else if (to_set & metadata_mask != 0) {
        var info = state.volume.stat(&node.path) catch |err| return replyError(req, errnoValue(err));
        applyMetadata(&info.metadata, value, to_set, state.volume.io);
        state.volume.setMetadata(&node.path, info.metadata) catch |err| return replyError(req, errnoValue(err));
    }
    const info = state.volume.stat(&node.path) catch |err| return replyError(req, errnoValue(err));
    node.cached_info = info;
    var stat: c.struct_stat = undefined;
    fillStat(&stat, node, info);
    _ = c.fuse_reply_attr(req, &stat, cache_timeout);
}

fn readLink(req: c.fuse_req_t, id: c.fuse_ino_t) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    if (!node.linked) return replyError(req, c.ENOENT);
    const info = state.volume.stat(&node.path) catch |err| return replyError(req, errnoValue(err));
    node.cached_info = info;
    if (info.metadata.kind != .symlink) return replyError(req, c.EINVAL);
    var handle: volume_mod.FileHandle = undefined;
    state.volume.openFile(&handle, &node.path, lfs.LFS_O_RDONLY, 0, 0, 0) catch |err|
        return replyError(req, errnoValue(err));
    defer state.volume.closeFile(&handle) catch {};
    var buffer: [path_capacity:0]u8 = @splat(0);
    const amount = state.volume.readFile(&handle, buffer[0..path_capacity], 0) catch |err|
        return replyError(req, errnoValue(err));
    if (amount == path_capacity) return replyError(req, c.ENAMETOOLONG);
    buffer[amount] = 0;
    _ = c.fuse_reply_readlink(req, &buffer);
}

fn makeDirectory(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8, mode: c.mode_t) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    joinPath(&path, parent, name) catch |err| return replyError(req, errnoValue(err));
    const context = c.fuse_req_ctx(req).?;
    const permissions = @as(u32, mode) & ~@as(u32, context[0].umask);
    state.volume.makeDirectory(&path, permissions | 0o040000, context[0].uid, context[0].gid) catch |err|
        return replyError(req, errnoValue(err));
    const node = state.addNode(parent, name, .directory) catch |err| {
        state.volume.remove(&path) catch {};
        return replyError(req, errnoValue(err));
    };
    const info = state.volume.stat(&node.path) catch |err| return replyError(req, errnoValue(err));
    node.cached_info = info;
    node.lookup_count = 1;
    replyEntry(req, node, info);
}

fn unlink(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8) callconv(.c) void {
    removeNode(req, parent_id, name_raw, false);
}

fn removeDirectory(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8) callconv(.c) void {
    removeNode(req, parent_id, name_raw, true);
}

fn removeNode(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8, directory: bool) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    joinPath(&path, parent, name) catch |err| return replyError(req, errnoValue(err));
    const info = state.volume.stat(&path) catch |err| return replyError(req, errnoValue(err));
    if (directory and info.metadata.kind != .directory) return replyError(req, c.ENOTDIR);
    if (!directory and info.metadata.kind == .directory) return replyError(req, c.EISDIR);
    state.volume.remove(&path) catch |err| return replyError(req, errnoValue(err));
    if (state.findChild(parent, name)) |node| {
        node.linked = false;
        state.maybeRemove(node);
    }
    replyError(req, 0);
}

fn makeSymlink(req: c.fuse_req_t, target_raw: ?[*:0]const u8, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    joinPath(&path, parent, name) catch |err| return replyError(req, errnoValue(err));
    const context = c.fuse_req_ctx(req).?;
    var handle: volume_mod.FileHandle = undefined;
    state.volume.openFile(&handle, &path, lfs.LFS_O_CREAT | lfs.LFS_O_EXCL | lfs.LFS_O_WRONLY, 0o120777, context[0].uid, context[0].gid) catch |err|
        return replyError(req, errnoValue(err));
    handle.metadata.kind = .symlink;
    state.volume.persistMetadata(&handle) catch |err| {
        state.volume.closeFile(&handle) catch {};
        state.volume.remove(&path) catch {};
        return replyError(req, errnoValue(err));
    };
    const target = std.mem.span(target_raw.?);
    _ = state.volume.writeFile(&handle, target, 0) catch |err| {
        state.volume.closeFile(&handle) catch {};
        state.volume.remove(&path) catch {};
        return replyError(req, errnoValue(err));
    };
    state.volume.closeFile(&handle) catch |err| return replyError(req, errnoValue(err));
    const node = state.addNode(parent, name, .symlink) catch |err| {
        state.volume.remove(&path) catch {};
        return replyError(req, errnoValue(err));
    };
    const info = state.volume.stat(&node.path) catch |err| return replyError(req, errnoValue(err));
    node.lookup_count = 1;
    replyEntry(req, node, info);
}

fn rename(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8, new_parent_id: c.fuse_ino_t, new_name_raw: ?[*:0]const u8, flags: c_uint) callconv(.c) void {
    const rename_noreplace: c_uint = 1;
    if (flags & ~rename_noreplace != 0) return replyError(req, c.EINVAL);
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const new_parent = state.find(new_parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    const new_name = std.mem.span(new_name_raw.?);
    var old_path: [path_capacity:0]u8 = @splat(0);
    var new_path: [path_capacity:0]u8 = @splat(0);
    joinPath(&old_path, parent, name) catch |err| return replyError(req, errnoValue(err));
    joinPath(&new_path, new_parent, new_name) catch |err| return replyError(req, errnoValue(err));
    if (flags & rename_noreplace != 0) {
        if (state.volume.stat(&new_path)) |_| {
            return replyError(req, c.EEXIST);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return replyError(req, errnoValue(err)),
        }
    }
    const source = state.findChild(parent, name);
    const target = state.findChild(new_parent, new_name);
    if (source) |node| {
        if (new_name.len >= name_capacity) return replyError(req, c.ENAMETOOLONG);
        state.validateDescendantPaths(node, std.mem.sliceTo(&new_path, 0)) catch |err|
            return replyError(req, errnoValue(err));
    }
    state.volume.rename(&old_path, &new_path) catch |err| return replyError(req, errnoValue(err));
    if (target) |node| {
        if (node != source) {
            node.linked = false;
            state.maybeRemove(node);
        }
    }
    if (source) |node| {
        node.parent = new_parent;
        node.name = @splat(0);
        @memcpy(node.name[0..new_name.len], new_name);
        setNodePath(node) catch return replyError(req, c.ENAMETOOLONG);
        state.updateDescendantPaths(node) catch return replyError(req, c.ENAMETOOLONG);
    }
    replyError(req, 0);
}

fn open(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    if (!node.linked) return replyError(req, c.ENOENT);
    if (node.kind == .directory) return replyError(req, c.EISDIR);
    openInternal(req, state, node, fi.?, false, 0);
}

fn create(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8, mode: c.mode_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    const node = state.addNode(parent, name, .file) catch |err| return replyError(req, errnoValue(err));
    openInternal(req, state, node, fi.?, true, mode);
    if (node.open_count == 0) {
        node.linked = false;
        state.maybeRemove(node);
    }
}

fn openInternal(req: c.fuse_req_t, state: *MountState, node: *Inode, fi: *c.struct_fuse_file_info, create_file: bool, mode: c.mode_t) void {
    const handle = std.heap.c_allocator.create(FuseFileHandle) catch return replyError(req, c.ENOMEM);
    const context = c.fuse_req_ctx(req).?;
    const host_flags = c.devdrive_fuse_get_flags(fi);
    handle.append = host_flags & c.O_APPEND != 0;
    var flags: c_int = switch (host_flags & 3) {
        0 => lfs.LFS_O_RDONLY,
        else => lfs.LFS_O_RDWR,
    };
    if (handle.append) flags |= lfs.LFS_O_APPEND;
    if (create_file) flags |= lfs.LFS_O_CREAT | lfs.LFS_O_EXCL;
    if (!create_file and host_flags & c.O_TRUNC != 0) flags |= lfs.LFS_O_TRUNC;
    const permissions = @as(u32, mode) & ~@as(u32, context[0].umask);
    state.volume.openFile(&handle.file, &node.path, flags, permissions | 0o100000, context[0].uid, context[0].gid) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    handle.inode = node;
    handle.next = state.open_files;
    state.open_files = handle;
    node.open_count += 1;
    c.devdrive_fuse_set_handle(fi, @intFromPtr(handle));
    c.devdrive_fuse_set_direct_io(fi);
    if (create_file) {
        const info = state.volume.statFile(&handle.file) catch |err| {
            state.volume.closeFile(&handle.file) catch {};
            state.unregisterOpenFile(handle);
            node.open_count -= 1;
            std.heap.c_allocator.destroy(handle);
            return replyError(req, errnoValue(err));
        };
        node.cached_info = info;
        node.lookup_count = 1;
        var entry: c.struct_fuse_entry_param = undefined;
        fillEntry(&entry, node, info);
        _ = c.fuse_reply_create(req, &entry, fi);
    } else {
        _ = c.fuse_reply_open(req, fi);
    }
}

fn read(req: c.fuse_req_t, id: c.fuse_ino_t, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (offset < 0) return replyError(req, c.EINVAL);
    const buffer = std.heap.c_allocator.alloc(u8, size) catch return replyError(req, c.ENOMEM);
    defer std.heap.c_allocator.free(buffer);
    const handle = fuseFileHandle(fi.?);
    const amount = stateFor(req).volume.readFile(&handle.file, buffer, @intCast(offset)) catch |err|
        return replyError(req, errnoValue(err));
    _ = c.fuse_reply_buf(req, buffer.ptr, amount);
}

fn write(req: c.fuse_req_t, id: c.fuse_ino_t, data_raw: ?[*]const u8, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (offset < 0) return replyError(req, c.EINVAL);
    const handle = fuseFileHandle(fi.?);
    const amount = if (handle.append)
        stateFor(req).volume.writeFile(&handle.file, data_raw.?[0..size], 0) catch |err| return replyError(req, errnoValue(err))
    else
        stateFor(req).volume.writeFile(&handle.file, data_raw.?[0..size], @intCast(offset)) catch |err| return replyError(req, errnoValue(err));
    _ = c.fuse_reply_write(req, amount);
}

fn statFs(req: c.fuse_req_t, id: c.fuse_ino_t) callconv(.c) void {
    _ = id;
    const volume = stateFor(req).volume;
    const used = volume.usedBlocks() catch |err| return replyError(req, errnoValue(err));
    var stat: c.struct_statvfs = std.mem.zeroes(c.struct_statvfs);
    stat.f_bsize = volume.header.block_size;
    stat.f_frsize = volume.header.block_size;
    stat.f_blocks = volume.header.block_count;
    stat.f_bfree = volume.header.block_count - used;
    stat.f_bavail = stat.f_bfree;
    stat.f_namemax = volume.header.name_max;
    _ = c.fuse_reply_statfs(req, &stat);
}

fn flush(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    const handle = fuseFileHandle(fi.?);
    stateFor(req).volume.syncFile(&handle.file) catch |err| return replyError(req, errnoValue(err));
    replyError(req, 0);
}

fn fsync(req: c.fuse_req_t, id: c.fuse_ino_t, datasync: c_int, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = datasync;
    flush(req, id, fi);
}

fn release(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    const state = stateFor(req);
    const handle = fuseFileHandle(fi.?);
    const node = handle.inode;
    const result = state.volume.closeFile(&handle.file);
    state.unregisterOpenFile(handle);
    node.open_count -= 1;
    std.heap.c_allocator.destroy(handle);
    state.maybeRemove(node);
    result catch |err| return replyError(req, errnoValue(err));
    replyError(req, 0);
}

fn openDirectory(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    if (!node.linked) return replyError(req, c.ENOENT);
    if (node.kind != .directory) return replyError(req, c.ENOTDIR);
    const handle = std.heap.c_allocator.create(FuseDirectoryHandle) catch return replyError(req, c.ENOMEM);
    handle.directory = .{};
    state.volume.openDirectory(&handle.directory, &node.path) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    handle.inode = node;
    node.open_count += 1;
    c.devdrive_fuse_set_handle(fi.?, @intFromPtr(handle));
    _ = c.fuse_reply_open(req, fi.?);
}

fn readDirectory(req: c.fuse_req_t, id: c.fuse_ino_t, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (offset < 0 or offset > std.math.maxInt(u32)) return replyError(req, c.EINVAL);
    const state = stateFor(req);
    const handle = fuseDirectoryHandle(fi.?);
    state.volume.seekDirectory(&handle.directory, @intCast(offset)) catch |err|
        return replyError(req, errnoValue(err));
    const buffer = std.heap.c_allocator.alloc(u8, size) catch return replyError(req, c.ENOMEM);
    defer std.heap.c_allocator.free(buffer);
    var used: usize = 0;
    while (true) {
        var info: lfs.struct_lfs_info = undefined;
        const has_entry = state.volume.readDirectory(&handle.directory, &info) catch |err|
            return replyError(req, errnoValue(err));
        if (!has_entry) break;
        const next_offset = state.volume.tellDirectory(&handle.directory) catch |err|
            return replyError(req, errnoValue(err));
        var stat: c.struct_stat = std.mem.zeroes(c.struct_stat);
        stat.st_mode = if (info.type == lfs.LFS_TYPE_DIR) 0o040000 else 0o100000;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
        if (std.mem.eql(u8, name, ".")) {
            stat.st_ino = handle.inode.id;
        } else if (std.mem.eql(u8, name, "..")) {
            stat.st_ino = if (handle.inode.parent) |parent| parent.id else c.FUSE_ROOT_ID;
        } else if (state.findChild(handle.inode, name)) |node| {
            stat.st_ino = node.id;
            stat.st_mode = kindMode(node.kind);
        }
        const needed = c.fuse_add_direntry(req, buffer.ptr + used, size - used, @ptrCast(&info.name), &stat, next_offset);
        if (needed > size - used) break;
        used += needed;
    }
    _ = c.fuse_reply_buf(req, buffer.ptr, used);
}

fn releaseDirectory(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    const state = stateFor(req);
    const handle = fuseDirectoryHandle(fi.?);
    const node = handle.inode;
    const result = state.volume.closeDirectory(&handle.directory);
    node.open_count -= 1;
    std.heap.c_allocator.destroy(handle);
    state.maybeRemove(node);
    result catch |err| return replyError(req, errnoValue(err));
    replyError(req, 0);
}

fn setNodePath(node: *Inode) !void {
    const parent = node.parent orelse return;
    try joinPath(&node.path, parent, std.mem.sliceTo(&node.name, 0));
}

fn isDescendant(node: *const Inode, ancestor: *const Inode) bool {
    var parent = node.parent;
    while (parent) |current| : (parent = current.parent) {
        if (current == ancestor) return true;
    }
    return false;
}

fn joinPath(output: *[path_capacity:0]u8, parent: *const Inode, name: []const u8) !void {
    const parent_path = std.mem.sliceTo(&parent.path, 0);
    const separator: usize = if (parent_path.len == 1) 0 else 1;
    const length = std.math.add(usize, parent_path.len + separator, name.len) catch return error.NameTooLong;
    if (length >= path_capacity) return error.NameTooLong;
    output.* = @splat(0);
    @memcpy(output[0..parent_path.len], parent_path);
    var cursor = parent_path.len;
    if (separator != 0) {
        output[cursor] = '/';
        cursor += 1;
    }
    @memcpy(output[cursor .. cursor + name.len], name);
}

fn replyEntry(req: c.fuse_req_t, node: *Inode, info: volume_mod.NodeInfo) void {
    node.cached_info = info;
    var entry: c.struct_fuse_entry_param = undefined;
    fillEntry(&entry, node, info);
    _ = c.fuse_reply_entry(req, &entry);
}

fn fillEntry(entry: *c.struct_fuse_entry_param, node: *Inode, info: volume_mod.NodeInfo) void {
    entry.* = std.mem.zeroes(c.struct_fuse_entry_param);
    entry.ino = node.id;
    entry.generation = 1;
    entry.attr_timeout = cache_timeout;
    entry.entry_timeout = cache_timeout;
    fillStat(&entry.attr, node, info);
}

fn fillStat(stat: *c.struct_stat, node: *const Inode, info: volume_mod.NodeInfo) void {
    stat.* = std.mem.zeroes(c.struct_stat);
    stat.st_ino = node.id;
    stat.st_mode = info.metadata.mode;
    stat.st_nlink = if (!node.linked) 0 else if (info.metadata.kind == .directory) 2 else 1;
    stat.st_uid = info.metadata.uid;
    stat.st_gid = info.metadata.gid;
    stat.st_size = @intCast(info.size);
    stat.st_blksize = 4096;
    const blocks = std.math.divCeil(u64, info.allocated_bytes, 512) catch 0;
    stat.st_blocks = std.math.cast(@TypeOf(stat.st_blocks), blocks) orelse
        std.math.maxInt(@TypeOf(stat.st_blocks));
    setTimespec(&stat.st_atim, info.metadata.atime_ns);
    setTimespec(&stat.st_mtim, info.metadata.mtime_ns);
    setTimespec(&stat.st_ctim, info.metadata.ctime_ns);
}

fn kindMode(kind: metadata.Kind) c.mode_t {
    return switch (kind) {
        .directory => 0o040000,
        .symlink => 0o120000,
        .file => 0o100000,
    };
}

fn applyMetadata(value: *metadata.Metadata, stat: *const c.struct_stat, to_set: c_int, io: Io) void {
    if (to_set & c.FUSE_SET_ATTR_MODE != 0)
        value.mode = (value.mode & 0o170000) | (@as(u32, stat.st_mode) & 0o7777);
    if (to_set & c.FUSE_SET_ATTR_UID != 0) value.uid = stat.st_uid;
    if (to_set & c.FUSE_SET_ATTR_GID != 0) value.gid = stat.st_gid;
    if (to_set & c.FUSE_SET_ATTR_ATIME_NOW != 0) {
        value.atime_ns = now(io);
    } else if (to_set & c.FUSE_SET_ATTR_ATIME != 0) {
        value.atime_ns = timespecNs(stat.st_atim);
    }
    if (to_set & c.FUSE_SET_ATTR_MTIME_NOW != 0) {
        value.mtime_ns = now(io);
    } else if (to_set & c.FUSE_SET_ATTR_MTIME != 0) {
        value.mtime_ns = timespecNs(stat.st_mtim);
    }
    value.ctime_ns = now(io);
}

fn timespecNs(value: c.struct_timespec) i64 {
    return @as(i64, @intCast(value.tv_sec)) * std.time.ns_per_s + @as(i64, @intCast(value.tv_nsec));
}

fn setTimespec(value: *c.struct_timespec, ns: i64) void {
    value.tv_sec = @intCast(@divFloor(ns, std.time.ns_per_s));
    value.tv_nsec = @intCast(@mod(ns, std.time.ns_per_s));
}

fn now(io: Io) i64 {
    return @intCast(Io.Clock.real.now(io).nanoseconds);
}

fn fuseFileHandle(file_info: *c.struct_fuse_file_info) *FuseFileHandle {
    return @ptrFromInt(c.devdrive_fuse_get_handle(file_info));
}

fn fuseDirectoryHandle(file_info: *c.struct_fuse_file_info) *FuseDirectoryHandle {
    return @ptrFromInt(c.devdrive_fuse_get_handle(file_info));
}

fn replyError(req: c.fuse_req_t, value: c_int) void {
    _ = c.fuse_reply_err(req, value);
}

fn errnoValue(err: anyerror) c_int {
    return switch (err) {
        error.FileNotFound => c.ENOENT,
        error.PathAlreadyExists => c.EEXIST,
        error.NotDirectory => c.ENOTDIR,
        error.IsDirectory => c.EISDIR,
        error.DirectoryNotEmpty => c.ENOTEMPTY,
        error.FileTooLarge => c.EFBIG,
        error.InvalidArgument, error.InvalidMetadata => c.EINVAL,
        error.NoSpaceLeft => c.ENOSPC,
        error.OutOfMemory => c.ENOMEM,
        error.NameTooLong => c.ENAMETOOLONG,
        error.AccessDenied, error.PermissionDenied => c.EACCES,
        else => c.EIO,
    };
}
