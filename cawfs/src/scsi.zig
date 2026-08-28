//! Backend-neutral SCSI commands for a full-block conditional transport.

const std = @import("std");
const block = @import("conditional_block.zig");

pub const read_capacity_16 = 0x9e;
pub const read_16 = 0x88;
pub const compare_and_write = 0x89;
pub const synchronize_cache_16 = 0x91;
pub const maintenance_in = 0xa3;
pub const inquiry = 0x12;

pub const Data = union(enum) {
    none,
    from_device: []u8,
    to_device: []const u8,
    to_device_pair: struct {
        first: []const u8,
        second: []const u8,
    },

    pub fn byteLen(self: Data) usize {
        return switch (self) {
            .none => 0,
            .from_device => |bytes| bytes.len,
            .to_device => |bytes| bytes.len,
            .to_device_pair => |pair| pair.first.len + pair.second.len,
        };
    }
};

pub const Command = struct {
    cdb: [16]u8,
    cdb_len: u8 = 16,
    data: Data,
    timeout_ms: u32,
};

pub const max_sense_size = 252;

pub const Completion = struct {
    status: u8 = 0,
    host_status: u16 = 0,
    driver_status: u16 = 0,
    residual: i32 = 0,
    sense_len: u8 = 0,
    sense: [max_sense_size]u8 = @splat(0),

    pub fn senseBytes(self: *const Completion) []const u8 {
        return self.sense[0..self.sense_len];
    }
};

/// `.indeterminate` means the command may have reached the device. Ordinary
/// errors are allowed only when the executor knows the command was not sent.
pub const Execution = union(enum) {
    completed: Completion,
    indeterminate,
};

pub const Executor = struct {
    context: *anyopaque,
    execute_fn: *const fn (*anyopaque, *Command) anyerror!Execution,

    /// Implementations must support concurrent calls when used by
    /// `ScsiConditionalBlock`.
    pub fn execute(self: Executor, command: *Command) !Execution {
        return self.execute_fn(self.context, command);
    }
};

pub const Sense = struct {
    key: u4,
    asc: u8,
    ascq: u8,
    deferred: bool,
};

pub fn parseSense(bytes: []const u8) ?Sense {
    if (bytes.len == 0) return null;
    return switch (bytes[0] & 0x7f) {
        0x70, 0x71 => |response| if (bytes.len >= 14) .{
            .key = @truncate(bytes[2]),
            .asc = bytes[12],
            .ascq = bytes[13],
            .deferred = response == 0x71,
        } else null,
        0x72, 0x73 => |response| if (bytes.len >= 4) .{
            .key = @truncate(bytes[1]),
            .asc = bytes[2],
            .ascq = bytes[3],
            .deferred = response == 0x73,
        } else null,
        else => null,
    };
}

pub const Options = struct {
    timeout_ms: u32 = 30_000,
    safe_attempts: u8 = 3,
};

pub const ScsiConditionalBlock = struct {
    executor: Executor,
    geometry: block.Geometry,
    options: Options,

    pub fn init(executor: Executor, options: Options) !ScsiConditionalBlock {
        if (options.timeout_ms == 0) return error.InvalidTimeout;
        if (options.safe_attempts == 0) return error.InvalidAttemptCount;

        var capacity: [32]u8 = @splat(0);
        var capacity_command = capacityCommand(&capacity, options.timeout_ms);
        _ = try executeSafe(executor, &capacity_command, options.safe_attempts);
        const last_lba = readBe64(capacity[0..8]);
        if (last_lba == std.math.maxInt(u64)) return error.InvalidDeviceGeometry;
        const geometry = block.Geometry{
            .logical_block_size = readBe32(capacity[8..12]),
            .block_count = last_lba + 1,
        };
        try geometry.validate();

        var support: [20]u8 = @splat(0);
        var support_command = reportOpcodeCommand(compare_and_write, &support, options.timeout_ms);
        _ = executeSafe(executor, &support_command, options.safe_attempts) catch
            return error.CompareAndWriteProbeFailed;
        if ((support[1] & 0x07) != 0x03 or
            readBe16(support[2..4]) != 16 or
            support[4] != compare_and_write)
        {
            return error.CompareAndWriteUnsupported;
        }

        var block_limits: [64]u8 = @splat(0);
        var limits_command = blockLimitsCommand(&block_limits, options.timeout_ms);
        _ = executeSafe(executor, &limits_command, options.safe_attempts) catch
            return error.BlockLimitsProbeFailed;
        if (block_limits[1] != 0xb0 or
            readBe16(block_limits[2..4]) < 2 or
            block_limits[5] < 1)
        {
            return error.CompareAndWriteUnsupported;
        }

        return .{ .executor = executor, .geometry = geometry, .options = options };
    }

    pub fn transport(self: *ScsiConditionalBlock) block.ConditionalBlockTransport {
        return .{
            .context = self,
            .vtable = &vtable,
            .geometry = self.geometry,
            .device_identity = self.executor.context,
        };
    }

    fn readBlock(context: *anyopaque, block_index: u64, output: []u8) !void {
        const self: *ScsiConditionalBlock = @ptrCast(@alignCast(context));
        var command = readCommand(block_index, output, self.options.timeout_ms);
        _ = try executeSafe(self.executor, &command, self.options.safe_attempts);
    }

    fn compareAndWrite(
        context: *anyopaque,
        block_index: u64,
        expected: []const u8,
        replacement: []const u8,
    ) !block.CawResult {
        const self: *ScsiConditionalBlock = @ptrCast(@alignCast(context));
        var command = compareAndWriteCommand(
            block_index,
            expected,
            replacement,
            self.options.timeout_ms,
        );
        const execution = self.executor.execute(&command) catch |err| return err;
        return switch (execution) {
            .indeterminate => .indeterminate,
            .completed => |completion| classifyCaw(&completion),
        };
    }

    fn stabilize(context: *anyopaque) !void {
        const self: *ScsiConditionalBlock = @ptrCast(@alignCast(context));
        var command = synchronizeCommand(self.options.timeout_ms);
        _ = try executeSafe(self.executor, &command, self.options.safe_attempts);
    }

    const vtable = block.ConditionalBlockTransport.VTable{
        .read_block = readBlock,
        .compare_and_write = compareAndWrite,
        .stabilize = stabilize,
    };
};

pub fn capacityCommand(output: []u8, timeout_ms: u32) Command {
    var cdb: [16]u8 = @splat(0);
    cdb[0] = read_capacity_16;
    cdb[1] = 0x10;
    writeBe32(cdb[10..14], @intCast(output.len));
    return .{ .cdb = cdb, .data = .{ .from_device = output }, .timeout_ms = timeout_ms };
}

pub fn reportOpcodeCommand(opcode: u8, output: []u8, timeout_ms: u32) Command {
    var cdb: [16]u8 = @splat(0);
    cdb[0] = maintenance_in;
    cdb[1] = 0x0c;
    cdb[2] = 0x01;
    cdb[3] = opcode;
    writeBe32(cdb[6..10], @intCast(output.len));
    return .{ .cdb = cdb, .data = .{ .from_device = output }, .timeout_ms = timeout_ms };
}

pub fn blockLimitsCommand(output: []u8, timeout_ms: u32) Command {
    std.debug.assert(output.len <= std.math.maxInt(u16));
    var cdb: [16]u8 = @splat(0);
    cdb[0] = inquiry;
    cdb[1] = 0x01;
    cdb[2] = 0xb0;
    writeBe16(cdb[3..5], @intCast(output.len));
    return .{
        .cdb = cdb,
        .cdb_len = 6,
        .data = .{ .from_device = output },
        .timeout_ms = timeout_ms,
    };
}

pub fn readCommand(block_index: u64, output: []u8, timeout_ms: u32) Command {
    var cdb: [16]u8 = @splat(0);
    cdb[0] = read_16;
    writeBe64(cdb[2..10], block_index);
    writeBe32(cdb[10..14], 1);
    return .{ .cdb = cdb, .data = .{ .from_device = output }, .timeout_ms = timeout_ms };
}

pub fn compareAndWriteCommand(
    block_index: u64,
    expected: []const u8,
    replacement: []const u8,
    timeout_ms: u32,
) Command {
    var cdb: [16]u8 = @splat(0);
    cdb[0] = compare_and_write;
    writeBe64(cdb[2..10], block_index);
    cdb[13] = 1;
    return .{
        .cdb = cdb,
        .data = .{ .to_device_pair = .{ .first = expected, .second = replacement } },
        .timeout_ms = timeout_ms,
    };
}

pub fn synchronizeCommand(timeout_ms: u32) Command {
    var cdb: [16]u8 = @splat(0);
    cdb[0] = synchronize_cache_16;
    return .{ .cdb = cdb, .data = .none, .timeout_ms = timeout_ms };
}

fn executeSafe(executor: Executor, command: *Command, max_attempts: u8) !Completion {
    var attempts: u8 = 0;
    while (attempts < max_attempts) : (attempts += 1) {
        const execution = executor.execute(command) catch |err| {
            if (attempts + 1 == max_attempts) return err;
            continue;
        };
        switch (execution) {
            .indeterminate => {},
            .completed => |completion| {
                if (isSuccessful(&completion)) return completion;
                if (!isRetryable(&completion)) return completionError(&completion);
            },
        }
    }
    return error.ScsiCommandIndeterminate;
}

fn classifyCaw(completion: *const Completion) !block.CawResult {
    if (isSuccessful(completion)) return .written;
    if (completion.host_status != 0 or hasDriverFailure(completion)) return .indeterminate;

    const sense = parseSense(completion.senseBytes());
    if (completion.status == 0x02 and sense != null) {
        if (!sense.?.deferred and
            sense.?.key == 0x0e and
            sense.?.asc == 0x1d and
            sense.?.ascq == 0)
        {
            return .miscompare;
        }
        if (!sense.?.deferred and sense.?.key == 0x05) {
            if (sense.?.asc == 0x20 and sense.?.ascq == 0)
                return error.CompareAndWriteUnsupported;
            return error.ScsiIllegalRequest;
        }
    }
    if (completion.status == 0x08 or
        completion.status == 0x18 or
        completion.status == 0x28)
    {
        return error.ScsiCommandRejected;
    }
    return .indeterminate;
}

fn isSuccessful(completion: *const Completion) bool {
    return completion.status == 0 and
        completion.host_status == 0 and
        completion.driver_status == 0 and
        completion.residual == 0;
}

fn isRetryable(completion: *const Completion) bool {
    return completion.host_status != 0 or
        hasDriverFailure(completion) or
        completion.status == 0x08 or
        completion.status == 0x28;
}

fn hasDriverFailure(completion: *const Completion) bool {
    const status = completion.driver_status & 0x0f;
    return status != 0 and status != 0x08;
}

fn completionError(completion: *const Completion) anyerror {
    if (completion.status == 0x18) return error.ScsiReservationConflict;
    if (parseSense(completion.senseBytes())) |sense| {
        if (sense.key == 0x05) return error.ScsiIllegalRequest;
    }
    return error.ScsiCommandFailed;
}

fn writeBe32(output: []u8, value: u32) void {
    output[0] = @truncate(value >> 24);
    output[1] = @truncate(value >> 16);
    output[2] = @truncate(value >> 8);
    output[3] = @truncate(value);
}

fn writeBe16(output: []u8, value: u16) void {
    output[0] = @truncate(value >> 8);
    output[1] = @truncate(value);
}

fn writeBe64(output: []u8, value: u64) void {
    output[0] = @truncate(value >> 56);
    output[1] = @truncate(value >> 48);
    output[2] = @truncate(value >> 40);
    output[3] = @truncate(value >> 32);
    output[4] = @truncate(value >> 24);
    output[5] = @truncate(value >> 16);
    output[6] = @truncate(value >> 8);
    output[7] = @truncate(value);
}

fn readBe32(input: []const u8) u32 {
    return (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        input[3];
}

fn readBe16(input: []const u8) u16 {
    return (@as(u16, input[0]) << 8) | input[1];
}

fn readBe64(input: []const u8) u64 {
    return (@as(u64, input[0]) << 56) |
        (@as(u64, input[1]) << 48) |
        (@as(u64, input[2]) << 40) |
        (@as(u64, input[3]) << 32) |
        (@as(u64, input[4]) << 24) |
        (@as(u64, input[5]) << 16) |
        (@as(u64, input[6]) << 8) |
        input[7];
}

const Mock = struct {
    calls: usize = 0,
    read_failures: u8 = 0,
    sync_failures: u8 = 0,
    opcode_support: u8 = 0x03,
    reported_cdb_len: u16 = 16,
    maximum_caw_blocks: u8 = 1,
    caw_execution: Execution = .{ .completed = .{} },

    fn executor(self: *Mock) Executor {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: *Command) !Execution {
        const self: *Mock = @ptrCast(@alignCast(context));
        self.calls += 1;
        switch (command.cdb[0]) {
            read_capacity_16 => {
                const output = command.data.from_device;
                writeBe64(output[0..8], 7);
                writeBe32(output[8..12], 512);
                return .{ .completed = .{} };
            },
            maintenance_in => {
                const output = command.data.from_device;
                output[1] = self.opcode_support;
                writeBe16(output[2..4], self.reported_cdb_len);
                output[4] = compare_and_write;
                return .{ .completed = .{} };
            },
            inquiry => {
                const output = command.data.from_device;
                output[1] = 0xb0;
                writeBe16(output[2..4], 60);
                output[5] = self.maximum_caw_blocks;
                return .{ .completed = .{} };
            },
            read_16 => {
                if (self.read_failures != 0) {
                    self.read_failures -= 1;
                    return .indeterminate;
                }
                @memset(command.data.from_device, 0x5a);
                return .{ .completed = .{} };
            },
            compare_and_write => return self.caw_execution,
            synchronize_cache_16 => {
                if (self.sync_failures != 0) {
                    self.sync_failures -= 1;
                    return .{ .completed = .{ .status = 0x08 } };
                }
                return .{ .completed = .{} };
            },
            else => return error.UnexpectedCommand,
        }
    }
};

test "SCSI CDBs encode one complete logical block" {
    var output: [512]u8 = undefined;
    const read = readCommand(0x0102030405060708, &output, 1234);
    try std.testing.expectEqualSlices(u8, &.{
        0x88, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 1, 0, 0,
    }, &read.cdb);

    const replacement: [512]u8 = @splat(1);
    const caw = compareAndWriteCommand(0x0102030405060708, &output, &replacement, 1234);
    try std.testing.expectEqualSlices(u8, &.{
        0x89, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 1, 0, 0,
    }, &caw.cdb);
    try std.testing.expectEqual(@as(usize, 1024), caw.data.byteLen());

    var limits: [64]u8 = undefined;
    const inquiry_command = blockLimitsCommand(&limits, 1234);
    try std.testing.expectEqual(@as(u8, 6), inquiry_command.cdb_len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x12, 1, 0xb0, 0, 64, 0 },
        inquiry_command.cdb[0..inquiry_command.cdb_len],
    );
}

test "sense parser accepts fixed and descriptor formats" {
    var fixed: [14]u8 = @splat(0);
    fixed[0] = 0x70;
    fixed[2] = 0x0e;
    fixed[12] = 0x1d;
    try std.testing.expectEqual(Sense{
        .key = 0x0e,
        .asc = 0x1d,
        .ascq = 0,
        .deferred = false,
    }, parseSense(&fixed).?);
    try std.testing.expectEqual(
        Sense{ .key = 0x05, .asc = 0x20, .ascq = 0, .deferred = false },
        parseSense(&.{ 0x72, 0x05, 0x20, 0 }).?,
    );
    try std.testing.expect(parseSense(&.{ 0x73, 0x0e, 0x1d, 0 }).?.deferred);
    try std.testing.expectEqual(@as(?Sense, null), parseSense(&.{0x70}));
}

test "SCSI transport probes geometry and retries only safe commands" {
    var mock = Mock{ .read_failures = 1, .sync_failures = 1 };
    var scsi = try ScsiConditionalBlock.init(mock.executor(), .{});
    const transport = scsi.transport();
    try std.testing.expect(transport.deviceIdentity() == @as(*anyopaque, @ptrCast(&mock)));
    try std.testing.expectEqual(block.Geometry{
        .logical_block_size = 512,
        .block_count = 8,
    }, transport.geometry);

    var output: [512]u8 = undefined;
    try transport.readBlock(3, &output);
    try std.testing.expectEqual(@as(u8, 0x5a), output[511]);
    try transport.stabilize();
    try std.testing.expectEqual(@as(usize, 7), mock.calls);
}

test "SCSI transport never retries indeterminate CAW" {
    var mock = Mock{ .caw_execution = .indeterminate };
    var scsi = try ScsiConditionalBlock.init(mock.executor(), .{});
    const transport = scsi.transport();
    const expected: [512]u8 = @splat(0);
    const replacement: [512]u8 = @splat(1);
    try std.testing.expectEqual(
        block.CawResult.indeterminate,
        try transport.compareAndWrite(0, &expected, &replacement),
    );
    try std.testing.expectEqual(@as(usize, 4), mock.calls);
}

test "SCSI transport recognizes CAW miscompare sense" {
    var completion = Completion{ .status = 0x02, .sense_len = 4 };
    completion.sense[0..4].* = .{ 0x72, 0x0e, 0x1d, 0 };
    var mock = Mock{ .caw_execution = .{ .completed = completion } };
    var scsi = try ScsiConditionalBlock.init(mock.executor(), .{});
    const transport = scsi.transport();
    const expected: [512]u8 = @splat(0);
    const replacement: [512]u8 = @splat(1);
    try std.testing.expectEqual(
        block.CawResult.miscompare,
        try transport.compareAndWrite(0, &expected, &replacement),
    );
}

test "SCSI transport rejects malformed or insufficient CAW capabilities" {
    var reserved_support = Mock{ .opcode_support = 0x07 };
    try std.testing.expectError(
        error.CompareAndWriteUnsupported,
        ScsiConditionalBlock.init(reserved_support.executor(), .{}),
    );

    var wrong_cdb_size = Mock{ .reported_cdb_len = 10 };
    try std.testing.expectError(
        error.CompareAndWriteUnsupported,
        ScsiConditionalBlock.init(wrong_cdb_size.executor(), .{}),
    );

    var zero_length = Mock{ .maximum_caw_blocks = 0 };
    try std.testing.expectError(
        error.CompareAndWriteUnsupported,
        ScsiConditionalBlock.init(zero_length.executor(), .{}),
    );
}

test "deferred or transport-failed sense is not a proven CAW miscompare" {
    var deferred = Completion{ .status = 0x02, .sense_len = 4 };
    deferred.sense[0..4].* = .{ 0x73, 0x0e, 0x1d, 0 };
    try std.testing.expectEqual(block.CawResult.indeterminate, try classifyCaw(&deferred));

    var failed = Completion{ .status = 0x02, .driver_status = 0x01, .sense_len = 4 };
    failed.sense[0..4].* = .{ 0x72, 0x0e, 0x1d, 0 };
    try std.testing.expectEqual(block.CawResult.indeterminate, try classifyCaw(&failed));
}
