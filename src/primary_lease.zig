const std = @import("std");

pub const Id = [16]u8;

pub const duration_ms: u64 = 30_000;
pub const renew_after_ms: u64 = 10_000;
pub const early_stop_margin_ms: u64 = 5_000;
pub const minimum_ready_remaining_ms: u64 = 10_000;

comptime {
    std.debug.assert(renew_after_ms < duration_ms - early_stop_margin_ms);
    std.debug.assert(minimum_ready_remaining_ms <= duration_ms - early_stop_margin_ms);
}

pub const Token = struct {
    lease_id: Id,
    holder_boot_id: Id,
    authority_generation: u64,
    write_epoch: u64,
};

pub const Window = struct {
    token: Token,
    started_ms: u64,
    admission_deadline_ms: u64,
    hard_deadline_ms: u64,
    ready: bool = false,

    fn init(token: Token, now_ms: u64) !Window {
        if (isZero(token.lease_id) or isZero(token.holder_boot_id) or token.authority_generation == 0 or token.write_epoch == 0)
            return error.InvalidToken;
        const hard_deadline_ms = std.math.add(u64, now_ms, duration_ms) catch return error.ClockOverflow;
        return .{
            .token = token,
            .started_ms = now_ms,
            .admission_deadline_ms = hard_deadline_ms - early_stop_margin_ms,
            .hard_deadline_ms = hard_deadline_ms,
        };
    }

    pub fn shouldRenew(self: Window, now_ms: u64) bool {
        return now_ms >= self.started_ms + renew_after_ms and now_ms < self.admission_deadline_ms;
    }

    pub fn canAdmit(self: Window, now_ms: u64) bool {
        return self.ready and now_ms < self.admission_deadline_ms;
    }

    pub fn canComplete(self: Window, now_ms: u64) bool {
        return self.ready and now_ms < self.hard_deadline_ms;
    }
};

pub const Runtime = struct {
    boot_id: Id,
    current: ?Window = null,
    candidate: ?Window = null,

    pub fn init(boot_id: Id) !Runtime {
        if (isZero(boot_id)) return error.InvalidBootId;
        return .{ .boot_id = boot_id };
    }

    /// Starts the holder-local monotonic window before its activation ACK is sent.
    pub fn stage(self: *Runtime, token: Token, now_ms: u64) !Window {
        if (!std.mem.eql(u8, &token.holder_boot_id, &self.boot_id)) return error.BootMismatch;
        if (self.current) |current| {
            if (token.write_epoch < current.token.write_epoch or token.authority_generation < current.token.authority_generation)
                return error.StaleAuthority;
            if (std.mem.eql(u8, &token.lease_id, &current.token.lease_id)) {
                if (!std.meta.eql(token, current.token)) return error.LeaseConflict;
                return current;
            }
        }
        if (self.candidate) |candidate| {
            if (std.mem.eql(u8, &token.lease_id, &candidate.token.lease_id)) {
                if (!std.meta.eql(token, candidate.token)) return error.LeaseConflict;
                return candidate;
            }
            if (token.write_epoch < candidate.token.write_epoch or token.authority_generation < candidate.token.authority_generation)
                return error.StaleAuthority;
        }
        const candidate = try Window.init(token, now_ms);
        self.candidate = candidate;
        return candidate;
    }

    /// Called only after the matching READY authority has committed in Raft.
    pub fn markReady(self: *Runtime, lease_id: Id, now_ms: u64) !void {
        var candidate = self.candidate orelse return error.NoCandidate;
        if (!std.mem.eql(u8, &candidate.token.lease_id, &lease_id)) return error.LeaseMismatch;
        if (now_ms >= candidate.admission_deadline_ms or candidate.hard_deadline_ms - now_ms < minimum_ready_remaining_ms)
            return error.InsufficientWindow;
        candidate.ready = true;
        self.current = candidate;
        self.candidate = null;
    }

    pub fn discardCandidate(self: *Runtime, lease_id: Id) void {
        const candidate = self.candidate orelse return;
        if (std.mem.eql(u8, &candidate.token.lease_id, &lease_id)) self.candidate = null;
    }

    pub fn canAdmit(self: Runtime, token: Token, now_ms: u64) bool {
        const current = self.current orelse return false;
        return std.meta.eql(token, current.token) and current.canAdmit(now_ms);
    }

    pub fn canComplete(self: Runtime, token: Token, now_ms: u64) bool {
        const current = self.current orelse return false;
        return std.meta.eql(token, current.token) and current.canComplete(now_ms);
    }

    pub fn stop(self: *Runtime) void {
        self.current = null;
        self.candidate = null;
    }
};

fn isZero(id: Id) bool {
    for (id) |byte| if (byte != 0) return false;
    return true;
}

const boot_a: Id = .{1} ++ @as([15]u8, @splat(0));
const boot_b: Id = .{2} ++ @as([15]u8, @splat(0));
const lease_a: Id = .{3} ++ @as([15]u8, @splat(0));
const lease_b: Id = .{4} ++ @as([15]u8, @splat(0));

fn testToken(lease_id: Id, epoch: u64) Token {
    return .{ .lease_id = lease_id, .holder_boot_id = boot_a, .authority_generation = epoch, .write_epoch = epoch };
}

test "lease window stops admission before hard completion deadline" {
    var runtime = try Runtime.init(boot_a);
    const authority = testToken(lease_a, 7);
    _ = try runtime.stage(authority, 1_000);
    try std.testing.expect(!runtime.canAdmit(authority, 1_000));
    try runtime.markReady(lease_a, 2_000);
    try std.testing.expect(runtime.canAdmit(authority, 25_999));
    try std.testing.expect(!runtime.canAdmit(authority, 26_000));
    try std.testing.expect(runtime.canComplete(authority, 30_999));
    try std.testing.expect(!runtime.canComplete(authority, 31_000));
}

test "unknown renewal never extends the current window" {
    var runtime = try Runtime.init(boot_a);
    const current = testToken(lease_a, 7);
    _ = try runtime.stage(current, 1_000);
    try runtime.markReady(lease_a, 2_000);
    const renewal = testToken(lease_b, 7);
    _ = try runtime.stage(renewal, 12_000);
    try std.testing.expect(runtime.canAdmit(current, 25_000));
    try std.testing.expect(!runtime.canAdmit(current, 26_000));
    try std.testing.expect(!runtime.canAdmit(renewal, 12_000));
}

test "pause and boot changes fail closed" {
    var runtime = try Runtime.init(boot_a);
    const authority = testToken(lease_a, 7);
    _ = try runtime.stage(authority, 1_000);
    try runtime.markReady(lease_a, 2_000);
    try std.testing.expect(!runtime.canAdmit(authority, 40_000));

    var restarted = try Runtime.init(boot_b);
    try std.testing.expectError(error.BootMismatch, restarted.stage(authority, 40_000));
    try std.testing.expect(!restarted.canComplete(authority, 40_000));
}

test "ready requires a fresh committed candidate" {
    var runtime = try Runtime.init(boot_a);
    const authority = testToken(lease_a, 7);
    _ = try runtime.stage(authority, 1_000);
    try std.testing.expectError(error.InsufficientWindow, runtime.markReady(lease_a, 21_001));
    try std.testing.expect(!runtime.canAdmit(authority, 21_001));
}

test "older candidate cannot replace newer authority" {
    var runtime = try Runtime.init(boot_a);
    _ = try runtime.stage(testToken(lease_a, 9), 1_000);
    try std.testing.expectError(error.StaleAuthority, runtime.stage(testToken(lease_b, 8), 2_000));
    try runtime.markReady(lease_a, 3_000);
    try std.testing.expect(runtime.canAdmit(testToken(lease_a, 9), 3_000));
}
