const std = @import("std");
const Io = std.Io;
const c = @import("block_device.zig").c;
const metadata = @import("metadata.zig");
const format = @import("object_format.zig");
const google_crc32c = @import("crc32c");

pub const max_path_bytes: usize = 4096;
pub const namespace_root = "/namespace";
const system_root = "/system";
const objects_root = system_root ++ "/objects";
const temporary_root = system_root ++ "/tmp";
const chunk_header_size: usize = 24;
const chunk_magic = [8]u8{ 'D', 'D', 'V', 'C', 'H', 'N', 'K', '2' };

pub const ChunkLayout = enum { co_located, legacy };

const ChunkVersion = struct {
    index: u64,
    generation: u64,
    layout: ChunkLayout = .co_located,
};

const ChunkChange = struct {
    old_size: u32,
    new_size: u32,
};

const ChunkData = struct {
    bytes: []u8,
    stored_length: u32,
};

const ChunkHeader = struct {
    length: u32,
    crc: u32,
};

pub const WriteResult = struct {
    amount: usize,
    head: format.ObjectHead,
};

pub const WriteFootprint = struct {
    payload_bytes: u64,
    chunk_count: u64,
    reserved: bool,
};

const ReservationAccounting = struct {
    interval_bytes: u64 = 0,
    payload_bytes: u64 = 0,
    existing_bytes: u64 = 0,
    chunk_count: u64 = 0,
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

    pub fn collectLinkCounts(self: Store, counts: *std.AutoHashMap(format.ObjectId, u64)) !void {
        try self.collectNamespaceRefs(namespace_root, counts);
    }

    pub fn recoverOrphans(
        self: Store,
        referenced: *const std.AutoHashMap(format.ObjectId, u64),
        recovered_heads: *std.AutoHashMap(format.ObjectId, format.ObjectHead),
    ) !void {
        while (try self.firstTemporaryRef()) |name| {
            var path_buffer: [max_path_bytes:0]u8 = undefined;
            const path = try formatPath(&path_buffer, "{s}/{s}", .{ temporary_root, name });
            try checkLfs(c.lfs_remove(self.lfs, path));
        }
        var iterator = referenced.keyIterator();
        while (iterator.next()) |id| {
            try recovered_heads.put(id.*, try self.recoverObject(id.*));
        }
        while (try self.firstOrphan(referenced)) |id| try self.removeObject(id);
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

        var object_path_buffer: [max_path_bytes:0]u8 = undefined;
        const object_path = try objectPath(id, &object_path_buffer);
        try checkLfs(c.lfs_mkdir(self.lfs, object_path));
        errdefer self.removeObject(id) catch {};

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
        var translated_buffer: [max_path_bytes:0]u8 = undefined;
        const translated = try translateUserPath(path, &translated_buffer);
        var temporary_buffer: [max_path_bytes:0]u8 = undefined;
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
        var translated_buffer: [max_path_bytes:0]u8 = undefined;
        return self.readRefInternal(try translateUserPath(path, &translated_buffer));
    }

    pub fn readHead(self: Store, id: format.ObjectId) !format.ObjectHead {
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        const path = try headPath(id, &path_buffer);
        var bytes: [format.head_encoded_size]u8 = undefined;
        try readExact(self.lfs, path, &bytes);
        const head = try format.ObjectHead.decode(&bytes);
        if (!std.mem.eql(u8, &head.object_id, &id)) return error.InvalidObjectHead;
        return head;
    }

    pub fn writeHead(self: Store, head: format.ObjectHead) !void {
        var temporary_buffer: [max_path_bytes:0]u8 = undefined;
        var final_buffer: [max_path_bytes:0]u8 = undefined;
        const temporary = try temporaryHeadPath(head.object_id, &temporary_buffer);
        const final = try headPath(head.object_id, &final_buffer);
        const bytes = head.encode();
        errdefer removeIfPresent(self.lfs, temporary) catch {};
        try writeExact(self.lfs, temporary, &bytes);
        try checkLfs(c.lfs_rename(self.lfs, temporary, final));
    }

    pub fn recoverObject(self: Store, id: format.ObjectId) !format.ObjectHead {
        const head = try self.readHead(id);
        var temporary_buffer: [max_path_bytes:0]u8 = undefined;
        try removeIfPresent(self.lfs, try temporaryHeadPath(id, &temporary_buffer));
        try self.removeUnselectedChunkVersions(id, head.data_generation);
        try self.removeUnselectedReservationVersions(id, head.reservation_generation);
        try self.validateReservations(head);
        return head;
    }

    fn prepareObjectTransaction(self: Store, id: format.ObjectId) !format.ObjectHead {
        return self.prepareObjectTransactionWithHead(try self.readHead(id));
    }

    fn prepareObjectTransactionWithHead(self: Store, head: format.ObjectHead) !format.ObjectHead {
        const id = head.object_id;
        var temporary_buffer: [max_path_bytes:0]u8 = undefined;
        try removeIfPresent(self.lfs, try temporaryHeadPath(id, &temporary_buffer));
        try self.removeUncommittedChunkVersions(id, head.data_generation);
        try self.removeUnselectedReservationVersions(id, head.reservation_generation);
        return head;
    }

    pub fn validateReservations(self: Store, head: format.ObjectHead) !void {
        const intervals = try self.readReservationsAlloc(head, std.heap.c_allocator);
        defer std.heap.c_allocator.free(intervals);
        var verified = head;
        try self.setReservationAccounting(&verified, intervals);
        if (verified.reservation_generation != head.reservation_generation or
            verified.reservation_interval_bytes != head.reservation_interval_bytes or
            verified.reservation_payload_bytes != head.reservation_payload_bytes or
            verified.reservation_existing_bytes != head.reservation_existing_bytes or
            verified.reservation_chunk_count != head.reservation_chunk_count or
            verified.reservation_interval_count != head.reservation_interval_count)
            return error.CorruptFilesystem;
    }

    pub fn read(
        self: Store,
        id: format.ObjectId,
        buffer: []u8,
        offset: u64,
    ) !usize {
        const head = try self.readHead(id);
        return self.readWithHead(head, buffer, offset);
    }

    pub fn readWithHead(
        self: Store,
        head: format.ObjectHead,
        buffer: []u8,
        offset: u64,
    ) !usize {
        if (offset >= head.logical_size or buffer.len == 0) return 0;
        return self.readWithHeadLayout(head, try self.chunkLayout(head.object_id), buffer, offset);
    }

    pub fn readWithHeadLayout(
        self: Store,
        head: format.ObjectHead,
        layout: ChunkLayout,
        buffer: []u8,
        offset: u64,
    ) !usize {
        const id = head.object_id;
        if (offset >= head.logical_size or buffer.len == 0) return 0;
        const available = head.logical_size - offset;
        const amount: usize = @intCast(@min(@as(u64, buffer.len), available));

        var consumed: usize = 0;
        while (consumed < amount) {
            const position = offset + consumed;
            const index = position / head.stored_chunk_size;
            const chunk_offset: u32 = @intCast(position % head.stored_chunk_size);
            const part = @min(amount - consumed, head.stored_chunk_size - chunk_offset);
            try self.readChunk(id, index, head.data_generation, layout, buffer[consumed..][0..part], chunk_offset);
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
        return self.writeWithHead(try self.readHead(id), data, offset);
    }

    pub fn writeWithHead(
        self: Store,
        initial_head: format.ObjectHead,
        data: []const u8,
        offset: u64,
    ) !WriteResult {
        const id = initial_head.object_id;
        const end = std.math.add(u64, offset, data.len) catch return error.FileTooLarge;
        if (end > format.max_file_size) return error.FileTooLarge;
        if (data.len == 0) return .{ .amount = 0, .head = initial_head };

        var head = try self.prepareObjectTransactionWithHead(initial_head);
        const reservations = try self.readReservationsAlloc(head, std.heap.c_allocator);
        defer std.heap.c_allocator.free(reservations);
        const generation = std.math.add(u64, head.data_generation, 1) catch return error.CorruptFilesystem;
        const first_touched = offset / head.stored_chunk_size;
        const last_touched = (end - 1) / head.stored_chunk_size;
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
            consumed += part;
        }

        head.logical_size = @max(head.logical_size, end);
        head.generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        head.data_generation = generation;
        try self.setReservationAccounting(&head, reservations);
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head.metadata.mtime_ns = now;
        head.metadata.ctime_ns = now;
        try self.writeHead(head);
        self.pruneChunkVersionRange(id, first_touched, last_touched, generation) catch {};
        return .{ .amount = data.len, .head = head };
    }

    pub fn writeFootprint(self: Store, id: format.ObjectId, offset: u64, length: u64) !WriteFootprint {
        return self.writeFootprintWithHead(try self.readHead(id), offset, length);
    }

    pub fn writeFootprintWithHead(
        self: Store,
        head: format.ObjectHead,
        offset: u64,
        length: u64,
    ) !WriteFootprint {
        const id = head.object_id;
        const end = std.math.add(u64, offset, length) catch return error.FileTooLarge;
        if (end > format.max_file_size) return error.FileTooLarge;
        if (length == 0) return .{ .payload_bytes = 0, .chunk_count = 0, .reserved = false };
        const reservations = try self.readReservationsAlloc(head, std.heap.c_allocator);
        defer std.heap.c_allocator.free(reservations);
        var position = offset;
        var result: WriteFootprint = .{
            .payload_bytes = 0,
            .chunk_count = 0,
            .reserved = rangeCovered(reservations, offset, end),
        };
        while (position < end) {
            const index = position / head.stored_chunk_size;
            const chunk_offset: u32 = @intCast(position % head.stored_chunk_size);
            const part = @min(end - position, head.stored_chunk_size - chunk_offset);
            const old_size = if (try self.findChunkVersion(id, index, head.data_generation)) |version|
                try self.readChunkLength(id, version, head.stored_chunk_size)
            else
                0;
            const new_size = @max(@as(u64, old_size), @as(u64, chunk_offset) + part);
            result.payload_bytes = std.math.add(u64, result.payload_bytes, new_size) catch
                return error.FileTooLarge;
            result.chunk_count += 1;
            position += part;
        }
        return result;
    }

    pub fn reservationProposal(self: Store, id: format.ObjectId, offset: u64, length: u64) !format.ObjectHead {
        if (length == 0) return error.InvalidArgument;
        const end = std.math.add(u64, offset, length) catch return error.FileTooLarge;
        if (end > format.max_file_size) return error.FileTooLarge;
        var head = try self.readHead(id);
        const current = try self.readReservationsAlloc(head, std.heap.c_allocator);
        defer std.heap.c_allocator.free(current);
        const merged = try mergeReservationAlloc(std.heap.c_allocator, current, .{ .start = offset, .end = end });
        defer std.heap.c_allocator.free(merged);
        head.reservation_generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        try self.setReservationAccounting(&head, merged);
        head.logical_size = @max(head.logical_size, end);
        return head;
    }

    pub fn reserve(self: Store, id: format.ObjectId, offset: u64, length: u64) !format.ObjectHead {
        if (length == 0) return error.InvalidArgument;
        const end = std.math.add(u64, offset, length) catch return error.FileTooLarge;
        if (end > format.max_file_size) return error.FileTooLarge;
        var head = try self.prepareObjectTransaction(id);
        const current = try self.readReservationsAlloc(head, std.heap.c_allocator);
        defer std.heap.c_allocator.free(current);
        const merged = try mergeReservationAlloc(std.heap.c_allocator, current, .{ .start = offset, .end = end });
        defer std.heap.c_allocator.free(merged);
        const generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        try self.writeReservationVersion(id, generation, merged);
        errdefer self.removeReservationVersion(id, generation) catch {};
        head.logical_size = @max(head.logical_size, end);
        head.generation = generation;
        head.reservation_generation = generation;
        try self.setReservationAccounting(&head, merged);
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head.metadata.mtime_ns = now;
        head.metadata.ctime_ns = now;
        try self.writeHead(head);
        self.removeUnselectedReservationVersions(id, generation) catch {};
        return head;
    }

    pub fn truncate(self: Store, id: format.ObjectId, size: u64) !format.ObjectHead {
        if (size > format.max_file_size) return error.FileTooLarge;
        var head = try self.prepareObjectTransaction(id);
        const current_reservations = try self.readReservationsAlloc(head, std.heap.c_allocator);
        defer std.heap.c_allocator.free(current_reservations);
        const reservations = try clipReservationsAlloc(std.heap.c_allocator, current_reservations, size);
        defer std.heap.c_allocator.free(reservations);
        const generation = std.math.add(u64, head.data_generation, 1) catch return error.CorruptFilesystem;
        var touched = std.AutoHashMap(u64, void).init(std.heap.c_allocator);
        defer touched.deinit();
        if (size < head.logical_size) {
            try self.truncateChunks(&head, size, generation, &touched);
        }
        head.logical_size = size;
        head.generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        head.data_generation = generation;
        var wrote_reservation = false;
        if (reservations.len == 0) {
            clearReservation(&head);
        } else if (!reservationsEqual(current_reservations, reservations)) {
            try self.writeReservationVersion(id, head.generation, reservations);
            wrote_reservation = true;
            head.reservation_generation = head.generation;
            try self.setReservationAccounting(&head, reservations);
        } else {
            try self.setReservationAccounting(&head, reservations);
        }
        const now: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head.metadata.mtime_ns = now;
        head.metadata.ctime_ns = now;
        errdefer if (wrote_reservation) self.removeReservationVersion(id, head.generation) catch {};
        try self.writeHead(head);
        self.pruneTouchedChunkVersions(id, &touched, generation) catch {};
        self.removeUnselectedReservationVersions(id, head.reservation_generation) catch {};
        return head;
    }

    pub fn updateMetadata(self: Store, id: format.ObjectId, value: metadata.Metadata) !void {
        _ = try self.updateMetadataWithHead(try self.readHead(id), value);
    }

    pub fn updateMetadataWithHead(
        self: Store,
        initial_head: format.ObjectHead,
        value: metadata.Metadata,
    ) !format.ObjectHead {
        var head = initial_head;
        head.metadata = value;
        head.generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        try self.writeHead(head);
        return head;
    }

    pub fn patchMetadata(self: Store, id: format.ObjectId, patch: metadata.Patch) !format.ObjectHead {
        var head = try self.readHead(id);
        if (patch.mode) |mode|
            head.metadata.mode = (head.metadata.mode & 0o170000) | (mode & 0o7777);
        if (patch.uid) |uid| head.metadata.uid = uid;
        if (patch.gid) |gid| head.metadata.gid = gid;
        if (patch.atime_ns) |atime_ns| head.metadata.atime_ns = atime_ns;
        if (patch.mtime_ns) |mtime_ns| head.metadata.mtime_ns = mtime_ns;
        if (patch.update_ctime)
            head.metadata.ctime_ns = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head.generation = std.math.add(u64, head.generation, 1) catch return error.CorruptFilesystem;
        try self.writeHead(head);
        return head;
    }

    pub fn removeObject(self: Store, id: format.ObjectId) !void {
        while (try self.firstChunkName(id)) |name| {
            var path_buffer: [max_path_bytes:0]u8 = undefined;
            try checkLfs(c.lfs_remove(self.lfs, try self.namedChunkPath(id, name, &path_buffer)));
        }
        while (try self.firstReservationName(id)) |name| {
            var reservation_path_buffer: [max_path_bytes:0]u8 = undefined;
            try checkLfs(c.lfs_remove(self.lfs, try namedReservationPath(id, name, &reservation_path_buffer)));
        }

        var path_buffer: [max_path_bytes:0]u8 = undefined;
        try removeIfPresent(self.lfs, try temporaryHeadPath(id, &path_buffer));
        try removeIfPresent(self.lfs, try headPath(id, &path_buffer));
        try removeIfPresent(self.lfs, try chunksPath(id, &path_buffer));
        try removeIfPresent(self.lfs, try objectPath(id, &path_buffer));
    }

    pub fn readReservationsAlloc(
        self: Store,
        head: format.ObjectHead,
        allocator: std.mem.Allocator,
    ) ![]format.ReservationInterval {
        if (head.reservation_generation == 0)
            return allocator.alloc(format.ReservationInterval, 0);
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        const path = try reservationVersionPath(head.object_id, head.reservation_generation, &path_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(self.lfs, path, &info));
        const bytes = try allocator.alloc(u8, info.size);
        defer allocator.free(bytes);
        try readExact(self.lfs, path, bytes);
        const sidecar = try format.ReservationSidecar.decodeAlloc(allocator, bytes);
        errdefer sidecar.deinit(allocator);
        if (sidecar.generation != head.reservation_generation or
            sidecar.intervals.len != head.reservation_interval_count)
            return error.CorruptFilesystem;
        var interval_bytes: u64 = 0;
        for (sidecar.intervals) |interval| {
            interval_bytes = std.math.add(u64, interval_bytes, interval.end - interval.start) catch
                return error.CorruptFilesystem;
        }
        if (interval_bytes != head.reservation_interval_bytes) return error.CorruptFilesystem;
        return sidecar.intervals;
    }

    fn setReservationAccounting(
        self: Store,
        head: *format.ObjectHead,
        intervals: []const format.ReservationInterval,
    ) !void {
        if (intervals.len == 0) {
            clearReservation(head);
            return;
        }
        var accounting = try baseReservationAccounting(intervals, head.stored_chunk_size);
        var indices = std.AutoHashMap(u64, void).init(std.heap.c_allocator);
        defer indices.deinit();
        try self.collectChunkIndices(head.object_id, &indices);
        var iterator = indices.keyIterator();
        while (iterator.next()) |index| {
            const target = reservationTarget(intervals, index.*, head.stored_chunk_size) orelse continue;
            const version = try self.findChunkVersion(head.object_id, index.*, head.data_generation) orelse continue;
            const existing = try self.readChunkLength(head.object_id, version, head.stored_chunk_size);
            accounting.existing_bytes = std.math.add(u64, accounting.existing_bytes, existing) catch
                return error.CorruptFilesystem;
            if (existing > target)
                accounting.payload_bytes = std.math.add(u64, accounting.payload_bytes, existing - target) catch
                    return error.CorruptFilesystem;
        }
        head.reservation_interval_bytes = accounting.interval_bytes;
        head.reservation_payload_bytes = accounting.payload_bytes;
        head.reservation_existing_bytes = accounting.existing_bytes;
        head.reservation_chunk_count = accounting.chunk_count;
        head.reservation_interval_count = @intCast(intervals.len);
    }

    fn writeReservationVersion(
        self: Store,
        id: format.ObjectId,
        generation: u64,
        intervals: []const format.ReservationInterval,
    ) !void {
        const bytes = try format.ReservationSidecar.encodeAlloc(std.heap.c_allocator, generation, intervals);
        defer std.heap.c_allocator.free(bytes);
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        const path = try reservationVersionPath(id, generation, &path_buffer);
        errdefer removeIfPresent(self.lfs, path) catch {};
        try writeExact(self.lfs, path, bytes);
    }

    fn removeUnselectedReservationVersions(
        self: Store,
        id: format.ObjectId,
        selected_generation: u64,
    ) !void {
        var names: std.ArrayList([28]u8) = .empty;
        defer names.deinit(std.heap.c_allocator);
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try objectPath(id, &path_buffer)));
        var open = true;
        defer if (open) {
            _ = c.lfs_dir_close(self.lfs, &directory);
        };
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) break;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            const generation = parseReservationGeneration(name) catch continue;
            if (generation == selected_generation) continue;
            try names.append(std.heap.c_allocator, undefined);
            @memcpy(&names.items[names.items.len - 1], name);
        }
        try checkLfs(c.lfs_dir_close(self.lfs, &directory));
        open = false;
        for (names.items) |name| {
            try checkLfs(c.lfs_remove(self.lfs, try namedReservationPath(id, name, &path_buffer)));
        }
    }

    fn removeReservationVersion(self: Store, id: format.ObjectId, generation: u64) !void {
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        try removeIfPresent(self.lfs, try reservationVersionPath(id, generation, &path_buffer));
    }

    fn firstReservationName(self: Store, id: format.ObjectId) !?[28]u8 {
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try objectPath(id, &path_buffer)));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return null;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            _ = parseReservationGeneration(name) catch continue;
            var copy: [28]u8 = undefined;
            @memcpy(&copy, name);
            return copy;
        }
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
        layout: ChunkLayout,
        buffer: []u8,
        offset: u32,
    ) !void {
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        var version: ChunkVersion = .{ .index = index, .generation = generation, .layout = layout };
        const exact_result = c.lfs_file_open(
            self.lfs,
            &file,
            try chunkVersionPathWithLayout(id, version, &path_buffer),
            c.LFS_O_RDONLY,
        );
        if (exact_result == c.LFS_ERR_ISDIR) return error.CorruptFilesystem;
        if (exact_result == c.LFS_ERR_NOENT) {
            version = try self.findOlderChunkVersionWithLayout(id, index, generation, layout) orelse {
                @memset(buffer, 0);
                return;
            };
            file = std.mem.zeroes(c.lfs_file_t);
            const open_result = c.lfs_file_open(
                self.lfs,
                &file,
                try chunkVersionPathWithLayout(id, version, &path_buffer),
                c.LFS_O_RDONLY,
            );
            if (open_result == c.LFS_ERR_ISDIR) return error.CorruptFilesystem;
            try checkLfs(open_result);
        } else {
            try checkLfs(exact_result);
        }
        defer _ = c.lfs_file_close(self.lfs, &file);
        const header = try readChunkHeader(self.lfs, &file, version, format.chunk_size);
        const length = header.length;
        if (offset == 0 and buffer.len >= length) {
            const amount = c.lfs_file_read(self.lfs, &file, buffer.ptr, length);
            try checkLfs(amount);
            if (amount != length or google_crc32c.value(buffer[0..length]) != header.crc)
                return error.CorruptFilesystem;
            @memset(buffer[length..], 0);
            return;
        }
        const bytes = try std.heap.c_allocator.alloc(u8, length);
        defer std.heap.c_allocator.free(bytes);
        const amount = c.lfs_file_read(self.lfs, &file, bytes.ptr, length);
        try checkLfs(amount);
        if (amount != length or google_crc32c.value(bytes) != header.crc)
            return error.CorruptFilesystem;
        const copied = if (offset < length) @min(buffer.len, length - offset) else 0;
        if (copied != 0) @memcpy(buffer[0..copied], bytes[offset..][0..copied]);
        @memset(buffer[copied..], 0);
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
        const write_end: u32 = @intCast(@as(usize, offset) + data.len);
        const layout = try self.chunkLayout(id);
        const old_version = try self.findChunkVersionWithLayout(id, index, old_generation, layout);
        const chunk = if (old_version) |version| try self.readChunkVersionAlloc(id, version, format.chunk_size, write_end) else value: {
            const bytes = try std.heap.c_allocator.alloc(u8, write_end);
            @memset(bytes[0..offset], 0);
            break :value ChunkData{ .bytes = bytes, .stored_length = 0 };
        };
        defer std.heap.c_allocator.free(chunk.bytes);
        const new_size = @max(chunk.stored_length, write_end);
        @memcpy(chunk.bytes[offset..][0..data.len], data);
        try self.writeChunkVersion(id, .{
            .index = index,
            .generation = new_generation,
            .layout = layout,
        }, chunk.bytes[0..new_size]);
        return .{ .old_size = chunk.stored_length, .new_size = new_size };
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
            const chunk = try self.readChunkVersionAlloc(
                head.object_id,
                version,
                head.stored_chunk_size,
                0,
            );
            defer std.heap.c_allocator.free(chunk.bytes);
            const start = std.math.mul(u64, index.*, head.stored_chunk_size) catch return error.CorruptFilesystem;
            const new_size: u32 = if (start >= size) 0 else @intCast(@min(@as(u64, chunk.stored_length), size - start));
            if (new_size == chunk.stored_length) continue;
            try self.writeChunkVersion(
                head.object_id,
                .{ .index = index.*, .generation = generation, .layout = version.layout },
                chunk.bytes[0..new_size],
            );
            head.allocated_bytes = try adjustAllocated(head.allocated_bytes, .{
                .old_size = chunk.stored_length,
                .new_size = new_size,
            });
            try touched.put(index.*, {});
        }
    }

    fn collectChunkIndices(self: Store, id: format.ObjectId, indices: *std.AutoHashMap(u64, void)) !void {
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try self.chunkDirectoryPath(id, &path_buffer)));
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
        const layout = try self.chunkLayout(id);
        return self.findChunkVersionWithLayout(id, index, generation, layout);
    }

    fn findChunkVersionWithLayout(
        self: Store,
        id: format.ObjectId,
        index: u64,
        generation: u64,
        layout: ChunkLayout,
    ) !?ChunkVersion {
        const exact: ChunkVersion = .{ .index = index, .generation = generation, .layout = layout };
        var exact_path_buffer: [max_path_bytes:0]u8 = undefined;
        var exact_info: c.struct_lfs_info = undefined;
        const exact_result = c.lfs_stat(self.lfs, try chunkVersionPathWithLayout(id, exact, &exact_path_buffer), &exact_info);
        if (exact_result >= 0) {
            if (exact_info.type == c.LFS_TYPE_DIR) return error.CorruptFilesystem;
            return exact;
        }
        if (exact_result != c.LFS_ERR_NOENT) try checkLfs(exact_result);

        return self.findOlderChunkVersionWithLayout(id, index, generation, layout);
    }

    fn findOlderChunkVersionWithLayout(
        self: Store,
        id: format.ObjectId,
        index: u64,
        generation: u64,
        layout: ChunkLayout,
    ) !?ChunkVersion {
        var selected: ?ChunkVersion = null;
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try chunkDirectoryPathWithLayout(id, layout, &path_buffer)));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return selected;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            var version = parseChunkVersion(name) catch continue;
            version.layout = layout;
            if (version.index != index or version.generation > generation) continue;
            if (selected == null or version.generation > selected.?.generation) selected = version;
        }
    }

    fn firstChunkName(self: Store, id: format.ObjectId) !?[33]u8 {
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        const open_result = c.lfs_dir_open(self.lfs, &directory, try self.chunkDirectoryPath(id, &path_buffer));
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

    fn readChunkVersionAlloc(
        self: Store,
        id: format.ObjectId,
        version: ChunkVersion,
        maximum: u32,
        minimum: u32,
    ) !ChunkData {
        if (minimum > maximum) return error.CorruptFilesystem;
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try checkLfs(c.lfs_file_open(self.lfs, &file, try self.chunkVersionPath(id, version, &path_buffer), c.LFS_O_RDONLY));
        defer _ = c.lfs_file_close(self.lfs, &file);
        const header = try readChunkHeader(self.lfs, &file, version, maximum);
        const length = header.length;
        const bytes = try std.heap.c_allocator.alloc(u8, @max(length, minimum));
        errdefer std.heap.c_allocator.free(bytes);
        const amount = c.lfs_file_read(self.lfs, &file, bytes.ptr, length);
        try checkLfs(amount);
        if (amount != length or google_crc32c.value(bytes[0..length]) != header.crc)
            return error.CorruptFilesystem;
        @memset(bytes[length..], 0);
        return .{ .bytes = bytes, .stored_length = length };
    }

    fn readChunkLength(self: Store, id: format.ObjectId, version: ChunkVersion, maximum: u32) !u32 {
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try checkLfs(c.lfs_file_open(self.lfs, &file, try self.chunkVersionPath(id, version, &path_buffer), c.LFS_O_RDONLY));
        defer _ = c.lfs_file_close(self.lfs, &file);
        return (try readChunkHeader(self.lfs, &file, version, maximum)).length;
    }

    fn writeChunkVersion(self: Store, id: format.ObjectId, version: ChunkVersion, data: []const u8) !void {
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        const path = try self.chunkVersionPath(id, version, &path_buffer);
        errdefer removeIfPresent(self.lfs, path) catch {};
        var file: c.lfs_file_t = std.mem.zeroes(c.lfs_file_t);
        try checkLfs(c.lfs_file_open(
            self.lfs,
            &file,
            path,
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
        std.mem.writeInt(u32, header[20..24], google_crc32c.value(data), .little);
        try writeToOpenFile(self.lfs, &file, &header);
        try writeToOpenFile(self.lfs, &file, data);
        const close_result = c.lfs_file_close(self.lfs, &file);
        open = false;
        try checkLfs(close_result);
    }

    fn pruneChunkVersionRange(
        self: Store,
        id: format.ObjectId,
        first_index: u64,
        last_index: u64,
        keep_generation: u64,
    ) !void {
        const versions = try self.collectChunkVersionsAlloc(id, std.heap.c_allocator);
        defer std.heap.c_allocator.free(versions);
        for (versions) |version| {
            if (version.index < first_index or version.index > last_index or version.generation == keep_generation)
                continue;
            var path_buffer: [max_path_bytes:0]u8 = undefined;
            try checkLfs(c.lfs_remove(self.lfs, try chunkVersionPathWithLayout(id, version, &path_buffer)));
        }
    }

    fn pruneTouchedChunkVersions(
        self: Store,
        id: format.ObjectId,
        touched: *const std.AutoHashMap(u64, void),
        keep_generation: u64,
    ) !void {
        const versions = try self.collectChunkVersionsAlloc(id, std.heap.c_allocator);
        defer std.heap.c_allocator.free(versions);
        for (versions) |version| {
            if (!touched.contains(version.index) or version.generation == keep_generation) continue;
            var path_buffer: [max_path_bytes:0]u8 = undefined;
            try checkLfs(c.lfs_remove(self.lfs, try chunkVersionPathWithLayout(id, version, &path_buffer)));
        }
    }

    fn removeUnselectedChunkVersions(self: Store, id: format.ObjectId, committed_generation: u64) !void {
        const versions = try self.collectChunkVersionsAlloc(id, std.heap.c_allocator);
        defer std.heap.c_allocator.free(versions);
        var selected = std.AutoHashMap(u64, u64).init(std.heap.c_allocator);
        defer selected.deinit();
        for (versions) |version| {
            if (version.generation > committed_generation) continue;
            const entry = try selected.getOrPut(version.index);
            if (!entry.found_existing or version.generation > entry.value_ptr.*)
                entry.value_ptr.* = version.generation;
        }
        for (versions) |version| {
            if (selected.get(version.index) == version.generation) continue;
            var path_buffer: [max_path_bytes:0]u8 = undefined;
            try checkLfs(c.lfs_remove(self.lfs, try chunkVersionPathWithLayout(id, version, &path_buffer)));
        }
    }

    fn removeUncommittedChunkVersions(self: Store, id: format.ObjectId, committed_generation: u64) !void {
        const versions = try self.collectChunkVersionsAlloc(id, std.heap.c_allocator);
        defer std.heap.c_allocator.free(versions);
        for (versions) |version| {
            if (version.generation <= committed_generation) continue;
            var path_buffer: [max_path_bytes:0]u8 = undefined;
            try checkLfs(c.lfs_remove(self.lfs, try chunkVersionPathWithLayout(id, version, &path_buffer)));
        }
    }

    fn collectChunkVersionsAlloc(
        self: Store,
        id: format.ObjectId,
        allocator: std.mem.Allocator,
    ) ![]ChunkVersion {
        const layout = try self.chunkLayout(id);
        var versions: std.ArrayList(ChunkVersion) = .empty;
        errdefer versions.deinit(allocator);
        var path_buffer: [max_path_bytes:0]u8 = undefined;
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, try chunkDirectoryPathWithLayout(id, layout, &path_buffer)));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return versions.toOwnedSlice(allocator);
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            var version = parseChunkVersion(name) catch continue;
            version.layout = layout;
            try versions.append(allocator, version);
        }
    }

    fn firstOrphan(self: Store, referenced: *const std.AutoHashMap(format.ObjectId, u64)) !?format.ObjectId {
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

    fn firstTemporaryRef(self: Store) !?[36]u8 {
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(self.lfs, &directory, temporary_root));
        defer _ = c.lfs_dir_close(self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return null;
            if (info.type == c.LFS_TYPE_DIR) continue;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (name.len != 36 or !std.mem.endsWith(u8, name, ".ref")) continue;
            _ = format.parseObjectId(name[0..32]) catch continue;
            var copy: [36]u8 = undefined;
            @memcpy(&copy, name);
            return copy;
        }
    }

    fn collectNamespaceRefs(
        self: Store,
        directory_path: [*:0]const u8,
        counts: *std.AutoHashMap(format.ObjectId, u64),
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
            var child_buffer: [max_path_bytes:0]u8 = undefined;
            const child = try formatPath(&child_buffer, "{s}/{s}", .{ std.mem.span(directory_path), name });
            if (info.type == c.LFS_TYPE_DIR) {
                try self.collectNamespaceRefs(child, counts);
            } else {
                const object_ref = try self.readRefInternal(child);
                const entry = try counts.getOrPut(object_ref.object_id);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* = std.math.add(u64, entry.value_ptr.*, 1) catch
                    return error.CorruptFilesystem;
            }
        }
    }

    pub fn chunkLayout(self: Store, id: format.ObjectId) !ChunkLayout {
        var buffer: [max_path_bytes:0]u8 = undefined;
        const legacy = try chunksPath(id, &buffer);
        var info: c.struct_lfs_info = undefined;
        const result = c.lfs_stat(self.lfs, legacy, &info);
        if (result >= 0) {
            if (info.type != c.LFS_TYPE_DIR) return error.CorruptFilesystem;
            return .legacy;
        }
        if (result != c.LFS_ERR_NOENT) try checkLfs(result);
        return .co_located;
    }

    fn chunkDirectoryPath(self: Store, id: format.ObjectId, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
        return chunkDirectoryPathWithLayout(id, try self.chunkLayout(id), buffer);
    }

    fn chunkVersionPath(
        self: Store,
        id: format.ObjectId,
        version: ChunkVersion,
        buffer: *[max_path_bytes:0]u8,
    ) ![*:0]const u8 {
        _ = self;
        return chunkVersionPathWithLayout(id, version, buffer);
    }

    fn namedChunkPath(
        self: Store,
        id: format.ObjectId,
        name: [33]u8,
        buffer: *[max_path_bytes:0]u8,
    ) ![*:0]const u8 {
        var directory_buffer: [max_path_bytes:0]u8 = undefined;
        const directory = try self.chunkDirectoryPath(id, &directory_buffer);
        return formatPath(buffer, "{s}/{s}", .{ std.mem.span(directory), name });
    }
};

fn chunkDirectoryPathWithLayout(
    id: format.ObjectId,
    layout: ChunkLayout,
    buffer: *[max_path_bytes:0]u8,
) ![*:0]const u8 {
    return switch (layout) {
        .co_located => objectPath(id, buffer),
        .legacy => chunksPath(id, buffer),
    };
}

fn chunkVersionPathWithLayout(
    id: format.ObjectId,
    version: ChunkVersion,
    buffer: *[max_path_bytes:0]u8,
) ![*:0]const u8 {
    var directory_buffer: [max_path_bytes:0]u8 = undefined;
    const directory = try chunkDirectoryPathWithLayout(id, version.layout, &directory_buffer);
    return formatPath(buffer, "{s}/{x:0>16}-{x:0>16}", .{
        std.mem.span(directory),
        version.index,
        version.generation,
    });
}

fn clearReservation(head: *format.ObjectHead) void {
    head.reservation_generation = 0;
    head.reservation_interval_bytes = 0;
    head.reservation_payload_bytes = 0;
    head.reservation_existing_bytes = 0;
    head.reservation_chunk_count = 0;
    head.reservation_interval_count = 0;
}

fn rangeCovered(intervals: []const format.ReservationInterval, start: u64, end: u64) bool {
    if (start == end) return false;
    for (intervals) |interval| {
        if (interval.start > start) return false;
        if (interval.start <= start and interval.end >= end) return true;
    }
    return false;
}

fn reservationsEqual(
    left: []const format.ReservationInterval,
    right: []const format.ReservationInterval,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.start != b.start or a.end != b.end) return false;
    }
    return true;
}

fn mergeReservationAlloc(
    allocator: std.mem.Allocator,
    intervals: []const format.ReservationInterval,
    added: format.ReservationInterval,
) ![]format.ReservationInterval {
    const scratch = try allocator.alloc(format.ReservationInterval, intervals.len + 1);
    defer allocator.free(scratch);
    var count: usize = 0;
    var merged = added;
    var inserted = false;
    for (intervals) |interval| {
        if (interval.end < merged.start) {
            scratch[count] = interval;
            count += 1;
        } else if (merged.end < interval.start) {
            if (!inserted) {
                scratch[count] = merged;
                count += 1;
                inserted = true;
            }
            scratch[count] = interval;
            count += 1;
        } else {
            merged.start = @min(merged.start, interval.start);
            merged.end = @max(merged.end, interval.end);
        }
    }
    if (!inserted) {
        scratch[count] = merged;
        count += 1;
    }
    return allocator.dupe(format.ReservationInterval, scratch[0..count]);
}

fn clipReservationsAlloc(
    allocator: std.mem.Allocator,
    intervals: []const format.ReservationInterval,
    size: u64,
) ![]format.ReservationInterval {
    var count: usize = 0;
    for (intervals) |interval| {
        if (interval.start >= size) break;
        count += 1;
    }
    const clipped = try allocator.alloc(format.ReservationInterval, count);
    for (intervals[0..count], 0..) |interval, index| {
        clipped[index] = .{ .start = interval.start, .end = @min(interval.end, size) };
    }
    return clipped;
}

fn baseReservationAccounting(
    intervals: []const format.ReservationInterval,
    chunk_size: u32,
) !ReservationAccounting {
    var result = ReservationAccounting{};
    var last_index: ?u64 = null;
    var last_target: u64 = 0;
    for (intervals) |interval| {
        result.interval_bytes = std.math.add(u64, result.interval_bytes, interval.end - interval.start) catch
            return error.FileTooLarge;
        const start_index = interval.start / chunk_size;
        const end_index = (interval.end - 1) / chunk_size;
        const final_target = interval.end - end_index * chunk_size;
        var first_index = start_index;
        if (last_index != null and last_index.? == start_index) {
            const replacement = if (end_index == start_index) final_target else chunk_size;
            result.payload_bytes = std.math.add(u64, result.payload_bytes, replacement - last_target) catch
                return error.FileTooLarge;
            last_target = replacement;
            if (end_index == start_index) continue;
            first_index += 1;
        }
        const count = end_index - first_index + 1;
        result.chunk_count = std.math.add(u64, result.chunk_count, count) catch return error.FileTooLarge;
        const full_chunks = count - 1;
        const full_bytes = std.math.mul(u64, full_chunks, chunk_size) catch return error.FileTooLarge;
        result.payload_bytes = std.math.add(u64, result.payload_bytes, full_bytes) catch return error.FileTooLarge;
        result.payload_bytes = std.math.add(u64, result.payload_bytes, final_target) catch return error.FileTooLarge;
        last_index = end_index;
        last_target = final_target;
    }
    return result;
}

fn reservationTarget(
    intervals: []const format.ReservationInterval,
    index: u64,
    chunk_size: u32,
) ?u64 {
    const chunk_start = std.math.mul(u64, index, chunk_size) catch return null;
    const chunk_end = std.math.add(u64, chunk_start, chunk_size) catch std.math.maxInt(u64);
    var target: ?u64 = null;
    for (intervals) |interval| {
        if (interval.end <= chunk_start) continue;
        if (interval.start >= chunk_end) break;
        const current = @min(interval.end, chunk_end) - chunk_start;
        target = @max(target orelse 0, current);
        if (target.? == chunk_size) break;
    }
    return target;
}

fn parseReservationGeneration(name: []const u8) !u64 {
    if (name.len != 28 or !std.mem.eql(u8, name[0..12], "reservation-"))
        return error.InvalidReservationName;
    return std.fmt.parseInt(u64, name[12..28], 16) catch error.InvalidReservationName;
}

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

fn readChunkHeader(
    lfs: *c.lfs_t,
    file: *c.lfs_file_t,
    version: ChunkVersion,
    maximum: u32,
) !ChunkHeader {
    var bytes: [chunk_header_size]u8 = undefined;
    const amount = c.lfs_file_read(lfs, file, &bytes, bytes.len);
    try checkLfs(amount);
    if (amount != bytes.len or !std.mem.eql(u8, bytes[0..8], &chunk_magic) or
        std.mem.readInt(u64, bytes[8..16], .little) != version.generation)
        return error.CorruptFilesystem;
    const length = std.mem.readInt(u32, bytes[16..20], .little);
    if (length > maximum) return error.CorruptFilesystem;
    return .{ .length = length, .crc = std.mem.readInt(u32, bytes[20..24], .little) };
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

fn reservationVersionPath(id: format.ObjectId, generation: u64, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/reservation-{x:0>16}", .{
        objects_root,
        format.formatObjectId(id, &id_buffer),
        generation,
    });
}

fn namedReservationPath(id: format.ObjectId, name: [28]u8, buffer: *[max_path_bytes:0]u8) ![*:0]const u8 {
    var id_buffer: [32]u8 = undefined;
    return formatPath(buffer, "{s}/{s}/{s}", .{
        objects_root,
        format.formatObjectId(id, &id_buffer),
        name,
    });
}

fn formatPath(buffer: *[max_path_bytes:0]u8, comptime pattern: []const u8, args: anytype) ![*:0]const u8 {
    const path = std.fmt.bufPrint(buffer, pattern, args) catch return error.NameTooLong;
    buffer[path.len] = 0;
    return buffer[0..path.len :0].ptr;
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
    var buffer: [max_path_bytes:0]u8 = undefined;
    try std.testing.expectEqualStrings(namespace_root, std.mem.span(try Store.translateUserPath("/", &buffer)));
    try std.testing.expectEqualStrings("/namespace/a/b", std.mem.span(try Store.translateUserPath("/a/b", &buffer)));
    try std.testing.expectError(error.InvalidArgument, Store.translateUserPath("/../system", &buffer));
    try std.testing.expectError(error.InvalidArgument, Store.translateUserPath("/a/../../system", &buffer));
    try std.testing.expectError(error.InvalidArgument, Store.translateUserPath("/a//b", &buffer));
}

test "path formatting terminates reused and maximum-length buffers" {
    var buffer: [max_path_bytes:0]u8 = undefined;
    @memset(&buffer, 0xa5);
    try std.testing.expectEqualStrings("longer", std.mem.span(try formatPath(&buffer, "{s}", .{"longer"})));
    try std.testing.expectEqualStrings("x", std.mem.span(try formatPath(&buffer, "{s}", .{"x"})));

    const maximum: [max_path_bytes]u8 = @splat('x');
    try std.testing.expectEqual(maximum.len, std.mem.span(try formatPath(&buffer, "{s}", .{&maximum})).len);
    const too_long: [max_path_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, formatPath(&buffer, "{s}", .{&too_long}));
}

test "reservation accounting preserves sparse prefixes and chunk payload prefixes" {
    const chunk = format.chunk_size;
    const intervals = [_]format.ReservationInterval{
        .{ .start = 8 * chunk, .end = 8 * chunk + 4096 },
        .{ .start = 9 * chunk + 100, .end = 9 * chunk + 200 },
        .{ .start = 9 * chunk + 300, .end = 9 * chunk + 400 },
    };
    const accounting = try baseReservationAccounting(&intervals, chunk);
    try std.testing.expectEqual(@as(u64, 4096 + 100 + 100), accounting.interval_bytes);
    try std.testing.expectEqual(@as(u64, 4096 + 400), accounting.payload_bytes);
    try std.testing.expectEqual(@as(u64, 2), accounting.chunk_count);
}

test "reservation merging and coverage distinguish holes" {
    const current = [_]format.ReservationInterval{
        .{ .start = 100, .end = 200 },
        .{ .start = 400, .end = 500 },
    };
    const merged = try mergeReservationAlloc(std.testing.allocator, &current, .{ .start = 200, .end = 300 });
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqual(@as(u64, 100), merged[0].start);
    try std.testing.expectEqual(@as(u64, 300), merged[0].end);
    try std.testing.expect(rangeCovered(merged, 120, 280));
    try std.testing.expect(!rangeCovered(merged, 280, 420));
    try std.testing.expect(rangeCovered(merged, 420, 480));
}
