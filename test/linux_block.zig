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

    var opened = try api.openStorage(init.io, init.arena.allocator(), device, true);
    defer opened.storage.close(init.io);
    if (!api.DeviceId.eql(info.id, opened.info.id)) return error.DeviceChanged;
    if (opened.storage.kind != .linux_block_device) return error.WrongStorageKind;

    const offset: u64 = 8 * 1024 * 1024;
    const expected = "zettide-block-probe";
    try opened.storage.writeAllAt(init.io, expected, offset);
    try opened.storage.sync(init.io);
    var actual: [expected.len]u8 = undefined;
    const amount = try opened.storage.readAt(init.io, &actual, offset);
    if (amount != actual.len or !std.mem.eql(u8, expected, &actual)) return error.DataMismatch;
}
