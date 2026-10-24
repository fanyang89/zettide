const std = @import("std");
const engine = @import("zettide_storage").v3;
const data_node = @import("zettide_data_node");
const fixture = @import("catalog_fixture.zig");
const volume_api = engine.pool_catalog_volume;
const allocator = std.testing.allocator;
const io = std.testing.io;

test "Catalog Volume preserves one- and three-member data through read-only reopen" {
    inline for ([_]usize{ 1, 3 }) |count| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var set = try fixture.createSet(io, allocator, tmp.dir, count);
        defer set.deinit();
        const volume_id = try fixture.publishMapped(io, &set);
        if (count == 3) {
            var blocked = try ((try set.memberAt(1)).?).claimData();
            defer blocked.release() catch unreachable;
            try std.testing.expectError(error.DataAlreadyClaimed, volume_api.CatalogDataLease.acquire(&set));
            // A failed acquisition must roll back earlier claims without
            // releasing another owner's claim on the blocked Member.
            for ([_]usize{ 0, 2 }) |index| {
                var available = try ((try set.memberAt(index)).?).claimData();
                try available.release();
            }
            try std.testing.expectError(error.DataAlreadyClaimed, ((try set.memberAt(1)).?).claimData());
            try blocked.release();
        }
        var lease = try volume_api.CatalogDataLease.acquire(&set);
        defer lease.deinit();
        var volume = try volume_api.CatalogVolumeBackend.openWritable(allocator, &lease, volume_id);
        try std.testing.expectError(error.DataAlreadyClaimed, volume_api.CatalogDataLease.acquire(&set));
        const expected: [4096]u8 = @splat(0x5a);
        try volume.write(&lease, 0, &expected);
        try volume.flush(&lease);
        var actual: [4096]u8 = undefined;
        try volume.read(0, &actual);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        for (0..count) |index| {
            const member = (try set.memberAt(index)).?;
            try member.read(.data, 0, &actual);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
            try std.testing.expectError(error.DataGenerationLeaseRequired, member.write(.data, 0, &expected));
        }
        try volume.read(4096, &actual);
        try std.testing.expect(std.mem.allEqual(u8, &actual, 0));
        const crosses_hole: [8192]u8 = @splat(0xa5);
        try std.testing.expectError(error.ExtentNotMapped, volume.write(&lease, 0, &crosses_hole));
        try volume.read(0, &actual);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectError(error.ExtentNotMapped, volume.write(&lease, 4096, &expected));
        try std.testing.expectError(error.OutOfBounds, volume.write(&lease, volume.logicalSize(), &expected));
        try std.testing.expect(set.controlWriteReady() != null);
        lease.release();
        try std.testing.expectError(error.DataLeaseReleased, volume.flush(&lease));
        try set.close();

        var reopened = try fixture.reopenSet(io, allocator, tmp.dir, count, .read_only);
        defer reopened.deinit();
        try std.testing.expectError(error.DataWriteUnavailable, volume_api.CatalogDataLease.acquire(&reopened));
        volume = try volume_api.CatalogVolumeBackend.open(allocator, &reopened, volume_id);
        try volume.read(0, &actual);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "Catalog replicated reads require two matching copies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var set = try fixture.createSet(io, allocator, tmp.dir, 3);
    defer set.deinit();
    const volume_id = try fixture.publishMapped(io, &set);
    var lease = try volume_api.CatalogDataLease.acquire(&set);
    defer lease.deinit();
    var volume = try volume_api.CatalogVolumeBackend.openWritable(allocator, &lease, volume_id);
    const expected: [4096]u8 = @splat(0x5a);
    try volume.write(&lease, 0, &expected);
    try volume.flush(&lease);
    var actual: [4096]u8 = undefined;
    // Deliberately corrupt the underlying media, bypassing claims only in this
    // test. Catalog reads must not trust the first readable replica.
    const first = (try set.memberAt(0)).?;
    const second = (try set.memberAt(1)).?;
    const corrupt_first: [4096]u8 = @splat(0x11);
    const corrupt_second: [4096]u8 = @splat(0x22);
    try first.storage.writeAllAt(io, &corrupt_first, first.header().data.offset);
    try volume.read(0, &actual);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try second.storage.writeAllAt(io, &corrupt_second, second.header().data.offset);
    try std.testing.expectError(error.ReplicaQuorumUnavailable, volume.read(0, &actual));
}

test "Catalog write and flush faults on any replica freeze the whole lease" {
    const Failure = enum { write_before, write_partial, write_after, sync_before, sync_after };
    inline for (std.enums.values(Failure)) |failure| {
        for (0..3) |failed_index| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var set = try fixture.createSet(io, allocator, tmp.dir, 3);
            defer set.deinit();
            const volume_id = try fixture.publishMapped(io, &set);
            var lease = try volume_api.CatalogDataLease.acquire(&set);
            defer lease.deinit();
            var volume = try volume_api.CatalogVolumeBackend.openWritable(allocator, &lease, volume_id);
            var faults: [3]engine.member.FaultController = @splat(.{});
            defer for (0..3) |index| ((set.memberAt(index) catch unreachable).?).setFaultController(null);
            for (&faults, 0..) |*fault, index| ((try set.memberAt(index)).?).setFaultController(fault);
            const failed = &faults[failed_index];
            switch (failure) {
                .write_before => failed.fail_write_at = 0,
                .write_partial => failed.fail_write_partial_at = 0,
                .write_after => failed.fail_write_after_at = 0,
                .sync_before => failed.fail_sync_at = 0,
                .sync_after => failed.fail_sync_after_at = 0,
            }
            const expected: [4096]u8 = @splat(0x5a);
            const sync_failure = failure == .sync_before or failure == .sync_after;
            if (sync_failure) {
                try volume.write(&lease, 0, &expected);
                try std.testing.expectError(error.InjectedFault, volume.flush(&lease));
            } else {
                try std.testing.expectError(error.InjectedFault, volume.write(&lease, 0, &expected));
            }
            try std.testing.expectError(error.WriteFrozen, volume.write(&lease, 0, &expected));
            try std.testing.expectError(error.WriteFrozen, volume.flush(&lease));
            try std.testing.expect(set.controlWriteReady() == null);
            try std.testing.expectEqual(.unavailable, set.dataAccess());
            for (faults) |fault| {
                // Every placement is attempted, but nothing queued after the
                // failure may reach storage or acknowledge a successful flush.
                try std.testing.expectEqual(@as(u64, 1), fault.write_count);
                try std.testing.expectEqual(@as(u64, @intFromBool(sync_failure)), fault.sync_count);
            }
        }
    }
}

test "Catalog worker drains ordered writes and flush and freezes queued requests" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const worker_api = data_node.spdk_catalog_volume_backend;
    const c = worker_api.c;
    const Completion = struct {
        log: *Log,
        index: usize,

        const Log = struct {
            count: std.atomic.Value(usize) = .init(0),
            order: [4]usize = undefined,
            status: [4]c_int = undefined,
        };

        fn complete(context: ?*anyopaque, status: c_int) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const index = self.log.count.fetchAdd(1, .acq_rel);
            self.log.order[index] = self.index;
            self.log.status[self.index] = status;
        }
    };
    inline for ([_]bool{ false, true }) |fail_first| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var set = try fixture.createSet(io, allocator, tmp.dir, 3);
        defer set.deinit();
        const volume_id = try fixture.publishMapped(io, &set);
        var pause: engine.member.FaultPause = .{};
        var fault: engine.member.FaultController = .{
            .pause_after_write = &pause,
            .fail_write_after_at = if (fail_first) 0 else null,
        };
        const member = (try set.memberAt(0)).?;
        member.setFaultController(&fault);
        defer member.setFaultController(null);
        var log: Completion.Log = .{};
        var completions: [4]Completion = undefined;
        for (&completions, 0..) |*completion, index| completion.* = .{ .log = &log, .index = index };
        const first: [4096]u8 = @splat(0x11);
        const second: [4096]u8 = @splat(0x22);
        var actual: [4096]u8 = undefined;
        const worker = try worker_api.Worker.create(allocator, io, &set, volume_id);
        var worker_open = true;
        defer if (worker_open) worker.close();
        defer pause.released.store(true, .release);
        try std.testing.expectEqual(@as(c_int, 0), worker_api.Worker.submit(worker, c.ZETTIDE_SPDK_BDEV_PROVIDER_WRITE, 0, @constCast(&first), first.len, Completion.complete, &completions[0]));
        for (0..5000) |_| {
            if (pause.reached.load(.acquire)) break;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(pause.reached.load(.acquire));
        try std.testing.expectEqual(@as(c_int, 0), worker_api.Worker.submit(worker, c.ZETTIDE_SPDK_BDEV_PROVIDER_WRITE, 0, @constCast(&second), second.len, Completion.complete, &completions[1]));
        try std.testing.expectEqual(@as(c_int, 0), worker_api.Worker.submit(worker, c.ZETTIDE_SPDK_BDEV_PROVIDER_FLUSH, 0, null, 0, Completion.complete, &completions[2]));
        try std.testing.expectEqual(@as(c_int, 0), worker_api.Worker.submit(worker, c.ZETTIDE_SPDK_BDEV_PROVIDER_READ, 0, &actual, actual.len, Completion.complete, &completions[3]));
        try std.testing.expectEqual(@as(usize, 0), log.count.load(.acquire));
        pause.released.store(true, .release);
        worker.close();
        worker_open = false;
        try std.testing.expectEqual(@as(usize, 4), log.count.load(.acquire));
        try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, &log.order);
        if (fail_first) {
            try std.testing.expectEqualSlices(c_int, &.{ -c.EIO, -c.EBADF, -c.EBADF, -c.ENODEV }, &log.status);
            try std.testing.expectEqual(@as(u64, 1), fault.write_count);
            try std.testing.expectEqual(@as(u64, 0), fault.sync_count);
            try std.testing.expectEqual(.unavailable, set.dataAccess());
        } else {
            try std.testing.expectEqualSlices(c_int, &.{ 0, 0, 0, 0 }, &log.status);
            try std.testing.expectEqualSlices(u8, &second, &actual);
            try std.testing.expectEqual(@as(u64, 2), fault.write_count);
            try std.testing.expectEqual(@as(u64, 1), fault.sync_count);
            for (0..3) |index| {
                try ((try set.memberAt(index)).?).read(.data, 0, &actual);
                try std.testing.expectEqualSlices(u8, &second, &actual);
            }
        }
    }
}
