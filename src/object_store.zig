const std = @import("std");
const Io = std.Io;
const c = @import("block_device.zig").c;
const metadata = @import("metadata.zig");
const format = @import("object_format.zig");

pub const max_path_bytes: usize = 4096;
pub const namespace_root = "/namespace";
const system_root = "/system";
const objects_root = system_root ++ "/objects";
const temporary_root = system_root ++ "/tmp";
const chunk_header_size: usize = 24;
const chunk_magic = [8]u8{ 'D', 'D', 'V', 'C', 'H', 'N', 'K', '2' };

const ChunkVersion = struct {
    index: u64,
    generation: u64,
};

const ChunkChange = struct {
    old_size: u32,
    new_size: u32,
};

pub const WriteResult = struct {
    amount: usize,
    head: format.ObjectHead,
};

pub const Store = struct {
    io: Io,
    lfs: *c.lfs_t,

    pub fn initialize(self: Store) !void {
        try makeDirectory(self.lfs, namespace_root);
        try makeDirectory(self.lfs, system_root);
        try makeDirectory(self.lfs, objects_root);
        try makeDirectory(self.lfs, temporary_root);
    }

    pub fn recoverOrphans(self: Store) !void {
        var referenced = std.AutoHashMap(format.ObjectId, void).init(std.heap.c_allocator);
        defer referenced.deinit();
        try self.collectNamespaceRefs(namespace_root, &referenced);
        while (try self.firstOrphan(&referenced)) |id| try self.removeObject(id);
    }

    pub fn translateUserPath(path: [*:0]const u8, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
        const value = std.mem.span(path);
        if (value.len == 0 or value[0] != '/') return error.InvalidArgument;
        if (std.mem.eql(u8, value, "/")) return formatPath(buffer, "{s}", .{namespace_root});
        var components = std.mem.splitScalar(u8, value[1..], '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, ".."))
                return error.InvalidArgument;
        }
        return formatPath(buffer, "{s}{s}", .{ namespace_root, value });
    }

    pub fn createObject(
        self: Store,
        kind: format.RefKind,
        object_metadata: metadata.Metadata,
    ) !format.ObjectRef {
        var id: format.ObjectId = undefined;
        try self.io.randomSecure(&id);
        const object_ref: format.ObjectRef = .{ .kind = kind, .object_id = id };

        var object_path_buffer: [max_path_bytes:0]u8 = @splat(0);
        const object_path = try objectPath(id, &object_path_buffer);
        try checkLfs(c.lfs_mkdir(self.lfs, object_path));
        errdefer self.removeObject(id) catch {};

        var chunks_path_buffer: [max_path_bytes:0]u8 = @splat(0);
        try checkLfs(c.lfs_mkdir(self.lfs, try chunksPath(id, &chunks_path_buffer)));
        const head: format.ObjectHead = .{
            .object_id = id,
            .generation = 1,
            .logical_size = 0,
            .allocated_bytes = 0,
            .metadata = object_metadata,
        };
        try self.writeHead(head);
        return object_ref;
    }

    pub fn publishRef(
        self: Store,
        path: [*:0]const u8,
        object_ref: format.ObjectRef,
        exclusive: bool,
    ) !void {
        var translated_buffer: [max_path_bytes:0]u8 = @splat(0);
        const translated = try translateUserPath(path, &translated_buffer);
        var temporary_buffer: [max_path_bytes:0]u8 = @splat(0);
        var id_buffer: [32]u8 = undefined;
        const temporary = try formatPath(&temporary_buffer, "{s}/{s}.ref", .{
            temporary_root,
            format.formatObjectId(object_ref.object_id, &id_buffer),
        });
        const bytes = object_ref.encode();
        try writeExact(self.lfs, temporary, &bytes);
        errdefer removeIfPresent(self.lfs, temporary) catch {};
        if (exclusive) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_stat(self.lfs, translated, &info);
            if (result >= 0) return error.PathAlreadyExists;
            if (result != c.LFS_ERR_NOENT) try checkLfs(result);
        }
        try checkLfs(c.lfs_rename(self.lfs, temporary, translated));
    }

    pub fn readRef(self: Store, path: [*:0]const u8) !format.ObjectRef {
        var translated_buffer: [max_path_bytes:0]u8 = @splat(0);
        return self.readRefInternal(try translateUserPath(path, &translated_buffer));
    }

    pub fn readHead(self: Store, id: format.ObjectId) !format.ObjectHead {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        const path = try headPath(id, &path_buffer);
        var bytes: [format.head_encoded_size]u8 = undefined;
        try readExact(self.lfs, path, &bytes);
        const head = try format.ObjectHead.decode(&bytes);
        if (!std.mem.eql(u8, &head.object_id, &id)) return error.InvalidObjectHead;
        return head;
    }

    pub fn writeHead(self: Store, head: format.ObjectHead) !void {
        var temporary_buffer: [max_path_bytes:0]u8 = @splat(0);
        var final_buffer: [max_path_bytes:0]u8 = @splat(0);
        const temporary = try temporaryHeadPath(head.object_id, &temporary_buffer);
        const final = try headPath(head.object_id, &final_buffer);
        const bytes = head.encode();
        try writeExact(self.lfs, temporary, &bytes);
        try checkLfs(c.lfs_rename(self.lfs, temporary, final));
    }

    pub fn read(
        self: Store,
        id: format.ObjectId,
        buffer: []u8,
        offset: u64,
    ) !usize {
        const head = try self.readHead(id);
        if (offset >= head.logical_size or buffer.len == 0) return 0;
        const available = head.logical_size - offset;
        const amount: usize = @intCast(@min(@as(u64, buffer.len), available));
        @memset(buffer[0..amount], 0);

        var consumed: usize = 0;
        while (consumed < amount) {
            const position = offset + consumed;
            const index = position / head.stored_chunk_size;
            const chunk_offset: u32 = @intCast(position % head.stored_chunk_size);
            const part = @min(amount - consumed, head.stored_chunk_size - chunk_offset);
            try self.readChunk(id, index, head.data_generation, buffer[consumed..][0..part], chunk_offset);
            consumed += part;
        }
        return amount;
    }

    pub fn write(
        self: Store,
        id: format.ObjectId,
        data: []const u8,
        offset: u64,
    ) !WriteResult {
        const end = std.math.add(u64, offset, data.len) catch return error.FileTooLarge;
        if (end > format.max_file_size) return error.FileTooLarge;
        if (data.len == 0) return .{ .amount = 0, .head = try self.readHead(id) };

        var head = try self.readHead(id);
        const generation = std.math.add(u64, head.data_generation, 1) catch return error.CorruptFilesystem;
        var touched = std.AutoHashMap(u64, void).init(std.heap.c_allocator);
        defer touched.deinit();
        var consumed: usize = 0;
        while (consumed < data.len) {
            const position = offset + consumed;
            const index = position / head.stored_chunk_size;
            const chunk_offset: u32 = @intCast(position % head.stored_chunk_size);
            const part = @min(data.len - consumed, head.stored_chunk_size - chunk_offset);
            const change = try self.writeChunk(
                id,
                index,
                head.data_generation,
                generation,
                data[consumed..][0..part],
                chunk_offset,
            );
            head.allocated_bytes = try adjustAllocated(head.allocated_bytes, change);
            try touched.put(index, {});
            consumed += part;
        }

        head.logical_size = @max(head.logical_size, end);
        head.generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        head.data_generation = generation;
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head.metadata.mtime_ns = now;
        head.metadata.ctime_ns = now;
        try self.writeHead(head);
        var touched_iterator = touched.keyIterator();
        while (touched_iterator.next()) |index| self.pruneChunkVersions(id, index.*, generation) catch {};
        return .{ .amount = data.len, .head = head };
    }

    pub fn truncate(self: Store, id: format.ObjectId, size: u64) !format.ObjectHead {
        if (size > format.max_file_size) return error.FileTooLarge;
        var head = try self.readHead(id);
        const generation = std.math.add(u64, head.data_generation, 1) catch return error.CorruptFilesystem;
        var touched = std.AutoHashMap(u64, void).init(std.heap.c_allocator);
        defer touched.deinit();
        if (size < head.logical_size) {
            try self.truncateChunks(&head, size, generation, &touched);
        }
        head.logical_size = size;
        head.generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        head.data_generation = generation;
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head.metadata.mtime_ns = now;
        head.metadata.ctime_ns = now;
        try self.writeHead(head);
        var touched_iterator = touched.keyIterator();
        while (touched_iterator.next()) |index| self.pruneChunkVersions(id, index.*, generation) catch {};
        return head;
    }

    pub fn updateMetadata(self: Store, id: format.ObjectId, value: metadata.Metadata) !void {
        var head = try self.readHead(id);
        head.metadata = value;
        head.generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        try self.writeHead(head);
    }

    pub fn removeObject(self: Store, id: format.ObjectId) !void {
        while (try self.firstChunkName(id)) |name| {
            var path_buffer: [max_path_bytes:0]u8 = @splat(0);
            try checkLfs(c.lfs_remove(self.lfs, try namedChunkPath(id, name, &path_buffer)));
        }

        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        try removeIfPresent(self.lfs, try temporaryHeadPath(id, &path_buffer));
        path_buffer = @splat(0);
        try removeIfPresent(self.lfs, try headPath(id, &path_buffer));
        path_buffer = @splat(0);
        try removeIfPresent(self.lfs, try chunksPath(id, &path_buffer));
        path_buffer = @splat(0);
        try removeIfPresent(self.lfs, try objectPath(id, &path_buffer));
    }

    fn readRefInternal(self: Store, path: [*:0]const u8) !format.ObjectRef {
        var bytes: [format.ref_encoded_size]u8 = undefined;
        try readExact(self.lfs, path, &bytes);
        return format.ObjectRef.decode(&bytes);
    }

    fn readChunk(
        self: Store,
        id: format.ObjectId,
        index: u64,
        generation: u64,
        buffer: []u8,
        offset: u32,
    ) !void {
        const version = try self.findChunkVersion(id, index, generation) orelse return;
        const chunk = try std.heap.c_allocator.alloc(u8, format.chunk_size);
        defer std.heap.c_allocator.free(chunk);
        @memset(chunk, 0);
        const length = try self.readChunkVersion(id, version, chunk);
        if (offset >= length) return;
        const amount = @min(buffer.len, length - offset);
        @memcpy(buffer[0..amount], chunk[offset..][0..amount]);
    }

    fn writeChunk(
        self: Store,
        id: format.ObjectId,
        index: u64,
        old_generation: u64,
        new_generation: u64,
        data: []const u8,
        offset: u32,
    ) !ChunkChange {
        const chunk = try std.heap.c_allocator.alloc(u8, format.chunk_size);
        defer std.heap.c_allocator.free(chunk);
        @memset(chunk, 0);
        const old_size = if (try self.findChunkVersion(id, index, old_generation)) |version|
            try self.readChunkVersion(id, version, chunk)
        else
            0;
        const new_size: u32 = @intCast(@max(@as(usize, old_size), @as(usize, offset) + data.len));
        @memcpy(chunk[offset..][0..data.len], data);
        try self.writeChunkVersion(id, .{ .index = index, .generation = new_generation }, chunk[0..new_size]);
        return .{ .old_size = old_size, .new_size = new_size };
    }

    fn truncateChunks(
        self: Store,
        head: *format.ObjectHead,
        size: u64,
        generation: u64,
        touched: *std.AutoHashMap(u64, void),
    ) !void {
        var indices = std.AutoHashMap(u64, void).init(std.heap.c_allocator);
        defer indices.deinit();
        try self.collectChunkIndices(head.object_id, &indices);
        var iterator = indices.keyIterator();
        while (iterator.next()) |index| {
            const version = try self.findChunkVersion(head.object_id, index.*, head.data_generation) orelse continue;
            const chunk = try std.heap.c_allocator.alloc(u8, head.stored_chunk_size);
            defer std.heap.c_allocator.free(chunk);
            @memset(chunk, 0);
            const old_size = try self.readChunkVersion(head.object_id, version, chunk);
            const start = std.math.mul(u64, index.*, head.stored_chunk_size) catch return error.CorruptFilesystem;
            const new_size: u32 = if (start >= size) 0 else @intCast(@min(@as(u64, old_size), size - start));
            if (new_size == old_size) continue;
            try self.writeChunkVersion(
                head.object_id,
                .{ .index = index.*, .generation = generation },
                chunk[0..new_size],
            );
            head.allocated_bytes = try adjustAllocated(head.allocated_bytes, .{
                .old_size = old_size,
                .new_size = new_size,
            });
            try touched.put(index.*, {});
        }
    }

    fn collectChunkIndices(self: Store, id: format.ObjectId, indices: *std.AutoHashMap(u64, void)) !void {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try chunksPath(id, &path_buffer)));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            const version = parseChunkVersion(name) catch continue;
            try indices.put(version.index, {});
        }
    }

    fn findChunkVersion(self: Store, id: format.ObjectId, index: u64, generation: u64) !?ChunkVersion {
        var selected: ?ChunkVersion = null;
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try chunksPath(id, &path_buffer)));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return selected;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            const version = parseChunkVersion(name) catch continue;
            if (version.index != index or version.generation > generation) continue;
            if (selected == null or version.generation > selected.?.generation) selected = version;
        }
    }

    fn firstChunkName(self: Store, id: format.ObjectId) !?[33]u8 {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        const open_result = c.lfs_dir_open(self.lfs, &directory, try chunksPath(id, &path_buffer));
        if (open_result == c.LFS_ERR_NOENT) return null;
        try checkLfs(open_result);
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return null;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (name.len != 33) continue;
            var copy: [33]u8 = undefined;
            @memcpy(&copy, name);
            return copy;
        }
    }

    fn readChunkVersion(self: Store, id: format.ObjectId, version: ChunkVersion, buffer: []u8) !u32 {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try checkLfs(c.lfs_file_open(self.lfs, &file, try chunkVersionPath(id, version, &path_buffer), c.LFS_O_RDONLY));
        defer _ = c.lfs_file_close(self.lfs, &file);
        var header: [chunk_header_size]u8 = undefined;
        const header_amount = c.lfs_file_read(self.lfs, &file, &header, header.len);
        try checkLfs(header_amount);
        if (header_amount != header.len or !std.mem.eql(u8, header[0..8], &chunk_magic))
            return error.CorruptFilesystem;
        if (std.mem.readInt(u64, header[8..16], .little) != version.generation)
            return error.CorruptFilesystem;
        const length = std.mem.readInt(u32, header[16..20], .little);
        if (length > buffer.len) return error.CorruptFilesystem;
        const amount = c.lfs_file_read(self.lfs, &file, buffer.ptr, length);
        try checkLfs(amount);
        if (amount != length or std.hash.crc.Crc32Iscsi.hash(buffer[0..length]) !=
            std.mem.readInt(u32, header[20..24], .little))
            return error.CorruptFilesystem;
        return length;
    }

    fn writeChunkVersion(self: Store, id: format.ObjectId, version: ChunkVersion, data: []const u8) !void {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try checkLfs(c.lfs_file_open(
            self.lfs,
            &file,
            try chunkVersionPath(id, version, &path_buffer),
            c.LFS_O_WRONLY | c.LFS_O_CREAT | c.LFS_O_TRUNC,
        ));
        var open = true;
        errdefer if (open) {
            _ = c.lfs_file_close(self.lfs, &file);
        };
        var header: [chunk_header_size]u8 = @splat(0);
        @memcpy(header[0..8], &chunk_magic);
        std.mem.writeInt(u64, header[8..16], version.generation, .little);
        std.mem.writeInt(u32, header[16..20], @intCast(data.len), .little);
        std.mem.writeInt(u32, header[20..24], std.hash.crc.Crc32Iscsi.hash(data), .little);
        try writeToOpenFile(self.lfs, &file, &header);
        try writeToOpenFile(self.lfs, &file, data);
        const close_result = c.lfs_file_close(self.lfs, &file);
        open = false;
        try checkLfs(close_result);
    }

    fn pruneChunkVersions(self: Store, id: format.ObjectId, index: u64, keep_generation: u64) !void {
        while (try self.firstObsoleteChunkVersion(id, index, keep_generation)) |version| {
            var path_buffer: [max_path_bytes:0]u8 = @splat(0);
            try checkLfs(c.lfs_remove(self.lfs, try chunkVersionPath(id, version, &path_buffer)));
        }
    }

    fn firstObsoleteChunkVersion(
        self: Store,
        id: format.ObjectId,
        index: u64,
        keep_generation: u64,
    ) !?ChunkVersion {
        var path_buffer: [max_path_bytes:0]u8 = @splat(0);
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try chunksPath(id, &path_buffer)));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return null;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            const version = parseChunkVersion(name) catch continue;
            if (version.index == index and version.generation != keep_generation) return version;
        }
    }

    fn firstOrphan(self: Store, referenced: *const std.AutoHashMap(format.ObjectId, void)) !?format.ObjectId {
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, objects_root));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return null;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (name.len != 32) continue;
            const id = format.parseObjectId(name) catch continue;
            if (!referenced.contains(id)) return id;
        }
    }

    fn collectNamespaceRefs(
        self: Store,
        directory_path: [*:0]const u8,
        referenced: *std.AutoHashMap(format.ObjectId, void),
    ) !void {
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, directory_path));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child_buffer: [max_path_bytes:0]u8 = @splat(0);
            const child = try formatPath(&child_buffer, "{s}/{s}", .{ std.mem.span(directory_path), name });
            if (info.type == c.LFS_TYPE_DIR) {
                try self.collectNamespaceRefs(child, referenced);
            } else {
                const object_ref = try self.readRefInternal(child);
                try referenced.put(object_ref.object_id, {});
            }
        }
    }
};

fn makeDirectory(lfs: *c.lfs_t, path: [*:0]const u8) !void {
    const result = c.lfs_mkdir(lfs, path);
    if (result != c.LFS_ERR_EXIST) try checkLfs(result);
}

fn readExact(lfs: *c.lfs_t, path: [*:0]const u8, buffer: []u8) !void {
    var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
    try checkLfs(c.lfs_file_open(lfs, &file, path, c.LFS_O_RDONLY));
    defer _ = c.lfs_file_close(lfs, &file);
    const amount = c.lfs_file_read(lfs, &file, buffer.ptr, @intCast(buffer.len));
    try checkLfs(amount);
    if (amount != buffer.len) return error.InvalidObjectFormat;
}

fn writeExact(lfs: *c.lfs_t, path: [*:0]const u8, data: []const u8) !void {
    var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
    try checkLfs(c.lfs_file_open(lfs, &file, path, c.LFS_O_WRONLY | c.LFS_O_CREAT | c.LFS_O_TRUNC));
    var open = true;
    errdefer if (open) {
        _ = c.lfs_file_close(lfs, &file);
    };
    const amount = c.lfs_file_write(lfs, &file, data.ptr, @intCast(data.len));
    try checkLfs(amount);
    if (amount != data.len) return error.InputOutput;
    const close_result = c.lfs_file_close(lfs, &file);
    open = false;
    try checkLfs(close_result);
}

fn writeToOpenFile(lfs: *c.lfs_t, file: *c.lfs_file_t, data: []const u8) !void {
    if (data.len == 0) return;
    const amount = c.lfs_file_write(lfs, file, data.ptr, @intCast(data.len));
    try checkLfs(amount);
    if (amount != data.len) return error.InputOutput;
}

fn adjustAllocated(current: u64, change: ChunkChange) !u64 {
    if (change.new_size >= change.old_size)
        return std.math.add(u64, current, change.new_size - change.old_size) catch
            error.CorruptFilesystem;
    return std.math.sub(u64, current, change.old_size - change.new_size) catch
        error.CorruptFilesystem;
}

fn parseChunkVersion(name: []const u8) !ChunkVersion {
    if (name.len != 33 or name[16] != '-') return error.InvalidChunkName;
    return .{
        .index = std.fmt.parseInt(u64, name[0..16], 16) catch return error.InvalidChunkName,
        .generation = std.fmt.parseInt(u64, name[17..33], 16) catch return error.InvalidChunkName,
    };
}

fn removeIfPresent(lfs: *c.lfs_t, path: [*:0]const u8) !void {
    const result = c.lfs_remove(lfs, path);
    if (result != c.LFS_ERR_NOENT) try checkLfs(result);
}

fn objectPath(id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}", .{ objects_root, format.formatObjectId(id, &id_buffer) });
}

fn chunksPath(id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/chunks", .{ objects_root, format.formatObjectId(id, &id_buffer) });
}

fn headPath(id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/head", .{ objects_root, format.formatObjectId(id, &id_buffer) });
}

fn temporaryHeadPath(id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/head.tmp", .{ objects_root, format.formatObjectId(id, &id_buffer) });
}

fn chunkVersionPath(id: format.ObjectId, version: ChunkVersion, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/chunks/{x:0>16}-{x:0>16}", .{
        objects_root,
        format.formatObjectId(id, &id_buffer),
        version.index,
        version.generation,
    });
}

fn namedChunkPath(id: format.ObjectId, name: [33]u8, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/chunks/{s}", .{
        objects_root,
        format.formatObjectId(id, &id_buffer),
        name,
    });
}

fn formatPath(buffer: *[max_path_bytes:0]u8, comptime pattern: []const u8, args: anytype) ![*:0]const u8 {
    @memset(buffer, 0);
    _ = std.fmt.bufPrint(buffer[0..max_path_bytes], pattern, args) catch return error.NameTooLong;
    return @ptrCast(buffer);
}

fn checkLfs(result: anytype) !void {
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
        else => error.LittleFsFailure,
    };
}

test "user paths are isolated below the namespace root" {
    var buffer: [max_path_bytes:0]u8 = @splat(0);
    try std.testing.expectEqualStrings(namespace_root, std.mem.span(try Store.translateUserPath("/", &buffer)));
    try std.testing.expectEqualStrings("/namespace/a/b", std.mem.span(try Store.translateUserPath("/a/b", &buffer)));
    try std.testing.expectError(error.InvalidArgument, Store.translateUserPath("/../system", &buffer));
    try std.testing.expectError(error.InvalidArgument, Store.translateUserPath("/a/../../system", &buffer));
    try std.testing.expectError(error.InvalidArgument, Store.translateUserPath("/a//b", &buffer));
}
