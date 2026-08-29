const std = @import("std");
const protocol = @import("model.zig");
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
        /// Validate a binding without mutating backend or admission state.
        validate: ?*const fn (*anyopaque, Binding) anyerror!void = null,
        /// Implement this when backend state can be verified before replaying a mutation.
        inspect: ?*const fn (*anyopaque, Binding) anyerror!BackendState = null,
        ensure: *const fn (*anyopaque, Binding) anyerror!Digest,
        delete: *const fn (*anyopaque, Binding) anyerror!void,
    };

    pub fn validate(self: Backend, binding: Binding) !void {
        const validateFn = self.vtable.validate orelse return;
        return validateFn(self.context, binding);
    }

    pub fn inspect(self: Backend, binding: Binding) !?BackendState {
        const inspectFn = self.vtable.inspect orelse return null;
        return try inspectFn(self.context, binding);
    }

    pub fn ensure(self: Backend, binding: Binding) !Digest {
        return self.vtable.ensure(self.context, binding);
    }

    pub fn delete(self: Backend, binding: Binding) !void {
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
        find_replica_record: *const fn (*anyopaque, Id) ?OperationRecord,
        find_allocation_conflict: *const fn (*anyopaque, Binding) ?ReplicaState,
        append: *const fn (*anyopaque, OperationRecord) anyerror!void,
    };

    fn findOperation(self: Store, operation_id: Id) ?OperationRecord {
        return self.vtable.find_operation(self.context, operation_id);
    }

    fn findReplicaRecord(self: Store, target_placement_id: Id) ?OperationRecord {
        return self.vtable.find_replica_record(self.context, target_placement_id);
    }

    fn findAllocationConflict(self: Store, binding: Binding) ?ReplicaState {
        return self.vtable.find_allocation_conflict(self.context, binding);
    }

    fn append(self: Store, record: OperationRecord) !void {
        return self.vtable.append(self.context, record);
    }
};

pub const Service = struct {
    store: Store,
    backend: Backend,
    transaction_lock: std.atomic.Mutex = .unlocked,

    pub fn init(store: Store, backend: Backend) Service {
        return .{ .store = store, .backend = backend };
    }

    fn lockTransaction(self: *Service) void {
        while (!self.transaction_lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn ensureReplica(self: *Service, request: Request) !Response {
        self.lockTransaction();
        defer self.transaction_lock.unlock();
        return self.ensureReplicaLocked(request);
    }

    fn ensureReplicaLocked(self: *Service, request: Request) !Response {
        const parsed = try parseRequest(request);
        if (try self.recoverOperation(parsed, .ensure)) |response| return response;

        if (self.store.findReplicaRecord(parsed.binding.placement_id)) |current_record| {
            if (current_record.status == .prepared) return error.OperationInProgress;
            const current = current_record.result;
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
            if (current.state == .active) return error.PlacementStillActive;
        }
        if (self.store.findAllocationConflict(parsed.binding)) |state| return switch (state) {
            .active => error.AllocationOverlap,
            .tombstoned => error.AllocationQuarantined,
        };
        try self.backend.validate(parsed.binding);

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
        self.lockTransaction();
        defer self.transaction_lock.unlock();
        const parsed = try parseRequest(request);
        const record = self.store.findReplicaRecord(parsed.binding.placement_id) orelse return error.ReplicaNotFound;
        if (record.status == .prepared) return error.OperationInProgress;
        const replica = record.result;
        try validateGeneration(parsed.binding, replica.attestation.binding);
        if (!std.meta.eql(parsed.binding, replica.attestation.binding)) return error.BindingConflict;
        return .{ .operation_id = parsed.operation_id, .replica = replica };
    }

    pub fn deleteReplica(self: *Service, request: Request) !Response {
        self.lockTransaction();
        defer self.transaction_lock.unlock();
        return self.deleteReplicaLocked(request);
    }

    fn deleteReplicaLocked(self: *Service, request: Request) !Response {
        const parsed = try parseRequest(request);
        if (try self.recoverOperation(parsed, .delete)) |response| return response;

        const current_record = self.store.findReplicaRecord(parsed.binding.placement_id) orelse return error.ReplicaNotFound;
        if (current_record.status == .prepared) return error.OperationInProgress;
        const current = current_record.result;
        try validateGeneration(parsed.binding, current.attestation.binding);
        if (!std.meta.eql(parsed.binding, current.attestation.binding)) return error.BindingConflict;
        if (current.state == .tombstoned) {
            const completed: OperationRecord = .{
                .operation_id = parsed.operation_id,
                .kind = .delete,
                .status = .completed,
                .result = current,
            };
            try self.store.append(completed);
            return responseOf(completed);
        }
        try self.backend.validate(parsed.binding);
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
        try self.backend.validate(prepared.result.attestation.binding);
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
        try self.backend.validate(prepared.result.attestation.binding);
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
    if (!validUuidV7Bytes(&result)) return error.InvalidId;
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

fn findReplicaRecord(records: []const OperationRecord, target_placement_id: Id) ?OperationRecord {
    var index = records.len;
    while (index != 0) {
        index -= 1;
        const record = records[index];
        if (std.mem.eql(u8, &record.result.attestation.binding.placement_id, &target_placement_id)) return record;
    }
    return null;
}

fn findAllocationConflict(records: []const OperationRecord, requested: Binding) ?ReplicaState {
    var index = records.len;
    while (index != 0) {
        index -= 1;
        const replica = records[index].result;
        const binding = replica.attestation.binding;
        if (!std.mem.eql(u8, &binding.member_id, &requested.member_id)) continue;
        const binding_end = binding.offset_bytes + binding.length_bytes;
        const requested_end = requested.offset_bytes + requested.length_bytes;
        if (binding.offset_bytes < requested_end and requested.offset_bytes < binding_end)
            return replica.state;
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

    fn findReplicaRecordOpaque(context: *anyopaque, target_placement_id: Id) ?OperationRecord {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return findReplicaRecord(self.records, target_placement_id);
    }

    fn findAllocationConflictOpaque(context: *anyopaque, binding: Binding) ?ReplicaState {
        const self: *MemoryStore = @ptrCast(@alignCast(context));
        return findAllocationConflict(self.records, binding);
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
        .find_replica_record = findReplicaRecordOpaque,
        .find_allocation_conflict = findAllocationConflictOpaque,
        .append = appendOpaque,
    };
};

pub const CapacitySnapshot = struct {
    free_extent_count: u64,
    allocated_extent_count: u64,
    reserved_extent_count: u64,
    retired_extent_count: u64,
};

const CapacityGeometry = struct {
    capacity_bytes: u64,
    extent_size_bytes: u64,
};

fn summarizeCapacity(records: []const OperationRecord, geometry: CapacityGeometry) !CapacitySnapshot {
    var latest_by_allocation: std.AutoHashMapUnmanaged(Id, OperationRecord) = .empty;
    defer latest_by_allocation.deinit(std.heap.page_allocator);
    var reverse_index = records.len;
    while (reverse_index != 0) {
        reverse_index -= 1;
        const record = records[reverse_index];
        const binding = record.result.attestation.binding;
        const entry = try latest_by_allocation.getOrPut(std.heap.page_allocator, binding.allocation_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = record;
        } else if (!std.meta.eql(entry.value_ptr.result.attestation.binding, binding)) {
            return error.AllocationIdentityConflict;
        }
    }

    var result: CapacitySnapshot = .{
        .free_extent_count = 0,
        .allocated_extent_count = 0,
        .reserved_extent_count = 0,
        .retired_extent_count = 0,
    };
    var iterator = latest_by_allocation.valueIterator();
    while (iterator.next()) |record| {
        const binding = record.result.attestation.binding;
        if (binding.offset_bytes % geometry.extent_size_bytes != 0 or
            binding.length_bytes % geometry.extent_size_bytes != 0)
            return error.InvalidMemberGeometry;
        const end = std.math.add(u64, binding.offset_bytes, binding.length_bytes) catch
            return error.InvalidMemberGeometry;
        if (end > geometry.capacity_bytes) return error.InvalidMemberGeometry;
        const extents = binding.length_bytes / geometry.extent_size_bytes;
        const target = if (record.status == .prepared)
            if (record.kind == .ensure)
                &result.reserved_extent_count
            else
                &result.retired_extent_count
        else if (record.result.state == .active)
            &result.allocated_extent_count
        else
            &result.retired_extent_count;
        target.* = std.math.add(u64, target.*, extents) catch return error.InvalidMemberGeometry;
    }
    var used = std.math.add(u64, result.allocated_extent_count, result.reserved_extent_count) catch
        return error.InvalidMemberGeometry;
    used = std.math.add(u64, used, result.retired_extent_count) catch return error.InvalidMemberGeometry;
    const total = geometry.capacity_bytes / geometry.extent_size_bytes;
    if (used > total) return error.InvalidMemberGeometry;
    result.free_extent_count = total - used;
    return result;
}

pub const FileStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    records: []OperationRecord,
    mutex: std.Io.Mutex = .init,
    capacity_geometry: ?CapacityGeometry = null,
    capacity_snapshot: CapacitySnapshot = .{
        .free_extent_count = 0,
        .allocated_extent_count = 0,
        .reserved_extent_count = 0,
        .retired_extent_count = 0,
    },
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
        const bytes = parent.readFileAlloc(io, basename, allocator, .limited(max_file_size + 1)) catch |err| switch (err) {
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

    pub fn validateMember(self: *const FileStore, expected_member_id: Id) !void {
        if (isZero(&expected_member_id)) return error.InvalidMemberId;
        for (self.records) |record| {
            if (!std.mem.eql(u8, &record.result.attestation.binding.member_id, &expected_member_id))
                return error.MemberIdentityMismatch;
        }
    }

    pub fn configureCapacity(
        self: *FileStore,
        expected_member_id: Id,
        capacity_bytes: u64,
        extent_size_bytes: u64,
    ) !void {
        try self.validateMember(expected_member_id);
        if (capacity_bytes == 0 or extent_size_bytes == 0 or capacity_bytes % extent_size_bytes != 0)
            return error.InvalidMemberGeometry;
        const geometry: CapacityGeometry = .{
            .capacity_bytes = capacity_bytes,
            .extent_size_bytes = extent_size_bytes,
        };
        const snapshot = try summarizeCapacity(self.records, geometry);
        self.capacity_geometry = geometry;
        self.capacity_snapshot = snapshot;
    }

    pub fn capacitySnapshot(self: *FileStore) !CapacitySnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.capacity_geometry == null) return error.CapacityNotConfigured;
        return self.capacity_snapshot;
    }

    fn findOperationOpaque(context: *anyopaque, operation_id: Id) ?OperationRecord {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return findOperation(self.records, operation_id);
    }

    fn findReplicaRecordOpaque(context: *anyopaque, target_placement_id: Id) ?OperationRecord {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return findReplicaRecord(self.records, target_placement_id);
    }

    fn findAllocationConflictOpaque(context: *anyopaque, binding: Binding) ?ReplicaState {
        const self: *FileStore = @ptrCast(@alignCast(context));
        return findAllocationConflict(self.records, binding);
    }

    fn appendOpaque(context: *anyopaque, record: OperationRecord) !void {
        const self: *FileStore = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const required_slots: usize = if (record.status == .prepared) 2 else 1;
        if (required_slots > max_records - self.records.len) return error.StoreFull;
        const replacement = try self.allocator.alloc(OperationRecord, self.records.len + 1);
        var installed = false;
        errdefer if (!installed) self.allocator.free(replacement);
        @memcpy(replacement[0..self.records.len], self.records);
        replacement[self.records.len] = record;
        const capacity = if (self.capacity_geometry) |geometry|
            try summarizeCapacity(replacement, geometry)
        else
            null;
        try self.replace(replacement);
        try self.syncParent(replacement.len);
        const previous = self.records;
        self.records = replacement;
        if (capacity) |snapshot| self.capacity_snapshot = snapshot;
        installed = true;
        if (previous.len != 0) self.allocator.free(previous);
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

    fn syncParent(self: *FileStore, candidate_record_count: usize) !void {
        if (self.faults) |faults| {
            if (faults.fail_directory_sync_once_at_record_count == candidate_record_count) {
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
        .find_replica_record = findReplicaRecordOpaque,
        .find_allocation_conflict = findAllocationConflictOpaque,
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
const member_id: Id = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x20 };

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

const ConcurrentResult = struct { err: ?anyerror = null };

fn runConcurrentEnsure(service: *Service, request: Request, result: *ConcurrentResult) void {
    _ = service.ensureReplica(request) catch |err| {
        result.err = err;
        return;
    };
}

test "concurrent overlapping ensure transactions are serialized" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var service = Service.init(store.store(), backend.backend());
    const first = testRequest(ensure_operation_id, 1);
    var second = testRequest("0198f54d-5c2a-7000-8000-000000000017", 1);
    second.placement_id = "0198f54d-5c2a-7000-8000-000000000018";
    second.allocation_id = "0198f54d-5c2a-7000-8000-000000000019";
    second.offset_bytes = 8192;
    second.length_bytes = 4096;
    var first_result: ConcurrentResult = .{};
    var second_result: ConcurrentResult = .{};
    const first_thread = try std.Thread.spawn(.{}, runConcurrentEnsure, .{ &service, first, &first_result });
    const second_thread = try std.Thread.spawn(.{}, runConcurrentEnsure, .{ &service, second, &second_result });
    first_thread.join();
    second_thread.join();
    try std.testing.expect((first_result.err == null) != (second_result.err == null));
    const rejected = first_result.err orelse second_result.err.?;
    try std.testing.expectEqual(error.AllocationOverlap, rejected);
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
    invalid = testRequest("0198f54d-5c2a-7000-0000-000000000016", 2);
    try std.testing.expectError(error.InvalidId, service.inspectReplica(invalid));
    invalid = testRequest(inspect_operation_id, 2);
    invalid.offset_bytes = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidGeometry, service.inspectReplica(invalid));
}

test "overlapping active and tombstoned allocations are rejected" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var service = Service.init(store.store(), backend.backend());
    _ = try service.ensureReplica(testRequest(ensure_operation_id, 1));

    var overlap = testRequest("0198f54d-5c2a-7000-8000-000000000017", 1);
    overlap.placement_id = "0198f54d-5c2a-7000-8000-000000000018";
    overlap.allocation_id = "0198f54d-5c2a-7000-8000-000000000019";
    overlap.offset_bytes = 8192;
    overlap.length_bytes = 4096;
    try std.testing.expectError(error.AllocationOverlap, service.ensureReplica(overlap));

    _ = try service.deleteReplica(testRequest(delete_operation_id, 1));
    overlap.operation_id = "0198f54d-5c2a-7000-8000-00000000001a";
    try std.testing.expectError(error.AllocationQuarantined, service.ensureReplica(overlap));
}

test "higher generations require deletion and cannot reuse quarantined extents" {
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var backend: FakeBackend = .{};
    var service = Service.init(store.store(), backend.backend());
    _ = try service.ensureReplica(testRequest(ensure_operation_id, 1));

    var next = testRequest("0198f54d-5c2a-7000-8000-00000000001b", 2);
    next.allocation_id = "0198f54d-5c2a-7000-8000-00000000001c";
    try std.testing.expectError(error.PlacementStillActive, service.ensureReplica(next));

    _ = try service.deleteReplica(testRequest(delete_operation_id, 1));
    try std.testing.expectError(error.AllocationQuarantined, service.ensureReplica(next));

    next.operation_id = "0198f54d-5c2a-7000-8000-00000000001d";
    next.offset_bytes = 16 * 1024;
    _ = try service.ensureReplica(next);
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
        try std.testing.expectError(
            error.AllocationOverlap,
            service.ensureReplica(testRequest("0198f54d-5c2a-7000-8000-000000000017", 1)),
        );
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
        try std.testing.expectError(
            error.OperationInProgress,
            service.ensureReplica(testRequest("0198f54d-5c2a-7000-8000-00000000001e", 1)),
        );
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

test "FileStore tracks capacity and rejects configured Member identity drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};
    var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
    defer file_store.deinit();
    try file_store.configureCapacity(member_id, 32 * 1024, 4096);
    var capacity = try file_store.capacitySnapshot();
    try std.testing.expectEqual(@as(u64, 8), capacity.free_extent_count);

    var service = Service.init(file_store.store(), backend.backend());
    _ = try service.ensureReplica(testRequest(ensure_operation_id, 1));
    capacity = try file_store.capacitySnapshot();
    try std.testing.expectEqual(@as(u64, 6), capacity.free_extent_count);
    try std.testing.expectEqual(@as(u64, 2), capacity.allocated_extent_count);
    _ = try service.deleteReplica(testRequest(delete_operation_id, 1));
    capacity = try file_store.capacitySnapshot();
    try std.testing.expectEqual(@as(u64, 2), capacity.retired_extent_count);
    try std.testing.expectEqual(@as(u64, 0), capacity.allocated_extent_count);

    var changed = member_id;
    changed[15] ^= 1;
    try std.testing.expectError(error.MemberIdentityMismatch, file_store.validateMember(changed));
}

test "directory sync failure before prepare prevents backend mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend: FakeBackend = .{};
    var faults: FileStore.Faults = .{ .fail_directory_sync_once_at_record_count = 1 };
    var file_store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas");
    defer file_store.deinit();
    file_store.faults = &faults;
    var service = Service.init(file_store.store(), backend.backend());

    try std.testing.expectError(
        error.InjectedDirectorySyncFailure,
        service.ensureReplica(testRequest(ensure_operation_id, 1)),
    );
    try std.testing.expectEqual(@as(usize, 0), file_store.records.len);
    try std.testing.expectEqual(@as(usize, 0), backend.ensure_calls);

    _ = try service.ensureReplica(testRequest(ensure_operation_id, 1));
    try std.testing.expectEqual(@as(usize, 1), backend.ensure_calls);
}

test "FileStore does not publish a record before directory sync succeeds" {
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
        try std.testing.expectEqual(@as(usize, 1), file_store.records.len);
        try std.testing.expectEqual(OperationStatus.prepared, file_store.records[0].status);

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
