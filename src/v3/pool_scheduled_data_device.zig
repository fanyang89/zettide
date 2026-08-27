const std = @import("std");
const pool_blob_schedule = @import("pool_blob_schedule.zig");
const ReplicaEndpoint = @import("replica_endpoint.zig").ReplicaEndpoint;
const storage_api = @import("storage.zig");

pub const minimum_io_size: u32 = 4096;
pub const max_read_count: usize = 32;
pub const max_read_size: usize = 1024 * 1024;
pub const max_write_count: usize = 32;
pub const max_write_size: usize = 1024 * 1024;
pub const max_span_count: usize = 64;

pub const ReadPolicy = enum {
    first_available,
    quorum,
};

pub const Options = struct {
    read_policy: ReadPolicy = .first_available,
    read_path_metrics: ?*ReadPathMetrics = null,
};

pub const ReadPathMetrics = struct {
    single_operation_batches: std.atomic.Value(u64) = .init(0),
    single_operation_items: std.atomic.Value(u64) = .init(0),
    multi_operation_batches: std.atomic.Value(u64) = .init(0),
    multi_operation_count: std.atomic.Value(u64) = .init(0),
    multi_operation_items: std.atomic.Value(u64) = .init(0),
    async_submit_attempts: std.atomic.Value(u64) = .init(0),
    async_submitted: std.atomic.Value(u64) = .init(0),
    async_fallbacks: std.atomic.Value(u64) = .init(0),
    async_submit_errors: std.atomic.Value(u64) = .init(0),

    pub const Snapshot = struct {
        single_operation_batches: u64,
        single_operation_items: u64,
        multi_operation_batches: u64,
        multi_operation_count: u64,
        multi_operation_items: u64,
        async_submit_attempts: u64,
        async_submitted: u64,
        async_fallbacks: u64,
        async_submit_errors: u64,
    };

    pub fn snapshot(self: *const ReadPathMetrics) Snapshot {
        return .{
            .single_operation_batches = self.single_operation_batches.load(.monotonic),
            .single_operation_items = self.single_operation_items.load(.monotonic),
            .multi_operation_batches = self.multi_operation_batches.load(.monotonic),
            .multi_operation_count = self.multi_operation_count.load(.monotonic),
            .multi_operation_items = self.multi_operation_items.load(.monotonic),
            .async_submit_attempts = self.async_submit_attempts.load(.monotonic),
            .async_submitted = self.async_submitted.load(.monotonic),
            .async_fallbacks = self.async_fallbacks.load(.monotonic),
            .async_submit_errors = self.async_submit_errors.load(.monotonic),
        };
    }
};

pub const MemberEndpoint = struct {
    slot: u16,
    endpoint: ReplicaEndpoint,
};

const Member = struct {
    slot: u16,
    endpoint: ReplicaEndpoint,
};

const Operation = union(enum) {
    read: struct { offset: u64, buffer: []u8 },
    read_many: struct { reads: []const storage_api.Read, results: []storage_api.ReadResult },
    write_many: []const storage_api.Write,
    sync,
};

pub const Device = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: pool_blob_schedule.PlacementPlan,
    members: [pool_blob_schedule.max_member_count]Member,
    member_count: usize,
    logical_capacity: u64,
    read_policy: ReadPolicy,
    read_path_metrics: ?*ReadPathMetrics,
    mutex: std.Io.Mutex = .init,
    dirty_member_mask: u16 = 0,
    write_frozen: std.atomic.Value(bool) = .init(false),
    read_sequence: std.atomic.Value(usize) = .init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        endpoints: []const MemberEndpoint,
        plan: pool_blob_schedule.PlacementPlan,
    ) !Device {
        return initOptions(allocator, io, endpoints, plan, .{});
    }

    pub fn initOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        endpoints: []const MemberEndpoint,
        plan: pool_blob_schedule.PlacementPlan,
        options: Options,
    ) !Device {
        try pool_blob_schedule.validate(plan);
        if (endpoints.len > plan.member_count or endpoints.len + 1 < plan.member_count)
            return error.EndpointSetMismatch;

        var device: Device = .{
            .allocator = allocator,
            .io = io,
            .plan = plan,
            .members = undefined,
            .member_count = endpoints.len,
            .logical_capacity = std.math.mul(u64, plan.logical_stripe_count, plan.stripe_size) catch
                return error.CapacityOverflow,
            .read_policy = options.read_policy,
            .read_path_metrics = options.read_path_metrics,
        };
        for (endpoints, 0..) |candidate, member_index| {
            for (endpoints[0..member_index]) |previous|
                if (previous.slot == candidate.slot) return error.DuplicateEndpointSlot;
            var matching: ?pool_blob_schedule.Entry = null;
            for (plan.memberSlice()) |entry| {
                if (candidate.slot == entry.slot) matching = entry;
            }
            const entry = matching orelse return error.ExtraEndpointSlot;
            const required = std.math.mul(u64, entry.assigned_stripes, plan.stripe_size) catch
                return error.MemberCapacityOverflow;
            if (candidate.endpoint.geometry.data_length < required) return error.TruncatedMemberData;
            device.members[member_index] = .{ .slot = candidate.slot, .endpoint = candidate.endpoint };
        }
        return device;
    }

    pub fn capacity(self: *const Device) u64 {
        return self.logical_capacity;
    }

    pub fn isWriteFrozen(self: *const Device) bool {
        return self.write_frozen.load(.acquire);
    }

    pub fn readAt(self: *Device, buffer: []u8, offset: u64) !usize {
        try self.validateRange(offset, buffer.len);
        var processed: usize = 0;
        while (processed < buffer.len) {
            const span_len = self.spanLength(offset + processed, buffer.len - processed);
            try self.readSpan(buffer[processed..][0..span_len], offset + processed);
            processed += span_len;
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
        for (reads) |read| try self.validateRange(read.offset, read.buffer.len);
        var index: usize = 0;
        while (index < reads.len) {
            var batch_count: usize = 0;
            var batch_bytes: usize = 0;
            while (index + batch_count < reads.len and batch_count < max_read_count) {
                const read = reads[index + batch_count];
                if (self.spanLength(read.offset, read.buffer.len) != read.buffer.len or
                    read.buffer.len > max_read_size - batch_bytes) break;
                batch_bytes += read.buffer.len;
                batch_count += 1;
            }
            if (batch_count != 0) {
                self.readBatch(
                    reads[index..][0..batch_count],
                    results[index..][0..batch_count],
                ) catch |err| {
                    for (results[index..][0..batch_count]) |*result| result.failure = err;
                };
                index += batch_count;
                continue;
            }
            const read = reads[index];
            results[index].amount = self.readAt(read.buffer, read.offset) catch |err| {
                results[index].failure = err;
                index += 1;
                continue;
            };
            index += 1;
        }
    }

    pub fn writeAllAt(self: *Device, bytes: []const u8, offset: u64) !void {
        return self.writeAllManyAt(&.{.{ .bytes = bytes, .offset = offset }});
    }

    pub fn writeAllManyAt(self: *Device, writes: []const storage_api.Write) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (self.member_count != self.plan.member_count) return error.DegradedDeviceReadOnly;
        if (writes.len > max_write_count) return error.BatchTooLarge;

        var member_writes: [pool_blob_schedule.max_member_count][max_span_count]storage_api.Write = undefined;
        var member_write_counts: [pool_blob_schedule.max_member_count]usize = @splat(0);
        var span_count: usize = 0;
        for (writes) |write| {
            if (write.bytes.len > max_write_size) return error.WriteTooLarge;
            try self.validateRange(write.offset, write.bytes.len);
            var processed: usize = 0;
            while (processed < write.bytes.len) {
                if (span_count == max_span_count) return error.BatchTooLarge;
                const logical_offset = write.offset + processed;
                const span_len = self.spanLength(logical_offset, write.bytes.len - processed);
                const locations = try pool_blob_schedule.mapValidated(&self.plan, logical_offset / self.plan.stripe_size);
                for (locations) |location| {
                    const member_index = self.memberIndex(location.slot) orelse unreachable;
                    const count = member_write_counts[member_index];
                    member_writes[member_index][count] = .{
                        .bytes = write.bytes[processed..][0..span_len],
                        .offset = try self.physicalOffset(location, logical_offset % self.plan.stripe_size),
                    };
                    member_write_counts[member_index] = count + 1;
                }
                span_count += 1;
                processed += span_len;
            }
        }
        if (span_count == 0) return;

        var operations: [pool_blob_schedule.max_member_count]Operation = undefined;
        var operation_members: [pool_blob_schedule.max_member_count]usize = undefined;
        var errors: [pool_blob_schedule.max_member_count]?anyerror = @splat(null);
        var operation_count: usize = 0;
        var touched_mask: u16 = 0;
        for (member_write_counts, 0..) |count, member_index| {
            if (count == 0) continue;
            operations[operation_count] = .{ .write_many = member_writes[member_index][0..count] };
            operation_members[operation_count] = member_index;
            touched_mask |= @as(u16, 1) << @intCast(member_index);
            operation_count += 1;
        }
        self.runOperations(
            operations[0..operation_count],
            operation_members[0..operation_count],
            errors[0..operation_count],
        ) catch |err| {
            self.freezeWrites();
            return err;
        };
        if (firstError(errors[0..operation_count])) |err| {
            self.freezeWrites();
            return err;
        }
        self.dirty_member_mask |= touched_mask;
    }

    pub fn sync(self: *Device) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.isWriteFrozen()) return error.WriteFrozen;
        if (self.dirty_member_mask == 0) return;

        var operations: [pool_blob_schedule.max_member_count]Operation = undefined;
        var operation_members: [pool_blob_schedule.max_member_count]usize = undefined;
        var errors: [pool_blob_schedule.max_member_count]?anyerror = @splat(null);
        var operation_count: usize = 0;
        for (0..self.member_count) |member_index| {
            if (self.dirty_member_mask & (@as(u16, 1) << @intCast(member_index)) == 0) continue;
            operations[operation_count] = .sync;
            operation_members[operation_count] = member_index;
            operation_count += 1;
        }
        self.runOperations(
            operations[0..operation_count],
            operation_members[0..operation_count],
            errors[0..operation_count],
        ) catch |err| {
            self.freezeWrites();
            return err;
        };
        if (firstError(errors[0..operation_count])) |err| {
            self.freezeWrites();
            return err;
        }
        self.dirty_member_mask = 0;
    }

    fn readSpan(self: *Device, output: []u8, logical_offset: u64) !void {
        return switch (self.read_policy) {
            .first_available => self.readSpanFirstAvailable(output, logical_offset),
            .quorum => self.readSpanQuorum(output, logical_offset),
        };
    }

    fn readSpanFirstAvailable(self: *Device, output: []u8, logical_offset: u64) !void {
        const locations = try pool_blob_schedule.mapValidated(&self.plan, logical_offset / self.plan.stripe_size);
        const preferred_lane = self.read_sequence.fetchAdd(1, .monotonic) % pool_blob_schedule.replica_count;
        var last_error: anyerror = error.ReplicaUnavailable;
        for (0..pool_blob_schedule.replica_count) |attempt| {
            const lane = (preferred_lane + attempt) % pool_blob_schedule.replica_count;
            const location = locations[lane];
            const member_index = self.memberIndex(location.slot) orelse continue;
            self.members[member_index].endpoint.readData(
                try self.physicalOffset(location, logical_offset % self.plan.stripe_size),
                output,
            ) catch |err| {
                last_error = err;
                continue;
            };
            return;
        }
        return last_error;
    }

    fn readSpanQuorum(self: *Device, output: []u8, logical_offset: u64) !void {
        const locations = try pool_blob_schedule.mapValidated(&self.plan, logical_offset / self.plan.stripe_size);
        const allocation_len = std.math.mul(usize, output.len, pool_blob_schedule.replica_count) catch
            return error.OutOfMemory;
        const copies = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(minimum_io_size),
            allocation_len,
        );
        defer self.allocator.free(copies);
        var operations: [pool_blob_schedule.replica_count]Operation = undefined;
        var operation_members: [pool_blob_schedule.replica_count]usize = undefined;
        var errors: [pool_blob_schedule.replica_count]?anyerror = @splat(null);
        var operation_count: usize = 0;
        var lanes: [pool_blob_schedule.replica_count]u8 = undefined;
        for (locations, 0..) |location, lane| {
            const member_index = self.memberIndex(location.slot) orelse continue;
            operation_members[operation_count] = member_index;
            lanes[operation_count] = @intCast(lane);
            operations[operation_count] = .{ .read = .{
                .offset = try self.physicalOffset(location, logical_offset % self.plan.stripe_size),
                .buffer = copies[lane * output.len ..][0..output.len],
            } };
            operation_count += 1;
        }
        const available_count = operation_count;
        const first_count = @min(operation_count, 2);
        self.runOperations(
            operations[0..first_count],
            operation_members[0..first_count],
            errors[0..first_count],
        ) catch
            return error.ReplicaQuorumUnavailable;
        if (first_count == 2 and errors[0] == null and errors[1] == null and std.mem.eql(
            u8,
            copies[@as(usize, lanes[0]) * output.len ..][0..output.len],
            copies[@as(usize, lanes[1]) * output.len ..][0..output.len],
        )) {
            @memcpy(output, copies[@as(usize, lanes[0]) * output.len ..][0..output.len]);
            return;
        }
        if (available_count > first_count) {
            self.runOperations(
                operations[first_count..available_count],
                operation_members[first_count..available_count],
                errors[first_count..available_count],
            ) catch return error.ReplicaQuorumUnavailable;
        }
        for (0..available_count) |left| {
            if (errors[left] != null) continue;
            for (left + 1..available_count) |right| {
                if (errors[right] != null or !std.mem.eql(
                    u8,
                    copies[@as(usize, lanes[left]) * output.len ..][0..output.len],
                    copies[@as(usize, lanes[right]) * output.len ..][0..output.len],
                )) continue;
                @memcpy(output, copies[@as(usize, lanes[left]) * output.len ..][0..output.len]);
                return;
            }
        }
        return if (available_count == pool_blob_schedule.replica_count and
            firstError(errors[0..available_count]) == null)
            error.ReplicaDivergence
        else
            error.ReplicaQuorumUnavailable;
    }

    fn readBatch(
        self: *Device,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
    ) !void {
        return switch (self.read_policy) {
            .first_available => self.readBatchFirstAvailable(reads, results),
            .quorum => self.readBatchQuorum(reads, results),
        };
    }

    fn readBatchFirstAvailable(
        self: *Device,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
    ) !void {
        std.debug.assert(reads.len == results.len and reads.len <= max_read_count);
        const Target = struct { request: u8 };
        const preferred_lane = self.read_sequence.fetchAdd(1, .monotonic) % pool_blob_schedule.replica_count;
        var available_counts: [max_read_count]u8 = @splat(0);
        var available_lanes: [max_read_count][pool_blob_schedule.replica_count]u8 = undefined;
        var request_locations: [max_read_count][pool_blob_schedule.replica_count]pool_blob_schedule.Location = undefined;
        var attempts: [max_read_count]u8 = @splat(0);
        var resolved: [max_read_count]bool = @splat(false);
        var last_errors: [max_read_count]anyerror = @splat(error.ReplicaUnavailable);
        for (reads, 0..) |read, request_index| {
            const locations = try pool_blob_schedule.mapValidated(&self.plan, read.offset / self.plan.stripe_size);
            request_locations[request_index] = locations;
            for (0..pool_blob_schedule.replica_count) |attempt| {
                const lane = (preferred_lane + attempt) % pool_blob_schedule.replica_count;
                const location = locations[lane];
                if (self.memberIndex(location.slot) == null) continue;
                available_lanes[request_index][available_counts[request_index]] = @intCast(lane);
                available_counts[request_index] += 1;
            }
        }

        while (true) {
            var member_reads: [pool_blob_schedule.max_member_count][max_read_count]storage_api.Read = undefined;
            var member_results: [pool_blob_schedule.max_member_count][max_read_count]storage_api.ReadResult = undefined;
            var member_targets: [pool_blob_schedule.max_member_count][max_read_count]Target = undefined;
            var member_read_counts: [pool_blob_schedule.max_member_count]usize = @splat(0);
            var pending_count: usize = 0;
            for (reads, 0..) |read, request_index| {
                if (resolved[request_index] or attempts[request_index] >= available_counts[request_index]) continue;
                const lane: usize = available_lanes[request_index][attempts[request_index]];
                attempts[request_index] += 1;
                const location = request_locations[request_index][lane];
                const member_index = self.memberIndex(location.slot).?;
                const member_read_index = member_read_counts[member_index];
                member_reads[member_index][member_read_index] = .{
                    .buffer = read.buffer,
                    .offset = try self.physicalOffset(location, read.offset % self.plan.stripe_size),
                };
                member_results[member_index][member_read_index] = .{};
                member_targets[member_index][member_read_index] = .{ .request = @intCast(request_index) };
                member_read_counts[member_index] += 1;
                pending_count += 1;
            }
            if (pending_count == 0) break;

            var operations: [pool_blob_schedule.max_member_count]Operation = undefined;
            var operation_members: [pool_blob_schedule.max_member_count]usize = undefined;
            var errors: [pool_blob_schedule.max_member_count]?anyerror = @splat(null);
            var operation_count: usize = 0;
            for (member_read_counts, 0..) |count, member_index| {
                if (count == 0) continue;
                operations[operation_count] = .{ .read_many = .{
                    .reads = member_reads[member_index][0..count],
                    .results = member_results[member_index][0..count],
                } };
                operation_members[operation_count] = member_index;
                operation_count += 1;
            }
            self.runOperations(
                operations[0..operation_count],
                operation_members[0..operation_count],
                errors[0..operation_count],
            ) catch |err| {
                for (operation_members[0..operation_count]) |member_index| {
                    for (member_targets[member_index][0..member_read_counts[member_index]]) |target|
                        last_errors[target.request] = err;
                }
                continue;
            };

            for (operation_members[0..operation_count], errors[0..operation_count]) |member_index, operation_error| {
                for (
                    member_results[member_index][0..member_read_counts[member_index]],
                    member_targets[member_index][0..member_read_counts[member_index]],
                ) |endpoint_result, target| {
                    const request_index: usize = target.request;
                    if (operation_error) |err| {
                        last_errors[request_index] = err;
                    } else if (endpoint_result.failure) |err| {
                        last_errors[request_index] = err;
                    } else if (endpoint_result.amount != reads[request_index].buffer.len) {
                        last_errors[request_index] = error.TruncatedMember;
                    } else {
                        resolved[request_index] = true;
                        results[request_index].amount = endpoint_result.amount;
                    }
                }
            }
        }
        for (results, resolved[0..reads.len], last_errors[0..reads.len]) |*result, success, err| {
            if (!success) result.failure = err;
        }
    }

    fn readBatchQuorum(
        self: *Device,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
    ) !void {
        std.debug.assert(reads.len == results.len and reads.len <= max_read_count);
        var total_bytes: usize = 0;
        for (reads) |read| total_bytes = std.math.add(usize, total_bytes, read.buffer.len) catch
            return error.OutOfMemory;
        const allocation_len = std.math.mul(usize, total_bytes, pool_blob_schedule.replica_count) catch
            return error.OutOfMemory;
        const copies = try self.allocator.alignedAlloc(
            u8,
            .fromByteUnits(minimum_io_size),
            allocation_len,
        );
        defer self.allocator.free(copies);

        const Target = struct { request: u8, lane: u8 };
        var member_reads: [pool_blob_schedule.max_member_count][max_read_count]storage_api.Read = undefined;
        var member_results: [pool_blob_schedule.max_member_count][max_read_count]storage_api.ReadResult = undefined;
        var member_targets: [pool_blob_schedule.max_member_count][max_read_count]Target = undefined;
        var member_read_counts: [pool_blob_schedule.max_member_count]usize = @splat(0);
        var request_offsets: [max_read_count]usize = undefined;
        var available_counts: [max_read_count]u8 = @splat(0);
        var available_lanes: [max_read_count][pool_blob_schedule.replica_count]u8 = undefined;
        var copy_offset: usize = 0;
        for (reads, 0..) |read, request_index| {
            request_offsets[request_index] = copy_offset;
            const locations = try pool_blob_schedule.mapValidated(&self.plan, read.offset / self.plan.stripe_size);
            for (locations, 0..) |location, lane| {
                if (self.memberIndex(location.slot) == null) continue;
                available_lanes[request_index][available_counts[request_index]] = @intCast(lane);
                available_counts[request_index] += 1;
            }
            for (available_lanes[request_index][0..@min(available_counts[request_index], 2)]) |lane_u8| {
                const lane: usize = lane_u8;
                const location = locations[lane];
                const member_index = self.memberIndex(location.slot).?;
                const member_read_index = member_read_counts[member_index];
                member_reads[member_index][member_read_index] = .{
                    .buffer = copies[copy_offset + lane * read.buffer.len ..][0..read.buffer.len],
                    .offset = try self.physicalOffset(location, read.offset % self.plan.stripe_size),
                };
                member_results[member_index][member_read_index] = .{};
                member_targets[member_index][member_read_index] = .{
                    .request = @intCast(request_index),
                    .lane = @intCast(lane),
                };
                member_read_counts[member_index] += 1;
            }
            copy_offset += read.buffer.len * pool_blob_schedule.replica_count;
        }

        var operations: [pool_blob_schedule.max_member_count]Operation = undefined;
        var operation_members: [pool_blob_schedule.max_member_count]usize = undefined;
        var errors: [pool_blob_schedule.max_member_count]?anyerror = @splat(null);
        var operation_count: usize = 0;
        for (member_read_counts, 0..) |count, member_index| {
            if (count == 0) continue;
            operations[operation_count] = .{ .read_many = .{
                .reads = member_reads[member_index][0..count],
                .results = member_results[member_index][0..count],
            } };
            operation_members[operation_count] = member_index;
            operation_count += 1;
        }
        self.runOperations(
            operations[0..operation_count],
            operation_members[0..operation_count],
            errors[0..operation_count],
        ) catch {
            for (results) |*result| result.failure = error.ReplicaQuorumUnavailable;
            return;
        };

        var successful: [max_read_count][pool_blob_schedule.replica_count]bool =
            @splat(@splat(false));
        for (operation_members[0..operation_count], errors[0..operation_count]) |member_index, operation_error| {
            if (operation_error != null) continue;
            for (
                member_results[member_index][0..member_read_counts[member_index]],
                member_targets[member_index][0..member_read_counts[member_index]],
            ) |endpoint_result, target| {
                const request_index: usize = target.request;
                if (endpoint_result.failure == null and endpoint_result.amount == reads[request_index].buffer.len)
                    successful[request_index][target.lane] = true;
            }
        }

        var resolved: [max_read_count]bool = @splat(false);
        for (reads, results, 0..) |read, *result, request_index| {
            const base = request_offsets[request_index];
            const first_count = @min(available_counts[request_index], 2);
            if (first_count == 2) {
                const left: usize = available_lanes[request_index][0];
                const right: usize = available_lanes[request_index][1];
                if (successful[request_index][left] and successful[request_index][right] and std.mem.eql(
                    u8,
                    copies[base + left * read.buffer.len ..][0..read.buffer.len],
                    copies[base + right * read.buffer.len ..][0..read.buffer.len],
                )) {
                    @memcpy(read.buffer, copies[base + left * read.buffer.len ..][0..read.buffer.len]);
                    result.amount = read.buffer.len;
                    resolved[request_index] = true;
                }
            }
        }

        member_read_counts = @splat(0);
        for (reads, 0..) |read, request_index| {
            if (resolved[request_index] or available_counts[request_index] < 3) continue;
            const lane: usize = available_lanes[request_index][2];
            const locations = try pool_blob_schedule.mapValidated(&self.plan, read.offset / self.plan.stripe_size);
            const location = locations[lane];
            const member_index = self.memberIndex(location.slot).?;
            const member_read_index = member_read_counts[member_index];
            member_reads[member_index][member_read_index] = .{
                .buffer = copies[request_offsets[request_index] + lane * read.buffer.len ..][0..read.buffer.len],
                .offset = try self.physicalOffset(location, read.offset % self.plan.stripe_size),
            };
            member_results[member_index][member_read_index] = .{};
            member_targets[member_index][member_read_index] = .{
                .request = @intCast(request_index),
                .lane = @intCast(lane),
            };
            member_read_counts[member_index] += 1;
        }

        errors = @splat(null);
        operation_count = 0;
        for (member_read_counts, 0..) |count, member_index| {
            if (count == 0) continue;
            operations[operation_count] = .{ .read_many = .{
                .reads = member_reads[member_index][0..count],
                .results = member_results[member_index][0..count],
            } };
            operation_members[operation_count] = member_index;
            operation_count += 1;
        }
        self.runOperations(
            operations[0..operation_count],
            operation_members[0..operation_count],
            errors[0..operation_count],
        ) catch {
            for (results, resolved[0..reads.len]) |*result, is_resolved| {
                if (!is_resolved) result.failure = error.ReplicaQuorumUnavailable;
            }
            return;
        };
        for (operation_members[0..operation_count], errors[0..operation_count]) |member_index, operation_error| {
            if (operation_error != null) continue;
            for (
                member_results[member_index][0..member_read_counts[member_index]],
                member_targets[member_index][0..member_read_counts[member_index]],
            ) |endpoint_result, target| {
                const request_index: usize = target.request;
                if (endpoint_result.failure == null and endpoint_result.amount == reads[request_index].buffer.len)
                    successful[request_index][target.lane] = true;
            }
        }

        for (reads, results, resolved[0..reads.len], 0..) |read, *result, is_resolved, request_index| {
            if (is_resolved) continue;
            const base = request_offsets[request_index];
            var successful_count: u8 = 0;
            for (successful[request_index]) |value| successful_count += @intFromBool(value);
            for (0..pool_blob_schedule.replica_count) |left| {
                if (!successful[request_index][left]) continue;
                for (left + 1..pool_blob_schedule.replica_count) |right| {
                    if (successful[request_index][right] and std.mem.eql(
                        u8,
                        copies[base + left * read.buffer.len ..][0..read.buffer.len],
                        copies[base + right * read.buffer.len ..][0..read.buffer.len],
                    )) {
                        @memcpy(read.buffer, copies[base + left * read.buffer.len ..][0..read.buffer.len]);
                        result.amount = read.buffer.len;
                        break;
                    }
                } else continue;
                break;
            } else {
                result.failure = if (available_counts[request_index] == pool_blob_schedule.replica_count and
                    successful_count == pool_blob_schedule.replica_count)
                    error.ReplicaDivergence
                else
                    error.ReplicaQuorumUnavailable;
            }
        }
    }

    fn validateRange(self: *const Device, offset: u64, len: usize) !void {
        if (len == 0 or offset % minimum_io_size != 0 or len % minimum_io_size != 0 or
            offset > self.logical_capacity or len > self.logical_capacity - offset)
            return error.InvalidPoolDataIo;
    }

    fn spanLength(self: *const Device, offset: u64, remaining: usize) usize {
        const within_stripe: usize = @intCast(offset % self.plan.stripe_size);
        return @min(remaining, @as(usize, self.plan.stripe_size) - within_stripe);
    }

    fn physicalOffset(
        self: *const Device,
        location: pool_blob_schedule.Location,
        within_stripe: u64,
    ) !u64 {
        const stripe_offset = std.math.mul(u64, location.physical_stripe, self.plan.stripe_size) catch
            return error.PhysicalOffsetOverflow;
        return std.math.add(u64, stripe_offset, within_stripe) catch error.PhysicalOffsetOverflow;
    }

    fn memberIndex(self: *const Device, slot: u16) ?usize {
        for (self.members[0..self.member_count], 0..) |member, index|
            if (member.slot == slot) return index;
        return null;
    }

    fn runOperations(
        self: *Device,
        operations: []const Operation,
        member_indexes: []const usize,
        errors: []?anyerror,
    ) !void {
        std.debug.assert(operations.len == member_indexes.len and operations.len == errors.len);
        if (operations.len == 1) {
            if (self.read_path_metrics) |metrics| {
                const item_count = readItemCount(operations[0]);
                if (item_count != 0) {
                    _ = metrics.single_operation_batches.fetchAdd(1, .monotonic);
                    _ = metrics.single_operation_items.fetchAdd(item_count, .monotonic);
                }
            }
            switch (operations[0]) {
                .read, .read_many => return self.runReadOperations(operations, member_indexes, errors),
                else => {},
            }
            runOperation(self.members[member_indexes[0]].endpoint, operations[0], &errors[0]);
            return;
        }
        var all_reads = true;
        for (operations) |operation| switch (operation) {
            .read, .read_many => {},
            else => all_reads = false,
        };
        if (all_reads) {
            if (self.read_path_metrics) |metrics| {
                var item_count: u64 = 0;
                for (operations) |operation| item_count += readItemCount(operation);
                _ = metrics.multi_operation_batches.fetchAdd(1, .monotonic);
                _ = metrics.multi_operation_count.fetchAdd(@intCast(operations.len), .monotonic);
                _ = metrics.multi_operation_items.fetchAdd(item_count, .monotonic);
            }
            return self.runReadOperations(operations, member_indexes, errors);
        }
        return self.runConcurrentOperations(operations, member_indexes, errors);
    }

    fn runConcurrentOperations(
        self: *Device,
        operations: []const Operation,
        member_indexes: []const usize,
        errors: []?anyerror,
    ) !void {
        var group: std.Io.Group = .init;
        defer group.cancel(self.io);
        var first_spawn_error: ?anyerror = null;
        for (operations, member_indexes, errors) |operation, member_index, *result| {
            const endpoint = self.members[member_index].endpoint;
            group.concurrent(self.io, runOperation, .{ endpoint, operation, result }) catch |err| {
                if (first_spawn_error == null) first_spawn_error = err;
                runOperation(endpoint, operation, result);
            };
        }
        group.await(self.io) catch |err| if (first_spawn_error == null) {
            first_spawn_error = err;
        };
        if (first_spawn_error) |err| return err;
    }

    fn runReadOperations(
        self: *Device,
        operations: []const Operation,
        member_indexes: []const usize,
        errors: []?anyerror,
    ) !void {
        const State = struct {
            io: std.Io,
            event: std.Io.Event = .unset,
            failure: ?anyerror = null,
            submitted: bool = false,
            singleton_read: [1]storage_api.Read = undefined,
            singleton_result: [1]storage_api.ReadResult = undefined,

            fn complete(context: *anyopaque, failure: ?anyerror) void {
                const state: *@This() = @ptrCast(@alignCast(context));
                state.failure = failure;
                state.event.set(state.io);
            }
        };
        std.debug.assert(operations.len <= pool_blob_schedule.max_member_count);
        var states: [pool_blob_schedule.max_member_count]State = undefined;
        var fallback: [pool_blob_schedule.max_member_count]bool = @splat(false);
        for (operations, member_indexes, errors, states[0..operations.len], fallback[0..operations.len]) |
            operation,
            member_index,
            *result,
            *state,
            *use_fallback,
        | {
            result.* = null;
            state.* = .{ .io = self.io };
            const endpoint = self.members[member_index].endpoint;
            if (self.read_path_metrics) |metrics|
                _ = metrics.async_submit_attempts.fetchAdd(1, .monotonic);
            const submit = switch (operation) {
                .read => |read| submit: {
                    state.singleton_read[0] = .{ .buffer = read.buffer, .offset = read.offset };
                    state.singleton_result[0] = .{};
                    break :submit endpoint.submitReadDataMany(
                        &state.singleton_read,
                        &state.singleton_result,
                        .{ .context = state, .complete = State.complete },
                    );
                },
                .read_many => |batch| endpoint.submitReadDataMany(
                    batch.reads,
                    batch.results,
                    .{ .context = state, .complete = State.complete },
                ),
                else => unreachable,
            } catch |err| {
                if (self.read_path_metrics) |metrics|
                    _ = metrics.async_submit_errors.fetchAdd(1, .monotonic);
                result.* = err;
                continue;
            };
            if (submit == .submitted) {
                if (self.read_path_metrics) |metrics|
                    _ = metrics.async_submitted.fetchAdd(1, .monotonic);
                state.submitted = true;
            } else {
                if (self.read_path_metrics) |metrics|
                    _ = metrics.async_fallbacks.fetchAdd(1, .monotonic);
                use_fallback.* = true;
            }
        }

        var fallback_operations: [pool_blob_schedule.max_member_count]Operation = undefined;
        var fallback_members: [pool_blob_schedule.max_member_count]usize = undefined;
        var fallback_errors: [pool_blob_schedule.max_member_count]?anyerror = @splat(null);
        var fallback_indexes: [pool_blob_schedule.max_member_count]usize = undefined;
        var fallback_count: usize = 0;
        for (operations, member_indexes, fallback[0..operations.len], 0..) |operation, member_index, use_fallback, index| {
            if (!use_fallback) continue;
            fallback_operations[fallback_count] = operation;
            fallback_members[fallback_count] = member_index;
            fallback_indexes[fallback_count] = index;
            fallback_count += 1;
        }
        var fallback_run_error: ?anyerror = null;
        if (fallback_count != 0) {
            self.runConcurrentOperations(
                fallback_operations[0..fallback_count],
                fallback_members[0..fallback_count],
                fallback_errors[0..fallback_count],
            ) catch |err| {
                fallback_run_error = err;
            };
            if (fallback_run_error == null) {
                for (fallback_indexes[0..fallback_count], fallback_errors[0..fallback_count]) |index, failure|
                    errors[index] = failure;
            }
        }
        for (operations, errors, states[0..operations.len]) |operation, *result, *state| {
            if (!state.submitted) continue;
            state.event.waitUncancelable(self.io);
            if (state.failure) |err| {
                result.* = err;
                continue;
            }
            switch (operation) {
                .read => |read| {
                    const read_result = state.singleton_result[0];
                    result.* = read_result.failure orelse if (read_result.amount != read.buffer.len)
                        error.TruncatedMember
                    else
                        null;
                },
                .read_many => {},
                else => unreachable,
            }
        }
        if (fallback_run_error) |err| return err;
    }

    fn freezeWrites(self: *Device) void {
        self.write_frozen.store(true, .release);
    }
};

fn readItemCount(operation: Operation) u64 {
    return switch (operation) {
        .read => 1,
        .read_many => |batch| @intCast(batch.reads.len),
        else => 0,
    };
}

fn runOperation(endpoint: ReplicaEndpoint, operation: Operation, result: *?anyerror) void {
    result.* = null;
    (switch (operation) {
        .read => |read| endpoint.readData(read.offset, read.buffer),
        .read_many => |batch| endpoint.readDataMany(batch.reads, batch.results),
        .write_many => |writes| endpoint.writeDataMany(writes),
        .sync => endpoint.sync(),
    }) catch |err| {
        result.* = err;
    };
}

fn firstError(errors: []const ?anyerror) ?anyerror {
    for (errors) |maybe_error| if (maybe_error) |err| return err;
    return null;
}

const TestEndpoint = struct {
    bytes: []u8,
    read_calls: std.atomic.Value(usize) = .init(0),
    read_batch_calls: std.atomic.Value(usize) = .init(0),
    read_batch_items: std.atomic.Value(usize) = .init(0),
    async_submit_calls: std.atomic.Value(usize) = .init(0),
    write_calls: std.atomic.Value(usize) = .init(0),
    write_batch_calls: std.atomic.Value(usize) = .init(0),
    sync_calls: std.atomic.Value(usize) = .init(0),
    fail_read: bool = false,
    fail_read_batch: bool = false,
    fail_read_offset: ?u64 = null,
    short_read: bool = false,
    short_read_offset: ?u64 = null,
    fail_write: bool = false,
    fail_sync: bool = false,
    supports_async_reads: bool = false,

    fn readMetadata(_: *anyopaque, _: u64, _: []u8) !void {}

    fn readData(context: *anyopaque, offset: u64, buffer: []u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self.read_calls.fetchAdd(1, .monotonic);
        if (self.fail_read) return error.InjectedReadFault;
        const start = std.math.cast(usize, offset) orelse return error.OutOfBounds;
        if (start > self.bytes.len or buffer.len > self.bytes.len - start) return error.OutOfBounds;
        @memcpy(buffer, self.bytes[start..][0..buffer.len]);
    }

    fn readDataMany(
        context: *anyopaque,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
    ) !void {
        if (reads.len != results.len) return error.InvalidReadBatch;
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self.read_batch_calls.fetchAdd(1, .monotonic);
        _ = self.read_batch_items.fetchAdd(reads.len, .monotonic);
        if (self.fail_read_batch) return error.InjectedBatchReadFault;
        for (results) |*result| result.* = .{};
        for (reads, results) |read, *result| {
            if (self.fail_read or self.fail_read_offset == read.offset) {
                result.failure = error.InjectedReadFault;
                continue;
            }
            const start = std.math.cast(usize, read.offset) orelse {
                result.failure = error.OutOfBounds;
                continue;
            };
            if (start > self.bytes.len or read.buffer.len > self.bytes.len - start) {
                result.failure = error.OutOfBounds;
                continue;
            }
            @memcpy(read.buffer, self.bytes[start..][0..read.buffer.len]);
            result.amount = if (self.short_read or self.short_read_offset == read.offset)
                read.buffer.len - minimum_io_size
            else
                read.buffer.len;
        }
    }

    fn submitReadDataMany(
        context: *anyopaque,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
        completion: storage_api.AsyncReadCompletion,
    ) !storage_api.AsyncReadSubmit {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!self.supports_async_reads) return .unsupported;
        _ = self.async_submit_calls.fetchAdd(1, .monotonic);
        var failure: ?anyerror = null;
        readDataMany(context, reads, results) catch |err| {
            failure = err;
        };
        completion.complete(completion.context, failure);
        return .submitted;
    }

    fn writeData(context: *anyopaque, offset: u64, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self.write_calls.fetchAdd(1, .monotonic);
        if (self.fail_write) return error.InjectedWriteFault;
        const start = std.math.cast(usize, offset) orelse return error.OutOfBounds;
        if (start > self.bytes.len or bytes.len > self.bytes.len - start) return error.OutOfBounds;
        @memcpy(self.bytes[start..][0..bytes.len], bytes);
    }

    fn writeDataMany(context: *anyopaque, writes: []const storage_api.Write) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self.write_batch_calls.fetchAdd(1, .monotonic);
        for (writes) |write| try writeData(context, write.offset, write.bytes);
    }

    fn writeMetadataDurable(_: *anyopaque, _: u64, _: []const u8) !void {}

    fn syncEndpoint(context: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        _ = self.sync_calls.fetchAdd(1, .monotonic);
        if (self.fail_sync) return error.InjectedSyncFault;
    }

    fn endpoint(self: *@This(), data_length: u64) ReplicaEndpoint {
        return .init(self, .{ .logical_capacity = data_length, .data_length = data_length }, &vtable);
    }

    const vtable: ReplicaEndpoint.VTable = .{
        .read_metadata = readMetadata,
        .read_data = readData,
        .read_data_many = readDataMany,
        .submit_read_data_many = submitReadDataMany,
        .write_data = writeData,
        .write_data_many = writeDataMany,
        .write_metadata_durable = writeMetadataDurable,
        .sync = syncEndpoint,
    };
};

fn testPlan(member_count: usize, stripe_size: u32, stripes: u64) !pool_blob_schedule.PlacementPlan {
    var geometries: [pool_blob_schedule.max_member_count]pool_blob_schedule.Geometry = undefined;
    for (geometries[0..member_count], 0..) |*geometry, index| geometry.* = .{
        .slot = @intCast(index * 2 + 1),
        .available_stripes = stripes,
    };
    return pool_blob_schedule.build(stripe_size, geometries[0..member_count], 17);
}

fn initTestEndpoints(
    allocator: std.mem.Allocator,
    contexts: []TestEndpoint,
    endpoints: []MemberEndpoint,
    plan: pool_blob_schedule.PlacementPlan,
) !void {
    for (contexts, endpoints, plan.memberSlice()) |*context, *endpoint, entry| {
        const data_length = try std.math.mul(u64, entry.assigned_stripes, plan.stripe_size);
        const bytes = try allocator.alloc(u8, @intCast(data_length));
        @memset(bytes, 0);
        context.* = .{ .bytes = bytes };
        endpoint.* = .{ .slot = entry.slot, .endpoint = context.endpoint(data_length) };
    }
}

fn deinitTestEndpoints(allocator: std.mem.Allocator, contexts: []TestEndpoint) void {
    for (contexts) |context| allocator.free(context.bytes);
}

fn resetTestReads(contexts: []TestEndpoint) void {
    for (contexts) |*context| {
        context.read_calls.store(0, .monotonic);
        context.read_batch_calls.store(0, .monotonic);
        context.read_batch_items.store(0, .monotonic);
        context.async_submit_calls.store(0, .monotonic);
        context.fail_read = false;
        context.fail_read_batch = false;
        context.fail_read_offset = null;
        context.short_read = false;
        context.short_read_offset = null;
    }
}

test "scheduled reads submit member batches asynchronously" {
    const plan = try testPlan(12, 4096, 4);
    var contexts: [12]TestEndpoint = undefined;
    var endpoints: [12]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    for (&contexts) |*context| context.supports_async_reads = true;
    var metrics: ReadPathMetrics = .{};
    var device = try Device.initOptions(
        std.testing.allocator,
        std.testing.io,
        &endpoints,
        plan,
        .{ .read_path_metrics = &metrics },
    );

    var buffers: [12][4096]u8 = undefined;
    var reads: [buffers.len]storage_api.Read = undefined;
    var results: [buffers.len]storage_api.ReadResult = undefined;
    for (&reads, &buffers, 0..) |*read, *buffer, index| read.* = .{
        .buffer = buffer,
        .offset = index * 4096,
    };
    try device.readManyAt(&reads, &results);
    var submit_count: usize = 0;
    for (&contexts) |*context| submit_count += context.async_submit_calls.load(.monotonic);
    try std.testing.expect(submit_count > 1);
    for (results) |result| {
        try std.testing.expectEqual(@as(?anyerror, null), result.failure);
        try std.testing.expectEqual(@as(usize, 4096), result.amount);
    }
    const snapshot = metrics.snapshot();
    try std.testing.expect(snapshot.multi_operation_batches != 0);
    try std.testing.expectEqual(@as(u64, @intCast(submit_count)), snapshot.multi_operation_count);
    try std.testing.expectEqual(@as(u64, @intCast(reads.len)), snapshot.multi_operation_items);
    try std.testing.expectEqual(@as(u64, @intCast(submit_count)), snapshot.async_submit_attempts);
    try std.testing.expectEqual(@as(u64, @intCast(submit_count)), snapshot.async_submitted);
    try std.testing.expectEqual(@as(u64, 0), snapshot.async_fallbacks);
    try std.testing.expectEqual(@as(u64, 0), snapshot.async_submit_errors);
}

fn totalBatchItems(contexts: []TestEndpoint) usize {
    var total: usize = 0;
    for (contexts) |*context| total += context.read_batch_items.load(.monotonic);
    return total;
}

fn mappedBytes(
    device: *Device,
    contexts: []TestEndpoint,
    logical_stripe: u64,
    lane: usize,
) []u8 {
    const location = pool_blob_schedule.map(device.plan, logical_stripe) catch unreachable;
    const member_index = device.memberIndex(location[lane].slot).?;
    const start: usize = @intCast(location[lane].physical_stripe * device.plan.stripe_size);
    return contexts[member_index].bytes[start..][0..device.plan.stripe_size];
}

test "scheduled device validates endpoints, heterogeneous bounds, and large capacity" {
    const plan = try testPlan(12, 4096, 3);
    var contexts: [12]TestEndpoint = undefined;
    var endpoints: [12]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);

    const device = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    try std.testing.expectEqual(@as(u64, 12 * 4096), device.capacity());
    var duplicate = endpoints;
    duplicate[1].slot = duplicate[0].slot;
    try std.testing.expectError(
        error.DuplicateEndpointSlot,
        Device.init(std.testing.allocator, std.testing.io, &duplicate, plan),
    );
    var truncated = endpoints;
    truncated[5].endpoint.geometry.data_length -= 1;
    try std.testing.expectError(
        error.TruncatedMemberData,
        Device.init(std.testing.allocator, std.testing.io, &truncated, plan),
    );

    var heterogeneous_geometries: [12]pool_blob_schedule.Geometry = undefined;
    for (&heterogeneous_geometries, 0..) |*geometry, index| geometry.* = .{
        .slot = @intCast(index + 20),
        .available_stripes = if (index < 6) 4 else 2,
    };
    const heterogeneous_plan = try pool_blob_schedule.build(4096, &heterogeneous_geometries, 3);
    var heterogeneous_contexts: [12]TestEndpoint = undefined;
    var heterogeneous_endpoints: [12]MemberEndpoint = undefined;
    try initTestEndpoints(
        std.testing.allocator,
        &heterogeneous_contexts,
        &heterogeneous_endpoints,
        heterogeneous_plan,
    );
    defer deinitTestEndpoints(std.testing.allocator, &heterogeneous_contexts);
    const heterogeneous = try Device.init(
        std.testing.allocator,
        std.testing.io,
        &heterogeneous_endpoints,
        heterogeneous_plan,
    );
    try std.testing.expectEqual(@as(u64, 12 * 4096), heterogeneous.capacity());

    const huge_stripes = (@as(u64, 16) * 1024 * 1024 * 1024 * 1024) / 4096 + 1;
    const huge_plan = try testPlan(3, 4096, huge_stripes);
    var tiny_contexts: [3]TestEndpoint = undefined;
    var huge_endpoints: [3]MemberEndpoint = undefined;
    for (&tiny_contexts, &huge_endpoints, huge_plan.memberSlice()) |*context, *endpoint, entry| {
        context.* = .{ .bytes = &.{} };
        endpoint.* = .{
            .slot = entry.slot,
            .endpoint = context.endpoint(entry.assigned_stripes * huge_plan.stripe_size),
        };
    }
    const huge = try Device.init(std.testing.allocator, std.testing.io, &huge_endpoints, huge_plan);
    try std.testing.expect(huge.capacity() > 16 * 1024 * 1024 * 1024 * 1024);
    _ = try pool_blob_schedule.map(huge_plan, huge_plan.logical_stripe_count - 1);
}

test "scheduled writes cross stripes, keep three copies, and batch by member" {
    const plan = try testPlan(12, 8192, 4);
    var contexts: [12]TestEndpoint = undefined;
    var endpoints: [12]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);

    var input: [3 * 4096]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index);
    const writes = [_]storage_api.Write{
        .{ .bytes = input[0..4096], .offset = 4096 },
        .{ .bytes = input[4096..], .offset = 8192 },
    };
    try device.writeAllManyAt(&writes);
    var total_writes: usize = 0;
    var touched_members: usize = 0;
    for (&contexts) |*context| {
        const calls = context.write_calls.load(.monotonic);
        total_writes += calls;
        if (calls != 0) {
            touched_members += 1;
            try std.testing.expectEqual(@as(usize, 1), context.write_batch_calls.load(.monotonic));
        }
    }
    try std.testing.expectEqual(@as(usize, 6), total_writes);
    try std.testing.expect(touched_members >= 3);
    for (0..3) |logical_stripe| {
        const expected = if (logical_stripe == 0)
            input[0..4096]
        else if (logical_stripe == 1)
            input[4096..][0..8192]
        else
            input[0..0];
        if (expected.len == 0) continue;
        const offset: usize = if (logical_stripe == 0) 4096 else 0;
        for (0..3) |lane| try std.testing.expectEqualSlices(
            u8,
            expected,
            mappedBytes(&device, &contexts, logical_stripe, lane)[offset..][0..expected.len],
        );
    }
    var output: [3 * 4096]u8 = undefined;
    try std.testing.expectEqual(output.len, try device.readAt(&output, 4096));
    try std.testing.expectEqualSlices(u8, &input, &output);
}

test "scheduled readMany batches requests by physical member" {
    const plan = try testPlan(12, 4096, 32);
    var contexts: [12]TestEndpoint = undefined;
    var endpoints: [12]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);

    var input: [max_read_count][4096]u8 = undefined;
    var output: [max_read_count][4096]u8 = undefined;
    var writes: [max_read_count]storage_api.Write = undefined;
    var reads: [max_read_count]storage_api.Read = undefined;
    for (&input, &output, &writes, &reads, 0..) |*source, *destination, *write, *read, index| {
        @memset(source, @intCast(index + 1));
        @memset(destination, 0);
        write.* = .{ .bytes = source, .offset = index * 4096 };
        read.* = .{ .buffer = destination, .offset = index * 4096 };
    }
    try device.writeAllManyAt(&writes);
    var results: [max_read_count]storage_api.ReadResult = undefined;
    try device.readManyAt(&reads, &results);

    var total_batch_items: usize = 0;
    for (&contexts) |*context| {
        const items = context.read_batch_items.load(.monotonic);
        total_batch_items += items;
        try std.testing.expectEqual(@as(usize, 0), context.read_calls.load(.monotonic));
        try std.testing.expectEqual(@intFromBool(items != 0), context.read_batch_calls.load(.monotonic));
    }
    try std.testing.expectEqual(max_read_count, total_batch_items);
    for (&input, &output, results) |*source, *destination, result| {
        try std.testing.expectEqual(@as(?anyerror, null), result.failure);
        try std.testing.expectEqual(@as(usize, 4096), result.amount);
        try std.testing.expectEqualSlices(u8, source, destination);
    }
}

test "scheduled first-available scalar reads rotate and fall back cyclically" {
    const plan = try testPlan(3, 4096, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    for (0..pool_blob_schedule.replica_count) |lane| @memset(mappedBytes(&device, &contexts, 0, lane), 0x5a);

    const locations = try pool_blob_schedule.map(plan, 0);
    var output: [4096]u8 = undefined;
    for (0..3) |_| _ = try device.readAt(&output, 0);
    try std.testing.expect(std.mem.allEqual(u8, &output, 0x5a));
    for (locations) |location| try std.testing.expectEqual(
        @as(usize, 1),
        contexts[device.memberIndex(location.slot).?].read_calls.load(.monotonic),
    );

    _ = try device.readAt(&output, 0);
    try std.testing.expectEqual(@as(usize, 2), contexts[device.memberIndex(locations[0].slot).?].read_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), contexts[device.memberIndex(locations[1].slot).?].read_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), contexts[device.memberIndex(locations[2].slot).?].read_calls.load(.monotonic));

    resetTestReads(&contexts);
    device.read_sequence.store(2, .monotonic);
    contexts[device.memberIndex(locations[2].slot).?].fail_read = true;
    _ = try device.readAt(&output, 0);
    try std.testing.expectEqual(@as(usize, 1), contexts[device.memberIndex(locations[2].slot).?].read_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), contexts[device.memberIndex(locations[0].slot).?].read_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), contexts[device.memberIndex(locations[1].slot).?].read_calls.load(.monotonic));

    for (&contexts) |*context| context.fail_read = true;
    try std.testing.expectError(error.InjectedReadFault, device.readAt(&output, 0));
}

test "scheduled first-available batches rotate while preserving member batch depth" {
    const plan = try testPlan(3, 4096, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    for (&contexts) |*context| context.supports_async_reads = true;
    var metrics: ReadPathMetrics = .{};
    var device = try Device.initOptions(
        std.testing.allocator,
        std.testing.io,
        &endpoints,
        plan,
        .{ .read_path_metrics = &metrics },
    );
    for (0..pool_blob_schedule.replica_count) |lane| @memset(mappedBytes(&device, &contexts, 0, lane), 0x6b);

    const locations = try pool_blob_schedule.map(plan, 0);
    var output: [2][4096]u8 = undefined;
    var results: [2]storage_api.ReadResult = undefined;
    const reads = [_]storage_api.Read{
        .{ .buffer = &output[0], .offset = 0 },
        .{ .buffer = &output[1], .offset = 0 },
    };
    for (1..5) |completed| {
        try device.readManyAt(&reads, &results);
        for (results) |result| {
            try std.testing.expectEqual(@as(?anyerror, null), result.failure);
            try std.testing.expectEqual(@as(usize, 4096), result.amount);
        }
        for (locations, 0..) |location, lane| {
            const expected_calls = (completed + 2 - lane) / pool_blob_schedule.replica_count;
            const context = &contexts[device.memberIndex(location.slot).?];
            try std.testing.expectEqual(expected_calls, context.read_batch_calls.load(.monotonic));
            try std.testing.expectEqual(expected_calls * reads.len, context.read_batch_items.load(.monotonic));
        }
    }
    for (&output) |*block| try std.testing.expect(std.mem.allEqual(u8, block, 0x6b));
    const snapshot = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 4), snapshot.single_operation_batches);
    try std.testing.expectEqual(@as(u64, 8), snapshot.single_operation_items);
    try std.testing.expectEqual(@as(u64, 0), snapshot.multi_operation_batches);
    try std.testing.expectEqual(@as(u64, 4), snapshot.async_submit_attempts);
    try std.testing.expectEqual(@as(u64, 4), snapshot.async_submitted);
    try std.testing.expectEqual(@as(u64, 0), snapshot.async_fallbacks);
}

test "scheduled first-available batch retries only failed and short reads" {
    const plan = try testPlan(3, 4096, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    for (0..2) |stripe| for (0..pool_blob_schedule.replica_count) |lane|
        @memset(mappedBytes(&device, &contexts, stripe, lane), @intCast(stripe + 1));

    var output: [2][4096]u8 = undefined;
    var results: [2]storage_api.ReadResult = undefined;
    const first_locations = try pool_blob_schedule.map(plan, 0);
    const first_member = device.memberIndex(first_locations[0].slot).?;
    contexts[first_member].fail_read_batch = true;
    try device.readManyAt(&.{.{ .buffer = &output[0], .offset = 0 }}, results[0..1]);
    try std.testing.expectEqual(@as(?anyerror, null), results[0].failure);
    try std.testing.expectEqual(@as(usize, 2), totalBatchItems(&contexts));

    resetTestReads(&contexts);
    device.read_sequence.store(0, .monotonic);
    const second_locations = try pool_blob_schedule.map(plan, 4096 / plan.stripe_size);
    const failed_location = first_locations[0];
    contexts[device.memberIndex(failed_location.slot).?].fail_read_offset =
        try device.physicalOffset(failed_location, 0);
    try device.readManyAt(&.{
        .{ .buffer = &output[0], .offset = 0 },
        .{ .buffer = &output[1], .offset = 4096 },
    }, &results);
    for (results) |result| try std.testing.expectEqual(@as(?anyerror, null), result.failure);
    try std.testing.expectEqual(@as(usize, 3), totalBatchItems(&contexts));
    try std.testing.expectEqual(@as(u8, 1), output[0][0]);
    try std.testing.expectEqual(@as(u8, 2), output[1][0]);

    resetTestReads(&contexts);
    device.read_sequence.store(0, .monotonic);
    contexts[device.memberIndex(second_locations[0].slot).?].short_read_offset =
        try device.physicalOffset(second_locations[0], 0);
    try device.readManyAt(&.{.{ .buffer = &output[1], .offset = 4096 }}, results[0..1]);
    try std.testing.expectEqual(@as(?anyerror, null), results[0].failure);
    try std.testing.expectEqual(@as(usize, 2), totalBatchItems(&contexts));

    resetTestReads(&contexts);
    device.read_sequence.store(0, .monotonic);
    for (&contexts) |*context| context.fail_read_batch = true;
    try device.readManyAt(&.{.{ .buffer = &output[0], .offset = 0 }}, results[0..1]);
    try std.testing.expectEqual(error.InjectedBatchReadFault, results[0].failure.?);
    try std.testing.expectEqual(@as(usize, pool_blob_schedule.replica_count), totalBatchItems(&contexts));
}

test "scheduled first-available degraded reads skip every missing lane" {
    const plan = try testPlan(3, 4096, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var full = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    for (0..pool_blob_schedule.replica_count) |lane| @memset(mappedBytes(&full, &contexts, 0, lane), 0x33);
    const locations = try pool_blob_schedule.map(plan, 0);
    var output: [4096]u8 = undefined;

    for (locations, 0..) |missing, missing_lane| {
        resetTestReads(&contexts);
        var available: [pool_blob_schedule.replica_count - 1]MemberEndpoint = undefined;
        var available_count: usize = 0;
        for (endpoints) |endpoint| {
            if (endpoint.slot == missing.slot) continue;
            available[available_count] = endpoint;
            available_count += 1;
        }
        var degraded = try Device.init(std.testing.allocator, std.testing.io, &available, plan);
        _ = try degraded.readAt(&output, 0);
        try std.testing.expect(std.mem.allEqual(u8, &output, 0x33));
        var total_calls: usize = 0;
        for (&contexts) |*context| total_calls += context.read_calls.load(.monotonic);
        try std.testing.expectEqual(@as(usize, 1), total_calls);
        const expected_scalar_lane: usize = if (missing_lane == 0) 1 else 0;
        try std.testing.expectEqual(
            @as(usize, 1),
            contexts[full.memberIndex(locations[expected_scalar_lane].slot).?].read_calls.load(.monotonic),
        );

        resetTestReads(&contexts);
        var result: [1]storage_api.ReadResult = undefined;
        try degraded.readManyAt(&.{.{ .buffer = &output, .offset = 0 }}, &result);
        try std.testing.expectEqual(@as(?anyerror, null), result[0].failure);
        try std.testing.expectEqual(@as(usize, output.len), result[0].amount);
        try std.testing.expectEqual(@as(usize, 1), totalBatchItems(&contexts));
        const expected_batch_lane: usize = if (missing_lane == 1) 2 else 1;
        try std.testing.expectEqual(
            @as(usize, 1),
            contexts[full.memberIndex(locations[expected_batch_lane].slot).?].read_batch_items.load(.monotonic),
        );
    }
}

test "scheduled reads select a matching pair and classify quorum failures" {
    const plan = try testPlan(3, 4096, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.initOptions(
        std.testing.allocator,
        std.testing.io,
        &endpoints,
        plan,
        .{ .read_policy = .quorum },
    );
    @memset(mappedBytes(&device, &contexts, 0, 0), 7);
    @memset(mappedBytes(&device, &contexts, 0, 1), 7);
    @memset(mappedBytes(&device, &contexts, 0, 2), 9);
    var output: [4096]u8 = undefined;
    _ = try device.readAt(&output, 0);
    try std.testing.expectEqual(@as(u8, 7), output[0]);
    try std.testing.expectEqual(@as(usize, 0), device.read_sequence.load(.monotonic));
    var total_read_calls: usize = 0;
    for (&contexts) |*context| total_read_calls += context.read_calls.load(.monotonic);
    try std.testing.expectEqual(@as(usize, 2), total_read_calls);
    const first_locations = try pool_blob_schedule.map(plan, 0);
    const third_member = device.memberIndex(first_locations[2].slot).?;
    try std.testing.expectEqual(@as(usize, 0), contexts[third_member].read_calls.load(.monotonic));

    @memset(mappedBytes(&device, &contexts, 0, 0), 1);
    @memset(mappedBytes(&device, &contexts, 0, 1), 2);
    @memset(mappedBytes(&device, &contexts, 0, 2), 1);
    _ = try device.readAt(&output, 0);
    try std.testing.expectEqual(@as(u8, 1), output[0]);
    @memset(mappedBytes(&device, &contexts, 0, 2), 2);
    _ = try device.readAt(&output, 0);
    try std.testing.expectEqual(@as(u8, 2), output[0]);

    @memset(mappedBytes(&device, &contexts, 1, 0), 4);
    @memset(mappedBytes(&device, &contexts, 1, 1), 5);
    @memset(mappedBytes(&device, &contexts, 1, 2), 6);
    var second_output: [4096]u8 = undefined;
    var batch_results: [2]storage_api.ReadResult = undefined;
    try device.readManyAt(&.{
        .{ .buffer = &output, .offset = 0 },
        .{ .buffer = &second_output, .offset = 4096 },
    }, &batch_results);
    try std.testing.expectEqual(@as(?anyerror, null), batch_results[0].failure);
    try std.testing.expectEqual(@as(usize, output.len), batch_results[0].amount);
    try std.testing.expectEqual(error.ReplicaDivergence, batch_results[1].failure.?);

    @memset(mappedBytes(&device, &contexts, 0, 0), 1);
    @memset(mappedBytes(&device, &contexts, 0, 1), 2);
    @memset(mappedBytes(&device, &contexts, 0, 2), 3);
    try std.testing.expectError(error.ReplicaDivergence, device.readAt(&output, 0));
    try device.readManyAt(&.{.{ .buffer = &output, .offset = 0 }}, batch_results[0..1]);
    try std.testing.expectEqual(error.ReplicaDivergence, batch_results[0].failure.?);
    contexts[device.memberIndex((try pool_blob_schedule.map(plan, 0))[0].slot).?].fail_read = true;
    try std.testing.expectError(error.ReplicaQuorumUnavailable, device.readAt(&output, 0));
    try device.readManyAt(&.{.{ .buffer = &output, .offset = 0 }}, batch_results[0..1]);
    try std.testing.expectEqual(error.ReplicaQuorumUnavailable, batch_results[0].failure.?);
    contexts[device.memberIndex((try pool_blob_schedule.map(plan, 0))[0].slot).?].fail_read = false;
    contexts[device.memberIndex((try pool_blob_schedule.map(plan, 0))[2].slot).?].short_read = true;
    try device.readManyAt(&.{.{ .buffer = &output, .offset = 0 }}, batch_results[0..1]);
    try std.testing.expectEqual(error.ReplicaQuorumUnavailable, batch_results[0].failure.?);
    try std.testing.expectEqual(@as(usize, 0), device.read_sequence.load(.monotonic));
}

test "scheduled readMany falls back for cross-stripe requests" {
    const plan = try testPlan(3, 8192, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.initOptions(
        std.testing.allocator,
        std.testing.io,
        &endpoints,
        plan,
        .{ .read_policy = .quorum },
    );
    var input: [8192]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index *% 19);
    try device.writeAllAt(&input, 4096);

    var output: [8192]u8 = undefined;
    var results: [1]storage_api.ReadResult = undefined;
    try device.readManyAt(&.{.{ .buffer = &output, .offset = 4096 }}, &results);
    try std.testing.expectEqual(@as(?anyerror, null), results[0].failure);
    try std.testing.expectEqualSlices(u8, &input, &output);
    var total_read_calls: usize = 0;
    for (&contexts) |*context| {
        total_read_calls += context.read_calls.load(.monotonic);
        try std.testing.expectEqual(@as(usize, 0), context.read_batch_calls.load(.monotonic));
    }
    try std.testing.expectEqual(@as(usize, 4), total_read_calls);
}

test "scheduled readMany submits fallback only for unresolved requests" {
    const plan = try testPlan(3, 4096, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.initOptions(
        std.testing.allocator,
        std.testing.io,
        &endpoints,
        plan,
        .{ .read_policy = .quorum },
    );

    @memset(mappedBytes(&device, &contexts, 0, 0), 7);
    @memset(mappedBytes(&device, &contexts, 0, 1), 7);
    @memset(mappedBytes(&device, &contexts, 0, 2), 9);
    @memset(mappedBytes(&device, &contexts, 1, 0), 3);
    @memset(mappedBytes(&device, &contexts, 1, 1), 4);
    @memset(mappedBytes(&device, &contexts, 1, 2), 4);

    var output: [2][4096]u8 = undefined;
    var results: [2]storage_api.ReadResult = undefined;
    try device.readManyAt(&.{
        .{ .buffer = &output[0], .offset = 0 },
        .{ .buffer = &output[1], .offset = 4096 },
    }, &results);
    try std.testing.expectEqual(@as(u8, 7), output[0][0]);
    try std.testing.expectEqual(@as(u8, 4), output[1][0]);
    for (results) |result| {
        try std.testing.expectEqual(@as(?anyerror, null), result.failure);
        try std.testing.expectEqual(@as(usize, 4096), result.amount);
    }

    var total_batch_items: usize = 0;
    for (&contexts) |*context| total_batch_items += context.read_batch_items.load(.monotonic);
    try std.testing.expectEqual(@as(usize, 5), total_batch_items);

    const second_third = (try pool_blob_schedule.map(plan, 1))[2];
    var expected_items: [3]usize = @splat(0);
    for (0..2) |logical_stripe| {
        const locations = try pool_blob_schedule.map(plan, logical_stripe);
        for (locations[0..2]) |location| expected_items[device.memberIndex(location.slot).?] += 1;
    }
    expected_items[device.memberIndex(second_third.slot).?] += 1;
    for (&contexts, expected_items) |*context, expected|
        try std.testing.expectEqual(expected, context.read_batch_items.load(.monotonic));
}

test "scheduled degraded reads require both remaining replicas and reject writes" {
    const plan = try testPlan(3, 4096, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var full = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    const locations = try pool_blob_schedule.map(plan, 0);
    var output: [4096]u8 = undefined;
    var input: [4096]u8 = @splat(7);

    for (locations) |missing| {
        for (0..pool_blob_schedule.replica_count) |lane| @memset(mappedBytes(&full, &contexts, 0, lane), 7);
        var available: [pool_blob_schedule.replica_count - 1]MemberEndpoint = undefined;
        var available_count: usize = 0;
        for (endpoints) |endpoint| {
            if (endpoint.slot == missing.slot) continue;
            available[available_count] = endpoint;
            available_count += 1;
        }
        var degraded = try Device.initOptions(
            std.testing.allocator,
            std.testing.io,
            &available,
            plan,
            .{ .read_policy = .quorum },
        );
        var read_results: [1]storage_api.ReadResult = undefined;
        try degraded.readManyAt(&.{.{ .buffer = &output, .offset = 0 }}, &read_results);
        try std.testing.expectEqual(@as(?anyerror, null), read_results[0].failure);
        try std.testing.expectEqual(@as(u8, 7), output[0]);
        try std.testing.expectError(error.DegradedDeviceReadOnly, degraded.writeAllAt(&input, 0));

        var value: u8 = 1;
        for (locations, 0..) |location, lane| {
            if (location.slot == missing.slot) continue;
            @memset(mappedBytes(&full, &contexts, 0, lane), value);
            value += 1;
        }
        try degraded.readManyAt(&.{.{ .buffer = &output, .offset = 0 }}, &read_results);
        try std.testing.expectEqual(error.ReplicaQuorumUnavailable, read_results[0].failure.?);
    }

    try std.testing.expectError(
        error.EndpointSetMismatch,
        Device.init(std.testing.allocator, std.testing.io, endpoints[0..1], plan),
    );
}

test "scheduled degraded reads preserve wide-plan slot mapping" {
    const plan = try testPlan(12, 4096, 3);
    var contexts: [12]TestEndpoint = undefined;
    var endpoints: [12]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var full = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    var output: [4096]u8 = undefined;

    for (endpoints) |missing| {
        var logical_stripe: u64 = 0;
        while (logical_stripe < plan.logical_stripe_count) : (logical_stripe += 1) {
            const locations = try pool_blob_schedule.map(plan, logical_stripe);
            var found = false;
            for (locations) |location| found = found or location.slot == missing.slot;
            if (found) break;
        }
        try std.testing.expect(logical_stripe < plan.logical_stripe_count);
        for (0..pool_blob_schedule.replica_count) |lane|
            @memset(mappedBytes(&full, &contexts, logical_stripe, lane), 0x5a);

        var available: [11]MemberEndpoint = undefined;
        var available_count: usize = 0;
        for (endpoints) |endpoint| {
            if (endpoint.slot == missing.slot) continue;
            available[available_count] = endpoint;
            available_count += 1;
        }
        var degraded = try Device.init(std.testing.allocator, std.testing.io, &available, plan);
        _ = try degraded.readAt(&output, logical_stripe * plan.stripe_size);
        try std.testing.expect(std.mem.allEqual(u8, &output, 0x5a));
    }
}

test "scheduled validation performs no IO and enforces batch span limit" {
    const plan = try testPlan(3, 4096, 128);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    var block: [4096]u8 = @splat(1);
    try std.testing.expectError(error.InvalidPoolDataIo, device.writeAllAt(&block, 1));
    var output: [4096]u8 = undefined;
    var reads = [_]storage_api.Read{
        .{ .buffer = &output, .offset = 0 },
        .{ .buffer = &output, .offset = device.capacity() },
    };
    var results: [2]storage_api.ReadResult = undefined;
    try std.testing.expectError(error.InvalidPoolDataIo, device.readManyAt(&reads, &results));
    var large: [65 * 4096]u8 = @splat(2);
    try std.testing.expectError(error.BatchTooLarge, device.writeAllAt(&large, 0));
    for (&contexts) |*context| {
        try std.testing.expectEqual(@as(usize, 0), context.read_calls.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 0), context.write_calls.load(.monotonic));
    }
}

test "scheduled write and sync failures freeze after all members finish" {
    const plan = try testPlan(3, 4096, 4);
    var contexts: [3]TestEndpoint = undefined;
    var endpoints: [3]MemberEndpoint = undefined;
    try initTestEndpoints(std.testing.allocator, &contexts, &endpoints, plan);
    defer deinitTestEndpoints(std.testing.allocator, &contexts);
    var device = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    contexts[0].fail_write = true;
    var block: [4096]u8 = @splat(4);
    try std.testing.expectError(error.InjectedWriteFault, device.writeAllAt(&block, 0));
    try std.testing.expect(device.isWriteFrozen());
    for (&contexts) |*context|
        try std.testing.expectEqual(@as(usize, 1), context.write_calls.load(.monotonic));
    try std.testing.expectError(error.WriteFrozen, device.sync());

    for (&contexts) |*context| {
        context.fail_write = false;
        context.write_calls.store(0, .monotonic);
    }
    var sync_device = try Device.init(std.testing.allocator, std.testing.io, &endpoints, plan);
    try sync_device.writeAllAt(&block, 0);
    contexts[1].fail_sync = true;
    try std.testing.expectError(error.InjectedSyncFault, sync_device.sync());
    try std.testing.expect(sync_device.isWriteFrozen());
    for (&contexts) |*context|
        try std.testing.expectEqual(@as(usize, 1), context.sync_calls.load(.monotonic));
}
