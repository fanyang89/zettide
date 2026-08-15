const std = @import("std");
const endpoint_registry = @import("endpoint_registry.zig");
const linux = std.os.linux;

pub const protocol_version: u8 = 1;
pub const max_request_size = 4096;
pub const max_response_size = 4 * 1024 * 1024;
const io_deadline_ns = 2 * std.time.ns_per_s;

pub const Request = union(enum) {
    ensure: endpoint_registry.Spec,
    inspect: endpoint_registry.EndpointId,
    list,
    release: endpoint_registry.EndpointId,
};

pub fn parseRequest(input: []const u8) !Request {
    if (input.len == 0 or input.len > max_request_size or input[input.len - 1] != '\n' or
        std.mem.indexOfAny(u8, input[0 .. input.len - 1], "\r\n") != null)
        return error.InvalidRequestLine;
    const Wire = struct {
        v: u8,
        action: []const u8,
        endpoint_id: ?[]const u8 = null,
        pool_id: ?[]const u8 = null,
        volume_id: ?[]const u8 = null,
        frontend: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(
        Wire,
        std.heap.page_allocator,
        input[0 .. input.len - 1],
        .{ .ignore_unknown_fields = false, .max_value_len = max_request_size },
    ) catch return error.InvalidRequest;
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.v != protocol_version) return error.UnsupportedProtocolVersion;

    if (std.mem.eql(u8, wire.action, "ensure")) {
        return .{ .ensure = .{
            .endpoint_id = try parseId(wire.endpoint_id orelse return error.MissingRequestField),
            .pool_id = try parseId(wire.pool_id orelse return error.MissingRequestField),
            .volume_id = try parseId(wire.volume_id orelse return error.MissingRequestField),
            .frontend = try parseFrontend(wire.frontend orelse return error.MissingRequestField),
        } };
    }
    if (std.mem.eql(u8, wire.action, "inspect")) {
        if (wire.pool_id != null or wire.volume_id != null or wire.frontend != null)
            return error.InvalidRequestFields;
        return .{ .inspect = try parseId(wire.endpoint_id orelse return error.MissingRequestField) };
    }
    if (std.mem.eql(u8, wire.action, "list")) {
        if (wire.endpoint_id != null or wire.pool_id != null or wire.volume_id != null or wire.frontend != null)
            return error.InvalidRequestFields;
        return .list;
    }
    if (std.mem.eql(u8, wire.action, "release")) {
        if (wire.pool_id != null or wire.volume_id != null or wire.frontend != null)
            return error.InvalidRequestFields;
        return .{ .release = try parseId(wire.endpoint_id orelse return error.MissingRequestField) };
    }
    return error.UnknownAction;
}

pub fn dispatch(
    registry: *endpoint_registry.Registry,
    allocator: std.mem.Allocator,
    request: Request,
    writer: *std.Io.Writer,
) !void {
    switch (request) {
        .ensure => |spec| {
            const view = registry.ensure(spec) catch |err| switch (err) {
                error.EndpointConflict,
                error.PoolBusy,
                error.EndpointStopping,
                error.InvalidEndpointSpec,
                error.TooManyEndpoints,
                => return writeApiError(writer, err),
                else => registry.inspect(spec.endpoint_id) catch return writeApiError(writer, err),
            };
            try writeEndpointResponse(writer, view);
        },
        .inspect => |endpoint_id| {
            const view = registry.inspect(endpoint_id) catch |err| return writeApiError(writer, err);
            try writeEndpointResponse(writer, view);
        },
        .list => {
            const views = registry.list(allocator) catch |err| return writeApiError(writer, err);
            defer allocator.free(views);
            try writeListResponse(writer, views);
        },
        .release => |endpoint_id| {
            registry.release(endpoint_id) catch |err| {
                _ = registry.inspect(endpoint_id) catch return writeReleaseResponse(writer, true);
                return writeApiError(writer, err);
            };
            try writeReleaseResponse(writer, false);
        },
    }
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *endpoint_registry.Registry,
    parent: std.Io.Dir,
    basename: []u8,
    inode: std.Io.File.INode,
    lock_file: std.Io.File,
    fd: i32,
    stopping: std.atomic.Value(bool) = .init(false),
    client_mutex: std.atomic.Mutex = .unlocked,
    client_fd: i32 = -1,
    thread: std.Thread,

    /// parent and registry remain owned by the caller and must outlive Server.
    /// The server thread is the sole registry caller until deinit returns.
    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        basename: []const u8,
        registry: *endpoint_registry.Registry,
    ) !*Server {
        if (basename.len == 0 or std.mem.indexOfScalar(u8, basename, '/') != null)
            return error.InvalidControlSocketName;
        try validateControlDirectory(parent);
        const lock_name = try std.fmt.allocPrint(allocator, "{s}.lock", .{basename});
        defer allocator.free(lock_name);
        const lock_file = parent.createFile(io, lock_name, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock => return error.ControlServerAlreadyRunning,
            else => return err,
        };
        errdefer lock_file.close(io);
        const parent_path = try parent.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(parent_path);
        const full_path = try std.fs.path.join(allocator, &.{ parent_path, basename });
        defer allocator.free(full_path);
        if (full_path.len >= 108) return error.ControlSocketPathTooLong;

        if (parent.statFile(io, basename, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind != .unix_domain_socket) return error.UnsafeControlSocketEntry;
            const confirmed = try parent.statFile(io, basename, .{ .follow_symlinks = false });
            if (confirmed.kind != .unix_domain_socket or confirmed.inode != stat.inode)
                return error.ControlSocketChanged;
            try parent.deleteFile(io, basename);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const fd = try unixSocket(false);
        errdefer _ = linux.close(fd);
        var address = try unixAddress(full_path);
        if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS)
            return error.ControlSocketBindFailed;
        errdefer parent.deleteFile(io, basename) catch {};
        try parent.setFilePermissions(
            io,
            basename,
            std.Io.File.Permissions.fromMode(0o600),
            .{ .follow_symlinks = false },
        );
        if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) return error.ControlSocketListenFailed;
        const stat = try parent.statFile(io, basename, .{ .follow_symlinks = false });

        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .registry = registry,
            .parent = parent,
            .basename = try allocator.dupe(u8, basename),
            .inode = stat.inode,
            .lock_file = lock_file,
            .fd = fd,
            .thread = undefined,
        };
        errdefer allocator.free(self.basename);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        if (!self.stopping.swap(true, .acq_rel)) {
            _ = linux.shutdown(self.fd, linux.SHUT.RDWR);
            self.lockClient();
            defer self.client_mutex.unlock();
            if (self.client_fd >= 0) _ = linux.shutdown(self.client_fd, linux.SHUT.RDWR);
        }
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        self.thread.join();
        _ = linux.close(self.fd);
        if (self.parent.statFile(self.io, self.basename, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind == .unix_domain_socket and stat.inode == self.inode)
                self.parent.deleteFile(self.io, self.basename) catch {};
        } else |_| {}
        self.lock_file.close(self.io);
        self.allocator.free(self.basename);
        self.allocator.destroy(self);
    }

    fn run(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            const result = linux.accept4(self.fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
            const accept_error = linux.errno(result);
            if (accept_error != .SUCCESS) {
                if (self.stopping.load(.acquire)) return;
                if (accept_error == .INTR) continue;
                return;
            }
            const client: i32 = @intCast(result);
            self.lockClient();
            if (self.stopping.load(.acquire)) {
                self.client_mutex.unlock();
                _ = linux.close(client);
                return;
            }
            self.client_fd = client;
            self.client_mutex.unlock();
            handleConnection(self, client);
            self.lockClient();
            self.client_fd = -1;
            _ = linux.close(client);
            self.client_mutex.unlock();
        }
    }

    fn lockClient(self: *Server) void {
        while (!self.client_mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

fn handleConnection(server: *Server, fd: i32) void {
    if (!peerIsOwner(fd)) return;
    var input: [max_request_size + 1]u8 = undefined;
    const length = readRequestLine(server.io, fd, &input) catch {
        writeAllDeadline(server.io, fd, invalidRequestResponse()) catch {};
        return;
    };
    if (hasTrailingRequestData(fd)) {
        writeAllDeadline(server.io, fd, invalidRequestResponse()) catch {};
        return;
    }
    const request = parseRequest(input[0..length]) catch {
        writeAllDeadline(server.io, fd, invalidRequestResponse()) catch {};
        return;
    };

    const output = server.allocator.alloc(u8, max_response_size) catch return;
    defer server.allocator.free(output);
    var writer = std.Io.Writer.fixed(output);
    dispatch(server.registry, server.allocator, request, &writer) catch return;
    writeAllDeadline(server.io, fd, writer.buffered()) catch {};
}

pub fn validateControlDirectory(dir: std.Io.Dir) !void {
    var stat: linux.Statx = undefined;
    const result = linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat);
    if (linux.errno(result) != .SUCCESS) return error.ControlDirectoryMetadataUnavailable;
    if (!linux.S.ISDIR(stat.mode) or stat.uid != std.c.geteuid())
        return error.ControlDirectoryOwnerMismatch;
    if (stat.mode & 0o077 != 0) return error.InsecureControlDirectory;
}

fn writeEndpointResponse(writer: *std.Io.Writer, view: endpoint_registry.View) !void {
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("v");
    try stringify.write(protocol_version);
    try stringify.objectField("ok");
    try stringify.write(true);
    try stringify.objectField("endpoint");
    try writeView(&stringify, view);
    try stringify.endObject();
    try writer.writeByte('\n');
}

fn writeListResponse(writer: *std.Io.Writer, views: []const endpoint_registry.View) !void {
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.beginObject();
    try stringify.objectField("v");
    try stringify.write(protocol_version);
    try stringify.objectField("ok");
    try stringify.write(true);
    try stringify.objectField("endpoints");
    try stringify.beginArray();
    for (views) |view| try writeView(&stringify, view);
    try stringify.endArray();
    try stringify.endObject();
    try writer.writeByte('\n');
}

fn writeReleaseResponse(writer: *std.Io.Writer, stopping: bool) !void {
    try std.json.Stringify.value(.{
        .v = protocol_version,
        .ok = true,
        .released = true,
        .stopping = stopping,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn writeView(stringify: *std.json.Stringify, view: endpoint_registry.View) !void {
    var endpoint_id: [32]u8 = undefined;
    var pool_id: [32]u8 = undefined;
    var volume_id: [32]u8 = undefined;
    try stringify.beginObject();
    try stringify.objectField("endpoint_id");
    try stringify.write(formatId(&endpoint_id, view.spec.endpoint_id));
    try stringify.objectField("pool_id");
    try stringify.write(formatId(&pool_id, view.spec.pool_id));
    try stringify.objectField("volume_id");
    try stringify.write(formatId(&volume_id, view.spec.volume_id));
    try stringify.objectField("frontend");
    try stringify.write(@tagName(view.spec.frontend));
    try stringify.objectField("state");
    try stringify.write(@tagName(view.state));
    try stringify.objectField("locator");
    if (view.locator) |locator| {
        try stringify.beginObject();
        switch (locator) {
            .vhost_user_blk => |vhost| {
                try stringify.objectField("type");
                try stringify.write("vhost_user_blk");
                try stringify.objectField("socket_path");
                try stringify.write(vhost.socket_path);
            },
            .iscsi => |iscsi| {
                try stringify.objectField("type");
                try stringify.write("iscsi");
                try stringify.objectField("portal");
                try stringify.write(iscsi.portal);
                try stringify.objectField("target_name");
                try stringify.write(iscsi.target_name);
                try stringify.objectField("lun");
                try stringify.write(iscsi.lun);
            },
            .nvme_of_tcp => |nvme| {
                try stringify.objectField("type");
                try stringify.write("nvme_of_tcp");
                try stringify.objectField("traddr");
                try stringify.write(nvme.traddr);
                try stringify.objectField("trsvcid");
                try stringify.write(nvme.trsvcid);
                try stringify.objectField("nqn");
                try stringify.write(nvme.nqn);
                try stringify.objectField("nsid");
                try stringify.write(nvme.nsid);
            },
            .nvme_of_rdma => |nvme| {
                try stringify.objectField("type");
                try stringify.write("nvme_of_rdma");
                try stringify.objectField("traddr");
                try stringify.write(nvme.traddr);
                try stringify.objectField("trsvcid");
                try stringify.write(nvme.trsvcid);
                try stringify.objectField("nqn");
                try stringify.write(nvme.nqn);
                try stringify.objectField("nsid");
                try stringify.write(nvme.nsid);
            },
        }
        try stringify.endObject();
    } else {
        try stringify.write(null);
    }
    try stringify.endObject();
}

fn writeApiError(writer: *std.Io.Writer, err: anyerror) !void {
    const api_error = switch (err) {
        error.EndpointNotFound => .{ "not_found", "Endpoint was not found" },
        error.EndpointConflict => .{ "conflict", "Endpoint identity conflicts with desired state" },
        error.PoolBusy => .{ "pool_busy", "Pool already has an endpoint" },
        error.EndpointStopping => .{ "stopping", "Endpoint teardown is still in progress" },
        error.UnsupportedFrontend => .{ "unsupported_frontend", "Endpoint frontend is not available" },
        error.InvalidEndpointSpec => .{ "invalid_spec", "Endpoint specification is invalid" },
        error.TooManyEndpoints => .{ "resource_exhausted", "Endpoint limit was reached" },
        error.OutOfMemory => .{ "resource_exhausted", "Endpoint resources are exhausted" },
        else => .{ "unavailable", "Endpoint operation did not complete" },
    };
    try std.json.Stringify.value(.{
        .v = protocol_version,
        .ok = false,
        .@"error" = .{ .code = api_error[0], .message = api_error[1] },
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn invalidRequestResponse() []const u8 {
    return "{\"v\":1,\"ok\":false,\"error\":{\"code\":\"invalid_request\",\"message\":\"Invalid endpoint control request\"}}\n";
}

fn parseId(text: []const u8) ![16]u8 {
    if (text.len != 32) return error.InvalidId;
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return error.InvalidId;
    for (result) |byte| if (byte != 0) return result;
    return error.InvalidId;
}

fn formatId(buffer: *[32]u8, id: [16]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{x}", .{id}) catch unreachable;
}

fn parseFrontend(text: []const u8) !endpoint_registry.Frontend {
    if (std.mem.eql(u8, text, "vhost_user_blk")) return .vhost_user_blk;
    if (std.mem.eql(u8, text, "iscsi")) return .iscsi;
    if (std.mem.eql(u8, text, "nvme_of_tcp")) return .nvme_of_tcp;
    if (std.mem.eql(u8, text, "nvme_of_rdma")) return .nvme_of_rdma;
    return error.InvalidFrontend;
}

fn readRequestLine(io: std.Io, fd: i32, buffer: []u8) !usize {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + io_deadline_ns;
    var length: usize = 0;
    while (length < buffer.len) {
        try waitFor(io, fd, linux.POLL.IN, deadline);
        const result = linux.read(fd, buffer.ptr + length, 1);
        const err = linux.errno(result);
        if (err == .INTR or err == .AGAIN) continue;
        if (err != .SUCCESS or result == 0) return error.ControlSocketReadFailed;
        length += 1;
        if (buffer[length - 1] == '\n') return length;
    }
    return error.ControlRequestTooLarge;
}

fn hasTrailingRequestData(fd: i32) bool {
    var buffer: [256]u8 = undefined;
    var found = false;
    while (true) {
        const result = linux.recvfrom(fd, &buffer, buffer.len, linux.MSG.DONTWAIT, null, null);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return found;
                found = true;
            },
            .INTR => continue,
            .AGAIN => return found,
            else => return true,
        }
    }
}

const PeerCredentials = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

fn peerIsOwner(fd: i32) bool {
    var credentials: PeerCredentials = undefined;
    var length: linux.socklen_t = @sizeOf(PeerCredentials);
    if (linux.errno(linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        @ptrCast(&credentials),
        &length,
    )) != .SUCCESS) return false;
    return length == @sizeOf(PeerCredentials) and credentials.uid == std.c.geteuid();
}

pub fn connectPath(path: []const u8) !i32 {
    const fd = try unixSocket(true);
    errdefer _ = linux.close(fd);
    var address = try unixAddress(path);
    var err = linux.errno(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un)));
    if (err == .INPROGRESS) {
        var poll_fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
        const result = linux.poll(&poll_fds, 1, 2000);
        if (linux.errno(result) != .SUCCESS or result == 0) return error.ControlSocketUnreachable;
        var socket_error: i32 = 0;
        var error_size: linux.socklen_t = @sizeOf(i32);
        if (linux.errno(linux.getsockopt(
            fd,
            linux.SOL.SOCKET,
            linux.SO.ERROR,
            @ptrCast(&socket_error),
            &error_size,
        )) != .SUCCESS) return error.ControlSocketConnectFailed;
        err = @enumFromInt(@as(u16, @intCast(socket_error)));
    }
    switch (err) {
        .SUCCESS => {},
        .NOENT, .CONNREFUSED, .CONNRESET, .TIMEDOUT => return error.ControlSocketUnreachable,
        .ACCES, .PERM => return error.ControlSocketPermissionDenied,
        else => return error.ControlSocketConnectFailed,
    }
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS or
        linux.errno(linux.fcntl(fd, linux.F.SETFL, flags & ~@as(usize, linux.SOCK.NONBLOCK))) != .SUCCESS)
        return error.ControlSocketFlagsFailed;
    return fd;
}

fn unixSocket(nonblocking: bool) !i32 {
    const flags: u32 = @intCast(linux.SOCK.STREAM | linux.SOCK.CLOEXEC);
    const socket_flags = flags | if (nonblocking) @as(u32, @intCast(linux.SOCK.NONBLOCK)) else 0;
    const result = linux.socket(linux.AF.UNIX, socket_flags, 0);
    if (linux.errno(result) != .SUCCESS) return error.ControlSocketCreateFailed;
    return @intCast(result);
}

fn unixAddress(path: []const u8) !linux.sockaddr.un {
    var result = linux.sockaddr.un{ .path = @splat(0) };
    if (path.len >= result.path.len) return error.ControlSocketPathTooLong;
    @memcpy(result.path[0..path.len], path);
    return result;
}

pub fn writeAll(fd: i32, input: []const u8) !void {
    var written: usize = 0;
    while (written < input.len) {
        const result = linux.sendto(fd, input.ptr + written, input.len - written, linux.MSG.NOSIGNAL, null, 0);
        const err = linux.errno(result);
        if (err == .INTR or err == .AGAIN) continue;
        if (err != .SUCCESS or result == 0) return error.ControlSocketWriteFailed;
        written += result;
    }
}

fn writeAllDeadline(io: std.Io, fd: i32, input: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + io_deadline_ns;
    var written: usize = 0;
    while (written < input.len) {
        try waitFor(io, fd, linux.POLL.OUT, deadline);
        const result = linux.sendto(fd, input.ptr + written, input.len - written, linux.MSG.NOSIGNAL, null, 0);
        const err = linux.errno(result);
        if (err == .INTR or err == .AGAIN) continue;
        if (err != .SUCCESS or result == 0) return error.ControlSocketWriteFailed;
        written += result;
    }
}

fn waitFor(io: std.Io, fd: i32, events: i16, deadline_ns: i96) !void {
    while (true) {
        const remaining = deadline_ns - std.Io.Clock.awake.now(io).nanoseconds;
        if (remaining <= 0) return error.ControlSocketTimedOut;
        const timeout_ms: i32 = @intCast(@min(
            @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms),
            std.math.maxInt(i32),
        ));
        var poll_fds = [_]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const result = linux.poll(&poll_fds, 1, timeout_ms);
        const err = linux.errno(result);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return error.ControlSocketPollFailed;
        if (result == 0) return error.ControlSocketTimedOut;
        if (poll_fds[0].revents & events != 0) return;
        if (poll_fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
            return error.ControlSocketClosed;
    }
}

pub fn readToEof(fd: i32, buffer: []u8) !usize {
    var length: usize = 0;
    while (length < buffer.len) {
        const result = linux.read(fd, buffer.ptr + length, buffer.len - length);
        const err = linux.errno(result);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return error.ControlSocketReadFailed;
        if (result == 0) return length;
        length += result;
    }
    return length;
}

const TestBackend = struct {
    active: bool = false,
    fail_start: bool = false,
    fail_stop: bool = false,
    socket_path: []const u8 = "/run/zettide/test.sock",

    fn backend(self: *TestBackend) endpoint_registry.Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn start(context: *anyopaque, spec: endpoint_registry.Spec) !endpoint_registry.Backend.Instance {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        if (self.fail_start) return error.StartFailed;
        if (self.active) return error.AlreadyActive;
        self.active = true;
        const locator: endpoint_registry.Locator = switch (spec.frontend) {
            .vhost_user_blk => .{ .vhost_user_blk = .{ .socket_path = self.socket_path } },
            .iscsi => .{ .iscsi = .{
                .portal = "127.0.0.1:3260",
                .target_name = "iqn.2026-08.io.zettide:test",
                .lun = 7,
            } },
            .nvme_of_tcp => .{ .nvme_of_tcp = .{
                .traddr = "127.0.0.1",
                .trsvcid = "4420",
                .nqn = "nqn.2026-08.io.zettide:test",
                .nsid = 1,
            } },
            .nvme_of_rdma => .{ .nvme_of_rdma = .{
                .traddr = "192.0.2.2",
                .trsvcid = "4420",
                .nqn = "nqn.2026-08.io.zettide:test",
                .nsid = 1,
            } },
        };
        return .{ .handle = self, .locator = locator };
    }

    fn stop(context: *anyopaque, handle: *anyopaque) !void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        std.debug.assert(handle == @as(*anyopaque, @ptrCast(self)) and self.active);
        if (self.fail_stop) return error.StopFailed;
        self.active = false;
    }

    const vtable: endpoint_registry.Backend.VTable = .{ .start = start, .stop = stop };
};

fn testId(value: u8) [16]u8 {
    var result: [16]u8 = @splat(0);
    result[15] = value;
    return result;
}

fn secureTmpDir(tmp: *std.testing.TmpDir) !void {
    try tmp.parent_dir.setFilePermissions(
        std.testing.io,
        &tmp.sub_path,
        std.Io.File.Permissions.fromMode(0o700),
        .{},
    );
}

fn waitForActiveClient(server: *Server) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + std.time.ns_per_s;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline) {
        server.lockClient();
        const active = server.client_fd >= 0;
        server.client_mutex.unlock();
        if (active) return;
        try std.Thread.yield();
    }
    return error.TestExpectedActiveClient;
}

test "endpoint control parses strict versioned requests" {
    const request = try parseRequest(
        "{\"v\":1,\"action\":\"ensure\",\"endpoint_id\":\"00000000000000000000000000000001\",\"pool_id\":\"00000000000000000000000000000002\",\"volume_id\":\"00000000000000000000000000000003\",\"frontend\":\"nvme_of_tcp\"}\n",
    );
    try std.testing.expectEqual(endpoint_registry.Frontend.nvme_of_tcp, request.ensure.frontend);
    try std.testing.expectEqualSlices(u8, &testId(3), &request.ensure.volume_id);
    const rdma_request = try parseRequest(
        "{\"v\":1,\"action\":\"ensure\",\"endpoint_id\":\"00000000000000000000000000000001\",\"pool_id\":\"00000000000000000000000000000002\",\"volume_id\":\"00000000000000000000000000000003\",\"frontend\":\"nvme_of_rdma\"}\n",
    );
    try std.testing.expectEqual(endpoint_registry.Frontend.nvme_of_rdma, rdma_request.ensure.frontend);
    try std.testing.expectError(error.InvalidRequestFields, parseRequest(
        "{\"v\":1,\"action\":\"list\",\"endpoint_id\":\"00000000000000000000000000000001\"}\n",
    ));
    try std.testing.expectError(error.UnsupportedProtocolVersion, parseRequest(
        "{\"v\":2,\"action\":\"list\"}\n",
    ));
    try std.testing.expectError(error.InvalidRequest, parseRequest(
        "{\"v\":1,\"action\":\"list\",\"extra\":true}\n",
    ));
}

test "endpoint control dispatches typed locator responses and stable errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = endpoint_registry.FileStore.init(std.testing.io, tmp.dir, "state");
    var backend: TestBackend = .{};
    var registry = try endpoint_registry.Registry.init(
        std.testing.allocator,
        store.desiredStore(),
        backend.backend(),
    );
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }
    const spec: endpoint_registry.Spec = .{
        .endpoint_id = testId(1),
        .pool_id = testId(2),
        .volume_id = testId(3),
        .frontend = .nvme_of_tcp,
    };

    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try dispatch(&registry, std.testing.allocator, .{ .ensure = spec }, &writer);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"ok\":true,\"endpoint\":{\"endpoint_id\":\"00000000000000000000000000000001\",\"pool_id\":\"00000000000000000000000000000002\",\"volume_id\":\"00000000000000000000000000000003\",\"frontend\":\"nvme_of_tcp\",\"state\":\"active\",\"locator\":{\"type\":\"nvme_of_tcp\",\"traddr\":\"127.0.0.1\",\"trsvcid\":\"4420\",\"nqn\":\"nqn.2026-08.io.zettide:test\",\"nsid\":1}}}\n",
        writer.buffered(),
    );

    writer = std.Io.Writer.fixed(&output);
    try dispatch(&registry, std.testing.allocator, .{ .release = spec.endpoint_id }, &writer);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"ok\":true,\"released\":true,\"stopping\":false}\n",
        writer.buffered(),
    );

    var rdma_spec = spec;
    rdma_spec.frontend = .nvme_of_rdma;
    writer = std.Io.Writer.fixed(&output);
    try dispatch(&registry, std.testing.allocator, .{ .ensure = rdma_spec }, &writer);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"ok\":true,\"endpoint\":{\"endpoint_id\":\"00000000000000000000000000000001\",\"pool_id\":\"00000000000000000000000000000002\",\"volume_id\":\"00000000000000000000000000000003\",\"frontend\":\"nvme_of_rdma\",\"state\":\"active\",\"locator\":{\"type\":\"nvme_of_rdma\",\"traddr\":\"192.0.2.2\",\"trsvcid\":\"4420\",\"nqn\":\"nqn.2026-08.io.zettide:test\",\"nsid\":1}}}\n",
        writer.buffered(),
    );
    try registry.release(rdma_spec.endpoint_id);

    backend.fail_start = true;
    writer = std.Io.Writer.fixed(&output);
    try dispatch(&registry, std.testing.allocator, .{ .ensure = spec }, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"state\":\"failed\"") != null);
    backend.fail_start = false;
    _ = try registry.ensure(spec);

    backend.fail_stop = true;
    writer = std.Io.Writer.fixed(&output);
    try dispatch(&registry, std.testing.allocator, .{ .release = spec.endpoint_id }, &writer);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"ok\":true,\"released\":true,\"stopping\":true}\n",
        writer.buffered(),
    );
    backend.fail_stop = false;
    try registry.release(spec.endpoint_id);

    writer = std.Io.Writer.fixed(&output);
    try dispatch(&registry, std.testing.allocator, .{ .inspect = testId(9) }, &writer);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"Endpoint was not found\"}}\n",
        writer.buffered(),
    );
}

test "endpoint control serves one request over a protected unix socket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try secureTmpDir(&tmp);
    var store = endpoint_registry.FileStore.init(std.testing.io, tmp.dir, "state");
    var backend: TestBackend = .{};
    var registry = try endpoint_registry.Registry.init(
        std.heap.c_allocator,
        store.desiredStore(),
        backend.backend(),
    );
    defer {
        registry.shutdown() catch unreachable;
        registry.deinit();
    }
    const server = try Server.start(std.heap.c_allocator, std.testing.io, tmp.dir, "control.sock", &registry);
    defer server.deinit();
    try std.testing.expectError(
        error.ControlServerAlreadyRunning,
        Server.start(std.heap.c_allocator, std.testing.io, tmp.dir, "control.sock", &registry),
    );
    const full_path = try tmp.dir.realPathFileAlloc(std.testing.io, "control.sock", std.testing.allocator);
    defer std.testing.allocator.free(full_path);

    const fd = try connectPath(full_path);
    defer _ = linux.close(fd);
    try writeAll(fd, "{\"v\":1,\"action\":\"list\"}\n");
    _ = linux.shutdown(fd, linux.SHUT.WR);
    var response: [1024]u8 = undefined;
    const length = try readToEof(fd, &response);
    try std.testing.expectEqualStrings("{\"v\":1,\"ok\":true,\"endpoints\":[]}\n", response[0..length]);
    const stat = try tmp.dir.statFile(std.testing.io, "control.sock", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.unix_domain_socket, stat.kind);
    try std.testing.expectEqual(@as(u32, 0), stat.permissions.toMode() & 0o077);

    const trailing_fd = try connectPath(full_path);
    defer _ = linux.close(trailing_fd);
    try writeAll(trailing_fd, "{\"v\":1,\"action\":\"list\"}\n{\"v\":1,\"action\":\"list\"}\n");
    _ = linux.shutdown(trailing_fd, linux.SHUT.WR);
    const trailing_length = try readToEof(trailing_fd, &response);
    try std.testing.expectEqualStrings(invalidRequestResponse(), response[0..trailing_length]);

    const stalled_fd = try connectPath(full_path);
    defer _ = linux.close(stalled_fd);
    try writeAll(stalled_fd, "{");
    try waitForActiveClient(server);
    server.stop();
    try std.testing.expectEqual(@as(usize, 0), try readToEof(stalled_fd, &response));
}

test "endpoint control rejects an insecure parent directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.parent_dir.setFilePermissions(
        std.testing.io,
        &tmp.sub_path,
        std.Io.File.Permissions.fromMode(0o711),
        .{},
    );
    var store = endpoint_registry.FileStore.init(std.testing.io, tmp.dir, "state");
    var backend: TestBackend = .{};
    var registry = try endpoint_registry.Registry.init(
        std.testing.allocator,
        store.desiredStore(),
        backend.backend(),
    );
    defer registry.deinit();

    try std.testing.expectError(
        error.InsecureControlDirectory,
        Server.start(std.testing.allocator, std.testing.io, tmp.dir, "control.sock", &registry),
    );
}
