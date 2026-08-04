const std = @import("std");
const blob_device = @import("blob_device.zig");
const format = @import("blob_format.zig");
const google_crc32c = @import("crc32c");

const Io = std.Io;

pub const Store = struct {
    allocator: std.mem.Allocator,
    device: blob_device.Device,
    header: format.Header,
    staged_slots: u64,
    mutex: Io.Mutex = .init,
    frozen: bool = false,

    /// Takes ownership of device, including on failure.
    pub fn create(allocator: std.mem.Allocator, io: Io, device: blob_device.Device) !Store {
        var owned_device = device;
        errdefer owned_device.close(io) catch {};
        var header = try format.Header.init(io, owned_device.capacity());
        try writeHeader(allocator, io, &owned_device, format.header_a_offset, header);
        try owned_device.syncData(io);
        header.sequence += 1;
        try writeHeader(allocator, io, &owned_device, format.header_b_offset, header);
        try owned_device.sync(io);
        return .{
            .allocator = allocator,
            .device = owned_device,
            .header = header,
            .staged_slots = header.committed_slots,
        };
    }

    /// Takes ownership of device, including on failure.
    pub fn open(allocator: std.mem.Allocator, io: Io, device: blob_device.Device) !Store {
        var owned_device = device;
        errdefer owned_device.close(io) catch {};
        const first = try readHeader(allocator, io, &owned_device, format.header_a_offset);
        const second = try readHeader(allocator, io, &owned_device, format.header_b_offset);
        const header = try selectHeader(first, second, owned_device.capacity());
        return .{
            .allocator = allocator,
            .device = owned_device,
            .header = header,
            .staged_slots = header.committed_slots,
        };
    }

    pub fn close(self: *Store, io: Io) !void {
        try self.device.close(io);
        self.* = undefined;
    }

    pub fn committedSlots(self: *const Store) u64 {
        return self.header.committed_slots;
    }

    pub fn stagedSlots(self: *const Store) u64 {
        return self.staged_slots;
    }

    pub fn put(self: *Store, io: Io, data: []const u8) !format.BlobRef {
        const inputs = [_][]const u8{data};
        var references: [1]format.BlobRef = undefined;
        try self.putMany(io, &inputs, &references);
        return references[0];
    }

    pub fn putMany(
        self: *Store,
        io: Io,
        inputs: []const []const u8,
        references: []format.BlobRef,
    ) !void {
        if (inputs.len == 0 or inputs.len != references.len or inputs.len > blob_device.max_batch)
            return error.InvalidBlobBatch;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.requireWritable();
        if (inputs.len > self.header.slot_count - self.staged_slots) return error.BlobStoreFull;
        for (inputs) |input| if (input.len > format.blob_size) return error.BlobTooLarge;

        var writes: [blob_device.max_batch]blob_device.Write = undefined;
        const alignment = self.device.alignment();
        const direct = for (inputs) |input| {
            if (input.len != format.blob_size or @intFromPtr(input.ptr) % alignment != 0) break false;
        } else true;
        if (direct) {
            for (inputs, references, writes[0..inputs.len], 0..) |input, *reference, *write, index| {
                const slot = self.staged_slots + index;
                reference.* = .{
                    .slot = slot,
                    .valid_bytes = format.blob_size,
                    .checksums = format.payloadChecksums(input),
                };
                write.* = .{ .bytes = input, .offset = try format.slotOffset(slot) };
            }
            self.device.writeAllManyAt(io, writes[0..inputs.len]) catch |err| {
                self.frozen = true;
                return err;
            };
            self.staged_slots += inputs.len;
            return;
        }

        const bytes = try self.allocator.alignedAlloc(u8, .fromByteUnits(4096), inputs.len * format.blob_size);
        defer self.allocator.free(bytes);
        for (inputs, references, writes[0..inputs.len], 0..) |input, *reference, *write, index| {
            const slot = self.staged_slots + index;
            const payload = bytes[index * format.blob_size ..][0..format.blob_size];
            @memcpy(payload[0..input.len], input);
            @memset(payload[input.len..], 0);
            reference.* = .{
                .slot = slot,
                .valid_bytes = @intCast(input.len),
                .checksums = format.payloadChecksums(payload),
            };
            write.* = .{ .bytes = payload, .offset = try format.slotOffset(slot) };
        }
        self.device.writeAllManyAt(io, writes[0..inputs.len]) catch |err| {
            self.frozen = true;
            return err;
        };
        self.staged_slots += inputs.len;
    }

    /// Reserves one slot but writes only an aligned digest-protected prefix.
    pub fn putDigestOnly(self: *Store, io: Io, data: []const u8) !u64 {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.requireWritable();
        if (self.staged_slots == self.header.slot_count) return error.BlobStoreFull;
        const alignment = self.device.alignment();
        if (data.len == 0 or data.len > format.blob_size or data.len % alignment != 0)
            return error.InvalidDigestOnlyBlob;

        var allocated: ?[]align(4096) u8 = null;
        defer if (allocated) |bytes| self.allocator.free(bytes);
        const bytes = if (@intFromPtr(data.ptr) % alignment == 0)
            data
        else copied: {
            const buffer = try self.allocator.alignedAlloc(u8, .fromByteUnits(4096), data.len);
            @memcpy(buffer, data);
            allocated = buffer;
            break :copied buffer;
        };
        const slot = self.staged_slots;
        self.device.writeAllAt(io, bytes, try format.slotOffset(slot)) catch |err| {
            self.frozen = true;
            return err;
        };
        self.staged_slots += 1;
        return slot;
    }

    /// Reads and verifies one complete slot. Returns the logical payload length.
    pub fn read(self: *Store, io: Io, reference: format.BlobRef, output: []u8) !usize {
        if (output.len != format.blob_size) return error.InvalidBlobBuffer;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.frozen) return error.BlobStoreFrozen;
        try reference.validate(self.header.slot_count);
        if (reference.slot >= self.staged_slots) return error.UnpublishedBlobReference;
        try self.device.readAt(io, output, try format.slotOffset(reference.slot));
        if (!std.mem.eql(u32, &reference.checksums, &format.payloadChecksums(output)))
            return error.BlobChecksumMismatch;
        return reference.valid_bytes;
    }

    pub fn readDigestVerified(
        self: *Store,
        io: Io,
        slot: u64,
        valid_bytes: usize,
        expected_digest: *const [32]u8,
        output: []u8,
    ) !void {
        if (output.len != valid_bytes or valid_bytes == 0)
            return error.InvalidBlobBuffer;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.frozen) return error.BlobStoreFrozen;
        if (slot >= self.staged_slots) return error.UnpublishedBlobReference;
        try self.device.readAt(io, output, try format.slotOffset(slot));
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(output, &digest, .{});
        if (!std.mem.eql(u8, &digest, expected_digest)) return error.BlobDigestMismatch;
    }

    pub fn commit(self: *Store, io: Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.requireWritable();
        if (self.staged_slots == self.header.committed_slots) return;

        self.device.syncData(io) catch |err| {
            self.frozen = true;
            return err;
        };
        var next = self.header;
        next.sequence = std.math.add(u64, next.sequence, 1) catch {
            self.frozen = true;
            return error.BlobStoreSequenceExhausted;
        };
        next.committed_slots = self.staged_slots;
        const offset = if (next.sequence % 2 == 1) format.header_a_offset else format.header_b_offset;
        writeHeader(self.allocator, io, &self.device, offset, next) catch |err| {
            self.frozen = true;
            return err;
        };
        self.device.sync(io) catch |err| {
            self.frozen = true;
            return err;
        };
        self.header = next;
    }

    fn requireWritable(self: *const Store) !void {
        if (self.frozen) return error.BlobStoreFrozen;
    }
};

fn writeHeader(
    allocator: std.mem.Allocator,
    io: Io,
    device: *blob_device.Device,
    offset: u64,
    header: format.Header,
) !void {
    const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(4096), format.header_size);
    defer allocator.free(bytes);
    bytes[0..format.header_size].* = format.encodeHeader(header);
    try device.writeAllAt(io, bytes, offset);
}

fn readHeader(
    allocator: std.mem.Allocator,
    io: Io,
    device: *blob_device.Device,
    offset: u64,
) !?format.Header {
    const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(4096), format.header_size);
    defer allocator.free(bytes);
    try device.readAt(io, bytes, offset);
    return format.decodeHeader(@ptrCast(bytes.ptr)) catch null;
}

fn selectHeader(first: ?format.Header, second: ?format.Header, device_size: u64) !format.Header {
    const valid_first: ?format.Header = if (first) |header| value: {
        header.validate(device_size) catch break :value null;
        break :value header;
    } else null;
    const valid_second: ?format.Header = if (second) |header| value: {
        header.validate(device_size) catch break :value null;
        break :value header;
    } else null;
    if (valid_first == null and valid_second == null) return error.NoValidBlobStoreHeader;
    if (valid_first != null and valid_second != null and
        !std.mem.eql(u8, &valid_first.?.uuid, &valid_second.?.uuid))
        return error.ConflictingBlobStoreHeaders;
    if (valid_first != null and valid_second != null and
        valid_first.?.sequence == valid_second.?.sequence and
        !std.meta.eql(valid_first.?, valid_second.?))
        return error.AmbiguousBlobStoreAuthority;
    if (valid_first) |header| if (valid_second == null or header.sequence > valid_second.?.sequence) return header;
    return valid_second.?;
}

test "blob store commits and reopens immutable blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "blob-store",
        8 * 1024 * 1024,
        4096,
    );
    var store = try Store.create(std.testing.allocator, std.testing.io, device);
    var store_open = true;
    defer if (store_open) store.close(std.testing.io) catch {};

    const inputs = [_][]const u8{ "first", "second payload" };
    var references: [inputs.len]format.BlobRef = undefined;
    try store.putMany(std.testing.io, &inputs, &references);
    try std.testing.expectEqual(@as(u64, 0), store.committedSlots());
    try std.testing.expectEqual(@as(u64, 2), store.stagedSlots());

    const output = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), format.blob_size);
    defer std.testing.allocator.free(output);
    const first_len = try store.read(std.testing.io, references[0], output);
    try std.testing.expectEqualStrings(inputs[0], output[0..first_len]);
    try store.commit(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), store.committedSlots());
    try store.close(std.testing.io);
    store_open = false;

    const file = try tmp.dir.openFile(std.testing.io, "blob-store", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = @import("v3/storage.zig").Storage.initOwned(file, 8 * 1024 * 1024, .regular_file, 1, false);
    device = try blob_device.Device.init(storage, 0, 8 * 1024 * 1024, 4096);
    file_open = false;
    store = try Store.open(std.testing.allocator, std.testing.io, device);
    store_open = true;
    try std.testing.expectEqual(@as(u64, 2), store.committedSlots());
    const second_len = try store.read(std.testing.io, references[1], output);
    try std.testing.expectEqualStrings(inputs[1], output[0..second_len]);
}

test "blob store capacity and unpublished references are enforced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "small-blob-store",
        2 * 1024 * 1024,
        4096,
    );
    var store = try Store.create(std.testing.allocator, std.testing.io, device);
    defer store.close(std.testing.io) catch {};
    _ = try store.put(std.testing.io, "only slot");
    try std.testing.expectError(error.BlobStoreFull, store.put(std.testing.io, "full"));

    const output = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), format.blob_size);
    defer std.testing.allocator.free(output);
    const invalid: format.BlobRef = .{
        .slot = 1,
        .valid_bytes = 0,
        .checksums = @splat(0),
    };
    try std.testing.expectError(error.InvalidBlobReference, store.read(std.testing.io, invalid, output));
}

test "blob store falls back to the previous valid header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 4 * 1024 * 1024;
    const device = try blob_device.Device.createFile(std.testing.io, tmp.dir, "header-fallback", device_size, 4096);
    var store = try Store.create(std.testing.allocator, std.testing.io, device);
    _ = try store.put(std.testing.io, "committed in sequence three");
    try store.commit(std.testing.io);
    try std.testing.expectEqual(@as(u64, 3), store.header.sequence);
    try store.close(std.testing.io);

    const corrupt = try tmp.dir.openFile(std.testing.io, "header-fallback", .{ .mode = .read_write });
    try corrupt.writePositionalAll(std.testing.io, "x", 80);
    corrupt.close(std.testing.io);

    const reopened_file = try tmp.dir.openFile(std.testing.io, "header-fallback", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) reopened_file.close(std.testing.io);
    const storage = @import("v3/storage.zig").Storage.initOwned(reopened_file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, 4096);
    file_open = false;
    store = try Store.open(std.testing.allocator, std.testing.io, reopened_device);
    defer store.close(std.testing.io) catch {};
    try std.testing.expectEqual(@as(u64, 2), store.header.sequence);
    try std.testing.expectEqual(@as(u64, 0), store.committedSlots());
}

test "blob store detects payload corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 4 * 1024 * 1024;
    const device = try blob_device.Device.createFile(std.testing.io, tmp.dir, "payload-corruption", device_size, 4096);
    var store = try Store.create(std.testing.allocator, std.testing.io, device);
    const reference = try store.put(std.testing.io, "protected payload");
    try store.commit(std.testing.io);
    try store.close(std.testing.io);

    const corrupt = try tmp.dir.openFile(std.testing.io, "payload-corruption", .{ .mode = .read_write });
    try corrupt.writePositionalAll(std.testing.io, "x", try format.slotOffset(reference.slot));
    corrupt.close(std.testing.io);

    const reopened_file = try tmp.dir.openFile(std.testing.io, "payload-corruption", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) reopened_file.close(std.testing.io);
    const storage = @import("v3/storage.zig").Storage.initOwned(reopened_file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, 4096);
    file_open = false;
    store = try Store.open(std.testing.allocator, std.testing.io, reopened_device);
    defer store.close(std.testing.io) catch {};

    const output = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), format.blob_size);
    defer std.testing.allocator.free(output);
    try std.testing.expectError(error.BlobChecksumMismatch, store.read(std.testing.io, reference, output));
}
