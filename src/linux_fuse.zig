const std = @import("std");
const Io = std.Io;
const volume_mod = @import("volume.zig");
const metadata = @import("metadata.zig");
const object_format = @import("object_format.zig");
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
    identity: object_format.ObjectId,
    object_id: ?object_format.ObjectId,
    kind: metadata.Kind,
    cached_info: ?volume_mod.NodeInfo,
    lookup_count: u64,
    open_count: u64,
    next: ?*Inode,
};

const Dentry = struct {
    parent: *Inode,
    inode: *Inode,
    name: [name_capacity:0]u8,
    path: [path_capacity:0]u8,
    next: ?*Dentry,
};

const MountState = struct {
    volume: *volume_mod.Volume,
    nodes: ?*Inode = null,
    dentries: ?*Dentry = null,
    open_files: ?*FuseFileHandle = null,
    writeback_cache: bool = false,

    fn init(volume: *volume_mod.Volume) !MountState {
        var state = MountState{ .volume = volume };
        const root_info = try volume.stat("/");
        const root = try std.heap.c_allocator.create(Inode);
        root.* = .{
            .id = c.FUSE_ROOT_ID,
            .identity = root_info.identity,
            .object_id = null,
            .kind = .directory,
            .cached_info = root_info,
            .lookup_count = 1,
            .open_count = 0,
            .next = null,
        };
        state.nodes = root;
        return state;
    }

    fn deinit(self: *MountState) void {
        var current_dentry = self.dentries;
        while (current_dentry) |dentry| {
            const next = dentry.next;
            std.heap.c_allocator.destroy(dentry);
            current_dentry = next;
        }
        self.dentries = null;
        var current = self.nodes;
        while (current) |node| {
            const next = node.next;
            if (node.object_id) |object_id| self.volume.unpinObject(object_id) catch {};
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

    fn findChild(self: *MountState, parent: *Inode, name: []const u8) ?*Dentry {
        var current = self.dentries;
        while (current) |dentry| : (current = dentry.next) {
            if (dentry.parent == parent and
                std.mem.eql(u8, std.mem.sliceTo(&dentry.name, 0), name)) return dentry;
        }
        return null;
    }

    fn findIdentity(self: *MountState, identity: object_format.ObjectId) ?*Inode {
        var current = self.nodes;
        while (current) |node| : (current = node.next) {
            if (std.mem.eql(u8, &node.identity, &identity)) return node;
        }
        return null;
    }

    fn addEntry(self: *MountState, parent: *Inode, name: []const u8, info: volume_mod.NodeInfo) !*Dentry {
        if (name.len >= name_capacity) return error.NameTooLong;
        if (self.findChild(parent, name) != null) return error.PathAlreadyExists;
        var new_node = false;
        const node = self.findIdentity(info.identity) orelse value: {
            new_node = true;
            break :value try self.addNode(info);
        };
        errdefer if (new_node) self.maybeRemove(node);
        const dentry = try std.heap.c_allocator.create(Dentry);
        errdefer std.heap.c_allocator.destroy(dentry);
        dentry.* = .{
            .parent = parent,
            .inode = node,
            .name = @splat(0),
            .path = @splat(0),
            .next = self.dentries,
        };
        @memcpy(dentry.name[0..name.len], name);
        try self.setDentryPath(dentry);
        self.dentries = dentry;
        node.kind = info.metadata.kind;
        node.cached_info = info;
        return dentry;
    }

    fn addNode(self: *MountState, info: volume_mod.NodeInfo) !*Inode {
        const id = inodeNumber(info.identity);
        if (self.find(id) != null) return error.CorruptFilesystem;
        const node = try std.heap.c_allocator.create(Inode);
        errdefer std.heap.c_allocator.destroy(node);
        if (info.object_id) |object_id| try self.volume.pinObject(object_id);
        node.* = .{
            .id = id,
            .identity = info.identity,
            .object_id = info.object_id,
            .kind = info.metadata.kind,
            .cached_info = null,
            .lookup_count = 0,
            .open_count = 0,
            .next = self.nodes,
        };
        self.nodes = node;
        return node;
    }

    fn maybeRemove(self: *MountState, target: *Inode) void {
        self.removeUnreferencedNode(target);
        self.pruneCaches();
    }

    fn removeUnreferencedNode(self: *MountState, target: *Inode) void {
        if (target.id == c.FUSE_ROOT_ID or target.lookup_count != 0 or target.open_count != 0 or
            self.hasDentryReference(target)) return;
        var cursor = &self.nodes;
        while (cursor.*) |node| {
            if (node == target) {
                cursor.* = node.next;
                if (node.object_id) |object_id| self.volume.unpinObject(object_id) catch {};
                std.heap.c_allocator.destroy(node);
                return;
            }
            cursor = &node.next;
        }
    }

    fn hasDentryReference(self: *MountState, target: *const Inode) bool {
        var current = self.dentries;
        while (current) |dentry| : (current = dentry.next) {
            if (dentry.inode == target or dentry.parent == target) return true;
        }
        return false;
    }

    fn hasChildren(self: *MountState, target: *const Inode) bool {
        var current = self.dentries;
        while (current) |dentry| : (current = dentry.next) {
            if (dentry.parent == target) return true;
        }
        return false;
    }

    fn pruneCaches(self: *MountState) void {
        while (true) {
            var cursor = &self.dentries;
            var removed = false;
            while (cursor.*) |dentry| {
                if (dentry.inode.lookup_count == 0 and dentry.inode.open_count == 0 and
                    !self.hasChildren(dentry.inode))
                {
                    const inode = dentry.inode;
                    const parent = dentry.parent;
                    cursor.* = dentry.next;
                    std.heap.c_allocator.destroy(dentry);
                    self.removeUnreferencedNode(inode);
                    self.removeUnreferencedNode(parent);
                    removed = true;
                    break;
                }
                cursor = &dentry.next;
            }
            if (removed) continue;

            var current = self.nodes;
            while (current) |node| : (current = node.next) {
                if (node.id != c.FUSE_ROOT_ID and node.lookup_count == 0 and node.open_count == 0 and
                    !self.hasDentryReference(node))
                {
                    self.removeUnreferencedNode(node);
                    removed = true;
                    break;
                }
            }
            if (!removed) return;
        }
    }

    fn removeEntry(self: *MountState, target: *Dentry) void {
        var cursor = &self.dentries;
        while (cursor.*) |dentry| {
            if (dentry == target) {
                cursor.* = dentry.next;
                std.heap.c_allocator.destroy(dentry);
                return;
            }
            cursor = &dentry.next;
        }
    }

    fn updateDescendantPaths(self: *MountState, parent: *Inode) !void {
        var current = self.dentries;
        while (current) |dentry| : (current = dentry.next) {
            if (dentry.parent == parent) {
                try self.setDentryPath(dentry);
                try self.updateDescendantPaths(dentry.inode);
            }
        }
    }

    fn validateDescendantPaths(self: *MountState, source: *Dentry, new_path: []const u8) !void {
        const old_path_length = std.mem.sliceTo(&source.path, 0).len;
        var current = self.dentries;
        while (current) |dentry| : (current = dentry.next) {
            if (dentry == source or !self.isDescendant(dentry, source.inode)) continue;
            const path_length = std.mem.sliceTo(&dentry.path, 0).len;
            if (new_path.len + path_length - old_path_length >= path_capacity)
                return error.NameTooLong;
        }
    }

    fn isDescendant(self: *MountState, dentry: *const Dentry, ancestor: *const Inode) bool {
        var parent: ?*Inode = dentry.parent;
        while (parent) |current| {
            if (current == ancestor) return true;
            const parent_dentry = self.findEntryForInode(current) orelse return false;
            parent = parent_dentry.parent;
        }
        return false;
    }

    fn findEntryForInode(self: *MountState, inode: *const Inode) ?*Dentry {
        var current = self.dentries;
        while (current) |dentry| : (current = dentry.next) {
            if (dentry.inode == inode) return dentry;
        }
        return null;
    }

    fn pathFor(self: *MountState, inode: *const Inode) ?[*:0]const u8 {
        if (inode.id == c.FUSE_ROOT_ID) return "/";
        const dentry = self.findEntryForInode(inode) orelse return null;
        return &dentry.path;
    }

    fn setDentryPath(self: *MountState, dentry: *Dentry) !void {
        const parent_path = self.pathFor(dentry.parent) orelse return error.FileNotFound;
        try joinPath(&dentry.path, std.mem.span(parent_path), std.mem.sliceTo(&dentry.name, 0));
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
    next: ?*FuseFileHandle,
};

const FuseDirectoryHandle = struct {
    directory: volume_mod.DirectoryHandle,
    inode: *Inode,
    parent_id: c.fuse_ino_t,
};

pub fn mount(volume: *volume_mod.Volume, mountpoint: []const u8, allow_other: bool) !void {
    const allocator = std.heap.c_allocator;
    const program = try allocator.dupeZ(u8, "devdrive");
    defer allocator.free(program);
    const foreground = try allocator.dupeZ(u8, "-f");
    defer allocator.free(foreground);
    const single_thread = try allocator.dupeZ(u8, "-s");
    defer allocator.free(single_thread);
    const option = try allocator.dupeZ(u8, "-o");
    defer allocator.free(option);
    const permissions = try allocator.dupeZ(
        u8,
        if (allow_other) "default_permissions,allow_other" else "default_permissions",
    );
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
    operations.init = initialize;
    operations.lookup = lookup;
    operations.forget = forget;
    operations.getattr = getAttr;
    operations.setattr = setAttr;
    operations.readlink = readLink;
    operations.mknod = makeNode;
    operations.mkdir = makeDirectory;
    operations.unlink = unlink;
    operations.rmdir = removeDirectory;
    operations.symlink = makeSymlink;
    operations.rename = rename;
    operations.link = makeLink;
    operations.open = open;
    operations.read = read;
    operations.write = write;
    operations.fallocate = fallocate;
    operations.statfs = statFs;
    operations.flush = flush;
    operations.release = release;
    operations.fsync = fsync;
    operations.opendir = openDirectory;
    operations.readdir = readDirectory;
    operations.releasedir = releaseDirectory;
    operations.fsyncdir = fsyncDirectory;
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

fn initialize(userdata: ?*anyopaque, connection: ?*c.struct_fuse_conn_info) callconv(.c) void {
    const state: *MountState = @ptrCast(@alignCast(userdata.?));
    state.writeback_cache = c.devdrive_fuse_configure_connection(connection.?) != 0;
}

fn lookup(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    const parent_path = state.pathFor(parent) orelse return replyError(req, c.ENOENT);
    joinPath(&path, std.mem.span(parent_path), name) catch |err| return replyError(req, errnoValue(err));
    const info = state.volume.stat(&path) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.findChild(parent, name) orelse
        state.addEntry(parent, name, info) catch |err| return replyError(req, errnoValue(err));
    const node = dentry.inode;
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
        if (node.object_id) |object_id|
            break :value state.volume.statObject(object_id) catch
                node.cached_info orelse return replyError(req, c.ENOENT);
        const path = state.pathFor(node) orelse
            break :value node.cached_info orelse return replyError(req, c.ENOENT);
        break :value state.volume.stat(path) catch |err| return replyError(req, errnoValue(err));
    } else value: {
        if (node.object_id) |object_id|
            break :value state.volume.statObject(object_id) catch
                node.cached_info orelse return replyError(req, c.ENOENT);
        const path = state.pathFor(node) orelse
            break :value node.cached_info orelse return replyError(req, c.ENOENT);
        break :value state.volume.stat(path) catch |err| return replyError(req, errnoValue(err));
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
        if (node.kind == .file) {
            const handle = fuseFileHandle(file_info);
            if (to_set & c.FUSE_SET_ATTR_SIZE != 0) {
                if (value.st_size < 0) return replyError(req, c.EINVAL);
                state.volume.truncateFile(&handle.file, @intCast(value.st_size)) catch |err|
                    return replyError(req, errnoValue(err));
            }
            if (to_set & metadata_mask != 0) {
                _ = state.volume.patchObjectMetadata(
                    handle.file.object_id,
                    metadataPatch(value, to_set, state.volume.io),
                ) catch |err| return replyError(req, errnoValue(err));
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
        if (node.kind != .directory) return replyError(req, c.EOPNOTSUPP);
        if (to_set & c.FUSE_SET_ATTR_SIZE != 0) return replyError(req, c.EISDIR);
        const handle = fuseDirectoryHandle(file_info);
        if (handle.inode != node) return replyError(req, c.EIO);
        const info = patchDirectoryMetadata(state, node, value, to_set) catch |err|
            return replyError(req, errnoValue(err));
        handle.directory.info = info;
        var stat: c.struct_stat = undefined;
        fillStat(&stat, node, info);
        _ = c.fuse_reply_attr(req, &stat, cache_timeout);
        return;
    }

    const info = if (node.object_id) |object_id| value_info: {
        if (to_set & c.FUSE_SET_ATTR_SIZE != 0) {
            if (node.kind != .file) return replyError(req, c.EINVAL);
            if (value.st_size < 0) return replyError(req, c.EINVAL);
            var handle: volume_mod.FileHandle = undefined;
            state.volume.openObject(&handle, object_id, lfs.LFS_O_RDWR) catch |err|
                return replyError(req, errnoValue(err));
            var open_handle = true;
            defer if (open_handle) state.volume.closeFile(&handle) catch {};
            state.volume.truncateFile(&handle, @intCast(value.st_size)) catch |err|
                return replyError(req, errnoValue(err));
            if (to_set & metadata_mask != 0) {
                _ = state.volume.patchObjectMetadata(
                    object_id,
                    metadataPatch(value, to_set, state.volume.io),
                ) catch |err| return replyError(req, errnoValue(err));
            }
            state.volume.syncFile(&handle) catch |err| return replyError(req, errnoValue(err));
            state.volume.closeFile(&handle) catch |err| return replyError(req, errnoValue(err));
            open_handle = false;
        } else if (to_set & metadata_mask != 0) {
            _ = state.volume.patchObjectMetadata(
                object_id,
                metadataPatch(value, to_set, state.volume.io),
            ) catch |err|
                return replyError(req, errnoValue(err));
        }
        break :value_info state.volume.statObject(object_id) catch |err|
            return replyError(req, errnoValue(err));
    } else value_info: {
        if (node.kind == .directory) {
            if (to_set & c.FUSE_SET_ATTR_SIZE != 0) return replyError(req, c.EISDIR);
            break :value_info patchDirectoryMetadata(state, node, value, to_set) catch |err|
                return replyError(req, errnoValue(err));
        }
        const path = state.pathFor(node) orelse return replyError(req, c.ENOENT);
        if (to_set & c.FUSE_SET_ATTR_SIZE != 0) return replyError(req, c.EISDIR);
        if (to_set & metadata_mask != 0) {
            var directory_info = state.volume.stat(path) catch |err|
                return replyError(req, errnoValue(err));
            applyMetadata(&directory_info.metadata, value, to_set, state.volume.io);
            state.volume.setMetadata(path, directory_info.metadata) catch |err|
                return replyError(req, errnoValue(err));
        }
        break :value_info state.volume.stat(path) catch |err| return replyError(req, errnoValue(err));
    };
    node.cached_info = info;
    var stat: c.struct_stat = undefined;
    fillStat(&stat, node, info);
    _ = c.fuse_reply_attr(req, &stat, cache_timeout);
}

fn readLink(req: c.fuse_req_t, id: c.fuse_ino_t) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    const object_id = node.object_id orelse return replyError(req, c.EINVAL);
    const info = state.volume.statObject(object_id) catch |err| return replyError(req, errnoValue(err));
    node.cached_info = info;
    if (info.metadata.kind != .symlink) return replyError(req, c.EINVAL);
    var buffer: [path_capacity:0]u8 = @splat(0);
    const amount = state.volume.readObject(object_id, buffer[0..path_capacity], 0) catch |err|
        return replyError(req, errnoValue(err));
    state.volume.updateAccessTime(object_id) catch {};
    if (amount == path_capacity) return replyError(req, c.ENAMETOOLONG);
    buffer[amount] = 0;
    _ = c.fuse_reply_readlink(req, &buffer);
}

fn makeDirectory(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8, mode: c.mode_t) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    const parent_path = state.pathFor(parent) orelse return replyError(req, c.ENOENT);
    joinPath(&path, std.mem.span(parent_path), name) catch |err| return replyError(req, errnoValue(err));
    const context = c.fuse_req_ctx(req).?;
    const permissions = @as(u32, mode) & ~@as(u32, context[0].umask);
    state.volume.makeDirectory(&path, permissions | 0o040000, context[0].uid, context[0].gid) catch |err|
        return replyError(req, errnoValue(err));
    const info = state.volume.stat(&path) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.addEntry(parent, name, info) catch |err| {
        state.volume.remove(&path) catch {};
        return replyError(req, errnoValue(err));
    };
    const node = dentry.inode;
    node.lookup_count = 1;
    replyEntry(req, node, info);
}

fn makeNode(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8, mode: c.mode_t, rdev: c.dev_t) callconv(.c) void {
    _ = rdev;
    if (@as(u32, mode) & 0o170000 != 0o010000) return replyError(req, c.EOPNOTSUPP);
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const parent_path = state.pathFor(parent) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    joinPath(&path, std.mem.span(parent_path), name) catch |err|
        return replyError(req, errnoValue(err));
    const context = c.fuse_req_ctx(req).?;
    const permissions = @as(u32, mode) & ~@as(u32, context[0].umask);
    state.volume.makeFifo(&path, permissions, context[0].uid, context[0].gid) catch |err|
        return replyError(req, errnoValue(err));
    const info = state.volume.stat(&path) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.addEntry(parent, name, info) catch |err| {
        state.volume.remove(&path) catch {};
        return replyError(req, errnoValue(err));
    };
    dentry.inode.lookup_count += 1;
    replyEntry(req, dentry.inode, info);
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
    const parent_path = state.pathFor(parent) orelse return replyError(req, c.ENOENT);
    joinPath(&path, std.mem.span(parent_path), name) catch |err| return replyError(req, errnoValue(err));
    const info = state.volume.stat(&path) catch |err| return replyError(req, errnoValue(err));
    if (directory and info.metadata.kind != .directory) return replyError(req, c.ENOTDIR);
    if (!directory and info.metadata.kind == .directory) return replyError(req, c.EISDIR);
    state.volume.remove(&path) catch |err| return replyError(req, errnoValue(err));
    if (state.findChild(parent, name)) |dentry| {
        if (dentry.inode.cached_info) |*cached| {
            cached.nlink = if (directory) 0 else info.nlink -| 1;
            if (directory) cached.metadata.ctime_ns = now(state.volume.io);
        }
        state.removeEntry(dentry);
    }
    state.pruneCaches();
    replyError(req, 0);
}

fn makeSymlink(req: c.fuse_req_t, target_raw: ?[*:0]const u8, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    const parent_path = state.pathFor(parent) orelse return replyError(req, c.ENOENT);
    joinPath(&path, std.mem.span(parent_path), name) catch |err| return replyError(req, errnoValue(err));
    const context = c.fuse_req_ctx(req).?;
    const target = std.mem.span(target_raw.?);
    state.volume.makeSymlink(&path, target, context[0].uid, context[0].gid) catch |err|
        return replyError(req, errnoValue(err));
    const info = state.volume.stat(&path) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.addEntry(parent, name, info) catch |err| {
        state.volume.remove(&path) catch {};
        return replyError(req, errnoValue(err));
    };
    const node = dentry.inode;
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
    if (parent == new_parent and std.mem.eql(u8, name, new_name)) return replyError(req, 0);
    var old_path: [path_capacity:0]u8 = @splat(0);
    var new_path: [path_capacity:0]u8 = @splat(0);
    const parent_path = state.pathFor(parent) orelse return replyError(req, c.ENOENT);
    const new_parent_path = state.pathFor(new_parent) orelse return replyError(req, c.ENOENT);
    joinPath(&old_path, std.mem.span(parent_path), name) catch |err| return replyError(req, errnoValue(err));
    joinPath(&new_path, std.mem.span(new_parent_path), new_name) catch |err| return replyError(req, errnoValue(err));
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
    if (source) |dentry| {
        if (new_name.len >= name_capacity) return replyError(req, c.ENAMETOOLONG);
        state.validateDescendantPaths(dentry, std.mem.sliceTo(&new_path, 0)) catch |err|
            return replyError(req, errnoValue(err));
    }
    const result = state.volume.renameWithResult(&old_path, &new_path) catch |err|
        return replyError(req, errnoValue(err));
    if (result == .same_object) return replyError(req, 0);
    if (target) |dentry| {
        if (dentry.inode.cached_info) |*cached| {
            cached.nlink = if (dentry.inode.kind == .directory) 0 else cached.nlink -| 1;
            if (dentry.inode.kind == .directory) cached.metadata.ctime_ns = now(state.volume.io);
        }
        state.removeEntry(dentry);
    }
    if (source) |dentry| {
        dentry.parent = new_parent;
        dentry.name = @splat(0);
        @memcpy(dentry.name[0..new_name.len], new_name);
        dentry.path = new_path;
        state.updateDescendantPaths(dentry.inode) catch {};
    }
    state.pruneCaches();
    replyError(req, 0);
}

fn makeLink(req: c.fuse_req_t, id: c.fuse_ino_t, new_parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    if (node.kind == .directory) return replyError(req, c.EPERM);
    const old_path = state.pathFor(node) orelse return replyError(req, c.ENOENT);
    const new_parent = state.find(new_parent_id) orelse return replyError(req, c.ENOENT);
    const new_parent_path = state.pathFor(new_parent) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var new_path: [path_capacity:0]u8 = @splat(0);
    joinPath(&new_path, std.mem.span(new_parent_path), name) catch |err|
        return replyError(req, errnoValue(err));
    const object_id = node.object_id orelse return replyError(req, c.EIO);
    const old_info = state.volume.statObject(object_id) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.addEntry(new_parent, name, old_info) catch |err|
        return replyError(req, errnoValue(err));
    if (dentry.inode != node) {
        state.removeEntry(dentry);
        state.pruneCaches();
        return replyError(req, c.EIO);
    }
    const info = state.volume.linkWithInfo(old_path, &new_path) catch |err| {
        state.removeEntry(dentry);
        state.pruneCaches();
        return replyError(req, errnoValue(err));
    };
    node.lookup_count += 1;
    replyEntry(req, node, info);
}

fn open(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    if (node.kind == .directory) return replyError(req, c.EISDIR);
    if (node.kind != .file) return replyError(req, c.EOPNOTSUPP);
    openInternal(req, state, node, fi.?);
}

fn create(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8, mode: c.mode_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    const parent_path = state.pathFor(parent) orelse return replyError(req, c.ENOENT);
    var path: [path_capacity:0]u8 = @splat(0);
    joinPath(&path, std.mem.span(parent_path), name) catch |err|
        return replyError(req, errnoValue(err));
    const handle = std.heap.c_allocator.create(FuseFileHandle) catch return replyError(req, c.ENOMEM);
    const context = c.fuse_req_ctx(req).?;
    const host_flags = c.devdrive_fuse_get_flags(fi.?);
    var flags: c_int = switch (host_flags & 3) {
        0 => lfs.LFS_O_RDONLY,
        else => lfs.LFS_O_RDWR,
    };
    flags |= lfs.LFS_O_CREAT | lfs.LFS_O_EXCL;
    if (!state.writeback_cache and host_flags & c.O_APPEND != 0) flags |= lfs.LFS_O_APPEND;
    const permissions = @as(u32, mode) & ~@as(u32, context[0].umask);
    state.volume.openFile(&handle.file, &path, flags, permissions | 0o100000, context[0].uid, context[0].gid) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    const info = state.volume.statFile(&handle.file) catch |err| {
        state.volume.closeFile(&handle.file) catch {};
        state.volume.remove(&path) catch {};
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    const dentry = state.addEntry(parent, name, info) catch |err| {
        state.volume.closeFile(&handle.file) catch {};
        state.volume.remove(&path) catch {};
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    const node = dentry.inode;
    handle.inode = node;
    handle.next = state.open_files;
    state.open_files = handle;
    node.open_count += 1;
    node.lookup_count += 1;
    c.devdrive_fuse_set_handle(fi.?, @intFromPtr(handle));
    if (!state.writeback_cache) c.devdrive_fuse_set_direct_io(fi.?);
    var entry: c.struct_fuse_entry_param = undefined;
    fillEntry(&entry, node, info);
    _ = c.fuse_reply_create(req, &entry, fi.?);
}

fn openInternal(req: c.fuse_req_t, state: *MountState, node: *Inode, fi: *c.struct_fuse_file_info) void {
    const handle = std.heap.c_allocator.create(FuseFileHandle) catch return replyError(req, c.ENOMEM);
    const host_flags = c.devdrive_fuse_get_flags(fi);
    const flags: c_int = if (state.writeback_cache)
        lfs.LFS_O_RDWR
    else switch (host_flags & 3) {
        0 => lfs.LFS_O_RDONLY,
        else => lfs.LFS_O_RDWR,
    };
    var open_flags = flags | if (host_flags & c.O_TRUNC != 0) lfs.LFS_O_TRUNC else 0;
    if (!state.writeback_cache and host_flags & c.O_APPEND != 0) open_flags |= lfs.LFS_O_APPEND;
    const object_id = node.object_id orelse {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, c.EIO);
    };
    state.volume.openObject(&handle.file, object_id, open_flags) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    handle.inode = node;
    handle.next = state.open_files;
    state.open_files = handle;
    node.open_count += 1;
    c.devdrive_fuse_set_handle(fi, @intFromPtr(handle));
    if (!state.writeback_cache) c.devdrive_fuse_set_direct_io(fi);
    _ = c.fuse_reply_open(req, fi);
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
    const amount = stateFor(req).volume.writeFile(&handle.file, data_raw.?[0..size], @intCast(offset)) catch |err|
        return replyError(req, errnoValue(err));
    _ = c.fuse_reply_write(req, amount);
}

fn fallocate(req: c.fuse_req_t, id: c.fuse_ino_t, mode: c_int, offset: c.off_t, length: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (mode != 0) return replyError(req, c.EOPNOTSUPP);
    if (offset < 0 or length <= 0) return replyError(req, c.EINVAL);
    const start: u64 = @intCast(offset);
    const amount: u64 = @intCast(length);
    const end = std.math.add(u64, start, amount) catch return replyError(req, c.EFBIG);
    if (end > object_format.max_file_size) return replyError(req, c.EFBIG);
    const handle = fuseFileHandle(fi.?);
    const state = stateFor(req);
    state.volume.fallocateFile(&handle.file, start, amount) catch |err|
        return replyError(req, errnoValue(err));
    state.volume.syncFile(&handle.file) catch |err| return replyError(req, errnoValue(err));
    const info = state.volume.statFile(&handle.file) catch |err| return replyError(req, errnoValue(err));
    handle.inode.cached_info = info;
    replyError(req, 0);
}

fn statFs(req: c.fuse_req_t, id: c.fuse_ino_t) callconv(.c) void {
    _ = id;
    const volume = stateFor(req).volume;
    const available = volume.availableBlocks() catch |err| return replyError(req, errnoValue(err));
    var stat: c.struct_statvfs = std.mem.zeroes(c.struct_statvfs);
    stat.f_bsize = volume.header.block_size;
    stat.f_frsize = volume.header.block_size;
    stat.f_blocks = volume.header.block_count;
    stat.f_bfree = available;
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
    if (node.kind != .directory) return replyError(req, c.ENOTDIR);
    const path = state.pathFor(node) orelse return replyError(req, c.ENOENT);
    const handle = std.heap.c_allocator.create(FuseDirectoryHandle) catch return replyError(req, c.ENOMEM);
    handle.directory = .{};
    state.volume.openDirectory(&handle.directory, path) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    handle.inode = node;
    handle.parent_id = if (state.findEntryForInode(node)) |dentry| dentry.parent.id else c.FUSE_ROOT_ID;
    node.cached_info = handle.directory.info;
    node.open_count += 1;
    c.devdrive_fuse_set_handle(fi.?, @intFromPtr(handle));
    _ = c.fuse_reply_open(req, fi.?);
}

fn readDirectory(req: c.fuse_req_t, id: c.fuse_ino_t, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (offset < 0 or offset > std.math.maxInt(u32)) return replyError(req, c.EINVAL);
    const state = stateFor(req);
    defer state.pruneCaches();
    const handle = fuseDirectoryHandle(fi.?);
    updateDirectoryAccessTime(state, handle) catch {};
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
            stat.st_ino = if (state.findEntryForInode(handle.inode)) |dentry|
                dentry.parent.id
            else
                handle.parent_id;
        } else {
            const dentry = state.findChild(handle.inode, name) orelse value: {
                const directory_path = state.pathFor(handle.inode) orelse return replyError(req, c.ENOENT);
                var child_path: [path_capacity:0]u8 = @splat(0);
                joinPath(&child_path, std.mem.span(directory_path), name) catch |err|
                    return replyError(req, errnoValue(err));
                const child_info = state.volume.stat(&child_path) catch |err|
                    return replyError(req, errnoValue(err));
                break :value state.addEntry(handle.inode, name, child_info) catch |err|
                    return replyError(req, errnoValue(err));
            };
            stat.st_ino = dentry.inode.id;
            stat.st_mode = kindMode(dentry.inode.kind);
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

fn fsyncDirectory(req: c.fuse_req_t, id: c.fuse_ino_t, datasync: c_int, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    _ = datasync;
    _ = fi;
    stateFor(req).volume.sync() catch |err| return replyError(req, errnoValue(err));
    replyError(req, 0);
}

fn currentDirectoryInfo(state: *MountState, node: *Inode) !volume_mod.NodeInfo {
    if (state.pathFor(node)) |path| {
        const info = try state.volume.stat(path);
        if (!std.mem.eql(u8, &info.identity, &node.identity)) return error.CorruptFilesystem;
        return info;
    }
    return node.cached_info orelse error.FileNotFound;
}

fn patchDirectoryMetadata(
    state: *MountState,
    node: *Inode,
    stat: *const c.struct_stat,
    to_set: c_int,
) !volume_mod.NodeInfo {
    var info = try currentDirectoryInfo(state, node);
    const metadata_mask = c.FUSE_SET_ATTR_MODE | c.FUSE_SET_ATTR_UID | c.FUSE_SET_ATTR_GID |
        c.FUSE_SET_ATTR_ATIME | c.FUSE_SET_ATTR_MTIME | c.FUSE_SET_ATTR_ATIME_NOW | c.FUSE_SET_ATTR_MTIME_NOW;
    if (to_set & metadata_mask != 0) {
        applyMetadata(&info.metadata, stat, to_set, state.volume.io);
        if (state.pathFor(node)) |path| try state.volume.setMetadata(path, info.metadata);
    }
    node.cached_info = info;
    return info;
}

fn updateDirectoryAccessTime(state: *MountState, handle: *FuseDirectoryHandle) !void {
    var info = try currentDirectoryInfo(state, handle.inode);
    info.metadata.atime_ns = now(state.volume.io);
    if (state.pathFor(handle.inode)) |path| try state.volume.setMetadata(path, info.metadata);
    handle.directory.info = info;
    handle.inode.cached_info = info;
}

fn joinPath(output: *[path_capacity:0]u8, parent_path: []const u8, name: []const u8) !void {
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

fn inodeNumber(identity: object_format.ObjectId) c.fuse_ino_t {
    var id: c.fuse_ino_t = std.mem.readInt(u64, identity[0..8], .little);
    if (id == 0 or id == c.FUSE_ROOT_ID) id +%= 2;
    return id;
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
    stat.st_nlink = std.math.cast(@TypeOf(stat.st_nlink), info.nlink) orelse
        std.math.maxInt(@TypeOf(stat.st_nlink));
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
        .fifo => 0o010000,
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

fn metadataPatch(stat: *const c.struct_stat, to_set: c_int, io: Io) metadata.Patch {
    var patch: metadata.Patch = .{};
    if (to_set & c.FUSE_SET_ATTR_MODE != 0) patch.mode = @as(u32, stat.st_mode) & 0o7777;
    if (to_set & c.FUSE_SET_ATTR_UID != 0) patch.uid = stat.st_uid;
    if (to_set & c.FUSE_SET_ATTR_GID != 0) patch.gid = stat.st_gid;
    if (to_set & c.FUSE_SET_ATTR_ATIME_NOW != 0) {
        patch.atime_ns = now(io);
    } else if (to_set & c.FUSE_SET_ATTR_ATIME != 0) {
        patch.atime_ns = timespecNs(stat.st_atim);
    }
    if (to_set & c.FUSE_SET_ATTR_MTIME_NOW != 0) {
        patch.mtime_ns = now(io);
    } else if (to_set & c.FUSE_SET_ATTR_MTIME != 0) {
        patch.mtime_ns = timespecNs(stat.st_mtim);
    }
    return patch;
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
        error.TooManyLinks => c.EMLINK,
        error.AccessDenied, error.PermissionDenied => c.EACCES,
        error.UnsupportedOperation => c.EOPNOTSUPP,
        else => c.EIO,
    };
}
