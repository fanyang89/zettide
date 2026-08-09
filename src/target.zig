const std = @import("std");
const builtin = @import("builtin");
const volume_api = @import("volume.zig");
const container = @import("container.zig");
const pool_member_set = @import("v3/pool_member_set.zig");
const pool_provision = @import("v3/pool_provision.zig");
const storage_api = @import("v3/storage.zig");
const name_profile = @import("name_profile.zig");
const volume_crypto = @import("volume_crypto.zig");
const linux_block = if (builtin.os.tag == .linux) @import("v3/linux_block_device.zig") else struct {};

const Io = std.Io;
const member_alignment: u64 = 1024 * 1024;

pub const Kind = enum {
    regular_file,
    block_device,
};

const RegularIdentity = struct {
    inode: u64,
    mtime_ns: i96,
    ctime_ns: i96,
};

const BlockIdentity = struct {
    major: u32,
    minor: u32,
    disk_sequence: u64,
    capacity_bytes: u64,
    logical_sector_size: u32,
};

pub const FormatPlan = struct {
    path: []const u8,
    label: []const u8,
    name_profile: name_profile.Profile,
    encryption_kdf: ?volume_crypto.Kdf,
    canonical_path_digest: [32]u8,
    kind: Kind,
    capacity_bytes: u64,
    minimum_io_size: u32,
    contains_data: bool,
    data_digest: [32]u8,
    eligible: bool,
    token: [32]u8,
    identity: union(Kind) {
        regular_file: RegularIdentity,
        block_device: BlockIdentity,
    },

    pub fn tokenText(self: *const FormatPlan, buffer: *[64]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{x}", .{self.token}) catch unreachable;
    }
};

pub const FormatOptions = struct {
    name_profile: name_profile.Profile = .legacy_raw,
    encryption_credential: ?volume_crypto.Credential = null,
};

pub const AcquiredFormat = struct {
    plan: FormatPlan,
    storage: storage_api.Storage,
    io: Io,
    storage_owned: bool = true,

    pub fn deinit(self: *AcquiredFormat) void {
        if (self.storage_owned) self.storage.close(self.io) catch {};
        self.storage_owned = false;
    }

    pub fn apply(
        self: *AcquiredFormat,
        allocator: std.mem.Allocator,
        confirmation: []const u8,
        options: FormatOptions,
    ) !FormatResult {
        if (self.plan.name_profile != options.name_profile or
            self.plan.encryption_kdf != credentialKdf(options.encryption_credential))
            return error.FormatPlanChanged;
        if (!std.mem.eql(u8, &self.plan.token, &computeToken(&self.plan)))
            return error.FormatPlanChanged;
        var token_buffer: [64]u8 = undefined;
        if (!std.mem.eql(u8, confirmation, self.plan.tokenText(&token_buffer)))
            return error.ConfirmationMismatch;
        if (!self.plan.eligible) return error.TargetNotEligible;
        self.storage_owned = false;
        return provision(self.io, allocator, &self.storage, self.plan.label, options);
    }
};

pub const OpenOptions = volume_api.Volume.OpenOptions;

pub const FormatResult = union(enum) {
    complete,
    pool_created: struct {
        set_id: [16]u8,
        cause: anyerror,
    },
    partial: struct {
        set_id: [16]u8,
        completed_member_count: u16,
        failed_member_index: u16,
        cause: anyerror,
    },
};

pub fn inspectFormat(io: Io, allocator: std.mem.Allocator, path: []const u8, label: []const u8) !FormatPlan {
    return inspectFormatOptions(io, allocator, path, label, .{});
}

pub fn inspectFormatOptions(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    options: FormatOptions,
) !FormatPlan {
    _ = try @import("v3/member_format.zig").Label.init(label);
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    return switch (stat.kind) {
        .file => inspectRegularFormat(io, allocator, path, label, options),
        .block_device => if (comptime builtin.os.tag == .linux)
            if (options.encryption_credential != null)
                error.EncryptedBlockDeviceNotSupported
            else
                inspectBlockFormat(io, allocator, path, label, options)
        else
            error.BlockDeviceNotImplemented,
        else => error.UnsupportedTargetType,
    };
}

pub fn acquireFormatOptions(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    options: FormatOptions,
) !AcquiredFormat {
    _ = try @import("v3/member_format.zig").Label.init(label);
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    return switch (stat.kind) {
        .file => acquireRegularFormat(io, allocator, path, label, options),
        .block_device => if (comptime builtin.os.tag == .linux)
            if (options.encryption_credential != null)
                error.EncryptedBlockDeviceNotSupported
            else
                acquireBlockFormat(io, allocator, path, label, options)
        else
            error.BlockDeviceNotImplemented,
        else => error.UnsupportedTargetType,
    };
}

pub fn formatNewFile(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    size: u64,
    label: []const u8,
) !FormatResult {
    return formatNewFileOptions(io, allocator, path, size, label, .{});
}

pub fn formatNewFileOptions(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    size: u64,
    label: []const u8,
    options: FormatOptions,
) !FormatResult {
    if (size < 3 * member_alignment or size % member_alignment != 0) return error.InvalidTargetSize;
    _ = try @import("v3/member_format.zig").Label.init(label);
    var storage = try storage_api.Storage.createFile(io, Io.Dir.cwd(), path, size);
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};
    var storage_owned = true;
    defer if (storage_owned) storage.close(io) catch {};
    storage_owned = false;
    return provision(io, allocator, &storage, label, options);
}

pub fn applyFormat(
    io: Io,
    allocator: std.mem.Allocator,
    plan: *const FormatPlan,
    confirmation: []const u8,
) !FormatResult {
    return applyFormatOptions(io, allocator, plan, confirmation, .{});
}

pub fn applyFormatOptions(
    io: Io,
    allocator: std.mem.Allocator,
    plan: *const FormatPlan,
    confirmation: []const u8,
    options: FormatOptions,
) !FormatResult {
    if (plan.name_profile != options.name_profile or
        plan.encryption_kdf != credentialKdf(options.encryption_credential))
        return error.FormatPlanChanged;
    if (!std.mem.eql(u8, &plan.token, &computeToken(plan))) return error.FormatPlanChanged;
    if (!try pathMatchesPlan(io, plan)) return error.TargetChanged;
    var token_buffer: [64]u8 = undefined;
    if (!std.mem.eql(u8, confirmation, plan.tokenText(&token_buffer)))
        return error.ConfirmationMismatch;
    if (!plan.eligible) return error.TargetNotEligible;

    switch (plan.kind) {
        .regular_file => {
            const file = try Io.Dir.cwd().openFile(io, plan.path, .{
                .mode = .read_write,
                .lock = .exclusive,
                .lock_nonblocking = true,
            });
            var file_owned = true;
            errdefer if (file_owned) file.close(io);
            const stat = try file.stat(io);
            const capacity = try file.length(io);
            const identity = plan.identity.regular_file;
            if (stat.kind != .file or inodeValue(stat.inode) != identity.inode or
                stat.mtime.nanoseconds != identity.mtime_ns or stat.ctime.nanoseconds != identity.ctime_ns or
                capacity != plan.capacity_bytes) return error.TargetChanged;
            var storage = storage_api.Storage.initOwned(file, capacity, .regular_file, 1, true);
            file_owned = false;
            var storage_owned = true;
            defer if (storage_owned) storage.close(io) catch {};
            const scan = try scanStorage(&storage, io, allocator);
            if (!std.mem.eql(u8, &scan.digest, &plan.data_digest)) return error.TargetChanged;
            storage_owned = false;
            return provision(io, allocator, &storage, plan.label, options);
        },
        .block_device => {
            if (options.encryption_credential != null) return error.EncryptedBlockDeviceNotSupported;
            if (comptime builtin.os.tag != .linux) return error.BlockDeviceNotImplemented;
            var opened = try linux_block.openStorage(io, allocator, plan.path, true);
            var storage_owned = true;
            defer if (storage_owned) opened.storage.close(io) catch {};
            const expected = plan.identity.block_device;
            if (expected.major != opened.info.id.major or expected.minor != opened.info.id.minor or
                expected.disk_sequence != opened.info.disk_sequence or
                expected.capacity_bytes != opened.info.capacity_bytes or
                expected.logical_sector_size != opened.info.logical_sector_size)
            {
                return error.TargetChanged;
            }
            const scan = try scanStorage(&opened.storage, io, allocator);
            if (!std.mem.eql(u8, &scan.digest, &plan.data_digest)) return error.TargetChanged;
            storage_owned = false;
            return provision(io, allocator, &opened.storage, plan.label, .{ .name_profile = plan.name_profile });
        },
    }
}

pub fn openVolumeInto(
    result: *volume_api.Volume,
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    writable: bool,
) !void {
    return openVolumeIntoOptions(result, io, allocator, path, writable, .{});
}

pub fn inspectVolumeHeader(io: Io, allocator: std.mem.Allocator, path: []const u8) !container.Header {
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    return switch (stat.kind) {
        .file => inspectRegularVolumeHeader(io, allocator, path),
        .block_device => if (comptime builtin.os.tag == .linux)
            inspectBlockVolumeHeader(io, allocator, path)
        else
            error.BlockDeviceNotImplemented,
        else => error.UnsupportedTargetType,
    };
}

fn inspectRegularVolumeHeader(io: Io, allocator: std.mem.Allocator, path: []const u8) !container.Header {
    const file = try Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .lock = .shared,
        .lock_nonblocking = true,
    });
    if (container.read(file, io)) |header| {
        file.close(io);
        return header;
    } else |err| switch (err) {
        error.NoValidHeader => file.close(io),
        else => {
            file.close(io);
            return err;
        },
    }

    var storage = try storage_api.Storage.openFile(io, Io.Dir.cwd(), path, false);
    var storage_owned = true;
    defer if (storage_owned) storage.close(io) catch {};
    var storages = [_]storage_api.Storage{storage};
    storage_owned = false;
    var set = try pool_member_set.PoolMemberSet.openStorages(
        io,
        allocator,
        &storages,
        .read_only,
    );
    defer set.deinit();
    return volume_api.Volume.inspectPoolHeader(io, &set);
}

fn inspectBlockVolumeHeader(io: Io, allocator: std.mem.Allocator, path: []const u8) !container.Header {
    var opened = try linux_block.openStorageOptions(io, allocator, path, false, true);
    var storage_owned = true;
    defer if (storage_owned) opened.storage.close(io) catch {};
    var storages = [_]storage_api.Storage{opened.storage};
    storage_owned = false;
    var set = try pool_member_set.PoolMemberSet.openStorages(io, allocator, &storages, .read_only);
    defer set.deinit();
    return volume_api.Volume.inspectPoolHeader(io, &set);
}

pub fn openVolumeIntoOptions(
    result: *volume_api.Volume,
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    writable: bool,
    options: OpenOptions,
) !void {
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    switch (stat.kind) {
        .file => try openRegularVolumeInto(result, io, allocator, path, writable, options),
        .block_device => if (comptime builtin.os.tag == .linux)
            if (options.encryption_credential != null)
                return error.EncryptedBlockDeviceNotSupported
            else
                try openBlockVolumeInto(result, io, allocator, path, writable)
        else
            return error.BlockDeviceNotImplemented,
        else => return error.UnsupportedTargetType,
    }
}

fn openRegularVolumeInto(
    result: *volume_api.Volume,
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    writable: bool,
    options: OpenOptions,
) !void {
    if (volume_api.Volume.openIntoOptions(result, io, path, writable, options)) |_| return else |err| switch (err) {
        error.NoValidHeader => {},
        else => return err,
    }
    var storage = try storage_api.Storage.openFile(io, Io.Dir.cwd(), path, writable);
    var storage_owned = true;
    defer if (storage_owned) storage.close(io) catch {};
    var storages = [_]storage_api.Storage{storage};
    const set = try allocator.create(pool_member_set.PoolMemberSet);
    defer allocator.destroy(set);
    storage_owned = false;
    try pool_member_set.PoolMemberSet.openStoragesInto(
        set,
        io,
        allocator,
        &storages,
        if (writable) .writable else .read_only,
    );
    return volume_api.Volume.openPoolIntoOptions(result, io, allocator, set, writable, options);
}

fn openBlockVolumeInto(
    result: *volume_api.Volume,
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    writable: bool,
) !void {
    var opened = try linux_block.openStorageOptions(io, allocator, path, writable, true);
    var storage_owned = true;
    defer if (storage_owned) opened.storage.close(io) catch {};
    var storages = [_]storage_api.Storage{opened.storage};
    const set = try allocator.create(pool_member_set.PoolMemberSet);
    defer allocator.destroy(set);
    storage_owned = false;
    try pool_member_set.PoolMemberSet.openStoragesInto(
        set,
        io,
        allocator,
        &storages,
        if (writable) .writable else .read_only,
    );
    return volume_api.Volume.openPoolInto(result, io, allocator, set, writable);
}

fn inspectRegularFormat(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    options: FormatOptions,
) !FormatPlan {
    const file = try Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .lock = .shared,
        .lock_nonblocking = true,
    });
    var file_owned = true;
    errdefer if (file_owned) file.close(io);
    const capacity = try file.length(io);
    var storage = storage_api.Storage.initOwned(file, capacity, .regular_file, 1, true);
    file_owned = false;
    defer storage.close(io) catch {};
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsupportedTargetType;
    const scan = try scanStorage(&storage, io, allocator);
    var plan: FormatPlan = .{
        .path = path,
        .label = label,
        .name_profile = options.name_profile,
        .encryption_kdf = credentialKdf(options.encryption_credential),
        .canonical_path_digest = try canonicalPathDigest(io, path),
        .kind = .regular_file,
        .capacity_bytes = capacity,
        .minimum_io_size = 1,
        .contains_data = scan.contains_data,
        .data_digest = scan.digest,
        .eligible = capacity >= 3 * member_alignment and capacity % member_alignment == 0,
        .token = undefined,
        .identity = .{ .regular_file = .{
            .inode = inodeValue(stat.inode),
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
        } },
    };
    plan.token = computeToken(&plan);
    return plan;
}

fn inspectBlockFormat(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    options: FormatOptions,
) !FormatPlan {
    var opened = try linux_block.openStorage(io, allocator, path, false);
    defer opened.storage.close(io) catch {};
    const info = opened.info;
    const scan = try scanStorage(&opened.storage, io, allocator);
    var plan: FormatPlan = .{
        .path = path,
        .label = label,
        .name_profile = options.name_profile,
        .encryption_kdf = credentialKdf(options.encryption_credential),
        .canonical_path_digest = try canonicalPathDigest(io, path),
        .kind = .block_device,
        .capacity_bytes = info.capacity_bytes,
        .minimum_io_size = info.logical_sector_size,
        .contains_data = scan.contains_data,
        .data_digest = scan.digest,
        .eligible = info.preflightEligible() and
            std.math.isPowerOfTwo(info.logical_sector_size) and
            info.logical_sector_size <= 4096 and
            4096 % info.logical_sector_size == 0 and
            info.capacity_bytes >= 3 * member_alignment,
        .token = undefined,
        .identity = .{ .block_device = .{
            .major = info.id.major,
            .minor = info.id.minor,
            .disk_sequence = info.disk_sequence,
            .capacity_bytes = info.capacity_bytes,
            .logical_sector_size = info.logical_sector_size,
        } },
    };
    plan.token = computeToken(&plan);
    return plan;
}

fn acquireRegularFormat(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    options: FormatOptions,
) !AcquiredFormat {
    const file = try Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    var file_owned = true;
    errdefer if (file_owned) file.close(io);
    const capacity = try file.length(io);
    var storage = storage_api.Storage.initOwned(file, capacity, .regular_file, 1, true);
    file_owned = false;
    errdefer storage.close(io) catch {};
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsupportedTargetType;
    const scan = try scanStorage(&storage, io, allocator);
    var plan: FormatPlan = .{
        .path = path,
        .label = label,
        .name_profile = options.name_profile,
        .encryption_kdf = credentialKdf(options.encryption_credential),
        .canonical_path_digest = try canonicalPathDigest(io, path),
        .kind = .regular_file,
        .capacity_bytes = capacity,
        .minimum_io_size = 1,
        .contains_data = scan.contains_data,
        .data_digest = scan.digest,
        .eligible = capacity >= 3 * member_alignment and capacity % member_alignment == 0,
        .token = undefined,
        .identity = .{ .regular_file = .{
            .inode = inodeValue(stat.inode),
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
        } },
    };
    plan.token = computeToken(&plan);
    return .{ .plan = plan, .storage = storage, .io = io };
}

fn acquireBlockFormat(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    options: FormatOptions,
) !AcquiredFormat {
    var opened = try linux_block.openStorage(io, allocator, path, true);
    errdefer opened.storage.close(io) catch {};
    const info = opened.info;
    const scan = try scanStorage(&opened.storage, io, allocator);
    var plan: FormatPlan = .{
        .path = path,
        .label = label,
        .name_profile = options.name_profile,
        .encryption_kdf = credentialKdf(options.encryption_credential),
        .canonical_path_digest = try canonicalPathDigest(io, path),
        .kind = .block_device,
        .capacity_bytes = info.capacity_bytes,
        .minimum_io_size = info.logical_sector_size,
        .contains_data = scan.contains_data,
        .data_digest = scan.digest,
        .eligible = info.preflightEligible() and
            std.math.isPowerOfTwo(info.logical_sector_size) and
            info.logical_sector_size <= 4096 and
            4096 % info.logical_sector_size == 0 and
            info.capacity_bytes >= 3 * member_alignment,
        .token = undefined,
        .identity = .{ .block_device = .{
            .major = info.id.major,
            .minor = info.id.minor,
            .disk_sequence = info.disk_sequence,
            .capacity_bytes = info.capacity_bytes,
            .logical_sector_size = info.logical_sector_size,
        } },
    };
    plan.token = computeToken(&plan);
    return .{ .plan = plan, .storage = opened.storage, .io = io };
}

fn provision(
    io: Io,
    allocator: std.mem.Allocator,
    storage: *storage_api.Storage,
    label: []const u8,
    options: FormatOptions,
) !FormatResult {
    var storages = [_]storage_api.Storage{storage.*};
    const outcome = try pool_provision.create(io, allocator, &storages, .{
        .protection = .unprotected,
        .data_mode = .catalog,
        .label = label,
    });
    switch (outcome) {
        .complete => |value| {
            var provisioned = value;
            defer provisioned.deinit();
            const set_id = provisioned.genesis.topology.set_id;
            volume_api.Volume.initializePoolOptions(io, &provisioned, label, .{
                .name_profile = options.name_profile,
                .encryption_credential = options.encryption_credential,
            }) catch |cause| {
                return .{ .pool_created = .{ .set_id = set_id, .cause = cause } };
            };
            return .complete;
        },
        .partial => |partial| return .{ .partial = .{
            .set_id = partial.set_id,
            .completed_member_count = partial.completed_member_count,
            .failed_member_index = partial.failed_member_index,
            .cause = partial.cause,
        } },
    }
}

const StorageScan = struct {
    contains_data: bool,
    digest: [32]u8,
};

fn scanStorage(storage: *storage_api.Storage, io: Io, allocator: std.mem.Allocator) !StorageScan {
    const chunk_size = 1024 * 1024;
    const batch_depth = 8;
    const buffer = try allocator.alloc(u8, chunk_size * batch_depth);
    defer allocator.free(buffer);
    var hasher = std.crypto.hash.Blake3.init(.{});
    var contains_data = false;
    var offset: u64 = 0;
    while (offset < storage.capacity()) {
        var reads: [batch_depth]storage_api.Read = undefined;
        var results: [batch_depth]storage_api.ReadResult = undefined;
        var count: usize = 0;
        var batch_offset = offset;
        while (count < batch_depth and batch_offset < storage.capacity()) : (count += 1) {
            const amount: usize = @intCast(@min(@as(u64, chunk_size), storage.capacity() - batch_offset));
            reads[count] = .{ .buffer = buffer[count * chunk_size ..][0..amount], .offset = batch_offset };
            batch_offset += amount;
        }
        try storage.readManyAt(io, reads[0..count], results[0..count]);
        for (reads[0..count], results[0..count]) |read, result| {
            if (result.failure) |err| return err;
            if (result.amount != read.buffer.len) return error.TruncatedTarget;
            hasher.update(read.buffer);
            contains_data = contains_data or !std.mem.allEqual(u8, read.buffer, 0);
        }
        offset = batch_offset;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .contains_data = contains_data, .digest = digest };
}

fn computeToken(plan: *const FormatPlan) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("zettide-format-plan-v1\x00");
    hasher.update(&plan.canonical_path_digest);
    hashSlice(&hasher, plan.label);
    var values: [25]u8 = @splat(0);
    values[0] = @intFromEnum(plan.kind);
    std.mem.writeInt(u64, values[1..9], plan.capacity_bytes, .little);
    std.mem.writeInt(u32, values[9..13], plan.minimum_io_size, .little);
    values[13] = @intFromBool(plan.contains_data);
    values[14] = @intFromBool(plan.eligible);
    switch (plan.kind) {
        .regular_file => std.mem.writeInt(u64, values[15..23], plan.identity.regular_file.inode, .little),
        .block_device => if (comptime builtin.os.tag == .linux) {
            const identity = plan.identity.block_device;
            std.mem.writeInt(u32, values[15..19], identity.major, .little);
            std.mem.writeInt(u32, values[19..23], identity.minor, .little);
        },
    }
    hasher.update(&values);
    hasher.update(&plan.data_digest);
    if (plan.name_profile != .legacy_raw) {
        hasher.update("zettide-name-profile\x00");
        hashSlice(&hasher, plan.name_profile.name());
    }
    if (plan.encryption_kdf) |kdf| {
        hasher.update("zettide-encryption-kdf\x00");
        var encoded: [2]u8 = undefined;
        std.mem.writeInt(u16, &encoded, @intFromEnum(kdf), .little);
        hasher.update(&encoded);
    }
    if (plan.kind == .regular_file) {
        var timestamps: [24]u8 = undefined;
        std.mem.writeInt(i96, timestamps[0..12], plan.identity.regular_file.mtime_ns, .little);
        std.mem.writeInt(i96, timestamps[12..24], plan.identity.regular_file.ctime_ns, .little);
        hasher.update(&timestamps);
    }
    if (plan.kind == .block_device and comptime builtin.os.tag == .linux) {
        var sequence: [8]u8 = undefined;
        std.mem.writeInt(u64, &sequence, plan.identity.block_device.disk_sequence, .little);
        hasher.update(&sequence);
    }
    var token: [32]u8 = undefined;
    hasher.final(&token);
    return token;
}

fn pathMatchesPlan(io: Io, plan: *const FormatPlan) !bool {
    const current = try canonicalPathDigest(io, plan.path);
    return std.mem.eql(u8, &current, &plan.canonical_path_digest);
}

fn canonicalPathDigest(io: Io, path: []const u8) ![32]u8 {
    var canonical: [Io.Dir.max_path_bytes]u8 = undefined;
    const length = try Io.Dir.cwd().realPathFile(io, path, &canonical);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(canonical[0..length], &digest, .{});
    return digest;
}

fn hashSlice(hasher: *std.crypto.hash.Blake3, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    hasher.update(&length);
    hasher.update(bytes);
}

fn inodeValue(inode: anytype) u64 {
    return @bitCast(inode);
}

fn credentialKdf(credential: ?volume_crypto.Credential) ?volume_crypto.Kdf {
    return if (credential) |value| value.kind() else null;
}

test "new regular target formats and reopens as a volume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "image" });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(
        FormatResult.complete,
        try formatNewFile(std.testing.io, std.testing.allocator, path, 8 * member_alignment, "Target Test"),
    );
    const volume = try std.testing.allocator.create(volume_api.Volume);
    defer std.testing.allocator.destroy(volume);
    try openVolumeInto(volume, std.testing.io, std.testing.allocator, path, true);
    defer volume.deinit();
    try volume.mount();
    try std.testing.expectEqualStrings("Target Test", volume.header.labelSlice());
    try volume.close();
}

test "acquired regular target reproduces inspection token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "existing" });
    defer std.testing.allocator.free(path);
    const file = try Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true });
    try file.setLength(std.testing.io, 8 * member_alignment);
    file.close(std.testing.io);

    const inspected = try inspectFormat(std.testing.io, std.testing.allocator, path, "Existing");
    var acquired = try acquireFormatOptions(std.testing.io, std.testing.allocator, path, "Existing", .{});
    defer acquired.deinit();
    try std.testing.expectEqualSlices(u8, &inspected.token, &acquired.plan.token);
    try std.testing.expectEqualDeep(inspected.identity, acquired.plan.identity);
    try std.testing.expectError(
        error.ConfirmationMismatch,
        acquired.apply(std.testing.allocator, "invalid", .{}),
    );
}

test "encrypted regular target hides and reopens filesystem data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "encrypted-image" });
    defer std.testing.allocator.free(path);
    const key: [volume_crypto.master_key_length]u8 = @splat(0x3c);
    const credential: volume_crypto.Credential = .{ .raw_key = &key };
    try std.testing.expectEqual(
        FormatResult.complete,
        try formatNewFileOptions(std.testing.io, std.testing.allocator, path, 8 * member_alignment, "Encrypted", .{
            .encryption_credential = credential,
        }),
    );

    const wrong_key: [volume_crypto.master_key_length]u8 = @splat(0x4d);
    const rejected = try std.testing.allocator.create(volume_api.Volume);
    defer std.testing.allocator.destroy(rejected);
    try std.testing.expectError(
        error.InvalidEncryptionCredential,
        openVolumeIntoOptions(rejected, std.testing.io, std.testing.allocator, path, true, .{
            .encryption_credential = .{ .raw_key = &wrong_key },
        }),
    );

    const secret_path = "/hidden-filename";
    const secret_payload = "hidden payload bytes";
    {
        const volume = try std.testing.allocator.create(volume_api.Volume);
        defer std.testing.allocator.destroy(volume);
        try openVolumeIntoOptions(volume, std.testing.io, std.testing.allocator, path, true, .{
            .encryption_credential = credential,
        });
        defer volume.deinit();
        try volume.mount();
        var file: volume_api.FileHandle = undefined;
        try volume.openFile(&file, secret_path, volume_api.c.LFS_O_CREAT | volume_api.c.LFS_O_RDWR, 0o100600, 1, 1);
        try std.testing.expectEqual(secret_payload.len, try volume.writeFile(&file, secret_payload, 0));
        try volume.closeFile(&file);
        try volume.close();
    }
    {
        const volume = try std.testing.allocator.create(volume_api.Volume);
        defer std.testing.allocator.destroy(volume);
        try openVolumeIntoOptions(volume, std.testing.io, std.testing.allocator, path, false, .{
            .encryption_credential = credential,
        });
        defer volume.deinit();
        try volume.mount();
        var file: volume_api.FileHandle = undefined;
        try volume.openFile(&file, secret_path, volume_api.c.LFS_O_RDONLY, 0, 0, 0);
        var actual: [secret_payload.len]u8 = undefined;
        try std.testing.expectEqual(actual.len, try volume.readFile(&file, &actual, 0));
        try std.testing.expectEqualStrings(secret_payload, &actual);
        try volume.closeFile(&file);
        try volume.close();
    }

    const raw = try Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_only });
    defer raw.close(std.testing.io);
    const buffer = try std.testing.allocator.alloc(u8, 1024 * 1024 + 256);
    defer std.testing.allocator.free(buffer);
    const length = try raw.length(std.testing.io);
    var offset: u64 = 0;
    while (offset < length) : (offset += 1024 * 1024) {
        const amount: usize = @intCast(@min(@as(u64, buffer.len), length - offset));
        try std.testing.expectEqual(amount, try raw.readPositionalAll(std.testing.io, buffer[0..amount], offset));
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..amount], secret_path[1..]) == null);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..amount], secret_payload) == null);
    }
}
