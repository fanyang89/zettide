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

const FuseFileHandle = struct {
    file: volume_mod.FileHandle,
    path: [:0]u8,
    append: bool,
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

    var argv = [_][*c]u8{
        program.ptr,
        foreground.ptr,
        single_thread.ptr,
        option.ptr,
        permissions.ptr,
        mountpoint_z.ptr,
    };
    var operations: c.struct_fuse_operations = std.mem.zeroes(c.struct_fuse_operations);
    operations.getattr = getAttr;
    operations.readlink = readLink;
    operations.mkdir = makeDirectory;
    operations.unlink = unlink;
    operations.rmdir = removeDirectory;
    operations.symlink = makeSymlink;
    operations.rename = rename;
    operations.chmod = changeMode;
    operations.chown = changeOwner;
    operations.truncate = truncate;
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
    operations.utimens = updateTimes;

    const result = c.devdrive_fuse_main(
        argv.len,
        &argv,
        &operations,
        volume,
    );
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

fn currentVolume() *volume_mod.Volume {
    const context = c.fuse_get_context().?;
    return @ptrCast(@alignCast(context[0].private_data.?));
}

fn getAttr(path_raw: ?[*:0]const u8, stat_raw: ?*c.struct_stat, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const info = currentVolume().stat(path_raw.?) catch |err| return errno(err);
    const stat = stat_raw.?;
    stat.* = std.mem.zeroes(c.struct_stat);
    stat.st_mode = info.metadata.mode;
    stat.st_nlink = if (info.metadata.kind == .directory) 2 else 1;
    stat.st_uid = info.metadata.uid;
    stat.st_gid = info.metadata.gid;
    stat.st_size = info.size;
    stat.st_blksize = 4096;
    stat.st_blocks = @intCast(std.math.divCeil(u64, info.size, 512) catch 0);
    setTimespec(&stat.st_atim, info.metadata.atime_ns);
    setTimespec(&stat.st_mtim, info.metadata.mtime_ns);
    setTimespec(&stat.st_ctim, info.metadata.ctime_ns);
    return 0;
}

fn readLink(path_raw: ?[*:0]const u8, buffer_raw: ?[*]u8, size: usize) callconv(.c) c_int {
    if (size == 0) return -c.EINVAL;
    const volume = currentVolume();
    const info = volume.stat(path_raw.?) catch |err| return errno(err);
    if (info.metadata.kind != .symlink) return -c.EINVAL;
    const handle = std.heap.c_allocator.create(volume_mod.FileHandle) catch return -c.ENOMEM;
    defer std.heap.c_allocator.destroy(handle);
    volume.openFile(handle, path_raw.?, lfs.LFS_O_RDONLY, 0, 0, 0) catch |err| return errno(err);
    defer volume.closeFile(handle) catch {};
    const buffer = buffer_raw.?[0..size];
    const amount = volume.readFile(handle, buffer[0 .. size - 1], 0) catch |err| return errno(err);
    buffer[amount] = 0;
    return 0;
}

fn makeDirectory(path_raw: ?[*:0]const u8, mode: c.mode_t) callconv(.c) c_int {
    const context = c.fuse_get_context().?;
    const permissions = @as(u32, mode) & ~@as(u32, context[0].umask);
    currentVolume().makeDirectory(path_raw.?, permissions | 0o040000, context[0].uid, context[0].gid) catch |err|
        return errno(err);
    return 0;
}

fn unlink(path_raw: ?[*:0]const u8) callconv(.c) c_int {
    const volume = currentVolume();
    const info = volume.stat(path_raw.?) catch |err| return errno(err);
    if (info.metadata.kind == .directory) return -c.EISDIR;
    volume.remove(path_raw.?) catch |err| return errno(err);
    return 0;
}

fn removeDirectory(path_raw: ?[*:0]const u8) callconv(.c) c_int {
    const volume = currentVolume();
    const info = volume.stat(path_raw.?) catch |err| return errno(err);
    if (info.metadata.kind != .directory) return -c.ENOTDIR;
    volume.remove(path_raw.?) catch |err| return errno(err);
    return 0;
}

fn makeSymlink(target_raw: ?[*:0]const u8, path_raw: ?[*:0]const u8) callconv(.c) c_int {
    const context = c.fuse_get_context().?;
    const volume = currentVolume();
    const handle = std.heap.c_allocator.create(volume_mod.FileHandle) catch return -c.ENOMEM;
    defer std.heap.c_allocator.destroy(handle);
    volume.openFile(handle, path_raw.?, lfs.LFS_O_CREAT | lfs.LFS_O_EXCL | lfs.LFS_O_WRONLY, 0o120777, context[0].uid, context[0].gid) catch |err|
        return errno(err);
    handle.metadata.kind = .symlink;
    const target = std.mem.span(target_raw.?);
    _ = volume.writeFile(handle, target, 0) catch |err| {
        volume.closeFile(handle) catch {};
        volume.remove(path_raw.?) catch {};
        return errno(err);
    };
    volume.closeFile(handle) catch |err| return errno(err);
    return 0;
}

fn rename(old_raw: ?[*:0]const u8, new_raw: ?[*:0]const u8, flags: c_uint) callconv(.c) c_int {
    const rename_noreplace: c_uint = 1;
    if (flags & ~rename_noreplace != 0) return -c.EINVAL;
    const volume = currentVolume();
    if (flags & rename_noreplace != 0) {
        if (volume.stat(new_raw.?)) |_| {
            return -c.EEXIST;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return errno(err),
        }
    }
    volume.rename(old_raw.?, new_raw.?) catch |err| return errno(err);
    return 0;
}

fn changeMode(path_raw: ?[*:0]const u8, mode: c.mode_t, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const volume = currentVolume();
    if (fi) |file_info| {
        const handle = fuseFileHandle(file_info);
        if (handle.append) return changeMode(path_raw, mode, null);
        handle.file.metadata.mode = (handle.file.metadata.mode & 0o170000) | (@as(u32, mode) & 0o7777);
        handle.file.metadata.ctime_ns = now(volume.io);
        return 0;
    }
    var info = volume.stat(path_raw.?) catch |err| return errno(err);
    info.metadata.mode = (info.metadata.mode & 0o170000) | (@as(u32, mode) & 0o7777);
    info.metadata.ctime_ns = now(volume.io);
    volume.setMetadata(path_raw.?, info.metadata) catch |err| return errno(err);
    return 0;
}

fn changeOwner(path_raw: ?[*:0]const u8, uid: c.uid_t, gid: c.gid_t, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const volume = currentVolume();
    if (fi) |file_info| {
        const handle = fuseFileHandle(file_info);
        if (handle.append) return changeOwner(path_raw, uid, gid, null);
        if (uid != std.math.maxInt(c.uid_t)) handle.file.metadata.uid = uid;
        if (gid != std.math.maxInt(c.gid_t)) handle.file.metadata.gid = gid;
        handle.file.metadata.ctime_ns = now(volume.io);
        return 0;
    }
    var info = volume.stat(path_raw.?) catch |err| return errno(err);
    if (uid != std.math.maxInt(c.uid_t)) info.metadata.uid = uid;
    if (gid != std.math.maxInt(c.gid_t)) info.metadata.gid = gid;
    info.metadata.ctime_ns = now(volume.io);
    volume.setMetadata(path_raw.?, info.metadata) catch |err| return errno(err);
    return 0;
}

fn truncate(path_raw: ?[*:0]const u8, size: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    if (size < 0 or size > std.math.maxInt(u32)) return -c.EFBIG;
    const volume = currentVolume();
    if (fi) |file_info| {
        const handle = fuseFileHandle(file_info);
        if (handle.append) {
            truncateByPath(volume, handle, @intCast(size)) catch |err| return errno(err);
        } else {
            volume.truncateFile(&handle.file, @intCast(size)) catch |err| return errno(err);
            volume.syncFile(&handle.file) catch |err| return errno(err);
        }
        return 0;
    }
    const handle = std.heap.c_allocator.create(volume_mod.FileHandle) catch return -c.ENOMEM;
    defer std.heap.c_allocator.destroy(handle);
    volume.openFile(handle, path_raw.?, lfs.LFS_O_RDWR, 0, 0, 0) catch |err| return errno(err);
    volume.truncateFile(handle, @intCast(size)) catch |err| {
        volume.closeFile(handle) catch {};
        return errno(err);
    };
    volume.closeFile(handle) catch |err| return errno(err);
    return 0;
}

fn open(path_raw: ?[*:0]const u8, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    return openInternal(path_raw.?, fi_raw.?, false, 0);
}

fn create(path_raw: ?[*:0]const u8, mode: c.mode_t, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    return openInternal(path_raw.?, fi_raw.?, true, mode);
}

fn openInternal(path: [*:0]const u8, fi: *c.struct_fuse_file_info, create_file: bool, mode: c.mode_t) c_int {
    const handle = std.heap.c_allocator.create(FuseFileHandle) catch return -c.ENOMEM;
    handle.path = std.heap.c_allocator.dupeZ(u8, std.mem.span(path)) catch {
        std.heap.c_allocator.destroy(handle);
        return -c.ENOMEM;
    };
    const context = c.fuse_get_context().?;
    const host_flags = c.devdrive_fuse_get_flags(fi);
    handle.append = host_flags & c.O_APPEND != 0;
    var flags: c_int = switch (host_flags & 3) {
        0 => lfs.LFS_O_RDONLY,
        // littlefs only loads configured attributes for handles with read access.
        1 => lfs.LFS_O_RDWR,
        else => lfs.LFS_O_RDWR,
    };
    if (create_file) flags |= lfs.LFS_O_CREAT | lfs.LFS_O_EXCL;
    if (!create_file and host_flags & c.O_TRUNC != 0) flags |= lfs.LFS_O_TRUNC;
    const permissions = if (create_file)
        @as(u32, mode) & ~@as(u32, context[0].umask)
    else
        @as(u32, mode);
    currentVolume().openFile(&handle.file, handle.path.ptr, flags, permissions | 0o100000, context[0].uid, context[0].gid) catch |err| {
        std.heap.c_allocator.free(handle.path);
        std.heap.c_allocator.destroy(handle);
        return errno(err);
    };
    if (handle.append) {
        currentVolume().closeFile(&handle.file) catch |err| {
            std.heap.c_allocator.free(handle.path);
            std.heap.c_allocator.destroy(handle);
            return errno(err);
        };
        currentVolume().openFile(&handle.file, handle.path.ptr, lfs.LFS_O_RDONLY, 0, 0, 0) catch |err| {
            std.heap.c_allocator.free(handle.path);
            std.heap.c_allocator.destroy(handle);
            return errno(err);
        };
    }
    c.devdrive_fuse_set_handle(fi, @intFromPtr(handle));
    return 0;
}

fn read(path: ?[*:0]const u8, buffer_raw: ?[*]u8, size: usize, offset: c.off_t, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = path;
    if (offset < 0 or offset > std.math.maxInt(u32) or size > std.math.maxInt(u32)) return -c.EFBIG;
    const handle = fuseFileHandle(fi_raw.?);
    const previous_atime = handle.file.metadata.atime_ns;
    const amount = currentVolume().readFile(&handle.file, buffer_raw.?[0..size], @intCast(offset)) catch |err| return errno(err);
    if (handle.file.metadata.atime_ns != previous_atime) {
        currentVolume().persistMetadata(&handle.file) catch |err| switch (err) {
            error.FileNotFound, error.AttributeNotFound => {},
            else => return errno(err),
        };
    }
    return @intCast(amount);
}

fn write(path: ?[*:0]const u8, data_raw: ?[*]const u8, size: usize, offset: c.off_t, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = path;
    if (offset < 0 or offset > std.math.maxInt(u32) or size > std.math.maxInt(u32)) return -c.EFBIG;
    const handle = fuseFileHandle(fi_raw.?);
    const amount = if (handle.append)
        appendFile(currentVolume(), handle, data_raw.?[0..size]) catch |err| return errno(err)
    else
        currentVolume().writeFile(&handle.file, data_raw.?[0..size], @intCast(offset)) catch |err| return errno(err);
    return @intCast(amount);
}

fn statFs(path: ?[*:0]const u8, stat_raw: ?*c.struct_statvfs) callconv(.c) c_int {
    _ = path;
    const volume = currentVolume();
    const used = volume.usedBlocks() catch |err| return errno(err);
    const stat = stat_raw.?;
    stat.* = std.mem.zeroes(c.struct_statvfs);
    stat.f_bsize = volume.header.block_size;
    stat.f_frsize = volume.header.block_size;
    stat.f_blocks = volume.header.block_count;
    stat.f_bfree = volume.header.block_count - used;
    stat.f_bavail = stat.f_bfree;
    stat.f_namemax = volume.header.name_max;
    return 0;
}

fn flush(path: ?[*:0]const u8, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const handle = fuseFileHandle(fi_raw.?);
    _ = path;
    currentVolume().syncFile(&handle.file) catch |err| return errno(err);
    return 0;
}

fn fsync(path: ?[*:0]const u8, datasync: c_int, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = datasync;
    return flush(path, fi_raw);
}

fn release(path: ?[*:0]const u8, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const handle = fuseFileHandle(fi_raw.?);
    _ = path;
    defer {
        std.heap.c_allocator.free(handle.path);
        std.heap.c_allocator.destroy(handle);
    }
    currentVolume().closeFile(&handle.file) catch |err| return errno(err);
    return 0;
}

fn openDirectory(path_raw: ?[*:0]const u8, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const handle = std.heap.c_allocator.create(volume_mod.DirectoryHandle) catch return -c.ENOMEM;
    handle.* = .{};
    currentVolume().openDirectory(handle, path_raw.?) catch |err| {
        std.heap.c_allocator.destroy(handle);
        return errno(err);
    };
    c.devdrive_fuse_set_handle(fi_raw.?, @intFromPtr(handle));
    return 0;
}

fn readDirectory(path: ?[*:0]const u8, buffer: ?*anyopaque, filler: c.fuse_fill_dir_t, offset: c.off_t, fi_raw: ?*c.struct_fuse_file_info, flags: c.enum_fuse_readdir_flags) callconv(.c) c_int {
    _ = path;
    _ = flags;
    if (offset < 0 or offset > std.math.maxInt(u32)) return -c.EINVAL;
    const volume = currentVolume();
    const handle: *volume_mod.DirectoryHandle = @ptrFromInt(c.devdrive_fuse_get_handle(fi_raw.?));
    volume.seekDirectory(handle, @intCast(offset)) catch |err| return errno(err);
    while (true) {
        var info: lfs.struct_lfs_info = undefined;
        const has_entry = volume.readDirectory(handle, &info) catch |err| return errno(err);
        if (!has_entry) break;
        const next_offset = volume.tellDirectory(handle) catch |err| return errno(err);
        if (filler.?(buffer, @ptrCast(&info.name), null, next_offset, 0) != 0) break;
    }
    return 0;
}

fn releaseDirectory(path: ?[*:0]const u8, fi_raw: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = path;
    const handle: *volume_mod.DirectoryHandle = @ptrFromInt(c.devdrive_fuse_get_handle(fi_raw.?));
    defer std.heap.c_allocator.destroy(handle);
    currentVolume().closeDirectory(handle) catch |err| return errno(err);
    return 0;
}

fn updateTimes(path_raw: ?[*:0]const u8, times_raw: ?[*]const c.struct_timespec, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    const volume = currentVolume();
    const times = times_raw.?[0..2];
    if (times[0].tv_nsec == c.UTIME_OMIT and times[1].tv_nsec == c.UTIME_OMIT) return 0;
    if (fi) |file_info| {
        const handle = fuseFileHandle(file_info);
        if (handle.append) return updateTimes(path_raw, times_raw, null);
        handle.file.metadata.atime_ns = timespecNs(times[0], handle.file.metadata.atime_ns, volume.io);
        handle.file.metadata.mtime_ns = timespecNs(times[1], handle.file.metadata.mtime_ns, volume.io);
        handle.file.metadata.ctime_ns = now(volume.io);
        return 0;
    }
    var info = volume.stat(path_raw.?) catch |err| return errno(err);
    info.metadata.atime_ns = timespecNs(times[0], info.metadata.atime_ns, volume.io);
    info.metadata.mtime_ns = timespecNs(times[1], info.metadata.mtime_ns, volume.io);
    info.metadata.ctime_ns = now(volume.io);
    volume.setMetadata(path_raw.?, info.metadata) catch |err| return errno(err);
    return 0;
}

fn timespecNs(value: c.struct_timespec, current: i64, io: Io) i64 {
    if (value.tv_nsec == c.UTIME_OMIT) return current;
    if (value.tv_nsec == c.UTIME_NOW) return now(io);
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

fn appendFile(volume: *volume_mod.Volume, handle: *FuseFileHandle, data: []const u8) !usize {
    var current: volume_mod.FileHandle = undefined;
    try volume.openFile(&current, handle.path.ptr, lfs.LFS_O_RDWR | lfs.LFS_O_APPEND, 0, 0, 0);
    errdefer volume.closeFile(&current) catch {};
    const amount = try volume.writeFile(&current, data, 0);
    try volume.closeFile(&current);

    try volume.closeFile(&handle.file);
    try volume.openFile(&handle.file, handle.path.ptr, lfs.LFS_O_RDONLY, 0, 0, 0);
    return amount;
}

fn truncateByPath(volume: *volume_mod.Volume, handle: *FuseFileHandle, size: u32) !void {
    var current: volume_mod.FileHandle = undefined;
    try volume.openFile(&current, handle.path.ptr, lfs.LFS_O_RDWR, 0, 0, 0);
    errdefer volume.closeFile(&current) catch {};
    try volume.truncateFile(&current, size);
    try volume.closeFile(&current);

    try volume.closeFile(&handle.file);
    try volume.openFile(&handle.file, handle.path.ptr, lfs.LFS_O_RDONLY, 0, 0, 0);
}

fn errno(err: anyerror) c_int {
    const value: c_int = switch (err) {
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
    return -value;
}
