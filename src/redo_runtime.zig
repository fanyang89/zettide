const std = @import("std");
const Io = std.Io;
const File = Io.File;
const container = @import("container.zig");
const redo_journal = @import("redo_journal.zig");

const Image = [redo_journal.block_size]u8;
const ImageMap = std.AutoHashMap(u32, *Image);

pub const DurableSync = struct {
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque) anyerror!void,

    pub fn run(sync: DurableSync) !void {
        try sync.runFn(sync.context);
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
    file: File,
    payload_start: u64,
    block_count: u32,
    descriptor: container.RedoJournal,
    active: ImageMap,
    committed: ImageMap,
    active_transaction: bool = false,
    append_offset: u64 = 0,
    tail_sequence: u64 = 0,
    tail_digest: redo_journal.Digest = redo_journal.zero_digest,
    unresolved_tail_damage: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        file: File,
        header: container.Header,
    ) !Runtime {
        const descriptor = header.redo_journal orelse return error.MissingRedoJournal;
        try descriptor.validate(
            std.math.add(u64, header.payload_start, header.logical_size) catch
                return error.InvalidRedoJournal,
            header.block_size,
        );
        if (header.block_size != redo_journal.block_size) return error.UnsupportedRedoJournal;
        var result: Runtime = .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .payload_start = header.payload_start,
            .block_count = header.block_count,
            .descriptor = descriptor,
            .active = ImageMap.init(allocator),
            .committed = ImageMap.init(allocator),
        };
        errdefer result.deinit();
        try result.active.ensureTotalCapacity(descriptor.max_transaction_blocks);
        try result.recover();
        return result;
    }

    pub fn deinit(self: *Runtime) void {
        self.freeImages(&self.active);
        self.freeImages(&self.committed);
        self.active.deinit();
        self.committed.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Runtime) !void {
        if (self.active_transaction) return error.TransactionAlreadyActive;
        if (self.unresolved_tail_damage or self.remainingCapacity() < try self.maximumTransactionSize())
            return error.CheckpointRequired;
        std.debug.assert(self.active.count() == 0);
        self.active_transaction = true;
    }

    pub fn abort(self: *Runtime) void {
        self.freeImages(&self.active);
        self.active.clearRetainingCapacity();
        self.active_transaction = false;
    }

    pub fn read(self: *Runtime, block: u32, offset: u32, buffer: []u8) !void {
        try self.validateRange(block, offset, buffer.len);
        if (self.active.get(block)) |image| {
            @memcpy(buffer, image[offset..][0..buffer.len]);
            return;
        }
        if (self.committed.get(block)) |image| {
            @memcpy(buffer, image[offset..][0..buffer.len]);
            return;
        }
        const amount = try self.file.readPositionalAll(
            self.io,
            buffer,
            try self.homePosition(block, offset),
        );
        if (amount != buffer.len) return error.UnexpectedEndOfFile;
    }

    pub fn program(self: *Runtime, block: u32, offset: u32, data: []const u8) !void {
        if (!self.active_transaction) return error.NoActiveTransaction;
        try self.validateRange(block, offset, data.len);
        const entry = try self.active.getOrPut(block);
        if (!entry.found_existing) {
            if (self.active.count() > self.descriptor.max_transaction_blocks) {
                _ = self.active.remove(block);
                return error.TransactionTooLarge;
            }
            const image = try self.allocator.create(Image);
            errdefer self.allocator.destroy(image);
            if (self.committed.get(block)) |committed|
                image.* = committed.*
            else {
                const amount = try self.file.readPositionalAll(
                    self.io,
                    image,
                    try self.homePosition(block, 0),
                );
                if (amount != image.len) return error.UnexpectedEndOfFile;
            }
            entry.value_ptr.* = image;
        }
        @memcpy(entry.value_ptr.*[offset..][0..data.len], data);
    }

    pub fn logicalSync(self: *Runtime) !void {
        if (!self.active_transaction and self.active.count() != 0)
            return error.InvalidTransactionState;
    }

    pub fn commit(self: *Runtime, durable_sync: DurableSync) !void {
        if (!self.active_transaction) return error.NoActiveTransaction;
        if (self.active.count() == 0) {
            self.active_transaction = false;
            return;
        }
        const ids = try self.sortedIds(&self.active);
        defer self.allocator.free(ids);
        const blocks = try self.allocator.alloc(redo_journal.BlockImage, ids.len);
        defer self.allocator.free(blocks);
        for (ids, blocks) |id, *block| block.* = .{
            .block = id,
            .bytes = self.active.get(id).?,
        };
        const next_sequence = std.math.add(u64, self.tail_sequence, 1) catch
            return error.SequenceOverflow;
        const encoded = try redo_journal.encode(self.allocator, .{
            .sequence = next_sequence,
            .previous_digest = self.tail_digest,
        }, blocks);
        defer self.allocator.free(encoded);
        if (encoded.len > self.remainingCapacity()) return error.JournalFull;
        try self.committed.ensureUnusedCapacity(@intCast(self.active.count()));
        try self.file.writePositionalAll(
            self.io,
            encoded,
            try self.journalPosition(self.append_offset),
        );
        try durable_sync.run();

        for (ids) |id| {
            const image = self.active.get(id).?;
            if (self.committed.getPtr(id)) |existing| {
                self.allocator.destroy(existing.*);
                existing.* = image;
            } else {
                self.committed.putAssumeCapacity(id, image);
            }
        }
        self.active.clearRetainingCapacity();
        self.active_transaction = false;
        self.append_offset += encoded.len;
        self.tail_sequence = next_sequence;
        self.tail_digest = redo_journal.encodedDigest(encoded);
    }

    pub fn checkpoint(self: *Runtime, durable_sync: DurableSync) !void {
        if (self.active_transaction) return error.TransactionActive;
        if (self.committed.count() != 0) {
            const ids = try self.sortedIds(&self.committed);
            defer self.allocator.free(ids);
            for (ids) |id| try self.file.writePositionalAll(
                self.io,
                self.committed.get(id).?,
                try self.homePosition(id, 0),
            );
            try durable_sync.run();
        }
        if (self.append_offset != 0 or self.unresolved_tail_damage) {
            const zero: [redo_journal.block_size]u8 = @splat(0);
            var offset: u64 = 0;
            const clear_length = if (self.unresolved_tail_damage)
                self.dataCapacity()
            else
                std.mem.alignForward(u64, self.append_offset, redo_journal.block_size);
            while (offset < clear_length) : (offset += zero.len) {
                const amount: usize = @intCast(@min(@as(u64, zero.len), clear_length - offset));
                try self.file.writePositionalAll(
                    self.io,
                    zero[0..amount],
                    try self.journalPosition(offset),
                );
            }
            try durable_sync.run();
        }
        self.freeImages(&self.committed);
        self.committed.clearRetainingCapacity();
        self.append_offset = 0;
        self.tail_sequence = 0;
        self.tail_digest = redo_journal.zero_digest;
        self.unresolved_tail_damage = false;
    }

    pub fn needsCheckpoint(self: *Runtime) !bool {
        return self.unresolved_tail_damage or self.remainingCapacity() < try self.maximumTransactionSize();
    }

    fn recover(self: *Runtime) !void {
        var prefix: [redo_journal.alignment]u8 = undefined;
        while (self.append_offset < self.dataCapacity()) {
            const remaining = self.dataCapacity() - self.append_offset;
            if (remaining < prefix.len) {
                self.unresolved_tail_damage = true;
                return;
            }
            const amount = try self.file.readPositionalAll(
                self.io,
                &prefix,
                try self.journalPosition(self.append_offset),
            );
            if (amount != prefix.len) return error.TruncatedRedoJournal;
            const transaction_length = redo_journal.transactionLength(&prefix) catch {
                self.unresolved_tail_damage = true;
                return;
            } orelse return;
            if (transaction_length > remaining) {
                self.unresolved_tail_damage = true;
                return;
            }
            const encoded = try self.allocator.alloc(u8, transaction_length);
            defer self.allocator.free(encoded);
            const read_amount = try self.file.readPositionalAll(
                self.io,
                encoded,
                try self.journalPosition(self.append_offset),
            );
            if (read_amount != encoded.len) return error.TruncatedRedoJournal;
            var transaction = redo_journal.decode(
                self.allocator,
                encoded,
                self.block_count,
            ) catch {
                self.unresolved_tail_damage = true;
                return;
            };
            defer transaction.deinit();
            const expected_sequence = std.math.add(u64, self.tail_sequence, 1) catch
                return error.SequenceOverflow;
            if (transaction.sequence != expected_sequence)
                return error.TransactionSequenceGap;
            if (!std.mem.eql(u8, &transaction.previous_digest, &self.tail_digest))
                return error.PreviousTransactionDigestMismatch;
            try self.committed.ensureUnusedCapacity(@intCast(transaction.blocks.len));
            for (transaction.blocks) |block| try self.putCommitted(block.block, block.bytes);
            self.append_offset += transaction.encoded_length;
            self.tail_sequence = transaction.sequence;
            self.tail_digest = transaction.encoded_digest;
        }
    }

    fn putCommitted(self: *Runtime, block: u32, bytes: []const u8) !void {
        if (self.committed.get(block)) |image| {
            @memcpy(image, bytes);
            return;
        }
        const image = try self.allocator.create(Image);
        errdefer self.allocator.destroy(image);
        @memcpy(image, bytes);
        self.committed.putAssumeCapacity(block, image);
    }

    fn sortedIds(self: *Runtime, map: *const ImageMap) ![]u32 {
        const ids = try self.allocator.alloc(u32, map.count());
        var iterator = map.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |id| : (index += 1) ids[index] = id.*;
        std.mem.sort(u32, ids, {}, std.sort.asc(u32));
        return ids;
    }

    fn freeImages(self: *Runtime, map: *ImageMap) void {
        var iterator = map.valueIterator();
        while (iterator.next()) |image| self.allocator.destroy(image.*);
    }

    fn validateRange(self: *const Runtime, block: u32, offset: u32, length: usize) !void {
        if (block >= self.block_count or offset > redo_journal.block_size or
            length > redo_journal.block_size - offset)
            return error.OutOfBounds;
    }

    fn homePosition(self: *const Runtime, block: u32, offset: u32) !u64 {
        const block_offset = std.math.mul(u64, block, redo_journal.block_size) catch
            return error.OutOfBounds;
        return std.math.add(u64, self.payload_start, block_offset + offset) catch
            error.OutOfBounds;
    }

    fn journalPosition(self: *const Runtime, offset: u64) !u64 {
        const data_start = std.math.add(u64, self.descriptor.offset, redo_journal.data_offset) catch
            return error.InvalidRedoJournal;
        return std.math.add(u64, data_start, offset) catch error.InvalidRedoJournal;
    }

    fn dataCapacity(self: *const Runtime) u64 {
        return self.descriptor.length - redo_journal.data_offset;
    }

    fn remainingCapacity(self: *const Runtime) u64 {
        return self.dataCapacity() - self.append_offset;
    }

    fn maximumTransactionSize(self: *const Runtime) !u64 {
        return redo_journal.encodedSize(self.descriptor.max_transaction_blocks);
    }
};

const TestSync = struct {
    io: Io,
    file: File,
    count: u64 = 0,

    fn callback(raw: *anyopaque) !void {
        const self: *TestSync = @ptrCast(@alignCast(raw));
        try self.file.sync(self.io);
        self.count += 1;
    }

    fn durable(self: *TestSync) DurableSync {
        return .{ .context = self, .runFn = callback };
    }
};

test "redo runtime commits once and recovers through the overlay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "runtime.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "Runtime");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));

    var sync_state: TestSync = .{ .io = std.testing.io, .file = file };
    {
        var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
        defer runtime.deinit();
        try runtime.begin();
        try runtime.program(3, 100, "durable");
        try runtime.logicalSync();
        try runtime.commit(sync_state.durable());
        try std.testing.expectEqual(@as(u64, 1), sync_state.count);

        var actual: [7]u8 = undefined;
        try runtime.read(3, 100, &actual);
        try std.testing.expectEqualStrings("durable", &actual);
        var home: [7]u8 = undefined;
        _ = try file.readPositionalAll(
            std.testing.io,
            &home,
            header.payload_start + 3 * redo_journal.block_size + 100,
        );
        try std.testing.expectEqualSlices(u8, &@as([7]u8, @splat(0)), &home);
    }

    {
        var recovered = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
        defer recovered.deinit();
        var actual: [7]u8 = undefined;
        try recovered.read(3, 100, &actual);
        try std.testing.expectEqualStrings("durable", &actual);
        try recovered.checkpoint(sync_state.durable());
        try std.testing.expectEqual(@as(u64, 3), sync_state.count);
    }

    {
        var checkpointed = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
        defer checkpointed.deinit();
        var actual: [7]u8 = undefined;
        try checkpointed.read(3, 100, &actual);
        try std.testing.expectEqualStrings("durable", &actual);
        try std.testing.expectEqual(@as(u64, 0), checkpointed.tail_sequence);
    }
}

test "redo runtime abort discards active block images" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "abort.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "Abort");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));

    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer runtime.deinit();
    try runtime.begin();
    try runtime.program(1, 0, "discarded");
    runtime.abort();
    var actual: [9]u8 = undefined;
    try runtime.read(1, 0, &actual);
    try std.testing.expectEqualSlices(u8, &@as([9]u8, @splat(0)), &actual);
}
