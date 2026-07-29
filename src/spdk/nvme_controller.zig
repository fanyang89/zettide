const std = @import("std");
const runtime_api = @import("runtime.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("spdk/nvme_controller.h");
});

pub const Controller = struct {
    handle: ?*c.struct_zettide_spdk_nvme_controller,

    pub const Transport = enum {
        tcp,
        rdma,
    };

    pub const AddressFamily = enum {
        unspecified,
        ipv4,
        ipv6,
    };

    pub const Options = struct {
        name: []const u8,
        transport: Transport = .tcp,
        address_family: AddressFamily = .ipv4,
        transport_address: []const u8,
        transport_service_id: []const u8 = "4420",
        subsystem_nqn: []const u8,
        host_nqn: ?[]const u8 = null,
        connect_timeout_us: u64 = 10 * std.time.us_per_s,
        namespace_name_capacity: u32 = 128,
    };

    pub fn attach(
        allocator: std.mem.Allocator,
        runtime: *runtime_api.Runtime,
        options: Options,
    ) !Controller {
        const runtime_handle = runtime.handle orelse return error.RuntimeStopped;
        const name_z = try allocator.dupeZ(u8, options.name);
        defer allocator.free(name_z);
        const address_z = try allocator.dupeZ(u8, options.transport_address);
        defer allocator.free(address_z);
        const service_z = try allocator.dupeZ(u8, options.transport_service_id);
        defer allocator.free(service_z);
        const subsystem_nqn_z = try allocator.dupeZ(u8, options.subsystem_nqn);
        defer allocator.free(subsystem_nqn_z);
        const host_nqn_z = if (options.host_nqn) |value| try allocator.dupeZ(u8, value) else null;
        defer if (host_nqn_z) |value| allocator.free(value);

        var c_options: c.struct_zettide_spdk_nvme_controller_opts = undefined;
        c.zettide_spdk_nvme_controller_opts_init(&c_options, @sizeOf(@TypeOf(c_options)));
        c_options.name = name_z.ptr;
        c_options.transport = switch (options.transport) {
            .tcp => c.ZETTIDE_SPDK_NVME_TRANSPORT_TCP,
            .rdma => c.ZETTIDE_SPDK_NVME_TRANSPORT_RDMA,
        };
        c_options.address_family = switch (options.address_family) {
            .unspecified => c.ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_UNSPECIFIED,
            .ipv4 => c.ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_IPV4,
            .ipv6 => c.ZETTIDE_SPDK_NVME_ADDRESS_FAMILY_IPV6,
        };
        c_options.transport_address = address_z.ptr;
        c_options.transport_service_id = service_z.ptr;
        c_options.subsystem_nqn = subsystem_nqn_z.ptr;
        c_options.host_nqn = if (host_nqn_z) |value| value.ptr else null;
        c_options.connect_timeout_us = options.connect_timeout_us;
        c_options.namespace_name_capacity = options.namespace_name_capacity;

        var handle: ?*c.struct_zettide_spdk_nvme_controller = null;
        try statusError(c.zettide_spdk_nvme_controller_attach(@ptrCast(runtime_handle), &c_options, &handle));
        return .{ .handle = handle orelse return error.UnexpectedControllerStatus };
    }

    pub fn namespaceCount(self: *const Controller) usize {
        return c.zettide_spdk_nvme_controller_get_namespace_count(self.handle);
    }

    pub fn namespaceNamesTruncated(self: *const Controller) bool {
        return c.zettide_spdk_nvme_controller_namespace_names_truncated(self.handle);
    }

    /// The returned slice remains valid until detach succeeds.
    pub fn namespaceName(self: *const Controller, index: usize) ![]const u8 {
        const name = c.zettide_spdk_nvme_controller_get_namespace_name(self.handle, index) orelse
            return error.NamespaceIndexOutOfBounds;
        return std.mem.span(name);
    }

    pub fn detach(self: *Controller) !void {
        const handle = self.handle orelse return;
        try statusError(c.zettide_spdk_nvme_controller_detach(handle));
        self.handle = null;
    }

    pub fn deinit(self: *Controller) void {
        self.detach() catch |err|
            std.debug.panic("failed to detach SPDK NVMe controller: {s}", .{@errorName(err)});
    }
};

fn statusError(status: c_int) !void {
    if (status == 0) return;
    return switch (-status) {
        c.EINVAL => error.InvalidControllerOptions,
        c.ENOMEM => error.OutOfMemory,
        c.EEXIST, c.EALREADY => error.ControllerExists,
        c.EBUSY => error.RuntimeBusy,
        c.EDEADLK => error.SpdkThreadViolation,
        c.ESHUTDOWN => error.RuntimeStopped,
        c.ENODEV, c.ENXIO => error.ControllerNotFound,
        c.ETIMEDOUT => error.ControllerTimeout,
        else => error.ControllerOperationFailed,
    };
}
