const std = @import("std");
const builtin = @import("builtin");
const codec = @import("codec.zig");
const control_record = @import("control_record.zig");
const genesis_payload_format = @import("genesis_payload.zig");
const member_format = @import("member_format.zig");
const topology_format = @import("topology.zig");

const Io = std.Io;
const File = Io.File;

pub const OpenMode = member_format.OpenMode;
pub const SourceSlot = member_format.SourceSlot;

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
    file: File,
    selected_header: member_format.Header,
    selected_source: SourceSlot,
    degraded: bool,
    open_mode: OpenMode,
    mutex: Io.Mutex = .init,
    fault: ?*FaultController = null,
    dirty: bool = false,
    frozen: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    journal_claimed: std.atomic.Value(bool) = .init(false),

    pub fn createAt(
        io: Io,
        parent: Io.Dir,
        basename: []const u8,
        initial_header: member_format.Header,
        genesis_payload: genesis_payload_format.GenesisPayload,
        options: CreateOptions,
    ) !Member {
        if (!validBasename(basename)) return error.InvalidBasename;
        const encoded_header = try validateCreate(initial_header, genesis_payload);
        const genesis_record = try genesis_payload_format.makeRecord(initial_header.member_id, genesis_payload);
        const encoded_genesis = try control_record.encode(genesis_record);

        const file = try parent.createFile(io, basename, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        errdefer {
            file.unlock(io);
            file.close(io);
        }

        try file.setLength(io, initial_header.member_bytes);
        try createSync(file, io, options.fault, .extent_sync);
        try createWrite(file, io, initial_header.control.offset, &encoded_genesis, options.fault, .genesis_write);
        try createSync(file, io, options.fault, .genesis_sync);
        try createWrite(file, io, member_format.encoded_size, &encoded_header, options.fault, .header_b_write);
        try createSync(file, io, options.fault, .header_b_sync);
        try createWrite(file, io, 0, &encoded_header, options.fault, .header_a_write);
        try createSync(file, io, options.fault, .header_a_sync);
        if (builtin.os.tag == .linux) try createParentSync(parent, io, options.fault);

        return .{
            .io = io,
            .file = file,
            .selected_header = initial_header,
            .selected_source = .a,
            .degraded = false,
            .open_mode = .writable,
        };
    }

    pub fn openAt(io: Io, parent: Io.Dir, basename: []const u8, open_mode: OpenMode) !Member {
        if (!validBasename(basename)) return error.InvalidBasename;
        const file = try parent.openFile(io, basename, .{
            .mode = if (open_mode == .writable) .read_write else .read_only,
            .lock = if (open_mode == .writable) .exclusive else .shared,
            .lock_nonblocking = true,
        });
        errdefer {
            file.unlock(io);
            file.close(io);
        }

        var first_transport_error: ?anyerror = null;
        const a = readCandidate(file, io, 0) catch |err| candidate: {
            first_transport_error = err;
            break :candidate member_format.Candidate{ .invalid = err };
        };
        const b = readCandidate(file, io, member_format.encoded_size) catch |err| candidate: {
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
        const actual_length = try file.length(io);
        if (actual_length < selection.header.member_bytes) return error.TruncatedMember;
        if (actual_length > selection.header.member_bytes) return error.UnexpectedMemberLength;

        return .{
            .io = io,
            .file = file,
            .selected_header = selection.header,
            .selected_source = selection.source,
            .degraded = selection.redundancy_degraded,
            .open_mode = open_mode,
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

    pub fn claimJournal(self: *Member) !void {
        if (self.journal_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
            return error.JournalAlreadyOpen;
    }

    pub fn releaseJournal(self: *Member) void {
        self.journal_claimed.store(false, .release);
    }

    pub fn read(self: *Member, kind: RegionKind, offset: u64, buffer: []u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.isClosed()) return error.MemberClosed;
        const file_offset = try self.position(kind, offset, buffer.len);
        const amount = try self.file.readPositionalAll(self.io, buffer, file_offset);
        if (amount != buffer.len) return error.TruncatedMember;
    }

    pub fn write(self: *Member, kind: RegionKind, offset: u64, bytes: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.writeLocked(kind, offset, bytes);
    }

    pub fn writeDurable(self: *Member, kind: RegionKind, offset: u64, bytes: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        try self.writeLocked(kind, offset, bytes);
        try self.syncLocked();
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

        try self.writeHeaderLocked(file_offset, &encoded);
        try self.syncLocked();
        self.selected_header = next_header;
        self.selected_source = target;
        self.degraded = false;
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
        self.file.writePositionalAll(self.io, write_bytes, file_offset) catch |err| {
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
        self.file.writePositionalAll(self.io, write_bytes, offset) catch |err| {
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
        try self.syncLocked();
    }

    pub fn close(self: *Member) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.isClosed()) return;

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
        self.closed.store(true, .release);
        self.file.unlock(self.io);
        self.file.close(self.io);
        if (first_error) |err| return err;
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
        self.file.sync(self.io) catch |err| {
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

pub fn openAt(io: Io, parent: Io.Dir, basename: []const u8, mode: OpenMode) !Member {
    return Member.openAt(io, parent, basename, mode);
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

fn validateCreate(
    header: member_format.Header,
    genesis_payload: genesis_payload_format.GenesisPayload,
) ![member_format.encoded_size]u8 {
    const encoded_header = try member_format.encode(header);
    if (header.header_sequence != 1) return error.InvalidInitialHeaderSequence;
    if (header.checkpoint_offset != 0 or header.checkpoint_record_sequence != 0 or
        !codec.isZero(&header.checkpoint_record_digest)) return error.InvalidInitialCheckpoint;
    try member_format.checkOpenPolicy(header, .writable);
    if (header.member_bytes > std.math.maxInt(i64)) return error.MemberTooLarge;

    const genesis_digest = try topology_format.digest(genesis_payload.topology);
    try topology_format.validateMemberHeader(genesis_payload.topology, genesis_digest, header);
    if (header.chunk_size != genesis_payload.layout.chunk_size) return error.ChunkSizeMismatch;
    const record = try genesis_payload_format.makeRecord(header.member_id, genesis_payload);
    _ = try genesis_payload_format.validateRecord(record);
    return encoded_header;
}

fn createWrite(
    file: File,
    io: Io,
    offset: u64,
    bytes: []const u8,
    fault: ?*CreateFaultController,
    point: CreateFaultPoint,
) !void {
    const action = if (fault) |controller| controller.action(point) else null;
    if (action == .before) return error.InjectedCreateFault;
    const write_bytes = if (action == .partial) bytes[0 .. bytes.len / 2] else bytes;
    try file.writePositionalAll(io, write_bytes, offset);
    if (action == .partial or action == .after) return error.InjectedCreateFault;
}

fn createSync(file: File, io: Io, fault: ?*CreateFaultController, point: CreateFaultPoint) !void {
    const action = if (fault) |controller| controller.action(point) else null;
    if (action == .before) return error.InjectedCreateFault;
    try file.sync(io);
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

fn readCandidate(file: File, io: Io, offset: u64) !member_format.Candidate {
    var bytes: [member_format.encoded_size]u8 = undefined;
    const amount = try file.readPositionalAll(io, &bytes, offset);
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
    unsupported.incompat_features = 1;
    try createRawMember(tmp.dir, "member", unsupported, unsupported, unsupported.member_bytes);
    try std.testing.expectError(error.UnsupportedIncompatFeature, openAt(std.testing.io, tmp.dir, "member", .read_only));
    unsupported = header;
    unsupported.ro_compat_features = 1;
    try createRawMember(tmp.dir, "member", unsupported, unsupported, unsupported.member_bytes);
    member = try openAt(std.testing.io, tmp.dir, "member", .read_only);
    try member.close();
    try std.testing.expectError(error.UnsupportedReadOnlyFeature, openAt(std.testing.io, tmp.dir, "member", .writable));
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
    var write_future = std.testing.io.async(durableWriteWorker, .{&member});
    var write_pending = true;
    defer if (write_pending) {
        _ = write_future.cancel(std.testing.io) catch {};
    };
    while (!pause.reached.load(.acquire)) try std.Thread.yield();

    var close_started: std.atomic.Value(bool) = .init(false);
    var close_future = std.testing.io.async(closeWorker, .{ &member, &close_started });
    var close_pending = true;
    defer if (close_pending) {
        _ = close_future.cancel(std.testing.io) catch {};
    };
    while (!close_started.load(.acquire) or member.mutex.state.load(.acquire) != .contended)
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
