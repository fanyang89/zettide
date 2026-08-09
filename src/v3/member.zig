const std = @import("std");
const builtin = @import("builtin");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const genesis_payload_format = @import("genesis_payload.zig");
const member_bootstrap = @import("member_bootstrap.zig");
const member_format = @import("member_format.zig");
const pool_genesis_payload = @import("pool_genesis_payload.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");
const replica_endpoint = @import("replica_endpoint.zig");
const storage_api = @import("storage.zig");
const topology_format = @import("topology.zig");

const Io = std.Io;
const File = Io.File;

pub const OpenMode = member_format.OpenMode;
pub const SourceSlot = member_format.SourceSlot;
pub const Storage = storage_api.Storage;
pub const ReplicaEndpoint = replica_endpoint.ReplicaEndpoint;

pub const CreateFaultPoint = enum {
    extent_sync,
    genesis_write,
    genesis_sync,
    header_b_write,
    header_b_sync,
    header_a_write,
    header_a_sync,
    parent_sync,
};

pub const CreateFaultAction = enum { before, partial, after };

pub const CreateFault = struct {
    point: CreateFaultPoint,
    action: CreateFaultAction,
};

pub const CreateFaultController = struct {
    fail: ?CreateFault = null,
    observed: [8]CreateFaultPoint = undefined,
    observed_count: usize = 0,

    fn action(self: *CreateFaultController, point: CreateFaultPoint) ?CreateFaultAction {
        if (self.observed_count < self.observed.len) {
            self.observed[self.observed_count] = point;
            self.observed_count += 1;
        }
        if (self.fail) |fault| if (fault.point == point) return fault.action;
        return null;
    }

    pub fn events(self: *const CreateFaultController) []const CreateFaultPoint {
        return self.observed[0..self.observed_count];
    }
};

pub const CreateOptions = struct {
    fault: ?*CreateFaultController = null,
};

pub const RegionKind = enum {
    control,
    metadata,
    data,
};

pub const RegionWrite = struct {
    offset: u64,
    bytes: []const u8,
};

pub const CatalogClaim = struct {
    member: *Member,
    id: u64,
    released: bool = false,

    pub fn read(self: *const CatalogClaim, offset: u64, buffer: []u8) !void {
        try self.member.validateCatalogClaim(self.id);
        try self.member.read(.metadata, offset, buffer);
    }

    pub fn writeBatchDurable(self: *const CatalogClaim, writes: []const RegionWrite) !void {
        return self.member.writeCatalogBatchDurable(self.id, writes);
    }

    pub fn writeRootDurable(self: *const CatalogClaim, offset: u64, bytes: []const u8) !void {
        return self.member.writeCatalogRootDurable(self.id, offset, bytes);
    }

    pub fn activateCatalogData(self: *const CatalogClaim) !void {
        return self.member.activateCatalogDataWithCatalogClaim(self.id);
    }

    pub fn release(self: *CatalogClaim) !void {
        if (self.released) return;
        try self.member.releaseCatalogClaim(self.id);
        self.released = true;
    }
};

pub const DataClaim = struct {
    member: *Member,
    id: u64,
    released: bool = false,

    pub fn write(self: *const DataClaim, offset: u64, bytes: []const u8) !void {
        return self.member.writeDataClaimed(self.id, offset, bytes);
    }

    pub fn writeMany(self: *const DataClaim, writes: []const storage_api.Write) !void {
        return self.member.writeDataClaimedMany(self.id, writes);
    }

    pub fn sync(self: *const DataClaim) !void {
        return self.member.syncDataClaimed(self.id);
    }

    pub fn activateCatalogData(self: *const DataClaim) !void {
        return self.member.activateCatalogDataWithDataClaim(self.id);
    }

    pub fn release(self: *DataClaim) !void {
        if (self.released) return;
        try self.member.releaseDataClaim(self.id);
        self.released = true;
    }
};

pub const FaultController = struct {
    fail_write_at: ?u64 = null,
    fail_write_partial_at: ?u64 = null,
    fail_write_after_at: ?u64 = null,
    fail_sync_at: ?u64 = null,
    fail_sync_after_at: ?u64 = null,
    write_count: u64 = 0,
    sync_count: u64 = 0,
    pause_after_write: ?*FaultPause = null,

    pub fn disable(self: *FaultController) void {
        self.fail_write_at = null;
        self.fail_write_partial_at = null;
        self.fail_write_after_at = null;
        self.fail_sync_at = null;
        self.fail_sync_after_at = null;
        self.pause_after_write = null;
    }

    fn action(self: *FaultController, operation: enum { write, sync }) FaultAction {
        const count = switch (operation) {
            .write => &self.write_count,
            .sync => &self.sync_count,
        };
        const current = count.*;
        count.* += 1;
        return switch (operation) {
            .write => if (matches(self.fail_write_at, current))
                .before
            else if (matches(self.fail_write_partial_at, current))
                .partial
            else if (matches(self.fail_write_after_at, current))
                .after
            else
                .none,
            .sync => if (matches(self.fail_sync_at, current))
                .before
            else if (matches(self.fail_sync_after_at, current))
                .after
            else
                .none,
        };
    }
};

pub const FaultPause = struct {
    reached: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
};

const FaultAction = enum { none, before, partial, after };

fn matches(target: ?u64, current: u64) bool {
    return target != null and target.? == current;
}

pub const Member = struct {
    io: Io,
    storage: Storage,
    selected_header: member_format.Header,
    selected_source: SourceSlot,
    degraded: bool,
    checkpoint_reclaim_ready: bool,
    open_mode: OpenMode,
    mutex: Io.RwLock = .init,
    fault: ?*FaultController = null,
    dirty: bool = false,
    frozen: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    journal_claimed: std.atomic.Value(bool) = .init(false),
    catalog_claim_id: std.atomic.Value(u64) = .init(0),
    catalog_claim_sequence: std.atomic.Value(u64) = .init(1),
    data_claim_id: std.atomic.Value(u64) = .init(0),
    data_claim_sequence: std.atomic.Value(u64) = .init(1),
    catalog_mode_active: std.atomic.Value(bool) = .init(false),

    pub fn createAt(
        io: Io,
        parent: Io.Dir,
        basename: []const u8,
        initial_header: member_format.Header,
        genesis_payload: genesis_payload_format.GenesisPayload,
        options: CreateOptions,
    ) !Member {
        try validateCreateAt(basename, initial_header, genesis_payload);
        const storage = try Storage.createFile(io, parent, basename, initial_header.member_bytes);
        var result = try Member.createStorage(io, storage, initial_header, genesis_payload, options);
        errdefer result.deinit();
        if (builtin.os.tag == .linux) try createParentSync(parent, io, options.fault);
        return result;
    }

    pub fn createPoolAt(
        io: Io,
        parent: Io.Dir,
        basename: []const u8,
        initial_header: member_format.Header,
        genesis_payload: pool_genesis_payload.GenesisPayload,
        options: CreateOptions,
    ) !Member {
        try validateCreatePoolAt(basename, initial_header, genesis_payload);
        const storage = try Storage.createFile(io, parent, basename, initial_header.member_bytes);
        var result = try Member.createPoolStorage(io, storage, initial_header, genesis_payload, options);
        errdefer result.deinit();
        if (builtin.os.tag == .linux) try createParentSync(parent, io, options.fault);
        return result;
    }

    pub fn createJoiningAt(
        io: Io,
        parent: Io.Dir,
        basename: []const u8,
        initial_header: member_format.Header,
        bootstrap_record: control_record.Record,
        options: CreateOptions,
    ) !Member {
        try validateCreateJoiningAt(basename, initial_header, bootstrap_record);
        const storage = try Storage.createFile(io, parent, basename, initial_header.member_bytes);
        var result = try Member.createJoiningStorage(io, storage, initial_header, bootstrap_record, options);
        errdefer result.deinit();
        if (builtin.os.tag == .linux) try createParentSync(parent, io, options.fault);
        return result;
    }

    pub fn createStorage(
        io: Io,
        storage: Storage,
        initial_header: member_format.Header,
        genesis_payload: genesis_payload_format.GenesisPayload,
        options: CreateOptions,
    ) !Member {
        var owned_storage = storage;
        errdefer owned_storage.close(io) catch {};
        try validateCreateStorage(initial_header, genesis_payload);
        const genesis_record = try genesis_payload_format.makeRecord(initial_header.member_id, genesis_payload);
        const encoded_genesis = try control_record.encode(genesis_record);
        return createWithFirstRecord(io, owned_storage, initial_header, &encoded_genesis, options);
    }

    pub fn createPoolStorage(
        io: Io,
        storage: Storage,
        initial_header: member_format.Header,
        genesis_payload: pool_genesis_payload.GenesisPayload,
        options: CreateOptions,
    ) !Member {
        var owned_storage = storage;
        errdefer owned_storage.close(io) catch {};
        try validateCreatePoolStorage(initial_header, genesis_payload);
        const genesis_record = try pool_genesis_payload.makeRecord(initial_header.member_id, genesis_payload);
        const encoded_genesis = try control_record.encodeDynamicPool(genesis_record);
        return createWithFirstRecord(io, owned_storage, initial_header, &encoded_genesis, options);
    }

    pub fn createJoiningStorage(
        io: Io,
        storage: Storage,
        initial_header: member_format.Header,
        bootstrap_record: control_record.Record,
        options: CreateOptions,
    ) !Member {
        var owned_storage = storage;
        errdefer owned_storage.close(io) catch {};
        try validateCreateJoiningStorage(initial_header, bootstrap_record);
        const encoded_bootstrap = try control_record.encodeDynamicPool(bootstrap_record);
        return createWithFirstRecord(io, owned_storage, initial_header, &encoded_bootstrap, options);
    }

    fn createWithFirstRecord(
        io: Io,
        storage_value: Storage,
        initial_header: member_format.Header,
        first_record: *const [control_record.encoded_size]u8,
        options: CreateOptions,
    ) !Member {
        const encoded_header = try member_format.encode(initial_header);
        var storage = storage_value;
        if (storage.capacity() < initial_header.member_bytes) return error.TruncatedMember;
        if (storage.kind == .regular_file and storage.capacity() > initial_header.member_bytes)
            return error.UnexpectedMemberLength;

        try createSync(&storage, io, options.fault, .extent_sync);
        try createWrite(&storage, io, initial_header.control.offset, first_record, options.fault, .genesis_write);
        try createSync(&storage, io, options.fault, .genesis_sync);
        try createWrite(&storage, io, member_format.encoded_size, &encoded_header, options.fault, .header_b_write);
        try createSync(&storage, io, options.fault, .header_b_sync);
        try createWrite(&storage, io, 0, &encoded_header, options.fault, .header_a_write);
        try createSync(&storage, io, options.fault, .header_a_sync);

        return .{
            .io = io,
            .storage = storage,
            .selected_header = initial_header,
            .selected_source = .a,
            .degraded = false,
            .checkpoint_reclaim_ready = false,
            .open_mode = .writable,
            .catalog_mode_active = .init(member_format.hasCatalogData(initial_header)),
        };
    }

    pub fn openAt(io: Io, parent: Io.Dir, basename: []const u8, open_mode: OpenMode) !Member {
        if (!validBasename(basename)) return error.InvalidBasename;
        const storage = try Storage.openFile(io, parent, basename, open_mode == .writable);
        return Member.openStorage(io, storage, open_mode);
    }

    pub fn openStorage(io: Io, storage_value: Storage, open_mode: OpenMode) !Member {
        var storage = storage_value;
        errdefer storage.close(io) catch {};

        var first_transport_error: ?anyerror = null;
        const a = readCandidate(&storage, io, 0) catch |err| candidate: {
            first_transport_error = err;
            break :candidate member_format.Candidate{ .invalid = err };
        };
        const b = readCandidate(&storage, io, member_format.encoded_size) catch |err| candidate: {
            if (first_transport_error == null) first_transport_error = err;
            break :candidate member_format.Candidate{ .invalid = err };
        };
        const selection = member_format.select(a, b) catch |err| {
            if (err == error.NoValidMemberHeader) {
                if (first_transport_error) |transport_error| return transport_error;
            }
            return err;
        };

        try member_format.checkOpenPolicy(selection.header, open_mode);
        const actual_length = storage.capacity();
        if (actual_length < selection.header.member_bytes) return error.TruncatedMember;
        if (storage.kind == .regular_file and actual_length > selection.header.member_bytes)
            return error.UnexpectedMemberLength;

        return .{
            .io = io,
            .storage = storage,
            .selected_header = selection.header,
            .selected_source = selection.source,
            .degraded = selection.redundancy_degraded,
            .checkpoint_reclaim_ready = false,
            .open_mode = open_mode,
            .catalog_mode_active = .init(member_format.hasCatalogData(selection.header)),
        };
    }

    pub fn header(self: *const Member) member_format.Header {
        return self.selected_header;
    }

    pub fn source(self: *const Member) SourceSlot {
        return self.selected_source;
    }

    pub fn redundancyDegraded(self: *const Member) bool {
        return self.degraded;
    }

    pub fn checkpointReclaimReady(self: *const Member) bool {
        return !self.isClosed() and self.checkpoint_reclaim_ready;
    }

    pub fn mode(self: *const Member) OpenMode {
        return self.open_mode;
    }

    pub fn isFrozen(self: *const Member) bool {
        return self.frozen.load(.acquire);
    }

    pub fn isClosed(self: *const Member) bool {
        return self.closed.load(.acquire);
    }

    pub fn setFaultController(self: *Member, fault: ?*FaultController) void {
        self.fault = fault;
    }

    pub fn fenceUnleasedCatalogWrites(self: *Member) void {
        self.catalog_mode_active.store(true, .release);
    }

    pub fn asReplicaEndpoint(self: *Member) ReplicaEndpoint {
        const selected = self.header();
        return ReplicaEndpoint.init(
            self,
            .{
                .logical_capacity = selected.logical_capacity,
                .data_length = selected.data.length,
            },
            &member_replica_vtable,
        );
    }

    pub fn claimJournal(self: *Member) !void {
        if (self.journal_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
            return error.JournalAlreadyOpen;
    }

    pub fn releaseJournal(self: *Member) void {
        self.journal_claimed.store(false, .release);
    }

    pub fn claimCatalog(self: *Member) !CatalogClaim {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;
        var id = self.catalog_claim_sequence.load(.acquire);
        while (true) {
            if (id == 0 or id == std.math.maxInt(u64)) return error.CatalogClaimSequenceExhausted;
            if (self.catalog_claim_sequence.cmpxchgWeak(id, id + 1, .acq_rel, .acquire)) |observed| {
                id = observed;
                continue;
            }
            break;
        }
        if (self.catalog_claim_id.cmpxchgStrong(0, id, .acq_rel, .acquire) != null)
            return error.CatalogAlreadyClaimed;
        return .{ .member = self, .id = id };
    }

    fn releaseCatalogClaim(self: *Member, claim_id: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.catalog_claim_id.cmpxchgStrong(claim_id, 0, .acq_rel, .acquire) != null)
            return error.InvalidCatalogClaim;
    }

    pub fn read(self: *Member, kind: RegionKind, offset: u64, buffer: []u8) !void {
        try self.mutex.lockShared(self.io);
        defer self.mutex.unlockShared(self.io);

        if (self.isClosed()) return error.MemberClosed;
        const file_offset = try self.position(kind, offset, buffer.len);
        const amount = try self.storage.readAt(self.io, buffer, file_offset);
        if (amount != buffer.len) return error.TruncatedMember;
    }

    pub fn transportKind(self: *const Member) storage_api.TransportKind {
        return self.storage.transportKind();
    }

    pub fn transportStats(self: *Member) storage_api.TransportStats {
        return self.storage.transportStats(self.io);
    }

    pub fn resetTransportStats(self: *Member) void {
        self.storage.resetTransportStats(self.io);
    }

    pub fn readMany(
        self: *Member,
        kind: RegionKind,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
    ) !void {
        if (reads.len != results.len) return error.InvalidReadBatch;
        try self.mutex.lockShared(self.io);
        defer self.mutex.unlockShared(self.io);
        if (self.isClosed()) return error.MemberClosed;
        for (results) |*result| result.* = .{};

        var index: usize = 0;
        while (index < reads.len) {
            const count = @min(reads.len - index, @as(usize, 32));
            var absolute: [32]storage_api.Read = undefined;
            for (reads[index..][0..count], absolute[0..count]) |request, *item| item.* = .{
                .buffer = request.buffer,
                .offset = try self.position(kind, request.offset, request.buffer.len),
            };
            try self.storage.readManyAt(self.io, absolute[0..count], results[index..][0..count]);
            for (reads[index..][0..count], results[index..][0..count]) |request, *result| {
                if (result.failure == null and result.amount != request.buffer.len)
                    result.failure = error.TruncatedMember;
            }
            index += count;
        }
    }

    pub fn write(self: *Member, kind: RegionKind, offset: u64, bytes: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (kind == .metadata) {
            if (self.catalog_mode_active.load(.acquire)) return error.CatalogClaimRequired;
            if (self.catalog_claim_id.load(.acquire) != 0) return error.CatalogClaimed;
        }
        if (kind == .data) {
            if (self.catalog_mode_active.load(.acquire)) return error.DataGenerationLeaseRequired;
            if (self.data_claim_id.load(.acquire) != 0) return error.DataClaimed;
        }
        try self.writeLocked(kind, offset, bytes);
    }

    pub fn writeDurable(self: *Member, kind: RegionKind, offset: u64, bytes: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (kind == .metadata) {
            if (self.catalog_mode_active.load(.acquire)) return error.CatalogClaimRequired;
            if (self.catalog_claim_id.load(.acquire) != 0) return error.CatalogClaimed;
        }
        if (kind == .data) {
            if (self.catalog_mode_active.load(.acquire)) return error.DataGenerationLeaseRequired;
            if (self.data_claim_id.load(.acquire) != 0) return error.DataClaimed;
        }
        try self.writeLocked(kind, offset, bytes);
        try self.syncLocked();
    }

    fn writeCatalogBatchDurable(self: *Member, claim_id: u64, writes: []const RegionWrite) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.validateCatalogWriteClaim(claim_id);
        if (writes.len == 0) return;
        for (writes) |item| _ = try self.position(.metadata, item.offset, item.bytes.len);
        for (writes) |item| try self.writeLocked(.metadata, item.offset, item.bytes);
        try self.syncLocked();
    }

    fn writeCatalogRootDurable(self: *Member, claim_id: u64, offset: u64, bytes: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.validateCatalogWriteClaim(claim_id);
        try self.writeLocked(.metadata, offset, bytes);
        try self.syncLocked();
    }

    fn activateCatalogDataWithCatalogClaim(self: *Member, claim_id: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.validateCatalogWriteClaim(claim_id);
        try self.activateCatalogDataLocked();
    }

    fn validateCatalogWriteClaim(self: *Member, claim_id: u64) !void {
        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;
        if (claim_id == 0 or self.catalog_claim_id.load(.acquire) != claim_id)
            return error.InvalidCatalogClaim;
    }

    fn validateCatalogClaim(self: *Member, claim_id: u64) !void {
        if (claim_id == 0 or self.catalog_claim_id.load(.acquire) != claim_id)
            return error.InvalidCatalogClaim;
    }

    pub fn claimData(self: *Member) !DataClaim {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;
        var id = self.data_claim_sequence.load(.acquire);
        while (true) {
            if (id == 0 or id == std.math.maxInt(u64)) return error.DataClaimSequenceExhausted;
            if (self.data_claim_sequence.cmpxchgWeak(id, id + 1, .acq_rel, .acquire)) |observed| {
                id = observed;
                continue;
            }
            break;
        }
        if (self.data_claim_id.cmpxchgStrong(0, id, .acq_rel, .acquire) != null)
            return error.DataAlreadyClaimed;
        return .{ .member = self, .id = id };
    }

    fn releaseDataClaim(self: *Member, claim_id: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.data_claim_id.cmpxchgStrong(claim_id, 0, .acq_rel, .acquire) != null)
            return error.InvalidDataClaim;
    }

    fn writeDataClaimed(self: *Member, claim_id: u64, offset: u64, bytes: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.validateDataClaim(claim_id);
        try self.writeLocked(.data, offset, bytes);
    }

    fn writeDataClaimedMany(self: *Member, claim_id: u64, writes: []const storage_api.Write) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.validateDataClaim(claim_id);
        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;
        var batchable = self.fault == null;
        for (writes) |request| {
            _ = try self.position(.data, request.offset, request.bytes.len);
            batchable = batchable and request.bytes.len != 0;
        }
        if (!batchable) {
            for (writes) |request| try self.writeLocked(.data, request.offset, request.bytes);
            return;
        }

        var index: usize = 0;
        while (index < writes.len) {
            const count = @min(writes.len - index, @as(usize, 32));
            var absolute: [32]storage_api.Write = undefined;
            for (writes[index..][0..count], absolute[0..count]) |request, *item| item.* = .{
                .bytes = request.bytes,
                .offset = try self.position(.data, request.offset, request.bytes.len),
            };
            self.dirty = true;
            self.storage.writeAllManyAt(self.io, absolute[0..count]) catch |err| {
                self.freeze();
                return err;
            };
            index += count;
        }
    }

    fn syncDataClaimed(self: *Member, claim_id: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.validateDataClaim(claim_id);
        try self.syncLocked();
    }

    fn activateCatalogDataWithDataClaim(self: *Member, claim_id: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;
        try self.validateDataClaim(claim_id);
        try self.activateCatalogDataLocked();
    }

    fn validateDataClaim(self: *Member, claim_id: u64) !void {
        if (claim_id == 0 or self.data_claim_id.load(.acquire) != claim_id)
            return error.InvalidDataClaim;
    }

    fn activateCatalogDataLocked(self: *Member) !void {
        if (member_format.poolFilesystem(self.selected_header) == .blob)
            return error.BlobFilesystemCatalogDataConflict;
        self.catalog_mode_active.store(true, .release);
        if (member_format.hasCatalogData(self.selected_header)) {
            if (!self.degraded) return;
            const encoded = try member_format.encode(self.selected_header);
            const mirror_offset: u64 = if (self.selected_source == .a) member_format.encoded_size else 0;
            try self.writeHeaderLocked(mirror_offset, &encoded);
            try self.syncLocked();
            self.degraded = false;
            return;
        }

        var next_header = self.selected_header;
        next_header.header_sequence = std.math.add(u64, next_header.header_sequence, 1) catch
            return error.HeaderSequenceOverflow;
        next_header.incompat_features |= member_format.catalog_data_incompat_feature;
        const encoded = try member_format.encode(next_header);
        const first_offset: u64 = if (self.selected_source == .a) member_format.encoded_size else 0;
        const second_offset: u64 = if (self.selected_source == .a) 0 else member_format.encoded_size;
        try self.writeHeaderLocked(first_offset, &encoded);
        try self.syncLocked();
        try self.writeHeaderLocked(second_offset, &encoded);
        try self.syncLocked();
        self.selected_header = next_header;
        self.selected_source = .a;
        self.degraded = false;
    }

    pub fn publishCheckpoint(
        self: *Member,
        absolute_offset: u64,
        record_sequence: u64,
        record_digest: codec.Digest,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;

        var next_header = self.selected_header;
        next_header.header_sequence = std.math.add(u64, next_header.header_sequence, 1) catch
            return error.HeaderSequenceOverflow;
        next_header.checkpoint_offset = absolute_offset;
        next_header.checkpoint_record_sequence = record_sequence;
        next_header.checkpoint_record_digest = record_digest;
        const encoded = try member_format.encode(next_header);
        const target: SourceSlot = if (self.selected_source == .a) .b else .a;
        const file_offset: u64 = if (target == .a) 0 else member_format.encoded_size;

        self.checkpoint_reclaim_ready = false;
        try self.writeHeaderLocked(file_offset, &encoded);
        try self.syncLocked();
        self.selected_header = next_header;
        self.selected_source = target;
        self.degraded = false;
    }

    pub fn publishCheckpointRedundant(
        self: *Member,
        absolute_offset: u64,
        record_sequence: u64,
        record_digest: codec.Digest,
    ) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;

        var next_header = self.selected_header;
        next_header.header_sequence = std.math.add(u64, next_header.header_sequence, 1) catch
            return error.HeaderSequenceOverflow;
        next_header.checkpoint_offset = absolute_offset;
        next_header.checkpoint_record_sequence = record_sequence;
        next_header.checkpoint_record_digest = record_digest;
        const encoded = try member_format.encode(next_header);
        const first_offset: u64 = if (self.selected_source == .a) member_format.encoded_size else 0;
        const second_offset: u64 = if (self.selected_source == .a) 0 else member_format.encoded_size;

        self.checkpoint_reclaim_ready = false;
        try self.writeHeaderLocked(first_offset, &encoded);
        try self.syncLocked();
        try self.writeHeaderLocked(second_offset, &encoded);
        try self.syncLocked();
        self.selected_header = next_header;
        self.selected_source = .a;
        self.degraded = false;
        self.checkpoint_reclaim_ready = true;
    }

    fn writeLocked(self: *Member, kind: RegionKind, offset: u64, bytes: []const u8) !void {
        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;
        const file_offset = try self.position(kind, offset, bytes.len);
        if (bytes.len == 0) return;
        self.dirty = true;

        const action = if (self.fault) |fault| fault.action(.write) else .none;
        if (action == .before or (action == .partial and bytes.len < 2)) {
            self.freeze();
            return error.InjectedFault;
        }
        const write_bytes = if (action == .partial) bytes[0 .. bytes.len / 2] else bytes;
        self.storage.writeAllAt(self.io, write_bytes, file_offset) catch |err| {
            self.freeze();
            return err;
        };
        if (self.fault) |fault| if (fault.pause_after_write) |pause| {
            pause.reached.store(true, .release);
            while (!pause.released.load(.acquire)) std.Thread.yield() catch {};
        };
        if (action == .partial or action == .after) {
            self.freeze();
            return error.InjectedFault;
        }
    }

    fn writeHeaderLocked(self: *Member, offset: u64, bytes: []const u8) !void {
        self.dirty = true;
        const action = if (self.fault) |fault| fault.action(.write) else .none;
        if (action == .before) {
            self.freeze();
            return error.InjectedFault;
        }
        const write_bytes = if (action == .partial) bytes[0 .. bytes.len / 2] else bytes;
        self.storage.writeAllAt(self.io, write_bytes, offset) catch |err| {
            self.freeze();
            return err;
        };
        if (action == .partial or action == .after) {
            self.freeze();
            return error.InjectedFault;
        }
    }

    pub fn sync(self: *Member) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.catalog_mode_active.load(.acquire)) return error.DataGenerationLeaseRequired;
        if (self.data_claim_id.load(.acquire) != 0) return error.DataClaimed;
        try self.syncLocked();
    }

    /// Active catalog or data claims reject close without consuming the member.
    /// Otherwise close consumes the underlying Storage even when cleanup fails.
    pub fn close(self: *Member) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.isClosed()) return;
        if (self.catalog_claim_id.load(.acquire) != 0) return error.CatalogClaimed;
        if (self.data_claim_id.load(.acquire) != 0) return error.DataClaimed;
        self.checkpoint_reclaim_ready = false;

        var first_error: ?anyerror = null;
        if (self.open_mode == .writable and self.dirty) {
            if (self.isFrozen()) {
                first_error = error.WriteFrozen;
            } else {
                self.syncLocked() catch |err| {
                    first_error = err;
                };
            }
        }
        var close_error: ?anyerror = null;
        self.storage.close(self.io) catch |err| {
            close_error = err;
        };
        self.closed.store(true, .release);
        if (first_error) |err| return err;
        if (close_error) |err| return err;
    }

    pub fn deinit(self: *Member) void {
        self.close() catch {};
    }

    fn syncLocked(self: *Member) !void {
        if (self.isClosed()) return error.MemberClosed;
        if (self.open_mode != .writable) return error.ReadOnlyMember;
        if (self.isFrozen()) return error.WriteFrozen;

        const action = if (self.fault) |fault| fault.action(.sync) else .none;
        if (action == .before) {
            self.freeze();
            return error.InjectedFault;
        }
        self.storage.sync(self.io) catch |err| {
            self.freeze();
            return err;
        };
        if (action == .after) {
            self.freeze();
            return error.InjectedFault;
        }
        self.dirty = false;
    }

    fn position(self: *const Member, kind: RegionKind, offset: u64, len: usize) !u64 {
        const region = switch (kind) {
            .control => self.selected_header.control,
            .metadata => self.selected_header.metadata,
            .data => self.selected_header.data,
        };
        const length = std.math.cast(u64, len) orelse return error.RegionOutOfBounds;
        if (offset > region.length or length > region.length - offset)
            return error.RegionOutOfBounds;
        return std.math.add(u64, region.offset, offset) catch error.RegionOutOfBounds;
    }

    fn freeze(self: *Member) void {
        self.frozen.store(true, .release);
    }
};

const member_replica_vtable: ReplicaEndpoint.VTable = .{
    .read_metadata = replicaReadMetadata,
    .read_data = replicaReadData,
    .read_data_many = replicaReadDataMany,
    .write_data = replicaWriteData,
    .write_metadata_durable = replicaWriteMetadataDurable,
    .sync = replicaSync,
};

fn replicaMember(context: *anyopaque) *Member {
    return @ptrCast(@alignCast(context));
}

fn replicaReadMetadata(context: *anyopaque, offset: u64, buffer: []u8) anyerror!void {
    return replicaMember(context).read(.metadata, offset, buffer);
}

fn replicaReadData(context: *anyopaque, offset: u64, buffer: []u8) anyerror!void {
    return replicaMember(context).read(.data, offset, buffer);
}

fn replicaReadDataMany(
    context: *anyopaque,
    reads: []const storage_api.Read,
    results: []storage_api.ReadResult,
) anyerror!void {
    return replicaMember(context).readMany(.data, reads, results);
}

fn replicaWriteData(context: *anyopaque, offset: u64, data: []const u8) anyerror!void {
    return replicaMember(context).write(.data, offset, data);
}

fn replicaWriteMetadataDurable(context: *anyopaque, offset: u64, data: []const u8) anyerror!void {
    return replicaMember(context).writeDurable(.metadata, offset, data);
}

fn replicaSync(context: *anyopaque) anyerror!void {
    return replicaMember(context).sync();
}

pub fn openAt(io: Io, parent: Io.Dir, basename: []const u8, mode: OpenMode) !Member {
    return Member.openAt(io, parent, basename, mode);
}

pub fn openStorage(io: Io, storage: Storage, mode: OpenMode) !Member {
    return Member.openStorage(io, storage, mode);
}

pub fn createAt(
    io: Io,
    parent: Io.Dir,
    basename: []const u8,
    header: member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
    options: CreateOptions,
) !Member {
    return Member.createAt(io, parent, basename, header, genesis_payload, options);
}

pub fn createStorage(
    io: Io,
    storage: Storage,
    header: member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
    options: CreateOptions,
) !Member {
    return Member.createStorage(io, storage, header, genesis_payload, options);
}

pub fn createPoolAt(
    io: Io,
    parent: Io.Dir,
    basename: []const u8,
    header: member_format.Header,
    genesis_payload: pool_genesis_payload.GenesisPayload,
    options: CreateOptions,
) !Member {
    return Member.createPoolAt(io, parent, basename, header, genesis_payload, options);
}

pub fn createPoolStorage(
    io: Io,
    storage: Storage,
    header: member_format.Header,
    genesis_payload: pool_genesis_payload.GenesisPayload,
    options: CreateOptions,
) !Member {
    return Member.createPoolStorage(io, storage, header, genesis_payload, options);
}

pub fn createJoiningAt(
    io: Io,
    parent: Io.Dir,
    basename: []const u8,
    header: member_format.Header,
    bootstrap_record: control_record.Record,
    options: CreateOptions,
) !Member {
    return Member.createJoiningAt(io, parent, basename, header, bootstrap_record, options);
}

pub fn createJoiningStorage(
    io: Io,
    storage: Storage,
    header: member_format.Header,
    bootstrap_record: control_record.Record,
    options: CreateOptions,
) !Member {
    return Member.createJoiningStorage(io, storage, header, bootstrap_record, options);
}

pub fn validateCreateAt(
    basename: []const u8,
    header: member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
) !void {
    if (!validBasename(basename)) return error.InvalidBasename;
    try validateCreateStorage(header, genesis_payload);
}

pub fn validateCreateStorage(
    header: member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
) !void {
    try validateInitialCreate(header);
    if (member_format.isDynamicPool(header)) return error.LegacyMemberRequired;

    const genesis_digest = try topology_format.digest(genesis_payload.topology);
    try topology_format.validateMemberHeader(genesis_payload.topology, genesis_digest, header);
    if (header.chunk_size != genesis_payload.layout.chunk_size) return error.ChunkSizeMismatch;
    const record = try genesis_payload_format.makeRecord(header.member_id, genesis_payload);
    _ = try genesis_payload_format.validateRecord(record);
}

pub fn validateCreatePoolAt(
    basename: []const u8,
    header: member_format.Header,
    genesis_payload: pool_genesis_payload.GenesisPayload,
) !void {
    if (!validBasename(basename)) return error.InvalidBasename;
    try validateCreatePoolStorage(header, genesis_payload);
}

pub fn validateCreatePoolStorage(
    header: member_format.Header,
    genesis_payload: pool_genesis_payload.GenesisPayload,
) !void {
    try validateInitialCreate(header);
    try pool_genesis_payload.validateMemberHeader(genesis_payload, header);
    const record = try pool_genesis_payload.makeRecord(header.member_id, genesis_payload);
    _ = try pool_genesis_payload.validateRecord(record);
}

pub fn validateCreateJoiningAt(
    basename: []const u8,
    header: member_format.Header,
    bootstrap_record: control_record.Record,
) !void {
    if (!validBasename(basename)) return error.InvalidBasename;
    try validateCreateJoiningStorage(header, bootstrap_record);
}

pub fn validateCreateJoiningStorage(
    header: member_format.Header,
    bootstrap_record: control_record.Record,
) !void {
    try validateInitialCreate(header);
    _ = try member_bootstrap.validateTargetFirstRecord(header, bootstrap_record);
}

fn validateInitialCreate(header: member_format.Header) !void {
    _ = try member_format.encode(header);
    if (header.header_sequence != 1) return error.InvalidInitialHeaderSequence;
    if (header.checkpoint_offset != 0 or header.checkpoint_record_sequence != 0 or
        !codec.isZero(&header.checkpoint_record_digest)) return error.InvalidInitialCheckpoint;
    try member_format.checkOpenPolicy(header, .writable);
    if (header.member_bytes > std.math.maxInt(i64)) return error.MemberTooLarge;
}

fn createWrite(
    storage: *Storage,
    io: Io,
    offset: u64,
    bytes: []const u8,
    fault: ?*CreateFaultController,
    point: CreateFaultPoint,
) !void {
    const action = if (fault) |controller| controller.action(point) else null;
    if (action == .before) return error.InjectedCreateFault;
    const write_bytes = if (action == .partial) bytes[0 .. bytes.len / 2] else bytes;
    try storage.writeAllAt(io, write_bytes, offset);
    if (action == .partial or action == .after) return error.InjectedCreateFault;
}

fn createSync(storage: *Storage, io: Io, fault: ?*CreateFaultController, point: CreateFaultPoint) !void {
    const action = if (fault) |controller| controller.action(point) else null;
    if (action == .before) return error.InjectedCreateFault;
    try storage.sync(io);
    if (action == .partial or action == .after) return error.InjectedCreateFault;
}

fn createParentSync(parent: Io.Dir, io: Io, fault: ?*CreateFaultController) !void {
    const action = if (fault) |controller| controller.action(.parent_sync) else null;
    if (action == .before) return error.InjectedCreateFault;
    const syncable_parent = try parent.openDir(io, ".", .{ .iterate = true });
    defer syncable_parent.close(io);
    const directory_file: File = .{ .handle = syncable_parent.handle, .flags = .{ .nonblocking = false } };
    try directory_file.sync(io);
    if (action == .partial or action == .after) return error.InjectedCreateFault;
}

fn validBasename(name: []const u8) bool {
    return name.len != 0 and
        !std.mem.eql(u8, name, ".") and
        !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

fn readCandidate(storage: *Storage, io: Io, offset: u64) !member_format.Candidate {
    var bytes: [member_format.encoded_size]u8 = undefined;
    const amount = try storage.readAt(io, &bytes, offset);
    if (amount != bytes.len) return .{ .invalid = error.TruncatedMember };
    return member_format.decodeCandidate(&bytes);
}

fn testHeader() member_format.Header {
    return .{
        .header_sequence = 1,
        .set_id = .{ 0x10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .member_id = .{ 0x20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .member_slot = 0,
        .created_ns = 1,
        .member_bytes = 3 * 1024 * 1024,
        .logical_capacity = 1024 * 1024,
        .control = .{ .offset = 64 * 1024, .length = 4096 },
        .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
        .data = .{ .offset = 2 * 1024 * 1024, .length = 1024 * 1024 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = 1024 * 1024,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = 1,
        .control_record_format_version = 1,
        .label = member_format.Label.init("member-test") catch unreachable,
        .genesis_topology_digest = @splat(0x5a),
    };
}

fn testCreatePayload() genesis_payload_format.GenesisPayload {
    return .{
        .topology = .{
            .set_id = @splat(0x10),
            .epoch = 1,
            .parent_digest = @splat(0),
            .members = .{
                .{ .member_id = @splat(0x20), .slot = 0 },
                .{ .member_id = @splat(0x30), .slot = 1 },
                .{ .member_id = @splat(0x40), .slot = 2 },
            },
        },
        .layout = .{ .layout_epoch = 1, .topology_epoch = 1, .chunk_size = 1024 * 1024 },
    };
}

fn testCreateHeader(slot: u16) !member_format.Header {
    const payload = testCreatePayload();
    var header = testHeader();
    header.set_id = payload.topology.set_id;
    header.member_id = payload.topology.members[slot].member_id;
    header.member_slot = slot;
    header.genesis_topology_digest = try topology_format.digest(payload.topology);
    return header;
}

fn testPoolCreate() !struct { member_format.Header, pool_genesis_payload.GenesisPayload } {
    const members = [_]pool_topology.Member{.{
        .member_id = @splat(0x20),
        .slot = 7,
        .control_role = pool_topology.voter_role,
        .role_flags = member_format.known_role_flags,
    }};
    const payload: pool_genesis_payload.GenesisPayload = .{
        .topology = try pool_topology.Topology.init(@splat(0x10), 1, @splat(0), &members),
        .layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024),
    };
    var header = testHeader();
    header.incompat_features = member_format.dynamic_pool_incompat_feature;
    header.set_id = payload.topology.set_id;
    header.member_id = members[0].member_id;
    header.member_slot = members[0].slot;
    header.member_count = 1;
    header.layout_format_version = member_format.dynamic_layout_format_version;
    header.genesis_topology_digest = try pool_topology.digest(payload.topology);
    return .{ header, payload };
}

fn testJoiningCreate() !struct { member_format.Header, control_record.Record } {
    const members = [_]pool_topology.Member{
        .{
            .member_id = @splat(0x30),
            .slot = 3,
            .control_role = pool_topology.voter_role,
            .role_flags = member_format.known_role_flags,
        },
        .{ .member_id = @splat(0x20), .slot = 19, .state = .joining },
    };
    const evidence: member_bootstrap.Evidence = .{
        .target_member_id = @splat(0x20),
        .target_slot = 19,
        .topology = try pool_topology.Topology.init(@splat(0x10), 2, @splat(0x33), &members),
        .layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024),
    };
    var header = testHeader();
    header.incompat_features = member_format.dynamic_pool_incompat_feature;
    header.set_id = evidence.topology.set_id;
    header.member_id = evidence.target_member_id;
    header.member_slot = evidence.target_slot;
    header.member_count = evidence.topology.member_count;
    header.role_flags = member_format.data_role;
    header.layout_format_version = member_format.dynamic_layout_format_version;
    header.genesis_topology_digest = try pool_topology.digest(evidence.topology);
    var record: control_record.Record = .{
        .kind = control_record.member_bootstrap_kind,
        .local_sequence = 1,
        .membership_epoch = evidence.topology.epoch,
        .writer_term = 1,
        .generation = 1,
        .set_id = evidence.topology.set_id,
        .member_id = evidence.target_member_id,
        .mount_session_id = @splat(0),
        .transaction_id = @splat(0x44),
        .previous_record_digest = @splat(0),
        .previous_history_digest = @splat(0x55),
        .data_root_digest = @splat(0x66),
        .topology_digest = try pool_topology.digest(evidence.topology),
        .layout_digest = try pool_layout.digest(evidence.layout),
        .payload = try member_bootstrap.makePayload(evidence),
    };
    record.history_digest = try control_record.historyDigest(record);
    return .{ header, record };
}

fn createRawMember(dir: Io.Dir, name: []const u8, a: member_format.Header, b: member_format.Header, length: u64) !void {
    const file = try dir.createFile(std.testing.io, name, .{ .read = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &(try member_format.encode(a)), 0);
    try file.writePositionalAll(std.testing.io, &(try member_format.encode(b)), member_format.encoded_size);
    try file.setLength(std.testing.io, length);
}

fn corruptByte(dir: Io.Dir, name: []const u8, offset: u64) !void {
    const file = try dir.openFile(std.testing.io, name, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &.{0xff}, offset);
}

const common_create_fault_points = [_]CreateFaultPoint{
    .extent_sync,
    .genesis_write,
    .genesis_sync,
    .header_b_write,
    .header_b_sync,
    .header_a_write,
    .header_a_sync,
};

const linux_create_fault_points = common_create_fault_points ++ [_]CreateFaultPoint{.parent_sync};

fn expectedCreateFaultPoints() []const CreateFaultPoint {
    return if (builtin.os.tag == .linux) &linux_create_fault_points else &common_create_fault_points;
}

test "storage entry points format and reopen a member" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try testCreateHeader(0);

    const storage = try Storage.createFile(std.testing.io, tmp.dir, "storage-member", header.member_bytes);
    var created = try Member.createStorage(std.testing.io, storage, header, testCreatePayload(), .{});
    try std.testing.expectEqual(header.member_id, created.header().member_id);
    try created.close();

    const reopened_storage = try Storage.openFile(std.testing.io, tmp.dir, "storage-member", false);
    var reopened = try Member.openStorage(std.testing.io, reopened_storage, .read_only);
    defer reopened.deinit();
    try std.testing.expectEqual(header.member_id, reopened.header().member_id);
    try std.testing.expectEqual(OpenMode.read_only, reopened.mode());
}

test "block storage permits unused physical tail capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try testCreateHeader(0);
    const physical_capacity = header.member_bytes + 4096;

    const file = try tmp.dir.createFile(std.testing.io, "block-storage", .{ .read = true });
    try file.setLength(std.testing.io, physical_capacity);
    const storage = Storage.initOwned(file, physical_capacity, .linux_block_device, 4096, false);
    var created = try Member.createStorage(std.testing.io, storage, header, testCreatePayload(), .{});
    try created.close();

    const reopened_file = try tmp.dir.openFile(std.testing.io, "block-storage", .{ .mode = .read_only });
    const reopened_storage = Storage.initOwned(reopened_file, physical_capacity, .linux_block_device, 4096, false);
    var reopened = try Member.openStorage(std.testing.io, reopened_storage, .read_only);
    defer reopened.deinit();
    try std.testing.expectEqual(header.member_bytes, reopened.header().member_bytes);
}

test "create publishes genesis then B then A with exact durability stages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try testCreateHeader(0);
    var fault: CreateFaultController = .{};
    var member = try createAt(std.testing.io, tmp.dir, "member", header, testCreatePayload(), .{ .fault = &fault });
    try std.testing.expectEqualSlices(CreateFaultPoint, expectedCreateFaultPoints(), fault.events());
    try std.testing.expectEqual(SourceSlot.a, member.source());
    try std.testing.expect(!member.redundancyDegraded());
    try std.testing.expect(!member.dirty);

    var raw_genesis: [control_record.encoded_size]u8 = undefined;
    try member.read(.control, 0, &raw_genesis);
    const genesis = try control_record.decode(&raw_genesis);
    _ = try genesis_payload_format.validateRecord(genesis);
    try std.testing.expectEqualSlices(u8, &header.member_id, &genesis.member_id);
    try member.close();

    var reopened = try openAt(std.testing.io, tmp.dir, "member", .writable);
    try std.testing.expectEqual(SourceSlot.a, reopened.source());
    try std.testing.expect(!reopened.redundancyDegraded());
    try reopened.close();
}

test "dynamic create publishes pool genesis with the same durability order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try testPoolCreate();
    var fault: CreateFaultController = .{};
    var member = try createPoolAt(std.testing.io, tmp.dir, "pool-member", input[0], input[1], .{ .fault = &fault });
    defer member.deinit();
    try std.testing.expectEqualSlices(CreateFaultPoint, expectedCreateFaultPoints(), fault.events());
    var raw: [control_record.encoded_size]u8 = undefined;
    try member.read(.control, 0, &raw);
    _ = try pool_genesis_payload.validateRecord(try control_record.decode(&raw));
}

test "joining create publishes target bootstrap as its first record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try testJoiningCreate();
    var member = try createJoiningAt(std.testing.io, tmp.dir, "joining-member", input[0], input[1], .{});
    defer member.deinit();
    var raw: [control_record.encoded_size]u8 = undefined;
    try member.read(.control, 0, &raw);
    _ = try member_bootstrap.validateTargetFirstRecord(input[0], try control_record.decode(&raw));
}

test "create faults retain files with publication-state recovery" {
    inline for (std.meta.tags(CreateFaultPoint)) |point| {
        inline for (std.meta.tags(CreateFaultAction)) |action| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const header = try testCreateHeader(0);
            var fault: CreateFaultController = .{ .fail = .{ .point = point, .action = action } };
            if (builtin.os.tag != .linux and point == .parent_sync) {
                var member = try createAt(
                    std.testing.io,
                    tmp.dir,
                    "member",
                    header,
                    testCreatePayload(),
                    .{ .fault = &fault },
                );
                try std.testing.expectEqualSlices(CreateFaultPoint, expectedCreateFaultPoints(), fault.events());
                try member.close();
            } else {
                try std.testing.expectError(
                    error.InjectedCreateFault,
                    createAt(std.testing.io, tmp.dir, "member", header, testCreatePayload(), .{ .fault = &fault }),
                );

                const retained = try tmp.dir.openFile(std.testing.io, "member", .{});
                retained.close(std.testing.io);
                const no_header = point == .extent_sync or point == .genesis_write or point == .genesis_sync or
                    (point == .header_b_write and action != .after);
                if (no_header) {
                    try std.testing.expectError(
                        error.NoValidMemberHeader,
                        openAt(std.testing.io, tmp.dir, "member", .read_only),
                    );
                } else {
                    var reopened = try openAt(std.testing.io, tmp.dir, "member", .read_only);
                    const only_b = point == .header_b_write or point == .header_b_sync or
                        (point == .header_a_write and action != .after);
                    try std.testing.expectEqual(only_b, reopened.redundancyDegraded());
                    try std.testing.expectEqual(if (only_b) SourceSlot.b else SourceSlot.a, reopened.source());
                    try reopened.close();
                }
            }
        }
    }
}

test "create rejects invalid input before creation and preserves existing paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testCreatePayload();
    const header = try testCreateHeader(0);

    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b" }) |name|
        try std.testing.expectError(error.InvalidBasename, createAt(std.testing.io, tmp.dir, name, header, payload, .{}));

    const existing = try tmp.dir.createFile(std.testing.io, "existing", .{ .read = true });
    try existing.writePositionalAll(std.testing.io, "sentinel", 0);
    existing.close(std.testing.io);
    try std.testing.expectError(
        error.PathAlreadyExists,
        createAt(std.testing.io, tmp.dir, "existing", header, payload, .{}),
    );
    const sentinel = try tmp.dir.openFile(std.testing.io, "existing", .{});
    defer sentinel.close(std.testing.io);
    var actual: [8]u8 = undefined;
    try std.testing.expectEqual(actual.len, try sentinel.readPositionalAll(std.testing.io, &actual, 0));
    try std.testing.expectEqualSlices(u8, "sentinel", &actual);

    var sequence = header;
    sequence.header_sequence = 2;
    try std.testing.expectError(
        error.InvalidInitialHeaderSequence,
        createAt(std.testing.io, tmp.dir, "sequence", sequence, payload, .{}),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "sequence", .{}));

    var checkpoint = header;
    checkpoint.checkpoint_offset = header.control.offset;
    checkpoint.checkpoint_record_sequence = 1;
    checkpoint.checkpoint_record_digest = @splat(1);
    try std.testing.expectError(
        error.InvalidInitialCheckpoint,
        createAt(std.testing.io, tmp.dir, "checkpoint", checkpoint, payload, .{}),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "checkpoint", .{}));

    var wrong_member = header;
    wrong_member.member_id = payload.topology.members[1].member_id;
    try std.testing.expectError(
        error.MemberHeaderMismatch,
        createAt(std.testing.io, tmp.dir, "identity", wrong_member, payload, .{}),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "identity", .{}));

    var wrong_chunk = header;
    wrong_chunk.chunk_size = 2 * 1024 * 1024;
    wrong_chunk.data.length = wrong_chunk.chunk_size;
    wrong_chunk.member_bytes = wrong_chunk.data.offset + wrong_chunk.data.length;
    try std.testing.expectError(
        error.ChunkSizeMismatch,
        createAt(std.testing.io, tmp.dir, "chunk", wrong_chunk, payload, .{}),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "chunk", .{}));

    var too_large = header;
    too_large.data.length = @as(u64, std.math.maxInt(i64)) + 1;
    too_large.member_bytes = too_large.data.offset + too_large.data.length;
    try std.testing.expectError(
        error.MemberTooLarge,
        createAt(std.testing.io, tmp.dir, "large", too_large, payload, .{}),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "large", .{}));
}

test "open selects independent headers and enforces policy and exact length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);

    var member = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    try std.testing.expectEqual(SourceSlot.a, member.source());
    try std.testing.expect(!member.redundancyDegraded());
    try std.testing.expectEqual(OpenMode.read_only, member.mode());
    try member.close();

    var newer = header;
    newer.header_sequence = 2;
    try createRawMember(tmp.dir, "member", header, newer, header.member_bytes);
    member = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    try std.testing.expectEqual(SourceSlot.b, member.source());
    try member.close();

    try corruptByte(tmp.dir, "member", member_format.encoded_size);
    member = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    try std.testing.expectEqual(SourceSlot.a, member.source());
    try std.testing.expect(member.redundancyDegraded());
    try member.close();

    try createRawMember(tmp.dir, "member", header, newer, header.member_bytes);
    try corruptByte(tmp.dir, "member", 0);
    member = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    try std.testing.expectEqual(SourceSlot.b, member.source());
    try std.testing.expect(member.redundancyDegraded());
    try member.close();

    var conflict = header;
    conflict.member_slot = 1;
    try createRawMember(tmp.dir, "member", header, conflict, header.member_bytes);
    try std.testing.expectError(error.ConflictingMemberHeaders, openAt(std.testing.io, tmp.dir, "member", .read_only));

    var ambiguous = header;
    ambiguous.checkpoint_offset = header.control.offset;
    ambiguous.checkpoint_record_sequence = 2;
    ambiguous.checkpoint_record_digest = @splat(1);
    try createRawMember(tmp.dir, "member", header, ambiguous, header.member_bytes);
    try std.testing.expectError(error.AmbiguousMemberHeader, openAt(std.testing.io, tmp.dir, "member", .read_only));

    try createRawMember(tmp.dir, "member", header, header, header.member_bytes - 1);
    try std.testing.expectError(error.TruncatedMember, openAt(std.testing.io, tmp.dir, "member", .read_only));
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes + 1);
    try std.testing.expectError(error.UnexpectedMemberLength, openAt(std.testing.io, tmp.dir, "member", .read_only));

    var unsupported = header;
    unsupported.metadata_format_version = 2;
    try createRawMember(tmp.dir, "member", unsupported, unsupported, unsupported.member_bytes);
    try std.testing.expectError(error.UnsupportedMetadataFormat, openAt(std.testing.io, tmp.dir, "member", .read_only));
    unsupported = header;
    unsupported.incompat_features = 1 << 4;
    try createRawMember(tmp.dir, "member", unsupported, unsupported, unsupported.member_bytes);
    try std.testing.expectError(error.UnsupportedIncompatFeature, openAt(std.testing.io, tmp.dir, "member", .read_only));
    unsupported = header;
    unsupported.ro_compat_features = 1;
    try createRawMember(tmp.dir, "member", unsupported, unsupported, unsupported.member_bytes);
    member = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    try member.close();
    try std.testing.expectError(error.UnsupportedReadOnlyFeature, openAt(std.testing.io, tmp.dir, "member", .writable));
}

test "redundant checkpoint publication persists the same anchor in both headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var header = try testCreateHeader(0);
    header.control.length = 4 * 4096;
    const payload = testCreatePayload();
    var member = try createAt(std.testing.io, tmp.dir, "anchor", header, payload, .{});
    try member.publishCheckpoint(header.control.offset + 4096, 2, @splat(0x44));
    try std.testing.expect(!member.checkpointReclaimReady());
    try member.close();

    member = try openAt(std.testing.io, tmp.dir, "anchor", .writable);
    try std.testing.expect(!member.checkpointReclaimReady());
    try member.publishCheckpointRedundant(header.control.offset + 8192, 3, @splat(0x55));
    try std.testing.expect(member.checkpointReclaimReady());
    try std.testing.expectEqual(SourceSlot.a, member.source());
    try member.close();

    member = try openAt(std.testing.io, tmp.dir, "anchor", .read_only);
    defer member.deinit();
    try std.testing.expect(!member.checkpointReclaimReady());
    try std.testing.expectEqual(@as(u64, header.control.offset + 8192), member.header().checkpoint_offset);
    try std.testing.expectEqual(@as(u64, 3), member.header().checkpoint_record_sequence);
    const expected_digest: codec.Digest = @splat(0x55);
    try std.testing.expectEqualSlices(u8, &expected_digest, &member.header().checkpoint_record_digest);
}

test "interrupted redundant publication never reports a reclaim barrier" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var header = try testCreateHeader(0);
    header.control.length = 4 * 4096;
    const payload = testCreatePayload();
    var member = try createAt(std.testing.io, tmp.dir, "anchor-fault", header, payload, .{});
    try member.publishCheckpointRedundant(header.control.offset + 4096, 2, @splat(0x33));
    try std.testing.expect(member.checkpointReclaimReady());
    var fault: FaultController = .{ .fail_write_at = 1 };
    member.setFaultController(&fault);
    try std.testing.expectError(
        error.InjectedFault,
        member.publishCheckpointRedundant(header.control.offset + 8192, 3, @splat(0x44)),
    );
    try std.testing.expect(!member.checkpointReclaimReady());
    member.deinit();

    member = try openAt(std.testing.io, tmp.dir, "anchor-fault", .read_only);
    defer member.deinit();
    try std.testing.expect(!member.checkpointReclaimReady());
    try std.testing.expectEqual(@as(u64, header.control.offset + 8192), member.header().checkpoint_offset);
}

test "open rejects invalid basenames and invalid or short header pairs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b" }) |name|
        try std.testing.expectError(error.InvalidBasename, openAt(std.testing.io, tmp.dir, name, .read_only));

    const file = try tmp.dir.createFile(std.testing.io, "bad", .{ .read = true });
    try file.setLength(std.testing.io, 2 * member_format.encoded_size);
    file.close(std.testing.io);
    try std.testing.expectError(error.NoValidMemberHeader, openAt(std.testing.io, tmp.dir, "bad", .read_only));

    const header = testHeader();
    try createRawMember(tmp.dir, "short", header, header, member_format.encoded_size + 100);
    try std.testing.expectError(error.TruncatedMember, openAt(std.testing.io, tmp.dir, "short", .read_only));
}

test "lock matrix permits shared readers and excludes writers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);

    var first = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    defer first.deinit();
    var second = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    try std.testing.expectError(error.WouldBlock, openAt(std.testing.io, tmp.dir, "member", .writable));
    try second.close();
    try first.close();

    var writer = try openAt(std.testing.io, tmp.dir, "member", .writable);
    defer writer.deinit();
    try std.testing.expectError(error.WouldBlock, openAt(std.testing.io, tmp.dir, "member", .read_only));
    try std.testing.expectError(error.WouldBlock, openAt(std.testing.io, tmp.dir, "member", .writable));
}

test "region IO accepts boundaries and rejects crossings without touching sentinels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
    var member = try openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();

    inline for (std.meta.tags(RegionKind)) |kind| {
        const region = switch (kind) {
            .control => header.control,
            .metadata => header.metadata,
            .data => header.data,
        };
        try member.write(kind, 0, &.{0x11});
        try member.write(kind, region.length - 1, &.{0x22});
        try member.write(kind, region.length, &.{});
        var first: [1]u8 = undefined;
        var last: [1]u8 = undefined;
        try member.read(kind, 0, &first);
        try member.read(kind, region.length - 1, &last);
        try member.read(kind, region.length, &.{});
        try std.testing.expectEqual(@as(u8, 0x11), first[0]);
        try std.testing.expectEqual(@as(u8, 0x22), last[0]);
        try std.testing.expectError(error.RegionOutOfBounds, member.write(kind, region.length, &.{1}));
        var crossing: [2]u8 = undefined;
        try std.testing.expectError(error.RegionOutOfBounds, member.read(kind, region.length - 1, &crossing));
        try std.testing.expectError(error.RegionOutOfBounds, member.read(kind, std.math.maxInt(u64), &.{}));
    }
    try member.close();

    const raw = try tmp.dir.openFile(std.testing.io, "member", .{});
    defer raw.close(std.testing.io);
    var sentinels: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try raw.readPositionalAll(std.testing.io, &sentinels, header.control.offset + header.control.length));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, &sentinels);
}

test "read-only and closed members reject mutations and IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
    var member = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    try std.testing.expectError(error.ReadOnlyMember, member.write(.control, 0, &.{1}));
    try std.testing.expectError(error.ReadOnlyMember, member.sync());
    try member.close();
    try member.close();
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.MemberClosed, member.read(.control, 0, &byte));
    try std.testing.expectError(error.MemberClosed, member.write(.control, 0, &.{1}));
    try std.testing.expectError(error.MemberClosed, member.sync());
}

test "empty writes validate lifecycle without dirtying or consuming faults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
    var member = try openAt(std.testing.io, tmp.dir, "member", .writable);
    var fault: FaultController = .{ .fail_write_at = 0, .fail_sync_at = 0 };
    member.setFaultController(&fault);

    try member.write(.control, header.control.length, &.{});
    try std.testing.expect(!member.isFrozen());
    try std.testing.expectEqual(@as(u64, 0), fault.write_count);
    try std.testing.expectEqual(@as(u64, 0), fault.sync_count);
    try std.testing.expectError(error.RegionOutOfBounds, member.write(.control, header.control.length + 1, &.{}));
    try std.testing.expectEqual(@as(u64, 0), fault.write_count);
    try member.close();
    try std.testing.expectEqual(@as(u64, 0), fault.sync_count);

    var reopened = try openAt(std.testing.io, tmp.dir, "member", .writable);
    try reopened.close();
    try std.testing.expectError(error.MemberClosed, member.write(.control, 0, &.{}));
}

test "durable write batches prevalidate ranges and use one sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
    var member = try openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    var fault: FaultController = .{};
    member.setFaultController(&fault);

    var claim = try member.claimCatalog();
    try std.testing.expectError(error.RegionOutOfBounds, claim.writeBatchDurable(&.{
        .{ .offset = 0, .bytes = &.{1} },
        .{ .offset = header.metadata.length, .bytes = &.{2} },
    }));
    try std.testing.expectEqual(@as(u64, 0), fault.write_count);
    try std.testing.expectEqual(@as(u64, 0), fault.sync_count);

    try claim.writeBatchDurable(&.{
        .{ .offset = 0, .bytes = &.{ 1, 2 } },
        .{ .offset = 8, .bytes = &.{ 3, 4 } },
    });
    try std.testing.expectEqual(@as(u64, 2), fault.write_count);
    try std.testing.expectEqual(@as(u64, 1), fault.sync_count);
    var first: [2]u8 = undefined;
    var second: [2]u8 = undefined;
    try member.read(.metadata, 0, &first);
    try member.read(.metadata, 8, &second);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &first);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, &second);

    const stale_claim = claim;
    try std.testing.expectError(error.CatalogClaimed, member.write(.metadata, 16, &.{1}));
    try claim.writeBatchDurable(&.{.{ .offset = 16, .bytes = &.{5} }});
    try claim.release();
    var next_claim = try member.claimCatalog();
    try std.testing.expectError(
        error.InvalidCatalogClaim,
        stale_claim.writeBatchDurable(&.{.{ .offset = 24, .bytes = &.{6} }}),
    );
    try next_claim.release();
    member.catalog_claim_sequence.store(std.math.maxInt(u64), .release);
    try std.testing.expectError(error.CatalogClaimSequenceExhausted, member.claimCatalog());
    try std.testing.expectError(error.CatalogClaimSequenceExhausted, member.claimCatalog());
    try std.testing.expectEqual(@as(u64, 3), fault.write_count);
    try std.testing.expectEqual(@as(u64, 2), fault.sync_count);
}

test "data claims fence ordinary writers and reject stale owners" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
    var member = try openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();

    var catalog_claim = try member.claimCatalog();
    var data_claim = try member.claimData();
    try std.testing.expectError(error.DataAlreadyClaimed, member.claimData());
    try std.testing.expectError(error.DataClaimed, member.write(.data, 0, "ordinary"));
    try std.testing.expectError(error.DataClaimed, member.writeDurable(.data, 0, "ordinary"));
    try std.testing.expectError(error.DataClaimed, member.sync());
    try catalog_claim.writeBatchDurable(&.{.{ .offset = 0, .bytes = "metadata" }});
    try catalog_claim.release();
    try std.testing.expectError(error.DataClaimed, member.close());

    try data_claim.write(0, "claimed");
    try data_claim.writeMany(&.{
        .{ .offset = 8, .bytes = "batch-a" },
        .{ .offset = 16, .bytes = "batch-b" },
    });
    try data_claim.sync();
    const stale_claim = data_claim;
    try data_claim.release();
    var next_claim = try member.claimData();
    try std.testing.expectError(error.InvalidDataClaim, stale_claim.write(8, "stale"));
    try std.testing.expectError(
        error.InvalidDataClaim,
        stale_claim.writeMany(&.{.{ .offset = 24, .bytes = "stale" }}),
    );
    try next_claim.release();
    var actual: [7]u8 = undefined;
    try member.read(.data, 0, &actual);
    try std.testing.expectEqualStrings("claimed", &actual);
    var batch_actual: [7]u8 = undefined;
    try member.read(.data, 8, &batch_actual);
    try std.testing.expectEqualStrings("batch-a", &batch_actual);

    member.fenceUnleasedCatalogWrites();
    try std.testing.expectError(error.DataGenerationLeaseRequired, member.write(.data, 0, "unleased"));
    try std.testing.expectError(error.DataGenerationLeaseRequired, member.sync());
    var leased_claim = try member.claimData();
    try leased_claim.write(0, "leased");
    try leased_claim.sync();
    try leased_claim.release();

    member.data_claim_sequence.store(std.math.maxInt(u64), .release);
    try std.testing.expectError(error.DataClaimSequenceExhausted, member.claimData());
    try std.testing.expectError(error.DataClaimSequenceExhausted, member.claimData());
}

test "catalog mode persists across standalone reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try testPoolCreate();
    var member = try createPoolAt(std.testing.io, tmp.dir, "member", input[0], input[1], .{});

    var catalog_claim = try member.claimCatalog();
    try catalog_claim.activateCatalogData();
    try catalog_claim.release();
    try std.testing.expect(member_format.hasCatalogData(member.header()));
    try std.testing.expectError(error.CatalogClaimRequired, member.write(.metadata, 0, "stale"));
    try std.testing.expectError(error.DataGenerationLeaseRequired, member.write(.data, 0, "stale"));
    try member.close();

    var reopened = try openAt(std.testing.io, tmp.dir, "member", .writable);
    defer reopened.deinit();
    try std.testing.expect(member_format.hasCatalogData(reopened.header()));
    try std.testing.expectError(error.CatalogClaimRequired, reopened.writeDurable(.metadata, 0, "stale"));
    try std.testing.expectError(error.DataGenerationLeaseRequired, reopened.writeDurable(.data, 0, "stale"));

    var reopened_catalog_claim = try reopened.claimCatalog();
    try reopened_catalog_claim.writeBatchDurable(&.{.{ .offset = 0, .bytes = "catalog" }});
    try reopened_catalog_claim.release();
    var reopened_data_claim = try reopened.claimData();
    try reopened_data_claim.write(0, "leased");
    try reopened_data_claim.sync();
    try reopened_data_claim.release();
}

test "Blob member catalog activation fails without changing writable state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input = try testPoolCreate();
    input[0].incompat_features |= member_format.blob_filesystem_incompat_feature;
    var member = try createPoolAt(std.testing.io, tmp.dir, "member", input[0], input[1], .{});
    defer member.deinit();

    const original_header = member.header();
    const original_source = member.source();
    const original_degraded = member.redundancyDegraded();
    var header_a_before: [member_format.encoded_size]u8 = undefined;
    var header_b_before: [member_format.encoded_size]u8 = undefined;
    _ = try member.storage.readAt(std.testing.io, &header_a_before, 0);
    _ = try member.storage.readAt(std.testing.io, &header_b_before, member_format.encoded_size);

    var claim = try member.claimCatalog();
    try std.testing.expectError(error.BlobFilesystemCatalogDataConflict, claim.activateCatalogData());
    try claim.release();

    try std.testing.expect(!member.catalog_mode_active.load(.acquire));
    try std.testing.expectEqual(member_format.OpenMode.writable, member.mode());
    try std.testing.expect(!member.isFrozen());
    try std.testing.expectEqualDeep(original_header, member.header());
    try std.testing.expectEqual(original_source, member.source());
    try std.testing.expectEqual(original_degraded, member.redundancyDegraded());
    var header_a_after: [member_format.encoded_size]u8 = undefined;
    var header_b_after: [member_format.encoded_size]u8 = undefined;
    _ = try member.storage.readAt(std.testing.io, &header_a_after, 0);
    _ = try member.storage.readAt(std.testing.io, &header_b_after, member_format.encoded_size);
    try std.testing.expectEqualSlices(u8, &header_a_before, &header_a_after);
    try std.testing.expectEqualSlices(u8, &header_b_before, &header_b_after);
    try member.write(.metadata, 0, "metadata");
    try member.write(.data, 0, "data");
    try member.sync();
}

test "catalog mode survives interruption after the first header sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const input = try testPoolCreate();
    var member = try createPoolAt(std.testing.io, tmp.dir, "member", input[0], input[1], .{});
    var fault: FaultController = .{ .fail_sync_after_at = 0 };
    member.setFaultController(&fault);
    var claim = try member.claimCatalog();
    try std.testing.expectError(error.InjectedFault, claim.activateCatalogData());
    try claim.release();
    member.deinit();

    var reopened = try openAt(std.testing.io, tmp.dir, "member", .writable);
    try std.testing.expect(reopened.redundancyDegraded());
    try std.testing.expect(member_format.hasCatalogData(reopened.header()));
    try std.testing.expectError(error.CatalogClaimRequired, reopened.write(.metadata, 0, "stale"));
    try std.testing.expectError(error.DataGenerationLeaseRequired, reopened.write(.data, 0, "stale"));
    var repair_claim = try reopened.claimCatalog();
    try repair_claim.activateCatalogData();
    try repair_claim.release();
    try std.testing.expect(!reopened.redundancyDegraded());
    try reopened.close();

    try corruptByte(tmp.dir, "member", member_format.encoded_size);
    var recovered = try openAt(std.testing.io, tmp.dir, "member", .writable);
    defer recovered.deinit();
    try std.testing.expect(member_format.hasCatalogData(recovered.header()));
    try std.testing.expectError(error.CatalogClaimRequired, recovered.write(.metadata, 0, "stale"));
    try std.testing.expectError(error.DataGenerationLeaseRequired, recovered.write(.data, 0, "stale"));
}

test "region reads report truncation exactly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
    var member = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    defer member.deinit();

    const raw = try tmp.dir.openFile(std.testing.io, "member", .{ .mode = .read_write });
    try raw.setLength(std.testing.io, header.member_bytes - 1);
    raw.close(std.testing.io);
    var bytes: [2]u8 = undefined;
    try std.testing.expectError(error.TruncatedMember, member.read(.data, header.data.length - bytes.len, &bytes));
}

test "write faults freeze writes while preserving reads" {
    inline for (.{ FaultAction.before, FaultAction.partial, FaultAction.after }) |action| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const header = testHeader();
        try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
        var member = try openAt(std.testing.io, tmp.dir, "member", .writable);
        defer member.deinit();
        var fault: FaultController = .{};
        switch (action) {
            .before => fault.fail_write_at = 0,
            .partial => fault.fail_write_partial_at = 0,
            .after => fault.fail_write_after_at = 0,
            .none => unreachable,
        }
        member.setFaultController(&fault);
        try std.testing.expectError(error.InjectedFault, member.write(.data, 0, &.{ 1, 2, 3, 4 }));
        try std.testing.expect(member.isFrozen());
        try std.testing.expectError(error.WriteFrozen, member.write(.data, 0, &.{1}));
        try std.testing.expectError(error.WriteFrozen, member.write(.data, 0, &.{}));
        try std.testing.expectError(error.WriteFrozen, member.sync());
        var byte: [1]u8 = undefined;
        try member.read(.data, 0, &byte);
        try std.testing.expectError(error.WriteFrozen, member.close());
        try member.close();
    }
}

test "sync faults freeze and close always releases the lock" {
    inline for (.{ FaultAction.before, FaultAction.after }) |action| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const header = testHeader();
        try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
        var member = try openAt(std.testing.io, tmp.dir, "member", .writable);
        var fault: FaultController = .{};
        switch (action) {
            .before => fault.fail_sync_at = 0,
            .after => fault.fail_sync_after_at = 0,
            else => unreachable,
        }
        member.setFaultController(&fault);
        try member.write(.control, 0, &.{1});
        try std.testing.expectError(error.InjectedFault, member.sync());
        try std.testing.expect(member.isFrozen());
        try std.testing.expectError(error.WriteFrozen, member.close());
        try member.close();

        var reopened = try openAt(std.testing.io, tmp.dir, "member", .writable);
        try reopened.close();
    }
}

test "dirty close syncs and sync failure still closes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
    var member = try openAt(std.testing.io, tmp.dir, "member", .writable);
    var fault: FaultController = .{ .fail_sync_at = 0 };
    member.setFaultController(&fault);
    try member.write(.metadata, 0, &.{1});
    try std.testing.expectError(error.InjectedFault, member.close());
    try std.testing.expect(member.isClosed());
    try member.close();

    var reopened = try openAt(std.testing.io, tmp.dir, "member", .writable);
    try reopened.write(.metadata, 1, &.{2});
    try reopened.close();
    try std.testing.expectEqual(@as(u64, 1), fault.sync_count);
}

fn durableWriteWorker(member: *Member) !void {
    try member.writeDurable(.control, 0, &.{ 1, 2, 3, 4 });
}

fn closeWorker(member: *Member, started: *std.atomic.Value(bool)) !void {
    started.store(true, .release);
    try member.close();
}

test "durable write excludes close through write and sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = testHeader();
    try createRawMember(tmp.dir, "member", header, header, header.member_bytes);
    var member = try openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();

    var pause: FaultPause = .{};
    var fault: FaultController = .{ .pause_after_write = &pause };
    member.setFaultController(&fault);
    defer pause.released.store(true, .release);
    var write_future = try std.testing.io.concurrent(durableWriteWorker, .{&member});
    var write_pending = true;
    defer if (write_pending) {
        _ = write_future.cancel(std.testing.io) catch {};
    };
    while (!pause.reached.load(.acquire)) try std.Thread.yield();

    var close_started: std.atomic.Value(bool) = .init(false);
    var close_future = try std.testing.io.concurrent(closeWorker, .{ &member, &close_started });
    var close_pending = true;
    defer if (close_pending) {
        _ = close_future.cancel(std.testing.io) catch {};
    };
    while (!close_started.load(.acquire) or member.mutex.mutex.state.load(.acquire) != .contended)
        try std.Thread.yield();
    try std.testing.expect(!member.isClosed());

    pause.released.store(true, .release);
    try write_future.await(std.testing.io);
    write_pending = false;
    try close_future.await(std.testing.io);
    close_pending = false;
    try std.testing.expect(member.isClosed());

    const raw = try tmp.dir.openFile(std.testing.io, "member", .{});
    defer raw.close(std.testing.io);
    var actual: [4]u8 = undefined;
    try std.testing.expectEqual(actual.len, try raw.readPositionalAll(std.testing.io, &actual, header.control.offset));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &actual);
}
