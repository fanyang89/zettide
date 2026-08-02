//! Resolution of indeterminate conditional publications.

const std = @import("std");
const anchor = @import("anchor.zig");
const commit = @import("commit.zig");
const store_mod = @import("store.zig");

pub const Attempt = struct {
    base_generation: u64,
    transaction_id: store_mod.TransactionId,
};

pub const Options = struct {
    max_depth: usize = 1024,
};

pub const Resolution = enum {
    committed,
    not_committed,
    /// The base anchor is still current, so the request may still take effect.
    pending,
};

pub const Error = error{
    GenerationOverflow,
    AnchorGenerationRegression,
    MissingCommit,
    CommitGenerationMismatch,
    AnchorCommitMismatch,
    TransactionGenerationMismatch,
    BrokenAncestry,
    AncestryTooDeep,
};

/// Resolves whether one specific publish request entered the current commit
/// ancestry. Errors mean the outcome cannot be determined safely.
pub fn resolve(
    store: store_mod.ConditionalStore,
    allocator: std.mem.Allocator,
    attempt: Attempt,
    options: Options,
) !Resolution {
    const attempted_generation = std.math.add(u64, attempt.base_generation, 1) catch
        return error.GenerationOverflow;
    var snapshot = try store.readAnchor(allocator);
    defer snapshot.deinit();
    const current = try anchor.decode(&snapshot.anchor);

    if (current.generation < attempt.base_generation) return error.AnchorGenerationRegression;
    if (current.generation == attempt.base_generation) return .pending;

    const distance = current.generation - attempted_generation + 1;
    const max_depth = std.math.cast(u64, options.max_depth) orelse std.math.maxInt(u64);
    if (distance > max_depth) return error.AncestryTooDeep;

    var object_ref = current.head orelse return error.MissingCommit;
    var expected_generation = current.generation;
    var first = true;
    while (expected_generation >= attempted_generation) : (expected_generation -= 1) {
        var bytes = try store.loadImmutable(object_ref, allocator);
        defer bytes.deinit();
        const record = try commit.decode(bytes.bytes);

        if (record.generation != expected_generation) return error.CommitGenerationMismatch;
        if (first and !std.mem.eql(u8, &record.transaction_id, &current.transaction_id))
            return error.AnchorCommitMismatch;
        if (std.mem.eql(u8, &record.transaction_id, &attempt.transaction_id)) {
            if (expected_generation != attempted_generation)
                return error.TransactionGenerationMismatch;
            return .committed;
        }
        if (expected_generation == attempted_generation) return .not_committed;

        object_ref = record.parent orelse return error.BrokenAncestry;
        first = false;
    }
    unreachable;
}
