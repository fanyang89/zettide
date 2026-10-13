const std = @import("std");
const Id = @import("model.zig").Id;

pub const duration_ms: u64 = 30_000;
pub const early_stop_margin_ms: u64 = 5_000;
pub const block_size: u64 = 4096;
pub const max_leases: usize = 10_000;
pub const max_inflight: usize = 4096;
pub const Mode = enum { read, write };

pub const Token = struct {
    lease_id: Id,
    volume_id: Id,
    holder_node_id: Id,
    holder_boot_id: Id,
    offset: u64,
    length: u64,
    mode: Mode,
    revision: u64,
};

pub fn validRange(offset: u64, length: u64, capacity: u64) bool {
    return length != 0 and offset % block_size == 0 and length % block_size == 0 and
        offset <= capacity and length <= capacity - offset;
}

pub fn overlaps(a_offset: u64, a_length: u64, b_offset: u64, b_length: u64) bool {
    if (a_length == 0 or b_length == 0) return false;
    // Subtraction avoids overflow even for untrusted endpoints.
    return if (a_offset <= b_offset) b_offset - a_offset < a_length else a_offset - b_offset < b_length;
}

pub fn conflicts(a_mode: Mode, a_offset: u64, a_length: u64, b_mode: Mode, b_offset: u64, b_length: u64) bool {
    return (a_mode == .write or b_mode == .write) and overlaps(a_offset, a_length, b_offset, b_length);
}

const Entry = struct {
    token: Token,
    deadline_ms: u64,
    closed: bool = false,
    revoke_revision: u64 = 0,
    inflight: usize = 0,
};
pub const Ticket = struct { id: u64 };
const Admitted = struct { lease_id: Id, deadline_ms: u64 };

/// Caller-serialized process-local gate. Callers must synchronize every method,
/// including installation and revocation, with their I/O admission path.
/// A ticket must remain live until the underlying I/O has actually drained,
/// even when its caller times out. This is authorization, not backend readiness.
pub const Gate = struct {
    allocator: std.mem.Allocator,
    node_id: Id,
    boot_id: Id,
    entries: std.AutoHashMapUnmanaged(Id, Entry) = .empty,
    tickets: std.AutoHashMapUnmanaged(u64, Admitted) = .empty,
    next_ticket: u64 = 1,
    last_now_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, node_id: Id, boot_id: Id) !Gate {
        if (zero(node_id) or zero(boot_id)) return error.InvalidIdentity;
        return .{ .allocator = allocator, .node_id = node_id, .boot_id = boot_id };
    }
    pub fn deinit(self: *Gate) void {
        std.debug.assert(self.tickets.count() == 0);
        self.entries.deinit(self.allocator);
        self.tickets.deinit(self.allocator);
        self.* = undefined;
    }

    /// Anchor expiration BEFORE sending Acquire/Renew, never at reply arrival.
    /// Exact response retries never extend an already installed deadline.
    pub fn install(self: *Gate, token: Token, request_started_ms: u64, now_ms: u64) !void {
        try self.checkClock(now_ms);
        try self.validateToken(token);
        if (request_started_ms > now_ms) return error.InvalidClock;
        const deadline = std.math.add(u64, request_started_ms, duration_ms) catch return error.InvalidClock;
        if (now_ms >= deadline - early_stop_margin_ms) return error.LeaseExpired;
        if (self.entries.getPtr(token.lease_id)) |entry| {
            if (entry.closed) return error.LeaseRevoked;
            if (token.revision < entry.token.revision) return error.StaleToken;
            if (!sameBinding(token, entry.token)) return error.BindingMismatch;
            if (token.revision == entry.token.revision) return;
            if (now_ms >= entry.deadline_ms - early_stop_margin_ms) return error.LeaseExpired;
            entry.token = token;
            entry.deadline_ms = deadline;
        } else {
            if (self.entries.count() >= max_leases) return error.LeaseLimit;
            try self.entries.put(self.allocator, token.lease_id, .{ .token = token, .deadline_ms = deadline });
        }
    }

    pub fn begin(self: *Gate, token: Token, volume_id: Id, offset: u64, length: u64, mode: Mode, now_ms: u64) !Ticket {
        try self.checkClock(now_ms);
        const entry = self.entries.getPtr(token.lease_id) orelse return error.LeaseNotInstalled;
        if (!std.meta.eql(entry.token, token) or !std.mem.eql(u8, &token.volume_id, &volume_id)) return error.BindingMismatch;
        if (entry.closed) return error.LeaseRevoked;
        if (now_ms >= entry.deadline_ms - early_stop_margin_ms) return error.LeaseExpired;
        if (mode == .write and token.mode != .write) return error.ReadOnly;
        if (!validRange(offset, length, std.math.maxInt(u64)) or offset < token.offset or
            offset - token.offset > token.length or length > token.length - (offset - token.offset)) return error.OutOfRange;
        if (self.tickets.count() >= max_inflight) return error.InflightLimit;
        const id = self.next_ticket;
        const next = std.math.add(u64, id, 1) catch return error.TicketExhausted;
        try self.tickets.put(self.allocator, id, .{ .lease_id = token.lease_id, .deadline_ms = entry.deadline_ms });
        self.next_ticket = next;
        entry.inflight += 1;
        return .{ .id = id };
    }

    /// Must be called only after physical I/O completion/cancellation has drained.
    pub fn finish(self: *Gate, ticket: Ticket, now_ms: u64) !void {
        const admitted = self.tickets.fetchRemove(ticket.id) orelse return error.UnknownTicket;
        self.entries.getPtr(admitted.value.lease_id).?.inflight -= 1;
        try self.checkClock(now_ms);
        if (now_ms >= admitted.value.deadline_ms) return error.LeaseExpired;
    }

    /// Retain a tombstone even if revocation arrives before the grant reply.
    pub fn revoke(self: *Gate, token: Token, revoke_revision: u64) !void {
        try self.validateToken(token);
        if (revoke_revision <= token.revision) return error.StaleToken;
        if (self.entries.getPtr(token.lease_id)) |entry| {
            if (!sameBinding(entry.token, token) or token.revision < entry.token.revision) return error.BindingMismatch;
            if (entry.revoke_revision > revoke_revision) return error.StaleToken;
            entry.closed = true;
            entry.revoke_revision = revoke_revision;
            entry.token = token;
        } else {
            if (self.entries.count() >= max_leases) return error.LeaseLimit;
            try self.entries.put(self.allocator, token.lease_id, .{ .token = token, .deadline_ms = 0, .closed = true, .revoke_revision = revoke_revision });
        }
    }

    pub fn drained(self: *const Gate, lease_id: Id, revoke_revision: u64) bool {
        const entry = self.entries.get(lease_id) orelse return false;
        return entry.closed and entry.revoke_revision == revoke_revision and entry.inflight == 0;
    }

    fn checkClock(self: *Gate, now_ms: u64) !void {
        if (now_ms < self.last_now_ms) return error.InvalidClock;
        self.last_now_ms = now_ms;
    }
    fn validateToken(self: *const Gate, token: Token) !void {
        if (!std.mem.eql(u8, &token.holder_node_id, &self.node_id) or !std.mem.eql(u8, &token.holder_boot_id, &self.boot_id)) return error.HolderMismatch;
        if (zero(token.lease_id) or zero(token.volume_id) or token.revision == 0 or !validRange(token.offset, token.length, std.math.maxInt(u64))) return error.InvalidToken;
    }
};

fn sameBinding(a: Token, b: Token) bool {
    var normalized = a;
    normalized.revision = b.revision;
    return std.meta.eql(normalized, b);
}
fn zero(id: Id) bool {
    return std.mem.allEqual(u8, &id, 0);
}

fn tokenForTest() Token {
    return .{ .lease_id = @splat(1), .volume_id = @splat(2), .holder_node_id = @splat(3), .holder_boot_id = @splat(4), .offset = 4096, .length = 8192, .mode = .read, .revision = 10 };
}

test "range conflicts are shared read exclusive write and overflow safe" {
    try std.testing.expect(!conflicts(.read, 0, 8192, .read, 4096, 8192));
    try std.testing.expect(conflicts(.read, 0, 8192, .write, 4096, 8192));
    try std.testing.expect(conflicts(.write, 0, 8192, .write, 4096, 8192));
    try std.testing.expect(!conflicts(.write, 0, 4096, .write, 4096, 4096));
    try std.testing.expect(!validRange(std.math.maxInt(u64) - 4095, 4096, std.math.maxInt(u64)));
}

test "gate validates scope mode boot and drains before revoke acknowledgement" {
    var token = tokenForTest();
    var gate = try Gate.init(std.testing.allocator, token.holder_node_id, token.holder_boot_id);
    defer gate.deinit();
    try gate.install(token, 100, 101);
    try std.testing.expectError(error.ReadOnly, gate.begin(token, token.volume_id, 4096, 4096, .write, 102));
    try std.testing.expectError(error.OutOfRange, gate.begin(token, token.volume_id, 0, 4096, .read, 102));
    const ticket = try gate.begin(token, token.volume_id, 4096, 4096, .read, 102);
    try gate.revoke(token, 11);
    try std.testing.expect(!gate.drained(token.lease_id, 11));
    try std.testing.expectError(error.LeaseRevoked, gate.begin(token, token.volume_id, 4096, 4096, .read, 103));
    try gate.finish(ticket, 104);
    try std.testing.expect(gate.drained(token.lease_id, 11));
    try std.testing.expectError(error.UnknownTicket, gate.finish(ticket, 104));
    try std.testing.expectError(error.LeaseRevoked, gate.install(token, 105, 106));
    token.holder_boot_id = @splat(5);
    try std.testing.expectError(error.HolderMismatch, gate.install(token, 107, 108));
}

test "gate never extends replay deadlines or resurrects revoked delayed grants" {
    const token = tokenForTest();
    var gate = try Gate.init(std.testing.allocator, token.holder_node_id, token.holder_boot_id);
    defer gate.deinit();
    try gate.install(token, 100, 200);
    try gate.install(token, 5000, 6000);
    try std.testing.expectError(error.LeaseExpired, gate.begin(token, token.volume_id, 4096, 4096, .read, 25_100));
    var renewal = token;
    renewal.revision = 11;
    try std.testing.expectError(error.LeaseExpired, gate.install(renewal, 25_000, 25_101));
    var late = token;
    late.lease_id = @splat(9);
    try gate.revoke(late, 12);
    try std.testing.expect(gate.drained(late.lease_id, 12));
    try std.testing.expectError(error.LeaseRevoked, gate.install(late, 25_102, 25_103));
}

test "renewal fences old-token admission without extending old I/O deadlines" {
    var token = tokenForTest();
    token.mode = .write;
    var gate = try Gate.init(std.testing.allocator, token.holder_node_id, token.holder_boot_id);
    defer gate.deinit();
    try gate.install(token, 100, 101);
    const read = try gate.begin(token, token.volume_id, 4096, 4096, .read, 102);
    const write = try gate.begin(token, token.volume_id, 8192, 4096, .write, 103);
    var renewed = token;
    renewed.revision = 11;
    try gate.install(renewed, 10_000, 10_001);
    try std.testing.expectError(error.BindingMismatch, gate.begin(token, token.volume_id, 4096, 4096, .read, 10_002));
    try gate.revoke(renewed, 12);
    try gate.finish(read, 10_003);
    try std.testing.expect(!gate.drained(token.lease_id, 12));
    try std.testing.expectError(error.LeaseExpired, gate.finish(write, 30_100));
    try std.testing.expect(gate.drained(token.lease_id, 12));
    try std.testing.expectError(error.InvalidClock, gate.begin(renewed, token.volume_id, 4096, 4096, .read, 30_000));
}
