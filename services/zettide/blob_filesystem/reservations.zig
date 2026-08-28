const std = @import("std");
const blob_file = @import("../blob_file.zig");

pub fn contains(comptime Reservation: type, current: []const Reservation, block: u64) bool {
    for (current) |reservation| {
        if (block < reservation.start) return false;
        if (block < reservation.end) return true;
    }
    return false;
}

pub fn merge(
    comptime Reservation: type,
    allocator: std.mem.Allocator,
    current: []const Reservation,
    added: Reservation,
) ![]Reservation {
    std.debug.assert(added.start < added.end);
    var result: std.ArrayList(Reservation) = .empty;
    defer result.deinit(allocator);
    var merged = added;
    var inserted = false;
    for (current) |reservation| {
        if (reservation.end < merged.start) {
            try result.append(allocator, reservation);
        } else if (merged.end < reservation.start) {
            if (!inserted) {
                try result.append(allocator, merged);
                inserted = true;
            }
            try result.append(allocator, reservation);
        } else {
            merged.start = @min(merged.start, reservation.start);
            merged.end = @max(merged.end, reservation.end);
        }
    }
    if (!inserted) try result.append(allocator, merged);
    return result.toOwnedSlice(allocator);
}

pub fn clip(
    comptime Reservation: type,
    allocator: std.mem.Allocator,
    current: []const Reservation,
    size: u64,
) ![]Reservation {
    const end_block = try std.math.divCeil(u64, size, blob_file.block_size);
    var result: std.ArrayList(Reservation) = .empty;
    defer result.deinit(allocator);
    for (current) |reservation| {
        if (reservation.start >= end_block) break;
        try result.append(allocator, .{
            .start = reservation.start,
            .end = @min(reservation.end, end_block),
        });
    }
    return result.toOwnedSlice(allocator);
}
