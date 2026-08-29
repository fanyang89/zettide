const std = @import("std");
const builtin = @import("builtin");
const zbench = @import("zbench");
const storage_engine = @import("zettide_storage");
const data_node = @import("zettide_data_node");

const Io = std.Io;
const backend = storage_engine.filesystem_backend;

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

const all_operations = std.enums.values(Operation);
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
    help: bool = false,
};

const TempWorkspace = struct {
    path_buffer: [Io.Dir.max_path_bytes]u8,
    path_length: usize,

    fn init(io: Io, parent_path: []const u8) !TempWorkspace {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, parent_path);
        var random: [12]u8 = undefined;
        var encoded: [std.base64.url_safe.Encoder.calcSize(random.len)]u8 = undefined;
        for (0..8) |_| {
            io.random(&random);
            _ = std.base64.url_safe.Encoder.encode(&encoded, &random);
            var result: TempWorkspace = .{ .path_buffer = undefined, .path_length = 0 };
            const candidate = try std.fmt.bufPrint(&result.path_buffer, "{s}/{s}", .{ parent_path, encoded });
            result.path_length = candidate.len;
            if (try cwd.createDirPathStatus(io, candidate, .default_dir) == .created) return result;
        }
        return error.TemporaryDirectoryCollision;
    }

    fn path(self: *const TempWorkspace) []const u8 {
        return self.path_buffer[0..self.path_length];
    }
};

const CaseState = struct {
    allocator: std.mem.Allocator,
    filesystem: backend.Filesystem,
    operation: Operation,
    payload: []u8,
    read_buffer: []u8,
    handle: backend.FileHandle = undefined,
    handle_open: bool = false,
    transient: backend.FileHandle = undefined,
    transient_open: bool = false,
    rename_source_is_primary: bool = true,
    failure: ?anyerror = null,

    fn init(allocator: std.mem.Allocator, filesystem: backend.Filesystem, operation: Operation, block_size: usize) !CaseState {
        const payload = try allocator.alloc(u8, block_size);
        errdefer allocator.free(payload);
        @memset(payload, 0x5a);
        const read_buffer = try allocator.alloc(u8, block_size);
        errdefer allocator.free(read_buffer);
        return .{ .allocator = allocator, .filesystem = filesystem, .operation = operation, .payload = payload, .read_buffer = read_buffer };
    }

    fn deinit(self: *CaseState) void {
        if (self.transient_open) self.transient.close() catch {};
        if (self.handle_open) self.handle.close() catch {};
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.payload);
    }

    fn createClosedFile(self: *CaseState, path: [*:0]const u8) !void {
        var file = try self.filesystem.openFile(self.allocator, path, .{
            .access = .read_write,
            .create = true,
            .exclusive = true,
        }, .{ .mode = 0o644, .uid = 0, .gid = 0 });
        try file.close();
    }

    fn prepare(self: *CaseState) !void {
        switch (self.operation) {
            .create, .remove => {},
            .open, .stat, .rename => try self.createClosedFile("/subject"),
            .read_readonly, .read_partial => {
                self.handle = try self.filesystem.openFile(self.allocator, "/data", .{ .access = .read_only }, .{ .mode = 0, .uid = 0, .gid = 0 });
                self.handle_open = true;
            },
            .read_writable_relatime, .write_overwrite => {
                self.handle = try self.filesystem.openFile(self.allocator, "/data", .{ .access = .read_write, .create = true, .exclusive = true }, .{ .mode = 0o644, .uid = 0, .gid = 0 });
                self.handle_open = true;
                if (try self.handle.write(self.payload, 0) != self.payload.len) return error.ShortWrite;
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
                try self.filesystem.remove("/create");
            },
            .open => try self.closeTransient(),
            else => {},
        }
    }

    fn execute(self: *CaseState) !void {
        switch (self.operation) {
            .create => {
                self.transient = try self.filesystem.openFile(self.allocator, "/create", .{ .access = .read_write, .create = true, .exclusive = true }, .{ .mode = 0o644, .uid = 0, .gid = 0 });
                self.transient_open = true;
            },
            .open => {
                self.transient = try self.filesystem.openFile(self.allocator, "/subject", .{ .access = .read_only }, .{ .mode = 0, .uid = 0, .gid = 0 });
                self.transient_open = true;
            },
            .stat => std.mem.doNotOptimizeAway(try self.filesystem.statPath("/subject")),
            .read_readonly, .read_partial, .read_writable_relatime => {
                const offset = if (self.operation == .read_partial) storage_engine.blob_format.allocation_unit / 2 else 0;
                if (try self.handle.read(self.read_buffer, offset) != self.read_buffer.len) return error.ShortRead;
                std.mem.doNotOptimizeAway(self.read_buffer);
            },
            .write_overwrite => if (try self.handle.write(self.payload, 0) != self.payload.len) return error.ShortWrite,
            .rename => {
                const old_path: [*:0]const u8 = if (self.rename_source_is_primary) "/subject" else "/renamed";
                const new_path: [*:0]const u8 = if (self.rename_source_is_primary) "/renamed" else "/subject";
                if (try self.filesystem.rename(old_path, new_path, false) != .renamed) return error.RenameDidNotMove;
                self.rename_source_is_primary = !self.rename_source_is_primary;
            },
            .remove => try self.filesystem.remove("/remove"),
        }
    }

    fn closeTransient(self: *CaseState) !void {
        if (!self.transient_open) return;
        try self.transient.close();
        self.transient_open = false;
    }

    fn recordFailure(self: *CaseState, err: anyerror) void {
        if (self.failure == null) self.failure = err;
    }
};

const BenchmarkCase = struct {
    state: *CaseState,
    pub fn run(self: *BenchmarkCase, _: std.mem.Allocator) void {
        if (self.state.failure == null) self.state.execute() catch |err| self.state.recordFailure(err);
    }
};

var active_state: ?*CaseState = null;

fn beforeEachHook() void {
    const state = active_state orelse @panic("missing active benchmark state");
    if (state.failure == null) state.beforeEach() catch |err| state.recordFailure(err);
}

fn afterEachHook() void {
    const state = active_state orelse @panic("missing active benchmark state");
    state.afterEach() catch |err| state.recordFailure(err);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try parseArgs(args);
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const stdout = &file_writer.interface;
    defer stdout.flush() catch {};
    if (config.help) return usage(stdout);
    try stdout.print("benchmark=zettide_fs_ops framework=zbench backend=blob optimize={s} target_os={s} target_arch={s} iterations={} warmup={} block_size={} image_size={} workspace_root={s}\n", .{
        @tagName(builtin.mode), @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), config.iterations, config.warmup, config.block_size, config.image_size, config.workspace_root,
    });
    try stdout.flush();
    try zbench.prettyPrintHeader(init.io, .stdout(), benchmark_name_width);
    if (config.operation) |operation| try runOperation(init.gpa, init.io, config, operation) else for (all_operations) |operation| try runOperation(init.gpa, init.io, config, operation);
}

fn runOperation(allocator: std.mem.Allocator, io: Io, config: Config, operation: Operation) !void {
    var workspace = try TempWorkspace.init(io, config.workspace_root);
    defer Io.Dir.cwd().deleteTree(io, workspace.path()) catch {};
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const image_path = try std.fmt.bufPrint(&path_buffer, "{s}/image.blob", .{workspace.path()});
    try data_node.filesystem_target.formatNewBlobFile(io, allocator, image_path, config.image_size, .portable_v1, .{});
    const read_only = operation == .read_readonly or operation == .read_partial;
    if (read_only) try populateReadOnlyImage(allocator, io, image_path, if (operation == .read_partial) storage_engine.blob_format.allocation_unit else config.block_size);
    var native = try data_node.filesystem_target.openBlobFilesystem(allocator, io, image_path, !read_only);
    var adapter = storage_engine.blob_filesystem_adapter.Adapter.init(&native, io);
    var state = try CaseState.init(allocator, adapter.filesystem(), operation, config.block_size);
    defer state.deinit();
    try state.prepare();
    for (0..config.warmup) |_| {
        try state.beforeEach();
        try state.execute();
        try state.afterEach();
    }
    const benchmark_case: BenchmarkCase = .{ .state = &state };
    var benchmark = zbench.Benchmark.init(allocator, .{ .iterations = config.iterations, .hooks = .{ .before_each = beforeEachHook, .after_each = afterEachHook } });
    defer benchmark.deinit();
    try benchmark.addParam(@tagName(operation), &benchmark_case, .{});
    active_state = &state;
    defer active_state = null;
    var iterator = try benchmark.iterator();
    var result: ?zbench.Result = null;
    while (try iterator.next(io)) |step| switch (step) {
        .progress => {},
        .result => |value| result = value,
    };
    active_state = null;
    if (state.failure) |err| return err;
    if (state.transient_open) try state.closeTransient();
    if (state.handle_open) {
        try state.handle.close();
        state.handle_open = false;
    }
    try native.close(io);
    const completed = result orelse return error.MissingBenchmarkResult;
    defer completed.deinit();
    try completed.prettyPrint(io, .stdout(), benchmark_name_width);
}

fn populateReadOnlyImage(allocator: std.mem.Allocator, io: Io, path: []const u8, size: usize) !void {
    var native = try data_node.filesystem_target.openBlobFilesystem(allocator, io, path, true);
    var adapter = storage_engine.blob_filesystem_adapter.Adapter.init(&native, io);
    var file = try adapter.filesystem().openFile(allocator, "/data", .{ .access = .read_write, .create = true, .exclusive = true }, .{ .mode = 0o644, .uid = 0, .gid = 0 });
    const payload = try allocator.alloc(u8, size * 2);
    defer allocator.free(payload);
    @memset(payload, 0x5a);
    if (try file.write(payload, 0) != payload.len) return error.ShortWrite;
    try file.close();
    try native.close(io);
}

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--help")) {
            config.help = true;
            return config;
        }
        if (index + 1 >= args.len) return error.MissingArgumentValue;
        const value = args[index + 1];
        if (std.mem.eql(u8, argument, "--operation")) config.operation = try Operation.parse(value) else if (std.mem.eql(u8, argument, "--iterations")) config.iterations = try parsePositive(u32, value) else if (std.mem.eql(u8, argument, "--warmup")) config.warmup = try std.fmt.parseUnsigned(u32, value, 10) else if (std.mem.eql(u8, argument, "--block-size")) config.block_size = try parsePositive(usize, value) else if (std.mem.eql(u8, argument, "--image-size")) config.image_size = try std.fmt.parseUnsigned(u64, value, 10) else if (std.mem.eql(u8, argument, "--workspace-root")) {
            if (value.len == 0) return error.EmptyWorkspaceRoot;
            config.workspace_root = value;
        } else return error.UnknownArgument;
    }
    if (config.image_size < storage_engine.blob_format.minimum_device_size or config.image_size % storage_engine.blob_format.blob_size != 0) return error.InvalidImageSize;
    if (config.block_size > config.image_size / 4) return error.BlockSizeTooLarge;
    return config;
}

fn parsePositive(comptime T: type, value: []const u8) !T {
    const parsed = try std.fmt.parseUnsigned(T, value, 10);
    if (parsed == 0) return error.ZeroValue;
    return parsed;
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zettide-fs-ops-benchmark [options]
        \\
        \\  --operation NAME    workload name or all
        \\  --iterations N      measured operations (default: 100)
        \\  --warmup N          warmup operations (default: 5)
        \\  --block-size N      data operation size (default: 4096)
        \\  --image-size N      Blob image size (default: 536870912)
        \\  --workspace-root P  workspace parent (default: .zig-cache/benchmarks)
        \\  --help              show this help
        \\
    );
}

test "parse Blob filesystem benchmark options" {
    const defaults = try parseArgs(&.{"benchmark"});
    try std.testing.expectEqual(@as(?Operation, null), defaults.operation);
    try std.testing.expectEqual(@as(u32, 100), defaults.iterations);
    const configured = try parseArgs(&.{ "benchmark", "--operation", "write-overwrite", "--iterations", "12", "--warmup", "0", "--block-size", "8192", "--image-size", "67108864", "--workspace-root", "/tmp/bench" });
    try std.testing.expectEqual(Operation.write_overwrite, configured.operation.?);
    try std.testing.expectEqual(@as(u32, 12), configured.iterations);
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "benchmark", "--journaled", "true" }));
    try std.testing.expectError(error.ZeroValue, parseArgs(&.{ "benchmark", "--iterations", "0" }));
}
