//! Minimal persistent filesystem metadata composition.

const std = @import("std");
const anchor_mod = @import("anchor.zig");
const commit_mod = @import("commit.zig");
const format_mod = @import("filesystem_format.zig");
const store_mod = @import("store.zig");
const transaction_mod = @import("transaction.zig");
const tree = @import("tree.zig");

pub const Error = error{
    Unformatted,
    InvalidAnchorState,
    AlreadyFormatted,
    MissingRootInode,
    RootNotDirectory,
    StaleSnapshot,
    ParentNotFound,
    NotDirectory,
    AlreadyExists,
    InodeIdOverflow,
    InodeIdCollision,
    MissingChildInode,
    DirectoryEntryKindMismatch,
};

pub const FormatOptions = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    now_ns: u64,
};

pub const CreateFileOptions = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    now_ns: u64,
};

/// A non-owning view of one published filesystem generation. The store backend
/// must outlive the Snapshot. Read methods own no resources after returning.
pub const Snapshot = struct {
    store: store_mod.ConditionalStore,
    generation: u64,
    commit_ref: store_mod.ObjectRef,
    root_ref: store_mod.ObjectRef,
    root: format_mod.FilesystemRoot,
    root_inode: format_mod.Inode,

    pub fn getInode(
        self: Snapshot,
        allocator: std.mem.Allocator,
        inode_id: format_mod.InodeId,
    ) !?format_mod.Inode {
        const key = try format_mod.encodeInodeKey(inode_id);
        var encoded = try tree.get(self.store, allocator, self.root.inode_tree_root, &key);
        defer if (encoded) |*value| value.deinit();
        const value = encoded orelse return null;
        const inode = try format_mod.decodeInode(value.bytes);
        try format_mod.validateInodeKeyValue(&key, inode);
        return inode;
    }

    pub fn lookup(
        self: Snapshot,
        allocator: std.mem.Allocator,
        parent_inode_id: format_mod.InodeId,
        name: []const u8,
    ) !?format_mod.DirectoryEntry {
        var key_buffer: format_mod.DirectoryKeyBuffer = undefined;
        const key = try format_mod.encodeDirectoryKey(&key_buffer, parent_inode_id, name);
        var encoded = try tree.get(self.store, allocator, self.root.directory_tree_root, key);
        defer if (encoded) |*value| value.deinit();
        const value = encoded orelse return null;
        const entry = try format_mod.decodeDirectoryEntry(value.bytes);
        try format_mod.validateDirectoryKeyValue(key, entry);
        const child = try self.getInode(allocator, entry.child_inode_id) orelse
            return error.MissingChildInode;
        if (entry.child_kind != child.kind) return error.DirectoryEntryKindMismatch;
        return entry;
    }

    pub fn hasExtentMappings(
        self: Snapshot,
        allocator: std.mem.Allocator,
        inode_id: format_mod.InodeId,
    ) !bool {
        const start = try format_mod.encodeInodeKey(inode_id);
        var cursor = try tree.scan(self.store, allocator, self.root.extent_tree_root, &start);
        defer cursor.deinit();
        var entry = (try cursor.next()) orelse return false;
        defer entry.deinit();
        const key = try format_mod.decodeExtentKey(entry.key.bytes);
        if (key.inode_id != inode_id) return false;
        const mapping = try format_mod.decodeExtentMapping(entry.value.bytes);
        try format_mod.validateExtentKeyValue(entry.key.bytes, mapping);
        return true;
    }
};

pub fn open(
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
) !Snapshot {
    var anchor_snapshot = try store.readAnchor(allocator);
    defer anchor_snapshot.deinit();
    const anchor = try anchor_mod.decode(&anchor_snapshot.anchor);
    if (anchor.generation == 0 and anchor.head == null) return error.Unformatted;
    if ((anchor.generation == 0) != (anchor.head == null)) return error.InvalidAnchorState;
    const commit_ref = anchor.head.?;

    var commit_bytes = try store.loadImmutable(commit_ref, allocator);
    defer commit_bytes.deinit();
    const commit = try commit_mod.decode(commit_bytes.bytes);
    if (commit.generation != anchor.generation or
        !std.mem.eql(u8, &commit.transaction_id, &anchor.transaction_id) or
        ((commit.generation == 1) != (commit.parent == null)))
    {
        return error.InvalidAnchorState;
    }

    var root_bytes = try store.loadImmutable(commit.root, allocator);
    defer root_bytes.deinit();
    const root = try format_mod.decodeFilesystemRoot(root_bytes.bytes);

    var directory_cursor = try tree.scan(store, allocator, root.directory_tree_root, "");
    directory_cursor.deinit();
    var extent_cursor = try tree.scan(store, allocator, root.extent_tree_root, "");
    extent_cursor.deinit();

    const partial = Snapshot{
        .store = store,
        .generation = anchor.generation,
        .commit_ref = commit_ref,
        .root_ref = commit.root,
        .root = root,
        .root_inode = undefined,
    };
    const root_inode = try partial.getInode(allocator, format_mod.root_inode_id) orelse
        return error.MissingRootInode;
    if (root_inode.kind != .directory) return error.RootNotDirectory;

    var snapshot = partial;
    snapshot.root_inode = root_inode;
    return snapshot;
}

/// Stages an initial filesystem root. The caller retains the Transaction and
/// decides when to commit, resolve, and stabilize it.
pub fn format(
    transaction: *transaction_mod.Transaction,
    options: FormatOptions,
) !store_mod.ObjectRef {
    if (transaction.base_generation != 0 or transaction.base_head != null)
        return error.AlreadyFormatted;

    var trees = tree.Mutator.init(transaction);
    defer trees.deinit();
    var inode_tree_root = try trees.createEmpty();
    const directory_tree_root = try trees.createEmpty();
    const extent_tree_root = try trees.createEmpty();

    const root_inode = format_mod.Inode{
        .kind = .directory,
        .inode_id = format_mod.root_inode_id,
        .logical_size = 0,
        .allocated_bytes = 0,
        .link_count = 2,
        .mode = options.mode,
        .uid = options.uid,
        .gid = options.gid,
        .atime_ns = options.now_ns,
        .mtime_ns = options.now_ns,
        .ctime_ns = options.now_ns,
        .birthtime_ns = options.now_ns,
    };
    const inode_key = try format_mod.encodeInodeKey(root_inode.inode_id);
    const encoded_inode = try format_mod.encodeInode(root_inode);
    inode_tree_root = try trees.put(inode_tree_root, &inode_key, &encoded_inode);

    const root = try format_mod.encodeFilesystemRoot(.{
        .root_inode_id = format_mod.root_inode_id,
        .next_inode_id = format_mod.root_inode_id + 1,
        .inode_tree_root = inode_tree_root,
        .directory_tree_root = directory_tree_root,
        .extent_tree_root = extent_tree_root,
    });
    return transaction.putImmutable(&root);
}

/// Owns speculative tree pages for one Transaction. Call deinit before
/// deinitializing the Transaction. Snapshot does not need to outlive init.
pub const Mutator = struct {
    transaction: *transaction_mod.Transaction,
    trees: tree.Mutator,
    root: format_mod.FilesystemRoot,

    pub fn init(
        transaction: *transaction_mod.Transaction,
        snapshot: Snapshot,
    ) Error!Mutator {
        if (!transaction.store.sameBackend(snapshot.store) or
            transaction.base_generation != snapshot.generation)
        {
            return error.StaleSnapshot;
        }
        const base_head = transaction.base_head orelse return error.StaleSnapshot;
        if (!store_mod.ObjectRef.eql(base_head, snapshot.commit_ref))
            return error.StaleSnapshot;
        return .{
            .transaction = transaction,
            .trees = tree.Mutator.init(transaction),
            .root = snapshot.root,
        };
    }

    pub fn deinit(self: *Mutator) void {
        self.trees.deinit();
        self.* = undefined;
    }

    pub fn createEmptyFile(
        self: *Mutator,
        parent_inode_id: format_mod.InodeId,
        name: []const u8,
        options: CreateFileOptions,
    ) !format_mod.InodeId {
        const parent = try self.getInode(parent_inode_id) orelse return error.ParentNotFound;
        if (parent.kind != .directory) return error.NotDirectory;

        var directory_key_buffer: format_mod.DirectoryKeyBuffer = undefined;
        const directory_key = try format_mod.encodeDirectoryKey(
            &directory_key_buffer,
            parent_inode_id,
            name,
        );
        var existing = try self.trees.get(self.root.directory_tree_root, directory_key);
        if (existing) |*value| {
            value.deinit();
            return error.AlreadyExists;
        }

        const inode_id = self.root.next_inode_id;
        const next_inode_id = std.math.add(format_mod.InodeId, inode_id, 1) catch
            return error.InodeIdOverflow;
        if (try self.getInode(inode_id) != null) return error.InodeIdCollision;
        const inode = format_mod.Inode{
            .kind = .file,
            .inode_id = inode_id,
            .logical_size = 0,
            .allocated_bytes = 0,
            .link_count = 1,
            .mode = options.mode,
            .uid = options.uid,
            .gid = options.gid,
            .atime_ns = options.now_ns,
            .mtime_ns = options.now_ns,
            .ctime_ns = options.now_ns,
            .birthtime_ns = options.now_ns,
        };
        const inode_key = try format_mod.encodeInodeKey(inode_id);
        const encoded_inode = try format_mod.encodeInode(inode);
        const encoded_entry = try format_mod.encodeDirectoryEntry(.{
            .child_kind = .file,
            .parent_inode_id = parent_inode_id,
            .child_inode_id = inode_id,
        });

        const inode_tree_root = try self.trees.put(
            self.root.inode_tree_root,
            &inode_key,
            &encoded_inode,
        );
        const directory_tree_root = try self.trees.put(
            self.root.directory_tree_root,
            directory_key,
            &encoded_entry,
        );
        self.root.inode_tree_root = inode_tree_root;
        self.root.directory_tree_root = directory_tree_root;
        self.root.next_inode_id = next_inode_id;
        return inode_id;
    }

    /// Stages the current filesystem root without publishing it.
    pub fn finish(self: *Mutator) !store_mod.ObjectRef {
        const encoded = try format_mod.encodeFilesystemRoot(self.root);
        return self.transaction.putImmutable(&encoded);
    }

    fn getInode(self: *Mutator, inode_id: format_mod.InodeId) !?format_mod.Inode {
        const key = try format_mod.encodeInodeKey(inode_id);
        var encoded = try self.trees.get(self.root.inode_tree_root, &key);
        defer if (encoded) |*value| value.deinit();
        const value = encoded orelse return null;
        const inode = try format_mod.decodeInode(value.bytes);
        try format_mod.validateInodeKeyValue(&key, inode);
        return inode;
    }
};
