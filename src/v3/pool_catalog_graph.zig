const std = @import("std");
const container = @import("../container.zig");
const codec = @import("codec.zig");
const member_format = @import("member_format.zig");
const pool_catalog = @import("pool_catalog.zig");
const pool_catalog_page = @import("pool_catalog_page.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const max_volume_count: usize = pool_catalog.max_leaf_volume_count;
pub const max_current_page_count: usize = 5 + 2 * max_volume_count;

pub const PageImage = struct {
    offset: u64,
    bytes: *const [pool_catalog.page_size]u8,
};

pub const Graph = struct {
    root_bytes: *const [pool_catalog.root_encoded_size]u8,
    pages: []const PageImage,
};

pub const AuthorityBinding = struct {
    generation: u64,
    data_root_digest: codec.Digest,
    topology: pool_topology.Topology,
    layout: pool_layout.Layout,
};

pub const MemberGeometry = struct {
    member_id: [16]u8,
    slot: u16,
    metadata_length: u64,
    data_length: u64,
};

pub const ValidatedCatalog = struct {
    root: pool_catalog.Root,
    descriptors: [max_volume_count]pool_catalog.VolumeDescriptor = undefined,
    names: [max_volume_count]pool_catalog_page.NameEntry = undefined,
    extent_runs: [max_volume_count][pool_catalog_page.max_extent_run_count]pool_catalog.ExtentRun = undefined,
    extent_counts: [max_volume_count]u16 = @splat(0),
    free: [pool_catalog_page.max_physical_interval_count]pool_catalog_page.PhysicalInterval = undefined,
    free_count: u16 = 0,
    retired: [pool_catalog_page.max_physical_interval_count]pool_catalog_page.PhysicalInterval = undefined,
    retired_count: u16 = 0,
    metadata: [pool_catalog_page.max_metadata_interval_count]pool_catalog_page.MetadataInterval = undefined,
    metadata_count: u16 = 0,
    current_pages: [max_current_page_count]pool_catalog.PageReference = undefined,
    current_page_count: u16 = 0,
    members: [pool_topology.max_member_count]MemberGeometry = undefined,
    member_count: u16 = 0,
    metadata_page_count: u64 = 0,

    pub fn descriptorSlice(self: *const ValidatedCatalog) []const pool_catalog.VolumeDescriptor {
        return self.descriptors[0..self.root.volume_count];
    }

    pub fn nameSlice(self: *const ValidatedCatalog) []const pool_catalog_page.NameEntry {
        return self.names[0..self.root.volume_count];
    }

    pub fn extentSlice(self: *const ValidatedCatalog, volume_index: usize) []const pool_catalog.ExtentRun {
        return self.extent_runs[volume_index][0..self.extent_counts[volume_index]];
    }

    pub fn freeSlice(self: *const ValidatedCatalog) []const pool_catalog_page.PhysicalInterval {
        return self.free[0..self.free_count];
    }

    pub fn retiredSlice(self: *const ValidatedCatalog) []const pool_catalog_page.PhysicalInterval {
        return self.retired[0..self.retired_count];
    }

    pub fn metadataSlice(self: *const ValidatedCatalog) []const pool_catalog_page.MetadataInterval {
        return self.metadata[0..self.metadata_count];
    }

    pub fn currentPageSlice(self: *const ValidatedCatalog) []const pool_catalog.PageReference {
        return self.current_pages[0..self.current_page_count];
    }

    pub fn memberSlice(self: *const ValidatedCatalog) []const MemberGeometry {
        return self.members[0..self.member_count];
    }
};

pub fn validateGraph(
    binding: AuthorityBinding,
    graph: Graph,
    members: []const MemberGeometry,
) !ValidatedCatalog {
    return validateGraphWithProtectedPages(binding, graph, members, &.{});
}

fn validateGraphWithProtectedPages(
    binding: AuthorityBinding,
    graph: Graph,
    members: []const MemberGeometry,
    protected_pages: []const pool_catalog.PageReference,
) !ValidatedCatalog {
    try validateInputs(binding, graph, members);
    const root = try pool_catalog.decodeRoot(graph.root_bytes);
    if (root.generation != binding.generation) return error.CatalogGenerationMismatch;
    if (!std.mem.eql(u8, &root.set_id, &binding.topology.set_id)) return error.CatalogSetMismatch;
    if (!std.mem.eql(u8, &(try pool_catalog.rootDigest(root)), &binding.data_root_digest))
        return error.CatalogAuthorityDigestMismatch;
    if (root.extent_size != binding.layout.chunk_size) return error.ExtentSizeMismatch;

    var result: ValidatedCatalog = .{ .root = root };
    result.member_count = @intCast(members.len);
    @memcpy(result.members[0..members.len], members);

    var data_geometry: [pool_topology.max_member_count]pool_catalog.MemberDataGeometry = undefined;
    var metadata_lengths: [pool_topology.max_member_count]u64 = undefined;
    for (members, 0..) |member, index| {
        data_geometry[index] = .{ .slot = member.slot, .data_length = member.data_length };
        metadata_lengths[index] = member.metadata_length;
    }
    result.metadata_page_count = metadata_lengths[0] / pool_catalog.page_size;

    if (!root.volume_tree_root.isNull()) {
        const bytes = try addReference(&result, graph, root.volume_tree_root);
        try validateLeafGeneration(bytes, .volume_index, root.generation);
        const descriptors = try pool_catalog_page.decodeVolumeIndex(bytes, &result.descriptors);
        if (descriptors.len != root.volume_count) return error.CatalogIndexCountMismatch;
    }
    if (!root.name_index_root.isNull()) {
        const bytes = try addReference(&result, graph, root.name_index_root);
        try validateLeafGeneration(bytes, .name_index, root.generation);
        const names = try pool_catalog_page.decodeNameIndex(bytes, &result.names);
        if (names.len != root.volume_count) return error.CatalogIndexCountMismatch;
    }

    const allocator_bytes = try addReference(&result, graph, root.allocator_root);
    try validateLeafGeneration(allocator_bytes, .physical_allocator, root.generation);
    result.free_count = @intCast((try pool_catalog_page.decodePhysicalIntervals(
        allocator_bytes,
        .physical_allocator,
        &result.free,
    )).len);

    if (!root.retired_extent_root.isNull()) {
        const retired_bytes = try addReference(&result, graph, root.retired_extent_root);
        try validateLeafGeneration(retired_bytes, .retired_extents, root.generation);
        result.retired_count = @intCast((try pool_catalog_page.decodePhysicalIntervals(
            retired_bytes,
            .retired_extents,
            &result.retired,
        )).len);
    }

    const metadata_bytes = try addReference(&result, graph, root.metadata_allocator_root);
    try validateLeafGeneration(metadata_bytes, .metadata_allocator, root.generation);
    result.metadata_count = @intCast((try pool_catalog_page.decodeMetadataAllocator(
        metadata_bytes,
        &result.metadata,
    )).len);

    try pool_catalog_page.validateCatalogIndexes(root, result.descriptorSlice(), result.nameSlice());
    var extent_maps: [max_volume_count]pool_catalog_page.VolumeExtentMap = undefined;
    for (result.descriptorSlice(), 0..) |descriptor, index| {
        const volume_header_bytes = try addReference(&result, graph, descriptor.header_page);
        try validateVolumeHeader(descriptor, volume_header_bytes);
        if (!descriptor.extent_map_root.isNull()) {
            const extent_bytes = try addReference(&result, graph, descriptor.extent_map_root);
            try validateLeafGeneration(extent_bytes, .extent_map, root.generation);
            result.extent_counts[index] = @intCast((try pool_catalog_page.decodeExtentMap(
                extent_bytes,
                descriptor.volume_id,
                &result.extent_runs[index],
            )).len);
        }
        const runs = result.extentSlice(index);
        try pool_catalog.validateVolumeForPool(
            root,
            descriptor,
            runs,
            binding.layout,
            binding.topology,
            data_geometry[0..members.len],
        );
        extent_maps[index] = .{ .volume_id = descriptor.volume_id, .runs = runs };
    }

    try pool_catalog_page.validatePhysicalIntervalsForMembers(result.freeSlice(), root.extent_size, data_geometry[0..members.len]);
    try pool_catalog_page.validatePhysicalIntervalsForMembers(result.retiredSlice(), root.extent_size, data_geometry[0..members.len]);
    try pool_catalog_page.validatePhysicalOwnership(
        extent_maps[0..root.volume_count],
        result.freeSlice(),
        result.retiredSlice(),
    );
    try pool_catalog_page.validateMetadataIntervalsForMembers(
        result.metadataSlice(),
        result.currentPageSlice(),
        protected_pages,
        metadata_lengths[0..members.len],
    );
    try validateMetadataCoverage(&result);
    return result;
}

fn validateInputs(binding: AuthorityBinding, graph: Graph, members: []const MemberGeometry) !void {
    try pool_topology.validate(binding.topology);
    try pool_layout.validate(binding.layout);
    _ = try pool_layout.dataAccess(binding.layout, binding.topology);
    if (binding.generation == 0 or codec.isZero(&binding.data_root_digest))
        return error.InvalidCatalogAuthority;
    if (members.len == 0 or members.len > binding.topology.member_count)
        return error.MissingMemberGeometry;
    for (members, 0..) |member, index| {
        const topology_member = pool_topology.findSlot(&binding.topology, member.slot) orelse
            return error.UnexpectedMemberGeometry;
        if (!std.mem.eql(u8, &member.member_id, &topology_member.member_id))
            return error.MemberGeometryIdentityMismatch;
        for (members[0..index]) |previous| {
            if (previous.slot == member.slot) return error.DuplicateMemberGeometry;
        }
        if (member.metadata_length < 3 * pool_catalog.page_size or
            member.metadata_length % pool_catalog.page_size != 0)
            return error.InvalidMemberMetadataGeometry;
        if (index != 0 and member.metadata_length != members[0].metadata_length)
            return error.InconsistentMemberMetadataGeometry;
    }
    for (binding.topology.memberSlice()) |member| {
        var found = false;
        for (members) |geometry| {
            if (geometry.slot == member.slot) found = true;
        }
        if (!found and member.state != .joining) return error.MissingMemberGeometry;
    }
    for (graph.pages, 0..) |image, index| {
        const reference: pool_catalog.PageReference = .{ .offset = image.offset, .digest = @splat(1) };
        try reference.validate();
        for (graph.pages[0..index]) |previous| {
            if (previous.offset == image.offset) return error.DuplicatePageImage;
        }
    }
}

fn validateVolumeHeader(
    descriptor: pool_catalog.VolumeDescriptor,
    bytes: *const [pool_catalog.page_size]u8,
) !void {
    const header = try container.Header.decode(bytes);
    if (!std.mem.eql(u8, &header.uuid, &descriptor.volume_id) or
        header.created_ns != descriptor.created_ns or header.logical_size != descriptor.logical_size or
        header.chunk_size != descriptor.extent_size or
        !std.mem.eql(u8, header.labelSlice(), descriptor.name.slice()))
        return error.VolumeHeaderMismatch;
    switch (descriptor.state) {
        .creating => if (header.state != .creating) return error.VolumeHeaderStateMismatch,
        .ready, .deleting => if (header.state != .ready) return error.VolumeHeaderStateMismatch,
    }
}

fn addReference(
    result: *ValidatedCatalog,
    graph: Graph,
    reference: pool_catalog.PageReference,
) !*const [pool_catalog.page_size]u8 {
    if (reference.isNull()) return error.MissingPageReference;
    for (result.currentPageSlice()) |current| {
        if (current.offset == reference.offset) return error.AliasedCatalogPageReference;
    }
    if (result.current_page_count == max_current_page_count) return error.TooManyCatalogPages;
    const bytes = try resolveReference(graph, reference);
    result.current_pages[result.current_page_count] = reference;
    result.current_page_count += 1;
    return bytes;
}

fn resolveReference(graph: Graph, reference: pool_catalog.PageReference) !*const [pool_catalog.page_size]u8 {
    try reference.validate();
    for (graph.pages) |image| {
        if (image.offset != reference.offset) continue;
        if (!std.mem.eql(u8, &codec.blake3(image.bytes), &reference.digest))
            return error.PageDigestMismatch;
        return image.bytes;
    }
    return error.MissingPageImage;
}

fn validateLeafGeneration(
    bytes: *const [pool_catalog.page_size]u8,
    kind: pool_catalog_page.Kind,
    root_generation: u64,
) !void {
    const header = try pool_catalog_page.decodeHeader(bytes, kind);
    if (header.generation > root_generation) return error.FutureCatalogPage;
}

fn validateMetadataCoverage(catalog: *const ValidatedCatalog) !void {
    var accounted: u64 = catalog.current_page_count;
    for (catalog.metadataSlice()) |interval|
        accounted = try std.math.add(u64, accounted, interval.page_count);
    if (accounted != catalog.metadata_page_count - 2) return error.IncompleteMetadataAllocator;
}

pub fn validateTransition(
    previous_binding: AuthorityBinding,
    previous_graph: Graph,
    previous_members: []const MemberGeometry,
    current_binding: AuthorityBinding,
    current_graph: Graph,
    current_members: []const MemberGeometry,
) !ValidatedCatalog {
    const previous = try validateGraph(previous_binding, previous_graph, previous_members);
    const current = try validateGraphWithProtectedPages(
        current_binding,
        current_graph,
        current_members,
        previous.currentPageSlice(),
    );
    if (!std.mem.eql(u8, &(try pool_topology.digest(previous_binding.topology)), &(try pool_topology.digest(current_binding.topology))))
        return error.TopologyChangedDuringCatalogGeneration;
    if (!std.mem.eql(u8, &(try pool_layout.digest(previous_binding.layout)), &(try pool_layout.digest(current_binding.layout))))
        return error.LayoutChangedDuringCatalogGeneration;
    try validateSnapshots(&previous, &current);
    return current;
}

pub fn validateNoNewDataMappings(
    previous: ?*const ValidatedCatalog,
    current: *const ValidatedCatalog,
) !void {
    for (current.descriptorSlice(), 0..) |descriptor, volume_index| {
        for (current.extentSlice(volume_index)) |run| {
            const previous_catalog = previous orelse return error.DataMappingRequiresDurabilityWitness;
            const previous_index = findVolumeIndex(previous_catalog, descriptor.volume_id) orelse
                return error.DataMappingRequiresDurabilityWitness;
            var logical_cursor = run.logical_start;
            const logical_end = try std.math.add(u64, run.logical_start, run.extent_count);
            while (logical_cursor < logical_end) {
                const previous_run = findMatchingRun(
                    previous_catalog.extentSlice(previous_index),
                    run,
                    logical_cursor,
                ) orelse return error.DataMappingRequiresDurabilityWitness;
                const previous_end = try std.math.add(u64, previous_run.logical_start, previous_run.extent_count);
                logical_cursor = @min(logical_end, previous_end);
            }
        }
    }
}

fn validateSnapshots(
    previous: *const ValidatedCatalog,
    current: *const ValidatedCatalog,
) !void {
    if (previous.root.generation == std.math.maxInt(u64) or
        current.root.generation != previous.root.generation + 1)
        return error.UnexpectedCatalogGeneration;
    if (!std.mem.eql(u8, &previous.root.set_id, &current.root.set_id)) return error.CatalogSetMismatch;
    if (!std.mem.eql(u8, &current.root.previous_root_digest, &(try pool_catalog.rootDigest(previous.root))))
        return error.InvalidPreviousRootDigest;
    if (current.root.sequence <= previous.root.sequence) return error.NonMonotonicRootSequence;
    if (previous.metadata_page_count != current.metadata_page_count)
        return error.MetadataGeometryChanged;

    if (previous.member_count != current.member_count) return error.TopologyChangedDuringCatalogGeneration;
    for (previous.memberSlice()) |previous_member| {
        const current_member = findMemberGeometry(current.memberSlice(), previous_member.slot) orelse
            return error.TopologyChangedDuringCatalogGeneration;
        if (!std.mem.eql(u8, &previous_member.member_id, &current_member.member_id))
            return error.TopologyChangedDuringCatalogGeneration;
        if (previous_member.metadata_length != current_member.metadata_length or
            previous_member.data_length != current_member.data_length)
            return error.MemberGeometryChangedDuringCatalogGeneration;
        try validatePhysicalSlotTransition(previous, current, previous_member.slot);
    }
    try validateMetadataTransition(previous, current);
}

const Mapping = struct {
    volume_id: [16]u8,
    logical_extent: u64,
};

const PhysicalState = union(enum) {
    absent,
    free,
    retired: u64,
    mapped: Mapping,
};

fn validatePhysicalSlotTransition(
    previous: ?*const ValidatedCatalog,
    current: *const ValidatedCatalog,
    slot: u16,
) !void {
    const previous_has_state = if (previous) |catalog| physicalSlotHasState(catalog, slot) else false;
    var cursor = firstPhysicalBoundary(previous, current, slot) orelse return;
    while (nextPhysicalBoundary(previous, current, slot, cursor)) |next| {
        const before = if (previous) |catalog| physicalStateAt(catalog, slot, cursor) else .absent;
        const after = physicalStateAt(current, slot, cursor);
        try validatePhysicalStateChange(
            before,
            after,
            previous_has_state,
            current.root.generation,
            if (previous) |catalog| catalog.root.generation else null,
        );
        cursor = next;
    }
}

fn validatePhysicalStateChange(
    before: PhysicalState,
    after: PhysicalState,
    previous_has_state: bool,
    current_generation: u64,
    reclaim_barrier_generation: ?u64,
) !void {
    switch (before) {
        .absent => switch (after) {
            .absent => {},
            .free => if (previous_has_state) return error.InventedPhysicalFreeSpace,
            .retired, .mapped => return error.InvalidPhysicalAllocationTransition,
        },
        .free => switch (after) {
            .free, .mapped, .absent => {},
            .retired => return error.InvalidPhysicalAllocationTransition,
        },
        .mapped => |before_mapping| switch (after) {
            .mapped => |after_mapping| {
                if (!std.mem.eql(u8, &before_mapping.volume_id, &after_mapping.volume_id) or
                    before_mapping.logical_extent != after_mapping.logical_extent)
                    return error.PhysicalExtentReassignedWithoutRetirement;
            },
            .retired => |generation| if (generation != current_generation)
                return error.InvalidNewRetirementGeneration,
            .absent, .free => return error.PhysicalExtentReusedBeforeRetirement,
        },
        .retired => |retired_generation| switch (after) {
            .retired => |generation| if (generation != retired_generation)
                return error.ChangedRetirementGeneration,
            .free, .mapped => if (reclaim_barrier_generation == null or
                retired_generation > reclaim_barrier_generation.?)
                return error.PhysicalExtentReclaimRequiresAuthorityBarrier,
            .absent => return error.InvalidPhysicalAllocationTransition,
        },
    }
}

fn physicalStateAt(catalog: *const ValidatedCatalog, slot: u16, position: u64) PhysicalState {
    for (catalog.freeSlice()) |interval| {
        if (interval.member_slot == slot and rangeContains(interval.physical_start, interval.extent_count, position))
            return .free;
    }
    for (catalog.retiredSlice()) |interval| {
        if (interval.member_slot == slot and rangeContains(interval.physical_start, interval.extent_count, position))
            return .{ .retired = interval.retired_generation };
    }
    for (catalog.descriptorSlice(), 0..) |descriptor, volume_index| {
        for (catalog.extentSlice(volume_index)) |run| {
            if (std.mem.indexOfScalar(u16, run.memberSlice(), slot) == null or
                !rangeContains(run.physical_start, run.extent_count, position)) continue;
            return .{ .mapped = .{
                .volume_id = descriptor.volume_id,
                .logical_extent = run.logical_start + (position - run.physical_start),
            } };
        }
    }
    return .absent;
}

fn physicalSlotHasState(catalog: *const ValidatedCatalog, slot: u16) bool {
    for (catalog.freeSlice()) |interval| if (interval.member_slot == slot) return true;
    for (catalog.retiredSlice()) |interval| if (interval.member_slot == slot) return true;
    for (0..catalog.root.volume_count) |volume_index| {
        for (catalog.extentSlice(volume_index)) |run| {
            if (std.mem.indexOfScalar(u16, run.memberSlice(), slot) != null) return true;
        }
    }
    return false;
}

fn firstPhysicalBoundary(
    previous: ?*const ValidatedCatalog,
    current: *const ValidatedCatalog,
    slot: u16,
) ?u64 {
    var boundary: ?u64 = null;
    if (previous) |catalog| collectPhysicalBoundaries(catalog, slot, null, &boundary);
    collectPhysicalBoundaries(current, slot, null, &boundary);
    return boundary;
}

fn nextPhysicalBoundary(
    previous: ?*const ValidatedCatalog,
    current: *const ValidatedCatalog,
    slot: u16,
    cursor: u64,
) ?u64 {
    var boundary: ?u64 = null;
    if (previous) |catalog| collectPhysicalBoundaries(catalog, slot, cursor, &boundary);
    collectPhysicalBoundaries(current, slot, cursor, &boundary);
    return boundary;
}

fn collectPhysicalBoundaries(
    catalog: *const ValidatedCatalog,
    slot: u16,
    after: ?u64,
    boundary: *?u64,
) void {
    for (catalog.freeSlice()) |interval| if (interval.member_slot == slot) {
        considerBoundary(interval.physical_start, after, boundary);
        considerBoundary(interval.physical_start + interval.extent_count, after, boundary);
    };
    for (catalog.retiredSlice()) |interval| if (interval.member_slot == slot) {
        considerBoundary(interval.physical_start, after, boundary);
        considerBoundary(interval.physical_start + interval.extent_count, after, boundary);
    };
    for (0..catalog.root.volume_count) |volume_index| {
        for (catalog.extentSlice(volume_index)) |run| {
            if (std.mem.indexOfScalar(u16, run.memberSlice(), slot) == null) continue;
            considerBoundary(run.physical_start, after, boundary);
            considerBoundary(run.physical_start + run.extent_count, after, boundary);
        }
    }
}

const MetadataState = union(enum) {
    absent,
    free,
    retired: u64,
    used: codec.Digest,
};

fn validateMetadataTransition(
    previous: *const ValidatedCatalog,
    current: *const ValidatedCatalog,
) !void {
    var cursor: u64 = 2;
    while (nextMetadataBoundary(previous, current, cursor)) |next| {
        const before = metadataStateAt(previous, cursor);
        const after = metadataStateAt(current, cursor);
        switch (before) {
            .absent => return error.IncompletePreviousMetadataAllocator,
            .free => switch (after) {
                .free, .used => {},
                .absent, .retired => return error.InvalidMetadataAllocationTransition,
            },
            .used => |before_digest| switch (after) {
                .used => |after_digest| if (!std.mem.eql(u8, &before_digest, &after_digest))
                    return error.MetadataPageModifiedInPlace,
                .retired => |generation| if (generation != current.root.generation)
                    return error.InvalidNewRetirementGeneration,
                .absent, .free => return error.MetadataPageReusedBeforeRetirement,
            },
            .retired => |retired_generation| switch (after) {
                .retired => |generation| if (generation != retired_generation)
                    return error.ChangedRetirementGeneration,
                .free, .used => if (retired_generation > previous.root.generation)
                    return error.MetadataPageReclaimRequiresAuthorityBarrier,
                .absent => return error.InvalidMetadataAllocationTransition,
            },
        }
        cursor = next;
    }
    if (cursor != previous.metadata_page_count) return error.IncompleteMetadataAllocator;
}

fn metadataStateAt(catalog: *const ValidatedCatalog, page: u64) MetadataState {
    for (catalog.currentPageSlice()) |reference| {
        if (reference.offset / pool_catalog.page_size == page) return .{ .used = reference.digest };
    }
    for (catalog.metadataSlice()) |interval| {
        if (!rangeContains(interval.page_start, interval.page_count, page)) continue;
        return switch (interval.state) {
            .free => .free,
            .retired => .{ .retired = interval.retired_generation },
        };
    }
    return .absent;
}

fn nextMetadataBoundary(
    previous: *const ValidatedCatalog,
    current: *const ValidatedCatalog,
    cursor: u64,
) ?u64 {
    var boundary: ?u64 = null;
    collectMetadataBoundaries(previous, cursor, &boundary);
    collectMetadataBoundaries(current, cursor, &boundary);
    return boundary;
}

fn collectMetadataBoundaries(catalog: *const ValidatedCatalog, after: u64, boundary: *?u64) void {
    considerBoundary(catalog.metadata_page_count, after, boundary);
    for (catalog.currentPageSlice()) |reference| {
        const page = reference.offset / pool_catalog.page_size;
        considerBoundary(page, after, boundary);
        considerBoundary(page + 1, after, boundary);
    }
    for (catalog.metadataSlice()) |interval| {
        considerBoundary(interval.page_start, after, boundary);
        considerBoundary(interval.page_start + interval.page_count, after, boundary);
    }
}

fn considerBoundary(candidate: u64, after: ?u64, boundary: *?u64) void {
    if (after) |value| if (candidate <= value) return;
    if (boundary.* == null or candidate < boundary.*.?) boundary.* = candidate;
}

fn rangeContains(start: u64, count: anytype, position: u64) bool {
    return position >= start and position < start + @as(u64, @intCast(count));
}

fn findVolumeIndex(catalog: *const ValidatedCatalog, volume_id: [16]u8) ?usize {
    for (catalog.descriptorSlice(), 0..) |descriptor, index| {
        if (std.mem.eql(u8, &descriptor.volume_id, &volume_id)) return index;
    }
    return null;
}

fn findMatchingRun(
    runs: []const pool_catalog.ExtentRun,
    current: pool_catalog.ExtentRun,
    logical_extent: u64,
) ?pool_catalog.ExtentRun {
    for (runs) |candidate| {
        if (!rangeContains(candidate.logical_start, candidate.extent_count, logical_extent)) continue;
        const offset = logical_extent - current.logical_start;
        const candidate_offset = logical_extent - candidate.logical_start;
        if (current.physical_start + offset != candidate.physical_start + candidate_offset or
            current.state != candidate.state or current.member_count != candidate.member_count or
            !std.mem.eql(u16, current.memberSlice(), candidate.memberSlice())) continue;
        return candidate;
    }
    return null;
}

fn findMemberGeometry(members: []const MemberGeometry, slot: u16) ?MemberGeometry {
    for (members) |member| if (member.slot == slot) return member;
    return null;
}

fn testTopology() !pool_topology.Topology {
    return pool_topology.Topology.init(@splat(1), 1, @splat(0), &.{.{
        .member_id = @splat(2),
        .slot = 1,
        .control_role = pool_topology.voter_role,
        .role_flags = 3,
    }});
}

test "catalog graph resolves authority-bound pages" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const physical_bytes = try pool_catalog_page.encodePhysicalIntervals(.physical_allocator, 1, &.{.{
        .member_slot = 1,
        .physical_start = 0,
        .extent_count = 4,
    }});
    const metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(1, &.{.{
        .page_start = 4,
        .page_count = 4,
    }});
    const physical_reference = try pool_catalog_page.pageReference(2 * pool_catalog.page_size, &physical_bytes);
    const metadata_reference = try pool_catalog_page.pageReference(3 * pool_catalog.page_size, &metadata_bytes);
    const root: pool_catalog.Root = .{
        .set_id = topology.set_id,
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .allocator_root = physical_reference,
        .metadata_allocator_root = metadata_reference,
        .extent_size = layout.chunk_size,
    };
    const root_bytes = try pool_catalog.encodeRoot(root);
    const images = [_]PageImage{
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = metadata_reference.offset, .bytes = &metadata_bytes },
    };
    const geometry = [_]MemberGeometry{.{
        .member_id = @splat(2),
        .slot = 1,
        .metadata_length = 8 * pool_catalog.page_size,
        .data_length = 4 * 1024 * 1024,
    }};
    const catalog = try validateGraph(.{
        .generation = 1,
        .data_root_digest = try pool_catalog.rootDigest(root),
        .topology = topology,
        .layout = layout,
    }, .{ .root_bytes = &root_bytes, .pages = &images }, &geometry);
    try std.testing.expectEqual(@as(u16, 1), catalog.free_count);
    try std.testing.expectEqual(@as(u16, 1), catalog.metadata_count);
    try std.testing.expectEqual(@as(u16, 2), catalog.current_page_count);

    const joining_members = [_]pool_topology.Member{
        topology.members[0],
        .{ .member_id = @splat(3), .slot = 2, .state = .joining, .role_flags = member_format.data_role },
    };
    const joining_topology = try pool_topology.Topology.init(
        topology.set_id,
        topology.epoch + 1,
        try pool_topology.digest(topology),
        &joining_members,
    );
    _ = try validateGraph(.{
        .generation = 1,
        .data_root_digest = try pool_catalog.rootDigest(root),
        .topology = joining_topology,
        .layout = layout,
    }, .{ .root_bytes = &root_bytes, .pages = &images }, &geometry);

    var future_physical_bytes = try pool_catalog_page.encodePhysicalIntervals(.physical_allocator, 2, catalog.freeSlice());
    var future_images = images;
    future_images[0].bytes = &future_physical_bytes;
    var future_root = root;
    future_root.allocator_root = try pool_catalog_page.pageReference(physical_reference.offset, &future_physical_bytes);
    const future_root_bytes = try pool_catalog.encodeRoot(future_root);
    try std.testing.expectError(error.FutureCatalogPage, validateGraph(.{
        .generation = 1,
        .data_root_digest = try pool_catalog.rootDigest(future_root),
        .topology = topology,
        .layout = layout,
    }, .{ .root_bytes = &future_root_bytes, .pages = &future_images }, &geometry));
}

test "nonempty catalog graph binds volume header and extent owner" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    var volume_header: container.Header = .{
        .sequence = 1,
        .state = .ready,
        .uuid = @splat(9),
        .created_ns = 123,
        .logical_size = 1024 * 1024,
        .block_count = 256,
    };
    @memcpy(volume_header.label[0..5], "alpha");
    volume_header.label_len = 5;
    const volume_header_bytes = volume_header.encode();
    const volume_header_reference = try pool_catalog_page.pageReference(6 * pool_catalog.page_size, &volume_header_bytes);
    const extent_bytes = try pool_catalog_page.encodeExtentMap(1, @splat(9), &.{.{
        .logical_start = 0,
        .physical_start = 0,
        .extent_count = 1,
        .state = .mapped,
        .member_count = 1,
        .member_slots = .{ 1, 0, 0 },
    }});
    const extent_reference = try pool_catalog_page.pageReference(7 * pool_catalog.page_size, &extent_bytes);
    const descriptor: pool_catalog.VolumeDescriptor = .{
        .volume_id = @splat(9),
        .state = .ready,
        .provisioning = .thin,
        .created_ns = 123,
        .logical_size = 1024 * 1024,
        .header_page = volume_header_reference,
        .extent_map_root = extent_reference,
        .allocated_extent_count = 1,
        .extent_size = 1024 * 1024,
        .name = try pool_catalog.Name.init("alpha"),
    };
    const volume_bytes = try pool_catalog_page.encodeVolumeIndex(1, &.{descriptor});
    const name_bytes = try pool_catalog_page.encodeNameIndex(1, &.{.{
        .volume_id = descriptor.volume_id,
        .name = descriptor.name,
    }});
    const physical_bytes = try pool_catalog_page.encodePhysicalIntervals(.physical_allocator, 1, &.{.{
        .member_slot = 1,
        .physical_start = 1,
        .extent_count = 3,
    }});
    const metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(1, &.{.{
        .page_start = 8,
        .page_count = 2,
    }});
    const volume_reference = try pool_catalog_page.pageReference(2 * pool_catalog.page_size, &volume_bytes);
    const name_reference = try pool_catalog_page.pageReference(3 * pool_catalog.page_size, &name_bytes);
    const physical_reference = try pool_catalog_page.pageReference(4 * pool_catalog.page_size, &physical_bytes);
    const metadata_reference = try pool_catalog_page.pageReference(5 * pool_catalog.page_size, &metadata_bytes);
    const root: pool_catalog.Root = .{
        .set_id = topology.set_id,
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .volume_tree_root = volume_reference,
        .name_index_root = name_reference,
        .allocator_root = physical_reference,
        .metadata_allocator_root = metadata_reference,
        .volume_count = 1,
        .extent_size = layout.chunk_size,
    };
    const root_bytes = try pool_catalog.encodeRoot(root);
    const images = [_]PageImage{
        .{ .offset = volume_reference.offset, .bytes = &volume_bytes },
        .{ .offset = name_reference.offset, .bytes = &name_bytes },
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = metadata_reference.offset, .bytes = &metadata_bytes },
        .{ .offset = volume_header_reference.offset, .bytes = &volume_header_bytes },
        .{ .offset = extent_reference.offset, .bytes = &extent_bytes },
    };
    const geometry = [_]MemberGeometry{.{
        .member_id = @splat(2),
        .slot = 1,
        .metadata_length = 10 * pool_catalog.page_size,
        .data_length = 4 * 1024 * 1024,
    }};
    const catalog = try validateGraph(.{
        .generation = 1,
        .data_root_digest = try pool_catalog.rootDigest(root),
        .topology = topology,
        .layout = layout,
    }, .{ .root_bytes = &root_bytes, .pages = &images }, &geometry);
    try std.testing.expectEqual(@as(u32, 1), catalog.root.volume_count);
    try std.testing.expectEqual(@as(u16, 1), catalog.extent_counts[0]);
}

test "public transition validates COW metadata quarantine" {
    const topology = try testTopology();
    const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
    const physical_bytes = try pool_catalog_page.encodePhysicalIntervals(.physical_allocator, 1, &.{.{
        .member_slot = 1,
        .physical_start = 0,
        .extent_count = 4,
    }});
    const previous_metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(1, &.{.{
        .page_start = 4,
        .page_count = 6,
    }});
    const physical_reference = try pool_catalog_page.pageReference(2 * pool_catalog.page_size, &physical_bytes);
    const previous_metadata_reference = try pool_catalog_page.pageReference(3 * pool_catalog.page_size, &previous_metadata_bytes);
    const previous_root: pool_catalog.Root = .{
        .set_id = topology.set_id,
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .allocator_root = physical_reference,
        .metadata_allocator_root = previous_metadata_reference,
        .extent_size = layout.chunk_size,
    };
    const previous_root_bytes = try pool_catalog.encodeRoot(previous_root);
    const previous_images = [_]PageImage{
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = previous_metadata_reference.offset, .bytes = &previous_metadata_bytes },
    };

    const current_metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(2, &.{
        .{ .page_start = 3, .page_count = 1, .state = .retired, .retired_generation = 2 },
        .{ .page_start = 5, .page_count = 5 },
    });
    const current_metadata_reference = try pool_catalog_page.pageReference(4 * pool_catalog.page_size, &current_metadata_bytes);
    const current_root: pool_catalog.Root = .{
        .set_id = topology.set_id,
        .generation = 2,
        .sequence = 2,
        .previous_root_digest = try pool_catalog.rootDigest(previous_root),
        .allocator_root = physical_reference,
        .metadata_allocator_root = current_metadata_reference,
        .extent_size = layout.chunk_size,
    };
    const current_root_bytes = try pool_catalog.encodeRoot(current_root);
    const current_images = [_]PageImage{
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = current_metadata_reference.offset, .bytes = &current_metadata_bytes },
    };
    const geometry = [_]MemberGeometry{.{
        .member_id = @splat(2),
        .slot = 1,
        .metadata_length = 10 * pool_catalog.page_size,
        .data_length = 4 * 1024 * 1024,
    }};
    const previous_binding: AuthorityBinding = .{
        .generation = 1,
        .data_root_digest = try pool_catalog.rootDigest(previous_root),
        .topology = topology,
        .layout = layout,
    };
    const current_binding: AuthorityBinding = .{
        .generation = 2,
        .data_root_digest = try pool_catalog.rootDigest(current_root),
        .topology = topology,
        .layout = layout,
    };
    const catalog = try validateTransition(
        previous_binding,
        .{ .root_bytes = &previous_root_bytes, .pages = &previous_images },
        &geometry,
        current_binding,
        .{ .root_bytes = &current_root_bytes, .pages = &current_images },
        &geometry,
    );
    try std.testing.expectEqual(@as(u64, 2), catalog.root.generation);

    const reclaimed_metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(3, &.{
        .{ .page_start = 3, .page_count = 1 },
        .{ .page_start = 4, .page_count = 1, .state = .retired, .retired_generation = 3 },
        .{ .page_start = 6, .page_count = 4 },
    });
    const reclaimed_metadata_reference = try pool_catalog_page.pageReference(5 * pool_catalog.page_size, &reclaimed_metadata_bytes);
    const reclaimed_root: pool_catalog.Root = .{
        .set_id = topology.set_id,
        .generation = 3,
        .sequence = 3,
        .previous_root_digest = try pool_catalog.rootDigest(current_root),
        .allocator_root = physical_reference,
        .metadata_allocator_root = reclaimed_metadata_reference,
        .extent_size = layout.chunk_size,
    };
    const reclaimed_root_bytes = try pool_catalog.encodeRoot(reclaimed_root);
    const reclaimed_images = [_]PageImage{
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = reclaimed_metadata_reference.offset, .bytes = &reclaimed_metadata_bytes },
    };
    const reclaimed = try validateTransition(
        current_binding,
        .{ .root_bytes = &current_root_bytes, .pages = &current_images },
        &geometry,
        .{
            .generation = 3,
            .data_root_digest = try pool_catalog.rootDigest(reclaimed_root),
            .topology = topology,
            .layout = layout,
        },
        .{ .root_bytes = &reclaimed_root_bytes, .pages = &reclaimed_images },
        &geometry,
    );
    try std.testing.expectEqual(pool_catalog_page.MetadataIntervalState.free, reclaimed.metadata[0].state);
    try std.testing.expectEqual(@as(u64, 3), reclaimed.metadata[1].retired_generation);
}

fn testTransitionRoot(generation: u64, previous_digest: codec.Digest) pool_catalog.Root {
    return .{
        .set_id = @splat(1),
        .generation = generation,
        .sequence = generation,
        .previous_root_digest = previous_digest,
        .volume_tree_root = .{ .offset = 2 * pool_catalog.page_size, .digest = @splat(2) },
        .name_index_root = .{ .offset = 3 * pool_catalog.page_size, .digest = @splat(3) },
        .allocator_root = .{ .offset = 4 * pool_catalog.page_size, .digest = @splat(4) },
        .retired_extent_root = .{ .offset = 5 * pool_catalog.page_size, .digest = @splat(5) },
        .metadata_allocator_root = .{ .offset = 6 * pool_catalog.page_size, .digest = @splat(6) },
        .volume_count = 1,
        .extent_size = 1024 * 1024,
    };
}

fn testTransitionCatalog(root: pool_catalog.Root) ValidatedCatalog {
    var catalog: ValidatedCatalog = .{ .root = root };
    catalog.descriptors[0].volume_id = @splat(9);
    catalog.member_count = 1;
    catalog.members[0] = .{
        .member_id = @splat(2),
        .slot = 1,
        .metadata_length = 8 * pool_catalog.page_size,
        .data_length = 4 * 1024 * 1024,
    };
    catalog.metadata_page_count = 8;
    return catalog;
}

test "catalog transition quarantines removed physical and metadata pages" {
    const previous_root = testTransitionRoot(1, @splat(0));
    var previous = testTransitionCatalog(previous_root);
    previous.extent_counts[0] = 1;
    previous.extent_runs[0][0] = .{
        .logical_start = 0,
        .physical_start = 0,
        .extent_count = 1,
        .state = .mapped,
        .member_count = 1,
        .member_slots = .{ 1, 0, 0 },
    };
    previous.free_count = 1;
    previous.free[0] = .{ .member_slot = 1, .physical_start = 1, .extent_count = 3 };
    previous.current_page_count = 3;
    previous.current_pages[0] = .{ .offset = 2 * pool_catalog.page_size, .digest = @splat(2) };
    previous.current_pages[1] = .{ .offset = 3 * pool_catalog.page_size, .digest = @splat(3) };
    previous.current_pages[2] = .{ .offset = 4 * pool_catalog.page_size, .digest = @splat(4) };
    previous.metadata_count = 1;
    previous.metadata[0] = .{ .page_start = 5, .page_count = 3 };

    const current_root = testTransitionRoot(2, try pool_catalog.rootDigest(previous_root));
    var current = testTransitionCatalog(current_root);
    current.free_count = 1;
    current.free[0] = previous.free[0];
    current.retired_count = 1;
    current.retired[0] = .{
        .member_slot = 1,
        .physical_start = 0,
        .extent_count = 1,
        .retired_generation = 2,
    };
    current.current_page_count = 3;
    current.current_pages[0] = previous.current_pages[0];
    current.current_pages[1] = previous.current_pages[1];
    current.current_pages[2] = .{ .offset = 5 * pool_catalog.page_size, .digest = @splat(5) };
    current.metadata_count = 2;
    current.metadata[0] = .{
        .page_start = 4,
        .page_count = 1,
        .state = .retired,
        .retired_generation = 2,
    };
    current.metadata[1] = .{ .page_start = 6, .page_count = 2 };
    try validateSnapshots(&previous, &current);
    try validateNoNewDataMappings(&previous, &current);
    try std.testing.expectError(
        error.DataMappingRequiresDurabilityWitness,
        validateNoNewDataMappings(&current, &previous),
    );

    var invalid = current;
    invalid.retired[0].retired_generation = 1;
    try std.testing.expectError(
        error.InvalidNewRetirementGeneration,
        validateSnapshots(&previous, &invalid),
    );

    const reclaimed_root = testTransitionRoot(3, try pool_catalog.rootDigest(current_root));
    var reclaimed = current;
    reclaimed.root = reclaimed_root;
    reclaimed.free[0] = .{ .member_slot = 1, .physical_start = 0, .extent_count = 4 };
    reclaimed.retired_count = 0;
    reclaimed.current_pages[2] = .{ .offset = 6 * pool_catalog.page_size, .digest = @splat(7) };
    reclaimed.metadata_count = 3;
    reclaimed.metadata[0] = .{ .page_start = 4, .page_count = 1 };
    reclaimed.metadata[1] = .{
        .page_start = 5,
        .page_count = 1,
        .state = .retired,
        .retired_generation = 3,
    };
    reclaimed.metadata[2] = .{ .page_start = 7, .page_count = 1 };
    try validateSnapshots(&current, &reclaimed);

    var premature = current;
    premature.retired[0].retired_generation = 3;
    try std.testing.expectError(
        error.PhysicalExtentReclaimRequiresAuthorityBarrier,
        validateSnapshots(&premature, &reclaimed),
    );
}

test "catalog transition compares member geometry by identity" {
    const previous_root = testTransitionRoot(1, @splat(0));
    var previous = testTransitionCatalog(previous_root);
    previous.member_count = 2;
    previous.members[1] = .{
        .member_id = @splat(3),
        .slot = 7,
        .metadata_length = 8 * pool_catalog.page_size,
        .data_length = 4 * 1024 * 1024,
    };
    previous.current_page_count = 2;
    previous.current_pages[0] = .{ .offset = 2 * pool_catalog.page_size, .digest = @splat(2) };
    previous.current_pages[1] = .{ .offset = 3 * pool_catalog.page_size, .digest = @splat(3) };
    previous.metadata_count = 1;
    previous.metadata[0] = .{ .page_start = 4, .page_count = 4 };

    var current = previous;
    current.root = testTransitionRoot(2, try pool_catalog.rootDigest(previous_root));
    std.mem.swap(MemberGeometry, &current.members[0], &current.members[1]);
    try validateSnapshots(&previous, &current);
}
