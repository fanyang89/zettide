const std = @import("std");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const genesis_payload = @import("genesis_payload.zig");
const member_api = @import("member.zig");
const topology_format = @import("topology.zig");

pub const CheckpointStatus = enum { none, valid, stale, invalid };

pub const ScanResult = struct {
    tail: ?control_record.Record = null,
    tail_raw_record_digest: codec.Digest = @splat(0),
    tail_physical_slot: ?u64 = null,
    physical_frontier: u64 = 0,
    slot_count: u64,
    zero_hole_count: u64 = 0,
    invalid_slot_count: u64 = 0,
    interior_invalid_slot_count: u64 = 0,
    unresolved_tail_damage: bool = false,
    journal_full: bool = false,
    checkpoint_status: CheckpointStatus = .none,
};

pub const AppendResult = struct {
    record: control_record.Record,
    record_digest: codec.Digest,
    physical_slot: u64,
};

pub const TailToken = struct {
    local_sequence: u64,
    raw_record_digest: codec.Digest,
    history_digest: codec.Digest,
    physical_frontier: u64,
};

pub const PreparedAppend = struct {
    expected_tail: TailToken,
    record: control_record.Record,
    encoded: [control_record.encoded_size]u8,
    record_digest: codec.Digest,
    physical_slot: u64,
};

pub const HistoryEntry = struct {
    record: control_record.Record,
    raw_record: [control_record.encoded_size]u8,
    raw_record_digest: codec.Digest,
    physical_slot: u64,
};

pub const HistoryScan = struct {
    scan_result: ScanResult,
    member_id: [16]u8,
    storage: []HistoryEntry,
    entry_count: usize,
    allocator: std.mem.Allocator,

    pub fn entries(self: *const HistoryScan) []const HistoryEntry {
        return self.storage[0..self.entry_count];
    }

    pub fn findHistoryDigest(self: *const HistoryScan, digest: codec.Digest) ?*const HistoryEntry {
        for (self.entries()) |*entry| {
            if (std.mem.eql(u8, &entry.record.history_digest, &digest)) return entry;
        }
        return null;
    }

    pub fn findRawRecordDigest(self: *const HistoryScan, digest: codec.Digest) ?*const HistoryEntry {
        for (self.entries()) |*entry| {
            if (std.mem.eql(u8, &entry.raw_record_digest, &digest)) return entry;
        }
        return null;
    }

    pub fn deinit(self: *HistoryScan) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const Journal = struct {
    member: *member_api.Member,
    scan_state: ScanResult,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    pub fn open(member: *member_api.Member) !Journal {
        try member.claimJournal();
        errdefer member.releaseJournal();
        const scan_state = try scan(member);
        if (scan_state.tail == null) {
            if (scan_state.unresolved_tail_damage) return error.JournalNeedsRecovery;
            return error.MissingGenesis;
        }
        if (member.mode() == .writable and scan_state.unresolved_tail_damage)
            return error.JournalNeedsRecovery;
        return .{ .member = member, .scan_state = scan_state };
    }

    pub fn state(self: *Journal) !ScanResult {
        try self.mutex.lock(self.member.io);
        defer self.mutex.unlock(self.member.io);
        if (self.closed) return error.JournalClosed;
        if (self.member.isClosed()) return error.MemberClosed;
        return self.scan_state;
    }

    pub fn tailToken(self: *Journal) !TailToken {
        try self.mutex.lock(self.member.io);
        defer self.mutex.unlock(self.member.io);
        try self.checkOpenLocked();
        return self.tailTokenLocked();
    }

    pub fn prepareExact(
        self: *Journal,
        expected_tail: TailToken,
        proposal: control_record.Record,
    ) !PreparedAppend {
        try self.mutex.lock(self.member.io);
        defer self.mutex.unlock(self.member.io);
        if (proposal.kind == control_record.checkpoint_kind) return error.UseCheckpointApi;
        return self.prepareLocked(proposal, expected_tail);
    }

    pub fn appendPrepared(self: *Journal, prepared: *const PreparedAppend) !AppendResult {
        try self.mutex.lock(self.member.io);
        defer self.mutex.unlock(self.member.io);
        if (prepared.record.kind == control_record.checkpoint_kind) return error.UseCheckpointApi;
        const canonical = try self.prepareLocked(prepared.record, prepared.expected_tail);
        if (!std.meta.eql(canonical, prepared.*)) return error.PreparedAppendMismatch;
        return self.commitPreparedLocked(canonical);
    }

    pub fn close(self: *Journal) void {
        self.mutex.lockUncancelable(self.member.io);
        defer self.mutex.unlock(self.member.io);
        if (self.closed) return;
        self.closed = true;
        self.member.releaseJournal();
    }

    pub fn deinit(self: *Journal) void {
        self.close();
    }

    pub fn append(self: *Journal, proposal: control_record.Record) !AppendResult {
        try self.mutex.lock(self.member.io);
        defer self.mutex.unlock(self.member.io);

        if (self.closed) return error.JournalClosed;
        if (self.member.isClosed()) return error.MemberClosed;
        if (proposal.kind == control_record.checkpoint_kind) return error.UseCheckpointApi;
        return self.appendLocked(proposal);
    }

    pub fn checkpoint(self: *Journal, proposal: control_record.Record) !AppendResult {
        try self.mutex.lock(self.member.io);
        defer self.mutex.unlock(self.member.io);

        if (self.closed) return error.JournalClosed;
        if (self.member.isClosed()) return error.MemberClosed;
        if (proposal.kind != control_record.checkpoint_kind) return error.NotCheckpointRecord;
        const appended = try self.appendLocked(proposal);
        const header = self.member.header();
        const relative_offset = std.math.mul(u64, appended.physical_slot, control_record.encoded_size) catch
            return error.ControlOffsetOverflow;
        const absolute_offset = std.math.add(u64, header.control.offset, relative_offset) catch
            return error.ControlOffsetOverflow;
        try self.member.publishCheckpoint(absolute_offset, appended.record.local_sequence, appended.record_digest);
        self.scan_state.checkpoint_status = .valid;
        return appended;
    }

    fn appendLocked(self: *Journal, proposal: control_record.Record) !AppendResult {
        const expected_tail = if (self.scan_state.tail != null) try self.tailTokenLocked() else null;
        const prepared = try self.prepareLocked(proposal, expected_tail);
        return self.commitPreparedLocked(prepared);
    }

    fn prepareLocked(
        self: *Journal,
        proposal: control_record.Record,
        expected_tail: ?TailToken,
    ) !PreparedAppend {
        try self.checkOpenLocked();
        if (self.member.mode() != .writable) return error.ReadOnlyMember;
        if (self.member.isFrozen()) return error.WriteFrozen;
        if (self.scan_state.unresolved_tail_damage) return error.UnresolvedTailDamage;
        if (self.scan_state.journal_full) return error.JournalFull;

        if (expected_tail) |expected| {
            if (!std.meta.eql(expected, try self.tailTokenLocked())) return error.StaleTailToken;
        } else if (self.scan_state.tail != null) {
            return error.StaleTailToken;
        }

        var record = proposal;
        const header = self.member.header();
        record.set_id = header.set_id;
        record.member_id = header.member_id;
        if (self.scan_state.tail) |tail| {
            if (record.kind == control_record.genesis_kind) return error.SecondGenesisRecord;
            record.local_sequence = std.math.add(u64, tail.local_sequence, 1) catch
                return error.RecordSequenceOverflow;
            record.previous_record_digest = self.scan_state.tail_raw_record_digest;
            record.previous_history_digest = tail.history_digest;
        } else {
            if (record.kind != control_record.genesis_kind) return error.NotGenesisRecord;
            record.local_sequence = 1;
            record.previous_record_digest = @splat(0);
            record.previous_history_digest = @splat(0);
        }
        record.history_digest = try control_record.historyDigest(record);

        if (record.kind == control_record.genesis_kind) {
            try validateGenesis(header, record);
        } else {
            try control_record.validatePolicy(record);
        }
        const encoded = try control_record.encode(record);
        const physical_slot = self.scan_state.physical_frontier;
        return .{
            .expected_tail = expected_tail orelse .{
                .local_sequence = 0,
                .raw_record_digest = @splat(0),
                .history_digest = @splat(0),
                .physical_frontier = 0,
            },
            .record = record,
            .encoded = encoded,
            .record_digest = control_record.recordDigest(&encoded),
            .physical_slot = physical_slot,
        };
    }

    fn commitPreparedLocked(self: *Journal, prepared: PreparedAppend) !AppendResult {
        const offset = std.math.mul(u64, prepared.physical_slot, control_record.encoded_size) catch
            return error.ControlOffsetOverflow;
        try self.member.writeDurable(.control, offset, &prepared.encoded);

        self.scan_state.tail = prepared.record;
        self.scan_state.tail_raw_record_digest = prepared.record_digest;
        self.scan_state.tail_physical_slot = prepared.physical_slot;
        self.scan_state.physical_frontier = std.math.add(u64, prepared.physical_slot, 1) catch unreachable;
        self.scan_state.journal_full = self.scan_state.physical_frontier == self.scan_state.slot_count;
        if (self.scan_state.checkpoint_status == .valid) self.scan_state.checkpoint_status = .stale;
        return .{
            .record = prepared.record,
            .record_digest = prepared.record_digest,
            .physical_slot = prepared.physical_slot,
        };
    }

    fn checkOpenLocked(self: *const Journal) !void {
        if (self.closed) return error.JournalClosed;
        if (self.member.isClosed()) return error.MemberClosed;
    }

    fn tailTokenLocked(self: *const Journal) !TailToken {
        const tail = self.scan_state.tail orelse return error.MissingGenesis;
        return .{
            .local_sequence = tail.local_sequence,
            .raw_record_digest = self.scan_state.tail_raw_record_digest,
            .history_digest = tail.history_digest,
            .physical_frontier = self.scan_state.physical_frontier,
        };
    }
};

fn validateGenesis(header: member_format.Header, record: control_record.Record) !void {
    const payload = try genesis_payload.validateRecord(record);
    const genesis_digest = try topology_format.digest(payload.topology);
    try topology_format.validateMemberHeader(payload.topology, genesis_digest, header);
    if (header.chunk_size != payload.layout.chunk_size) return error.ChunkSizeMismatch;
}

pub fn scan(member: *member_api.Member) !ScanResult {
    return scanInto(member, null);
}

pub fn scanHistory(allocator: std.mem.Allocator, member: *member_api.Member) !HistoryScan {
    const header = member.header();
    const slot_count = header.control.length / control_record.encoded_size;
    const storage = try allocator.alloc(
        HistoryEntry,
        std.math.cast(usize, slot_count) orelse return error.JournalTooLarge,
    );
    errdefer allocator.free(storage);
    var history: HistoryScan = .{
        .scan_result = undefined,
        .member_id = header.member_id,
        .storage = storage,
        .entry_count = 0,
        .allocator = allocator,
    };
    history.scan_result = try scanInto(member, &history);
    return history;
}

fn scanInto(member: *member_api.Member, history: ?*HistoryScan) !ScanResult {
    const header = member.header();
    const slot_count = header.control.length / control_record.encoded_size;
    var result: ScanResult = .{ .slot_count = slot_count };
    const hint_slot: ?u64 = if (header.checkpoint_offset == 0)
        null
    else
        (header.checkpoint_offset - header.control.offset) / control_record.encoded_size;
    if (hint_slot != null) result.checkpoint_status = .invalid;
    var matched_hint = false;
    var pending_zero_slots: u64 = 0;
    var pending_invalid_slots: u64 = 0;

    for (0..slot_count) |slot_index| {
        const slot: u64 = @intCast(slot_index);
        const offset = std.math.mul(u64, slot, control_record.encoded_size) catch
            return error.ControlOffsetOverflow;
        var raw: [control_record.encoded_size]u8 = undefined;
        try member.read(.control, offset, &raw);

        if (codec.isZero(&raw)) {
            pending_zero_slots = std.math.add(u64, pending_zero_slots, 1) catch
                return error.ScanCountOverflow;
            continue;
        }

        result.physical_frontier = std.math.add(u64, slot, 1) catch
            return error.ControlFrontierOverflow;
        result.zero_hole_count = std.math.add(u64, result.zero_hole_count, pending_zero_slots) catch
            return error.ScanCountOverflow;
        pending_zero_slots = 0;

        const record = control_record.decode(&raw) catch {
            result.invalid_slot_count = std.math.add(u64, result.invalid_slot_count, 1) catch
                return error.ScanCountOverflow;
            pending_invalid_slots = std.math.add(u64, pending_invalid_slots, 1) catch
                return error.ScanCountOverflow;
            continue;
        };

        if (!std.mem.eql(u8, &record.set_id, &header.set_id)) return error.ForeignSet;
        if (!std.mem.eql(u8, &record.member_id, &header.member_id)) return error.ForeignMember;

        if (result.tail) |tail| {
            if (record.kind == control_record.genesis_kind) return error.SecondGenesisRecord;
            try control_record.validatePolicy(record);
            if (record.local_sequence == tail.local_sequence)
                return error.DuplicateRecordSequence;
            if (record.local_sequence < tail.local_sequence)
                return error.RecordSequenceRegression;
            const expected_sequence = std.math.add(u64, tail.local_sequence, 1) catch
                return error.RecordSequenceGap;
            if (record.local_sequence != expected_sequence) return error.RecordSequenceGap;
            if (!std.mem.eql(u8, &record.previous_record_digest, &result.tail_raw_record_digest))
                return error.PreviousRecordDigestMismatch;
            if (!std.mem.eql(u8, &record.previous_history_digest, &tail.history_digest))
                return error.PreviousHistoryDigestMismatch;
        } else {
            try validateGenesis(header, record);
        }

        result.interior_invalid_slot_count = std.math.add(
            u64,
            result.interior_invalid_slot_count,
            pending_invalid_slots,
        ) catch return error.ScanCountOverflow;
        pending_invalid_slots = 0;
        const raw_record_digest = control_record.recordDigest(&raw);
        result.tail = record;
        result.tail_raw_record_digest = raw_record_digest;
        result.tail_physical_slot = slot;
        if (history) |evidence| {
            std.debug.assert(evidence.entry_count < evidence.storage.len);
            evidence.storage[evidence.entry_count] = .{
                .record = record,
                .raw_record = raw,
                .raw_record_digest = raw_record_digest,
                .physical_slot = slot,
            };
            evidence.entry_count += 1;
        }
        if (hint_slot == slot and
            record.kind == control_record.checkpoint_kind and
            record.local_sequence == header.checkpoint_record_sequence and
            std.mem.eql(u8, &result.tail_raw_record_digest, &header.checkpoint_record_digest))
        {
            matched_hint = true;
            result.checkpoint_status = .valid;
        } else if (matched_hint) {
            result.checkpoint_status = .stale;
        }
    }

    result.unresolved_tail_damage = pending_invalid_slots != 0;
    result.journal_full = result.physical_frontier == result.slot_count;
    return result;
}

pub fn validateGenerationCommitEvidence(
    commit_member_id: [16]u8,
    commit_raw_record_digest: codec.Digest,
    histories: []const *const HistoryScan,
    topology: topology_format.Topology,
) !control_record.CommitCertificate {
    const commit_entry = try findEvidenceRecord(
        histories,
        commit_member_id,
        commit_raw_record_digest,
        error.MissingCommitMember,
        error.MissingCommitRecord,
    );
    const commit = try verifiedRecord(commit_entry);
    if (commit.kind != control_record.generation_commit_kind) return error.NotGenerationCommit;
    if (!std.mem.eql(u8, &commit.member_id, &commit_member_id))
        return error.CommitMemberMismatch;
    var commit_member_is_voter = false;
    for (topology.members) |topology_member| {
        if (!std.mem.eql(u8, &topology_member.member_id, &commit.member_id)) continue;
        if (topology_member.control_role != topology_format.voter_role)
            return error.CommitMemberIsNotVoter;
        commit_member_is_voter = true;
        break;
    }
    if (!commit_member_is_voter) return error.CommitMemberNotInTopology;
    var certificate_bytes: [control_record.certificate_size]u8 = undefined;
    if (commit.payload.len != certificate_bytes.len) return error.InvalidCertificatePayloadLength;
    @memcpy(&certificate_bytes, commit.payload.slice());
    const certificate = try control_record.decodeCertificate(&certificate_bytes);
    try control_record.validateAgainstTopology(certificate, topology);
    if (!std.mem.eql(u8, &commit.set_id, &topology.set_id)) return error.ForeignSet;
    if (commit.membership_epoch != topology.epoch) return error.MembershipEpochMismatch;
    if (!std.mem.eql(u8, &commit.topology_digest, &(try topology_format.digest(topology))))
        return error.TopologyDigestMismatch;

    const prepare_history_digest = certificate.attestations[0].prepare_history_digest;
    if (!std.mem.eql(u8, &commit.previous_history_digest, &prepare_history_digest))
        return error.CommitDoesNotExtendPrepare;

    for (certificate.attestations) |attestation| {
        const prepare_entry = try findEvidenceRecord(
            histories,
            attestation.member_id,
            attestation.prepare_record_digest,
            error.MissingPrepareMember,
            error.MissingPrepareRecord,
        );
        const prepare = try verifiedRecord(prepare_entry);
        if (prepare.kind != control_record.generation_prepare_kind)
            return error.AttestedRecordIsNotPrepare;
        if (!std.mem.eql(u8, &prepare.member_id, &attestation.member_id))
            return error.PrepareMemberMismatch;
        if (!std.mem.eql(u8, &prepare.history_digest, &attestation.prepare_history_digest))
            return error.PrepareHistoryDigestMismatch;
        try validatePrepareCommitBinding(&prepare, &commit);
    }
    return certificate;
}

fn findEvidenceRecord(
    histories: []const *const HistoryScan,
    member_id: [16]u8,
    raw_record_digest: codec.Digest,
    missing_member_error: anyerror,
    missing_record_error: anyerror,
) !*const HistoryEntry {
    var matching_history: ?*const HistoryScan = null;
    for (histories) |history| {
        if (!std.mem.eql(u8, &history.member_id, &member_id)) continue;
        if (matching_history != null) return error.DuplicateMemberHistory;
        matching_history = history;
    }
    const history = matching_history orelse return missing_member_error;
    return history.findRawRecordDigest(raw_record_digest) orelse missing_record_error;
}

fn verifiedRecord(entry: *const HistoryEntry) !control_record.Record {
    if (!std.mem.eql(
        u8,
        &entry.raw_record_digest,
        &control_record.recordDigest(&entry.raw_record),
    )) return error.EvidenceRecordDigestMismatch;
    const record = try control_record.decode(&entry.raw_record);
    try control_record.validatePolicy(record);
    if (!std.meta.eql(record, entry.record)) return error.EvidenceRecordMismatch;
    return record;
}

fn validatePrepareCommitBinding(
    prepare: *const control_record.Record,
    commit: *const control_record.Record,
) !void {
    if (!std.mem.eql(u8, &prepare.history_digest, &commit.previous_history_digest))
        return error.CommitDoesNotExtendPrepare;
    if (!std.mem.eql(u8, &prepare.set_id, &commit.set_id) or
        prepare.membership_epoch != commit.membership_epoch or
        prepare.writer_term != commit.writer_term or
        prepare.generation != commit.generation or
        !std.mem.eql(u8, &prepare.mount_session_id, &commit.mount_session_id) or
        !std.mem.eql(u8, &prepare.transaction_id, &commit.transaction_id) or
        !std.mem.eql(u8, &prepare.data_root_digest, &commit.data_root_digest) or
        !std.mem.eql(u8, &prepare.topology_digest, &commit.topology_digest) or
        !std.mem.eql(u8, &prepare.layout_digest, &commit.layout_digest))
        return error.PrepareCommitMismatch;
}

const member_format = @import("member_format.zig");

fn testPayload() genesis_payload.GenesisPayload {
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

fn testHeader(slot_count: u64) !member_format.Header {
    const payload = testPayload();
    const control_end = 64 * 1024 + slot_count * control_record.encoded_size;
    const metadata_offset = try codec.alignForward(control_end, 1024 * 1024);
    const metadata_end = metadata_offset + 256 * 1024;
    const data_offset = try codec.alignForward(metadata_end, 1024 * 1024);
    return .{
        .header_sequence = 1,
        .set_id = payload.topology.set_id,
        .member_id = payload.topology.members[0].member_id,
        .member_slot = 0,
        .created_ns = 1,
        .member_bytes = data_offset + 1024 * 1024,
        .logical_capacity = 1024 * 1024,
        .control = .{ .offset = 64 * 1024, .length = slot_count * control_record.encoded_size },
        .metadata = .{ .offset = metadata_offset, .length = 256 * 1024 },
        .data = .{ .offset = data_offset, .length = 1024 * 1024 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = 1024 * 1024,
        .metadata_format_version = 1,
        .object_format_version = 1,
        .layout_format_version = 1,
        .control_record_format_version = 1,
        .label = try member_format.Label.init("journal-test"),
        .genesis_topology_digest = try topology_format.digest(payload.topology),
    };
}

fn createMember(dir: std.Io.Dir, name: []const u8, slot_count: u64) !member_format.Header {
    const header = try testHeader(slot_count);
    try createMemberWithHeader(dir, name, header);
    return header;
}

fn createInitializedMember(dir: std.Io.Dir, name: []const u8, slot_count: u64) !member_format.Header {
    const header = try createMember(dir, name, slot_count);
    try writeSlot(dir, name, header, 0, &(try genesisBytes()));
    return header;
}

fn createMemberWithHeader(dir: std.Io.Dir, name: []const u8, header: member_format.Header) !void {
    const file = try dir.createFile(std.testing.io, name, .{ .read = true });
    defer file.close(std.testing.io);
    const bytes = try member_format.encode(header);
    try file.writePositionalAll(std.testing.io, &bytes, 0);
    try file.writePositionalAll(std.testing.io, &bytes, member_format.encoded_size);
    try file.setLength(std.testing.io, header.member_bytes);
}

fn writeSlot(dir: std.Io.Dir, name: []const u8, header: member_format.Header, slot: u64, bytes: []const u8) !void {
    const file = try dir.openFile(std.testing.io, name, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(
        std.testing.io,
        bytes,
        header.control.offset + slot * control_record.encoded_size,
    );
}

fn writeHeaders(dir: std.Io.Dir, name: []const u8, header: member_format.Header) !void {
    const file = try dir.openFile(std.testing.io, name, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const bytes = try member_format.encode(header);
    try file.writePositionalAll(std.testing.io, &bytes, 0);
    try file.writePositionalAll(std.testing.io, &bytes, member_format.encoded_size);
}

fn genesisBytes() ![control_record.encoded_size]u8 {
    const payload = testPayload();
    return control_record.encode(try genesis_payload.makeRecord(payload.topology.members[0].member_id, payload));
}

fn genesisProposal() !control_record.Record {
    var record = try genesis_payload.makeRecord(@splat(0x20), testPayload());
    record.set_id = @splat(0x81);
    record.member_id = @splat(0x82);
    record.local_sequence = 99;
    record.previous_record_digest = @splat(0x83);
    record.previous_history_digest = @splat(0x84);
    record.history_digest = @splat(0x85);
    return record;
}

fn writerFenceProposal(previous: control_record.Record) !control_record.Record {
    var record: control_record.Record = .{
        .kind = control_record.writer_fence_kind,
        .local_sequence = 99,
        .membership_epoch = previous.membership_epoch,
        .writer_term = 1,
        .generation = previous.generation,
        .set_id = @splat(0x91),
        .member_id = @splat(0x92),
        .mount_session_id = @splat(0x50),
        .transaction_id = @splat(0x60),
        .previous_record_digest = @splat(0x93),
        .previous_history_digest = @splat(0x94),
        .history_digest = @splat(0x95),
        .data_root_digest = @splat(0),
        .topology_digest = previous.topology_digest,
        .layout_digest = previous.layout_digest,
    };
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

fn checkpointProposal(previous: control_record.Record) !control_record.Record {
    var record = try writerFenceProposal(previous);
    record.kind = control_record.checkpoint_kind;
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

fn appendWorker(journal: *Journal, proposal: control_record.Record) !AppendResult {
    return journal.append(proposal);
}

fn nextRecord(previous: control_record.Record, previous_raw: *const [control_record.encoded_size]u8) !control_record.Record {
    var record: control_record.Record = .{
        .kind = control_record.writer_fence_kind,
        .local_sequence = previous.local_sequence + 1,
        .membership_epoch = previous.membership_epoch,
        .writer_term = 1,
        .generation = previous.generation,
        .set_id = previous.set_id,
        .member_id = previous.member_id,
        .mount_session_id = @splat(0x50),
        .transaction_id = @splat(0x60),
        .previous_record_digest = control_record.recordDigest(previous_raw),
        .previous_history_digest = previous.history_digest,
        .data_root_digest = @splat(0),
        .topology_digest = previous.topology_digest,
        .layout_digest = previous.layout_digest,
    };
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

fn generationPrepare(
    genesis: control_record.Record,
    genesis_raw: *const [control_record.encoded_size]u8,
) !control_record.Record {
    var record: control_record.Record = .{
        .kind = control_record.generation_prepare_kind,
        .local_sequence = 2,
        .membership_epoch = genesis.membership_epoch,
        .writer_term = 1,
        .generation = 1,
        .set_id = genesis.set_id,
        .member_id = genesis.member_id,
        .mount_session_id = @splat(0x50),
        .transaction_id = @splat(0x60),
        .previous_record_digest = control_record.recordDigest(genesis_raw),
        .previous_history_digest = genesis.history_digest,
        .data_root_digest = @splat(0x70),
        .topology_digest = genesis.topology_digest,
        .layout_digest = genesis.layout_digest,
        .payload = try control_record.Payload.init("generation prepare"),
    };
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

fn generationCommit(
    prepare: control_record.Record,
    prepare_raw: *const [control_record.encoded_size]u8,
    certificate: control_record.CommitCertificate,
) !control_record.Record {
    var record = prepare;
    record.kind = control_record.generation_commit_kind;
    record.local_sequence += 1;
    record.previous_record_digest = control_record.recordDigest(prepare_raw);
    record.previous_history_digest = prepare.history_digest;
    record.payload = try control_record.Payload.init(&(try control_record.encodeCertificate(certificate)));
    record.history_digest = try control_record.historyDigest(record);
    return record;
}

fn fixChecksum(bytes: *[control_record.encoded_size]u8) void {
    codec.putInt(
        u32,
        bytes,
        control_record.checksum_offset,
        codec.crc32c(bytes[0..control_record.checksum_offset]),
    );
}

fn mutateDecodedRecord(
    base: [control_record.encoded_size]u8,
    record: control_record.Record,
) [control_record.encoded_size]u8 {
    var bytes = base;
    codec.putInt(u16, &bytes, 0x00a, record.kind);
    codec.putInt(u64, &bytes, 0x020, record.membership_epoch);
    @memcpy(bytes[0x0b8..0x0d8], &record.history_digest);
    codec.putInt(u16, &bytes, 0xff0, record.kind);
    fixChecksum(&bytes);
    return bytes;
}

test "empty and complete scans derive holes frontier and full state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try createMember(tmp.dir, "member", 5);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
    var result = try scan(&member);
    try std.testing.expect(result.tail == null);
    try std.testing.expectEqual(@as(u64, 0), result.physical_frontier);
    try std.testing.expectEqual(@as(u64, 0), result.zero_hole_count);
    try std.testing.expect(!result.unresolved_tail_damage);
    try member.close();

    const genesis = try genesisBytes();
    const genesis_record = try control_record.decode(&genesis);
    const second = try control_record.encode(try nextRecord(genesis_record, &genesis));
    try writeSlot(tmp.dir, "member", header, 1, &genesis);
    try writeSlot(tmp.dir, "member", header, 4, &second);
    member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
    result = try scan(&member);
    try std.testing.expectEqual(@as(u64, 2), result.tail.?.local_sequence);
    try std.testing.expectEqual(@as(?u64, 4), result.tail_physical_slot);
    try std.testing.expectEqual(@as(u64, 5), result.physical_frontier);
    try std.testing.expectEqual(@as(u64, 3), result.zero_hole_count);
    try std.testing.expectEqualSlices(u8, &control_record.recordDigest(&second), &result.tail_raw_record_digest);
    try std.testing.expect(result.journal_full);
    try member.close();
}

test "valid retry proves invalid interior damage abandoned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try createMember(tmp.dir, "member", 5);
    const genesis = try genesisBytes();
    const genesis_record = try control_record.decode(&genesis);
    const second_record = try nextRecord(genesis_record, &genesis);
    const second = try control_record.encode(second_record);
    const third = try control_record.encode(try nextRecord(second_record, &second));
    try writeSlot(tmp.dir, "member", header, 0, &genesis);
    try writeSlot(tmp.dir, "member", header, 1, &.{0xaa});
    try writeSlot(tmp.dir, "member", header, 2, &second);
    try writeSlot(tmp.dir, "member", header, 4, &third);

    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
    defer member.deinit();
    const result = try scan(&member);
    try std.testing.expectEqual(@as(u64, 3), result.tail.?.local_sequence);
    try std.testing.expectEqual(@as(u64, 1), result.zero_hole_count);
    try std.testing.expectEqual(@as(u64, 1), result.invalid_slot_count);
    try std.testing.expectEqual(@as(u64, 1), result.interior_invalid_slot_count);
    try std.testing.expect(!result.unresolved_tail_damage);
}

test "history scan retains every accepted record and supports digest lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try createMember(tmp.dir, "member", 5);
    const genesis = try genesisBytes();
    const genesis_record = try control_record.decode(&genesis);
    const second_record = try nextRecord(genesis_record, &genesis);
    const second = try control_record.encode(second_record);
    const third = try control_record.encode(try nextRecord(second_record, &second));
    try writeSlot(tmp.dir, "member", header, 0, &genesis);
    try writeSlot(tmp.dir, "member", header, 1, &.{0xaa});
    try writeSlot(tmp.dir, "member", header, 2, &second);
    try writeSlot(tmp.dir, "member", header, 4, &third);

    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
    defer member.deinit();
    var history = try scanHistory(std.testing.allocator, &member);
    defer history.deinit();
    const entries = history.entries();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqual(@as(u64, 0), entries[0].physical_slot);
    try std.testing.expectEqual(@as(u64, 2), entries[1].physical_slot);
    try std.testing.expectEqual(@as(u64, 4), entries[2].physical_slot);
    try std.testing.expectEqualDeep(history.scan_result, try scan(&member));
    try std.testing.expectEqual(
        entries[1].physical_slot,
        history.findHistoryDigest(entries[1].record.history_digest).?.physical_slot,
    );
    try std.testing.expectEqual(
        entries[2].physical_slot,
        history.findRawRecordDigest(entries[2].raw_record_digest).?.physical_slot,
    );
    try std.testing.expect(history.findHistoryDigest(@splat(0xff)) == null);
    try std.testing.expect(history.findRawRecordDigest(@splat(0xee)) == null);
}

test "generation commit evidence binds two exact prepare records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    var genesis_records: [3]control_record.Record = undefined;
    var genesis_raw: [3][control_record.encoded_size]u8 = undefined;
    var prepare_records: [3]control_record.Record = undefined;
    var prepare_raw: [3][control_record.encoded_size]u8 = undefined;

    for (0..3) |slot| {
        const member_id = payload.topology.members[slot].member_id;
        genesis_records[slot] = try genesis_payload.makeRecord(member_id, payload);
        genesis_raw[slot] = try control_record.encode(genesis_records[slot]);
        prepare_records[slot] = try generationPrepare(genesis_records[slot], &genesis_raw[slot]);
        prepare_raw[slot] = try control_record.encode(prepare_records[slot]);
    }
    const certificate: control_record.CommitCertificate = .{ .attestations = .{
        .{
            .member_id = payload.topology.members[0].member_id,
            .prepare_record_digest = control_record.recordDigest(&prepare_raw[0]),
            .prepare_history_digest = prepare_records[0].history_digest,
        },
        .{
            .member_id = payload.topology.members[1].member_id,
            .prepare_record_digest = control_record.recordDigest(&prepare_raw[1]),
            .prepare_history_digest = prepare_records[1].history_digest,
        },
    } };
    const commit_record = try generationCommit(prepare_records[0], &prepare_raw[0], certificate);
    const commit_raw = try control_record.encode(commit_record);
    var mismatched_commit_record = try generationCommit(prepare_records[2], &prepare_raw[2], certificate);
    mismatched_commit_record.generation += 1;
    mismatched_commit_record.history_digest = try control_record.historyDigest(mismatched_commit_record);
    const mismatched_commit_raw = try control_record.encode(mismatched_commit_record);

    const names = [_][]const u8{ "member0", "member1", "member2" };
    for (0..3) |slot| {
        var header = try testHeader(3);
        header.member_id = payload.topology.members[slot].member_id;
        header.member_slot = @intCast(slot);
        try createMemberWithHeader(tmp.dir, names[slot], header);
        try writeSlot(tmp.dir, names[slot], header, 0, &genesis_raw[slot]);
        try writeSlot(tmp.dir, names[slot], header, 1, &prepare_raw[slot]);
    }
    const header0 = try testHeader(3);
    try writeSlot(tmp.dir, names[0], header0, 2, &commit_raw);
    const header2 = try testHeader(3);
    try writeSlot(tmp.dir, names[2], header2, 2, &mismatched_commit_raw);

    var member0 = try member_api.openAt(std.testing.io, tmp.dir, names[0], .read_only);
    defer member0.deinit();
    var member1 = try member_api.openAt(std.testing.io, tmp.dir, names[1], .read_only);
    defer member1.deinit();
    var member2 = try member_api.openAt(std.testing.io, tmp.dir, names[2], .read_only);
    defer member2.deinit();
    var history0 = try scanHistory(std.testing.allocator, &member0);
    defer history0.deinit();
    var history1 = try scanHistory(std.testing.allocator, &member1);
    defer history1.deinit();
    var history2 = try scanHistory(std.testing.allocator, &member2);
    defer history2.deinit();
    const histories = [_]*const HistoryScan{ &history0, &history1, &history2 };
    const commit_digest = control_record.recordDigest(&commit_raw);

    const validated = try validateGenerationCommitEvidence(
        history0.member_id,
        commit_digest,
        &histories,
        payload.topology,
    );
    try std.testing.expectEqualDeep(
        try control_record.decodeCertificate(&(try control_record.encodeCertificate(certificate))),
        validated,
    );
    try std.testing.expectError(
        error.MissingPrepareMember,
        validateGenerationCommitEvidence(
            history0.member_id,
            commit_digest,
            &.{ &history0, &history2 },
            payload.topology,
        ),
    );
    try std.testing.expectError(
        error.DuplicateMemberHistory,
        validateGenerationCommitEvidence(
            history0.member_id,
            commit_digest,
            &.{ &history0, &history0, &history1 },
            payload.topology,
        ),
    );
    try std.testing.expectError(
        error.PrepareCommitMismatch,
        validateGenerationCommitEvidence(
            history2.member_id,
            control_record.recordDigest(&mismatched_commit_raw),
            &histories,
            payload.topology,
        ),
    );

    history1.storage[1].raw_record[0] ^= 1;
    try std.testing.expectError(
        error.EvidenceRecordDigestMismatch,
        validateGenerationCommitEvidence(
            history0.member_id,
            commit_digest,
            &histories,
            payload.topology,
        ),
    );
}

test "trailing and only invalid slots remain unresolved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var header = try createMember(tmp.dir, "trailing", 3);
    const genesis = try genesisBytes();
    try writeSlot(tmp.dir, "trailing", header, 0, &genesis);
    try writeSlot(tmp.dir, "trailing", header, 2, &.{0xaa});
    var member = try member_api.openAt(std.testing.io, tmp.dir, "trailing", .read_only);
    var result = try scan(&member);
    try std.testing.expect(result.unresolved_tail_damage);
    try std.testing.expectEqual(@as(u64, 0), result.interior_invalid_slot_count);
    try member.close();

    header = try createMember(tmp.dir, "invalid", 2);
    try writeSlot(tmp.dir, "invalid", header, 1, &.{0xbb});
    member = try member_api.openAt(std.testing.io, tmp.dir, "invalid", .read_only);
    result = try scan(&member);
    try std.testing.expect(result.tail == null);
    try std.testing.expect(result.unresolved_tail_damage);
    try std.testing.expectEqual(@as(u64, 1), result.invalid_slot_count);
    try std.testing.expectEqual(@as(u64, 2), result.physical_frontier);
    try member.close();
}

test "decoded duplicate gap and digest violations hard fail" {
    const Case = enum { duplicate, gap, record_digest, history_digest, second_genesis };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const header = try createMember(tmp.dir, "member", 2);
        const genesis = try genesisBytes();
        const genesis_record = try control_record.decode(&genesis);
        var record = try nextRecord(genesis_record, &genesis);
        switch (case) {
            .duplicate => {
                record.local_sequence = 1;
                record.previous_record_digest = @splat(0);
            },
            .gap => record.local_sequence = 3,
            .record_digest => record.previous_record_digest[0] ^= 1,
            .history_digest => record.previous_history_digest[0] ^= 1,
            .second_genesis => record = genesis_record,
        }
        record.history_digest = try control_record.historyDigest(record);
        const bytes = try control_record.encode(record);
        try writeSlot(tmp.dir, "member", header, 0, &genesis);
        try writeSlot(tmp.dir, "member", header, 1, &bytes);
        var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
        defer member.deinit();
        const expected = switch (case) {
            .duplicate => error.DuplicateRecordSequence,
            .gap => error.RecordSequenceGap,
            .record_digest => error.PreviousRecordDigestMismatch,
            .history_digest => error.PreviousHistoryDigestMismatch,
            .second_genesis => error.SecondGenesisRecord,
        };
        try std.testing.expectError(expected, scan(&member));
    }
}

test "decoded sequence regression hard fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try createMember(tmp.dir, "member", 3);
    const genesis = try genesisBytes();
    const genesis_record = try control_record.decode(&genesis);
    const second_record = try nextRecord(genesis_record, &genesis);
    const second = try control_record.encode(second_record);
    var regressed = second_record;
    regressed.local_sequence = 1;
    regressed.previous_record_digest = @splat(0);
    regressed.history_digest = try control_record.historyDigest(regressed);
    const regression = try control_record.encode(regressed);
    try writeSlot(tmp.dir, "member", header, 0, &genesis);
    try writeSlot(tmp.dir, "member", header, 1, &second);
    try writeSlot(tmp.dir, "member", header, 2, &regression);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
    defer member.deinit();
    try std.testing.expectError(error.RecordSequenceRegression, scan(&member));
}

test "decoded identity kind semantic and initial record violations hard fail" {
    const Case = enum { foreign_set, foreign_member, unknown_kind, semantic, non_genesis_first };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const header = try createMember(tmp.dir, "member", 1);
        const genesis = try genesisBytes();
        var record = try control_record.decode(&genesis);
        const raw = switch (case) {
            .foreign_set => raw: {
                record.set_id = @splat(0x71);
                record.history_digest = try control_record.historyDigest(record);
                break :raw try control_record.encode(record);
            },
            .foreign_member => raw: {
                record.member_id = @splat(0x72);
                break :raw try control_record.encode(record);
            },
            .unknown_kind => raw: {
                record.kind = 0x7777;
                record.history_digest = try control_record.historyDigest(record);
                break :raw mutateDecodedRecord(genesis, record);
            },
            .semantic => raw: {
                record.membership_epoch = 2;
                record.history_digest = try control_record.historyDigest(record);
                break :raw mutateDecodedRecord(genesis, record);
            },
            .non_genesis_first => try control_record.encode(try nextRecord(record, &genesis)),
        };
        try writeSlot(tmp.dir, "member", header, 0, &raw);
        var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
        defer member.deinit();
        const expected = switch (case) {
            .foreign_set => error.ForeignSet,
            .foreign_member => error.ForeignMember,
            .unknown_kind => error.UnsupportedRecordKind,
            .semantic => error.InvalidGenesisRecord,
            .non_genesis_first => error.NotGenesisRecord,
        };
        try std.testing.expectError(expected, scan(&member));
    }
}

test "genesis binds topology identity placement and layout to the member header" {
    const Case = enum { genesis_digest, member_slot, member_role, chunk_size };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var header = try testHeader(1);
        switch (case) {
            .genesis_digest => header.genesis_topology_digest[0] ^= 1,
            .member_slot => header.member_slot = 1,
            .member_role => {},
            .chunk_size => {
                header.chunk_size = 2 * 1024 * 1024;
                header.data.length = header.chunk_size;
                header.member_bytes = header.data.offset + header.data.length;
            },
        }
        try createMemberWithHeader(tmp.dir, "member", header);
        const genesis = try genesisBytes();
        try writeSlot(tmp.dir, "member", header, 0, &genesis);
        var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
        defer member.deinit();
        if (case == .member_role) member.selected_header.role_flags = member_format.metadata_role;
        const expected = switch (case) {
            .genesis_digest => error.GenesisTopologyDigestMismatch,
            .member_slot, .member_role => error.MemberHeaderMismatch,
            .chunk_size => error.ChunkSizeMismatch,
        };
        try std.testing.expectError(expected, scan(&member));
    }
}

test "short reads propagate and the scanner stays inside control" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try createMember(tmp.dir, "member", 1);
    const raw = try tmp.dir.openFile(std.testing.io, "member", .{ .mode = .read_write });
    try raw.writePositionalAll(std.testing.io, &.{0xcc}, header.metadata.offset);
    raw.close(std.testing.io);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
    const result = try scan(&member);
    try std.testing.expectEqual(@as(u64, 0), result.physical_frontier);

    const truncator = try tmp.dir.openFile(std.testing.io, "member", .{ .mode = .read_write });
    try truncator.setLength(std.testing.io, header.control.offset + control_record.encoded_size - 1);
    truncator.close(std.testing.io);
    try std.testing.expectError(error.TruncatedMember, scan(&member));
    try member.close();
}

test "journal append injects identity sequence and digests across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 3);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    var journal = try Journal.open(&member);

    const initial = try journal.state();
    try std.testing.expectEqual(@as(u64, 1), initial.tail.?.local_sequence);
    const next = try journal.append(try writerFenceProposal(initial.tail.?));
    try std.testing.expectEqual(@as(u64, 2), next.record.local_sequence);
    try std.testing.expectEqual(@as(u64, 1), next.physical_slot);
    try std.testing.expectEqualSlices(u8, &initial.tail_raw_record_digest, &next.record.previous_record_digest);
    try std.testing.expectEqualSlices(u8, &initial.tail.?.history_digest, &next.record.previous_history_digest);
    try std.testing.expectEqualSlices(u8, &(try control_record.historyDigest(next.record)), &next.record.history_digest);
    journal.close();
    try member.close();

    member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    journal = try Journal.open(&member);
    defer journal.deinit();
    const state = try journal.state();
    try std.testing.expectEqual(@as(u64, 2), state.tail.?.local_sequence);
    try std.testing.expectEqual(@as(u64, 2), state.physical_frontier);
    try std.testing.expectEqualSlices(u8, &next.record_digest, &state.tail_raw_record_digest);
}

test "exact prepare is side effect free and prepared append rechecks every field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 4);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    var journal = try Journal.open(&member);
    defer journal.deinit();
    const initial = try journal.state();
    const token = try journal.tailToken();
    try std.testing.expectEqual(initial.tail.?.local_sequence, token.local_sequence);
    try std.testing.expectEqual(initial.physical_frontier, token.physical_frontier);
    try std.testing.expectEqualSlices(u8, &initial.tail.?.history_digest, &token.history_digest);
    try std.testing.expectEqualSlices(u8, &initial.tail_raw_record_digest, &token.raw_record_digest);

    var fault: member_api.FaultController = .{ .fail_write_at = 0 };
    member.setFaultController(&fault);
    const prepared = try journal.prepareExact(token, try writerFenceProposal(initial.tail.?));
    try std.testing.expectEqual(@as(u64, 0), fault.write_count);
    try std.testing.expectEqualDeep(initial, try journal.state());

    var tampered = prepared;
    tampered.encoded[0] ^= 1;
    try std.testing.expectError(error.PreparedAppendMismatch, journal.appendPrepared(&tampered));
    try std.testing.expectEqual(@as(u64, 0), fault.write_count);
    try std.testing.expectEqualDeep(initial, try journal.state());

    var stale_token = token;
    stale_token.physical_frontier += 1;
    try std.testing.expectError(
        error.StaleTailToken,
        journal.prepareExact(stale_token, try writerFenceProposal(initial.tail.?)),
    );
    try std.testing.expectEqual(@as(u64, 0), fault.write_count);
    fault.disable();

    const appended = try journal.appendPrepared(&prepared);
    try std.testing.expectEqual(prepared.record, appended.record);
    try std.testing.expectEqual(prepared.record_digest, appended.record_digest);
    try std.testing.expectEqual(prepared.physical_slot, appended.physical_slot);

    const second_token = try journal.tailToken();
    const second_prepared = try journal.prepareExact(
        second_token,
        try writerFenceProposal(appended.record),
    );
    _ = try journal.append(try writerFenceProposal(appended.record));
    const state_before_stale = try journal.state();
    try std.testing.expectError(error.StaleTailToken, journal.appendPrepared(&second_prepared));
    try std.testing.expectEqualDeep(state_before_stale, try journal.state());
    try std.testing.expectError(
        error.UseCheckpointApi,
        journal.prepareExact(try journal.tailToken(), try checkpointProposal(state_before_stale.tail.?)),
    );
    var forged_checkpoint = second_prepared;
    forged_checkpoint.record.kind = control_record.checkpoint_kind;
    try std.testing.expectError(error.UseCheckpointApi, journal.appendPrepared(&forged_checkpoint));
}

test "concurrent journal appends serialize sequence and physical slots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 3);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    var journal = try Journal.open(&member);
    defer journal.deinit();
    const proposal = try writerFenceProposal((try journal.state()).tail.?);

    var first_future = std.testing.io.async(appendWorker, .{ &journal, proposal });
    var first_pending = true;
    defer if (first_pending) {
        _ = first_future.cancel(std.testing.io) catch {};
    };
    var second_future = std.testing.io.async(appendWorker, .{ &journal, proposal });
    var second_pending = true;
    defer if (second_pending) {
        _ = second_future.cancel(std.testing.io) catch {};
    };
    const first = try first_future.await(std.testing.io);
    first_pending = false;
    const second = try second_future.await(std.testing.io);
    second_pending = false;

    try std.testing.expect(first.record.local_sequence != second.record.local_sequence);
    try std.testing.expect(first.physical_slot != second.physical_slot);
    try std.testing.expectEqual(@as(u64, 3), (try journal.state()).tail.?.local_sequence);
    try std.testing.expect((try journal.state()).journal_full);
}

test "journal appends only at frontier and rejects terminal states before IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try createMember(tmp.dir, "holes", 3);
    const genesis = try genesisBytes();
    try writeSlot(tmp.dir, "holes", header, 1, &genesis);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "holes", .writable);
    var journal = try Journal.open(&member);
    const appended = try journal.append(try writerFenceProposal((try journal.state()).tail.?));
    try std.testing.expectEqual(@as(u64, 2), appended.physical_slot);
    try std.testing.expect((try journal.state()).journal_full);
    try std.testing.expectError(error.JournalFull, journal.append(try writerFenceProposal(appended.record)));
    var first_slot: [control_record.encoded_size]u8 = undefined;
    try member.read(.control, 0, &first_slot);
    try std.testing.expect(codec.isZero(&first_slot));
    journal.close();
    try member.close();

    _ = try createInitializedMember(tmp.dir, "invalid", 2);
    member = try member_api.openAt(std.testing.io, tmp.dir, "invalid", .writable);
    journal = try Journal.open(&member);
    var fault: member_api.FaultController = .{ .fail_write_at = 0 };
    member.setFaultController(&fault);
    var invalid = try writerFenceProposal((try journal.state()).tail.?);
    invalid.membership_epoch = 0;
    try std.testing.expectError(error.InvalidMembershipEpoch, journal.append(invalid));
    try std.testing.expectEqual(@as(u64, 0), fault.write_count);
    try std.testing.expect(!member.isFrozen());
    journal.scan_state.tail.?.local_sequence = std.math.maxInt(u64);
    journal.scan_state.physical_frontier = 1;
    try std.testing.expectError(error.RecordSequenceOverflow, journal.append(try writerFenceProposal(journal.scan_state.tail.?)));
    try std.testing.expectEqual(@as(u64, 0), fault.write_count);
    journal.close();
    try member.close();

    const unresolved_header = try createInitializedMember(tmp.dir, "unresolved", 2);
    try writeSlot(tmp.dir, "unresolved", unresolved_header, 1, &.{0xaa});
    member = try member_api.openAt(std.testing.io, tmp.dir, "unresolved", .writable);
    try std.testing.expectError(error.JournalNeedsRecovery, Journal.open(&member));
    try member.close();

    _ = try createMember(tmp.dir, "readonly", 1);
    member = try member_api.openAt(std.testing.io, tmp.dir, "readonly", .read_only);
    try std.testing.expectError(error.MissingGenesis, Journal.open(&member));
    try member.close();
}

test "append failures retain state and full scan classifies physical outcome" {
    const Case = enum { write_before, write_partial, write_after, sync_before, sync_after };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try createInitializedMember(tmp.dir, "member", 3);
        var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
        var journal = try Journal.open(&member);
        const old_state = try journal.state();
        var fault: member_api.FaultController = .{};
        switch (case) {
            .write_before => fault.fail_write_at = 0,
            .write_partial => fault.fail_write_partial_at = 0,
            .write_after => fault.fail_write_after_at = 0,
            .sync_before => fault.fail_sync_at = 0,
            .sync_after => fault.fail_sync_after_at = 0,
        }
        member.setFaultController(&fault);
        try std.testing.expectError(error.InjectedFault, journal.append(try writerFenceProposal(old_state.tail.?)));
        try std.testing.expectEqual(old_state.physical_frontier, (try journal.state()).physical_frontier);
        try std.testing.expectEqual(old_state.tail.?.local_sequence, (try journal.state()).tail.?.local_sequence);
        try std.testing.expect(member.isFrozen());
        journal.close();
        try std.testing.expectError(error.WriteFrozen, member.close());
        try member.close();

        member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
        defer member.deinit();
        if (case == .write_partial) {
            try std.testing.expectError(error.JournalNeedsRecovery, Journal.open(&member));
            try std.testing.expectError(error.JournalNeedsRecovery, Journal.open(&member));
            try member.close();
            member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
        }
        journal = try Journal.open(&member);
        const recovered = try journal.state();
        switch (case) {
            .write_before => {
                try std.testing.expectEqual(@as(u64, 1), recovered.physical_frontier);
                try std.testing.expectEqual(@as(u64, 1), recovered.tail.?.local_sequence);
                try std.testing.expect(!recovered.unresolved_tail_damage);
            },
            .write_partial => {
                try std.testing.expectEqual(@as(u64, 2), recovered.physical_frontier);
                try std.testing.expectEqual(@as(u64, 1), recovered.tail.?.local_sequence);
                try std.testing.expect(recovered.unresolved_tail_damage);
            },
            .write_after, .sync_before, .sync_after => {
                try std.testing.expectEqual(@as(u64, 2), recovered.physical_frontier);
                try std.testing.expectEqual(@as(u64, 2), recovered.tail.?.local_sequence);
                try std.testing.expect(!recovered.unresolved_tail_damage);
                const third = try journal.append(try writerFenceProposal(recovered.tail.?));
                try std.testing.expectEqual(@as(u64, 3), third.record.local_sequence);
                try std.testing.expect((try journal.state()).journal_full);
            },
        }
        journal.close();
    }
}

test "member enforces one journal owner and close permits a rescanned owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 2);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    var journal = try Journal.open(&member);
    const genesis = try journal.state();

    try std.testing.expectError(error.JournalAlreadyOpen, Journal.open(&member));
    journal.close();
    journal.close();
    try std.testing.expectError(error.JournalClosed, journal.state());
    try std.testing.expectError(error.JournalClosed, journal.append(try writerFenceProposal(genesis.tail.?)));

    var reopened = try Journal.open(&member);
    defer reopened.deinit();
    const state = try reopened.state();
    try std.testing.expectEqual(@as(u64, 1), state.tail.?.local_sequence);
    try std.testing.expectEqual(@as(u64, 1), state.physical_frontier);
    try std.testing.expectEqualSlices(u8, &genesis.tail_raw_record_digest, &state.tail_raw_record_digest);
}

test "failed journal scan releases the member claim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const header = try createMember(tmp.dir, "member", 1);
    const genesis = try genesisBytes();
    try writeSlot(tmp.dir, "member", header, 0, &genesis);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    member.selected_header.set_id[0] ^= 1;

    try std.testing.expectError(error.ForeignSet, Journal.open(&member));
    try std.testing.expectError(error.ForeignSet, Journal.open(&member));
    member.selected_header.set_id[0] ^= 1;
    var journal = try Journal.open(&member);
    journal.close();
}

test "journal open requires genesis and gates unresolved damage by mode" {
    const Case = enum { empty, only_invalid, unresolved };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const header = switch (case) {
            .empty, .only_invalid => try createMember(tmp.dir, "member", 2),
            .unresolved => try createInitializedMember(tmp.dir, "member", 2),
        };
        if (case != .empty) try writeSlot(tmp.dir, "member", header, 1, &.{0xaa});

        inline for (.{ member_format.OpenMode.read_only, member_format.OpenMode.writable }) |mode| {
            var member = try member_api.openAt(std.testing.io, tmp.dir, "member", mode);
            defer member.deinit();
            if (case == .unresolved and mode == .read_only) {
                var journal = try Journal.open(&member);
                try std.testing.expect((try journal.state()).unresolved_tail_damage);
                journal.close();
            } else {
                const expected = if (case == .empty) error.MissingGenesis else error.JournalNeedsRecovery;
                try std.testing.expectError(expected, Journal.open(&member));
                try std.testing.expectError(expected, Journal.open(&member));
            }
            try member.close();
        }
    }
}

test "created members open journals with shared history and local record digests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload = testPayload();
    var histories: [3]codec.Digest = undefined;
    var records: [3]codec.Digest = undefined;

    inline for (0..3) |slot| {
        var header = try testHeader(2);
        header.member_id = payload.topology.members[slot].member_id;
        header.member_slot = slot;
        const name: []const u8 = switch (slot) {
            0 => "member0",
            1 => "member1",
            2 => "member2",
            else => unreachable,
        };
        var member = try member_api.createAt(std.testing.io, tmp.dir, name, header, payload, .{});
        var journal = try Journal.open(&member);
        const state = try journal.state();
        histories[slot] = state.tail.?.history_digest;
        records[slot] = state.tail_raw_record_digest;
        journal.close();
        try member.close();

        member = try member_api.openAt(std.testing.io, tmp.dir, name, .writable);
        journal = try Journal.open(&member);
        try std.testing.expectEqualSlices(u8, &histories[slot], &(try journal.state()).tail.?.history_digest);
        journal.close();
        try member.close();
    }
    try std.testing.expectEqualSlices(u8, &histories[0], &histories[1]);
    try std.testing.expectEqualSlices(u8, &histories[1], &histories[2]);
    try std.testing.expect(!std.mem.eql(u8, &records[0], &records[1]));
    try std.testing.expect(!std.mem.eql(u8, &records[1], &records[2]));
    try std.testing.expect(!std.mem.eql(u8, &records[0], &records[2]));
}

test "journal releases its claim after the member closes first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 1);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    var journal = try Journal.open(&member);

    try member.close();
    try std.testing.expectError(error.MemberClosed, journal.state());
    try std.testing.expectError(error.MemberClosed, journal.append(try genesisProposal()));
    journal.close();
    journal.close();
    try member.claimJournal();
    member.releaseJournal();
}

test "full scan classifies checkpoint hints without changing scan results" {
    const Case = enum { zero, corrupt, wrong_kind, wrong_sequence, wrong_digest };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var header = try createInitializedMember(tmp.dir, "member", 2);
        if (case == .corrupt) try writeSlot(tmp.dir, "member", header, 1, &.{0xaa});

        var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
        var without_hint = try scan(&member);
        try std.testing.expectEqual(CheckpointStatus.none, without_hint.checkpoint_status);
        try member.close();

        var hinted_raw: [control_record.encoded_size]u8 = undefined;
        const hinted_slot: u64 = if (case == .zero or case == .corrupt) 1 else 0;
        if (hinted_slot == 0) {
            hinted_raw = try genesisBytes();
        } else {
            @memset(&hinted_raw, 0);
        }
        header.checkpoint_offset = header.control.offset + hinted_slot * control_record.encoded_size;
        header.checkpoint_record_sequence = if (case == .wrong_sequence) 2 else 1;
        header.checkpoint_record_digest = if (case == .wrong_digest or case == .zero or case == .corrupt)
            @splat(0x55)
        else
            control_record.recordDigest(&hinted_raw);
        try writeHeaders(tmp.dir, "member", header);

        member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
        defer member.deinit();
        var with_hint = try scan(&member);
        try std.testing.expectEqual(CheckpointStatus.invalid, with_hint.checkpoint_status);
        without_hint.checkpoint_status = .none;
        with_hint.checkpoint_status = .none;
        try std.testing.expectEqualDeep(without_hint, with_hint);
    }
}

test "checkpoint publication alternates headers and refreshes stale hints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 5);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    var journal = try Journal.open(&member);

    const first_proposal = try checkpointProposal((try journal.state()).tail.?);
    try std.testing.expectError(error.UseCheckpointApi, journal.append(first_proposal));
    try std.testing.expectError(error.NotCheckpointRecord, journal.checkpoint(try writerFenceProposal((try journal.state()).tail.?)));
    const first = try journal.checkpoint(first_proposal);
    try std.testing.expectEqual(member_api.SourceSlot.b, member.source());
    try std.testing.expectEqual(@as(u64, 2), member.header().header_sequence);
    try std.testing.expectEqual(CheckpointStatus.valid, (try journal.state()).checkpoint_status);
    try std.testing.expectEqual(CheckpointStatus.valid, (try scan(&member)).checkpoint_status);

    const ordinary = try journal.append(try writerFenceProposal(first.record));
    try std.testing.expectEqual(CheckpointStatus.stale, (try journal.state()).checkpoint_status);
    try std.testing.expectEqual(CheckpointStatus.stale, (try scan(&member)).checkpoint_status);
    const second = try journal.checkpoint(try checkpointProposal(ordinary.record));
    try std.testing.expectEqual(member_api.SourceSlot.a, member.source());
    try std.testing.expectEqual(@as(u64, 3), member.header().header_sequence);
    try std.testing.expectEqual(CheckpointStatus.valid, (try journal.state()).checkpoint_status);
    try std.testing.expectEqualSlices(u8, &second.record_digest, &member.header().checkpoint_record_digest);
    journal.close();
    try member.close();

    member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
    defer member.deinit();
    try std.testing.expectEqual(member_api.SourceSlot.a, member.source());
    try std.testing.expectEqual(@as(u64, 3), member.header().header_sequence);
    const rescanned = try scan(&member);
    try std.testing.expectEqual(CheckpointStatus.valid, rescanned.checkpoint_status);
    try std.testing.expectEqual(second.record.local_sequence, rescanned.tail.?.local_sequence);
}

test "checkpoint header faults retain durable journal state and old selection" {
    const Case = enum { write_before, write_partial, write_after, sync_before, sync_after };
    inline for (std.meta.tags(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try createInitializedMember(tmp.dir, "member", 3);
        var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
        var journal = try Journal.open(&member);
        var fault: member_api.FaultController = .{};
        switch (case) {
            .write_before => fault.fail_write_at = 1,
            .write_partial => fault.fail_write_partial_at = 1,
            .write_after => fault.fail_write_after_at = 1,
            .sync_before => fault.fail_sync_at = 1,
            .sync_after => fault.fail_sync_after_at = 1,
        }
        member.setFaultController(&fault);

        try std.testing.expectError(
            error.InjectedFault,
            journal.checkpoint(try checkpointProposal((try journal.state()).tail.?)),
        );
        const retained = try journal.state();
        try std.testing.expectEqual(@as(u64, 2), retained.tail.?.local_sequence);
        try std.testing.expectEqual(@as(u64, 2), retained.physical_frontier);
        try std.testing.expect(member.isFrozen());
        try std.testing.expectEqual(member_api.SourceSlot.a, member.source());
        try std.testing.expectEqual(@as(u64, 1), member.header().header_sequence);
        journal.close();
        try std.testing.expectError(error.WriteFrozen, member.close());
        try member.close();

        member = try member_api.openAt(std.testing.io, tmp.dir, "member", .read_only);
        defer member.deinit();
        const complete_header = case == .write_after or case == .sync_before or case == .sync_after;
        try std.testing.expectEqual(if (complete_header) member_api.SourceSlot.b else member_api.SourceSlot.a, member.source());
        const recovered = try scan(&member);
        try std.testing.expectEqual(@as(u64, 2), recovered.tail.?.local_sequence);
        try std.testing.expectEqual(
            if (complete_header) CheckpointStatus.valid else CheckpointStatus.none,
            recovered.checkpoint_status,
        );
    }
}

test "checkpoint record sync failure never starts header publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 2);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    var journal = try Journal.open(&member);
    defer journal.deinit();
    const old_state = try journal.state();
    var fault: member_api.FaultController = .{ .fail_sync_at = 0 };
    member.setFaultController(&fault);

    try std.testing.expectError(
        error.InjectedFault,
        journal.checkpoint(try checkpointProposal(old_state.tail.?)),
    );
    try std.testing.expectEqual(@as(u64, 1), fault.write_count);
    try std.testing.expectEqual(@as(u64, 1), fault.sync_count);
    try std.testing.expectEqualDeep(old_state, try journal.state());
    try std.testing.expectEqual(@as(u64, 1), member.header().header_sequence);
    try std.testing.expectEqual(member_api.SourceSlot.a, member.source());
}

test "checkpoint header overflow occurs after durable append and before header IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 2);
    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    var journal = try Journal.open(&member);
    defer journal.deinit();
    member.selected_header.header_sequence = std.math.maxInt(u64);
    var fault: member_api.FaultController = .{};
    member.setFaultController(&fault);

    try std.testing.expectError(
        error.HeaderSequenceOverflow,
        journal.checkpoint(try checkpointProposal((try journal.state()).tail.?)),
    );
    try std.testing.expectEqual(@as(u64, 2), (try journal.state()).tail.?.local_sequence);
    try std.testing.expectEqual(@as(u64, 1), fault.write_count);
    try std.testing.expectEqual(@as(u64, 1), fault.sync_count);
    try std.testing.expect(!member.isFrozen());
}

test "checkpoint publication repairs a degraded header pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    _ = try createInitializedMember(tmp.dir, "member", 2);
    const file = try tmp.dir.openFile(std.testing.io, "member", .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, &.{0xff}, member_format.encoded_size);
    file.close(std.testing.io);

    var member = try member_api.openAt(std.testing.io, tmp.dir, "member", .writable);
    defer member.deinit();
    try std.testing.expect(member.redundancyDegraded());
    try std.testing.expectEqual(member_api.SourceSlot.a, member.source());
    var journal = try Journal.open(&member);
    defer journal.deinit();
    _ = try journal.checkpoint(try checkpointProposal((try journal.state()).tail.?));
    try std.testing.expectEqual(member_api.SourceSlot.b, member.source());
    try std.testing.expect(!member.redundancyDegraded());
}
