const std = @import("std");
const codec = @import("codec.zig");
const member_api = @import("member.zig");
const member_format = @import("member_format.zig");
const pool_authority = @import("pool_authority.zig");
const pool_catalog = @import("pool_catalog.zig");
const pool_catalog_graph = @import("pool_catalog_graph.zig");
const pool_catalog_page = @import("pool_catalog_page.zig");
const pool_genesis_payload = @import("pool_genesis_payload.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const RootSlot = enum { a, b };

pub const ValidRoot = struct {
    root: pool_catalog.Root,
    bytes: [pool_catalog.root_encoded_size]u8,
    digest: codec.Digest,
};

pub const RootCandidate = union(enum) {
    zero,
    unreadable: anyerror,
    invalid: struct {
        bytes: [pool_catalog.root_encoded_size]u8,
        reason: anyerror,
    },
    valid: ValidRoot,
};

pub const RootCopies = struct {
    a: RootCandidate,
    b: RootCandidate,
};

pub const RootSelection = struct {
    authoritative: ValidRoot,
    target: RootSlot,
    mirror_degraded: bool,
};

pub const LoadScratch = struct {
    root_bytes: [pool_catalog.root_encoded_size]u8 = undefined,
    page_bytes: [pool_catalog_graph.max_current_page_count][pool_catalog.page_size]u8 = undefined,
    images: [pool_catalog_graph.max_current_page_count]pool_catalog_graph.PageImage = undefined,
    image_count: usize = 0,

    pub fn graph(self: *const LoadScratch) pool_catalog_graph.Graph {
        return .{ .root_bytes = &self.root_bytes, .pages = self.images[0..self.image_count] };
    }
};

pub const LoadedCatalog = struct {
    selection: RootSelection,
    validated: pool_catalog_graph.ValidatedCatalog,
};

pub fn readRootCopies(claim: *const member_api.CatalogClaim) RootCopies {
    return .{
        .a = readRootCandidate(claim, .a),
        .b = readRootCandidate(claim, .b),
    };
}

pub fn selectAuthorityRoot(copies: RootCopies, authority: pool_authority.Authority) !RootSelection {
    if (authority.generation == 0 or codec.isZero(&authority.data_root_digest))
        return error.GenesisHasNoCatalogRoot;
    const a_matches = candidateMatches(copies.a, authority);
    const b_matches = candidateMatches(copies.b, authority);
    if (!a_matches and !b_matches) return error.AuthorityRootUnavailable;
    return .{
        .authoritative = if (a_matches) copies.a.valid else copies.b.valid,
        .target = if (a_matches and !b_matches) .b else .a,
        .mirror_degraded = a_matches != b_matches,
    };
}

pub fn loadAuthorityCatalog(
    member: *member_api.Member,
    authority: pool_authority.Authority,
    geometry: []const pool_catalog_graph.MemberGeometry,
    scratch: *LoadScratch,
) !LoadedCatalog {
    scratch.image_count = 0;
    const selection = try selectAuthorityRoot(readMemberRootCopies(member), authority);
    scratch.root_bytes = selection.authoritative.bytes;
    const root = selection.authoritative.root;

    try loadPage(member, scratch, root.volume_tree_root);
    try loadPage(member, scratch, root.name_index_root);
    try loadPage(member, scratch, root.allocator_root);
    try loadPage(member, scratch, root.retired_extent_root);
    try loadPage(member, scratch, root.metadata_allocator_root);

    if (!root.volume_tree_root.isNull()) {
        const volume_index_bytes = findLoadedPage(scratch, root.volume_tree_root) orelse
            return error.MissingVolumeIndexPage;
        var descriptors: [pool_catalog_graph.max_volume_count]pool_catalog.VolumeDescriptor = undefined;
        const decoded = try pool_catalog_page.decodeVolumeIndex(volume_index_bytes, &descriptors);
        for (decoded) |descriptor| {
            try loadPage(member, scratch, descriptor.header_page);
            try loadPage(member, scratch, descriptor.extent_map_root);
        }
    }

    const graph: pool_catalog_graph.Graph = .{
        .root_bytes = &scratch.root_bytes,
        .pages = scratch.images[0..scratch.image_count],
    };
    return .{
        .selection = selection,
        .validated = try pool_catalog_graph.validateGraph(.{
            .generation = authority.generation,
            .data_root_digest = authority.data_root_digest,
            .topology = authority.topology,
            .layout = authority.layout,
        }, graph, geometry),
    };
}

pub fn installAuthorityCatalog(
    target: *const member_api.CatalogClaim,
    authority: pool_authority.Authority,
    geometry: []const pool_catalog_graph.MemberGeometry,
    source: *const LoadScratch,
    verify_scratch: *LoadScratch,
) !void {
    const source_root = try pool_catalog.decodeRoot(&source.root_bytes);
    if (source_root.generation != authority.generation or
        !std.mem.eql(u8, &source_root.set_id, &authority.topology.set_id) or
        !std.mem.eql(u8, &(try pool_catalog.rootDigest(source_root)), &authority.data_root_digest))
        return error.CatalogAuthorityRootMismatch;
    _ = try pool_catalog_graph.validateGraph(.{
        .generation = authority.generation,
        .data_root_digest = authority.data_root_digest,
        .topology = authority.topology,
        .layout = authority.layout,
    }, source.graph(), geometry);

    const copies = readRootCopies(target);
    const write_a = try installRootNeedsWrite(copies.a, &source.root_bytes);
    const write_b = try installRootNeedsWrite(copies.b, &source.root_bytes);

    var writes: [pool_catalog_graph.max_current_page_count]member_api.RegionWrite = undefined;
    var write_count: usize = 0;
    var actual: [pool_catalog.page_size]u8 = undefined;
    for (source.images[0..source.image_count]) |image| {
        try target.read(image.offset, &actual);
        if (std.mem.eql(u8, &actual, image.bytes)) continue;
        if (!codec.isZero(&actual) and !isExpectedPrefix(&actual, image.bytes))
            return error.MetadataPageConflict;
        writes[write_count] = .{ .offset = image.offset, .bytes = image.bytes };
        write_count += 1;
    }
    try target.writeBatchDurable(writes[0..write_count]);
    if (write_a) try target.writeRootDurable(rootOffset(.a), &source.root_bytes);
    if (write_b) try target.writeRootDurable(rootOffset(.b), &source.root_bytes);

    const loaded = try loadAuthorityCatalog(target.member, authority, geometry, verify_scratch);
    if (loaded.selection.mirror_degraded) return error.CatalogInstallIncomplete;
}

pub fn selectInitializationTarget(
    copies: RootCopies,
    authority: pool_authority.Authority,
    expected_root: *const [pool_catalog.root_encoded_size]u8,
) !RootSlot {
    if (authority.generation != 0 or !codec.isZero(&authority.data_root_digest))
        return error.NotGenesisAuthority;
    const a = initializationCandidate(copies.a, expected_root) catch return error.MetadataRootSlotConflict;
    const b = initializationCandidate(copies.b, expected_root) catch return error.MetadataRootSlotConflict;
    if (a == .conflict or b == .conflict) return error.MetadataRootSlotConflict;
    if (a == .matching) return .a;
    if (b == .matching) return .b;
    return .a;
}

pub fn stageTransition(
    claim: *const member_api.CatalogClaim,
    authority: pool_authority.Authority,
    previous: *const pool_catalog_graph.ValidatedCatalog,
    current: *const pool_catalog_graph.ValidatedCatalog,
    current_graph: pool_catalog_graph.Graph,
) !RootSlot {
    const selection = try selectAuthorityRoot(readRootCopies(claim), authority);
    if (!std.meta.eql(selection.authoritative.root, previous.root))
        return error.MemberAuthorityRootMismatch;
    try validateGraphRoot(current, current_graph);
    try stagePages(claim, previous.currentPageSlice(), current, current_graph);
    try claim.writeRootDurable(rootOffset(selection.target), current_graph.root_bytes);
    return selection.target;
}

pub fn stageInitialization(
    claim: *const member_api.CatalogClaim,
    authority: pool_authority.Authority,
    current: *const pool_catalog_graph.ValidatedCatalog,
    current_graph: pool_catalog_graph.Graph,
) !RootSlot {
    const target = try selectInitializationTarget(readRootCopies(claim), authority, current_graph.root_bytes);
    try validateGraphRoot(current, current_graph);
    try stagePages(claim, &.{}, current, current_graph);
    try claim.writeRootDurable(rootOffset(target), current_graph.root_bytes);
    return target;
}

pub fn repairRootMirror(
    claim: *const member_api.CatalogClaim,
    authority: pool_authority.Authority,
    root_bytes: *const [pool_catalog.root_encoded_size]u8,
) !RootSlot {
    const selection = try selectAuthorityRoot(readRootCopies(claim), authority);
    const root = try pool_catalog.decodeRoot(root_bytes);
    if (!std.mem.eql(u8, &(try pool_catalog.rootDigest(root)), &authority.data_root_digest))
        return error.CatalogAuthorityDigestMismatch;
    try claim.writeRootDurable(rootOffset(selection.target), root_bytes);
    return selection.target;
}

fn readRootCandidate(claim: *const member_api.CatalogClaim, slot: RootSlot) RootCandidate {
    var bytes: [pool_catalog.root_encoded_size]u8 = undefined;
    claim.read(rootOffset(slot), &bytes) catch |err| return .{ .unreadable = err };
    return decodeRootCandidate(bytes);
}

fn readMemberRootCopies(member: *member_api.Member) RootCopies {
    return .{
        .a = readMemberRootCandidate(member, .a),
        .b = readMemberRootCandidate(member, .b),
    };
}

fn readMemberRootCandidate(member: *member_api.Member, slot: RootSlot) RootCandidate {
    var bytes: [pool_catalog.root_encoded_size]u8 = undefined;
    member.read(.metadata, rootOffset(slot), &bytes) catch |err| return .{ .unreadable = err };
    return decodeRootCandidate(bytes);
}

fn decodeRootCandidate(bytes: [pool_catalog.root_encoded_size]u8) RootCandidate {
    if (codec.isZero(&bytes)) return .zero;
    const root = pool_catalog.decodeRoot(&bytes) catch |err| return .{ .invalid = .{
        .bytes = bytes,
        .reason = err,
    } };
    return .{ .valid = .{
        .root = root,
        .bytes = bytes,
        .digest = pool_catalog.rootDigest(root) catch |err| return .{ .invalid = .{
            .bytes = bytes,
            .reason = err,
        } },
    } };
}

const InitializationCandidate = enum { zero, matching, conflict };

fn initializationCandidate(
    candidate: RootCandidate,
    expected_root: *const [pool_catalog.root_encoded_size]u8,
) !InitializationCandidate {
    return switch (candidate) {
        .zero => .zero,
        .valid => |valid| if (std.mem.eql(u8, &valid.bytes, expected_root)) .matching else .conflict,
        .invalid => |invalid| if (isExpectedPrefix(&invalid.bytes, expected_root)) .matching else .conflict,
        .unreadable => error.MetadataRootSlotUnreadable,
    };
}

fn isExpectedPrefix(
    actual: []const u8,
    expected: []const u8,
) bool {
    if (actual.len != expected.len) return false;
    var split: usize = 0;
    while (split < actual.len and actual[split] == expected[split]) split += 1;
    return split != 0 and split != actual.len and codec.isZero(actual[split..]);
}

fn installRootNeedsWrite(
    candidate: RootCandidate,
    expected: *const [pool_catalog.root_encoded_size]u8,
) !bool {
    return switch (candidate) {
        .zero => true,
        .valid => |valid| if (std.mem.eql(u8, &valid.bytes, expected)) false else error.MetadataRootSlotConflict,
        .invalid => |invalid| if (isExpectedPrefix(&invalid.bytes, expected)) true else error.MetadataRootSlotConflict,
        .unreadable => error.MetadataRootSlotUnreadable,
    };
}

fn candidateMatches(candidate: RootCandidate, authority: pool_authority.Authority) bool {
    return switch (candidate) {
        .valid => |valid| valid.root.generation == authority.generation and
            std.mem.eql(u8, &valid.root.set_id, &authority.topology.set_id) and
            std.mem.eql(u8, &valid.digest, &authority.data_root_digest),
        else => false,
    };
}

fn validateGraphRoot(
    current: *const pool_catalog_graph.ValidatedCatalog,
    graph: pool_catalog_graph.Graph,
) !void {
    const root = try pool_catalog.decodeRoot(graph.root_bytes);
    if (!std.meta.eql(root, current.root)) return error.StagedRootMismatch;
}

fn stagePages(
    claim: *const member_api.CatalogClaim,
    previous_pages: []const pool_catalog.PageReference,
    current: *const pool_catalog_graph.ValidatedCatalog,
    graph: pool_catalog_graph.Graph,
) !void {
    var writes: [pool_catalog_graph.max_current_page_count]member_api.RegionWrite = undefined;
    var write_count: usize = 0;
    var read_bytes: [pool_catalog.page_size]u8 = undefined;
    for (current.currentPageSlice()) |reference| {
        if (findReference(previous_pages, reference.offset)) |previous| {
            if (!std.mem.eql(u8, &previous.digest, &reference.digest))
                return error.MetadataPageModifiedInPlace;
            try claim.read(reference.offset, &read_bytes);
            if (!std.mem.eql(u8, &codec.blake3(&read_bytes), &reference.digest))
                return error.SharedPageDigestMismatch;
            continue;
        }
        const image = findImage(graph.pages, reference) orelse return error.MissingPageImage;
        writes[write_count] = .{ .offset = reference.offset, .bytes = image.bytes };
        write_count += 1;
    }
    try claim.writeBatchDurable(writes[0..write_count]);
}

fn findReference(references: []const pool_catalog.PageReference, offset: u64) ?pool_catalog.PageReference {
    for (references) |reference| if (reference.offset == offset) return reference;
    return null;
}

fn findImage(
    images: []const pool_catalog_graph.PageImage,
    reference: pool_catalog.PageReference,
) ?pool_catalog_graph.PageImage {
    for (images) |image| {
        if (image.offset != reference.offset) continue;
        if (!std.mem.eql(u8, &codec.blake3(image.bytes), &reference.digest)) return null;
        return image;
    }
    return null;
}

fn loadPage(
    member: *member_api.Member,
    scratch: *LoadScratch,
    reference: pool_catalog.PageReference,
) !void {
    if (reference.isNull()) return;
    try reference.validate();
    for (scratch.images[0..scratch.image_count]) |image| {
        if (image.offset != reference.offset) continue;
        if (!std.mem.eql(u8, &codec.blake3(image.bytes), &reference.digest))
            return error.ConflictingPageReference;
        return;
    }
    if (scratch.image_count == scratch.images.len) return error.TooManyCatalogPages;
    const index = scratch.image_count;
    try member.read(.metadata, reference.offset, &scratch.page_bytes[index]);
    if (!std.mem.eql(u8, &codec.blake3(&scratch.page_bytes[index]), &reference.digest))
        return error.PageDigestMismatch;
    scratch.images[index] = .{ .offset = reference.offset, .bytes = &scratch.page_bytes[index] };
    scratch.image_count += 1;
}

fn findLoadedPage(
    scratch: *const LoadScratch,
    reference: pool_catalog.PageReference,
) ?*const [pool_catalog.page_size]u8 {
    for (scratch.images[0..scratch.image_count]) |image| {
        if (image.offset == reference.offset) return image.bytes;
    }
    return null;
}

fn rootOffset(slot: RootSlot) u64 {
    return if (slot == .a) 0 else pool_catalog.page_size;
}

fn testAuthority(
    topology: pool_topology.Topology,
    layout: pool_layout.Layout,
    generation: u64,
    data_root_digest: codec.Digest,
) pool_authority.Authority {
    return .{
        .kind = if (generation == 0) .genesis else .generation_commit,
        .history_digest = @splat(7),
        .data_root_digest = data_root_digest,
        .topology = topology,
        .layout = layout,
        .membership_epoch = 1,
        .writer_term = 1,
        .generation = generation,
        .witness_count = 1,
    };
}

test "catalog store stages pages before root and preserves authority mirror" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const topology = try pool_topology.Topology.init(@splat(1), 1, @splat(0), &.{.{
        .member_id = @splat(2),
        .slot = 1,
        .control_role = pool_topology.voter_role,
        .role_flags = member_format.known_role_flags,
    }});
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const payload: pool_genesis_payload.GenesisPayload = .{ .topology = topology, .layout = layout };
    const header: member_format.Header = .{
        .header_sequence = 1,
        .incompat_features = member_format.dynamic_pool_incompat_feature |
            member_format.catalog_intent_incompat_feature,
        .set_id = topology.set_id,
        .member_id = topology.members[0].member_id,
        .member_slot = topology.members[0].slot,
        .member_count = 1,
        .role_flags = member_format.known_role_flags,
        .created_ns = 1,
        .member_bytes = 3 * 1024 * 1024,
        .logical_capacity = 1024 * 1024,
        .control = .{ .offset = 64 * 1024, .length = 64 * 1024 },
        .metadata = .{ .offset = 1024 * 1024, .length = 256 * 1024 },
        .data = .{ .offset = 2 * 1024 * 1024, .length = 1024 * 1024 },
        .metadata_block_size = 4096,
        .metadata_read_size = 512,
        .metadata_program_size = 512,
        .chunk_size = 1024 * 1024,
        .metadata_format_version = member_format.supported_metadata_format_version,
        .object_format_version = member_format.supported_object_format_version,
        .layout_format_version = member_format.dynamic_layout_format_version,
        .control_record_format_version = member_format.supported_control_record_format_version,
        .label = try member_format.Label.init("catalog-store"),
        .genesis_topology_digest = try pool_topology.digest(topology),
    };
    var member = try member_api.Member.createPoolAt(std.testing.io, tmp.dir, "member", header, payload, .{});
    defer member.deinit();
    var claim = try member.claimCatalog();
    defer claim.release() catch unreachable;

    const physical_bytes = try pool_catalog_page.encodePhysicalIntervals(.physical_allocator, 1, &.{.{
        .member_slot = 1,
        .physical_start = 0,
        .extent_count = 1,
    }});
    const metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(1, &.{.{
        .page_start = 4,
        .page_count = 60,
    }});
    const physical_reference = try pool_catalog_page.pageReference(2 * pool_catalog.page_size, &physical_bytes);
    const metadata_reference = try pool_catalog_page.pageReference(3 * pool_catalog.page_size, &metadata_bytes);
    const previous_root: pool_catalog.Root = .{
        .set_id = topology.set_id,
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .allocator_root = physical_reference,
        .metadata_allocator_root = metadata_reference,
        .extent_size = layout.chunk_size,
    };
    const previous_root_bytes = try pool_catalog.encodeRoot(previous_root);
    const previous_images = [_]pool_catalog_graph.PageImage{
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = metadata_reference.offset, .bytes = &metadata_bytes },
    };
    const geometry = [_]pool_catalog_graph.MemberGeometry{.{
        .member_id = header.member_id,
        .slot = header.member_slot,
        .metadata_length = header.metadata.length,
        .data_length = header.data.length,
    }};
    const previous_binding: pool_catalog_graph.AuthorityBinding = .{
        .generation = 1,
        .data_root_digest = try pool_catalog.rootDigest(previous_root),
        .topology = topology,
        .layout = layout,
    };
    const previous_graph: pool_catalog_graph.Graph = .{
        .root_bytes = &previous_root_bytes,
        .pages = &previous_images,
    };
    const previous = try pool_catalog_graph.validateGraph(previous_binding, previous_graph, &geometry);
    const genesis_authority = testAuthority(topology, layout, 0, @splat(0));
    var partial_root: [pool_catalog.root_encoded_size]u8 = @splat(0);
    @memcpy(partial_root[0 .. partial_root.len / 2], previous_root_bytes[0 .. previous_root_bytes.len / 2]);
    try std.testing.expectEqual(RootSlot.a, try selectInitializationTarget(.{
        .a = .{ .invalid = .{ .bytes = partial_root, .reason = error.InjectedFault } },
        .b = .zero,
    }, genesis_authority, &previous_root_bytes));
    try std.testing.expectEqual(RootSlot.a, try stageInitialization(&claim, genesis_authority, &previous, previous_graph));

    const previous_authority = testAuthority(topology, layout, 1, previous_binding.data_root_digest);
    try std.testing.expectEqual(RootSlot.b, try repairRootMirror(&claim, previous_authority, &previous_root_bytes));
    const redundant = readRootCopies(&claim);
    try std.testing.expect(candidateMatches(redundant.a, previous_authority));
    try std.testing.expect(candidateMatches(redundant.b, previous_authority));
    var load_scratch: LoadScratch = .{};
    const loaded_previous = try loadAuthorityCatalog(&member, previous_authority, &geometry, &load_scratch);
    try std.testing.expectEqual(@as(u64, 1), loaded_previous.validated.root.generation);
    try std.testing.expectEqual(@as(usize, 2), load_scratch.image_count);
    try std.testing.expect(!loaded_previous.selection.mirror_degraded);

    const next_metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(2, &.{
        .{ .page_start = 3, .page_count = 1, .state = .retired, .retired_generation = 2 },
        .{ .page_start = 5, .page_count = 59 },
    });
    const next_metadata_reference = try pool_catalog_page.pageReference(4 * pool_catalog.page_size, &next_metadata_bytes);
    const next_root: pool_catalog.Root = .{
        .set_id = topology.set_id,
        .generation = 2,
        .sequence = 2,
        .previous_root_digest = previous_binding.data_root_digest,
        .allocator_root = physical_reference,
        .metadata_allocator_root = next_metadata_reference,
        .extent_size = layout.chunk_size,
    };
    const next_root_bytes = try pool_catalog.encodeRoot(next_root);
    const next_images = [_]pool_catalog_graph.PageImage{
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = next_metadata_reference.offset, .bytes = &next_metadata_bytes },
    };
    const next_binding: pool_catalog_graph.AuthorityBinding = .{
        .generation = 2,
        .data_root_digest = try pool_catalog.rootDigest(next_root),
        .topology = topology,
        .layout = layout,
    };
    const next_graph: pool_catalog_graph.Graph = .{ .root_bytes = &next_root_bytes, .pages = &next_images };
    const next = try pool_catalog_graph.validateTransition(
        previous_binding,
        previous_graph,
        &geometry,
        next_binding,
        next_graph,
        &geometry,
    );
    try std.testing.expectEqual(
        RootSlot.a,
        try stageTransition(&claim, previous_authority, &previous, &next, next_graph),
    );
    const staged = readRootCopies(&claim);
    const next_authority = testAuthority(topology, layout, 2, next_binding.data_root_digest);
    try std.testing.expect(candidateMatches(staged.a, next_authority));
    try std.testing.expect(candidateMatches(staged.b, previous_authority));
    const loaded_next = try loadAuthorityCatalog(&member, next_authority, &geometry, &load_scratch);
    try std.testing.expectEqual(@as(u64, 2), loaded_next.validated.root.generation);
    try std.testing.expect(loaded_next.selection.mirror_degraded);

    var target = try member_api.Member.createPoolAt(std.testing.io, tmp.dir, "target", header, payload, .{});
    defer target.deinit();
    var target_fault: member_api.FaultController = .{ .fail_write_partial_at = 0 };
    target.setFaultController(&target_fault);
    var target_claim = try target.claimCatalog();
    var verify_scratch: LoadScratch = .{};
    try std.testing.expectError(
        error.InjectedFault,
        installAuthorityCatalog(&target_claim, next_authority, &geometry, &load_scratch, &verify_scratch),
    );
    try target_claim.release();
    try std.testing.expectError(error.WriteFrozen, target.close());

    var reopened_target = try member_api.Member.openAt(std.testing.io, tmp.dir, "target", .writable);
    defer reopened_target.deinit();
    var retry_claim = try reopened_target.claimCatalog();
    defer retry_claim.release() catch unreachable;
    try installAuthorityCatalog(&retry_claim, next_authority, &geometry, &load_scratch, &verify_scratch);
    const installed = try loadAuthorityCatalog(&reopened_target, next_authority, &geometry, &verify_scratch);
    try std.testing.expect(!installed.selection.mirror_degraded);

    var repair_fault: member_api.FaultController = .{ .fail_write_at = 0 };
    member.setFaultController(&repair_fault);
    try std.testing.expectError(
        error.InjectedFault,
        repairRootMirror(&claim, next_authority, &next_root_bytes),
    );
    try std.testing.expect(member.isFrozen());
    const after_failed_repair = readRootCopies(&claim);
    try std.testing.expect(candidateMatches(after_failed_repair.a, next_authority));
    try std.testing.expect(candidateMatches(after_failed_repair.b, previous_authority));
}
