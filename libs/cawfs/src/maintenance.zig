//! Durable service-mode transitions and control-publication resolution.

const std = @import("std");
const anchor = @import("anchor.zig");
const store_mod = @import("store.zig");

pub const record_size = 256;
pub const format_version: u16 = 1;
pub const Encoded = [record_size]u8;

pub const Record = struct {
    revision: u64,
    generation: u64,
    mode_epoch: u64,
    operation_id: store_mod.TransactionId,
    previous_mode: anchor.Mode,
    mode: anchor.Mode,
    parent: ?store_mod.ObjectRef,
};

pub const RecordError = error{
    InvalidSize,
    InvalidMagic,
    UnsupportedFormatVersion,
    InvalidFlags,
    NonCanonicalEncoding,
    ChecksumMismatch,
    InvalidMode,
    InvalidRecord,
};

pub const Status = enum {
    staging,
    failed,
    conflict,
    indeterminate,
    not_committed,
    published,
    committed,
};

pub const Outcome = enum { committed, conflict, indeterminate };

pub const Resolution = enum {
    committed,
    not_committed,
    pending,
};

pub const Attempt = struct {
    base_revision: u64,
    base_generation: u64,
    base_mode_epoch: u64,
    base_control_ref: ?store_mod.ObjectRef,
    operation_id: store_mod.TransactionId,
    previous_mode: anchor.Mode,
    mode: anchor.Mode,
};

pub const Options = struct {
    max_depth: usize = 1024,
};

pub const Error = error{
    InvalidAnchorState,
    InvalidAttempt,
    InvalidOperationId,
    InvalidState,
    InvalidTransition,
    RevisionOverflow,
    ModeEpochOverflow,
    RevisionRegression,
    GenerationRegression,
    BrokenAncestry,
    AncestryTooDeep,
    ControlAnchorMismatch,
};

const magic = "ZCAWCT\x00\x00";
const magic_start = 0;
const magic_end = magic_start + magic.len;
const version_start = magic_end;
const version_end = version_start + @sizeOf(u16);
const flags_start = version_end;
const flags_end = flags_start + @sizeOf(u16);
const revision_start = flags_end;
const revision_end = revision_start + @sizeOf(u64);
const generation_start = revision_end;
const generation_end = generation_start + @sizeOf(u64);
const mode_epoch_start = generation_end;
const mode_epoch_end = mode_epoch_start + @sizeOf(u64);
const operation_id_start = mode_epoch_end;
const operation_id_end = operation_id_start + @sizeOf(store_mod.TransactionId);
const previous_mode_start = operation_id_end;
const mode_start = previous_mode_start + @sizeOf(u8);
const reserved_start = mode_start + @sizeOf(u8);
const parent_start = 56;
const parent_end = parent_start + store_mod.object_ref_size;
const checksum_start = parent_end;
const checksum_end = checksum_start + std.crypto.hash.sha2.Sha256.digest_length;
const has_parent: u16 = 1 << 0;
const known_flags = has_parent;

comptime {
    std.debug.assert(reserved_start <= parent_start);
    std.debug.assert(checksum_end <= record_size);
}

pub fn encode(record: Record) Encoded {
    var encoded: Encoded = @splat(0);
    @memcpy(encoded[magic_start..magic_end], magic);
    std.mem.writeInt(u16, encoded[version_start..version_end], format_version, .big);
    std.mem.writeInt(u64, encoded[revision_start..revision_end], record.revision, .big);
    std.mem.writeInt(u64, encoded[generation_start..generation_end], record.generation, .big);
    std.mem.writeInt(u64, encoded[mode_epoch_start..mode_epoch_end], record.mode_epoch, .big);
    @memcpy(encoded[operation_id_start..operation_id_end], &record.operation_id);
    encoded[previous_mode_start] = @intFromEnum(record.previous_mode);
    encoded[mode_start] = @intFromEnum(record.mode);
    if (record.parent) |parent| {
        std.mem.writeInt(u16, encoded[flags_start..flags_end], has_parent, .big);
        @memcpy(encoded[parent_start..parent_end], &parent.bytes);
    }
    seal(&encoded);
    return encoded;
}

pub fn decode(bytes: []const u8) RecordError!Record {
    if (bytes.len != record_size) return error.InvalidSize;
    const encoded: *const Encoded = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, encoded[magic_start..magic_end], magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, encoded[version_start..version_end], .big) != format_version)
        return error.UnsupportedFormatVersion;
    const flags = std.mem.readInt(u16, encoded[flags_start..flags_end], .big);
    if (flags & ~known_flags != 0) return error.InvalidFlags;
    if (!allZero(encoded[reserved_start..parent_start])) return error.NonCanonicalEncoding;
    if (flags & has_parent == 0 and !allZero(encoded[parent_start..parent_end]))
        return error.NonCanonicalEncoding;
    if (!allZero(encoded[checksum_end..])) return error.NonCanonicalEncoding;

    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    checksum(encoded, &expected);
    if (!std.mem.eql(u8, encoded[checksum_start..checksum_end], &expected))
        return error.ChecksumMismatch;

    const previous_mode = std.enums.fromInt(anchor.Mode, encoded[previous_mode_start]) orelse
        return error.InvalidMode;
    const mode = std.enums.fromInt(anchor.Mode, encoded[mode_start]) orelse
        return error.InvalidMode;
    var parent: ?store_mod.ObjectRef = null;
    if (flags & has_parent != 0) {
        parent = .{ .bytes = encoded[parent_start..parent_end].* };
    }
    const record = Record{
        .revision = std.mem.readInt(u64, encoded[revision_start..revision_end], .big),
        .generation = std.mem.readInt(u64, encoded[generation_start..generation_end], .big),
        .mode_epoch = std.mem.readInt(u64, encoded[mode_epoch_start..mode_epoch_end], .big),
        .operation_id = encoded[operation_id_start..operation_id_end].*,
        .previous_mode = previous_mode,
        .mode = mode,
        .parent = parent,
    };
    validateRecord(record) catch return error.InvalidRecord;
    return record;
}

pub const Transition = struct {
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    operation_id: store_mod.TransactionId,
    previous: anchor.State,
    next_mode: anchor.Mode,
    next_revision: u64,
    next_mode_epoch: u64,
    version: store_mod.OwnedBytes,
    batch: store_mod.WriteBatch,
    current_status: Status = .staging,
    prepared_control: ?store_mod.ObjectRef = null,

    pub fn begin(
        store: store_mod.ConditionalStore,
        allocator: std.mem.Allocator,
        operation_id: store_mod.TransactionId,
        next_mode: anchor.Mode,
    ) !Transition {
        if (allZero(&operation_id)) return error.InvalidOperationId;
        var snapshot = try store.readAnchor(allocator);
        errdefer snapshot.deinit();
        const previous = try anchor.decode(&snapshot.anchor);
        try validateAnchorState(store, allocator, previous);
        const next_revision = std.math.add(u64, previous.revision, 1) catch
            return error.RevisionOverflow;
        const next_mode_epoch = try successorModeEpoch(previous, operation_id, next_mode);
        const batch = try store.beginControlBatch(allocator, operation_id, snapshot.version.bytes);

        return .{
            .store = store,
            .allocator = allocator,
            .operation_id = operation_id,
            .previous = previous,
            .next_mode = next_mode,
            .next_revision = next_revision,
            .next_mode_epoch = next_mode_epoch,
            .version = snapshot.version,
            .batch = batch,
        };
    }

    pub fn deinit(self: *Transition) void {
        self.batch.deinit();
        self.version.deinit();
        self.* = undefined;
    }

    pub fn status(self: *const Transition) Status {
        return self.current_status;
    }

    pub fn candidateControlRef(self: *const Transition) ?store_mod.ObjectRef {
        return self.prepared_control;
    }

    pub fn commit(self: *Transition) !Outcome {
        if (self.current_status != .staging) return error.InvalidState;
        self.current_status = .failed;
        const encoded = encode(.{
            .revision = self.next_revision,
            .generation = self.previous.generation,
            .mode_epoch = self.next_mode_epoch,
            .operation_id = self.operation_id,
            .previous_mode = self.previous.mode,
            .mode = self.next_mode,
            .parent = self.previous.control_ref,
        });
        const control_ref = try self.batch.putImmutable(&encoded);
        try self.batch.prepare();
        self.prepared_control = control_ref;

        const next = anchor.encode(.{
            .revision = self.next_revision,
            .generation = self.previous.generation,
            .transaction_id = self.previous.transaction_id,
            .head = self.previous.head,
            .mode = self.next_mode,
            .mode_epoch = self.next_mode_epoch,
            .control_operation_id = if (self.next_mode == .active)
                @splat(0)
            else
                self.operation_id,
            .control_ref = control_ref,
        });
        switch (try self.batch.publish(self.version.bytes, &next)) {
            .conflict => {
                self.current_status = .conflict;
                return .conflict;
            },
            .indeterminate => {
                self.current_status = .indeterminate;
                return .indeterminate;
            },
            .committed => {
                self.current_status = .published;
                try self.stabilize();
                return .committed;
            },
        }
    }

    pub fn resolve(self: *Transition, options: Options) !Resolution {
        const terminal = switch (self.current_status) {
            .indeterminate, .published => self.batch.publicationTerminated(),
            else => return error.InvalidState,
        };
        const publication_attempt = self.attempt();
        const result = if (terminal)
            try resolveTerminal(self.store, self.allocator, publication_attempt, options)
        else
            try resolvePublication(self.store, self.allocator, publication_attempt, options);
        switch (result) {
            .committed => self.current_status = .published,
            .not_committed => self.current_status = .not_committed,
            .pending => {},
        }
        return result;
    }

    pub fn stabilize(self: *Transition) !void {
        if (self.current_status != .published) return error.InvalidState;
        try self.batch.stabilize();
        self.current_status = .committed;
    }

    fn attempt(self: *const Transition) Attempt {
        return .{
            .base_revision = self.previous.revision,
            .base_generation = self.previous.generation,
            .base_mode_epoch = self.previous.mode_epoch,
            .base_control_ref = self.previous.control_ref,
            .operation_id = self.operation_id,
            .previous_mode = self.previous.mode,
            .mode = self.next_mode,
        };
    }
};

pub fn resolvePublication(
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    attempt: Attempt,
    options: Options,
) !Resolution {
    return resolveInternal(store, allocator, attempt, options, true);
}

pub fn resolveTerminal(
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    attempt: Attempt,
    options: Options,
) !Resolution {
    return resolveInternal(store, allocator, attempt, options, false);
}

fn resolveInternal(
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    attempt: Attempt,
    options: Options,
    request_may_be_in_flight: bool,
) !Resolution {
    if (allZero(&attempt.operation_id) or attempt.base_revision < attempt.base_generation or
        attempt.base_mode_epoch == 0)
    {
        return error.InvalidAttempt;
    }
    const attempted_revision = std.math.add(u64, attempt.base_revision, 1) catch
        return error.RevisionOverflow;
    _ = try attemptModeEpoch(attempt);

    var snapshot = try store.readAnchor(allocator);
    defer snapshot.deinit();
    const current = try anchor.decode(&snapshot.anchor);
    if (current.revision < attempt.base_revision)
        return if (request_may_be_in_flight) error.RevisionRegression else .not_committed;
    if (current.generation < attempt.base_generation)
        return if (request_may_be_in_flight) error.GenerationRegression else .not_committed;
    if (current.revision == attempt.base_revision) {
        if (current.generation != attempt.base_generation or
            current.mode_epoch != attempt.base_mode_epoch or
            current.mode != attempt.previous_mode or
            !optionalRefEql(current.control_ref, attempt.base_control_ref) or
            (current.mode != .active and
                !std.mem.eql(u8, &current.control_operation_id, &attempt.operation_id)))
        {
            return error.InvalidAnchorState;
        }
        return if (request_may_be_in_flight) .pending else .not_committed;
    }

    var object_ref = current.control_ref orelse {
        try validateCurrentControl(current, null);
        return .not_committed;
    };
    var child: ?Record = null;
    var depth: usize = 0;
    while (depth < options.max_depth) : (depth += 1) {
        var bytes = try store.loadImmutable(object_ref, allocator);
        defer bytes.deinit();
        const record = try decode(bytes.bytes);
        if (child) |child_record| {
            try validateParent(record, child_record);
        } else {
            try validateCurrentControl(current, record);
        }

        if (record.revision == attempted_revision) {
            return if (matchesAttempt(record, attempt)) .committed else .not_committed;
        }
        if (record.revision < attempted_revision) return .not_committed;
        object_ref = record.parent orelse return .not_committed;
        child = record;
    }
    return error.AncestryTooDeep;
}

fn validateParent(parent: Record, child: Record) !void {
    if (parent.revision >= child.revision or parent.generation > child.generation or
        parent.mode_epoch > child.mode_epoch or child.previous_mode != parent.mode)
    {
        return error.BrokenAncestry;
    }
    if (child.previous_mode == .active) {
        const expected_epoch = std.math.add(u64, parent.mode_epoch, 1) catch
            return error.BrokenAncestry;
        const revision_delta = child.revision - parent.revision;
        const generation_delta = child.generation - parent.generation;
        if (child.mode_epoch != expected_epoch or revision_delta != generation_delta + 1)
            return error.BrokenAncestry;
    } else if (child.mode_epoch != parent.mode_epoch or
        child.revision != parent.revision + 1 or child.generation != parent.generation or
        !std.mem.eql(u8, &child.operation_id, &parent.operation_id))
    {
        return error.BrokenAncestry;
    }
}

fn validateCurrentControl(current: anchor.State, record: ?Record) !void {
    const control = record orelse {
        if (current.mode != .active or current.revision != current.generation or
            current.mode_epoch != 1)
        {
            return error.ControlAnchorMismatch;
        }
        return;
    };
    if (control.revision > current.revision or control.generation > current.generation or
        control.mode_epoch != current.mode_epoch)
    {
        return error.ControlAnchorMismatch;
    }
    if (current.mode == .active) {
        if (control.mode != .active or
            current.revision - control.revision != current.generation - control.generation)
        {
            return error.ControlAnchorMismatch;
        }
        return;
    }
    if (control.revision != current.revision or control.generation != current.generation or
        control.mode != current.mode or
        !std.mem.eql(u8, &control.operation_id, &current.control_operation_id))
    {
        return error.ControlAnchorMismatch;
    }
}

fn matchesAttempt(record: Record, attempt: Attempt) bool {
    const mode_epoch = attemptModeEpoch(attempt) catch return false;
    return record.generation == attempt.base_generation and
        record.mode_epoch == mode_epoch and
        std.mem.eql(u8, &record.operation_id, &attempt.operation_id) and
        record.previous_mode == attempt.previous_mode and record.mode == attempt.mode and
        optionalRefEql(record.parent, attempt.base_control_ref);
}

fn validateRecord(record: Record) !void {
    if (record.revision <= record.generation or record.mode_epoch == 0 or
        allZero(&record.operation_id))
    {
        return error.InvalidRecord;
    }
    switch (record.previous_mode) {
        .active => {
            if (record.mode != .quiescing or record.mode_epoch == 1)
                return error.InvalidRecord;
            if (record.parent == null and
                (record.revision != record.generation + 1 or record.mode_epoch != 2))
            {
                return error.InvalidRecord;
            }
        },
        .quiescing => if ((record.mode != .maintenance and record.mode != .blocked) or
            record.parent == null or record.mode_epoch == 1)
        {
            return error.InvalidRecord;
        },
        .maintenance => if ((record.mode != .active and record.mode != .blocked) or
            record.parent == null or record.mode_epoch == 1)
        {
            return error.InvalidRecord;
        },
        .blocked => return error.InvalidRecord,
    }
}

pub fn validateAnchorState(
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    state: anchor.State,
) !void {
    const control_ref = state.control_ref orelse {
        try validateCurrentControl(state, null);
        return;
    };
    var bytes = try store.loadImmutable(control_ref, allocator);
    defer bytes.deinit();
    try validateCurrentControl(state, try decode(bytes.bytes));
}

fn successorModeEpoch(
    previous: anchor.State,
    operation_id: store_mod.TransactionId,
    next_mode: anchor.Mode,
) !u64 {
    switch (previous.mode) {
        .active => {
            if (next_mode != .quiescing) return error.InvalidTransition;
            return std.math.add(u64, previous.mode_epoch, 1) catch
                return error.ModeEpochOverflow;
        },
        .quiescing => {
            try requireCurrentOperation(previous, operation_id);
            if (next_mode != .maintenance and next_mode != .blocked)
                return error.InvalidTransition;
        },
        .maintenance => {
            try requireCurrentOperation(previous, operation_id);
            if (next_mode != .active and next_mode != .blocked)
                return error.InvalidTransition;
        },
        .blocked => return error.InvalidTransition,
    }
    return previous.mode_epoch;
}

fn attemptModeEpoch(attempt: Attempt) !u64 {
    switch (attempt.previous_mode) {
        .active => {
            if (attempt.mode != .quiescing) return error.InvalidAttempt;
            return std.math.add(u64, attempt.base_mode_epoch, 1) catch
                return error.ModeEpochOverflow;
        },
        .quiescing => if (attempt.mode != .maintenance and attempt.mode != .blocked)
            return error.InvalidAttempt,
        .maintenance => if (attempt.mode != .active and attempt.mode != .blocked)
            return error.InvalidAttempt,
        .blocked => return error.InvalidAttempt,
    }
    return attempt.base_mode_epoch;
}

fn requireCurrentOperation(previous: anchor.State, operation_id: store_mod.TransactionId) !void {
    if (!std.mem.eql(u8, &previous.control_operation_id, &operation_id))
        return error.InvalidOperationId;
}

fn seal(encoded: *Encoded) void {
    checksum(encoded, encoded[checksum_start..checksum_end]);
}

fn checksum(encoded: *const Encoded, result: *[std.crypto.hash.sha2.Sha256.digest_length]u8) void {
    var canonical = encoded.*;
    @memset(canonical[checksum_start..checksum_end], 0);
    std.crypto.hash.sha2.Sha256.hash(&canonical, result, .{});
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn optionalRefEql(a: ?store_mod.ObjectRef, b: ?store_mod.ObjectRef) bool {
    if (a) |a_ref| {
        const b_ref = b orelse return false;
        return store_mod.ObjectRef.eql(a_ref, b_ref);
    }
    return b == null;
}

fn patternedRef(seed: u8) store_mod.ObjectRef {
    var result: store_mod.ObjectRef = .{};
    for (&result.bytes, 0..) |*byte, index| byte.* = seed +% @as(u8, @truncate(index * 17));
    return result;
}

test "maintenance record encoding matches the golden vector" {
    const parent = patternedRef(3);
    const operation_id: store_mod.TransactionId = @splat(0x41);
    const encoded = encode(.{
        .revision = 12,
        .generation = 9,
        .mode_epoch = 3,
        .operation_id = operation_id,
        .previous_mode = .quiescing,
        .mode = .maintenance,
        .parent = parent,
    });
    var expected: Encoded = @splat(0);
    @memcpy(expected[0..8], magic);
    expected[9] = 1;
    expected[11] = 1;
    expected[19] = 12;
    expected[27] = 9;
    expected[35] = 3;
    @memcpy(expected[36..52], &operation_id);
    expected[52] = @intFromEnum(anchor.Mode.quiescing);
    expected[53] = @intFromEnum(anchor.Mode.maintenance);
    @memcpy(expected[56..120], &parent.bytes);
    @memcpy(expected[120..152], &[_]u8{
        0x8e, 0x4f, 0x27, 0x99, 0x5b, 0xce, 0xb4, 0x69,
        0xff, 0x4f, 0xfc, 0xda, 0xe9, 0xaf, 0xa2, 0x2f,
        0x00, 0xc4, 0xf0, 0xb5, 0xd3, 0x6d, 0x35, 0xf6,
        0x69, 0x61, 0x42, 0xfe, 0xa2, 0x72, 0x4c, 0xda,
    });

    try std.testing.expectEqualSlices(u8, &expected, &encoded);
    const decoded = try decode(&encoded);

    try std.testing.expectEqual(@as(u64, 12), decoded.revision);
    try std.testing.expectEqual(@as(u64, 9), decoded.generation);
    try std.testing.expectEqual(@as(u64, 3), decoded.mode_epoch);
    try std.testing.expectEqual(operation_id, decoded.operation_id);
    try std.testing.expectEqual(anchor.Mode.quiescing, decoded.previous_mode);
    try std.testing.expectEqual(anchor.Mode.maintenance, decoded.mode);
    try std.testing.expect(store_mod.ObjectRef.eql(parent, decoded.parent.?));
}

test "maintenance record rejects corruption and invalid transitions" {
    var encoded = encode(.{
        .revision = 2,
        .generation = 0,
        .mode_epoch = 2,
        .operation_id = @splat(0x41),
        .previous_mode = .active,
        .mode = .quiescing,
        .parent = null,
    });
    encoded[generation_start] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(&encoded));

    const invalid = encode(.{
        .revision = 2,
        .generation = 0,
        .mode_epoch = 2,
        .operation_id = @splat(0x41),
        .previous_mode = .active,
        .mode = .maintenance,
        .parent = null,
    });
    try std.testing.expectError(error.InvalidRecord, decode(&invalid));

    const missing_parent = encode(.{
        .revision = 3,
        .generation = 0,
        .mode_epoch = 2,
        .operation_id = @splat(0x41),
        .previous_mode = .quiescing,
        .mode = .maintenance,
        .parent = null,
    });
    try std.testing.expectError(error.InvalidRecord, decode(&missing_parent));
}
