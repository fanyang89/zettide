const std = @import("std");
const metadata = @import("metadata.zig");

pub const Identity = [16]u8;
pub const name_capacity = 256;

pub const Node = struct {
    kind: metadata.Kind,
    identity: Identity,
};

pub const NodeInfo = struct {
    size: u64,
    allocated_bytes: u64,
    metadata: metadata.Metadata,
    identity: Identity,
    nlink: u64,

    pub fn node(self: NodeInfo) Node {
        return .{ .kind = self.metadata.kind, .identity = self.identity };
    }
};

pub const SpaceInfo = struct {
    block_size: u32,
    total_blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
};

pub const CreateAttributes = struct {
    mode: u32,
    uid: u32,
    gid: u32,
};

pub const DirectoryEntry = struct {
    name_buffer: [name_capacity:0]u8,
    next_cookie: u32,
    info: NodeInfo,

    pub fn name(self: *const DirectoryEntry) [:0]const u8 {
        return std.mem.sliceTo(&self.name_buffer, 0);
    }
};

/// A borrowed identity-oriented filesystem view for stable NFS handles.
pub const Filesystem = struct {
    context: *anyopaque,
    filesystem_id: [16]u8,
    vtable: *const VTable,

    pub const VTable = struct {
        space_info: *const fn (*anyopaque) anyerror!SpaceInfo,
        root: *const fn (*anyopaque) anyerror!NodeInfo,
        stat: *const fn (*anyopaque, Node) anyerror!NodeInfo,
        set_metadata: *const fn (*anyopaque, Node, metadata.Metadata) anyerror!NodeInfo,
        truncate: *const fn (*anyopaque, Node, u64) anyerror!NodeInfo,
        lookup: *const fn (*anyopaque, Node, []const u8) anyerror!NodeInfo,
        parent: *const fn (*anyopaque, Node) anyerror!NodeInfo,
        read: *const fn (*anyopaque, Node, []u8, u64) anyerror!usize,
        write: *const fn (*anyopaque, Node, []const u8, u64) anyerror!usize,
        create_file: *const fn (*anyopaque, Node, []const u8, CreateAttributes) anyerror!NodeInfo,
        make_directory: *const fn (*anyopaque, Node, []const u8, CreateAttributes) anyerror!NodeInfo,
        make_symlink: *const fn (*anyopaque, Node, []const u8, []const u8, u32, u32) anyerror!NodeInfo,
        readlink: *const fn (*anyopaque, Node, []u8) anyerror!usize,
        link: *const fn (*anyopaque, Node, Node, []const u8) anyerror!NodeInfo,
        remove: *const fn (*anyopaque, Node, []const u8) anyerror!void,
        rename: *const fn (*anyopaque, Node, []const u8, Node, []const u8, bool) anyerror!void,
        open_directory: *const fn (*anyopaque, std.mem.Allocator, Node, u32) anyerror!Directory,
        sync: *const fn (*anyopaque) anyerror!void,
    };

    pub fn spaceInfo(self: Filesystem) !SpaceInfo {
        return self.vtable.space_info(self.context);
    }

    pub fn root(self: Filesystem) !NodeInfo {
        return self.vtable.root(self.context);
    }

    pub fn stat(self: Filesystem, node: Node) !NodeInfo {
        return self.vtable.stat(self.context, node);
    }

    pub fn setMetadata(self: Filesystem, node: Node, value: metadata.Metadata) !NodeInfo {
        return self.vtable.set_metadata(self.context, node, value);
    }

    pub fn truncate(self: Filesystem, node: Node, size: u64) !NodeInfo {
        return self.vtable.truncate(self.context, node, size);
    }

    pub fn lookup(self: Filesystem, parent_node: Node, name: []const u8) !NodeInfo {
        return self.vtable.lookup(self.context, parent_node, name);
    }

    pub fn parent(self: Filesystem, directory: Node) !NodeInfo {
        return self.vtable.parent(self.context, directory);
    }

    pub fn read(self: Filesystem, node: Node, output: []u8, offset: u64) !usize {
        return self.vtable.read(self.context, node, output, offset);
    }

    pub fn write(self: Filesystem, node: Node, data: []const u8, offset: u64) !usize {
        return self.vtable.write(self.context, node, data, offset);
    }

    pub fn createFile(
        self: Filesystem,
        parent_node: Node,
        name: []const u8,
        attributes: CreateAttributes,
    ) !NodeInfo {
        return self.vtable.create_file(self.context, parent_node, name, attributes);
    }

    pub fn makeDirectory(
        self: Filesystem,
        parent_node: Node,
        name: []const u8,
        attributes: CreateAttributes,
    ) !NodeInfo {
        return self.vtable.make_directory(self.context, parent_node, name, attributes);
    }

    pub fn makeSymlink(
        self: Filesystem,
        parent_node: Node,
        name: []const u8,
        target: []const u8,
        uid: u32,
        gid: u32,
    ) !NodeInfo {
        return self.vtable.make_symlink(self.context, parent_node, name, target, uid, gid);
    }

    pub fn readlink(self: Filesystem, node: Node, output: []u8) !usize {
        return self.vtable.readlink(self.context, node, output);
    }

    pub fn link(self: Filesystem, source: Node, parent_node: Node, name: []const u8) !NodeInfo {
        return self.vtable.link(self.context, source, parent_node, name);
    }

    pub fn remove(self: Filesystem, parent_node: Node, name: []const u8) !void {
        return self.vtable.remove(self.context, parent_node, name);
    }

    pub fn rename(
        self: Filesystem,
        old_parent: Node,
        old_name: []const u8,
        new_parent: Node,
        new_name: []const u8,
        no_replace: bool,
    ) !void {
        return self.vtable.rename(self.context, old_parent, old_name, new_parent, new_name, no_replace);
    }

    pub fn openDirectory(
        self: Filesystem,
        allocator: std.mem.Allocator,
        node: Node,
        cookie: u32,
    ) !Directory {
        return self.vtable.open_directory(self.context, allocator, node, cookie);
    }

    pub fn sync(self: Filesystem) !void {
        return self.vtable.sync(self.context);
    }
};

/// A move-only directory cursor. `close` consumes it even on error.
pub const Directory = struct {
    context: *anyopaque,
    allocator: std.mem.Allocator,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque, *DirectoryEntry) anyerror!bool,
        close: *const fn (*anyopaque) anyerror!void,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn read(self: Directory, entry: *DirectoryEntry) !bool {
        return self.vtable.read(self.context, entry);
    }

    pub fn close(self: *Directory) !void {
        const context = self.context;
        const allocator = self.allocator;
        const vtable = self.vtable;
        self.* = undefined;
        defer vtable.destroy(context, allocator);
        return vtable.close(context);
    }
};

test "NFS directory consumes its context when close fails" {
    const Fake = struct {
        destroyed: *bool,

        fn read(_: *anyopaque, _: *DirectoryEntry) anyerror!bool {
            return error.Unused;
        }

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
    var directory: Directory = .{
        .context = context,
        .allocator = std.testing.allocator,
        .vtable = &.{ .read = Fake.read, .close = Fake.close, .destroy = Fake.destroy },
    };
    try std.testing.expectError(error.CloseFailed, directory.close());
    try std.testing.expect(destroyed);
}
