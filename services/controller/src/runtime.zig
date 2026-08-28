const std = @import("std");

const grpc = @import("grpc_lite");
const raft = @import("raftz");
const config_mod = @import("config.zig");
const heartbeat = @import("heartbeat.zig");
const reconciler_mod = @import("reconciler.zig");
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
    data_service_client: ?reconciler_mod.DataServiceClient = null,
    reconcile_interval_ms: i64 = 1_000,
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
    io: std.Io,
    reconciler: ?reconciler_mod.Reconciler = null,
    reconcile_thread: ?std.Thread = null,
    reconcile_stopping: std.atomic.Value(bool) = .init(false),
    reconcile_event: std.Io.Event = .unset,
    planned_action: ?*reconciler_mod.Action = null,
    reconcile_error: ?anyerror = null,
    proposal_response: ?[]u8 = null,
    proposal_allocator: ?std.mem.Allocator = null,
    running: bool = true,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: *const config_mod.Config,
        options: Options,
    ) !*Runtime {
        if (options.management_graceful_timeout_ns == 0 or
            (options.data_service_client != null and options.reconcile_interval_ms <= 0)) return error.InvalidConfig;

        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.options = options;
        self.io = io;
        self.driver_exited = .init(false);
        self.driver_failed = .init(false);
        self.reconciler = null;
        self.reconcile_thread = null;
        self.reconcile_stopping = .init(false);
        self.reconcile_event = .unset;
        self.planned_action = null;
        self.reconcile_error = null;
        self.proposal_response = null;
        self.proposal_allocator = null;
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
        if (options.data_service_client) |data_client| {
            self.reconciler = reconciler_mod.Reconciler.init(
                allocator,
                io,
                &self.machine,
                data_client,
                self.commandSubmitter(),
            );
            errdefer self.reconciler.?.deinit();
            self.reconcile_thread = try std.Thread.spawn(.{}, runReconciler, .{self});
        }
        self.running = true;
        log.info(@src(), "control plane listening on {s}:{}", .{ config.management_host, config.management_port });
        return self;
    }

    pub fn shutdown(self: *Runtime) !void {
        if (!self.running) return;
        self.stopReconciler();
        self.pool_rpc.stopAccepting();
        self.management_server.shutdownGracefully(self.options.management_graceful_timeout_ns);
        self.management_server.wait();
        self.raftor.stop();
        self.driver_thread.join();
        if (self.planned_action) |action| {
            action.deinit();
            self.planned_action = null;
        }
        if (self.proposal_response) |response| {
            self.allocator.free(response);
            self.proposal_response = null;
        }
        self.proposal_allocator = null;
        self.running = false;
        try self.pool_rpc.shutdown();
        if (self.driver_failed.load(.acquire)) return error.RaftDriverFailed;
    }

    pub fn deinit(self: *Runtime) void {
        std.debug.assert(!self.running);
        if (self.reconciler) |*reconciler| reconciler.deinit();
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

    fn stopReconciler(self: *Runtime) void {
        if (self.options.data_service_client) |data_client| data_client.cancel();
        self.reconcile_stopping.store(true, .release);
        self.reconcile_event.set(self.io);
        if (self.reconcile_thread) |thread| {
            thread.join();
            self.reconcile_thread = null;
        }
    }

    fn runReconciler(self: *Runtime) void {
        while (!self.reconcile_stopping.load(.acquire)) {
            if (self.status().role == .leader) self.reconcileOnce() catch |err| {
                if (!self.reconcile_stopping.load(.acquire))
                    log.warn(@src(), "reconciliation round failed: {s}", .{@errorName(err)});
            };
            if (self.reconcile_stopping.load(.acquire)) break;
            self.reconcile_event.reset();
            if (self.reconcile_stopping.load(.acquire)) break;
            self.reconcile_event.waitTimeout(
                self.io,
                .{ .duration = .{
                    .raw = .fromMilliseconds(self.options.reconcile_interval_ms),
                    .clock = .awake,
                } },
            ) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
        }
    }

    fn reconcileOnce(self: *Runtime) !void {
        self.planned_action = null;
        self.reconcile_error = null;
        self.reconcile_event.reset();
        if (self.reconcile_stopping.load(.acquire)) return error.ShuttingDown;
        self.raftor.readIndex("reconcile", .{ .ctx = self, .function = planCallback }) catch |err| return err;
        self.reconcile_event.waitUncancelable(self.io);
        if (self.reconcile_stopping.load(.acquire)) return error.ShuttingDown;
        if (self.reconcile_error) |err| return err;
        const action = self.planned_action orelse return;
        self.planned_action = null;
        defer action.deinit();
        try action.execute(self.options.data_service_client.?, self.commandSubmitter());
    }

    fn planCallback(context: *anyopaque, result: raft.ReadIndexResult) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.reconcile_stopping.load(.acquire)) {
            self.reconcile_error = error.ShuttingDown;
        } else switch (result) {
            .ok => self.planned_action = self.reconciler.?.planOnce() catch |err| {
                self.reconcile_error = err;
                return self.reconcile_event.set(self.io);
            },
            .err => |err| self.reconcile_error = err,
        }
        self.reconcile_event.set(self.io);
    }

    fn commandSubmitter(self: *Runtime) reconciler_mod.CommandSubmitter {
        return .{ .context = self, .vtable = &command_submitter_vtable };
    }

    fn submitCommand(context: *anyopaque, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.proposal_response = null;
        self.proposal_allocator = allocator;
        self.reconcile_error = null;
        self.reconcile_event.reset();
        if (self.reconcile_stopping.load(.acquire)) return error.ShuttingDown;
        self.raftor.propose(command, .{ .ctx = self, .function = proposalCallback }) catch |err| return err;
        self.reconcile_event.waitUncancelable(self.io);
        if (self.reconcile_stopping.load(.acquire)) return error.ShuttingDown;
        if (self.reconcile_error) |err| return err;
        const response = self.proposal_response orelse return error.MissingApplyResponse;
        self.proposal_response = null;
        self.proposal_allocator = null;
        return response;
    }

    fn proposalCallback(context: *anyopaque, result: raft.ProposalResult) void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.reconcile_stopping.load(.acquire)) {
            self.reconcile_error = error.ShuttingDown;
        } else switch (result) {
            .ok => |response| self.proposal_response = self.proposal_allocator.?.dupe(u8, response) catch |err| {
                self.reconcile_error = err;
                return self.reconcile_event.set(self.io);
            },
            .err => |err| self.reconcile_error = err,
        }
        self.reconcile_event.set(self.io);
    }

    const command_submitter_vtable: reconciler_mod.CommandSubmitter.VTable = .{ .submit = submitCommand };
};
