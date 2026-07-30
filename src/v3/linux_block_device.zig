const std = @import("std");
const linux_uring_storage = @import("linux_uring_storage.zig");
const storage_api = @import("storage.zig");

const Io = std.Io;
const File = Io.File;
const linux = std.os.linux;

const block_ioctl_type = 0x12;
const blk_sector_size = linux.IOCTL.IO(block_ioctl_type, 104);
const blk_capacity = linux.IOCTL.IOR(block_ioctl_type, 114, usize);
const blk_disk_sequence = linux.IOCTL.IOR(block_ioctl_type, 128, u64);

pub const DeviceId = struct {
    major: u32,
    minor: u32,

    pub fn eql(a: DeviceId, b: DeviceId) bool {
        return a.major == b.major and a.minor == b.minor;
    }
};

pub const Eligibility = packed struct {
    partition: bool = false,
    read_only: bool = false,
    mounted: bool = false,
    swap: bool = false,
    held: bool = false,

    pub fn preflightEligible(self: Eligibility) bool {
        return !self.partition and !self.read_only and !self.mounted and !self.swap and !self.held;
    }
};

pub const DeviceInfo = struct {
    id: DeviceId,
    disk_sequence: u64,
    capacity_bytes: u64,
    logical_sector_size: u32,
    sysfs_path: [Io.Dir.max_path_bytes]u8,
    sysfs_path_len: usize,
    eligibility: Eligibility,

    pub fn sysfsPath(self: *const DeviceInfo) []const u8 {
        return self.sysfs_path[0..self.sysfs_path_len];
    }

    /// Reports observable conflicts only. O_EXCL coordinates with other exclusive
    /// block-device users, but cannot prevent an uncooperative raw writer.
    pub fn preflightEligible(self: *const DeviceInfo) bool {
        return self.eligibility.preflightEligible();
    }

    pub fn preflightReadable(self: *const DeviceInfo) bool {
        const eligibility = self.eligibility;
        return !eligibility.partition and !eligibility.mounted and !eligibility.swap and !eligibility.held;
    }
};

pub const OpenedStorage = struct {
    storage: storage_api.Storage,
    info: DeviceInfo,
};

pub fn inspect(io: Io, allocator: std.mem.Allocator, path: []const u8) !DeviceInfo {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    return inspectFile(io, allocator, file);
}

pub fn openStorage(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    writable: bool,
) !OpenedStorage {
    return openStorageOptions(io, allocator, path, writable, writable);
}

pub fn openStorageOptions(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    writable: bool,
    exclusive: bool,
) !OpenedStorage {
    const inspected = try inspect(io, allocator, path);
    if ((writable and !inspected.preflightEligible()) or
        (!writable and exclusive and !inspected.preflightReadable())) return error.DeviceNotEligible;

    const path_z = try std.posix.toPosixPath(path);
    const rc = linux.open(path_z[0..].ptr, .{
        .ACCMODE = if (writable) .RDWR else .RDONLY,
        .EXCL = exclusive,
        .CLOEXEC = true,
    }, 0);
    const fd: linux.fd_t = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES, .PERM => return error.AccessDenied,
        .BUSY, .AGAIN => return error.DeviceBusy,
        .NOENT => return error.FileNotFound,
        .ROFS => return error.ReadOnlyDevice,
        else => return error.OpenDeviceFailed,
    };
    const file: File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    errdefer file.close(io);

    const opened = try inspectFile(io, allocator, file);
    if (!DeviceId.eql(inspected.id, opened.id) or
        inspected.disk_sequence != opened.disk_sequence or
        inspected.capacity_bytes != opened.capacity_bytes or
        inspected.logical_sector_size != opened.logical_sector_size)
        return error.DeviceChanged;
    if ((writable and !opened.preflightEligible()) or
        (!writable and exclusive and !opened.preflightReadable())) return error.DeviceNotEligible;

    const storage = try linux_uring_storage.initOwned(
        allocator,
        file,
        opened.capacity_bytes,
        opened.logical_sector_size,
        .{
            .major = opened.id.major,
            .minor = opened.id.minor,
            .disk_sequence = opened.disk_sequence,
        },
    );
    return .{
        .storage = storage,
        .info = opened,
    };
}

pub fn hasData(storage: *storage_api.Storage, io: Io, allocator: std.mem.Allocator) !bool {
    const buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(buffer);
    var offset: u64 = 0;
    while (offset < storage.capacity()) {
        const amount: usize = @intCast(@min(@as(u64, buffer.len), storage.capacity() - offset));
        if (try storage.readAt(io, buffer[0..amount], offset) != amount) return error.TruncatedDevice;
        if (!std.mem.allEqual(u8, buffer[0..amount], 0)) return true;
        offset += amount;
    }
    return false;
}

pub fn pathHasData(io: Io, allocator: std.mem.Allocator, path: []const u8) !bool {
    var opened = try openStorage(io, allocator, path, false);
    defer opened.storage.close(io) catch {};
    return hasData(&opened.storage, io, allocator);
}

fn inspectFile(io: Io, allocator: std.mem.Allocator, file: File) !DeviceInfo {
    const stat = try file.stat(io);
    if (stat.kind != .block_device) return error.NotBlockDevice;
    const statx = try statxFile(file);
    const id: DeviceId = .{ .major = statx.rdev_major, .minor = statx.rdev_minor };
    const disk_sequence = try ioctlValue(file, blk_disk_sequence, u64);
    const capacity_bytes = try ioctlValue(file, blk_capacity, u64);
    const logical_sector_size = try ioctlValue(file, blk_sector_size, u32);
    if (capacity_bytes == 0 or logical_sector_size == 0 or capacity_bytes % logical_sector_size != 0)
        return error.InvalidDeviceGeometry;

    var result: DeviceInfo = .{
        .id = id,
        .disk_sequence = disk_sequence,
        .capacity_bytes = capacity_bytes,
        .logical_sector_size = logical_sector_size,
        .sysfs_path = undefined,
        .sysfs_path_len = 0,
        .eligibility = .{},
    };
    result.sysfs_path_len = try resolveSysfsDevice(io, id, &result.sysfs_path) orelse
        return error.DeviceNotInSysfs;
    const sysfs_path = result.sysfsPath();
    if (result.disk_sequence == 0) return error.InvalidDiskSequence;
    result.eligibility.partition = try childPathExists(io, sysfs_path, "partition");
    result.eligibility.read_only = try readBooleanChild(io, sysfs_path, "ro");
    result.eligibility.held = try descendantHasHolders(io, sysfs_path);
    result.eligibility.mounted = try mountedDescendant(io, allocator, sysfs_path);
    result.eligibility.swap = try swapDescendant(io, allocator, sysfs_path);
    return result;
}

fn statxFile(file: File) !linux.Statx {
    var result: linux.Statx = undefined;
    const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &result);
    return switch (linux.errno(rc)) {
        .SUCCESS => result,
        else => error.StatDeviceFailed,
    };
}

fn ioctlValue(file: File, request: u32, comptime T: type) !T {
    var value: T = 0;
    const rc = linux.ioctl(file.handle, request, @intFromPtr(&value));
    return switch (linux.errno(rc)) {
        .SUCCESS => value,
        else => error.DeviceIoctlFailed,
    };
}

fn resolveSysfsDevice(io: Io, id: DeviceId, output: []u8) !?usize {
    var link_buffer: [64]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buffer, "/sys/dev/block/{d}:{d}", .{ id.major, id.minor });
    return Io.Dir.realPathFileAbsolute(io, link, output) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn descendantHasHolders(io: Io, target: []const u8) !bool {
    const class = try Io.Dir.openDirAbsolute(io, "/sys/class/block", .{ .iterate = true });
    defer class.close(io);
    var iterator = class.iterate();
    while (try iterator.next(io)) |entry| {
        var class_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const class_path = try std.fmt.bufPrint(&class_path_buffer, "/sys/class/block/{s}", .{entry.name});
        var resolved_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const resolved_len = try Io.Dir.realPathFileAbsolute(io, class_path, &resolved_buffer);
        if (!isSameOrDescendant(target, resolved_buffer[0..resolved_len])) continue;

        var holders_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const holders_path = try std.fmt.bufPrint(&holders_path_buffer, "{s}/holders", .{class_path});
        const holders = try Io.Dir.openDirAbsolute(io, holders_path, .{ .iterate = true });
        defer holders.close(io);
        var holders_iterator = holders.iterate();
        if (try holders_iterator.next(io) != null) return true;
    }
    return false;
}

fn mountedDescendant(io: Io, allocator: std.mem.Allocator, target: []const u8) !bool {
    const contents = try readStreamingAlloc(io, allocator, "/proc/self/mountinfo", 16 * 1024 * 1024);
    defer allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const device = fields.next() orelse continue;
        if (try sysfsIdIsDescendant(io, target, device)) return true;
    }
    return false;
}

fn swapDescendant(io: Io, allocator: std.mem.Allocator, target: []const u8) !bool {
    const contents = try readStreamingAlloc(io, allocator, "/proc/swaps", 1024 * 1024);
    defer allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const path = fields.next() orelse continue;
        const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        const statx = try statxFile(file);
        const id: DeviceId = if (stat.kind == .block_device)
            .{ .major = statx.rdev_major, .minor = statx.rdev_minor }
        else
            .{ .major = statx.dev_major, .minor = statx.dev_minor };
        var resolved_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const resolved_len = try resolveSysfsDevice(io, id, &resolved_buffer) orelse continue;
        if (isSameOrDescendant(target, resolved_buffer[0..resolved_len])) return true;
    }
    return false;
}

fn sysfsIdIsDescendant(io: Io, target: []const u8, text: []const u8) !bool {
    const separator = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    const id: DeviceId = .{
        .major = std.fmt.parseInt(u32, text[0..separator], 10) catch return false,
        .minor = std.fmt.parseInt(u32, text[separator + 1 ..], 10) catch return false,
    };
    var resolved_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const resolved_len = try resolveSysfsDevice(io, id, &resolved_buffer) orelse return false;
    return isSameOrDescendant(target, resolved_buffer[0..resolved_len]);
}

fn readStreamingAlloc(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

fn readBooleanChild(io: Io, parent: []const u8, child: []const u8) !bool {
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ parent, child });
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buffer: [16]u8 = undefined;
    const amount = try file.readPositionalAll(io, &buffer, 0);
    const value = std.mem.trim(u8, buffer[0..amount], " \t\r\n");
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.mem.eql(u8, value, "1")) return true;
    return error.InvalidSysfsValue;
}

fn childPathExists(io: Io, parent: []const u8, child: []const u8) !bool {
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ parent, child });
    Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn isSameOrDescendant(parent: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, parent, candidate) or
        (candidate.len > parent.len and std.mem.startsWith(u8, candidate, parent) and
            candidate[parent.len] == '/');
}

test "eligibility requires an idle writable whole disk" {
    try std.testing.expect((Eligibility{}).preflightEligible());
    try std.testing.expect(!(Eligibility{ .partition = true }).preflightEligible());
    try std.testing.expect(!(Eligibility{ .read_only = true }).preflightEligible());
    try std.testing.expect(!(Eligibility{ .mounted = true }).preflightEligible());
    try std.testing.expect(!(Eligibility{ .swap = true }).preflightEligible());
    try std.testing.expect(!(Eligibility{ .held = true }).preflightEligible());
}

test "device ancestry uses path component boundaries" {
    try std.testing.expect(isSameOrDescendant("/sys/devices/disk", "/sys/devices/disk"));
    try std.testing.expect(isSameOrDescendant("/sys/devices/disk", "/sys/devices/disk/part"));
    try std.testing.expect(!isSameOrDescendant("/sys/devices/disk", "/sys/devices/diskette"));
}

test "inspection rejects non-block devices" {
    try std.testing.expectError(
        error.NotBlockDevice,
        inspect(std.testing.io, std.testing.allocator, "/dev/null"),
    );
}

test {
    _ = linux_uring_storage;
}
