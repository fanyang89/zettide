const std = @import("std");
const Io = std.Io;
const storage_engine = @import("zettide_storage");
const filesystem_backend = storage_engine.filesystem_backend;
const metadata = storage_engine.metadata;

const Filesystem = filesystem_backend.Filesystem;
const NodeInfo = filesystem_backend.NodeInfo;
const FileId = filesystem_backend.FileId;
const FileHandle = filesystem_backend.FileHandle;
const DirectoryHandle = filesystem_backend.DirectoryHandle;

const c = @import("linux_c");

const path_capacity = 4096;
const name_capacity = 256;
const cache_timeout = 1.0;
const async_read_probe_interval = 32;

pub const OperationMetrics = struct {
    calls: u64 = 0,
    bytes: u64 = 0,
    errors: u64 = 0,
    elapsed_ns: u64 = 0,
    max_ns: u64 = 0,
};

pub const Metrics = struct {
    read: OperationMetrics = .{},
    write: OperationMetrics = .{},
    flush: OperationMetrics = .{},
    fsync: OperationMetrics = .{},
    release: OperationMetrics = .{},
};

const Inode = struct {
    id: c.fuse_ino_t,
    identity: FileId,
    file_id: ?FileId,
    kind: metadata.Kind,
    cached_info: ?NodeInfo,
    lookup_count: u64,
    open_count: u64,
    children: std.StringHashMapUnmanaged(*Dentry),
    dentries: ?*Dentry,
    previous: ?*Inode,
    next: ?*Inode,
};

const Dentry = struct {
    parent: *Inode,
    inode: *Inode,
    name: [name_capacity:0]u8,
    path: [path_capacity:0]u8,
    inode_previous: ?*Dentry,
    inode_next: ?*Dentry,
    previous: ?*Dentry,
    next: ?*Dentry,
};

const MountState = struct {
    filesystem: Filesystem,
    io: Io,
    read_only: bool,
    update_access_time: bool,
    async_read_size: ?usize,
    nodes: ?*Inode = null,
    node_index: std.AutoHashMapUnmanaged(c.fuse_ino_t, *Inode) = .empty,
    dentries: ?*Dentry = null,
    open_files: ?*FuseFileHandle = null,
    open_directories: ?*FuseDirectoryHandle = null,
    reply_buffer: std.ArrayList(u8) = .empty,
    read_group: Io.Group = .init,
    async_read_sequence: std.atomic.Value(u32) = .init(0),
    async_reads_inflight: std.atomic.Value(u32) = .init(0),
    metrics_mutex: Io.Mutex = .init,
    writeback_cache: bool = false,
    metrics: ?*Metrics,

    fn init(
        filesystem: Filesystem,
        io: Io,
        read_only: bool,
        update_access_time: bool,
        async_read_size: ?usize,
        metrics: ?*Metrics,
    ) !MountState {
        var state = MountState{
            .filesystem = filesystem,
            .io = io,
            .read_only = read_only,
            .update_access_time = update_access_time,
            .async_read_size = async_read_size,
            .metrics = metrics,
        };
        errdefer state.node_index.deinit(std.heap.c_allocator);
        const root_info = try filesystem.statPath("/");
        const root = try std.heap.c_allocator.create(Inode);
        errdefer std.heap.c_allocator.destroy(root);
        try state.node_index.ensureUnusedCapacity(std.heap.c_allocator, 1);
        root.* = .{
            .id = c.FUSE_ROOT_ID,
            .identity = root_info.identity,
            .file_id = null,
            .kind = .directory,
            .cached_info = root_info,
            .lookup_count = 1,
            .open_count = 0,
            .children = .empty,
            .dentries = null,
            .previous = null,
            .next = null,
        };
        state.node_index.putAssumeCapacityNoClobber(root.id, root);
        state.nodes = root;
        return state;
    }

    fn deinit(self: *MountState) void {
        self.drainReads();
        while (self.open_files) |handle| {
            self.open_files = handle.next;
            handle.file.close() catch {};
            handle.inode.open_count -= 1;
            std.heap.c_allocator.destroy(handle);
        }
        while (self.open_directories) |handle| {
            self.open_directories = handle.next;
            handle.directory.close() catch {};
            handle.inode.open_count -= 1;
            std.heap.c_allocator.destroy(handle);
        }
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
            if (node.file_id) |file_id| self.filesystem.unpinFile(file_id) catch {};
            node.children.deinit(std.heap.c_allocator);
            std.heap.c_allocator.destroy(node);
            current = next;
        }
        self.nodes = null;
        self.node_index.deinit(std.heap.c_allocator);
        self.reply_buffer.deinit(std.heap.c_allocator);
    }

    fn drainReads(self: *MountState) void {
        self.read_group.await(self.io) catch {};
    }

    fn shouldRunReadAsync(self: *MountState, size: usize) bool {
        if (self.async_read_size != size or self.update_access_time) return false;
        if (self.async_reads_inflight.load(.acquire) != 0) return true;
        const sequence = self.async_read_sequence.fetchAdd(1, .monotonic);
        return sequence % async_read_probe_interval == 0;
    }

    fn find(self: *MountState, id: c.fuse_ino_t) ?*Inode {
        return self.node_index.get(id);
    }

    fn findChild(self: *MountState, parent: *Inode, name: []const u8) ?*Dentry {
        _ = self;
        return parent.children.get(name);
    }

    fn findIdentity(self: *MountState, identity: FileId) ?*Inode {
        const root = self.find(c.FUSE_ROOT_ID).?;
        if (std.mem.eql(u8, &root.identity, &identity)) return root;
        const node = self.find(inodeNumber(identity)) orelse return null;
        return if (std.mem.eql(u8, &node.identity, &identity)) node else null;
    }

    fn addEntry(self: *MountState, parent: *Inode, name: []const u8, info: NodeInfo) !*Dentry {
        if (name.len >= name_capacity) return error.NameTooLong;
        if (self.findChild(parent, name) != null) return error.PathAlreadyExists;
        try parent.children.ensureUnusedCapacity(std.heap.c_allocator, 1);
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
            .inode_previous = null,
            .inode_next = node.dentries,
            .previous = null,
            .next = self.dentries,
        };
        @memcpy(dentry.name[0..name.len], name);
        try self.setDentryPath(dentry);
        parent.children.putAssumeCapacityNoClobber(std.mem.sliceTo(&dentry.name, 0), dentry);
        if (dentry.inode_next) |next| next.inode_previous = dentry;
        node.dentries = dentry;
        if (dentry.next) |next| next.previous = dentry;
        self.dentries = dentry;
        node.kind = info.metadata.kind;
        node.cached_info = info;
        return dentry;
    }

    fn reconcileChild(self: *MountState, parent: *Inode, name: []const u8, info: NodeInfo) !*Dentry {
        if (self.findChild(parent, name)) |existing| {
            if (std.mem.eql(u8, &existing.inode.identity, &info.identity)) {
                existing.inode.kind = info.metadata.kind;
                existing.inode.cached_info = info;
                return existing;
            }
            const stale_inode = existing.inode;
            self.removeEntry(existing);
            self.removeUnreferencedNode(stale_inode);
        }
        return self.addEntry(parent, name, info);
    }

    fn addNode(self: *MountState, info: NodeInfo) !*Inode {
        const id = inodeNumber(info.identity);
        if (self.find(id) != null) return error.CorruptFilesystem;
        try self.node_index.ensureUnusedCapacity(std.heap.c_allocator, 1);
        const node = try std.heap.c_allocator.create(Inode);
        errdefer std.heap.c_allocator.destroy(node);
        if (info.file_id) |file_id| try self.filesystem.pinFile(file_id);
        node.* = .{
            .id = id,
            .identity = info.identity,
            .file_id = info.file_id,
            .kind = info.metadata.kind,
            .cached_info = null,
            .lookup_count = 0,
            .open_count = 0,
            .children = .empty,
            .dentries = null,
            .previous = null,
            .next = self.nodes,
        };
        if (node.next) |next| next.previous = node;
        self.node_index.putAssumeCapacityNoClobber(id, node);
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
        if (target.previous) |previous| previous.next = target.next else self.nodes = target.next;
        if (target.next) |next| next.previous = target.previous;
        const removed = self.node_index.fetchRemove(target.id) orelse unreachable;
        std.debug.assert(removed.value == target);
        if (target.file_id) |file_id| self.filesystem.unpinFile(file_id) catch {};
        target.children.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(target);
    }

    fn hasDentryReference(self: *MountState, target: *const Inode) bool {
        _ = self;
        return target.dentries != null or target.children.count() != 0;
    }

    fn hasChildren(self: *MountState, target: *const Inode) bool {
        _ = self;
        return target.children.count() != 0;
    }

    fn pruneCaches(self: *MountState) void {
        while (true) {
            var current_dentry = self.dentries;
            var removed = false;
            while (current_dentry) |dentry| : (current_dentry = dentry.next) {
                if (dentry.inode.lookup_count == 0 and dentry.inode.open_count == 0 and
                    !self.hasChildren(dentry.inode))
                {
                    const inode = dentry.inode;
                    const parent = dentry.parent;
                    self.removeEntry(dentry);
                    self.removeUnreferencedNode(inode);
                    self.removeUnreferencedNode(parent);
                    removed = true;
                    break;
                }
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
        if (target.previous) |previous| previous.next = target.next else self.dentries = target.next;
        if (target.next) |next| next.previous = target.previous;
        if (target.inode_previous) |previous| {
            previous.inode_next = target.inode_next;
        } else {
            target.inode.dentries = target.inode_next;
        }
        if (target.inode_next) |next| next.inode_previous = target.inode_previous;
        self.removeEntryFromIndex(target);
        std.heap.c_allocator.destroy(target);
    }

    fn removeEntryFromIndex(self: *MountState, target: *Dentry) void {
        _ = self;
        const removed = target.parent.children.fetchRemove(std.mem.sliceTo(&target.name, 0)) orelse
            unreachable;
        std.debug.assert(removed.value == target);
    }

    fn updateDescendantPaths(self: *MountState, parent: *Inode) !void {
        var iterator = parent.children.valueIterator();
        while (iterator.next()) |dentry_ptr| {
            const dentry = dentry_ptr.*;
            try self.setDentryPath(dentry);
            try self.updateDescendantPaths(dentry.inode);
        }
    }

    fn validateDescendantPaths(self: *MountState, source: *Dentry, new_path: []const u8) !void {
        return self.validateChildPaths(
            source.inode,
            std.mem.sliceTo(&source.path, 0).len,
            new_path.len,
        );
    }

    fn validateChildPaths(
        self: *MountState,
        parent: *Inode,
        old_prefix_length: usize,
        new_prefix_length: usize,
    ) !void {
        var iterator = parent.children.valueIterator();
        while (iterator.next()) |dentry_ptr| {
            const dentry = dentry_ptr.*;
            const path_length = std.mem.sliceTo(&dentry.path, 0).len;
            if (new_prefix_length + path_length - old_prefix_length >= path_capacity)
                return error.NameTooLong;
            try self.validateChildPaths(dentry.inode, old_prefix_length, new_prefix_length);
        }
    }

    fn findEntryForInode(self: *MountState, inode: *const Inode) ?*Dentry {
        _ = self;
        return inode.dentries;
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

    fn unregisterOpenDirectory(self: *MountState, target: *FuseDirectoryHandle) void {
        var link = &self.open_directories;
        while (link.*) |handle| {
            if (handle == target) {
                link.* = handle.next;
                return;
            }
            link = &handle.next;
        }
    }

    fn recordOperation(
        self: *MountState,
        operation: *OperationMetrics,
        start_ns: i96,
        bytes: usize,
        failed: bool,
    ) void {
        const elapsed: u64 = @intCast(Io.Clock.awake.now(self.io).nanoseconds - start_ns);
        self.metrics_mutex.lockUncancelable(self.io);
        defer self.metrics_mutex.unlock(self.io);
        operation.calls += 1;
        operation.bytes += bytes;
        operation.errors += @intFromBool(failed);
        operation.elapsed_ns += elapsed;
        operation.max_ns = @max(operation.max_ns, elapsed);
    }
};

const FuseFileHandle = struct {
    file: FileHandle,
    inode: *Inode,
    sync_on_write: bool,
    next: ?*FuseFileHandle,
};

const FuseDirectoryHandle = struct {
    directory: DirectoryHandle,
    inode: *Inode,
    parent_id: c.fuse_ino_t,
    next: ?*FuseDirectoryHandle,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    state: *MountState,
    handle: *c.struct_zettide_fuse_session,
    thread: std.Thread,
    done: std.atomic.Value(bool) = .init(false),
    result: std.atomic.Value(c_int) = .init(0),
    on_exit: ?*const fn (?*anyopaque) void,
    on_exit_context: ?*anyopaque,

    pub const Options = struct {
        allow_other: bool = false,
        read_only: bool = false,
        update_access_time: bool = true,
        async_read_size: ?usize = null,
        metrics: ?*Metrics = null,
        on_exit: ?*const fn (?*anyopaque) void = null,
        on_exit_context: ?*anyopaque = null,
    };

    pub fn start(
        allocator: std.mem.Allocator,
        filesystem: Filesystem,
        io: Io,
        mountpoint: []const u8,
        options: Options,
    ) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        const state = try allocator.create(MountState);
        errdefer allocator.destroy(state);
        state.* = try MountState.init(
            filesystem,
            io,
            options.read_only,
            options.update_access_time and !options.read_only,
            options.async_read_size,
            options.metrics,
        );
        errdefer state.deinit();

        const program = try allocator.dupeSentinel(u8, "zettide", 0);
        defer allocator.free(program);
        const foreground = try allocator.dupeSentinel(u8, "-f", 0);
        defer allocator.free(foreground);
        const single_thread = try allocator.dupeSentinel(u8, "-s", 0);
        defer allocator.free(single_thread);
        const option = try allocator.dupeSentinel(u8, "-o", 0);
        defer allocator.free(option);
        const permissions = try allocator.dupeSentinel(u8, mountOptions(options.allow_other, options.read_only), 0);
        defer allocator.free(permissions);
        const mountpoint_z = try allocator.dupeSentinel(u8, mountpoint, 0);
        defer allocator.free(mountpoint_z);
        var argv = [_][*c]u8{
            program.ptr,
            foreground.ptr,
            single_thread.ptr,
            option.ptr,
            permissions.ptr,
            mountpoint_z.ptr,
        };
        var operations = fuseOperations();
        const handle = c.zettide_fuse_session_create(argv.len, &argv, &operations, state) orelse
            return error.FuseSessionCreateFailed;
        errdefer c.zettide_fuse_session_destroy(handle);
        if (c.zettide_fuse_session_mount(handle) != 0) return error.FuseMountFailed;

        self.* = .{
            .allocator = allocator,
            .state = state,
            .handle = handle,
            .thread = undefined,
            .on_exit = options.on_exit,
            .on_exit_context = options.on_exit_context,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn hasExited(self: *const Session) bool {
        return self.done.load(.acquire);
    }

    pub fn stop(self: *Session) !void {
        if (!self.hasExited()) c.zettide_fuse_session_exit(self.handle);
        self.thread.join();
        const result = self.result.load(.acquire);
        self.state.drainReads();
        c.zettide_fuse_session_destroy(self.handle);
        self.state.deinit();
        self.allocator.destroy(self.state);
        const allocator = self.allocator;
        allocator.destroy(self);
        if (result != 0) return error.FuseSessionFailed;
    }

    fn run(self: *Session) void {
        const result = c.zettide_fuse_session_loop(self.handle);
        self.result.store(result, .release);
        self.done.store(true, .release);
        if (self.on_exit) |callback| callback(self.on_exit_context);
    }
};

pub fn mount(filesystem: Filesystem, io: Io, mountpoint: []const u8, options: Session.Options) !void {
    const allocator = std.heap.c_allocator;
    const program = try allocator.dupeSentinel(u8, "zettide", 0);
    defer allocator.free(program);
    const foreground = try allocator.dupeSentinel(u8, "-f", 0);
    defer allocator.free(foreground);
    const single_thread = try allocator.dupeSentinel(u8, "-s", 0);
    defer allocator.free(single_thread);
    const option = try allocator.dupeSentinel(u8, "-o", 0);
    defer allocator.free(option);
    const permissions = try allocator.dupeSentinel(u8, mountOptions(options.allow_other, options.read_only), 0);
    defer allocator.free(permissions);
    const mountpoint_z = try allocator.dupeSentinel(u8, mountpoint, 0);
    defer allocator.free(mountpoint_z);

    var state = try MountState.init(
        filesystem,
        io,
        options.read_only,
        options.update_access_time and !options.read_only,
        options.async_read_size,
        options.metrics,
    );
    defer state.deinit();
    var argv = [_][*c]u8{
        program.ptr,
        foreground.ptr,
        single_thread.ptr,
        option.ptr,
        permissions.ptr,
        mountpoint_z.ptr,
    };
    var operations = fuseOperations();

    const result = c.zettide_fuse_main(argv.len, &argv, &operations, &state, drainAsyncReads);
    if (result != 0) return error.FuseMountFailed;
}

fn drainAsyncReads(context: ?*anyopaque) callconv(.c) void {
    const state: *MountState = @ptrCast(@alignCast(context.?));
    state.drainReads();
}

fn mountOptions(allow_other: bool, read_only: bool) []const u8 {
    return if (allow_other and read_only)
        "default_permissions,allow_other,ro"
    else if (allow_other)
        "default_permissions,allow_other"
    else if (read_only)
        "default_permissions,ro"
    else
        "default_permissions";
}

fn fuseOperations() c.struct_fuse_lowlevel_ops {
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
    return operations;
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
    state.writeback_cache = c.zettide_fuse_configure_connection(connection.?) != 0;
}

fn lookup(req: c.fuse_req_t, parent_id: c.fuse_ino_t, name_raw: ?[*:0]const u8) callconv(.c) void {
    const state = stateFor(req);
    const parent = state.find(parent_id) orelse return replyError(req, c.ENOENT);
    const name = std.mem.span(name_raw.?);
    var path: [path_capacity:0]u8 = @splat(0);
    const parent_path = state.pathFor(parent) orelse return replyError(req, c.ENOENT);
    joinPath(&path, std.mem.span(parent_path), name) catch |err| return replyError(req, errnoValue(err));
    const info = state.filesystem.statPath(&path) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.reconcileChild(parent, name, info) catch |err|
        return replyError(req, errnoValue(err));
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
            break :value handle.file.stat() catch |err| return replyError(req, errnoValue(err));
        }
        if (node.file_id) |file_id|
            break :value state.filesystem.statFileId(file_id) catch
                node.cached_info orelse return replyError(req, c.ENOENT);
        const path = state.pathFor(node) orelse
            break :value node.cached_info orelse return replyError(req, c.ENOENT);
        break :value state.filesystem.statPath(path) catch |err| return replyError(req, errnoValue(err));
    } else value: {
        if (node.file_id) |file_id|
            break :value state.filesystem.statFileId(file_id) catch
                node.cached_info orelse return replyError(req, c.ENOENT);
        const path = state.pathFor(node) orelse
            break :value node.cached_info orelse return replyError(req, c.ENOENT);
        break :value state.filesystem.statPath(path) catch |err| return replyError(req, errnoValue(err));
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
                handle.file.truncate(@intCast(value.st_size)) catch |err|
                    return replyError(req, errnoValue(err));
            }
            if (to_set & metadata_mask != 0) {
                _ = handle.file.patchMetadata(metadataPatch(value, to_set, state.io)) catch |err|
                    return replyError(req, errnoValue(err));
            }
            if (to_set & c.FUSE_SET_ATTR_SIZE != 0)
                handle.file.sync() catch |err| return replyError(req, errnoValue(err));
            const info = handle.file.stat() catch |err| return replyError(req, errnoValue(err));
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
        var stat: c.struct_stat = undefined;
        fillStat(&stat, node, info);
        _ = c.fuse_reply_attr(req, &stat, cache_timeout);
        return;
    }

    const info = if (node.file_id) |file_id| value_info: {
        if (to_set & c.FUSE_SET_ATTR_SIZE != 0) {
            if (node.kind != .file) return replyError(req, c.EINVAL);
            if (value.st_size < 0) return replyError(req, c.EINVAL);
            var handle = state.filesystem.openFileId(
                std.heap.c_allocator,
                file_id,
                .{ .access = .read_write },
            ) catch |err|
                return replyError(req, errnoValue(err));
            var open_handle = true;
            defer if (open_handle) handle.close() catch {};
            handle.truncate(@intCast(value.st_size)) catch |err|
                return replyError(req, errnoValue(err));
            if (to_set & metadata_mask != 0) {
                _ = handle.patchMetadata(metadataPatch(value, to_set, state.io)) catch |err|
                    return replyError(req, errnoValue(err));
            }
            handle.sync() catch |err| return replyError(req, errnoValue(err));
            const close_result = handle.close();
            open_handle = false;
            close_result catch |err| return replyError(req, errnoValue(err));
        } else if (to_set & metadata_mask != 0) {
            _ = state.filesystem.patchMetadata(file_id, metadataPatch(value, to_set, state.io)) catch |err|
                return replyError(req, errnoValue(err));
        }
        break :value_info state.filesystem.statFileId(file_id) catch |err|
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
            var directory_info = state.filesystem.statPath(path) catch |err|
                return replyError(req, errnoValue(err));
            applyMetadata(&directory_info.metadata, value, to_set, state.io);
            state.filesystem.setMetadata(path, directory_info.metadata) catch |err|
                return replyError(req, errnoValue(err));
        }
        break :value_info state.filesystem.statPath(path) catch |err| return replyError(req, errnoValue(err));
    };
    node.cached_info = info;
    var stat: c.struct_stat = undefined;
    fillStat(&stat, node, info);
    _ = c.fuse_reply_attr(req, &stat, cache_timeout);
}

fn readLink(req: c.fuse_req_t, id: c.fuse_ino_t) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    const file_id = node.file_id orelse return replyError(req, c.EINVAL);
    var info = state.filesystem.statFileId(file_id) catch |err| return replyError(req, errnoValue(err));
    node.cached_info = info;
    if (info.metadata.kind != .symlink) return replyError(req, c.EINVAL);
    var buffer: [path_capacity:0]u8 = @splat(0);
    const amount = state.filesystem.readSpecial(file_id, buffer[0..path_capacity], 0) catch |err|
        return replyError(req, errnoValue(err));
    if (state.update_access_time) {
        const timestamp = now(state.io);
        if (metadata.relatimeNeedsUpdate(info.metadata, timestamp)) {
            if (state.filesystem.patchMetadata(file_id, .{
                .atime_ns = timestamp,
                .update_ctime = false,
            })) |updated| {
                info.metadata = updated;
                node.cached_info = info;
            } else |_| {}
        }
    }
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
    state.filesystem.makeDirectory(&path, .{
        .mode = permissions | 0o040000,
        .uid = context[0].uid,
        .gid = context[0].gid,
    }) catch |err|
        return replyError(req, errnoValue(err));
    const info = state.filesystem.statPath(&path) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.addEntry(parent, name, info) catch |err| {
        state.filesystem.remove(&path) catch {};
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
    state.filesystem.makeFifo(&path, .{
        .mode = permissions,
        .uid = context[0].uid,
        .gid = context[0].gid,
    }) catch |err|
        return replyError(req, errnoValue(err));
    const info = state.filesystem.statPath(&path) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.addEntry(parent, name, info) catch |err| {
        state.filesystem.remove(&path) catch {};
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
    const info = state.filesystem.statPath(&path) catch |err| return replyError(req, errnoValue(err));
    if (directory and info.metadata.kind != .directory) return replyError(req, c.ENOTDIR);
    if (!directory and info.metadata.kind == .directory) return replyError(req, c.EISDIR);
    state.filesystem.remove(&path) catch |err| return replyError(req, errnoValue(err));
    if (state.findChild(parent, name)) |dentry| {
        if (dentry.inode.cached_info) |*cached| {
            cached.nlink = if (directory) 0 else info.nlink -| 1;
            if (directory) cached.metadata.ctime_ns = now(state.io);
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
    state.filesystem.makeSymlink(&path, target, context[0].uid, context[0].gid) catch |err|
        return replyError(req, errnoValue(err));
    const info = state.filesystem.statPath(&path) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.addEntry(parent, name, info) catch |err| {
        state.filesystem.remove(&path) catch {};
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
    const source = state.findChild(parent, name);
    const target = state.findChild(new_parent, new_name);
    if (source) |dentry| {
        if (new_name.len >= name_capacity) return replyError(req, c.ENAMETOOLONG);
        state.validateDescendantPaths(dentry, std.mem.sliceTo(&new_path, 0)) catch |err|
            return replyError(req, errnoValue(err));
        new_parent.children.ensureUnusedCapacity(std.heap.c_allocator, 1) catch
            return replyError(req, c.ENOMEM);
    }
    const rename_result = state.filesystem.rename(
        &old_path,
        &new_path,
        flags & rename_noreplace != 0,
    ) catch |err|
        return replyError(req, errnoValue(err));
    if (rename_result == .same_object) return replyError(req, 0);
    if (target) |dentry| {
        if (dentry.inode.cached_info) |*cached| {
            cached.nlink = if (dentry.inode.kind == .directory) 0 else cached.nlink -| 1;
            if (dentry.inode.kind == .directory) cached.metadata.ctime_ns = now(state.io);
        }
        state.removeEntry(dentry);
    }
    if (source) |dentry| {
        state.removeEntryFromIndex(dentry);
        dentry.parent = new_parent;
        dentry.name = @splat(0);
        @memcpy(dentry.name[0..new_name.len], new_name);
        dentry.path = new_path;
        new_parent.children.putAssumeCapacityNoClobber(std.mem.sliceTo(&dentry.name, 0), dentry);
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
    const file_id = node.file_id orelse return replyError(req, c.EIO);
    const old_info = state.filesystem.statFileId(file_id) catch |err| return replyError(req, errnoValue(err));
    const dentry = state.addEntry(new_parent, name, old_info) catch |err|
        return replyError(req, errnoValue(err));
    if (dentry.inode != node) {
        state.removeEntry(dentry);
        state.pruneCaches();
        return replyError(req, c.EIO);
    }
    const info = state.filesystem.link(old_path, &new_path) catch |err| {
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
    const host_flags = c.zettide_fuse_get_flags(fi.?);
    const options: filesystem_backend.OpenOptions = .{
        .access = if (host_flags & 3 == 0) .read_only else .read_write,
        .create = true,
        .exclusive = true,
        .append = !state.writeback_cache and host_flags & c.O_APPEND != 0,
    };
    const permissions = @as(u32, mode) & ~@as(u32, context[0].umask);
    handle.file = state.filesystem.openFile(std.heap.c_allocator, &path, options, .{
        .mode = permissions | 0o100000,
        .uid = context[0].uid,
        .gid = context[0].gid,
    }) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    const info = handle.file.stat() catch |err| {
        handle.file.close() catch {};
        state.filesystem.remove(&path) catch {};
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    const dentry = state.addEntry(parent, name, info) catch |err| {
        handle.file.close() catch {};
        state.filesystem.remove(&path) catch {};
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    const node = dentry.inode;
    handle.inode = node;
    handle.sync_on_write = host_flags & (c.O_SYNC | c.O_DSYNC) != 0;
    handle.next = state.open_files;
    state.open_files = handle;
    node.open_count += 1;
    node.lookup_count += 1;
    c.zettide_fuse_set_handle(fi.?, @intFromPtr(handle));
    if (!state.writeback_cache) c.zettide_fuse_set_direct_io(fi.?);
    var entry: c.struct_fuse_entry_param = undefined;
    fillEntry(&entry, node, info);
    _ = c.fuse_reply_create(req, &entry, fi.?);
}

fn openInternal(req: c.fuse_req_t, state: *MountState, node: *Inode, fi: *c.struct_fuse_file_info) void {
    const handle = std.heap.c_allocator.create(FuseFileHandle) catch return replyError(req, c.ENOMEM);
    const host_flags = c.zettide_fuse_get_flags(fi);
    const options: filesystem_backend.OpenOptions = .{
        .access = if (state.read_only)
            .read_only
        else if (state.writeback_cache or host_flags & 3 != 0)
            .read_write
        else
            .read_only,
        .truncate = host_flags & c.O_TRUNC != 0,
        .append = !state.writeback_cache and host_flags & c.O_APPEND != 0,
    };
    const file_id = node.file_id orelse {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, c.EIO);
    };
    handle.file = state.filesystem.openFileId(std.heap.c_allocator, file_id, options) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    handle.inode = node;
    handle.sync_on_write = host_flags & (c.O_SYNC | c.O_DSYNC) != 0;
    handle.next = state.open_files;
    state.open_files = handle;
    node.open_count += 1;
    c.zettide_fuse_set_handle(fi, @intFromPtr(handle));
    if (!state.writeback_cache) c.zettide_fuse_set_direct_io(fi);
    _ = c.fuse_reply_open(req, fi);
}

fn read(req: c.fuse_req_t, id: c.fuse_ino_t, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (offset < 0) return replyError(req, c.EINVAL);
    const state = stateFor(req);
    const start = Io.Clock.awake.now(state.io).nanoseconds;
    if (state.shouldRunReadAsync(size)) {
        const request = std.heap.c_allocator.create(AsyncRead) catch {
            if (state.metrics) |metrics| state.recordOperation(&metrics.read, start, 0, true);
            return replyError(req, c.ENOMEM);
        };
        request.* = .{
            .state = state,
            .req = req,
            .handle = fuseFileHandle(fi.?),
            .size = size,
            .offset = @intCast(offset),
            .start = start,
        };
        _ = state.async_reads_inflight.fetchAdd(1, .release);
        state.read_group.concurrent(state.io, completeAsyncRead, .{request}) catch {
            completeAsyncRead(request) catch {};
        };
        return;
    }
    state.reply_buffer.resize(std.heap.c_allocator, size) catch {
        if (state.metrics) |metrics| state.recordOperation(&metrics.read, start, 0, true);
        return replyError(req, c.ENOMEM);
    };
    const buffer = state.reply_buffer.items;
    const handle = fuseFileHandle(fi.?);
    const amount = handle.file.read(buffer, @intCast(offset)) catch |err| {
        if (state.metrics) |metrics| state.recordOperation(&metrics.read, start, 0, true);
        return replyError(req, errnoValue(err));
    };
    updateFileAccessTime(state, handle);
    if (state.metrics) |metrics| state.recordOperation(&metrics.read, start, amount, false);
    _ = c.fuse_reply_buf(req, buffer.ptr, amount);
}

const AsyncRead = struct {
    state: *MountState,
    req: c.fuse_req_t,
    handle: *FuseFileHandle,
    size: usize,
    offset: u64,
    start: i96,
};

fn completeAsyncRead(request: *AsyncRead) Io.Cancelable!void {
    defer std.heap.c_allocator.destroy(request);
    const state = request.state;
    defer _ = state.async_reads_inflight.fetchSub(1, .release);
    const buffer = std.heap.c_allocator.alloc(u8, request.size) catch {
        if (state.metrics) |metrics| state.recordOperation(&metrics.read, request.start, 0, true);
        return replyError(request.req, c.ENOMEM);
    };
    defer std.heap.c_allocator.free(buffer);
    const amount = request.handle.file.read(buffer, request.offset) catch |err| {
        if (state.metrics) |metrics| state.recordOperation(&metrics.read, request.start, 0, true);
        return replyError(request.req, errnoValue(err));
    };
    if (state.metrics) |metrics| state.recordOperation(&metrics.read, request.start, amount, false);
    _ = c.fuse_reply_buf(request.req, buffer.ptr, amount);
}

fn write(req: c.fuse_req_t, id: c.fuse_ino_t, data_raw: ?[*]const u8, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (offset < 0) return replyError(req, c.EINVAL);
    const state = stateFor(req);
    const start = Io.Clock.awake.now(state.io).nanoseconds;
    const handle = fuseFileHandle(fi.?);
    const amount = handle.file.write(data_raw.?[0..size], @intCast(offset)) catch |err| {
        if (state.metrics) |metrics| state.recordOperation(&metrics.write, start, 0, true);
        return replyError(req, errnoValue(err));
    };
    if (handle.sync_on_write) handle.file.sync() catch |err| {
        if (state.metrics) |metrics| state.recordOperation(&metrics.write, start, 0, true);
        return replyError(req, errnoValue(err));
    };
    if (state.metrics) |metrics| state.recordOperation(&metrics.write, start, amount, false);
    _ = c.fuse_reply_write(req, amount);
}

fn fallocate(req: c.fuse_req_t, id: c.fuse_ino_t, mode: c_int, offset: c.off_t, length: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (mode != 0) return replyError(req, c.EOPNOTSUPP);
    if (offset < 0 or length <= 0) return replyError(req, c.EINVAL);
    const start: u64 = @intCast(offset);
    const amount: u64 = @intCast(length);
    _ = std.math.add(u64, start, amount) catch return replyError(req, c.EFBIG);
    const handle = fuseFileHandle(fi.?);
    handle.file.fallocate(start, amount) catch |err|
        return replyError(req, errnoValue(err));
    handle.file.sync() catch |err| return replyError(req, errnoValue(err));
    const info = handle.file.stat() catch |err| return replyError(req, errnoValue(err));
    handle.inode.cached_info = info;
    replyError(req, 0);
}

fn statFs(req: c.fuse_req_t, id: c.fuse_ino_t) callconv(.c) void {
    _ = id;
    const space = stateFor(req).filesystem.spaceInfo() catch |err|
        return replyError(req, errnoValue(err));
    var stat: c.struct_statvfs = std.mem.zeroes(c.struct_statvfs);
    stat.f_bsize = space.block_size;
    stat.f_frsize = space.block_size;
    stat.f_blocks = space.total_blocks;
    stat.f_bfree = space.free_blocks;
    stat.f_bavail = space.available_blocks;
    stat.f_namemax = space.name_max;
    _ = c.fuse_reply_statfs(req, &stat);
}

fn flush(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    const state = stateFor(req);
    const start = Io.Clock.awake.now(state.io).nanoseconds;
    const handle = fuseFileHandle(fi.?);
    handle.file.sync() catch |err| {
        if (state.metrics) |metrics| state.recordOperation(&metrics.flush, start, 0, true);
        return replyError(req, errnoValue(err));
    };
    if (state.metrics) |metrics| state.recordOperation(&metrics.flush, start, 0, false);
    replyError(req, 0);
}

fn fsync(req: c.fuse_req_t, id: c.fuse_ino_t, datasync: c_int, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    _ = datasync;
    const state = stateFor(req);
    const start = Io.Clock.awake.now(state.io).nanoseconds;
    const handle = fuseFileHandle(fi.?);
    handle.file.sync() catch |err| {
        if (state.metrics) |metrics| state.recordOperation(&metrics.fsync, start, 0, true);
        return replyError(req, errnoValue(err));
    };
    if (state.metrics) |metrics| state.recordOperation(&metrics.fsync, start, 0, false);
    replyError(req, 0);
}

fn release(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    const state = stateFor(req);
    const start = Io.Clock.awake.now(state.io).nanoseconds;
    const handle = fuseFileHandle(fi.?);
    const node = handle.inode;
    const result = handle.file.close();
    state.unregisterOpenFile(handle);
    node.open_count -= 1;
    std.heap.c_allocator.destroy(handle);
    state.maybeRemove(node);
    result catch |err| {
        if (state.metrics) |metrics| state.recordOperation(&metrics.release, start, 0, true);
        return replyError(req, errnoValue(err));
    };
    if (state.metrics) |metrics| state.recordOperation(&metrics.release, start, 0, false);
    replyError(req, 0);
}

fn openDirectory(req: c.fuse_req_t, id: c.fuse_ino_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    const state = stateFor(req);
    const node = state.find(id) orelse return replyError(req, c.ENOENT);
    if (node.kind != .directory) return replyError(req, c.ENOTDIR);
    const path = state.pathFor(node) orelse return replyError(req, c.ENOENT);
    const handle = std.heap.c_allocator.create(FuseDirectoryHandle) catch return replyError(req, c.ENOMEM);
    handle.directory = state.filesystem.openDirectory(std.heap.c_allocator, path) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return replyError(req, errnoValue(err));
    };
    handle.inode = node;
    handle.parent_id = if (state.findEntryForInode(node)) |dentry| dentry.parent.id else c.FUSE_ROOT_ID;
    handle.next = state.open_directories;
    state.open_directories = handle;
    node.cached_info = handle.directory.info();
    node.open_count += 1;
    c.zettide_fuse_set_handle(fi.?, @intFromPtr(handle));
    _ = c.fuse_reply_open(req, fi.?);
}

fn readDirectory(req: c.fuse_req_t, id: c.fuse_ino_t, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    if (offset < 0 or offset > std.math.maxInt(u32)) return replyError(req, c.EINVAL);
    const state = stateFor(req);
    defer state.pruneCaches();
    const handle = fuseDirectoryHandle(fi.?);
    updateDirectoryAccessTime(state, handle) catch {};
    handle.directory.seek(@intCast(offset)) catch |err|
        return replyError(req, errnoValue(err));
    state.reply_buffer.resize(std.heap.c_allocator, size) catch return replyError(req, c.ENOMEM);
    const buffer = state.reply_buffer.items;
    var used: usize = 0;
    while (true) {
        var info: filesystem_backend.DirectoryEntry = undefined;
        const has_entry = handle.directory.read(&info) catch |err|
            return replyError(req, errnoValue(err));
        if (!has_entry) break;
        const next_offset = handle.directory.tell() catch |err|
            return replyError(req, errnoValue(err));
        var stat: c.struct_stat = std.mem.zeroes(c.struct_stat);
        stat.st_mode = if (info.kind == .directory) 0o040000 else 0o100000;
        const name = info.name();
        if (std.mem.eql(u8, name, ".")) {
            stat.st_ino = handle.inode.id;
        } else if (std.mem.eql(u8, name, "..")) {
            stat.st_ino = if (state.findEntryForInode(handle.inode)) |dentry|
                dentry.parent.id
            else
                handle.parent_id;
        } else {
            const directory_path = state.pathFor(handle.inode) orelse return replyError(req, c.ENOENT);
            var child_path: [path_capacity:0]u8 = @splat(0);
            joinPath(&child_path, std.mem.span(directory_path), name) catch |err|
                return replyError(req, errnoValue(err));
            // Snapshot cookies stay stable, but stale names must never reuse an old cached inode.
            const child_info = state.filesystem.statPath(&child_path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return replyError(req, errnoValue(err)),
            };
            const dentry = state.reconcileChild(handle.inode, name, child_info) catch |err|
                return replyError(req, errnoValue(err));
            stat.st_ino = dentry.inode.id;
            stat.st_mode = kindMode(dentry.inode.kind);
        }
        const needed = c.fuse_add_direntry(req, buffer.ptr + used, size - used, name.ptr, &stat, next_offset);
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
    const result = handle.directory.close();
    state.unregisterOpenDirectory(handle);
    node.open_count -= 1;
    std.heap.c_allocator.destroy(handle);
    state.maybeRemove(node);
    result catch |err| return replyError(req, errnoValue(err));
    replyError(req, 0);
}

fn fsyncDirectory(req: c.fuse_req_t, id: c.fuse_ino_t, datasync: c_int, fi: ?*c.struct_fuse_file_info) callconv(.c) void {
    _ = id;
    _ = datasync;
    const handle = fuseDirectoryHandle(fi.?);
    handle.directory.sync() catch |err| return replyError(req, errnoValue(err));
    replyError(req, 0);
}

fn currentDirectoryInfo(state: *MountState, node: *Inode) !NodeInfo {
    if (state.pathFor(node)) |path| {
        const info = try state.filesystem.statPath(path);
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
) !NodeInfo {
    var info = try currentDirectoryInfo(state, node);
    const metadata_mask = c.FUSE_SET_ATTR_MODE | c.FUSE_SET_ATTR_UID | c.FUSE_SET_ATTR_GID |
        c.FUSE_SET_ATTR_ATIME | c.FUSE_SET_ATTR_MTIME | c.FUSE_SET_ATTR_ATIME_NOW | c.FUSE_SET_ATTR_MTIME_NOW;
    if (to_set & metadata_mask != 0) {
        applyMetadata(&info.metadata, stat, to_set, state.io);
        if (state.pathFor(node)) |path| try state.filesystem.setMetadata(path, info.metadata);
    }
    node.cached_info = info;
    return info;
}

fn updateDirectoryAccessTime(state: *MountState, handle: *FuseDirectoryHandle) !void {
    if (!state.update_access_time) return;
    var info = try currentDirectoryInfo(state, handle.inode);
    const timestamp = now(state.io);
    if (!accessTimeUpdateRequired(state.update_access_time, info.metadata, timestamp)) return;
    info.metadata.atime_ns = timestamp;
    if (state.pathFor(handle.inode)) |path| try state.filesystem.setMetadata(path, info.metadata);
    handle.inode.cached_info = info;
}

fn updateFileAccessTime(state: *MountState, handle: *FuseFileHandle) void {
    if (!state.update_access_time) return;
    var info = handle.file.stat() catch return;
    const timestamp = now(state.io);
    if (!metadata.relatimeNeedsUpdate(info.metadata, timestamp)) return;
    const updated = handle.file.patchMetadata(.{
        .atime_ns = timestamp,
        .update_ctime = false,
    }) catch return;
    info.metadata = updated;
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

fn inodeNumber(identity: FileId) c.fuse_ino_t {
    var id: c.fuse_ino_t = std.mem.readInt(u64, identity[0..8], .little);
    if (id == 0 or id == c.FUSE_ROOT_ID) id +%= 2;
    return id;
}

fn replyEntry(req: c.fuse_req_t, node: *Inode, info: NodeInfo) void {
    node.cached_info = info;
    var entry: c.struct_fuse_entry_param = undefined;
    fillEntry(&entry, node, info);
    _ = c.fuse_reply_entry(req, &entry);
}

fn fillEntry(entry: *c.struct_fuse_entry_param, node: *Inode, info: NodeInfo) void {
    entry.* = std.mem.zeroes(c.struct_fuse_entry_param);
    entry.ino = node.id;
    entry.generation = 1;
    entry.attr_timeout = cache_timeout;
    entry.entry_timeout = cache_timeout;
    fillStat(&entry.attr, node, info);
}

fn fillStat(stat: *c.struct_stat, node: *const Inode, info: NodeInfo) void {
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

fn accessTimeUpdateRequired(enabled: bool, value: metadata.Metadata, timestamp: i64) bool {
    return enabled and metadata.relatimeNeedsUpdate(value, timestamp);
}

fn fuseFileHandle(file_info: *c.struct_fuse_file_info) *FuseFileHandle {
    return @ptrFromInt(c.zettide_fuse_get_handle(file_info));
}

fn fuseDirectoryHandle(file_info: *c.struct_fuse_file_info) *FuseDirectoryHandle {
    return @ptrFromInt(c.zettide_fuse_get_handle(file_info));
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
        error.InvalidArgument,
        error.InvalidMetadata,
        error.InvalidName,
        error.InvalidUtf8,
        error.UnassignedCodepoint,
        error.ReservedName,
        => c.EINVAL,
        error.NoSpaceLeft => c.ENOSPC,
        error.OutOfMemory => c.ENOMEM,
        error.NameTooLong => c.ENAMETOOLONG,
        error.TooManyLinks => c.EMLINK,
        error.AccessDenied, error.PermissionDenied => c.EACCES,
        error.ReadOnlyVolume => c.EROFS,
        error.UnsupportedOperation, error.OperationNotSupported => c.EOPNOTSUPP,
        else => c.EIO,
    };
}

test "access time updates honor mount policy and relatime" {
    const value: metadata.Metadata = .{
        .kind = .directory,
        .mode = 0o040755,
        .uid = 0,
        .gid = 0,
        .atime_ns = 1,
        .mtime_ns = 2,
        .ctime_ns = 2,
        .birthtime_ns = 1,
    };

    try std.testing.expect(!accessTimeUpdateRequired(false, value, 3));
    try std.testing.expect(accessTimeUpdateRequired(true, value, 3));
}

test "backend errors map to Linux errno values" {
    try std.testing.expectEqual(@as(c_int, c.EROFS), errnoValue(error.ReadOnlyVolume));
    try std.testing.expectEqual(@as(c_int, c.EINVAL), errnoValue(error.InvalidName));
    try std.testing.expectEqual(@as(c_int, c.EINVAL), errnoValue(error.InvalidUtf8));
    try std.testing.expectEqual(@as(c_int, c.EINVAL), errnoValue(error.UnassignedCodepoint));
    try std.testing.expectEqual(@as(c_int, c.EINVAL), errnoValue(error.ReservedName));
    try std.testing.expectEqual(@as(c_int, c.EOPNOTSUPP), errnoValue(error.UnsupportedOperation));
    try std.testing.expectEqual(@as(c_int, c.EOPNOTSUPP), errnoValue(error.OperationNotSupported));
}

test "cached portable aliases reconcile changed identities" {
    const TestInfo = struct {
        fn make(identity_byte: u8) NodeInfo {
            return .{
                .size = 0,
                .allocated_bytes = 0,
                .metadata = .{
                    .kind = .file,
                    .mode = 0o100644,
                    .uid = 0,
                    .gid = 0,
                    .atime_ns = 0,
                    .mtime_ns = 0,
                    .ctime_ns = 0,
                    .birthtime_ns = 0,
                },
                .file_id = null,
                .identity = @splat(identity_byte),
                .nlink = 1,
            };
        }
    };

    var state: MountState = .{
        .filesystem = undefined,
        .io = std.testing.io,
        .read_only = false,
        .update_access_time = false,
        .metrics = null,
    };
    defer state.deinit();
    const root = try std.heap.c_allocator.create(Inode);
    try state.node_index.ensureUnusedCapacity(std.heap.c_allocator, 1);
    root.* = .{
        .id = c.FUSE_ROOT_ID,
        .identity = @splat(1),
        .file_id = null,
        .kind = .directory,
        .cached_info = null,
        .lookup_count = 1,
        .open_count = 0,
        .children = .empty,
        .dentries = null,
        .previous = null,
        .next = null,
    };
    state.node_index.putAssumeCapacityNoClobber(root.id, root);
    state.nodes = root;

    const old_info = TestInfo.make(0x10);
    const old_node = (try state.addEntry(root, "Straße", old_info)).inode;
    _ = try state.addEntry(root, "STRASSE", old_info);
    const old_id = old_node.id;
    const new_info = TestInfo.make(0x20);
    try std.testing.expectEqualDeep(
        new_info.identity,
        (try state.reconcileChild(root, "STRASSE", new_info)).inode.identity,
    );
    try std.testing.expectEqualDeep(
        new_info.identity,
        (try state.reconcileChild(root, "Straße", new_info)).inode.identity,
    );
    try std.testing.expect(state.find(old_id) == null);
    try std.testing.expectEqual(@as(usize, 2), root.children.count());
}
