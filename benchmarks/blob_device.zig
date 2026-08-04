const std = @import("std");
const builtin = @import("builtin");
const zettide = @import("zettide");

const Io = std.Io;
const Device = zettide.blob_device.Device;
const FileIoMode = zettide.v3.file_storage.Mode;

const Operation = enum {
    read,
    write,

    fn parse(value: []const u8) !Operation {
        if (std.mem.eql(u8, value, "read")) return .read;
        if (std.mem.eql(u8, value, "write")) return .write;
        return error.InvalidOperation;
    }
};

const Config = struct {
    operation: Operation = .write,
    path: ?[]const u8 = null,
    size: u64 = 8 * 1024 * 1024 * 1024,
    block_size: usize = 1024 * 1024,
    batch_depth: usize = zettide.blob_device.max_batch,
    file_io: FileIoMode = .posix,
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = parseArgs(args) catch |err| {
        std.debug.print("invalid arguments: {s}\n", .{@errorName(err)});
        return err;
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};
    if (config.help) return usage(stdout);
    const path = config.path orelse return error.MissingPath;

    const file = switch (config.operation) {
        .write => try Io.Dir.createFileAbsolute(init.io, path, .{
            .read = true,
            .exclusive = true,
        }),
        .read => try Io.Dir.openFileAbsolute(init.io, path, .{
            .mode = .read_only,
            .lock = .shared,
            .lock_nonblocking = true,
        }),
    };
    var file_open = true;
    defer if (file_open) file.close(init.io);
    if (config.operation == .write) try file.setLength(init.io, config.size);
    if (try file.length(init.io) < config.size) return error.BenchmarkFileTooSmall;

    const storage = try zettide.v3.file_storage.initOwned(
        init.gpa,
        file,
        try file.length(init.io),
        config.operation == .write,
        false,
        config.file_io,
    );
    var device = try Device.init(storage, 0, config.size, 4096);
    file_open = false;
    defer device.close(init.io) catch {};

    const buffers = try init.gpa.alloc([]u8, config.batch_depth);
    defer init.gpa.free(buffers);
    var allocated: usize = 0;
    defer for (buffers[0..allocated]) |buffer| init.gpa.free(buffer);
    for (buffers) |*buffer| {
        buffer.* = try init.gpa.alignedAlloc(u8, .fromByteUnits(4096), config.block_size);
        allocated += 1;
        @memset(buffer.*, @intCast(allocated));
    }
    const operation_count = config.size / config.block_size;
    const latency_capacity = try std.math.divCeil(u64, operation_count, config.batch_depth);
    const latencies = try init.gpa.alloc(u64, @intCast(latency_capacity));
    defer init.gpa.free(latencies);
    var latency_count: usize = 0;

    try stdout.print(
        "benchmark=zettide_blob_device optimize={s} operation={s} path={s} size={} block_size={} batch_depth={} requested_file_io={s} selected_file_io={s}\n",
        .{
            @tagName(builtin.mode),
            @tagName(config.operation),
            path,
            config.size,
            config.block_size,
            config.batch_depth,
            @tagName(config.file_io),
            @tagName(device.transportKind()),
        },
    );
    try stdout.flush();

    device.resetTransportStats(init.io);
    const io_start = Io.Clock.awake.now(init.io).nanoseconds;
    const validation_elapsed: u64 = switch (config.operation) {
        .write => validation: {
            try runWrites(init.gpa, init.io, &device, buffers, config, latencies, &latency_count);
            break :validation 0;
        },
        .read => try runReads(init.gpa, init.io, &device, buffers, config, latencies, &latency_count),
    };
    const operation_elapsed: u64 = @intCast(Io.Clock.awake.now(init.io).nanoseconds - io_start);
    const io_elapsed = operation_elapsed - validation_elapsed;
    const transport = device.transportStats(init.io);
    try validateTransport(config, device.transportKind(), transport, operation_count);

    var sync_elapsed: u64 = 0;
    if (config.operation == .write) {
        const sync_start = Io.Clock.awake.now(init.io).nanoseconds;
        try device.syncData(init.io);
        sync_elapsed = @intCast(Io.Clock.awake.now(init.io).nanoseconds - sync_start);
    }
    const durable_elapsed = if (config.operation == .write) operation_elapsed + sync_elapsed else io_elapsed;
    const latency = latencySummary(latencies[0..latency_count]);
    try stdout.print(
        "blob_device_result operation={s} bytes={} block_size={} batch_depth={} operations={} io_elapsed_ns={} bytes_per_second={} iops={} latency_scope=batch latency_samples={} latency_avg_ns={} latency_p95_ns={} validation_elapsed_ns={} sync_elapsed_ns={} durable_bytes_per_second={} durable_iops={} total_bytes_per_second={} transport={s} operation_transport_queue_capacity={} operation_transport_submitted_sqes={} operation_transport_submit_calls={} operation_transport_completions={} operation_transport_current_inflight={} operation_transport_max_inflight={}\n",
        .{
            @tagName(config.operation),
            config.size,
            config.block_size,
            config.batch_depth,
            operation_count,
            io_elapsed,
            rate(config.size, io_elapsed),
            rate(operation_count, io_elapsed),
            latency_count,
            latency.average_ns,
            latency.p95_ns,
            validation_elapsed,
            sync_elapsed,
            rate(config.size, durable_elapsed),
            rate(operation_count, durable_elapsed),
            rate(config.size, operation_elapsed + sync_elapsed),
            @tagName(device.transportKind()),
            transport.queue_capacity,
            transport.submitted_sqes,
            transport.submit_calls,
            transport.completions,
            transport.current_inflight,
            transport.max_inflight,
        },
    );
}

fn runWrites(
    allocator: std.mem.Allocator,
    io: Io,
    device: *Device,
    buffers: []const []u8,
    config: Config,
    latencies: []u64,
    latency_count: *usize,
) !void {
    const writes = try allocator.alloc(zettide.blob_device.Write, buffers.len);
    defer allocator.free(writes);
    var offset: u64 = 0;
    while (offset < config.size) {
        const remaining_blocks = (config.size - offset) / config.block_size;
        const count: usize = @intCast(@min(remaining_blocks, buffers.len));
        for (writes[0..count], buffers[0..count], 0..) |*write, buffer, index| write.* = .{
            .bytes = buffer,
            .offset = offset + index * config.block_size,
        };
        const latency_start = Io.Clock.awake.now(io).nanoseconds;
        try device.writeAllManyAt(io, writes[0..count]);
        latencies[latency_count.*] = @intCast(Io.Clock.awake.now(io).nanoseconds - latency_start);
        latency_count.* += 1;
        offset += count * config.block_size;
    }
}

fn runReads(
    allocator: std.mem.Allocator,
    io: Io,
    device: *Device,
    buffers: []const []u8,
    config: Config,
    latencies: []u64,
    latency_count: *usize,
) !u64 {
    const reads = try allocator.alloc(zettide.blob_device.Read, buffers.len);
    defer allocator.free(reads);
    const results = try allocator.alloc(zettide.blob_device.ReadResult, buffers.len);
    defer allocator.free(results);
    var validation_elapsed: u64 = 0;
    var offset: u64 = 0;
    while (offset < config.size) {
        const remaining_blocks = (config.size - offset) / config.block_size;
        const count: usize = @intCast(@min(remaining_blocks, buffers.len));
        for (reads[0..count], buffers[0..count], 0..) |*read, buffer, index| read.* = .{
            .buffer = buffer,
            .offset = offset + index * config.block_size,
        };
        const latency_start = Io.Clock.awake.now(io).nanoseconds;
        try device.readManyAt(io, reads[0..count], results[0..count]);
        for (results[0..count]) |result| {
            if (result.failure) |err| return err;
            if (result.amount != config.block_size) return error.IncompleteBlobDeviceRead;
        }
        latencies[latency_count.*] = @intCast(Io.Clock.awake.now(io).nanoseconds - latency_start);
        latency_count.* += 1;
        const validation_start = Io.Clock.awake.now(io).nanoseconds;
        for (buffers[0..count], 0..) |buffer, index| {
            const expected: u8 = @intCast(index + 1);
            if (!std.mem.allEqual(u8, buffer, expected)) return error.BlobDeviceBenchmarkDataMismatch;
        }
        validation_elapsed += @intCast(Io.Clock.awake.now(io).nanoseconds - validation_start);
        offset += count * config.block_size;
    }
    return validation_elapsed;
}

const LatencySummary = struct {
    average_ns: u64,
    p95_ns: u64,
};

fn latencySummary(samples: []u64) LatencySummary {
    std.debug.assert(samples.len != 0);
    var total: u128 = 0;
    for (samples) |sample| total += sample;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const p95_index = (samples.len * 95 + 99) / 100 - 1;
    return .{
        .average_ns = @intCast(total / samples.len),
        .p95_ns = samples[p95_index],
    };
}

fn validateTransport(
    config: Config,
    kind: zettide.v3.storage.TransportKind,
    stats: zettide.v3.storage.TransportStats,
    operation_count: u64,
) !void {
    if (config.file_io == .io_uring and kind != .io_uring) return error.IoUringBackendNotSelected;
    if (kind != .io_uring) return;
    const expected_inflight = @min(
        operation_count,
        @as(u64, config.batch_depth),
        @as(u64, zettide.blob_device.max_batch),
    );
    if (stats.queue_capacity != 32 or
        stats.submitted_sqes < operation_count or
        stats.submitted_sqes != stats.completions or
        stats.current_inflight != 0 or
        stats.max_inflight != expected_inflight)
        return error.InvalidIoUringBenchmarkStats;
}

fn rate(bytes: u64, elapsed_ns: u64) u64 {
    if (elapsed_ns == 0) return std.math.maxInt(u64);
    return @intCast((@as(u128, bytes) * std.time.ns_per_s) / elapsed_ns);
}

fn parseArgs(args: []const []const u8) !Config {
    var result: Config = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--operation")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.operation = try .parse(args[index]);
        } else if (std.mem.eql(u8, arg, "--path")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.path = args[index];
        } else if (std.mem.eql(u8, arg, "--size")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.size = try zettide.size.parse(args[index]);
        } else if (std.mem.eql(u8, arg, "--block-size")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.block_size = std.math.cast(usize, try zettide.size.parse(args[index])) orelse
                return error.InvalidBlockSize;
        } else if (std.mem.eql(u8, arg, "--batch-depth")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.batch_depth = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--file-io")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.file_io = try .parse(args[index]);
        } else return error.UnknownArgument;
    }
    if (result.help) return result;
    if (result.path == null) return error.MissingPath;
    if (result.size == 0 or result.block_size == 0 or
        result.block_size % 4096 != 0 or result.size % result.block_size != 0)
        return error.InvalidBenchmarkGeometry;
    if (result.batch_depth == 0 or result.batch_depth > zettide.blob_device.max_batch)
        return error.InvalidBatchDepth;
    if (result.file_io != .posix and result.block_size > std.math.maxInt(u32))
        return error.BlockSizeTooLargeForIoUring;
    return result;
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zettide-blob-device-benchmark [options]
        \\
        \\Options:
        \\  --operation read|write  operation to run (default: write)
        \\  --path P               absolute benchmark file path
        \\  --size N               bytes to transfer (default: 8GiB)
        \\  --block-size N         request size (default: 1MiB)
        \\  --batch-depth N        requests per batch (default: 32)
        \\  --file-io NAME         auto, posix, or io_uring (default: posix)
        \\  --help                 show this help
        \\
    );
}

test "parse blob device benchmark options" {
    const config = try parseArgs(&.{
        "benchmark",
        "--operation",
        "read",
        "--path",
        "/tmp/blob",
        "--size",
        "64MiB",
        "--block-size",
        "1MiB",
        "--batch-depth",
        "16",
        "--file-io",
        "io_uring",
    });
    try std.testing.expectEqual(Operation.read, config.operation);
    try std.testing.expectEqualStrings("/tmp/blob", config.path.?);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), config.size);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), config.block_size);
    try std.testing.expectEqual(@as(usize, 16), config.batch_depth);
    try std.testing.expectEqual(FileIoMode.io_uring, config.file_io);
}

test "summarize blob device benchmark latency" {
    var samples = [_]u64{ 4, 1, 3, 2 };
    const summary = latencySummary(&samples);
    try std.testing.expectEqual(@as(u64, 2), summary.average_ns);
    try std.testing.expectEqual(@as(u64, 4), summary.p95_ns);
}

test "reject invalid blob device benchmark options" {
    try std.testing.expectError(error.MissingPath, parseArgs(&.{"benchmark"}));
    try std.testing.expectError(error.InvalidOperation, parseArgs(&.{ "benchmark", "--operation", "other" }));
    try std.testing.expectError(error.InvalidBatchDepth, parseArgs(&.{ "benchmark", "--path", "/tmp/blob", "--batch-depth", "33" }));
    try std.testing.expect((try parseArgs(&.{ "benchmark", "--help" })).help);
}
