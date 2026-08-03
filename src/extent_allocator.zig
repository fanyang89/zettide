//! Shared extent claims coordinated by persistent claim gates and an index.

const std = @import("std");
const allocation = @import("allocation_format.zig");
const block = @import("conditional_block.zig");
const gate_format = @import("claim_gate_format.zig");
const index_format = @import("claim_index_format.zig");
const store = @import("store.zig");
const volume_format = @import("volume_format.zig");

pub const Options = struct {
    max_contention_retries: usize = 64,
};

pub const ClaimRequest = struct {
    kind: allocation.Kind,
    claim_id: [16]u8,
    owner_id: [16]u8,
    owner_incarnation: [16]u8,
    base_generation: u64,
    owner_epoch: u64,

    fn validate(self: ClaimRequest) !void {
        var value = self.entry(0, 1);
        value.extent_index = 0;
        try value.validate();
    }

    fn entry(self: ClaimRequest, extent_index: u64, claim_epoch: u64) allocation.Entry {
        return .{
            .state = .claimed,
            .kind = self.kind,
            .extent_index = extent_index,
            .claim_id = self.claim_id,
            .owner_id = self.owner_id,
            .owner_incarnation = self.owner_incarnation,
            .base_generation = self.base_generation,
            .owner_epoch = self.owner_epoch,
            .claim_epoch = claim_epoch,
        };
    }
};

pub const Claim = struct {
    volume_id: [16]u8,
    entry: allocation.Entry,

    pub fn extentIndex(self: Claim) u64 {
        return self.entry.extent_index;
    }
};

pub const PendingClaim = struct {
    volume_id: [16]u8,
    request: ClaimRequest,
};

pub const ClaimOutcome = union(enum) {
    claimed: Claim,
    pending: PendingClaim,
    exhausted,
};

pub const ClaimResolution = union(enum) {
    claimed: Claim,
    not_claimed,
    pending,
};

pub const PendingTransition = struct {
    operation: enum { entry, release } = .entry,
    volume_id: [16]u8,
    extent_index: u64,
    expected_page_generation: u64 = 0,
    expected: allocation.Entry,
    replacement: allocation.Entry,
};

pub const TransitionOutcome = union(enum) {
    completed,
    pending: PendingTransition,
};

pub const TransitionResolution = enum {
    completed,
    not_completed,
    pending,
};

pub const FormatResult = enum {
    formatted,
    already_formatted,
    pending,
};

pub const RecoveryResult = enum {
    completed,
    pending,
};

const PageSnapshot = struct {
    physical: store.OwnedBytes,
    view: allocation.View,

    fn deinit(self: *PageSnapshot) void {
        self.physical.deinit();
        self.* = undefined;
    }
};

const IndexSnapshot = struct {
    physical: store.OwnedBytes,
    view: index_format.View,

    fn deinit(self: *IndexSnapshot) void {
        self.physical.deinit();
        self.* = undefined;
    }
};

const GateSnapshot = struct {
    physical: store.OwnedBytes,
    view: gate_format.View,

    fn deinit(self: *GateSnapshot) void {
        self.physical.deinit();
        self.* = undefined;
    }
};

const StepResult = enum { completed, retry, pending };

const Candidate = struct {
    extent_index: u64,
    page_generation: u64,
};

const OperationIdentity = struct {
    operation: gate_format.Operation,
    claim_id: [16]u8,
    claim_epoch: u64,
};

const IndexLookup = union(enum) {
    found: struct {
        entry: index_format.Entry,
        slot: u64,
        page_generation: u64,
    },
    vacant: struct {
        slot: u64,
        page_generation: u64,
        state: index_format.State,
    },
    full,
};

const ClaimRun = union(enum) {
    claimed: Claim,
    exhausted,
    pending,
    completed,
};

pub const ExtentAllocator = struct {
    allocator: std.mem.Allocator,
    transport: block.ConditionalBlockTransport,
    header: volume_format.Header,
    options: Options,

    pub fn init(
        allocator: std.mem.Allocator,
        transport: block.ConditionalBlockTransport,
        header: volume_format.Header,
        options: Options,
    ) !ExtentAllocator {
        try transport.geometry.validate();
        try volume_format.validate(header);
        if (!std.meta.eql(transport.geometry, header.geometry())) return error.GeometryMismatch;
        if (options.max_contention_retries == 0) return error.InvalidRetryCount;
        return .{ .allocator = allocator, .transport = transport, .header = header, .options = options };
    }

    pub fn format(self: ExtentAllocator) !FormatResult {
        var changed = false;
        for (0..self.header.layout.claim_stripe_count) |stripe| {
            var desired = try gate_format.encode(
                self.allocator,
                self.header.logical_block_size,
                self.header.volume_id,
                stripe,
                self.header.layout.claim_stripe_count,
                0,
                gate_format.Descriptor.idle(),
            );
            defer desired.deinit();
            switch (try self.formatBlock(self.gateBlock(stripe), desired.bytes, .gate, stripe)) {
                .changed => changed = true,
                .unchanged => {},
                .pending => {
                    try self.transport.stabilize();
                    return .pending;
                },
            }
        }

        var index_page: u64 = 0;
        while (index_page < self.header.layout.claim_index_block_count) : (index_page += 1) {
            const range = try index_format.rangeForPage(
                self.header.logical_block_size,
                index_page,
                self.header.layout.claim_index_slot_count,
            );
            var entries: [index_format.max_entries_per_page]index_format.Entry = undefined;
            for (entries[0..range.count]) |*entry| entry.* = .empty();
            var desired = try index_format.encodePage(
                self.allocator,
                self.header.logical_block_size,
                self.header.volume_id,
                index_page,
                0,
                self.header.layout.claim_index_slot_count,
                self.header.layout.extent_count,
                entries[0..range.count],
            );
            defer desired.deinit();
            switch (try self.formatBlock(self.indexBlock(index_page), desired.bytes, .index, index_page)) {
                .changed => changed = true,
                .unchanged => {},
                .pending => {
                    try self.transport.stabilize();
                    return .pending;
                },
            }
        }

        var page_index: u64 = 0;
        while (page_index < self.header.layout.allocator_block_count) : (page_index += 1) {
            const range = try allocation.rangeForPage(
                self.header.logical_block_size,
                page_index,
                self.header.layout.extent_count,
            );
            var entries: [allocation.max_entries_per_page]allocation.Entry = undefined;
            for (entries[0..range.count], 0..) |*entry, index| {
                entry.* = allocation.Entry.free(range.first_extent + index);
            }
            var desired = try allocation.encodePage(
                self.allocator,
                self.header.logical_block_size,
                self.header.volume_id,
                page_index,
                0,
                self.header.layout.extent_count,
                entries[0..range.count],
            );
            defer desired.deinit();
            switch (try self.formatBlock(self.pageBlock(page_index), desired.bytes, .allocator, page_index)) {
                .changed => changed = true,
                .unchanged => {},
                .pending => {
                    try self.transport.stabilize();
                    return .pending;
                },
            }
        }
        try self.transport.stabilize();
        return if (changed) .formatted else .already_formatted;
    }

    pub fn claim(self: ExtentAllocator, request: ClaimRequest) !ClaimOutcome {
        try request.validate();
        const stripe = self.stripeFor(request.claim_id);
        var retries: usize = 0;
        while (retries < self.options.max_contention_retries) : (retries += 1) {
            var gate = try self.readGate(stripe);
            defer gate.deinit();
            if (gate.view.descriptor.operation != .idle) {
                try self.transport.stabilize();
                const same_claim = std.mem.eql(
                    u8,
                    &gate.view.descriptor.claim_id,
                    &request.claim_id,
                );
                const recovered = try self.runActiveGate(stripe);
                if (recovered == .pending) {
                    if (same_claim) return .{ .pending = .{ .volume_id = self.header.volume_id, .request = request } };
                    return error.AllocationIndeterminate;
                }
                continue;
            }

            const next_generation = std.math.add(u64, gate.view.generation, 1) catch
                return error.GateGenerationOverflow;
            const descriptor = descriptorForClaim(request, next_generation);
            switch (try self.changeGate(&gate, descriptor)) {
                .completed => {},
                .retry => continue,
                .pending => return .{ .pending = .{ .volume_id = self.header.volume_id, .request = request } },
            }
            return switch (try self.runClaim(stripe, operationIdentity(descriptor))) {
                .claimed => |value| .{ .claimed = value },
                .exhausted => .exhausted,
                .pending => .{ .pending = .{ .volume_id = self.header.volume_id, .request = request } },
                .completed => continue,
            };
        }
        return error.AllocationContention;
    }

    /// Completes every durable gate operation left by an interrupted caller.
    pub fn recover(self: ExtentAllocator) !RecoveryResult {
        var stripe: u64 = 0;
        while (stripe < self.header.layout.claim_stripe_count) : (stripe += 1) {
            var gate = try self.readGate(stripe);
            defer gate.deinit();
            if (gate.view.descriptor.operation == .idle) continue;
            if (try self.runActiveGate(stripe) == .pending) return .pending;
        }
        try self.transport.stabilize();
        return .completed;
    }

    pub fn resolveClaim(self: ExtentAllocator, pending: PendingClaim) !ClaimResolution {
        try self.validateVolume(pending.volume_id);
        return switch (try self.claim(pending.request)) {
            .claimed => |value| .{ .claimed = value },
            .exhausted => .not_claimed,
            .pending => .pending,
        };
    }

    pub fn activate(
        self: ExtentAllocator,
        claim_value: Claim,
        publication_generation: u64,
    ) !TransitionOutcome {
        try self.validateClaim(claim_value);
        var replacement = claim_value.entry;
        replacement.state = .live;
        replacement.transition_generation = publication_generation;
        return self.transition(claim_value.entry, replacement);
    }

    pub fn retire(
        self: ExtentAllocator,
        claim_value: Claim,
        retirement_generation: u64,
    ) !TransitionOutcome {
        try self.validateClaim(claim_value);
        var replacement = claim_value.entry;
        replacement.state = .retired;
        replacement.transition_generation = retirement_generation;
        return self.transition(claim_value.entry, replacement);
    }

    pub fn release(self: ExtentAllocator, retired: Claim) !TransitionOutcome {
        try self.validateClaim(retired);
        if (retired.entry.state != .retired) return error.InvalidReleaseState;
        const stripe = self.stripeFor(retired.entry.claim_id);
        var retries: usize = 0;
        while (retries < self.options.max_contention_retries) : (retries += 1) {
            var gate = try self.readGate(stripe);
            defer gate.deinit();
            if (gate.view.descriptor.operation != .idle) {
                try self.transport.stabilize();
                const recovered = try self.runActiveGate(stripe);
                if (recovered == .pending) return .{ .pending = pendingRelease(retired) };
                continue;
            }
            const descriptor = descriptorForRelease(retired.entry);
            switch (try self.changeGate(&gate, descriptor)) {
                .completed => {},
                .retry => continue,
                .pending => return .{ .pending = pendingRelease(retired) },
            }
            return switch (try self.runRelease(stripe, operationIdentity(descriptor))) {
                .completed => .completed,
                .pending => .{ .pending = pendingRelease(retired) },
                .retry => continue,
            };
        }
        return error.AllocationContention;
    }

    pub fn resolveTransition(
        self: ExtentAllocator,
        pending: PendingTransition,
    ) !TransitionResolution {
        try self.validateVolume(pending.volume_id);
        if (pending.operation == .release) {
            const outcome = try self.release(.{ .volume_id = pending.volume_id, .entry = pending.expected });
            return switch (outcome) {
                .completed => .completed,
                .pending => .pending,
            };
        }
        if (pending.extent_index >= self.header.layout.extent_count)
            return error.ExtentOutOfRange;
        var snapshot = try self.readPage(self.pageIndex(pending.extent_index));
        defer snapshot.deinit();
        const current = try snapshot.view.entry(self.entryIndex(pending.extent_index));
        if (std.meta.eql(current, pending.replacement)) {
            try self.transport.stabilize();
            return .completed;
        }
        if (snapshot.view.generation == pending.expected_page_generation and
            std.meta.eql(current, pending.expected))
        {
            return .pending;
        }
        if (std.meta.eql(current, pending.expected)) return .not_completed;
        return error.AllocationStateChanged;
    }

    pub fn extentFirstBlock(self: ExtentAllocator, extent_index: u64) !u64 {
        if (extent_index >= self.header.layout.extent_count) return error.ExtentOutOfRange;
        const extent_blocks = self.header.extent_size / self.header.logical_block_size;
        const offset = std.math.mul(u64, extent_index, extent_blocks) catch
            return error.ExtentOutOfRange;
        return std.math.add(u64, self.header.layout.extent_base_block, offset) catch
            return error.ExtentOutOfRange;
    }

    const FormatBlockKind = enum { gate, index, allocator };
    const FormatBlockResult = enum { changed, unchanged, pending };

    fn formatBlock(
        self: ExtentAllocator,
        block_index: u64,
        desired: []const u8,
        kind: FormatBlockKind,
        position: u64,
    ) !FormatBlockResult {
        var current = try self.allocatePhysical();
        defer current.deinit();
        try self.transport.readBlock(block_index, current.bytes);
        if (std.mem.eql(u8, current.bytes, desired)) return .unchanged;
        if (!allZero(current.bytes)) {
            try self.validateFormattedBlock(kind, position, current.bytes);
            return .unchanged;
        }
        switch (try self.transport.compareAndWrite(block_index, current.bytes, desired)) {
            .written => return .changed,
            .miscompare => {
                try self.transport.readBlock(block_index, current.bytes);
                if (std.mem.eql(u8, current.bytes, desired)) return .changed;
                try self.validateFormattedBlock(kind, position, current.bytes);
                return .unchanged;
            },
            .indeterminate => {
                try self.transport.readBlock(block_index, current.bytes);
                if (std.mem.eql(u8, current.bytes, desired)) return .changed;
                if (allZero(current.bytes)) return .pending;
                try self.validateFormattedBlock(kind, position, current.bytes);
                return .changed;
            },
        }
    }

    fn validateFormattedBlock(
        self: ExtentAllocator,
        kind: FormatBlockKind,
        position: u64,
        bytes: []const u8,
    ) !void {
        switch (kind) {
            .gate => _ = try gate_format.decode(
                bytes,
                self.header.volume_id,
                position,
                self.header.layout.claim_stripe_count,
            ),
            .index => _ = try index_format.decodePage(
                bytes,
                self.header.volume_id,
                position,
                self.header.layout.claim_index_slot_count,
                self.header.layout.extent_count,
            ),
            .allocator => _ = try allocation.decodePage(
                bytes,
                self.header.volume_id,
                position,
                self.header.layout.extent_count,
            ),
        }
    }

    fn runActiveGate(self: ExtentAllocator, stripe: u64) !StepResult {
        try self.transport.stabilize();
        var gate = try self.readGate(stripe);
        defer gate.deinit();
        const identity = operationIdentity(gate.view.descriptor);
        return switch (gate.view.descriptor.operation) {
            .idle => .completed,
            .claim => switch (try self.runClaim(stripe, identity)) {
                .pending => .pending,
                else => .completed,
            },
            .release => self.runRelease(stripe, identity),
        };
    }

    fn runClaim(
        self: ExtentAllocator,
        stripe: u64,
        identity: OperationIdentity,
    ) !ClaimRun {
        var retries: usize = 0;
        while (retries < self.options.max_contention_retries) : (retries += 1) {
            var gate = try self.readGate(stripe);
            defer gate.deinit();
            const descriptor = gate.view.descriptor;
            if (!operationMatches(descriptor, identity)) return .completed;
            const request = try requestFromDescriptor(descriptor);

            switch (descriptor.phase) {
                .claim_lookup => {
                    switch (try self.lookupIndex(descriptor.claim_id)) {
                        .found => |found| {
                            expectIndexRequest(found.entry, request) catch |err| {
                                switch (try self.clearGate(&gate)) {
                                    .completed => return err,
                                    .retry => continue,
                                    .pending => return .pending,
                                }
                            };
                            var page = try self.readPage(self.pageIndex(found.entry.extent_index));
                            defer page.deinit();
                            const entry = try page.view.entry(self.entryIndex(found.entry.extent_index));
                            try expectIndexAllocation(found.entry, entry);
                            try self.transport.stabilize();
                            switch (try self.clearGate(&gate)) {
                                .completed => {
                                    if (entry.state == .retired) return error.ClaimRetired;
                                    return .{ .claimed = .{
                                        .volume_id = self.header.volume_id,
                                        .entry = entry,
                                    } };
                                },
                                .retry => continue,
                                .pending => return .pending,
                            }
                        },
                        .vacant, .full => {
                            const candidate = (try self.findFreeExtent(descriptor.claim_id)) orelse {
                                switch (try self.clearGate(&gate)) {
                                    .completed => return .exhausted,
                                    .retry => continue,
                                    .pending => return .pending,
                                }
                            };
                            var next = descriptor;
                            next.phase = .claim_extent;
                            next.expected_target_state = .extent_free;
                            next.extent_index = candidate.extent_index;
                            next.target_page_generation = candidate.page_generation;
                            switch (try self.changeGate(&gate, next)) {
                                .completed, .retry => continue,
                                .pending => return .pending,
                            }
                        },
                    }
                },
                .claim_extent => {
                    const desired = request.entry(descriptor.extent_index, descriptor.claim_epoch);
                    switch (try self.changeAllocatorEntry(
                        descriptor.extent_index,
                        allocation.Entry.free(descriptor.extent_index),
                        desired,
                        descriptor.target_page_generation,
                    )) {
                        .completed => {},
                        .pending => return .pending,
                        .retry => {
                            var observed = try self.readPage(self.pageIndex(descriptor.extent_index));
                            defer observed.deinit();
                            const current = try observed.view.entry(self.entryIndex(descriptor.extent_index));
                            if (std.meta.eql(current, desired)) continue;
                            const candidate = (try self.findFreeExtent(descriptor.claim_id)) orelse {
                                switch (try self.clearGate(&gate)) {
                                    .completed => return .exhausted,
                                    .retry => continue,
                                    .pending => return .pending,
                                }
                            };
                            var next = descriptor;
                            next.extent_index = candidate.extent_index;
                            next.target_page_generation = candidate.page_generation;
                            switch (try self.changeGate(&gate, next)) {
                                .completed, .retry => continue,
                                .pending => return .pending,
                            }
                        },
                    }

                    switch (try self.lookupIndex(descriptor.claim_id)) {
                        .found => |found| {
                            if (found.entry.claim_epoch != descriptor.claim_epoch)
                                return error.DuplicateClaimId;
                            switch (try self.clearGate(&gate)) {
                                .completed => return .{ .claimed = .{ .volume_id = self.header.volume_id, .entry = desired } },
                                .retry => continue,
                                .pending => return .pending,
                            }
                        },
                        .full => return error.ClaimIndexFull,
                        .vacant => |vacant| {
                            var next = descriptor;
                            next.phase = .claim_index;
                            next.expected_target_state = if (vacant.state == .empty)
                                .index_empty
                            else
                                .index_tombstone;
                            next.index_slot = vacant.slot;
                            next.target_page_generation = vacant.page_generation;
                            switch (try self.changeGate(&gate, next)) {
                                .completed, .retry => continue,
                                .pending => return .pending,
                            }
                        },
                    }
                },
                .claim_index => {
                    const desired = indexEntryFromDescriptor(descriptor);
                    switch (try self.changeIndexEntry(
                        descriptor.index_slot,
                        indexExpected(descriptor.expected_target_state),
                        desired,
                        descriptor.target_page_generation,
                    )) {
                        .completed => switch (try self.clearGate(&gate)) {
                            .completed => return .{ .claimed = .{
                                .volume_id = self.header.volume_id,
                                .entry = request.entry(descriptor.extent_index, descriptor.claim_epoch),
                            } },
                            .retry => continue,
                            .pending => return .pending,
                        },
                        .pending => return .pending,
                        .retry => switch (try self.lookupIndex(descriptor.claim_id)) {
                            .found => |found| {
                                if (!std.meta.eql(found.entry, desired)) return error.DuplicateClaimId;
                                try self.transport.stabilize();
                                continue;
                            },
                            .full => return error.ClaimIndexFull,
                            .vacant => |vacant| {
                                var next = descriptor;
                                next.index_slot = vacant.slot;
                                next.target_page_generation = vacant.page_generation;
                                next.expected_target_state = if (vacant.state == .empty)
                                    .index_empty
                                else
                                    .index_tombstone;
                                switch (try self.changeGate(&gate, next)) {
                                    .completed, .retry => continue,
                                    .pending => return .pending,
                                }
                            },
                        },
                    }
                },
                else => return error.InvalidOperationPhase,
            }
        }
        return error.AllocationContention;
    }

    fn runRelease(
        self: ExtentAllocator,
        stripe: u64,
        identity: OperationIdentity,
    ) !StepResult {
        var retries: usize = 0;
        while (retries < self.options.max_contention_retries) : (retries += 1) {
            var gate = try self.readGate(stripe);
            defer gate.deinit();
            const descriptor = gate.view.descriptor;
            if (!operationMatches(descriptor, identity)) return .completed;

            switch (descriptor.phase) {
                .release_lookup => switch (try self.lookupIndex(descriptor.claim_id)) {
                    .found => |found| {
                        if (found.entry.claim_epoch != descriptor.claim_epoch) {
                            return self.clearGate(&gate);
                        }
                        try expectDescriptorIndex(descriptor, found.entry);
                        var page = try self.readPage(self.pageIndex(descriptor.extent_index));
                        defer page.deinit();
                        const entry = try page.view.entry(self.entryIndex(descriptor.extent_index));
                        if (!entryMatchesDescriptor(entry, descriptor) or entry.state != .retired) {
                            switch (try self.clearGate(&gate)) {
                                .completed => return error.InvalidReleaseState,
                                .retry => continue,
                                .pending => return .pending,
                            }
                        }
                        var next = descriptor;
                        next.phase = .release_index;
                        next.expected_target_state = .index_bound;
                        next.index_slot = found.slot;
                        next.target_page_generation = found.page_generation;
                        switch (try self.changeGate(&gate, next)) {
                            .completed, .retry => continue,
                            .pending => return .pending,
                        }
                    },
                    .vacant, .full => {
                        var page = try self.readPage(self.pageIndex(descriptor.extent_index));
                        defer page.deinit();
                        const entry = try page.view.entry(self.entryIndex(descriptor.extent_index));
                        if (!entryMatchesDescriptor(entry, descriptor)) return self.clearGate(&gate);
                        if (entry.state != .retired) return error.InvalidReleaseState;
                        var next = descriptor;
                        next.phase = .release_extent;
                        next.expected_target_state = .extent_retired;
                        next.target_page_generation = page.view.generation;
                        switch (try self.changeGate(&gate, next)) {
                            .completed, .retry => continue,
                            .pending => return .pending,
                        }
                    },
                },
                .release_index => {
                    switch (try self.changeIndexEntry(
                        descriptor.index_slot,
                        indexEntryFromDescriptor(descriptor),
                        .tombstone(),
                        descriptor.target_page_generation,
                    )) {
                        .completed => {},
                        .pending => return .pending,
                        .retry => switch (try self.lookupIndex(descriptor.claim_id)) {
                            .found => |found| {
                                if (found.entry.claim_epoch != descriptor.claim_epoch)
                                    return error.AllocationStateChanged;
                                var next = descriptor;
                                next.index_slot = found.slot;
                                next.target_page_generation = found.page_generation;
                                switch (try self.changeGate(&gate, next)) {
                                    .completed, .retry => continue,
                                    .pending => return .pending,
                                }
                            },
                            .vacant, .full => {},
                        },
                    }
                    var page = try self.readPage(self.pageIndex(descriptor.extent_index));
                    defer page.deinit();
                    const entry = try page.view.entry(self.entryIndex(descriptor.extent_index));
                    if (!entryMatchesDescriptor(entry, descriptor)) return self.clearGate(&gate);
                    if (entry.state != .retired) return error.InvalidReleaseState;
                    var next = descriptor;
                    next.phase = .release_extent;
                    next.expected_target_state = .extent_retired;
                    next.target_page_generation = page.view.generation;
                    switch (try self.changeGate(&gate, next)) {
                        .completed, .retry => continue,
                        .pending => return .pending,
                    }
                },
                .release_extent => {
                    const expected = entryFromDescriptor(descriptor, .retired);
                    switch (try self.changeAllocatorEntry(
                        descriptor.extent_index,
                        expected,
                        allocation.Entry.free(descriptor.extent_index),
                        descriptor.target_page_generation,
                    )) {
                        .completed => return self.clearGate(&gate),
                        .pending => return .pending,
                        .retry => {
                            var page = try self.readPage(self.pageIndex(descriptor.extent_index));
                            defer page.deinit();
                            const current = try page.view.entry(self.entryIndex(descriptor.extent_index));
                            if (current.state == .free or !entryMatchesDescriptor(current, descriptor))
                                return self.clearGate(&gate);
                            var next = descriptor;
                            next.target_page_generation = page.view.generation;
                            switch (try self.changeGate(&gate, next)) {
                                .completed, .retry => continue,
                                .pending => return .pending,
                            }
                        },
                    }
                },
                else => return error.InvalidOperationPhase,
            }
        }
        return error.AllocationContention;
    }

    fn transition(
        self: ExtentAllocator,
        expected: allocation.Entry,
        replacement: allocation.Entry,
    ) !TransitionOutcome {
        try allocation.validateTransition(expected, replacement);
        var retries: usize = 0;
        while (retries < self.options.max_contention_retries) : (retries += 1) {
            var page = try self.readPage(self.pageIndex(expected.extent_index));
            defer page.deinit();
            const current = try page.view.entry(self.entryIndex(expected.extent_index));
            if (std.meta.eql(current, replacement)) {
                try self.transport.stabilize();
                return .completed;
            }
            if (!std.meta.eql(current, expected)) return error.AllocationStateChanged;
            switch (try self.changeAllocatorEntry(
                expected.extent_index,
                expected,
                replacement,
                page.view.generation,
            )) {
                .completed => return .completed,
                .retry => continue,
                .pending => return .{ .pending = .{
                    .volume_id = self.header.volume_id,
                    .extent_index = expected.extent_index,
                    .expected_page_generation = page.view.generation,
                    .expected = expected,
                    .replacement = replacement,
                } },
            }
        }
        return error.AllocationContention;
    }

    fn lookupIndex(self: ExtentAllocator, claim_id: [16]u8) !IndexLookup {
        const total = self.header.layout.claim_index_slot_count;
        const home = self.homeSlot(claim_id);
        var first_tombstone: ?IndexLookup = null;
        var offset: u64 = 0;
        while (offset < total) : (offset += 1) {
            const slot = if (offset < total - home) home + offset else offset - (total - home);
            var page = try self.readIndex(self.indexPage(slot));
            defer page.deinit();
            const entry = try page.view.entry(self.indexEntry(slot));
            switch (entry.state) {
                .bound => if (std.mem.eql(u8, &entry.claim_id, &claim_id)) return .{ .found = .{
                    .entry = entry,
                    .slot = slot,
                    .page_generation = page.view.generation,
                } },
                .tombstone => {
                    if (first_tombstone == null) first_tombstone = .{ .vacant = .{
                        .slot = slot,
                        .page_generation = page.view.generation,
                        .state = .tombstone,
                    } };
                },
                .empty => return first_tombstone orelse .{ .vacant = .{
                    .slot = slot,
                    .page_generation = page.view.generation,
                    .state = .empty,
                } },
            }
        }
        return first_tombstone orelse .full;
    }

    fn findFreeExtent(self: ExtentAllocator, claim_id: [16]u8) !?Candidate {
        const page_count = self.header.layout.allocator_block_count;
        const start = std.mem.readInt(u64, claim_id[0..8], .big) % page_count;
        var offset: u64 = 0;
        while (offset < page_count) : (offset += 1) {
            const page_index = if (offset < page_count - start)
                start + offset
            else
                offset - (page_count - start);
            var page = try self.readPage(page_index);
            defer page.deinit();
            for (0..page.view.entry_count) |entry_index| {
                const entry = try page.view.entry(entry_index);
                if (entry.state == .free) return .{
                    .extent_index = entry.extent_index,
                    .page_generation = page.view.generation,
                };
            }
        }
        return null;
    }

    fn changeAllocatorEntry(
        self: ExtentAllocator,
        extent_index: u64,
        expected: allocation.Entry,
        replacement: allocation.Entry,
        expected_generation: u64,
    ) !StepResult {
        var page = try self.readPage(self.pageIndex(extent_index));
        defer page.deinit();
        const slot = self.entryIndex(extent_index);
        const current = try page.view.entry(slot);
        if (std.meta.eql(current, replacement)) {
            try self.transport.stabilize();
            return .completed;
        }
        if (page.view.generation != expected_generation) {
            try self.transport.stabilize();
            return .retry;
        }
        if (!std.meta.eql(current, expected)) return error.AllocationStateChanged;
        var desired = try self.replaceAllocatorEntry(&page, slot, replacement);
        defer desired.deinit();
        return self.issueTargetCaw(
            self.pageBlock(page.view.page_index),
            page.physical.bytes,
            desired.bytes,
            .allocator,
            page.view.page_index,
        );
    }

    fn changeIndexEntry(
        self: ExtentAllocator,
        global_slot: u64,
        expected: index_format.Entry,
        replacement: index_format.Entry,
        expected_generation: u64,
    ) !StepResult {
        const page_index = self.indexPage(global_slot);
        var page = try self.readIndex(page_index);
        defer page.deinit();
        const slot = self.indexEntry(global_slot);
        const current = try page.view.entry(slot);
        if (std.meta.eql(current, replacement)) {
            try self.transport.stabilize();
            return .completed;
        }
        if (page.view.generation != expected_generation) {
            try self.transport.stabilize();
            return .retry;
        }
        if (!std.meta.eql(current, expected)) return error.AllocationStateChanged;
        var desired = try self.replaceIndexEntry(&page, slot, replacement);
        defer desired.deinit();
        return self.issueTargetCaw(
            self.indexBlock(page_index),
            page.physical.bytes,
            desired.bytes,
            .index,
            page_index,
        );
    }

    fn issueTargetCaw(
        self: ExtentAllocator,
        block_index: u64,
        expected: []const u8,
        replacement: []const u8,
        kind: FormatBlockKind,
        position: u64,
    ) !StepResult {
        switch (try self.transport.compareAndWrite(block_index, expected, replacement)) {
            .written => {
                try self.transport.stabilize();
                return .completed;
            },
            .miscompare => return .retry,
            .indeterminate => {
                var observed = try self.allocatePhysical();
                defer observed.deinit();
                try self.transport.readBlock(block_index, observed.bytes);
                if (std.mem.eql(u8, observed.bytes, replacement)) {
                    try self.transport.stabilize();
                    return .completed;
                }
                if (!std.mem.eql(u8, observed.bytes, expected)) {
                    try self.transport.stabilize();
                    return .retry;
                }
                return self.fenceBlock(block_index, kind, position, observed.bytes);
            },
        }
    }

    fn fenceBlock(
        self: ExtentAllocator,
        block_index: u64,
        kind: FormatBlockKind,
        position: u64,
        expected: []const u8,
    ) !StepResult {
        var replacement = switch (kind) {
            .allocator => blk: {
                const view = try allocation.decodePage(
                    expected,
                    self.header.volume_id,
                    position,
                    self.header.layout.extent_count,
                );
                var entries: [allocation.max_entries_per_page]allocation.Entry = undefined;
                for (0..view.entry_count) |index| entries[index] = try view.entry(index);
                break :blk try allocation.encodePage(
                    self.allocator,
                    self.header.logical_block_size,
                    self.header.volume_id,
                    position,
                    std.math.add(u64, view.generation, 1) catch return error.AllocatorGenerationOverflow,
                    self.header.layout.extent_count,
                    entries[0..view.entry_count],
                );
            },
            .index => blk: {
                const view = try index_format.decodePage(
                    expected,
                    self.header.volume_id,
                    position,
                    self.header.layout.claim_index_slot_count,
                    self.header.layout.extent_count,
                );
                var entries: [index_format.max_entries_per_page]index_format.Entry = undefined;
                for (0..view.entry_count) |index| entries[index] = try view.entry(index);
                break :blk try index_format.encodePage(
                    self.allocator,
                    self.header.logical_block_size,
                    self.header.volume_id,
                    position,
                    std.math.add(u64, view.generation, 1) catch return error.IndexGenerationOverflow,
                    self.header.layout.claim_index_slot_count,
                    self.header.layout.extent_count,
                    entries[0..view.entry_count],
                );
            },
            .gate => unreachable,
        };
        defer replacement.deinit();
        switch (try self.transport.compareAndWrite(block_index, expected, replacement.bytes)) {
            .written => {
                try self.transport.stabilize();
                return .retry;
            },
            .miscompare => return .retry,
            .indeterminate => return .pending,
        }
    }

    fn changeGate(
        self: ExtentAllocator,
        snapshot: *const GateSnapshot,
        descriptor: gate_format.Descriptor,
    ) !StepResult {
        const next_generation = std.math.add(u64, snapshot.view.generation, 1) catch
            return error.GateGenerationOverflow;
        var replacement = try gate_format.encode(
            self.allocator,
            self.header.logical_block_size,
            self.header.volume_id,
            snapshot.view.stripe_index,
            self.header.layout.claim_stripe_count,
            next_generation,
            descriptor,
        );
        defer replacement.deinit();
        const block_index = self.gateBlock(snapshot.view.stripe_index);
        switch (try self.transport.compareAndWrite(
            block_index,
            snapshot.physical.bytes,
            replacement.bytes,
        )) {
            .written => {
                try self.transport.stabilize();
                return .completed;
            },
            .miscompare => return .retry,
            .indeterminate => {
                var observed = try self.readGate(snapshot.view.stripe_index);
                defer observed.deinit();
                if (std.meta.eql(observed.view.descriptor, descriptor)) {
                    try self.transport.stabilize();
                    return .completed;
                }
                if (observed.view.generation != snapshot.view.generation or
                    !std.meta.eql(observed.view.descriptor, snapshot.view.descriptor))
                {
                    try self.transport.stabilize();
                    return .retry;
                }
                var fence = try gate_format.encode(
                    self.allocator,
                    self.header.logical_block_size,
                    self.header.volume_id,
                    snapshot.view.stripe_index,
                    self.header.layout.claim_stripe_count,
                    next_generation,
                    snapshot.view.descriptor,
                );
                defer fence.deinit();
                switch (try self.transport.compareAndWrite(
                    block_index,
                    observed.physical.bytes,
                    fence.bytes,
                )) {
                    .written => {
                        try self.transport.stabilize();
                        return .retry;
                    },
                    .miscompare => return .retry,
                    .indeterminate => return .pending,
                }
            },
        }
    }

    fn clearGate(self: ExtentAllocator, snapshot: *const GateSnapshot) !StepResult {
        return self.changeGate(snapshot, gate_format.Descriptor.idle());
    }

    fn replaceAllocatorEntry(
        self: ExtentAllocator,
        snapshot: *const PageSnapshot,
        slot: usize,
        replacement: allocation.Entry,
    ) !store.OwnedBytes {
        var entries: [allocation.max_entries_per_page]allocation.Entry = undefined;
        for (0..snapshot.view.entry_count) |index| entries[index] = try snapshot.view.entry(index);
        entries[slot] = replacement;
        return allocation.encodePage(
            self.allocator,
            self.header.logical_block_size,
            self.header.volume_id,
            snapshot.view.page_index,
            std.math.add(u64, snapshot.view.generation, 1) catch return error.AllocatorGenerationOverflow,
            self.header.layout.extent_count,
            entries[0..snapshot.view.entry_count],
        );
    }

    fn replaceIndexEntry(
        self: ExtentAllocator,
        snapshot: *const IndexSnapshot,
        slot: usize,
        replacement: index_format.Entry,
    ) !store.OwnedBytes {
        var entries: [index_format.max_entries_per_page]index_format.Entry = undefined;
        for (0..snapshot.view.entry_count) |index| entries[index] = try snapshot.view.entry(index);
        entries[slot] = replacement;
        return index_format.encodePage(
            self.allocator,
            self.header.logical_block_size,
            self.header.volume_id,
            snapshot.view.page_index,
            std.math.add(u64, snapshot.view.generation, 1) catch return error.IndexGenerationOverflow,
            self.header.layout.claim_index_slot_count,
            self.header.layout.extent_count,
            entries[0..snapshot.view.entry_count],
        );
    }

    fn readPage(self: ExtentAllocator, page_index: u64) !PageSnapshot {
        if (page_index >= self.header.layout.allocator_block_count)
            return error.AllocatorPageOutOfRange;
        var physical = try self.allocatePhysical();
        errdefer physical.deinit();
        try self.transport.readBlock(self.pageBlock(page_index), physical.bytes);
        const view = try allocation.decodePage(
            physical.bytes,
            self.header.volume_id,
            page_index,
            self.header.layout.extent_count,
        );
        return .{ .physical = physical, .view = view };
    }

    fn readIndex(self: ExtentAllocator, page_index: u64) !IndexSnapshot {
        if (page_index >= self.header.layout.claim_index_block_count)
            return error.IndexPageOutOfRange;
        var physical = try self.allocatePhysical();
        errdefer physical.deinit();
        try self.transport.readBlock(self.indexBlock(page_index), physical.bytes);
        const view = try index_format.decodePage(
            physical.bytes,
            self.header.volume_id,
            page_index,
            self.header.layout.claim_index_slot_count,
            self.header.layout.extent_count,
        );
        return .{ .physical = physical, .view = view };
    }

    fn readGate(self: ExtentAllocator, stripe: u64) !GateSnapshot {
        if (stripe >= self.header.layout.claim_stripe_count) return error.GateOutOfRange;
        var physical = try self.allocatePhysical();
        errdefer physical.deinit();
        try self.transport.readBlock(self.gateBlock(stripe), physical.bytes);
        const view = try gate_format.decode(
            physical.bytes,
            self.header.volume_id,
            stripe,
            self.header.layout.claim_stripe_count,
        );
        return .{ .physical = physical, .view = view };
    }

    fn allocatePhysical(self: ExtentAllocator) !store.OwnedBytes {
        return .{
            .allocator = self.allocator,
            .bytes = try self.allocator.alloc(u8, self.header.logical_block_size),
        };
    }

    fn validateClaim(self: ExtentAllocator, claim_value: Claim) !void {
        try self.validateVolume(claim_value.volume_id);
        if (claim_value.extentIndex() >= self.header.layout.extent_count)
            return error.ExtentOutOfRange;
        try claim_value.entry.validate();
    }

    fn validateVolume(self: ExtentAllocator, volume_id: [16]u8) !void {
        if (!std.mem.eql(u8, &volume_id, &self.header.volume_id)) return error.VolumeMismatch;
    }

    fn gateBlock(self: ExtentAllocator, stripe: u64) u64 {
        return self.header.layout.claim_gate_base_block + stripe;
    }

    fn indexBlock(self: ExtentAllocator, page: u64) u64 {
        return self.header.layout.claim_index_base_block + page;
    }

    fn pageBlock(self: ExtentAllocator, page: u64) u64 {
        return self.header.layout.allocator_base_block + page;
    }

    fn pageIndex(self: ExtentAllocator, extent_index: u64) u64 {
        return extent_index / (allocation.entriesPerPage(self.header.logical_block_size) catch unreachable);
    }

    fn entryIndex(self: ExtentAllocator, extent_index: u64) usize {
        return @intCast(extent_index % (allocation.entriesPerPage(self.header.logical_block_size) catch unreachable));
    }

    fn indexPage(self: ExtentAllocator, slot: u64) u64 {
        return slot / (index_format.entriesPerPage(self.header.logical_block_size) catch unreachable);
    }

    fn indexEntry(self: ExtentAllocator, slot: u64) usize {
        return @intCast(slot % (index_format.entriesPerPage(self.header.logical_block_size) catch unreachable));
    }

    fn hashClaim(self: ExtentAllocator, claim_id: [16]u8) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("ZCAW claim v1");
        hasher.update(&self.header.volume_id);
        hasher.update(&claim_id);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }

    fn stripeFor(self: ExtentAllocator, claim_id: [16]u8) u64 {
        const digest = self.hashClaim(claim_id);
        return std.mem.readInt(u64, digest[0..8], .big) & (self.header.layout.claim_stripe_count - 1);
    }

    fn homeSlot(self: ExtentAllocator, claim_id: [16]u8) u64 {
        const digest = self.hashClaim(claim_id);
        return std.mem.readInt(u64, digest[8..16], .big) % self.header.layout.claim_index_slot_count;
    }
};

fn descriptorForClaim(request: ClaimRequest, claim_epoch: u64) gate_format.Descriptor {
    return .{
        .operation = .claim,
        .phase = .claim_lookup,
        .kind = @intFromEnum(request.kind),
        .claim_id = request.claim_id,
        .owner_id = request.owner_id,
        .owner_incarnation = request.owner_incarnation,
        .base_generation = request.base_generation,
        .owner_epoch = request.owner_epoch,
        .claim_epoch = claim_epoch,
    };
}

fn descriptorForRelease(entry: allocation.Entry) gate_format.Descriptor {
    return .{
        .operation = .release,
        .phase = .release_lookup,
        .kind = @intFromEnum(entry.kind),
        .claim_id = entry.claim_id,
        .owner_id = entry.owner_id,
        .owner_incarnation = entry.owner_incarnation,
        .base_generation = entry.base_generation,
        .owner_epoch = entry.owner_epoch,
        .claim_epoch = entry.claim_epoch,
        .extent_index = entry.extent_index,
        .transition_generation = entry.transition_generation,
    };
}

fn operationIdentity(descriptor: gate_format.Descriptor) OperationIdentity {
    return .{
        .operation = descriptor.operation,
        .claim_id = descriptor.claim_id,
        .claim_epoch = descriptor.claim_epoch,
    };
}

fn operationMatches(
    descriptor: gate_format.Descriptor,
    identity: OperationIdentity,
) bool {
    return descriptor.operation == identity.operation and
        std.mem.eql(u8, &descriptor.claim_id, &identity.claim_id) and
        descriptor.claim_epoch == identity.claim_epoch;
}

fn requestFromDescriptor(descriptor: gate_format.Descriptor) !ClaimRequest {
    return .{
        .kind = std.enums.fromInt(allocation.Kind, descriptor.kind) orelse return error.InvalidEntryKind,
        .claim_id = descriptor.claim_id,
        .owner_id = descriptor.owner_id,
        .owner_incarnation = descriptor.owner_incarnation,
        .base_generation = descriptor.base_generation,
        .owner_epoch = descriptor.owner_epoch,
    };
}

fn indexEntryFromDescriptor(descriptor: gate_format.Descriptor) index_format.Entry {
    return .{
        .state = .bound,
        .kind = std.enums.fromInt(allocation.Kind, descriptor.kind).?,
        .claim_id = descriptor.claim_id,
        .owner_id = descriptor.owner_id,
        .owner_incarnation = descriptor.owner_incarnation,
        .base_generation = descriptor.base_generation,
        .owner_epoch = descriptor.owner_epoch,
        .claim_epoch = descriptor.claim_epoch,
        .extent_index = descriptor.extent_index,
    };
}

fn entryFromDescriptor(descriptor: gate_format.Descriptor, state: allocation.State) allocation.Entry {
    return .{
        .state = state,
        .kind = std.enums.fromInt(allocation.Kind, descriptor.kind).?,
        .extent_index = descriptor.extent_index,
        .claim_id = descriptor.claim_id,
        .owner_id = descriptor.owner_id,
        .owner_incarnation = descriptor.owner_incarnation,
        .base_generation = descriptor.base_generation,
        .owner_epoch = descriptor.owner_epoch,
        .transition_generation = descriptor.transition_generation,
        .claim_epoch = descriptor.claim_epoch,
    };
}

fn indexExpected(state: gate_format.TargetState) index_format.Entry {
    return switch (state) {
        .index_empty => .empty(),
        .index_tombstone => .tombstone(),
        else => unreachable,
    };
}

fn expectIndexRequest(entry: index_format.Entry, request: ClaimRequest) !void {
    if (entry.kind != request.kind or
        !std.mem.eql(u8, &entry.owner_id, &request.owner_id) or
        !std.mem.eql(u8, &entry.owner_incarnation, &request.owner_incarnation) or
        entry.base_generation != request.base_generation or entry.owner_epoch != request.owner_epoch)
    {
        return error.DuplicateClaimId;
    }
}

fn expectIndexAllocation(index: index_format.Entry, entry: allocation.Entry) !void {
    if (entry.state == .free or entry.kind != index.kind or entry.extent_index != index.extent_index or
        !std.mem.eql(u8, &entry.claim_id, &index.claim_id) or
        !std.mem.eql(u8, &entry.owner_id, &index.owner_id) or
        !std.mem.eql(u8, &entry.owner_incarnation, &index.owner_incarnation) or
        entry.base_generation != index.base_generation or entry.owner_epoch != index.owner_epoch or
        entry.claim_epoch != index.claim_epoch)
    {
        return error.AllocationStateChanged;
    }
}

fn expectDescriptorIndex(descriptor: gate_format.Descriptor, entry: index_format.Entry) !void {
    if (!std.meta.eql(indexEntryFromDescriptor(descriptor), entry)) return error.AllocationStateChanged;
}

fn entryMatchesDescriptor(entry: allocation.Entry, descriptor: gate_format.Descriptor) bool {
    return entry.kind == std.enums.fromInt(allocation.Kind, descriptor.kind).? and
        entry.extent_index == descriptor.extent_index and
        std.mem.eql(u8, &entry.claim_id, &descriptor.claim_id) and
        std.mem.eql(u8, &entry.owner_id, &descriptor.owner_id) and
        std.mem.eql(u8, &entry.owner_incarnation, &descriptor.owner_incarnation) and
        entry.base_generation == descriptor.base_generation and
        entry.owner_epoch == descriptor.owner_epoch and entry.claim_epoch == descriptor.claim_epoch;
}

fn pendingRelease(retired: Claim) PendingTransition {
    return .{
        .operation = .release,
        .volume_id = retired.volume_id,
        .extent_index = retired.extentIndex(),
        .expected = retired.entry,
        .replacement = allocation.Entry.free(retired.extentIndex()),
    };
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const model_block = @import("model_conditional_block.zig");

fn patternedId(seed: u8) [16]u8 {
    var id: [16]u8 = undefined;
    for (&id, seed..) |*byte, value| byte.* = @intCast(value);
    return id;
}

fn testHeader(geometry: block.Geometry) !volume_format.Header {
    return volume_format.Header.init(patternedId(100), 123, geometry, geometry.logical_block_size);
}

fn testRequest(seed: u8) ClaimRequest {
    return .{
        .kind = .data,
        .claim_id = patternedId(seed),
        .owner_id = patternedId(seed + 16),
        .owner_incarnation = patternedId(seed + 32),
        .base_generation = 0,
        .owner_epoch = 1,
    };
}

test "allocator formats gates index and allocator pages durably" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    try std.testing.expectEqual(FormatResult.formatted, try allocator.format());
    model.crash();
    try std.testing.expectEqual(FormatResult.already_formatted, try allocator.format());
}

test "allocator retries the format durability barrier" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    model.injectNextStabilizeFailure();
    try std.testing.expectError(error.InjectedStabilizeFailure, allocator.format());
    try std.testing.expectEqual(FormatResult.already_formatted, try allocator.format());
    model.crash();
    try std.testing.expectEqual(FormatResult.already_formatted, try allocator.format());
}

test "duplicate claims converge through the persistent index" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();
    const first = (try allocator.claim(testRequest(1))).claimed;
    const duplicate = (try allocator.claim(testRequest(1))).claimed;
    try std.testing.expectEqual(first.entry, duplicate.entry);
    var changed = testRequest(1);
    changed.owner_epoch = 2;
    try std.testing.expectError(error.DuplicateClaimId, allocator.claim(changed));
    const after_conflict = (try allocator.claim(testRequest(1))).claimed;
    try std.testing.expectEqual(first.entry, after_conflict.entry);
}

test "a resumed caller does not adopt a reused gate operation" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();

    const first_request = testRequest(1);
    const stripe = allocator.stripeFor(first_request.claim_id);
    var gate = try allocator.readGate(stripe);
    const first_descriptor = descriptorForClaim(first_request, gate.view.generation + 1);
    try std.testing.expectEqual(StepResult.completed, try allocator.changeGate(&gate, first_descriptor));
    gate.deinit();
    _ = try allocator.runClaim(stripe, operationIdentity(first_descriptor));

    var second_seed: u8 = 2;
    while (allocator.stripeFor(testRequest(second_seed).claim_id) != stripe) : (second_seed += 1) {}
    const second_request = testRequest(second_seed);
    gate = try allocator.readGate(stripe);
    const second_descriptor = descriptorForClaim(second_request, gate.view.generation + 1);
    try std.testing.expectEqual(StepResult.completed, try allocator.changeGate(&gate, second_descriptor));
    gate.deinit();

    try std.testing.expect((try allocator.runClaim(
        stripe,
        operationIdentity(first_descriptor),
    )) == .completed);
    const second = try allocator.runClaim(stripe, operationIdentity(second_descriptor));
    try std.testing.expectEqual(second_request.claim_id, second.claimed.entry.claim_id);
}

test "claim recovers an indeterminate allocator CAW with a durable fence" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();
    model.injectFaultAfter(2, .indeterminate_pending);
    const claimed = (try allocator.claim(testRequest(1))).claimed;
    try std.testing.expectEqual(block.CawResult.miscompare, model.completePending().?);
    model.crash();
    const recovered = (try allocator.claim(testRequest(1))).claimed;
    try std.testing.expectEqual(claimed.entry, recovered.entry);
}

test "claim fences indeterminate gate and index CAWs" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();

    model.injectNextFault(.indeterminate_pending);
    _ = (try allocator.claim(testRequest(1))).claimed;
    try std.testing.expectEqual(block.CawResult.miscompare, model.completePending().?);

    model.injectFaultAfter(4, .indeterminate_pending);
    _ = (try allocator.claim(testRequest(2))).claimed;
    try std.testing.expectEqual(block.CawResult.miscompare, model.completePending().?);
}

test "claim resumes a stable gate after crash rolls back its target intent" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();
    model.injectStabilizeFailureAfter(1);
    try std.testing.expectError(error.InjectedStabilizeFailure, allocator.claim(testRequest(1)));
    model.crash();
    try std.testing.expectEqual(RecoveryResult.completed, try allocator.recover());
    _ = (try allocator.claim(testRequest(1))).claimed;
}

test "release deletes the index before freeing and rejects a stale token" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();
    const claimed = (try allocator.claim(testRequest(1))).claimed;
    try std.testing.expectEqual(TransitionOutcome.completed, try allocator.activate(claimed, 1));
    var live = claimed;
    live.entry.state = .live;
    live.entry.transition_generation = 1;
    try std.testing.expectEqual(TransitionOutcome.completed, try allocator.retire(live, 2));
    var retired = live;
    retired.entry.state = .retired;
    retired.entry.transition_generation = 2;
    try std.testing.expectError(error.ClaimRetired, allocator.claim(testRequest(1)));
    try std.testing.expectEqual(TransitionOutcome.completed, try allocator.release(retired));

    const replacement = (try allocator.claim(testRequest(1))).claimed;
    try std.testing.expect(replacement.entry.claim_epoch != retired.entry.claim_epoch);
    try std.testing.expectEqual(TransitionOutcome.completed, try allocator.release(retired));
    const duplicate = (try allocator.claim(testRequest(1))).claimed;
    try std.testing.expectEqual(replacement.entry, duplicate.entry);
}

test "release fences indeterminate index and allocator CAWs" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();

    const releaseOne = struct {
        fn run(value: ExtentAllocator, request: ClaimRequest) !void {
            const claimed = (try value.claim(request)).claimed;
            _ = try value.activate(claimed, 1);
            var live = claimed;
            live.entry.state = .live;
            live.entry.transition_generation = 1;
            _ = try value.retire(live, 2);
            var retired = live;
            retired.entry.state = .retired;
            retired.entry.transition_generation = 2;
            _ = try value.release(retired);
        }
    }.run;

    model.injectFaultAfter(10, .indeterminate_pending);
    try releaseOne(allocator, testRequest(1));
    try std.testing.expectEqual(block.CawResult.miscompare, model.completePending().?);

    model.injectFaultAfter(12, .indeterminate_pending);
    try releaseOne(allocator, testRequest(2));
    try std.testing.expectEqual(block.CawResult.miscompare, model.completePending().?);
}

test "release resumes after crash rolls back an index deletion" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 128 };
    var model = try model_block.ModelConditionalBlock.init(std.testing.allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.testing.allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();
    const claimed = (try allocator.claim(testRequest(1))).claimed;
    _ = try allocator.activate(claimed, 1);
    var live = claimed;
    live.entry.state = .live;
    live.entry.transition_generation = 1;
    _ = try allocator.retire(live, 2);
    var retired = live;
    retired.entry.state = .retired;
    retired.entry.transition_generation = 2;

    model.injectStabilizeFailureAfter(2);
    try std.testing.expectError(error.InjectedStabilizeFailure, allocator.release(retired));
    model.crash();
    try std.testing.expectEqual(RecoveryResult.completed, try allocator.recover());
    try std.testing.expectEqual(TransitionOutcome.completed, try allocator.release(retired));
}

test "concurrent duplicate claims return one allocation" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 256 };
    var model = try model_block.ModelConditionalBlock.init(std.heap.page_allocator, geometry);
    defer model.deinit();
    const header = try testHeader(geometry);
    const first_allocator = try ExtentAllocator.init(std.heap.page_allocator, model.transport(), header, .{});
    const second_allocator = try ExtentAllocator.init(std.heap.page_allocator, model.transport(), header, .{});
    _ = try first_allocator.format();

    const Worker = struct {
        allocator: ExtentAllocator,
        result: ?Claim = null,

        fn run(self: *@This()) void {
            self.result = (self.allocator.claim(testRequest(1)) catch |err|
                std.debug.panic("claim failed: {s}", .{@errorName(err)})).claimed;
        }
    };
    var first = Worker{ .allocator = first_allocator };
    var second = Worker{ .allocator = second_allocator };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expectEqual(first.result.?.entry, second.result.?.entry);
}

test "concurrent releases are idempotent" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 256 };
    var model = try model_block.ModelConditionalBlock.init(std.heap.page_allocator, geometry);
    defer model.deinit();
    const allocator = try ExtentAllocator.init(
        std.heap.page_allocator,
        model.transport(),
        try testHeader(geometry),
        .{},
    );
    _ = try allocator.format();
    const claimed = (try allocator.claim(testRequest(1))).claimed;
    _ = try allocator.activate(claimed, 1);
    var live = claimed;
    live.entry.state = .live;
    live.entry.transition_generation = 1;
    _ = try allocator.retire(live, 2);
    var retired = live;
    retired.entry.state = .retired;
    retired.entry.transition_generation = 2;

    const Worker = struct {
        allocator: ExtentAllocator,
        retired: Claim,
        completed: bool = false,

        fn run(self: *@This()) void {
            const outcome = self.allocator.release(self.retired) catch |err|
                std.debug.panic("release failed: {s}", .{@errorName(err)});
            self.completed = outcome == .completed;
        }
    };
    var first = Worker{ .allocator = allocator, .retired = retired };
    var second = Worker{ .allocator = allocator, .retired = retired };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.completed);
    try std.testing.expect(second.completed);
}

test "concurrent claims receive distinct physical extents" {
    const geometry = block.Geometry{ .logical_block_size = 512, .block_count = 256 };
    var model = try model_block.ModelConditionalBlock.init(std.heap.page_allocator, geometry);
    defer model.deinit();
    const header = try testHeader(geometry);
    const first_allocator = try ExtentAllocator.init(std.heap.page_allocator, model.transport(), header, .{});
    const second_allocator = try ExtentAllocator.init(std.heap.page_allocator, model.transport(), header, .{});
    _ = try first_allocator.format();

    const Worker = struct {
        allocator: ExtentAllocator,
        request: ClaimRequest,
        result: ?Claim = null,

        fn run(self: *@This()) void {
            self.result = (self.allocator.claim(self.request) catch |err|
                std.debug.panic("claim failed: {s}", .{@errorName(err)})).claimed;
        }
    };
    var first = Worker{ .allocator = first_allocator, .request = testRequest(1) };
    var second = Worker{ .allocator = second_allocator, .request = testRequest(2) };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.result.?.extentIndex() != second.result.?.extentIndex());
}
