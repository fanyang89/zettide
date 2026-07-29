const std = @import("std");
const storage_api = @import("../v3/storage.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("stdlib.h");
    @cInclude("spdk/bdev_dispatcher.h");
});

pub const Owner = c.struct_spdk_thread;

const Context = struct {
    allocator: std.mem.Allocator,
    dispatcher: *c.struct_zettide_spdk_bdev_dispatcher,
    geometry: c.struct_zettide_spdk_bdev_geometry,
    canonical_name: [*:0]u8,
};

/// The SPDK owner must remain alive and polling until the returned Storage closes.
pub fn open(
    allocator: std.mem.Allocator,
    owner: *Owner,
    name: []const u8,
    writable: bool,
) !storage_api.Storage {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    var dispatcher: ?*c.struct_zettide_spdk_bdev_dispatcher = null;
    try statusError(c.zettide_spdk_bdev_dispatcher_open(owner, name_z.ptr, writable, &dispatcher));
    const opened = dispatcher orelse return error.UnexpectedSpdkStatus;
    errdefer statusError(c.zettide_spdk_bdev_dispatcher_close(opened)) catch {};

    var geometry: c.struct_zettide_spdk_bdev_geometry = undefined;
    try statusError(c.zettide_spdk_bdev_dispatcher_get_geometry(opened, &geometry));
    var canonical_name: [*c]u8 = null;
    try statusError(c.zettide_spdk_bdev_dispatcher_get_name(opened, &canonical_name));
    if (canonical_name == null) return error.UnexpectedSpdkStatus;
    errdefer c.free(canonical_name);
    const minimum_io_size = try validateGeometry(geometry, writable);
    const context = try allocator.create(Context);
    context.* = .{
        .allocator = allocator,
        .dispatcher = opened,
        .geometry = geometry,
        .canonical_name = @ptrCast(canonical_name),
    };
    return storage_api.Storage.initBackend(
        context,
        &storage_vtable,
        geometry.capacity_bytes,
        .spdk_bdev,
        minimum_io_size,
    );
}

fn sameIdentity(context_ptr: *anyopaque, other_context_ptr: *anyopaque) bool {
    const context: *const Context = @ptrCast(@alignCast(context_ptr));
    const other: *const Context = @ptrCast(@alignCast(other_context_ptr));
    return std.mem.eql(u8, std.mem.span(context.canonical_name), std.mem.span(other.canonical_name));
}

fn validateGeometry(geometry: c.struct_zettide_spdk_bdev_geometry, writable: bool) !u32 {
    if (geometry.capacity_bytes == 0 or geometry.logical_block_size == 0 or
        geometry.write_unit_blocks == 0 or geometry.buffer_alignment == 0 or
        geometry.capacity_bytes % geometry.logical_block_size != 0)
        return error.InvalidStorageGeometry;
    const write_unit_size = std.math.mul(
        u32,
        geometry.logical_block_size,
        geometry.write_unit_blocks,
    ) catch return error.InvalidStorageGeometry;
    const minimum_io_size = if (writable)
        @max(geometry.logical_block_size, write_unit_size)
    else
        geometry.logical_block_size;
    if (!std.math.isPowerOfTwo(minimum_io_size) or minimum_io_size > 4096 or
        4096 % minimum_io_size != 0)
        return error.UnsupportedStorageAlignment;
    if (writable and (geometry.flags & c.ZETTIDE_SPDK_BDEV_WRITABLE) == 0)
        return error.ReadOnlyStorage;
    if (writable and (geometry.flags & c.ZETTIDE_SPDK_BDEV_WRITE_CACHE) != 0 and
        (geometry.flags & c.ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED) == 0)
        return error.DurabilityUnavailable;
    return minimum_io_size;
}

fn readAt(context_ptr: *anyopaque, _: std.Io, buffer: []u8, offset: u64) !usize {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (buffer.len == 0) return 0;
    try validateIo(context, offset, buffer.len, context.geometry.logical_block_size);
    const dma_buffer = c.zettide_spdk_dma_zmalloc(buffer.len, context.geometry.buffer_alignment) orelse
        return error.OutOfMemory;
    defer c.zettide_spdk_dma_free(dma_buffer);
    try statusError(c.zettide_spdk_bdev_dispatcher_read(
        context.dispatcher,
        dma_buffer,
        offset,
        buffer.len,
    ));
    const dma_bytes: [*]const u8 = @ptrCast(dma_buffer);
    @memcpy(buffer, dma_bytes[0..buffer.len]);
    return buffer.len;
}

fn writeAllAt(context_ptr: *anyopaque, _: std.Io, bytes: []const u8, offset: u64) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if (bytes.len == 0) return;
    const write_unit_size = std.math.mul(
        u32,
        context.geometry.logical_block_size,
        context.geometry.write_unit_blocks,
    ) catch return error.InvalidStorageGeometry;
    try validateIo(context, offset, bytes.len, write_unit_size);
    const dma_buffer = c.zettide_spdk_dma_zmalloc(bytes.len, context.geometry.buffer_alignment) orelse
        return error.OutOfMemory;
    defer c.zettide_spdk_dma_free(dma_buffer);
    const dma_bytes: [*]u8 = @ptrCast(dma_buffer);
    @memcpy(dma_bytes[0..bytes.len], bytes);
    try statusError(c.zettide_spdk_bdev_dispatcher_write(
        context.dispatcher,
        dma_buffer,
        offset,
        bytes.len,
    ));
}

fn sync(context_ptr: *anyopaque, _: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    if ((context.geometry.flags & c.ZETTIDE_SPDK_BDEV_FLUSH_SUPPORTED) == 0) return;
    try statusError(c.zettide_spdk_bdev_dispatcher_flush(
        context.dispatcher,
        0,
        context.geometry.capacity_bytes,
    ));
}

fn close(context_ptr: *anyopaque, _: std.Io) !void {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    try statusError(c.zettide_spdk_bdev_dispatcher_close(context.dispatcher));
    c.free(context.canonical_name);
    context.allocator.destroy(context);
}

fn validateIo(context: *const Context, offset: u64, len: usize, alignment: u32) !void {
    const length = std.math.cast(u64, len) orelse return error.StorageOutOfBounds;
    if (offset > context.geometry.capacity_bytes or
        length > context.geometry.capacity_bytes - offset)
        return error.StorageOutOfBounds;
    if (offset % alignment != 0 or length % alignment != 0)
        return error.UnalignedStorageIo;
}

fn statusError(status: c_int) !void {
    if (status == 0) return;
    return switch (-status) {
        c.ENODEV => error.StorageRemoved,
        c.EPERM => error.StorageBusy,
        c.EOVERFLOW => error.InvalidStorageGeometry,
        c.ERANGE => error.StorageOutOfBounds,
        c.EINVAL => error.UnalignedStorageIo,
        c.EBADF => error.ReadOnlyStorage,
        c.ENOTSUP => error.UnsupportedStorageOperation,
        c.ENOMEM => error.OutOfMemory,
        c.EDEADLK => error.SpdkThreadViolation,
        c.EBUSY => error.StorageOperationsActive,
        c.EIO => error.StorageIo,
        else => error.UnexpectedSpdkStatus,
    };
}

const storage_vtable: storage_api.Storage.VTable = .{
    .same_identity = sameIdentity,
    .read_at = readAt,
    .write_all_at = writeAllAt,
    .sync = sync,
    .close = close,
};
