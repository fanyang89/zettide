const std = @import("std");
const pool_catalog_volume = @import("../v3/pool_catalog_volume.zig");
const pool_member_set = @import("../v3/pool_member_set.zig");

pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("spdk/bdev_provider.h");
});

/// Serializes a writable catalog volume backend behind the asynchronous SPDK
/// provider contract. The allocator must be thread-safe, and the caller must
/// not use `set` until `close` returns.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lease: pool_catalog_volume.CatalogDataLease,
    backend: pool_catalog_volume.CatalogVolumeBackend,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    head: ?*Request = null,
    tail: ?*Request = null,
    stopping: bool = false,
    thread: std.Thread,

    const Request = struct {
        operation: c.enum_zettide_spdk_bdev_provider_operation,
        offset: u64,
        buffer: ?*anyopaque,
        length: usize,
        complete: c.zettide_spdk_bdev_provider_complete,
        complete_context: ?*anyopaque,
        next: ?*Request = null,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        set: *pool_member_set.PoolMemberSet,
        volume_id: [16]u8,
    ) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = undefined;
        self.allocator = allocator;
        self.io = io;
        self.lease = try pool_catalog_volume.CatalogDataLease.acquire(set);
        errdefer self.lease.release();
        self.backend = try pool_catalog_volume.CatalogVolumeBackend.openWritable(
            allocator,
            &self.lease,
            volume_id,
        );
        self.mutex = .init;
        self.condition = .init;
        self.head = null;
        self.tail = null;
        self.stopping = false;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn logicalSize(self: *const Worker) u64 {
        return self.backend.logicalSize();
    }

    /// Call only after the provider deletion callback has completed.
    pub fn close(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();
        self.lease.release();
        self.allocator.destroy(self);
    }

    pub fn submit(
        context_raw: ?*anyopaque,
        operation: c.enum_zettide_spdk_bdev_provider_operation,
        offset: u64,
        buffer: ?*anyopaque,
        length_raw: u64,
        complete: c.zettide_spdk_bdev_provider_complete,
        complete_context: ?*anyopaque,
    ) callconv(.c) c_int {
        const context = context_raw orelse return -c.EINVAL;
        const self: *Worker = @ptrCast(@alignCast(context));
        const length = std.math.cast(usize, length_raw) orelse return -c.EOVERFLOW;
        if (complete == null or
            (length != 0 and buffer == null and
                (operation == c.ZETTIDE_SPDK_BDEV_PROVIDER_READ or
                    operation == c.ZETTIDE_SPDK_BDEV_PROVIDER_WRITE)))
            return -c.EINVAL;

        const request = self.allocator.create(Request) catch return -c.ENOMEM;
        request.* = .{
            .operation = operation,
            .offset = offset,
            .buffer = buffer,
            .length = length,
            .complete = complete,
            .complete_context = complete_context,
        };
        self.mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            self.allocator.destroy(request);
            return -c.ESHUTDOWN;
        }
        if (self.tail) |tail| {
            tail.next = request;
        } else {
            self.head = request;
        }
        self.tail = request;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        return 0;
    }

    fn run(self: *Worker) void {
        while (self.nextRequest()) |request| {
            const status = self.execute(request) catch |err| errorStatus(err);
            request.complete.?(request.complete_context, status);
            self.allocator.destroy(request);
        }
    }

    fn nextRequest(self: *Worker) ?*Request {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.head == null and !self.stopping)
            self.condition.waitUncancelable(self.io, &self.mutex);
        const request = self.head orelse return null;
        self.head = request.next;
        if (self.head == null) self.tail = null;
        return request;
    }

    fn execute(self: *Worker, request: *Request) !c_int {
        switch (request.operation) {
            c.ZETTIDE_SPDK_BDEV_PROVIDER_READ => {
                const buffer = if (request.length == 0)
                    @as([]u8, &.{})
                else
                    @as([*]u8, @ptrCast(request.buffer.?))[0..request.length];
                try self.backend.read(request.offset, buffer);
            },
            c.ZETTIDE_SPDK_BDEV_PROVIDER_WRITE => {
                const buffer = if (request.length == 0)
                    @as([]const u8, &.{})
                else
                    @as([*]const u8, @ptrCast(request.buffer.?))[0..request.length];
                try self.backend.write(&self.lease, request.offset, buffer);
            },
            c.ZETTIDE_SPDK_BDEV_PROVIDER_FLUSH => try self.backend.flush(&self.lease),
            c.ZETTIDE_SPDK_BDEV_PROVIDER_RESET => {},
            else => return error.InvalidProviderOperation,
        }
        return 0;
    }
};

pub const submit_callback: c.zettide_spdk_bdev_provider_submit = Worker.submit;

fn errorStatus(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -c.ENOMEM,
        error.OutOfBounds => -c.ERANGE,
        error.ExtentNotMapped => -c.ENOSPC,
        error.PoolAuthorityChanged => -c.ESTALE,
        error.MissingAuthority,
        error.DataReadUnavailable,
        error.DataWriteUnavailable,
        error.DataMemberUnavailable,
        => -c.ENODEV,
        error.DataLeaseReleased,
        error.DataLeaseMismatch,
        error.WriteFrozen,
        => -c.EBADF,
        else => -c.EIO,
    };
}
