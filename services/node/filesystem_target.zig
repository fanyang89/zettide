const std = @import("std");
const storage_engine = @import("zettide_storage");
const blob_device = storage_engine.blob_device;
const blob_filesystem = storage_engine.blob_filesystem;
const blob_filesystem_format = storage_engine.blob_filesystem_format;
const blob_format = storage_engine.blob_format;
const blob_store = storage_engine.blob_store;
const google_crc32c = @import("crc32c");
const member_format = storage_engine.v3.member_format;
const name_profile = storage_engine.name_profile;
const pool_data_storage = storage_engine.v3.pool_data_storage;
const pool_member_set = storage_engine.v3.pool_member_set;
const pool_policy = storage_engine.v3.pool_policy;
const pool_provision = storage_engine.v3.pool_provision;
const storage_api = storage_engine.v3.storage;

const Io = std.Io;
const header_size: usize = 4096;
const header_a_offset: u64 = 0;
const header_b_offset: u64 = header_size;
const legacy_magic = "LFSDRV2\x00";

pub const FormatKind = enum {
    unknown,
    littlefs_container,
    pool_member,
    blob,
};

pub const TargetKind = enum { regular_file };

const RegularIdentity = struct {
    inode: u64,
    mtime_ns: i96,
    ctime_ns: i96,
};

pub const FormatPlan = struct {
    path: []const u8,
    name_profile: name_profile.Profile,
    canonical_path_digest: [32]u8,
    kind: TargetKind = .regular_file,
    capacity_bytes: u64,
    contains_data: bool,
    data_digest: [32]u8,
    token: [32]u8,
    identity: RegularIdentity,
};

pub const BlobFormatPlan = struct {
    target_plan: FormatPlan,
    format_options: blob_filesystem.Filesystem.FormatOptions,
    eligible: bool,
    token: [32]u8,

    pub fn tokenText(self: *const BlobFormatPlan, buffer: *[64]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{x}", .{self.token}) catch unreachable;
    }
};

pub const AcquiredBlobFormat = struct {
    storage: storage_api.Storage,
    io: Io,
    storage_owned: bool = true,
    plan: BlobFormatPlan,

    pub fn deinit(self: *AcquiredBlobFormat) void {
        if (self.storage_owned) self.storage.close(self.io) catch {};
        self.storage_owned = false;
    }

    pub fn apply(
        self: *AcquiredBlobFormat,
        allocator: std.mem.Allocator,
        confirmation: []const u8,
        profile: name_profile.Profile,
        options: blob_filesystem.Filesystem.FormatOptions,
    ) !void {
        if (profile != self.plan.target_plan.name_profile) return error.FormatPlanChanged;
        if (options.root_uid != self.plan.format_options.root_uid or
            options.root_gid != self.plan.format_options.root_gid)
            return error.FormatPlanChanged;
        const expected = blobPlan(self.plan.target_plan, options);
        if (!std.mem.eql(u8, &expected.token, &self.plan.token) or expected.eligible != self.plan.eligible)
            return error.FormatPlanChanged;
        var token_buffer: [64]u8 = undefined;
        if (!std.mem.eql(u8, confirmation, self.plan.tokenText(&token_buffer)))
            return error.ConfirmationMismatch;
        if (!self.plan.eligible) return error.TargetNotEligible;

        const capacity = self.storage.capacity();
        const device = try blob_device.Device.init(
            self.storage,
            0,
            capacity,
            blob_format.allocation_unit,
        );
        self.storage_owned = false;
        const blobs = try blob_store.Store.create(allocator, self.io, device);
        var filesystem = try blob_filesystem.Filesystem.formatOptions(
            allocator,
            self.io,
            blobs,
            profile,
            options,
        );
        try filesystem.close(self.io);
    }
};

pub fn classifyHeaderSlots(first: []const u8, second: []const u8) !FormatKind {
    const first_kind = headerKind(first);
    const second_kind = headerKind(second);
    if (first_kind != .unknown and second_kind != .unknown and first_kind != second_kind)
        return error.ConflictingTargetFormats;
    return if (first_kind != .unknown) first_kind else second_kind;
}

pub fn classifyPath(io: Io, path: []const u8) !FormatKind {
    var storage = openRegularStorage(io, path, false) catch |err| switch (err) {
        error.BlobRequiresRegularFile => return .unknown,
        else => return err,
    };
    defer storage.close(io) catch {};
    var first: [header_size]u8 = undefined;
    var second: [header_size]u8 = undefined;
    const first_len = try storage.readAt(io, &first, header_a_offset);
    const second_len = try storage.readAt(io, &second, header_b_offset);
    return classifyHeaderSlots(first[0..first_len], second[0..second_len]);
}

pub fn inspectBlobFormat(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    profile: name_profile.Profile,
    options: blob_filesystem.Filesystem.FormatOptions,
) !BlobFormatPlan {
    try requireRegularFile(io, path);
    var opened = try openRegularFormatStorage(io, path, false);
    defer opened.storage.close(io) catch {};
    try rejectLegacyFormat(&opened.storage, io);
    return blobPlan(try inspectStorage(
        io,
        allocator,
        path,
        profile,
        &opened.storage,
        opened.identity,
    ), options);
}

pub fn acquireBlobFormat(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    profile: name_profile.Profile,
    options: blob_filesystem.Filesystem.FormatOptions,
) !AcquiredBlobFormat {
    try requireRegularFile(io, path);
    var opened = try openRegularFormatStorage(io, path, true);
    errdefer opened.storage.close(io) catch {};
    try rejectLegacyFormat(&opened.storage, io);
    return .{
        .plan = blobPlan(try inspectStorage(
            io,
            allocator,
            path,
            profile,
            &opened.storage,
            opened.identity,
        ), options),
        .storage = opened.storage,
        .io = io,
    };
}

pub fn formatNewBlobFile(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    size: u64,
    profile: name_profile.Profile,
    options: blob_filesystem.Filesystem.FormatOptions,
) !void {
    _ = try blob_format.Header.init(io, size);
    const device = try blob_device.Device.createFile(
        io,
        Io.Dir.cwd(),
        path,
        size,
        blob_format.allocation_unit,
    );
    var remove_on_failure = true;
    errdefer if (remove_on_failure) Io.Dir.cwd().deleteFile(io, path) catch {};
    const blobs = try blob_store.Store.create(allocator, io, device);
    var filesystem = try blob_filesystem.Filesystem.formatOptions(
        allocator,
        io,
        blobs,
        profile,
        options,
    );
    try filesystem.close(io);
    remove_on_failure = false;
}

pub fn openBlobFilesystem(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
    writable: bool,
) !blob_filesystem.Filesystem {
    var storage = try openRegularStorage(io, path, writable);
    var storage_owned = true;
    errdefer if (storage_owned) storage.close(io) catch {};
    const device = try blob_device.Device.init(
        storage,
        0,
        storage.capacity(),
        blob_format.allocation_unit,
    );
    storage_owned = false;
    const blobs = try blob_store.Store.open(allocator, io, device);
    return blob_filesystem.Filesystem.open(allocator, io, blobs, writable);
}

/// Takes the provisioned Pool after its members have been adopted successfully.
pub fn formatProvisionedBlobPool(
    allocator: std.mem.Allocator,
    io: Io,
    provisioned: *pool_provision.ProvisionedPool,
    profile: name_profile.Profile,
    options: blob_filesystem.Filesystem.FormatOptions,
) !blob_filesystem.Filesystem {
    var set = try provisioned.intoMemberSet();
    errdefer set.deinit();
    return formatBlobPoolSet(allocator, io, &set, profile, options);
}

/// Leaves set untouched on marker rejection. Once Pool storage is created, failures
/// close the complete ownership chain.
pub fn formatBlobPoolSet(
    allocator: std.mem.Allocator,
    io: Io,
    set: *pool_member_set.PoolMemberSet,
    profile: name_profile.Profile,
    options: blob_filesystem.Filesystem.FormatOptions,
) !blob_filesystem.Filesystem {
    if (try set.dataMode() != .blob) return error.PoolDataRequiresBlobFilesystem;
    const storage = try pool_data_storage.create(allocator, io, set, true);
    const device = blob_device.Device.init(
        storage,
        0,
        storage.capacity(),
        blob_format.allocation_unit,
    ) catch |err| {
        var owned_storage = storage;
        owned_storage.close(io) catch {};
        return err;
    };
    const blobs = try blob_store.Store.create(allocator, io, device);
    return blob_filesystem.Filesystem.formatOptions(allocator, io, blobs, profile, options);
}

/// Leaves set untouched on marker rejection and preserves its access mode. Once
/// Pool storage is created, failures close the complete ownership chain.
pub fn openBlobPoolFilesystem(
    allocator: std.mem.Allocator,
    io: Io,
    set: *pool_member_set.PoolMemberSet,
    writable: bool,
) !blob_filesystem.Filesystem {
    if (try set.dataMode() != .blob) return error.PoolDataRequiresBlobFilesystem;
    const storage = try pool_data_storage.create(allocator, io, set, writable);
    const device = blob_device.Device.init(
        storage,
        0,
        storage.capacity(),
        blob_format.allocation_unit,
    ) catch |err| {
        var owned_storage = storage;
        owned_storage.close(io) catch {};
        return err;
    };
    const blobs = try blob_store.Store.open(allocator, io, device);
    return blob_filesystem.Filesystem.open(allocator, io, blobs, writable);
}

fn blobPlan(
    target_plan: FormatPlan,
    options: blob_filesystem.Filesystem.FormatOptions,
) BlobFormatPlan {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("zettide-blob-format-plan-v1\x00");
    hasher.update(&target_plan.token);
    var owner: [8]u8 = undefined;
    std.mem.writeInt(u32, owner[0..4], options.root_uid, .little);
    std.mem.writeInt(u32, owner[4..8], options.root_gid, .little);
    hasher.update(&owner);
    var token: [32]u8 = undefined;
    hasher.final(&token);
    return .{
        .target_plan = target_plan,
        .format_options = options,
        .eligible = validBlobSize(target_plan.capacity_bytes),
        .token = token,
    };
}

fn validBlobSize(size: u64) bool {
    return size >= blob_format.minimum_device_size and size % blob_format.blob_size == 0;
}

fn requireRegularFile(io: Io, path: []const u8) !void {
    if ((try Io.Dir.cwd().statFile(io, path, .{})).kind != .file)
        return error.BlobRequiresRegularFile;
}

fn openRegularStorage(io: Io, path: []const u8, writable: bool) !storage_api.Storage {
    const file = try Io.Dir.cwd().openFile(io, path, .{
        .mode = if (writable) .read_write else .read_only,
        .lock = if (writable) .exclusive else .shared,
        .lock_nonblocking = true,
    });
    errdefer {
        file.unlock(io);
        file.close(io);
    }
    try requireRegularKind((try file.stat(io)).kind);
    return storage_api.Storage.initOwned(file, try file.length(io), .regular_file, 1, true);
}

fn openRegularFormatStorage(io: Io, path: []const u8, writable: bool) !struct {
    storage: storage_api.Storage,
    identity: RegularIdentity,
} {
    const file = try Io.Dir.cwd().openFile(io, path, .{
        .mode = if (writable) .read_write else .read_only,
        .lock = if (writable) .exclusive else .shared,
        .lock_nonblocking = true,
    });
    errdefer {
        file.unlock(io);
        file.close(io);
    }
    const stat = try file.stat(io);
    try requireRegularKind(stat.kind);
    return .{
        .storage = storage_api.Storage.initOwned(file, try file.length(io), .regular_file, 1, true),
        .identity = .{
            .inode = @bitCast(stat.inode),
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
        },
    };
}

fn inspectStorage(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    profile: name_profile.Profile,
    storage: *storage_api.Storage,
    identity: RegularIdentity,
) !FormatPlan {
    const scan = try scanStorage(storage, io, allocator);
    var plan: FormatPlan = .{
        .path = path,
        .name_profile = profile,
        .canonical_path_digest = try canonicalPathDigest(io, path),
        .capacity_bytes = storage.capacity(),
        .contains_data = scan.contains_data,
        .data_digest = scan.digest,
        .token = undefined,
        .identity = identity,
    };
    plan.token = computeToken(&plan);
    return plan;
}

const StorageScan = struct {
    contains_data: bool,
    digest: [32]u8,
};

fn scanStorage(storage: *storage_api.Storage, io: Io, allocator: std.mem.Allocator) !StorageScan {
    const chunk_size = 1024 * 1024;
    const buffer = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buffer);
    var hasher = std.crypto.hash.Blake3.init(.{});
    var contains_data = false;
    var offset: u64 = 0;
    while (offset < storage.capacity()) {
        const amount: usize = @intCast(@min(@as(u64, buffer.len), storage.capacity() - offset));
        if (try storage.readAt(io, buffer[0..amount], offset) != amount) return error.TruncatedTarget;
        hasher.update(buffer[0..amount]);
        contains_data = contains_data or !std.mem.allEqual(u8, buffer[0..amount], 0);
        offset += amount;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .contains_data = contains_data, .digest = digest };
}

fn computeToken(plan: *const FormatPlan) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("zettide-blob-target-plan-v1\x00");
    hasher.update(&plan.canonical_path_digest);
    hasher.update(&plan.data_digest);
    hasher.update(plan.name_profile.name());
    var values: [41]u8 = undefined;
    std.mem.writeInt(u64, values[0..8], plan.capacity_bytes, .little);
    std.mem.writeInt(u64, values[8..16], plan.identity.inode, .little);
    std.mem.writeInt(i96, values[16..28], plan.identity.mtime_ns, .little);
    std.mem.writeInt(i96, values[28..40], plan.identity.ctime_ns, .little);
    values[40] = @intFromBool(plan.contains_data);
    hasher.update(&values);
    var token: [32]u8 = undefined;
    hasher.final(&token);
    return token;
}

fn canonicalPathDigest(io: Io, path: []const u8) ![32]u8 {
    var canonical: [Io.Dir.max_path_bytes]u8 = undefined;
    const length = try Io.Dir.cwd().realPathFile(io, path, &canonical);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(canonical[0..length], &digest, .{});
    return digest;
}

fn rejectLegacyFormat(storage: *storage_api.Storage, io: Io) !void {
    var first: [header_size]u8 = undefined;
    var second: [header_size]u8 = undefined;
    const first_len = try storage.readAt(io, &first, header_a_offset);
    const second_len = try storage.readAt(io, &second, header_b_offset);
    if (headerKind(first[0..first_len]) == .littlefs_container or
        headerKind(second[0..second_len]) == .littlefs_container)
        return error.UnsupportedLegacyFormat;
}

fn requireRegularKind(kind: Io.File.Kind) !void {
    if (kind != .file) return error.BlobRequiresRegularFile;
}

fn headerKind(bytes: []const u8) FormatKind {
    if (blob_format.hasHeaderMagic(bytes)) return .blob;
    if (bytes.len >= legacy_magic.len and std.mem.eql(u8, bytes[0..legacy_magic.len], legacy_magic))
        return .littlefs_container;
    if (member_format.hasHeaderMagic(bytes)) return .pool_member;
    return .unknown;
}

const pool_test_names = [_][]const u8{ "member-a", "member-b", "member-c" };

fn provisionBlobTestPool(
    dir: Io.Dir,
    protection: pool_policy.Protection,
) !pool_provision.ProvisionedPool {
    const member_count = try protection.fullWidth();
    var storages: [pool_test_names.len]storage_api.Storage = undefined;
    for (pool_test_names[0..member_count], storages[0..member_count]) |name, *storage|
        storage.* = try storage_api.Storage.createFile(std.testing.io, dir, name, 16 * 1024 * 1024);
    const outcome = try pool_provision.create(
        std.testing.io,
        std.testing.allocator,
        storages[0..member_count],
        .{ .protection = protection, .data_mode = .blob },
    );
    return switch (outcome) {
        .complete => |value| value,
        .partial => error.UnexpectedPartialCreation,
    };
}

fn openBlobTestPoolSet(
    dir: Io.Dir,
    member_count: usize,
    writable: bool,
) !pool_member_set.PoolMemberSet {
    var storages: [pool_test_names.len]storage_api.Storage = undefined;
    for (pool_test_names[0..member_count], storages[0..member_count]) |name, *storage|
        storage.* = try storage_api.Storage.openFile(std.testing.io, dir, name, writable);
    return pool_member_set.PoolMemberSet.openStorages(
        std.testing.io,
        std.testing.allocator,
        storages[0..member_count],
        if (writable) .writable else .read_only,
    );
}

test "Blob Pool format and writable and read-only reopen round trip" {
    const protections = [_]pool_policy.Protection{ .unprotected, .replicated };
    for (protections) |protection| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const member_count = try protection.fullWidth();
        var provisioned = try provisionBlobTestPool(tmp.dir, protection);
        defer provisioned.deinit();
        var formatted = try formatProvisionedBlobPool(
            std.testing.allocator,
            std.testing.io,
            &provisioned,
            .portable_v1,
            .{ .root_uid = 123, .root_gid = 456 },
        );
        try std.testing.expectEqual(name_profile.Profile.portable_v1, formatted.root.name_profile);
        const root = try formatted.stat(std.testing.io, blob_filesystem_format.root_inode);
        try std.testing.expectEqual(@as(u32, 123), root.metadata.uid);
        try std.testing.expectEqual(@as(u32, 456), root.metadata.gid);
        const inode = try formatted.createFile(
            std.testing.io,
            blob_filesystem_format.root_inode,
            "payload",
            0o640,
            123,
            456,
        );
        try std.testing.expectEqual(@as(usize, 5), try formatted.write(std.testing.io, inode, "first", 0));
        try formatted.close(std.testing.io);

        var read_set = try openBlobTestPoolSet(tmp.dir, member_count, false);
        defer read_set.deinit();
        var readonly = try openBlobPoolFilesystem(
            std.testing.allocator,
            std.testing.io,
            &read_set,
            false,
        );
        const reopened_inode = try readonly.resolvePath(std.testing.io, "/payload");
        var first: [5]u8 = undefined;
        try std.testing.expectEqual(first.len, try readonly.read(std.testing.io, reopened_inode, &first, 0));
        try std.testing.expectEqualStrings("first", &first);
        try std.testing.expectError(
            error.ReadOnlyFilesystem,
            readonly.write(std.testing.io, reopened_inode, "x", 0),
        );
        try readonly.close(std.testing.io);

        var write_set = try openBlobTestPoolSet(tmp.dir, member_count, true);
        defer write_set.deinit();
        var writable = try openBlobPoolFilesystem(
            std.testing.allocator,
            std.testing.io,
            &write_set,
            true,
        );
        const writable_inode = try writable.resolvePath(std.testing.io, "/payload");
        try std.testing.expectEqual(@as(usize, 6), try writable.write(std.testing.io, writable_inode, "-again", 5));
        try writable.close(std.testing.io);

        var final_set = try openBlobTestPoolSet(tmp.dir, member_count, false);
        defer final_set.deinit();
        var final = try openBlobPoolFilesystem(
            std.testing.allocator,
            std.testing.io,
            &final_set,
            false,
        );
        defer final.close(std.testing.io) catch {};
        const final_inode = try final.resolvePath(std.testing.io, "/payload");
        var contents: [11]u8 = undefined;
        try std.testing.expectEqual(contents.len, try final.read(std.testing.io, final_inode, &contents, 0));
        try std.testing.expectEqualStrings("first-again", &contents);
    }
}

test "Catalog Pool marker rejects Blob formatting without data changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storages = [_]storage_api.Storage{
        try storage_api.Storage.createFile(std.testing.io, tmp.dir, "member-a", 8 * 1024 * 1024),
    };
    const outcome = try pool_provision.create(
        std.testing.io,
        std.testing.allocator,
        &storages,
        .{ .protection = .unprotected, .data_mode = .catalog },
    );
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    const before = try tmp.dir.readFileAlloc(
        std.testing.io,
        "member-a",
        std.testing.allocator,
        .limited(8 * 1024 * 1024 + 1),
    );
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.PoolDataRequiresBlobFilesystem,
        formatProvisionedBlobPool(
            std.testing.allocator,
            std.testing.io,
            &provisioned,
            .legacy_raw,
            .{},
        ),
    );
    const after = try tmp.dir.readFileAlloc(
        std.testing.io,
        "member-a",
        std.testing.allocator,
        .limited(8 * 1024 * 1024 + 1),
    );
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "format classifier uses both slots and rejects conflicts" {
    var blob: [header_size]u8 = @splat(0);
    @memcpy(blob[0..8], "ZTBLOB01");
    var littlefs: [header_size]u8 = @splat(0);
    @memcpy(littlefs[0..8], "LFSDRV2\x00");
    var pool: [header_size]u8 = @splat(0);
    @memcpy(pool[0..8], "DDVMEM3\x00");
    const empty: [header_size]u8 = @splat(0);

    try std.testing.expectEqual(FormatKind.blob, try classifyHeaderSlots(&blob, &empty));
    try std.testing.expectEqual(FormatKind.blob, try classifyHeaderSlots(&empty, &blob));
    try std.testing.expectEqual(FormatKind.littlefs_container, try classifyHeaderSlots(&littlefs, &littlefs));
    try std.testing.expectEqual(FormatKind.pool_member, try classifyHeaderSlots(&pool, &empty));
    try std.testing.expectError(error.ConflictingTargetFormats, classifyHeaderSlots(&blob, &littlefs));
    try std.testing.expectError(error.ConflictingTargetFormats, classifyHeaderSlots(&pool, &blob));
}

test "new blob file reopens and preserves format options" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "blob-image" });
    defer std.testing.allocator.free(path);

    try formatNewBlobFile(
        std.testing.io,
        std.testing.allocator,
        path,
        8 * blob_format.blob_size,
        .portable_v1,
        .{ .root_uid = 123, .root_gid = 456 },
    );
    try std.testing.expectEqual(FormatKind.blob, try classifyPath(std.testing.io, path));
    var filesystem = try openBlobFilesystem(std.testing.allocator, std.testing.io, path, false);
    defer filesystem.close(std.testing.io) catch {};
    try std.testing.expectEqual(name_profile.Profile.portable_v1, filesystem.root.name_profile);
    const root = try filesystem.stat(std.testing.io, 1);
    try std.testing.expectEqual(@as(u32, 123), root.metadata.uid);
    try std.testing.expectEqual(@as(u32, 456), root.metadata.gid);

    try tmp.dir.symLink(std.testing.io, "blob-image", "blob-link", .{});
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ directory, "blob-link" });
    defer std.testing.allocator.free(link_path);
    try std.testing.expectEqual(FormatKind.blob, try classifyPath(std.testing.io, link_path));
    var linked = try openBlobFilesystem(std.testing.allocator, std.testing.io, link_path, false);
    defer linked.close(std.testing.io) catch {};
    try std.testing.expectEqual(name_profile.Profile.portable_v1, linked.root.name_profile);
}

test "regular storage helper rejects wrong file kinds" {
    try std.testing.expectError(error.BlobRequiresRegularFile, requireRegularKind(.directory));
}

test "unsupported blob headers reject all opens without disk changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 8 * blob_format.blob_size;
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "future-header" });
    defer std.testing.allocator.free(path);
    try formatNewBlobFile(
        std.testing.io,
        std.testing.allocator,
        path,
        device_size,
        .legacy_raw,
        .{},
    );

    var filesystem = try openBlobFilesystem(std.testing.allocator, std.testing.io, path, true);
    _ = try filesystem.createFile(std.testing.io, blob_filesystem_format.root_inode, "new", 0o644, 0, 0);
    const selected_header = filesystem.blobs.selected_header;
    for (filesystem.blobs.authorityCandidates()) |candidate| {
        try std.testing.expect(candidate != null and candidate.?.authority_root != null);
    }
    try filesystem.close(std.testing.io);

    const file = try tmp.dir.openFile(std.testing.io, "future-header", .{ .mode = .read_write });
    const offset = if (selected_header == 0) blob_format.header_a_offset else blob_format.header_b_offset;
    var bytes: [blob_format.header_size]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try file.readPositionalAll(std.testing.io, &bytes, offset));
    std.mem.writeInt(u16, bytes[8..10], 0xffff, .little);
    const checksum_offset = blob_format.header_size - @sizeOf(u32);
    std.mem.writeInt(u32, bytes[checksum_offset..], google_crc32c.value(bytes[0..checksum_offset]), .little);
    try file.writePositionalAll(std.testing.io, &bytes, offset);
    try file.sync(std.testing.io);
    file.close(std.testing.io);

    const before = try tmp.dir.readFileAlloc(
        std.testing.io,
        "future-header",
        std.testing.allocator,
        .limited(device_size + 1),
    );
    defer std.testing.allocator.free(before);
    try expectBlobOpenError(path, false, error.UnsupportedBlobStoreVersion);
    try expectBlobOpenError(path, true, error.UnsupportedBlobStoreVersion);
    const after = try tmp.dir.readFileAlloc(
        std.testing.io,
        "future-header",
        std.testing.allocator,
        .limited(device_size + 1),
    );
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}

test "unsupported blob filesystem authorities never fall back or change disk" {
    const Mutation = enum { version, name_profile };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 8 * blob_format.blob_size;
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);

    for ([_]Mutation{ .version, .name_profile }) |mutation| {
        const basename = switch (mutation) {
            .version => "future-root",
            .name_profile => "future-name-profile",
        };
        const path = try std.fs.path.join(std.testing.allocator, &.{ directory, basename });
        defer std.testing.allocator.free(path);
        try formatNewBlobFile(
            std.testing.io,
            std.testing.allocator,
            path,
            device_size,
            .legacy_raw,
            .{},
        );

        var filesystem = try openBlobFilesystem(std.testing.allocator, std.testing.io, path, true);
        var root_bytes = try blob_filesystem_format.encodeRoot(filesystem.root);
        switch (mutation) {
            .version => std.mem.writeInt(u16, root_bytes[8..10], 0xffff, .little),
            .name_profile => std.mem.writeInt(u16, root_bytes[58..60], 0xffff, .little),
        }
        const checksum_offset = blob_filesystem_format.root_encoded_size - @sizeOf(u32);
        std.mem.writeInt(
            u32,
            root_bytes[checksum_offset..],
            google_crc32c.value(root_bytes[0..checksum_offset]),
            .little,
        );
        const unsupported_root = try filesystem.blobs.put(std.testing.io, &root_bytes);
        try filesystem.blobs.commitAuthority(std.testing.io, unsupported_root);
        for (filesystem.blobs.authorityCandidates()) |candidate| {
            try std.testing.expect(candidate != null and candidate.?.authority_root != null);
        }
        try filesystem.close(std.testing.io);

        const before = try tmp.dir.readFileAlloc(
            std.testing.io,
            basename,
            std.testing.allocator,
            .limited(device_size + 1),
        );
        defer std.testing.allocator.free(before);
        const expected = switch (mutation) {
            .version => error.UnsupportedBlobFilesystemVersion,
            .name_profile => error.UnsupportedNameProfile,
        };
        try expectBlobOpenError(path, false, expected);
        try expectBlobOpenError(path, true, expected);
        const after = try tmp.dir.readFileAlloc(
            std.testing.io,
            basename,
            std.testing.allocator,
            .limited(device_size + 1),
        );
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
    }
}

fn expectBlobOpenError(path: []const u8, writable: bool, expected: anyerror) !void {
    var filesystem = openBlobFilesystem(std.testing.allocator, std.testing.io, path, writable) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer filesystem.close(std.testing.io) catch {};
    return error.TestExpectedError;
}

test "blob format rejects invalid geometry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "bad-geometry" });
    defer std.testing.allocator.free(path);
    try std.testing.expectError(
        error.InvalidBlobStoreSize,
        formatNewBlobFile(
            std.testing.io,
            std.testing.allocator,
            path,
            blob_format.minimum_device_size + 1,
            .legacy_raw,
            .{},
        ),
    );
}
