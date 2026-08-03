const std = @import("std");
const metadata = @import("metadata.zig");

pub const FileId = [16]u8;
pub const name_capacity = 256;

pub const NodeInfo = struct {
    size: u64,
    allocated_bytes: u64,
    metadata: metadata.Metadata,
    file_id: ?FileId,
    identity: FileId,
    nlink: u64,
};

pub const RenameResult = enum {
    renamed,
    same_object,
};

pub const SpaceInfo = struct {
    block_size: u32,
    total_blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
    name_max: u32,
};

pub const AccessMode = enum {
    read_only,
    read_write,
};

pub const OpenOptions = struct {
    access: AccessMode,
    create: bool = false,
    exclusive: bool = false,
    truncate: bool = false,
    append: bool = false,
};

pub const CreateAttributes = struct {
    mode: u32,
    uid: u32,
    gid: u32,
};

pub const DirectoryEntry = struct {
    kind: Kind,
    name_buffer: [name_capacity:0]u8,

    pub const Kind = enum {
        file,
        directory,
    };

    pub fn name(self: *const DirectoryEntry) [:0]const u8 {
        return std.mem.sliceTo(&self.name_buffer, 0);
    }
};

pub const Filesystem = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stat_path: *const fn (*anyopaque, [*:0]const u8) anyerror!NodeInfo,
        stat_file_id: *const fn (*anyopaque, FileId) anyerror!NodeInfo,
        pin_file: *const fn (*anyopaque, FileId) anyerror!void,
        unpin_file: *const fn (*anyopaque, FileId) anyerror!void,
        set_metadata: *const fn (*anyopaque, [*:0]const u8, metadata.Metadata) anyerror!void,
        patch_metadata: *const fn (*anyopaque, FileId, metadata.Patch) anyerror!metadata.Metadata,
        make_directory: *const fn (*anyopaque, [*:0]const u8, CreateAttributes) anyerror!void,
        make_symlink: *const fn (*anyopaque, [*:0]const u8, []const u8, u32, u32) anyerror!void,
        make_fifo: *const fn (*anyopaque, [*:0]const u8, CreateAttributes) anyerror!void,
        link: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) anyerror!NodeInfo,
        remove: *const fn (*anyopaque, [*:0]const u8) anyerror!void,
        rename: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8, bool) anyerror!RenameResult,
        read_special: *const fn (*anyopaque, FileId, []u8, u64) anyerror!usize,
        open_file: *const fn (*anyopaque, std.mem.Allocator, [*:0]const u8, OpenOptions, CreateAttributes) anyerror!FileHandle,
        open_file_id: *const fn (*anyopaque, std.mem.Allocator, FileId, OpenOptions) anyerror!FileHandle,
        open_directory: *const fn (*anyopaque, std.mem.Allocator, [*:0]const u8) anyerror!DirectoryHandle,
        sync: *const fn (*anyopaque) anyerror!void,
        space_info: *const fn (*anyopaque) anyerror!SpaceInfo,
    };

    pub fn statPath(self: Filesystem, path: [*:0]const u8) !NodeInfo {
        return self.vtable.stat_path(self.context, path);
    }

    pub fn statFileId(self: Filesystem, file_id: FileId) !NodeInfo {
        return self.vtable.stat_file_id(self.context, file_id);
    }

    pub fn pinFile(self: Filesystem, file_id: FileId) !void {
        return self.vtable.pin_file(self.context, file_id);
    }

    pub fn unpinFile(self: Filesystem, file_id: FileId) !void {
        return self.vtable.unpin_file(self.context, file_id);
    }

    pub fn setMetadata(self: Filesystem, path: [*:0]const u8, value: metadata.Metadata) !void {
        return self.vtable.set_metadata(self.context, path, value);
    }

    pub fn patchMetadata(self: Filesystem, file_id: FileId, patch: metadata.Patch) !metadata.Metadata {
        return self.vtable.patch_metadata(self.context, file_id, patch);
    }

    pub fn makeDirectory(self: Filesystem, path: [*:0]const u8, attributes: CreateAttributes) !void {
        return self.vtable.make_directory(self.context, path, attributes);
    }

    pub fn makeSymlink(self: Filesystem, path: [*:0]const u8, target: []const u8, uid: u32, gid: u32) !void {
        return self.vtable.make_symlink(self.context, path, target, uid, gid);
    }

    pub fn makeFifo(self: Filesystem, path: [*:0]const u8, attributes: CreateAttributes) !void {
        return self.vtable.make_fifo(self.context, path, attributes);
    }

    pub fn link(self: Filesystem, old_path: [*:0]const u8, new_path: [*:0]const u8) !NodeInfo {
        return self.vtable.link(self.context, old_path, new_path);
    }

    pub fn remove(self: Filesystem, path: [*:0]const u8) !void {
        return self.vtable.remove(self.context, path);
    }

    pub fn rename(self: Filesystem, old_path: [*:0]const u8, new_path: [*:0]const u8, no_replace: bool) !RenameResult {
        return self.vtable.rename(self.context, old_path, new_path, no_replace);
    }

    pub fn readSpecial(self: Filesystem, file_id: FileId, buffer: []u8, offset: u64) !usize {
        return self.vtable.read_special(self.context, file_id, buffer, offset);
    }

    pub fn openFile(
        self: Filesystem,
        allocator: std.mem.Allocator,
        path: [*:0]const u8,
        options: OpenOptions,
        attributes: CreateAttributes,
    ) !FileHandle {
        return self.vtable.open_file(self.context, allocator, path, options, attributes);
    }

    pub fn openFileId(
        self: Filesystem,
        allocator: std.mem.Allocator,
        file_id: FileId,
        options: OpenOptions,
    ) !FileHandle {
        return self.vtable.open_file_id(self.context, allocator, file_id, options);
    }

    pub fn openDirectory(self: Filesystem, allocator: std.mem.Allocator, path: [*:0]const u8) !DirectoryHandle {
        return self.vtable.open_directory(self.context, allocator, path);
    }

    pub fn sync(self: Filesystem) !void {
        return self.vtable.sync(self.context);
    }

    pub fn spaceInfo(self: Filesystem) !SpaceInfo {
        return self.vtable.space_info(self.context);
    }
};

/// A move-only backend file handle. `close` consumes the handle even on error.
pub const FileHandle = struct {
    context: *anyopaque,
    allocator: std.mem.Allocator,
    vtable: *const VTable,

    pub const VTable = struct {
        stat: *const fn (*anyopaque) anyerror!NodeInfo,
        file_id: *const fn (*anyopaque) FileId,
        read: *const fn (*anyopaque, []u8, u64) anyerror!usize,
        write: *const fn (*anyopaque, []const u8, u64) anyerror!usize,
        truncate: *const fn (*anyopaque, u64) anyerror!void,
        fallocate: *const fn (*anyopaque, u64, u64) anyerror!void,
        sync: *const fn (*anyopaque) anyerror!void,
        set_metadata: *const fn (*anyopaque, metadata.Metadata) anyerror!void,
        patch_metadata: *const fn (*anyopaque, metadata.Patch) anyerror!metadata.Metadata,
        close: *const fn (*anyopaque) anyerror!void,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn stat(self: FileHandle) !NodeInfo {
        return self.vtable.stat(self.context);
    }

    pub fn fileId(self: FileHandle) FileId {
        return self.vtable.file_id(self.context);
    }

    pub fn read(self: FileHandle, buffer: []u8, offset: u64) !usize {
        return self.vtable.read(self.context, buffer, offset);
    }

    pub fn write(self: FileHandle, data: []const u8, offset: u64) !usize {
        return self.vtable.write(self.context, data, offset);
    }

    pub fn truncate(self: FileHandle, size: u64) !void {
        return self.vtable.truncate(self.context, size);
    }

    pub fn fallocate(self: FileHandle, offset: u64, length: u64) !void {
        return self.vtable.fallocate(self.context, offset, length);
    }

    pub fn sync(self: FileHandle) !void {
        return self.vtable.sync(self.context);
    }

    pub fn setMetadata(self: FileHandle, value: metadata.Metadata) !void {
        return self.vtable.set_metadata(self.context, value);
    }

    pub fn patchMetadata(self: FileHandle, patch: metadata.Patch) !metadata.Metadata {
        return self.vtable.patch_metadata(self.context, patch);
    }

    pub fn close(self: *FileHandle) !void {
        const context = self.context;
        const allocator = self.allocator;
        const vtable = self.vtable;
        self.* = undefined;
        defer vtable.destroy(context, allocator);
        return vtable.close(context);
    }
};

/// A move-only backend directory handle. `close` consumes it even on error.
pub const DirectoryHandle = struct {
    context: *anyopaque,
    allocator: std.mem.Allocator,
    vtable: *const VTable,

    pub const VTable = struct {
        info: *const fn (*anyopaque) NodeInfo,
        read: *const fn (*anyopaque, *DirectoryEntry) anyerror!bool,
        seek: *const fn (*anyopaque, u32) anyerror!void,
        tell: *const fn (*anyopaque) anyerror!u32,
        sync: *const fn (*anyopaque) anyerror!void,
        close: *const fn (*anyopaque) anyerror!void,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn info(self: DirectoryHandle) NodeInfo {
        return self.vtable.info(self.context);
    }

    pub fn read(self: DirectoryHandle, entry: *DirectoryEntry) !bool {
        return self.vtable.read(self.context, entry);
    }

    pub fn seek(self: DirectoryHandle, offset: u32) !void {
        return self.vtable.seek(self.context, offset);
    }

    pub fn tell(self: DirectoryHandle) !u32 {
        return self.vtable.tell(self.context);
    }

    pub fn sync(self: DirectoryHandle) !void {
        return self.vtable.sync(self.context);
    }

    pub fn close(self: *DirectoryHandle) !void {
        const context = self.context;
        const allocator = self.allocator;
        const vtable = self.vtable;
        self.* = undefined;
        defer vtable.destroy(context, allocator);
        return vtable.close(context);
    }
};

test "file handle releases context when native close fails" {
    const Fake = struct {
        destroyed: *bool,

        fn close(_: *anyopaque) anyerror!void {
            return error.CloseFailed;
        }

        fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.destroyed.* = true;
            allocator.destroy(self);
        }
    };

    var destroyed = false;
    const context = try std.testing.allocator.create(Fake);
    context.* = .{ .destroyed = &destroyed };
    const unused = struct {
        fn stat(_: *anyopaque) anyerror!NodeInfo {
            return error.Unused;
        }
        fn fileId(_: *anyopaque) FileId {
            return @splat(0);
        }
        fn read(_: *anyopaque, _: []u8, _: u64) anyerror!usize {
            return error.Unused;
        }
        fn write(_: *anyopaque, _: []const u8, _: u64) anyerror!usize {
            return error.Unused;
        }
        fn truncate(_: *anyopaque, _: u64) anyerror!void {
            return error.Unused;
        }
        fn fallocate(_: *anyopaque, _: u64, _: u64) anyerror!void {
            return error.Unused;
        }
        fn sync(_: *anyopaque) anyerror!void {
            return error.Unused;
        }
        fn setMetadata(_: *anyopaque, _: metadata.Metadata) anyerror!void {
            return error.Unused;
        }
        fn patchMetadata(_: *anyopaque, _: metadata.Patch) anyerror!metadata.Metadata {
            return error.Unused;
        }
    };
    const vtable: FileHandle.VTable = .{
        .stat = unused.stat,
        .file_id = unused.fileId,
        .read = unused.read,
        .write = unused.write,
        .truncate = unused.truncate,
        .fallocate = unused.fallocate,
        .sync = unused.sync,
        .set_metadata = unused.setMetadata,
        .patch_metadata = unused.patchMetadata,
        .close = Fake.close,
        .destroy = Fake.destroy,
    };
    var handle: FileHandle = .{
        .context = context,
        .allocator = std.testing.allocator,
        .vtable = &vtable,
    };

    try std.testing.expectError(error.CloseFailed, handle.close());
    try std.testing.expect(destroyed);
}

test "directory handle releases context when native close fails" {
    const Fake = struct {
        destroyed: *bool,

        fn close(_: *anyopaque) anyerror!void {
            return error.CloseFailed;
        }

        fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.destroyed.* = true;
            allocator.destroy(self);
        }
    };

    var destroyed = false;
    const context = try std.testing.allocator.create(Fake);
    context.* = .{ .destroyed = &destroyed };
    const unused = struct {
        fn info(_: *anyopaque) NodeInfo {
            return undefined;
        }
        fn read(_: *anyopaque, _: *DirectoryEntry) anyerror!bool {
            return error.Unused;
        }
        fn seek(_: *anyopaque, _: u32) anyerror!void {
            return error.Unused;
        }
        fn tell(_: *anyopaque) anyerror!u32 {
            return error.Unused;
        }
        fn sync(_: *anyopaque) anyerror!void {
            return error.Unused;
        }
    };
    const vtable: DirectoryHandle.VTable = .{
        .info = unused.info,
        .read = unused.read,
        .seek = unused.seek,
        .tell = unused.tell,
        .sync = unused.sync,
        .close = Fake.close,
        .destroy = Fake.destroy,
    };
    var handle: DirectoryHandle = .{
        .context = context,
        .allocator = std.testing.allocator,
        .vtable = &vtable,
    };

    try std.testing.expectError(error.CloseFailed, handle.close());
    try std.testing.expect(destroyed);
}
