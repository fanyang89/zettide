const std = @import("std");
const uuid = @import("uuid");

pub const Id = [16]u8;
pub const Digest = [32]u8;

pub const Request = struct {
    operation_id: []const u8,
    volume_id: []const u8,
    placement_id: []const u8,
    allocation_id: []const u8,
    generation: u64,
    member_id: []const u8,
    offset_bytes: u64,
    length_bytes: u64,
};

pub const ReplicaState = enum(u8) {
    active = 1,
    tombstoned = 2,
};

pub const Binding = struct {
    volume_id: Id,
    placement_id: Id,
    allocation_id: Id,
    generation: u64,
    member_id: Id,
    offset_bytes: u64,
    length_bytes: u64,
};

pub const Attestation = struct {
    binding: Binding,
    backend_digest: Digest,
};

pub const Replica = struct {
    state: ReplicaState,
    attestation: Attestation,
};

pub const Response = struct {
    operation_id: Id,
    replica: Replica,
};

pub const Backend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ensure: *const fn (*anyopaque, Binding) anyerror!Digest,
        delete: *const fn (*anyopaque, Binding) anyerror!void,
    };

    fn ensure(self: Backend, binding: Binding) !Digest {
        return self.vtable.ensure(self.context, binding);
    }

    fn delete(self: Backend, binding: Binding) !void {
        return self.vtable.delete(self.context, binding);
    }
};

pub const OperationKind = enum(u8) {
    ensure = 1,
    delete = 2,
};

pub const OperationRecord = struct {
    operation_id: Id,
    kind: OperationKind,
    result: Replica,
};

pub const Store = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        find_operation: *const fn (*anyopaque, Id) ?OperationRecord,
        find_replica: *const fn (*anyopaque, Id) ?Replica,
        append: *const fn (*anyopaque, OperationRecord) anyerror!void,
    };

    fn findOperation(self: Store, operation_id: Id) ?OperationRecord {
        return self.vtable.find_operation(self.context, operation_id);
    }

    fn findReplica(self: Store, target_placement_id: Id) ?Replica {
        return self.vtable.find_replica(self.context, target_placement_id);
    }

    fn append(self: Store, record: OperationRecord) !void {
        return self.vtable.append(self.context, record);
    }
};

pub const Service = struct {
    store: Store,
    backend: Backend,

    pub fn init(store: Store, backend: Backend) Service {
        return .{ .store = store, .backend = backend };
    }

    pub fn ensureReplica(self: *Service, request: Request) !Response {
        const parsed = try parseRequest(request);
        if (try self.replay(parsed, .ensure)) |response| return response;

        if (self.store.findReplica(parsed.binding.placement_id)) |current| {
            try validateGeneration(parsed.binding, current.attestation.binding);
            if (parsed.binding.generation == current.attestation.binding.generation) {
                if (!std.meta.eql(parsed.binding, current.attestation.binding)) return error.BindingConflict;
                if (current.state == .tombstoned) return error.GenerationRegression;
                const record: OperationRecord = .{
                    .operation_id = parsed.operation_id,
                    .kind = .ensure,
                    .result = current,
                };
                try self.store.append(record);
                return responseOf(record);
            }
        }

        const digest = try self.backend.ensure(parsed.binding);
        const record: OperationRecord = .{
            .operation_id = parsed.operation_id,
            .kind = .ensure,
            .result = .{ .state = .active, .attestation = .{
                .binding = parsed.binding,
                .backend_digest = digest,
            } },
        };
        try self.store.append(record);
        return responseOf(record);
    }

    pub fn inspectReplica(self: *Service, request: Request) !Response {
        const parsed = try parseRequest(request);
        const replica = self.store.findReplica(parsed.binding.placement_id) orelse return error.ReplicaNotFound;
        try validateGeneration(parsed.binding, replica.attestation.binding);
        if (!std.meta.eql(parsed.binding, replica.attestation.binding)) return error.BindingConflict;
        return .{ .operation_id = parsed.operation_id, .replica = replica };
    }

    pub fn deleteReplica(self: *Service, request: Request) !Response {
        const parsed = try parseRequest(request);
        if (try self.replay(parsed, .delete)) |response| return response;

        const current = self.store.findReplica(parsed.binding.placement_id) orelse return error.ReplicaNotFound;
        try validateGeneration(parsed.binding, current.attestation.binding);
        if (!std.meta.eql(parsed.binding, current.attestation.binding)) return error.BindingConflict;
        if (current.state == .active) try self.backend.delete(parsed.binding);

        const record: OperationRecord = .{
            .operation_id = parsed.operation_id,
            .kind = .delete,
            .result = .{ .state = .tombstoned, .attestation = current.attestation },
        };
        try self.store.append(record);
        return responseOf(record);
    }

    fn replay(self: *Service, parsed: ParsedRequest, kind: OperationKind) !?Response {
        const existing = self.store.findOperation(parsed.operation_id) orelse return null;
        if (existing.kind != kind or !std.meta.eql(existing.result.attestation.binding, parsed.binding))
            return error.OperationConflict;
        return responseOf(existing);
    }
};

const ParsedRequest = struct {
    operation_id: Id,
    binding: Binding,
};

fn parseRequest(request: Request) !ParsedRequest {
    if (request.generation == 0 or request.length_bytes == 0) return error.InvalidGeometry;
    _ = std.math.add(u64, request.offset_bytes, request.length_bytes) catch return error.InvalidGeometry;
    if (request.member_id.len != 16 or isZero(request.member_id)) return error.InvalidMemberId;
    return .{
        .operation_id = try parseUuidV7(request.operation_id),
        .binding = .{
            .volume_id = try parseUuidV7(request.volume_id),
            .placement_id = try parseUuidV7(request.placement_id),
            .allocation_id = try parseUuidV7(request.allocation_id),
            .generation = request.generation,
            .member_id = request.member_id[0..16].*,
            .offset_bytes = request.offset_bytes,
            .length_bytes = request.length_bytes,
        },
    };
}

fn parseUuidV7(value: []const u8) !Id {
    const parsed = uuid.urn.deserialize(value) catch return error.InvalidId;
    const canonical = uuid.urn.serialize(parsed);
    if (canonical[14] != '7' or !std.mem.eql(u8, value, &canonical)) return error.InvalidId;
    var result: Id = undefined;
    std.mem.writeInt(u128, &result, parsed, .little);
    return result;
}

fn validateGeneration(requested: Binding, current: Binding) !void {
    if (requested.generation < current.generation) return error.GenerationRegression;
}

fn responseOf(record: OperationRecord) Response {
    return .{ .operation_id = record.operation_id, .replica = record.result };
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn findOperation(records: []const OperationRecord, operation_id: Id) ?OperationRecord {
    for (records) |record| if (std.mem.eql(u8, &record.operation_id, &operation_id)) return record;
    return null;
}

fn findReplica(records: []const OperationRecord, target_placement_id: Id) ?Replica {
    var index = records.len;
    while (index != 0) {
        index -= 1;
        const replica = records[index].result;
        if (std.mem.eql(u8, &replica.attestation.binding.placement_id, &target_placement_id)) return replica;
    }
    return null;
}

pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    records: []OperationRecord = &.{},

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

    fn findOperationOpaque(context: *anyopaque, operation_id: Id) ?OperationRecord {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return findOperation(self.records, operation_id);
    }

    fn findReplicaOpaque(context: *anyopaque, target_placement_id: Id) ?Replica {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return findReplica(self.records, target_placement_id);
    }

    fn appendOpaque(context: *anyopaque, record: OperationRecord) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        const replacement = try self.allocator.alloc(OperationRecord, self.records.len + 1);
        @memcpy(replacement[0..self.records.len], self.records);
        replacement[self.records.len] = record;
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
    records: []OperationRecord,

    const magic = "ZETDATA1".*;
    const version: u16 = 1;
    const header_size: usize = 24;
    const record_size: usize = 144;
    const max_records: usize = 16 * 1024;
    const max_file_size = header_size + max_records * record_size;

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

    fn findOperationOpaque(context: *anyopaque, operation_id: Id) ?OperationRecord {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return findOperation(self.records, operation_id);
    }

    fn findReplicaOpaque(context: *anyopaque, target_placement_id: Id) ?Replica {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return findReplica(self.records, target_placement_id);
    }

    fn appendOpaque(context: *anyopaque, record: OperationRecord) !void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        if (self.records.len == max_records) return error.StoreFull;
        const replacement = try self.allocator.alloc(OperationRecord, self.records.len + 1);
        errdefer self.allocator.free(replacement);
        @memcpy(replacement[0..self.records.len], self.records);
        replacement[self.records.len] = record;
        try self.persist(replacement);
        if (self.records.len != 0) self.allocator.free(self.records);
        self.records = replacement;
    }

    fn persist(self: *FileStore, records: []const OperationRecord) !void {
        const bytes = try encode(std.heap.page_allocator, records);
        defer std.heap.page_allocator.free(bytes);
        var atomic_file = try self.parent.createFileAtomic(self.io, self.basename, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        try atomic_file.file.writeStreamingAll(self.io, bytes);
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
        const parent_file = try self.parent.openFile(self.io, ".", .{ .mode = .read_only });
        defer parent_file.close(self.io);
        try parent_file.sync(self.io);
    }

    const vtable: Store.VTable = .{
        .find_operation = findOperationOpaque,
        .find_replica = findReplicaOpaque,
        .append = appendOpaque,
    };

    fn encode(allocator: std.mem.Allocator, records: []const OperationRecord) ![]u8 {
        if (records.len > max_records) return error.StoreFull;
        const bytes = try allocator.alloc(u8, header_size + records.len * record_size);
        @memset(bytes, 0);
        @memcpy(bytes[0..8], &magic);
        std.mem.writeInt(u16, bytes[8..10], version, .little);
        std.mem.writeInt(u16, bytes[10..12], record_size, .little);
        std.mem.writeInt(u32, bytes[12..16], @intCast(records.len), .little);
        for (records, 0..) |record, index| encodeRecord(bytes[header_size + index * record_size ..][0..record_size], record);
        std.mem.writeInt(u32, bytes[16..20], std.hash.crc.Crc32Iscsi.hash(bytes[header_size..]), .little);
        return bytes;
    }

    fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]OperationRecord {
        if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..8], &magic)) return error.StoreCorrupt;
        if (std.mem.readInt(u16, bytes[8..10], .little) != version or
            std.mem.readInt(u16, bytes[10..12], .little) != record_size) return error.StoreCorrupt;
        const count = std.mem.readInt(u32, bytes[12..16], .little);
        if (count > max_records or bytes.len != header_size + @as(usize, count) * record_size) return error.StoreCorrupt;
        if (!isZero(bytes[20..24]) or
            std.mem.readInt(u32, bytes[16..20], .little) != std.hash.crc.Crc32Iscsi.hash(bytes[header_size..]))
            return error.StoreCorrupt;
        const records = try allocator.alloc(OperationRecord, count);
        errdefer allocator.free(records);
        for (records, 0..) |*record, index| record.* = try decodeRecord(bytes[header_size + index * record_size ..][0..record_size]);
        return records;
    }

    fn encodeRecord(bytes: *[record_size]u8, record: OperationRecord) void {
        @memset(bytes, 0);
        @memcpy(bytes[0..16], &record.operation_id);
        bytes[16] = @intFromEnum(record.kind);
        bytes[17] = @intFromEnum(record.result.state);
        const binding = record.result.attestation.binding;
        @memcpy(bytes[24..40], &binding.volume_id);
        @memcpy(bytes[40..56], &binding.placement_id);
        @memcpy(bytes[56..72], &binding.allocation_id);
        @memcpy(bytes[72..88], &binding.member_id);
        std.mem.writeInt(u64, bytes[88..96], binding.generation, .little);
        std.mem.writeInt(u64, bytes[96..104], binding.offset_bytes, .little);
        std.mem.writeInt(u64, bytes[104..112], binding.length_bytes, .little);
        @memcpy(bytes[112..144], &record.result.attestation.backend_digest);
    }

    fn decodeRecord(bytes: *const [record_size]u8) !OperationRecord {
        if (!isZero(bytes[18..24])) return error.StoreCorrupt;
        const kind = std.enums.fromInt(OperationKind, bytes[16]) orelse return error.StoreCorrupt;
        const state = std.enums.fromInt(ReplicaState, bytes[17]) orelse return error.StoreCorrupt;
        const binding: Binding = .{
            .volume_id = bytes[24..40].*,
            .placement_id = bytes[40..56].*,
            .allocation_id = bytes[56..72].*,
            .member_id = bytes[72..88].*,
            .generation = std.mem.readInt(u64, bytes[88..96], .little),
            .offset_bytes = std.mem.readInt(u64, bytes[96..104], .little),
            .length_bytes = std.mem.readInt(u64, bytes[104..112], .little),
        };
        _ = std.math.add(u64, binding.offset_bytes, binding.length_bytes) catch return error.StoreCorrupt;
        if (!validUuidV7Bytes(bytes[0..16]) or !validUuidV7Bytes(&binding.volume_id) or
            !validUuidV7Bytes(&binding.placement_id) or !validUuidV7Bytes(&binding.allocation_id) or
            isZero(&binding.member_id) or binding.generation == 0 or binding.length_bytes == 0 or
            (kind == .ensure and state != .active) or (kind == .delete and state != .tombstoned))
            return error.StoreCorrupt;
        return .{
            .operation_id = bytes[0..16].*,
            .kind = kind,
            .result = .{ .state = state, .attestation = .{
                .binding = binding,
                .backend_digest = bytes[112..144].*,
            } },
        };
    }
};

fn validUuidV7Bytes(bytes: []const u8) bool {
    return bytes.len == 16 and bytes[6] & 0xf0 == 0x70 and bytes[8] & 0xc0 == 0x80;
}

const FakeBackend = struct {
    ensures: usize = 0,
    deletes: usize = 0,

    fn backend(self: *FakeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn ensureOpaque(context: *anyopaque, binding: Binding) !Digest {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.ensures += 1;
        var digest: Digest = @splat(0);
        digest[0..16].* = binding.allocation_id;
        std.mem.writeInt(u64, digest[16..24], binding.offset_bytes, .little);
        std.mem.writeInt(u64, digest[24..32], binding.length_bytes, .little);
        return digest;
    }

    fn deleteOpaque(context: *anyopaque, _: Binding) !void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.deletes += 1;
    }

    const vtable: Backend.VTable = .{ .ensure = ensureOpaque, .delete = deleteOpaque };
};

const volume_id = "0198f54d-5c2a-7000-8000-000000000011";
const placement_id = "0198f54d-5c2a-7000-8000-000000000012";
const allocation_id = "0198f54d-5c2a-7000-8000-000000000013";
const ensure_operation_id = "0198f54d-5c2a-7000-8000-000000000014";
const delete_operation_id = "0198f54d-5c2a-7000-8000-000000000015";
const inspect_operation_id = "0198f54d-5c2a-7000-8000-000000000016";
const member_id: Id = .{1} ++ .{0} ** 15;

fn testRequest(operation_id: []const u8, generation: u64) Request {
    return .{
        .operation_id = operation_id,
        .volume_id = volume_id,
        .placement_id = placement_id,
        .allocation_id = allocation_id,
        .generation = generation,
        .member_id = &member_id,
        .offset_bytes = 4096,
        .length_bytes = 8192,
    };
}

test "ensure is durable idempotent and operation conflicts are rejected" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var service = Service.init(store.store(), backend.backend());

    const first = try service.ensureReplica(testRequest(ensure_operation_id, 1));
    const replay = try service.ensureReplica(testRequest(ensure_operation_id, 1));
    try std.testing.expectEqual(first, replay);
    try std.testing.expectEqual(@as(usize, 1), backend.ensures);

    var conflict = testRequest(ensure_operation_id, 1);
    conflict.length_bytes += 1;
    try std.testing.expectError(error.OperationConflict, service.ensureReplica(conflict));
    try std.testing.expectError(error.InvalidGeometry, service.ensureReplica(testRequest(inspect_operation_id, 0)));
}

test "ensure can be inspected and delete tombstone survives response loss" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var service = Service.init(store.store(), backend.backend());

    const ensured = try service.ensureReplica(testRequest(ensure_operation_id, 1));
    const inspected = try service.inspectReplica(testRequest(inspect_operation_id, 1));
    try std.testing.expectEqual(ensured.replica, inspected.replica);
    const deleted = try service.deleteReplica(testRequest(delete_operation_id, 1));
    try std.testing.expectEqual(ReplicaState.tombstoned, deleted.replica.state);

    var restarted = Service.init(store.store(), backend.backend());
    const replay = try restarted.deleteReplica(testRequest(delete_operation_id, 1));
    try std.testing.expectEqual(deleted, replay);
    try std.testing.expectEqual(@as(usize, 1), backend.deletes);
    const tombstone = try restarted.inspectReplica(testRequest(inspect_operation_id, 1));
    try std.testing.expectEqual(ReplicaState.tombstoned, tombstone.replica.state);
}

test "generation regression and malformed identities and geometry are rejected" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var service = Service.init(store.store(), backend.backend());
    _ = try service.ensureReplica(testRequest(ensure_operation_id, 2));
    try std.testing.expectError(error.GenerationRegression, service.inspectReplica(testRequest(inspect_operation_id, 1)));

    var invalid = testRequest(inspect_operation_id, 2);
    invalid.volume_id = "not-a-uuid";
    try std.testing.expectError(error.InvalidId, service.inspectReplica(invalid));
    invalid = testRequest(inspect_operation_id, 2);
    invalid.offset_bytes = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidGeometry, service.inspectReplica(invalid));
}

test "FileStore recovers operations and rejects truncation and corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};

    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backend());
        _ = try service.ensureReplica(testRequest(ensure_operation_id, 1));
        _ = try service.deleteReplica(testRequest(delete_operation_id, 1));
    }
    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backend());
        const replay = try service.deleteReplica(testRequest(delete_operation_id, 1));
        try std.testing.expectEqual(ReplicaState.tombstoned, replay.replica.state);
        try std.testing.expectEqual(@as(usize, 1), backend.deletes);
    }

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "replicas", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    {
        const file = try tmp.dir.createFile(std.testing.io, "replicas", .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, bytes[0 .. bytes.len - 1]);
    }
    try std.testing.expectError(error.StoreCorrupt, FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas"));
    {
        const file = try tmp.dir.createFile(std.testing.io, "replicas", .{ .truncate = true });
        defer file.close(std.testing.io);
        bytes[bytes.len - 1] ^= 1;
        try file.writeStreamingAll(std.testing.io, bytes);
    }
    try std.testing.expectError(error.StoreCorrupt, FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas"));
}
