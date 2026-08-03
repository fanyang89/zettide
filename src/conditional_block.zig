//! Backend-neutral full-block COMPARE AND WRITE transport.

pub const CawResult = enum {
    written,
    miscompare,
    indeterminate,
};

pub const Error = error{
    InvalidLogicalBlockSize,
    InvalidBlockCount,
    InvalidBufferSize,
    BlockOutOfRange,
    NoOpWrite,
};

pub const Geometry = struct {
    logical_block_size: u32,
    block_count: u64,

    pub fn validate(self: Geometry) Error!void {
        if (self.logical_block_size != 512 and self.logical_block_size != 4096)
            return error.InvalidLogicalBlockSize;
        if (self.block_count == 0) return error.InvalidBlockCount;
    }
};

/// A thread-safe, non-owning transport view. Implementations must stop
/// borrowing caller buffers before a method returns, including when returning
/// an indeterminate result.
pub const ConditionalBlockTransport = struct {
    context: *anyopaque,
    vtable: *const VTable,
    geometry: Geometry,

    pub const VTable = struct {
        read_block: *const fn (*anyopaque, u64, []u8) anyerror!void,
        compare_and_write: *const fn (
            *anyopaque,
            u64,
            []const u8,
            []const u8,
        ) anyerror!CawResult,
        stabilize: *const fn (*anyopaque) anyerror!void,
    };

    pub fn readBlock(
        self: ConditionalBlockTransport,
        block_index: u64,
        output: []u8,
    ) !void {
        try self.validateAccess(block_index, output.len);
        return self.vtable.read_block(self.context, block_index, output);
    }

    /// Compares and replaces one complete logical block atomically.
    /// `.written` means visible but not necessarily crash durable;
    /// `.miscompare` proves no write occurred; `.indeterminate` means the
    /// caller must reread. An ordinary error is permitted only before the
    /// command may have reached storage. Every post-dispatch failure, including
    /// timeout and path loss, must be returned as `.indeterminate`.
    pub fn compareAndWrite(
        self: ConditionalBlockTransport,
        block_index: u64,
        expected: []const u8,
        replacement: []const u8,
    ) !CawResult {
        try self.validateAccess(block_index, expected.len);
        if (replacement.len != expected.len) return error.InvalidBufferSize;
        if (std.mem.eql(u8, expected, replacement)) return error.NoOpWrite;
        return self.vtable.compare_and_write(
            self.context,
            block_index,
            expected,
            replacement,
        );
    }

    /// Makes completed writes crash durable. It is safe to retry after error.
    pub fn stabilize(self: ConditionalBlockTransport) !void {
        try self.geometry.validate();
        return self.vtable.stabilize(self.context);
    }

    fn validateAccess(
        self: ConditionalBlockTransport,
        block_index: u64,
        buffer_size: usize,
    ) Error!void {
        try self.geometry.validate();
        if (block_index >= self.geometry.block_count) return error.BlockOutOfRange;
        if (buffer_size != self.geometry.logical_block_size) return error.InvalidBufferSize;
    }
};

const std = @import("std");

test "conditional block validates geometry and access" {
    try (Geometry{ .logical_block_size = 512, .block_count = 1 }).validate();
    try (Geometry{ .logical_block_size = 4096, .block_count = 1 }).validate();
    try std.testing.expectError(
        error.InvalidLogicalBlockSize,
        (Geometry{ .logical_block_size = 1024, .block_count = 1 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidBlockCount,
        (Geometry{ .logical_block_size = 512, .block_count = 0 }).validate(),
    );
}
