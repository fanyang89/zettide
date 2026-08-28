//! Fixed-layout voting region over full-block conditional storage.

const std = @import("std");
const block = @import("conditional_block.zig");
const store = @import("store.zig");
const voting = @import("voting.zig");

pub const region_block_count: u64 = 2 + voting.max_members;
const configuration_offset: u64 = 0;
const authority_offset: u64 = 1;
const members_offset: u64 = 2;

pub const FormatResult = enum {
    formatted,
    already_formatted,
    pending,
};

pub const Error = error{
    RegionOutOfRange,
    Unformatted,
    FormatConflict,
    NonCanonicalPhysicalBlock,
    SnapshotMismatch,
    VotesChanged,
};

pub const MemberSnapshot = struct {
    physical: store.OwnedBytes,
    value: voting.Member,

    pub fn deinit(self: *MemberSnapshot) void {
        self.physical.deinit();
        self.* = undefined;
    }
};

pub const AuthoritySnapshot = struct {
    physical: store.OwnedBytes,
    value: voting.Authority,

    pub fn deinit(self: *AuthoritySnapshot) void {
        self.physical.deinit();
        self.* = undefined;
    }
};

pub const VotingRegion = struct {
    transport: block.ConditionalBlockTransport,
    base_block: u64,
    configuration: voting.Configuration,

    pub fn open(
        transport: block.ConditionalBlockTransport,
        allocator: std.mem.Allocator,
        base_block: u64,
    ) !VotingRegion {
        try validateRange(transport, base_block);
        try transport.stabilize();
        var physical = try allocateBlock(allocator, transport.geometry.logical_block_size);
        defer physical.deinit();
        try transport.readBlock(base_block + configuration_offset, physical.bytes);
        if (allZero(physical.bytes)) return error.Unformatted;
        const configuration = try voting.decodeConfiguration(try logicalEnvelope(physical.bytes));
        var region = VotingRegion{
            .transport = transport,
            .base_block = base_block,
            .configuration = configuration,
        };
        try region.verifyRecords(allocator);
        return region;
    }

    pub fn readMember(
        self: VotingRegion,
        allocator: std.mem.Allocator,
        slot: u8,
    ) !MemberSnapshot {
        if (slot >= self.configuration.member_count) return error.InvalidMember;
        var physical = try allocateBlock(allocator, self.transport.geometry.logical_block_size);
        errdefer physical.deinit();
        try self.transport.readBlock(self.memberBlock(slot), physical.bytes);
        const value = try voting.decodeMember(try logicalEnvelope(physical.bytes));
        try voting.validateMember(self.configuration, value);
        if (value.slot != slot) return error.InvalidMember;
        return .{ .physical = physical, .value = value };
    }

    pub fn readAuthority(
        self: VotingRegion,
        allocator: std.mem.Allocator,
    ) !AuthoritySnapshot {
        var physical = try allocateBlock(allocator, self.transport.geometry.logical_block_size);
        errdefer physical.deinit();
        try self.transport.readBlock(self.base_block + authority_offset, physical.bytes);
        const value = try voting.decodeAuthority(try logicalEnvelope(physical.bytes));
        try voting.validateAuthority(self.configuration, value);
        return .{ .physical = physical, .value = value };
    }

    pub fn compareAndWriteMember(
        self: VotingRegion,
        allocator: std.mem.Allocator,
        snapshot: *const MemberSnapshot,
        replacement: voting.Member,
    ) !block.CawResult {
        if (snapshot.physical.bytes.len != self.transport.geometry.logical_block_size)
            return error.SnapshotMismatch;
        const decoded = try voting.decodeMember(try logicalEnvelope(snapshot.physical.bytes));
        if (!std.meta.eql(decoded, snapshot.value)) return error.SnapshotMismatch;
        try voting.validateMemberTransition(self.configuration, snapshot.value, replacement);
        if (snapshot.value.slot != replacement.slot) return error.SnapshotMismatch;
        var encoded = try encodePhysical(
            allocator,
            self.transport.geometry.logical_block_size,
            try voting.encodeMember(replacement),
        );
        defer encoded.deinit();
        return self.transport.compareAndWrite(
            self.memberBlock(replacement.slot),
            snapshot.physical.bytes,
            encoded.bytes,
        );
    }

    /// Stabilizes an observed vote set, rereads the exact blocks, and only then
    /// attempts authority publication. The returned write still requires a
    /// final stabilize before the authority is crash durable.
    pub fn compareAndWriteAuthority(
        self: VotingRegion,
        allocator: std.mem.Allocator,
        snapshot: *const AuthoritySnapshot,
        replacement: voting.Authority,
    ) !block.CawResult {
        if (snapshot.physical.bytes.len != self.transport.geometry.logical_block_size)
            return error.SnapshotMismatch;
        const decoded = try voting.decodeAuthority(try logicalEnvelope(snapshot.physical.bytes));
        if (!std.meta.eql(decoded, snapshot.value)) return error.SnapshotMismatch;
        var observed: [voting.max_members]MemberSnapshot = undefined;
        var observed_count: usize = 0;
        defer for (observed[0..observed_count]) |*member| member.deinit();
        while (observed_count < self.configuration.member_count) : (observed_count += 1) {
            observed[observed_count] = try self.readMember(allocator, @intCast(observed_count));
        }

        try self.transport.stabilize();
        var durable: [voting.max_members]voting.Member = undefined;
        for (observed[0..observed_count], 0..) |*member, slot| {
            var current = try self.readMember(allocator, @intCast(slot));
            defer current.deinit();
            if (!std.mem.eql(u8, member.physical.bytes, current.physical.bytes))
                return error.VotesChanged;
            durable[slot] = current.value;
        }
        try voting.validateAuthorityTransition(
            self.configuration,
            snapshot.value,
            replacement,
            durable[0..observed_count],
        );

        var encoded = try encodePhysical(
            allocator,
            self.transport.geometry.logical_block_size,
            try voting.encodeAuthority(replacement),
        );
        defer encoded.deinit();
        return self.transport.compareAndWrite(
            self.base_block + authority_offset,
            snapshot.physical.bytes,
            encoded.bytes,
        );
    }

    pub fn stabilize(self: VotingRegion) !void {
        return self.transport.stabilize();
    }

    fn memberBlock(self: VotingRegion, slot: u8) u64 {
        return self.base_block + members_offset + slot;
    }

    fn verifyInitialRecords(self: VotingRegion, allocator: std.mem.Allocator) !void {
        const empty_authority = try voting.encodeAuthority(.{
            .domain_id = self.configuration.domain_id,
            .active = null,
        });
        try self.expectBlock(allocator, self.base_block + authority_offset, &empty_authority);
        for (0..voting.max_members) |slot| {
            if (slot < self.configuration.member_count) {
                const empty_member = try voting.encodeMember(.{
                    .domain_id = self.configuration.domain_id,
                    .slot = @intCast(slot),
                    .presence = null,
                    .campaign = null,
                    .vote = null,
                });
                try self.expectBlock(allocator, self.memberBlock(@intCast(slot)), &empty_member);
            } else {
                var physical = try allocateBlock(allocator, self.transport.geometry.logical_block_size);
                defer physical.deinit();
                try self.transport.readBlock(self.memberBlock(@intCast(slot)), physical.bytes);
                if (!allZero(physical.bytes)) return error.FormatConflict;
            }
        }
    }

    fn verifyRecords(self: VotingRegion, allocator: std.mem.Allocator) !void {
        var authority = try self.readAuthority(allocator);
        authority.deinit();
        for (0..voting.max_members) |slot| {
            if (slot < self.configuration.member_count) {
                var member = try self.readMember(allocator, @intCast(slot));
                member.deinit();
            } else {
                var physical = try allocateBlock(allocator, self.transport.geometry.logical_block_size);
                defer physical.deinit();
                try self.transport.readBlock(self.memberBlock(@intCast(slot)), physical.bytes);
                if (!allZero(physical.bytes)) return error.FormatConflict;
            }
        }
    }

    fn expectBlock(
        self: VotingRegion,
        allocator: std.mem.Allocator,
        block_index: u64,
        expected: *const voting.Encoded,
    ) !void {
        var physical = try allocateBlock(allocator, self.transport.geometry.logical_block_size);
        defer physical.deinit();
        try self.transport.readBlock(block_index, physical.bytes);
        const envelope = try logicalEnvelope(physical.bytes);
        if (!std.mem.eql(u8, envelope, expected)) return error.FormatConflict;
    }
};

pub fn format(
    transport: block.ConditionalBlockTransport,
    allocator: std.mem.Allocator,
    base_block: u64,
    configuration: voting.Configuration,
) !FormatResult {
    try validateRange(transport, base_block);
    const config_record = try voting.encodeConfiguration(configuration);
    var desired_config = try encodePhysical(
        allocator,
        transport.geometry.logical_block_size,
        config_record,
    );
    defer desired_config.deinit();
    var current_config = try allocateBlock(allocator, transport.geometry.logical_block_size);
    defer current_config.deinit();
    try transport.readBlock(base_block + configuration_offset, current_config.bytes);
    if (!allZero(current_config.bytes)) {
        if (!std.mem.eql(u8, current_config.bytes, desired_config.bytes))
            return error.FormatConflict;
        try transport.stabilize();
        const region = VotingRegion{
            .transport = transport,
            .base_block = base_block,
            .configuration = configuration,
        };
        try region.verifyRecords(allocator);
        return .already_formatted;
    }

    const authority = try voting.encodeAuthority(.{
        .domain_id = configuration.domain_id,
        .active = null,
    });
    switch (try installInitial(transport, allocator, base_block + authority_offset, &authority)) {
        .pending => return .pending,
        else => {},
    }
    for (0..configuration.member_count) |slot| {
        const member = try voting.encodeMember(.{
            .domain_id = configuration.domain_id,
            .slot = @intCast(slot),
            .presence = null,
            .campaign = null,
            .vote = null,
        });
        switch (try installInitial(
            transport,
            allocator,
            base_block + members_offset + slot,
            &member,
        )) {
            .pending => return .pending,
            else => {},
        }
    }
    for (configuration.member_count..voting.max_members) |slot| {
        var unused = try allocateBlock(allocator, transport.geometry.logical_block_size);
        defer unused.deinit();
        try transport.readBlock(base_block + members_offset + slot, unused.bytes);
        if (!allZero(unused.bytes)) return error.FormatConflict;
    }

    try transport.stabilize();
    const uncommitted = VotingRegion{
        .transport = transport,
        .base_block = base_block,
        .configuration = configuration,
    };
    try uncommitted.verifyInitialRecords(allocator);
    switch (try installInitialRecord(
        transport,
        allocator,
        base_block + configuration_offset,
        current_config.bytes,
        desired_config.bytes,
    )) {
        .pending => return .pending,
        else => {},
    }
    try transport.stabilize();
    return .formatted;
}

fn installInitial(
    transport: block.ConditionalBlockTransport,
    allocator: std.mem.Allocator,
    block_index: u64,
    record: *const voting.Encoded,
) !FormatResult {
    var current = try allocateBlock(allocator, transport.geometry.logical_block_size);
    defer current.deinit();
    try transport.readBlock(block_index, current.bytes);
    var desired = try encodePhysical(allocator, transport.geometry.logical_block_size, record.*);
    defer desired.deinit();
    return installInitialRecord(transport, allocator, block_index, current.bytes, desired.bytes);
}

fn installInitialRecord(
    transport: block.ConditionalBlockTransport,
    allocator: std.mem.Allocator,
    block_index: u64,
    current: []const u8,
    desired: []const u8,
) !FormatResult {
    if (std.mem.eql(u8, current, desired)) return .already_formatted;
    if (!allZero(current)) return error.FormatConflict;
    const result = try transport.compareAndWrite(block_index, current, desired);
    if (result == .written) return .formatted;
    var observed = try allocateBlock(allocator, transport.geometry.logical_block_size);
    defer observed.deinit();
    try transport.readBlock(block_index, observed.bytes);
    if (std.mem.eql(u8, observed.bytes, desired)) return .formatted;
    if (result == .indeterminate and std.mem.eql(u8, observed.bytes, current)) return .pending;
    return error.FormatConflict;
}

fn validateRange(transport: block.ConditionalBlockTransport, base_block: u64) !void {
    try transport.geometry.validate();
    const end = std.math.add(u64, base_block, region_block_count) catch
        return error.RegionOutOfRange;
    if (end > transport.geometry.block_count) return error.RegionOutOfRange;
}

fn encodePhysical(
    allocator: std.mem.Allocator,
    logical_block_size: u32,
    record: voting.Encoded,
) !store.OwnedBytes {
    var physical = try allocateBlock(allocator, logical_block_size);
    @memcpy(physical.bytes[0..voting.block_size], &record);
    return physical;
}

fn allocateBlock(allocator: std.mem.Allocator, logical_block_size: u32) !store.OwnedBytes {
    const bytes = try allocator.alloc(u8, logical_block_size);
    @memset(bytes, 0);
    return .{ .allocator = allocator, .bytes = bytes };
}

fn logicalEnvelope(physical: []const u8) Error![]const u8 {
    if (physical.len != 512 and physical.len != 4096) return error.NonCanonicalPhysicalBlock;
    if (!allZero(physical[voting.block_size..])) return error.NonCanonicalPhysicalBlock;
    return physical[0..voting.block_size];
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const ModelConditionalBlock = @import("model_conditional_block.zig").ModelConditionalBlock;
const ModelFault = @import("model_conditional_block.zig").Fault;

fn id(seed: u8) voting.Id {
    var result: voting.Id = undefined;
    for (&result, 0..) |*byte, index| byte.* = seed +% @as(u8, @intCast(index));
    return result;
}

fn testConfiguration() voting.Configuration {
    return .{
        .domain_id = id(1),
        .member_count = 3,
        .members = .{ id(0x20), id(0x40), id(0x60), @splat(0), @splat(0) },
    };
}

test "voting region formats and opens on 512 and 4096 byte blocks" {
    for ([_]u32{ 512, 4096 }) |block_size| {
        var model = try ModelConditionalBlock.init(std.testing.allocator, .{
            .logical_block_size = block_size,
            .block_count = region_block_count + 4,
        });
        defer model.deinit();
        const transport = model.transport();
        try std.testing.expectEqual(
            FormatResult.formatted,
            try format(transport, std.testing.allocator, 2, testConfiguration()),
        );
        const region = try VotingRegion.open(transport, std.testing.allocator, 2);
        try std.testing.expectEqual(@as(u8, 3), region.configuration.member_count);
        var member = try region.readMember(std.testing.allocator, 0);
        defer member.deinit();
        try std.testing.expectEqual(@as(?voting.Presence, null), member.value.presence);
    }
}

test "voting formatter recovers after an indeterminate initial write" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = region_block_count,
    });
    defer model.deinit();
    const transport = model.transport();
    model.injectNextFault(.indeterminate_pending);
    try std.testing.expectEqual(
        FormatResult.pending,
        try format(transport, std.testing.allocator, 0, testConfiguration()),
    );
    try std.testing.expectEqual(block.CawResult.written, model.completePending().?);
    try std.testing.expectEqual(
        FormatResult.formatted,
        try format(transport, std.testing.allocator, 0, testConfiguration()),
    );
    _ = try VotingRegion.open(transport, std.testing.allocator, 0);
}

test "configuration is absent when the pre-commit barrier fails" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = region_block_count,
    });
    defer model.deinit();
    const transport = model.transport();
    model.injectNextStabilizeFailure();
    try std.testing.expectError(
        error.InjectedStabilizeFailure,
        format(transport, std.testing.allocator, 0, testConfiguration()),
    );
    model.crash();
    try std.testing.expectError(
        error.Unformatted,
        VotingRegion.open(transport, std.testing.allocator, 0),
    );
}

test "formatted voting region reopens after member activity" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = region_block_count,
    });
    defer model.deinit();
    const transport = model.transport();
    try std.testing.expectEqual(
        FormatResult.formatted,
        try format(transport, std.testing.allocator, 0, testConfiguration()),
    );
    const region = try VotingRegion.open(transport, std.testing.allocator, 0);
    var member = try region.readMember(std.testing.allocator, 0);
    defer member.deinit();
    const replacement = voting.Member{
        .domain_id = testConfiguration().domain_id,
        .slot = 0,
        .presence = .{
            .incarnation_id = id(0x80),
            .incarnation_counter = 1,
            .sequence = 1,
        },
        .campaign = null,
        .vote = null,
    };
    try std.testing.expectEqual(
        block.CawResult.written,
        try region.compareAndWriteMember(std.testing.allocator, &member, replacement),
    );
    try region.stabilize();
    _ = try VotingRegion.open(transport, std.testing.allocator, 0);
    try std.testing.expectEqual(
        FormatResult.already_formatted,
        try format(transport, std.testing.allocator, 0, testConfiguration()),
    );
}

test "voting region rejects a snapshot value detached from its block" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = region_block_count,
    });
    defer model.deinit();
    const transport = model.transport();
    _ = try format(transport, std.testing.allocator, 0, testConfiguration());
    const region = try VotingRegion.open(transport, std.testing.allocator, 0);
    var member = try region.readMember(std.testing.allocator, 0);
    defer member.deinit();
    member.value.presence = .{
        .incarnation_id = id(0x80),
        .incarnation_counter = 1,
        .sequence = 1,
    };
    var replacement = member.value;
    replacement.presence.?.sequence = 2;
    try std.testing.expectError(
        error.SnapshotMismatch,
        region.compareAndWriteMember(std.testing.allocator, &member, replacement),
    );
}

test "authority publication stabilizes exact votes before CAW" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = region_block_count,
    });
    defer model.deinit();
    const transport = model.transport();
    _ = try format(transport, std.testing.allocator, 0, testConfiguration());
    const region = try VotingRegion.open(transport, std.testing.allocator, 0);

    for (0..3) |slot| {
        var member = try region.readMember(std.testing.allocator, @intCast(slot));
        defer member.deinit();
        var replacement = member.value;
        replacement.presence = .{
            .incarnation_id = id(@intCast(0x80 + slot)),
            .incarnation_counter = 1,
            .sequence = 1,
        };
        try std.testing.expectEqual(
            block.CawResult.written,
            try region.compareAndWriteMember(std.testing.allocator, &member, replacement),
        );
    }
    const proposal = voting.Proposal{
        .ballot = .{
            .counter = 1,
            .candidate_slot = 0,
            .candidate_incarnation_id = id(0x80),
            .candidate_incarnation_counter = 1,
            .proposal_id = id(0xa0),
        },
        .cohort_bitmap = 0b00111,
    };
    for (0..2) |slot| {
        var member = try region.readMember(std.testing.allocator, @intCast(slot));
        defer member.deinit();
        var replacement = member.value;
        replacement.presence.?.sequence += 1;
        replacement.vote = proposal;
        if (slot == 0) replacement.campaign = proposal;
        try std.testing.expectEqual(
            block.CawResult.written,
            try region.compareAndWriteMember(std.testing.allocator, &member, replacement),
        );
    }
    var authority = try region.readAuthority(std.testing.allocator);
    defer authority.deinit();
    const replacement = voting.Authority{
        .domain_id = testConfiguration().domain_id,
        .active = .{ .proposal = proposal, .voter_bitmap = 0b00011 },
    };
    model.injectNextStabilizeFailure();
    try std.testing.expectError(
        error.InjectedStabilizeFailure,
        region.compareAndWriteAuthority(std.testing.allocator, &authority, replacement),
    );
    try std.testing.expectEqual(
        block.CawResult.written,
        try region.compareAndWriteAuthority(std.testing.allocator, &authority, replacement),
    );
    try region.stabilize();
    model.crash();
    const reopened = try VotingRegion.open(transport, std.testing.allocator, 0);
    var recovered = try reopened.readAuthority(std.testing.allocator);
    defer recovered.deinit();
    try std.testing.expect(recovered.value.active.?.proposal.eql(proposal));
}

test "formatter resolves a delayed configuration commit" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = region_block_count,
    });
    defer model.deinit();
    const transport = model.transport();
    model.injectFaultAfter(4, .indeterminate_pending);
    try std.testing.expectEqual(
        FormatResult.pending,
        try format(transport, std.testing.allocator, 0, testConfiguration()),
    );
    try std.testing.expectEqual(block.CawResult.written, model.completePending().?);
    try std.testing.expectEqual(
        FormatResult.already_formatted,
        try format(transport, std.testing.allocator, 0, testConfiguration()),
    );
    _ = try VotingRegion.open(transport, std.testing.allocator, 0);
}

test "configuration rolls back when its final barrier fails" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 512,
        .block_count = region_block_count,
    });
    defer model.deinit();
    const transport = model.transport();
    model.injectStabilizeFailureAfter(1);
    try std.testing.expectError(
        error.InjectedStabilizeFailure,
        format(transport, std.testing.allocator, 0, testConfiguration()),
    );
    model.crash();
    try std.testing.expectError(
        error.Unformatted,
        VotingRegion.open(transport, std.testing.allocator, 0),
    );
    try std.testing.expectEqual(
        FormatResult.formatted,
        try format(transport, std.testing.allocator, 0, testConfiguration()),
    );
}

test "voting region rejects noncanonical 4096 byte padding" {
    var model = try ModelConditionalBlock.init(std.testing.allocator, .{
        .logical_block_size = 4096,
        .block_count = region_block_count,
    });
    defer model.deinit();
    const transport = model.transport();
    _ = try format(transport, std.testing.allocator, 0, testConfiguration());
    const expected = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(expected);
    const replacement = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(replacement);
    try transport.readBlock(0, expected);
    @memcpy(replacement, expected);
    replacement[replacement.len - 1] = 1;
    try std.testing.expectEqual(
        block.CawResult.written,
        try transport.compareAndWrite(0, expected, replacement),
    );
    try transport.stabilize();
    try std.testing.expectError(
        error.NonCanonicalPhysicalBlock,
        VotingRegion.open(transport, std.testing.allocator, 0),
    );
}
