const std = @import("std");
const block_device = @import("../block_device.zig");
const container = @import("../container.zig");
const pool_layout = @import("pool_layout.zig");
const ReplicaEndpoint = @import("replica_endpoint.zig").ReplicaEndpoint;
const storage_api = @import("storage.zig");
const volume_crypto = @import("../volume_crypto.zig");

const c = block_device.c;
const max_replica_count = 3;
const byte_io_alignment = 4096;

const ReplicaOperation = union(enum) {
    read: struct { offset: u64, buffer: []u8 },
    read_many: struct { reads: []const storage_api.Read, results: []storage_api.ReadResult },
    write: struct { offset: u64, data: []const u8 },
    write_many: []const storage_api.Write,
    sync,
};

pub const PoolBlockDevice = struct {
    io: std.Io,
    replicas: [max_replica_count]ReplicaEndpoint,
    replica_count: usize,
    kind: pool_layout.Kind,
    volume_header: container.Header,
    block_size: u32,
    block_count: u32,
    logical_capacity: u64,
    mutex: std.Io.Mutex = .init,
    dirty: std.atomic.Value(bool) = .init(false),
    write_frozen: std.atomic.Value(bool) = .init(false),
    crypto: ?*const volume_crypto.Context = null,
    pipeline_metrics: block_device.AtomicPipelineMetrics = .{},

    pub fn init(
        io: std.Io,
        replicas: []const ReplicaEndpoint,
        layout: pool_layout.Layout,
        header: container.Header,
    ) !PoolBlockDevice {
        return initCrypto(io, replicas, layout, header, null);
    }

    pub fn initCrypto(
        io: std.Io,
        replicas: []const ReplicaEndpoint,
        layout: pool_layout.Layout,
        header: container.Header,
        crypto: ?*const volume_crypto.Context,
    ) !PoolBlockDevice {
        const required_count: usize = switch (layout.kind) {
            .unprotected => 1,
            .replicated => max_replica_count,
            .erasure_coded => return error.ErasureCodingNotImplemented,
        };
        if (replicas.len != required_count) return error.UnsupportedPoolWidth;
        if (header.logical_size > replicas[0].geometry.logical_capacity)
            return error.TruncatedPoolData;
        var result: PoolBlockDevice = .{
            .io = io,
            .replicas = undefined,
            .replica_count = replicas.len,
            .kind = layout.kind,
            .volume_header = header,
            .block_size = header.block_size,
            .block_count = header.block_count,
            .logical_capacity = header.logical_size,
            .crypto = crypto,
        };
        for (replicas, 0..) |replica, index| {
            if (header.logical_size > replica.geometry.logical_capacity)
                return error.InconsistentPoolCapacity;
            result.replicas[index] = replica;
        }
        return result;
    }

    /// Initializes a header-free byte device over the Pool data regions.
    pub fn initBytes(
        io: std.Io,
        replicas: []const ReplicaEndpoint,
        layout: pool_layout.Layout,
        logical_capacity: u64,
    ) !PoolBlockDevice {
        const required_count: usize = switch (layout.kind) {
            .unprotected => 1,
            .replicated => max_replica_count,
            .erasure_coded => return error.ErasureCodingNotImplemented,
        };
        if (replicas.len != required_count) return error.UnsupportedPoolWidth;
        if (logical_capacity == 0 or logical_capacity % byte_io_alignment != 0)
            return error.InvalidPoolDataGeometry;
        var result: PoolBlockDevice = .{
            .io = io,
            .replicas = undefined,
            .replica_count = replicas.len,
            .kind = layout.kind,
            .volume_header = undefined,
            .block_size = 0,
            .block_count = 0,
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

    pub fn initHeaderReader(
        io: std.Io,
        replicas: []const ReplicaEndpoint,
        layout: pool_layout.Layout,
    ) !PoolBlockDevice {
        var header: container.Header = undefined;
        header.logical_size = container.default_block_size;
        header.block_size = container.default_block_size;
        header.block_count = 1;
        return init(io, replicas, layout, header);
    }

    pub fn read(self: *PoolBlockDevice, block: u32, offset: u32, buffer: []u8) !void {
        const start = std.Io.Clock.awake.now(self.io).nanoseconds;
        defer {
            const elapsed: u64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - start);
            _ = self.pipeline_metrics.littlefs_read_calls.fetchAdd(1, .monotonic);
            _ = self.pipeline_metrics.littlefs_read_bytes.fetchAdd(buffer.len, .monotonic);
            _ = self.pipeline_metrics.littlefs_read_elapsed_ns.fetchAdd(elapsed, .monotonic);
            block_device.recordAtomicMax(&self.pipeline_metrics.littlefs_read_max_ns, elapsed);
        }
        const data_offset = try self.position(block, offset, buffer.len);
        if (self.kind == .unprotected) {
            if (self.crypto == null) return self.replicas[0].readData(data_offset, buffer);
            if (buffer.len > container.default_block_size) return error.OutOfBounds;
            var ciphertext: [container.default_block_size]u8 = undefined;
            try self.replicas[0].readData(data_offset, ciphertext[0..buffer.len]);
            return self.decrypt(buffer, ciphertext[0..buffer.len], data_offset);
        }
        if (buffer.len > container.default_block_size) return error.OutOfBounds;

        var copies: [max_replica_count][container.default_block_size]u8 = undefined;
        var operations: [max_replica_count]ReplicaOperation = undefined;
        for (operations[0..self.replica_count], 0..) |*operation, index|
            operation.* = .{ .read = .{ .offset = data_offset, .buffer = copies[index][0..buffer.len] } };
        var errors: [max_replica_count]?anyerror = @splat(null);
        try self.runReplicaOperations(operations[0..self.replica_count], errors[0..self.replica_count]);
        for (0..self.replica_count) |left| {
            if (errors[left] != null) continue;
            for (left + 1..self.replica_count) |right| {
                if (errors[right] == null and std.mem.eql(
                    u8,
                    copies[left][0..buffer.len],
                    copies[right][0..buffer.len],
                )) {
                    if (self.crypto != null)
                        try self.decrypt(buffer, copies[left][0..buffer.len], data_offset)
                    else
                        @memcpy(buffer, copies[left][0..buffer.len]);
                    return;
                }
            }
        }
        return error.ReplicaQuorumUnavailable;
    }

    pub fn program(self: *PoolBlockDevice, block: u32, offset: u32, data: []const u8) !void {
        const start = std.Io.Clock.awake.now(self.io).nanoseconds;
        defer {
            const elapsed: u64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - start);
            _ = self.pipeline_metrics.littlefs_program_calls.fetchAdd(1, .monotonic);
            _ = self.pipeline_metrics.littlefs_program_bytes.fetchAdd(data.len, .monotonic);
            _ = self.pipeline_metrics.littlefs_program_elapsed_ns.fetchAdd(elapsed, .monotonic);
            block_device.recordAtomicMax(&self.pipeline_metrics.littlefs_program_max_ns, elapsed);
        }
        if (self.isWriteFrozen()) return error.WriteFrozen;
        const data_offset = try self.position(block, offset, data.len);
        var ciphertext: [container.default_block_size]u8 = undefined;
        const write_data = if (self.crypto != null) encrypted: {
            if (data.len > ciphertext.len) return error.OutOfBounds;
            try self.encrypt(ciphertext[0..data.len], data, data_offset);
            break :encrypted ciphertext[0..data.len];
        } else data;
        var operations: [max_replica_count]ReplicaOperation = undefined;
        for (operations[0..self.replica_count]) |*operation|
            operation.* = .{ .write = .{ .offset = data_offset, .data = write_data } };
        var errors: [max_replica_count]?anyerror = @splat(null);
        self.runReplicaOperations(operations[0..self.replica_count], errors[0..self.replica_count]) catch |err| {
            self.freezeWrites();
            return err;
        };
        if (firstReplicaError(errors[0..self.replica_count])) |err| {
            self.freezeWrites();
            return err;
        }
        _ = self.pipeline_metrics.direct_program_bytes.fetchAdd(data.len, .monotonic);
        _ = self.pipeline_metrics.backing_write_bytes.fetchAdd(data.len * self.replica_count, .monotonic);
        self.dirty.store(true, .release);
    }

    pub fn readAt(self: *PoolBlockDevice, buffer: []u8, offset: u64) !usize {
        try self.validateByteIo(offset, buffer.len);
        if (self.kind == .unprotected) {
            try self.replicas[0].readData(offset, buffer);
            return buffer.len;
        }

        var processed: usize = 0;
        while (processed < buffer.len) : (processed += byte_io_alignment) {
            const chunk = buffer[processed..][0..byte_io_alignment];
            const chunk_offset = offset + processed;
            var copies: [max_replica_count][byte_io_alignment]u8 = undefined;
            var operations: [max_replica_count]ReplicaOperation = undefined;
            for (operations[0..self.replica_count], 0..) |*operation, index|
                operation.* = .{ .read = .{ .offset = chunk_offset, .buffer = &copies[index] } };
            var errors: [max_replica_count]?anyerror = @splat(null);
            try self.runReplicaOperations(operations[0..self.replica_count], errors[0..self.replica_count]);
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
                if (firstReplicaError(errors[0..self.replica_count]) == null)
                    return error.ReplicaDivergence;
                return error.ReplicaQuorumUnavailable;
            }
        }
        return buffer.len;
    }

    pub fn readBufferAlignment(self: *const PoolBlockDevice) u32 {
        const conservative = if (self.block_size == 0) byte_io_alignment else self.block_size;
        if (self.kind != .unprotected or self.crypto != null) return conservative;
        return self.replicas[0].readBufferAlignment() orelse conservative;
    }

    pub fn readManyAt(
        self: *PoolBlockDevice,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
    ) !void {
        if (reads.len != results.len) return error.InvalidReadBatch;
        for (results) |*result| result.* = .{};
        for (reads) |request| try self.validateByteIo(request.offset, request.buffer.len);
        if (self.kind == .unprotected)
            return self.replicas[0].readDataMany(reads, results);
        for (reads, results) |request, *result| {
            result.amount = self.readAt(request.buffer, request.offset) catch |err| {
                result.failure = err;
                continue;
            };
        }
    }

    pub fn writeAllAt(self: *PoolBlockDevice, data: []const u8, offset: u64) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        try self.validateByteIo(offset, data.len);
        // Unlike control-plane quorum commits, Blob data writes require every replica.
        // Otherwise replicas could expose divergent committed Blob prefixes after failover.
        var operations: [max_replica_count]ReplicaOperation = undefined;
        for (operations[0..self.replica_count]) |*operation|
            operation.* = .{ .write = .{ .offset = offset, .data = data } };
        var errors: [max_replica_count]?anyerror = @splat(null);
        self.runReplicaOperations(operations[0..self.replica_count], errors[0..self.replica_count]) catch |err| {
            self.freezeWrites();
            return err;
        };
        if (firstReplicaError(errors[0..self.replica_count])) |err| {
            self.freezeWrites();
            return err;
        }
        _ = self.pipeline_metrics.direct_program_bytes.fetchAdd(data.len, .monotonic);
        _ = self.pipeline_metrics.backing_write_bytes.fetchAdd(data.len * self.replica_count, .monotonic);
        self.dirty.store(true, .release);
    }

    pub fn writeAllManyAt(self: *PoolBlockDevice, writes: []const storage_api.Write) !void {
        if (self.isWriteFrozen()) return error.WriteFrozen;
        var total_bytes: u64 = 0;
        for (writes) |write| {
            try self.validateByteIo(write.offset, write.bytes.len);
            total_bytes = std.math.add(u64, total_bytes, write.bytes.len) catch
                return error.InvalidPoolDataIo;
        }
        if (writes.len == 0) return;

        var operations: [max_replica_count]ReplicaOperation = undefined;
        for (operations[0..self.replica_count]) |*operation| operation.* = .{ .write_many = writes };
        var errors: [max_replica_count]?anyerror = @splat(null);
        self.runReplicaOperations(operations[0..self.replica_count], errors[0..self.replica_count]) catch |err| {
            self.freezeWrites();
            return err;
        };
        if (firstReplicaError(errors[0..self.replica_count])) |err| {
            self.freezeWrites();
            return err;
        }
        _ = self.pipeline_metrics.direct_program_bytes.fetchAdd(total_bytes, .monotonic);
        const backing_bytes = std.math.mul(u64, total_bytes, self.replica_count) catch std.math.maxInt(u64);
        _ = self.pipeline_metrics.backing_write_bytes.fetchAdd(backing_bytes, .monotonic);
        self.dirty.store(true, .release);
    }

    pub fn sync(self: *PoolBlockDevice) !void {
        _ = self.pipeline_metrics.logical_sync_calls.fetchAdd(1, .monotonic);
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (!self.dirty.load(.acquire)) return;
        const start = std.Io.Clock.awake.now(self.io).nanoseconds;
        defer {
            const elapsed: u64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds - start);
            _ = self.pipeline_metrics.backing_sync_calls.fetchAdd(self.replica_count, .monotonic);
            _ = self.pipeline_metrics.backing_sync_elapsed_ns.fetchAdd(elapsed, .monotonic);
            block_device.recordAtomicMax(&self.pipeline_metrics.backing_sync_max_ns, elapsed);
        }
        var operations: [max_replica_count]ReplicaOperation = @splat(.sync);
        var errors: [max_replica_count]?anyerror = @splat(null);
        self.runReplicaOperations(operations[0..self.replica_count], errors[0..self.replica_count]) catch |err| {
            self.freezeWrites();
            return err;
        };
        if (firstReplicaError(errors[0..self.replica_count])) |err| {
            self.freezeWrites();
            return err;
        }
        self.dirty.store(false, .release);
    }

    pub fn pipelineMetrics(self: *const PoolBlockDevice) block_device.PipelineMetrics {
        return self.pipeline_metrics.snapshot();
    }

    pub fn resetPipelineMetrics(self: *PoolBlockDevice) void {
        self.pipeline_metrics.reset();
    }

    pub fn initializeEncryptedData(self: *PoolBlockDevice) !void {
        if (self.crypto == null) return error.EncryptionNotConfigured;
        const zeros: [container.default_block_size]u8 = @splat(0);
        for (0..self.block_count) |block| try self.program(@intCast(block), 0, &zeros);
        try self.sync();
    }

    pub fn writeHeaderDurable(self: *PoolBlockDevice, offset: u64, header: container.Header) !void {
        if (offset != container.header_a_offset and offset != container.header_b_offset)
            return error.InvalidHeaderOffset;
        if (self.isWriteFrozen()) return error.WriteFrozen;
        const encoded = header.encode();
        var first_error: ?anyerror = null;
        for (self.replicas[0..self.replica_count]) |replica| {
            replica.writeMetadataDurable(offset, &encoded) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
        if (first_error) |err| {
            self.freezeWrites();
            return err;
        }
    }

    pub fn readHeader(self: *PoolBlockDevice) !container.Header {
        var headers: [max_replica_count]?container.Header = @splat(null);
        for (self.replicas[0..self.replica_count], 0..) |replica, index|
            headers[index] = readReplicaHeader(replica) catch null;
        if (self.kind == .unprotected) return headers[0] orelse error.NoValidPoolVolumeHeader;
        for (0..self.replica_count) |left| {
            const left_header = headers[left] orelse continue;
            const left_identity = volumeIdentity(left_header);
            for (left + 1..self.replica_count) |right| {
                const right_header = headers[right] orelse continue;
                if (std.mem.eql(u8, &left_identity, &volumeIdentity(right_header)))
                    return if (right_header.sequence > left_header.sequence) right_header else left_header;
            }
        }
        for (headers, 0..) |maybe_header, ready_index| {
            const header = maybe_header orelse continue;
            const identity = volumeIdentity(header);
            for (self.replicas[0..self.replica_count], 0..) |replica, replica_index| {
                if (replica_index == ready_index) continue;
                if (try replicaHeaderState(replica, identity) != .creating) break;
            } else return header;
        }
        return error.VolumeHeaderQuorumUnavailable;
    }

    pub fn canInitializeVolume(self: *PoolBlockDevice, allocator: std.mem.Allocator) !bool {
        var bytes: [container.header_size]u8 = undefined;
        var volume_identity: ?[container.header_size]u8 = null;
        var creating_found = false;
        var invalid_found = false;
        var ready_members: usize = 0;
        for (self.replicas[0..self.replica_count]) |replica| {
            var replica_ready = false;
            for ([_]u64{ container.header_a_offset, container.header_b_offset }) |offset| {
                try replica.readMetadata(offset, &bytes);
                if (std.mem.allEqual(u8, &bytes, 0)) continue;
                const header = container.Header.decode(&bytes) catch {
                    invalid_found = true;
                    continue;
                };
                const identity = volumeIdentity(header);
                if (volume_identity) |expected| {
                    if (!std.mem.eql(u8, &expected, &identity)) return false;
                } else {
                    volume_identity = identity;
                }
                switch (header.state) {
                    .creating => creating_found = true,
                    .ready => replica_ready = true,
                }
            }
            ready_members += @intFromBool(replica_ready);
        }
        if (ready_members != 0) return false;
        if (creating_found) return true;
        if (invalid_found) return false;

        const chunk_size = 1024 * 1024;
        const batch_depth = 8;
        const buffer = try allocator.alloc(u8, chunk_size * batch_depth);
        defer allocator.free(buffer);
        for (self.replicas[0..self.replica_count]) |replica| {
            var offset: u64 = 0;
            while (offset < replica.geometry.data_length) {
                var reads: [batch_depth]storage_api.Read = undefined;
                var results: [batch_depth]storage_api.ReadResult = undefined;
                var count: usize = 0;
                var batch_offset = offset;
                while (count < batch_depth and batch_offset < replica.geometry.data_length) : (count += 1) {
                    const amount: usize = @intCast(@min(@as(u64, chunk_size), replica.geometry.data_length - batch_offset));
                    reads[count] = .{ .buffer = buffer[count * chunk_size ..][0..amount], .offset = batch_offset };
                    batch_offset += amount;
                }
                try replica.readDataMany(reads[0..count], results[0..count]);
                for (reads[0..count], results[0..count]) |request, result| {
                    if (result.failure) |err| return err;
                    if (result.amount != request.buffer.len) return error.TruncatedMember;
                    if (!std.mem.allEqual(u8, request.buffer, 0)) return false;
                }
                offset = batch_offset;
            }
        }
        return true;
    }

    pub fn prepareWritableReplicas(self: *PoolBlockDevice, allocator: std.mem.Allocator) !void {
        if (self.kind == .unprotected) return;
        const expected_header = self.volume_header;
        const expected_header_identity = volumeIdentity(expected_header);
        var header_states: [max_replica_count]MemberHeaderState = undefined;
        for (self.replicas[0..self.replica_count], 0..) |replica, index|
            header_states[index] = try replicaHeaderState(replica, expected_header_identity);
        const chunk_size = 1024 * 1024;
        const batch_depth = 8;
        const buffers = try allocator.alloc([batch_depth][chunk_size]u8, self.replica_count);
        defer allocator.free(buffers);
        const logical_size = @as(u64, self.block_size) * self.block_count;
        var offset: u64 = 0;
        while (offset < logical_size) {
            var reads: [max_replica_count][batch_depth]storage_api.Read = undefined;
            var results: [max_replica_count][batch_depth]storage_api.ReadResult = undefined;
            var count: usize = 0;
            var batch_offset = offset;
            while (count < batch_depth and batch_offset < logical_size) : (count += 1) {
                const amount: usize = @intCast(@min(@as(u64, chunk_size), logical_size - batch_offset));
                for (0..self.replica_count) |replica_index| reads[replica_index][count] = .{
                    .buffer = buffers[replica_index][count][0..amount],
                    .offset = batch_offset,
                };
                batch_offset += amount;
            }
            var operations: [max_replica_count]ReplicaOperation = undefined;
            for (operations[0..self.replica_count], 0..) |*operation, index|
                operation.* = .{ .read_many = .{
                    .reads = reads[index][0..count],
                    .results = results[index][0..count],
                } };
            var errors: [max_replica_count]?anyerror = @splat(null);
            try self.runReplicaOperations(operations[0..self.replica_count], errors[0..self.replica_count]);
            if (firstReplicaError(errors[0..self.replica_count])) |err| return err;
            for (0..count) |batch_index| {
                for (results[0..self.replica_count], reads[0..self.replica_count]) |replica_results, replica_reads| {
                    const result = replica_results[batch_index];
                    if (result.failure) |err| return err;
                    if (result.amount != replica_reads[batch_index].buffer.len)
                        return error.TruncatedMember;
                }
                const expected = reads[0][batch_index].buffer;
                for (reads[1..self.replica_count]) |replica_reads| {
                    if (!std.mem.eql(u8, expected, replica_reads[batch_index].buffer))
                        return error.ReplicaDivergence;
                }
            }
            offset = batch_offset;
        }
        var repaired_header = expected_header;
        repaired_header.state = .ready;
        repaired_header.sequence = 2;
        for (self.replicas[0..self.replica_count], header_states[0..self.replica_count]) |replica, state| {
            if (state == .ready) continue;
            try replica.writeMetadataDurable(container.header_b_offset, &repaired_header.encode());
            repaired_header.sequence = 3;
            try replica.writeMetadataDurable(container.header_a_offset, &repaired_header.encode());
            repaired_header.sequence = 2;
        }
    }

    pub fn isWriteFrozen(self: *const PoolBlockDevice) bool {
        return self.write_frozen.load(.acquire);
    }

    pub fn configure(self: *PoolBlockDevice, header: container.Header) c.struct_lfs_config {
        var config: c.struct_lfs_config = std.mem.zeroes(c.struct_lfs_config);
        config.context = self;
        config.read = readCallback;
        config.prog = programCallback;
        config.erase = eraseCallback;
        config.sync = syncCallback;
        config.lock = lockCallback;
        config.unlock = unlockCallback;
        config.read_size = header.read_size;
        config.prog_size = header.prog_size;
        config.block_size = header.block_size;
        config.block_count = header.block_count;
        config.block_cycles = -1;
        config.cache_size = header.block_size;
        config.lookahead_size = lookaheadSize(header.block_count);
        config.name_max = header.name_max;
        config.file_max = header.file_max;
        config.attr_max = header.attr_max;
        return config;
    }

    fn freezeWrites(self: *PoolBlockDevice) void {
        self.write_frozen.store(true, .release);
    }

    fn runReplicaOperations(
        self: *PoolBlockDevice,
        operations: []const ReplicaOperation,
        errors: []?anyerror,
    ) !void {
        std.debug.assert(operations.len == self.replica_count);
        std.debug.assert(errors.len == self.replica_count);
        var group: std.Io.Group = .init;
        defer group.cancel(self.io);
        for (self.replicas[0..self.replica_count], operations, errors) |replica, operation, *result| {
            group.concurrent(self.io, runReplicaOperation, .{ replica, operation, result }) catch
                try runReplicaOperation(replica, operation, result);
        }
        try group.await(self.io);
    }

    fn position(self: *const PoolBlockDevice, block: u32, offset: u32, len: usize) !u64 {
        if (block >= self.block_count or offset > self.block_size) return error.OutOfBounds;
        if (len > self.block_size - offset) return error.OutOfBounds;
        const block_offset = std.math.mul(u64, block, self.block_size) catch return error.OutOfBounds;
        return std.math.add(u64, block_offset, offset) catch return error.OutOfBounds;
    }

    fn validateByteIo(self: *const PoolBlockDevice, offset: u64, len: usize) !void {
        if (len == 0 or len % byte_io_alignment != 0 or offset % byte_io_alignment != 0 or
            offset > self.logical_capacity or len > self.logical_capacity - offset)
            return error.InvalidPoolDataIo;
    }

    fn encrypt(self: *const PoolBlockDevice, output: []u8, input: []const u8, offset: u64) !void {
        return self.crypt(output, input, offset, true);
    }

    fn decrypt(self: *const PoolBlockDevice, output: []u8, input: []const u8, offset: u64) !void {
        return self.crypt(output, input, offset, false);
    }

    fn crypt(
        self: *const PoolBlockDevice,
        output: []u8,
        input: []const u8,
        offset: u64,
        encrypting: bool,
    ) !void {
        const crypto = self.crypto orelse return error.EncryptionNotConfigured;
        if (offset % volume_crypto.sector_size != 0 or input.len % volume_crypto.sector_size != 0 or
            output.len != input.len) return error.InvalidEncryptedIo;
        var processed: usize = 0;
        while (processed < input.len) : (processed += volume_crypto.sector_size) {
            const data_unit = offset / volume_crypto.sector_size + processed / volume_crypto.sector_size;
            if (encrypting)
                try crypto.encrypt(
                    output[processed..][0..volume_crypto.sector_size],
                    input[processed..][0..volume_crypto.sector_size],
                    data_unit,
                )
            else
                try crypto.decrypt(
                    output[processed..][0..volume_crypto.sector_size],
                    input[processed..][0..volume_crypto.sector_size],
                    data_unit,
                );
        }
    }

    fn fromConfig(config: *const c.struct_lfs_config) *PoolBlockDevice {
        return @ptrCast(@alignCast(config.context.?));
    }

    fn readCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t, offset: c.lfs_off_t, raw: ?*anyopaque, size: c.lfs_size_t) callconv(.c) c_int {
        const buffer = @as([*]u8, @ptrCast(raw.?))[0..size];
        fromConfig(config.?).read(block, offset, buffer) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn programCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t, offset: c.lfs_off_t, raw: ?*const anyopaque, size: c.lfs_size_t) callconv(.c) c_int {
        const data = @as([*]const u8, @ptrCast(raw.?))[0..size];
        fromConfig(config.?).program(block, offset, data) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn eraseCallback(config: ?*const c.struct_lfs_config, block: c.lfs_block_t) callconv(.c) c_int {
        const self = fromConfig(config.?);
        if (block >= self.block_count) return c.LFS_ERR_IO;
        return 0;
    }

    fn syncCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        fromConfig(config.?).sync() catch return c.LFS_ERR_IO;
        return 0;
    }

    fn lockCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        const self = fromConfig(config.?);
        self.mutex.lock(self.io) catch return c.LFS_ERR_IO;
        return 0;
    }

    fn unlockCallback(config: ?*const c.struct_lfs_config) callconv(.c) c_int {
        const self = fromConfig(config.?);
        self.mutex.unlock(self.io);
        return 0;
    }
};

fn runReplicaOperation(
    replica: ReplicaEndpoint,
    operation: ReplicaOperation,
    result: *?anyerror,
) std.Io.Cancelable!void {
    switch (operation) {
        .read => |read| replica.readData(read.offset, read.buffer) catch |err| {
            result.* = err;
        },
        .read_many => |read| replica.readDataMany(read.reads, read.results) catch |err| {
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

fn firstReplicaError(errors: []const ?anyerror) ?anyerror {
    for (errors) |maybe_error| if (maybe_error) |err| return err;
    return null;
}

fn readReplicaHeader(replica: ReplicaEndpoint) !container.Header {
    var a_bytes: [container.header_size]u8 = undefined;
    var b_bytes: [container.header_size]u8 = undefined;
    try replica.readMetadata(container.header_a_offset, &a_bytes);
    try replica.readMetadata(container.header_b_offset, &b_bytes);
    const a = container.Header.decode(&a_bytes) catch null;
    const b = container.Header.decode(&b_bytes) catch null;
    const selected = if (a) |a_header|
        if (b) |b_header| if (b_header.sequence > a_header.sequence) b_header else a_header else a_header
    else if (b) |b_header|
        b_header
    else
        return error.NoValidPoolVolumeHeader;
    if (selected.state != .ready) return error.IncompletePoolVolume;
    if (selected.logical_size > replica.geometry.logical_capacity) return error.TruncatedPoolData;
    return selected;
}

const MemberHeaderState = enum { creating, ready };

fn replicaHeaderState(replica: ReplicaEndpoint, expected_identity: [container.header_size]u8) !MemberHeaderState {
    var bytes: [container.header_size]u8 = undefined;
    var creating_found = false;
    var ready_found = false;
    for ([_]u64{ container.header_a_offset, container.header_b_offset }) |offset| {
        try replica.readMetadata(offset, &bytes);
        if (std.mem.allEqual(u8, &bytes, 0)) continue;
        const header = container.Header.decode(&bytes) catch continue;
        if (!std.mem.eql(u8, &expected_identity, &volumeIdentity(header)))
            return error.ReplicaHeaderDivergence;
        switch (header.state) {
            .creating => creating_found = true,
            .ready => ready_found = true,
        }
    }
    if (ready_found) return .ready;
    if (creating_found) return .creating;
    return error.NoValidPoolVolumeHeader;
}

fn volumeIdentity(source: container.Header) [container.header_size]u8 {
    var header = source;
    header.sequence = 0;
    header.state = .creating;
    return header.encode();
}

fn lookaheadSize(block_count: u32) u32 {
    const bytes = std.math.divCeil(u32, block_count, 8) catch unreachable;
    return @max(8, @min(4096, std.mem.alignForward(u32, bytes, 8)));
}

const ConcurrentReplicaProbe = struct {
    io: std.Io,
    entered: *std.atomic.Value(u32),
    all_entered: *std.Io.Event,

    const vtable: ReplicaEndpoint.VTable = .{
        .read_metadata = read,
        .read_data = read,
        .write_data = write,
        .write_metadata_durable = write,
        .sync = sync,
    };

    fn fromContext(context: *anyopaque) *ConcurrentReplicaProbe {
        return @ptrCast(@alignCast(context));
    }

    fn read(context: *anyopaque, offset: u64, buffer: []u8) anyerror!void {
        _ = context;
        _ = offset;
        @memset(buffer, 0);
    }

    fn write(context: *anyopaque, offset: u64, data: []const u8) anyerror!void {
        _ = offset;
        _ = data;
        const self = fromContext(context);
        if (self.entered.fetchAdd(1, .acq_rel) + 1 == max_replica_count)
            self.all_entered.set(self.io);
        self.all_entered.waitUncancelable(self.io);
    }

    fn sync(context: *anyopaque) anyerror!void {
        _ = context;
    }
};

test "replicated writes run concurrently" {
    var entered: std.atomic.Value(u32) = .init(0);
    var all_entered: std.Io.Event = .unset;
    var probes: [max_replica_count]ConcurrentReplicaProbe = undefined;
    var replicas: [max_replica_count]ReplicaEndpoint = undefined;
    for (&probes, &replicas) |*probe, *replica| {
        probe.* = .{ .io = std.testing.io, .entered = &entered, .all_entered = &all_entered };
        replica.* = .init(probe, .{
            .logical_capacity = 1024 * 1024,
            .data_length = 1024 * 1024,
        }, &ConcurrentReplicaProbe.vtable);
    }
    const layout = try pool_layout.Layout.init(.replicated, 1, 1, container.default_block_size);
    const header = try container.Header.init(std.testing.io, 1024 * 1024, "concurrent");
    var device = try PoolBlockDevice.init(std.testing.io, &replicas, layout, header);

    try device.program(0, 0, "data");
    try std.testing.expectEqual(@as(u32, max_replica_count), entered.load(.acquire));
    try device.sync();
    const metrics = device.pipelineMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics.littlefs_program_calls);
    try std.testing.expectEqual(@as(u64, 4), metrics.littlefs_program_bytes);
    try std.testing.expectEqual(@as(u64, 12), metrics.backing_write_bytes);
    try std.testing.expectEqual(@as(u64, 1), metrics.logical_sync_calls);
    try std.testing.expectEqual(@as(u64, max_replica_count), metrics.backing_sync_calls);
    device.resetPipelineMetrics();
    try std.testing.expectEqual(@as(u64, 0), device.pipelineMetrics().littlefs_program_calls);
}

const BatchReplicaProbe = struct {
    batch_calls: std.atomic.Value(u32) = .init(0),
    single_calls: std.atomic.Value(u32) = .init(0),
    write_count: std.atomic.Value(u32) = .init(0),
    fail_batch: bool = false,

    const vtable: ReplicaEndpoint.VTable = .{
        .read_metadata = read,
        .read_data = read,
        .write_data = write,
        .write_data_many = writeMany,
        .write_metadata_durable = write,
        .sync = sync,
        .read_buffer_alignment = readBufferAlignment,
    };

    fn fromContext(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }

    fn read(_: *anyopaque, _: u64, buffer: []u8) anyerror!void {
        @memset(buffer, 0);
    }

    fn write(context: *anyopaque, _: u64, _: []const u8) anyerror!void {
        _ = fromContext(context).single_calls.fetchAdd(1, .monotonic);
    }

    fn writeMany(context: *anyopaque, writes: []const storage_api.Write) anyerror!void {
        const self = fromContext(context);
        _ = self.batch_calls.fetchAdd(1, .monotonic);
        _ = self.write_count.fetchAdd(@intCast(writes.len), .monotonic);
        if (self.fail_batch) return error.InjectedFault;
    }

    fn sync(_: *anyopaque) anyerror!void {}

    fn readBufferAlignment(_: *anyopaque) u32 {
        return 1;
    }
};

test "Pool byte reads only propagate relaxed alignment when unprotected" {
    var probes: [max_replica_count]BatchReplicaProbe = @splat(.{});
    var replicas: [max_replica_count]ReplicaEndpoint = undefined;
    for (&probes, &replicas) |*probe, *replica| replica.* = .init(probe, .{
        .logical_capacity = 1024 * 1024,
        .data_length = 1024 * 1024,
    }, &BatchReplicaProbe.vtable);

    const unprotected_layout = try pool_layout.Layout.init(.unprotected, 1, 1, container.default_block_size);
    const unprotected = try PoolBlockDevice.initBytes(std.testing.io, replicas[0..1], unprotected_layout, 1024 * 1024);
    try std.testing.expectEqual(@as(u32, 1), unprotected.readBufferAlignment());

    const replicated_layout = try pool_layout.Layout.init(.replicated, 1, 1, container.default_block_size);
    const replicated = try PoolBlockDevice.initBytes(std.testing.io, &replicas, replicated_layout, 1024 * 1024);
    try std.testing.expectEqual(@as(u32, byte_io_alignment), replicated.readBufferAlignment());
}

test "replicated byte writes preserve batches for every member" {
    var probes: [max_replica_count]BatchReplicaProbe = @splat(.{});
    var replicas: [max_replica_count]ReplicaEndpoint = undefined;
    for (&probes, &replicas) |*probe, *replica| replica.* = .init(probe, .{
        .logical_capacity = 1024 * 1024,
        .data_length = 1024 * 1024,
    }, &BatchReplicaProbe.vtable);
    const layout = try pool_layout.Layout.init(.replicated, 1, 1, container.default_block_size);
    var device = try PoolBlockDevice.initBytes(std.testing.io, &replicas, layout, 1024 * 1024);
    const first: [byte_io_alignment]u8 = @splat(0x11);
    const second: [byte_io_alignment]u8 = @splat(0x22);
    const writes = [_]storage_api.Write{
        .{ .bytes = &first, .offset = 0 },
        .{ .bytes = &second, .offset = byte_io_alignment },
    };

    const invalid = [_]storage_api.Write{
        writes[0],
        .{ .bytes = &second, .offset = 1024 * 1024 },
    };
    try std.testing.expectError(error.InvalidPoolDataIo, device.writeAllManyAt(&invalid));
    for (&probes) |*probe| try std.testing.expectEqual(@as(u32, 0), probe.batch_calls.load(.monotonic));

    try device.writeAllManyAt(&writes);
    for (&probes) |*probe| {
        try std.testing.expectEqual(@as(u32, 1), probe.batch_calls.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 0), probe.single_calls.load(.monotonic));
        try std.testing.expectEqual(@as(u32, writes.len), probe.write_count.load(.monotonic));
    }
    const metrics = device.pipelineMetrics();
    try std.testing.expectEqual(@as(u64, 2 * byte_io_alignment), metrics.direct_program_bytes);
    try std.testing.expectEqual(@as(u64, 2 * byte_io_alignment * max_replica_count), metrics.backing_write_bytes);

    probes[2].fail_batch = true;
    try std.testing.expectError(error.InjectedFault, device.writeAllManyAt(&writes));
    try std.testing.expect(device.isWriteFrozen());
    for (&probes) |*probe| try std.testing.expectEqual(@as(u32, 2), probe.batch_calls.load(.monotonic));
    try std.testing.expectError(error.WriteFrozen, device.writeAllManyAt(&writes));
}

test "replicated reads require two matching members" {
    const member_api = @import("member.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storages: [3]member_api.Storage = undefined;
    for (&storages, 0..) |*storage, index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "member-{d}", .{index});
        storage.* = try member_api.Storage.createFile(std.testing.io, tmp.dir, name, 4 * 1024 * 1024);
    }
    const outcome = try @import("pool_provision.zig").create(
        std.testing.io,
        std.testing.allocator,
        &storages,
        .{ .protection = .replicated, .label = "block-device" },
    );
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.PartialPoolCreation,
    };
    defer provisioned.deinit();
    var members: [3]*member_api.Member = undefined;
    for (&members, 0..) |*member, index| member.* = &provisioned.members[index];
    var replicas: [3]ReplicaEndpoint = undefined;
    for (&replicas, members) |*replica, member| replica.* = member.asReplicaEndpoint();
    const header = try container.Header.init(std.testing.io, 1024 * 1024, "Pool");
    var device = try PoolBlockDevice.init(std.testing.io, &replicas, provisioned.genesis.layout, header);
    try std.testing.expect(try device.canInitializeVolume(std.testing.allocator));
    try provisioned.members[0].writeDurable(.data, 0, "existing");
    try std.testing.expect(!try device.canInitializeVolume(std.testing.allocator));
    try provisioned.members[0].writeDurable(.data, 0, &@as([8]u8, @splat(0)));
    try std.testing.expect(try device.canInitializeVolume(std.testing.allocator));
    try provisioned.members[0].writeDurable(.metadata, container.header_a_offset, &header.encode());
    try std.testing.expect(try device.canInitializeVolume(std.testing.allocator));
    var ready_header = header;
    ready_header.state = .ready;
    try provisioned.members[0].writeDurable(.metadata, container.header_a_offset, &ready_header.encode());
    try std.testing.expect(!try device.canInitializeVolume(std.testing.allocator));
    try provisioned.members[1].writeDurable(.metadata, container.header_a_offset, &header.encode());
    try provisioned.members[2].writeDurable(.metadata, container.header_a_offset, &header.encode());
    try std.testing.expect(!try device.canInitializeVolume(std.testing.allocator));
    try std.testing.expectEqualSlices(u8, &volumeIdentity(ready_header), &volumeIdentity(try device.readHeader()));
    try device.prepareWritableReplicas(std.testing.allocator);
    for (provisioned.members) |*member| {
        try member.writeDurable(.metadata, container.header_a_offset, &ready_header.encode());
        try member.writeDurable(.metadata, container.header_b_offset, &ready_header.encode());
    }
    try device.program(0, 0, "replicated");
    try device.program(0, 128, "offset");
    try device.sync();
    var newer_header = ready_header;
    newer_header.sequence += 1;
    try provisioned.members[2].writeDurable(.metadata, container.header_a_offset, &newer_header.encode());
    try device.prepareWritableReplicas(std.testing.allocator);
    var divergent_header = newer_header;
    divergent_header.uuid[0] ^= 1;
    try provisioned.members[2].writeDurable(.metadata, container.header_a_offset, &divergent_header.encode());
    try provisioned.members[2].writeDurable(.metadata, container.header_b_offset, &divergent_header.encode());
    try std.testing.expectError(error.ReplicaHeaderDivergence, device.prepareWritableReplicas(std.testing.allocator));
    try provisioned.members[2].writeDurable(.metadata, container.header_a_offset, &ready_header.encode());
    try provisioned.members[2].writeDurable(.metadata, container.header_b_offset, &ready_header.encode());
    var fault: member_api.FaultController = .{ .fail_write_at = 0 };
    provisioned.members[2].setFaultController(&fault);
    try std.testing.expectError(error.InjectedFault, device.program(1, 0, "failed-write"));
    try std.testing.expect(device.isWriteFrozen());
    try std.testing.expectError(error.WriteFrozen, device.program(2, 0, "frozen"));
    var failed_write_actual: [12]u8 = undefined;
    try device.read(1, 0, &failed_write_actual);
    try std.testing.expectEqualStrings("failed-write", &failed_write_actual);
    try provisioned.members[0].writeDurable(.data, 0, "corruption");
    var actual: [10]u8 = undefined;
    try device.read(0, 0, &actual);
    try std.testing.expectEqualStrings("replicated", &actual);
    var offset_actual: [6]u8 = undefined;
    try device.read(0, 128, &offset_actual);
    try std.testing.expectEqualStrings("offset", &offset_actual);
    try std.testing.expectError(error.ReplicaDivergence, device.prepareWritableReplicas(std.testing.allocator));
    var sync_device = try PoolBlockDevice.init(std.testing.io, &replicas, provisioned.genesis.layout, ready_header);
    try sync_device.sync();
    try std.testing.expect(!sync_device.isWriteFrozen());
    sync_device.dirty.store(true, .release);
    try std.testing.expectError(error.WriteFrozen, sync_device.sync());
    try std.testing.expect(sync_device.isWriteFrozen());
}
