pub const endpoint_daemon = @import("data_node_root.zig").endpoint_daemon;
pub const v3 = @import("v3/root.zig");

test {
    _ = @import("data_node_root.zig");
    _ = v3;
}
