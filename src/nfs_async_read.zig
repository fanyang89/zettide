const std = @import("std");
const zettide = @import("zettide");

const IoUring = std.os.linux.IoUring;
const linux = std.os.linux;

pub const block_size = 4096;
pub const queue_capacity = 256;
const ring_capacity = 128;
const wake_token = 1;

pub const Callback = *const fn (c_int, usize, ?*anyopaque) callconv(.c) void;

pub const Stats = struct {
    submitted: u64 = 0,
    completed: u64 = 0,
    fallbacks: u64 = 0,
    queue_peak: usize = 0,
};

const Request = struct {
    plan: zettide.blob_store.DirectReadPlan,
    buffer: []u8,
    callback: Callback,
    context: ?*anyopaque,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    ring: IoUring,
    wake_fd: linux.fd_t,
    thread: std.Thread,
    mutex: std.atomic.Mutex = .unlocked,
    queue: [queue_capacity]*Request = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,
    active: [ring_capacity - 1]*Request = undefined,
    active_len: usize = 0,
    accepting: bool = true,
    stopping: bool = false,
    destroy_on_exit: bool = false,
    stats: Stats = .{},

    pub fn create(allocator: std.mem.Allocator, _: std.Io) !*Engine {
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);

        var ring = try IoUring.init(ring_capacity, 0);
        errdefer ring.deinit();
        const probe = try ring.get_probe();
        if (!probe.is_supported(.READ) or !probe.is_supported(.POLL_ADD))
            return error.UnsupportedIoUringOperations;
        const wake_fd = try createEventFd();
        errdefer _ = linux.close(wake_fd);

        self.* = .{
            .allocator = allocator,
            .ring = ring,
            .wake_fd = wake_fd,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn destroy(self: *Engine) void {
        self.stopAccepting();
        if (self.thread.getHandle() == std.c.pthread_self()) {
            self.lock();
            self.destroy_on_exit = true;
            self.mutex.unlock();
            self.thread.detach();
            return;
        }
        self.thread.join();
        self.allocator.destroy(self);
    }

    pub fn stopAccepting(self: *Engine) void {
        self.lock();
        self.accepting = false;
        self.stopping = true;
        self.mutex.unlock();
        self.wake();
    }

    pub fn enqueue(
        self: *Engine,
        plan: zettide.blob_store.DirectReadPlan,
        buffer: []u8,
        callback: Callback,
        context: ?*anyopaque,
    ) !bool {
        const request = try self.allocator.create(Request);
        request.* = .{
            .plan = plan,
            .buffer = buffer,
            .callback = callback,
            .context = context,
        };
        self.lock();
        if (!self.accepting or self.queue_len == queue_capacity) {
            self.stats.fallbacks += 1;
            self.mutex.unlock();
            self.allocator.destroy(request);
            return false;
        }
        const tail = (self.queue_head + self.queue_len) % queue_capacity;
        self.queue[tail] = request;
        self.queue_len += 1;
        self.stats.queue_peak = @max(self.stats.queue_peak, self.queue_len);
        self.mutex.unlock();
        self.wake();
        return true;
    }

    pub fn noteFallback(self: *Engine) void {
        self.lock();
        self.stats.fallbacks += 1;
        self.mutex.unlock();
    }

    pub fn getStats(self: *Engine) Stats {
        self.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    fn run(self: *Engine) void {
        self.runLoop() catch @panic("unrecoverable NFS io_uring failure");
        self.ring.deinit();
        self.closeWakeFd();
        self.lock();
        const destroy_on_exit = self.destroy_on_exit;
        self.mutex.unlock();
        if (destroy_on_exit) self.allocator.destroy(self);
    }

    fn runLoop(self: *Engine) !void {
        var inflight: usize = 0;
        var wake_armed = false;
        while (true) {
            var scheduled: usize = 0;
            var wake_scheduled = false;
            if (!wake_armed and !self.isStopping()) {
                _ = try self.ring.poll_add(wake_token, self.wake_fd, linux.POLL.IN);
                wake_armed = true;
                wake_scheduled = true;
                scheduled += 1;
            }
            while (inflight < ring_capacity - 1) {
                const request = self.pop() orelse break;
                _ = self.ring.read(
                    @intFromPtr(request),
                    request.plan.extent.fd,
                    .{ .buffer = request.buffer },
                    @intCast(request.plan.extent.offset),
                ) catch {
                    self.finish(request, 11, 0);
                    continue;
                };
                self.active[self.active_len] = request;
                self.active_len += 1;
                inflight += 1;
                scheduled += 1;
            }
            if (scheduled != 0) {
                try submitExact(&self.ring, scheduled);
                self.addSubmitted(scheduled - @intFromBool(wake_scheduled));
            }
            if (self.isStopping() and self.queueEmpty() and inflight == 0 and !wake_armed)
                return;

            var completions: [ring_capacity]linux.io_uring_cqe = undefined;
            const count = while (true) {
                break self.ring.copy_cqes(&completions, 1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return err,
                };
            };
            for (completions[0..count]) |completion| {
                if (completion.user_data == wake_token) {
                    wake_armed = false;
                    drainEventFd(self.wake_fd);
                    continue;
                }
                const request: *Request = @ptrFromInt(completion.user_data);
                self.removeActive(request);
                inflight -= 1;
                const valid = completion.res == block_size and
                    std.hash.crc.Crc32Iscsi.hash(request.buffer) == request.plan.expected_crc32c;
                self.finish(request, if (valid) 0 else 9, if (valid) block_size else 0);
            }
        }
    }

    fn pop(self: *Engine) ?*Request {
        self.lock();
        defer self.mutex.unlock();
        if (self.queue_len == 0) return null;
        const request = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % queue_capacity;
        self.queue_len -= 1;
        return request;
    }

    fn finish(self: *Engine, request: *Request, completion_status: c_int, amount: usize) void {
        request.plan.deinit();
        const callback = request.callback;
        const context = request.context;
        self.allocator.destroy(request);
        self.lock();
        self.stats.completed += 1;
        self.mutex.unlock();
        callback(completion_status, amount, context);
    }

    fn removeActive(self: *Engine, request: *Request) void {
        for (self.active[0..self.active_len], 0..) |active, index| {
            if (active != request) continue;
            self.active_len -= 1;
            self.active[index] = self.active[self.active_len];
            return;
        }
        unreachable;
    }

    fn addSubmitted(self: *Engine, count: usize) void {
        self.lock();
        self.stats.submitted += count;
        self.mutex.unlock();
    }

    fn isStopping(self: *Engine) bool {
        self.lock();
        defer self.mutex.unlock();
        return self.stopping;
    }

    fn queueEmpty(self: *Engine) bool {
        self.lock();
        defer self.mutex.unlock();
        return self.queue_len == 0;
    }

    fn wake(self: *Engine) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.wake_fd < 0) return;
        const one: u64 = 1;
        while (true) {
            const result = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
            switch (linux.errno(result)) {
                .SUCCESS, .AGAIN => return,
                .INTR => continue,
                else => return,
            }
        }
    }

    fn closeWakeFd(self: *Engine) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.wake_fd < 0) return;
        _ = linux.close(self.wake_fd);
        self.wake_fd = -1;
    }

    fn lock(self: *Engine) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

fn createEventFd() !linux.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .MFILE, .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn drainEventFd(fd: linux.fd_t) void {
    var value: u64 = undefined;
    while (true) {
        const result = linux.read(fd, std.mem.asBytes(&value).ptr, @sizeOf(u64));
        switch (linux.errno(result)) {
            .SUCCESS => continue,
            .INTR => continue,
            .AGAIN => return,
            else => return,
        }
    }
}

fn submitExact(ring: *IoUring, count: usize) !void {
    var submitted: u32 = 0;
    const expected: u32 = @intCast(count);
    while (submitted < expected) {
        const amount = (if (submitted == 0)
            ring.submit()
        else
            ring.enter(expected - submitted, 0, 0)) catch |err| switch (err) {
            error.SignalInterrupt, error.SystemResources, error.CompletionQueueOvercommitted => {
                std.Thread.yield() catch {};
                continue;
            },
            else => return err,
        };
        if (amount == 0) {
            std.Thread.yield() catch {};
            continue;
        }
        if (amount > expected - submitted)
            return error.IncompleteIoUringSubmission;
        submitted += amount;
    }
}

const TestCallbackContext = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    count: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),
    block: bool = false,
};

fn testCallback(completion_status: c_int, amount: usize, context_ptr: ?*anyopaque) callconv(.c) void {
    const context: *TestCallbackContext = @ptrCast(@alignCast(context_ptr.?));
    if (completion_status != 0 or amount != block_size)
        _ = context.failures.fetchAdd(1, .monotonic);
    _ = context.count.fetchAdd(1, .monotonic);
    context.entered.set(context.io);
    if (context.block) context.release.waitUncancelable(context.io);
}

fn testEngine() !*Engine {
    return Engine.create(std.testing.allocator, std.testing.io) catch |err| switch (err) {
        error.ArgumentsInvalid,
        error.PermissionDenied,
        error.SystemOutdated,
        error.UnsupportedIoUringOperations,
        => return error.SkipZigTest,
        else => return err,
    };
}

fn testPlan(fd: linux.fd_t, expected_crc32c: u32) !zettide.blob_store.DirectReadPlan {
    const result = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
    const duplicate: linux.fd_t = switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => |err| return std.posix.unexpectedErrno(err),
    };
    return .{
        .extent = .{ .fd = duplicate, .offset = 0, .length = block_size },
        .expected_crc32c = expected_crc32c,
    };
}

test "async read engine validates CRC and calls back exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "async-read", .{ .read = true });
    defer file.close(std.testing.io);
    const expected: [block_size]u8 = @splat(0x5a);
    try file.writePositionalAll(std.testing.io, &expected, 0);

    const engine = try testEngine();
    var storage: [2 * block_size + 1]u8 = undefined;
    const good = storage[1..][0..block_size];
    const bad = storage[block_size + 1 ..][0..block_size];
    var good_context: TestCallbackContext = .{ .io = std.testing.io };
    var bad_context: TestCallbackContext = .{ .io = std.testing.io };
    try std.testing.expect(try engine.enqueue(
        try testPlan(file.handle, std.hash.crc.Crc32Iscsi.hash(&expected)),
        good,
        testCallback,
        &good_context,
    ));
    try std.testing.expect(try engine.enqueue(
        try testPlan(file.handle, 0),
        bad,
        testCallback,
        &bad_context,
    ));
    good_context.entered.waitUncancelable(std.testing.io);
    bad_context.entered.waitUncancelable(std.testing.io);
    engine.destroy();

    try std.testing.expectEqualSlices(u8, &expected, good);
    try std.testing.expectEqual(@as(usize, 1), good_context.count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), good_context.failures.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), bad_context.count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), bad_context.failures.load(.monotonic));
}

test "async read engine bounds its queue and drains on destroy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "async-drain", .{ .read = true });
    defer file.close(std.testing.io);
    const expected: [block_size]u8 = @splat(0xa5);
    try file.writePositionalAll(std.testing.io, &expected, 0);
    const checksum = std.hash.crc.Crc32Iscsi.hash(&expected);

    const engine = try testEngine();
    var buffers: [queue_capacity + 1][block_size]u8 align(block_size) = undefined;
    var context: TestCallbackContext = .{ .io = std.testing.io, .block = true };
    try std.testing.expect(try engine.enqueue(
        try testPlan(file.handle, checksum),
        &buffers[0],
        testCallback,
        &context,
    ));
    context.entered.waitUncancelable(std.testing.io);
    for (buffers[1..], 0..) |*buffer, index| {
        var plan = try testPlan(file.handle, checksum);
        if (index == queue_capacity) {
            try std.testing.expect(!try engine.enqueue(plan, buffer, testCallback, &context));
            plan.deinit();
        } else {
            try std.testing.expect(try engine.enqueue(plan, buffer, testCallback, &context));
        }
    }
    context.release.set(std.testing.io);
    engine.destroy();
    try std.testing.expectEqual(@as(usize, queue_capacity + 1), context.count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), context.failures.load(.monotonic));
}
