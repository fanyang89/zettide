const std = @import("std");

const grpc = @import("grpc_lite");
const raft = @import("raftz");
const config_mod = @import("config.zig");
const heartbeat = @import("heartbeat.zig");
const service_mod = @import("service.zig");
const state_machine = @import("state_machine.zig");

const log = raft.log;

pub const Options = struct {
    tick_interval_ms: u64 = 100,
    election_tick: usize = 20,
    heartbeat_tick: usize = 2,
    proposal_timeout_ticks: u64 = 100,
    read_index_timeout_ticks: u64 = 100,
    snapshot_entries_threshold: u64 = 10_000,
    management_graceful_timeout_ns: u64 = 5 * std.time.ns_per_s,
    transport_reconnect_initial_delay_ns: u64 = 20 * std.time.ns_per_ms,
    transport_reconnect_max_delay_ns: u64 = 2 * std.time.ns_per_s,
    transport_graceful_timeout_ns: u64 = 5 * std.time.ns_per_s,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    options: Options,
    machine: state_machine.PoolStateMachine,
    heartbeat_store: heartbeat.HeartbeatStore,
    transport: *raft.GrpcLiteTransport,
    raftor: *raft.Raftor,
    pool_service: service_mod.PoolService,
    pool_rpc: service_mod.PoolRpc,
    management_server: grpc.Server,
    driver_thread: std.Thread,
    driver_exited: std.atomic.Value(bool) = .init(false),
    driver_failed: std.atomic.Value(bool) = .init(false),
    running: bool = true,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: *const config_mod.Config,
        options: Options,
    ) !*Runtime {
        if (options.management_graceful_timeout_ns == 0) return error.InvalidConfig;

        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.options = options;
        self.driver_exited = .init(false);
        self.driver_failed = .init(false);
        self.running = false;

        self.machine = state_machine.PoolStateMachine.init(allocator);
        errdefer self.machine.deinit();
        self.heartbeat_store = heartbeat.HeartbeatStore.init(allocator);
        errdefer self.heartbeat_store.deinit();
        self.machine.setHeartbeatStore(&self.heartbeat_store);
        self.transport = try raft.GrpcLiteTransport.create(allocator, .{
            .identity = .{
                .cluster_id = config.cluster_id,
                .node_id = config.node_id,
            },
            .listen_addr = config.raft_listen,
            .reconnect_initial_delay_ns = options.transport_reconnect_initial_delay_ns,
            .reconnect_max_delay_ns = options.transport_reconnect_max_delay_ns,
            .graceful_shutdown_timeout_ns = options.transport_graceful_timeout_ns,
        });
        errdefer self.transport.destroy();

        var raft_config: raft.RaftorConfig = .{};
        raft_config.raft.id = config.node_id;
        raft_config.raft.election_tick = options.election_tick;
        raft_config.raft.heartbeat_tick = options.heartbeat_tick;
        raft_config.raft.check_quorum = true;
        raft_config.raft.pre_vote = true;
        raft_config.raft.disable_proposal_forwarding = true;
        raft_config.cluster_id = config.cluster_id;
        raft_config.listen_addr = config.raft_listen;
        raft_config.advertise_addr = config.raft_advertise;
        raft_config.initial_peers = config.peers;
        raft_config.data_dir = config.data_dir;
        raft_config.tick_interval_ms = options.tick_interval_ms;
        raft_config.proposal_timeout_ticks = options.proposal_timeout_ticks;
        raft_config.read_index_timeout_ticks = options.read_index_timeout_ticks;
        raft_config.snapshot_entries_threshold = options.snapshot_entries_threshold;
        self.raftor = try raft.Raftor.createWithTransport(
            allocator,
            raft_config,
            self.machine.stateMachine(),
            self.transport.transport(),
        );
        errdefer self.raftor.destroy();

        self.pool_service = try service_mod.PoolService.init(
            allocator,
            io,
            self.raftor,
            &self.machine,
            &self.heartbeat_store,
            config.cluster_id,
        );
        self.pool_rpc = service_mod.PoolRpc.init(allocator, &self.pool_service);
        errdefer {
            self.pool_rpc.stopAccepting();
            self.pool_rpc.deinit();
        }
        self.management_server = try grpc.Server.init(allocator, .{
            .host = config.management_host,
            .port = config.management_port,
            .max_request_size = service_mod.max_heartbeat_request_wire_bytes,
            .stream_limits = .{
                .max_message_size = service_mod.max_heartbeat_request_wire_bytes,
                .max_inbound_buffer_size = 64 * 1024,
                .max_outbound_buffer_size = 64 * 1024,
            },
        });
        errdefer self.management_server.deinit();
        try self.pool_rpc.register(&self.management_server);

        self.driver_thread = try std.Thread.spawn(.{}, runDriver, .{self});
        errdefer {
            self.raftor.stop();
            self.driver_thread.join();
        }
        try self.management_server.start();
        self.running = true;
        log.info(@src(), "control plane listening on {s}:{}", .{ config.management_host, config.management_port });
        return self;
    }

    pub fn shutdown(self: *Runtime) !void {
        if (!self.running) return;
        self.pool_rpc.stopAccepting();
        self.management_server.shutdownGracefully(self.options.management_graceful_timeout_ns);
        self.management_server.wait();
        self.raftor.stop();
        self.driver_thread.join();
        self.running = false;
        try self.pool_rpc.shutdown();
        if (self.driver_failed.load(.acquire)) return error.RaftDriverFailed;
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(!self.running);
        self.pool_rpc.deinit();
        self.management_server.deinit();
        self.raftor.destroy();
        self.transport.destroy();
        self.machine.setHeartbeatStore(null);
        self.heartbeat_store.deinit();
        self.machine.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn driverExited(self: *const Runtime) bool {
        return self.driver_exited.load(.acquire);
    }

    pub fn status(self: *const Runtime) raft.NodeStatus {
        return self.raftor.getStatus();
    }

    pub fn managementAddress(self: *const Runtime) !grpc.ServerLocalAddress {
        return self.management_server.localAddress();
    }

    fn runDriver(self: *Runtime) void {
        self.raftor.run() catch |err| {
            self.driver_failed.store(true, .release);
            log.err(@src(), "Raft driver stopped: {s}", .{@errorName(err)});
        };
        self.driver_exited.store(true, .release);
    }
};
