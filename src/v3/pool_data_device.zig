const std = @import("std");
const pool_layout = @import("pool_layout.zig");
const ReplicaEndpoint = @import("replica_endpoint.zig").ReplicaEndpoint;
const storage_api = @import("storage.zig");

const max_replica_count = 3;
const io_alignment = 4096;

const Operation = union(enum) {
    read: struct { offset: u64, buffer: []u8 },
    write: struct { offset: u64, data: []const u8 },
    write_many: []const storage_api.Write,
    sync,
};

pub const Device = struct {
    io: std.Io,
    replicas: [max_replica_count]ReplicaEndpoint,
    replica_count: usize,
    kind: pool_layout.Kind,
    logical_capacity: u64,
    dirty: std.atomic.Value(bool) = .init(false),
    write_frozen: std.atomic.Value(bool) = .init(false),

    pub fn init(
        io: std.Io,
        replicas: []const ReplicaEndpoint,
        layout: pool_layout.Layout,
        logical_capacity: u64,
    ) !Device {
        const required_count: usize = switch (layout.kind) {
            .unprotected => 1,
            .replicated => max_replica_count,
            .erasure_coded => return error.ErasureCodingNotImplemented,
        };
        if (replicas.len != required_count) return error.UnsupportedPoolWidth;
        if (logical_capacity == 0 or logical_capacity % io_alignment != 0)
            return error.InvalidPoolDataGeometry;
        var result: Device = .{
            .io = io,
            .replicas = undefined,
            .replica_count = replicas.len,
            .kind = layout.kind,
            .logical_capacity = logical_capacity,
        };
        for (replicas, 0..) |replica, index| {
            if (replica.geometry.logical_capacity != logical_capacity or
                replica.geometry.data_length < logical_capacity)
                return error.InconsistentPoolCapacity;
            result.replicas[index] = replica;
        }
        return result;
    }

    pub fn readAt(self: *Device, buffer: []u8, offset: u64) !usize {
        try self.validateIo(offset, buffer.len);
        if (self.kind == .unprotected) {
            try self.replicas[0].readData(offset, buffer);
            return buffer.len;
        }

        var processed: usize = 0;
        while (processed < buffer.len) : (processed += io_alignment) {
            const chunk = buffer[processed..][0..io_alignment];
            const chunk_offset = offset + processed;
            var copies: [max_replica_count][io_alignment]u8 = undefined;
            var operations: [max_replica_count]Operation = undefined;
            for (operations[0..self.replica_count], 0..) |*operation, index|
                operation.* = .{ .read = .{ .offset = chunk_offset, .buffer = &copies[index] } };
            var errors: [max_replica_count]?anyerror = @splat(null);
            try self.run(operations[0..self.replica_count], errors[0..self.replica_count]);
            for (0..self.replica_count) |left| {
                if (errors[left] != null) continue;
                for (left + 1..self.replica_count) |right| {
                    if (errors[right] == null and std.mem.eql(u8, &copies[left], &copies[right])) {
                        @memcpy(chunk, &copies[left]);
                        break;
                    }
                } else continue;
                break;
            } else {
                if (firstError(errors[0..self.replica_count]) == null) return error.ReplicaDivergence;
                return error.ReplicaQuorumUnavailable;
            }
        }
        return buffer.len;
    }

    pub fn readManyAt(
        self: *Device,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
    ) !void {
        if (reads.len != results.len) return error.InvalidReadBatch;
        for (results) |*result| result.* = .{};
        for (reads) |request| try self.validateIo(request.offset, request.buffer.len);
        if (self.kind == .unprotected)
            return self.replicas[0].readDataMany(reads, results);
        for (reads, results) |request, *result| {
            result.amount = self.readAt(request.buffer, request.offset) catch |err| {
                result.failure = err;
                continue;
            };
        }
    }

    pub fn writeAllAt(self: *Device, data: []const u8, offset: u64) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        try self.validateIo(offset, data.len);
        var operations: [max_replica_count]Operation = undefined;
        for (operations[0..self.replica_count]) |*operation|
            operation.* = .{ .write = .{ .offset = offset, .data = data } };
        try self.runWrites(operations[0..self.replica_count]);
        self.dirty.store(true, .release);
    }

    pub fn writeAllManyAt(self: *Device, writes: []const storage_api.Write) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        for (writes) |write| try self.validateIo(write.offset, write.bytes.len);
        if (writes.len == 0) return;
        var operations: [max_replica_count]Operation = undefined;
        for (operations[0..self.replica_count]) |*operation| operation.* = .{ .write_many = writes };
        try self.runWrites(operations[0..self.replica_count]);
        self.dirty.store(true, .release);
    }

    pub fn sync(self: *Device) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (!self.dirty.load(.acquire)) return;
        var operations: [max_replica_count]Operation = @splat(.sync);
        try self.runWrites(operations[0..self.replica_count]);
        self.dirty.store(false, .release);
    }

    pub fn isWriteFrozen(self: *const Device) bool {
        return self.write_frozen.load(.acquire);
    }

    fn runWrites(self: *Device, operations: []const Operation) !void {
        var errors: [max_replica_count]?anyerror = @splat(null);
        self.run(operations, errors[0..self.replica_count]) catch |err| {
            self.write_frozen.store(true, .release);
            return err;
        };
        if (firstError(errors[0..self.replica_count])) |err| {
            self.write_frozen.store(true, .release);
            return err;
        }
    }

    fn run(self: *Device, operations: []const Operation, errors: []?anyerror) !void {
        std.debug.assert(operations.len == self.replica_count);
        std.debug.assert(errors.len == self.replica_count);
        var group: std.Io.Group = .init;
        defer group.cancel(self.io);
        for (self.replicas[0..self.replica_count], operations, errors) |replica, operation, *result| {
            group.concurrent(self.io, runOperation, .{ replica, operation, result }) catch
                try runOperation(replica, operation, result);
        }
        try group.await(self.io);
    }

    fn validateIo(self: *const Device, offset: u64, len: usize) !void {
        if (len == 0 or len % io_alignment != 0 or offset % io_alignment != 0 or
            offset > self.logical_capacity or len > self.logical_capacity - offset)
            return error.InvalidPoolDataIo;
    }
};

fn runOperation(replica: ReplicaEndpoint, operation: Operation, result: *?anyerror) std.Io.Cancelable!void {
    switch (operation) {
        .read => |read| replica.readData(read.offset, read.buffer) catch |err| {
            result.* = err;
        },
        .write => |write| replica.writeData(write.offset, write.data) catch |err| {
            result.* = err;
        },
        .write_many => |writes| replica.writeDataMany(writes) catch |err| {
            result.* = err;
        },
        .sync => replica.sync() catch |err| {
            result.* = err;
        },
    }
}

fn firstError(errors: []const ?anyerror) ?anyerror {
    for (errors) |maybe_error| if (maybe_error) |err| return err;
    return null;
}
