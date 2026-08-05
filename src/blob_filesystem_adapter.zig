const std = @import("std");
const backend = @import("filesystem_backend.zig");
const blob_filesystem = @import("blob_filesystem.zig");
const blob_format = @import("blob_format.zig");
const filesystem_format = @import("blob_filesystem_format.zig");
const metadata = @import("metadata.zig");

const Io = std.Io;

/// A borrowed backend view of an already-open BlobFilesystem.
///
/// The adapter and all handles created through it borrow `native`; they never close it.
/// The caller must keep both the adapter and native filesystem alive until every backend
/// handle is closed. Path open resolves/creates, retains, and truncates in separate native
/// transactions; nonexclusive create uses a bounded retry after namespace races.
pub const Adapter = struct {
    native: *blob_filesystem.Filesystem,
    io: Io,

    pub fn init(native: *blob_filesystem.Filesystem, io: Io) Adapter {
        return .{ .native = native, .io = io };
    }

    pub fn filesystem(self: *Adapter) backend.Filesystem {
        return .{ .context = self, .vtable = &filesystem_vtable };
    }
};

const Identity = struct {
    inode: u64,
    generation: u64,
};

const FileContext = struct {
    native: *blob_filesystem.Filesystem,
    io: Io,
    identity: Identity,
    access: backend.AccessMode,
    append: bool,
};

const DirectoryContext = struct {
    native: *blob_filesystem.Filesystem,
    io: Io,
    inode: u64,
    info_value: backend.NodeInfo,
    snapshot: blob_filesystem.Filesystem.DirectorySnapshot,
    cookie: u32 = 0,
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
    .open_file = openFile,
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
    .read = readDirectory,
    .seek = seekDirectory,
    .tell = tellDirectory,
    .sync = syncDirectory,
    .close = closeDirectory,
    .destroy = destroyDirectory,
};

fn adapter(raw: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(raw));
}

fn fileContext(raw: *anyopaque) *FileContext {
    return @ptrCast(@alignCast(raw));
}

fn directoryContext(raw: *anyopaque) *DirectoryContext {
    return @ptrCast(@alignCast(raw));
}

fn encodeIdentity(native: *const blob_filesystem.Filesystem, identity: Identity) backend.FileId {
    var result: backend.FileId = undefined;
    std.mem.writeInt(
        u64,
        result[0..8],
        identity.inode ^ std.mem.readInt(u64, native.blobs.header.uuid[0..8], .little),
        .little,
    );
    std.mem.writeInt(
        u64,
        result[8..16],
        identity.generation ^ std.mem.readInt(u64, native.blobs.header.uuid[8..16], .little),
        .little,
    );
    return result;
}

fn decodeIdentity(native: *const blob_filesystem.Filesystem, file_id: backend.FileId) !Identity {
    const result: Identity = .{
        .inode = std.mem.readInt(u64, file_id[0..8], .little) ^
            std.mem.readInt(u64, native.blobs.header.uuid[0..8], .little),
        .generation = std.mem.readInt(u64, file_id[8..16], .little) ^
            std.mem.readInt(u64, native.blobs.header.uuid[8..16], .little),
    };
    if (result.inode == 0 or result.generation == 0) return error.InvalidFileHandle;
    return result;
}

fn validateIdentity(value: *Adapter, identity: Identity) !blob_filesystem.Filesystem.InodeRecord {
    const record = try value.native.stat(value.io, identity.inode);
    if (record.generation != identity.generation) return error.FileNotFound;
    return record;
}

fn validateFileIdentity(context: *FileContext) !blob_filesystem.Filesystem.InodeRecord {
    const record = try context.native.stat(context.io, context.identity.inode);
    if (record.generation != context.identity.generation) return error.FileNotFound;
    return record;
}

fn nodeInfo(
    native: *const blob_filesystem.Filesystem,
    inode: u64,
    record: blob_filesystem.Filesystem.InodeRecord,
) backend.NodeInfo {
    const identity = encodeIdentity(native, .{ .inode = inode, .generation = record.generation });
    return .{
        .size = if (record.data) |data| data.logical_size else 0,
        .allocated_bytes = record.allocated_bytes,
        .metadata = record.metadata,
        .file_id = if (record.metadata.kind == .directory) null else identity,
        .identity = identity,
        .nlink = record.nlink,
    };
}

fn path(value: [*:0]const u8) []const u8 {
    return std.mem.span(value);
}

const ParentAndName = struct {
    parent: []const u8,
    name: []const u8,
};

fn splitParent(input: []const u8) !ParentAndName {
    if (input.len < 2 or input[0] != '/' or input[input.len - 1] == '/' or
        std.mem.indexOfScalar(u8, input, 0) != null)
        return error.InvalidArgument;
    var components = std.mem.splitScalar(u8, input[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
            return error.InvalidArgument;
    }
    const separator = std.mem.lastIndexOfScalar(u8, input, '/') orelse unreachable;
    return .{
        .parent = if (separator == 0) "/" else input[0..separator],
        .name = input[separator + 1 ..],
    };
}

fn resolveParent(value: *Adapter, input: []const u8) !struct { inode: u64, name: []const u8 } {
    const parts = try splitParent(input);
    return .{ .inode = try resolvePath(value, parts.parent), .name = parts.name };
}

fn resolvePath(value: *Adapter, input: []const u8) !u64 {
    return value.native.resolvePath(value.io, input) catch |err| return frontendError(err);
}

fn statPath(raw: *anyopaque, raw_path: [*:0]const u8) !backend.NodeInfo {
    const value = adapter(raw);
    const inode = try resolvePath(value, path(raw_path));
    return nodeInfo(value.native, inode, try value.native.stat(value.io, inode));
}

fn statFileId(raw: *anyopaque, file_id: backend.FileId) !backend.NodeInfo {
    const value = adapter(raw);
    const identity = try decodeIdentity(value.native, file_id);
    const record = try validateIdentity(value, identity);
    try requireNonDirectoryFileId(record);
    return nodeInfo(value.native, identity.inode, record);
}

fn pinFile(raw: *anyopaque, file_id: backend.FileId) !void {
    const value = adapter(raw);
    const identity = try decodeIdentity(value.native, file_id);
    try requireNonDirectoryFileId(try validateIdentity(value, identity));
    value.native.pinInode(value.io, identity.inode) catch |err| return frontendError(err);
}

fn unpinFile(raw: *anyopaque, file_id: backend.FileId) !void {
    const value = adapter(raw);
    const identity = try decodeIdentity(value.native, file_id);
    value.native.unpinInode(value.io, identity.inode) catch |err| return frontendError(err);
}

fn setMetadata(raw: *anyopaque, raw_path: [*:0]const u8, new_metadata: metadata.Metadata) !void {
    const value = adapter(raw);
    const inode = try resolvePath(value, path(raw_path));
    value.native.setMetadata(value.io, inode, new_metadata) catch |err| return frontendError(err);
}

fn patchMetadata(raw: *anyopaque, file_id: backend.FileId, patch: metadata.Patch) !metadata.Metadata {
    const value = adapter(raw);
    const identity = try decodeIdentity(value.native, file_id);
    try requireNonDirectoryFileId(try validateIdentity(value, identity));
    return value.native.patchMetadata(value.io, identity.inode, patch) catch |err| return frontendError(err);
}

fn makeDirectory(raw: *anyopaque, raw_path: [*:0]const u8, attributes: backend.CreateAttributes) !void {
    const value = adapter(raw);
    const target = try resolveParent(value, path(raw_path));
    _ = value.native.createDirectory(value.io, target.inode, target.name, attributes.mode, attributes.uid, attributes.gid) catch |err|
        return frontendError(err);
}

fn makeSymlink(raw: *anyopaque, raw_path: [*:0]const u8, target_value: []const u8, uid: u32, gid: u32) !void {
    const value = adapter(raw);
    const target = try resolveParent(value, path(raw_path));
    _ = value.native.createSymlink(value.io, target.inode, target.name, target_value, uid, gid) catch |err|
        return frontendError(err);
}

fn makeFifo(raw: *anyopaque, raw_path: [*:0]const u8, attributes: backend.CreateAttributes) !void {
    const value = adapter(raw);
    const target = try resolveParent(value, path(raw_path));
    _ = value.native.createFifo(value.io, target.inode, target.name, attributes.mode, attributes.uid, attributes.gid) catch |err|
        return frontendError(err);
}

fn link(raw: *anyopaque, old_path: [*:0]const u8, new_path: [*:0]const u8) !backend.NodeInfo {
    const value = adapter(raw);
    const source = try resolvePath(value, path(old_path));
    const target = try resolveParent(value, path(new_path));
    value.native.link(value.io, source, target.inode, target.name) catch |err| return frontendError(err);
    return nodeInfo(value.native, source, try value.native.stat(value.io, source));
}

fn remove(raw: *anyopaque, raw_path: [*:0]const u8) !void {
    const value = adapter(raw);
    const target = try resolveParent(value, path(raw_path));
    value.native.remove(value.io, target.inode, target.name) catch |err| return frontendError(err);
}

fn rename(
    raw: *anyopaque,
    old_path: [*:0]const u8,
    new_path: [*:0]const u8,
    no_replace: bool,
) !backend.RenameResult {
    const value = adapter(raw);
    const source = try resolveParent(value, path(old_path));
    const target = try resolveParent(value, path(new_path));
    return switch (value.native.rename(
        value.io,
        source.inode,
        source.name,
        target.inode,
        target.name,
        no_replace,
    ) catch |err| return frontendError(err)) {
        .renamed => .renamed,
        .same_object => .same_object,
    };
}

fn readSpecial(raw: *anyopaque, file_id: backend.FileId, output: []u8, offset: u64) !usize {
    const value = adapter(raw);
    const identity = try decodeIdentity(value.native, file_id);
    try requireNonDirectoryFileId(try validateIdentity(value, identity));
    return value.native.readSpecial(value.io, identity.inode, output, offset);
}

fn frontendError(err: anyerror) anyerror {
    return switch (err) {
        error.ReadOnlyFilesystem => error.ReadOnlyVolume,
        error.BlobStoreFull => error.NoSpaceLeft,
        error.InvalidName,
        error.InvalidUtf8,
        error.UnassignedCodepoint,
        error.ReservedName,
        => error.InvalidArgument,
        else => err,
    };
}

fn requireNonDirectoryFileId(record: blob_filesystem.Filesystem.InodeRecord) !void {
    if (record.metadata.kind == .directory) return error.InvalidFileHandle;
}

fn openFile(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    raw_path: [*:0]const u8,
    options: backend.OpenOptions,
    attributes: backend.CreateAttributes,
) !backend.FileHandle {
    const value = adapter(raw);
    try validateOpenOptions(value, options);
    const context = try allocator.create(FileContext);
    errdefer allocator.destroy(context);

    const opened = try resolveOrCreateFile(value, path(raw_path), options, attributes);
    const inode = opened.inode;
    const record = opened.record;
    try requireFile(record);
    const identity: Identity = .{ .inode = inode, .generation = record.generation };
    try value.native.retainInode(value.io, inode);
    errdefer value.native.releaseInode(value.io, inode) catch {};
    if (options.truncate)
        value.native.truncate(value.io, inode, 0) catch |err| return frontendError(err);
    context.* = .{
        .native = value.native,
        .io = value.io,
        .identity = identity,
        .access = options.access,
        .append = options.append,
    };
    return .{ .context = context, .allocator = allocator, .vtable = &file_vtable };
}

const OpenedFile = struct {
    inode: u64,
    record: blob_filesystem.Filesystem.InodeRecord,
};

fn resolveOrCreateFile(
    value: *Adapter,
    input: []const u8,
    options: backend.OpenOptions,
    attributes: backend.CreateAttributes,
) !OpenedFile {
    const max_attempts = 4;
    var attempt: usize = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const inode = if (resolvePath(value, input)) |existing_inode| existing: {
            if (options.create and options.exclusive) return error.PathAlreadyExists;
            break :existing existing_inode;
        } else |err| switch (err) {
            error.FileNotFound => create: {
                if (!options.create) return error.FileNotFound;
                const target = try resolveParent(value, input);
                const inode = value.native.createFile(
                    value.io,
                    target.inode,
                    target.name,
                    attributes.mode,
                    attributes.uid,
                    attributes.gid,
                ) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {
                        if (options.exclusive) return error.PathAlreadyExists;
                        continue;
                    },
                    else => return frontendError(create_err),
                };
                break :create inode;
            },
            else => return err,
        };
        const record = value.native.stat(value.io, inode) catch |err| switch (err) {
            error.FileNotFound => {
                if (options.create and !options.exclusive) continue;
                return error.FileNotFound;
            },
            else => return err,
        };
        return .{ .inode = inode, .record = record };
    }
    const inode = try resolvePath(value, input);
    return .{ .inode = inode, .record = try value.native.stat(value.io, inode) };
}

fn openFileId(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    file_id: backend.FileId,
    options: backend.OpenOptions,
) !backend.FileHandle {
    const value = adapter(raw);
    if (options.create or options.exclusive) return error.InvalidArgument;
    try validateOpenOptions(value, options);
    const identity = try decodeIdentity(value.native, file_id);
    try requireFile(try validateIdentity(value, identity));
    const context = try allocator.create(FileContext);
    errdefer allocator.destroy(context);
    try value.native.retainInode(value.io, identity.inode);
    errdefer value.native.releaseInode(value.io, identity.inode) catch {};
    if (options.truncate)
        value.native.truncate(value.io, identity.inode, 0) catch |err| return frontendError(err);
    context.* = .{
        .native = value.native,
        .io = value.io,
        .identity = identity,
        .access = options.access,
        .append = options.append,
    };
    return .{ .context = context, .allocator = allocator, .vtable = &file_vtable };
}

fn validateOpenOptions(value: *Adapter, options: backend.OpenOptions) !void {
    if (options.truncate and options.access != .read_write) return error.AccessDenied;
    if (options.access == .read_write and !value.native.writable) return error.ReadOnlyVolume;
}

fn requireFile(record: blob_filesystem.Filesystem.InodeRecord) !void {
    return switch (record.metadata.kind) {
        .file => {},
        .directory => error.IsDirectory,
        .symlink, .fifo => error.InvalidArgument,
    };
}

fn openDirectory(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    raw_path: [*:0]const u8,
) !backend.DirectoryHandle {
    const value = adapter(raw);
    const inode = try resolvePath(value, path(raw_path));
    const record = try value.native.stat(value.io, inode);
    if (record.metadata.kind != .directory) return error.NotDirectory;
    try value.native.retainInode(value.io, inode);
    errdefer value.native.releaseInode(value.io, inode) catch {};
    var snapshot = try value.native.snapshotDirectory(value.io, inode);
    errdefer snapshot.deinit();
    _ = try directoryEndCookie(snapshot.entries.len);
    const context = try allocator.create(DirectoryContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .native = value.native,
        .io = value.io,
        .inode = inode,
        .info_value = nodeInfo(value.native, inode, record),
        .snapshot = snapshot,
    };
    return .{ .context = context, .allocator = allocator, .vtable = &directory_vtable };
}

fn sync(_: *anyopaque) !void {
    // Every BlobFilesystem mutation publishes through a durable BlobStore authority commit.
}

fn spaceInfo(raw: *anyopaque) !backend.SpaceInfo {
    const value = adapter(raw);
    try value.native.transaction_mutex.lock(value.io);
    defer value.native.transaction_mutex.unlock(value.io);
    const total = value.native.blobs.header.unit_count;
    const committed = value.native.blobs.committedUnits();
    const staged = value.native.blobs.stagedUnits();
    return .{
        .block_size = blob_format.allocation_unit,
        .total_blocks = total,
        .free_blocks = total - committed,
        .available_blocks = total - staged,
        .name_max = filesystem_format.max_name_bytes,
    };
}

fn statFile(raw: *anyopaque) !backend.NodeInfo {
    const context = fileContext(raw);
    return nodeInfo(context.native, context.identity.inode, try validateFileIdentity(context));
}

fn fileId(raw: *anyopaque) backend.FileId {
    const context = fileContext(raw);
    return encodeIdentity(context.native, context.identity);
}

fn readFile(raw: *anyopaque, output: []u8, offset: u64) !usize {
    const context = fileContext(raw);
    _ = try validateFileIdentity(context);
    return context.native.read(context.io, context.identity.inode, output, offset);
}

fn writeFile(raw: *anyopaque, data: []const u8, offset: u64) !usize {
    const context = fileContext(raw);
    if (context.access != .read_write) return error.AccessDenied;
    _ = try validateFileIdentity(context);
    if (context.append)
        return context.native.append(context.io, context.identity.inode, data) catch |err|
            return frontendError(err);
    return context.native.write(context.io, context.identity.inode, data, offset) catch |err|
        return frontendError(err);
}

fn truncateFile(raw: *anyopaque, size: u64) !void {
    const context = fileContext(raw);
    if (context.access != .read_write) return error.AccessDenied;
    _ = try validateFileIdentity(context);
    context.native.truncate(context.io, context.identity.inode, size) catch |err| return frontendError(err);
}

fn fallocateFile(raw: *anyopaque, offset: u64, length: u64) !void {
    const context = fileContext(raw);
    if (context.access != .read_write) return error.AccessDenied;
    _ = try validateFileIdentity(context);
    if (length == 0 or offset > std.math.maxInt(u64) - length) return error.InvalidArgument;
    if (!context.native.writable) return error.ReadOnlyVolume;
    return error.OperationNotSupported;
}

fn syncFile(raw: *anyopaque) !void {
    _ = try validateFileIdentity(fileContext(raw));
}

fn setFileMetadata(raw: *anyopaque, new_metadata: metadata.Metadata) !void {
    const context = fileContext(raw);
    _ = try validateFileIdentity(context);
    context.native.setMetadata(context.io, context.identity.inode, new_metadata) catch |err|
        return frontendError(err);
}

fn patchFileMetadata(raw: *anyopaque, patch: metadata.Patch) !metadata.Metadata {
    const context = fileContext(raw);
    _ = try validateFileIdentity(context);
    return context.native.patchMetadata(context.io, context.identity.inode, patch) catch |err|
        return frontendError(err);
}

fn closeFile(raw: *anyopaque) !void {
    const context = fileContext(raw);
    return context.native.releaseInode(context.io, context.identity.inode) catch |err|
        return frontendError(err);
}

fn destroyFile(raw: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(fileContext(raw));
}

fn directoryInfo(raw: *anyopaque) backend.NodeInfo {
    return directoryContext(raw).info_value;
}

fn directoryEndCookie(entry_count: usize) !u32 {
    if (entry_count > std.math.maxInt(u32) - 2) return error.TooManyDirectoryEntries;
    return @intCast(entry_count + 2);
}

fn readDirectory(raw: *anyopaque, output: *backend.DirectoryEntry) !bool {
    const context = directoryContext(raw);
    const end_cookie = try directoryEndCookie(context.snapshot.entries.len);
    if (context.cookie == end_cookie) return false;
    if (context.cookie < 2) {
        const name = if (context.cookie == 0) "." else "..";
        output.* = .{ .kind = .directory, .name_buffer = @splat(0) };
        @memcpy(output.name_buffer[0..name.len], name);
        context.cookie += 1;
        return true;
    }
    const entry = context.snapshot.entries[@as(usize, context.cookie - 2)];
    if (entry.spelling.len >= backend.name_capacity) return error.NameTooLong;
    output.* = .{
        .kind = if (entry.kind == .directory) .directory else .file,
        .name_buffer = @splat(0),
    };
    @memcpy(output.name_buffer[0..entry.spelling.len], entry.spelling);
    context.cookie += 1;
    return true;
}

fn seekDirectory(raw: *anyopaque, cookie: u32) !void {
    const context = directoryContext(raw);
    if (cookie > try directoryEndCookie(context.snapshot.entries.len)) return error.InvalidArgument;
    context.cookie = cookie;
}

fn tellDirectory(raw: *anyopaque) !u32 {
    return directoryContext(raw).cookie;
}

fn syncDirectory(_: *anyopaque) !void {}

fn closeDirectory(raw: *anyopaque) !void {
    const context = directoryContext(raw);
    context.snapshot.deinit();
    return context.native.releaseInode(context.io, context.inode) catch |err|
        return frontendError(err);
}

fn destroyDirectory(raw: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(directoryContext(raw));
}

test "blob filesystem adapter file identity and namespace round trip" {
    const blob_device = @import("blob_device.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "adapter-files",
        64 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    const blobs = try @import("blob_store.zig").Store.create(std.testing.allocator, std.testing.io, device);
    var native = try blob_filesystem.Filesystem.format(std.testing.allocator, std.testing.io, blobs, .portable_v1);
    defer native.close(std.testing.io) catch {};
    var adapter_value = Adapter.init(&native, std.testing.io);
    const fs = adapter_value.filesystem();
    const attributes: backend.CreateAttributes = .{ .mode = 0o100640, .uid = 10, .gid = 20 };

    var file = try fs.openFile(std.testing.allocator, "/Data", .{
        .access = .read_write,
        .create = true,
        .exclusive = true,
    }, attributes);
    var file_open = true;
    defer if (file_open) file.close() catch {};
    try std.testing.expectEqual(@as(usize, 5), try file.write("hello", 0));
    try std.testing.expectEqual(@as(usize, 1), try file.write("!", 5));
    var output: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try file.read(&output, 0));
    try std.testing.expectEqualStrings("hello!", output[0..6]);
    const id = file.fileId();
    try std.testing.expectError(error.PathAlreadyExists, fs.openFile(std.testing.allocator, "/data", .{
        .access = .read_write,
        .create = true,
        .exclusive = true,
    }, attributes));
    try std.testing.expectEqual(id, (try fs.statFileId(id)).file_id.?);
    try std.testing.expectEqual(id, (try fs.statPath("/data")).identity);
    const decoded = try decodeIdentity(&native, id);
    const stale = encodeIdentity(&native, .{ .inode = decoded.inode, .generation = decoded.generation + 1 });
    try std.testing.expectError(error.FileNotFound, fs.statFileId(stale));
    try fs.pinFile(id);
    try file.close();
    file_open = false;

    var append_handle = try fs.openFileId(std.testing.allocator, id, .{ .access = .read_write, .append = true });
    var append_open = true;
    defer if (append_open) append_handle.close() catch {};
    try std.testing.expectEqual(@as(usize, 5), try append_handle.write("-tail", 0));
    try append_handle.truncate(8);
    _ = try fs.link("/data", "/alias");
    try std.testing.expectEqual(@as(u64, 2), (try append_handle.stat()).nlink);
    try std.testing.expectEqual(backend.RenameResult.renamed, try fs.rename("/alias", "/moved", true));
    try std.testing.expectError(error.PathAlreadyExists, fs.rename("/moved", "/data", true));
    try fs.remove("/data");
    try fs.remove("/moved");
    try std.testing.expectEqual(@as(u64, 0), (try append_handle.stat()).nlink);
    try std.testing.expectEqual(@as(usize, 8), try append_handle.read(&output, 0));
    try std.testing.expectEqualStrings("hello!-t", output[0..8]);
    _ = try append_handle.patchMetadata(.{ .uid = 77, .update_ctime = false });
    try std.testing.expectEqual(@as(u32, 77), (try append_handle.stat()).metadata.uid);
    try std.testing.expectError(error.OperationNotSupported, append_handle.fallocate(0, 4096));
    try append_handle.close();
    append_open = false;
    try std.testing.expectEqual(@as(u64, 0), (try fs.statFileId(id)).nlink);
    try fs.unpinFile(id);
    try std.testing.expectError(error.FileNotFound, fs.statFileId(id));

    const malformed = encodeIdentity(&native, .{ .inode = 0, .generation = 0 });
    try std.testing.expectError(error.InvalidFileHandle, fs.statFileId(malformed));

    var truncate_option = try fs.openFile(std.testing.allocator, "/Truncate", .{
        .access = .read_write,
        .create = true,
    }, attributes);
    try std.testing.expectEqual(@as(usize, 4), try truncate_option.write("data", 0));
    try truncate_option.close();
    truncate_option = try fs.openFile(std.testing.allocator, "/Truncate", .{
        .access = .read_write,
        .truncate = true,
    }, attributes);
    try std.testing.expectEqual(@as(u64, 0), (try truncate_option.stat()).size);
    const truncate_id = truncate_option.fileId();
    try truncate_option.close();
    try fs.pinFile(truncate_id);
    const truncate_inode = (try decodeIdentity(&native, truncate_id)).inode;
    native.blobs.frozen = true;
    try std.testing.expectError(error.BlobStoreFrozen, fs.unpinFile(truncate_id));
    try std.testing.expect(!native.inode_pins.contains(truncate_inode));
    native.blobs.frozen = false;

    var close_error = try fs.openFile(std.testing.allocator, "/CloseError", .{
        .access = .read_write,
        .create = true,
    }, attributes);
    const close_error_inode = (try decodeIdentity(&native, close_error.fileId())).inode;
    try fs.remove("/CloseError");
    native.writable = false;
    try std.testing.expectError(error.ReadOnlyVolume, close_error.close());
    try std.testing.expect(!native.open_references.contains(close_error_inode));
    native.writable = true;
}

test "blob filesystem adapter metadata specials directory snapshot and readonly" {
    const blob_device = @import("blob_device.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "adapter-metadata",
        64 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    const blobs = try @import("blob_store.zig").Store.create(std.testing.allocator, std.testing.io, device);
    var native = try blob_filesystem.Filesystem.format(std.testing.allocator, std.testing.io, blobs, .portable_v1);
    defer native.close(std.testing.io) catch {};
    var adapter_value = Adapter.init(&native, std.testing.io);
    const fs = adapter_value.filesystem();
    const attributes: backend.CreateAttributes = .{ .mode = 0o755, .uid = 1, .gid = 2 };

    for ([_][*:0]const u8{ "/bad//child", "/bad/.", "/bad/..", "/bad/" }) |invalid|
        try std.testing.expectError(error.InvalidArgument, fs.makeDirectory(invalid, attributes));
    try std.testing.expectError(error.InvalidArgument, fs.makeDirectory("/CON", attributes));
    try std.testing.expectError(error.InvalidArgument, fs.makeDirectory("/trailing.", attributes));
    const invalid_utf8: [2:0]u8 = .{ '/', 0xff };
    try std.testing.expectError(error.InvalidArgument, fs.makeDirectory(&invalid_utf8, attributes));
    try fs.makeDirectory("/Entries", attributes);
    const directory_identity = (try fs.statPath("/Entries")).identity;
    try std.testing.expectError(error.InvalidFileHandle, fs.statFileId(directory_identity));
    try std.testing.expectError(error.InvalidFileHandle, fs.pinFile(directory_identity));
    try fs.makeFifo("/Entries/Pipe", .{ .mode = 0o600, .uid = 3, .gid = 4 });
    try fs.makeSymlink("/Entries/Link", "../Target", 5, 6);
    var target: [16]u8 = undefined;
    const link_info = try fs.statPath("/entries/link");
    try std.testing.expectEqual(@as(usize, 9), try fs.readSpecial(link_info.file_id.?, &target, 0));
    try std.testing.expectEqualStrings("../Target", target[0..9]);
    try std.testing.expectError(error.InvalidArgument, fs.openFile(
        std.testing.allocator,
        "/Entries/Link",
        .{ .access = .read_only },
        attributes,
    ));
    try std.testing.expectError(error.NotDirectory, fs.openDirectory(std.testing.allocator, "/Entries/Link"));
    var file = try fs.openFile(std.testing.allocator, "/Entries/Zulu", .{ .access = .read_write, .create = true }, .{
        .mode = 0o600,
        .uid = 7,
        .gid = 8,
    });
    try file.close();
    try fs.setMetadata("/Entries/Zulu", blk: {
        var value = (try fs.statPath("/Entries/Zulu")).metadata;
        value.uid = 9;
        value.mode = 0o100644;
        break :blk value;
    });
    const file_id = (try fs.statPath("/Entries/Zulu")).file_id.?;
    _ = try fs.patchMetadata(file_id, .{ .gid = 10, .update_ctime = false });
    try std.testing.expectEqual(@as(u32, 9), (try fs.statFileId(file_id)).metadata.uid);
    try std.testing.expectEqual(@as(u32, 10), (try fs.statFileId(file_id)).metadata.gid);

    var directory = try fs.openDirectory(std.testing.allocator, "/Entries");
    var directory_open = true;
    defer if (directory_open) directory.close() catch {};
    try std.testing.expectEqual(metadata.Kind.directory, directory.info().metadata.kind);
    var first: backend.DirectoryEntry = undefined;
    try std.testing.expect(try directory.read(&first));
    try std.testing.expectEqualStrings(".", first.name());
    try std.testing.expectEqual(@as(u32, 1), try directory.tell());
    _ = try fs.rename("/Entries/Zulu", "/Entries/Alpha", false);
    try fs.remove("/Entries/Pipe");
    try directory.seek(0);
    var names: [5][]const u8 = undefined;
    var name_buffers: [5][backend.name_capacity]u8 = undefined;
    var count: usize = 0;
    while (count < names.len) : (count += 1) {
        var entry: backend.DirectoryEntry = undefined;
        if (!try directory.read(&entry)) break;
        @memcpy(name_buffers[count][0..entry.name().len], entry.name());
        names[count] = name_buffers[count][0..entry.name().len];
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualStrings(".", names[0]);
    try std.testing.expectEqualStrings("..", names[1]);
    try std.testing.expectEqualStrings("Link", names[2]);
    try std.testing.expectEqualStrings("Pipe", names[3]);
    try std.testing.expectEqualStrings("Zulu", names[4]);
    try directory.seek(5);
    try std.testing.expectError(error.InvalidArgument, directory.seek(6));
    try directory.sync();
    try directory.close();
    directory_open = false;

    try fs.makeDirectory("/Empty", attributes);
    var empty = try fs.openDirectory(std.testing.allocator, "/Empty");
    var empty_entry: backend.DirectoryEntry = undefined;
    try std.testing.expect(try empty.read(&empty_entry));
    try std.testing.expectEqualStrings(".", empty_entry.name());
    try std.testing.expect(try empty.read(&empty_entry));
    try std.testing.expectEqualStrings("..", empty_entry.name());
    try std.testing.expectEqual(@as(u32, 2), try empty.tell());
    try std.testing.expect(!try empty.read(&empty_entry));
    try empty.seek(2);
    try std.testing.expectError(error.InvalidArgument, empty.seek(3));
    try empty.close();

    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), try directoryEndCookie(std.math.maxInt(u32) - 2));
    try std.testing.expectError(error.TooManyDirectoryEntries, directoryEndCookie(std.math.maxInt(u32) - 1));

    const space = try fs.spaceInfo();
    try std.testing.expectEqual(@as(u32, 4096), space.block_size);
    try std.testing.expect(space.total_blocks > space.free_blocks);
    try std.testing.expect(space.available_blocks <= space.free_blocks);
    try std.testing.expectEqual(@as(u32, 255), space.name_max);
    try fs.sync();

    native.writable = false;
    try std.testing.expectError(error.ReadOnlyVolume, fs.makeDirectory("/readonly", attributes));
    try std.testing.expectError(error.ReadOnlyVolume, fs.openFile(std.testing.allocator, "/Entries/Alpha", .{
        .access = .read_write,
    }, attributes));
    var readonly = try fs.openFile(std.testing.allocator, "/Entries/Alpha", .{ .access = .read_only }, attributes);
    defer readonly.close() catch {};
    try std.testing.expectError(error.AccessDenied, readonly.write("x", 0));
    try readonly.sync();
    try fs.sync();
}

test "blob filesystem adapter identities survive readonly reopen" {
    const blob_device = @import("blob_device.zig");
    const blob_store = @import("blob_store.zig");
    const storage_api = @import("v3/storage.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 64 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "adapter-reopen",
        device_size,
        blob_format.allocation_unit,
    );
    const blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var native = try blob_filesystem.Filesystem.format(std.testing.allocator, std.testing.io, blobs, .portable_v1);
    var native_open = true;
    defer if (native_open) native.close(std.testing.io) catch {};
    var adapter_value = Adapter.init(&native, std.testing.io);
    var fs = adapter_value.filesystem();
    const attributes: backend.CreateAttributes = .{ .mode = 0o600, .uid = 1, .gid = 2 };
    var created = try fs.openFile(std.testing.allocator, "/Persisted", .{
        .access = .read_write,
        .create = true,
        .exclusive = true,
    }, attributes);
    try std.testing.expectEqual(@as(usize, 9), try created.write("persisted", 0));
    const id = created.fileId();
    try created.close();
    try native.close(std.testing.io);
    native_open = false;

    const backing = try tmp.dir.openFile(std.testing.io, "adapter-reopen", .{ .mode = .read_write });
    var backing_open = true;
    defer if (backing_open) backing.close(std.testing.io);
    const storage = storage_api.Storage.initOwned(backing, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, blob_format.allocation_unit);
    backing_open = false;
    const reopened_blobs = try blob_store.Store.open(std.testing.allocator, std.testing.io, reopened_device);
    native = try blob_filesystem.Filesystem.open(std.testing.allocator, std.testing.io, reopened_blobs, false);
    native_open = true;
    adapter_value = Adapter.init(&native, std.testing.io);
    fs = adapter_value.filesystem();

    try std.testing.expectEqual(id, (try fs.statPath("/persisted")).file_id.?);
    var reopened = try fs.openFileId(std.testing.allocator, id, .{ .access = .read_only });
    defer reopened.close() catch {};
    var output: [9]u8 = undefined;
    try std.testing.expectEqual(output.len, try reopened.read(&output, 0));
    try std.testing.expectEqualStrings("persisted", &output);
    try std.testing.expectError(error.ReadOnlyVolume, fs.remove("/persisted"));
    try fs.sync();

    const other_device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "adapter-other-store",
        device_size,
        blob_format.allocation_unit,
    );
    const other_blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, other_device);
    var other_native = try blob_filesystem.Filesystem.format(
        std.testing.allocator,
        std.testing.io,
        other_blobs,
        .portable_v1,
    );
    defer other_native.close(std.testing.io) catch {};
    var other_adapter = Adapter.init(&other_native, std.testing.io);
    const other_fs = other_adapter.filesystem();
    try std.testing.expect(!std.mem.eql(
        u8,
        &(try fs.statPath("/")).identity,
        &(try other_fs.statPath("/")).identity,
    ));
    const persisted_identity = try decodeIdentity(&native, id);
    try std.testing.expect(!std.mem.eql(
        u8,
        &id,
        &encodeIdentity(&other_native, persisted_identity),
    ));
    if (other_fs.statFileId(id)) |_| {
        return error.TestExpectedForeignFileIdRejection;
    } else |err| {
        try std.testing.expect(err == error.FileNotFound or err == error.InvalidFileHandle);
    }
}

test "blob filesystem adapter validates mutation paths and frontend errors" {
    for ([_][*:0]const u8{ "/bad//child", "/bad/.", "/bad/..", "/bad/" }) |invalid|
        try std.testing.expectError(error.InvalidArgument, splitParent(path(invalid)));
    try std.testing.expectError(error.InvalidArgument, splitParent("/bad\x00child"));
    try std.testing.expectEqual(error.ReadOnlyVolume, frontendError(error.ReadOnlyFilesystem));
    try std.testing.expectEqual(error.NoSpaceLeft, frontendError(error.BlobStoreFull));
    try std.testing.expectEqual(error.InvalidArgument, frontendError(error.InvalidName));
    try std.testing.expectEqual(error.InvalidArgument, frontendError(error.InvalidUtf8));
    try std.testing.expectEqual(error.InvalidArgument, frontendError(error.UnassignedCodepoint));
    try std.testing.expectEqual(error.InvalidArgument, frontendError(error.ReservedName));
    try std.testing.expectEqual(error.InputOutput, frontendError(error.InputOutput));
}
