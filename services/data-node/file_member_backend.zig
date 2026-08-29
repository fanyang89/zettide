const std = @import("std");

const protocol = @import("zettide_data_service_contracts");
const fence_service = protocol.fence_service;
const replica_service = protocol.replica_service;
const write_service = protocol.write_service;

pub const file_write_alignment: u64 = 4096;

/// Development backend that binds Replica allocations to aligned ranges of one
/// pre-sized member file. Allocation ownership and tombstones are persisted by
/// replica_service.FileStore; this backend validates the physical member and
/// produces a stable identity digest without claiming that user data is
/// replicated.
pub const FileMemberBackend = struct {
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    file: std.Io.File,
    inode: std.Io.File.INode,
    identity: []const u8,
    member_id: protocol.Id,
    generation: protocol.Digest,
    capacity_bytes: u64,
    extent_size_bytes: u64,
    backend_digest: protocol.Digest,

    pub fn init(
        io: std.Io,
        parent: std.Io.Dir,
        basename: []const u8,
        identity: []const u8,
        member_id: protocol.Id,
        generation: protocol.Digest,
        capacity_bytes: u64,
        extent_size_bytes: u64,
    ) !FileMemberBackend {
        if (identity.len == 0 or isZero(&member_id) or isZero(&generation) or capacity_bytes == 0 or extent_size_bytes == 0 or
            extent_size_bytes % file_write_alignment != 0 or capacity_bytes % extent_size_bytes != 0)
            return error.InvalidMemberConfiguration;
        const file = try parent.openFile(io, basename, .{ .mode = .read_write });
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.size != capacity_bytes) return error.MemberGeometryChanged;
        return .{
            .io = io,
            .parent = parent,
            .basename = basename,
            .file = file,
            .inode = stat.inode,
            .identity = identity,
            .member_id = member_id,
            .generation = generation,
            .capacity_bytes = capacity_bytes,
            .extent_size_bytes = extent_size_bytes,
            .backend_digest = digestIdentity(identity, member_id, generation, capacity_bytes, extent_size_bytes, stat.inode),
        };
    }

    pub fn deinit(self: *FileMemberBackend) void {
        self.file.close(self.io);
        self.* = undefined;
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
        const stat = try self.file.stat(self.io);
        if (stat.kind != .file or stat.size != self.capacity_bytes or stat.inode != self.inode)
            return error.MemberGeometryChanged;
    }

    const vtable: replica_service.Backend.VTable = .{
        .validate = validateOpaque,
        .inspect = inspectOpaque,
        .ensure = ensureOpaque,
        .delete = deleteOpaque,
    };
};

/// Node-local development write adapter. The caller must hold the same
/// placement gate used by Replica deletion and fencing for the complete apply.
/// Every apply revalidates the exact active Replica and physical member before
/// translating the participant-relative range into the member file.
pub const FileWriteBackend = struct {
    member: *FileMemberBackend,
    replicas: *replica_service.FileStore,

    pub fn init(member: *FileMemberBackend, replicas: *replica_service.FileStore) FileWriteBackend {
        return .{ .member = member, .replicas = replicas };
    }

    pub fn backend(self: *FileWriteBackend) write_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn applyOpaque(
        context: *anyopaque,
        replica: protocol.ReplicaBinding,
        relative_offset: u64,
        data: []const u8,
    ) !void {
        const self: *FileWriteBackend = @ptrCast(@alignCast(context));
        const data_length = std.math.cast(u64, data.len) orelse return error.WriteOutOfBounds;
        if (data.len == 0 or relative_offset % file_write_alignment != 0 or
            data_length % file_write_alignment != 0)
            return error.UnalignedWrite;
        const relative_end = std.math.add(u64, relative_offset, data_length) catch
            return error.WriteOutOfBounds;
        if (relative_end > replica.length_bytes) return error.WriteOutOfBounds;
        const absolute_offset = std.math.add(u64, replica.offset_bytes, relative_offset) catch
            return error.WriteOutOfBounds;
        if (absolute_offset % file_write_alignment != 0) return error.UnalignedWrite;
        _ = std.math.add(u64, absolute_offset, data_length) catch return error.WriteOutOfBounds;

        const attestation = try self.replicas.validateActive(replica);
        if (!std.mem.eql(u8, &attestation.backend_digest, &self.member.backend_digest))
            return error.MemberBackendIdentityMismatch;
        try self.member.validateBinding(replica);
        try self.member.validateFile();
        try self.member.file.writePositionalAll(self.member.io, data, absolute_offset);
        try self.member.file.sync(self.member.io);
    }

    const vtable: write_service.Backend.VTable = .{ .apply = applyOpaque };
};

/// File-backed fencing adapter. Until participant composition supplies the
/// shared placement gate, this adapter alone is not sufficient to fence user
/// writes. It validates the durable Replica binding and synchronizes the member
/// before issuing deterministic evidence.
pub const FileFenceBackend = struct {
    member: *FileMemberBackend,
    replicas: *replica_service.FileStore,

    pub fn init(member: *FileMemberBackend, replicas: *replica_service.FileStore) FileFenceBackend {
        return .{ .member = member, .replicas = replicas };
    }

    pub fn backend(self: *FileFenceBackend) fence_service.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn quiesceDrainFlushOpaque(context: *anyopaque, binding: fence_service.Binding) !protocol.Digest {
        const self: *FileFenceBackend = @ptrCast(@alignCast(context));
        try self.replicas.validateFence(binding);
        try self.member.validateFile();
        try self.member.file.sync(self.member.io);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hasher, "zettide-file-fence-v1");
        hashField(&hasher, &self.member.backend_digest);
        hashField(&hasher, &binding.volume_id);
        hashField(&hasher, &binding.placement_id);
        hashU64(&hasher, binding.replica_generation);
        hashU64(&hasher, binding.write_epoch);
        hashField(&hasher, &binding.primary_node_id);
        hashField(&hasher, &binding.lease_id);
        hashField(&hasher, &binding.authority_digest);
        var digest: protocol.Digest = undefined;
        hasher.final(&digest);
        return digest;
    }

    const vtable: fence_service.Backend.VTable = .{
        .quiesceDrainFlush = quiesceDrainFlushOpaque,
    };
};

fn digestIdentity(
    identity: []const u8,
    member_id: protocol.Id,
    generation: protocol.Digest,
    capacity_bytes: u64,
    extent_size_bytes: u64,
    inode: std.Io.File.INode,
) protocol.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "zettide-file-member-v1");
    hashField(&hasher, identity);
    hashField(&hasher, &member_id);
    hashField(&hasher, &generation);
    hashU64(&hasher, capacity_bytes);
    hashU64(&hasher, extent_size_bytes);
    hashU64(&hasher, @intCast(inode));
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
const test_generation: protocol.Digest = @splat(0x6a);

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

fn testReplicaRequest(operation_id: []const u8) protocol.ReplicaRequest {
    return .{
        .operation_id = operation_id,
        .volume_id = "0198f54d-5c2a-7000-8000-000000000011",
        .placement_id = "0198f54d-5c2a-7000-8000-000000000012",
        .allocation_id = "0198f54d-5c2a-7000-8000-000000000013",
        .generation = 1,
        .member_id = &test_id,
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

    try std.testing.expectError(
        error.InvalidMemberConfiguration,
        FileMemberBackend.init(
            std.testing.io,
            tmp.dir,
            "member.img",
            "/test/member.img",
            test_id,
            test_generation,
            24 * 1024,
            6144,
        ),
    );
    var backend = try FileMemberBackend.init(
        std.testing.io,
        tmp.dir,
        "member.img",
        "/test/member.img",
        test_id,
        test_generation,
        16 * 1024,
        4096,
    );
    defer backend.deinit();
    const first = try backend.backend().ensure(testBinding());
    const inspected = (try backend.backend().inspect(testBinding())).?;
    try std.testing.expectEqual(first, inspected.active);
    var next_generation = test_generation;
    next_generation[0] ^= 1;
    var rebound = try FileMemberBackend.init(
        std.testing.io,
        tmp.dir,
        "member.img",
        "/test/member.img",
        test_id,
        next_generation,
        16 * 1024,
        4096,
    );
    defer rebound.deinit();
    try std.testing.expect(!std.mem.eql(u8, &backend.backend_digest, &rebound.backend_digest));

    var invalid = testBinding();
    invalid.offset_bytes = 1;
    try std.testing.expectError(error.UnalignedAllocation, backend.backend().ensure(invalid));
    invalid = testBinding();
    invalid.offset_bytes = 12 * 1024;
    try std.testing.expectError(error.AllocationOutOfBounds, backend.backend().ensure(invalid));
}

test "file write backend applies only to the exact active Replica extent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "member.img", .{ .read = true });
    defer file.close(std.testing.io);
    try file.setLength(std.testing.io, 16 * 1024);

    var member = try FileMemberBackend.init(
        std.testing.io,
        tmp.dir,
        "member.img",
        "/test/member.img",
        test_id,
        test_generation,
        16 * 1024,
        4096,
    );
    defer member.deinit();
    var replicas = try replica_service.FileStore.init(std.testing.allocator, std.testing.io, tmp.dir, "replicas.state");
    defer replicas.deinit();
    var replica_service_instance = replica_service.Service.init(replicas.store(), member.backend());
    const ensured = try replica_service_instance.ensureReplica(
        testReplicaRequest("0198f54d-5c2a-7000-8000-000000000014"),
    );
    var writer = FileWriteBackend.init(&member, &replicas);
    var payload: [4096]u8 = @splat(0xa5);
    try writer.backend().apply(ensured.replica.attestation.binding, 0, &payload);
    var actual: [4096]u8 = undefined;
    try std.testing.expectEqual(
        actual.len,
        try file.readPositionalAll(std.testing.io, &actual, 4096),
    );
    try std.testing.expectEqualSlices(u8, &payload, &actual);

    try std.testing.expectError(
        error.UnalignedWrite,
        writer.backend().apply(ensured.replica.attestation.binding, 1, &payload),
    );
    var wrong = ensured.replica.attestation.binding;
    wrong.allocation_id[15] +%= 1;
    try std.testing.expectError(error.ReplicaBindingMismatch, writer.backend().apply(wrong, 0, &payload));

    _ = try replica_service_instance.deleteReplica(
        testReplicaRequest("0198f54d-5c2a-7000-8000-000000000015"),
    );
    try std.testing.expectError(
        error.ReplicaNotActive,
        writer.backend().apply(ensured.replica.attestation.binding, 0, &payload),
    );
}

test "file member backend remains bound to opened inode across same-size path replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = try tmp.dir.createFile(std.testing.io, "member.img", .{});
    try original.setLength(std.testing.io, 16 * 1024);
    original.close(std.testing.io);
    var backend = try FileMemberBackend.init(
        std.testing.io,
        tmp.dir,
        "member.img",
        "/test/member.img",
        test_id,
        test_generation,
        16 * 1024,
        4096,
    );
    defer backend.deinit();
    const replacement = try tmp.dir.createFile(std.testing.io, "replacement.img", .{});
    try replacement.setLength(std.testing.io, 16 * 1024);
    replacement.close(std.testing.io);
    try std.Io.Dir.rename(tmp.dir, "replacement.img", tmp.dir, "member.img", std.testing.io);
    _ = try backend.backend().ensure(testBinding());

    var reopened = try FileMemberBackend.init(
        std.testing.io,
        tmp.dir,
        "member.img",
        "/test/member.img",
        test_id,
        test_generation,
        16 * 1024,
        4096,
    );
    defer reopened.deinit();
    try std.testing.expect(!std.mem.eql(u8, &backend.backend_digest, &reopened.backend_digest));
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
        test_generation,
        16 * 1024,
        4096,
    );
    defer backend.deinit();
    const replacement = try tmp.dir.createFile(std.testing.io, "member.img", .{ .truncate = true });
    defer replacement.close(std.testing.io);
    try replacement.setLength(std.testing.io, 8 * 1024);
    try std.testing.expectError(error.MemberGeometryChanged, backend.backend().ensure(testBinding()));
}
