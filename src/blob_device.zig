const std = @import("std");
const storage_api = @import("v3/storage.zig");

const Io = std.Io;

pub const max_batch = 32;

pub const Read = struct {
    buffer: []u8,
    offset: u64,
};

pub const ReadResult = storage_api.ReadResult;

pub const Write = struct {
    bytes: []const u8,
    offset: u64,
};

/// Owned aligned region used by the immutable blob data plane.
pub const Device = struct {
    storage: storage_api.Storage,
    region_offset: u64,
    capacity_bytes: u64,
    io_alignment: u32,

    pub fn init(
        storage: storage_api.Storage,
        region_offset: u64,
        capacity_bytes: u64,
        io_alignment: u32,
    ) !Device {
        if (!std.math.isPowerOfTwo(io_alignment) or
            io_alignment < storage.minimum_io_size or
            io_alignment % storage.minimum_io_size != 0 or
            region_offset % io_alignment != 0 or
            capacity_bytes % io_alignment != 0 or
            region_offset > storage.capacity() or
            capacity_bytes > storage.capacity() - region_offset)
            return error.InvalidBlobDeviceGeometry;
        return .{
            .storage = storage,
            .region_offset = region_offset,
            .capacity_bytes = capacity_bytes,
            .io_alignment = io_alignment,
        };
    }

    pub fn createFile(
        io: Io,
        parent: Io.Dir,
        basename: []const u8,
        capacity_bytes: u64,
        io_alignment: u32,
    ) !Device {
        var storage = try storage_api.Storage.createFile(io, parent, basename, capacity_bytes);
        errdefer storage.close(io) catch {};
        return init(storage, 0, capacity_bytes, io_alignment);
    }

    pub fn capacity(self: *const Device) u64 {
        return self.capacity_bytes;
    }

    pub fn readAt(self: *Device, io: Io, buffer: []u8, offset: u64) !void {
        try self.validateIo(buffer.ptr, buffer.len, offset);
        const amount = try self.storage.readAt(io, buffer, self.region_offset + offset);
        if (amount != buffer.len) return error.UnexpectedEndOfBlobDevice;
    }

    pub fn readManyAt(self: *Device, io: Io, reads: []const Read, results: []ReadResult) !void {
        if (reads.len != results.len) return error.InvalidReadBatch;
        var index: usize = 0;
        while (index < reads.len) {
            const count = @min(reads.len - index, max_batch);
            var translated: [max_batch]storage_api.Read = undefined;
            for (reads[index..][0..count], 0..) |read, batch_index| {
                try self.validateIo(read.buffer.ptr, read.buffer.len, read.offset);
                translated[batch_index] = .{
                    .buffer = read.buffer,
                    .offset = self.region_offset + read.offset,
                };
            }
            try self.storage.readManyAt(io, translated[0..count], results[index..][0..count]);
            index += count;
        }
    }

    pub fn writeAllAt(self: *Device, io: Io, bytes: []const u8, offset: u64) !void {
        try self.validateIo(bytes.ptr, bytes.len, offset);
        try self.storage.writeAllAt(io, bytes, self.region_offset + offset);
    }

    /// Writes must not overlap; execution order is backend-dependent.
    pub fn writeAllManyAt(self: *Device, io: Io, writes: []const Write) !void {
        var index: usize = 0;
        while (index < writes.len) {
            const count = @min(writes.len - index, max_batch);
            var translated: [max_batch]storage_api.Write = undefined;
            for (writes[index..][0..count], 0..) |write, batch_index| {
                try self.validateIo(write.bytes.ptr, write.bytes.len, write.offset);
                translated[batch_index] = .{
                    .bytes = write.bytes,
                    .offset = self.region_offset + write.offset,
                };
            }
            try self.storage.writeAllManyAt(io, translated[0..count]);
            index += count;
        }
    }

    pub fn syncData(self: *Device, io: Io) !void {
        try self.storage.syncData(io);
    }

    pub fn sync(self: *Device, io: Io) !void {
        try self.storage.sync(io);
    }

    pub fn close(self: *Device, io: Io) !void {
        try self.storage.close(io);
        self.* = undefined;
    }

    fn validateIo(self: *const Device, pointer: [*]const u8, len: usize, offset: u64) !void {
        if (@intFromPtr(pointer) % self.io_alignment != 0 or
            len == 0 or
            len % self.io_alignment != 0 or
            offset % self.io_alignment != 0 or
            offset > self.capacity_bytes or
            len > self.capacity_bytes - offset)
            return error.InvalidBlobDeviceIo;
    }
};

test "blob device translates aligned region IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var storage = try storage_api.Storage.createFile(std.testing.io, tmp.dir, "blob-device", 16 * 1024);
    var storage_open = true;
    defer if (storage_open) storage.close(std.testing.io) catch {};
    var device = try Device.init(storage, 4096, 8192, 4096);
    storage_open = false;
    defer device.close(std.testing.io) catch {};

    const allocator = std.testing.allocator;
    const first = try allocator.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    defer allocator.free(first);
    const second = try allocator.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    defer allocator.free(second);
    @memset(first, 0x11);
    @memset(second, 0x22);
    const writes = [_]Write{
        .{ .bytes = first, .offset = 0 },
        .{ .bytes = second, .offset = 4096 },
    };
    try device.writeAllManyAt(std.testing.io, &writes);
    try device.syncData(std.testing.io);

    @memset(first, 0);
    @memset(second, 0);
    const reads = [_]Read{
        .{ .buffer = first, .offset = 0 },
        .{ .buffer = second, .offset = 4096 },
    };
    var results: [reads.len]ReadResult = undefined;
    try device.readManyAt(std.testing.io, &reads, &results);
    for (results) |result| {
        try std.testing.expectEqual(@as(usize, 4096), result.amount);
        try std.testing.expectEqual(@as(?anyerror, null), result.failure);
    }
    try std.testing.expect(std.mem.allEqual(u8, first, 0x11));
    try std.testing.expect(std.mem.allEqual(u8, second, 0x22));
}

test "blob device rejects unaligned and out of range IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var device = try Device.createFile(std.testing.io, tmp.dir, "invalid-blob-device", 8192, 4096);
    defer device.close(std.testing.io) catch {};

    const bytes = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.InvalidBlobDeviceIo, device.writeAllAt(std.testing.io, bytes[0..2048], 0));
    try std.testing.expectError(error.InvalidBlobDeviceIo, device.writeAllAt(std.testing.io, bytes, 4096 + 1));
    try std.testing.expectError(error.InvalidBlobDeviceIo, device.writeAllAt(std.testing.io, bytes, 8192));
}
