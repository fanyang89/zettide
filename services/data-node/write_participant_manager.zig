const std = @import("std");

const protocol = @import("zettide_data_service_contracts");
const replica_io_gate = @import("replica_io_gate.zig");
const write_service = protocol.write_service;

const state_prefix = "write-";
const state_suffix = ".state";
const state_name_len = state_prefix.len + 32 + 1 + 16 + state_suffix.len;
const catalog_basename = "write-catalog.state";
const catalog_marker_basename = "write-catalog.required";
const catalog_magic = "ZETWCAT2".*;
const catalog_marker_magic = "ZETWREQ1".*;
const catalog_version: u16 = 2;
const catalog_header_size: usize = 24;
const catalog_record_size: usize = 144;
const catalog_checksum_size: usize = 4;
const max_participants: usize = 16 * 1024;
const max_catalog_size = catalog_header_size + max_participants * catalog_record_size + catalog_checksum_size;

/// Owns one immutable, file-backed write participant per local Replica
/// generation. Existing participants are discovered and any durable COMMIT is
/// replayed before init returns, so the server cannot publish a higher fence
/// before decided local work has drained.
pub const WriteParticipantManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    replicas: *protocol.replica_service.FileStore,
    replica_control: *protocol.replica_service.Service,
    fences: *protocol.fence_service.FileStore,
    backend: write_service.Backend,
    authority_validator: replica_io_gate.AuthorityValidator,
    mutex: std.Io.Mutex = .init,
    entries: std.AutoHashMapUnmanaged(Key, *Entry) = .empty,
    catalog: []CatalogRecord = &.{},
    poisoned: bool = false,

    const Key = struct {
        placement_id: protocol.Id,
        generation: u64,
    };

    const CatalogRecord = struct {
        binding: write_service.ParticipantBinding,
        retired: bool = false,
    };

    const Entry = struct {
        name: []u8,
        binding: write_service.ParticipantBinding,
        retired: bool,
        store: *write_service.FileStore,
        gate: replica_io_gate.ReplicaIoGate,
        participant: *write_service.Participant,
    };

    pub const ControlGuard = struct {
        manager: *WriteParticipantManager,
        entry: ?*Entry,

        pub fn retire(self: *ControlGuard) !void {
            const entry = self.entry orelse return;
            self.manager.retireLocked(entry) catch |err| {
                self.manager.poisoned = true;
                return err;
            };
        }

        pub fn end(self: *ControlGuard) void {
            if (self.entry) |entry| entry.gate.end();
            self.manager.mutex.unlock(self.manager.io);
            self.* = undefined;
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        replicas: *protocol.replica_service.FileStore,
        replica_control: *protocol.replica_service.Service,
        fences: *protocol.fence_service.FileStore,
        backend: write_service.Backend,
        authority_validator: replica_io_gate.AuthorityValidator,
    ) !WriteParticipantManager {
        var self: WriteParticipantManager = .{
            .allocator = allocator,
            .io = io,
            .parent = parent,
            .replicas = replicas,
            .replica_control = replica_control,
            .fences = fences,
            .backend = backend,
            .authority_validator = authority_validator,
        };
        errdefer self.deinit();
        self.catalog = try self.initializeAndReadCatalog();
        try self.recoverCatalogReplicaOperations();
        try self.loadExisting();
        return self;
    }

    pub fn deinit(self: *WriteParticipantManager) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry_ptr| self.destroyEntry(entry_ptr.*);
        self.entries.deinit(self.allocator);
        if (self.catalog.len != 0) self.allocator.free(self.catalog);
        self.* = undefined;
    }

    /// Durably provisions the immutable participant identity before any write
    /// transport is allowed to use it. Identical retries are idempotent.
    pub fn configure(
        self: *WriteParticipantManager,
        binding: write_service.ParticipantBinding,
        backend_digest: protocol.Digest,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        const attestation = try self.replicas.validateActive(binding.replica);
        if (!std.mem.eql(u8, &attestation.backend_digest, &backend_digest))
            return error.MemberBackendIdentityMismatch;
        _ = try self.openLocked(binding);
    }

    pub fn prepare(
        self: *WriteParticipantManager,
        binding: write_service.ParticipantBinding,
        request: write_service.PrepareRequest,
    ) !write_service.PrepareAttestation {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        const entry = try self.configuredLocked(binding);
        _ = try self.replicas.validateActive(binding.replica);
        return entry.participant.prepare(request);
    }

    pub fn commit(
        self: *WriteParticipantManager,
        binding: write_service.ParticipantBinding,
        transaction_id: protocol.Id,
        commit_certificate: write_service.CommitCertificate,
    ) !write_service.CommitResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        const entry = try self.configuredLocked(binding);
        _ = try self.replicas.validateActive(binding.replica);
        return entry.participant.commit(transaction_id, commit_certificate);
    }

    pub fn inspect(
        self: *WriteParticipantManager,
        binding: write_service.ParticipantBinding,
    ) !write_service.Inspection {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        const entry = try self.configuredLocked(binding);
        return entry.participant.inspect();
    }

    pub fn hasWriteHistory(self: *WriteParticipantManager, volume_id: protocol.Id) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (!std.mem.eql(u8, &entry.binding.replica.volume_id, &volume_id)) continue;
            const inspection = try entry.participant.inspect();
            if (inspection.frontier.sequence != 0 or inspection.pending != null) return true;
        }
        return false;
    }

    /// Serializes a complete Replica mutation or fence against participant
    /// creation and I/O. Durable COMMIT is drained before the guard is returned;
    /// an undecided PREPARE or poisoned participant blocks the control action.
    pub fn beginControl(
        self: *WriteParticipantManager,
        placement_id: protocol.Id,
        generation: u64,
        allow_retired: bool,
    ) !ControlGuard {
        self.mutex.lockUncancelable(self.io);
        errdefer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        const entry = self.entries.get(key(placement_id, generation));
        if (entry) |value| {
            if (value.retired) {
                if (!allow_retired) return error.ReplicaRetired;
                return .{ .manager = self, .entry = null };
            }
            var inspection = try value.participant.inspect();
            if (inspection.pending != null and inspection.pending.?.commit_decided) {
                _ = try value.participant.recover();
                inspection = try value.participant.inspect();
            }
            if (inspection.pending != null) return error.WriteInProgress;
            value.gate.beginExclusive();
        }
        return .{ .manager = self, .entry = entry };
    }

    fn configuredLocked(self: *WriteParticipantManager, binding: write_service.ParticipantBinding) !*Entry {
        const entry = self.entries.get(keyOf(binding.replica)) orelse return error.ParticipantNotConfigured;
        if (!std.meta.eql(entry.binding, binding)) return error.ReplicaStateMismatch;
        if (entry.retired) return error.ReplicaRetired;
        return entry;
    }

    fn openLocked(self: *WriteParticipantManager, binding: write_service.ParticipantBinding) !*Entry {
        try write_service.validateParticipantBinding(binding);
        if (self.entries.get(keyOf(binding.replica))) |existing| {
            if (!std.meta.eql(existing.binding, binding)) return error.ReplicaStateMismatch;
            if (existing.retired) return error.ReplicaRetired;
            return existing;
        }
        _ = try self.replicas.validateActive(binding.replica);
        for (self.catalog) |record| {
            if (!std.meta.eql(keyOf(record.binding.replica), keyOf(binding.replica))) continue;
            if (!std.meta.eql(record.binding, binding)) return error.ReplicaStateMismatch;
            if (record.retired) return error.ReplicaRetired;
            try self.loadExistingEntry(record);
            return self.entries.get(keyOf(binding.replica)) orelse return error.StoreCorrupt;
        }

        // Install discoverability before creating/binding the participant file.
        // A crash can therefore leave a cataloged unbound file, which startup
        // safely finishes, but can never leave hidden write history.
        const record: CatalogRecord = .{ .binding = binding };
        try self.appendCatalog(record);
        try self.loadExistingEntry(record);
        return self.entries.get(keyOf(binding.replica)) orelse return error.StoreCorrupt;
    }

    fn recoverCatalogReplicaOperations(self: *WriteParticipantManager) !void {
        for (self.catalog) |record| {
            if (record.retired) continue;
            _ = try self.replica_control.recoverReplica(record.binding.replica);
        }
    }

    fn loadExisting(self: *WriteParticipantManager) !void {
        var reconciled = false;
        for (self.catalog) |*record| {
            if (record.retired) {
                _ = try self.replicas.validateRetired(record.binding.replica);
            } else {
                const current = try self.replicas.validateCurrent(record.binding.replica);
                if (current.state == .tombstoned) {
                    record.retired = true;
                    reconciled = true;
                }
            }
            try self.loadExistingEntry(record.*);
        }
        if (reconciled) {
            const replacement = try self.allocator.dupe(CatalogRecord, self.catalog);
            try self.installCatalog(replacement);
        }
    }

    fn loadExistingEntry(self: *WriteParticipantManager, record: CatalogRecord) !void {
        const binding = record.binding;
        const name = try stateName(self.allocator, binding.replica);
        var name_owned = true;
        errdefer if (name_owned) self.allocator.free(name);
        const store = try write_service.FileStore.init(self.allocator, self.io, self.parent, name);
        var store_owned = true;
        errdefer if (store_owned) store.deinit();
        const durable_binding = try store.binding();
        if (durable_binding) |existing| {
            if (!std.meta.eql(binding, existing)) return error.ReplicaStateMismatch;
        } else if (record.retired) return error.UnboundParticipantState;
        const entry = try self.createEntry(name, binding, record.retired, store);
        name_owned = false;
        store_owned = false;
        errdefer {
            _ = self.entries.remove(keyOf(binding.replica));
            self.destroyEntry(entry);
        }
        var inspection = try entry.participant.inspect();
        if (record.retired and inspection.pending != null) return error.StoreCorrupt;
        if (!record.retired and inspection.pending != null and inspection.pending.?.commit_decided) {
            _ = try entry.participant.recover();
            inspection = try entry.participant.inspect();
        }
        if (!record.retired and inspection.pending != null and inspection.pending.?.commit_decided)
            return error.StoreCorrupt;
    }

    fn initializeAndReadCatalog(self: *WriteParticipantManager) ![]CatalogRecord {
        const marker_exists = self.catalogMarkerExists() catch |err| return err;
        const bytes = self.parent.readFileAlloc(
            self.io,
            catalog_basename,
            self.allocator,
            .limited(max_catalog_size + 1),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                if (marker_exists) return error.CatalogMissing;
                try self.validateCatalogCoverage(&.{});
                const empty = try encodeCatalog(self.allocator, &.{});
                defer self.allocator.free(empty);
                try self.replaceCatalogBytes(empty);
                try self.writeCatalogMarker();
                return &.{};
            },
            error.StreamTooLong => return error.StoreCorrupt,
            else => return err,
        };
        defer self.allocator.free(bytes);
        const catalog = try decodeCatalog(self.allocator, bytes);
        errdefer if (catalog.len != 0) self.allocator.free(catalog);
        try self.validateCatalogRecords(catalog);
        try self.validateCatalogCoverage(catalog);
        if (!marker_exists) try self.writeCatalogMarker();
        return catalog;
    }

    fn validateCatalogRecords(self: *WriteParticipantManager, catalog: []const CatalogRecord) !void {
        var seen: std.AutoHashMapUnmanaged(Key, void) = .empty;
        defer seen.deinit(self.allocator);
        try seen.ensureTotalCapacity(self.allocator, @intCast(catalog.len));
        for (catalog) |record| {
            write_service.validateParticipantBinding(record.binding) catch return error.StoreCorrupt;
            const result = seen.getOrPutAssumeCapacity(keyOf(record.binding.replica));
            if (result.found_existing) return error.StoreCorrupt;
        }
    }

    fn validateCatalogCoverage(self: *WriteParticipantManager, catalog: []const CatalogRecord) !void {
        const directory = try self.parent.openDir(self.io, ".", .{ .iterate = true });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            const discovered = try parseStateKey(entry.name) orelse continue;
            var found = false;
            for (catalog) |record| {
                if (!std.meta.eql(discovered, keyOf(record.binding.replica))) continue;
                found = true;
                break;
            }
            if (!found) return error.OrphanParticipantState;
        }
    }

    fn catalogMarkerExists(self: *WriteParticipantManager) !bool {
        const bytes = self.parent.readFileAlloc(
            self.io,
            catalog_marker_basename,
            self.allocator,
            .limited(catalog_marker_magic.len + 1),
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, &catalog_marker_magic)) return error.StoreCorrupt;
        return true;
    }

    fn writeCatalogMarker(self: *WriteParticipantManager) !void {
        var atomic_file = try self.parent.createFileAtomic(self.io, catalog_marker_basename, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        try atomic_file.file.writeStreamingAll(self.io, &catalog_marker_magic);
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
        try self.syncParent();
    }

    fn appendCatalog(self: *WriteParticipantManager, record: CatalogRecord) !void {
        if (self.poisoned) return error.StorePoisoned;
        if (self.catalog.len == max_participants) return error.StoreFull;
        for (self.catalog) |existing|
            if (std.meta.eql(keyOf(existing.binding.replica), keyOf(record.binding.replica)))
                return error.DuplicateParticipantState;
        const replacement = try self.allocator.alloc(CatalogRecord, self.catalog.len + 1);
        @memcpy(replacement[0..self.catalog.len], self.catalog);
        replacement[self.catalog.len] = record;
        try self.installCatalog(replacement);
    }

    fn retireLocked(self: *WriteParticipantManager, entry: *Entry) !void {
        if (entry.retired) return;
        const replacement = try self.allocator.dupe(CatalogRecord, self.catalog);
        var found = false;
        for (replacement) |*record| {
            if (!std.meta.eql(keyOf(record.binding.replica), keyOf(entry.binding.replica))) continue;
            if (!std.meta.eql(record.binding, entry.binding)) return error.ReplicaStateMismatch;
            record.retired = true;
            found = true;
            break;
        }
        if (!found) {
            self.allocator.free(replacement);
            return error.StoreCorrupt;
        }
        try self.installCatalog(replacement);
        entry.retired = true;
    }

    fn installCatalog(self: *WriteParticipantManager, replacement: []CatalogRecord) !void {
        var installed = false;
        errdefer if (!installed) self.allocator.free(replacement);
        const bytes = try encodeCatalog(self.allocator, replacement);
        defer self.allocator.free(bytes);
        try self.replaceCatalogBytes(bytes);
        const previous = self.catalog;
        self.catalog = replacement;
        installed = true;
        if (previous.len != 0) self.allocator.free(previous);
    }

    fn replaceCatalogBytes(self: *WriteParticipantManager, bytes: []const u8) !void {
        var atomic_file = try self.parent.createFileAtomic(self.io, catalog_basename, .{ .replace = true });
        defer atomic_file.deinit(self.io);
        try atomic_file.file.writeStreamingAll(self.io, bytes);
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
        self.syncParent() catch |err| {
            self.poisoned = true;
            return err;
        };
    }

    fn syncParent(self: *WriteParticipantManager) !void {
        const parent_file = try self.parent.openFile(self.io, ".", .{ .mode = .read_only });
        defer parent_file.close(self.io);
        try parent_file.sync(self.io);
    }

    fn createEntry(
        self: *WriteParticipantManager,
        name: []u8,
        binding: write_service.ParticipantBinding,
        retired: bool,
        store: *write_service.FileStore,
    ) !*Entry {
        if (self.entries.contains(keyOf(binding.replica))) return error.DuplicateParticipantState;
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .name = name,
            .binding = binding,
            .retired = retired,
            .store = store,
            .gate = replica_io_gate.ReplicaIoGate.init(
                self.io,
                binding.replica,
                self.replicas,
                self.fences,
                self.authority_validator,
            ),
            .participant = undefined,
        };
        entry.participant = try write_service.Participant.initFile(
            self.allocator,
            binding.replica,
            binding.replica_members,
            store,
            self.backend,
            entry.gate.admission(),
        );
        errdefer entry.participant.deinit();
        try self.entries.put(self.allocator, keyOf(binding.replica), entry);
        return entry;
    }

    fn destroyEntry(self: *WriteParticipantManager, entry: *Entry) void {
        entry.participant.deinit();
        entry.store.deinit();
        self.allocator.free(entry.name);
        self.allocator.destroy(entry);
    }
};

fn key(placement_id: protocol.Id, generation: u64) WriteParticipantManager.Key {
    return .{ .placement_id = placement_id, .generation = generation };
}

fn keyOf(replica: protocol.ReplicaBinding) WriteParticipantManager.Key {
    return key(replica.placement_id, replica.generation);
}

fn encodeCatalog(
    allocator: std.mem.Allocator,
    records: []const WriteParticipantManager.CatalogRecord,
) ![]u8 {
    if (records.len > max_participants) return error.StoreFull;
    const size = catalog_header_size + records.len * catalog_record_size + catalog_checksum_size;
    const bytes = try allocator.alloc(u8, size);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], &catalog_magic);
    std.mem.writeInt(u16, bytes[8..10], catalog_version, .little);
    std.mem.writeInt(u16, bytes[10..12], catalog_record_size, .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(records.len), .little);
    var offset: usize = catalog_header_size;
    for (records) |record| {
        bytes[offset] = @intFromBool(record.retired);
        offset += 8;
        const binding = record.binding;
        catalogPutBytes(bytes, &offset, &binding.replica.volume_id);
        catalogPutBytes(bytes, &offset, &binding.replica.placement_id);
        catalogPutBytes(bytes, &offset, &binding.replica.allocation_id);
        catalogPutU64(bytes, &offset, binding.replica.generation);
        catalogPutBytes(bytes, &offset, &binding.replica.member_id);
        catalogPutU64(bytes, &offset, binding.replica.offset_bytes);
        catalogPutU64(bytes, &offset, binding.replica.length_bytes);
        for (binding.replica_members) |member| catalogPutBytes(bytes, &offset, &member);
    }
    std.mem.writeInt(
        u32,
        bytes[bytes.len - catalog_checksum_size ..][0..catalog_checksum_size],
        std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - catalog_checksum_size]),
        .little,
    );
    return bytes;
}

fn decodeCatalog(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]WriteParticipantManager.CatalogRecord {
    if (bytes.len < catalog_header_size + catalog_checksum_size or
        !std.mem.eql(u8, bytes[0..8], &catalog_magic) or
        std.mem.readInt(u16, bytes[8..10], .little) != catalog_version or
        std.mem.readInt(u16, bytes[10..12], .little) != catalog_record_size or
        !isZero(bytes[16..catalog_header_size]))
        return error.StoreCorrupt;
    const count = std.mem.readInt(u32, bytes[12..16], .little);
    if (count > max_participants or
        bytes.len != catalog_header_size + @as(usize, count) * catalog_record_size + catalog_checksum_size or
        std.mem.readInt(u32, bytes[bytes.len - catalog_checksum_size ..][0..catalog_checksum_size], .little) !=
            std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - catalog_checksum_size]))
        return error.StoreCorrupt;
    if (count == 0) return &.{};
    const result = try allocator.alloc(WriteParticipantManager.CatalogRecord, count);
    errdefer allocator.free(result);
    var offset: usize = catalog_header_size;
    for (result) |*record| {
        const retired = bytes[offset];
        if (retired > 1 or !isZero(bytes[offset + 1 .. offset + 8])) return error.StoreCorrupt;
        offset += 8;
        record.* = .{ .binding = .{
            .replica = .{
                .volume_id = catalogGetArray(16, bytes, &offset),
                .placement_id = catalogGetArray(16, bytes, &offset),
                .allocation_id = catalogGetArray(16, bytes, &offset),
                .generation = catalogGetU64(bytes, &offset),
                .member_id = catalogGetArray(16, bytes, &offset),
                .offset_bytes = catalogGetU64(bytes, &offset),
                .length_bytes = catalogGetU64(bytes, &offset),
            },
            .replica_members = .{
                catalogGetArray(16, bytes, &offset),
                catalogGetArray(16, bytes, &offset),
                catalogGetArray(16, bytes, &offset),
            },
        }, .retired = retired == 1 };
    }
    return result;
}

fn catalogPutBytes(bytes: []u8, offset: *usize, value: []const u8) void {
    @memcpy(bytes[offset.*..][0..value.len], value);
    offset.* += value.len;
}

fn catalogPutU64(bytes: []u8, offset: *usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset.*..][0..8], value, .little);
    offset.* += 8;
}

fn catalogGetArray(comptime size: usize, bytes: []const u8, offset: *usize) [size]u8 {
    const value = bytes[offset.*..][0..size].*;
    offset.* += size;
    return value;
}

fn catalogGetU64(bytes: []const u8, offset: *usize) u64 {
    const value = std.mem.readInt(u64, bytes[offset.*..][0..8], .little);
    offset.* += 8;
    return value;
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn stateName(allocator: std.mem.Allocator, replica: protocol.ReplicaBinding) ![]u8 {
    const name = try allocator.alloc(u8, state_name_len);
    var offset: usize = 0;
    @memcpy(name[offset..][0..state_prefix.len], state_prefix);
    offset += state_prefix.len;
    putHex(name[offset..][0..32], &replica.placement_id);
    offset += 32;
    name[offset] = '-';
    offset += 1;
    var generation: [8]u8 = undefined;
    std.mem.writeInt(u64, &generation, replica.generation, .little);
    putHex(name[offset..][0..16], &generation);
    offset += 16;
    @memcpy(name[offset..][0..state_suffix.len], state_suffix);
    return name;
}

fn parseStateKey(name: []const u8) !?WriteParticipantManager.Key {
    if (std.mem.eql(u8, name, catalog_basename) or std.mem.eql(u8, name, catalog_marker_basename)) return null;
    if (!std.mem.startsWith(u8, name, state_prefix)) return null;
    if (std.mem.endsWith(u8, name, state_suffix ++ ".lock")) {
        if (name.len != state_name_len + ".lock".len) return error.StoreCorrupt;
        _ = try parseStateKey(name[0..state_name_len]) orelse return error.StoreCorrupt;
        return null;
    }
    if (!std.mem.endsWith(u8, name, state_suffix) or name.len != state_name_len)
        return error.StoreCorrupt;
    var offset: usize = state_prefix.len;
    const placement_id = try parseHex(16, name[offset..][0..32]);
    offset += 32;
    if (name[offset] != '-') return error.StoreCorrupt;
    offset += 1;
    const generation_bytes = try parseHex(8, name[offset..][0..16]);
    const generation = std.mem.readInt(u64, &generation_bytes, .little);
    if (generation == 0) return error.StoreCorrupt;
    return key(placement_id, generation);
}

fn parseHex(comptime size: usize, encoded: []const u8) ![size]u8 {
    if (encoded.len != size * 2) return error.StoreCorrupt;
    var result: [size]u8 = undefined;
    for (&result, 0..) |*byte, index| {
        const high = std.fmt.charToDigit(encoded[index * 2], 16) catch return error.StoreCorrupt;
        const low = std.fmt.charToDigit(encoded[index * 2 + 1], 16) catch return error.StoreCorrupt;
        byte.* = @as(u8, @intCast(high << 4 | low));
    }
    return result;
}

fn putHex(output: []u8, input: []const u8) void {
    const alphabet = "0123456789abcdef";
    std.debug.assert(output.len == input.len * 2);
    for (input, 0..) |byte, index| {
        output[index * 2] = alphabet[byte >> 4];
        output[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

const FakeBackend = struct {
    bytes: [16 * 1024]u8 = @splat(0),
    fail_once: bool = false,

    fn backend(self: *FakeBackend) write_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn applyOpaque(context: *anyopaque, replica: protocol.ReplicaBinding, offset: u64, data: []const u8) !void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        if (self.fail_once) {
            self.fail_once = false;
            return error.InjectedApplyFailure;
        }
        const start = std.math.cast(usize, replica.offset_bytes + offset) orelse return error.WriteOutOfBounds;
        @memcpy(self.bytes[start..][0..data.len], data);
    }

    const vtable: write_service.Backend.VTable = .{ .apply = applyOpaque };
};

const FakeReplicaBackend = struct {
    digest: protocol.Digest = @splat(0x33),
    fail_delete_once: bool = false,
    deletes: usize = 0,

    fn backend(self: *FakeReplicaBackend) protocol.replica_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn ensureOpaque(context: *anyopaque, _: protocol.ReplicaBinding) !protocol.Digest {
        return (@as(*FakeReplicaBackend, @ptrCast(@alignCast(context)))).digest;
    }

    fn deleteOpaque(context: *anyopaque, _: protocol.ReplicaBinding) !void {
        const self: *FakeReplicaBackend = @ptrCast(@alignCast(context));
        self.deletes += 1;
        if (self.fail_delete_once) {
            self.fail_delete_once = false;
            return error.InjectedDeleteFailure;
        }
    }

    const vtable: protocol.replica_service.Backend.VTable = .{
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
    };
};

const FakeFenceBackend = struct {
    fn backend(self: *FakeFenceBackend) protocol.fence_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn quiesceDrainFlushOpaque(_: *anyopaque, binding: protocol.FenceBinding) !protocol.Digest {
        var result: protocol.Digest = @splat(0x44);
        result[0] = @truncate(binding.write_epoch);
        return result;
    }

    const vtable: protocol.fence_service.Backend.VTable = .{ .quiesceDrainFlush = quiesceDrainFlushOpaque };
};

const FakeAuthorityValidator = struct {
    expected: protocol.AuthorityBinding,
    active: bool = true,

    fn validator(self: *FakeAuthorityValidator) replica_io_gate.AuthorityValidator {
        return .{ .context = self, .validate_fn = validateOpaque };
    }

    fn validateOpaque(context: *anyopaque, authority: protocol.AuthorityBinding) !void {
        const self: *FakeAuthorityValidator = @ptrCast(@alignCast(context));
        if (!self.active or !std.meta.eql(self.expected, authority)) return error.AuthorityRejected;
    }
};

fn testId(byte: u8) protocol.Id {
    var id: protocol.Id = @splat(byte);
    id[6] = 0x70 | (byte & 0x0f);
    id[8] = 0x80 | (byte & 0x3f);
    return id;
}

const test_member_id = testId(4);

fn testAuthority(volume_id: protocol.Id) protocol.AuthorityBinding {
    return .{
        .volume_id = volume_id,
        .primary_placement_id = testId(6),
        .primary_node_id = testId(7),
        .lease_id = testId(8),
        .holder_boot_id = testId(9),
        .authority_generation = 10,
        .write_epoch = 11,
        .placement_revision = 12,
        .activation_nonce = testId(13),
        .authority_digest = @splat(0x55),
    };
}

fn replicaRequest(operation_id: []const u8) protocol.ReplicaRequest {
    return .{
        .operation_id = operation_id,
        .volume_id = "0198f54d-5c2a-7000-8000-000000000001",
        .placement_id = "0198f54d-5c2a-7000-8000-000000000002",
        .allocation_id = "0198f54d-5c2a-7000-8000-000000000003",
        .generation = 1,
        .member_id = &test_member_id,
        .offset_bytes = 4096,
        .length_bytes = 8192,
    };
}

fn canonicalMembers(local: protocol.Id) [3]protocol.Id {
    var result = [3]protocol.Id{ local, testId(14), testId(15) };
    std.mem.sort(protocol.Id, &result, {}, struct {
        fn lessThan(_: void, left: protocol.Id, right: protocol.Id) bool {
            return std.mem.order(u8, &left, &right) == .lt;
        }
    }.lessThan);
    return result;
}

fn fenceBinding(replica: protocol.ReplicaBinding, authority: protocol.AuthorityBinding) protocol.FenceBinding {
    return .{
        .operation_id = testId(16),
        .volume_id = replica.volume_id,
        .placement_id = replica.placement_id,
        .replica_generation = replica.generation,
        .write_epoch = authority.write_epoch,
        .primary_node_id = authority.primary_node_id,
        .lease_id = authority.lease_id,
        .authority_digest = authority.authority_digest,
    };
}

fn prepareRequest(
    binding: write_service.ParticipantBinding,
    authority: protocol.AuthorityBinding,
    data: []const u8,
) write_service.PrepareRequest {
    return .{
        .write = .{
            .authority = authority,
            .replica_members = binding.replica_members,
            .sequence = 1,
            .transaction_id = testId(17),
            .previous_history_digest = @splat(0),
            .offset_bytes = 0,
            .length_bytes = data.len,
            .data_digest = write_service.digestData(data),
        },
        .data = data,
    };
}

fn certificate(local: write_service.PrepareAttestation, binding: write_service.ParticipantBinding) write_service.CommitCertificate {
    var remote = local;
    for (binding.replica_members) |member| if (!std.mem.eql(u8, &member, &local.member_id)) {
        remote.member_id = member;
        break;
    };
    remote.prepare_digest[0] ^= 1;
    return if (std.mem.order(u8, &local.member_id, &remote.member_id) == .lt)
        .{ .attestations = .{ local, remote } }
    else
        .{ .attestations = .{ remote, local } };
}

test "manager durably configures an immutable participant before writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var replicas = try protocol.replica_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer replicas.deinit();
    var replica_backend: FakeReplicaBackend = .{};
    var replica_engine = protocol.replica_service.Service.init(replicas.store(), replica_backend.backend());
    const ensured = try replica_engine.ensureReplica(replicaRequest("0198f54d-5c2a-7000-8000-000000000004"));
    const binding: write_service.ParticipantBinding = .{
        .replica = ensured.replica.attestation.binding,
        .replica_members = canonicalMembers(ensured.replica.attestation.binding.member_id),
    };
    var fences = try protocol.fence_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences.state");
    defer fences.deinit();
    var backend: FakeBackend = .{};
    var validator: FakeAuthorityValidator = .{ .expected = testAuthority(binding.replica.volume_id) };
    {
        var manager = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer manager.deinit();
        var invalid_binding = binding;
        invalid_binding.replica_members = .{ @splat(0), binding.replica.member_id, testId(14) };
        try std.testing.expectError(
            error.InvalidReplicaSet,
            manager.configure(invalid_binding, ensured.replica.attestation.backend_digest),
        );
        try std.testing.expectEqual(@as(usize, 0), manager.catalog.len);
        try manager.configure(binding, ensured.replica.attestation.backend_digest);
        try manager.configure(binding, ensured.replica.attestation.backend_digest);
        const inspection = try manager.inspect(binding);
        try std.testing.expectEqual(@as(u64, 0), inspection.frontier.sequence);
        try std.testing.expect(inspection.pending == null);
        var changed_digest = ensured.replica.attestation.backend_digest;
        changed_digest[0] ^= 1;
        try std.testing.expectError(error.MemberBackendIdentityMismatch, manager.configure(binding, changed_digest));
    }
    {
        var reopened = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer reopened.deinit();
        try reopened.configure(binding, ensured.replica.attestation.backend_digest);
        try std.testing.expectEqual(@as(u64, 0), (try reopened.inspect(binding)).frontier.sequence);
    }
}

test "manager completes a cataloged unbound participant on startup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var replicas = try protocol.replica_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer replicas.deinit();
    var replica_backend: FakeReplicaBackend = .{};
    var replica_engine = protocol.replica_service.Service.init(replicas.store(), replica_backend.backend());
    const ensured = try replica_engine.ensureReplica(replicaRequest("0198f54d-5c2a-7000-8000-000000000004"));
    const binding: write_service.ParticipantBinding = .{
        .replica = ensured.replica.attestation.binding,
        .replica_members = canonicalMembers(ensured.replica.attestation.binding.member_id),
    };
    var fences = try protocol.fence_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences.state");
    defer fences.deinit();
    var backend: FakeBackend = .{};
    var validator: FakeAuthorityValidator = .{ .expected = testAuthority(binding.replica.volume_id) };
    {
        var manager = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer manager.deinit();
        try manager.appendCatalog(.{ .binding = binding });
    }
    {
        var reopened = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer reopened.deinit();
        try std.testing.expectEqual(@as(u64, 0), (try reopened.inspect(binding)).frontier.sequence);
    }
}

test "startup rejects a malformed catalog before Replica recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var replicas = try protocol.replica_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer replicas.deinit();
    var replica_backend: FakeReplicaBackend = .{};
    var replica_engine = protocol.replica_service.Service.init(replicas.store(), replica_backend.backend());
    const ensured = try replica_engine.ensureReplica(replicaRequest("0198f54d-5c2a-7000-8000-000000000004"));
    const binding: write_service.ParticipantBinding = .{
        .replica = ensured.replica.attestation.binding,
        .replica_members = canonicalMembers(ensured.replica.attestation.binding.member_id),
    };
    var invalid_binding = binding;
    invalid_binding.replica_members = .{ @splat(0), binding.replica.member_id, testId(14) };
    var fences = try protocol.fence_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences.state");
    defer fences.deinit();
    var backend: FakeBackend = .{};
    var validator: FakeAuthorityValidator = .{ .expected = testAuthority(binding.replica.volume_id) };
    {
        var manager = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer manager.deinit();
        try manager.appendCatalog(.{ .binding = invalid_binding });
    }
    replica_backend.fail_delete_once = true;
    try std.testing.expectError(
        error.InjectedDeleteFailure,
        replica_engine.deleteReplica(replicaRequest("0198f54d-5c2a-7000-8000-000000000005")),
    );
    try std.testing.expectEqual(@as(usize, 1), replica_backend.deletes);
    try std.testing.expectError(
        error.StoreCorrupt,
        WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), replica_backend.deletes);
}

test "manager discovers and replays a durable COMMIT before returning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var replicas = try protocol.replica_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer replicas.deinit();
    var replica_backend: FakeReplicaBackend = .{};
    var replica_engine = protocol.replica_service.Service.init(replicas.store(), replica_backend.backend());
    const ensured = try replica_engine.ensureReplica(
        replicaRequest("0198f54d-5c2a-7000-8000-000000000004"),
    );
    const binding: write_service.ParticipantBinding = .{
        .replica = ensured.replica.attestation.binding,
        .replica_members = canonicalMembers(ensured.replica.attestation.binding.member_id),
    };

    var fences = try protocol.fence_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences.state");
    defer fences.deinit();
    var fence_backend: FakeFenceBackend = .{};
    var fence_engine = protocol.fence_service.Service.init(fences.store(), fence_backend.backend());
    const authority = testAuthority(binding.replica.volume_id);
    _ = try fence_engine.accept(fenceBinding(binding.replica, authority));

    var validator: FakeAuthorityValidator = .{ .expected = authority };
    var backend: FakeBackend = .{ .fail_once = true };
    var payload: [4096]u8 = @splat(0xa6);
    const request = prepareRequest(binding, authority, &payload);
    {
        var manager = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer manager.deinit();
        try manager.configure(binding, ensured.replica.attestation.backend_digest);
        const prepared = try manager.prepare(binding, request);
        try std.testing.expectError(
            error.InjectedApplyFailure,
            manager.commit(binding, request.write.transaction_id, certificate(prepared, binding)),
        );
        try std.testing.expect((try manager.inspect(binding)).pending.?.commit_decided);
        backend.fail_once = true;
        try std.testing.expectError(
            error.InjectedApplyFailure,
            manager.beginControl(binding.replica.placement_id, binding.replica.generation, false),
        );
        try std.testing.expect((try manager.inspect(binding)).pending.?.commit_decided);
    }

    validator.active = false;
    {
        var reopened = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer reopened.deinit();
        const inspection = try reopened.inspect(binding);
        try std.testing.expect(inspection.pending == null);
        try std.testing.expectEqual(@as(u64, 1), inspection.frontier.sequence);
        try std.testing.expectEqualSlices(u8, &payload, backend.bytes[4096 .. 4096 + payload.len]);
        var guard = try reopened.beginControl(binding.replica.placement_id, binding.replica.generation, true);
        const delete_request = replicaRequest("0198f54d-5c2a-7000-8000-000000000005");
        replica_backend.fail_delete_once = true;
        try std.testing.expectError(error.InjectedDeleteFailure, replica_engine.deleteReplica(delete_request));
        guard.end();
    }
    {
        var recovered = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer recovered.deinit();
        var retry_guard = try recovered.beginControl(binding.replica.placement_id, binding.replica.generation, true);
        const delete_request = replicaRequest("0198f54d-5c2a-7000-8000-000000000005");
        _ = try replica_engine.deleteReplica(delete_request);
        try retry_guard.retire();
        retry_guard.end();
    }
    var next_request = replicaRequest("0198f54d-5c2a-7000-8000-000000000006");
    next_request.generation = 2;
    next_request.allocation_id = "0198f54d-5c2a-7000-8000-000000000007";
    next_request.offset_bytes = 12 * 1024;
    next_request.length_bytes = 4096;
    const next_replica = (try replica_engine.ensureReplica(next_request)).replica.attestation.binding;
    const next_binding: write_service.ParticipantBinding = .{
        .replica = next_replica,
        .replica_members = canonicalMembers(next_replica.member_id),
    };
    {
        var reopened = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        defer reopened.deinit();
        try std.testing.expect(try reopened.hasWriteHistory(binding.replica.volume_id));
        try std.testing.expectError(error.ParticipantNotConfigured, reopened.inspect(next_binding));
        try reopened.configure(next_binding, replica_backend.digest);
        const next_inspection = try reopened.inspect(next_binding);
        try std.testing.expectEqual(@as(u64, 0), next_inspection.frontier.sequence);
    }
}

test "manager rejects an uncataloged participant state file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var replicas = try protocol.replica_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer replicas.deinit();
    var replica_backend: FakeReplicaBackend = .{};
    var replica_engine = protocol.replica_service.Service.init(replicas.store(), replica_backend.backend());
    var fences = try protocol.fence_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences.state");
    defer fences.deinit();
    var backend: FakeBackend = .{};
    var validator: FakeAuthorityValidator = .{ .expected = testAuthority(testId(1)) };
    {
        var manager = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        manager.deinit();
    }
    const orphan_replica: protocol.ReplicaBinding = .{
        .volume_id = testId(1),
        .placement_id = testId(2),
        .allocation_id = testId(3),
        .generation = 1,
        .member_id = test_member_id,
        .offset_bytes = 4096,
        .length_bytes = 4096,
    };
    const orphan_name = try stateName(std.testing.allocator, orphan_replica);
    defer std.testing.allocator.free(orphan_name);
    const orphan = try tmp.dir.createFile(std.testing.io, orphan_name, .{});
    orphan.close(std.testing.io);
    try std.testing.expectError(
        error.OrphanParticipantState,
        WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        ),
    );
}

test "manager rejects a missing catalog after durable initialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var replicas = try protocol.replica_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer replicas.deinit();
    var replica_backend: FakeReplicaBackend = .{};
    var replica_engine = protocol.replica_service.Service.init(replicas.store(), replica_backend.backend());
    var fences = try protocol.fence_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "fences.state");
    defer fences.deinit();
    var backend: FakeBackend = .{};
    var validator: FakeAuthorityValidator = .{ .expected = testAuthority(testId(1)) };
    {
        var manager = try WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        );
        manager.deinit();
    }
    try tmp.dir.deleteFile(std.testing.io, catalog_basename);
    try std.testing.expectError(
        error.CatalogMissing,
        WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            &replicas,
            &replica_engine,
            &fences,
            backend.backend(),
            validator.validator(),
        ),
    );
}
