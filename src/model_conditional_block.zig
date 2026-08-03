//! Fault-injection model for full-block conditional transports.

const std = @import("std");
const block = @import("conditional_block.zig");

pub const Fault = enum {
    none,
    indeterminate_no_write,
    indeterminate_after_write,
    indeterminate_pending,
};

const Pending = struct {
    block_index: u64,
    expected: []u8,
    replacement: []u8,
};

fn spinLock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {}
}

pub const ModelConditionalBlock = struct {
    allocator: std.mem.Allocator,
    geometry: block.Geometry,
    mutex: std.atomic.Mutex = .unlocked,
    visible: []u8,
    stable: []u8,
    next_fault: Fault = .none,
    fail_next_stabilize: bool = false,
    stabilizes_until_failure: usize = 0,
    pending: std.ArrayList(Pending) = .empty,
    caws_until_fault: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        geometry: block.Geometry,
    ) !ModelConditionalBlock {
        try geometry.validate();
        const block_count = std.math.cast(usize, geometry.block_count) orelse
            return error.GeometryTooLarge;
        const size = try std.math.mul(
            usize,
            block_count,
            geometry.logical_block_size,
        );
        const visible = try allocator.alloc(u8, size);
        errdefer allocator.free(visible);
        const stable = try allocator.alloc(u8, size);
        @memset(visible, 0);
        @memset(stable, 0);
        return .{
            .allocator = allocator,
            .geometry = geometry,
            .visible = visible,
            .stable = stable,
        };
    }

    pub fn deinit(self: *ModelConditionalBlock) void {
        for (self.pending.items) |pending| self.freePending(pending);
        self.pending.deinit(self.allocator);
        self.allocator.free(self.visible);
        self.allocator.free(self.stable);
        self.* = undefined;
    }

    pub fn transport(self: *ModelConditionalBlock) block.ConditionalBlockTransport {
        return .{ .context = self, .vtable = &vtable, .geometry = self.geometry };
    }

    pub fn injectNextFault(self: *ModelConditionalBlock, fault: Fault) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.next_fault = fault;
        self.caws_until_fault = 0;
    }

    pub fn injectFaultAfter(
        self: *ModelConditionalBlock,
        successful_compares: usize,
        fault: Fault,
    ) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.next_fault = fault;
        self.caws_until_fault = successful_compares;
    }

    pub fn injectNextStabilizeFailure(self: *ModelConditionalBlock) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.fail_next_stabilize = true;
        self.stabilizes_until_failure = 0;
    }

    pub fn injectStabilizeFailureAfter(
        self: *ModelConditionalBlock,
        successful_stabilizes: usize,
    ) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.fail_next_stabilize = true;
        self.stabilizes_until_failure = successful_stabilizes;
    }

    pub fn completePending(self: *ModelConditionalBlock) ?block.CawResult {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.pending.items.len == 0) return null;
        const pending = self.pending.orderedRemove(0);
        defer self.freePending(pending);
        const current = self.blockSlice(self.visible, pending.block_index);
        if (!std.mem.eql(u8, current, pending.expected)) return .miscompare;
        @memcpy(current, pending.replacement);
        return .written;
    }

    pub fn crash(self: *ModelConditionalBlock) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        @memcpy(self.visible, self.stable);
        for (self.pending.items) |pending| self.freePending(pending);
        self.pending.clearRetainingCapacity();
        self.next_fault = .none;
        self.caws_until_fault = 0;
        self.fail_next_stabilize = false;
        self.stabilizes_until_failure = 0;
    }

    fn readBlock(context: *anyopaque, block_index: u64, output: []u8) !void {
        const self: *ModelConditionalBlock = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        @memcpy(output, self.blockSlice(self.visible, block_index));
    }

    fn compareAndWrite(
        context: *anyopaque,
        block_index: u64,
        expected: []const u8,
        replacement: []const u8,
    ) !block.CawResult {
        const self: *ModelConditionalBlock = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        const current = self.blockSlice(self.visible, block_index);
        if (!std.mem.eql(u8, current, expected)) return .miscompare;

        var fault: Fault = .none;
        if (self.next_fault != .none) {
            if (self.caws_until_fault == 0) {
                fault = self.next_fault;
                self.next_fault = .none;
            } else {
                self.caws_until_fault -= 1;
            }
        }
        switch (fault) {
            .none => {
                @memcpy(current, replacement);
                return .written;
            },
            .indeterminate_no_write => return .indeterminate,
            .indeterminate_after_write => {
                @memcpy(current, replacement);
                return .indeterminate;
            },
            .indeterminate_pending => {
                const expected_copy = try self.allocator.dupe(u8, expected);
                errdefer self.allocator.free(expected_copy);
                const replacement_copy = try self.allocator.dupe(u8, replacement);
                errdefer self.allocator.free(replacement_copy);
                try self.pending.append(self.allocator, .{
                    .block_index = block_index,
                    .expected = expected_copy,
                    .replacement = replacement_copy,
                });
                return .indeterminate;
            },
        }
    }

    fn stabilize(context: *anyopaque) !void {
        const self: *ModelConditionalBlock = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.fail_next_stabilize) {
            if (self.stabilizes_until_failure == 0) {
                self.fail_next_stabilize = false;
                return error.InjectedStabilizeFailure;
            }
            self.stabilizes_until_failure -= 1;
        }
        @memcpy(self.stable, self.visible);
    }

    fn blockSlice(self: *const ModelConditionalBlock, bytes: []u8, block_index: u64) []u8 {
        const start: usize = @intCast(block_index * self.geometry.logical_block_size);
        return bytes[start .. start + self.geometry.logical_block_size];
    }

    fn freePending(self: *ModelConditionalBlock, pending: Pending) void {
        self.allocator.free(pending.expected);
        self.allocator.free(pending.replacement);
    }

    const vtable = block.ConditionalBlockTransport.VTable{
        .read_block = readBlock,
        .compare_and_write = compareAndWrite,
        .stabilize = stabilize,
    };
};

test "model transport compares complete 512 and 4096 byte blocks" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        var model = try ModelConditionalBlock.init(std.testing.allocator, .{
            .logical_block_size = block_size,
            .block_count = 2,
        });
        defer model.deinit();
        const transport = model.transport();
        const expected = try std.testing.allocator.alloc(u8, block_size);
        defer std.testing.allocator.free(expected);
        const replacement = try std.testing.allocator.alloc(u8, block_size);
        defer std.testing.allocator.free(replacement);
        @memset(expected, 0);
        @memset(replacement, 0);
        replacement[block_size - 1] = 1;
        try std.testing.expectEqual(
            block.CawResult.written,
            try transport.compareAndWrite(1, expected, replacement),
        );
        try std.testing.expectEqual(
            block.CawResult.miscompare,
            try transport.compareAndWrite(1, expected, replacement),
        );
    }
}

test "model transport rolls back writes until stabilize" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 1,
    });
    defer model.deinit();
    const transport = model.transport();
    var expected: [512]u8 = @splat(0);
    var replacement = expected;
    replacement[0] = 1;
    try std.testing.expectEqual(
        block.CawResult.written,
        try transport.compareAndWrite(0, &expected, &replacement),
    );
    model.crash();
    try transport.readBlock(0, &expected);
    try std.testing.expectEqual(@as(u8, 0), expected[0]);

    try std.testing.expectEqual(
        block.CawResult.written,
        try transport.compareAndWrite(0, &expected, &replacement),
    );
    try transport.stabilize();
    model.crash();
    try transport.readBlock(0, &expected);
    try std.testing.expectEqual(@as(u8, 1), expected[0]);
}

test "delayed indeterminate CAW cannot overwrite a successor" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 1,
    });
    defer model.deinit();
    const transport = model.transport();
    var expected: [512]u8 = @splat(0);
    var delayed = expected;
    delayed[0] = 1;
    var successor = expected;
    successor[0] = 2;

    model.injectNextFault(.indeterminate_pending);
    try std.testing.expectEqual(
        block.CawResult.indeterminate,
        try transport.compareAndWrite(0, &expected, &delayed),
    );
    try std.testing.expectEqual(
        block.CawResult.written,
        try transport.compareAndWrite(0, &expected, &successor),
    );
    try std.testing.expectEqual(block.CawResult.miscompare, model.completePending().?);
    try transport.readBlock(0, &expected);
    try std.testing.expectEqual(@as(u8, 2), expected[0]);
}

test "concurrent full-block CAWs have exactly one winner" {
    const Worker = struct {
        transport: block.ConditionalBlockTransport,
        expected: [512]u8,
        replacement: [512]u8,
        result: ?block.CawResult = null,

        fn run(self: *@This()) void {
            self.result = self.transport.compareAndWrite(
                0,
                &self.expected,
                &self.replacement,
            ) catch |err| std.debug.panic("concurrent CAW failed: {s}", .{@errorName(err)});
        }
    };

    var model = try ModelConditionalBlock.init(std.heap.page_allocator, .{
        .logical_block_size = 512,
        .block_count = 1,
    });
    defer model.deinit();
    const expected: [512]u8 = @splat(0);
    var first_replacement = expected;
    first_replacement[0] = 1;
    var second_replacement = expected;
    second_replacement[0] = 2;
    var first = Worker{
        .transport = model.transport(),
        .expected = expected,
        .replacement = first_replacement,
    };
    var second = Worker{
        .transport = model.transport(),
        .expected = expected,
        .replacement = second_replacement,
    };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();
    const written = @intFromBool(first.result == .written) + @intFromBool(second.result == .written);
    const mismatched = @intFromBool(first.result == .miscompare) + @intFromBool(second.result == .miscompare);
    try std.testing.expectEqual(@as(u2, 1), written);
    try std.testing.expectEqual(@as(u2, 1), mismatched);
}

test "model queues delayed commands for independent blocks" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 2,
    });
    defer model.deinit();
    const transport = model.transport();
    const expected: [512]u8 = @splat(0);
    var first = expected;
    first[0] = 1;
    var second = expected;
    second[0] = 2;
    model.injectNextFault(.indeterminate_pending);
    try std.testing.expectEqual(
        block.CawResult.indeterminate,
        try transport.compareAndWrite(0, &expected, &first),
    );
    model.injectNextFault(.indeterminate_pending);
    try std.testing.expectEqual(
        block.CawResult.indeterminate,
        try transport.compareAndWrite(1, &expected, &second),
    );
    try std.testing.expectEqual(block.CawResult.written, model.completePending().?);
    try std.testing.expectEqual(block.CawResult.written, model.completePending().?);
    try std.testing.expectEqual(@as(?block.CawResult, null), model.completePending());
}
