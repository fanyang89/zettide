const std = @import("std");
const Io = std.Io;
const File = Io.File;
const container = @import("container.zig");
const block_device = @import("block_device.zig");
const metadata = @import("metadata.zig");
const object_format = @import("object_format.zig");
const object_store = @import("object_store.zig");
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
    writable: bool = false,
    open_files: ?*FileHandle = null,
    link_counts: std.AutoHashMap(object_format.ObjectId, u64),
    object_pins: std.AutoHashMap(object_format.ObjectId, u64),

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
        const object_store_handle: object_store.Store = .{ .io = io, .lfs = &lfs };
        try object_store_handle.initialize();
        const owner = hostOwner();
        const root_metadata = metadata.Metadata.init(io, .directory, 0o40755, owner.uid, owner.gid);
        const root_bytes = root_metadata.encode();
        try checkLfs(c.lfs_setattr(&lfs, object_store.namespace_root, metadata.attribute_type, &root_bytes, root_bytes.len));
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
        result.writable = writable;
        result.open_files = null;
        result.link_counts = std.AutoHashMap(object_format.ObjectId, u64).init(std.heap.c_allocator);
        result.object_pins = std.AutoHashMap(object_format.ObjectId, u64).init(std.heap.c_allocator);
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
        errdefer {
            _ = c.lfs_unmount(&self.lfs);
            self.mounted = false;
        }
        self.link_counts.clearRetainingCapacity();
        self.object_pins.clearRetainingCapacity();
        try self.store().collectLinkCounts(&self.link_counts);
        if (self.writable) try self.store().recoverOrphans(&self.link_counts);
    }

    pub fn deinit(self: *Volume) void {
        if (self.mounted) {
            _ = c.lfs_unmount(&self.lfs);
            self.mounted = false;
        }
        self.object_pins.deinit();
        self.link_counts.deinit();
        self.file.close(self.io);
    }

    pub fn usedBlocks(self: *Volume) !u32 {
        const result = c.lfs_fs_size(&self.lfs);
        try checkLfs(result);
        return @intCast(result);
    }

    pub fn stat(self: *Volume, path: [*:0]const u8) !NodeInfo {
        var translated_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
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
        if (info.type == c.LFS_TYPE_DIR) return .{
            .size = 0,
            .allocated_bytes = 0,
            .metadata = stored_metadata,
            .object_id = null,
            .nlink = try self.directoryLinkCount(translated),
        };
        const object_ref = try self.store().readRef(path);
        const head = try self.store().readHead(object_ref.object_id);
        return .{
            .size = head.logical_size,
            .allocated_bytes = head.allocated_bytes,
            .metadata = head.metadata,
            .object_id = object_ref.object_id,
            .nlink = try self.linkCount(object_ref.object_id),
        };
    }

    pub fn statFile(self: *Volume, handle: *FileHandle) !NodeInfo {
        const info = try self.statObject(handle.object_id);
        handle.metadata = info.metadata;
        return info;
    }

    pub fn statObject(self: *Volume, object_id: object_format.ObjectId) !NodeInfo {
        const head = try self.store().readHead(object_id);
        return .{
            .size = head.logical_size,
            .allocated_bytes = head.allocated_bytes,
            .metadata = head.metadata,
            .object_id = object_id,
            .nlink = try self.linkCount(object_id),
        };
    }

    pub fn linkCount(self: *const Volume, object_id: object_format.ObjectId) !u64 {
        return self.link_counts.get(object_id) orelse error.CorruptFilesystem;
    }

    pub fn pinObject(self: *Volume, object_id: object_format.ObjectId) !void {
        if (!self.link_counts.contains(object_id)) return error.CorruptFilesystem;
        const entry = try self.object_pins.getOrPut(object_id);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* = std.math.add(u64, entry.value_ptr.*, 1) catch
            return error.TooManyReferences;
    }

    pub fn unpinObject(self: *Volume, object_id: object_format.ObjectId) !void {
        const count = self.object_pins.getPtr(object_id) orelse return error.InvalidArgument;
        if (count.* == 0) return error.InvalidArgument;
        count.* -= 1;
        if (count.* != 0) return;
        _ = self.object_pins.remove(object_id);
        try self.reclaimObjectIfUnused(object_id);
    }

    pub fn objectPinCount(self: *const Volume, object_id: object_format.ObjectId) u64 {
        return self.object_pins.get(object_id) orelse 0;
    }

    pub fn trackedObjectCount(self: *const Volume) usize {
        return self.link_counts.count();
    }

    pub fn setMetadata(self: *Volume, path: [*:0]const u8, value: metadata.Metadata) !void {
        var translated_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        if (info.type != c.LFS_TYPE_DIR) {
            const object_ref = try self.store().readRef(path);
            try self.store().updateMetadata(object_ref.object_id, value);
            self.updateOpenMetadata(object_ref.object_id, value);
            return;
        }
        const bytes = value.encode();
        try checkLfs(c.lfs_setattr(&self.lfs, translated, metadata.attribute_type, &bytes, bytes.len));
    }

    pub fn getMetadata(self: *Volume, path: [*:0]const u8) !metadata.Metadata {
        var translated_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        if (info.type != c.LFS_TYPE_DIR) {
            const object_ref = try self.store().readRef(path);
            return (try self.store().readHead(object_ref.object_id)).metadata;
        }
        var bytes: [metadata.encoded_size]u8 = undefined;
        const result = c.lfs_getattr(&self.lfs, translated, metadata.attribute_type, &bytes, bytes.len);
        if (result < 0) {
            try checkLfs(result);
            unreachable;
        }
        if (result != bytes.len) return error.InvalidMetadata;
        return metadata.Metadata.decode(&bytes);
    }

    pub fn makeDirectory(self: *Volume, path: [*:0]const u8, mode: u32, uid: u32, gid: u32) !void {
        const inherited = try self.inheritCreateMetadata(path, mode, gid, true);
        var translated_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        try checkLfs(c.lfs_mkdir(&self.lfs, translated));
        errdefer _ = c.lfs_remove(&self.lfs, translated);
        try self.setMetadata(path, metadata.Metadata.init(
            self.io,
            .directory,
            inherited.mode,
            uid,
            inherited.gid,
        ));
        try self.updateParentTimes(path);
    }

    pub fn makeSymlink(self: *Volume, path: [*:0]const u8, target: []const u8, uid: u32, gid: u32) !void {
        const inherited = try self.inheritCreateMetadata(path, 0o120777, gid, false);
        try self.createSpecial(path, target, .symlink, .symlink, inherited.mode, uid, inherited.gid);
    }

    pub fn makeFifo(self: *Volume, path: [*:0]const u8, mode: u32, uid: u32, gid: u32) !void {
        const inherited = try self.inheritCreateMetadata(path, mode, gid, false);
        try self.createSpecial(path, "", .fifo, .fifo, inherited.mode, uid, inherited.gid);
    }

    pub fn link(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !void {
        _ = try self.linkWithInfo(old_path, new_path);
    }

    pub fn linkWithInfo(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !NodeInfo {
        const object_ref = self.store().readRef(old_path) catch |err| switch (err) {
            error.IsDirectory => return error.PermissionDenied,
            else => return err,
        };
        const count = self.link_counts.getPtr(object_ref.object_id) orelse
            return error.CorruptFilesystem;
        if (count.* == std.math.maxInt(u64)) return error.TooManyLinks;
        var translated_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const translated = try object_store.Store.translateUserPath(new_path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        const stat_result = c.lfs_stat(&self.lfs, translated, &info);
        if (stat_result >= 0) return error.PathAlreadyExists;
        if (stat_result != c.LFS_ERR_NOENT) try checkLfs(stat_result);
        try self.validateParentDirectory(new_path);
        var head = try self.store().readHead(object_ref.object_id);
        head.metadata.ctime_ns = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        try self.store().updateMetadata(object_ref.object_id, head.metadata);
        self.updateOpenMetadata(object_ref.object_id, head.metadata);
        try self.updateParentTimes(new_path);
        try self.store().publishRef(new_path, object_ref, true);
        count.* += 1;
        return .{
            .size = head.logical_size,
            .allocated_bytes = head.allocated_bytes,
            .metadata = head.metadata,
            .object_id = object_ref.object_id,
            .nlink = count.*,
        };
    }

    pub fn remove(self: *Volume, path: [*:0]const u8) !void {
        var translated_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        const removed_object = if (info.type == c.LFS_TYPE_DIR) null else try self.store().readRef(path);
        if (info.type == c.LFS_TYPE_DIR and !try self.directoryIsEmpty(translated))
            return error.DirectoryNotEmpty;
        const object_count = if (removed_object) |object_ref|
            self.link_counts.getPtr(object_ref.object_id) orelse return error.CorruptFilesystem
        else
            null;
        if (object_count) |count| if (count.* == 0) return error.CorruptFilesystem;
        if (removed_object) |object_ref| {
            var object_metadata = (try self.store().readHead(object_ref.object_id)).metadata;
            object_metadata.ctime_ns = @intCast(Io.Clock.real.now(self.io).nanoseconds);
            try self.store().updateMetadata(object_ref.object_id, object_metadata);
            self.updateOpenMetadata(object_ref.object_id, object_metadata);
        }
        try self.updateParentTimes(path);
        try checkLfs(c.lfs_remove(&self.lfs, translated));
        if (removed_object) |object_ref| {
            object_count.?.* -= 1;
            self.reclaimObjectIfUnused(object_ref.object_id) catch {};
        }
    }

    pub fn rename(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !void {
        _ = try self.renameWithResult(old_path, new_path);
    }

    pub fn renameWithResult(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !RenameResult {
        if (std.mem.eql(u8, std.mem.span(old_path), std.mem.span(new_path))) return .same_object;
        var old_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        var new_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const old_translated = try object_store.Store.translateUserPath(old_path, &old_buffer);
        const new_translated = try object_store.Store.translateUserPath(new_path, &new_buffer);
        var old_info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, old_translated, &old_info));
        var new_info: c.struct_lfs_info = undefined;
        const new_stat_result = c.lfs_stat(&self.lfs, new_translated, &new_info);
        const new_exists = new_stat_result >= 0;
        if (!new_exists and new_stat_result != c.LFS_ERR_NOENT) try checkLfs(new_stat_result);
        if (new_exists) {
            if (old_info.type == c.LFS_TYPE_DIR and new_info.type != c.LFS_TYPE_DIR)
                return error.NotDirectory;
            if (old_info.type != c.LFS_TYPE_DIR and new_info.type == c.LFS_TYPE_DIR)
                return error.IsDirectory;
            if (new_info.type == c.LFS_TYPE_DIR and !try self.directoryIsEmpty(new_translated))
                return error.DirectoryNotEmpty;
        }
        if (old_info.type == c.LFS_TYPE_DIR) {
            const old_value = std.mem.span(old_path);
            const new_parent = parentSlice(new_path);
            if (std.mem.eql(u8, old_value, new_parent) or
                (new_parent.len > old_value.len and std.mem.startsWith(u8, new_parent, old_value) and
                    new_parent[old_value.len] == '/'))
                return error.InvalidArgument;
        }
        try self.validateParentDirectory(new_path);
        const replaced = self.store().readRef(new_path) catch |err| switch (err) {
            error.FileNotFound, error.IsDirectory => null,
            else => return err,
        };
        const source = self.store().readRef(old_path) catch |err| switch (err) {
            error.IsDirectory => null,
            else => return err,
        };
        if (source != null and replaced != null and
            std.mem.eql(u8, &source.?.object_id, &replaced.?.object_id))
            return .same_object;
        const replaced_count = if (replaced) |object_ref|
            self.link_counts.getPtr(object_ref.object_id) orelse return error.CorruptFilesystem
        else
            null;
        if (replaced_count) |count| if (count.* == 0) return error.CorruptFilesystem;
        const timestamp: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        if (replaced) |object_ref| {
            var replaced_metadata = (try self.store().readHead(object_ref.object_id)).metadata;
            replaced_metadata.ctime_ns = timestamp;
            try self.store().updateMetadata(object_ref.object_id, replaced_metadata);
            self.updateOpenMetadata(object_ref.object_id, replaced_metadata);
        }
        var renamed_metadata = try self.getMetadata(old_path);
        renamed_metadata.ctime_ns = timestamp;
        try self.setMetadata(old_path, renamed_metadata);
        try self.updateParentTimes(old_path);
        if (!std.mem.eql(u8, parentSlice(old_path), parentSlice(new_path)))
            try self.updateParentTimes(new_path);
        try checkLfs(c.lfs_rename(&self.lfs, old_translated, new_translated));
        if (replaced) |object_ref| {
            replaced_count.?.* -= 1;
            self.reclaimObjectIfUnused(object_ref.object_id) catch {};
        }
        return .renamed;
    }

    pub fn openFile(self: *Volume, handle: *FileHandle, path: [*:0]const u8, flags: c_int, mode: u32, uid: u32, gid: u32) !void {
        const existing_ref = self.store().readRef(path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_ref != null and flags & c.LFS_O_CREAT != 0 and flags & c.LFS_O_EXCL != 0)
            return error.PathAlreadyExists;
        if (existing_ref == null and flags & c.LFS_O_CREAT == 0) return error.FileNotFound;

        const object_ref = existing_ref orelse value: {
            const inherited = try self.inheritCreateMetadata(path, mode, gid, false);
            const created = try self.store().createObject(.file, metadata.Metadata.init(
                self.io,
                .file,
                inherited.mode,
                uid,
                inherited.gid,
            ));
            self.link_counts.put(created.object_id, 0) catch |err| {
                self.store().removeObject(created.object_id) catch {};
                return err;
            };
            self.store().publishRef(path, created, true) catch |err| {
                _ = self.link_counts.remove(created.object_id);
                self.store().removeObject(created.object_id) catch {};
                return err;
            };
            self.link_counts.getPtr(created.object_id).?.* = 1;
            self.updateParentTimes(path) catch {};
            break :value created;
        };
        try self.openObject(handle, object_ref.object_id, flags);
    }

    pub fn openObject(self: *Volume, handle: *FileHandle, object_id: object_format.ObjectId, flags: c_int) !void {
        const head = if (flags & c.LFS_O_TRUNC != 0)
            try self.store().truncate(object_id, 0)
        else
            try self.store().readHead(object_id);
        if (flags & c.LFS_O_TRUNC != 0) self.updateOpenMetadata(object_id, head.metadata);
        handle.* = .{
            .object_id = object_id,
            .metadata = head.metadata,
            .original_metadata = head.metadata,
            .append = flags & c.LFS_O_APPEND != 0,
            .writable = flags & c.LFS_O_WRONLY != 0 or flags & c.LFS_O_RDWR != 0,
            .open = true,
            .next = self.open_files,
        };
        self.open_files = handle;
    }

    pub fn closeFile(self: *Volume, handle: *FileHandle) !void {
        if (!handle.open) return;
        try self.unregisterFile(handle);
        handle.open = false;
        try self.reclaimObjectIfUnused(handle.object_id);
    }

    pub fn readFile(self: *Volume, handle: *FileHandle, buffer: []u8, offset: u64) !usize {
        const head = try self.store().readHead(handle.object_id);
        handle.metadata = head.metadata;
        const result = try self.store().read(handle.object_id, buffer, offset);
        const timestamp: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        const one_day = 24 * std.time.ns_per_hour;
        if (self.writable and (handle.metadata.atime_ns <= handle.metadata.mtime_ns or
            handle.metadata.atime_ns <= handle.metadata.ctime_ns or
            timestamp -| handle.metadata.atime_ns >= one_day))
        {
            _ = try self.patchObjectMetadata(handle.object_id, .{ .atime_ns = timestamp });
        }
        return result;
    }

    pub fn writeFile(self: *Volume, handle: *FileHandle, data: []const u8, offset: u64) !usize {
        if (!handle.writable) return error.AccessDenied;
        const effective_offset = if (handle.append)
            (try self.store().readHead(handle.object_id)).logical_size
        else
            offset;
        const result = try self.store().write(handle.object_id, data, effective_offset);
        self.updateOpenMetadata(handle.object_id, result.head.metadata);
        return result.amount;
    }

    pub fn truncateFile(self: *Volume, handle: *FileHandle, size: u64) !void {
        if (!handle.writable) return error.AccessDenied;
        const head = try self.store().truncate(handle.object_id, size);
        self.updateOpenMetadata(handle.object_id, head.metadata);
    }

    pub fn syncFile(self: *Volume, handle: *FileHandle) !void {
        self.device.sync() catch return error.InputOutput;
        handle.original_metadata = handle.metadata;
    }

    pub fn persistMetadata(self: *Volume, handle: *FileHandle) !void {
        try self.store().updateMetadata(handle.object_id, handle.metadata);
        self.updateOpenMetadata(handle.object_id, handle.metadata);
        handle.original_metadata = handle.metadata;
    }

    pub fn setObjectMetadata(self: *Volume, object_id: object_format.ObjectId, value: metadata.Metadata) !void {
        try self.store().updateMetadata(object_id, value);
        self.updateOpenMetadata(object_id, value);
    }

    pub fn patchObjectMetadata(
        self: *Volume,
        object_id: object_format.ObjectId,
        patch: metadata.Patch,
    ) !object_format.ObjectHead {
        const head = try self.store().patchMetadata(object_id, patch);
        self.updateOpenMetadata(object_id, head.metadata);
        return head;
    }

    pub fn readObject(self: *Volume, object_id: object_format.ObjectId, buffer: []u8, offset: u64) !usize {
        return self.store().read(object_id, buffer, offset);
    }

    pub fn openDirectory(self: *Volume, handle: *DirectoryHandle, path: [*:0]const u8) !void {
        var translated_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        try checkLfs(c.lfs_dir_open(
            &self.lfs,
            &handle.dir,
            try object_store.Store.translateUserPath(path, &translated_buffer),
        ));
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

    fn store(self: *Volume) object_store.Store {
        return .{ .io = self.io, .lfs = &self.lfs };
    }

    fn updateOpenMetadata(self: *Volume, id: object_format.ObjectId, value: metadata.Metadata) void {
        var current = self.open_files;
        while (current) |handle| : (current = handle.next) {
            if (std.mem.eql(u8, &handle.object_id, &id)) handle.metadata = value;
        }
    }

    fn hasOpenObject(self: *Volume, id: object_format.ObjectId) bool {
        var current = self.open_files;
        while (current) |handle| : (current = handle.next) {
            if (std.mem.eql(u8, &handle.object_id, &id)) return true;
        }
        return false;
    }

    fn reclaimObjectIfUnused(self: *Volume, id: object_format.ObjectId) !void {
        const links = self.link_counts.get(id) orelse return error.CorruptFilesystem;
        if (links != 0 or self.hasOpenObject(id) or self.objectPinCount(id) != 0) return;
        try self.store().removeObject(id);
        _ = self.link_counts.remove(id);
    }

    fn unregisterFile(self: *Volume, target: *FileHandle) !void {
        var cursor = &self.open_files;
        while (cursor.*) |handle| {
            if (handle == target) {
                cursor.* = handle.next;
                target.next = null;
                return;
            }
            cursor = &handle.next;
        }
        return error.InvalidArgument;
    }

    fn createSpecial(
        self: *Volume,
        path: [*:0]const u8,
        contents: []const u8,
        ref_kind: object_format.RefKind,
        kind: metadata.Kind,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !void {
        const created = try self.store().createObject(ref_kind, metadata.Metadata.init(
            self.io,
            kind,
            mode,
            uid,
            gid,
        ));
        self.link_counts.put(created.object_id, 0) catch |err| {
            self.store().removeObject(created.object_id) catch {};
            return err;
        };
        errdefer {
            _ = self.link_counts.remove(created.object_id);
            self.store().removeObject(created.object_id) catch {};
        }
        if (contents.len != 0) _ = try self.store().write(created.object_id, contents, 0);
        try self.store().publishRef(path, created, true);
        self.link_counts.getPtr(created.object_id).?.* = 1;
        self.updateParentTimes(path) catch {};
    }

    fn inheritCreateMetadata(
        self: *Volume,
        path: [*:0]const u8,
        mode: u32,
        gid: u32,
        directory: bool,
    ) !struct { mode: u32, gid: u32 } {
        const parent = parentSlice(path);
        var buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        if (parent.len >= buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..parent.len], parent);
        const parent_metadata = try self.getMetadata(&buffer);
        if (parent_metadata.mode & 0o2000 == 0) return .{ .mode = mode, .gid = gid };
        return .{
            .mode = if (directory) mode | 0o2000 else mode,
            .gid = parent_metadata.gid,
        };
    }

    fn directoryLinkCount(self: *Volume, translated: [*:0]const u8) !u64 {
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(&self.lfs, &directory, translated));
        defer _ = c.lfs_dir_close(&self.lfs, &directory);
        var count: u64 = 2;
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(&self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return count;
            if (info.type == c.LFS_TYPE_DIR) {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."))
                    count = std.math.add(u64, count, 1) catch return error.CorruptFilesystem;
            }
        }
    }

    fn directoryIsEmpty(self: *Volume, translated: [*:0]const u8) !bool {
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(&self.lfs, &directory, translated));
        defer _ = c.lfs_dir_close(&self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(&self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return true;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) return false;
        }
    }

    fn validateParentDirectory(self: *Volume, path: [*:0]const u8) !void {
        const parent = parentSlice(path);
        var parent_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        @memcpy(parent_buffer[0..parent.len], parent);
        var translated_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const translated = try object_store.Store.translateUserPath(&parent_buffer, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        if (info.type != c.LFS_TYPE_DIR) return error.NotDirectory;
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
    size: u64,
    allocated_bytes: u64,
    metadata: metadata.Metadata,
    object_id: ?object_format.ObjectId,
    nlink: u64,
};

pub const RenameResult = enum {
    renamed,
    same_object,
};

pub const FileHandle = struct {
    object_id: object_format.ObjectId = @splat(0),
    metadata: metadata.Metadata = undefined,
    original_metadata: metadata.Metadata = undefined,
    append: bool = false,
    writable: bool = false,
    open: bool = false,
    next: ?*FileHandle = null,
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
    try std.testing.expectEqual(@as(u64, 5), info.size);
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
