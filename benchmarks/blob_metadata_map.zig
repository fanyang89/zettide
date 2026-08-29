const std = @import("std");
const builtin = @import("builtin");
const storage_engine = @import("zettide_storage");
const node = @import("zettide_node");

const Io = std.Io;
const blob_format = storage_engine.blob_format;
const filesystem_format = storage_engine.blob_filesystem_format;
const metadata_map = storage_engine.blob_metadata_map;
const metadata_store = storage_engine.blob_metadata_map_store;

const Config = struct {
    path: ?[]const u8 = null,
    records: usize = 100_000,
    samples: usize = 5,
    device_size: u64 = 256 * 1024 * 1024,
    help: bool = false,
};

const Summary = struct {
    average: u64,
    p95: u64,
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

    const file = try Io.Dir.createFileAbsolute(init.io, path, .{ .read = true, .exclusive = true });
    var file_open = true;
    defer if (file_open) file.close(init.io);
    try file.setLength(init.io, config.device_size);
    const storage = storage_engine.v3.storage.Storage.initOwned(
        file,
        config.device_size,
        .regular_file,
        1,
        false,
    );
    const device = try storage_engine.blob_device.Device.init(
        storage,
        0,
        config.device_size,
        blob_format.allocation_unit,
    );
    file_open = false;
    var blobs = try storage_engine.blob_store.Store.create(init.gpa, init.io, device);
    defer blobs.close(init.io) catch {};
    var maps = metadata_store.MapStore.init(init.gpa, &blobs);

    const keys = try init.gpa.alloc([9]u8, config.records);
    defer init.gpa.free(keys);
    const values = try init.gpa.alloc([filesystem_format.orphan_encoded_size]u8, config.records);
    defer init.gpa.free(values);
    const entries = try init.gpa.alloc(metadata_map.LeafEntry, config.records);
    defer init.gpa.free(entries);
    for (keys, values, entries, 1..) |*key, *value, *entry, inode| {
        key.* = try filesystem_format.orphanKey(inode);
        value.* = try filesystem_format.encodeOrphan(.{ .generation = 1, .kind = .file });
        entry.* = .{ .key = key, .value = value };
    }

    const root = try maps.build(init.io, 1, entries);
    try blobs.commit(init.io);
    const replacement = try filesystem_format.encodeOrphan(.{ .generation = 2, .kind = .symlink });
    const target = config.records / 2;
    const mutation = [_]metadata_store.Mutation{.{ .put = .{
        .key = &keys[target],
        .value = &replacement,
    } }};
    const incremental_latencies = try init.gpa.alloc(u64, config.samples);
    defer init.gpa.free(incremental_latencies);
    const incremental_units = try init.gpa.alloc(u64, config.samples);
    defer init.gpa.free(incremental_units);
    const rebuild_latencies = try init.gpa.alloc(u64, config.samples);
    defer init.gpa.free(rebuild_latencies);
    const rebuild_units = try init.gpa.alloc(u64, config.samples);
    defer init.gpa.free(rebuild_units);

    for (incremental_latencies, incremental_units) |*elapsed, *units| {
        const checkpoint = blobs.stagedUnits();
        const start = Io.Clock.awake.now(init.io).nanoseconds;
        _ = try maps.applyBatch(init.io, root, 1, 2, &mutation);
        elapsed.* = @intCast(Io.Clock.awake.now(init.io).nanoseconds - start);
        units.* = blobs.stagedUnits() - checkpoint;
        try blobs.discardStaged(init.io, checkpoint);
    }

    for (rebuild_latencies, rebuild_units) |*elapsed, *units| {
        const checkpoint = blobs.stagedUnits();
        const start = Io.Clock.awake.now(init.io).nanoseconds;
        const existing = try maps.loadAllAlloc(init.io, root, 1);
        defer metadata_store.deinitEntries(init.gpa, existing);
        @memcpy(existing[target].value, &replacement);
        const views = try init.gpa.alloc(metadata_map.LeafEntry, existing.len);
        defer init.gpa.free(views);
        for (existing, views) |entry, *view| view.* = entry.view();
        _ = try maps.build(init.io, 2, views);
        elapsed.* = @intCast(Io.Clock.awake.now(init.io).nanoseconds - start);
        units.* = blobs.stagedUnits() - checkpoint;
        try blobs.discardStaged(init.io, checkpoint);
    }

    const incremental = summarize(incremental_latencies);
    const rebuild = summarize(rebuild_latencies);
    const incremental_average_units = average(incremental_units);
    const rebuild_average_units = average(rebuild_units);
    try stdout.print(
        "benchmark=zettide_blob_metadata_map optimize={s} path={s} records={} samples={} root_level={}\n",
        .{ @tagName(builtin.mode), path, config.records, config.samples, root.level },
    );
    try stdout.print(
        "metadata_update_result mode=incremental average_ns={} p95_ns={} average_staged_units={}\n",
        .{ incremental.average, incremental.p95, incremental_average_units },
    );
    try stdout.print(
        "metadata_update_result mode=rebuild average_ns={} p95_ns={} average_staged_units={}\n",
        .{ rebuild.average, rebuild.p95, rebuild_average_units },
    );
    try stdout.print(
        "metadata_update_comparison latency_speedup_x100={} write_reduction_x100={}\n",
        .{
            ratio(rebuild.average, incremental.average),
            ratio(rebuild_average_units, incremental_average_units),
        },
    );
}

fn summarize(samples: []u64) Summary {
    std.debug.assert(samples.len != 0);
    const result = average(samples);
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .average = result,
        .p95 = samples[(samples.len * 95 + 99) / 100 - 1],
    };
}

fn average(samples: []const u64) u64 {
    std.debug.assert(samples.len != 0);
    var total: u128 = 0;
    for (samples) |sample| total += sample;
    return @intCast(total / samples.len);
}

fn ratio(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return std.math.maxInt(u64);
    return @intCast(@as(u128, numerator) * 100 / denominator);
}

fn parseArgs(args: []const []const u8) !Config {
    var result: Config = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--path")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.path = args[index];
        } else if (std.mem.eql(u8, arg, "--records")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.records = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.samples = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--device-size")) {
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            result.device_size = try node.size.parse(args[index]);
        } else return error.UnknownArgument;
    }
    if (result.help) return result;
    if (result.path == null) return error.MissingPath;
    if (result.records == 0 or result.samples == 0 or
        result.device_size < 8 * 1024 * 1024 or
        result.device_size % blob_format.allocation_unit != 0)
        return error.InvalidBenchmarkGeometry;
    return result;
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zettide-blob-metadata-map-benchmark [options]
        \\
        \\Options:
        \\  --path P          absolute benchmark file path
        \\  --records N       metadata records (default: 100000)
        \\  --samples N       updates per mode (default: 5)
        \\  --device-size N   backing file size (default: 256MiB)
        \\  --help            show this help
        \\
    );
}

test "parse blob metadata map benchmark options" {
    const config = try parseArgs(&.{
        "benchmark",
        "--path",
        "/tmp/metadata-map",
        "--records",
        "1000",
        "--samples",
        "3",
        "--device-size",
        "16MiB",
    });
    try std.testing.expectEqual(@as(usize, 1000), config.records);
    try std.testing.expectEqual(@as(usize, 3), config.samples);
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), config.device_size);
}

test "summarize blob metadata map benchmark latency" {
    var samples = [_]u64{ 4, 1, 3, 2 };
    const summary = summarize(&samples);
    try std.testing.expectEqual(@as(u64, 2), summary.average);
    try std.testing.expectEqual(@as(u64, 4), summary.p95);
    try std.testing.expectEqual(@as(u64, 250), ratio(5, 2));
}

test "reject invalid blob metadata map benchmark options" {
    try std.testing.expectError(error.MissingPath, parseArgs(&.{"benchmark"}));
    try std.testing.expectError(error.InvalidBenchmarkGeometry, parseArgs(&.{
        "benchmark",
        "--path",
        "/tmp/metadata-map",
        "--records",
        "0",
    }));
    try std.testing.expect((try parseArgs(&.{ "benchmark", "--help" })).help);
}
