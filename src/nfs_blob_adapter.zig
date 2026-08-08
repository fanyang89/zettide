const std = @import("std");
const blob_filesystem = @import("blob_filesystem.zig");
const blob_format = @import("blob_format.zig");
const blob_store = @import("blob_store.zig");
const filesystem_format = @import("blob_filesystem_format.zig");
const metadata = @import("metadata.zig");
const nfs_filesystem = @import("nfs_filesystem.zig");

const Io = std.Io;

pub const Adapter = struct {
    native: *blob_filesystem.Filesystem,
    io: Io,

    pub fn init(native: *blob_filesystem.Filesystem, io: Io) Adapter {
        return .{ .native = native, .io = io };
    }

    pub fn filesystem(self: *Adapter) nfs_filesystem.Filesystem {
        return .{
            .context = self,
            .filesystem_id = self.native.blobs.header.uuid,
            .vtable = &filesystem_vtable,
        };
    }

    pub fn directReadPlan(
        self: *Adapter,
        node: nfs_filesystem.Node,
        offset: u64,
        length: usize,
    ) !?blob_store.DirectReadPlan {
        if (node.kind == .directory) return error.IsDirectory;
        if (node.kind != .file) return error.InvalidArgument;
        const identity = try decodeIdentity(node.identity);
        return self.native.directReadPlanAtGeneration(
            self.io,
            identity.inode,
            identity.generation,
            offset,
            length,
        ) catch |err| return normalizeError(err);
    }
};

const Identity = struct {
    inode: u64,
    generation: u64,
};

const DirectoryContext = struct {
    native: *blob_filesystem.Filesystem,
    io: Io,
    inode: u64,
    snapshot: blob_filesystem.Filesystem.DirectorySnapshot,
    cookie: u32,
};

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

fn adapter(raw: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(raw));
}

fn directory(raw: *anyopaque) *DirectoryContext {
    return @ptrCast(@alignCast(raw));
}

fn encodeIdentity(identity: Identity) nfs_filesystem.Identity {
    var result: nfs_filesystem.Identity = undefined;
    std.mem.writeInt(u64, result[0..8], identity.inode, .little);
    std.mem.writeInt(u64, result[8..16], identity.generation, .little);
    return result;
}

fn decodeIdentity(value: nfs_filesystem.Identity) !Identity {
    const result: Identity = .{
        .inode = std.mem.readInt(u64, value[0..8], .little),
        .generation = std.mem.readInt(u64, value[8..16], .little),
    };
    if (result.inode == 0 or result.generation == 0) return error.InvalidFileHandle;
    return result;
}

fn validate(value: *Adapter, node: nfs_filesystem.Node) !struct {
    identity: Identity,
    record: blob_filesystem.Filesystem.InodeRecord,
} {
    const identity = try decodeIdentity(node.identity);
    const record = value.native.stat(value.io, identity.inode) catch |err| return normalizeError(err);
    if (record.generation != identity.generation or record.metadata.kind != node.kind)
        return error.FileNotFound;
    return .{ .identity = identity, .record = record };
}

fn nodeInfo(
    inode: u64,
    record: blob_filesystem.Filesystem.InodeRecord,
) nfs_filesystem.NodeInfo {
    return .{
        .size = if (record.data) |data| data.logical_size else 0,
        .allocated_bytes = record.allocated_bytes,
        .metadata = record.metadata,
        .identity = encodeIdentity(.{ .inode = inode, .generation = record.generation }),
        .nlink = record.nlink,
    };
}

fn normalizeError(err: anyerror) anyerror {
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

fn spaceInfo(raw: *anyopaque) !nfs_filesystem.SpaceInfo {
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
    };
}

fn root(raw: *anyopaque) !nfs_filesystem.NodeInfo {
    const value = adapter(raw);
    const record = value.native.stat(value.io, filesystem_format.root_inode) catch |err|
        return normalizeError(err);
    return nodeInfo(filesystem_format.root_inode, record);
}

fn stat(raw: *anyopaque, node: nfs_filesystem.Node) !nfs_filesystem.NodeInfo {
    const validated = try validate(adapter(raw), node);
    return nodeInfo(validated.identity.inode, validated.record);
}

fn setMetadata(
    raw: *anyopaque,
    node: nfs_filesystem.Node,
    new_metadata: metadata.Metadata,
) !nfs_filesystem.NodeInfo {
    const value = adapter(raw);
    const validated = try validate(value, node);
    value.native.setMetadata(value.io, validated.identity.inode, new_metadata) catch |err|
        return normalizeError(err);
    return nodeInfo(
        validated.identity.inode,
        value.native.stat(value.io, validated.identity.inode) catch |err| return normalizeError(err),
    );
}

fn truncate(raw: *anyopaque, node: nfs_filesystem.Node, size: u64) !nfs_filesystem.NodeInfo {
    if (node.kind != .file) return error.InvalidArgument;
    const value = adapter(raw);
    const validated = try validate(value, node);
    value.native.truncate(value.io, validated.identity.inode, size) catch |err| return normalizeError(err);
    return nodeInfo(
        validated.identity.inode,
        value.native.stat(value.io, validated.identity.inode) catch |err| return normalizeError(err),
    );
}

fn lookup(raw: *anyopaque, parent_node: nfs_filesystem.Node, name: []const u8) !nfs_filesystem.NodeInfo {
    if (parent_node.kind != .directory) return error.NotDirectory;
    const value = adapter(raw);
    const parent_identity = (try validate(value, parent_node)).identity;
    const result = (value.native.lookup(value.io, parent_identity.inode, name) catch |err|
        return normalizeError(err)) orelse return error.FileNotFound;
    return nodeInfo(
        result.inode,
        value.native.stat(value.io, result.inode) catch |err| return normalizeError(err),
    );
}

fn parent(raw: *anyopaque, node: nfs_filesystem.Node) !nfs_filesystem.NodeInfo {
    if (node.kind != .directory) return error.NotDirectory;
    const value = adapter(raw);
    const validated = try validate(value, node);
    return nodeInfo(
        validated.record.parent_inode,
        value.native.stat(value.io, validated.record.parent_inode) catch |err| return normalizeError(err),
    );
}

fn read(raw: *anyopaque, node: nfs_filesystem.Node, output: []u8, offset: u64) !usize {
    if (node.kind == .directory) return error.IsDirectory;
    if (node.kind != .file) return error.InvalidArgument;
    const value = adapter(raw);
    const identity = try decodeIdentity(node.identity);
    return value.native.readAtGeneration(
        value.io,
        identity.inode,
        identity.generation,
        output,
        offset,
    ) catch |err| return normalizeError(err);
}

fn write(raw: *anyopaque, node: nfs_filesystem.Node, data: []const u8, offset: u64) !usize {
    if (node.kind == .directory) return error.IsDirectory;
    if (node.kind != .file) return error.InvalidArgument;
    const value = adapter(raw);
    if (!value.native.writable or value.native.frozen) {
        _ = try validate(value, node);
        if (!value.native.writable) return error.ReadOnlyVolume;
    }
    const identity = try decodeIdentity(node.identity);
    return value.native.writeAtGeneration(
        value.io,
        identity.inode,
        identity.generation,
        data,
        offset,
    ) catch |err| return normalizeError(err);
}

fn createFile(
    raw: *anyopaque,
    parent_node: nfs_filesystem.Node,
    name: []const u8,
    attributes: nfs_filesystem.CreateAttributes,
) !nfs_filesystem.NodeInfo {
    if (parent_node.kind != .directory) return error.NotDirectory;
    const value = adapter(raw);
    const parent_identity = (try validate(value, parent_node)).identity;
    const inode = value.native.createFile(
        value.io,
        parent_identity.inode,
        name,
        attributes.mode,
        attributes.uid,
        attributes.gid,
    ) catch |err| return normalizeError(err);
    return nodeInfo(inode, value.native.stat(value.io, inode) catch |err| return normalizeError(err));
}

fn makeDirectory(
    raw: *anyopaque,
    parent_node: nfs_filesystem.Node,
    name: []const u8,
    attributes: nfs_filesystem.CreateAttributes,
) !nfs_filesystem.NodeInfo {
    if (parent_node.kind != .directory) return error.NotDirectory;
    const value = adapter(raw);
    const parent_identity = (try validate(value, parent_node)).identity;
    const inode = value.native.createDirectory(
        value.io,
        parent_identity.inode,
        name,
        attributes.mode,
        attributes.uid,
        attributes.gid,
    ) catch |err| return normalizeError(err);
    return nodeInfo(inode, value.native.stat(value.io, inode) catch |err| return normalizeError(err));
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
    const value = adapter(raw);
    const parent_identity = (try validate(value, parent_node)).identity;
    const inode = value.native.createSymlink(value.io, parent_identity.inode, name, target, uid, gid) catch |err|
        return normalizeError(err);
    return nodeInfo(inode, value.native.stat(value.io, inode) catch |err| return normalizeError(err));
}

fn readlink(raw: *anyopaque, node: nfs_filesystem.Node, output: []u8) !usize {
    if (node.kind != .symlink) return error.InvalidArgument;
    const value = adapter(raw);
    const identity = (try validate(value, node)).identity;
    return value.native.readSpecial(value.io, identity.inode, output, 0) catch |err| return normalizeError(err);
}

fn link(
    raw: *anyopaque,
    source: nfs_filesystem.Node,
    parent_node: nfs_filesystem.Node,
    name: []const u8,
) !nfs_filesystem.NodeInfo {
    if (source.kind == .directory) return error.IsDirectory;
    if (parent_node.kind != .directory) return error.NotDirectory;
    const value = adapter(raw);
    const source_identity = (try validate(value, source)).identity;
    const parent_identity = (try validate(value, parent_node)).identity;
    value.native.link(value.io, source_identity.inode, parent_identity.inode, name) catch |err|
        return normalizeError(err);
    return nodeInfo(
        source_identity.inode,
        value.native.stat(value.io, source_identity.inode) catch |err| return normalizeError(err),
    );
}

fn remove(raw: *anyopaque, parent_node: nfs_filesystem.Node, name: []const u8) !void {
    if (parent_node.kind != .directory) return error.NotDirectory;
    const value = adapter(raw);
    const parent_identity = (try validate(value, parent_node)).identity;
    value.native.remove(value.io, parent_identity.inode, name) catch |err| return normalizeError(err);
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
    const value = adapter(raw);
    const old_identity = (try validate(value, old_parent)).identity;
    const new_identity = (try validate(value, new_parent)).identity;
    _ = value.native.rename(
        value.io,
        old_identity.inode,
        old_name,
        new_identity.inode,
        new_name,
        no_replace,
    ) catch |err| return normalizeError(err);
}

fn openDirectory(
    raw: *anyopaque,
    allocator: std.mem.Allocator,
    node: nfs_filesystem.Node,
    cookie: u32,
) !nfs_filesystem.Directory {
    if (node.kind != .directory) return error.NotDirectory;
    const value = adapter(raw);
    const identity = (try validate(value, node)).identity;
    try value.native.retainInode(value.io, identity.inode);
    errdefer value.native.releaseInode(value.io, identity.inode) catch {};
    var snapshot = value.native.snapshotDirectory(value.io, identity.inode) catch |err|
        return normalizeError(err);
    errdefer snapshot.deinit();
    if (snapshot.entries.len > std.math.maxInt(u32) or @as(usize, cookie) > snapshot.entries.len)
        return error.InvalidArgument;
    const context = try allocator.create(DirectoryContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .native = value.native,
        .io = value.io,
        .inode = identity.inode,
        .snapshot = snapshot,
        .cookie = cookie,
    };
    return .{ .context = context, .allocator = allocator, .vtable = &directory_vtable };
}

fn sync(raw: *anyopaque) !void {
    const value = adapter(raw);
    return value.native.sync(value.io) catch |err| return normalizeError(err);
}

fn readDirectory(raw: *anyopaque, output: *nfs_filesystem.DirectoryEntry) !bool {
    const context = directory(raw);
    if (@as(usize, context.cookie) == context.snapshot.entries.len) return false;
    const entry = context.snapshot.entries[@intCast(context.cookie)];
    if (entry.spelling.len >= nfs_filesystem.name_capacity) return error.NameTooLong;
    const info = nodeInfo(
        entry.inode,
        context.native.stat(context.io, entry.inode) catch |err| return normalizeError(err),
    );
    context.cookie += 1;
    output.* = .{
        .name_buffer = @splat(0),
        .next_cookie = context.cookie,
        .info = info,
    };
    @memcpy(output.name_buffer[0..entry.spelling.len], entry.spelling);
    return true;
}

fn closeDirectory(raw: *anyopaque) !void {
    const context = directory(raw);
    context.snapshot.deinit();
    return context.native.releaseInode(context.io, context.inode) catch |err| return normalizeError(err);
}

fn destroyDirectory(raw: *anyopaque, allocator: std.mem.Allocator) void {
    allocator.destroy(directory(raw));
}

test "NFS blob adapter direct read plans preserve fallback and stale handles" {
    const blob_device = @import("blob_device.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "nfs-direct-plan",
        16 * 1024 * 1024,
        blob_format.allocation_unit,
    );
    const blobs = try blob_store.Store.create(std.testing.allocator, std.testing.io, device);
    var native = try blob_filesystem.Filesystem.format(
        std.testing.allocator,
        std.testing.io,
        blobs,
        .legacy_raw,
    );
    defer native.close(std.testing.io) catch {};
    const inode = try native.createFile(
        std.testing.io,
        filesystem_format.root_inode,
        "file",
        0o644,
        0,
        0,
    );
    const initial = try native.stat(std.testing.io, inode);
    const node = nodeInfo(inode, initial).node();
    var value = Adapter.init(&native, std.testing.io);
    const data: [blob_format.allocation_unit]u8 = @splat('n');
    _ = try native.writeAtGeneration(std.testing.io, inode, initial.generation, &data, 0);

    try std.testing.expectEqual(
        @as(?blob_store.DirectReadPlan, null),
        try value.directReadPlan(node, 0, data.len),
    );
    var stale = node;
    std.mem.writeInt(u64, stale.identity[8..16], initial.generation + 1, .little);
    try std.testing.expectError(error.FileNotFound, value.directReadPlan(stale, 0, data.len));

    try native.sync(std.testing.io);
    try std.testing.expectEqual(
        @as(?blob_store.DirectReadPlan, null),
        try value.directReadPlan(node, 0, data.len),
    );
    try std.testing.expectEqual(
        @as(?blob_store.DirectReadPlan, null),
        try value.directReadPlan(node, 1, data.len),
    );
    const root_record = try native.stat(std.testing.io, filesystem_format.root_inode);
    try std.testing.expectError(
        error.IsDirectory,
        value.directReadPlan(nodeInfo(filesystem_format.root_inode, root_record).node(), 0, data.len),
    );
}
