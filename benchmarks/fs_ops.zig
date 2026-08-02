const std = @import("std");
const builtin = @import("builtin");
const zbench = @import("zbench");
const zettide = @import("zettide");

const Io = std.Io;
const Volume = zettide.volume.Volume;
const FileHandle = zettide.volume.FileHandle;
const c = zettide.volume.c;

const Operation = enum {
    create,
    open,
    stat,
    read_readonly,
    read_partial,
    read_writable_relatime,
    write_overwrite,
    rename,
    remove,

    fn parse(value: []const u8) !?Operation {
        if (std.mem.eql(u8, value, "all")) return null;
        if (std.mem.eql(u8, value, "create")) return .create;
        if (std.mem.eql(u8, value, "open")) return .open;
        if (std.mem.eql(u8, value, "stat")) return .stat;
        if (std.mem.eql(u8, value, "read-readonly")) return .read_readonly;
        if (std.mem.eql(u8, value, "read-partial")) return .read_partial;
        if (std.mem.eql(u8, value, "read-writable-relatime")) return .read_writable_relatime;
        if (std.mem.eql(u8, value, "write-overwrite")) return .write_overwrite;
        if (std.mem.eql(u8, value, "rename")) return .rename;
        if (std.mem.eql(u8, value, "remove")) return .remove;
        return error.InvalidOperation;
    }
};

const all_operations = [_]Operation{
    .create,
    .open,
    .stat,
    .read_readonly,
    .read_partial,
    .read_writable_relatime,
    .write_overwrite,
    .rename,
    .remove,
};

const DurabilityMode = enum {
    durable,
    writeback,

    fn parse(value: []const u8) !DurabilityMode {
        if (std.mem.eql(u8, value, "durable")) return .durable;
        if (std.mem.eql(u8, value, "writeback")) return .writeback;
        return error.InvalidDurability;
    }

    fn mountValue(self: DurabilityMode) zettide.block_device.Durability {
        return switch (self) {
            .durable => .durable,
            .writeback => .{ .writeback = .{} },
        };
    }
};

const benchmark_name_width = blk: {
    var width: usize = 0;
    for (all_operations) |operation| width = @max(width, @tagName(operation).len);
    break :blk width;
};

const Config = struct {
    operation: ?Operation = null,
    iterations: u32 = 100,
    warmup: u32 = 5,
    block_size: usize = 4096,
    image_size: u64 = 512 * 1024 * 1024,
    workspace_root: []const u8 = ".zig-cache/benchmarks",
    journaled: bool = false,
    durability: DurabilityMode = .writeback,
    help: bool = false,
};

const TempWorkspace = struct {
    path_buffer: [Io.Dir.max_path_bytes]u8,
    path_length: usize,

    fn init(io: Io, parent_path: []const u8) !TempWorkspace {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, parent_path);

        var random_bytes: [12]u8 = undefined;
        var encoded: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
        for (0..8) |_| {
            io.random(&random_bytes);
            _ = std.base64.url_safe.Encoder.encode(&encoded, &random_bytes);
            var result: TempWorkspace = .{ .path_buffer = undefined, .path_length = 0 };
            const workspace_path = try std.fmt.bufPrint(&result.path_buffer, "{s}/{s}", .{ parent_path, encoded });
            result.path_length = workspace_path.len;
            const status = try cwd.createDirPathStatus(io, workspace_path, .default_dir);
            if (status == .created) return result;
        }
        return error.TemporaryDirectoryCollision;
    }

    fn path(self: *const TempWorkspace) []const u8 {
        return self.path_buffer[0..self.path_length];
    }

    fn cleanup(self: *TempWorkspace, io: Io) !void {
        try Io.Dir.cwd().deleteTree(io, self.path());
    }
};

const CaseState = struct {
    allocator: std.mem.Allocator,
    volume: *Volume,
    operation: Operation,
    payload: []u8,
    read_buffer: []u8,
    handle: FileHandle = undefined,
    handle_open: bool = false,
    transient_handle: FileHandle = undefined,
    transient_open: bool = false,
    rename_source_is_primary: bool = true,
    failure: ?anyerror = null,

    fn init(
        allocator: std.mem.Allocator,
        volume: *Volume,
        operation: Operation,
        block_size: usize,
    ) !CaseState {
        const payload = try allocator.alloc(u8, block_size);
        errdefer allocator.free(payload);
        @memset(payload, 0x5a);
        const read_buffer = try allocator.alloc(u8, block_size);
        errdefer allocator.free(read_buffer);
        return .{
            .allocator = allocator,
            .volume = volume,
            .operation = operation,
            .payload = payload,
            .read_buffer = read_buffer,
        };
    }

    fn deinit(self: *CaseState) void {
        if (self.transient_open) self.volume.closeFile(&self.transient_handle) catch {};
        if (self.handle_open) self.volume.closeFile(&self.handle) catch {};
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.payload);
        self.* = undefined;
    }

    fn close(self: *CaseState) !void {
        try self.closeTransient();
        if (!self.handle_open) return;
        try self.volume.closeFile(&self.handle);
        self.handle_open = false;
    }

    fn prepare(self: *CaseState) !void {
        switch (self.operation) {
            .create, .remove => {},
            .open, .stat, .rename => try self.createClosedFile("/subject"),
            .read_readonly, .read_partial => {
                try self.volume.openFile(&self.handle, "/data", c.LFS_O_RDONLY, 0, 0, 0);
                self.handle_open = true;
            },
            .read_writable_relatime, .write_overwrite => {
                try self.volume.openFile(
                    &self.handle,
                    "/data",
                    c.LFS_O_CREAT | c.LFS_O_EXCL | c.LFS_O_RDWR,
                    0o100644,
                    0,
                    0,
                );
                self.handle_open = true;
                if (try self.volume.writeFile(&self.handle, self.payload, 0) != self.payload.len)
                    return error.ShortWrite;
            },
        }
    }

    fn beforeEach(self: *CaseState) !void {
        if (self.transient_open) return error.TransientHandleStillOpen;
        if (self.operation == .remove) try self.createClosedFile("/remove");
    }

    fn afterEach(self: *CaseState) !void {
        switch (self.operation) {
            .create => {
                try self.closeTransient();
                try self.volume.remove("/create");
            },
            .open => try self.closeTransient(),
            else => {},
        }
    }

    fn execute(self: *CaseState) !void {
        switch (self.operation) {
            .create => {
                try self.volume.openFile(
                    &self.transient_handle,
                    "/create",
                    c.LFS_O_CREAT | c.LFS_O_EXCL | c.LFS_O_RDWR,
                    0o100644,
                    0,
                    0,
                );
                self.transient_open = true;
            },
            .open => {
                try self.volume.openFile(&self.transient_handle, "/subject", c.LFS_O_RDONLY, 0, 0, 0);
                self.transient_open = true;
            },
            .stat => {
                const info = try self.volume.stat("/subject");
                std.mem.doNotOptimizeAway(info.size);
            },
            .read_readonly, .read_partial, .read_writable_relatime => {
                const offset = if (self.operation == .read_partial) zettide.object_format.chunk_size / 2 else 0;
                const amount = try self.volume.readFile(&self.handle, self.read_buffer, offset);
                if (amount != self.read_buffer.len) return error.ShortRead;
                std.mem.doNotOptimizeAway(self.read_buffer);
            },
            .write_overwrite => {
                if (try self.volume.writeFile(&self.handle, self.payload, 0) != self.payload.len)
                    return error.ShortWrite;
            },
            .rename => {
                const old_path: [*:0]const u8 = if (self.rename_source_is_primary) "/subject" else "/renamed";
                const new_path: [*:0]const u8 = if (self.rename_source_is_primary) "/renamed" else "/subject";
                if (try self.volume.renameWithResult(old_path, new_path) != .renamed)
                    return error.RenameDidNotMove;
                self.rename_source_is_primary = !self.rename_source_is_primary;
            },
            .remove => try self.volume.remove("/remove"),
        }
    }

    fn createClosedFile(self: *CaseState, path: [*:0]const u8) !void {
        var file: FileHandle = undefined;
        try self.volume.openFile(
            &file,
            path,
            c.LFS_O_CREAT | c.LFS_O_EXCL | c.LFS_O_RDWR,
            0o100644,
            0,
            0,
        );
        errdefer self.volume.closeFile(&file) catch {};
        try self.volume.closeFile(&file);
    }

    fn closeTransient(self: *CaseState) !void {
        if (!self.transient_open) return;
        try self.volume.closeFile(&self.transient_handle);
        self.transient_open = false;
    }

    fn recordFailure(self: *CaseState, err: anyerror) void {
        if (self.failure == null) self.failure = err;
    }
};

const BenchmarkCase = struct {
    state: *CaseState,

    pub fn run(self: *BenchmarkCase, _: std.mem.Allocator) void {
        if (self.state.failure != null) return;
        self.state.execute() catch |err| self.state.recordFailure(err);
    }
};

// zBench 0.16 hooks have no context, and this runner executes one case at a time.
var active_state: ?*CaseState = null;

fn beforeEachHook() void {
    const state = active_state orelse @panic("missing active benchmark state");
    if (state.failure != null) return;
    state.beforeEach() catch |err| state.recordFailure(err);
}

fn afterEachHook() void {
    const state = active_state orelse @panic("missing active benchmark state");
    state.afterEach() catch |err| state.recordFailure(err);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = parseArgs(args) catch |err| {
        std.debug.print("invalid arguments: {s}\n", .{@errorName(err)});
        return err;
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    if (config.help) {
        try usage(stdout);
        return;
    }

    try stdout.print(
        "benchmark=zettide_fs_ops framework=zbench optimize={s} target_os={s} target_arch={s} iterations={} warmup={} block_size={} image_size={} workspace_root={s} journaled={} durability={s}\n",
        .{
            @tagName(builtin.mode),
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            config.iterations,
            config.warmup,
            config.block_size,
            config.image_size,
            config.workspace_root,
            config.journaled,
            @tagName(config.durability),
        },
    );
    try stdout.flush();
    try zbench.prettyPrintHeader(init.io, .stdout(), benchmark_name_width);

    if (config.operation) |operation| {
        try runOperation(allocator, init.io, config, operation);
    } else {
        for (all_operations) |operation| try runOperation(allocator, init.io, config, operation);
    }
}

fn runOperation(
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,
    operation: Operation,
) !void {
    var workspace = try TempWorkspace.init(io, config.workspace_root);
    errdefer workspace.cleanup(io) catch {};
    var image_path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const image_path = try std.fmt.bufPrint(&image_path_buffer, "{s}/image.ddv", .{workspace.path()});
    try Volume.createOptions(io, image_path, config.image_size, "FsOpsBenchmark", .{
        .redo_journal = if (config.journaled) .{
            .length = 1024 * 1024 * 1024,
            .max_transaction_blocks = 1024,
        } else null,
    });

    const read_only = operation == .read_readonly or operation == .read_partial;
    if (read_only) try populateReadOnlyImage(
        allocator,
        io,
        image_path,
        if (operation == .read_partial) zettide.object_format.chunk_size else config.block_size,
    );

    var volume = try Volume.open(io, image_path, !read_only);
    defer volume.deinit();
    try volume.mountOptions(.{ .journal_durability = config.durability.mountValue() });

    var state = try CaseState.init(allocator, &volume, operation, config.block_size);
    defer state.deinit();
    try state.prepare();
    for (0..config.warmup) |_| try runWarmup(&state);

    const benchmark_case: BenchmarkCase = .{ .state = &state };
    var benchmark = zbench.Benchmark.init(allocator, .{
        .iterations = config.iterations,
        .hooks = .{
            .before_each = beforeEachHook,
            .after_each = afterEachHook,
        },
    });
    defer benchmark.deinit();
    try benchmark.addParam(@tagName(operation), &benchmark_case, .{});

    if (active_state != null) return error.BenchmarkAlreadyActive;
    active_state = &state;
    defer active_state = null;
    var iterator = try benchmark.iterator();
    var result: ?zbench.Result = null;
    while (try iterator.next(io)) |step| switch (step) {
        .progress => {},
        .result => |value| result = value,
    };
    active_state = null;

    const benchmark_error = state.failure;
    try state.close();
    try volume.close();
    try workspace.cleanup(io);
    if (benchmark_error) |err| return err;

    const completed = result orelse return error.MissingBenchmarkResult;
    defer completed.deinit();
    try completed.prettyPrint(io, .stdout(), benchmark_name_width);
}

fn runWarmup(state: *CaseState) !void {
    try state.beforeEach();
    errdefer state.afterEach() catch {};
    try state.execute();
    try state.afterEach();
}

fn populateReadOnlyImage(
    allocator: std.mem.Allocator,
    io: Io,
    image_path: []const u8,
    block_size: usize,
) !void {
    const payload = try allocator.alloc(u8, block_size);
    defer allocator.free(payload);
    @memset(payload, 0x5a);

    var volume = try Volume.open(io, image_path, true);
    defer volume.deinit();
    try volume.mount();
    var handle: FileHandle = undefined;
    try volume.openFile(
        &handle,
        "/data",
        c.LFS_O_CREAT | c.LFS_O_EXCL | c.LFS_O_RDWR,
        0o100644,
        0,
        0,
    );
    errdefer volume.closeFile(&handle) catch {};
    if (try volume.writeFile(&handle, payload, 0) != payload.len) return error.ShortWrite;
    try volume.syncFile(&handle);
    try volume.closeFile(&handle);
    try volume.close();
}

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{};
    var index: usize = 1;
    while (index < args.len) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--help")) {
            config.help = true;
            return config;
        }
        if (std.mem.eql(u8, argument, "--journaled")) {
            config.journaled = true;
            index += 1;
            continue;
        }
        const known_option = std.mem.eql(u8, argument, "--operation") or
            std.mem.eql(u8, argument, "--iterations") or
            std.mem.eql(u8, argument, "--warmup") or
            std.mem.eql(u8, argument, "--block-size") or
            std.mem.eql(u8, argument, "--image-size") or
            std.mem.eql(u8, argument, "--workspace-root") or
            std.mem.eql(u8, argument, "--durability");
        if (!known_option) return error.UnknownArgument;
        if (index + 1 >= args.len) return error.MissingArgumentValue;
        const value = args[index + 1];
        if (std.mem.eql(u8, argument, "--operation")) {
            config.operation = try Operation.parse(value);
        } else if (std.mem.eql(u8, argument, "--iterations")) {
            config.iterations = try parsePositiveU32(value);
        } else if (std.mem.eql(u8, argument, "--warmup")) {
            config.warmup = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, argument, "--block-size")) {
            config.block_size = try parsePositiveUsize(value);
        } else if (std.mem.eql(u8, argument, "--image-size")) {
            config.image_size = try std.fmt.parseUnsigned(u64, value, 10);
        } else if (std.mem.eql(u8, argument, "--workspace-root")) {
            if (value.len == 0) return error.EmptyWorkspaceRoot;
            config.workspace_root = value;
        } else if (std.mem.eql(u8, argument, "--durability")) {
            config.durability = try DurabilityMode.parse(value);
        }
        index += 2;
    }
    if (config.image_size < zettide.container.min_volume_size or
        config.image_size % zettide.container.default_block_size != 0)
        return error.InvalidImageSize;
    if (config.block_size > config.image_size / 4) return error.BlockSizeTooLarge;
    if (config.journaled and config.block_size > zettide.object_format.chunk_size)
        return error.JournaledBlockSizeTooLarge;
    return config;
}

fn parsePositiveU32(value: []const u8) !u32 {
    const parsed = try std.fmt.parseUnsigned(u32, value, 10);
    if (parsed == 0) return error.ZeroValue;
    return parsed;
}

fn parsePositiveUsize(value: []const u8) !usize {
    const parsed = try std.fmt.parseUnsigned(usize, value, 10);
    if (parsed == 0) return error.ZeroValue;
    return parsed;
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zettide-fs-ops-benchmark [options]
        \\
        \\Options:
        \\  --operation NAME   all, create, open, stat, read-readonly,
        \\                     read-partial, read-writable-relatime, write-overwrite,
        \\                     rename, or remove
        \\  --iterations N     measured operations per workload (default: 100)
        \\  --warmup N         warmup operations per workload (default: 5)
        \\  --block-size N      data operation size in bytes (default: 4096)
        \\  --image-size N      container logical size in bytes (default: 536870912)
        \\  --workspace-root P  benchmark workspace parent (default: .zig-cache/benchmarks)
        \\  --journaled         use redo journaling (block size up to 1048576)
        \\  --durability NAME   durable or writeback (default: writeback)
        \\  --help              show this help
        \\
    );
}

test "parse filesystem benchmark defaults and options" {
    const defaults = try parseArgs(&.{"benchmark"});
    try std.testing.expectEqual(@as(?Operation, null), defaults.operation);
    try std.testing.expectEqual(@as(u32, 100), defaults.iterations);
    try std.testing.expectEqual(@as(u32, 5), defaults.warmup);
    try std.testing.expectEqual(@as(usize, 4096), defaults.block_size);
    try std.testing.expectEqualStrings(".zig-cache/benchmarks", defaults.workspace_root);
    try std.testing.expect(!defaults.journaled);
    try std.testing.expectEqual(DurabilityMode.writeback, defaults.durability);

    const configured = try parseArgs(&.{
        "benchmark",
        "--operation",
        "write-overwrite",
        "--iterations",
        "12",
        "--warmup",
        "0",
        "--block-size",
        "8192",
        "--image-size",
        "67108864",
        "--workspace-root",
        "/var/tmp/zettide-bench",
        "--journaled",
        "--durability",
        "durable",
    });
    try std.testing.expectEqual(Operation.write_overwrite, configured.operation.?);
    try std.testing.expectEqual(@as(u32, 12), configured.iterations);
    try std.testing.expectEqual(@as(u32, 0), configured.warmup);
    try std.testing.expectEqual(@as(usize, 8192), configured.block_size);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), configured.image_size);
    try std.testing.expectEqualStrings("/var/tmp/zettide-bench", configured.workspace_root);
    try std.testing.expect(configured.journaled);
    try std.testing.expectEqual(DurabilityMode.durable, configured.durability);
}

test "reject invalid filesystem benchmark options" {
    try std.testing.expectError(error.InvalidOperation, parseArgs(&.{ "benchmark", "--operation", "other" }));
    try std.testing.expectError(error.ZeroValue, parseArgs(&.{ "benchmark", "--iterations", "0" }));
    try std.testing.expectError(error.MissingArgumentValue, parseArgs(&.{ "benchmark", "--warmup" }));
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "benchmark", "--other" }));
    try std.testing.expectError(error.InvalidImageSize, parseArgs(&.{ "benchmark", "--image-size", "12345" }));
    try std.testing.expectError(error.EmptyWorkspaceRoot, parseArgs(&.{ "benchmark", "--workspace-root", "" }));
    try std.testing.expectError(error.InvalidDurability, parseArgs(&.{ "benchmark", "--durability", "other" }));
    try std.testing.expectError(
        error.JournaledBlockSizeTooLarge,
        parseArgs(&.{ "benchmark", "--journaled", "--block-size", "4194304" }),
    );
    try std.testing.expect((try parseArgs(&.{ "benchmark", "--help", "--other" })).help);
}
