//! In-memory CAW and crash model for shared-disk voting records.

const std = @import("std");
const voting = @import("voting.zig");

pub const Error = voting.Error || error{InvalidSlot};

pub const Result = enum {
    written,
    miscompare,
    indeterminate,
};

pub const Fault = enum {
    none,
    indeterminate_before,
    indeterminate_after,
};

fn spinLock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {}
}

pub const ModelVotingDisk = struct {
    mutex: std.atomic.Mutex = .unlocked,
    configuration: voting.Configuration,
    config_block: voting.Encoded,
    visible_members: [voting.max_members]voting.Encoded,
    stable_members: [voting.max_members]voting.Encoded,
    visible_authority: voting.Encoded,
    stable_authority: voting.Encoded,
    next_fault: Fault = .none,

    pub fn init(configuration: voting.Configuration) Error!ModelVotingDisk {
        const config_block = try voting.encodeConfiguration(configuration);
        var members: [voting.max_members]voting.Encoded = undefined;
        for (&members, 0..) |*member, slot| member.* = try voting.encodeMember(.{
            .domain_id = configuration.domain_id,
            .slot = @intCast(slot),
            .presence = null,
            .campaign = null,
            .vote = null,
        });
        const authority = try voting.encodeAuthority(.{
            .domain_id = configuration.domain_id,
            .active = null,
        });
        return .{
            .configuration = configuration,
            .config_block = config_block,
            .visible_members = members,
            .stable_members = members,
            .visible_authority = authority,
            .stable_authority = authority,
        };
    }

    pub fn readConfiguration(self: *ModelVotingDisk) voting.Encoded {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        return self.config_block;
    }

    pub fn readMember(self: *ModelVotingDisk, slot: u8) Error!voting.Encoded {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        try self.validateSlot(slot);
        return self.visible_members[slot];
    }

    pub fn readAuthority(self: *ModelVotingDisk) voting.Encoded {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        return self.visible_authority;
    }

    pub fn compareAndWriteMember(
        self: *ModelVotingDisk,
        slot: u8,
        expected: voting.Encoded,
        replacement: voting.Encoded,
    ) Error!Result {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        try self.validateSlot(slot);
        const current = &self.visible_members[slot];
        if (!std.mem.eql(u8, current, &expected)) return .miscompare;

        const previous = try voting.decodeMember(current);
        const next = try voting.decodeMember(&replacement);
        if (next.slot != slot) return error.InvalidSlot;
        try voting.validateMemberTransition(self.configuration, previous, next);
        return self.apply(current, replacement);
    }

    pub fn compareAndWriteAuthority(
        self: *ModelVotingDisk,
        expected: voting.Encoded,
        replacement: voting.Encoded,
    ) Error!Result {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        if (!std.mem.eql(u8, &self.visible_authority, &expected)) return .miscompare;

        const previous = try voting.decodeAuthority(&self.visible_authority);
        const next = try voting.decodeAuthority(&replacement);
        var members: [voting.max_members]voting.Member = undefined;
        for (members[0..self.configuration.member_count], 0..) |*member, slot| {
            member.* = try voting.decodeMember(&self.stable_members[slot]);
        }
        try voting.validateAuthorityTransition(
            self.configuration,
            previous,
            next,
            members[0..self.configuration.member_count],
        );
        return self.apply(&self.visible_authority, replacement);
    }

    pub fn injectNextFault(self: *ModelVotingDisk, fault: Fault) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.next_fault = fault;
    }

    pub fn stabilize(self: *ModelVotingDisk) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.stable_members = self.visible_members;
        self.stable_authority = self.visible_authority;
    }

    pub fn crash(self: *ModelVotingDisk) void {
        spinLock(&self.mutex);
        defer self.mutex.unlock();
        self.visible_members = self.stable_members;
        self.visible_authority = self.stable_authority;
        self.next_fault = .none;
    }

    fn validateSlot(self: *const ModelVotingDisk, slot: u8) Error!void {
        if (slot >= self.configuration.member_count) return error.InvalidSlot;
    }

    fn apply(
        self: *ModelVotingDisk,
        current: *voting.Encoded,
        replacement: voting.Encoded,
    ) Result {
        const fault = self.next_fault;
        self.next_fault = .none;
        if (fault == .indeterminate_before) return .indeterminate;
        current.* = replacement;
        return if (fault == .indeterminate_after) .indeterminate else .written;
    }
};

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

fn presence(slot: u8, sequence: u64) voting.Member {
    return .{
        .domain_id = id(1),
        .slot = slot,
        .presence = .{
            .incarnation_id = id(@intCast(0x80 + slot)),
            .incarnation_counter = 1,
            .sequence = sequence,
        },
        .campaign = null,
        .vote = null,
    };
}

fn proposal() voting.Proposal {
    return .{
        .ballot = .{
            .counter = 1,
            .candidate_slot = 0,
            .candidate_incarnation_id = id(0x80),
            .candidate_incarnation_counter = 1,
            .proposal_id = id(0xa0),
        },
        .cohort_bitmap = 0b00111,
    };
}

test "model voting disk compares full member blocks" {
    var disk = try ModelVotingDisk.init(testConfiguration());
    const initial = try disk.readMember(0);
    const first = try voting.encodeMember(presence(0, 1));
    try std.testing.expectEqual(
        Result.written,
        try disk.compareAndWriteMember(0, initial, first),
    );
    try std.testing.expectEqual(
        Result.miscompare,
        try disk.compareAndWriteMember(0, initial, first),
    );
}

test "model voting disk rolls unstable writes back on crash" {
    var disk = try ModelVotingDisk.init(testConfiguration());
    const initial = try disk.readMember(0);
    const first = try voting.encodeMember(presence(0, 1));
    disk.injectNextFault(.indeterminate_after);
    try std.testing.expectEqual(
        Result.indeterminate,
        try disk.compareAndWriteMember(0, initial, first),
    );
    try std.testing.expectEqualSlices(u8, &first, &(try disk.readMember(0)));
    disk.crash();
    try std.testing.expectEqualSlices(u8, &initial, &(try disk.readMember(0)));
}

test "model voting disk preserves stabilized writes" {
    var disk = try ModelVotingDisk.init(testConfiguration());
    const initial = try disk.readMember(0);
    const first = try voting.encodeMember(presence(0, 1));
    try std.testing.expectEqual(
        Result.written,
        try disk.compareAndWriteMember(0, initial, first),
    );
    disk.stabilize();
    disk.crash();
    try std.testing.expectEqualSlices(u8, &first, &(try disk.readMember(0)));
}

test "model voting disk publishes authority with durable votes" {
    var disk = try ModelVotingDisk.init(testConfiguration());
    const selected = proposal();
    for (0..3) |slot| {
        const member_slot: u8 = @intCast(slot);
        const initial = try disk.readMember(member_slot);
        var member = presence(member_slot, 1);
        if (slot == 0) member.campaign = selected;
        if (slot < 2) member.vote = selected;
        const replacement = try voting.encodeMember(member);
        try std.testing.expectEqual(
            Result.written,
            try disk.compareAndWriteMember(member_slot, initial, replacement),
        );
    }
    disk.stabilize();

    const initial_authority = disk.readAuthority();
    const replacement = try voting.encodeAuthority(.{
        .domain_id = id(1),
        .active = .{ .proposal = selected, .voter_bitmap = 0b00011 },
    });
    try std.testing.expectEqual(
        Result.written,
        try disk.compareAndWriteAuthority(initial_authority, replacement),
    );
    try std.testing.expectEqualSlices(u8, &replacement, &disk.readAuthority());
}

test "indeterminate-before model write leaves the block unchanged" {
    var disk = try ModelVotingDisk.init(testConfiguration());
    const initial = try disk.readMember(0);
    const first = try voting.encodeMember(presence(0, 1));
    disk.injectNextFault(.indeterminate_before);
    try std.testing.expectEqual(
        Result.indeterminate,
        try disk.compareAndWriteMember(0, initial, first),
    );
    try std.testing.expectEqualSlices(u8, &initial, &(try disk.readMember(0)));
}

test "authority rejects votes that have not crossed a durability barrier" {
    var disk = try ModelVotingDisk.init(testConfiguration());
    const selected = proposal();
    for (0..3) |slot| {
        const member_slot: u8 = @intCast(slot);
        const initial = try disk.readMember(member_slot);
        var member = presence(member_slot, 1);
        if (slot == 0) member.campaign = selected;
        if (slot < 2) member.vote = selected;
        const replacement = try voting.encodeMember(member);
        try std.testing.expectEqual(
            Result.written,
            try disk.compareAndWriteMember(member_slot, initial, replacement),
        );
    }

    const initial_authority = disk.readAuthority();
    const replacement = try voting.encodeAuthority(.{
        .domain_id = id(1),
        .active = .{ .proposal = selected, .voter_bitmap = 0b00011 },
    });
    try std.testing.expectError(
        error.MissingQuorum,
        disk.compareAndWriteAuthority(initial_authority, replacement),
    );
}
