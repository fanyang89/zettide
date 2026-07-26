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
        if (self.closed) return error.JournalClosed;
        if (self.member.isClosed()) return error.MemberClosed;
        if (self.member.mode() != .writable) return error.ReadOnlyMember;
        if (self.member.isFrozen()) return error.WriteFrozen;
        if (self.scan_state.unresolved_tail_damage) return error.UnresolvedTailDamage;
        if (self.scan_state.journal_full) return error.JournalFull;

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
        const offset = std.math.mul(u64, physical_slot, control_record.encoded_size) catch
            return error.ControlOffsetOverflow;
        try self.member.writeDurable(.control, offset, &encoded);

        const record_digest = control_record.recordDigest(&encoded);
        self.scan_state.tail = record;
        self.scan_state.tail_raw_record_digest = record_digest;
        self.scan_state.tail_physical_slot = physical_slot;
        self.scan_state.physical_frontier = std.math.add(u64, physical_slot, 1) catch unreachable;
        self.scan_state.journal_full = self.scan_state.physical_frontier == self.scan_state.slot_count;
        if (self.scan_state.checkpoint_status == .valid) self.scan_state.checkpoint_status = .stale;
        return .{ .record = record, .record_digest = record_digest, .physical_slot = physical_slot };
    }
};

fn validateGenesis(header: member_format.Header, record: control_record.Record) !void {
    const payload = try genesis_payload.validateRecord(record);
    const genesis_digest = try topology_format.digest(payload.topology);
    try topology_format.validateMemberHeader(payload.topology, genesis_digest, header);
    if (header.chunk_size != payload.layout.chunk_size) return error.ChunkSizeMismatch;
}

pub fn scan(member: *member_api.Member) !ScanResult {
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
        result.tail = record;
        result.tail_raw_record_digest = control_record.recordDigest(&raw);
        result.tail_physical_slot = slot;
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
