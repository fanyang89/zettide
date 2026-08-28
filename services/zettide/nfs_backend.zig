const std = @import("std");
const zettide = @import("zettide");

const allocator = std.heap.c_allocator;
const filesystem_api = zettide.nfs_filesystem;
const nfs_handle = zettide.nfs_handle;

const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    no_entry = 2,
    stale = 3,
    not_directory = 4,
    is_directory = 5,
    exists = 6,
    read_only = 7,
    no_space = 8,
    input_output = 9,
    not_supported = 10,
    internal = 11,
    permission_denied = 12,
    directory_not_empty = 13,
    too_many_links = 14,
    file_too_large = 15,
    name_too_long = 16,
};

const BlobOwner = struct {
    native: zettide.blob_filesystem.Filesystem,
    adapter: zettide.nfs_blob_adapter.Adapter,
};

const FilesystemOwner = struct {
    blob: BlobOwner,

    fn openInto(
        self: *FilesystemOwner,
        io: std.Io,
        allocator_value: std.mem.Allocator,
        path: []const u8,
        writable: bool,
    ) !void {
        const target_stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        if (target_stat.kind == .block_device)
            return self.openPoolInto(io, allocator_value, path, writable);

        switch (try zettide.filesystem_target.classifyPath(io, path)) {
            .blob => {
                self.* = .{ .blob = undefined };
                self.blob.native = try zettide.filesystem_target.openBlobFilesystem(
                    allocator_value,
                    io,
                    path,
                    writable,
                );
                self.blob.adapter = .init(&self.blob.native, io);
                return;
            },
            .pool_member => return self.openPoolInto(io, allocator_value, path, writable),
            .littlefs_container => return error.UnsupportedLegacyFormat,
            .unknown => return error.UnsupportedFilesystemFormat,
        }
    }

    fn openPoolInto(
        self: *FilesystemOwner,
        io: std.Io,
        allocator_value: std.mem.Allocator,
        path: []const u8,
        writable: bool,
    ) !void {
        var set = try openSingleMemberPool(io, allocator_value, path, writable);
        defer set.deinit();
        switch (try set.dataMode()) {
            .catalog => return error.CatalogPoolUnsupported,
            .blob => {
                self.* = .{ .blob = undefined };
                self.blob.native = try zettide.filesystem_target.openBlobPoolFilesystem(
                    allocator_value,
                    io,
                    &set,
                    writable,
                );
                self.blob.adapter = .init(&self.blob.native, io);
            },
            .legacy_unsupported => return error.LegacyPoolDataModeUnsupported,
        }
    }

    fn filesystem(self: *FilesystemOwner) filesystem_api.Filesystem {
        return self.blob.adapter.filesystem();
    }

    fn close(self: *FilesystemOwner, io: std.Io) !void {
        return self.blob.native.close(io);
    }
};

fn openSingleMemberPool(
    io: std.Io,
    allocator_value: std.mem.Allocator,
    path: []const u8,
    writable: bool,
) !zettide.v3.pool_member_set.PoolMemberSet {
    const target_stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    const storage = switch (target_stat.kind) {
        .file => try zettide.v3.storage.Storage.openFile(io, std.Io.Dir.cwd(), path, writable),
        .block_device => if (@import("builtin").os.tag == .linux)
            (try zettide.v3.linux_block_device.openStorageOptions(
                io,
                allocator_value,
                path,
                writable,
                true,
            )).storage
        else
            return error.BlockDeviceNotImplemented,
        else => return error.UnsupportedTargetType,
    };
    var storages = [_]zettide.v3.storage.Storage{storage};
    return zettide.v3.pool_member_set.PoolMemberSet.openStorages(
        io,
        allocator_value,
        &storages,
        if (writable) .writable else .read_only,
    );
}

const Export = struct {
    threaded: std.Io.Threaded,
    owner: FilesystemOwner,
    filesystem: filesystem_api.Filesystem,
    mutex: std.Io.RwLock = .init,

    fn io(self: *Export) std.Io {
        return self.threaded.io();
    }

    fn lock(self: *Export) !void {
        try self.mutex.lock(self.io());
    }

    fn unlock(self: *Export) void {
        self.mutex.unlock(self.io());
    }

    fn lockDataRead(self: *Export) !void {
        try self.mutex.lockShared(self.io());
    }

    fn unlockDataRead(self: *Export) void {
        self.mutex.unlockShared(self.io());
    }
};

const Directory = struct {
    export_handle: *Export,
    handle: filesystem_api.Directory,
};

const Handle = extern struct {
    bytes: [nfs_handle.encoded_size]u8,
};

const Attributes = extern struct {
    kind: u8,
    reserved: [3]u8,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    allocated_bytes: u64,
    nlink: u64,
    atime_ns: i64,
    mtime_ns: i64,
    ctime_ns: i64,
    birthtime_ns: i64,
};

const DirectoryEntry = extern struct {
    name: [256]u8,
    next_cookie: u32,
    handle: Handle,
    attributes: Attributes,
};

const SetAttributes = extern struct {
    mask: u64,
    size: u64,
    atime_ns: i64,
    mtime_ns: i64,
    mode: u32,
    uid: u32,
    gid: u32,
    reserved: u32,
};

const FilesystemInfo = extern struct {
    total_bytes: u64,
    free_bytes: u64,
    available_bytes: u64,
};

const set_mode: u64 = 1 << 0;
const set_uid: u64 = 1 << 1;
const set_gid: u64 = 1 << 2;
const set_size: u64 = 1 << 3;
const set_atime: u64 = 1 << 4;
const set_mtime: u64 = 1 << 5;
const set_mask = set_mode | set_uid | set_gid | set_size | set_atime | set_mtime;

pub export fn zettide_nfs_export_open(
    target: ?[*:0]const u8,
    writable: bool,
    out_export: ?**Export,
) callconv(.c) c_int {
    const target_value = target orelse return status(.invalid_argument);
    const output = out_export orelse return status(.invalid_argument);
    const self = allocator.create(Export) catch return status(.internal);
    self.threaded = .init(allocator, .{ .environ = .empty });
    self.owner.openInto(
        self.threaded.io(),
        allocator,
        std.mem.span(target_value),
        writable,
    ) catch |err| {
        self.threaded.deinit();
        allocator.destroy(self);
        return statusFor(err, false);
    };
    self.filesystem = self.owner.filesystem();
    self.mutex = .init;
    output.* = self;
    return status(.ok);
}

pub export fn zettide_nfs_export_close(export_handle: ?*Export) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    const result = self.owner.close(self.io());
    self.unlock();
    self.threaded.deinit();
    allocator.destroy(self);
    result catch |err| return statusFor(err, false);
    return status(.ok);
}

pub export fn zettide_nfs_statfs(
    export_handle: ?*Export,
    out_info: ?*FilesystemInfo,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const output = out_info orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const info = self.filesystem.spaceInfo() catch |err| return statusFor(err, false);
    output.* = .{
        .total_bytes = info.total_blocks * info.block_size,
        .free_bytes = info.free_blocks * info.block_size,
        .available_bytes = info.available_blocks * info.block_size,
    };
    return status(.ok);
}

pub export fn zettide_nfs_root(
    export_handle: ?*Export,
    out_handle: ?*Handle,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const output_handle = out_handle orelse return status(.invalid_argument);
    const output_attributes = out_attributes orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const info = self.filesystem.root() catch |err| return statusFor(err, false);
    fillResult(self, info, output_handle, output_attributes);
    return status(.ok);
}

pub export fn zettide_nfs_lookup(
    export_handle: ?*Export,
    parent: ?*const Handle,
    name: ?[*]const u8,
    name_length: usize,
    out_handle: ?*Handle,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const parent_value = parent orelse return status(.invalid_argument);
    const name_value = name orelse return status(.invalid_argument);
    const output_handle = out_handle orelse return status(.invalid_argument);
    const output_attributes = out_attributes orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded = decodeExisting(self, parent_value) catch |err| return statusFor(err, true);
    if (decoded.kind != .directory) return status(.not_directory);
    const info = self.filesystem.lookup(node(decoded), name_value[0..name_length]) catch |err|
        return statusFor(err, false);
    fillResult(self, info, output_handle, output_attributes);
    return status(.ok);
}

pub export fn zettide_nfs_lookup_parent(
    export_handle: ?*Export,
    directory: ?*const Handle,
    out_handle: ?*Handle,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const directory_value = directory orelse return status(.invalid_argument);
    const output_handle = out_handle orelse return status(.invalid_argument);
    const output_attributes = out_attributes orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded = decodeExisting(self, directory_value) catch |err| return statusFor(err, true);
    if (decoded.kind != .directory) return status(.not_directory);
    const info = self.filesystem.parent(node(decoded)) catch |err|
        return statusFor(err, true);
    fillResult(self, info, output_handle, output_attributes);
    return status(.ok);
}

pub export fn zettide_nfs_getattr(
    export_handle: ?*Export,
    handle: ?*const Handle,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const handle_value = handle orelse return status(.invalid_argument);
    const output = out_attributes orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded = decodeHandle(self, handle_value) catch |err| return statusFor(err, true);
    const info = self.filesystem.stat(node(decoded)) catch |err| return statusFor(err, true);
    output.* = attributes(info);
    return status(.ok);
}

pub export fn zettide_nfs_setattr(
    export_handle: ?*Export,
    handle: ?*const Handle,
    set_attributes: ?*const SetAttributes,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const handle_value = handle orelse return status(.invalid_argument);
    const changes = set_attributes orelse return status(.invalid_argument);
    const output = out_attributes orelse return status(.invalid_argument);
    if (changes.mask & ~set_mask != 0) return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded = decodeExisting(self, handle_value) catch |err| return statusFor(err, true);

    if (changes.mask & set_size != 0) {
        if (decoded.kind != .file) return status(.invalid_argument);
        _ = self.filesystem.truncate(node(decoded), changes.size) catch |err|
            return statusFor(err, false);
    }

    if (changes.mask & (set_mode | set_uid | set_gid | set_atime | set_mtime) != 0) {
        const current = self.filesystem.stat(node(decoded)) catch |err| return statusFor(err, true);
        var value = current.metadata;
        if (changes.mask & set_mode != 0)
            value.mode = (value.mode & ~@as(u32, 0o7777)) | (changes.mode & 0o7777);
        if (changes.mask & set_uid != 0) value.uid = changes.uid;
        if (changes.mask & set_gid != 0) value.gid = changes.gid;
        if (changes.mask & set_atime != 0) value.atime_ns = changes.atime_ns;
        if (changes.mask & set_mtime != 0) value.mtime_ns = changes.mtime_ns;
        value.ctime_ns = @intCast(std.Io.Clock.real.now(self.io()).nanoseconds);
        _ = self.filesystem.setMetadata(node(decoded), value) catch |err| return statusFor(err, true);
    }
    if (changes.mask != 0)
        self.filesystem.sync() catch |err| return statusFor(err, false);

    const info = self.filesystem.stat(node(decoded)) catch |err| return statusFor(err, true);
    output.* = attributes(info);
    return status(.ok);
}

pub export fn zettide_nfs_read(
    export_handle: ?*Export,
    handle: ?*const Handle,
    offset: u64,
    buffer: ?*anyopaque,
    buffer_length: usize,
    out_read: ?*usize,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const handle_value = handle orelse return status(.invalid_argument);
    const output = out_read orelse return status(.invalid_argument);
    if (buffer_length != 0 and buffer == null) return status(.invalid_argument);
    self.lockDataRead() catch return status(.internal);
    defer self.unlockDataRead();
    const decoded = decodeDataHandle(self, handle_value) catch |err| return statusFor(err, true);
    if (decoded.kind != .file) {
        _ = self.filesystem.stat(node(decoded)) catch |err| return statusFor(err, true);
        return if (decoded.kind == .directory) status(.is_directory) else status(.invalid_argument);
    }
    if (buffer_length == 0) {
        _ = self.filesystem.stat(node(decoded)) catch |err| return statusFor(err, true);
        output.* = 0;
        return status(.ok);
    }
    const bytes = @as([*]u8, @ptrCast(buffer.?))[0..buffer_length];
    output.* = self.filesystem.read(node(decoded), bytes, offset) catch |err| return statusFor(err, true);
    return status(.ok);
}

pub export fn zettide_nfs_create(
    export_handle: ?*Export,
    parent: ?*const Handle,
    name: ?[*]const u8,
    name_length: usize,
    mode: u32,
    uid: u32,
    gid: u32,
    out_handle: ?*Handle,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const parent_value = parent orelse return status(.invalid_argument);
    const name_value = name orelse return status(.invalid_argument);
    const output_handle = out_handle orelse return status(.invalid_argument);
    const output_attributes = out_attributes orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded_parent = decodeExisting(self, parent_value) catch |err| return statusFor(err, true);
    if (decoded_parent.kind != .directory) return status(.not_directory);
    const info = self.filesystem.createFile(
        node(decoded_parent),
        name_value[0..name_length],
        .{ .mode = mode, .uid = uid, .gid = gid },
    ) catch |err| return statusFor(err, false);
    self.filesystem.sync() catch |err| return statusFor(err, false);
    fillResult(self, info, output_handle, output_attributes);
    return status(.ok);
}

pub export fn zettide_nfs_write(
    export_handle: ?*Export,
    handle: ?*const Handle,
    offset: u64,
    data: ?*const anyopaque,
    data_length: usize,
    out_written: ?*usize,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const handle_value = handle orelse return status(.invalid_argument);
    const output = out_written orelse return status(.invalid_argument);
    if (data_length != 0 and data == null) return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded = decodeDataHandle(self, handle_value) catch |err| return statusFor(err, true);
    if (decoded.kind != .file) {
        _ = self.filesystem.stat(node(decoded)) catch |err| return statusFor(err, true);
        return if (decoded.kind == .directory) status(.is_directory) else status(.invalid_argument);
    }
    if (data_length == 0) {
        _ = self.filesystem.stat(node(decoded)) catch |err| return statusFor(err, true);
        output.* = 0;
        return status(.ok);
    }
    const bytes = @as([*]const u8, @ptrCast(data.?))[0..data_length];
    output.* = self.filesystem.write(node(decoded), bytes, offset) catch |err| return statusFor(err, true);
    return status(.ok);
}

pub export fn zettide_nfs_sync(export_handle: ?*Export) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    self.filesystem.sync() catch |err| return statusFor(err, false);
    return status(.ok);
}

pub export fn zettide_nfs_mkdir(
    export_handle: ?*Export,
    parent: ?*const Handle,
    name: ?[*]const u8,
    name_length: usize,
    mode: u32,
    uid: u32,
    gid: u32,
    out_handle: ?*Handle,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const parent_value = parent orelse return status(.invalid_argument);
    const name_value = name orelse return status(.invalid_argument);
    const output_handle = out_handle orelse return status(.invalid_argument);
    const output_attributes = out_attributes orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded_parent = decodeExisting(self, parent_value) catch |err| return statusFor(err, true);
    if (decoded_parent.kind != .directory) return status(.not_directory);
    const info = self.filesystem.makeDirectory(
        node(decoded_parent),
        name_value[0..name_length],
        .{ .mode = mode, .uid = uid, .gid = gid },
    ) catch |err| return statusFor(err, false);
    self.filesystem.sync() catch |err| return statusFor(err, false);
    fillResult(self, info, output_handle, output_attributes);
    return status(.ok);
}

pub export fn zettide_nfs_symlink(
    export_handle: ?*Export,
    parent: ?*const Handle,
    name: ?[*]const u8,
    name_length: usize,
    target: ?[*]const u8,
    target_length: usize,
    uid: u32,
    gid: u32,
    out_handle: ?*Handle,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const parent_value = parent orelse return status(.invalid_argument);
    const name_value = name orelse return status(.invalid_argument);
    const target_value = target orelse return status(.invalid_argument);
    const output_handle = out_handle orelse return status(.invalid_argument);
    const output_attributes = out_attributes orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded_parent = decodeExisting(self, parent_value) catch |err| return statusFor(err, true);
    if (decoded_parent.kind != .directory) return status(.not_directory);
    const info = self.filesystem.makeSymlink(
        node(decoded_parent),
        name_value[0..name_length],
        target_value[0..target_length],
        uid,
        gid,
    ) catch |err| return statusFor(err, false);
    self.filesystem.sync() catch |err| return statusFor(err, false);
    fillResult(self, info, output_handle, output_attributes);
    return status(.ok);
}

pub export fn zettide_nfs_readlink(
    export_handle: ?*Export,
    handle: ?*const Handle,
    buffer: ?*anyopaque,
    buffer_length: usize,
    out_read: ?*usize,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const handle_value = handle orelse return status(.invalid_argument);
    const output = out_read orelse return status(.invalid_argument);
    if (buffer_length != 0 and buffer == null) return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded = decodeExisting(self, handle_value) catch |err| return statusFor(err, true);
    if (decoded.kind != .symlink) return status(.invalid_argument);
    if (buffer_length == 0) {
        output.* = 0;
        return status(.ok);
    }
    const bytes = @as([*]u8, @ptrCast(buffer.?))[0..buffer_length];
    output.* = self.filesystem.readlink(node(decoded), bytes) catch |err| return statusFor(err, true);
    return status(.ok);
}

pub export fn zettide_nfs_link(
    export_handle: ?*Export,
    source: ?*const Handle,
    parent: ?*const Handle,
    name: ?[*]const u8,
    name_length: usize,
    out_handle: ?*Handle,
    out_attributes: ?*Attributes,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const source_value = source orelse return status(.invalid_argument);
    const parent_value = parent orelse return status(.invalid_argument);
    const name_value = name orelse return status(.invalid_argument);
    const output_handle = out_handle orelse return status(.invalid_argument);
    const output_attributes = out_attributes orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded_source = decodeExisting(self, source_value) catch |err| return statusFor(err, true);
    if (decoded_source.kind == .directory) return status(.is_directory);
    const decoded_parent = decodeExisting(self, parent_value) catch |err| return statusFor(err, true);
    if (decoded_parent.kind != .directory) return status(.not_directory);
    const info = self.filesystem.link(
        node(decoded_source),
        node(decoded_parent),
        name_value[0..name_length],
    ) catch |err| return statusFor(err, false);
    self.filesystem.sync() catch |err| return statusFor(err, false);
    fillResult(self, info, output_handle, output_attributes);
    return status(.ok);
}

pub export fn zettide_nfs_remove(
    export_handle: ?*Export,
    parent: ?*const Handle,
    name: ?[*]const u8,
    name_length: usize,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const parent_value = parent orelse return status(.invalid_argument);
    const name_value = name orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded_parent = decodeExisting(self, parent_value) catch |err| return statusFor(err, true);
    if (decoded_parent.kind != .directory) return status(.not_directory);
    self.filesystem.remove(node(decoded_parent), name_value[0..name_length]) catch |err|
        return statusFor(err, false);
    self.filesystem.sync() catch |err| return statusFor(err, false);
    return status(.ok);
}

pub export fn zettide_nfs_rename(
    export_handle: ?*Export,
    old_parent: ?*const Handle,
    old_name: ?[*]const u8,
    old_name_length: usize,
    new_parent: ?*const Handle,
    new_name: ?[*]const u8,
    new_name_length: usize,
    no_replace: bool,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const old_parent_value = old_parent orelse return status(.invalid_argument);
    const old_name_value = old_name orelse return status(.invalid_argument);
    const new_parent_value = new_parent orelse return status(.invalid_argument);
    const new_name_value = new_name orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded_old_parent = decodeExisting(self, old_parent_value) catch |err| return statusFor(err, true);
    const decoded_new_parent = decodeExisting(self, new_parent_value) catch |err| return statusFor(err, true);
    if (decoded_old_parent.kind != .directory or decoded_new_parent.kind != .directory)
        return status(.not_directory);
    self.filesystem.rename(
        node(decoded_old_parent),
        old_name_value[0..old_name_length],
        node(decoded_new_parent),
        new_name_value[0..new_name_length],
        no_replace,
    ) catch |err| return statusFor(err, false);
    self.filesystem.sync() catch |err| return statusFor(err, false);
    return status(.ok);
}

pub export fn zettide_nfs_directory_open(
    export_handle: ?*Export,
    handle: ?*const Handle,
    cookie: u32,
    out_directory: ?**Directory,
) callconv(.c) c_int {
    const self = export_handle orelse return status(.invalid_argument);
    const handle_value = handle orelse return status(.invalid_argument);
    const output = out_directory orelse return status(.invalid_argument);
    self.lock() catch return status(.internal);
    defer self.unlock();
    const decoded = decodeExisting(self, handle_value) catch |err| return statusFor(err, true);
    if (decoded.kind != .directory) return status(.not_directory);
    const directory = allocator.create(Directory) catch return status(.internal);
    directory.* = .{
        .export_handle = self,
        .handle = self.filesystem.openDirectory(allocator, node(decoded), cookie) catch |err| {
            allocator.destroy(directory);
            return statusFor(err, true);
        },
    };
    output.* = directory;
    return status(.ok);
}

pub export fn zettide_nfs_directory_read(
    directory: ?*Directory,
    out_entry: ?*DirectoryEntry,
    out_has_entry: ?*bool,
) callconv(.c) c_int {
    const self = directory orelse return status(.invalid_argument);
    const output = out_entry orelse return status(.invalid_argument);
    const has_entry = out_has_entry orelse return status(.invalid_argument);
    self.export_handle.lock() catch return status(.internal);
    defer self.export_handle.unlock();
    var entry: filesystem_api.DirectoryEntry = undefined;
    has_entry.* = self.handle.read(&entry) catch |err|
        return statusFor(err, false);
    if (!has_entry.*) return status(.ok);
    output.* = .{
        .name = @splat(0),
        .next_cookie = entry.next_cookie,
        .handle = undefined,
        .attributes = attributes(entry.info),
    };
    const name = entry.name();
    @memcpy(output.name[0..name.len], name);
    output.handle.bytes = nfs_handle.encode(self.export_handle.filesystem.filesystem_id, .{
        .kind = entry.info.metadata.kind,
        .identity = entry.info.identity,
    });
    return status(.ok);
}

pub export fn zettide_nfs_directory_close(directory: ?*Directory) callconv(.c) c_int {
    const self = directory orelse return status(.invalid_argument);
    self.export_handle.lock() catch return status(.internal);
    const result = self.handle.close();
    self.export_handle.unlock();
    allocator.destroy(self);
    result catch |err| return statusFor(err, false);
    return status(.ok);
}

fn decodeExisting(self: *Export, handle: *const Handle) !nfs_handle.Handle {
    const decoded = try decodeHandle(self, handle);
    try validateExisting(self, decoded);
    return decoded;
}

fn decodeDataHandle(self: *Export, handle: *const Handle) !nfs_handle.Handle {
    const decoded = try decodeHandle(self, handle);
    return decoded;
}

fn validateExisting(self: *Export, decoded: nfs_handle.Handle) !void {
    _ = self.filesystem.stat(node(decoded)) catch |err| switch (err) {
        error.FileNotFound => return error.StaleFileHandle,
        else => return err,
    };
}

fn decodeHandle(self: *Export, handle: *const Handle) !nfs_handle.Handle {
    return nfs_handle.decode(self.filesystem.filesystem_id, &handle.bytes) catch
        return error.StaleFileHandle;
}

fn fillResult(self: *Export, info: filesystem_api.NodeInfo, handle: *Handle, attrs: *Attributes) void {
    handle.bytes = nfs_handle.encode(self.filesystem.filesystem_id, .{
        .kind = info.metadata.kind,
        .identity = info.identity,
    });
    attrs.* = attributes(info);
}

fn attributes(info: filesystem_api.NodeInfo) Attributes {
    return .{
        .kind = @intFromEnum(info.metadata.kind),
        .reserved = @splat(0),
        .mode = info.metadata.mode,
        .uid = info.metadata.uid,
        .gid = info.metadata.gid,
        .size = info.size,
        .allocated_bytes = info.allocated_bytes,
        .nlink = info.nlink,
        .atime_ns = info.metadata.atime_ns,
        .mtime_ns = info.metadata.mtime_ns,
        .ctime_ns = info.metadata.ctime_ns,
        .birthtime_ns = info.metadata.birthtime_ns,
    };
}

fn node(handle: nfs_handle.Handle) filesystem_api.Node {
    return .{ .kind = handle.kind, .identity = handle.identity };
}

fn status(value: Status) c_int {
    return @intFromEnum(value);
}

fn statusFor(err: anyerror, stale_context: bool) c_int {
    const value: Status = switch (err) {
        error.InvalidArgument, error.InvalidFileHandle, error.ForeignVolume => if (stale_context) .stale else .invalid_argument,
        error.StaleFileHandle => .stale,
        error.FileNotFound => if (stale_context) .stale else .no_entry,
        error.NotDirectory => .not_directory,
        error.IsDirectory => .is_directory,
        error.PathAlreadyExists => .exists,
        error.ReadOnlyVolume, error.AccessDenied => .read_only,
        error.NoSpaceLeft => .no_space,
        error.FileTooLarge => .file_too_large,
        error.NameTooLong => .name_too_long,
        error.InputOutput, error.CorruptFilesystem, error.VolumeRequiresReopen => .input_output,
        error.OperationNotSupported,
        error.UnsupportedFilesystemBackend,
        error.UnsupportedLegacyFormat,
        error.UnsupportedFilesystemFormat,
        error.CatalogPoolUnsupported,
        error.LegacyPoolDataModeUnsupported,
        => .not_supported,
        error.PermissionDenied => .permission_denied,
        error.DirectoryNotEmpty => .directory_not_empty,
        error.TooManyLinks => .too_many_links,
        else => .internal,
    };
    return status(value);
}

test "direct NFS backend resolves and reads stable handles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const suffix = "/nfs-backend.ddv";
    @memcpy(path_buffer[root_length .. root_length + suffix.len], suffix);
    const path = path_buffer[0 .. root_length + suffix.len];
    try zettide.filesystem_target.formatNewBlobFile(
        std.testing.io,
        std.testing.allocator,
        path,
        8 * 1024 * 1024,
        .portable_v1,
        .{},
    );
    {
        var filesystem = try zettide.filesystem_target.openBlobFilesystem(
            std.testing.allocator,
            std.testing.io,
            path,
            true,
        );
        _ = try filesystem.createDirectory(std.testing.io, 1, "directory", 0o755, 10, 20);
        const inode = try filesystem.createFile(std.testing.io, 1, "payload", 0o644, 10, 20);
        _ = try filesystem.write(std.testing.io, inode, "direct backend", 0);
        try filesystem.close(std.testing.io);
    }

    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);
    var export_handle: *Export = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_export_open(path_z, true, &export_handle));
    var export_open = true;
    defer if (export_open) {
        _ = zettide_nfs_export_close(export_handle);
    };

    var root_handle: Handle = undefined;
    var root_attributes: Attributes = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_root(export_handle, &root_handle, &root_attributes));
    try std.testing.expectEqual(@intFromEnum(zettide.metadata.Kind.directory), root_attributes.kind);
    var filesystem_info: FilesystemInfo = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_statfs(export_handle, &filesystem_info));
    try std.testing.expect(filesystem_info.total_bytes > 0);
    try std.testing.expect(filesystem_info.free_bytes <= filesystem_info.total_bytes);
    try std.testing.expectEqual(filesystem_info.free_bytes, filesystem_info.available_bytes);

    var file_handle: Handle = undefined;
    var file_attributes: Attributes = undefined;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_lookup(export_handle, &root_handle, "payload", "payload".len, &file_handle, &file_attributes),
    );
    try std.testing.expectEqual(@as(u64, "direct backend".len), file_attributes.size);
    var contents: [32]u8 = undefined;
    var bytes_read: usize = 0;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_read(export_handle, &file_handle, 0, &contents, contents.len, &bytes_read),
    );
    try std.testing.expectEqualStrings("direct backend", contents[0..bytes_read]);

    var created_handle: Handle = undefined;
    var created_attributes: Attributes = undefined;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_create(
            export_handle,
            &root_handle,
            "created",
            "created".len,
            0o644,
            10,
            20,
            &created_handle,
            &created_attributes,
        ),
    );
    var bytes_written: usize = 0;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_write(
            export_handle,
            &created_handle,
            0,
            "written through ABI",
            "written through ABI".len,
            &bytes_written,
        ),
    );
    try std.testing.expectEqual(@as(usize, "written through ABI".len), bytes_written);
    try std.testing.expectEqual(status(.ok), zettide_nfs_getattr(export_handle, &created_handle, &created_attributes));
    try std.testing.expectEqual(@as(u64, "written through ABI".len), created_attributes.size);
    const changed_atime: i64 = 1_000_000_000;
    const changed_mtime: i64 = 2_000_000_000;
    const changes: SetAttributes = .{
        .mask = set_mode | set_uid | set_gid | set_size | set_atime | set_mtime,
        .size = 7,
        .atime_ns = changed_atime,
        .mtime_ns = changed_mtime,
        .mode = 0o600,
        .uid = 30,
        .gid = 40,
        .reserved = 0,
    };
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_setattr(export_handle, &created_handle, &changes, &created_attributes),
    );
    try std.testing.expectEqual(@as(u64, 7), created_attributes.size);
    try std.testing.expectEqual(@as(u32, 0o100600), created_attributes.mode);
    try std.testing.expectEqual(@as(u32, 30), created_attributes.uid);
    try std.testing.expectEqual(@as(u32, 40), created_attributes.gid);
    try std.testing.expectEqual(changed_atime, created_attributes.atime_ns);
    try std.testing.expectEqual(changed_mtime, created_attributes.mtime_ns);

    var linked_handle: Handle = undefined;
    var linked_attributes: Attributes = undefined;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_link(
            export_handle,
            &created_handle,
            &root_handle,
            "hard",
            "hard".len,
            &linked_handle,
            &linked_attributes,
        ),
    );
    try std.testing.expectEqual(@as(u64, 2), linked_attributes.nlink);

    var symlink_handle: Handle = undefined;
    var symlink_attributes: Attributes = undefined;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_symlink(
            export_handle,
            &root_handle,
            "symbolic",
            "symbolic".len,
            "created",
            "created".len,
            10,
            20,
            &symlink_handle,
            &symlink_attributes,
        ),
    );
    var target_buffer: [32]u8 = undefined;
    var target_length: usize = 0;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_readlink(
            export_handle,
            &symlink_handle,
            &target_buffer,
            target_buffer.len,
            &target_length,
        ),
    );
    try std.testing.expectEqualStrings("created", target_buffer[0..target_length]);

    var mismatched_symlink = try nfs_handle.decode(export_handle.filesystem.filesystem_id, &symlink_handle.bytes);
    mismatched_symlink.kind = .file;
    const mismatched_symlink_handle: Handle = .{
        .bytes = nfs_handle.encode(export_handle.filesystem.filesystem_id, mismatched_symlink),
    };
    try std.testing.expectEqual(
        status(.stale),
        zettide_nfs_read(export_handle, &mismatched_symlink_handle, 0, &contents, contents.len, &bytes_read),
    );
    try std.testing.expectEqual(
        status(.stale),
        zettide_nfs_write(export_handle, &mismatched_symlink_handle, 0, "stale", "stale".len, &bytes_written),
    );

    var new_directory_handle: Handle = undefined;
    var new_directory_attributes: Attributes = undefined;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_mkdir(
            export_handle,
            &root_handle,
            "new-directory",
            "new-directory".len,
            0o755,
            10,
            20,
            &new_directory_handle,
            &new_directory_attributes,
        ),
    );
    var parent_handle: Handle = undefined;
    var parent_attributes: Attributes = undefined;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_lookup_parent(
            export_handle,
            &new_directory_handle,
            &parent_handle,
            &parent_attributes,
        ),
    );
    try std.testing.expectEqualSlices(u8, &root_handle.bytes, &parent_handle.bytes);
    const directory_changes: SetAttributes = .{
        .mask = set_mode,
        .size = 0,
        .atime_ns = 0,
        .mtime_ns = 0,
        .mode = 0o700,
        .uid = 0,
        .gid = 0,
        .reserved = 0,
    };
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_setattr(
            export_handle,
            &new_directory_handle,
            &directory_changes,
            &new_directory_attributes,
        ),
    );
    try std.testing.expectEqual(@as(u32, 0o40700), new_directory_attributes.mode);
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_rename(
            export_handle,
            &root_handle,
            "created",
            "created".len,
            &new_directory_handle,
            "moved",
            "moved".len,
            false,
        ),
    );
    try std.testing.expectEqual(status(.ok), zettide_nfs_remove(export_handle, &root_handle, "hard", "hard".len));
    try std.testing.expectEqual(status(.ok), zettide_nfs_remove(export_handle, &root_handle, "symbolic", "symbolic".len));
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_remove(export_handle, &new_directory_handle, "moved", "moved".len),
    );
    try std.testing.expectEqual(status(.stale), zettide_nfs_getattr(export_handle, &created_handle, &created_attributes));
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_remove(export_handle, &root_handle, "new-directory", "new-directory".len),
    );
    try std.testing.expectEqual(status(.ok), zettide_nfs_sync(export_handle));

    var directory: *Directory = undefined;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_directory_open(export_handle, &root_handle, 0, &directory),
    );
    var directory_open = true;
    defer if (directory_open) {
        _ = zettide_nfs_directory_close(directory);
    };
    var found_payload = false;
    while (true) {
        var entry: DirectoryEntry = undefined;
        var has_entry = false;
        try std.testing.expectEqual(status(.ok), zettide_nfs_directory_read(directory, &entry, &has_entry));
        if (!has_entry) break;
        found_payload = found_payload or std.mem.eql(u8, std.mem.sliceTo(&entry.name, 0), "payload");
    }
    try std.testing.expect(found_payload);
    try std.testing.expectEqual(status(.ok), zettide_nfs_directory_close(directory));
    directory_open = false;
    try std.testing.expectEqual(status(.ok), zettide_nfs_export_close(export_handle));
    export_open = false;
}

test "direct NFS backend exports standalone BlobFilesystem" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const suffix = "/nfs-blob.img";
    @memcpy(path_buffer[root_length .. root_length + suffix.len], suffix);
    const path = path_buffer[0 .. root_length + suffix.len];
    try zettide.filesystem_target.formatNewBlobFile(
        std.testing.io,
        std.testing.allocator,
        path,
        8 * 1024 * 1024,
        .portable_v1,
        .{},
    );
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);

    var export_handle: *Export = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_export_open(path_z, true, &export_handle));
    var export_open = true;
    defer if (export_open) {
        _ = zettide_nfs_export_close(export_handle);
    };
    var root_handle: Handle = undefined;
    var root_attributes: Attributes = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_root(export_handle, &root_handle, &root_attributes));
    try std.testing.expectEqual(@intFromEnum(zettide.metadata.Kind.directory), root_attributes.kind);

    var file_handle: Handle = undefined;
    var file_attributes: Attributes = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_create(
        export_handle,
        &root_handle,
        "payload",
        "payload".len,
        0o640,
        10,
        20,
        &file_handle,
        &file_attributes,
    ));
    var written: usize = 0;
    try std.testing.expectEqual(status(.ok), zettide_nfs_write(
        export_handle,
        &file_handle,
        0,
        "blob through NFS",
        "blob through NFS".len,
        &written,
    ));
    try std.testing.expectEqual(@as(usize, "blob through NFS".len), written);
    try std.testing.expect(export_handle.owner.blob.native.dirty);

    var decoded_stale = try nfs_handle.decode(export_handle.filesystem.filesystem_id, &file_handle.bytes);
    const stale_generation = std.mem.readInt(u64, decoded_stale.identity[8..16], .little) + 1;
    std.mem.writeInt(u64, decoded_stale.identity[8..16], stale_generation, .little);
    const stale_handle: Handle = .{
        .bytes = nfs_handle.encode(export_handle.filesystem.filesystem_id, decoded_stale),
    };
    var stale_buffer: [16]u8 = undefined;
    var stale_amount: usize = 0;
    try std.testing.expectEqual(
        status(.stale),
        zettide_nfs_read(export_handle, &stale_handle, 0, &stale_buffer, stale_buffer.len, &stale_amount),
    );
    try std.testing.expectEqual(
        status(.stale),
        zettide_nfs_write(export_handle, &stale_handle, 0, "stale", "stale".len, &stale_amount),
    );
    export_handle.owner.blob.native.frozen = true;
    try std.testing.expectEqual(
        status(.stale),
        zettide_nfs_write(export_handle, &stale_handle, 0, "stale", "stale".len, &stale_amount),
    );
    export_handle.owner.blob.native.frozen = false;
    try std.testing.expectEqual(status(.ok), zettide_nfs_sync(export_handle));
    try std.testing.expect(!export_handle.owner.blob.native.dirty);
    try std.testing.expectEqual(
        status(.stale),
        zettide_nfs_read(export_handle, &stale_handle, 0, &stale_buffer, stale_buffer.len, &stale_amount),
    );

    var directory_handle: Handle = undefined;
    var directory_attributes: Attributes = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_mkdir(
        export_handle,
        &root_handle,
        "directory",
        "directory".len,
        0o755,
        10,
        20,
        &directory_handle,
        &directory_attributes,
    ));
    var parent_handle: Handle = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_lookup_parent(
        export_handle,
        &directory_handle,
        &parent_handle,
        &root_attributes,
    ));
    try std.testing.expectEqualSlices(u8, &root_handle.bytes, &parent_handle.bytes);

    var directory: *Directory = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_directory_open(export_handle, &root_handle, 0, &directory));
    var found_payload = false;
    while (true) {
        var entry: DirectoryEntry = undefined;
        var has_entry = false;
        try std.testing.expectEqual(status(.ok), zettide_nfs_directory_read(directory, &entry, &has_entry));
        if (!has_entry) break;
        found_payload = found_payload or std.mem.eql(u8, std.mem.sliceTo(&entry.name, 0), "payload");
    }
    try std.testing.expect(found_payload);
    try std.testing.expectEqual(status(.ok), zettide_nfs_directory_close(directory));
    try std.testing.expectEqual(status(.ok), zettide_nfs_export_close(export_handle));
    export_open = false;

    try std.testing.expectEqual(status(.ok), zettide_nfs_export_open(path_z, false, &export_handle));
    export_open = true;
    var reopened_root: Handle = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_root(export_handle, &reopened_root, &root_attributes));
    try std.testing.expectEqualSlices(u8, &root_handle.bytes, &reopened_root.bytes);
    try std.testing.expectEqual(
        status(.stale),
        zettide_nfs_write(export_handle, &stale_handle, 0, "stale", "stale".len, &stale_amount),
    );
    try std.testing.expectEqual(
        status(.read_only),
        zettide_nfs_write(export_handle, &file_handle, 0, "read only", "read only".len, &stale_amount),
    );
    var contents: [32]u8 = undefined;
    var amount: usize = 0;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_read(export_handle, &file_handle, 0, &contents, contents.len, &amount),
    );
    try std.testing.expectEqualStrings("blob through NFS", contents[0..amount]);
    try std.testing.expectEqual(status(.ok), zettide_nfs_export_close(export_handle));
    export_open = false;
}

test "direct NFS backend exports a single-member Blob Pool" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const member_name = "nfs-blob-pool-member";
    var storages = [_]zettide.v3.storage.Storage{
        try zettide.v3.storage.Storage.createFile(std.testing.io, tmp.dir, member_name, 16 * 1024 * 1024),
    };
    const outcome = try zettide.v3.pool_provision.create(
        std.testing.io,
        std.testing.allocator,
        &storages,
        .{ .protection = .unprotected, .data_mode = .blob },
    );
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    var native = try zettide.filesystem_target.formatProvisionedBlobPool(
        std.testing.allocator,
        std.testing.io,
        &provisioned,
        .portable_v1,
        .{},
    );
    try native.close(std.testing.io);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    path_buffer[root_length] = '/';
    @memcpy(path_buffer[root_length + 1 .. root_length + 1 + member_name.len], member_name);
    const path_z = try std.testing.allocator.dupeSentinel(u8, path_buffer[0 .. root_length + 1 + member_name.len], 0);
    defer std.testing.allocator.free(path_z);

    var export_handle: *Export = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_export_open(path_z, true, &export_handle));
    var root_handle: Handle = undefined;
    var root_attributes: Attributes = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_root(export_handle, &root_handle, &root_attributes));
    var file_handle: Handle = undefined;
    var file_attributes: Attributes = undefined;
    try std.testing.expectEqual(status(.ok), zettide_nfs_create(
        export_handle,
        &root_handle,
        "pool-data",
        "pool-data".len,
        0o600,
        1,
        2,
        &file_handle,
        &file_attributes,
    ));
    var amount: usize = 0;
    try std.testing.expectEqual(status(.ok), zettide_nfs_write(
        export_handle,
        &file_handle,
        0,
        "persistent",
        "persistent".len,
        &amount,
    ));
    try std.testing.expectEqual(status(.ok), zettide_nfs_export_close(export_handle));

    try std.testing.expectEqual(status(.ok), zettide_nfs_export_open(path_z, false, &export_handle));
    var contents: [16]u8 = undefined;
    amount = 0;
    try std.testing.expectEqual(
        status(.ok),
        zettide_nfs_read(export_handle, &file_handle, 0, &contents, contents.len, &amount),
    );
    try std.testing.expectEqualStrings("persistent", contents[0..amount]);
    try std.testing.expectEqual(status(.ok), zettide_nfs_export_close(export_handle));
}
