const std = @import("std");

const protocol = @import("zettide_data_service_contracts");
const write_participant_manager = @import("write_participant_manager.zig");
const replica_rpc_client = @import("replica_rpc_client.zig");
const replica_io_gate = @import("replica_io_gate.zig");

const coordinator = protocol.write_coordinator;
const write_service = protocol.write_service;

pub const max_endpoint_len: usize = 255;
const catalog_basename = "coordinator-catalog.state";
const marker_basename = "coordinator-catalog.required";
const lock_basename = "coordinator-catalog.state.lock";
const marker_magic = "ZETCREQ1".*;
const magic = "ZETCCAT1".*;
const version: u16 = 1;
const header_size: usize = 24;
const checksum_size: usize = 4;
const max_records: usize = 16 * 1024;
const route_encoded_size: usize = 88 + 48 + 3 * 96 + 32 + 16 + 2 + max_endpoint_len;
const record_encoded_size: usize = 16 + 1 + 7 + 3 * route_encoded_size;
const max_catalog_size: usize = header_size + max_records * record_encoded_size + checksum_size;
const journal_prefix = "coordinator-";
const journal_suffix = ".state";
const journal_name_len = journal_prefix.len + 32 + 1 + 16 + journal_suffix.len;

pub const OutboundTargetKey = struct {
    node_id: protocol.Id,
    key: [32]u8,
};

pub const ReplicaRoute = struct {
    binding: write_service.ParticipantBinding,
    backend_digest: protocol.Digest,
    node_id: protocol.Id,
    endpoint_len: u16,
    endpoint_bytes: [max_endpoint_len]u8,

    pub fn init(
        binding: write_service.ParticipantBinding,
        backend_digest: protocol.Digest,
        node_id: protocol.Id,
        replica_endpoint: []const u8,
    ) !ReplicaRoute {
        if (replica_endpoint.len == 0 or replica_endpoint.len > max_endpoint_len or std.mem.indexOfScalar(u8, replica_endpoint, 0) != null)
            return error.InvalidReplicaEndpoint;
        var result: ReplicaRoute = .{
            .binding = binding,
            .backend_digest = backend_digest,
            .node_id = node_id,
            .endpoint_len = @intCast(replica_endpoint.len),
            .endpoint_bytes = @splat(0),
        };
        @memcpy(result.endpoint_bytes[0..replica_endpoint.len], replica_endpoint);
        return result;
    }

    pub fn endpoint(self: *const ReplicaRoute) []const u8 {
        return self.endpoint_bytes[0..self.endpoint_len];
    }
};

pub const CoordinatorTopology = struct {
    local_member_id: protocol.Id,
    routes: [3]ReplicaRoute,
};

pub const CoordinateRequest = struct {
    authority: protocol.AuthorityBinding,
    transaction_id: protocol.Id,
    offset_bytes: u64,
    data: []const u8,
};

const Key = struct {
    placement_id: protocol.Id,
    generation: u64,
};

const CatalogRecord = struct {
    topology: CoordinatorTopology,
    armed: bool = false,
};

const Entry = struct {
    record_index: usize,
    basename: []u8,
    store: *coordinator.FileStore,
    instance: *coordinator.Coordinator,
};

const CatalogInitialization = struct {
    records: []CatalogRecord,
    marker_recovery_required: bool,
};

pub const ControlGuard = struct {
    manager: *WriteCoordinatorManager,
    pub fn end(self: *ControlGuard) void {
        self.manager.mutex.unlock(self.manager.io);
        self.* = undefined;
    }
};

/// Durable internal write coordinator. Payload execution is exposed only as a
/// process-local API; the management listener remains metadata-only.
pub const WriteCoordinatorManager = struct {
    pub const Faults = struct {
        fail_catalog_file_sync_once: bool = false,
        fail_catalog_rename_once: bool = false,
        fail_directory_sync_once: bool = false,
        fail_journal_creation_once: bool = false,
        fail_remote_prepare_before_request_once: bool = false,
        lose_remote_prepare_response_once: bool = false,
        lose_remote_commit_response_once: bool = false,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    participants: *write_participant_manager.WriteParticipantManager,
    local_signer: ?*const protocol.write_evidence.Signer,
    local_identity: write_service.WitnessIdentity,
    outbound_keys: []OutboundTargetKey,
    lock_file: std.Io.File,
    mutex: std.Io.Mutex = .init,
    records: []CatalogRecord = &.{},
    entries: std.AutoHashMapUnmanaged(Key, *Entry) = .empty,
    poisoned: bool = false,
    faults: ?*Faults = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        participants: *write_participant_manager.WriteParticipantManager,
        local_identity: write_service.WitnessIdentity,
        outbound_keys: []const OutboundTargetKey,
    ) !WriteCoordinatorManager {
        return initInternal(allocator, io, parent, participants, null, local_identity, outbound_keys);
    }

    pub fn initWithSigner(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        participants: *write_participant_manager.WriteParticipantManager,
        local_signer: *const protocol.write_evidence.Signer,
        outbound_keys: []const OutboundTargetKey,
    ) !WriteCoordinatorManager {
        return initInternal(allocator, io, parent, participants, local_signer, local_signer.identity(), outbound_keys);
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        participants: *write_participant_manager.WriteParticipantManager,
        local_signer: ?*const protocol.write_evidence.Signer,
        local_identity: write_service.WitnessIdentity,
        outbound_keys: []const OutboundTargetKey,
    ) !WriteCoordinatorManager {
        try protocol.write_evidence_contract.validateIdentity(local_identity);
        const owned_keys = try allocator.dupe(OutboundTargetKey, outbound_keys);
        var keys_owned = true;
        errdefer if (keys_owned) {
            for (owned_keys) |*target| std.crypto.secureZero(u8, &target.key);
            allocator.free(owned_keys);
        };
        for (owned_keys, 0..) |target, index| {
            if (isZero(&target.node_id) or isZero(&target.key) or
                std.mem.eql(u8, &target.node_id, &local_identity.node_id))
                return error.InvalidOutboundReplicaCredential;
            for (owned_keys[0..index]) |prior| if (std.mem.eql(u8, &prior.node_id, &target.node_id) or
                std.mem.eql(u8, &prior.key, &target.key)) return error.DuplicateOutboundReplicaCredential;
        }
        const lock_file = try openLock(io, parent);
        var owned = true;
        errdefer if (owned) lock_file.close(io);
        var self: WriteCoordinatorManager = .{
            .allocator = allocator,
            .io = io,
            .parent = parent,
            .participants = participants,
            .local_signer = local_signer,
            .local_identity = local_identity,
            .outbound_keys = owned_keys,
            .lock_file = lock_file,
        };
        owned = false;
        keys_owned = false;
        errdefer self.deinit();
        const initialized = try self.initializeCatalog();
        self.records = initialized.records;
        // Catalog bytes are only structural evidence. Every reopen must bind
        // them back to the current controller-pinned signer, exact local
        // participant/backend, and target-scoped outbound credentials before
        // any coordinator journal is opened or created.
        for (self.records) |record| try self.validateTopology(record.topology);
        try self.loadEntries(!initialized.marker_recovery_required);
        try self.rejectOrphans();
        if (initialized.marker_recovery_required) try createMarker(self.io, self.parent);
        return self;
    }

    pub fn deinit(self: *WriteCoordinatorManager) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            entry.instance.deinit();
            entry.store.deinit();
            self.allocator.free(entry.basename);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        if (self.records.len != 0) self.allocator.free(self.records);
        for (self.outbound_keys) |*target| std.crypto.secureZero(u8, &target.key);
        self.allocator.free(self.outbound_keys);
        self.lock_file.close(self.io);
        self.* = undefined;
    }

    pub fn setFaults(self: *WriteCoordinatorManager, faults: ?*Faults) void {
        self.faults = faults;
    }

    pub fn configure(self: *WriteCoordinatorManager, topology: CoordinatorTopology) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        try self.validateTopology(topology);
        const local = localRoute(topology) orelse return error.LocalCoordinatorRouteMissing;
        const key_value = key(local.binding.replica.placement_id, local.binding.replica.generation);
        if (self.entries.get(key_value)) |entry| {
            if (!std.meta.eql(self.records[entry.record_index].topology, topology))
                return error.CoordinatorTopologyConflict;
            return;
        }
        for (self.records) |record| {
            const existing_local = localRoute(record.topology) orelse return error.StoreCorrupt;
            if (std.mem.eql(u8, &existing_local.binding.replica.placement_id, &local.binding.replica.placement_id))
                return error.CoordinatorGenerationRolloverUnsupported;
        }
        if (self.records.len == max_records) return error.StoreFull;
        const next = try self.allocator.alloc(CatalogRecord, self.records.len + 1);
        var installed = false;
        errdefer if (!installed) self.allocator.free(next);
        @memcpy(next[0..self.records.len], self.records);
        next[self.records.len] = .{ .topology = topology };
        try validateRecords(next);
        try self.replaceCatalog(next);
        self.syncParent() catch |err| {
            self.poisoned = true;
            return err;
        };
        const previous = self.records;
        self.records = next;
        installed = true;
        if (previous.len != 0) self.allocator.free(previous);
        self.openEntry(self.records.len - 1, true) catch |err| {
            self.poisoned = true;
            return err;
        };
    }

    pub fn arm(self: *WriteCoordinatorManager, placement_id: protocol.Id, generation: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        const entry = self.entries.get(key(placement_id, generation)) orelse return error.CoordinatorNotConfigured;
        try self.armEntryLocked(entry);
    }

    /// Authenticated remote arm. The source must be one of the other pinned
    /// topology nodes; the target route is the exact local configured route.
    pub fn armFromPeer(
        self: *WriteCoordinatorManager,
        source_node_id: protocol.Id,
        placement_id: protocol.Id,
        generation: u64,
        authority: protocol.AuthorityBinding,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        const entry = self.entries.get(key(placement_id, generation)) orelse return error.CoordinatorNotConfigured;
        const topology = self.records[entry.record_index].topology;
        var source_found = false;
        for (topology.routes) |route| {
            if (std.mem.eql(u8, &route.node_id, &source_node_id)) source_found = true;
        }
        if (!source_found or std.mem.eql(u8, &source_node_id, &self.local_identity.node_id) or
            !std.mem.eql(u8, &source_node_id, &authority.primary_node_id))
            return error.CoordinatorSourceNotPinned;
        const primary_route = routeForNode(topology, authority.primary_node_id) orelse
            return error.CoordinatorSourceNotPinned;
        if (!std.mem.eql(u8, &primary_route.binding.replica.volume_id, &authority.volume_id) or
            !std.mem.eql(u8, &primary_route.binding.replica.placement_id, &authority.primary_placement_id))
            return error.CoordinatorSourceNotPinned;
        // An arm acknowledgement proves this witness's canonical local runtime
        // window is still admitting, not merely that routing metadata exists.
        try self.participants.validateAuthority(authority);
        try self.armEntryLocked(entry);
    }

    /// Process-local write path. No payload-bearing gRPC method exposes this
    /// seam. The returned success means both selected participants and the
    /// coordinator completion are durable.
    pub fn coordinate(self: *WriteCoordinatorManager, request: CoordinateRequest) !write_service.CommitResult {
        self.mutex.lockUncancelable(self.io);
        var locked = true;
        defer if (locked) self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        if (request.data.len == 0 or isZero(&request.transaction_id)) return error.InvalidWriteRequest;
        var entry = try self.entryForAuthorityLocked(request.authority);
        try validateCoordinateRequest(self.records[entry.record_index].topology, request);
        try self.validateCoordinateRetryLocked(entry, request);

        var inspection = try entry.instance.inspect();
        if (inspection.last_completed) |completed| {
            if (requestMatches(completed.write, request, null)) return completed.result;
        }
        if (inspection.pending != null)
            return self.drainEntryLocked(entry) catch return error.WriteOutcomeUnknown;

        // Admission is checked before arming and before the durable intent. Arm
        // RPCs execute without this manager lock so two candidates cannot form
        // a cross-node callback cycle. The exact immutable topology is checked
        // again after reacquiring the lock.
        try self.participants.validateAuthority(request.authority);
        const topology = self.records[entry.record_index].topology;
        self.mutex.unlock(self.io);
        locked = false;
        self.armRemoteRoutes(topology, request.authority) catch return error.WriteNotStarted;
        self.mutex.lockUncancelable(self.io);
        locked = true;

        if (self.poisoned) return error.StorePoisoned;
        entry = try self.entryForAuthorityLocked(request.authority);
        if (!std.meta.eql(self.records[entry.record_index].topology, topology))
            return error.CoordinatorTopologyConflict;
        try self.validateCoordinateRetryLocked(entry, request);
        inspection = try entry.instance.inspect();
        if (inspection.pending != null)
            return self.drainEntryLocked(entry) catch return error.WriteOutcomeUnknown;
        if (inspection.last_completed) |completed| {
            if (requestMatches(completed.write, request, null)) return completed.result;
        }
        try self.participants.validateAuthority(request.authority);
        try self.armEntryLocked(entry);

        const local = localRoute(topology) orelse return error.StoreCorrupt;
        const witnesses = selectedWitnesses(topology) orelse return error.InvalidCoordinatorTopology;
        const sequence = std.math.add(u64, inspection.frontier.sequence, 1) catch return error.SequenceOverflow;
        const write: write_service.WriteRequest = .{
            .authority = request.authority,
            .replica_members = local.binding.replica_members,
            .sequence = sequence,
            .transaction_id = request.transaction_id,
            .previous_history_digest = inspection.frontier.history_digest,
            .offset_bytes = request.offset_bytes,
            .length_bytes = @intCast(request.data.len),
            .data_digest = write_service.digestData(request.data),
        };
        _ = entry.instance.begin(.{
            .write = write,
            .data = request.data,
            .witnesses = witnesses,
        }) catch return error.WriteOutcomeUnknown;
        return self.drainEntryLocked(entry) catch return error.WriteOutcomeUnknown;
    }

    /// Best-effort same-directory recovery. A failure leaves durable state
    /// untouched and blocked; callers may retry after peers or leases recover.
    pub fn recoverPending(self: *WriteCoordinatorManager) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        var first_error: ?anyerror = null;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry_ptr| {
            const inspection = try entry_ptr.*.instance.inspect();
            if (inspection.pending == null) continue;
            _ = self.drainEntryLocked(entry_ptr.*) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
        }
        if (first_error) |err| return err;
    }

    pub fn beginControl(self: *WriteCoordinatorManager, placement_id: protocol.Id, generation: u64) !ControlGuard {
        self.mutex.lockUncancelable(self.io);
        errdefer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        if (self.entries.get(key(placement_id, generation))) |entry| {
            const before = try entry.instance.inspect();
            if (before.pending != null) _ = self.drainEntryLocked(entry) catch {};
            const inspection = try entry.instance.inspect();
            if (inspection.pending) |pending| {
                if (pending.signed_certificate != null) return error.CoordinatorDrainRequired;
                return error.CoordinatorWriteInProgress;
            }
        }
        return .{ .manager = self };
    }

    pub fn beginControlPlacement(self: *WriteCoordinatorManager, placement_id: protocol.Id) !ControlGuard {
        self.mutex.lockUncancelable(self.io);
        errdefer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        var found: ?*Entry = null;
        var iterator = self.entries.iterator();
        while (iterator.next()) |item| {
            if (!std.mem.eql(u8, &item.key_ptr.placement_id, &placement_id)) continue;
            if (found != null) return error.CoordinatorTopologyConflict;
            found = item.value_ptr.*;
        }
        if (found) |entry| {
            const before = try entry.instance.inspect();
            if (before.pending != null) _ = self.drainEntryLocked(entry) catch {};
            const inspection = try entry.instance.inspect();
            if (inspection.pending) |pending| {
                if (pending.signed_certificate != null) return error.CoordinatorDrainRequired;
                return error.CoordinatorWriteInProgress;
            }
        }
        return .{ .manager = self };
    }

    /// Returns null for unconfigured/unarmed empty state. An armed topology
    /// without a locally completed signed coordinator frontier is never allowed
    /// to manufacture empty recovery evidence.
    pub fn certifiedFrontier(self: *WriteCoordinatorManager, volume_id: protocol.Id) !?write_service.Frontier {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.poisoned) return error.StorePoisoned;
        var result: ?write_service.Frontier = null;
        var armed = false;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            const record = self.records[entry.record_index];
            const local = localRoute(record.topology) orelse return error.StoreCorrupt;
            if (!std.mem.eql(u8, &local.binding.replica.volume_id, &volume_id)) continue;
            const inspection = try entry.instance.inspect();
            if (!record.armed) {
                if (inspection.pending != null or inspection.frontier.sequence != 0)
                    return error.CoordinatorStateNotArmed;
                continue;
            }
            armed = true;
            if (inspection.pending) |pending| {
                if (pending.signed_certificate != null) return error.CoordinatorDrainRequired;
                return error.CoordinatorWriteInProgress;
            }
            if (inspection.frontier.sequence == 0 or inspection.last_completed == null)
                return error.RecoveryQuorumRequired;
            // Revalidate the exact active local participant while holding the
            // coordinator lock. Retired/replaced bindings and backend drift
            // must not inherit a signed coordinator frontier through the
            // volume-wide retired-history aggregator.
            const participant = try self.participants.inspectConfigured(
                local.binding,
                local.backend_digest,
            );
            if (participant.pending != null or
                participant.last_completed == null or
                !std.meta.eql(participant.frontier, inspection.frontier) or
                !std.meta.eql(participant.last_completed.?, inspection.last_completed.?.result))
                return error.CoordinatorHistoryConflict;
            // Coordinator validation on reopen already verifies both signed
            // COMMIT evidences and exact result/frontier binding.
            if (result) |existing| {
                if (!std.meta.eql(existing, inspection.frontier)) return error.CoordinatorHistoryConflict;
            } else result = inspection.frontier;
        }
        if (armed and result == null) return error.RecoveryQuorumRequired;
        return result;
    }

    fn armEntryLocked(self: *WriteCoordinatorManager, entry: *Entry) !void {
        if (self.records[entry.record_index].armed) return;
        const next = try self.allocator.dupe(CatalogRecord, self.records);
        errdefer self.allocator.free(next);
        next[entry.record_index].armed = true;
        try self.replaceCatalog(next);
        self.syncParent() catch |err| {
            self.poisoned = true;
            return err;
        };
        const previous = self.records;
        self.records = next;
        if (previous.len != 0) self.allocator.free(previous);
    }

    fn entryForAuthorityLocked(self: *WriteCoordinatorManager, authority: protocol.AuthorityBinding) !*Entry {
        if (!std.mem.eql(u8, &authority.primary_node_id, &self.local_identity.node_id))
            return error.NotLocalPrimary;
        var found: ?*Entry = null;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            const local = localRoute(self.records[entry.record_index].topology) orelse return error.StoreCorrupt;
            if (!std.mem.eql(u8, &local.binding.replica.volume_id, &authority.volume_id) or
                !std.mem.eql(u8, &local.binding.replica.placement_id, &authority.primary_placement_id)) continue;
            if (found != null) return error.CoordinatorTopologyConflict;
            found = entry;
        }
        return found orelse error.CoordinatorNotConfigured;
    }

    fn validateCoordinateRetryLocked(
        self: *WriteCoordinatorManager,
        entry: *Entry,
        request: CoordinateRequest,
    ) !void {
        _ = self;
        const inspection = try entry.instance.inspect();
        if (inspection.pending) |pending| {
            if (!requestMatches(pending.write, request, pending.data)) return error.WriteRetryConflict;
            return;
        }
        if (inspection.last_completed) |completed| {
            if (std.mem.eql(u8, &completed.write.transaction_id, &request.transaction_id) and
                !requestMatches(completed.write, request, null))
                return error.WriteRetryConflict;
        }
    }

    fn armRemoteRoutes(
        self: *WriteCoordinatorManager,
        topology: CoordinatorTopology,
        authority: protocol.AuthorityBinding,
    ) !void {
        for (topology.routes) |route| {
            if (std.mem.eql(u8, &route.binding.replica.member_id, &topology.local_member_id)) continue;
            var client = try self.clientForRoute(route);
            defer client.deinit();
            try client.armCoordinator(
                route.endpoint(),
                route.binding.replica.placement_id,
                route.binding.replica.generation,
                authority,
            );
        }
    }

    fn drainEntryLocked(self: *WriteCoordinatorManager, entry: *Entry) !write_service.CommitResult {
        const topology = self.records[entry.record_index].topology;
        const signer = self.local_signer orelse return error.CoordinatorSignerUnavailable;
        const initial = try entry.instance.inspect();
        const pending_initial = initial.pending orelse {
            if (initial.last_completed) |completed| return completed.result;
            return error.NoWriteInProgress;
        };
        const data = try self.allocator.dupe(u8, pending_initial.data);
        defer self.allocator.free(data);
        const write = pending_initial.write;
        const witnesses = pending_initial.witnesses;

        // A missing PREPARE is a new payload admission, not decision replay.
        // Revalidate the exact local primary READY/live authority immediately
        // before any such local or remote mutation. Once both PREPARE evidence
        // records are durable, certificate/COMMIT convergence remains
        // lease-independent and is guarded by the durable fence at participants.
        var missing_prepare = false;
        for (pending_initial.prepare_evidence) |evidence| {
            if (evidence == null) {
                missing_prepare = true;
                break;
            }
        }
        if (missing_prepare) try self.participants.validateAuthority(write.authority);

        // Reinspect after every durable mutation. Inspection payload storage is
        // borrowed and therefore never retained across coordinator saves.
        for (witnesses) |witness| {
            const current = (try entry.instance.inspect()).pending orelse break;
            const witness_index = memberIndex(current.witnesses, witness) orelse return error.StoreCorrupt;
            if (current.prepare_evidence[witness_index] != null) continue;
            const route = routeForMember(topology, witness) orelse return error.StoreCorrupt;
            const evidence: write_service.SignedPrepareEvidence = if (std.mem.eql(u8, &witness, &topology.local_member_id)) blk: {
                const attestation = try self.participants.prepareConfigured(
                    route.binding,
                    route.backend_digest,
                    .{ .write = write, .data = data },
                );
                break :blk try signer.signPrepare(write, attestation);
            } else blk: {
                if (self.faults) |faults| if (faults.fail_remote_prepare_before_request_once) {
                    faults.fail_remote_prepare_before_request_once = false;
                    return error.InjectedRemotePrepareBeforeRequestFailure;
                };
                var client = try self.clientForRoute(route);
                defer client.deinit();
                break :blk try client.prepare(
                    route.endpoint(),
                    .{ .participant = route.binding, .backend_digest = route.backend_digest },
                    .{ .write = write, .data = data },
                );
            };
            if (!std.mem.eql(u8, &witness, &topology.local_member_id)) if (self.faults) |faults|
                if (faults.lose_remote_prepare_response_once) {
                    faults.lose_remote_prepare_response_once = false;
                    return error.InjectedRemotePrepareResponseLoss;
                };
            try entry.instance.recordPrepared(evidence);
        }

        const after_prepare = try entry.instance.inspect();
        const pending_after_prepare = after_prepare.pending orelse {
            if (after_prepare.last_completed) |completed| return completed.result;
            return error.StoreCorrupt;
        };
        const certificate = pending_after_prepare.signed_certificate orelse try entry.instance.decide();

        for (witnesses) |witness| {
            const current_inspection = try entry.instance.inspect();
            const current = current_inspection.pending orelse {
                if (current_inspection.last_completed) |completed| return completed.result;
                return error.StoreCorrupt;
            };
            const witness_index = memberIndex(current.witnesses, witness) orelse return error.StoreCorrupt;
            if (current.commit_evidence[witness_index] != null) continue;
            const route = routeForMember(topology, witness) orelse return error.StoreCorrupt;
            const evidence: write_service.SignedCommitEvidence = if (std.mem.eql(u8, &witness, &topology.local_member_id)) blk: {
                const committed = try self.participants.commitConfigured(
                    route.binding,
                    route.backend_digest,
                    write.authority,
                    write.transaction_id,
                    write.sequence,
                    certificate,
                );
                const projection = try protocol.write_evidence_contract.certificateProjection(certificate);
                break :blk try signer.signCommit(committed.write, projection, committed.result);
            } else blk: {
                var client = try self.clientForRoute(route);
                defer client.deinit();
                break :blk try client.commit(
                    route.endpoint(),
                    .{ .participant = route.binding, .backend_digest = route.backend_digest },
                    write,
                    certificate,
                );
            };
            if (!std.mem.eql(u8, &witness, &topology.local_member_id)) if (self.faults) |faults|
                if (faults.lose_remote_commit_response_once) {
                    faults.lose_remote_commit_response_once = false;
                    return error.InjectedRemoteCommitResponseLoss;
                };
            _ = try entry.instance.recordCommitted(evidence);
        }
        const completed = (try entry.instance.inspect()).last_completed orelse return error.CoordinatorCompletionMissing;
        return completed.result;
    }

    fn clientForRoute(self: *WriteCoordinatorManager, route: ReplicaRoute) !replica_rpc_client.Client {
        const identity = protocol.write_evidence_contract.identityForMember(
            route.binding.witness_identities,
            route.binding.replica.member_id,
        ) orelse return error.InvalidCoordinatorTopology;
        if (!std.meta.eql(identity.node_id, route.node_id)) return error.InvalidCoordinatorTopology;
        var target_key = self.targetKey(route.node_id) orelse return error.OutboundReplicaCredentialMissing;
        defer std.crypto.secureZero(u8, &target_key);
        return replica_rpc_client.Client.init(
            self.allocator,
            self.io,
            self.local_identity.node_id,
            identity,
            target_key,
            .{},
        );
    }

    fn targetKey(self: *const WriteCoordinatorManager, node_id: protocol.Id) ?[32]u8 {
        for (self.outbound_keys) |target|
            if (std.mem.eql(u8, &target.node_id, &node_id)) return target.key;
        return null;
    }

    fn validateTopology(self: *WriteCoordinatorManager, topology: CoordinatorTopology) !void {
        try validateTopologyStructure(topology);
        for (&topology.routes) |*route| {
            const identity = protocol.write_evidence_contract.identityForMember(
                route.binding.witness_identities,
                route.binding.replica.member_id,
            ) orelse return error.InvalidCoordinatorTopology;
            if (std.mem.eql(u8, &route.binding.replica.member_id, &topology.local_member_id)) {
                if (!std.meta.eql(identity, self.local_identity)) return error.ReplicaSignerIdentityMismatch;
                _ = try self.participants.inspectConfigured(route.binding, route.backend_digest);
            } else if (!hasTargetKey(self.outbound_keys, route.node_id)) return error.OutboundReplicaCredentialMissing;
        }
    }

    fn initializeCatalog(self: *WriteCoordinatorManager) !CatalogInitialization {
        const marker_exists = try markerPresent(self.io, self.parent);
        const file = self.parent.openFile(self.io, catalog_basename, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                if (marker_exists) return error.CatalogMissing;
                const empty = try self.allocator.alloc(CatalogRecord, 0);
                try self.replaceCatalog(empty);
                self.syncParent() catch |sync_err| {
                    self.allocator.free(empty);
                    return sync_err;
                };
                try createMarker(self.io, self.parent);
                return .{ .records = empty, .marker_recovery_required = false };
            },
            else => return err,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size > max_catalog_size) return error.StoreCorrupt;
        const bytes = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.StoreCorrupt;
        return .{
            .records = try decodeCatalog(self.allocator, bytes),
            .marker_recovery_required = !marker_exists,
        };
    }

    fn loadEntries(self: *WriteCoordinatorManager, allow_unarmed_create: bool) !void {
        for (self.records, 0..) |record, index|
            try self.openEntry(index, allow_unarmed_create and !record.armed);
    }

    fn openEntry(self: *WriteCoordinatorManager, index: usize, allow_create: bool) !void {
        const topology = self.records[index].topology;
        const local = localRoute(topology) orelse return error.StoreCorrupt;
        const key_value = key(local.binding.replica.placement_id, local.binding.replica.generation);
        if (self.entries.contains(key_value)) return error.DuplicateCoordinatorState;
        var name: [journal_name_len]u8 = undefined;
        journalName(&name, key_value);
        const exists = try regularFileExists(self.io, self.parent, &name);
        if (!exists and (self.records[index].armed or !allow_create))
            return error.CoordinatorStateMissing;
        var lock_name: [journal_name_len + ".lock".len]u8 = undefined;
        @memcpy(lock_name[0..journal_name_len], &name);
        @memcpy(lock_name[journal_name_len..], ".lock");
        _ = try regularFileExists(self.io, self.parent, &lock_name);
        if (!exists) if (self.faults) |faults| if (faults.fail_journal_creation_once) {
            faults.fail_journal_creation_once = false;
            return error.InjectedJournalCreationFailure;
        };
        const owned_name = try self.allocator.dupe(u8, &name);
        var name_owned = true;
        errdefer if (name_owned) self.allocator.free(owned_name);
        const store = try coordinator.FileStore.init(self.allocator, self.io, self.parent, owned_name);
        errdefer store.deinit();
        const instance = try coordinator.Coordinator.initFile(
            self.allocator,
            topology.routes[0].binding.witness_identities,
            store,
        );
        errdefer instance.deinit();
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .record_index = index, .basename = owned_name, .store = store, .instance = instance };
        try self.entries.putNoClobber(self.allocator, key_value, entry);
        name_owned = false;
    }

    fn rejectOrphans(self: *WriteCoordinatorManager) !void {
        const directory = try self.parent.openDir(self.io, ".", .{ .iterate = true });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |item| {
            if (std.mem.eql(u8, item.name, catalog_basename) or
                std.mem.eql(u8, item.name, marker_basename) or
                std.mem.eql(u8, item.name, lock_basename)) continue;
            if (!std.mem.startsWith(u8, item.name, journal_prefix)) continue;
            if (item.kind != .file) return error.OrphanCoordinatorState;
            var covered = false;
            var entries = self.entries.keyIterator();
            while (entries.next()) |key_ptr| {
                var expected: [journal_name_len]u8 = undefined;
                journalName(&expected, key_ptr.*);
                if (std.mem.eql(u8, item.name, &expected)) {
                    covered = true;
                    break;
                }
                if (item.name.len == journal_name_len + ".lock".len and
                    std.mem.eql(u8, item.name[0..journal_name_len], &expected) and
                    std.mem.eql(u8, item.name[journal_name_len..], ".lock"))
                {
                    covered = true;
                    break;
                }
            }
            if (!covered) return error.OrphanCoordinatorState;
        }
    }

    fn replaceCatalog(self: *WriteCoordinatorManager, records: []const CatalogRecord) !void {
        const bytes = try encodeCatalog(self.allocator, records);
        defer self.allocator.free(bytes);
        var atomic = try self.parent.createFileAtomic(self.io, catalog_basename, .{ .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        if (self.faults) |faults| if (faults.fail_catalog_file_sync_once) {
            faults.fail_catalog_file_sync_once = false;
            return error.InjectedCatalogFileSyncFailure;
        };
        try atomic.file.sync(self.io);
        if (self.faults) |faults| if (faults.fail_catalog_rename_once) {
            faults.fail_catalog_rename_once = false;
            return error.InjectedCatalogRenameFailure;
        };
        try atomic.replace(self.io);
    }

    fn syncParent(self: *WriteCoordinatorManager) !void {
        if (self.faults) |faults| if (faults.fail_directory_sync_once) {
            faults.fail_directory_sync_once = false;
            return error.InjectedDirectorySyncFailure;
        };
        const file = try self.parent.openFile(self.io, ".", .{ .mode = .read_only });
        defer file.close(self.io);
        try file.sync(self.io);
    }
};

/// Detect coordinator artifacts before deciding whether it is safe to start
/// without Replica transport composition. Suspicious aliases, symlinks,
/// malformed catalog bytes, and journal-without-catalog state fail closed.
pub fn durableStatePresent(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
) !bool {
    var catalog_found = false;
    var marker_found = false;
    var journal_found = false;
    var lock_found = false;
    const directory = try parent.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |item| {
        if (std.mem.eql(u8, item.name, catalog_basename)) {
            if (item.kind != .file) return error.SuspiciousCoordinatorState;
            catalog_found = true;
            continue;
        }
        if (std.mem.eql(u8, item.name, marker_basename)) {
            if (item.kind != .file) return error.SuspiciousCoordinatorState;
            marker_found = true;
            continue;
        }
        if (std.mem.eql(u8, item.name, lock_basename)) {
            if (item.kind != .file) return error.SuspiciousCoordinatorState;
            lock_found = true;
            continue;
        }
        if (!std.mem.startsWith(u8, item.name, journal_prefix)) continue;
        if (item.kind != .file or !canonicalJournalArtifactName(item.name))
            return error.SuspiciousCoordinatorState;
        journal_found = true;
    }
    if (marker_found) {
        _ = try markerPresent(io, parent);
        if (!catalog_found) return error.CatalogMissing;
    }
    if (catalog_found) {
        const file = try parent.openFile(io, catalog_basename, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.size > max_catalog_size) return error.StoreCorrupt;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.StoreCorrupt;
        const records = try decodeCatalog(allocator, bytes);
        defer allocator.free(records);
        try validatePresenceJournalCoverage(io, parent, records);
    } else if (journal_found) {
        return error.OrphanCoordinatorState;
    }
    return catalog_found or marker_found or journal_found or lock_found;
}

fn validatePresenceJournalCoverage(
    io: std.Io,
    parent: std.Io.Dir,
    records: []const CatalogRecord,
) !void {
    const directory = try parent.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |item| {
        if (std.mem.eql(u8, item.name, catalog_basename) or
            std.mem.eql(u8, item.name, marker_basename) or
            std.mem.eql(u8, item.name, lock_basename) or
            !std.mem.startsWith(u8, item.name, journal_prefix)) continue;
        const journal = if (std.mem.endsWith(u8, item.name, ".lock"))
            item.name[0 .. item.name.len - ".lock".len]
        else
            item.name;
        var covered = false;
        for (records) |record| {
            const local = localRoute(record.topology) orelse return error.StoreCorrupt;
            var expected: [journal_name_len]u8 = undefined;
            journalName(&expected, key(
                local.binding.replica.placement_id,
                local.binding.replica.generation,
            ));
            if (std.mem.eql(u8, journal, &expected)) {
                covered = true;
                break;
            }
        }
        if (!covered) return error.OrphanCoordinatorState;
    }
    for (records) |record| if (record.armed) {
        const local = localRoute(record.topology) orelse return error.StoreCorrupt;
        var expected: [journal_name_len]u8 = undefined;
        journalName(&expected, key(
            local.binding.replica.placement_id,
            local.binding.replica.generation,
        ));
        if (!try regularFileExists(io, parent, &expected))
            return error.CoordinatorStateMissing;
    };
}

fn canonicalJournalArtifactName(name: []const u8) bool {
    const journal = if (name.len == journal_name_len + ".lock".len and
        std.mem.endsWith(u8, name, ".lock")) name[0..journal_name_len] else name;
    if (journal.len != journal_name_len or
        !std.mem.startsWith(u8, journal, journal_prefix) or
        !std.mem.endsWith(u8, journal, journal_suffix)) return false;
    const encoded = journal[journal_prefix.len .. journal.len - journal_suffix.len];
    if (encoded.len != 32 + 1 + 16 or encoded[32] != '-') return false;
    for (encoded, 0..) |character, index| {
        if (index == 32) continue;
        if (!((character >= '0' and character <= '9') or
            (character >= 'a' and character <= 'f'))) return false;
    }
    return true;
}

fn regularFileExists(io: std.Io, parent: std.Io.Dir, basename: []const u8) !bool {
    const file = parent.openFile(io, basename, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidCoordinatorStateFile;
    return true;
}

fn openLock(io: std.Io, parent: std.Io.Dir) !std.Io.File {
    while (true) {
        const file = parent.openFile(io, lock_basename, .{ .mode = .read_write, .allow_directory = false, .follow_symlinks = false }) catch |open_error| switch (open_error) {
            error.FileNotFound => parent.createFile(io, lock_basename, .{ .read = true, .truncate = false, .exclusive = true, .permissions = @enumFromInt(0o600) }) catch |create_error| switch (create_error) {
                error.PathAlreadyExists => continue,
                else => return create_error,
            },
            else => return open_error,
        };
        errdefer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.InvalidCatalogLockFile;
        if (!try file.tryLock(io, .exclusive)) return error.StateFileLocked;
        return file;
    }
}

fn markerPresent(io: std.Io, parent: std.Io.Dir) !bool {
    const file = parent.openFile(io, marker_basename, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidCatalogMarker;
    var bytes: [marker_magic.len]u8 = undefined;
    if (try file.readPositionalAll(io, &bytes, 0) != bytes.len or
        !std.mem.eql(u8, &bytes, &marker_magic) or (try file.stat(io)).size != marker_magic.len)
        return error.InvalidCatalogMarker;
    return true;
}

fn createMarker(io: std.Io, parent: std.Io.Dir) !void {
    var atomic = try parent.createFileAtomic(io, marker_basename, .{ .replace = false });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, &marker_magic);
    try atomic.file.sync(io);
    try atomic.link(io);
    const file = try parent.openFile(io, ".", .{ .mode = .read_only });
    defer file.close(io);
    try file.sync(io);
}

fn localRoute(topology: CoordinatorTopology) ?ReplicaRoute {
    for (topology.routes) |route|
        if (std.mem.eql(u8, &route.binding.replica.member_id, &topology.local_member_id)) return route;
    return null;
}

fn routeForNode(topology: CoordinatorTopology, node_id: protocol.Id) ?ReplicaRoute {
    for (topology.routes) |route|
        if (std.mem.eql(u8, &route.node_id, &node_id)) return route;
    return null;
}

fn routeForMember(topology: CoordinatorTopology, member_id: protocol.Id) ?ReplicaRoute {
    for (topology.routes) |route|
        if (std.mem.eql(u8, &route.binding.replica.member_id, &member_id)) return route;
    return null;
}

fn selectedWitnesses(topology: CoordinatorTopology) ?[write_service.certificate_witness_count]protocol.Id {
    var remote: ?protocol.Id = null;
    for (topology.routes) |route| {
        const member = route.binding.replica.member_id;
        if (std.mem.eql(u8, &member, &topology.local_member_id)) continue;
        if (remote == null or std.mem.order(u8, &member, &remote.?) == .lt) remote = member;
    }
    const selected_remote = remote orelse return null;
    return if (std.mem.order(u8, &topology.local_member_id, &selected_remote) == .lt)
        .{ topology.local_member_id, selected_remote }
    else
        .{ selected_remote, topology.local_member_id };
}

fn memberIndex(members: [write_service.certificate_witness_count]protocol.Id, member_id: protocol.Id) ?usize {
    for (members, 0..) |candidate, index|
        if (std.mem.eql(u8, &candidate, &member_id)) return index;
    return null;
}

fn validateCoordinateRequest(topology: CoordinatorTopology, request: CoordinateRequest) !void {
    if (request.data.len == 0 or request.data.len > write_service.max_payload_size or
        isZero(&request.transaction_id) or request.offset_bytes % 4096 != 0 or
        request.data.len % 4096 != 0)
        return error.InvalidWriteRequest;
    const length: u64 = @intCast(request.data.len);
    const end = std.math.add(u64, request.offset_bytes, length) catch
        return error.InvalidWriteRequest;
    for (topology.routes) |route| {
        if (!std.mem.eql(u8, &request.authority.volume_id, &route.binding.replica.volume_id) or
            end > route.binding.replica.length_bytes)
            return error.InvalidWriteRequest;
    }
}

fn requestMatches(
    write: write_service.WriteRequest,
    request: CoordinateRequest,
    payload: ?[]const u8,
) bool {
    const data_digest = write_service.digestData(request.data);
    if (!std.meta.eql(write.authority, request.authority) or
        !std.mem.eql(u8, &write.transaction_id, &request.transaction_id) or
        write.offset_bytes != request.offset_bytes or
        write.length_bytes != @as(u64, @intCast(request.data.len)) or
        !std.mem.eql(u8, &write.data_digest, &data_digest)) return false;
    return if (payload) |data| std.mem.eql(u8, data, request.data) else true;
}

fn hasTargetKey(keys: []const OutboundTargetKey, node_id: protocol.Id) bool {
    for (keys) |target| if (std.mem.eql(u8, &target.node_id, &node_id)) return true;
    return false;
}

fn key(placement_id: protocol.Id, generation: u64) Key {
    return .{ .placement_id = placement_id, .generation = generation };
}

fn journalName(buffer: *[journal_name_len]u8, value: Key) void {
    var offset: usize = 0;
    @memcpy(buffer[offset..][0..journal_prefix.len], journal_prefix);
    offset += journal_prefix.len;
    putHex(buffer[offset..][0..32], &value.placement_id);
    offset += 32;
    buffer[offset] = '-';
    offset += 1;
    var generation: [8]u8 = undefined;
    std.mem.writeInt(u64, &generation, value.generation, .little);
    putHex(buffer[offset..][0..16], &generation);
    offset += 16;
    @memcpy(buffer[offset..][0..journal_suffix.len], journal_suffix);
}

fn putHex(destination: []u8, source: []const u8) void {
    const alphabet = "0123456789abcdef";
    for (source, 0..) |byte, index| {
        destination[index * 2] = alphabet[byte >> 4];
        destination[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn validateTopologyStructure(topology: CoordinatorTopology) !void {
    if (isZero(&topology.local_member_id)) return error.InvalidCoordinatorTopology;
    var local_count: usize = 0;
    for (&topology.routes, 0..) |*route, index| {
        try write_service.validateParticipantBinding(route.binding);
        if (route.endpoint_len == 0 or route.endpoint_len > max_endpoint_len or
            std.mem.indexOfScalar(u8, route.endpoint_bytes[0..route.endpoint_len], 0) != null or
            !isZero(route.endpoint_bytes[route.endpoint_len..]) or
            isZero(&route.backend_digest) or isZero(&route.node_id) or
            (index != 0 and std.mem.order(u8, &topology.routes[index - 1].binding.replica.member_id, &route.binding.replica.member_id) != .lt) or
            !std.meta.eql(route.binding.witness_identities, topology.routes[0].binding.witness_identities) or
            !std.meta.eql(route.binding.replica_members, topology.routes[0].binding.replica_members) or
            !std.mem.eql(u8, &route.binding.replica.volume_id, &topology.routes[0].binding.replica.volume_id) or
            route.binding.replica.length_bytes != topology.routes[0].binding.replica.length_bytes or
            route.binding.replica.offset_bytes % 4096 != 0 or route.binding.replica.length_bytes % 4096 != 0)
            return error.InvalidCoordinatorTopology;
        const identity = protocol.write_evidence_contract.identityForMember(
            route.binding.witness_identities,
            route.binding.replica.member_id,
        ) orelse return error.InvalidCoordinatorTopology;
        if (!std.mem.eql(u8, &identity.node_id, &route.node_id)) return error.InvalidCoordinatorTopology;
        for (topology.routes[0..index]) |prior| if (std.mem.eql(u8, &prior.node_id, &route.node_id) or
            std.mem.eql(u8, prior.endpoint(), route.endpoint())) return error.InvalidCoordinatorTopology;
        if (std.mem.eql(u8, &route.binding.replica.member_id, &topology.local_member_id)) local_count += 1;
    }
    if (local_count != 1) return error.LocalCoordinatorRouteMissing;
}

fn validateRecords(records: []const CatalogRecord) !void {
    for (records, 0..) |record, index| {
        validateTopologyStructure(record.topology) catch return error.StoreCorrupt;
        const local = localRoute(record.topology) orelse return error.StoreCorrupt;
        for (records[0..index]) |prior| {
            const prior_local = localRoute(prior.topology) orelse return error.StoreCorrupt;
            if (std.mem.eql(u8, &prior_local.binding.replica.placement_id, &local.binding.replica.placement_id))
                return error.StoreCorrupt;
        }
    }
}

fn encodeCatalog(allocator: std.mem.Allocator, records: []const CatalogRecord) ![]u8 {
    if (records.len > max_records) return error.StoreFull;
    const bytes = try allocator.alloc(u8, header_size + records.len * record_encoded_size + checksum_size);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], &magic);
    std.mem.writeInt(u16, bytes[8..10], version, .little);
    std.mem.writeInt(u16, bytes[10..12], record_encoded_size, .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(records.len), .little);
    for (records, 0..) |record, index| encodeRecord(bytes[header_size + index * record_encoded_size ..][0..record_encoded_size], record);
    std.mem.writeInt(u32, bytes[bytes.len - checksum_size ..][0..checksum_size], std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - checksum_size]), .little);
    return bytes;
}

fn decodeCatalog(allocator: std.mem.Allocator, bytes: []const u8) ![]CatalogRecord {
    if (bytes.len < header_size + checksum_size or !std.mem.eql(u8, bytes[0..8], &magic) or
        std.mem.readInt(u16, bytes[8..10], .little) != version or
        std.mem.readInt(u16, bytes[10..12], .little) != record_encoded_size or !isZero(bytes[16..24]))
        return error.StoreCorrupt;
    const count = std.mem.readInt(u32, bytes[12..16], .little);
    if (count > max_records or bytes.len != header_size + @as(usize, count) * record_encoded_size + checksum_size or
        std.mem.readInt(u32, bytes[bytes.len - checksum_size ..][0..checksum_size], .little) != std.hash.crc.Crc32Iscsi.hash(bytes[0 .. bytes.len - checksum_size]))
        return error.StoreCorrupt;
    const records = try allocator.alloc(CatalogRecord, count);
    errdefer allocator.free(records);
    for (records, 0..) |*record, index| record.* = try decodeRecord(bytes[header_size + index * record_encoded_size ..][0..record_encoded_size]);
    try validateRecords(records);
    return records;
}

fn encodeRecord(bytes: []u8, record: CatalogRecord) void {
    var offset: usize = 0;
    put(bytes, &offset, &record.topology.local_member_id);
    bytes[offset] = @intFromBool(record.armed);
    offset += 8;
    for (record.topology.routes) |route| encodeRoute(bytes, &offset, route);
    std.debug.assert(offset == record_encoded_size);
}

fn decodeRecord(bytes: []const u8) !CatalogRecord {
    var offset: usize = 0;
    var result: CatalogRecord = .{ .topology = undefined };
    result.topology.local_member_id = take(16, bytes, &offset);
    result.armed = switch (bytes[offset]) {
        0 => false,
        1 => true,
        else => return error.StoreCorrupt,
    };
    if (!isZero(bytes[offset + 1 .. offset + 8])) return error.StoreCorrupt;
    offset += 8;
    for (&result.topology.routes) |*route| route.* = try decodeRoute(bytes, &offset);
    if (offset != bytes.len) return error.StoreCorrupt;
    return result;
}

fn encodeRoute(bytes: []u8, offset: *usize, route: ReplicaRoute) void {
    const replica = route.binding.replica;
    put(bytes, offset, &replica.volume_id);
    put(bytes, offset, &replica.placement_id);
    put(bytes, offset, &replica.allocation_id);
    putU64(bytes, offset, replica.generation);
    put(bytes, offset, &replica.member_id);
    putU64(bytes, offset, replica.offset_bytes);
    putU64(bytes, offset, replica.length_bytes);
    for (route.binding.replica_members) |member| put(bytes, offset, &member);
    for (route.binding.witness_identities) |identity| {
        put(bytes, offset, &identity.member_id);
        put(bytes, offset, &identity.node_id);
        put(bytes, offset, &identity.key_id);
        put(bytes, offset, &identity.public_key);
    }
    put(bytes, offset, &route.backend_digest);
    put(bytes, offset, &route.node_id);
    std.mem.writeInt(u16, bytes[offset.*..][0..2], route.endpoint_len, .little);
    offset.* += 2;
    @memcpy(bytes[offset.*..][0..max_endpoint_len], &route.endpoint_bytes);
    offset.* += max_endpoint_len;
}

fn decodeRoute(bytes: []const u8, offset: *usize) !ReplicaRoute {
    var route: ReplicaRoute = undefined;
    route.binding.replica.volume_id = take(16, bytes, offset);
    route.binding.replica.placement_id = take(16, bytes, offset);
    route.binding.replica.allocation_id = take(16, bytes, offset);
    route.binding.replica.generation = takeU64(bytes, offset);
    route.binding.replica.member_id = take(16, bytes, offset);
    route.binding.replica.offset_bytes = takeU64(bytes, offset);
    route.binding.replica.length_bytes = takeU64(bytes, offset);
    for (&route.binding.replica_members) |*member| member.* = take(16, bytes, offset);
    for (&route.binding.witness_identities) |*identity| {
        identity.member_id = take(16, bytes, offset);
        identity.node_id = take(16, bytes, offset);
        identity.key_id = take(32, bytes, offset);
        identity.public_key = take(32, bytes, offset);
    }
    route.backend_digest = take(32, bytes, offset);
    route.node_id = take(16, bytes, offset);
    route.endpoint_len = std.mem.readInt(u16, bytes[offset.*..][0..2], .little);
    offset.* += 2;
    route.endpoint_bytes = take(max_endpoint_len, bytes, offset);
    if (route.endpoint_len == 0 or route.endpoint_len > max_endpoint_len or
        std.mem.indexOfScalar(u8, route.endpoint_bytes[0..route.endpoint_len], 0) != null or
        !isZero(route.endpoint_bytes[route.endpoint_len..])) return error.StoreCorrupt;
    return route;
}

fn put(bytes: []u8, offset: *usize, value: []const u8) void {
    @memcpy(bytes[offset.*..][0..value.len], value);
    offset.* += value.len;
}
fn putU64(bytes: []u8, offset: *usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset.*..][0..8], value, .little);
    offset.* += 8;
}
fn take(comptime size: usize, bytes: []const u8, offset: *usize) [size]u8 {
    const value = bytes[offset.*..][0..size].*;
    offset.* += size;
    return value;
}
fn takeU64(bytes: []const u8, offset: *usize) u64 {
    const value = std.mem.readInt(u64, bytes[offset.*..][0..8], .little);
    offset.* += 8;
    return value;
}
fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn testId(value: u8) protocol.Id {
    var result: protocol.Id = @splat(value);
    result[6] = 0x70 | (value & 0x0f);
    result[8] = 0x80 | (value & 0x3f);
    return result;
}

fn testTopology() CoordinatorTopology {
    var identities: [3]write_service.WitnessIdentity = undefined;
    for (&identities, 0..) |*identity, index| {
        var pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(@as(u8, @intCast(index + 1)))) catch unreachable;
        const public_key = pair.public_key.toBytes();
        std.crypto.secureZero(u8, std.mem.asBytes(&pair));
        identity.* = .{
            .member_id = testId(@intCast(index + 1)),
            .node_id = testId(@intCast(index + 11)),
            .key_id = protocol.write_evidence_contract.keyId(public_key),
            .public_key = public_key,
        };
    }
    const members = protocol.write_evidence_contract.members(identities);
    var routes: [3]ReplicaRoute = undefined;
    for (&routes, 0..) |*route, index| {
        const value: u8 = @intCast(index + 1);
        route.* = ReplicaRoute.init(.{
            .replica = .{
                .volume_id = testId(20),
                .placement_id = testId(30 + value),
                .allocation_id = testId(40 + value),
                .generation = 1,
                .member_id = members[index],
                .offset_bytes = @as(u64, index) * 4096,
                .length_bytes = 4096,
            },
            .replica_members = members,
            .witness_identities = identities,
        }, @splat(50 + value), identities[index].node_id, switch (index) {
            0 => "node-a:7443",
            1 => "node-b:7443",
            else => "node-c:7443",
        }) catch unreachable;
    }
    return .{ .local_member_id = members[0], .routes = routes };
}

test "coordinator catalog round trips canonical topology and arm bit" {
    const records = [_]CatalogRecord{.{ .topology = testTopology(), .armed = true }};
    const bytes = try encodeCatalog(std.testing.allocator, &records);
    defer std.testing.allocator.free(bytes);
    const decoded = try decodeCatalog(std.testing.allocator, bytes);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(CatalogRecord, &records, decoded);
    var corrupted = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupted);
    corrupted[header_size + 16] = 2;
    std.mem.writeInt(u32, corrupted[corrupted.len - checksum_size ..][0..checksum_size], std.hash.crc.Crc32Iscsi.hash(corrupted[0 .. corrupted.len - checksum_size]), .little);
    try std.testing.expectError(error.StoreCorrupt, decodeCatalog(std.testing.allocator, corrupted));
}

test "coordinator topology rejects embedded NUL padding and invalid endpoint length" {
    var topology = testTopology();
    topology.routes[0].endpoint_bytes[1] = 0;
    try std.testing.expectError(error.InvalidCoordinatorTopology, validateTopologyStructure(topology));

    topology = testTopology();
    topology.routes[0].endpoint_bytes[topology.routes[0].endpoint_len] = 1;
    try std.testing.expectError(error.InvalidCoordinatorTopology, validateTopologyStructure(topology));

    topology = testTopology();
    topology.routes[0].endpoint_len = 0;
    try std.testing.expectError(error.InvalidCoordinatorTopology, validateTopologyStructure(topology));

    topology = testTopology();
    topology.routes[0].endpoint_len = max_endpoint_len + 1;
    try std.testing.expectError(error.InvalidCoordinatorTopology, validateTopologyStructure(topology));
}

test "coordinator catalog rejects duplicate records" {
    const records = [_]CatalogRecord{
        .{ .topology = testTopology() },
        .{ .topology = testTopology() },
    };
    try std.testing.expectError(error.StoreCorrupt, validateRecords(&records));
}

test "coordinator journal name is fixed width lowercase canonical" {
    const topology = testTopology();
    const local = localRoute(topology).?;
    var name: [journal_name_len]u8 = undefined;
    journalName(&name, key(local.binding.replica.placement_id, local.binding.replica.generation));
    try std.testing.expectEqual(@as(usize, journal_name_len), name.len);
    try std.testing.expect(std.mem.startsWith(u8, &name, journal_prefix));
    try std.testing.expect(std.mem.endsWith(u8, &name, journal_suffix));
    for (name[journal_prefix.len .. name.len - journal_suffix.len]) |character|
        try std.testing.expect(character == '-' or (character >= '0' and character <= '9') or
            (character >= 'a' and character <= 'f'));
}

test "coordinator catalog lock is exclusive and symlink safe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try openLock(std.testing.io, tmp.dir);
    defer first.close(std.testing.io);
    try std.testing.expectError(error.StateFileLocked, openLock(std.testing.io, tmp.dir));
}

const ManagerTestReplicaBackend = struct {
    digest: protocol.Digest = @splat(0x33),
    active: bool = false,

    fn backend(self: *ManagerTestReplicaBackend) protocol.replica_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn inspectOpaque(context: *anyopaque, _: protocol.ReplicaBinding) !protocol.replica_service.BackendState {
        const self: *ManagerTestReplicaBackend = @ptrCast(@alignCast(context));
        return if (self.active) .{ .active = self.digest } else .absent;
    }

    fn ensureOpaque(context: *anyopaque, _: protocol.ReplicaBinding) !protocol.Digest {
        const self: *ManagerTestReplicaBackend = @ptrCast(@alignCast(context));
        self.active = true;
        return self.digest;
    }

    fn deleteOpaque(context: *anyopaque, _: protocol.ReplicaBinding) !void {
        const self: *ManagerTestReplicaBackend = @ptrCast(@alignCast(context));
        self.active = false;
    }

    const vtable: protocol.replica_service.Backend.VTable = .{
        .inspect = inspectOpaque,
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
    };
};

const ManagerTestFenceBackend = struct {
    fn backend(self: *ManagerTestFenceBackend) protocol.fence_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn quiesceDrainFlushOpaque(_: *anyopaque, binding: protocol.FenceBinding) !protocol.Digest {
        var digest: protocol.Digest = @splat(0x44);
        digest[0] = @truncate(binding.write_epoch);
        return digest;
    }

    const vtable: protocol.fence_service.Backend.VTable = .{
        .quiesceDrainFlush = quiesceDrainFlushOpaque,
    };
};

const ManagerTestWriteBackend = struct {
    bytes: [32 * 1024]u8 = @splat(0),

    fn backend(self: *ManagerTestWriteBackend) write_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn applyOpaque(context: *anyopaque, replica: protocol.ReplicaBinding, offset: u64, data: []const u8) !void {
        const self: *ManagerTestWriteBackend = @ptrCast(@alignCast(context));
        const start = std.math.cast(usize, replica.offset_bytes + offset) orelse return error.WriteOutOfBounds;
        if (start + data.len > self.bytes.len) return error.WriteOutOfBounds;
        @memcpy(self.bytes[start..][0..data.len], data);
    }

    const vtable: write_service.Backend.VTable = .{ .apply = applyOpaque };
};

const ManagerTestAuthorityValidator = struct {
    expected: protocol.AuthorityBinding,

    fn validator(self: *ManagerTestAuthorityValidator) replica_io_gate.AuthorityValidator {
        return .{ .context = self, .validate_fn = validateOpaque };
    }

    fn validateOpaque(context: *anyopaque, authority: protocol.AuthorityBinding) !void {
        const self: *ManagerTestAuthorityValidator = @ptrCast(@alignCast(context));
        if (!std.meta.eql(self.expected, authority)) return error.AuthorityRejected;
    }
};

fn managerTestAuthority(volume_id: protocol.Id) protocol.AuthorityBinding {
    return .{
        .volume_id = volume_id,
        .primary_placement_id = testId(61),
        .primary_node_id = testId(62),
        .lease_id = testId(63),
        .holder_boot_id = testId(64),
        .authority_generation = 1,
        .write_epoch = 1,
        .placement_revision = 1,
        .activation_nonce = testId(65),
        .authority_digest = @splat(0x66),
    };
}

fn managerTestTopology(replica: protocol.ReplicaBinding, backend_digest: protocol.Digest) CoordinatorTopology {
    var members = [3]protocol.Id{ replica.member_id, testId(14), testId(15) };
    std.mem.sort(protocol.Id, &members, {}, struct {
        fn lessThan(_: void, lhs: protocol.Id, rhs: protocol.Id) bool {
            return std.mem.order(u8, &lhs, &rhs) == .lt;
        }
    }.lessThan);
    var identities: [3]write_service.WitnessIdentity = undefined;
    for (&identities, 0..) |*identity, index| {
        var pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(@as(u8, @intCast(index + 21)))) catch unreachable;
        const public_key = pair.public_key.toBytes();
        std.crypto.secureZero(u8, std.mem.asBytes(&pair));
        identity.* = .{
            .member_id = members[index],
            .node_id = testId(@intCast(index + 31)),
            .key_id = protocol.write_evidence_contract.keyId(public_key),
            .public_key = public_key,
        };
    }
    var routes: [3]ReplicaRoute = undefined;
    for (&routes, 0..) |*route, index| {
        var route_replica = replica;
        route_replica.member_id = members[index];
        if (!std.mem.eql(u8, &members[index], &replica.member_id)) {
            route_replica.placement_id = testId(@intCast(index + 41));
            route_replica.allocation_id = testId(@intCast(index + 51));
            route_replica.offset_bytes = @as(u64, index + 4) * 4096;
        }
        route.* = ReplicaRoute.init(.{
            .replica = route_replica,
            .replica_members = members,
            .witness_identities = identities,
        }, backend_digest, identities[index].node_id, switch (index) {
            0 => "node-a:7443",
            1 => "node-b:7443",
            else => "node-c:7443",
        }) catch unreachable;
    }
    return .{ .local_member_id = replica.member_id, .routes = routes };
}

fn managerTestIdentity(topology: CoordinatorTopology) write_service.WitnessIdentity {
    const route = localRoute(topology).?;
    return protocol.write_evidence_contract.identityForMember(
        route.binding.witness_identities,
        topology.local_member_id,
    ).?;
}

fn managerTestKeys(topology: CoordinatorTopology) [2]OutboundTargetKey {
    var result: [2]OutboundTargetKey = undefined;
    var next: usize = 0;
    for (topology.routes) |route| {
        if (std.mem.eql(u8, &route.binding.replica.member_id, &topology.local_member_id)) continue;
        result[next] = .{ .node_id = route.node_id, .key = @splat(@as(u8, @intCast(next + 1))) };
        next += 1;
    }
    return result;
}

const ManagerTestEnvironment = struct {
    replicas: protocol.replica_service.FileStore,
    replica_backend: ManagerTestReplicaBackend,
    replica_control: protocol.replica_service.Service,
    fences: protocol.fence_service.FileStore,
    fence_backend: ManagerTestFenceBackend,
    fence_control: protocol.fence_service.Service,
    write_backend: ManagerTestWriteBackend,
    validator: ManagerTestAuthorityValidator,
    participants: write_participant_manager.WriteParticipantManager,
    topology: CoordinatorTopology,
    keys: [2]OutboundTargetKey,

    fn init(self: *ManagerTestEnvironment, parent: std.Io.Dir) !void {
        self.replica_backend = .{};
        self.replicas = try protocol.replica_service.FileStore.init(
            std.testing.allocator,
            std.testing.io,
            parent,
            "replicas.state",
        );
        errdefer self.replicas.deinit();
        self.replica_control = protocol.replica_service.Service.init(
            self.replicas.store(),
            self.replica_backend.backend(),
        );
        const member_id = testId(4);
        const ensured = try self.replica_control.ensureReplica(.{
            .operation_id = "0198f54d-5c2a-7000-8000-000000000010",
            .volume_id = "0198f54d-5c2a-7000-8000-000000000001",
            .placement_id = "0198f54d-5c2a-7000-8000-000000000002",
            .allocation_id = "0198f54d-5c2a-7000-8000-000000000003",
            .generation = 1,
            .member_id = &member_id,
            .offset_bytes = 4096,
            .length_bytes = 8192,
        });
        self.topology = managerTestTopology(
            ensured.replica.attestation.binding,
            ensured.replica.attestation.backend_digest,
        );
        self.keys = managerTestKeys(self.topology);
        self.fences = try protocol.fence_service.FileStore.init(
            std.testing.allocator,
            std.testing.io,
            parent,
            "fences.state",
        );
        errdefer self.fences.deinit();
        self.fence_backend = .{};
        self.fence_control = protocol.fence_service.Service.init(
            self.fences.store(),
            self.fence_backend.backend(),
        );
        self.write_backend = .{};
        self.validator = .{ .expected = managerTestAuthority(self.topology.routes[0].binding.replica.volume_id) };
        self.participants = try write_participant_manager.WriteParticipantManager.init(
            std.testing.allocator,
            std.testing.io,
            parent,
            &self.replicas,
            &self.replica_control,
            &self.fences,
            self.write_backend.backend(),
            self.validator.validator(),
        );
        errdefer self.participants.deinit();
        const local = localRoute(self.topology).?;
        try self.participants.configure(local.binding, local.backend_digest);
    }

    fn deinit(self: *ManagerTestEnvironment) void {
        self.participants.deinit();
        self.fences.deinit();
        self.replicas.deinit();
        self.* = undefined;
    }
};

fn managerTestJournalName(topology: CoordinatorTopology) [journal_name_len]u8 {
    const local = localRoute(topology).?;
    var name: [journal_name_len]u8 = undefined;
    journalName(&name, key(local.binding.replica.placement_id, local.binding.replica.generation));
    return name;
}

fn managerTestWriteCatalog(parent: std.Io.Dir, records: []const CatalogRecord) !void {
    const bytes = try encodeCatalog(std.testing.allocator, records);
    defer std.testing.allocator.free(bytes);
    try parent.writeFile(std.testing.io, .{
        .sub_path = catalog_basename,
        .data = bytes,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
}

fn managerTestIdText(buffer: *[36]u8, id: protocol.Id) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7], id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15] },
    ) catch unreachable;
}

fn managerTestConfigureRoute(environment: *ManagerTestEnvironment, route: ReplicaRoute) !void {
    var operation_text: [36]u8 = undefined;
    var volume_text: [36]u8 = undefined;
    var placement_text: [36]u8 = undefined;
    var allocation_text: [36]u8 = undefined;
    _ = try environment.replica_control.ensureReplica(.{
        .operation_id = managerTestIdText(&operation_text, route.binding.replica.placement_id),
        .volume_id = managerTestIdText(&volume_text, route.binding.replica.volume_id),
        .placement_id = managerTestIdText(&placement_text, route.binding.replica.placement_id),
        .allocation_id = managerTestIdText(&allocation_text, route.binding.replica.allocation_id),
        .generation = route.binding.replica.generation,
        .member_id = &route.binding.replica.member_id,
        .offset_bytes = route.binding.replica.offset_bytes,
        .length_bytes = route.binding.replica.length_bytes,
    });
    try environment.participants.configure(route.binding, route.backend_digest);
}

fn managerTestFenceRoute(environment: *ManagerTestEnvironment, route: ReplicaRoute, authority: protocol.AuthorityBinding) !void {
    _ = try environment.fence_control.accept(.{
        .operation_id = route.binding.replica.allocation_id,
        .volume_id = route.binding.replica.volume_id,
        .placement_id = route.binding.replica.placement_id,
        .replica_generation = route.binding.replica.generation,
        .write_epoch = authority.write_epoch,
        .primary_node_id = authority.primary_node_id,
        .lease_id = authority.lease_id,
        .authority_digest = authority.authority_digest,
    });
}

fn managerTestSigner(identity: write_service.WitnessIdentity, index: usize) !*protocol.write_evidence.Signer {
    const seed: protocol.write_evidence.Seed = @splat(@as(u8, @intCast(index + 21)));
    return protocol.write_evidence.Signer.init(
        std.testing.allocator,
        identity.member_id,
        identity.node_id,
        &seed,
    );
}

fn managerTestCompleteSignedWrite(
    manager: *WriteCoordinatorManager,
    environment: *ManagerTestEnvironment,
) !write_service.Frontier {
    const local = localRoute(environment.topology).?;
    const authority = managerTestAuthority(local.binding.replica.volume_id);
    var local_index: usize = undefined;
    for (environment.topology.routes, 0..) |route, index| {
        if (std.mem.eql(u8, &route.binding.replica.member_id, &environment.topology.local_member_id)) {
            local_index = index;
            break;
        }
    }
    const remote_index: usize = if (local_index == 0) 1 else 0;
    const selected = [2]usize{ local_index, remote_index };
    for (selected) |index| {
        const route = environment.topology.routes[index];
        if (index != local_index) try managerTestConfigureRoute(environment, route);
        try managerTestFenceRoute(environment, route, authority);
    }

    const data = "signed-completed-frontier";
    const write: write_service.WriteRequest = .{
        .authority = authority,
        .replica_members = local.binding.replica_members,
        .sequence = 1,
        .transaction_id = testId(81),
        .previous_history_digest = @splat(0),
        .offset_bytes = 0,
        .length_bytes = data.len,
        .data_digest = write_service.digestData(data),
    };
    const entry = manager.entries.get(key(
        local.binding.replica.placement_id,
        local.binding.replica.generation,
    )).?;
    try std.testing.expectEqual(coordinator.BeginResult.started, try entry.instance.begin(.{
        .write = write,
        .data = data,
        .witnesses = .{
            environment.topology.routes[local_index].binding.replica.member_id,
            environment.topology.routes[remote_index].binding.replica.member_id,
        },
    }));

    var prepare_evidence: [2]write_service.SignedPrepareEvidence = undefined;
    for (selected, 0..) |index, evidence_index| {
        const route = environment.topology.routes[index];
        const attestation = try environment.participants.prepareConfigured(
            route.binding,
            route.backend_digest,
            .{ .write = write, .data = data },
        );
        const signer = try managerTestSigner(route.binding.witness_identities[index], index);
        defer signer.deinit();
        prepare_evidence[evidence_index] = try signer.signPrepare(write, attestation);
        try entry.instance.recordPrepared(prepare_evidence[evidence_index]);
    }
    const certificate = try entry.instance.decide();
    var local_tuple: write_participant_manager.WriteParticipantManager.CommittedEvidenceTuple = undefined;
    for (selected) |index| {
        const route = environment.topology.routes[index];
        const tuple = try environment.participants.commitConfigured(
            route.binding,
            route.backend_digest,
            authority,
            write.transaction_id,
            write.sequence,
            certificate,
        );
        if (index == local_index) local_tuple = tuple;
    }
    const projected = try protocol.write_evidence_contract.certificateProjection(certificate);
    for (selected) |index| {
        const route = environment.topology.routes[index];
        const signer = try managerTestSigner(route.binding.witness_identities[index], index);
        defer signer.deinit();
        _ = try entry.instance.recordCommitted(try signer.signCommit(
            write,
            projected,
            local_tuple.result,
        ));
    }
    return .{
        .sequence = local_tuple.result.sequence,
        .history_digest = local_tuple.result.history_digest,
    };
}

test "topology rejects cross-volume and unequal logical geometry" {
    const replica: protocol.ReplicaBinding = .{
        .volume_id = testId(1),
        .placement_id = testId(2),
        .allocation_id = testId(3),
        .generation = 1,
        .member_id = testId(4),
        .offset_bytes = 4096,
        .length_bytes = 8192,
    };
    const topology = managerTestTopology(replica, @splat(0x55));
    try validateTopologyStructure(topology);

    var cross_volume = topology;
    cross_volume.routes[1].binding.replica.volume_id = testId(99);
    try std.testing.expectError(error.InvalidCoordinatorTopology, validateTopologyStructure(cross_volume));

    var unequal = topology;
    unequal.routes[2].binding.replica.length_bytes = 4096;
    try std.testing.expectError(error.InvalidCoordinatorTopology, validateTopologyStructure(unequal));
}

test "invalid coordinate request creates no durable intent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    var manager = try WriteCoordinatorManager.init(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        &environment.participants,
        identity,
        &environment.keys,
    );
    defer manager.deinit();
    try manager.configure(environment.topology);
    const local = localRoute(environment.topology).?;
    const payload = [_]u8{0x44} ** 4096;
    var authority = managerTestAuthority(local.binding.replica.volume_id);
    authority.primary_placement_id = local.binding.replica.placement_id;
    authority.primary_node_id = identity.node_id;
    try std.testing.expectError(error.InvalidWriteRequest, manager.coordinate(.{
        .authority = authority,
        .transaction_id = testId(80),
        .offset_bytes = 8192,
        .data = &payload,
    }));
    try std.testing.expectError(error.InvalidWriteRequest, manager.coordinate(.{
        .authority = authority,
        .transaction_id = testId(81),
        .offset_bytes = 1,
        .data = &payload,
    }));
    const oversized = try std.testing.allocator.alloc(u8, write_service.max_payload_size + 4096);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0x55);
    try std.testing.expectError(error.InvalidWriteRequest, manager.coordinate(.{
        .authority = authority,
        .transaction_id = testId(82),
        .offset_bytes = 0,
        .data = oversized,
    }));
    const entry = manager.entries.get(key(
        local.binding.replica.placement_id,
        local.binding.replica.generation,
    )).?;
    try std.testing.expect((try entry.instance.inspect()).pending == null);
}

test "pending missing prepare revalidates exact primary admission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    const signer_index = for (environment.topology.routes, 0..) |route, index| {
        if (std.mem.eql(u8, &route.binding.replica.member_id, &identity.member_id)) break index;
    } else unreachable;
    const signer = try managerTestSigner(identity, signer_index);
    defer signer.deinit();
    var manager = try WriteCoordinatorManager.initWithSigner(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        &environment.participants,
        signer,
        &environment.keys,
    );
    defer manager.deinit();
    try manager.configure(environment.topology);
    const local = localRoute(environment.topology).?;
    const payload = [_]u8{0x33} ** 4096;
    const authority = environment.validator.expected;
    const entry = manager.entries.get(key(
        local.binding.replica.placement_id,
        local.binding.replica.generation,
    )).?;
    _ = try entry.instance.begin(.{
        .write = .{
            .authority = authority,
            .replica_members = local.binding.replica_members,
            .sequence = 1,
            .transaction_id = testId(82),
            .previous_history_digest = @splat(0),
            .offset_bytes = 0,
            .length_bytes = payload.len,
            .data_digest = write_service.digestData(&payload),
        },
        .data = &payload,
        .witnesses = selectedWitnesses(environment.topology).?,
    });
    environment.validator.expected.lease_id = testId(90);
    try std.testing.expectError(error.AuthorityRejected, manager.recoverPending());
    try std.testing.expect((try entry.instance.inspect()).pending != null);
}

test "coordinator configure is exact and reopens durable unarmed topology" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        try manager.configure(environment.topology);
        try manager.configure(environment.topology);
        var conflict = environment.topology;
        conflict.routes[0].endpoint_bytes[0] ^= 1;
        try std.testing.expectError(error.CoordinatorTopologyConflict, manager.configure(conflict));
    }
    {
        var reopened = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer reopened.deinit();
        try reopened.configure(environment.topology);
    }
}

test "unarmed catalog recovers catalog-before-journal crash but armed missing journal fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    var faults: WriteCoordinatorManager.Faults = .{ .fail_journal_creation_once = true };
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        manager.setFaults(&faults);
        try std.testing.expectError(error.InjectedJournalCreationFailure, manager.configure(environment.topology));
        try std.testing.expectError(error.StorePoisoned, manager.configure(environment.topology));
    }
    const local = localRoute(environment.topology).?;
    {
        var reopened = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        try reopened.arm(local.binding.replica.placement_id, local.binding.replica.generation);
        reopened.deinit();
    }
    const name = managerTestJournalName(environment.topology);
    try tmp.dir.deleteFile(std.testing.io, &name);
    var lock_name: [journal_name_len + ".lock".len]u8 = undefined;
    @memcpy(lock_name[0..journal_name_len], &name);
    @memcpy(lock_name[journal_name_len..], ".lock");
    try tmp.dir.deleteFile(std.testing.io, &lock_name);
    try std.testing.expectError(
        error.CoordinatorStateMissing,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );
}

test "markerless catalog is recovered only with validated journal coverage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        try manager.configure(environment.topology);
    }
    try tmp.dir.deleteFile(std.testing.io, marker_basename);
    {
        var reopened = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        reopened.deinit();
    }
    try std.testing.expect(try markerPresent(std.testing.io, tmp.dir));

    try tmp.dir.deleteFile(std.testing.io, marker_basename);
    const name = managerTestJournalName(environment.topology);
    try tmp.dir.deleteFile(std.testing.io, &name);
    try std.testing.expectError(
        error.CoordinatorStateMissing,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );
}

test "marker present with missing catalog fails closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        manager.deinit();
    }
    try tmp.dir.deleteFile(std.testing.io, catalog_basename);
    try std.testing.expectError(
        error.CatalogMissing,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );
}

test "reopen revalidates outbound targets and local participant backend" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        try manager.configure(environment.topology);
    }
    try std.testing.expectError(
        error.OutboundReplicaCredentialMissing,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, environment.keys[0..1]),
    );
    var wrong_keys = environment.keys;
    wrong_keys[1].node_id = testId(99);
    try std.testing.expectError(
        error.OutboundReplicaCredentialMissing,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &wrong_keys),
    );
    var wrong_identity = identity;
    wrong_identity.node_id = testId(98);
    try std.testing.expectError(
        error.ReplicaSignerIdentityMismatch,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, wrong_identity, &environment.keys),
    );

    var drift = environment.topology;
    const local_index = for (&drift.routes, 0..) |*route, index| {
        if (std.mem.eql(u8, &route.binding.replica.member_id, &drift.local_member_id)) break index;
    } else unreachable;
    drift.routes[local_index].backend_digest[0] ^= 1;
    const records = [_]CatalogRecord{.{ .topology = drift }};
    try managerTestWriteCatalog(tmp.dir, &records);
    try std.testing.expectError(
        error.MemberBackendIdentityMismatch,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );
}

const ManagerCatalogFault = enum { file_sync, rename, directory_sync };

fn runManagerCatalogFault(fault: ManagerCatalogFault) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    var faults: WriteCoordinatorManager.Faults = switch (fault) {
        .file_sync => .{ .fail_catalog_file_sync_once = true },
        .rename => .{ .fail_catalog_rename_once = true },
        .directory_sync => .{ .fail_directory_sync_once = true },
    };
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        manager.setFaults(&faults);
        const expected = switch (fault) {
            .file_sync => error.InjectedCatalogFileSyncFailure,
            .rename => error.InjectedCatalogRenameFailure,
            .directory_sync => error.InjectedDirectorySyncFailure,
        };
        try std.testing.expectError(expected, manager.configure(environment.topology));
        if (fault == .directory_sync) {
            try std.testing.expectError(error.StorePoisoned, manager.configure(environment.topology));
        } else {
            try manager.configure(environment.topology);
        }
    }
    if (fault == .directory_sync) {
        // Rename succeeded but directory durability was uncertain. Restart
        // accepts the durable catalog only if present and reconstructs its
        // still-unarmed missing journal.
        var reopened = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer reopened.deinit();
        try reopened.configure(environment.topology);
    }
}

test "catalog file-sync and rename faults retry while directory-sync uncertainty poisons" {
    for (std.enums.values(ManagerCatalogFault)) |fault| try runManagerCatalogFault(fault);
}

test "coordinator retained basename survives stack churn and reopen mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    const local = localRoute(environment.topology).?;
    const data = "path-lifetime";
    const witnesses = blk: {
        var result: [2]protocol.Id = undefined;
        var next: usize = 0;
        for (environment.topology.routes) |route| {
            if (next == result.len) break;
            result[next] = route.binding.replica.member_id;
            next += 1;
        }
        break :blk result;
    };
    const request: coordinator.BeginRequest = .{
        .write = .{
            .authority = managerTestAuthority(local.binding.replica.volume_id),
            .replica_members = local.binding.replica_members,
            .sequence = 1,
            .transaction_id = testId(71),
            .previous_history_digest = @splat(0),
            .offset_bytes = 0,
            .length_bytes = data.len,
            .data_digest = write_service.digestData(data),
        },
        .data = data,
        .witnesses = witnesses,
    };
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        try manager.configure(environment.topology);
        var churn: [64][journal_name_len]u8 = undefined;
        @memset(std.mem.asBytes(&churn), 0xa5);
        const entry = manager.entries.get(key(local.binding.replica.placement_id, local.binding.replica.generation)).?;
        try std.testing.expectEqual(coordinator.BeginResult.started, try entry.instance.begin(request));
    }
    {
        var reopened = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer reopened.deinit();
        const entry = reopened.entries.get(key(local.binding.replica.placement_id, local.binding.replica.generation)).?;
        try std.testing.expectEqual(coordinator.BeginResult.retry, try entry.instance.begin(request));
    }
}

test "coordinator startup rejects malformed catalog and journal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        try manager.configure(environment.topology);
    }
    const name = managerTestJournalName(environment.topology);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = &name,
        .data = "malformed coordinator journal",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.StoreCorrupt,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );

    // Restore an unarmed catalog crash window, then corrupt the catalog itself.
    try tmp.dir.deleteFile(std.testing.io, &name);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = catalog_basename,
        .data = "malformed coordinator catalog",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.StoreCorrupt,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );
}

test "coordinator startup rejects orphan and noncanonical journal names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        manager.deinit();
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "coordinator-orphan.state",
        .data = "orphan",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.OrphanCoordinatorState,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );
    try tmp.dir.deleteFile(std.testing.io, "coordinator-orphan.state");

    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        try manager.configure(environment.topology);
    }
    const canonical = managerTestJournalName(environment.topology);
    var alias = canonical;
    for (alias[journal_prefix.len .. alias.len - journal_suffix.len]) |*character| {
        if (character.* >= 'a' and character.* <= 'f') {
            character.* -= 'a' - 'A';
            break;
        }
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = &alias,
        .data = "noncanonical alias",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.OrphanCoordinatorState,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );
}

test "armed state is durable and rejects empty certified recovery after reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    const local = localRoute(environment.topology).?;
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        try manager.configure(environment.topology);
        try manager.arm(local.binding.replica.placement_id, local.binding.replica.generation);
    }
    {
        var reopened = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer reopened.deinit();
        try std.testing.expectError(
            error.RecoveryQuorumRequired,
            reopened.certifiedFrontier(local.binding.replica.volume_id),
        );
    }
}

test "reopen fails closed for a retired historical local participant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    const local = localRoute(environment.topology).?;
    {
        var manager = try WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys);
        defer manager.deinit();
        try manager.configure(environment.topology);
    }
    var guard = try environment.participants.beginControl(
        local.binding.replica.placement_id,
        local.binding.replica.generation,
        true,
    );
    try guard.retire();
    guard.end();
    try std.testing.expectError(
        error.ReplicaRetired,
        WriteCoordinatorManager.init(std.testing.allocator, std.testing.io, tmp.dir, &environment.participants, identity, &environment.keys),
    );
}

fn managerTestAdvanceParticipants(
    environment: *ManagerTestEnvironment,
    previous: write_service.Frontier,
) !write_service.Frontier {
    const local = localRoute(environment.topology).?;
    const authority = managerTestAuthority(local.binding.replica.volume_id);
    var local_index: usize = 0;
    for (environment.topology.routes, 0..) |route, index| if (std.mem.eql(u8, &route.binding.replica.member_id, &environment.topology.local_member_id)) {
        local_index = index;
        break;
    };
    const remote_index: usize = if (local_index == 0) 1 else 0;
    const selected = [2]usize{ local_index, remote_index };
    const data = "participant-frontier-ahead";
    const write: write_service.WriteRequest = .{
        .authority = authority,
        .replica_members = local.binding.replica_members,
        .sequence = previous.sequence + 1,
        .transaction_id = testId(82),
        .previous_history_digest = previous.history_digest,
        .offset_bytes = 64,
        .length_bytes = data.len,
        .data_digest = write_service.digestData(data),
    };
    var evidence: [2]write_service.SignedPrepareEvidence = undefined;
    for (selected, 0..) |index, evidence_index| {
        const route = environment.topology.routes[index];
        const attestation = try environment.participants.prepareConfigured(
            route.binding,
            route.backend_digest,
            .{ .write = write, .data = data },
        );
        const signer = try managerTestSigner(route.binding.witness_identities[index], index);
        defer signer.deinit();
        evidence[evidence_index] = try signer.signPrepare(write, attestation);
    }
    const certificate = try protocol.write_evidence_contract.normalizeSignedCertificate(.{
        .prepare_evidence = evidence,
    });
    var local_result: write_service.CommitResult = undefined;
    for (selected) |index| {
        const route = environment.topology.routes[index];
        const tuple = try environment.participants.commitConfigured(
            route.binding,
            route.backend_digest,
            authority,
            write.transaction_id,
            write.sequence,
            certificate,
        );
        if (index == local_index) local_result = tuple.result;
    }
    return .{ .sequence = local_result.sequence, .history_digest = local_result.history_digest };
}

test "armed certified frontier requires matching signed coordinator and active local participant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    const local = localRoute(environment.topology).?;
    var manager = try WriteCoordinatorManager.init(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        &environment.participants,
        identity,
        &environment.keys,
    );
    defer manager.deinit();
    try manager.configure(environment.topology);
    const completed = try managerTestCompleteSignedWrite(&manager, &environment);
    try manager.arm(local.binding.replica.placement_id, local.binding.replica.generation);
    try std.testing.expectEqual(
        completed,
        (try manager.certifiedFrontier(local.binding.replica.volume_id)).?,
    );
}

test "armed certified frontier rejects participant coordinator disagreement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    const local = localRoute(environment.topology).?;
    var manager = try WriteCoordinatorManager.init(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        &environment.participants,
        identity,
        &environment.keys,
    );
    defer manager.deinit();
    try manager.configure(environment.topology);
    const completed = try managerTestCompleteSignedWrite(&manager, &environment);
    _ = try managerTestAdvanceParticipants(&environment, completed);
    try manager.arm(local.binding.replica.placement_id, local.binding.replica.generation);
    try std.testing.expectError(
        error.CoordinatorHistoryConflict,
        manager.certifiedFrontier(local.binding.replica.volume_id),
    );
}

test "armed certified frontier rejects live retired local participant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var environment: ManagerTestEnvironment = undefined;
    try environment.init(tmp.dir);
    defer environment.deinit();
    const identity = managerTestIdentity(environment.topology);
    const local = localRoute(environment.topology).?;
    var manager = try WriteCoordinatorManager.init(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        &environment.participants,
        identity,
        &environment.keys,
    );
    defer manager.deinit();
    try manager.configure(environment.topology);
    _ = try managerTestCompleteSignedWrite(&manager, &environment);
    try manager.arm(local.binding.replica.placement_id, local.binding.replica.generation);
    var guard = try environment.participants.beginControl(
        local.binding.replica.placement_id,
        local.binding.replica.generation,
        true,
    );
    try guard.retire();
    guard.end();
    try std.testing.expectError(
        error.ReplicaRetired,
        manager.certifiedFrontier(local.binding.replica.volume_id),
    );
}

test "durable coordinator presence detection rejects suspicious downgrade state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(!try durableStatePresent(std.testing.allocator, std.testing.io, tmp.dir));
    const empty = [_]CatalogRecord{};
    try managerTestWriteCatalog(tmp.dir, &empty);
    try createMarker(std.testing.io, tmp.dir);
    try std.testing.expect(try durableStatePresent(std.testing.allocator, std.testing.io, tmp.dir));
    try tmp.dir.deleteFile(std.testing.io, marker_basename);
    try tmp.dir.deleteFile(std.testing.io, catalog_basename);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "coordinator-not-canonical.state",
        .data = "suspicious",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.SuspiciousCoordinatorState,
        durableStatePresent(std.testing.allocator, std.testing.io, tmp.dir),
    );
    try tmp.dir.deleteFile(std.testing.io, "coordinator-not-canonical.state");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "catalog-target",
        .data = "not a catalog",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try tmp.dir.symLink(std.testing.io, "catalog-target", catalog_basename, .{});
    try std.testing.expectError(
        error.SuspiciousCoordinatorState,
        durableStatePresent(std.testing.allocator, std.testing.io, tmp.dir),
    );
    try tmp.dir.deleteFile(std.testing.io, catalog_basename);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = catalog_basename,
        .data = "malformed catalog",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.StoreCorrupt,
        durableStatePresent(std.testing.allocator, std.testing.io, tmp.dir),
    );
}
