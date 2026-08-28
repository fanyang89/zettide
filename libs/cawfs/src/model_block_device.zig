//! Unified fault-injection device for conditional and ordinary block I/O.

const std = @import("std");
const conditional = @import("conditional_block.zig");
const data = @import("data_block.zig");

pub const CawFault = enum {
    none,
    error_before_dispatch,
    indeterminate_no_write,
    indeterminate_after_write,
    indeterminate_pending,
};
pub const DataFault = enum { none, indeterminate_no_write, indeterminate_after_write, indeterminate_pending };

const PendingCaw = struct {
    block_index: u64,
    expected: []u8,
    replacement: []u8,
};

const PendingWrite = struct {
    first_block: u64,
    bytes: []u8,
};

fn spinLock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {}
}

/// Both transport views address the same visible and stable image. This models
/// the unified Linux construction; equal geometry alone does not prove that two
/// arbitrary production transports address the same storage.
pub const ModelBlockDevice = struct {
    allocator: std.mem.Allocator,
    geometry: conditional.Geometry,
    mutex: std.atomic.Mutex = .unlocked,
    visible: []u8,
    stable: []u8,
    next_caw_fault: CawFault = .none,
    caws_until_fault: usize = 0,
    next_data_fault: DataFault = .none,
    writes_until_fault: usize = 0,
    fail_next_stabilize: bool = false,
    reset_before_next_stabilize: bool = false,
    pending_caws: std.ArrayList(PendingCaw) = .empty,
    pending_writes: std.ArrayList(PendingWrite) = .empty,
    caw_count: usize = 0,
    reset_epoch: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, geometry: conditional.Geometry) !ModelBlockDevice {
        try geometry.validate();
        const block_count = std.math.cast(usize, geometry.block_count) orelse
            return error.GeometryTooLarge;
        const byte_count = try std.math.mul(usize, block_count, geometry.logical_block_size);
        const visible = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(visible);
        const stable = try allocator.alloc(u8, byte_count);
        @memset(visible, 0);
        @memset(stable, 0);
        return .{ .allocator = allocator, .geometry = geometry, .visible = visible, .stable = stable };
    }

    pub fn deinit(self: *ModelBlockDevice) void {
        for (self.pending_caws.items) |pending| self.freePendingCaw(pending);
        for (self.pending_writes.items) |pending| self.allocator.free(pending.bytes);
        self.pending_caws.deinit(self.allocator);
        self.pending_writes.deinit(self.allocator);
        self.allocator.free(self.visible);
        self.allocator.free(self.stable);
        self.* = undefined;
    }

    pub fn conditionalTransport(self: *ModelBlockDevice) conditional.ConditionalBlockTransport {
        return .{ .context = self, .vtable = &conditional_vtable, .geometry = self.geometry };
    }

    pub fn dataTransport(self: *ModelBlockDevice) data.DataBlockTransport {
        return .{ .context = self, .vtable = &data_vtable, .geometry = self.geometry };
    }

    pub fn injectCawFaultAfter(self: *ModelBlockDevice, successful_caws: usize, fault: CawFault) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.next_caw_fault = fault;
        self.caws_until_fault = successful_caws;
    }

    pub fn injectNextCawFault(self: *ModelBlockDevice, fault: CawFault) void {
        self.injectCawFaultAfter(0, fault);
    }

    pub fn injectDataFaultAfter(self: *ModelBlockDevice, successful_writes: usize, fault: DataFault) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.next_data_fault = fault;
        self.writes_until_fault = successful_writes;
    }

    pub fn injectNextDataFault(self: *ModelBlockDevice, fault: DataFault) void {
        self.injectDataFaultAfter(0, fault);
    }

    pub fn injectNextStabilizeFailure(self: *ModelBlockDevice) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.fail_next_stabilize = true;
    }

    pub fn injectResetBeforeNextStabilize(self: *ModelBlockDevice) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.reset_before_next_stabilize = true;
    }

    pub fn cawCount(self: *ModelBlockDevice) usize {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        return self.caw_count;
    }

    pub fn completePendingCaw(self: *ModelBlockDevice) ?conditional.CawResult {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.pending_caws.items.len == 0) return null;
        const pending = self.pending_caws.orderedRemove(0);
        defer self.freePendingCaw(pending);
        const current = self.blockSlice(self.visible, pending.block_index);
        if (!std.mem.eql(u8, current, pending.expected)) return .miscompare;
        @memcpy(current, pending.replacement);
        return .written;
    }

    pub fn completePendingWrite(self: *ModelBlockDevice) bool {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.pending_writes.items.len == 0) return false;
        const pending = self.pending_writes.orderedRemove(0);
        defer self.allocator.free(pending.bytes);
        @memcpy(self.range(self.visible, pending.first_block, pending.bytes.len), pending.bytes);
        return true;
    }

    pub fn crash(self: *ModelBlockDevice) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        @memcpy(self.visible, self.stable);
        for (self.pending_caws.items) |pending| self.freePendingCaw(pending);
        for (self.pending_writes.items) |pending| self.allocator.free(pending.bytes);
        self.pending_caws.clearRetainingCapacity();
        self.pending_writes.clearRetainingCapacity();
        self.next_caw_fault = .none;
        self.next_data_fault = .none;
        self.fail_next_stabilize = false;
        self.reset_before_next_stabilize = false;
        self.reset_epoch += 1;
    }

    fn readBlock(context: *anyopaque, block_index: u64, output: []u8) !void {
        const self: *ModelBlockDevice = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        @memcpy(output, self.blockSlice(self.visible, block_index));
    }

    fn compareAndWrite(
        context: *anyopaque,
        block_index: u64,
        expected: []const u8,
        replacement: []const u8,
    ) !conditional.CawResult {
        const self: *ModelBlockDevice = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        return self.compareAndWriteLocked(block_index, expected, replacement);
    }

    fn compareAndWriteAtEpoch(
        context: *anyopaque,
        reset_epoch: u64,
        block_index: u64,
        expected: []const u8,
        replacement: []const u8,
    ) !conditional.CawResult {
        const self: *ModelBlockDevice = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (reset_epoch != self.reset_epoch) return error.DeviceReset;
        return self.compareAndWriteLocked(block_index, expected, replacement);
    }

    fn compareAndWriteLocked(
        self: *ModelBlockDevice,
        block_index: u64,
        expected: []const u8,
        replacement: []const u8,
    ) !conditional.CawResult {
        self.caw_count += 1;
        const current = self.blockSlice(self.visible, block_index);
        if (!std.mem.eql(u8, current, expected)) return .miscompare;
        const fault = self.takeCawFault();
        switch (fault) {
            .none => {
                @memcpy(current, replacement);
                return .written;
            },
            .error_before_dispatch => return error.InjectedCawFailure,
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
                try self.pending_caws.append(self.allocator, .{
                    .block_index = block_index,
                    .expected = expected_copy,
                    .replacement = replacement_copy,
                });
                return .indeterminate;
            },
        }
    }

    fn readBlocks(context: *anyopaque, first_block: u64, output: []u8) !void {
        const self: *ModelBlockDevice = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        @memcpy(output, self.range(self.visible, first_block, output.len));
    }

    fn writeBlocks(context: *anyopaque, first_block: u64, input: []const u8) !data.WriteResult {
        const self: *ModelBlockDevice = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        const target = self.range(self.visible, first_block, input.len);
        const fault = self.takeDataFault();
        switch (fault) {
            .none => {
                @memcpy(target, input);
                return .written;
            },
            .indeterminate_no_write => return .indeterminate,
            .indeterminate_after_write => {
                @memcpy(target, input);
                return .indeterminate;
            },
            .indeterminate_pending => {
                const copy = try self.allocator.dupe(u8, input);
                errdefer self.allocator.free(copy);
                try self.pending_writes.append(self.allocator, .{ .first_block = first_block, .bytes = copy });
                return .indeterminate;
            },
        }
    }

    fn stabilize(context: *anyopaque) !void {
        const self: *ModelBlockDevice = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.reset_before_next_stabilize) {
            self.reset_before_next_stabilize = false;
            @memcpy(self.visible, self.stable);
            for (self.pending_caws.items) |pending| self.freePendingCaw(pending);
            for (self.pending_writes.items) |pending| self.allocator.free(pending.bytes);
            self.pending_caws.clearRetainingCapacity();
            self.pending_writes.clearRetainingCapacity();
            self.next_caw_fault = .none;
            self.next_data_fault = .none;
            self.reset_epoch += 1;
        }
        if (self.fail_next_stabilize) {
            self.fail_next_stabilize = false;
            return error.InjectedStabilizeFailure;
        }
        @memcpy(self.stable, self.visible);
    }

    fn resetEpoch(context: *anyopaque) u64 {
        const self: *ModelBlockDevice = @ptrCast(@alignCast(context));
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        return self.reset_epoch;
    }

    fn takeCawFault(self: *ModelBlockDevice) CawFault {
        if (self.next_caw_fault == .none) return .none;
        if (self.caws_until_fault != 0) {
            self.caws_until_fault -= 1;
            return .none;
        }
        const fault = self.next_caw_fault;
        self.next_caw_fault = .none;
        return fault;
    }

    fn takeDataFault(self: *ModelBlockDevice) DataFault {
        if (self.next_data_fault == .none) return .none;
        if (self.writes_until_fault != 0) {
            self.writes_until_fault -= 1;
            return .none;
        }
        const fault = self.next_data_fault;
        self.next_data_fault = .none;
        return fault;
    }

    fn blockSlice(self: *const ModelBlockDevice, bytes: []u8, block_index: u64) []u8 {
        return self.range(bytes, block_index, self.geometry.logical_block_size);
    }

    fn range(self: *const ModelBlockDevice, bytes: []u8, first_block: u64, len: usize) []u8 {
        const start: usize = @intCast(first_block * self.geometry.logical_block_size);
        return bytes[start .. start + len];
    }

    fn freePendingCaw(self: *ModelBlockDevice, pending: PendingCaw) void {
        self.allocator.free(pending.expected);
        self.allocator.free(pending.replacement);
    }

    const conditional_vtable = conditional.ConditionalBlockTransport.VTable{
        .read_block = readBlock,
        .compare_and_write = compareAndWrite,
        .compare_and_write_at_epoch = compareAndWriteAtEpoch,
        .stabilize = stabilize,
        .reset_epoch = resetEpoch,
    };
    const data_vtable = data.DataBlockTransport.VTable{
        .read_blocks = readBlocks,
        .write_blocks = writeBlocks,
        .stabilize = stabilize,
    };
};

test "conditional and ordinary transports share visibility and durability" {
    var model = try ModelBlockDevice.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 2,
    });
    defer model.deinit();
    const ordinary = model.dataTransport();
    const caw = model.conditionalTransport();
    const written: [512]u8 = @splat(7);
    _ = try ordinary.writeBlocks(1, &written);
    var observed: [512]u8 = undefined;
    try caw.readBlock(1, &observed);
    try std.testing.expectEqualSlices(u8, &written, &observed);

    try ordinary.stabilize();
    model.crash();
    @memset(&observed, 0);
    try ordinary.readBlocks(1, &observed);
    try std.testing.expectEqualSlices(u8, &written, &observed);
}

test "one shared crash rolls back both transport views" {
    var model = try ModelBlockDevice.init(std.testing.allocator, .{
        .logical_block_size = 4096,
        .block_count = 2,
    });
    defer model.deinit();
    const ordinary = model.dataTransport();
    const caw = model.conditionalTransport();
    const first = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(first);
    const zero = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(zero);
    @memset(first, 1);
    @memset(zero, 0);
    _ = try ordinary.writeBlocks(0, first);
    try std.testing.expectEqual(conditional.CawResult.written, try caw.compareAndWrite(1, zero, first));
    model.crash();
    try ordinary.readBlocks(0, first);
    try caw.readBlock(1, zero);
    try std.testing.expect(std.mem.allEqual(u8, first, 0));
    try std.testing.expect(std.mem.allEqual(u8, zero, 0));
}

test "delayed ordinary write can overwrite a successor" {
    var model = try ModelBlockDevice.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 1,
    });
    defer model.deinit();
    const transport = model.dataTransport();
    const delayed: [512]u8 = @splat(1);
    const successor: [512]u8 = @splat(2);
    model.injectNextDataFault(.indeterminate_pending);
    try std.testing.expectEqual(
        data.WriteResult.indeterminate,
        try transport.writeBlocks(0, &delayed),
    );
    try std.testing.expectEqual(
        data.WriteResult.written,
        try transport.writeBlocks(0, &successor),
    );
    try std.testing.expect(model.completePendingWrite());

    var output: [512]u8 = undefined;
    try transport.readBlocks(0, &output);
    try std.testing.expectEqualSlices(u8, &delayed, &output);
}

test "ordinary writes report pre and post-write indeterminate outcomes" {
    var model = try ModelBlockDevice.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = 1,
    });
    defer model.deinit();
    const transport = model.dataTransport();
    const input: [512]u8 = @splat(3);

    model.injectNextDataFault(.indeterminate_no_write);
    try std.testing.expectEqual(
        data.WriteResult.indeterminate,
        try transport.writeBlocks(0, &input),
    );
    var output: [512]u8 = undefined;
    try transport.readBlocks(0, &output);
    try std.testing.expectEqual(@as(u8, 0), output[0]);

    model.injectNextDataFault(.indeterminate_after_write);
    try std.testing.expectEqual(
        data.WriteResult.indeterminate,
        try transport.writeBlocks(0, &input),
    );
    try transport.readBlocks(0, &output);
    try std.testing.expectEqual(@as(u8, 3), output[0]);
}
