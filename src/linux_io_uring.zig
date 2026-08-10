const std = @import("std");

const IoUring = std.os.linux.IoUring;
const linux = std.os.linux;

pub const queue_entries = 32;
const max_request_len = std.math.maxInt(u32);

pub const SyncMode = enum {
    data,
    full,
};

pub const Write = struct {
    bytes: []const u8,
    offset: u64,
};

pub const Stats = struct {
    queue_capacity: u64 = queue_entries,
    submitted_sqes: u64 = 0,
    submit_calls: u64 = 0,
    completions: u64 = 0,
    current_inflight: u64 = 0,
    max_inflight: u64 = 0,
};

pub const Engine = struct {
    ring: IoUring,
    mutex: std.Io.Mutex = .init,
    next_token: u64 = 1,
    stats: Stats = .{},
    current_inflight: u64 = 0,
    active: bool = true,
    file_registered: bool = true,
    writev_supported: bool,

    /// Initializes an engine that borrows fd; the caller retains ownership.
    pub fn init(fd: linux.fd_t) !Engine {
        var ring = try IoUring.init(queue_entries, 0);
        errdefer ring.deinit();
        const probe = try ring.get_probe();
        if (!probe.is_supported(.READ) or
            !probe.is_supported(.WRITE) or
            !probe.is_supported(.FSYNC))
            return error.UnsupportedIoUringOperations;

        var files = [_]linux.fd_t{fd};
        try ring.register_files(&files);
        errdefer ring.unregister_files() catch {};
        return .{
            .ring = ring,
            .writev_supported = probe.is_supported(.WRITEV),
        };
    }

    /// The owner must ensure no operation is active or waiting before deinit.
    pub fn deinit(self: *Engine) void {
        self.fail();
        self.* = undefined;
    }

    /// Reads up to buffer.len bytes, stopping only at EOF.
    pub fn readAt(self: *Engine, io: std.Io, buffer: []u8, offset: u64) !usize {
        _ = std.math.add(u64, offset, buffer.len) catch return error.OffsetOverflow;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        return self.readAtLocked(buffer, offset);
    }

    pub fn readManyAt(self: *Engine, io: std.Io, reads: anytype, results: anytype) !void {
        if (reads.len != results.len) return error.InvalidReadBatch;
        for (reads) |read| {
            if (read.buffer.len > max_request_len) return error.RequestTooLarge;
            _ = std.math.add(u64, read.offset, read.buffer.len) catch return error.OffsetOverflow;
        }
        for (results) |*result| result.* = .{};
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var index: usize = 0;
        while (index < reads.len) {
            const count = @min(reads.len - index, queue_entries);
            var tokens: [queue_entries]u64 = undefined;
            var lengths: [queue_entries]usize = undefined;
            var amounts: [queue_entries]usize = @splat(0);
            var errors: [queue_entries]?anyerror = @splat(null);
            var seen: [queue_entries]bool = @splat(false);
            for (reads[index..][0..count], 0..) |read, batch_index| {
                try self.requireActive();
                const token = self.nextToken();
                const sqe = self.ring.read(token, 0, .{ .buffer = read.buffer }, read.offset) catch |err| {
                    self.fail();
                    return err;
                };
                sqe.flags |= linux.IOSQE_FIXED_FILE;
                tokens[batch_index] = token;
                lengths[batch_index] = read.buffer.len;
            }
            try self.submitBatch(count);
            var tracker: BatchTracker = .{
                .tokens = tokens[0..count],
                .lengths = lengths[0..count],
                .amounts = amounts[0..count],
                .errors = errors[0..count],
                .seen = seen[0..count],
            };
            for (0..count) |_| {
                const completion = self.copyCompletion() catch |err| {
                    self.failAfterDrain();
                    return err;
                };
                tracker.record(completion) catch return self.invalidCompletion();
            }
            for (reads[index..][0..count], results[index..][0..count], amounts[0..count], errors[0..count]) |read, *result, amount, maybe_error| {
                if (maybe_error) |err| {
                    if (err == error.OperationInterrupted) {
                        result.amount = self.readAtLocked(read.buffer, read.offset) catch |retry_err| {
                            if (!self.active) return retry_err;
                            result.failure = retry_err;
                            continue;
                        };
                    } else result.failure = err;
                    continue;
                }
                result.amount = amount;
                if (amount < read.buffer.len) {
                    result.amount += self.readAtLocked(read.buffer[amount..], read.offset + amount) catch |err| {
                        if (!self.active) return err;
                        result.failure = err;
                        continue;
                    };
                }
            }
            index += count;
        }
    }

    fn readAtLocked(self: *Engine, buffer: []u8, offset: u64) !usize {
        var index: usize = 0;
        while (index < buffer.len) {
            try self.requireActive();
            const request_len = @min(buffer.len - index, max_request_len);
            const token = self.nextToken();
            const sqe = self.ring.read(
                token,
                0,
                .{ .buffer = buffer[index..][0..request_len] },
                offset + index,
            ) catch |err| {
                self.fail();
                return err;
            };
            sqe.flags |= linux.IOSQE_FIXED_FILE;
            const amount = self.complete(token) catch |err| switch (err) {
                error.OperationInterrupted => continue,
                else => return err,
            };
            if (amount == 0) break;
            if (amount > request_len) return self.invalidCompletion();
            index += amount;
        }
        return index;
    }

    pub fn readAllAt(self: *Engine, io: std.Io, buffer: []u8, offset: u64) !void {
        if (try self.readAt(io, buffer, offset) != buffer.len)
            return error.UnexpectedEndOfFile;
    }

    pub fn writeAllAt(self: *Engine, io: std.Io, bytes: []const u8, offset: u64) !void {
        _ = std.math.add(u64, offset, bytes.len) catch return error.OffsetOverflow;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.writeAllLocked(bytes, offset);
    }

    /// Writes must not overlap; completions may arrive in any order.
    pub fn writeAllManyAt(self: *Engine, io: std.Io, writes: anytype) !void {
        for (writes) |write| {
            if (write.bytes.len > max_request_len) return error.RequestTooLarge;
            _ = std.math.add(u64, write.offset, write.bytes.len) catch return error.OffsetOverflow;
        }
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var index: usize = 0;
        while (index < writes.len) {
            const batch_count = @min(writes.len - index, queue_entries);
            const batch = writes[index..][0..batch_count];
            if (self.writev_supported and contiguousWrites(batch)) {
                try self.writeAllVectoredLocked(batch);
                index += batch_count;
                continue;
            }
            var tokens: [queue_entries]u64 = undefined;
            var lengths: [queue_entries]usize = undefined;
            var amounts: [queue_entries]usize = @splat(0);
            var errors: [queue_entries]?anyerror = @splat(null);
            var seen: [queue_entries]bool = @splat(false);
            var count: usize = 0;
            while (index + count < writes.len and count < queue_entries) : (count += 1) {
                const write = writes[index + count];
                try self.requireActive();
                const token = self.nextToken();
                const sqe = self.ring.write(token, 0, write.bytes, write.offset) catch |err| {
                    self.fail();
                    return err;
                };
                sqe.flags |= linux.IOSQE_FIXED_FILE;
                tokens[count] = token;
                lengths[count] = write.bytes.len;
            }
            try self.submitBatch(count);
            var tracker: BatchTracker = .{
                .tokens = tokens[0..count],
                .lengths = lengths[0..count],
                .amounts = amounts[0..count],
                .errors = errors[0..count],
                .seen = seen[0..count],
            };
            for (0..count) |_| {
                const completion = self.copyCompletion() catch |err| {
                    self.failAfterDrain();
                    return err;
                };
                tracker.record(completion) catch return self.invalidCompletion();
            }
            for (writes[index..][0..count], amounts[0..count], errors[0..count]) |write, amount, maybe_error| {
                if (maybe_error) |err| switch (err) {
                    error.OperationInterrupted => {
                        try self.writeAllLocked(write.bytes, write.offset);
                        continue;
                    },
                    else => return err,
                };
                if (amount < write.bytes.len)
                    try self.writeAllLocked(write.bytes[amount..], write.offset + amount);
            }
            index += count;
        }
    }

    pub fn sync(self: *Engine, io: std.Io, mode: SyncMode) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        while (true) {
            try self.requireActive();
            const token = self.nextToken();
            const flags: u32 = if (mode == .data) linux.IORING_FSYNC_DATASYNC else 0;
            const sqe = self.ring.fsync(token, 0, flags) catch |err| {
                self.fail();
                return err;
            };
            sqe.flags |= linux.IOSQE_FIXED_FILE;
            const result = self.complete(token) catch |err| switch (err) {
                error.OperationInterrupted => continue,
                else => return err,
            };
            if (result != 0) return self.invalidCompletion();
            return;
        }
    }

    pub fn getStats(self: *Engine, io: std.Io) Stats {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var result = self.stats;
        result.current_inflight = self.current_inflight;
        return result;
    }

    pub fn resetStats(self: *Engine, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.current_inflight == 0);
        self.stats = .{};
    }

    fn nextToken(self: *Engine) u64 {
        const token = self.next_token;
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        return token;
    }

    fn requireActive(self: *const Engine) !void {
        if (!self.active) return error.IoUringFailed;
    }

    fn fail(self: *Engine) void {
        if (!self.active) return;
        if (self.file_registered) {
            self.ring.unregister_files() catch {};
            self.file_registered = false;
        }
        self.ring.deinit();
        self.active = false;
    }

    fn failAfterDrain(self: *Engine) void {
        while (self.current_inflight != 0) _ = self.copyCompletion() catch break;
        self.fail();
    }

    fn invalidCompletion(self: *Engine) error{InvalidIoUringCompletion} {
        self.failAfterDrain();
        return error.InvalidIoUringCompletion;
    }

    fn complete(self: *Engine, token: u64) !usize {
        try self.submitBatch(1);
        const completion = self.copyCompletion() catch |err| {
            self.failAfterDrain();
            return err;
        };
        if (completion.user_data != token) return self.invalidCompletion();
        if (completion.res < 0) return completionError(@fromBackingInt(@intCast(-completion.res)));
        return @intCast(completion.res);
    }

    fn submitBatch(self: *Engine, count: usize) !void {
        var submitted: u32 = 0;
        const expected: u32 = @intCast(count);
        var flushed = false;
        while (submitted < expected) {
            self.stats.submit_calls += 1;
            const amount = (if (!flushed) submit: {
                flushed = true;
                break :submit self.ring.submit();
            } else self.ring.enter(expected - submitted, 0, 0)) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => {
                    self.failAfterDrain();
                    return err;
                },
            };
            if (amount == 0 or amount > expected - submitted) {
                self.failAfterDrain();
                return error.IncompleteIoUringSubmission;
            }
            submitted += amount;
            self.stats.submitted_sqes += amount;
            self.current_inflight += amount;
            self.stats.max_inflight = @max(self.stats.max_inflight, self.current_inflight);
        }
    }

    fn copyCompletion(self: *Engine) !linux.io_uring_cqe {
        while (true) {
            const completion = self.ring.copy_cqe() catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };
            std.debug.assert(self.current_inflight != 0);
            self.current_inflight -= 1;
            self.stats.completions += 1;
            return completion;
        }
    }

    fn writeAllLocked(self: *Engine, bytes: []const u8, offset: u64) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            try self.requireActive();
            const request_len = @min(bytes.len - index, max_request_len);
            const token = self.nextToken();
            const sqe = self.ring.write(token, 0, bytes[index..][0..request_len], offset + index) catch |err| {
                self.fail();
                return err;
            };
            sqe.flags |= linux.IOSQE_FIXED_FILE;
            const amount = self.complete(token) catch |err| switch (err) {
                error.OperationInterrupted => continue,
                else => return err,
            };
            if (amount == 0 or amount > request_len) return self.invalidCompletion();
            index += amount;
        }
    }

    fn writeAllVectoredLocked(self: *Engine, writes: anytype) !void {
        std.debug.assert(writes.len > 1 and writes.len <= queue_entries);
        var iovecs: [queue_entries]std.posix.iovec_const = undefined;
        for (writes, iovecs[0..writes.len]) |write, *iovec| iovec.* = .{
            .base = write.bytes.ptr,
            .len = write.bytes.len,
        };
        var first: usize = 0;
        var offset = writes[0].offset;
        while (first < writes.len) {
            try self.requireActive();
            const token = self.nextToken();
            const sqe = self.ring.writev(token, 0, iovecs[first..writes.len], offset) catch |err| {
                self.fail();
                return err;
            };
            sqe.flags |= linux.IOSQE_FIXED_FILE;
            const amount = self.completeWritev(token) catch |err| switch (err) {
                error.OperationInterrupted => continue,
                error.WritevNotSupported => {
                    self.writev_supported = false;
                    var scalar_offset = offset;
                    for (iovecs[first..writes.len]) |iovec| {
                        try self.writeAllLocked(iovec.base[0..iovec.len], scalar_offset);
                        scalar_offset = std.math.add(u64, scalar_offset, iovec.len) catch
                            return self.invalidCompletion();
                    }
                    return;
                },
                else => return err,
            };
            if (amount == 0) return self.invalidCompletion();
            offset = std.math.add(u64, offset, amount) catch return self.invalidCompletion();
            if (!consumeIovecs(iovecs[0..writes.len], &first, amount)) return self.invalidCompletion();
        }
    }

    fn completeWritev(self: *Engine, token: u64) !usize {
        try self.submitBatch(1);
        const completion = self.copyCompletion() catch |err| {
            self.failAfterDrain();
            return err;
        };
        if (completion.user_data != token) return self.invalidCompletion();
        if (completion.res < 0) {
            const err: linux.E = @fromBackingInt(@intCast(-completion.res));
            if (err == .OPNOTSUPP) return error.WritevNotSupported;
            return completionError(err);
        }
        return @intCast(completion.res);
    }
};

fn contiguousWrites(writes: anytype) bool {
    if (writes.len <= 1) return false;
    for (writes) |write| if (write.bytes.len == 0) return false;
    for (writes[1..], writes[0 .. writes.len - 1]) |current, previous| {
        const expected = std.math.add(u64, previous.offset, previous.bytes.len) catch return false;
        if (current.offset != expected) return false;
    }
    return true;
}

fn consumeIovecs(iovecs: []std.posix.iovec_const, first: *usize, amount: usize) bool {
    var remaining = amount;
    while (remaining != 0 and first.* < iovecs.len) {
        if (remaining < iovecs[first.*].len) {
            iovecs[first.*].base += remaining;
            iovecs[first.*].len -= remaining;
            remaining = 0;
        } else {
            remaining -= iovecs[first.*].len;
            first.* += 1;
        }
    }
    return remaining == 0;
}

const BatchTracker = struct {
    tokens: []const u64,
    lengths: []const usize,
    amounts: []usize,
    errors: []?anyerror,
    seen: []bool,

    fn record(self: *BatchTracker, completion: linux.io_uring_cqe) !void {
        const completion_index = for (self.tokens, 0..) |token, token_index| {
            if (token == completion.user_data) break token_index;
        } else return error.InvalidIoUringCompletion;
        if (self.seen[completion_index]) return error.InvalidIoUringCompletion;
        self.seen[completion_index] = true;
        if (completion.res < 0) {
            self.errors[completion_index] = completionError(@fromBackingInt(@intCast(-completion.res)));
        } else {
            const amount: usize = @intCast(completion.res);
            if (amount > self.lengths[completion_index]) return error.InvalidIoUringCompletion;
            self.amounts[completion_index] = amount;
        }
    }
};

fn completionError(err: linux.E) anyerror {
    return switch (err) {
        .ACCES, .PERM, .ROFS => error.ReadOnlyFileSystem,
        .BADF => error.FileClosed,
        .DQUOT, .FBIG, .NOSPC => error.NoSpaceLeft,
        .NODEV, .NXIO => error.DeviceUnavailable,
        .NOMEM, .NOBUFS, .AGAIN => error.SystemResources,
        .CANCELED => error.OperationCanceled,
        .INTR => error.OperationInterrupted,
        .INVAL => error.InvalidIo,
        else => error.IoUringCompletion,
    };
}

test "vectored write cursor consumes partial and complete iovecs" {
    const bytes = "abcdefghijkl";
    var iovecs = [_]std.posix.iovec_const{
        .{ .base = bytes.ptr, .len = 3 },
        .{ .base = bytes.ptr + 3, .len = 4 },
        .{ .base = bytes.ptr + 7, .len = 5 },
    };
    var first: usize = 0;
    try std.testing.expect(consumeIovecs(&iovecs, &first, 2));
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 1), iovecs[0].len);
    try std.testing.expectEqual(bytes.ptr + 2, iovecs[0].base);
    try std.testing.expect(consumeIovecs(&iovecs, &first, 5));
    try std.testing.expectEqual(@as(usize, 2), first);
    try std.testing.expectEqual(@as(usize, 5), iovecs[2].len);
    try std.testing.expect(consumeIovecs(&iovecs, &first, 5));
    try std.testing.expectEqual(iovecs.len, first);

    iovecs = .{
        .{ .base = bytes.ptr, .len = 3 },
        .{ .base = bytes.ptr + 3, .len = 4 },
        .{ .base = bytes.ptr + 7, .len = 5 },
    };
    first = 0;
    try std.testing.expect(!consumeIovecs(&iovecs, &first, bytes.len + 1));
}

test "io_uring batch tracker accepts deterministic out-of-order completions" {
    const tokens = [_]u64{ 11, 12, 13 };
    const lengths = [_]usize{ 4, 5, 6 };
    var amounts: [tokens.len]usize = @splat(0);
    var errors: [tokens.len]?anyerror = @splat(null);
    var seen: [tokens.len]bool = @splat(false);
    var tracker: BatchTracker = .{
        .tokens = &tokens,
        .lengths = &lengths,
        .amounts = &amounts,
        .errors = &errors,
        .seen = &seen,
    };
    try tracker.record(.{ .user_data = 13, .res = 6, .flags = 0 });
    try tracker.record(.{ .user_data = 11, .res = 4, .flags = 0 });
    try tracker.record(.{ .user_data = 12, .res = -@as(i32, @backingInt(linux.E.INTR)), .flags = 0 });
    try std.testing.expectEqualSlices(usize, &.{ 4, 0, 6 }, &amounts);
    try std.testing.expectEqual(error.OperationInterrupted, errors[1].?);
    try std.testing.expectError(
        error.InvalidIoUringCompletion,
        tracker.record(.{ .user_data = 12, .res = 5, .flags = 0 }),
    );
    try std.testing.expectError(
        error.InvalidIoUringCompletion,
        tracker.record(.{ .user_data = 99, .res = 1, .flags = 0 }),
    );
}

test "borrowed-fd engine supports partial and exact reads and metrics reset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "uring-engine", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "abc", 0);

    var engine = Engine.init(file.handle) catch |err| switch (err) {
        error.ArgumentsInvalid,
        error.PermissionDenied,
        error.SystemOutdated,
        error.UnsupportedIoUringOperations,
        => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();

    var partial: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try engine.readAt(std.testing.io, &partial, 0));
    try std.testing.expectEqualStrings("abc", partial[0..3]);
    try std.testing.expectError(error.UnexpectedEndOfFile, engine.readAllAt(std.testing.io, &partial, 0));
    var exact: [3]u8 = undefined;
    try engine.readAllAt(std.testing.io, &exact, 0);
    try std.testing.expectEqualStrings("abc", &exact);
    try engine.writeAllAt(std.testing.io, "xyz", 8);
    try engine.sync(std.testing.io, .full);

    const stats = engine.getStats(std.testing.io);
    try std.testing.expect(stats.submitted_sqes > 0);
    try std.testing.expectEqual(stats.submitted_sqes, stats.completions);
    engine.resetStats(std.testing.io);
    try std.testing.expectEqual(Stats{}, engine.getStats(std.testing.io));

    const TestRead = struct { buffer: []u8, offset: u64 };
    const TestResult = struct { amount: usize = 0, failure: ?anyerror = null };
    var batch_bytes: [4][1]u8 = undefined;
    var reads: [4]TestRead = undefined;
    for (&reads, 0..) |*read, index| read.* = .{
        .buffer = &batch_bytes[index],
        .offset = index,
    };
    var results: [reads.len]TestResult = undefined;
    try engine.readManyAt(std.testing.io, &reads, &results);
    try std.testing.expectEqualStrings("abc\x00", std.mem.sliceAsBytes(&batch_bytes));
    for (results) |result| {
        try std.testing.expectEqual(@as(usize, 1), result.amount);
        try std.testing.expectEqual(@as(?anyerror, null), result.failure);
    }
    const batch_stats = engine.getStats(std.testing.io);
    try std.testing.expectEqual(@as(u64, reads.len), batch_stats.submitted_sqes);
    try std.testing.expectEqual(@as(u64, reads.len), batch_stats.max_inflight);

    const TestWrite = struct { bytes: []const u8, offset: u64 };
    const write_bytes = [_][2]u8{ "ab".*, "cd".*, "ef".*, "gh".* };
    var writes: [write_bytes.len]TestWrite = undefined;
    for (&writes, &write_bytes, 0..) |*write, *bytes, index| write.* = .{
        .bytes = bytes,
        .offset = 16 + index * bytes.len,
    };
    const writev_was_supported = engine.writev_supported;
    engine.resetStats(std.testing.io);
    try engine.writeAllManyAt(std.testing.io, &writes);
    const contiguous_stats = engine.getStats(std.testing.io);
    const expected_contiguous_sqes: u64 = if (engine.writev_supported)
        1
    else if (writev_was_supported)
        writes.len + 1
    else
        writes.len;
    try std.testing.expectEqual(expected_contiguous_sqes, contiguous_stats.submitted_sqes);
    try std.testing.expectEqual(expected_contiguous_sqes, contiguous_stats.completions);
    var contiguous: [8]u8 = undefined;
    try std.testing.expectEqual(contiguous.len, try file.readPositionalAll(std.testing.io, &contiguous, 16));
    try std.testing.expectEqualStrings("abcdefgh", &contiguous);

    for (&writes, &write_bytes, 0..) |*write, *bytes, index| write.* = .{
        .bytes = bytes,
        .offset = 32 + index * (bytes.len + 1),
    };
    engine.resetStats(std.testing.io);
    try engine.writeAllManyAt(std.testing.io, &writes);
    const gapped_stats = engine.getStats(std.testing.io);
    try std.testing.expectEqual(@as(u64, writes.len), gapped_stats.submitted_sqes);
    try std.testing.expectEqual(@as(u64, writes.len), gapped_stats.max_inflight);
}
