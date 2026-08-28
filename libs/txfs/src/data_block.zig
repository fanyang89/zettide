//! Aligned block I/O contract for mutable file extents.

const std = @import("std");
const conditional = @import("conditional_block.zig");

pub const Geometry = conditional.Geometry;

pub const WriteResult = enum {
    /// The complete range was accepted by the device.
    written,
    /// Some or all blocks may have been written. The owner must stop issuing
    /// dependent writes until the path is drained, fenced, or recovered.
    indeterminate,
};

/// A transport may be shared between threads. Calls borrow buffers only until
/// they return. Implementations must bypass incoherent host page caches when
/// the device can be accessed by multiple hosts.
pub const DataBlockTransport = struct {
    context: *anyopaque,
    vtable: *const VTable,
    geometry: Geometry,
    memory_alignment: u32 = 1,
    device_identity: ?*anyopaque = null,

    pub const VTable = struct {
        read_blocks: *const fn (*anyopaque, u64, []u8) anyerror!void,
        /// Ordinary errors are permitted only when the implementation knows
        /// that no byte reached storage. Any post-dispatch failure must return
        /// `.indeterminate`, including failures that report no completed bytes.
        write_blocks: *const fn (*anyopaque, u64, []const u8) anyerror!WriteResult,
        stabilize: *const fn (*anyopaque) anyerror!void,
    };

    pub fn validate(self: DataBlockTransport) !void {
        try self.geometry.validate();
        if (self.memory_alignment == 0 or !std.math.isPowerOfTwo(self.memory_alignment))
            return error.InvalidMemoryAlignment;
    }

    pub fn readBlocks(self: DataBlockTransport, first_block: u64, output: []u8) !void {
        try self.validateTransfer(first_block, output.len, output.ptr);
        if (output.len == 0) return;
        return self.vtable.read_blocks(self.context, first_block, output);
    }

    pub fn writeBlocks(
        self: DataBlockTransport,
        first_block: u64,
        input: []const u8,
    ) !WriteResult {
        try self.validateTransfer(first_block, input.len, input.ptr);
        if (input.len == 0) return .written;
        return self.vtable.write_blocks(self.context, first_block, input);
    }

    pub fn stabilize(self: DataBlockTransport) !void {
        return self.vtable.stabilize(self.context);
    }

    pub fn deviceIdentity(self: DataBlockTransport) *anyopaque {
        return self.device_identity orelse self.context;
    }

    fn validateTransfer(
        self: DataBlockTransport,
        first_block: u64,
        byte_count: usize,
        pointer: anytype,
    ) !void {
        try self.validate();
        if (byte_count % self.geometry.logical_block_size != 0)
            return error.UnalignedTransferLength;
        const transfer_blocks: u64 = @intCast(byte_count / self.geometry.logical_block_size);
        const end = std.math.add(u64, first_block, transfer_blocks) catch
            return error.BlockOutOfRange;
        if (end > self.geometry.block_count) return error.BlockOutOfRange;
        if (byte_count != 0 and @intFromPtr(pointer) % self.memory_alignment != 0)
            return error.UnalignedTransferBuffer;
    }
};

/// The maximum supported logical block size is also sufficient for Linux
/// direct-I/O buffers on supported TxFS devices.
pub fn allocateBuffer(
    allocator: std.mem.Allocator,
    byte_count: usize,
) ![]align(4096) u8 {
    return allocator.alignedAlloc(u8, comptime .fromByteUnits(4096), byte_count);
}

test "data transport validates block ranges and alignment" {
    const Stub = struct {
        fn read(_: *anyopaque, _: u64, _: []u8) !void {}
        fn write(_: *anyopaque, _: u64, _: []const u8) !WriteResult {
            return .written;
        }
        fn stabilize(_: *anyopaque) !void {}
        const vtable = DataBlockTransport.VTable{
            .read_blocks = read,
            .write_blocks = write,
            .stabilize = stabilize,
        };
    };
    var context: u8 = 0;
    const transport = DataBlockTransport{
        .context = &context,
        .vtable = &Stub.vtable,
        .geometry = .{ .logical_block_size = 512, .block_count = 2 },
    };
    var block: [512]u8 = undefined;
    try transport.readBlocks(1, &block);
    try std.testing.expectError(error.BlockOutOfRange, transport.readBlocks(2, &block));
    try std.testing.expectError(
        error.UnalignedTransferLength,
        transport.writeBlocks(0, block[0..511]),
    );
    try std.testing.expectEqual(WriteResult.written, try transport.writeBlocks(2, &.{}));
}

test "data transport enforces implementation buffer alignment" {
    const Stub = struct {
        fn read(_: *anyopaque, _: u64, _: []u8) !void {}
        fn write(_: *anyopaque, _: u64, _: []const u8) !WriteResult {
            return .written;
        }
        fn stabilize(_: *anyopaque) !void {}
        const vtable = DataBlockTransport.VTable{
            .read_blocks = read,
            .write_blocks = write,
            .stabilize = stabilize,
        };
    };
    var context: u8 = 0;
    const transport = DataBlockTransport{
        .context = &context,
        .vtable = &Stub.vtable,
        .geometry = .{ .logical_block_size = 512, .block_count = 1 },
        .memory_alignment = 4096,
    };
    const allocation = try allocateBuffer(std.testing.allocator, 513);
    defer std.testing.allocator.free(allocation);
    try transport.readBlocks(0, allocation[0..512]);
    try std.testing.expectError(
        error.UnalignedTransferBuffer,
        transport.readBlocks(0, allocation[1..513]),
    );
}
