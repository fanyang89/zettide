const std = @import("std");

const protocol = @import("zettide_data_service_contracts");

pub const Phase = enum(u8) {
    staged = 1,
    recovered = 2,
    ready = 3,
};

pub const Record = struct {
    binding: protocol.AuthorityBinding,
    phase: Phase,
    certified_sequence: u64 = 0,
    history_digest: protocol.Digest = @splat(0),
    empty_frontier: bool = false,
};

/// Append-only authority acceptance ledger. Lease deadlines remain process-local
/// and fail closed after restart, while the maximum accepted epoch/generation
/// survives restart and prevents stale authority from being staged.
pub const FileStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    records: []Record,
    poisoned: bool = false,
    faults: ?*Faults = null,

    pub const Faults = struct {
        fail_directory_sync_once_at_record_count: ?usize = null,
    };

    const magic = "ZETAUTH1".*;
    const version: u16 = 1;
    const header_size: usize = 24;
    const record_size: usize = 208;
    const max_records: usize = 16 * 1024;
    const max_file_size = header_size + max_records * record_size;

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

    pub fn latest(self: *const FileStore, volume_id: protocol.Id) ?Record {
        var index = self.records.len;
        while (index != 0) {
            index -= 1;
            if (std.mem.eql(u8, &self.records[index].binding.volume_id, &volume_id)) return self.records[index];
        }
        return null;
    }

    /// Validates a transition against the durable maximum. Returns the current
    /// exact-binding record when the requested phase was already reached.
    pub fn validate(self: *const FileStore, binding: protocol.AuthorityBinding, phase: Phase) !?Record {
        if (self.poisoned) return error.StorePoisoned;
        try validateBinding(binding);
        const current = self.latest(binding.volume_id) orelse {
            if (phase != .staged) return error.AuthorityNotStaged;
            return null;
        };
        if (binding.write_epoch < current.binding.write_epoch or
            binding.authority_generation < current.binding.authority_generation)
            return error.StaleAuthority;
        if (binding.write_epoch == current.binding.write_epoch and
            binding.authority_generation == current.binding.authority_generation)
        {
            if (!std.meta.eql(binding, current.binding)) return error.AuthorityConflict;
            if (@intFromEnum(phase) <= @intFromEnum(current.phase)) return current;
            return null;
        }
        if (phase != .staged) return error.AuthorityNotStaged;
        return null;
    }

    pub fn append(self: *FileStore, record: Record) !void {
        if (try self.validate(record.binding, record.phase)) |existing| {
            if (!sameEvidence(existing, record)) return error.AuthorityConflict;
            return;
        }
        try validateRecord(record);
        if (self.records.len == max_records) return error.StoreFull;
        const replacement = try self.allocator.alloc(Record, self.records.len + 1);
        var installed = false;
        errdefer if (!installed) self.allocator.free(replacement);
        @memcpy(replacement[0..self.records.len], self.records);
        replacement[self.records.len] = record;
        try self.replace(replacement);
        self.syncParent(replacement.len) catch |err| {
            self.poisoned = true;
            return err;
        };
        const previous = self.records;
        self.records = replacement;
        installed = true;
        if (previous.len != 0) self.allocator.free(previous);
    }

    fn replace(self: *FileStore, records: []const Record) !void {
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

    fn encode(allocator: std.mem.Allocator, records: []const Record) ![]u8 {
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

    fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Record {
        if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..8], &magic) or
            std.mem.readInt(u16, bytes[8..10], .little) != version or
            std.mem.readInt(u16, bytes[10..12], .little) != record_size or
            !allZero(bytes[20..24])) return error.StoreCorrupt;
        const count = std.mem.readInt(u32, bytes[12..16], .little);
        if (count > max_records or bytes.len != header_size + @as(usize, count) * record_size or
            std.mem.readInt(u32, bytes[16..20], .little) != std.hash.crc.Crc32Iscsi.hash(bytes[header_size..]))
            return error.StoreCorrupt;
        const records = try allocator.alloc(Record, count);
        errdefer allocator.free(records);
        for (records, 0..) |*record, index| {
            record.* = try decodeRecord(bytes[header_size + index * record_size ..][0..record_size]);
            var prior = FileStore{
                .allocator = allocator,
                .io = undefined,
                .parent = undefined,
                .basename = "",
                .records = records[0..index],
            };
            if (try prior.validate(record.binding, record.phase)) |existing| {
                if (!sameEvidence(existing, record.*)) return error.StoreCorrupt;
            }
        }
        return records;
    }

    fn encodeRecord(bytes: *[record_size]u8, record: Record) void {
        @memset(bytes, 0);
        const binding = record.binding;
        @memcpy(bytes[0..16], &binding.volume_id);
        @memcpy(bytes[16..32], &binding.primary_placement_id);
        @memcpy(bytes[32..48], &binding.primary_node_id);
        @memcpy(bytes[48..64], &binding.lease_id);
        @memcpy(bytes[64..80], &binding.holder_boot_id);
        std.mem.writeInt(u64, bytes[80..88], binding.authority_generation, .little);
        std.mem.writeInt(u64, bytes[88..96], binding.write_epoch, .little);
        std.mem.writeInt(u64, bytes[96..104], binding.placement_revision, .little);
        @memcpy(bytes[104..120], &binding.activation_nonce);
        @memcpy(bytes[120..152], &binding.authority_digest);
        bytes[152] = @intFromEnum(record.phase);
        std.mem.writeInt(u64, bytes[160..168], record.certified_sequence, .little);
        @memcpy(bytes[168..200], &record.history_digest);
        bytes[200] = @intFromBool(record.empty_frontier);
    }

    fn decodeRecord(bytes: *const [record_size]u8) !Record {
        if (!allZero(bytes[153..160]) or !allZero(bytes[201..208]) or bytes[200] > 1)
            return error.StoreCorrupt;
        const phase = std.enums.fromInt(Phase, bytes[152]) orelse return error.StoreCorrupt;
        const record: Record = .{
            .binding = .{
                .volume_id = bytes[0..16].*,
                .primary_placement_id = bytes[16..32].*,
                .primary_node_id = bytes[32..48].*,
                .lease_id = bytes[48..64].*,
                .holder_boot_id = bytes[64..80].*,
                .authority_generation = std.mem.readInt(u64, bytes[80..88], .little),
                .write_epoch = std.mem.readInt(u64, bytes[88..96], .little),
                .placement_revision = std.mem.readInt(u64, bytes[96..104], .little),
                .activation_nonce = bytes[104..120].*,
                .authority_digest = bytes[120..152].*,
            },
            .phase = phase,
            .certified_sequence = std.mem.readInt(u64, bytes[160..168], .little),
            .history_digest = bytes[168..200].*,
            .empty_frontier = bytes[200] == 1,
        };
        validateRecord(record) catch return error.StoreCorrupt;
        return record;
    }
};

fn validateRecord(record: Record) !void {
    try validateBinding(record.binding);
    switch (record.phase) {
        .staged => if (record.certified_sequence != 0 or !allZero(&record.history_digest) or record.empty_frontier)
            return error.InvalidEvidence,
        .recovered => if ((record.certified_sequence == 0) != record.empty_frontier or allZero(&record.history_digest))
            return error.InvalidEvidence,
        .ready => {
            const no_recovery = record.certified_sequence == 0 and !record.empty_frontier and allZero(&record.history_digest);
            const valid_recovery = (record.certified_sequence == 0) == record.empty_frontier and !allZero(&record.history_digest);
            if (!no_recovery and !valid_recovery) return error.InvalidEvidence;
        },
    }
}

fn validateBinding(binding: protocol.AuthorityBinding) !void {
    if (!validUuid(binding.volume_id) or !validUuid(binding.primary_placement_id) or
        !validUuid(binding.primary_node_id) or !validUuid(binding.lease_id) or
        !validUuid(binding.holder_boot_id) or !validUuid(binding.activation_nonce) or
        binding.authority_generation == 0 or binding.write_epoch == 0 or binding.placement_revision == 0 or
        allZero(&binding.authority_digest)) return error.InvalidBinding;
}

fn sameEvidence(a: Record, b: Record) bool {
    return std.meta.eql(a.binding, b.binding) and a.phase == b.phase and
        a.certified_sequence == b.certified_sequence and
        std.mem.eql(u8, &a.history_digest, &b.history_digest) and
        a.empty_frontier == b.empty_frontier;
}

fn validUuid(id: protocol.Id) bool {
    return id[6] & 0xf0 == 0x70 and id[8] & 0xc0 == 0x80;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn testId(byte: u8) protocol.Id {
    var id: protocol.Id = @splat(byte);
    id[6] = 0x70 | (byte & 0x0f);
    id[8] = 0x80 | (byte & 0x3f);
    return id;
}

fn testBinding(generation: u64, epoch: u64) protocol.AuthorityBinding {
    return .{
        .volume_id = testId(1),
        .primary_placement_id = testId(2),
        .primary_node_id = testId(3),
        .lease_id = testId(@intCast(3 + generation)),
        .holder_boot_id = testId(5),
        .authority_generation = generation,
        .write_epoch = epoch,
        .placement_revision = 1,
        .activation_nonce = testId(@intCast(6 + generation)),
        .authority_digest = @splat(@as(u8, @intCast(generation))),
    };
}

test "authority ledger persists monotonic epoch and recovery evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "authority.state");
        defer store.deinit();
        const first = testBinding(1, 7);
        try store.append(.{ .binding = first, .phase = .staged });
        const digest: protocol.Digest = @splat(0x55);
        try store.append(.{
            .binding = first,
            .phase = .recovered,
            .history_digest = digest,
            .empty_frontier = true,
        });
    }
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "authority.state");
        defer store.deinit();
        try std.testing.expectError(error.StaleAuthority, store.validate(testBinding(2, 6), .staged));
        try store.append(.{ .binding = testBinding(2, 7), .phase = .staged });
        try std.testing.expectError(error.StaleAuthority, store.validate(testBinding(1, 8), .staged));
        try std.testing.expectError(error.StaleAuthority, store.validate(testBinding(3, 6), .staged));
        try std.testing.expectEqual(@as(u64, 2), store.latest(testId(1)).?.binding.authority_generation);
    }
}

test "authority ledger poisons uncertain directory sync until reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "authority.state");
        defer store.deinit();
        var faults: FileStore.Faults = .{ .fail_directory_sync_once_at_record_count = 1 };
        store.faults = &faults;
        try std.testing.expectError(
            error.InjectedDirectorySyncFailure,
            store.append(.{ .binding = testBinding(1, 7), .phase = .staged }),
        );
        try std.testing.expect(store.poisoned);
        try std.testing.expectError(error.StorePoisoned, store.validate(testBinding(2, 8), .staged));
    }
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "authority.state");
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 7), store.latest(testId(1)).?.binding.write_epoch);
        try std.testing.expectError(error.StaleAuthority, store.validate(testBinding(2, 6), .staged));
    }
}

test "authority ledger rejects corrupt bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "authority.state");
        defer store.deinit();
        try store.append(.{ .binding = testBinding(1, 7), .phase = .staged });
    }
    const file = try tmp.dir.openFile(std.testing.io, "authority.state", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "X", 0);
    try std.testing.expectError(
        error.StoreCorrupt,
        FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "authority.state"),
    );
}
