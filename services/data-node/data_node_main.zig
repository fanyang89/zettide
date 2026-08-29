const std = @import("std");

const controller_pb = @import("controller_proto");
const data_node = @import("data_node_service");
const grpc = @import("grpc_lite");

const registration_attempts = 60;
const registration_retry_delay = std.Io.Duration.fromSeconds(1);

const Config = struct {
    listen_host: []const u8,
    listen_port: u16,
    advertise_endpoint: []const u8,
    controller_endpoint: []const u8,
    request_id: []const u8,
    node_id: []const u8,
    cluster_id: [16]u8,
    iscsi_endpoint: []const u8,
    failure_domain: []const u8,
};

const Signals = struct {
    set: std.c.sigset_t,
    previous: std.c.sigset_t,

    fn block() !Signals {
        var result: Signals = undefined;
        if (std.c.sigemptyset(&result.set) != 0 or
            std.c.sigaddset(&result.set, .INT) != 0 or
            std.c.sigaddset(&result.set, .TERM) != 0)
            return error.SignalSetupFailed;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &result.set, &result.previous);
        return result;
    }

    fn wait(self: *Signals) !void {
        var signal_number: c_int = 0;
        if (std.c.sigwait(&self.set, &signal_number) != 0) return error.SignalWaitFailed;
    }

    fn restore(self: *Signals) void {
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.previous, null);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const config = parseArgs(args) catch |err| {
        writeUsage();
        return err;
    };

    var signals = try Signals.block();
    defer signals.restore();
    var server = try data_node.DataNodeServer.init(
        allocator,
        init.io,
        config.listen_host,
        config.listen_port,
    );
    defer server.deinit();
    try server.start();

    try registerNodeWithRetry(allocator, init.io, config);
    std.log.info(
        "zettide data-node ready control={s} iscsi={s} controller={s}",
        .{ config.advertise_endpoint, config.iscsi_endpoint, config.controller_endpoint },
    );

    try signals.wait();
    server.shutdownGracefully(5 * std.time.ns_per_s);
    server.wait();
}

fn parseArgs(args: []const []const u8) !Config {
    var listen: ?[]const u8 = null;
    var advertise: ?[]const u8 = null;
    var controller: ?[]const u8 = null;
    var request_id: ?[]const u8 = null;
    var node_id: ?[]const u8 = null;
    var cluster_id: ?[16]u8 = null;
    var iscsi_endpoint: ?[]const u8 = null;
    var failure_domain: []const u8 = "local/docker";

    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.InvalidArguments;
        const name = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, name, "--listen")) {
            listen = value;
        } else if (std.mem.eql(u8, name, "--advertise")) {
            advertise = value;
        } else if (std.mem.eql(u8, name, "--controller")) {
            controller = value;
        } else if (std.mem.eql(u8, name, "--request-id")) {
            request_id = value;
        } else if (std.mem.eql(u8, name, "--node-id")) {
            node_id = value;
        } else if (std.mem.eql(u8, name, "--cluster-id")) {
            var parsed_cluster_id = try parseUuid(value);
            // Match controller.config: uuid.urn.deserialize packs textual bytes
            // least-significant first before the controller writes the u128 in
            // big-endian order.
            std.mem.reverse(u8, &parsed_cluster_id);
            cluster_id = parsed_cluster_id;
        } else if (std.mem.eql(u8, name, "--iscsi-endpoint")) {
            iscsi_endpoint = value;
        } else if (std.mem.eql(u8, name, "--failure-domain")) {
            failure_domain = value;
        } else {
            return error.InvalidArguments;
        }
    }

    const listen_endpoint = listen orelse return error.ListenRequired;
    const parsed_listen = try parseEndpoint(listen_endpoint);
    const advertise_endpoint = advertise orelse return error.AdvertiseRequired;
    _ = try parseEndpoint(advertise_endpoint);
    const controller_endpoint = controller orelse return error.ControllerRequired;
    _ = try parseEndpoint(controller_endpoint);
    const registration_request_id = request_id orelse return error.RequestIdRequired;
    _ = try parseUuid(registration_request_id);
    const stable_node_id = node_id orelse return error.NodeIdRequired;
    _ = try parseUuid(stable_node_id);
    const target_endpoint = iscsi_endpoint orelse return error.IscsiEndpointRequired;
    if (target_endpoint.len == 0 or failure_domain.len == 0) return error.InvalidArguments;

    return .{
        .listen_host = parsed_listen.host,
        .listen_port = parsed_listen.port,
        .advertise_endpoint = advertise_endpoint,
        .controller_endpoint = controller_endpoint,
        .request_id = registration_request_id,
        .node_id = stable_node_id,
        .cluster_id = cluster_id orelse return error.ClusterIdRequired,
        .iscsi_endpoint = target_endpoint,
        .failure_domain = failure_domain,
    };
}

const Endpoint = struct {
    host: []const u8,
    port: u16,
};

fn parseEndpoint(value: []const u8) !Endpoint {
    const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidEndpoint;
    const host = value[0..separator];
    if (host.len == 0 or separator + 1 == value.len) return error.InvalidEndpoint;
    const port = std.fmt.parseUnsigned(u16, value[separator + 1 ..], 10) catch
        return error.InvalidEndpoint;
    if (port == 0) return error.InvalidEndpoint;
    return .{ .host = host, .port = port };
}

fn parseUuid(value: []const u8) ![16]u8 {
    if (value.len != 36 or value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-')
        return error.InvalidUuid;
    var result: [16]u8 = undefined;
    var source: usize = 0;
    var destination: usize = 0;
    while (destination < result.len) : (destination += 1) {
        while (value[source] == '-') source += 1;
        result[destination] = (try hexNibble(value[source])) << 4 | try hexNibble(value[source + 1]);
        source += 2;
    }
    if (result[6] & 0xf0 != 0x70 or result[8] & 0xc0 != 0x80) return error.InvalidUuid;
    return result;
}

fn hexNibble(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidUuid,
    };
}

fn registerNodeWithRetry(allocator: std.mem.Allocator, io: std.Io, config: Config) !void {
    var attempt: usize = 1;
    while (attempt <= registration_attempts) : (attempt += 1) {
        registerNode(allocator, config) catch |err| {
            if (attempt == registration_attempts) return err;
            std.log.warn(
                "controller registration attempt {d}/{d} failed: {s}",
                .{ attempt, registration_attempts, @errorName(err) },
            );
            try io.sleep(registration_retry_delay, .awake);
            continue;
        };
        return;
    }
    unreachable;
}

fn registerNode(allocator: std.mem.Allocator, config: Config) !void {
    var request = controller_pb.RegisterNodeRequest{
        .request_id = config.request_id,
        .node_id = config.node_id,
        .cluster_id = &config.cluster_id,
        .control_endpoint = config.advertise_endpoint,
        // The current controller schema has one data-plane endpoint field. The
        // local E2E profile publishes its iSCSI URL through that field.
        .nvmf_endpoint = config.iscsi_endpoint,
        .failure_domain = config.failure_domain,
        .capability_bits = 1,
        .protocol_version = 1,
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try request.encode(&writer.writer, allocator);

    var channel = try grpc.Channel.init(allocator, config.controller_endpoint, .{});
    defer channel.deinit();
    var result = try channel.callUnary(
        allocator,
        "/zettide.controller.v1.NodeService/RegisterNode",
        writer.written(),
        .{ .timeout_ns = 5 * std.time.ns_per_s },
    );
    defer result.deinit();
    if (!result.status.isOk()) return error.ControllerRejectedRegistration;

    var reader: std.Io.Reader = .fixed(result.payload);
    var response = try controller_pb.RegisterNodeResponse.decode(&reader, allocator);
    defer response.deinit(allocator);
    const registered = response.node orelse return error.MissingRegisteredNode;
    if (!std.mem.eql(u8, registered.id, config.node_id)) return error.RegisteredNodeMismatch;
}

fn writeUsage() void {
    std.debug.print(
        \\usage: zettide-data-node
        \\  --listen HOST:PORT --advertise HOST:PORT --controller HOST:PORT
        \\  --request-id UUIDv7 --node-id UUIDv7 --cluster-id UUIDv7
        \\  --iscsi-endpoint URL [--failure-domain TEXT]
        \\
    , .{});
}
