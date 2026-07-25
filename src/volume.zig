const std = @import("std");
const Io = std.Io;
const File = Io.File;
const container = @import("container.zig");
const block_device = @import("block_device.zig");
const metadata = @import("metadata.zig");
pub const c = block_device.c;

pub const Volume = struct {
    io: Io,
    file: File,
    header: container.Header,
    device: block_device.FileBlockDevice,
    config: c.struct_lfs_config,
    lfs: c.lfs_t,
    mounted: bool = false,
    fallback_uid: u32 = 0,
    fallback_gid: u32 = 0,

    pub fn create(io: Io, path: []const u8, logical_size: u64, label: []const u8) !void {
        var header = try container.Header.init(io, logical_size, label);
        const file = try Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        defer file.close(io);

        const total_size = std.math.add(u64, header.payload_start, logical_size) catch
            return error.VolumeTooLarge;
        try file.setLength(io, total_size);
        try container.write(file, io, container.header_a_offset, header);
        try container.write(file, io, container.header_b_offset, header);
        try file.sync(io);

        var device = block_device.FileBlockDevice.init(io, file, header);
        var config = device.configure(header);
        var lfs: c.lfs_t = std.mem.zeroes(c.lfs_t);
        try checkLfs(c.lfs_format(&lfs, &config));

        try checkLfs(c.lfs_mount(&lfs, &config));
        var mounted = true;
        defer {
            if (mounted) _ = c.lfs_unmount(&lfs);
        }
        const owner = hostOwner();
        const root_metadata = metadata.Metadata.init(io, .directory, 0o40755, owner.uid, owner.gid);
        const root_bytes = root_metadata.encode();
        try checkLfs(c.lfs_setattr(&lfs, "/", metadata.attribute_type, &root_bytes, root_bytes.len));
        try checkLfs(c.lfs_unmount(&lfs));
        mounted = false;

        header.state = .ready;
        header.sequence += 1;
        try container.write(file, io, container.header_b_offset, header);
        try file.sync(io);
        header.sequence += 1;
        try container.write(file, io, container.header_a_offset, header);
        try file.sync(io);
    }

    pub fn open(io: Io, path: []const u8, writable: bool) !Volume {
        const file = try Io.Dir.cwd().openFile(io, path, .{
            .mode = if (writable) .read_write else .read_only,
            .lock = if (writable) .exclusive else .shared,
            .lock_nonblocking = true,
        });
        errdefer file.close(io);
        const header = try container.read(file, io);

        var result: Volume = undefined;
        result.io = io;
        result.file = file;
        result.header = header;
        result.device = block_device.FileBlockDevice.init(io, file, header);
        result.config = result.device.configure(header);
        result.lfs = std.mem.zeroes(c.lfs_t);
        result.mounted = false;
        result.fallback_uid = 0;
        result.fallback_gid = 0;
        return result;
    }

    pub fn setFallbackOwner(self: *Volume, uid: u32, gid: u32) void {
        self.fallback_uid = uid;
        self.fallback_gid = gid;
    }

    pub fn mount(self: *Volume) !void {
        if (self.mounted) return error.AlreadyMounted;
        // Moving Volume after this call is invalid because littlefs retains these pointers.
        self.config.context = &self.device;
        try checkLfs(c.lfs_mount(&self.lfs, &self.config));
        self.mounted = true;
    }

    pub fn deinit(self: *Volume) void {
        if (self.mounted) {
            _ = c.lfs_unmount(&self.lfs);
            self.mounted = false;
        }
        self.file.close(self.io);
    }

    pub fn usedBlocks(self: *Volume) !u32 {
        const result = c.lfs_fs_size(&self.lfs);
        try checkLfs(result);
        return @intCast(result);
    }

    pub fn stat(self: *Volume, path: [*:0]const u8) !NodeInfo {
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, path, &info));
        const fallback_kind: metadata.Kind = if (info.type == c.LFS_TYPE_DIR) .directory else .file;
        const stored_metadata = self.getMetadata(path) catch |err| switch (err) {
            error.AttributeNotFound => metadata.Metadata.init(
                self.io,
                fallback_kind,
                if (fallback_kind == .directory) 0o40755 else 0o100644,
                self.fallback_uid,
                self.fallback_gid,
            ),
            else => return err,
        };
        return .{
            .size = if (info.type == c.LFS_TYPE_DIR) 0 else info.size,
            .metadata = stored_metadata,
        };
    }

    pub fn setMetadata(self: *Volume, path: [*:0]const u8, value: metadata.Metadata) !void {
        const bytes = value.encode();
        try checkLfs(c.lfs_setattr(&self.lfs, path, metadata.attribute_type, &bytes, bytes.len));
    }

    pub fn getMetadata(self: *Volume, path: [*:0]const u8) !metadata.Metadata {
        var bytes: [metadata.encoded_size]u8 = undefined;
        const result = c.lfs_getattr(&self.lfs, path, metadata.attribute_type, &bytes, bytes.len);
        if (result < 0) {
            try checkLfs(result);
            unreachable;
        }
        if (result != bytes.len) return error.InvalidMetadata;
        return metadata.Metadata.decode(&bytes);
    }

    pub fn makeDirectory(self: *Volume, path: [*:0]const u8, mode: u32, uid: u32, gid: u32) !void {
        try checkLfs(c.lfs_mkdir(&self.lfs, path));
        errdefer _ = c.lfs_remove(&self.lfs, path);
        try self.setMetadata(path, metadata.Metadata.init(self.io, .directory, mode, uid, gid));
        try self.updateParentTimes(path);
    }

    pub fn remove(self: *Volume, path: [*:0]const u8) !void {
        try checkLfs(c.lfs_remove(&self.lfs, path));
        try self.updateParentTimes(path);
    }

    pub fn rename(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !void {
        try checkLfs(c.lfs_rename(&self.lfs, old_path, new_path));
        try self.updateParentTimes(old_path);
        if (!std.mem.eql(u8, parentSlice(old_path), parentSlice(new_path)))
            try self.updateParentTimes(new_path);
        var renamed_metadata = self.getMetadata(new_path) catch |err| switch (err) {
            error.AttributeNotFound => return,
            else => return err,
        };
        renamed_metadata.ctime_ns = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        try self.setMetadata(new_path, renamed_metadata);
    }

    pub fn openFile(self: *Volume, handle: *FileHandle, path: [*:0]const u8, flags: c_int, mode: u32, uid: u32, gid: u32) !void {
        var path_existed = true;
        const existing_metadata = self.getMetadata(path) catch |err| switch (err) {
            error.FileNotFound => value: {
                path_existed = false;
                break :value null;
            },
            error.AttributeNotFound => null,
            else => return err,
        };
        handle.* = .{};
        handle.path = path;
        handle.reopen_flags = flags & ~(c.LFS_O_CREAT | c.LFS_O_EXCL | c.LFS_O_TRUNC);
        try checkLfs(c.lfs_file_open(&self.lfs, &handle.file, path, flags));
        handle.open = true;

        handle.metadata = existing_metadata orelse metadata.Metadata.init(
            self.io,
            .file,
            if (path_existed) 0o100644 else mode,
            if (path_existed) self.fallback_uid else uid,
            if (path_existed) self.fallback_gid else gid,
        );
        handle.original_metadata = handle.metadata;
        if (existing_metadata == null) try self.setMetadata(path, handle.metadata);
        if (!path_existed) try self.updateParentTimes(path);
    }

    pub fn closeFile(self: *Volume, handle: *FileHandle) !void {
        if (!handle.open) return;
        const persist_metadata = try self.mergeCurrentMetadata(handle);
        try checkLfs(c.lfs_file_close(&self.lfs, &handle.file));
        handle.open = false;
        if (persist_metadata) {
            self.setMetadata(handle.path, handle.metadata) catch |err| switch (err) {
                error.FileNotFound, error.AttributeNotFound => {},
                else => return err,
            };
        }
    }

    pub fn readFile(self: *Volume, handle: *FileHandle, buffer: []u8, offset: u32) !usize {
        try self.refreshFileHandle(handle);
        const seek_result = c.lfs_file_seek(&self.lfs, &handle.file, @intCast(offset), c.LFS_SEEK_SET);
        try checkLfs(seek_result);
        const result = c.lfs_file_read(&self.lfs, &handle.file, buffer.ptr, @intCast(buffer.len));
        try checkLfs(result);
        const timestamp: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        const one_day = 24 * std.time.ns_per_hour;
        if (handle.metadata.atime_ns <= handle.metadata.mtime_ns or
            handle.metadata.atime_ns <= handle.metadata.ctime_ns or
            timestamp -| handle.metadata.atime_ns >= one_day)
        {
            handle.metadata.atime_ns = timestamp;
        }
        return @intCast(result);
    }

    pub fn writeFile(self: *Volume, handle: *FileHandle, data: []const u8, offset: u32) !usize {
        try self.refreshFileHandle(handle);
        const seek_result = c.lfs_file_seek(&self.lfs, &handle.file, @intCast(offset), c.LFS_SEEK_SET);
        try checkLfs(seek_result);
        const result = c.lfs_file_write(&self.lfs, &handle.file, data.ptr, @intCast(data.len));
        try checkLfs(result);
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        handle.metadata.mtime_ns = now;
        handle.metadata.ctime_ns = now;
        return @intCast(result);
    }

    pub fn truncateFile(self: *Volume, handle: *FileHandle, size: u32) !void {
        try self.refreshFileHandle(handle);
        try checkLfs(c.lfs_file_truncate(&self.lfs, &handle.file, size));
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        handle.metadata.mtime_ns = now;
        handle.metadata.ctime_ns = now;
    }

    pub fn syncFile(self: *Volume, handle: *FileHandle) !void {
        const persist_metadata = try self.mergeCurrentMetadata(handle);
        try checkLfs(c.lfs_file_sync(&self.lfs, &handle.file));
        if (persist_metadata) {
            self.setMetadata(handle.path, handle.metadata) catch |err| switch (err) {
                error.FileNotFound, error.AttributeNotFound => {},
                else => return err,
            };
        }
        handle.original_metadata = handle.metadata;
    }

    pub fn persistMetadata(self: *Volume, handle: *FileHandle) !void {
        if (!try self.mergeCurrentMetadata(handle)) return;
        self.setMetadata(handle.path, handle.metadata) catch |err| switch (err) {
            error.FileNotFound, error.AttributeNotFound => return,
            else => return err,
        };
        handle.original_metadata = handle.metadata;
    }

    pub fn openDirectory(self: *Volume, handle: *DirectoryHandle, path: [*:0]const u8) !void {
        try checkLfs(c.lfs_dir_open(&self.lfs, &handle.dir, path));
        handle.open = true;
    }

    pub fn readDirectory(self: *Volume, handle: *DirectoryHandle, info: *c.struct_lfs_info) !bool {
        const result = c.lfs_dir_read(&self.lfs, &handle.dir, info);
        try checkLfs(result);
        return result > 0;
    }

    pub fn seekDirectory(self: *Volume, handle: *DirectoryHandle, offset: u32) !void {
        try checkLfs(c.lfs_dir_seek(&self.lfs, &handle.dir, offset));
    }

    pub fn tellDirectory(self: *Volume, handle: *DirectoryHandle) !u32 {
        const result = c.lfs_dir_tell(&self.lfs, &handle.dir);
        try checkLfs(result);
        return @intCast(result);
    }

    pub fn closeDirectory(self: *Volume, handle: *DirectoryHandle) !void {
        if (!handle.open) return;
        handle.open = false;
        try checkLfs(c.lfs_dir_close(&self.lfs, &handle.dir));
    }

    pub fn check(self: *Volume) !CheckResult {
        if (!self.mounted) return error.NotMounted;
        var context = CheckContext{};
        try checkLfs(c.lfs_fs_traverse(&self.lfs, traverseCallback, &context));
        return .{
            .used_blocks = context.count,
            .total_blocks = self.header.block_count,
        };
    }

    fn mergeCurrentMetadata(self: *Volume, handle: *FileHandle) !bool {
        const current = self.getMetadata(handle.path) catch |err| switch (err) {
            error.FileNotFound => return false,
            error.AttributeNotFound => return true,
            else => return err,
        };
        const original = handle.original_metadata;
        if (current.birthtime_ns != original.birthtime_ns) return false;
        var changed = handle.metadata;
        if (changed.kind == original.kind) changed.kind = current.kind;
        if (changed.mode == original.mode) changed.mode = current.mode;
        if (changed.uid == original.uid) changed.uid = current.uid;
        if (changed.gid == original.gid) changed.gid = current.gid;
        if (changed.atime_ns == original.atime_ns) changed.atime_ns = current.atime_ns;
        if (changed.mtime_ns == original.mtime_ns) changed.mtime_ns = current.mtime_ns;
        if (changed.ctime_ns == original.ctime_ns) changed.ctime_ns = current.ctime_ns;
        if (changed.birthtime_ns == original.birthtime_ns) changed.birthtime_ns = current.birthtime_ns;
        if (changed.windows_attributes == original.windows_attributes)
            changed.windows_attributes = current.windows_attributes;
        handle.metadata = changed;
        return true;
    }

    fn refreshFileHandle(self: *Volume, handle: *FileHandle) !void {
        const current = self.getMetadata(handle.path) catch |err| switch (err) {
            error.FileNotFound, error.AttributeNotFound => return,
            else => return err,
        };
        if (current.birthtime_ns != handle.original_metadata.birthtime_ns) return;

        const path = handle.path;
        const flags = handle.reopen_flags;
        try self.closeFile(handle);
        try self.openFile(handle, path, flags, 0, 0, 0);
    }

    fn updateParentTimes(self: *Volume, path: [*:0]const u8) !void {
        const parent = parentSlice(path);
        var buffer: [4096:0]u8 = @splat(0);
        if (parent.len >= buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..parent.len], parent);
        var parent_metadata = self.getMetadata(&buffer) catch |err| switch (err) {
            error.FileNotFound, error.AttributeNotFound => return,
            else => return err,
        };
        const timestamp: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        parent_metadata.mtime_ns = timestamp;
        parent_metadata.ctime_ns = timestamp;
        try self.setMetadata(&buffer, parent_metadata);
    }
};

fn parentSlice(path: [*:0]const u8) []const u8 {
    const value = std.mem.span(path);
    if (value.len <= 1) return "/";
    const separator = std.mem.lastIndexOfScalar(u8, value, '/') orelse return "/";
    return if (separator == 0) "/" else value[0..separator];
}

fn hostOwner() struct { uid: u32, gid: u32 } {
    if (@import("builtin").os.tag != .linux) return .{ .uid = 0, .gid = 0 };
    return .{ .uid = @intCast(std.os.linux.getuid()), .gid = @intCast(std.os.linux.getgid()) };
}

pub const NodeInfo = struct {
    size: u32,
    metadata: metadata.Metadata,
};

pub const FileHandle = struct {
    file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t),
    metadata: metadata.Metadata = undefined,
    original_metadata: metadata.Metadata = undefined,
    path: [*:0]const u8 = undefined,
    reopen_flags: c_int = 0,
    open: bool = false,
};

pub const DirectoryHandle = struct {
    dir: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t),
    open: bool = false,
};

pub const CheckResult = struct {
    used_blocks: u32,
    total_blocks: u32,
};

const CheckContext = struct {
    count: u32 = 0,
};

fn traverseCallback(raw: ?*anyopaque, block: c.lfs_block_t) callconv(.c) c_int {
    _ = block;
    const context: *CheckContext = @ptrCast(@alignCast(raw.?));
    context.count += 1;
    return 0;
}

pub fn checkLfs(result: anytype) !void {
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
        c.LFS_ERR_NOATTR => error.AttributeNotFound,
        else => error.LittleFsFailure,
    };
}

test "create, write, reopen, and check volume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/volume.ddv", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    try Volume.create(std.testing.io, path, 1024 * 1024, "Test");
    var volume = try Volume.open(std.testing.io, path, true);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/hello", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1000, 1000);
    try std.testing.expectEqual(@as(usize, 5), try volume.writeFile(&file, "hello", 0));
    try volume.syncFile(&file);
    try volume.closeFile(&file);

    const info = try volume.stat("/hello");
    try std.testing.expectEqual(@as(u32, 5), info.size);
    try std.testing.expectEqual(metadata.Kind.file, info.metadata.kind);

    var reopened: FileHandle = undefined;
    try volume.openFile(&reopened, "/hello", c.LFS_O_RDONLY, 0, 0, 0);
    var buffer: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try volume.readFile(&reopened, &buffer, 0));
    try std.testing.expectEqualStrings("hello", &buffer);
    try volume.closeFile(&reopened);

    const result = try volume.check();
    try std.testing.expect(result.used_blocks >= 2);
}
