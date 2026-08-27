const std = @import("std");

pub const ReadPolicy = enum { first_available, quorum };
pub const StorageTransport = enum { linux, spdk_nvme_pcie, synthetic };
pub const PreparationMode = enum { none, create, validate };
pub const BenchmarkMode = enum { pool, raw_nvme };
pub const max_reactor_count = 16;
pub const max_vhost_controller_count = 4;
pub const default_concurrent_group_count = 8;
pub const max_concurrent_group_count = 64;

pub const WindowSpec = struct {
    device_index: usize,
    offset: u64,
    length: u64,
};

pub const PcieNamespace = struct {
    bdf: []const u8,
    nsid: u32,
};

pub fn parseStorageTransport(text: ?[]const u8) !StorageTransport {
    const value = text orelse return .linux;
    if (std.mem.eql(u8, value, "linux")) return .linux;
    if (std.mem.eql(u8, value, "spdk_nvme_pcie")) return .spdk_nvme_pcie;
    if (std.mem.eql(u8, value, "synthetic")) return .synthetic;
    return error.InvalidStorageTransport;
}

pub fn parsePreparationMode(text: ?[]const u8) !PreparationMode {
    const value = text orelse return .none;
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "create")) return .create;
    if (std.mem.eql(u8, value, "validate")) return .validate;
    return error.InvalidPreparationMode;
}

pub fn parseBenchmarkMode(text: ?[]const u8) !BenchmarkMode {
    const value = text orelse return .pool;
    if (std.mem.eql(u8, value, "pool")) return .pool;
    if (std.mem.eql(u8, value, "raw_nvme")) return .raw_nvme;
    return error.InvalidBenchmarkMode;
}

pub fn parsePcieNamespace(text: []const u8) !PcieNamespace {
    if (text.len < 14 or text[12] != '/' or std.mem.indexOfScalarPos(u8, text, 13, '/') != null)
        return error.InvalidPcieNamespace;
    const bdf = text[0..12];
    if (bdf[4] != ':' or bdf[7] != ':' or bdf[10] != '.' or
        !allLowerHex(bdf[0..4]) or !allLowerHex(bdf[5..7]) or
        !allLowerHex(bdf[8..10]) or bdf[11] < '0' or bdf[11] > '7')
        return error.InvalidPcieNamespace;
    const nsid = parseDecimal(u32, text[13..]) catch return error.InvalidPcieNamespace;
    if (nsid == 0) return error.InvalidPcieNamespace;
    return .{ .bdf = bdf, .nsid = nsid };
}

fn allLowerHex(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

pub fn parseReadPolicy(raw: c_int) !ReadPolicy {
    return switch (raw) {
        0 => .first_available,
        1 => .quorum,
        else => error.InvalidReadPolicy,
    };
}

pub fn parsePoolId(text: []const u8) ![16]u8 {
    if (text.len != 32) return error.InvalidExpectedPoolId;
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return error.InvalidExpectedPoolId;
    return result;
}

pub fn parseReactorCount(text: ?[]const u8) !usize {
    const value = text orelse return 1;
    if (value.len == 0) return error.InvalidReactorCount;
    var count: usize = 0;
    for (value) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidReactorCount;
        count = std.math.mul(usize, count, 10) catch return error.InvalidReactorCount;
        count = std.math.add(usize, count, digit - '0') catch return error.InvalidReactorCount;
    }
    if (count == 0 or count > max_reactor_count) return error.InvalidReactorCount;
    return count;
}

pub fn parseVhostControllerCount(text: ?[]const u8, reactor_count: usize) !usize {
    const count = if (text) |value|
        parseReactorCount(value) catch return error.InvalidVhostControllerCount
    else
        reactor_count;
    if (count == 0 or count > max_vhost_controller_count or count > reactor_count)
        return error.InvalidVhostControllerCount;
    return count;
}

pub fn parseVhostWorkerCount(text: ?[]const u8, controller_count: usize) !usize {
    const value = text orelse return 1;
    const count = parseDecimal(usize, value) catch return error.InvalidVhostWorkerCount;
    if (count == 0 or count > controller_count)
        return error.InvalidVhostWorkerCount;
    return count;
}

pub fn parseConcurrentGroupCount(text: ?[]const u8) !usize {
    const value = text orelse return default_concurrent_group_count;
    const count = parseDecimal(usize, value) catch return error.InvalidConcurrentGroupCount;
    if (count == 0 or count > max_concurrent_group_count)
        return error.InvalidConcurrentGroupCount;
    return count;
}

pub fn parseOptionalCpuBase(text: ?[]const u8) !?u32 {
    const value = text orelse return null;
    if (value.len == 0) return null;
    return parseDecimal(u32, value) catch error.InvalidCpuBase;
}

pub fn parseThreadedConcurrency(text: ?[]const u8) !?usize {
    const value = text orelse return null;
    if (value.len == 0) return null;
    const count = parseDecimal(usize, value) catch return error.InvalidThreadedConcurrency;
    if (count == 0 or count > 256) return error.InvalidThreadedConcurrency;
    return count;
}

pub fn parseOptionalFlag(text: ?[]const u8) !?bool {
    const value = text orelse return null;
    if (value.len == 0) return null;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.mem.eql(u8, value, "1")) return true;
    return error.InvalidFlag;
}

pub fn reactorMaskAt(mask: []const u8, index: usize, buffer: []u8) ![]const u8 {
    if (mask.len < 3 or mask[0] != '[' or mask[mask.len - 1] != ']')
        return error.InvalidReactorMask;
    var cores = std.mem.splitScalar(u8, mask[1 .. mask.len - 1], ',');
    var current: usize = 0;
    while (cores.next()) |core| : (current += 1) {
        if (core.len == 0) return error.InvalidReactorMask;
        if (current == index) return std.fmt.bufPrint(buffer, "[{s}]", .{core});
    }
    return error.InvalidReactorMask;
}

pub fn parseWindowSpecs(text: ?[]const u8, output: []WindowSpec) ![]const WindowSpec {
    const value = text orelse return output[0..0];
    if (value.len == 0) return output[0..0];
    var specs = std.mem.splitScalar(u8, value, ',');
    var count: usize = 0;
    while (specs.next()) |spec| {
        if (count == output.len) return error.TooManyStorageWindows;
        var fields = std.mem.splitScalar(u8, spec, ':');
        const device_index = try parseDecimal(usize, fields.next() orelse return error.InvalidStorageWindow);
        const offset = try parseDecimal(u64, fields.next() orelse return error.InvalidStorageWindow);
        const length = try parseDecimal(u64, fields.next() orelse return error.InvalidStorageWindow);
        if (fields.next() != null or length == 0)
            return error.InvalidStorageWindow;
        _ = std.math.add(u64, offset, length) catch return error.InvalidStorageWindow;
        output[count] = .{ .device_index = device_index, .offset = offset, .length = length };
        count += 1;
    }
    return output[0..count];
}

fn parseDecimal(comptime T: type, text: []const u8) !T {
    if (text.len == 0) return error.InvalidStorageWindow;
    var result: T = 0;
    for (text) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidStorageWindow;
        result = std.math.mul(T, result, 10) catch return error.InvalidStorageWindow;
        result = std.math.add(T, result, digit - '0') catch return error.InvalidStorageWindow;
    }
    return result;
}

test "read policy accepts only supported values" {
    try std.testing.expectEqual(ReadPolicy.first_available, try parseReadPolicy(0));
    try std.testing.expectEqual(ReadPolicy.quorum, try parseReadPolicy(1));
    try std.testing.expectError(error.InvalidReadPolicy, parseReadPolicy(2));
}

test "storage transport defaults to Linux and accepts supported backends" {
    try std.testing.expectEqual(StorageTransport.linux, try parseStorageTransport(null));
    try std.testing.expectEqual(StorageTransport.linux, try parseStorageTransport("linux"));
    try std.testing.expectEqual(StorageTransport.spdk_nvme_pcie, try parseStorageTransport("spdk_nvme_pcie"));
    try std.testing.expectEqual(StorageTransport.synthetic, try parseStorageTransport("synthetic"));
    for ([_][]const u8{ "", "pcie", "SPDK_NVME_PCIE", "dummy" }) |value|
        try std.testing.expectError(error.InvalidStorageTransport, parseStorageTransport(value));
}

test "preparation mode defaults to none and accepts supported modes" {
    try std.testing.expectEqual(PreparationMode.none, try parsePreparationMode(null));
    try std.testing.expectEqual(PreparationMode.none, try parsePreparationMode("none"));
    try std.testing.expectEqual(PreparationMode.create, try parsePreparationMode("create"));
    try std.testing.expectEqual(PreparationMode.validate, try parsePreparationMode("validate"));
}

test "preparation mode rejects empty and unknown values" {
    for ([_][]const u8{ "", "CREATE", "check", " create" }) |value|
        try std.testing.expectError(error.InvalidPreparationMode, parsePreparationMode(value));
}

test "benchmark mode defaults to Pool and accepts raw NVMe" {
    try std.testing.expectEqual(BenchmarkMode.pool, try parseBenchmarkMode(null));
    try std.testing.expectEqual(BenchmarkMode.pool, try parseBenchmarkMode("pool"));
    try std.testing.expectEqual(BenchmarkMode.raw_nvme, try parseBenchmarkMode("raw_nvme"));
    for ([_][]const u8{ "", "raw", "RAW_NVME" }) |value|
        try std.testing.expectError(error.InvalidBenchmarkMode, parseBenchmarkMode(value));
}

test "PCIe namespaces require canonical BDF and nonzero NSID" {
    try std.testing.expectEqualDeep(
        PcieNamespace{ .bdf = "0000:07:00.0", .nsid = 1 },
        try parsePcieNamespace("0000:07:00.0/1"),
    );
    try std.testing.expectEqual(std.math.maxInt(u32), (try parsePcieNamespace("ffff:ff:ff.7/4294967295")).nsid);
    for ([_][]const u8{
        "0000:07:00.0",
        "0000:07:00.0/0",
        "0000:07:00.0/1/2",
        "0000:7:00.0/1",
        "0000:07:00.8/1",
        "0000:0A:00.0/1",
        "0000:07:00.0/+1",
        "0000:07:00.0/4294967296",
    }) |value| try std.testing.expectError(error.InvalidPcieNamespace, parsePcieNamespace(value));
}

test "Pool ID requires 16 hexadecimal bytes" {
    try std.testing.expectEqual(@as([16]u8, @splat(0xab)), try parsePoolId("abababababababababababababababab"));
    try std.testing.expectError(error.InvalidExpectedPoolId, parsePoolId("ab"));
    try std.testing.expectError(error.InvalidExpectedPoolId, parsePoolId("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
}

test "reactor count defaults to one and accepts strict decimal values" {
    try std.testing.expectEqual(@as(usize, 1), try parseReactorCount(null));
    try std.testing.expectEqual(@as(usize, 1), try parseReactorCount("1"));
    try std.testing.expectEqual(max_reactor_count, try parseReactorCount("16"));
}

test "reactor count rejects invalid values" {
    for ([_][]const u8{ "", "0", "17", "+1", " 1", "1 ", "1x" }) |value| {
        try std.testing.expectError(error.InvalidReactorCount, parseReactorCount(value));
    }
}

test "vhost controller count defaults to reactors and stays bounded" {
    try std.testing.expectEqual(@as(usize, 4), try parseVhostControllerCount(null, 4));
    try std.testing.expectEqual(@as(usize, 2), try parseVhostControllerCount("2", 4));
    for ([_][]const u8{ "", "0", "5", "+1", "x" }) |value| {
        try std.testing.expectError(error.InvalidVhostControllerCount, parseVhostControllerCount(value, 4));
    }
    try std.testing.expectError(error.InvalidVhostControllerCount, parseVhostControllerCount("4", 2));
}

test "vhost worker count defaults to one and cannot exceed controllers" {
    try std.testing.expectEqual(@as(usize, 1), try parseVhostWorkerCount(null, 4));
    try std.testing.expectEqual(@as(usize, 4), try parseVhostWorkerCount("4", 4));
    for ([_][]const u8{ "", "0", "5", "+1", "x" }) |value| {
        try std.testing.expectError(error.InvalidVhostWorkerCount, parseVhostWorkerCount(value, 4));
    }
}

test "concurrent group count is strict and bounded" {
    try std.testing.expectEqual(default_concurrent_group_count, try parseConcurrentGroupCount(null));
    try std.testing.expectEqual(@as(usize, 16), try parseConcurrentGroupCount("16"));
    for ([_][]const u8{ "", "0", "65", "+1", "x" }) |value| {
        try std.testing.expectError(error.InvalidConcurrentGroupCount, parseConcurrentGroupCount(value));
    }
}

test "optional CPU base accepts strict decimal values" {
    try std.testing.expectEqual(@as(?u32, null), try parseOptionalCpuBase(null));
    try std.testing.expectEqual(@as(?u32, null), try parseOptionalCpuBase(""));
    try std.testing.expectEqual(@as(?u32, 4), try parseOptionalCpuBase("4"));
    for ([_][]const u8{ "+1", "-1", "x" }) |value| {
        try std.testing.expectError(error.InvalidCpuBase, parseOptionalCpuBase(value));
    }
}

test "threaded concurrency is optional and bounded" {
    try std.testing.expectEqual(@as(?usize, null), try parseThreadedConcurrency(null));
    try std.testing.expectEqual(@as(?usize, null), try parseThreadedConcurrency(""));
    try std.testing.expectEqual(@as(?usize, 16), try parseThreadedConcurrency("16"));
    for ([_][]const u8{ "0", "257", "+1", "x" }) |value| {
        try std.testing.expectError(error.InvalidThreadedConcurrency, parseThreadedConcurrency(value));
    }
}

test "optional flag accepts only zero and one" {
    try std.testing.expectEqual(@as(?bool, null), try parseOptionalFlag(null));
    try std.testing.expectEqual(@as(?bool, null), try parseOptionalFlag(""));
    try std.testing.expectEqual(@as(?bool, false), try parseOptionalFlag("0"));
    try std.testing.expectEqual(@as(?bool, true), try parseOptionalFlag("1"));
    try std.testing.expectError(error.InvalidFlag, parseOptionalFlag("true"));
}

test "reactor mask selects one core" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("[0]", try reactorMaskAt("[0,2,7,9]", 0, &buffer));
    try std.testing.expectEqualStrings("[7]", try reactorMaskAt("[0,2,7,9]", 2, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("[0,2]", 2, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("0,2", 0, &buffer));
    try std.testing.expectError(error.InvalidReactorMask, reactorMaskAt("[0,,2]", 2, &buffer));
}

test "storage window specs parse strict device ranges" {
    var output: [4]WindowSpec = undefined;
    const specs = try parseWindowSpecs("0:0:1024,1:1024:2048", &output);
    try std.testing.expectEqual(@as(usize, 2), specs.len);
    try std.testing.expectEqualDeep(WindowSpec{ .device_index = 0, .offset = 0, .length = 1024 }, specs[0]);
    try std.testing.expectEqualDeep(WindowSpec{ .device_index = 1, .offset = 1024, .length = 2048 }, specs[1]);
    try std.testing.expectEqual(@as(usize, 0), (try parseWindowSpecs(null, &output)).len);
    for ([_][]const u8{ "0:0", "0:0:0", "0:0:1:", "0::1", "+0:0:1", "0:18446744073709551615:2", "0:0:1," }) |value| {
        try std.testing.expectError(error.InvalidStorageWindow, parseWindowSpecs(value, &output));
    }
}
