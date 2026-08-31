const std = @import("std");
const linux = std.os.linux;

const data_node = @import("data_node_service");

const max_key_file_size: usize = 128 * 1024;
const max_peer_keys: usize = 1024;

pub const TargetKeys = struct {
    allocator: std.mem.Allocator,
    values: []data_node.OutboundReplicaPeerKey,

    pub fn deinit(self: *TargetKeys) void {
        for (self.values) |*peer| std.crypto.secureZero(u8, &peer.key);
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

/// Load target-scoped receiver keys. Each non-empty line is exactly:
///
///     TARGET_NODE_UUIDV7 64_LOWER_OR_UPPER_HEX_KEY_BYTES
///
/// Duplicate target identities and duplicate receiver keys are rejected here.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
) !TargetKeys {
    const file = try parent.openFile(io, basename, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .lock = .shared,
    });
    defer file.close(io);
    var metadata: linux.Statx = undefined;
    const metadata_result = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &metadata);
    if (linux.errno(metadata_result) != .SUCCESS) return error.ReplicaKeyFileMetadataUnavailable;
    if (!linux.S.ISREG(metadata.mode) or metadata.uid != std.c.geteuid())
        return error.ReplicaKeyFileOwnerMismatch;
    if (metadata.mode & 0o077 != 0) return error.InsecureReplicaKeyFile;
    if (metadata.size == 0 or metadata.size > max_key_file_size)
        return error.InvalidReplicaKeyFile;
    const bytes = try allocator.alloc(u8, @intCast(metadata.size));
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len)
        return error.InvalidReplicaKeyFile;

    var peers: std.ArrayList(data_node.OutboundReplicaPeerKey) = .empty;
    errdefer {
        for (peers.items) |*peer| std.crypto.secureZero(u8, &peer.key);
        peers.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len == 0) continue;
        if (peers.items.len == max_peer_keys) return error.ReplicaKeyLimitExceeded;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const node_text = fields.next() orelse return error.InvalidReplicaKeyFile;
        const key_text = fields.next() orelse return error.InvalidReplicaKeyFile;
        if (fields.next() != null) return error.InvalidReplicaKeyFile;
        var candidate: data_node.OutboundReplicaPeerKey = .{
            .node_id = try parseUuidV7(node_text),
            .key = try parseKey(key_text),
        };
        errdefer std.crypto.secureZero(u8, &candidate.key);
        if (isZero(&candidate.key)) return error.InvalidReplicaKeyFile;
        for (peers.items) |existing| {
            if (std.mem.eql(u8, &existing.node_id, &candidate.node_id) or
                std.mem.eql(u8, &existing.key, &candidate.key))
                return error.DuplicateReplicaKey;
        }
        try peers.append(allocator, candidate);
        std.crypto.secureZero(u8, &candidate.key);
    }
    if (peers.items.len == 0) return error.InvalidReplicaKeyFile;
    return .{
        .allocator = allocator,
        .values = try peers.toOwnedSlice(allocator),
    };
}

fn parseUuidV7(value: []const u8) ![16]u8 {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or
        value[18] != '-' or value[23] != '-')
        return error.InvalidReplicaKeyFile;
    var result: [16]u8 = undefined;
    var source: usize = 0;
    var destination: usize = 0;
    while (destination < result.len) : (destination += 1) {
        while (value[source] == '-') source += 1;
        result[destination] = (try hexNibble(value[source])) << 4 |
            try hexNibble(value[source + 1]);
        source += 2;
    }
    if (result[6] & 0xf0 != 0x70 or result[8] & 0xc0 != 0x80)
        return error.InvalidReplicaKeyFile;
    return result;
}

fn parseKey(value: []const u8) ![32]u8 {
    if (value.len != 64) return error.InvalidReplicaKeyFile;
    var key: [32]u8 = undefined;
    for (&key, 0..) |*byte, index| {
        byte.* = (try hexNibble(value[index * 2])) << 4 |
            try hexNibble(value[index * 2 + 1]);
    }
    return key;
}

fn isZero(value: []const u8) bool {
    for (value) |byte| if (byte != 0) return false;
    return true;
}

fn hexNibble(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidReplicaKeyFile,
    };
}

test "loads bounded target-scoped outbound key file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const contents =
        "0198f54d-5c2a-7000-8000-000000000011 " ++ "0102030405060708090a0b0c0d0e0f10" ++
        "1112131415161718191a1b1c1d1e1f20\n" ++
        "0198f54d-5c2a-7000-8000-000000000021\t" ++ "a1a2a3a4a5a6a7a8a9aaabacadaeafb0" ++
        "b1b2b3b4b5b6b7b8b9babbbcbdbebfc0\r\n";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "replica-outbound.keys",
        .data = contents,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    var loaded = try load(std.testing.allocator, std.testing.io, tmp.dir, "replica-outbound.keys");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.values.len);
    try std.testing.expectEqual(@as(u8, 0x01), loaded.values[0].key[0]);
    try std.testing.expectEqual(@as(u8, 0xc0), loaded.values[1].key[31]);
}

test "rejects malformed empty and oversized key files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "empty",
        .data = "\n",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.InvalidReplicaKeyFile,
        load(std.testing.allocator, std.testing.io, tmp.dir, "empty"),
    );
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "malformed",
        .data = "not-a-node not-a-key\n",
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.InvalidReplicaKeyFile,
        load(std.testing.allocator, std.testing.io, tmp.dir, "malformed"),
    );
    const oversized = try std.testing.allocator.alloc(u8, max_key_file_size + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "oversized",
        .data = oversized,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try std.testing.expectError(
        error.InvalidReplicaKeyFile,
        load(std.testing.allocator, std.testing.io, tmp.dir, "oversized"),
    );
}

test "rejects duplicate target identities keys and zero secrets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const node_a = "0198f54d-5c2a-7000-8000-000000000011";
    const node_b = "0198f54d-5c2a-7000-8000-000000000021";
    const key = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
    const cases = [_][]const u8{
        node_a ++ " " ++ key ++ "\n" ++ node_a ++ " " ++ "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\n",
        node_a ++ " " ++ key ++ "\n" ++ node_b ++ " " ++ key ++ "\n",
        node_a ++ " " ++ "0000000000000000000000000000000000000000000000000000000000000000\n",
    };
    for (cases, 0..) |contents, index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "bad-{d}.keys", .{index});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = contents, .flags = .{ .permissions = @enumFromInt(0o600) } });
        const expected = if (index == 2) error.InvalidReplicaKeyFile else error.DuplicateReplicaKey;
        try std.testing.expectError(expected, load(std.testing.allocator, std.testing.io, tmp.dir, name));
    }
}

test "rejects group or world accessible key file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const contents = "0198f54d-5c2a-7000-8000-000000000011 " ++
        "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20\n";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "replica-outbound.keys",
        .data = contents,
        .flags = .{ .permissions = @enumFromInt(0o640) },
    });
    const file = try tmp.dir.openFile(std.testing.io, "replica-outbound.keys", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, @enumFromInt(0o640));
    try std.testing.expectError(
        error.InsecureReplicaKeyFile,
        load(std.testing.allocator, std.testing.io, tmp.dir, "replica-outbound.keys"),
    );
}

test "rejects key-file symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const contents = "0198f54d-5c2a-7000-8000-000000000011 " ++
        "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20\n";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "target.keys",
        .data = contents,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
    try tmp.dir.symLink(std.testing.io, "target.keys", "replica-outbound.keys", .{});
    try std.testing.expectError(
        error.SymLinkLoop,
        load(std.testing.allocator, std.testing.io, tmp.dir, "replica-outbound.keys"),
    );
}
