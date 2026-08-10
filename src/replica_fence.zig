const std = @import("std");

pub const Id = [16]u8;
pub const Digest = [32]u8;

pub const Binding = struct {
    operation_id: Id,
    volume_id: Id,
    placement_id: Id,
    replica_generation: u64,
    write_epoch: u64,
    primary_node_id: Id,
    lease_id: Id,
    authority_digest: Digest,
};

pub const Result = struct {
    binding: Binding,
    fence_digest: Digest,
};

pub const Backend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Must be idempotent for an identical binding. It blocks new I/O,
        /// drains admitted I/O, and flushes durable media before returning.
        quiesceDrainFlush: *const fn (*anyopaque, Binding) anyerror!Digest,
    };

    fn quiesceDrainFlush(self: Backend, binding: Binding) !Digest {
        return self.vtable.quiesceDrainFlush(self.context, binding);
    }
};

pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        find_operation: *const fn (*anyopaque, Id) ?Result,
        find_replica: *const fn (*anyopaque, Id, Id, u64) ?Result,
        append: *const fn (*anyopaque, Result) anyerror!void,
    };

    fn findOperation(self: Store, operation_id: Id) ?Result {
        return self.vtable.find_operation(self.context, operation_id);
    }

    fn findReplica(self: Store, binding: Binding) ?Result {
        return self.vtable.find_replica(
            self.context,
            binding.volume_id,
            binding.placement_id,
            binding.replica_generation,
        );
    }

    fn append(self: Store, result: Result) !void {
        try self.vtable.append(self.context, result);
    }
};

pub const Service = struct {
    store: Store,
    backend: Backend,

    pub fn init(store: Store, backend: Backend) Service {
        return .{ .store = store, .backend = backend };
    }

    pub fn accept(self: *Service, binding: Binding) !Result {
        try validateBinding(binding);

        if (self.store.findOperation(binding.operation_id)) |existing| {
            if (!sameSemantics(existing.binding, binding)) return error.OperationConflict;
            return existing;
        }

        if (self.store.findReplica(binding)) |current| {
            if (binding.write_epoch < current.binding.write_epoch) return error.EpochRegression;
            if (binding.write_epoch == current.binding.write_epoch) {
                if (!sameSemantics(current.binding, binding)) return error.AuthorityConflict;
                const replay: Result = .{ .binding = binding, .fence_digest = current.fence_digest };
                try self.store.append(replay);
                return replay;
            }
        }

        const fence_digest = try self.backend.quiesceDrainFlush(binding);
        if (isZero(&fence_digest)) return error.InvalidFenceDigest;
        const result: Result = .{
            .binding = binding,
            .fence_digest = fence_digest,
        };
        try self.store.append(result);
        return result;
    }
};

fn validateBinding(binding: Binding) !void {
    if (!validUuidV7(binding.operation_id) or
        !validUuidV7(binding.volume_id) or
        !validUuidV7(binding.placement_id) or
        !validUuidV7(binding.primary_node_id) or
        !validUuidV7(binding.lease_id)) return error.InvalidBinding;
    if (binding.replica_generation == 0 or binding.write_epoch == 0 or isZero(&binding.authority_digest)) return error.InvalidBinding;
}

fn sameSemantics(a: Binding, b: Binding) bool {
    return std.mem.eql(u8, &a.volume_id, &b.volume_id) and
        std.mem.eql(u8, &a.placement_id, &b.placement_id) and
        a.replica_generation == b.replica_generation and
        a.write_epoch == b.write_epoch and
        std.mem.eql(u8, &a.primary_node_id, &b.primary_node_id) and
        std.mem.eql(u8, &a.lease_id, &b.lease_id) and
        std.mem.eql(u8, &a.authority_digest, &b.authority_digest);
}

fn validUuidV7(id: Id) bool {
    return id[6] & 0xf0 == 0x70 and id[8] & 0xc0 == 0x80;
}

fn findOperation(records: []const Result, operation_id: Id) ?Result {
    var index = records.len;
    while (index != 0) {
        index -= 1;
        if (std.mem.eql(u8, &records[index].binding.operation_id, &operation_id)) return records[index];
    }
    return null;
}

fn findReplica(
    records: []const Result,
    volume_id: Id,
    placement_id: Id,
    replica_generation: u64,
) ?Result {
    var index = records.len;
    while (index != 0) {
        index -= 1;
        const binding = records[index].binding;
        if (std.mem.eql(u8, &binding.volume_id, &volume_id) and
            std.mem.eql(u8, &binding.placement_id, &placement_id) and
            binding.replica_generation == replica_generation) return records[index];
    }
    return null;
}

pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    records: []Result = &.{},

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryStore) void {
        if (self.records.len != 0) self.allocator.free(self.records);
        self.* = undefined;
    }

    pub fn store(self: *MemoryStore) Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn findOperationOpaque(context: *anyopaque, operation_id: Id) ?Result {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return findOperation(self.records, operation_id);
    }

    fn findReplicaOpaque(context: *anyopaque, volume_id: Id, placement_id: Id, generation: u64) ?Result {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return findReplica(self.records, volume_id, placement_id, generation);
    }

    fn appendOpaque(context: *anyopaque, result: Result) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        const replacement = try self.allocator.alloc(Result, self.records.len + 1);
        @memcpy(replacement[0..self.records.len], self.records);
        replacement[self.records.len] = result;
        if (self.records.len != 0) self.allocator.free(self.records);
        self.records = replacement;
    }

    const vtable: Store.VTable = .{
        .find_operation = findOperationOpaque,
        .find_replica = findReplicaOpaque,
        .append = appendOpaque,
    };
};

pub const FileStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    records: []Result,
    faults: ?*Faults = null,

    const magic = "ZETFENCE".*;
    const version: u16 = 1;
    const header_size: usize = 24;
    const record_size: usize = 168;
    const max_records: usize = 16 * 1024;
    const max_file_size = header_size + max_records * record_size;

    pub const Faults = struct {
        fail_replace_once_at_record_count: ?usize = null,
        fail_directory_sync_once_at_record_count: ?usize = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        basename: []const u8,
    ) !FileStore {
        const bytes = parent.readFileAlloc(io, basename, allocator, .limited(max_file_size)) catch |err| switch (err) {
            error.FileNotFound => return .{
                .allocator = allocator,
                .io = io,
                .parent = parent,
                .basename = basename,
                .records = &.{},
            },
            else => return err,
        };
        defer allocator.free(bytes);
        return .{
            .allocator = allocator,
            .io = io,
            .parent = parent,
            .basename = basename,
            .records = try decode(allocator, bytes),
        };
    }

    pub fn deinit(self: *FileStore) void {
        if (self.records.len != 0) self.allocator.free(self.records);
        self.* = undefined;
    }

    pub fn store(self: *FileStore) Store {
        return .{ .context = self, .vtable = &vtable };
    }

    fn findOperationOpaque(context: *anyopaque, operation_id: Id) ?Result {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return findOperation(self.records, operation_id);
    }

    fn findReplicaOpaque(context: *anyopaque, volume_id: Id, placement_id: Id, generation: u64) ?Result {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return findReplica(self.records, volume_id, placement_id, generation);
    }

    fn appendOpaque(context: *anyopaque, result: Result) !void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        if (self.records.len == max_records) return error.StoreFull;
        const replacement = try self.allocator.alloc(Result, self.records.len + 1);
        var installed = false;
        errdefer if (!installed) self.allocator.free(replacement);
        @memcpy(replacement[0..self.records.len], self.records);
        replacement[self.records.len] = result;
        try self.replace(replacement);
        const previous = self.records;
        self.records = replacement;
        installed = true;
        if (previous.len != 0) self.allocator.free(previous);
        try self.syncParent();
    }

    fn replace(self: *FileStore, records: []const Result) !void {
        if (self.faults) |faults| {
            if (faults.fail_replace_once_at_record_count == records.len) {
                faults.fail_replace_once_at_record_count = null;
                return error.InjectedReplaceFailure;
            }
        }
        const bytes = try encode(std.heap.page_allocator, records);
        defer std.heap.page_allocator.free(bytes);
        var atomic_file = try self.parent.createFileAtomic(self.io, self.basename, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        try atomic_file.file.writeStreamingAll(self.io, bytes);
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
    }

    fn syncParent(self: *FileStore) !void {
        if (self.faults) |faults| {
            if (faults.fail_directory_sync_once_at_record_count == self.records.len) {
                faults.fail_directory_sync_once_at_record_count = null;
                return error.InjectedDirectorySyncFailure;
            }
        }
        const parent_file = try self.parent.openFile(self.io, ".", .{ .mode = .read_only });
        defer parent_file.close(self.io);
        try parent_file.sync(self.io);
    }

    const vtable: Store.VTable = .{
        .find_operation = findOperationOpaque,
        .find_replica = findReplicaOpaque,
        .append = appendOpaque,
    };

    fn encode(allocator: std.mem.Allocator, records: []const Result) ![]u8 {
        if (records.len > max_records) return error.StoreFull;
        const bytes = try allocator.alloc(u8, header_size + records.len * record_size);
        @memset(bytes, 0);
        @memcpy(bytes[0..8], &magic);
        std.mem.writeInt(u16, bytes[8..10], version, .little);
        std.mem.writeInt(u16, bytes[10..12], record_size, .little);
        std.mem.writeInt(u32, bytes[12..16], @intCast(records.len), .little);
        for (records, 0..) |record, index| encodeRecord(bytes[header_size + index * record_size ..][0..record_size], record);
        std.mem.writeInt(u32, bytes[16..20], std.hash.crc.@"CRC-32/ISCSI".hash(bytes[header_size..]), .little);
        return bytes;
    }

    fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Result {
        if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..8], &magic)) return error.StoreCorrupt;
        if (std.mem.readInt(u16, bytes[8..10], .little) != version or
            std.mem.readInt(u16, bytes[10..12], .little) != record_size) return error.StoreCorrupt;
        const count = std.mem.readInt(u32, bytes[12..16], .little);
        if (count > max_records or bytes.len != header_size + @as(usize, count) * record_size) return error.StoreCorrupt;
        if (!isZero(bytes[20..24]) or
            std.mem.readInt(u32, bytes[16..20], .little) != std.hash.crc.@"CRC-32/ISCSI".hash(bytes[header_size..]))
            return error.StoreCorrupt;
        const records = try allocator.alloc(Result, count);
        errdefer allocator.free(records);
        for (records, 0..) |*record, index| {
            record.* = try decodeRecord(bytes[header_size + index * record_size ..][0..record_size]);
            if (findOperation(records[0..index], record.binding.operation_id)) |existing| {
                if (!sameSemantics(existing.binding, record.binding) or !std.mem.eql(u8, &existing.fence_digest, &record.fence_digest)) return error.StoreCorrupt;
            }
            if (findReplica(records[0..index], record.binding.volume_id, record.binding.placement_id, record.binding.replica_generation)) |current| {
                if (record.binding.write_epoch < current.binding.write_epoch or
                    (record.binding.write_epoch == current.binding.write_epoch and
                        (!sameSemantics(record.binding, current.binding) or !std.mem.eql(u8, &record.fence_digest, &current.fence_digest)))) return error.StoreCorrupt;
            }
        }
        return records;
    }

    fn encodeRecord(bytes: *[record_size]u8, result: Result) void {
        @memset(bytes, 0);
        const binding = result.binding;
        @memcpy(bytes[0..16], &binding.operation_id);
        @memcpy(bytes[16..32], &binding.volume_id);
        @memcpy(bytes[32..48], &binding.placement_id);
        @memcpy(bytes[48..64], &binding.primary_node_id);
        @memcpy(bytes[64..80], &binding.lease_id);
        std.mem.writeInt(u64, bytes[80..88], binding.replica_generation, .little);
        std.mem.writeInt(u64, bytes[88..96], binding.write_epoch, .little);
        @memcpy(bytes[96..128], &binding.authority_digest);
        @memcpy(bytes[128..160], &result.fence_digest);
    }

    fn decodeRecord(bytes: *const [record_size]u8) !Result {
        if (!isZero(bytes[160..168])) return error.StoreCorrupt;
        const result: Result = .{
            .binding = .{
                .operation_id = bytes[0..16].*,
                .volume_id = bytes[16..32].*,
                .placement_id = bytes[32..48].*,
                .primary_node_id = bytes[48..64].*,
                .lease_id = bytes[64..80].*,
                .replica_generation = std.mem.readInt(u64, bytes[80..88], .little),
                .write_epoch = std.mem.readInt(u64, bytes[88..96], .little),
                .authority_digest = bytes[96..128].*,
            },
            .fence_digest = bytes[128..160].*,
        };
        validateBinding(result.binding) catch return error.StoreCorrupt;
        if (isZero(&result.fence_digest)) return error.StoreCorrupt;
        return result;
    }
};

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const FakeBackend = struct {
    calls: usize = 0,
    fail_once: bool = false,

    fn backend(self: *FakeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn quiesceDrainFlushOpaque(context: *anyopaque, binding: Binding) !Digest {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.fail_once) {
            self.fail_once = false;
            return error.InjectedBackendFailure;
        }
        var digest: Digest = binding.authority_digest;
        std.mem.writeInt(u64, digest[0..8], binding.write_epoch, .little);
        return digest;
    }

    const vtable: Backend.VTable = .{ .quiesceDrainFlush = quiesceDrainFlushOpaque };
};

fn testId(byte: u8) Id {
    var id: Id = @splat(byte);
    id[6] = 0x70 | (byte & 0x0f);
    id[8] = 0x80 | (byte & 0x3f);
    return id;
}

fn testBinding(operation: u8, epoch: u64) Binding {
    return .{
        .operation_id = testId(operation),
        .volume_id = testId(1),
        .placement_id = testId(2),
        .replica_generation = 3,
        .write_epoch = epoch,
        .primary_node_id = testId(4),
        .lease_id = testId(5),
        .authority_digest = @splat(@as(u8, @truncate(epoch))),
    };
}

test "epochs advance only after backend drain and reject rollback and conflicts" {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var backend: FakeBackend = .{};
    var service = Service.init(memory.store(), backend.backend());

    _ = try service.accept(testBinding(10, 7));
    try std.testing.expectError(error.EpochRegression, service.accept(testBinding(11, 6)));
    var conflict = testBinding(12, 7);
    conflict.lease_id = testId(6);
    try std.testing.expectError(error.AuthorityConflict, service.accept(conflict));
    _ = try service.accept(testBinding(13, 8));
    try std.testing.expectEqual(@as(usize, 2), backend.calls);
}

test "same authority is idempotent and operation ids bind semantics" {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var backend: FakeBackend = .{};
    var service = Service.init(memory.store(), backend.backend());

    const first = try service.accept(testBinding(10, 7));
    const replay = try service.accept(testBinding(10, 7));
    try std.testing.expectEqual(first, replay);
    const alias = try service.accept(testBinding(11, 7));
    try std.testing.expectEqual(first.fence_digest, alias.fence_digest);
    try std.testing.expectEqual(@as(usize, 1), backend.calls);

    var reused = testBinding(10, 8);
    reused.primary_node_id = testId(9);
    try std.testing.expectError(error.OperationConflict, service.accept(reused));
}

test "backend and persistence faults do not publish a higher epoch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};

    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backend());
        backend.fail_once = true;
        try std.testing.expectError(error.InjectedBackendFailure, service.accept(testBinding(10, 7)));
        try std.testing.expectEqual(@as(usize, 0), file_store.records.len);

        var faults: FileStore.Faults = .{ .fail_replace_once_at_record_count = 1 };
        file_store.faults = &faults;
        try std.testing.expectError(error.InjectedReplaceFailure, service.accept(testBinding(10, 7)));
        try std.testing.expectEqual(@as(usize, 0), file_store.records.len);
    }
    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backend());
        _ = try service.accept(testBinding(10, 7));
        try std.testing.expectEqual(@as(usize, 3), backend.calls);
    }
}

test "unknown response is replayed after restart without another drain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};

    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences");
        defer file_store.deinit();
        var faults: FileStore.Faults = .{ .fail_directory_sync_once_at_record_count = 1 };
        file_store.faults = &faults;
        var service = Service.init(file_store.store(), backend.backend());
        try std.testing.expectError(error.InjectedDirectorySyncFailure, service.accept(testBinding(10, 7)));
        try std.testing.expectEqual(@as(usize, 1), file_store.records.len);
    }
    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backend());
        _ = try service.accept(testBinding(10, 7));
        try std.testing.expectEqual(@as(usize, 1), backend.calls);
        try std.testing.expectError(error.EpochRegression, service.accept(testBinding(11, 6)));
    }
}

test "FileStore rejects truncation corruption and nonzero reserved bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};
    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backend());
        _ = try service.accept(testBinding(10, 7));
    }

    const original = try tmp.dir.readFileAlloc(std.testing.io, "fences", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(original);
    {
        const file = try tmp.dir.createFile(std.testing.io, "fences", .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, original[0 .. original.len - 1]);
    }
    try std.testing.expectError(error.StoreCorrupt, FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences"));
    {
        original[original.len - 1] = 1;
        std.mem.writeInt(u32, original[16..20], std.hash.crc.@"CRC-32/ISCSI".hash(original[FileStore.header_size..]), .little);
        const file = try tmp.dir.createFile(std.testing.io, "fences", .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, original);
    }
    try std.testing.expectError(error.StoreCorrupt, FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences"));
}
