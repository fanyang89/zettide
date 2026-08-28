const std = @import("std");
const Io = std.Io;
const zettide = @import("zettide");

pub fn printFuseMetrics(writer: *Io.Writer, metrics: zettide.linux_fuse.Metrics) !void {
    try writer.print(
        "fuse_metrics read_calls={} read_bytes={} read_errors={} read_elapsed_ns={} read_max_ns={} write_calls={} write_bytes={} write_errors={} write_elapsed_ns={} write_max_ns={} flush_calls={} flush_errors={} flush_elapsed_ns={} flush_max_ns={} fsync_calls={} fsync_errors={} fsync_elapsed_ns={} fsync_max_ns={} release_calls={} release_errors={} release_elapsed_ns={} release_max_ns={}\n",
        .{
            metrics.read.calls,
            metrics.read.bytes,
            metrics.read.errors,
            metrics.read.elapsed_ns,
            metrics.read.max_ns,
            metrics.write.calls,
            metrics.write.bytes,
            metrics.write.errors,
            metrics.write.elapsed_ns,
            metrics.write.max_ns,
            metrics.flush.calls,
            metrics.flush.errors,
            metrics.flush.elapsed_ns,
            metrics.flush.max_ns,
            metrics.fsync.calls,
            metrics.fsync.errors,
            metrics.fsync.elapsed_ns,
            metrics.fsync.max_ns,
            metrics.release.calls,
            metrics.release.errors,
            metrics.release.elapsed_ns,
            metrics.release.max_ns,
        },
    );
}

pub fn printPoolTransportMetrics(writer: *Io.Writer, stats: zettide.v3.storage.TransportStats) !void {
    try writer.print(
        "pool_transport_metrics queue_capacity={} submitted_sqes={} submit_calls={} completions={} current_inflight={} max_inflight={}\n",
        .{
            stats.queue_capacity,
            stats.submitted_sqes,
            stats.submit_calls,
            stats.completions,
            stats.current_inflight,
            stats.max_inflight,
        },
    );
}

pub fn currentOwner() struct { uid: u32, gid: u32 } {
    if (comptime @import("builtin").os.tag == .linux) return .{
        .uid = @intCast(std.os.linux.getuid()),
        .gid = @intCast(std.os.linux.getgid()),
    };
    return .{ .uid = 0, .gid = 0 };
}

pub fn requireBlobPath(io: Io, path: []const u8) !void {
    switch (try zettide.filesystem_target.classifyPath(io, path)) {
        .blob => {},
        .littlefs_container => return error.UnsupportedLegacyFormat,
        .pool_member => return error.PoolTargetRequiresPoolCommand,
        .unknown => return error.UnsupportedFilesystemFormat,
    }
}

pub fn printUuid(writer: *Io.Writer, uuid: [16]u8) !void {
    for (uuid, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) try writer.writeByte('-');
        try writer.print("{x:0>2}", .{byte});
    }
}
