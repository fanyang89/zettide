const std = @import("std");
const blob_device = @import("blob_device.zig");
const blob_filesystem = @import("blob_filesystem.zig");
const blob_filesystem_format = @import("blob_filesystem_format.zig");
const blob_format = @import("blob_format.zig");
const blob_store = @import("blob_store.zig");
const container = @import("container.zig");
const google_crc32c = @import("crc32c");
const member_format = @import("v3/member_format.zig");
const name_profile = @import("name_profile.zig");
const storage_api = @import("v3/storage.zig");
const target = @import("target.zig");

const Io = std.Io;

pub const FormatKind = enum {
    unknown,
    littlefs_container,
    pool_member,
    blob,
};

pub const BlobFormatPlan = struct {
    target_plan: target.FormatPlan,
    format_options: blob_filesystem.Filesystem.FormatOptions,
    eligible: bool,
    token: [32]u8,

    pub fn tokenText(self: *const BlobFormatPlan, buffer: *[64]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{x}", .{self.token}) catch unreachable;
    }
};

pub const AcquiredBlobFormat = struct {
    target_format: target.AcquiredFormat,
    plan: BlobFormatPlan,

    pub fn deinit(self: *AcquiredBlobFormat) void {
        self.target_format.deinit();
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

        const capacity = self.target_format.storage.capacity();
        const device = try blob_device.Device.init(
            self.target_format.storage,
            0,
            capacity,
            blob_format.allocation_unit,
        );
        self.target_format.storage_owned = false;
        const blobs = try blob_store.Store.create(allocator, self.target_format.io, device);
        var filesystem = try blob_filesystem.Filesystem.formatOptions(
            allocator,
            self.target_format.io,
            blobs,
            profile,
            options,
        );
        try filesystem.close(self.target_format.io);
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
    var first: [container.header_size]u8 = undefined;
    var second: [container.header_size]u8 = undefined;
    const first_len = try storage.readAt(io, &first, container.header_a_offset);
    const second_len = try storage.readAt(io, &second, container.header_b_offset);
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
    return blobPlan(
        try target.inspectFormatOptions(io, allocator, path, "Zettide", .{
            .name_profile = profile,
        }),
        options,
    );
}

pub fn acquireBlobFormat(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    profile: name_profile.Profile,
    options: blob_filesystem.Filesystem.FormatOptions,
) !AcquiredBlobFormat {
    try requireRegularFile(io, path);
    var acquired = try target.acquireFormatOptions(io, allocator, path, "Zettide", .{
        .name_profile = profile,
    });
    errdefer acquired.deinit();
    if (acquired.plan.kind != .regular_file) return error.BlobRequiresRegularFile;
    return .{ .plan = blobPlan(acquired.plan, options), .target_format = acquired };
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

fn blobPlan(
    target_plan: target.FormatPlan,
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
        .eligible = target_plan.kind == .regular_file and validBlobSize(target_plan.capacity_bytes),
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

fn requireRegularKind(kind: Io.File.Kind) !void {
    if (kind != .file) return error.BlobRequiresRegularFile;
}

fn headerKind(bytes: []const u8) FormatKind {
    if (blob_format.hasHeaderMagic(bytes)) return .blob;
    if (container.hasHeaderMagic(bytes)) return .littlefs_container;
    if (member_format.hasHeaderMagic(bytes)) return .pool_member;
    return .unknown;
}

test "format classifier uses both slots and rejects conflicts" {
    var blob = [_]u8{0} ** container.header_size;
    @memcpy(blob[0..8], "ZTBLOB01");
    var littlefs = [_]u8{0} ** container.header_size;
    @memcpy(littlefs[0..8], "LFSDRV2\x00");
    var pool = [_]u8{0} ** container.header_size;
    @memcpy(pool[0..8], "DDVMEM3\x00");
    const empty = [_]u8{0} ** container.header_size;

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
