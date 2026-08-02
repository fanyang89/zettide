const std = @import("std");
const Io = std.Io;
const File = Io.File;
const container = @import("container.zig");
const file_io = @import("file_io.zig");
const redo_journal = @import("redo_journal.zig");
const google_crc32c = @import("crc32c");

const Image = [redo_journal.block_size]u8;
const ImageMap = std.AutoHashMap(u32, *Image);
const PendingRecord = struct {
    offset: u64,
    bytes: []u8,
};
pub const AnchorSlot = enum(u1) { a, b };

pub const DurableSync = struct {
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque) anyerror!void,

    pub fn run(sync: DurableSync) !void {
        try sync.runFn(sync.context);
    }
};

pub const Flush = struct {
    anchor: redo_journal.Anchor,
    slot: AnchorSlot,
};

pub const PreparedFlush = struct {
    allocator: std.mem.Allocator,
    flush: Flush,
    writes: std.ArrayList(file_io.Write),
    records: std.ArrayList(PendingRecord),
    anchor_bytes: [redo_journal.anchor_size]u8,
    anchor_position: u64,

    pub fn execute(
        self: *const PreparedFlush,
        io: Io,
        backend: file_io.BorrowedFileIo,
        durable_sync: DurableSync,
    ) !void {
        try backend.writeAllManyAt(io, .writeback, self.writes.items);
        try backend.writeAllAt(io, .writeback, &self.anchor_bytes, self.anchor_position);
        try durable_sync.run();
    }

    pub fn deinit(self: *PreparedFlush) void {
        for (self.records.items) |record| self.allocator.free(record.bytes);
        self.records.deinit(self.allocator);
        self.writes.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
    file_io: file_io.BorrowedFileIo,
    payload_start: u64,
    block_count: u32,
    descriptor: container.RedoJournal,
    active: ImageMap,
    pending: ImageMap,
    flushing: ImageMap,
    committed: ImageMap,
    pending_records: std.ArrayList(PendingRecord) = .empty,
    active_transaction: bool = false,
    anchor_slot: ?AnchorSlot = null,
    anchor_generation: u64 = 0,
    head_offset: u64 = 0,
    used_bytes: u64 = 0,
    tail_sequence: u64 = 0,
    tail_digest: redo_journal.Digest = redo_journal.zero_digest,
    staged_used_bytes: u64 = 0,
    staged_tail_sequence: u64 = 0,
    staged_tail_digest: redo_journal.Digest = redo_journal.zero_digest,
    inflight_flush: ?Flush = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        file: File,
        header: container.Header,
    ) !Runtime {
        return initWithFileIo(allocator, io, file_io.FileIo.posix(file).borrow(), header);
    }

    pub fn initWithFileIo(
        allocator: std.mem.Allocator,
        io: Io,
        backend: file_io.BorrowedFileIo,
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
            .file_io = backend,
            .payload_start = header.payload_start,
            .block_count = header.block_count,
            .descriptor = descriptor,
            .active = ImageMap.init(allocator),
            .pending = ImageMap.init(allocator),
            .flushing = ImageMap.init(allocator),
            .committed = ImageMap.init(allocator),
        };
        errdefer result.deinit();
        try result.active.ensureTotalCapacity(descriptor.max_transaction_blocks);
        try result.recover();
        return result;
    }

    pub fn deinit(self: *Runtime) void {
        self.freeImages(&self.active);
        self.freeImages(&self.pending);
        self.freeImages(&self.flushing);
        self.freeImages(&self.committed);
        self.freePendingRecords();
        self.active.deinit();
        self.pending.deinit();
        self.flushing.deinit();
        self.committed.deinit();
        self.pending_records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn begin(self: *Runtime) !void {
        if (self.active_transaction) return error.TransactionAlreadyActive;
        if (self.remainingCapacity() < try self.maximumTransactionSize())
            return error.CheckpointRequired;
        std.debug.assert(self.active.count() == 0);
        self.active_transaction = true;
    }

    pub fn abort(self: *Runtime) void {
        self.freeImages(&self.active);
        self.active.clearRetainingCapacity();
        self.active_transaction = false;
    }

    pub fn hasActiveWrites(self: *const Runtime) bool {
        return self.active.count() != 0;
    }

    pub fn hasUndurableWrites(self: *const Runtime) bool {
        return self.active.count() != 0 or self.pending.count() != 0 or self.flushing.count() != 0;
    }

    pub fn hasPendingWrites(self: *const Runtime) bool {
        return self.pending.count() != 0 or self.flushing.count() != 0;
    }

    pub fn hasActiveTransaction(self: *const Runtime) bool {
        return self.active_transaction;
    }

    pub fn read(self: *Runtime, block: u32, offset: u32, buffer: []u8) !void {
        try self.validateRange(block, offset, buffer.len);
        if (self.active.get(block)) |image| {
            @memcpy(buffer, image[offset..][0..buffer.len]);
            return;
        }
        if (self.pending.get(block)) |image| {
            @memcpy(buffer, image[offset..][0..buffer.len]);
            return;
        }
        if (self.flushing.get(block)) |image| {
            @memcpy(buffer, image[offset..][0..buffer.len]);
            return;
        }
        if (self.committed.get(block)) |image| {
            @memcpy(buffer, image[offset..][0..buffer.len]);
            return;
        }
        try self.file_io.readAllAt(self.io, .foreground, buffer, try self.homePosition(block, offset));
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
            errdefer std.debug.assert(self.active.remove(block));
            const image = try self.allocator.create(Image);
            errdefer self.allocator.destroy(image);
            if (self.pending.get(block)) |pending|
                image.* = pending.*
            else if (self.flushing.get(block)) |flushing|
                image.* = flushing.*
            else if (self.committed.get(block)) |committed|
                image.* = committed.*
            else {
                try self.file_io.readAllAt(self.io, .foreground, image, try self.homePosition(block, 0));
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
        _ = try self.stage();
        var prepared = (try self.seal()) orelse return;
        defer prepared.deinit();
        try prepared.execute(self.io, self.file_io, durable_sync);
        try self.completeFlush(prepared.flush);
    }

    pub fn stage(self: *Runtime) !?u64 {
        if (!self.active_transaction) return error.NoActiveTransaction;
        if (self.active.count() == 0) {
            self.active_transaction = false;
            return null;
        }
        if (self.pending.count() == 0) {
            const base_generation = if (self.inflight_flush) |flush|
                flush.anchor.generation
            else
                self.anchor_generation;
            _ = std.math.add(u64, base_generation, 1) catch return error.GenerationOverflow;
        }
        const ids = try self.sortedIds(&self.active);
        defer self.allocator.free(ids);
        const blocks = try self.allocator.alloc(redo_journal.BlockImage, ids.len);
        defer self.allocator.free(blocks);
        for (ids, blocks) |id, *block| block.* = .{
            .block = id,
            .bytes = self.active.get(id).?,
        };
        const next_sequence = std.math.add(u64, self.staged_tail_sequence, 1) catch
            return error.SequenceOverflow;
        try self.pending.ensureUnusedCapacity(@intCast(self.active.count()));
        try self.pending_records.ensureUnusedCapacity(self.allocator, 1);
        const encoded = try redo_journal.encode(self.allocator, .{
            .sequence = next_sequence,
            .previous_digest = self.staged_tail_digest,
        }, blocks);
        errdefer self.allocator.free(encoded);
        if (encoded.len > self.remainingCapacity()) return error.JournalFull;
        const next_digest = redo_journal.encodedDigest(encoded);
        const record_offset = self.stagedTailOffset();

        for (ids) |id| {
            const image = self.active.get(id).?;
            if (self.pending.getPtr(id)) |existing| {
                self.allocator.destroy(existing.*);
                existing.* = image;
            } else {
                self.pending.putAssumeCapacity(id, image);
            }
        }
        self.active.clearRetainingCapacity();
        self.active_transaction = false;
        self.staged_used_bytes += encoded.len;
        self.staged_tail_sequence = next_sequence;
        self.staged_tail_digest = next_digest;
        self.pending_records.appendAssumeCapacity(.{
            .offset = record_offset,
            .bytes = encoded,
        });
        return next_sequence;
    }

    pub fn seal(self: *Runtime) !?PreparedFlush {
        if (self.inflight_flush != null or self.flushing.count() != 0) return error.FlushInProgress;
        if (self.pending.count() == 0) return null;
        try self.committed.ensureUnusedCapacity(@intCast(self.pending.count()));
        var writes: std.ArrayList(file_io.Write) = .empty;
        errdefer writes.deinit(self.allocator);
        const write_capacity = std.math.mul(usize, self.pending_records.items.len, 2) catch
            return error.OutOfMemory;
        try writes.ensureTotalCapacity(self.allocator, write_capacity);
        for (self.pending_records.items) |record|
            try self.appendRingWrites(&writes, record.offset, record.bytes);
        const next_generation = std.math.add(u64, self.anchor_generation, 1) catch
            return error.GenerationOverflow;
        const flush: Flush = .{
            .anchor = .{
                .generation = next_generation,
                .head_offset = self.head_offset,
                .used_bytes = self.staged_used_bytes,
                .tail_sequence = self.staged_tail_sequence,
                .tail_digest = self.staged_tail_digest,
            },
            .slot = self.nextAnchorSlot(),
        };
        const anchor_bytes = try redo_journal.encodeAnchor(flush.anchor, self.dataCapacity());
        const anchor_position = try self.anchorPosition(flush.slot);
        const records = self.pending_records;
        self.pending_records = .empty;
        std.mem.swap(ImageMap, &self.pending, &self.flushing);
        self.inflight_flush = flush;
        return .{
            .allocator = self.allocator,
            .flush = flush,
            .writes = writes,
            .records = records,
            .anchor_bytes = anchor_bytes,
            .anchor_position = anchor_position,
        };
    }

    pub fn inflightFlush(self: *const Runtime) ?Flush {
        return self.inflight_flush;
    }

    pub fn completeFlush(self: *Runtime, flush: Flush) !void {
        if (self.inflight_flush == null or !std.meta.eql(self.inflight_flush.?, flush))
            return error.InvalidFlush;
        if (self.flushing.count() == 0) return error.InvalidFlush;
        var iterator = self.flushing.iterator();
        while (iterator.next()) |entry| {
            const id = entry.key_ptr.*;
            const image = entry.value_ptr.*;
            if (self.committed.getPtr(id)) |existing| {
                self.allocator.destroy(existing.*);
                existing.* = image;
            } else {
                self.committed.putAssumeCapacity(id, image);
            }
        }
        self.flushing.clearRetainingCapacity();
        self.anchor_slot = flush.slot;
        self.anchor_generation = flush.anchor.generation;
        self.used_bytes = flush.anchor.used_bytes;
        self.tail_sequence = flush.anchor.tail_sequence;
        self.tail_digest = flush.anchor.tail_digest;
        self.inflight_flush = null;
    }

    pub fn checkpoint(self: *Runtime, durable_sync: DurableSync) !void {
        if (self.active_transaction) return error.TransactionActive;
        if (self.hasPendingWrites()) return error.PendingTransactions;
        if (self.committed.count() != 0) {
            const ids = try self.sortedIds(&self.committed);
            defer self.allocator.free(ids);
            for (ids) |id| try self.file_io.writeAllAt(
                self.io,
                .writeback,
                self.committed.get(id).?,
                try self.homePosition(id, 0),
            );
            try durable_sync.run();
        }
        if (self.used_bytes != 0) {
            const next_generation = std.math.add(u64, self.anchor_generation, 1) catch
                return error.GenerationOverflow;
            const next_anchor: redo_journal.Anchor = .{
                .generation = next_generation,
                .head_offset = self.tailOffset(),
                .used_bytes = 0,
                .tail_sequence = 0,
                .tail_digest = redo_journal.zero_digest,
            };
            const next_slot = self.nextAnchorSlot();
            const anchor_bytes = try redo_journal.encodeAnchor(next_anchor, self.dataCapacity());
            try self.file_io.writeAllAt(
                self.io,
                .writeback,
                &anchor_bytes,
                try self.anchorPosition(next_slot),
            );
            try durable_sync.run();
            self.anchor_slot = next_slot;
            self.anchor_generation = next_generation;
            self.head_offset = next_anchor.head_offset;
            self.used_bytes = 0;
            self.tail_sequence = 0;
            self.tail_digest = redo_journal.zero_digest;
            self.staged_used_bytes = 0;
            self.staged_tail_sequence = 0;
            self.staged_tail_digest = redo_journal.zero_digest;
        }
        self.freeImages(&self.committed);
        self.committed.clearRetainingCapacity();
    }

    pub fn needsCheckpoint(self: *Runtime) !bool {
        return self.remainingCapacity() < try self.maximumTransactionSize();
    }

    pub fn checkpointRecommended(self: *Runtime) !bool {
        const threshold = std.math.mul(u64, try self.maximumTransactionSize(), 2) catch
            std.math.maxInt(u64);
        return self.remainingCapacity() < @min(self.dataCapacity(), threshold);
    }

    fn recover(self: *Runtime) !void {
        var encoded_anchors: [redo_journal.anchor_count][redo_journal.anchor_size]u8 = undefined;
        var anchors: [redo_journal.anchor_count]?redo_journal.Anchor = @splat(null);
        var zero_anchor: bool = false;
        for (&encoded_anchors, 0..) |*encoded, index| {
            self.file_io.readAllAt(
                self.io,
                .foreground,
                encoded,
                try self.anchorPosition(@enumFromInt(index)),
            ) catch |err| switch (err) {
                error.UnexpectedEndOfFile => return error.TruncatedRedoJournal,
                else => return err,
            };
            zero_anchor = zero_anchor or std.mem.allEqual(u8, encoded, 0);
            anchors[index] = redo_journal.decodeAnchor(encoded, self.dataCapacity()) catch |err| switch (err) {
                error.InvalidRedoAnchorMagic,
                error.InvalidRedoAnchor,
                error.InvalidRedoAnchorChecksum,
                => null,
                else => return err,
            };
        }
        if (anchors[0] != null and anchors[1] != null and
            anchors[0].?.generation == anchors[1].?.generation and
            !std.meta.eql(anchors[0].?, anchors[1].?))
            return error.ConflictingRedoJournalAnchors;

        const first: ?AnchorSlot = if (anchors[0] == null)
            if (anchors[1] == null) null else .b
        else if (anchors[1] == null or anchors[0].?.generation >= anchors[1].?.generation)
            .a
        else
            .b;
        if (first) |slot| {
            if (try self.tryRecoverAnchor(slot, anchors[@intFromEnum(slot)].?)) return;
            const other: AnchorSlot = if (slot == .a) .b else .a;
            if (anchors[@intFromEnum(other)]) |anchor|
                if (try self.tryRecoverAnchor(other, anchor)) return;
        }
        if (zero_anchor) return;
        return error.NoValidRedoJournalAnchor;
    }

    fn tryRecoverAnchor(self: *Runtime, slot: AnchorSlot, anchor: redo_journal.Anchor) !bool {
        self.clearCommitted();
        self.replayAnchor(anchor) catch |err| switch (err) {
            error.TruncatedRecord,
            error.InvalidRecordMagic,
            error.InvalidRecordChecksum,
            error.InvalidRecordKind,
            error.InvalidBeginRecord,
            error.TransactionTooLarge,
            error.TruncatedTransaction,
            error.InvalidDataRecord,
            error.TargetBlockOutOfBounds,
            error.UnorderedTargetBlocks,
            error.InvalidPayloadDigest,
            error.InvalidCommitRecord,
            error.InvalidTransactionDigest,
            error.MissingAnchoredTransaction,
            error.AnchoredTransactionOutOfBounds,
            error.SequenceOverflow,
            error.TransactionSequenceGap,
            error.PreviousTransactionDigestMismatch,
            error.RedoJournalAnchorTailMismatch,
            => {
                self.clearCommitted();
                return false;
            },
            else => return err,
        };
        self.anchor_slot = slot;
        self.anchor_generation = anchor.generation;
        self.head_offset = anchor.head_offset;
        self.used_bytes = anchor.used_bytes;
        self.tail_sequence = anchor.tail_sequence;
        self.tail_digest = anchor.tail_digest;
        self.staged_used_bytes = anchor.used_bytes;
        self.staged_tail_sequence = anchor.tail_sequence;
        self.staged_tail_digest = anchor.tail_digest;
        return true;
    }

    fn replayAnchor(self: *Runtime, anchor: redo_journal.Anchor) !void {
        if (anchor.used_bytes == 0) return;
        var consumed: u64 = 0;
        var tail_sequence: u64 = 0;
        var tail_digest = redo_journal.zero_digest;
        while (consumed < anchor.used_bytes) {
            var prefix: [redo_journal.alignment]u8 = undefined;
            try self.readRing(self.ringAdvance(anchor.head_offset, consumed), &prefix);
            const transaction_length = (try redo_journal.transactionLength(&prefix)) orelse
                return error.MissingAnchoredTransaction;
            if (transaction_length > anchor.used_bytes - consumed)
                return error.AnchoredTransactionOutOfBounds;
            const encoded = try self.allocator.alloc(u8, transaction_length);
            defer self.allocator.free(encoded);
            try self.readRing(self.ringAdvance(anchor.head_offset, consumed), encoded);
            var transaction = try redo_journal.decode(self.allocator, encoded, self.block_count);
            defer transaction.deinit();
            const expected_sequence = std.math.add(u64, tail_sequence, 1) catch
                return error.SequenceOverflow;
            if (transaction.sequence != expected_sequence)
                return error.TransactionSequenceGap;
            if (!std.mem.eql(u8, &transaction.previous_digest, &tail_digest))
                return error.PreviousTransactionDigestMismatch;
            try self.committed.ensureUnusedCapacity(@intCast(transaction.blocks.len));
            for (transaction.blocks) |block| try self.putCommitted(block.block, block.bytes);
            consumed += transaction.encoded_length;
            tail_sequence = transaction.sequence;
            tail_digest = transaction.encoded_digest;
        }
        if (tail_sequence != anchor.tail_sequence or
            !std.mem.eql(u8, &tail_digest, &anchor.tail_digest))
            return error.RedoJournalAnchorTailMismatch;
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

    fn freePendingRecords(self: *Runtime) void {
        for (self.pending_records.items) |record| self.allocator.free(record.bytes);
        self.pending_records.clearRetainingCapacity();
    }

    fn clearCommitted(self: *Runtime) void {
        self.freeImages(&self.committed);
        self.committed.clearRetainingCapacity();
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

    fn anchorPosition(self: *const Runtime, slot: AnchorSlot) !u64 {
        const offset = std.math.mul(u64, @intFromEnum(slot), redo_journal.anchor_size) catch
            return error.InvalidRedoJournal;
        return std.math.add(u64, self.descriptor.offset, offset) catch error.InvalidRedoJournal;
    }

    fn readRing(self: *const Runtime, offset: u64, buffer: []u8) !void {
        if (offset >= self.dataCapacity() or buffer.len > self.dataCapacity())
            return error.InvalidRedoJournalRange;
        const first_length: usize = @intCast(@min(buffer.len, self.dataCapacity() - offset));
        self.file_io.readAllAt(
            self.io,
            .foreground,
            buffer[0..first_length],
            try self.journalPosition(offset),
        ) catch |err| switch (err) {
            error.UnexpectedEndOfFile => return error.TruncatedRedoJournal,
            else => return err,
        };
        if (first_length == buffer.len) return;
        self.file_io.readAllAt(
            self.io,
            .foreground,
            buffer[first_length..],
            try self.journalPosition(0),
        ) catch |err| switch (err) {
            error.UnexpectedEndOfFile => return error.TruncatedRedoJournal,
            else => return err,
        };
    }

    fn appendRingWrites(
        self: *const Runtime,
        writes: *std.ArrayList(file_io.Write),
        offset: u64,
        bytes: []const u8,
    ) !void {
        if (offset >= self.dataCapacity() or bytes.len > self.dataCapacity())
            return error.InvalidRedoJournalRange;
        const first_length: usize = @intCast(@min(bytes.len, self.dataCapacity() - offset));
        writes.appendAssumeCapacity(.{
            .bytes = bytes[0..first_length],
            .offset = try self.journalPosition(offset),
        });
        if (first_length != bytes.len)
            writes.appendAssumeCapacity(.{
                .bytes = bytes[first_length..],
                .offset = try self.journalPosition(0),
            });
    }

    fn dataCapacity(self: *const Runtime) u64 {
        return self.descriptor.length - redo_journal.data_offset;
    }

    fn remainingCapacity(self: *const Runtime) u64 {
        return self.dataCapacity() - self.staged_used_bytes;
    }

    fn tailOffset(self: *const Runtime) u64 {
        return self.ringAdvance(self.head_offset, self.used_bytes);
    }

    fn stagedTailOffset(self: *const Runtime) u64 {
        return self.ringAdvance(self.head_offset, self.staged_used_bytes);
    }

    fn ringAdvance(self: *const Runtime, offset: u64, amount: u64) u64 {
        std.debug.assert(offset < self.dataCapacity() and amount <= self.dataCapacity());
        const to_end = self.dataCapacity() - offset;
        return if (amount < to_end) offset + amount else amount - to_end;
    }

    fn nextAnchorSlot(self: *const Runtime) AnchorSlot {
        return if (self.anchor_slot == .a) .b else .a;
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

fn failSync(_: *anyopaque) !void {
    return error.InjectedFault;
}

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
        var journal_prefix: [redo_journal.alignment]u8 = undefined;
        _ = try file.readPositionalAll(
            std.testing.io,
            &journal_prefix,
            header.redo_journal.?.offset + redo_journal.data_offset,
        );
        try recovered.checkpoint(sync_state.durable());
        try std.testing.expectEqual(@as(u64, 3), sync_state.count);
        var checkpointed_prefix: [redo_journal.alignment]u8 = undefined;
        _ = try file.readPositionalAll(
            std.testing.io,
            &checkpointed_prefix,
            header.redo_journal.?.offset + redo_journal.data_offset,
        );
        try std.testing.expectEqualSlices(u8, &journal_prefix, &checkpointed_prefix);
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

test "redo runtime removes a block entry when loading its image fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "load-failure.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "LoadFailure");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));

    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer runtime.deinit();
    try file.setLength(std.testing.io, header.payload_start + 1);
    try runtime.begin();
    try std.testing.expectError(error.UnexpectedEndOfFile, runtime.program(1, 0, "unreadable"));
    runtime.abort();
    try std.testing.expectEqual(@as(u32, 0), runtime.active.count());
}

test "redo runtime flushes multiple staged transactions with one sync" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "staged.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "Staged");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var sync_state: TestSync = .{ .io = std.testing.io, .file = file };

    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer runtime.deinit();
    try runtime.begin();
    try runtime.program(1, 0, "first");
    try std.testing.expectEqual(@as(?u64, 1), try runtime.stage());
    try runtime.begin();
    try runtime.program(2, 0, "second");
    try std.testing.expectEqual(@as(?u64, 2), try runtime.stage());
    try std.testing.expectEqual(@as(u64, 0), sync_state.count);

    {
        var unflushed = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
        defer unflushed.deinit();
        var actual: [5]u8 = undefined;
        try unflushed.read(1, 0, &actual);
        try std.testing.expectEqualSlices(u8, &@as([5]u8, @splat(0)), &actual);
    }

    var prepared = (try runtime.seal()).?;
    defer prepared.deinit();
    try prepared.execute(std.testing.io, runtime.file_io, sync_state.durable());
    try runtime.completeFlush(prepared.flush);
    try std.testing.expectEqual(@as(u64, 1), sync_state.count);

    var recovered = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer recovered.deinit();
    var first: [5]u8 = undefined;
    var second: [6]u8 = undefined;
    try recovered.read(1, 0, &first);
    try recovered.read(2, 0, &second);
    try std.testing.expectEqualStrings("first", &first);
    try std.testing.expectEqualStrings("second", &second);
}

test "redo runtime collects the next cohort during a flush" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "cohorts.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "Cohorts");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var sync_state: TestSync = .{ .io = std.testing.io, .file = file };
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer runtime.deinit();

    try runtime.begin();
    try runtime.program(1, 0, "old");
    _ = try runtime.stage();
    var first_prepared = (try runtime.seal()).?;
    defer first_prepared.deinit();
    try runtime.begin();
    try runtime.program(1, 0, "new");
    _ = try runtime.stage();
    var visible: [3]u8 = undefined;
    try runtime.read(1, 0, &visible);
    try std.testing.expectEqualStrings("new", &visible);

    try first_prepared.execute(std.testing.io, runtime.file_io, sync_state.durable());
    try runtime.completeFlush(first_prepared.flush);
    try runtime.read(1, 0, &visible);
    try std.testing.expectEqualStrings("new", &visible);
    var second_prepared = (try runtime.seal()).?;
    defer second_prepared.deinit();
    try second_prepared.execute(std.testing.io, runtime.file_io, sync_state.durable());
    try runtime.completeFlush(second_prepared.flush);
    try std.testing.expectEqual(@as(u64, 2), sync_state.count);

    var recovered = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer recovered.deinit();
    try recovered.read(1, 0, &visible);
    try std.testing.expectEqualStrings("new", &visible);
}

test "redo runtime wraps transactions after checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "wrap.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "Wrap");
    try header.enableRedoJournal(20 * 1024, 1);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var sync_state: TestSync = .{ .io = std.testing.io, .file = file };

    {
        var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
        defer runtime.deinit();
        try runtime.begin();
        try runtime.program(1, 0, "first");
        try runtime.commit(sync_state.durable());
        try runtime.begin();
        try runtime.program(2, 0, "second");
        try runtime.commit(sync_state.durable());
        try std.testing.expect(try runtime.needsCheckpoint());

        try runtime.checkpoint(sync_state.durable());
        try std.testing.expectEqual(@as(u64, 4), sync_state.count);
        try std.testing.expectEqual(@as(u64, 11 * 1024), runtime.head_offset);
        try std.testing.expectEqual(@as(u64, 0), runtime.used_bytes);

        try runtime.begin();
        try runtime.program(3, 0, "wrapped");
        try runtime.commit(sync_state.durable());
        try std.testing.expectEqual(@as(u64, 5), sync_state.count);
        try std.testing.expectEqual(@as(u64, 11 * 1024), runtime.head_offset);
        try std.testing.expectEqual(@as(u64, 5632), runtime.used_bytes);
        try std.testing.expectEqual(@as(u64, 4608), runtime.tailOffset());
    }

    var recovered = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer recovered.deinit();
    var first: [5]u8 = undefined;
    var second: [6]u8 = undefined;
    var wrapped: [7]u8 = undefined;
    try recovered.read(1, 0, &first);
    try recovered.read(2, 0, &second);
    try recovered.read(3, 0, &wrapped);
    try std.testing.expectEqualStrings("first", &first);
    try std.testing.expectEqualStrings("second", &second);
    try std.testing.expectEqualStrings("wrapped", &wrapped);
    try std.testing.expectEqual(@as(u64, 11 * 1024), recovered.head_offset);
    try std.testing.expectEqual(@as(u64, 5632), recovered.used_bytes);
}

test "redo runtime falls back from a damaged newest anchor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "anchor-fallback.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "AnchorFallback");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var sync_state: TestSync = .{ .io = std.testing.io, .file = file };

    {
        var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
        defer runtime.deinit();
        try runtime.begin();
        try runtime.program(1, 0, "first");
        try runtime.commit(sync_state.durable());
        try runtime.begin();
        try runtime.program(2, 0, "second");
        try runtime.commit(sync_state.durable());
    }

    var damaged: [redo_journal.anchor_size]u8 = undefined;
    _ = try file.readPositionalAll(
        std.testing.io,
        &damaged,
        header.redo_journal.?.offset + redo_journal.anchor_size,
    );
    damaged[8] = 2;
    try file.writePositionalAll(
        std.testing.io,
        &damaged,
        header.redo_journal.?.offset + redo_journal.anchor_size,
    );
    try file.sync(std.testing.io);

    var recovered = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer recovered.deinit();
    var first: [5]u8 = undefined;
    var second: [6]u8 = undefined;
    try recovered.read(1, 0, &first);
    try recovered.read(2, 0, &second);
    try std.testing.expectEqualStrings("first", &first);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &second);
    try std.testing.expectEqual(@as(u64, 1), recovered.anchor_generation);
    try std.testing.expectEqual(AnchorSlot.a, recovered.anchor_slot.?);
}

test "redo runtime rejects an unsupported anchor version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "unsupported-anchor.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "UnsupportedAnchor");
    try header.enableRedoJournal(256 * 1024, 8);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var sync_state: TestSync = .{ .io = std.testing.io, .file = file };
    {
        var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
        defer runtime.deinit();
        try runtime.begin();
        try runtime.program(1, 0, "data");
        try runtime.commit(sync_state.durable());
    }

    var anchor: [redo_journal.anchor_size]u8 = undefined;
    _ = try file.readPositionalAll(std.testing.io, &anchor, header.redo_journal.?.offset);
    anchor[8] = 2;
    std.mem.writeInt(
        u32,
        anchor[redo_journal.anchor_size - @sizeOf(u32) ..][0..@sizeOf(u32)],
        google_crc32c.value(anchor[0 .. redo_journal.anchor_size - @sizeOf(u32)]),
        .little,
    );
    try file.writePositionalAll(std.testing.io, &anchor, header.redo_journal.?.offset);
    try file.sync(std.testing.io);
    try std.testing.expectError(
        error.UnsupportedRedoAnchorFormat,
        Runtime.init(std.testing.allocator, std.testing.io, file, header),
    );
}

test "redo runtime falls back after an interrupted wrapped commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "interrupted-wrap.ddv", .{ .read = true });
    defer file.close(std.testing.io);
    var header = try container.Header.init(std.testing.io, 1024 * 1024, "InterruptedWrap");
    try header.enableRedoJournal(20 * 1024, 1);
    header.state = .ready;
    try file.setLength(std.testing.io, try container.requiredFileSize(header));
    var sync_state: TestSync = .{ .io = std.testing.io, .file = file };
    {
        var runtime = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
        defer runtime.deinit();
        try runtime.begin();
        try runtime.program(1, 0, "first");
        try runtime.commit(sync_state.durable());
        try runtime.begin();
        try runtime.program(2, 0, "second");
        try runtime.commit(sync_state.durable());
        try runtime.checkpoint(sync_state.durable());

        try runtime.begin();
        try runtime.program(3, 0, "uncommitted");
        try std.testing.expectError(error.InjectedFault, runtime.commit(.{
            .context = &sync_state,
            .runFn = failSync,
        }));
    }

    const damaged_position = header.redo_journal.?.offset + redo_journal.data_offset + 32;
    var damaged: [1]u8 = undefined;
    _ = try file.readPositionalAll(std.testing.io, &damaged, damaged_position);
    damaged[0] ^= 1;
    try file.writePositionalAll(std.testing.io, &damaged, damaged_position);
    try file.sync(std.testing.io);

    var recovered = try Runtime.init(std.testing.allocator, std.testing.io, file, header);
    defer recovered.deinit();
    var first: [5]u8 = undefined;
    var uncommitted: [11]u8 = undefined;
    try recovered.read(1, 0, &first);
    try recovered.read(3, 0, &uncommitted);
    try std.testing.expectEqualStrings("first", &first);
    try std.testing.expectEqualSlices(u8, &@as([11]u8, @splat(0)), &uncommitted);
    try std.testing.expectEqual(@as(u64, 3), recovered.anchor_generation);
    try std.testing.expectEqual(@as(u64, 0), recovered.used_bytes);
}
