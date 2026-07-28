const std = @import("std");
const zettide = @import("zettide");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;

    const operation = args[1];
    const device = args[2];
    const api = zettide.v3.linux_block_device;
    const info = try api.inspect(init.io, init.arena.allocator(), device);
    if (std.mem.eql(u8, operation, "expect-read-only")) {
        if (!info.eligibility.read_only or info.preflightEligible()) return error.ExpectedReadOnlyDevice;
        return;
    }
    if (std.mem.eql(u8, operation, "expect-mounted")) {
        if (!info.eligibility.mounted or info.preflightEligible()) return error.ExpectedMountedDevice;
        return;
    }
    if (!std.mem.eql(u8, operation, "write")) return error.InvalidOperation;
    if (!info.preflightEligible()) return error.DeviceNotEligible;
    if (info.capacity_bytes < 16 * 1024 * 1024) return error.DeviceTooSmall;

    const opened = try api.openStorage(init.io, init.arena.allocator(), device, true);
    var transferred = false;
    defer if (!transferred) {
        var storage = opened.storage;
        storage.close(init.io);
    };
    if (!api.DeviceId.eql(info.id, opened.info.id)) return error.DeviceChanged;
    if (opened.storage.kind != .linux_block_device) return error.WrongStorageKind;
    var storages = [_]zettide.v3.storage.Storage{opened.storage};
    transferred = true;
    const outcome = try zettide.v3.pool_provision.create(
        init.io,
        init.arena.allocator(),
        &storages,
        .{ .protection = .unprotected, .label = "loop-probe" },
    );
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.PartialPoolCreation,
    };
    try provisioned.close();

    const reopened = try api.openStorage(init.io, init.arena.allocator(), device, false);
    var reopened_storages = [_]zettide.v3.storage.Storage{reopened.storage};
    var set = try zettide.v3.pool_member_set.openStorages(
        init.io,
        init.arena.allocator(),
        &reopened_storages,
        .read_only,
    );
    defer set.deinit();
    if (set.authority() == null) return error.MissingAuthority;
}
