const std = @import("std");
const runtime_api = @import("runtime.zig");

const c = @import("spdk_c");

pub const ServiceOptions = struct {
    traddr: []const u8,
    trsvcid: []const u8 = "3260",
    initiator_name: []const u8,
    netmask: []const u8,
    portal_group_tag: i32 = 1,
    initiator_group_tag: i32 = 1,
};

pub const IscsiService = struct {
    handle: ?*c.struct_zettide_spdk_iscsi_service,

    pub fn create(allocator: std.mem.Allocator, runtime: *runtime_api.Runtime, options: ServiceOptions) !IscsiService {
        const traddr = try allocator.dupeSentinel(u8, options.traddr, 0);
        defer allocator.free(traddr);
        const trsvcid = try allocator.dupeSentinel(u8, options.trsvcid, 0);
        defer allocator.free(trsvcid);
        const initiator_name = try allocator.dupeSentinel(u8, options.initiator_name, 0);
        defer allocator.free(initiator_name);
        const netmask = try allocator.dupeSentinel(u8, options.netmask, 0);
        defer allocator.free(netmask);

        var c_options: c.struct_zettide_spdk_iscsi_service_opts = undefined;
        c.zettide_spdk_iscsi_service_opts_init(&c_options, @sizeOf(@TypeOf(c_options)));
        c_options.traddr = traddr.ptr;
        c_options.trsvcid = trsvcid.ptr;
        c_options.initiator_name = initiator_name.ptr;
        c_options.netmask = netmask.ptr;
        c_options.portal_group_tag = options.portal_group_tag;
        c_options.initiator_group_tag = options.initiator_group_tag;
        var handle: ?*c.struct_zettide_spdk_iscsi_service = null;
        try statusError(c.zettide_spdk_iscsi_service_create(
            @ptrCast(runtime.handle orelse return error.RuntimeStopped),
            &c_options,
            &handle,
        ));
        return .{ .handle = handle orelse return error.UnexpectedIscsiStatus };
    }

    pub fn close(self: *IscsiService) !void {
        const handle = self.handle orelse return;
        try statusError(c.zettide_spdk_iscsi_service_close(handle));
        self.handle = null;
    }
};

pub const ExportOptions = struct {
    target_name: []const u8,
    bdev_name: []const u8,
    lun: i32 = 0,
    queue_depth: i32 = 64,
};

pub const IscsiExport = struct {
    handle: ?*c.struct_zettide_spdk_iscsi_export,

    pub fn create(allocator: std.mem.Allocator, service: *IscsiService, options: ExportOptions) !IscsiExport {
        const target_name = try allocator.dupeSentinel(u8, options.target_name, 0);
        defer allocator.free(target_name);
        const bdev_name = try allocator.dupeSentinel(u8, options.bdev_name, 0);
        defer allocator.free(bdev_name);
        var c_options: c.struct_zettide_spdk_iscsi_export_opts = undefined;
        c.zettide_spdk_iscsi_export_opts_init(&c_options, @sizeOf(@TypeOf(c_options)));
        c_options.target_name = target_name.ptr;
        c_options.bdev_name = bdev_name.ptr;
        c_options.lun = options.lun;
        c_options.queue_depth = options.queue_depth;
        var handle: ?*c.struct_zettide_spdk_iscsi_export = null;
        try statusError(c.zettide_spdk_iscsi_export_create(
            service.handle orelse return error.IscsiServiceStopped,
            &c_options,
            &handle,
        ));
        return .{ .handle = handle orelse return error.UnexpectedIscsiStatus };
    }

    pub fn close(self: *IscsiExport) !void {
        const handle = self.handle orelse return;
        try statusError(c.zettide_spdk_iscsi_export_close(handle));
        self.handle = null;
    }
};

fn statusError(status: c_int) !void {
    if (status == 0) return;
    return switch (-status) {
        c.EINVAL => error.InvalidIscsiOptions,
        c.ENOMEM => error.OutOfMemory,
        c.ENODEV => error.IscsiDependencyNotFound,
        c.ENOENT => error.IscsiExportNotFound,
        c.EEXIST => error.IscsiExportAlreadyExists,
        c.EADDRINUSE => error.IscsiAddressInUse,
        c.EBUSY, c.EAGAIN, c.EALREADY, c.EINPROGRESS => error.IscsiExportBusy,
        c.EDEADLK => error.SpdkThreadViolation,
        c.ESHUTDOWN => error.RuntimeStopped,
        else => error.UnexpectedIscsiStatus,
    };
}
