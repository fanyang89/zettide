const std = @import("std");
const builtin = @import("builtin");
const zettide = @import("zettide");

const Io = std.Io;
const Device = zettide.blob_device.Device;
const Object = zettide.blob_object.Object;
const Store = zettide.blob_store.Store;
const format = zettide.blob_format;

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
    block_size: usize = format.blob_size,
    batch_depth: usize = zettide.blob_device.max_batch,
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try parseArgs(args);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};
    if (config.help) return usage(stdout);
    const path = config.path orelse return error.MissingPath;
    const map_headroom = config.size / 8 + 64 * 1024 * 1024;
    const payload_region_size = std.math.add(u64, config.size, map_headroom) catch
        return error.InvalidBenchmarkGeometry;
    const device_size = std.math.add(u64, format.arena_offset, payload_region_size) catch
        return error.InvalidBenchmarkGeometry;

    const file = switch (config.operation) {
        .write => try Io.Dir.createFileAbsolute(init.io, path, .{ .read = true, .exclusive = true }),
        .read => try Io.Dir.openFileAbsolute(init.io, path, .{
            .mode = .read_only,
            .lock = .shared,
            .lock_nonblocking = true,
        }),
    };
    var file_open = true;
    defer if (file_open) file.close(init.io);
    if (config.operation == .write) try file.setLength(init.io, device_size);
    if (try file.length(init.io) != device_size) return error.InvalidBenchmarkFileSize;
    const storage = zettide.v3.storage.Storage.initOwned(file, device_size, .regular_file, 1, false);
    const device = try Device.init(storage, 0, device_size, 4096);
    file_open = false;
    const blobs = switch (config.operation) {
        .write => try Store.create(init.gpa, init.io, device),
        .read => try Store.open(init.gpa, init.io, device),
    };
    const open_start = Io.Clock.awake.now(init.io).nanoseconds;
    var object = switch (config.operation) {
        .write => try Object.create(init.gpa, init.io, blobs),
        .read => try Object.open(init.gpa, init.io, blobs),
    };
    const open_elapsed: u64 = @intCast(Io.Clock.awake.now(init.io).nanoseconds - open_start);
    defer object.close(init.io) catch {};

    const buffers = try init.gpa.alloc([]u8, config.batch_depth);
    defer init.gpa.free(buffers);
    var allocated: usize = 0;
    defer for (buffers[0..allocated]) |buffer| init.gpa.free(buffer);
    for (buffers) |*buffer| {
        buffer.* = try init.gpa.alignedAlloc(u8, .fromByteUnits(4096), format.blob_size);
        allocated += 1;
        @memset(buffer.*, @intCast(allocated));
    }

    try stdout.print(
        "benchmark=zettide_blob_object optimize={s} operation={s} path={s} size={} blob_size={} batch_depth={} open_elapsed_ns={}\n",
        .{
            @tagName(builtin.mode),
            @tagName(config.operation),
            path,
            config.size,
            format.blob_size,
            config.batch_depth,
            open_elapsed,
        },
    );
    try stdout.flush();

    const io_start = Io.Clock.awake.now(init.io).nanoseconds;
    const validation_elapsed: u64 = switch (config.operation) {
        .write => validation: {
            try runWrites(init.io, &object, buffers, config);
            break :validation 0;
        },
        .read => try runReads(init.io, &object, buffers, config),
    };
    const operation_elapsed: u64 = @intCast(Io.Clock.awake.now(init.io).nanoseconds - io_start);
    const io_elapsed = operation_elapsed - validation_elapsed;
    var sync_elapsed: u64 = 0;
    if (config.operation == .write) {
        const sync_start = Io.Clock.awake.now(init.io).nanoseconds;
        try object.commit(init.io);
        sync_elapsed = @intCast(Io.Clock.awake.now(init.io).nanoseconds - sync_start);
    }
    const durable_elapsed = if (config.operation == .write) operation_elapsed + sync_elapsed else io_elapsed;
    try stdout.print(
        "blob_object_result operation={s} bytes={} io_elapsed_ns={} bytes_per_second={} validation_elapsed_ns={} sync_elapsed_ns={} durable_bytes_per_second={} open_elapsed_ns={} total_bytes_per_second={}\n",
        .{
            @tagName(config.operation),
            config.size,
            io_elapsed,
            rate(config.size, io_elapsed),
            validation_elapsed,
            sync_elapsed,
            rate(config.size, durable_elapsed),
            open_elapsed,
            rate(config.size, open_elapsed + operation_elapsed + sync_elapsed),
        },
    );
}

fn runWrites(io: Io, object: *Object, buffers: []const []u8, config: Config) !void {
    var remaining = config.size / format.blob_size;
    while (remaining != 0) {
        const count: usize = @intCast(@min(remaining, buffers.len));
        try object.appendMany(io, buffers[0..count]);
        remaining -= count;
    }
}

fn runReads(io: Io, object: *Object, buffers: []const []u8, config: Config) !u64 {
    const blob_count = config.size / format.blob_size;
    var logical_blob: u64 = 0;
    var validation_elapsed: u64 = 0;
    while (logical_blob < blob_count) : (logical_blob += 1) {
        const buffer = buffers[logical_blob % buffers.len];
        const expected: u8 = @intCast(logical_blob % buffers.len + 1);
        const amount = try object.readBlob(io, logical_blob, buffer);
        if (amount != format.blob_size) return error.BlobObjectBenchmarkDataMismatch;
        const validation_start = Io.Clock.awake.now(io).nanoseconds;
        const valid = std.mem.allEqual(u8, buffer, expected);
        validation_elapsed += @intCast(Io.Clock.awake.now(io).nanoseconds - validation_start);
        if (!valid) return error.BlobObjectBenchmarkDataMismatch;
    }
    return validation_elapsed;
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
    if (result.size == 0 or result.size % format.blob_size != 0 or
        result.block_size != format.blob_size)
        return error.InvalidBenchmarkGeometry;
    if (result.batch_depth == 0 or result.batch_depth > zettide.blob_device.max_batch)
        return error.InvalidBatchDepth;
    return result;
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zettide-blob-object-benchmark [options]
        \\
        \\Options:
        \\  --operation read|write  operation to run (default: write)
        \\  --path P               absolute benchmark file path
        \\  --size N               logical payload bytes (default: 8GiB)
        \\  --block-size 1MiB      immutable blob size
        \\  --batch-depth N        blobs per append batch (default: 32)
        \\  --help                 show this help
        \\
    );
}

test "parse blob object benchmark options" {
    const config = try parseArgs(&.{
        "benchmark",
        "--operation",
        "read",
        "--path",
        "/tmp/blob-object",
        "--size",
        "64MiB",
        "--batch-depth",
        "16",
    });
    try std.testing.expectEqual(Operation.read, config.operation);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), config.size);
    try std.testing.expectEqual(@as(usize, 16), config.batch_depth);
}
