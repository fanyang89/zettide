const std = @import("std");
const blob_device = @import("blob_device.zig");
const format = @import("blob_format.zig");
const blob_map = @import("blob_map.zig");
const google_crc32c = @import("crc32c");
const storage_api = @import("v3/storage.zig");

const Io = std.Io;

const digest_cache_ways = 4;
const digest_cache_sets = 4096;
const digest_cache_entries = digest_cache_ways * digest_cache_sets;
const block_cache_ways = 4;
const block_cache_sets = 131_072;
const block_cache_entries = block_cache_ways * block_cache_sets;
const block_cache_shards = 64;
const block_cache_disabled = std.math.maxInt(usize);

const DigestCacheEntry = struct {
    slot: u64 = 0,
    digest: [32]u8 = @splat(0),
    valid: bool = false,
    bytes: [format.allocation_unit]u8 = undefined,
};

pub const CachedBlockMapping = union(enum) {
    miss,
    hole,
    present: format.BlobRef,
};

const BlockCacheEntry = struct {
    epoch: u64 = 0,
    root: blob_map.PageRef = undefined,
    generation: u64 = 0,
    readable_units: u64 = 0,
    block: u64 = 0,
    mapping: CachedBlockMapping = .miss,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    device: blob_device.Device,
    header: format.Header,
    headers: [2]?format.Header,
    selected_header: u1,
    sequence_floor: u64,
    staged_units: u64,
    mutex: Io.RwLock = .init,
    digest_cache_mutex: Io.RwLock = .init,
    digest_cache: ?[]DigestCacheEntry = null,
    digest_cache_next: usize = 0,
    block_cache_init_mutex: Io.Mutex = .init,
    block_cache_locks: [block_cache_shards]Io.RwLock = @splat(.init),
    block_cache_victims: [block_cache_shards]std.atomic.Value(usize) = @splat(.init(0)),
    block_cache_ptr: std.atomic.Value(usize) = .init(0),
    block_cache_epoch: std.atomic.Value(u64) = .init(1),
    frozen: bool = false,

    /// Takes ownership of device, including on failure.
    pub fn create(allocator: std.mem.Allocator, io: Io, device: blob_device.Device) !Store {
        var owned_device = device;
        errdefer owned_device.close(io) catch {};
        try validateAlignment(owned_device.alignment());
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
            .headers = .{ .{
                .sequence = 1,
                .uuid = header.uuid,
                .device_size = header.device_size,
                .unit_count = header.unit_count,
                .committed_units = 0,
                .authority_root = null,
            }, header },
            .selected_header = 1,
            .sequence_floor = header.sequence,
            .staged_units = header.committed_units,
        };
    }

    /// Takes ownership of device, including on failure.
    pub fn open(allocator: std.mem.Allocator, io: Io, device: blob_device.Device) !Store {
        var owned_device = device;
        errdefer owned_device.close(io) catch {};
        try validateAlignment(owned_device.alignment());
        const first = try readHeader(allocator, io, &owned_device, format.header_a_offset);
        const second = try readHeader(allocator, io, &owned_device, format.header_b_offset);
        const selected = try selectHeader(first, second, owned_device.capacity());
        return .{
            .allocator = allocator,
            .device = owned_device,
            .header = selected.header,
            .headers = selected.headers,
            .selected_header = selected.index,
            .sequence_floor = selected.sequence_floor,
            .staged_units = selected.header.committed_units,
        };
    }

    pub fn close(self: *Store, io: Io) !void {
        const allocator = self.allocator;
        const digest_cache = self.digest_cache;
        const block_cache_ptr = self.block_cache_ptr.load(.acquire);
        var device = self.device;
        self.* = undefined;
        if (digest_cache) |entries| allocator.free(entries);
        if (block_cache_ptr != 0 and block_cache_ptr != block_cache_disabled) {
            const entries: []BlockCacheEntry = @as([*]BlockCacheEntry, @ptrFromInt(block_cache_ptr))[0..block_cache_entries];
            allocator.free(entries);
        }
        try device.close(io);
    }

    pub fn committedUnits(self: *const Store) u64 {
        return self.header.committed_units;
    }

    pub fn stagedUnits(self: *const Store) u64 {
        return self.staged_units;
    }

    pub fn authorityRoot(self: *const Store) ?format.BlobRef {
        return self.header.authority_root;
    }

    pub fn authorityCandidates(self: *const Store) [2]?format.Header {
        return self.headers;
    }

    /// Selects a physical header after its application authority has been validated.
    pub fn selectAuthority(self: *Store, io: Io, candidate: format.Header) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.requireWritable();
        if (self.staged_units != self.header.committed_units) return error.BlobStoreHasStagedData;
        for (self.headers, 0..) |physical, index| {
            if (physical != null and std.meta.eql(physical.?, candidate)) {
                self.header = candidate;
                self.selected_header = @intCast(index);
                if (candidate.committed_units < self.staged_units) self.clearDigestCache(io);
                self.staged_units = candidate.committed_units;
                return;
            }
        }
        return error.UnknownBlobStoreAuthority;
    }

    pub fn discardStaged(self: *Store, io: Io, checkpoint: u64) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.requireWritable();
        if (checkpoint < self.header.committed_units or checkpoint > self.staged_units)
            return error.InvalidBlobStoreCheckpoint;
        if (checkpoint < self.staged_units) self.clearDigestCache(io);
        self.staged_units = checkpoint;
    }

    pub fn transportKind(self: *const Store) storage_api.TransportKind {
        return self.device.transportKind();
    }

    pub fn transportStats(self: *Store, io: Io) storage_api.TransportStats {
        return self.device.transportStats(io);
    }

    pub fn resetTransportStats(self: *Store, io: Io) void {
        self.device.resetTransportStats(io);
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
        var units: [blob_device.max_batch]u64 = undefined;
        var total_units: u64 = 0;
        for (inputs, units[0..inputs.len]) |input, *input_units| {
            if (input.len == 0) return error.EmptyBlob;
            if (input.len > format.blob_size) return error.BlobTooLarge;
            input_units.* = format.allocationUnits(input.len);
            total_units = std.math.add(u64, total_units, input_units.*) catch return error.BlobStoreFull;
        }
        if (total_units > self.header.unit_count - self.staged_units) return error.BlobStoreFull;

        var writes: [blob_device.max_batch]blob_device.Write = undefined;
        const alignment = self.device.alignment();
        const direct = for (inputs) |input| {
            if (input.len % alignment != 0 or @intFromPtr(input.ptr) % alignment != 0) break false;
        } else true;
        if (direct) {
            var next_unit = self.staged_units;
            for (inputs, references, writes[0..inputs.len], units[0..inputs.len]) |input, *reference, *write, input_units| {
                reference.* = .{
                    .slot = next_unit,
                    .valid_bytes = @intCast(input.len),
                    .checksums = format.payloadChecksums(input),
                };
                write.* = .{ .bytes = input, .offset = try format.slotOffset(next_unit) };
                next_unit += input_units;
            }
            self.device.writeAllManyAt(io, writes[0..inputs.len]) catch |err| {
                self.frozen = true;
                return err;
            };
            self.staged_units = next_unit;
            return;
        }

        const total_bytes = std.math.cast(usize, total_units * format.allocation_unit) orelse
            return error.OutOfMemory;
        const bytes = try self.allocator.alignedAlloc(u8, .fromByteUnits(format.allocation_unit), total_bytes);
        defer self.allocator.free(bytes);
        var next_unit = self.staged_units;
        var byte_offset: usize = 0;
        for (inputs, references, writes[0..inputs.len], units[0..inputs.len]) |input, *reference, *write, input_units| {
            const stored_bytes: usize = @intCast(input_units * format.allocation_unit);
            const payload = bytes[byte_offset..][0..stored_bytes];
            @memcpy(payload[0..input.len], input);
            @memset(payload[input.len..], 0);
            reference.* = .{
                .slot = next_unit,
                .valid_bytes = @intCast(input.len),
                .checksums = format.payloadChecksums(input),
            };
            write.* = .{ .bytes = payload, .offset = try format.slotOffset(next_unit) };
            next_unit += input_units;
            byte_offset += stored_bytes;
        }
        self.device.writeAllManyAt(io, writes[0..inputs.len]) catch |err| {
            self.frozen = true;
            return err;
        };
        self.staged_units = next_unit;
    }

    /// Reserves one slot but writes only an aligned digest-protected prefix.
    pub fn putDigestOnly(self: *Store, io: Io, data: []const u8) !u64 {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.requireWritable();
        const alignment = self.device.alignment();
        if (data.len == 0 or data.len > format.blob_size or data.len % alignment != 0)
            return error.InvalidDigestOnlyBlob;
        const units = format.allocationUnits(data.len);
        if (units > self.header.unit_count - self.staged_units) return error.BlobStoreFull;

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
        const slot = self.staged_units;
        self.device.writeAllAt(io, bytes, try format.slotOffset(slot)) catch |err| {
            self.frozen = true;
            return err;
        };
        self.staged_units += units;
        return slot;
    }

    /// Reads and verifies one complete slot. Returns the logical payload length.
    pub fn read(self: *Store, io: Io, reference: format.BlobRef, output: []u8) !usize {
        const reads = [_]Read{.{ .reference = reference, .output = output }};
        var results: [1]ReadResult = undefined;
        try self.readMany(io, &reads, &results);
        if (results[0].failure) |err| return err;
        return results[0].amount;
    }

    pub const Read = struct {
        reference: format.BlobRef,
        output: []u8,
    };

    pub const ReadResult = blob_device.ReadResult;

    pub fn readMany(self: *Store, io: Io, reads: []const Read, results: []ReadResult) !void {
        if (reads.len == 0 or reads.len != results.len or reads.len > blob_device.max_batch)
            return error.InvalidBlobBatch;
        try self.mutex.lockShared(io);
        defer self.mutex.unlockShared(io);
        if (self.frozen) return error.BlobStoreFrozen;
        var device_reads: [blob_device.max_batch]blob_device.Read = undefined;
        for (results) |*result| result.* = .{};
        for (reads, device_reads[0..reads.len]) |request, *device_read| {
            try request.reference.validate(self.header.unit_count);
            if (request.reference.endUnit() > self.staged_units) return error.UnpublishedBlobReference;
            const stored_bytes: usize = @intCast(format.storedBytes(request.reference.valid_bytes));
            if (request.output.len < stored_bytes) return error.InvalidBlobBuffer;
            device_read.* = .{
                .buffer = request.output[0..stored_bytes],
                .offset = try format.slotOffset(request.reference.slot),
            };
        }
        try self.device.readManyAt(io, device_reads[0..reads.len], results);
        for (reads, device_reads[0..reads.len], results) |request, device_read, *result| {
            if (result.failure != null) continue;
            if (result.amount != device_read.buffer.len) {
                result.failure = error.UnexpectedEndOfBlobDevice;
                continue;
            }
            if (!std.mem.eql(
                u32,
                &request.reference.checksums,
                &format.payloadChecksums(request.output[0..request.reference.valid_bytes]),
            )) {
                result.failure = error.BlobChecksumMismatch;
                continue;
            }
            @memset(request.output[request.reference.valid_bytes..], 0);
            result.amount = request.reference.valid_bytes;
        }
    }

    pub fn readDigestVerified(
        self: *Store,
        io: Io,
        slot: u64,
        valid_bytes: usize,
        expected_digest: *const [32]u8,
        output: []u8,
        cache: bool,
    ) !void {
        if (output.len != valid_bytes or valid_bytes == 0)
            return error.InvalidBlobBuffer;
        try self.mutex.lockShared(io);
        defer self.mutex.unlockShared(io);
        if (self.frozen) return error.BlobStoreFrozen;
        const units = format.allocationUnits(valid_bytes);
        if (slot > self.staged_units or units > self.staged_units - slot)
            return error.UnpublishedBlobReference;
        if (cache and valid_bytes == format.allocation_unit and
            self.readDigestCache(io, slot, expected_digest, output)) return;
        try self.device.readAt(io, output, try format.slotOffset(slot));
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(output, &digest, .{});
        if (!std.mem.eql(u8, &digest, expected_digest)) return error.BlobDigestMismatch;
        if (cache and valid_bytes == format.allocation_unit)
            self.writeDigestCache(io, slot, expected_digest, output);
    }

    fn readDigestCache(
        self: *Store,
        io: Io,
        slot: u64,
        digest: *const [32]u8,
        output: []u8,
    ) bool {
        self.digest_cache_mutex.lockSharedUncancelable(io);
        defer self.digest_cache_mutex.unlockShared(io);
        const entries = self.digest_cache orelse return false;
        const set = digestCacheSet(slot, digest);
        for (entries[set..][0..digest_cache_ways]) |*entry| {
            if (entry.valid and entry.slot == slot and std.mem.eql(u8, &entry.digest, digest)) {
                @memcpy(output, &entry.bytes);
                return true;
            }
        }
        return false;
    }

    fn writeDigestCache(
        self: *Store,
        io: Io,
        slot: u64,
        digest: *const [32]u8,
        bytes: []const u8,
    ) void {
        self.digest_cache_mutex.lockUncancelable(io);
        defer self.digest_cache_mutex.unlock(io);
        const entries = self.digest_cache orelse created: {
            const allocated = self.allocator.alloc(DigestCacheEntry, digest_cache_entries) catch return;
            for (allocated) |*entry| entry.* = .{};
            self.digest_cache = allocated;
            break :created allocated;
        };
        const set = digestCacheSet(slot, digest);
        var target: ?*DigestCacheEntry = null;
        for (entries[set..][0..digest_cache_ways]) |*entry| {
            if (entry.valid and entry.slot == slot and std.mem.eql(u8, &entry.digest, digest)) {
                target = entry;
                break;
            }
            if (!entry.valid) {
                target = entry;
                break;
            }
        }
        const selected = target orelse selected: {
            const entry = &entries[set + self.digest_cache_next % digest_cache_ways];
            self.digest_cache_next +%= 1;
            break :selected entry;
        };
        selected.* = .{
            .slot = slot,
            .digest = digest.*,
            .valid = true,
            .bytes = bytes[0..format.allocation_unit].*,
        };
    }

    fn clearDigestCache(self: *Store, io: Io) void {
        self.digest_cache_mutex.lockUncancelable(io);
        defer self.digest_cache_mutex.unlock(io);
        if (self.digest_cache) |entries| {
            for (entries) |*entry| entry.valid = false;
        }
        self.digest_cache_next = 0;
        self.clearBlockCache(io);
    }

    pub fn cachedBlockMapping(
        self: *Store,
        io: Io,
        root: blob_map.PageRef,
        generation: u64,
        readable_units: u64,
        block: u64,
    ) CachedBlockMapping {
        const entries = self.blockCacheEntries() orelse return .miss;
        const set = blockCacheSet(root, generation, readable_units, block);
        const shard = blockCacheShard(set);
        self.block_cache_locks[shard].lockSharedUncancelable(io);
        defer self.block_cache_locks[shard].unlockShared(io);
        const epoch = self.block_cache_epoch.load(.acquire);
        for (entries[set..][0..block_cache_ways]) |entry| {
            if (entry.epoch == epoch and entry.mapping != .miss and entry.generation == generation and
                entry.readable_units == readable_units and entry.block == block and
                std.meta.eql(entry.root, root))
            {
                const mapping = entry.mapping;
                return if (self.block_cache_epoch.load(.acquire) == epoch) mapping else .miss;
            }
        }
        return .miss;
    }

    pub fn blockCacheEpoch(self: *Store) u64 {
        return self.block_cache_epoch.load(.acquire);
    }

    pub fn cacheBlockMapping(
        self: *Store,
        io: Io,
        root: blob_map.PageRef,
        generation: u64,
        readable_units: u64,
        block: u64,
        reference: ?format.BlobRef,
        expected_epoch: u64,
    ) void {
        const entries = self.ensureBlockCache(io) orelse return;
        const set = blockCacheSet(root, generation, readable_units, block);
        const shard = blockCacheShard(set);
        self.block_cache_locks[shard].lockUncancelable(io);
        defer self.block_cache_locks[shard].unlock(io);
        const epoch = self.block_cache_epoch.load(.acquire);
        if (epoch != expected_epoch) return;
        var target: ?*BlockCacheEntry = null;
        for (entries[set..][0..block_cache_ways]) |*entry| {
            if (entry.epoch == epoch and entry.mapping != .miss and entry.generation == generation and
                entry.readable_units == readable_units and entry.block == block and
                std.meta.eql(entry.root, root))
            {
                target = entry;
                break;
            }
            if (entry.epoch != epoch or entry.mapping == .miss) {
                target = entry;
                break;
            }
        }
        const selected = target orelse &entries[set + self.block_cache_victims[shard].fetchAdd(1, .monotonic) % block_cache_ways];
        selected.* = .{
            .epoch = epoch,
            .root = root,
            .generation = generation,
            .readable_units = readable_units,
            .block = block,
            .mapping = if (reference) |value| .{ .present = value } else .hole,
        };
    }

    fn blockCacheEntries(self: *Store) ?[]BlockCacheEntry {
        const pointer = self.block_cache_ptr.load(.acquire);
        if (pointer == 0 or pointer == block_cache_disabled) return null;
        return @as([*]BlockCacheEntry, @ptrFromInt(pointer))[0..block_cache_entries];
    }

    fn ensureBlockCache(self: *Store, io: Io) ?[]BlockCacheEntry {
        if (self.blockCacheEntries()) |entries| return entries;
        if (self.block_cache_ptr.load(.acquire) == block_cache_disabled) return null;
        self.block_cache_init_mutex.lockUncancelable(io);
        defer self.block_cache_init_mutex.unlock(io);
        if (self.blockCacheEntries()) |entries| return entries;
        if (self.block_cache_ptr.load(.acquire) == block_cache_disabled) return null;
        const allocated = self.allocator.alloc(BlockCacheEntry, block_cache_entries) catch {
            self.block_cache_ptr.store(block_cache_disabled, .release);
            return null;
        };
        for (allocated) |*entry| entry.* = .{};
        self.block_cache_ptr.store(@intFromPtr(allocated.ptr), .release);
        return allocated;
    }

    fn clearBlockCache(self: *Store, io: Io) void {
        if (self.block_cache_epoch.fetchAdd(1, .acq_rel) != std.math.maxInt(u64)) return;
        for (&self.block_cache_locks) |*lock| lock.lockUncancelable(io);
        defer {
            var index = self.block_cache_locks.len;
            while (index != 0) {
                index -= 1;
                self.block_cache_locks[index].unlock(io);
            }
        }
        if (self.blockCacheEntries()) |entries| {
            for (entries) |*entry| entry.mapping = .miss;
        }
        self.block_cache_epoch.store(1, .release);
    }

    pub fn commit(self: *Store, io: Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.requireWritable();
        try self.commitLocked(io, self.header.authority_root);
    }

    pub fn commitAuthority(self: *Store, io: Io, authority_root: format.BlobRef) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.requireWritable();
        try authority_root.validate(self.header.unit_count);
        if (authority_root.endUnit() > self.staged_units) return error.UnpublishedBlobReference;
        try self.commitLocked(io, authority_root);
    }

    fn commitLocked(self: *Store, io: Io, authority_root: ?format.BlobRef) !void {
        if (self.staged_units == self.header.committed_units and
            std.meta.eql(authority_root, self.header.authority_root)) return;

        self.device.syncData(io) catch |err| {
            self.frozen = true;
            return err;
        };
        var next = self.header;
        next.sequence = std.math.add(u64, self.sequence_floor, 1) catch {
            self.frozen = true;
            return error.BlobStoreSequenceExhausted;
        };
        next.committed_units = self.staged_units;
        next.authority_root = authority_root;
        const target: u1 = self.selected_header ^ 1;
        const offset = if (target == 0) format.header_a_offset else format.header_b_offset;
        writeHeader(self.allocator, io, &self.device, offset, next) catch |err| {
            self.frozen = true;
            return err;
        };
        self.device.sync(io) catch |err| {
            self.frozen = true;
            return err;
        };
        self.header = next;
        self.headers[target] = next;
        self.selected_header = target;
        self.sequence_floor = next.sequence;
    }

    fn requireWritable(self: *const Store) !void {
        if (self.frozen) return error.BlobStoreFrozen;
    }
};

fn digestCacheSet(slot: u64, digest: *const [32]u8) usize {
    const hash = std.mem.readInt(u64, digest[0..8], .little) ^ slot;
    return @as(usize, @intCast(hash % digest_cache_sets)) * digest_cache_ways;
}

fn blockCacheSet(root: blob_map.PageRef, generation: u64, readable_units: u64, block: u64) usize {
    const digest = std.mem.readInt(u64, root.digest[0..8], .little);
    const hash = digest ^ root.page ^ generation ^ readable_units ^ block;
    return @as(usize, @intCast(hash % block_cache_sets)) * block_cache_ways;
}

fn blockCacheShard(set: usize) usize {
    return (set / block_cache_ways) % block_cache_shards;
}

fn validateAlignment(alignment: u32) !void {
    if (alignment > format.allocation_unit or format.allocation_unit % alignment != 0)
        return error.InvalidBlobStoreAlignment;
}

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
    return format.decodeHeader(@ptrCast(bytes.ptr)) catch |err| switch (err) {
        error.UnsupportedBlobStoreVersion => return err,
        else => null,
    };
}

const SelectedHeader = struct {
    header: format.Header,
    headers: [2]?format.Header,
    index: u1,
    sequence_floor: u64,
};

fn selectHeader(first: ?format.Header, second: ?format.Header, device_size: u64) !SelectedHeader {
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
    const selected_index: u1 = if (valid_first != null and
        (valid_second == null or valid_first.?.sequence > valid_second.?.sequence)) 0 else 1;
    const selected = if (selected_index == 0) valid_first.? else valid_second.?;
    return .{
        .header = selected,
        .headers = .{ valid_first, valid_second },
        .index = selected_index,
        .sequence_floor = @max(
            (valid_first orelse selected).sequence,
            (valid_second orelse selected).sequence,
        ),
    };
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
    try std.testing.expectEqual(@as(u64, 0), store.committedUnits());
    try std.testing.expectEqual(@as(u64, 2), store.stagedUnits());

    const output = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), format.blob_size);
    defer std.testing.allocator.free(output);
    const first_len = try store.read(std.testing.io, references[0], output);
    try std.testing.expectEqualStrings(inputs[0], output[0..first_len]);
    try store.commit(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), store.committedUnits());
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
    try std.testing.expectEqual(@as(u64, 2), store.committedUnits());
    const second_len = try store.read(std.testing.io, references[1], output);
    try std.testing.expectEqualStrings(inputs[1], output[0..second_len]);
}

test "blob store packs variable blobs into allocation units" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 8 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "variable-blob-store",
        device_size,
        format.allocation_unit,
    );
    var store = try Store.create(std.testing.allocator, std.testing.io, device);
    var store_open = true;
    defer if (store_open) store.close(std.testing.io) catch {};

    const crossing = try std.testing.allocator.alloc(u8, format.allocation_unit + 1);
    defer std.testing.allocator.free(crossing);
    @memset(crossing, 0x22);
    const checksum_sized = try std.testing.allocator.alloc(u8, format.checksum_unit);
    defer std.testing.allocator.free(checksum_sized);
    @memset(checksum_sized, 0x33);
    const inputs = [_][]const u8{ "x", crossing, checksum_sized };
    var references: [inputs.len]format.BlobRef = undefined;
    try store.putMany(std.testing.io, &inputs, &references);
    try std.testing.expectEqual(@as(u64, 0), references[0].slot);
    try std.testing.expectEqual(@as(u64, 1), references[1].slot);
    try std.testing.expectEqual(@as(u64, 3), references[2].slot);
    try std.testing.expectEqual(@as(u64, 19), store.stagedUnits());
    try store.commit(std.testing.io);
    try store.close(std.testing.io);
    store_open = false;

    const file = try tmp.dir.openFile(std.testing.io, "variable-blob-store", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = storage_api.Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, format.allocation_unit);
    file_open = false;
    store = try Store.open(std.testing.allocator, std.testing.io, reopened_device);
    store_open = true;
    try std.testing.expectEqual(@as(u64, 19), store.committedUnits());

    const output = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(format.allocation_unit), format.blob_size);
    defer std.testing.allocator.free(output);
    for (inputs, references) |expected, reference| {
        const amount = try store.read(std.testing.io, reference, output);
        try std.testing.expectEqual(expected.len, amount);
        try std.testing.expectEqualSlices(u8, expected, output[0..amount]);
        try std.testing.expect(std.mem.allEqual(u8, output[amount..], 0));
    }

    const batch_output = try std.testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(format.allocation_unit),
        inputs.len * format.blob_size,
    );
    defer std.testing.allocator.free(batch_output);
    @memset(batch_output, 0xff);
    var reads: [inputs.len]Store.Read = undefined;
    for (&reads, references, 0..) |*read_request, reference, index| read_request.* = .{
        .reference = reference,
        .output = batch_output[index * format.blob_size ..][0..format.blob_size],
    };
    var results: [inputs.len]Store.ReadResult = undefined;
    try store.readMany(std.testing.io, &reads, &results);
    for (inputs, reads, results) |expected, read_request, result| {
        try std.testing.expectEqual(@as(?anyerror, null), result.failure);
        try std.testing.expectEqual(expected.len, result.amount);
        try std.testing.expectEqualSlices(u8, expected, read_request.output[0..result.amount]);
        try std.testing.expect(std.mem.allEqual(u8, read_request.output[result.amount..], 0));
    }
}

test "blob store publishes and reselects application authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device_size = 8 * 1024 * 1024;
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "authority-store",
        device_size,
        format.allocation_unit,
    );
    var store = try Store.create(std.testing.allocator, std.testing.io, device);
    var store_open = true;
    defer if (store_open) store.close(std.testing.io) catch {};

    const first = try store.put(std.testing.io, "first root");
    try store.commitAuthority(std.testing.io, first);
    try std.testing.expectEqual(@as(u64, 3), store.header.sequence);
    try std.testing.expectEqualDeep(first, store.authorityRoot().?);

    const second = try store.put(std.testing.io, "second root");
    try store.commitAuthority(std.testing.io, second);
    try std.testing.expectEqual(@as(u64, 4), store.header.sequence);
    try store.close(std.testing.io);
    store_open = false;

    const file = try tmp.dir.openFile(std.testing.io, "authority-store", .{ .mode = .read_write });
    var file_open = true;
    defer if (file_open) file.close(std.testing.io);
    const storage = storage_api.Storage.initOwned(file, device_size, .regular_file, 1, false);
    const reopened_device = try blob_device.Device.init(storage, 0, device_size, format.allocation_unit);
    file_open = false;
    store = try Store.open(std.testing.allocator, std.testing.io, reopened_device);
    store_open = true;
    try std.testing.expectEqualDeep(second, store.authorityRoot().?);

    const candidates = store.authorityCandidates();
    const previous = if (candidates[0].?.sequence == 3) candidates[0].? else candidates[1].?;
    try store.selectAuthority(std.testing.io, previous);
    try std.testing.expectEqualDeep(first, store.authorityRoot().?);
    try std.testing.expectEqual(@as(u64, 1), store.stagedUnits());

    const recovered = try store.put(std.testing.io, "recovered root");
    try std.testing.expectEqual(second.slot, recovered.slot);
    try store.commitAuthority(std.testing.io, recovered);
    try std.testing.expectEqual(@as(u64, 5), store.header.sequence);
    try std.testing.expectEqualDeep(recovered, store.authorityRoot().?);
    const recovered_candidates = store.authorityCandidates();
    try std.testing.expectEqual(@as(u64, 3), recovered_candidates[0].?.sequence);
    try std.testing.expectEqualDeep(first, recovered_candidates[0].?.authority_root.?);
    try std.testing.expectEqual(@as(u64, 5), recovered_candidates[1].?.sequence);
}

test "blob store discards an unpublished tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "discard-store",
        4 * 1024 * 1024,
        format.allocation_unit,
    );
    var store = try Store.create(std.testing.allocator, std.testing.io, device);
    defer store.close(std.testing.io) catch {};

    const checkpoint = store.stagedUnits();
    const abandoned = try store.put(std.testing.io, "abandoned");
    try store.discardStaged(std.testing.io, checkpoint);
    const replacement = try store.put(std.testing.io, "replacement");
    try std.testing.expectEqual(abandoned.slot, replacement.slot);
    try std.testing.expect(!std.meta.eql(abandoned, replacement));
    try store.commit(std.testing.io);
    try std.testing.expectError(
        error.InvalidBlobStoreCheckpoint,
        store.discardStaged(std.testing.io, checkpoint),
    );

    const first_page: [format.allocation_unit]u8 = @splat(0x11);
    const second_page: [format.allocation_unit]u8 = @splat(0x22);
    var first_digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(&first_page, &first_digest, .{});
    const page_checkpoint = store.stagedUnits();
    const first_slot = try store.putDigestOnly(std.testing.io, &first_page);
    var output: [format.allocation_unit]u8 align(format.allocation_unit) = undefined;
    try store.readDigestVerified(std.testing.io, first_slot, output.len, &first_digest, &output, true);
    const root: blob_map.PageRef = .{
        .page = first_slot,
        .level = 0,
        .first_key = 7,
        .last_key = 7,
        .digest = first_digest,
    };
    const cached_reference: format.BlobRef = .{
        .slot = first_slot,
        .valid_bytes = format.allocation_unit,
        .checksums = @splat(0x1234),
    };
    store.cacheBlockMapping(
        std.testing.io,
        root,
        3,
        store.stagedUnits(),
        7,
        cached_reference,
        store.blockCacheEpoch(),
    );
    try std.testing.expectEqualDeep(
        CachedBlockMapping{ .present = cached_reference },
        store.cachedBlockMapping(std.testing.io, root, 3, store.stagedUnits(), 7),
    );
    try std.testing.expectEqualDeep(
        CachedBlockMapping.miss,
        store.cachedBlockMapping(std.testing.io, root, 4, store.stagedUnits(), 7),
    );
    try store.discardStaged(std.testing.io, page_checkpoint);
    try std.testing.expectEqualDeep(
        CachedBlockMapping.miss,
        store.cachedBlockMapping(std.testing.io, root, 3, first_slot + 1, 7),
    );
    const second_slot = try store.putDigestOnly(std.testing.io, &second_page);
    try std.testing.expectEqual(first_slot, second_slot);
    try std.testing.expectError(
        error.BlobDigestMismatch,
        store.readDigestVerified(std.testing.io, first_slot, output.len, &first_digest, &output, true),
    );
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
    try std.testing.expectError(error.EmptyBlob, store.put(std.testing.io, ""));
    const full_blob = try std.testing.allocator.alloc(u8, format.blob_size);
    defer std.testing.allocator.free(full_blob);
    @memset(full_blob, 0x5a);
    _ = try store.put(std.testing.io, full_blob);
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

test "blob store rejects device alignment larger than its allocation unit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const device = try blob_device.Device.createFile(
        std.testing.io,
        tmp.dir,
        "over-aligned-blob-store",
        8 * 1024 * 1024,
        2 * format.allocation_unit,
    );
    try std.testing.expectError(
        error.InvalidBlobStoreAlignment,
        Store.create(std.testing.allocator, std.testing.io, device),
    );
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
    try std.testing.expectEqual(@as(u64, 0), store.committedUnits());
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
