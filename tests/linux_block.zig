const std = @import("std");
const storage_engine = @import("zettide_storage");
const data_node = @import("zettide_data_node");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;

    const operation = args[1];
    const device = args[2];
    const api = data_node.linux_block_device;
    const info = try api.inspect(init.io, init.arena.allocator(), device);
    if (std.mem.eql(u8, operation, "expect-read-only")) {
        if (!info.eligibility.read_only or info.preflightEligible()) return error.ExpectedReadOnlyDevice;
        return;
    }
    if (std.mem.eql(u8, operation, "expect-mounted")) {
        if (!info.eligibility.mounted or info.preflightEligible()) return error.ExpectedMountedDevice;
        return;
    }
    if (std.mem.eql(u8, operation, "reopen")) {
        const reopened = try api.openStorage(init.io, init.arena.allocator(), device, false);
        var reopened_storages = [_]storage_engine.v3.storage.Storage{reopened.storage};
        var set = try storage_engine.v3.pool_member_set.openStorages(
            init.io,
            init.arena.allocator(),
            &reopened_storages,
            .read_only,
        );
        defer set.deinit();
        if (set.authority() == null) return error.MissingAuthority;
        return;
    }
    if (std.mem.eql(u8, operation, "expect-busy")) {
        const opened = api.openStorage(init.io, init.arena.allocator(), device, true) catch |err| {
            if (err == error.DeviceBusy) return;
            return err;
        };
        var storage = opened.storage;
        storage.close(init.io) catch {};
        return error.ExpectedBusyDevice;
    }
    return error.InvalidOperation;
}
