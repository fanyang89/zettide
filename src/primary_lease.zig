const std = @import("std");
const Id = @import("root.zig").Id;

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

    pub fn markReady(self: *Runtime, lease_id: Id, now_ms: u64) !void {
        var candidate = self.candidate orelse return error.NoCandidate;
        if (!std.mem.eql(u8, &candidate.token.lease_id, &lease_id)) return error.LeaseMismatch;
        if (!self.canMarkReady(lease_id, now_ms)) return error.InsufficientWindow;
        candidate.ready = true;
        self.current = candidate;
        self.candidate = null;
    }

    pub fn canMarkReady(self: Runtime, lease_id: Id, now_ms: u64) bool {
        const candidate = self.candidate orelse return false;
        return std.mem.eql(u8, &candidate.token.lease_id, &lease_id) and
            now_ms < candidate.admission_deadline_ms and
            candidate.hard_deadline_ms - now_ms >= minimum_ready_remaining_ms;
    }

    pub fn canMarkReadyToken(self: Runtime, token: Token, now_ms: u64) bool {
        const candidate = self.candidate orelse return false;
        return std.meta.eql(token, candidate.token) and self.canMarkReady(token.lease_id, now_ms);
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

    pub fn shouldRenew(self: Runtime, token: Token, now_ms: u64) bool {
        const current = self.current orelse return false;
        return current.ready and std.meta.eql(token, current.token) and current.shouldRenew(now_ms);
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

const boot: Id = .{1} ++ @as([15]u8, @splat(0));
const lease: Id = .{2} ++ @as([15]u8, @splat(0));

test "lease stops admission before completion deadline" {
    var runtime = try Runtime.init(boot);
    const token: Token = .{ .lease_id = lease, .holder_boot_id = boot, .authority_generation = 1, .write_epoch = 1 };
    _ = try runtime.stage(token, 1_000);
    try runtime.markReady(lease, 2_000);
    try std.testing.expect(runtime.canAdmit(token, 25_999));
    try std.testing.expect(!runtime.canAdmit(token, 26_000));
    try std.testing.expect(runtime.canComplete(token, 30_999));
    try std.testing.expect(!runtime.canComplete(token, 31_000));
}

test "restart and stale authority fail closed" {
    var runtime = try Runtime.init(boot);
    const current: Token = .{ .lease_id = lease, .holder_boot_id = boot, .authority_generation = 2, .write_epoch = 2 };
    _ = try runtime.stage(current, 1_000);
    var stale = current;
    stale.lease_id[0] = 3;
    stale.authority_generation = 1;
    stale.write_epoch = 1;
    try std.testing.expectError(error.StaleAuthority, runtime.stage(stale, 2_000));

    var other_boot = boot;
    other_boot[0] = 4;
    var restarted = try Runtime.init(other_boot);
    try std.testing.expectError(error.BootMismatch, restarted.stage(current, 3_000));
}
