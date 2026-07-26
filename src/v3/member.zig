const std = @import("std");
const member_format = @import("member_format.zig");

const Io = std.Io;
const File = Io.File;

pub const OpenMode = member_format.OpenMode;
pub const SourceSlot = member_format.SourceSlot;

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
