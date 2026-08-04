const std = @import("std");
const builtin = @import("builtin");
const zettide = @import("zettide");

const Io = std.Io;
const Device = zettide.blob_device.Device;

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

    const storage = zettide.v3.storage.Storage.initOwned(
        file,
        try file.length(init.io),
        .regular_file,
        1,
        false,
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

    try stdout.print(
        "benchmark=zettide_blob_device optimize={s} operation={s} path={s} size={} block_size={} batch_depth={}\n",
        .{
            @tagName(builtin.mode),
            @tagName(config.operation),
            path,
            config.size,
            config.block_size,
            config.batch_depth,
        },
    );
    try stdout.flush();

    const io_start = Io.Clock.awake.now(init.io).nanoseconds;
    switch (config.operation) {
        .write => try runWrites(init.gpa, init.io, &device, buffers, config),
        .read => try runReads(init.gpa, init.io, &device, buffers, config),
    }
    const io_elapsed: u64 = @intCast(Io.Clock.awake.now(init.io).nanoseconds - io_start);

    var sync_elapsed: u64 = 0;
    if (config.operation == .write) {
        const sync_start = Io.Clock.awake.now(init.io).nanoseconds;
        try device.syncData(init.io);
        sync_elapsed = @intCast(Io.Clock.awake.now(init.io).nanoseconds - sync_start);
    }
    const durable_elapsed = io_elapsed + sync_elapsed;
    try stdout.print(
        "blob_device_result operation={s} bytes={} io_elapsed_ns={} bytes_per_second={} sync_elapsed_ns={} durable_bytes_per_second={}\n",
        .{
            @tagName(config.operation),
            config.size,
            io_elapsed,
            rate(config.size, io_elapsed),
            sync_elapsed,
            rate(config.size, durable_elapsed),
        },
    );
}

fn runWrites(
    allocator: std.mem.Allocator,
    io: Io,
    device: *Device,
    buffers: []const []u8,
    config: Config,
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
        try device.writeAllManyAt(io, writes[0..count]);
        offset += count * config.block_size;
    }
}

fn runReads(
    allocator: std.mem.Allocator,
    io: Io,
    device: *Device,
    buffers: []const []u8,
    config: Config,
) !void {
    const reads = try allocator.alloc(zettide.blob_device.Read, buffers.len);
    defer allocator.free(reads);
    const results = try allocator.alloc(zettide.blob_device.ReadResult, buffers.len);
    defer allocator.free(results);
    var offset: u64 = 0;
    while (offset < config.size) {
        const remaining_blocks = (config.size - offset) / config.block_size;
        const count: usize = @intCast(@min(remaining_blocks, buffers.len));
        for (reads[0..count], buffers[0..count], 0..) |*read, buffer, index| read.* = .{
            .buffer = buffer,
            .offset = offset + index * config.block_size,
        };
        try device.readManyAt(io, reads[0..count], results[0..count]);
        for (results[0..count]) |result| {
            if (result.failure) |err| return err;
            if (result.amount != config.block_size) return error.IncompleteBlobDeviceRead;
        }
        offset += count * config.block_size;
    }
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
        } else return error.UnknownArgument;
    }
    if (result.help) return result;
    if (result.path == null) return error.MissingPath;
    if (result.size == 0 or result.block_size == 0 or
        result.block_size % 4096 != 0 or result.size % result.block_size != 0)
        return error.InvalidBenchmarkGeometry;
    if (result.batch_depth == 0 or result.batch_depth > zettide.blob_device.max_batch)
        return error.InvalidBatchDepth;
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
    });
    try std.testing.expectEqual(Operation.read, config.operation);
    try std.testing.expectEqualStrings("/tmp/blob", config.path.?);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), config.size);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), config.block_size);
    try std.testing.expectEqual(@as(usize, 16), config.batch_depth);
}

test "reject invalid blob device benchmark options" {
    try std.testing.expectError(error.MissingPath, parseArgs(&.{"benchmark"}));
    try std.testing.expectError(error.InvalidOperation, parseArgs(&.{ "benchmark", "--operation", "other" }));
    try std.testing.expectError(error.InvalidBatchDepth, parseArgs(&.{ "benchmark", "--path", "/tmp/blob", "--batch-depth", "33" }));
    try std.testing.expect((try parseArgs(&.{ "benchmark", "--help" })).help);
}
