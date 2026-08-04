const std = @import("std");
const builtin = @import("builtin");
const zettide = @import("zettide");

const Io = std.Io;
const Device = zettide.blob_device.Device;
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
    const device_size = std.math.add(u64, config.size, format.arena_offset) catch
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
    var store = switch (config.operation) {
        .write => try Store.create(init.gpa, init.io, device),
        .read => try Store.open(init.gpa, init.io, device),
    };
    defer store.close(init.io) catch {};

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
        "benchmark=zettide_blob_store optimize={s} operation={s} path={s} size={} blob_size={} batch_depth={}\n",
        .{
            @tagName(builtin.mode),
            @tagName(config.operation),
            path,
            config.size,
            format.blob_size,
            config.batch_depth,
        },
    );
    try stdout.flush();

    const io_start = Io.Clock.awake.now(init.io).nanoseconds;
    const validation_elapsed: u64 = switch (config.operation) {
        .write => validation: {
            try runWrites(init.gpa, init.io, &store, buffers, config);
            break :validation 0;
        },
        .read => try runReads(init.io, &store, buffers, config),
    };
    const operation_elapsed: u64 = @intCast(Io.Clock.awake.now(init.io).nanoseconds - io_start);
    const io_elapsed = operation_elapsed - validation_elapsed;
    var sync_elapsed: u64 = 0;
    if (config.operation == .write) {
        const sync_start = Io.Clock.awake.now(init.io).nanoseconds;
        try store.commit(init.io);
        sync_elapsed = @intCast(Io.Clock.awake.now(init.io).nanoseconds - sync_start);
    }
    const durable_elapsed = if (config.operation == .write) operation_elapsed + sync_elapsed else io_elapsed;
    try stdout.print(
        "blob_store_result operation={s} bytes={} io_elapsed_ns={} bytes_per_second={} validation_elapsed_ns={} sync_elapsed_ns={} durable_bytes_per_second={} total_bytes_per_second={}\n",
        .{
            @tagName(config.operation),
            config.size,
            io_elapsed,
            rate(config.size, io_elapsed),
            validation_elapsed,
            sync_elapsed,
            rate(config.size, durable_elapsed),
            rate(config.size, operation_elapsed + sync_elapsed),
        },
    );
}

fn runWrites(
    allocator: std.mem.Allocator,
    io: Io,
    store: *Store,
    buffers: []const []u8,
    config: Config,
) !void {
    const references = try allocator.alloc(format.BlobRef, buffers.len);
    defer allocator.free(references);
    var remaining = config.size / format.blob_size;
    while (remaining != 0) {
        const count: usize = @intCast(@min(remaining, buffers.len));
        try store.putMany(io, buffers[0..count], references[0..count]);
        remaining -= count;
    }
}

fn runReads(io: Io, store: *Store, buffers: []const []u8, config: Config) !u64 {
    var checksums: [zettide.blob_device.max_batch][format.checksum_count]u32 = undefined;
    for (buffers, checksums[0..buffers.len]) |buffer, *checksum|
        checksum.* = format.payloadChecksums(buffer);
    var slot: u64 = 0;
    var validation_elapsed: u64 = 0;
    const slot_count = config.size / format.blob_size;
    while (slot < slot_count) : (slot += 1) {
        const index: usize = @intCast(slot % buffers.len);
        const buffer = buffers[index];
        const expected_byte: u8 = @intCast(index + 1);
        const reference: format.BlobRef = .{
            .slot = slot,
            .valid_bytes = format.blob_size,
            .checksums = checksums[index],
        };
        const amount = try store.read(io, reference, buffer);
        if (amount != format.blob_size) return error.BlobBenchmarkDataMismatch;
        const validation_start = Io.Clock.awake.now(io).nanoseconds;
        const valid = std.mem.allEqual(u8, buffer, expected_byte);
        validation_elapsed += @intCast(Io.Clock.awake.now(io).nanoseconds - validation_start);
        if (!valid) return error.BlobBenchmarkDataMismatch;
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
        \\Usage: zettide-blob-store-benchmark [options]
        \\
        \\Options:
        \\  --operation read|write  operation to run (default: write)
        \\  --path P               absolute benchmark file path
        \\  --size N               payload bytes (default: 8GiB)
        \\  --block-size 1MiB      immutable blob size
        \\  --batch-depth N        blobs per batch (default: 32)
        \\  --help                 show this help
        \\
    );
}

test "parse blob store benchmark options" {
    const config = try parseArgs(&.{
        "benchmark",
        "--operation",
        "read",
        "--path",
        "/tmp/blob-store",
        "--size",
        "64MiB",
        "--batch-depth",
        "16",
    });
    try std.testing.expectEqual(Operation.read, config.operation);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), config.size);
    try std.testing.expectEqual(@as(usize, 16), config.batch_depth);
}

test "reject invalid blob store benchmark options" {
    try std.testing.expectError(error.MissingPath, parseArgs(&.{"benchmark"}));
    try std.testing.expectError(error.InvalidBenchmarkGeometry, parseArgs(&.{
        "benchmark",
        "--path",
        "/tmp/blob-store",
        "--block-size",
        "64KiB",
    }));
    try std.testing.expect((try parseArgs(&.{ "benchmark", "--help" })).help);
}
