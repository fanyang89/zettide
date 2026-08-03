//! Linux block-device SG_IO executor. Character SG devices are rejected
//! because their independent retry policy weakens CAW result classification.

const std = @import("std");
const linux = std.os.linux;
const scsi = @import("scsi.zig");

const sg_io = 0x2285;
const sg_dxfer_none: i32 = -1;
const sg_dxfer_to_device: i32 = -2;
const sg_dxfer_from_device: i32 = -3;
const blk_sector_size = 0x1268;
const blk_capacity = if (@sizeOf(usize) == 8) 0x80081272 else 0x80041272;

const SgIovec = extern struct {
    base: ?*anyopaque,
    len: usize,
};

const SgIoHeader = extern struct {
    interface_id: i32,
    dxfer_direction: i32,
    cmd_len: u8,
    max_sense_len: u8,
    iovec_count: u16,
    dxfer_len: u32,
    dxferp: ?*anyopaque,
    cmdp: [*]u8,
    sensep: [*]u8,
    timeout: u32,
    flags: u32,
    pack_id: i32,
    user_ptr: ?*anyopaque,
    status: u8,
    masked_status: u8,
    message_status: u8,
    sense_len: u8,
    host_status: u16,
    driver_status: u16,
    residual: i32,
    duration: u32,
    info: u32,
};

pub const LinuxSgIo = struct {
    fd: linux.fd_t,
    capacity_bytes: u64,
    logical_block_size: u32,

    pub fn open(path: [:0]const u8) !LinuxSgIo {
        const result = linux.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        const fd: linux.fd_t = switch (linux.errno(result)) {
            .SUCCESS => @intCast(result),
            .ACCES, .PERM => return error.PermissionDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.InvalidPath,
            .BUSY => return error.DeviceBusy,
            else => return error.OpenDeviceFailed,
        };
        errdefer _ = linux.close(fd);
        try requireBlockDevice(fd);
        const capacity_bytes = try ioctlValue(fd, blk_capacity, u64);
        const logical_block_size = try ioctlValue(fd, blk_sector_size, u32);
        if (capacity_bytes == 0 or logical_block_size == 0)
            return error.InvalidBlockDeviceGeometry;
        return .{
            .fd = fd,
            .capacity_bytes = capacity_bytes,
            .logical_block_size = logical_block_size,
        };
    }

    pub fn close(self: *LinuxSgIo) void {
        _ = linux.close(self.fd);
        self.* = undefined;
    }

    /// Probes through SG_IO and verifies that the block node is a complete,
    /// one-to-one view of the SCSI LUN. This rejects partitions and sliced
    /// device-mapper targets whose passthrough LBAs would bypass the mapping.
    pub fn initScsi(self: *LinuxSgIo, options: scsi.Options) !scsi.ScsiConditionalBlock {
        const result = try scsi.ScsiConditionalBlock.init(self.executor(), options);
        const scsi_capacity = std.math.mul(
            u64,
            result.geometry.block_count,
            result.geometry.logical_block_size,
        ) catch return error.DeviceGeometryMismatch;
        if (result.geometry.logical_block_size != self.logical_block_size or
            scsi_capacity != self.capacity_bytes)
        {
            return error.DeviceGeometryMismatch;
        }
        return result;
    }

    fn executor(self: *LinuxSgIo) scsi.Executor {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: *scsi.Command) !scsi.Execution {
        const self: *LinuxSgIo = @ptrCast(@alignCast(context));
        const transfer_len = std.math.cast(u32, command.data.byteLen()) orelse
            return error.TransferTooLarge;
        var sense: [scsi.max_sense_size]u8 = @splat(0);
        var iovecs: [2]SgIovec = undefined;
        var direction: i32 = sg_dxfer_none;
        var transfer: ?*anyopaque = null;
        var iovec_count: u16 = 0;

        switch (command.data) {
            .none => {},
            .from_device => |bytes| {
                direction = sg_dxfer_from_device;
                transfer = bytes.ptr;
            },
            .to_device => |bytes| {
                direction = sg_dxfer_to_device;
                transfer = @constCast(bytes.ptr);
            },
            .to_device_pair => |pair| {
                direction = sg_dxfer_to_device;
                iovecs = .{
                    .{ .base = @constCast(pair.first.ptr), .len = pair.first.len },
                    .{ .base = @constCast(pair.second.ptr), .len = pair.second.len },
                };
                transfer = &iovecs;
                iovec_count = iovecs.len;
            },
        }

        var header = SgIoHeader{
            .interface_id = 'S',
            .dxfer_direction = direction,
            .cmd_len = command.cdb_len,
            .max_sense_len = sense.len,
            .iovec_count = iovec_count,
            .dxfer_len = transfer_len,
            .dxferp = transfer,
            .cmdp = &command.cdb,
            .sensep = &sense,
            .timeout = command.timeout_ms,
            .flags = 0,
            .pack_id = 0,
            .user_ptr = null,
            .status = 0,
            .masked_status = 0,
            .message_status = 0,
            .sense_len = 0,
            .host_status = 0,
            .driver_status = 0,
            .residual = 0,
            .duration = 0,
            .info = 0,
        };
        const result = linux.ioctl(self.fd, sg_io, @intFromPtr(&header));
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .BADF => return error.InvalidFileDescriptor,
            .INVAL => return error.InvalidScsiCommand,
            .NOTTY => return error.SgIoUnsupported,
            .ACCES, .PERM => return error.PermissionDenied,
            else => return .indeterminate,
        }

        var completion = scsi.Completion{
            .status = header.status,
            .host_status = header.host_status,
            .driver_status = header.driver_status,
            .residual = header.residual,
            .sense_len = @min(header.sense_len, scsi.max_sense_size),
        };
        @memcpy(completion.sense[0..completion.sense_len], sense[0..completion.sense_len]);
        return .{ .completed = completion };
    }
};

fn requireBlockDevice(fd: linux.fd_t) !void {
    var stat: linux.Statx = undefined;
    const result = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat);
    if (linux.errno(result) != .SUCCESS) return error.StatDeviceFailed;
    if (stat.mode & linux.S.IFMT != linux.S.IFBLK) return error.NotBlockDevice;
}

fn ioctlValue(fd: linux.fd_t, request: u32, comptime T: type) !T {
    var value: T = 0;
    const result = linux.ioctl(fd, request, @intFromPtr(&value));
    if (linux.errno(result) != .SUCCESS) return error.BlockDeviceIoctlFailed;
    return value;
}

test "SG_IO ABI matches the Linux userspace header" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 16), @sizeOf(SgIovec));
        try std.testing.expectEqual(@as(usize, 88), @sizeOf(SgIoHeader));
    }
}

test "Linux SG_IO rejects character devices" {
    try std.testing.expectError(error.NotBlockDevice, LinuxSgIo.open("/dev/null"));
}
