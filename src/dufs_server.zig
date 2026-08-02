const std = @import("std");
const target = @import("target.zig");
const volume_api = @import("volume.zig");
const linux_fuse = @import("linux_fuse.zig");
const linux = std.os.linux;

var spawn_signal_received = std.atomic.Value(bool).init(false);

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("sys/signalfd.h");
    @cInclude("unistd.h");
});

const Notification = struct {
    read_fd: c_int,
    write_fd: c_int,

    fn init() !Notification {
        var descriptors: [2]c_int = undefined;
        const result = std.os.linux.pipe2(&descriptors, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (std.os.linux.errno(result) != .SUCCESS) return error.NotificationPipeFailed;
        return .{ .read_fd = descriptors[0], .write_fd = descriptors[1] };
    }

    fn notify(context: ?*anyopaque) void {
        const self: *Notification = @ptrCast(@alignCast(context.?));
        const byte: u8 = 1;
        _ = c.write(self.write_fd, &byte, 1);
    }

    fn drain(self: *Notification) void {
        var buffer: [64]u8 = undefined;
        while (c.read(self.read_fd, &buffer, buffer.len) > 0) {}
    }

    fn deinit(self: *Notification) void {
        _ = c.close(self.read_fd);
        _ = c.close(self.write_fd);
    }
};

const SignalEvents = struct {
    set: std.c.sigset_t,
    previous: std.c.sigset_t,
    fd: c_int,

    fn init() !SignalEvents {
        var self: SignalEvents = undefined;
        if (std.c.sigemptyset(&self.set) != 0 or
            std.c.sigaddset(&self.set, .INT) != 0 or
            std.c.sigaddset(&self.set, .TERM) != 0)
            return error.SignalSetupFailed;
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &self.set, &self.previous);
        errdefer std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.previous, null);
        self.fd = c.signalfd(-1, @ptrCast(&self.set), c.SFD_CLOEXEC | c.SFD_NONBLOCK);
        if (self.fd < 0) return error.SignalSetupFailed;
        return self;
    }

    fn consume(self: *SignalEvents) bool {
        var info: c.struct_signalfd_siginfo = undefined;
        return c.read(self.fd, &info, @sizeOf(@TypeOf(info))) == @sizeOf(@TypeOf(info));
    }

    fn block(self: *SignalEvents) void {
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &self.set, null);
    }

    fn restore(self: *SignalEvents) void {
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.previous, null);
    }

    fn deinit(self: *SignalEvents) void {
        _ = c.close(self.fd);
        self.restore();
    }
};

const PidFd = struct {
    fd: c_int,

    fn open(pid: std.posix.pid_t) !PidFd {
        const result = std.os.linux.pidfd_open(pid, 0);
        return switch (std.os.linux.errno(result)) {
            .SUCCESS => .{ .fd = @intCast(result) },
            else => error.PidFdOpenFailed,
        };
    }

    fn send(self: PidFd, signal: std.os.linux.SIG) void {
        _ = std.os.linux.pidfd_send_signal(self.fd, signal, null, 0);
    }

    fn wait(self: PidFd, timeout_ms: c_int) !bool {
        var descriptor = linux.pollfd{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 };
        while (true) {
            const result = linux.poll(@ptrCast(&descriptor), 1, timeout_ms);
            switch (linux.errno(result)) {
                .SUCCESS => return result != 0,
                .INTR => continue,
                else => return error.SupervisorPollFailed,
            }
        }
    }

    fn close(self: PidFd) void {
        _ = c.close(self.fd);
    }
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    read_only: bool,
    access_time: volume_api.AccessTimePolicy,
    dufs_args: []const []const u8,
    stdout: *std.Io.Writer,
) !void {
    try preflightDufs(allocator, io);
    const mountpoint = try createMountpoint(allocator, io);
    defer allocator.free(mountpoint);
    defer std.Io.Dir.deleteDirAbsolute(io, mountpoint) catch {};

    const argv = try allocator.alloc([]const u8, dufs_args.len + 2);
    defer allocator.free(argv);
    argv[0] = "dufs";
    argv[1] = mountpoint;
    @memcpy(argv[2..], dufs_args);
    var signals = try SignalEvents.init();
    defer signals.deinit();
    var notification = try Notification.init();
    defer notification.deinit();

    const volume = try allocator.create(volume_api.Volume);
    defer allocator.destroy(volume);
    try target.openVolumeInto(volume, io, allocator, target_path, !read_only);
    defer volume.deinit();
    volume.setFallbackOwner(@intCast(std.os.linux.getuid()), @intCast(std.os.linux.getgid()));
    try volume.mountOptions(.{ .access_time = access_time });

    var session = try linux_fuse.Session.start(allocator, volume, mountpoint, .{
        .read_only = read_only,
        .on_exit = Notification.notify,
        .on_exit_context = &notification,
    });
    var session_open = true;
    defer if (session_open) session.stop() catch {};

    var child = try spawnDufs(io, argv, &signals);
    var child_reaped = false;
    errdefer if (!child_reaped) child.kill(io);
    const child_pid = child.id.?;
    const pidfd = try PidFd.open(child_pid);
    defer pidfd.close();

    try stdout.print("Serving {s} with dufs\n", .{target_path});
    try stdout.flush();

    const event = try waitForEvent(&signals, &notification, pidfd);
    const termination_requested = event.signal and signals.consume();
    notification.drain();
    const fuse_done = session.hasExited();
    var child_done = event.child;
    if (!child_done and (termination_requested or fuse_done)) {
        pidfd.send(.INT);
        child_done = try pidfd.wait(5000);
        if (!child_done) {
            pidfd.send(.KILL);
            _ = try pidfd.wait(-1);
        }
    }

    var fuse_error: ?anyerror = null;
    session.stop() catch |err| {
        fuse_error = err;
    };
    session_open = false;
    const term = try child.wait(io);
    child_reaped = true;
    if (fuse_error) |err| return err;
    if (termination_requested) return;
    return checkTerm(term);
}

fn preflightDufs(allocator: std.mem.Allocator, io: std.Io) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "dufs", "--version" } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.DufsUnavailable,
        else => return error.DufsUnavailable,
    }
}

fn spawnDufs(io: std.Io, argv: []const []const u8, signals: *SignalEvents) !std.process.Child {
    spawn_signal_received.store(false, .release);
    var old_interrupt: std.posix.Sigaction = undefined;
    var old_terminate: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = spawnSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, &old_interrupt);
    std.posix.sigaction(.TERM, &action, &old_terminate);
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &signals.set, null);
    const result = std.process.spawn(io, .{ .argv = argv, .pgid = 0 });
    signals.block();
    std.posix.sigaction(.INT, &old_interrupt, null);
    std.posix.sigaction(.TERM, &old_terminate, null);
    if (spawn_signal_received.load(.acquire)) std.posix.kill(std.os.linux.getpid(), .TERM) catch {};
    return result;
}

fn spawnSignalHandler(_: std.posix.SIG) callconv(.c) void {
    spawn_signal_received.store(true, .release);
}

const SupervisorEvent = struct {
    signal: bool,
    notification: bool,
    child: bool,
};

fn waitForEvent(signals: *SignalEvents, notification: *Notification, pidfd: PidFd) !SupervisorEvent {
    var descriptors = [_]linux.pollfd{
        .{ .fd = signals.fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = notification.read_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = pidfd.fd, .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        const result = linux.poll(&descriptors, descriptors.len, -1);
        switch (linux.errno(result)) {
            .SUCCESS => return .{
                .signal = descriptors[0].revents & linux.POLL.IN != 0,
                .notification = descriptors[1].revents & linux.POLL.IN != 0,
                .child = descriptors[2].revents & linux.POLL.IN != 0,
            },
            .INTR => continue,
            else => return error.SupervisorPollFailed,
        }
    }
}

fn checkTerm(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.DufsExited,
        .signal => return error.DufsTerminated,
        .stopped, .unknown => return error.DufsTerminated,
    }
}

fn createMountpoint(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const path = try std.fmt.allocPrint(allocator, "/tmp/zettide-dufs-{x}", .{random});
        std.Io.Dir.createDirAbsolute(io, path, std.Io.File.Permissions.fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => {
                allocator.free(path);
                return err;
            },
        };
        return path;
    }
    return error.TemporaryDirectoryCollision;
}
