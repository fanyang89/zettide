const std = @import("std");

const clap = @import("clap");
const raft = @import("raftz");
const uuid = @import("uuid");

const params = clap.parseParamsComptime(
    \\-h, --help                         Display this help and exit.
    \\    --node-id <u64>                Stable non-zero Raft node ID.
    \\    --cluster-id <str>             Stable cluster UUID.
    \\    --management-listen <str>      Pool API IPv4 address.
    \\    --raft-listen <str>            Raft transport IPv4 address.
    \\    --raft-advertise <str>         Raft address advertised to peers.
    \\    --data-dir <str>               Persistent WAL directory.
    \\    --peer <str>...                Initial voter as ID=IPv4:PORT.
    \\
);

pub const Config = struct {
    allocator: std.mem.Allocator,
    node_id: u64,
    cluster_id: raft.ClusterId,
    management_host: []u8,
    management_port: u16,
    raft_listen: []u8,
    raft_advertise: []u8,
    data_dir: []u8,
    peers: []raft.Peer,

    pub fn deinit(self: *Config) void {
        for (self.peers) |peer| self.allocator.free(peer.context.?);
        self.allocator.free(self.peers);
        self.allocator.free(self.data_dir);
        self.allocator.free(self.raft_advertise);
        self.allocator.free(self.raft_listen);
        self.allocator.free(self.management_host);
        self.* = undefined;
    }
};

pub const ParseResult = union(enum) {
    help,
    config: Config,

    pub fn deinit(self: *ParseResult) void {
        switch (self.*) {
            .help => {},
            .config => |*config| config.deinit(),
        }
        self.* = undefined;
    }
};

pub const Diagnostic = clap.Diagnostic;

pub fn parse(
    allocator: std.mem.Allocator,
    iterator: anytype,
    diagnostic: *Diagnostic,
) !ParseResult {
    var parsed = try clap.parseEx(clap.Help, &params, clap.parsers.default, iterator, .{
        .allocator = allocator,
        .diagnostic = diagnostic,
    });
    defer parsed.deinit();
    if (parsed.args.help != 0) return .help;

    const node_id = @field(parsed.args, "node-id") orelse return error.NodeIdRequired;
    if (node_id == 0) return error.InvalidNodeId;
    const cluster_id_text = @field(parsed.args, "cluster-id") orelse return error.ClusterIdRequired;
    const parsed_cluster_id = uuid.urn.deserialize(cluster_id_text) catch return error.InvalidClusterId;
    if (parsed_cluster_id == 0) return error.InvalidClusterId;
    var cluster_id: raft.ClusterId = undefined;
    std.mem.writeInt(u128, &cluster_id, parsed_cluster_id, .big);

    const management_text = @field(parsed.args, "management-listen") orelse return error.ManagementListenRequired;
    const management = parseEndpoint(management_text) catch return error.InvalidManagementListen;
    const raft_listen_text = @field(parsed.args, "raft-listen") orelse return error.RaftListenRequired;
    _ = parseEndpoint(raft_listen_text) catch return error.InvalidRaftListen;
    const raft_advertise_text = @field(parsed.args, "raft-advertise") orelse raft_listen_text;
    _ = parseEndpoint(raft_advertise_text) catch return error.InvalidRaftAdvertise;
    if (std.mem.eql(u8, management_text, raft_listen_text)) return error.ListenAddressConflict;

    const data_dir_text = @field(parsed.args, "data-dir") orelse return error.DataDirRequired;
    if (data_dir_text.len == 0) return error.DataDirRequired;
    const peer_args = parsed.args.peer;
    if (peer_args.len == 0) return error.PeerRequired;

    const management_host = try allocator.dupe(u8, management.host);
    errdefer allocator.free(management_host);
    const raft_listen = try allocator.dupe(u8, raft_listen_text);
    errdefer allocator.free(raft_listen);
    const raft_advertise = try allocator.dupe(u8, raft_advertise_text);
    errdefer allocator.free(raft_advertise);
    const data_dir = try allocator.dupe(u8, data_dir_text);
    errdefer allocator.free(data_dir);
    const peers = try allocator.alloc(raft.Peer, peer_args.len);
    errdefer allocator.free(peers);

    var initialized: usize = 0;
    errdefer for (peers[0..initialized]) |peer| allocator.free(peer.context.?);
    var includes_self = false;
    for (peer_args, 0..) |peer_text, index| {
        const peer = parsePeer(peer_text) catch return error.InvalidPeer;
        for (peers[0..initialized]) |existing| {
            if (existing.id == peer.id) return error.DuplicatePeerId;
            if (std.mem.eql(u8, existing.context.?, peer.address)) return error.DuplicatePeerAddress;
        }
        peers[index] = .{
            .id = peer.id,
            .context = try allocator.dupe(u8, peer.address),
        };
        initialized += 1;
        if (peer.id == node_id) {
            if (!std.mem.eql(u8, peer.address, raft_advertise_text)) return error.LocalPeerAddressMismatch;
            includes_self = true;
        }
    }
    if (!includes_self) return error.LocalPeerRequired;

    return .{ .config = .{
        .allocator = allocator,
        .node_id = node_id,
        .cluster_id = cluster_id,
        .management_host = management_host,
        .management_port = management.port,
        .raft_listen = raft_listen,
        .raft_advertise = raft_advertise,
        .data_dir = data_dir,
        .peers = peers,
    } };
}

pub fn writeHelp(io: std.Io) !void {
    try clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
}

const Endpoint = struct {
    host: []const u8,
    port: u16,
};

fn parseEndpoint(value: []const u8) !Endpoint {
    const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidEndpoint;
    const host = value[0..separator];
    if (host.len == 0 or separator + 1 == value.len) return error.InvalidEndpoint;
    const port = std.fmt.parseUnsigned(u16, value[separator + 1 ..], 10) catch return error.InvalidEndpoint;
    if (port == 0) return error.InvalidEndpoint;
    _ = std.Io.net.IpAddress.parseIp4(host, port) catch return error.InvalidEndpoint;
    return .{ .host = host, .port = port };
}

const ParsedPeer = struct {
    id: u64,
    address: []const u8,
};

fn parsePeer(value: []const u8) !ParsedPeer {
    const separator = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidPeer;
    if (separator == 0 or separator + 1 == value.len) return error.InvalidPeer;
    const id = std.fmt.parseUnsigned(u64, value[0..separator], 10) catch return error.InvalidPeer;
    if (id == 0) return error.InvalidPeer;
    const address = value[separator + 1 ..];
    _ = try parseEndpoint(address);
    return .{ .id = id, .address = address };
}

fn parseSlice(arguments: []const []const u8) !ParseResult {
    var iterator = clap.args.SliceIterator{ .args = arguments };
    var diagnostic = Diagnostic{};
    return parse(std.testing.allocator, &iterator, &diagnostic);
}

test "parse persistent three-voter configuration" {
    const arguments = [_][]const u8{
        "--node-id",           "2",
        "--cluster-id",        "0198f54d-5c2a-7000-8000-000000000001",
        "--management-listen", "127.0.0.1:8002",
        "--raft-listen",       "127.0.0.1:9002",
        "--data-dir",          "/var/lib/zettide-controller/node-2",
        "--peer",              "1=127.0.0.1:9001",
        "--peer",              "2=127.0.0.1:9002",
        "--peer",              "3=127.0.0.1:9003",
    };
    var result = try parseSlice(&arguments);
    defer result.deinit();
    const config = &result.config;
    try std.testing.expectEqual(@as(u64, 2), config.node_id);
    try std.testing.expectEqualStrings("127.0.0.1", config.management_host);
    try std.testing.expectEqual(@as(u16, 8002), config.management_port);
    try std.testing.expectEqualStrings("127.0.0.1:9002", config.raft_advertise);
    try std.testing.expectEqual(@as(usize, 3), config.peers.len);
    try std.testing.expectEqualStrings("127.0.0.1:9003", config.peers[2].context.?);
}

test "parse explicit advertised Raft address" {
    const arguments = [_][]const u8{
        "--node-id",           "1",
        "--cluster-id",        "0198f54d-5c2a-7000-8000-000000000001",
        "--management-listen", "127.0.0.1:8001",
        "--raft-listen",       "0.0.0.0:9001",
        "--raft-advertise",    "127.0.0.1:9001",
        "--data-dir",          "/tmp/zettide-controller",
        "--peer",              "1=127.0.0.1:9001",
    };
    var result = try parseSlice(&arguments);
    defer result.deinit();
    try std.testing.expectEqualStrings("0.0.0.0:9001", result.config.raft_listen);
    try std.testing.expectEqualStrings("127.0.0.1:9001", result.config.raft_advertise);
}

test "parse help without required configuration" {
    const arguments = [_][]const u8{"--help"};
    var result = try parseSlice(&arguments);
    defer result.deinit();
    try std.testing.expect(result == .help);
}

test "reject invalid and inconsistent peers" {
    const base = [_][]const u8{
        "--node-id",           "1",
        "--cluster-id",        "0198f54d-5c2a-7000-8000-000000000001",
        "--management-listen", "127.0.0.1:8001",
        "--raft-listen",       "127.0.0.1:9001",
        "--data-dir",          "/tmp/zettide-controller",
    };
    const missing_local = base ++ [_][]const u8{ "--peer", "2=127.0.0.1:9002" };
    try std.testing.expectError(error.LocalPeerRequired, parseSlice(&missing_local));

    const wrong_local = base ++ [_][]const u8{
        "--peer", "1=127.0.0.1:9011",
    };
    try std.testing.expectError(error.LocalPeerAddressMismatch, parseSlice(&wrong_local));

    const duplicate_id = base ++ [_][]const u8{
        "--peer", "1=127.0.0.1:9001",
        "--peer", "1=127.0.0.1:9002",
    };
    try std.testing.expectError(error.DuplicatePeerId, parseSlice(&duplicate_id));

    const duplicate_address = base ++ [_][]const u8{
        "--peer", "1=127.0.0.1:9001",
        "--peer", "2=127.0.0.1:9001",
    };
    try std.testing.expectError(error.DuplicatePeerAddress, parseSlice(&duplicate_address));
}

test "reject missing durable and network configuration" {
    const missing_data_dir = [_][]const u8{
        "--node-id",           "1",
        "--cluster-id",        "0198f54d-5c2a-7000-8000-000000000001",
        "--management-listen", "127.0.0.1:8001",
        "--raft-listen",       "127.0.0.1:9001",
        "--peer",              "1=127.0.0.1:9001",
    };
    try std.testing.expectError(error.DataDirRequired, parseSlice(&missing_data_dir));

    const invalid_port = [_][]const u8{
        "--node-id",           "1",
        "--cluster-id",        "0198f54d-5c2a-7000-8000-000000000001",
        "--management-listen", "127.0.0.1:0",
        "--raft-listen",       "127.0.0.1:9001",
        "--data-dir",          "/tmp/zettide-controller",
        "--peer",              "1=127.0.0.1:9001",
    };
    try std.testing.expectError(error.InvalidManagementListen, parseSlice(&invalid_port));
}
