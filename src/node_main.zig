const std = @import("std");
const node = @import("node_data_service");

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
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--listen")) return error.InvalidArguments;
    const separator = std.mem.lastIndexOfScalar(u8, args[2], ':') orelse return error.InvalidListenAddress;
    const host = args[2][0..separator];
    const port = try std.fmt.parseInt(u16, args[2][separator + 1 ..], 10);
    if (host.len == 0 or port == 0 or std.mem.indexOfScalar(u8, host, ':') != null)
        return error.InvalidListenAddress;

    var signals = try Signals.block();
    defer signals.restore();
    var server = try node.DataServer.init(allocator, init.io, host, port);
    defer server.deinit();
    try server.start();
    const address = try server.localAddress();
    std.log.info("zettide node service ready address={s}:{d}", .{ address.host, address.port });
    try signals.wait();
    server.shutdownGracefully(5 * std.time.ns_per_s);
    server.wait();
}
