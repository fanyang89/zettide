//! Backend-neutral conditional publication contract.

const std = @import("std");

/// Globally unique for each logical transaction. Publication resolution relies
/// on identifiers never being reused.
pub const TransactionId = [16]u8;
pub const anchor_size = 512;
pub const Anchor = [anchor_size]u8;
pub const object_ref_size = 64;

/// A backend-owned locator. Callers may compare and persist it, but must not
/// interpret its bytes.
pub const ObjectRef = struct {
    bytes: [object_ref_size]u8 = @splat(0),

    pub fn eql(a: ObjectRef, b: ObjectRef) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const OwnedBytes = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn dupe(allocator: std.mem.Allocator, bytes: []const u8) !OwnedBytes {
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, bytes),
        };
    }

    pub fn deinit(self: *OwnedBytes) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const AnchorSnapshot = struct {
    anchor: Anchor,
    version: OwnedBytes,

    pub fn deinit(self: *AnchorSnapshot) void {
        self.version.deinit();
        self.* = undefined;
    }
};

pub const PublishResult = enum {
    /// The replacement definitely occurred.
    committed,
    /// The expected version was stale and no replacement occurred.
    conflict,
    /// The caller must inspect commit ancestry before deciding what occurred.
    indeterminate,
};

/// A store may be shared between threads. Owned return values follow Zig's
/// move-only convention and must not be copied. A WriteBatch has one caller and
/// must be destroyed before its store backend.
pub const ConditionalStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_anchor: *const fn (*anyopaque, std.mem.Allocator) anyerror!AnchorSnapshot,
        load_immutable: *const fn (*anyopaque, ObjectRef, std.mem.Allocator) anyerror!OwnedBytes,
        begin_batch: *const fn (*anyopaque, std.mem.Allocator, TransactionId) anyerror!WriteBatch,
    };

    pub fn readAnchor(self: ConditionalStore, allocator: std.mem.Allocator) !AnchorSnapshot {
        return self.vtable.read_anchor(self.context, allocator);
    }

    pub fn loadImmutable(
        self: ConditionalStore,
        object_ref: ObjectRef,
        allocator: std.mem.Allocator,
    ) !OwnedBytes {
        return self.vtable.load_immutable(self.context, object_ref, allocator);
    }

    pub fn beginBatch(
        self: ConditionalStore,
        allocator: std.mem.Allocator,
        transaction_id: TransactionId,
    ) !WriteBatch {
        return self.vtable.begin_batch(self.context, allocator, transaction_id);
    }
};

pub const WriteBatch = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put_immutable: *const fn (*anyopaque, []const u8) anyerror!ObjectRef,
        prepare: *const fn (*anyopaque) anyerror!void,
        publish: *const fn (*anyopaque, []const u8, *const Anchor) anyerror!PublishResult,
        stabilize: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn putImmutable(self: *WriteBatch, bytes: []const u8) !ObjectRef {
        return self.vtable.put_immutable(self.context, bytes);
    }

    pub fn prepare(self: *WriteBatch) !void {
        return self.vtable.prepare(self.context);
    }

    /// Atomically replaces the anchor when `expected_version` still matches.
    ///
    /// An error is permitted only before the replacement request may have
    /// reached storage. Transport failures after dispatch must be returned as
    /// `.indeterminate`. Every logical anchor must contain a monotonically
    /// changing generation and must never reuse an earlier physical value.
    pub fn publish(
        self: *WriteBatch,
        expected_version: []const u8,
        next_anchor: *const Anchor,
    ) !PublishResult {
        return self.vtable.publish(self.context, expected_version, next_anchor);
    }

    /// May be retried until durability is known.
    pub fn stabilize(self: *WriteBatch) !void {
        return self.vtable.stabilize(self.context);
    }

    pub fn deinit(self: *WriteBatch) void {
        self.vtable.deinit(self.context);
        self.* = undefined;
    }
};
