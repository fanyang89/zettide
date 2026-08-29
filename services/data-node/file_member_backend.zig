const std = @import("std");

const protocol = @import("zettide_data_service_contracts");
const replica_service = protocol.replica_service;

/// Development backend that binds Replica allocations to aligned ranges of one
/// pre-sized member file. Allocation ownership and tombstones are persisted by
/// replica_service.FileStore; this backend validates the physical member and
/// produces a stable identity digest without claiming that user data is
/// replicated.
pub const FileMemberBackend = struct {
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    identity: []const u8,
    member_id: protocol.Id,
    capacity_bytes: u64,
    extent_size_bytes: u64,
    backend_digest: protocol.Digest,

    pub fn init(
        io: std.Io,
        parent: std.Io.Dir,
        basename: []const u8,
        identity: []const u8,
        member_id: protocol.Id,
        capacity_bytes: u64,
        extent_size_bytes: u64,
    ) !FileMemberBackend {
        if (identity.len == 0 or isZero(&member_id) or capacity_bytes == 0 or extent_size_bytes == 0 or
            capacity_bytes % extent_size_bytes != 0)
            return error.InvalidMemberConfiguration;
        const value = FileMemberBackend{
            .io = io,
            .parent = parent,
            .basename = basename,
            .identity = identity,
            .member_id = member_id,
            .capacity_bytes = capacity_bytes,
            .extent_size_bytes = extent_size_bytes,
            .backend_digest = digestIdentity(identity, member_id, capacity_bytes, extent_size_bytes),
        };
        try value.validateFile();
        return value;
    }

    pub fn backend(self: *FileMemberBackend) replica_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn validateOpaque(context: *anyopaque, binding: replica_service.Binding) !void {
        const self: *FileMemberBackend = @ptrCast(@alignCast(context));
        try self.validateBinding(binding);
        try self.validateFile();
    }

    fn inspectOpaque(context: *anyopaque, binding: replica_service.Binding) !replica_service.BackendState {
        const self: *FileMemberBackend = @ptrCast(@alignCast(context));
        try validateOpaque(context, binding);
        return .{ .active = self.backend_digest };
    }

    fn ensureOpaque(context: *anyopaque, binding: replica_service.Binding) !protocol.Digest {
        const self: *FileMemberBackend = @ptrCast(@alignCast(context));
        try validateOpaque(context, binding);
        return self.backend_digest;
    }

    fn deleteOpaque(context: *anyopaque, binding: replica_service.Binding) !void {
        try validateOpaque(context, binding);
        // Physical reuse remains quarantined by the durable Replica ledger.
    }

    fn validateBinding(self: *const FileMemberBackend, binding: replica_service.Binding) !void {
        if (!std.mem.eql(u8, &binding.member_id, &self.member_id)) return error.MemberMismatch;
        if (binding.offset_bytes % self.extent_size_bytes != 0 or
            binding.length_bytes % self.extent_size_bytes != 0)
            return error.UnalignedAllocation;
        const end = std.math.add(u64, binding.offset_bytes, binding.length_bytes) catch
            return error.AllocationOutOfBounds;
        if (end > self.capacity_bytes) return error.AllocationOutOfBounds;
    }

    fn validateFile(self: *const FileMemberBackend) !void {
        const file = try self.parent.openFile(self.io, self.basename, .{ .mode = .read_only });
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.size != self.capacity_bytes) return error.MemberGeometryChanged;
    }

    const vtable: replica_service.Backend.VTable = .{
        .validate = validateOpaque,
        .inspect = inspectOpaque,
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
    };
};

fn digestIdentity(
    identity: []const u8,
    member_id: protocol.Id,
    capacity_bytes: u64,
    extent_size_bytes: u64,
) protocol.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-file-member-v1");
    hashField(&hasher, identity);
    hashField(&hasher, &member_id);
    hashU64(&hasher, capacity_bytes);
    hashU64(&hasher, extent_size_bytes);
    var digest: protocol.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .little);
    hasher.update(&length);
    hasher.update(value);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn isZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const test_id: protocol.Id = .{ 0x01, 0x98, 0xf5, 0x4d, 0x5c, 0x2a, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 1 };

fn testBinding() replica_service.Binding {
    return .{
        .volume_id = test_id,
        .placement_id = test_id,
        .allocation_id = test_id,
        .generation = 1,
        .member_id = test_id,
        .offset_bytes = 4096,
        .length_bytes = 8192,
    };
}

test "file member backend validates geometry and has stable identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "member.img", .{ .read = true });
    defer file.close(std.testing.io);
    try file.setLength(std.testing.io, 16 * 1024);

    var backend = try FileMemberBackend.init(
        std.testing.io,
        tmp.dir,
        "member.img",
        "/test/member.img",
        test_id,
        16 * 1024,
        4096,
    );
    const first = try backend.backend().ensure(testBinding());
    const inspected = (try backend.backend().inspect(testBinding())).?;
    try std.testing.expectEqual(first, inspected.active);

    var invalid = testBinding();
    invalid.offset_bytes = 1;
    try std.testing.expectError(error.UnalignedAllocation, backend.backend().ensure(invalid));
    invalid = testBinding();
    invalid.offset_bytes = 12 * 1024;
    try std.testing.expectError(error.AllocationOutOfBounds, backend.backend().ensure(invalid));
}

test "file member backend detects backing-file replacement geometry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "member.img", .{ .read = true });
    try file.setLength(std.testing.io, 16 * 1024);
    file.close(std.testing.io);

    var backend = try FileMemberBackend.init(
        std.testing.io,
        tmp.dir,
        "member.img",
        "/test/member.img",
        test_id,
        16 * 1024,
        4096,
    );
    const replacement = try tmp.dir.createFile(std.testing.io, "member.img", .{ .truncate = true });
    defer replacement.close(std.testing.io);
    try replacement.setLength(std.testing.io, 8 * 1024);
    try std.testing.expectError(error.MemberGeometryChanged, backend.backend().ensure(testBinding()));
}
