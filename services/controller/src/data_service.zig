const std = @import("std");
const protocol = @import("zettide_data_service_contracts");
const uuid = @import("uuid");

pub const Id = protocol.Id;
pub const Digest = protocol.Digest;
pub const Request = protocol.ReplicaRequest;
pub const ReplicaState = protocol.ReplicaState;
pub const Binding = protocol.ReplicaBinding;
pub const Attestation = protocol.ReplicaAttestation;
pub const Replica = protocol.Replica;
pub const Response = protocol.ReplicaResponse;

pub const Backend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// Mutations receive the complete Binding and must be idempotent for it.
    /// The journal provides durable at-least-once invocation, not exactly-once.
    pub const VTable = struct {
        /// Implement this when backend state can be verified before replaying a mutation.
        inspect: ?*const fn (*anyopaque, Binding) anyerror!BackendState = null,
        ensure: *const fn (*anyopaque, Binding) anyerror!Digest,
        delete: *const fn (*anyopaque, Binding) anyerror!void,
    };

    fn inspect(self: Backend, binding: Binding) !?BackendState {
        const inspectFn = self.vtable.inspect orelse return null;
        return try inspectFn(self.context, binding);
    }

    fn ensure(self: Backend, binding: Binding) !Digest {
        return self.vtable.ensure(self.context, binding);
    }

    fn delete(self: Backend, binding: Binding) !void {
        return self.vtable.delete(self.context, binding);
    }
};

pub const BackendState = union(enum) {
    absent,
    active: Digest,
    deleted,
};

pub const OperationKind = enum(u8) {
    ensure = 1,
    delete = 2,
};

pub const OperationStatus = enum(u8) {
    prepared = 1,
    completed = 2,
};

pub const OperationRecord = struct {
    operation_id: Id,
    kind: OperationKind,
    status: OperationStatus,
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
        if (try self.recoverOperation(parsed, .ensure)) |response| return response;

        if (self.store.findReplica(parsed.binding.placement_id)) |current| {
            try validateGeneration(parsed.binding, current.attestation.binding);
            if (parsed.binding.generation == current.attestation.binding.generation) {
                if (!std.meta.eql(parsed.binding, current.attestation.binding)) return error.BindingConflict;
                if (current.state == .tombstoned) return error.GenerationRegression;
                const record: OperationRecord = .{
                    .operation_id = parsed.operation_id,
                    .kind = .ensure,
                    .status = .completed,
                    .result = current,
                };
                try self.store.append(record);
                return responseOf(record);
            }
        }

        const prepared: OperationRecord = .{
            .operation_id = parsed.operation_id,
            .kind = .ensure,
            .status = .prepared,
            .result = .{ .state = .active, .attestation = .{
                .binding = parsed.binding,
                .backend_digest = @splat(0),
            } },
        };
        try self.store.append(prepared);
        return self.completeEnsure(prepared);
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
        if (try self.recoverOperation(parsed, .delete)) |response| return response;

        const current = self.store.findReplica(parsed.binding.placement_id) orelse return error.ReplicaNotFound;
        try validateGeneration(parsed.binding, current.attestation.binding);
        if (!std.meta.eql(parsed.binding, current.attestation.binding)) return error.BindingConflict;
        const prepared: OperationRecord = .{
            .operation_id = parsed.operation_id,
            .kind = .delete,
            .status = .prepared,
            .result = .{ .state = .tombstoned, .attestation = current.attestation },
        };
        try self.store.append(prepared);
        return self.completeDelete(prepared);
    }

    fn recoverOperation(self: *Service, parsed: ParsedRequest, kind: OperationKind) !?Response {
        const existing = self.store.findOperation(parsed.operation_id) orelse return null;
        if (existing.kind != kind or !std.meta.eql(existing.result.attestation.binding, parsed.binding))
            return error.OperationConflict;
        if (existing.status == .completed) return responseOf(existing);
        return switch (kind) {
            .ensure => try self.completeEnsure(existing),
            .delete => try self.completeDelete(existing),
        };
    }

    fn completeEnsure(self: *Service, prepared: OperationRecord) !Response {
        const digest = if (try self.backend.inspect(prepared.result.attestation.binding)) |state| switch (state) {
            .active => |digest| digest,
            .absent, .deleted => try self.backend.ensure(prepared.result.attestation.binding),
        } else try self.backend.ensure(prepared.result.attestation.binding);
        var completed = prepared;
        completed.status = .completed;
        completed.result.attestation.backend_digest = digest;
        try self.store.append(completed);
        return responseOf(completed);
    }

    fn completeDelete(self: *Service, prepared: OperationRecord) !Response {
        if (try self.backend.inspect(prepared.result.attestation.binding)) |state| switch (state) {
            .active => try self.backend.delete(prepared.result.attestation.binding),
            .absent, .deleted => {},
        } else try self.backend.delete(prepared.result.attestation.binding);
        var completed = prepared;
        completed.status = .completed;
        try self.store.append(completed);
        return responseOf(completed);
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
    var index = records.len;
    while (index != 0) {
        index -= 1;
        if (std.mem.eql(u8, &records[index].operation_id, &operation_id)) return records[index];
    }
    return null;
}

fn findReplica(records: []const OperationRecord, target_placement_id: Id) ?Replica {
    var index = records.len;
    while (index != 0) {
        index -= 1;
        if (records[index].status != .completed) continue;
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
    faults: ?*Faults = null,

    const magic = "ZETDATA1".*;
    const legacy_version: u16 = 1;
    const version: u16 = 2;
    const header_size: usize = 24;
    const record_size: usize = 144;
    const max_records: usize = 16 * 1024;
    const max_file_size = header_size + max_records * record_size;

    const Faults = struct {
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
        const required_slots: usize = if (record.status == .prepared) 2 else 1;
        if (required_slots > max_records - self.records.len) return error.StoreFull;
        const replacement = try self.allocator.alloc(OperationRecord, self.records.len + 1);
        var installed = false;
        errdefer if (!installed) self.allocator.free(replacement);
        @memcpy(replacement[0..self.records.len], self.records);
        replacement[self.records.len] = record;
        try self.replace(replacement);
        const previous = self.records;
        self.records = replacement;
        installed = true;
        if (previous.len != 0) self.allocator.free(previous);
        try self.syncParent();
    }

    fn replace(self: *FileStore, records: []const OperationRecord) !void {
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
        const file_version = std.mem.readInt(u16, bytes[8..10], .little);
        if ((file_version != legacy_version and file_version != version) or
            std.mem.readInt(u16, bytes[10..12], .little) != record_size) return error.StoreCorrupt;
        const count = std.mem.readInt(u32, bytes[12..16], .little);
        if (count > max_records or bytes.len != header_size + @as(usize, count) * record_size) return error.StoreCorrupt;
        if (!isZero(bytes[20..24]) or
            std.mem.readInt(u32, bytes[16..20], .little) != std.hash.crc.Crc32Iscsi.hash(bytes[header_size..]))
            return error.StoreCorrupt;
        const records = try allocator.alloc(OperationRecord, count);
        errdefer allocator.free(records);
        for (records, 0..) |*record, index| record.* = try decodeRecord(
            bytes[header_size + index * record_size ..][0..record_size],
            file_version,
        );
        return records;
    }

    fn encodeRecord(bytes: *[record_size]u8, record: OperationRecord) void {
        @memset(bytes, 0);
        @memcpy(bytes[0..16], &record.operation_id);
        bytes[16] = @intFromEnum(record.kind);
        bytes[17] = @intFromEnum(record.result.state);
        bytes[18] = @intFromEnum(record.status);
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

    fn decodeRecord(bytes: *const [record_size]u8, file_version: u16) !OperationRecord {
        if (!isZero(bytes[19..24])) return error.StoreCorrupt;
        const kind = std.enums.fromInt(OperationKind, bytes[16]) orelse return error.StoreCorrupt;
        const state = std.enums.fromInt(ReplicaState, bytes[17]) orelse return error.StoreCorrupt;
        const status = if (file_version == legacy_version) blk: {
            if (bytes[18] != 0) return error.StoreCorrupt;
            break :blk OperationStatus.completed;
        } else std.enums.fromInt(OperationStatus, bytes[18]) orelse return error.StoreCorrupt;
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
            .status = status,
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
    ensure_calls: usize = 0,
    delete_calls: usize = 0,
    binding: ?Binding = null,
    active: bool = false,

    fn backend(self: *FakeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn backendWithoutInspect(self: *FakeBackend) Backend {
        return .{ .context = self, .vtable = &vtable_without_inspect };
    }

    fn ensureOpaque(context: *anyopaque, binding: Binding) !Digest {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.ensure_calls += 1;
        if (self.binding) |existing| {
            if (self.active and !std.meta.eql(existing, binding)) return error.BackendBindingConflict;
            if (self.active) return digestOf(binding);
        }
        self.ensures += 1;
        self.binding = binding;
        self.active = true;
        return digestOf(binding);
    }

    fn deleteOpaque(context: *anyopaque, binding: Binding) !void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.delete_calls += 1;
        const existing = self.binding orelse return;
        if (!std.meta.eql(existing, binding)) return error.BackendBindingConflict;
        if (!self.active) return;
        self.deletes += 1;
        self.active = false;
    }

    fn inspectOpaque(context: *anyopaque, binding: Binding) !BackendState {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        const existing = self.binding orelse return .absent;
        if (!std.meta.eql(existing, binding)) return error.BackendBindingConflict;
        return if (self.active) .{ .active = digestOf(binding) } else .deleted;
    }

    fn digestOf(binding: Binding) Digest {
        var digest: Digest = @splat(0);
        digest[0..16].* = binding.allocation_id;
        std.mem.writeInt(u64, digest[16..24], binding.offset_bytes, .little);
        std.mem.writeInt(u64, digest[24..32], binding.length_bytes, .little);
        return digest;
    }

    const vtable: Backend.VTable = .{
        .inspect = inspectOpaque,
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
    };
    const vtable_without_inspect: Backend.VTable = .{
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
    };
};

const volume_id = "0198f54d-5c2a-7000-8000-000000000011";
const placement_id = "0198f54d-5c2a-7000-8000-000000000012";
const allocation_id = "0198f54d-5c2a-7000-8000-000000000013";
const ensure_operation_id = "0198f54d-5c2a-7000-8000-000000000014";
const delete_operation_id = "0198f54d-5c2a-7000-8000-000000000015";
const inspect_operation_id = "0198f54d-5c2a-7000-8000-000000000016";
const member_id: Id = .{1} ++ @as([15]u8, @splat(0));

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

test "pending operations provide durable at-least-once idempotent recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};

    {
        var faults: FileStore.Faults = .{ .fail_replace_once_at_record_count = 2 };
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
        defer file_store.deinit();
        file_store.faults = &faults;
        var service = Service.init(file_store.store(), backend.backendWithoutInspect());
        try std.testing.expectError(
            error.InjectedReplaceFailure,
            service.ensureReplica(testRequest(ensure_operation_id, 1)),
        );
        try std.testing.expectEqual(@as(usize, 1), backend.ensures);
        try std.testing.expectEqual(OperationStatus.prepared, file_store.records[0].status);

        var conflict = testRequest(ensure_operation_id, 1);
        conflict.length_bytes += 1;
        try std.testing.expectError(error.OperationConflict, service.ensureReplica(conflict));
    }
    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backendWithoutInspect());
        const recovered = try service.ensureReplica(testRequest(ensure_operation_id, 1));
        try std.testing.expectEqual(ReplicaState.active, recovered.replica.state);
        try std.testing.expectEqual(@as(usize, 1), backend.ensures);
        try std.testing.expectEqual(@as(usize, 2), backend.ensure_calls);
    }
    {
        var faults: FileStore.Faults = .{ .fail_replace_once_at_record_count = 4 };
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
        defer file_store.deinit();
        file_store.faults = &faults;
        var service = Service.init(file_store.store(), backend.backendWithoutInspect());
        try std.testing.expectError(
            error.InjectedReplaceFailure,
            service.deleteReplica(testRequest(delete_operation_id, 1)),
        );
        try std.testing.expectEqual(@as(usize, 1), backend.deletes);
    }
    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backendWithoutInspect());
        const recovered = try service.deleteReplica(testRequest(delete_operation_id, 1));
        try std.testing.expectEqual(ReplicaState.tombstoned, recovered.replica.state);
        try std.testing.expectEqual(@as(usize, 1), backend.deletes);
        try std.testing.expectEqual(@as(usize, 2), backend.delete_calls);
    }
}

test "FileStore retains a record published before directory sync failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};

    {
        var faults: FileStore.Faults = .{ .fail_directory_sync_once_at_record_count = 2 };
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
        defer file_store.deinit();
        file_store.faults = &faults;
        var service = Service.init(file_store.store(), backend.backend());
        try std.testing.expectError(
            error.InjectedDirectorySyncFailure,
            service.ensureReplica(testRequest(ensure_operation_id, 1)),
        );
        try std.testing.expectEqual(@as(usize, 2), file_store.records.len);
        try std.testing.expectEqual(OperationStatus.completed, file_store.records[1].status);

        const retry = try service.ensureReplica(testRequest(ensure_operation_id, 1));
        try std.testing.expectEqual(ReplicaState.active, retry.replica.state);
        try std.testing.expectEqual(@as(usize, 1), backend.ensures);
        try std.testing.expectEqual(@as(usize, 1), backend.ensure_calls);
    }
    {
        var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
        defer file_store.deinit();
        var service = Service.init(file_store.store(), backend.backend());
        _ = try service.ensureReplica(testRequest(ensure_operation_id, 1));
        try std.testing.expectEqual(@as(usize, 1), backend.ensures);
        try std.testing.expectEqual(@as(usize, 1), backend.ensure_calls);
    }
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
