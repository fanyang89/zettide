const std = @import("std");

pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("spdk/nvmf_tcp_export.h");
});

pub const Transport = enum {
    tcp,
    rdma,
};

pub const Options = struct {
    target_name: ?[]const u8 = null,
    nqn: []const u8,
    bdev_name: []const u8,
    serial_number: ?[]const u8 = null,
    model_number: ?[]const u8 = null,
    host_nqn: ?[]const u8 = null,
    traddr: []const u8,
    trsvcid: []const u8 = "4420",
    nsid: u32 = 1,
    allow_any_host: bool = false,
    transport: Transport = .tcp,
};

/// Owns one active NVMe-oF subsystem and listener for an existing SPDK bdev.
pub const NvmfExport = struct {
    handle: ?*c.struct_zettide_spdk_nvmf_tcp_export,

    pub fn create(
        allocator: std.mem.Allocator,
        runtime: *anyopaque,
        options: Options,
    ) !NvmfExport {
        const target_name = if (options.target_name) |value| try allocator.dupeZ(u8, value) else null;
        defer if (target_name) |value| allocator.free(value);
        const nqn = try allocator.dupeZ(u8, options.nqn);
        defer allocator.free(nqn);
        const bdev_name = try allocator.dupeZ(u8, options.bdev_name);
        defer allocator.free(bdev_name);
        const serial_number = if (options.serial_number) |value| try allocator.dupeZ(u8, value) else null;
        defer if (serial_number) |value| allocator.free(value);
        const model_number = if (options.model_number) |value| try allocator.dupeZ(u8, value) else null;
        defer if (model_number) |value| allocator.free(value);
        const host_nqn = if (options.host_nqn) |value| try allocator.dupeZ(u8, value) else null;
        defer if (host_nqn) |value| allocator.free(value);
        const traddr = try allocator.dupeZ(u8, options.traddr);
        defer allocator.free(traddr);
        const trsvcid = try allocator.dupeZ(u8, options.trsvcid);
        defer allocator.free(trsvcid);

        var c_options: c.struct_zettide_spdk_nvmf_tcp_export_opts = undefined;
        c.zettide_spdk_nvmf_tcp_export_opts_init(&c_options, @sizeOf(@TypeOf(c_options)));
        c_options.target_name = if (target_name) |value| value.ptr else null;
        c_options.nqn = nqn.ptr;
        c_options.bdev_name = bdev_name.ptr;
        c_options.serial_number = if (serial_number) |value| value.ptr else null;
        c_options.model_number = if (model_number) |value| value.ptr else null;
        c_options.host_nqn = if (host_nqn) |value| value.ptr else null;
        c_options.traddr = traddr.ptr;
        c_options.trsvcid = trsvcid.ptr;
        c_options.nsid = options.nsid;
        c_options.allow_any_host = options.allow_any_host;
        c_options.transport = switch (options.transport) {
            .tcp => c.ZETTIDE_SPDK_NVMF_TRANSPORT_TCP,
            .rdma => c.ZETTIDE_SPDK_NVMF_TRANSPORT_RDMA,
        };

        var handle: ?*c.struct_zettide_spdk_nvmf_tcp_export = null;
        try statusError(c.zettide_spdk_nvmf_tcp_export_create(
            @ptrCast(runtime),
            &c_options,
            &handle,
        ));
        return .{ .handle = handle orelse return error.UnexpectedNvmfStatus };
    }

    /// Keeps ownership when teardown fails, so close can be retried.
    pub fn close(self: *NvmfExport) !void {
        const handle = self.handle orelse return;
        try statusError(c.zettide_spdk_nvmf_tcp_export_close(handle));
        self.handle = null;
    }
};

pub const NvmfTcpExport = NvmfExport;

fn statusError(status: c_int) !void {
    if (status == 0) return;
    return switch (-status) {
        c.EINVAL => error.InvalidNvmfOptions,
        c.ENOMEM => error.OutOfMemory,
        c.ENODEV => error.NvmfDependencyNotFound,
        c.EEXIST => error.NvmfExportAlreadyExists,
        c.EADDRINUSE => error.NvmfAddressInUse,
        c.EBUSY, c.EAGAIN, c.EALREADY, c.EINPROGRESS => error.NvmfExportBusy,
        c.EDEADLK => error.SpdkThreadViolation,
        c.ESHUTDOWN => error.RuntimeStopped,
        else => error.UnexpectedNvmfStatus,
    };
}
