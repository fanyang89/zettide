//! Fault-injection model for mutable aligned block I/O.

const std = @import("std");
const data_block = @import("data_block.zig");

pub const Fault = enum {
    none,
    indeterminate_no_write,
    indeterminate_after_write,
    indeterminate_pending,
};

const Pending = struct {
    first_block: u64,
    bytes: []u8,
};

fn spinLock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {}
}

pub const ModelDataBlock = struct {
    allocator: std.mem.Allocator,
    geometry: data_block.Geometry,
    mutex: std.atomic.Mutex = .unlocked,
    visible: []u8,
    stable: []u8,
    next_fault: Fault = .none,
    writes_until_fault: usize = 0,
    fail_next_stabilize: bool = false,
    pending: std.ArrayList(Pending) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        geometry: data_block.Geometry,
    ) !ModelDataBlock {
        try geometry.validate();
        const block_count = std.math.cast(usize, geometry.block_count) orelse
            return error.GeometryTooLarge;
        const byte_count = try std.math.mul(usize, block_count, geometry.logical_block_size);
        const visible = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(visible);
        const stable = try allocator.alloc(u8, byte_count);
        @memset(visible, 0);
        @memset(stable, 0);
        return .{
            .allocator = allocator,
            .geometry = geometry,
            .visible = visible,
            .stable = stable,
        };
    }

    pub fn deinit(self: *ModelDataBlock) void {
        for (self.pending.items) |pending| self.allocator.free(pending.bytes);
        self.pending.deinit(self.allocator);
        self.allocator.free(self.visible);
        self.allocator.free(self.stable);
        self.* = undefined;
    }

    pub fn transport(self: *ModelDataBlock) data_block.DataBlockTransport {
        return .{ .context = self, .vtable = &vtable, .geometry = self.geometry };
    }

    pub fn injectNextFault(self: *ModelDataBlock, fault: Fault) void {
        self.injectFaultAfter(0, fault);
    }

    pub fn injectFaultAfter(
        self: *ModelDataBlock,
        successful_writes: usize,
        fault: Fault,
    ) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.next_fault = fault;
        self.writes_until_fault = successful_writes;
    }

    pub fn injectNextStabilizeFailure(self: *ModelDataBlock) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.fail_next_stabilize = true;
    }

    /// Completes one delayed ordinary write. Unlike CAW, it has no expected
    /// value and can therefore overwrite a newer write to the same range.
    pub fn completePending(self: *ModelDataBlock) bool {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.pending.items.len == 0) return false;
        const pending = self.pending.orderedRemove(0);
        defer self.allocator.free(pending.bytes);
        @memcpy(self.range(self.visible, pending.first_block, pending.bytes.len), pending.bytes);
        return true;
    }

    pub fn crash(self: *ModelDataBlock) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        @memcpy(self.visible, self.stable);
        for (self.pending.items) |pending| self.allocator.free(pending.bytes);
        self.pending.clearRetainingCapacity();
        self.next_fault = .none;
        self.writes_until_fault = 0;
        self.fail_next_stabilize = false;
    }

    fn readBlocks(context: *anyopaque, first_block: u64, output: []u8) !void {
        const self: *ModelDataBlock = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        @memcpy(output, self.range(self.visible, first_block, output.len));
    }

    fn writeBlocks(
        context: *anyopaque,
        first_block: u64,
        input: []const u8,
    ) !data_block.WriteResult {
        const self: *ModelDataBlock = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();

        var fault: Fault = .none;
        if (self.next_fault != .none) {
            if (self.writes_until_fault == 0) {
                fault = self.next_fault;
                self.next_fault = .none;
            } else {
                self.writes_until_fault -= 1;
            }
        }
        switch (fault) {
            .none => {
                @memcpy(self.range(self.visible, first_block, input.len), input);
                return .written;
            },
            .indeterminate_no_write => return .indeterminate,
            .indeterminate_after_write => {
                @memcpy(self.range(self.visible, first_block, input.len), input);
                return .indeterminate;
            },
            .indeterminate_pending => {
                const copy = try self.allocator.dupe(u8, input);
                errdefer self.allocator.free(copy);
                try self.pending.append(self.allocator, .{
                    .first_block = first_block,
                    .bytes = copy,
                });
                return .indeterminate;
            },
        }
    }

    fn stabilize(context: *anyopaque) !void {
        const self: *ModelDataBlock = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.fail_next_stabilize) {
            self.fail_next_stabilize = false;
            return error.InjectedStabilizeFailure;
        }
        @memcpy(self.stable, self.visible);
    }

    fn range(self: *const ModelDataBlock, bytes: []u8, first_block: u64, len: usize) []u8 {
        const start: usize = @intCast(first_block * self.geometry.logical_block_size);
        return bytes[start .. start + len];
    }

    const vtable = data_block.DataBlockTransport.VTable{
        .read_blocks = readBlocks,
        .write_blocks = writeBlocks,
        .stabilize = stabilize,
    };
};

test "model writes ranges and only preserves stabilized data" {
    var model = try ModelDataBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 3,
    });
    defer model.deinit();
    const transport = model.transport();
    var input: [1024]u8 = @splat(7);
    try std.testing.expectEqual(
        data_block.WriteResult.written,
        try transport.writeBlocks(1, &input),
    );
    model.crash();
    var output: [1024]u8 = undefined;
    try transport.readBlocks(1, &output);
    try std.testing.expectEqualSlices(u8, &@as([1024]u8, @splat(0)), &output);

    _ = try transport.writeBlocks(1, &input);
    try transport.stabilize();
    model.crash();
    try transport.readBlocks(1, &output);
    try std.testing.expectEqualSlices(u8, &input, &output);
}

test "delayed ordinary write can overwrite a successor" {
    var model = try ModelDataBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 1,
    });
    defer model.deinit();
    const transport = model.transport();
    const delayed: [512]u8 = @splat(1);
    const successor: [512]u8 = @splat(2);
    model.injectNextFault(.indeterminate_pending);
    try std.testing.expectEqual(
        data_block.WriteResult.indeterminate,
        try transport.writeBlocks(0, &delayed),
    );
    try std.testing.expectEqual(
        data_block.WriteResult.written,
        try transport.writeBlocks(0, &successor),
    );
    try std.testing.expect(model.completePending());

    var output: [512]u8 = undefined;
    try transport.readBlocks(0, &output);
    try std.testing.expectEqualSlices(u8, &delayed, &output);
}

test "model reports pre and post-write indeterminate outcomes" {
    var model = try ModelDataBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 1,
    });
    defer model.deinit();
    const transport = model.transport();
    const input: [512]u8 = @splat(3);

    model.injectNextFault(.indeterminate_no_write);
    try std.testing.expectEqual(
        data_block.WriteResult.indeterminate,
        try transport.writeBlocks(0, &input),
    );
    var output: [512]u8 = undefined;
    try transport.readBlocks(0, &output);
    try std.testing.expectEqual(@as(u8, 0), output[0]);

    model.injectNextFault(.indeterminate_after_write);
    try std.testing.expectEqual(
        data_block.WriteResult.indeterminate,
        try transport.writeBlocks(0, &input),
    );
    try transport.readBlocks(0, &output);
    try std.testing.expectEqual(@as(u8, 3), output[0]);
}
