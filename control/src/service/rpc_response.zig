const grpc = @import("grpc_lite");

pub fn send(call: grpc.ServerCall, status: grpc.Status, payload: []const u8) void {
    call.sendInitialMetadata(&.{}, .identity) catch {
        call.abort();
        return;
    };
    if (status.isOk()) {
        call.send(payload, .{}) catch {
            call.abort();
            return;
        };
    }
    call.finish(status, &.{}) catch call.abort();
}
