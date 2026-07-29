const std = @import("std");

const control = @import("zettide_control");

var stop_requested = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    try control.raft.log.initGlobal(init.gpa, init.io, false);
    defer control.raft.log.deinitGlobal(init.gpa);

    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    var diagnostic = control.config.Diagnostic{};
    var parsed = control.config.parse(init.gpa, &arguments, &diagnostic) catch |err| {
        try diagnostic.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer parsed.deinit();
    if (parsed == .help) {
        try control.config.writeHelp(init.io);
        return;
    }

    var old_interrupt: std.posix.Sigaction = undefined;
    var old_terminate: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, &old_interrupt);
    defer std.posix.sigaction(.INT, &old_interrupt, null);
    std.posix.sigaction(.TERM, &action, &old_terminate);
    defer std.posix.sigaction(.TERM, &old_terminate, null);

    const runtime = try control.Runtime.create(std.heap.smp_allocator, init.io, &parsed.config, .{});
    defer {
        if (runtime.running) runtime.shutdown() catch {};
        runtime.deinit();
    }
    while (!stop_requested.load(.acquire) and !runtime.driverExited()) {
        try init.io.sleep(.fromMilliseconds(100), .awake);
    }
    try runtime.shutdown();
}

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}
