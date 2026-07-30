const std = @import("std");
const container = @import("../container.zig");
const codec = @import("codec.zig");
const pool_catalog = @import("pool_catalog.zig");
const pool_catalog_graph = @import("pool_catalog_graph.zig");
const pool_catalog_page = @import("pool_catalog_page.zig");
const pool_layout = @import("pool_layout.zig");
const pool_topology = @import("pool_topology.zig");

pub const InitializationContents = union(enum) {
    zero,
    bytes: []const u8,
};

pub const InitializationRequirement = struct {
    volume_id: [16]u8,
    logical_start: u64,
    extent_count: u32,

    pub fn withContents(
        self: InitializationRequirement,
        contents: InitializationContents,
    ) pool_catalog_graph.DataInitialization {
        return .{
            .volume_id = self.volume_id,
            .logical_start = self.logical_start,
            .extent_count = self.extent_count,
            .contents = switch (contents) {
                .zero => .zero,
                .bytes => |bytes| .{ .bytes = bytes },
            },
        };
    }
};

pub const GraphScratch = struct {
    images: [pool_catalog_graph.max_current_page_count]pool_catalog_graph.PageImage = undefined,
};

pub const Candidate = struct {
    root_bytes: [pool_catalog.root_encoded_size]u8 = undefined,
    page_offsets: [pool_catalog_graph.max_current_page_count]u64 = undefined,
    page_bytes: [pool_catalog_graph.max_current_page_count][pool_catalog.page_size]u8 = undefined,
    page_count: usize = 0,
    initialization: InitializationRequirement = undefined,

    pub fn graph(self: *const Candidate, scratch: *GraphScratch) pool_catalog_graph.Graph {
        for (0..self.page_count) |index| {
            scratch.images[index] = .{
                .offset = self.page_offsets[index],
                .bytes = &self.page_bytes[index],
            };
        }
        return .{ .root_bytes = &self.root_bytes, .pages = scratch.images[0..self.page_count] };
    }

    pub fn authorityBinding(
        self: *const Candidate,
        previous: pool_catalog_graph.AuthorityBinding,
    ) !pool_catalog_graph.AuthorityBinding {
        const root = try pool_catalog.decodeRoot(&self.root_bytes);
        return .{
            .generation = root.generation,
            .data_root_digest = try pool_catalog.rootDigest(root),
            .topology = previous.topology,
            .layout = previous.layout,
        };
    }

    fn addPage(self: *Candidate, offset: u64, bytes: [pool_catalog.page_size]u8) !void {
        if (self.page_count == self.page_offsets.len) return error.CatalogPageCapacityExceeded;
        for (self.page_offsets[0..self.page_count]) |existing| {
            if (existing == offset) return error.DuplicatePageImage;
        }
        self.page_offsets[self.page_count] = offset;
        self.page_bytes[self.page_count] = bytes;
        self.page_count += 1;
    }
};

pub fn mapExtent(
    previous_binding: pool_catalog_graph.AuthorityBinding,
    previous_graph: pool_catalog_graph.Graph,
    members: []const pool_catalog_graph.MemberGeometry,
    volume_id: [16]u8,
    logical_extent: u64,
) !Candidate {
    const previous = try pool_catalog_graph.validateGraph(previous_binding, previous_graph, members);
    const volume_index = findVolume(&previous, volume_id) orelse return error.VolumeNotFound;
    const previous_descriptor = previous.descriptors[volume_index];
    if (previous_descriptor.state != .ready) return error.VolumeNotReady;
    const logical_extent_count = try std.math.divCeil(
        u64,
        previous_descriptor.logical_size,
        previous_descriptor.extent_size,
    );
    if (logical_extent >= logical_extent_count) return error.ExtentOutsideVolume;

    const previous_runs = previous.extentSlice(volume_index);
    const covered_run = findLogicalRun(previous_runs, logical_extent);
    if (covered_run) |run| {
        if (run.state == .mapped) return error.ExtentAlreadyMapped;
    } else if (previous_descriptor.provisioning != .thin) {
        return error.IncompleteThickExtentMap;
    }

    const mapped_run: pool_catalog.ExtentRun = if (covered_run) |run| .{
        .logical_start = logical_extent,
        .physical_start = run.physical_start + (logical_extent - run.logical_start),
        .extent_count = 1,
        .state = .mapped,
        .member_count = run.member_count,
        .member_slots = run.member_slots,
        .flags = run.flags,
    } else try allocateThinExtent(&previous, previous_binding.layout, previous_binding.topology, logical_extent);

    var next_runs: [pool_catalog_page.max_extent_run_count]pool_catalog.ExtentRun = undefined;
    const next_run_count = try replaceLogicalExtent(previous_runs, mapped_run, &next_runs);

    var descriptors: [pool_catalog_graph.max_volume_count]pool_catalog.VolumeDescriptor = undefined;
    @memcpy(descriptors[0..previous.root.volume_count], previous.descriptorSlice());
    descriptors[volume_index].allocated_extent_count = try std.math.add(
        u64,
        descriptors[volume_index].allocated_extent_count,
        1,
    );
    if (covered_run != null) {
        descriptors[volume_index].reserved_extent_count -= 1;
    }

    const changes_physical_allocator = covered_run == null;
    const changed_page_count: usize = if (changes_physical_allocator) 4 else 3;
    var allocated_pages: [4]u64 = undefined;
    var metadata_intervals: [pool_catalog_page.max_metadata_interval_count + 4]pool_catalog_page.MetadataInterval = undefined;
    const metadata_count = try allocateMetadataPages(
        previous.metadataSlice(),
        changed_page_count,
        &allocated_pages,
        &metadata_intervals,
    );

    const volume_offset = allocated_pages[0] * pool_catalog.page_size;
    const extent_offset = allocated_pages[1] * pool_catalog.page_size;
    const physical_offset = if (changes_physical_allocator)
        allocated_pages[2] * pool_catalog.page_size
    else
        previous.root.allocator_root.offset;
    const metadata_offset = allocated_pages[changed_page_count - 1] * pool_catalog.page_size;

    const next_generation = std.math.add(u64, previous.root.generation, 1) catch
        return error.CatalogGenerationOverflow;
    const extent_bytes = try pool_catalog_page.encodeExtentMap(
        next_generation,
        volume_id,
        next_runs[0..next_run_count],
    );
    descriptors[volume_index].extent_map_root = try pool_catalog_page.pageReference(extent_offset, &extent_bytes);
    const volume_bytes = try pool_catalog_page.encodeVolumeIndex(
        next_generation,
        descriptors[0..previous.root.volume_count],
    );
    const volume_reference = try pool_catalog_page.pageReference(volume_offset, &volume_bytes);

    var physical_bytes: [pool_catalog.page_size]u8 = undefined;
    const physical_reference = if (changes_physical_allocator) physical: {
        var free: [pool_catalog_page.max_physical_interval_count + 3]pool_catalog_page.PhysicalInterval = undefined;
        const free_count = try removePhysicalExtent(
            previous.freeSlice(),
            mapped_run,
            &free,
        );
        physical_bytes = try pool_catalog_page.encodePhysicalIntervals(
            .physical_allocator,
            next_generation,
            free[0..free_count],
        );
        break :physical try pool_catalog_page.pageReference(physical_offset, &physical_bytes);
    } else previous.root.allocator_root;

    var retired_pages: [4]pool_catalog.PageReference = undefined;
    var retired_page_count: usize = 0;
    retired_pages[retired_page_count] = previous.root.volume_tree_root;
    retired_page_count += 1;
    if (!previous_descriptor.extent_map_root.isNull()) {
        retired_pages[retired_page_count] = previous_descriptor.extent_map_root;
        retired_page_count += 1;
    }
    if (changes_physical_allocator) {
        retired_pages[retired_page_count] = previous.root.allocator_root;
        retired_page_count += 1;
    }
    retired_pages[retired_page_count] = previous.root.metadata_allocator_root;
    retired_page_count += 1;

    const final_metadata_count = try retireMetadataPages(
        metadata_intervals[0..metadata_count],
        retired_pages[0..retired_page_count],
        next_generation,
        &metadata_intervals,
    );
    const metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(
        next_generation,
        metadata_intervals[0..final_metadata_count],
    );
    const metadata_reference = try pool_catalog_page.pageReference(metadata_offset, &metadata_bytes);

    var root = previous.root;
    root.generation = next_generation;
    root.sequence = std.math.add(u64, root.sequence, 1) catch return error.CatalogSequenceOverflow;
    root.previous_root_digest = try pool_catalog.rootDigest(previous.root);
    root.volume_tree_root = volume_reference;
    root.allocator_root = physical_reference;
    root.metadata_allocator_root = metadata_reference;

    var candidate: Candidate = .{};
    candidate.root_bytes = try pool_catalog.encodeRoot(root);
    candidate.initialization = .{
        .volume_id = volume_id,
        .logical_start = logical_extent,
        .extent_count = 1,
    };

    for (previous.currentPageSlice()) |reference| {
        if (containsReference(retired_pages[0..retired_page_count], reference.offset)) continue;
        candidate.addPage(reference.offset, (try resolvePage(previous_graph, reference)).*) catch |err| return err;
    }
    try candidate.addPage(volume_offset, volume_bytes);
    try candidate.addPage(extent_offset, extent_bytes);
    if (changes_physical_allocator) try candidate.addPage(physical_offset, physical_bytes);
    try candidate.addPage(metadata_offset, metadata_bytes);

    const current_binding = try candidate.authorityBinding(previous_binding);
    var graph_scratch: GraphScratch = .{};
    const current = try pool_catalog_graph.validateTransition(
        previous_binding,
        previous_graph,
        members,
        current_binding,
        candidate.graph(&graph_scratch),
        members,
    );
    const initialization = candidate.initialization.withContents(.zero);
    try pool_catalog_graph.validateDataInitializations(&previous, &current, &.{initialization});
    return candidate;
}

fn findVolume(catalog: *const pool_catalog_graph.ValidatedCatalog, volume_id: [16]u8) ?usize {
    for (catalog.descriptorSlice(), 0..) |descriptor, index| {
        if (std.mem.eql(u8, &descriptor.volume_id, &volume_id)) return index;
    }
    return null;
}

fn findLogicalRun(runs: []const pool_catalog.ExtentRun, logical_extent: u64) ?pool_catalog.ExtentRun {
    for (runs) |run| {
        if (logical_extent >= run.logical_start and logical_extent < run.logical_start + run.extent_count)
            return run;
    }
    return null;
}

fn allocateThinExtent(
    catalog: *const pool_catalog_graph.ValidatedCatalog,
    layout: pool_layout.Layout,
    topology: pool_topology.Topology,
    logical_extent: u64,
) !pool_catalog.ExtentRun {
    const member_count: usize = switch (layout.kind) {
        .unprotected => 1,
        .replicated => 3,
        .erasure_coded => return error.ErasureCodingNotImplemented,
    };
    var active_slots: [pool_topology.max_member_count]u16 = undefined;
    var active_count: usize = 0;
    for (topology.memberSlice()) |member| {
        if (member.state != .active) continue;
        active_slots[active_count] = member.slot;
        active_count += 1;
    }
    std.mem.sort(u16, active_slots[0..active_count], {}, std.sort.asc(u16));
    if (active_count < member_count) return error.AllocationPlacementUnavailable;

    var best_physical: ?u64 = null;
    var best_slots: [3]u16 = @splat(0);
    for (catalog.freeSlice()) |interval| {
        const candidates = [_]u64{
            interval.physical_start,
            interval.physical_start + interval.extent_count - 1,
        };
        for (candidates) |candidate| {
            if (best_physical != null and candidate >= best_physical.?) continue;
            const Placement = struct { slot: u16, interval_delta: i8 };
            var placements: [pool_topology.max_member_count]Placement = undefined;
            var placement_count: usize = 0;
            for (active_slots[0..active_count]) |slot| {
                const free = physicalIntervalAt(catalog.freeSlice(), slot, candidate) orelse continue;
                placements[placement_count] = .{
                    .slot = slot,
                    .interval_delta = if (free.extent_count == 1)
                        -1
                    else if (candidate == free.physical_start or candidate + 1 == free.physical_start + free.extent_count)
                        0
                    else
                        1,
                };
                placement_count += 1;
            }
            if (placement_count < member_count) continue;
            std.mem.sort(Placement, placements[0..placement_count], {}, struct {
                fn lessThan(_: void, left: Placement, right: Placement) bool {
                    if (left.interval_delta != right.interval_delta) return left.interval_delta < right.interval_delta;
                    return left.slot < right.slot;
                }
            }.lessThan);
            var next_interval_count: isize = @intCast(catalog.free_count);
            for (placements[0..member_count]) |placement| next_interval_count += placement.interval_delta;
            if (next_interval_count > pool_catalog_page.max_physical_interval_count) continue;
            for (placements[0..member_count], 0..) |placement, index| best_slots[index] = placement.slot;
            std.mem.sort(u16, best_slots[0..member_count], {}, std.sort.asc(u16));
            best_physical = candidate;
        }
    }
    return .{
        .logical_start = logical_extent,
        .physical_start = best_physical orelse return error.PhysicalSpaceExhausted,
        .extent_count = 1,
        .state = .mapped,
        .member_count = @intCast(member_count),
        .member_slots = best_slots,
    };
}

fn physicalIntervalAt(
    intervals: []const pool_catalog_page.PhysicalInterval,
    slot: u16,
    physical: u64,
) ?pool_catalog_page.PhysicalInterval {
    for (intervals) |interval| {
        if (interval.member_slot == slot and physical >= interval.physical_start and
            physical < interval.physical_start + interval.extent_count) return interval;
    }
    return null;
}

fn replaceLogicalExtent(
    previous: []const pool_catalog.ExtentRun,
    mapped: pool_catalog.ExtentRun,
    output: *[pool_catalog_page.max_extent_run_count]pool_catalog.ExtentRun,
) !usize {
    var count: usize = 0;
    var inserted = false;
    for (previous) |run| {
        const run_end = run.logical_start + run.extent_count;
        if (!inserted and mapped.logical_start < run.logical_start) {
            try appendRun(output, &count, mapped);
            inserted = true;
        }
        if (mapped.logical_start < run.logical_start or mapped.logical_start >= run_end) {
            try appendRun(output, &count, run);
            continue;
        }
        if (run.state == .mapped) return error.ExtentAlreadyMapped;
        const prefix_count: u32 = @intCast(mapped.logical_start - run.logical_start);
        if (prefix_count != 0) try appendRun(output, &count, withRange(run, run.logical_start, prefix_count));
        try appendRun(output, &count, mapped);
        const suffix_start = mapped.logical_start + 1;
        const suffix_count: u32 = @intCast(run_end - suffix_start);
        if (suffix_count != 0) try appendRun(output, &count, withRange(run, suffix_start, suffix_count));
        inserted = true;
    }
    if (!inserted) try appendRun(output, &count, mapped);
    return count;
}

fn withRange(run: pool_catalog.ExtentRun, logical_start: u64, extent_count: u32) pool_catalog.ExtentRun {
    var result = run;
    result.physical_start += logical_start - run.logical_start;
    result.logical_start = logical_start;
    result.extent_count = extent_count;
    return result;
}

fn appendRun(
    output: *[pool_catalog_page.max_extent_run_count]pool_catalog.ExtentRun,
    count: *usize,
    run: pool_catalog.ExtentRun,
) !void {
    if (count.* != 0 and pool_catalog.ExtentRun.canMerge(output[count.* - 1], run)) {
        output[count.* - 1].extent_count += run.extent_count;
        return;
    }
    if (count.* == output.len) return error.ExtentMapCapacityExceeded;
    output[count.*] = run;
    count.* += 1;
}

fn removePhysicalExtent(
    previous: []const pool_catalog_page.PhysicalInterval,
    mapped: pool_catalog.ExtentRun,
    output: *[pool_catalog_page.max_physical_interval_count + 3]pool_catalog_page.PhysicalInterval,
) !usize {
    var count: usize = 0;
    var removed: usize = 0;
    for (previous) |interval| {
        if (std.mem.indexOfScalar(u16, mapped.memberSlice(), interval.member_slot) == null or
            mapped.physical_start < interval.physical_start or
            mapped.physical_start >= interval.physical_start + interval.extent_count)
        {
            output[count] = interval;
            count += 1;
            continue;
        }
        const prefix_count = mapped.physical_start - interval.physical_start;
        if (prefix_count != 0) {
            output[count] = interval;
            output[count].extent_count = prefix_count;
            count += 1;
        }
        const suffix_start = mapped.physical_start + 1;
        const interval_end = interval.physical_start + interval.extent_count;
        if (suffix_start < interval_end) {
            output[count] = interval;
            output[count].physical_start = suffix_start;
            output[count].extent_count = interval_end - suffix_start;
            count += 1;
        }
        removed += 1;
    }
    if (removed != mapped.member_count) return error.PhysicalAllocatorMismatch;
    if (count > pool_catalog_page.max_physical_interval_count) return error.PageCapacityExceeded;
    return count;
}

fn allocateMetadataPages(
    previous: []const pool_catalog_page.MetadataInterval,
    requested: usize,
    allocated: *[4]u64,
    output: *[pool_catalog_page.max_metadata_interval_count + 4]pool_catalog_page.MetadataInterval,
) !usize {
    @memcpy(output[0..previous.len], previous);
    var count = previous.len;
    for (0..requested) |allocation_index| {
        var selected: ?usize = null;
        for (output[0..count], 0..) |interval, index| {
            if (interval.state != .free) continue;
            if (selected == null or interval.page_count < output[selected.?].page_count or
                (interval.page_count == output[selected.?].page_count and
                    interval.page_start < output[selected.?].page_start)) selected = index;
        }
        const index = selected orelse return error.MetadataSpaceExhausted;
        allocated[allocation_index] = output[index].page_start;
        output[index].page_start += 1;
        output[index].page_count -= 1;
        count = compactEmptyMetadata(output, count);
    }
    return count;
}

fn compactEmptyMetadata(
    intervals: *[pool_catalog_page.max_metadata_interval_count + 4]pool_catalog_page.MetadataInterval,
    count: usize,
) usize {
    var output_count: usize = 0;
    for (intervals[0..count]) |interval| {
        if (interval.page_count == 0) continue;
        intervals[output_count] = interval;
        output_count += 1;
    }
    return output_count;
}

fn retireMetadataPages(
    allocated_state: []const pool_catalog_page.MetadataInterval,
    retired: []const pool_catalog.PageReference,
    generation: u64,
    output: *[pool_catalog_page.max_metadata_interval_count + 4]pool_catalog_page.MetadataInterval,
) !usize {
    var count = allocated_state.len;
    if (allocated_state.ptr != output) @memcpy(output[0..count], allocated_state);
    for (retired) |reference| {
        output[count] = .{
            .page_start = reference.offset / pool_catalog.page_size,
            .page_count = 1,
            .state = .retired,
            .retired_generation = generation,
        };
        count += 1;
    }
    std.mem.sort(
        pool_catalog_page.MetadataInterval,
        output[0..count],
        {},
        struct {
            fn lessThan(_: void, left: pool_catalog_page.MetadataInterval, right: pool_catalog_page.MetadataInterval) bool {
                return left.page_start < right.page_start;
            }
        }.lessThan,
    );

    var canonical_count: usize = 0;
    for (output[0..count]) |interval| {
        if (canonical_count != 0) {
            const previous = &output[canonical_count - 1];
            const previous_end = previous.page_start + previous.page_count;
            if (interval.page_start < previous_end) return error.OverlappingMetadataIntervals;
            if (interval.page_start == previous_end and previous.state == interval.state and
                previous.retired_generation == interval.retired_generation)
            {
                previous.page_count = std.math.add(u32, previous.page_count, interval.page_count) catch
                    return error.MetadataIntervalOverflow;
                continue;
            }
        }
        output[canonical_count] = interval;
        canonical_count += 1;
    }
    if (canonical_count > pool_catalog_page.max_metadata_interval_count) return error.PageCapacityExceeded;
    return canonical_count;
}

fn containsReference(references: []const pool_catalog.PageReference, offset: u64) bool {
    for (references) |reference| if (reference.offset == offset) return true;
    return false;
}

fn resolvePage(
    graph: pool_catalog_graph.Graph,
    reference: pool_catalog.PageReference,
) !*const [pool_catalog.page_size]u8 {
    for (graph.pages) |image| {
        if (image.offset != reference.offset) continue;
        if (!std.mem.eql(u8, &reference.digest, &codec.blake3(image.bytes))) return error.PageDigestMismatch;
        return image.bytes;
    }
    return error.MissingPageImage;
}

const TestCatalog = struct {
    root_bytes: [pool_catalog.root_encoded_size]u8 = undefined,
    volume_bytes: [pool_catalog.page_size]u8 = undefined,
    name_bytes: [pool_catalog.page_size]u8 = undefined,
    physical_bytes: [pool_catalog.page_size]u8 = undefined,
    metadata_bytes: [pool_catalog.page_size]u8 = undefined,
    header_bytes: [pool_catalog.page_size]u8 = undefined,
    extent_bytes: [pool_catalog.page_size]u8 = undefined,
    images: [6]pool_catalog_graph.PageImage = undefined,
    image_count: usize,
    root: pool_catalog.Root,
    topology: pool_topology.Topology,
    layout: pool_layout.Layout,
    geometry: [1]pool_catalog_graph.MemberGeometry,

    fn init(provisioning: pool_catalog.Provisioning) !TestCatalog {
        const topology = try pool_topology.Topology.init(@splat(1), 1, @splat(0), &.{.{
            .member_id = @splat(2),
            .slot = 1,
            .control_role = pool_topology.voter_role,
            .role_flags = 3,
        }});
        const layout = try pool_layout.Layout.init(.unprotected, 1, 1, 1024 * 1024);
        var header: container.Header = .{
            .sequence = 1,
            .state = .ready,
            .uuid = @splat(9),
            .created_ns = 123,
            .logical_size = 4 * 1024 * 1024,
            .block_count = 1024,
        };
        @memcpy(header.label[0..5], "alpha");
        header.label_len = 5;
        const header_bytes = header.encode();
        const header_reference = try pool_catalog_page.pageReference(6 * pool_catalog.page_size, &header_bytes);

        const reserved_run: pool_catalog.ExtentRun = .{
            .logical_start = 0,
            .physical_start = 0,
            .extent_count = 4,
            .state = .reserved_zero,
            .member_count = 1,
            .member_slots = .{ 1, 0, 0 },
        };
        const extent_bytes = try pool_catalog_page.encodeExtentMap(
            1,
            @splat(9),
            if (provisioning == .thick) &.{reserved_run} else &.{},
        );
        const extent_reference = try pool_catalog_page.pageReference(7 * pool_catalog.page_size, &extent_bytes);
        const descriptor: pool_catalog.VolumeDescriptor = .{
            .volume_id = @splat(9),
            .state = .ready,
            .provisioning = provisioning,
            .created_ns = 123,
            .logical_size = 4 * 1024 * 1024,
            .header_page = header_reference,
            .extent_map_root = if (provisioning == .thick) extent_reference else .{},
            .reserved_extent_count = if (provisioning == .thick) 4 else 0,
            .extent_size = layout.chunk_size,
            .name = try pool_catalog.Name.init("alpha"),
        };
        const volume_bytes = try pool_catalog_page.encodeVolumeIndex(1, &.{descriptor});
        const name_bytes = try pool_catalog_page.encodeNameIndex(1, &.{.{
            .volume_id = descriptor.volume_id,
            .name = descriptor.name,
        }});
        const physical_bytes = try pool_catalog_page.encodePhysicalIntervals(
            .physical_allocator,
            1,
            if (provisioning == .thin) &.{.{
                .member_slot = 1,
                .physical_start = 0,
                .extent_count = 4,
            }} else &.{},
        );
        const metadata_start: u64 = if (provisioning == .thick) 8 else 7;
        const metadata_bytes = try pool_catalog_page.encodeMetadataAllocator(1, &.{.{
            .page_start = metadata_start,
            .page_count = @intCast(32 - metadata_start),
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
        return .{
            .root_bytes = try pool_catalog.encodeRoot(root),
            .volume_bytes = volume_bytes,
            .name_bytes = name_bytes,
            .physical_bytes = physical_bytes,
            .metadata_bytes = metadata_bytes,
            .header_bytes = header_bytes,
            .extent_bytes = extent_bytes,
            .image_count = if (provisioning == .thick) 6 else 5,
            .root = root,
            .topology = topology,
            .layout = layout,
            .geometry = .{.{
                .member_id = @splat(2),
                .slot = 1,
                .metadata_length = 32 * pool_catalog.page_size,
                .data_length = 4 * 1024 * 1024,
            }},
        };
    }

    fn graph(self: *TestCatalog) pool_catalog_graph.Graph {
        self.images[0] = .{ .offset = self.root.volume_tree_root.offset, .bytes = &self.volume_bytes };
        self.images[1] = .{ .offset = self.root.name_index_root.offset, .bytes = &self.name_bytes };
        self.images[2] = .{ .offset = self.root.allocator_root.offset, .bytes = &self.physical_bytes };
        self.images[3] = .{ .offset = self.root.metadata_allocator_root.offset, .bytes = &self.metadata_bytes };
        self.images[4] = .{ .offset = 6 * pool_catalog.page_size, .bytes = &self.header_bytes };
        if (self.image_count == 6)
            self.images[5] = .{ .offset = 7 * pool_catalog.page_size, .bytes = &self.extent_bytes };
        return .{ .root_bytes = &self.root_bytes, .pages = self.images[0..self.image_count] };
    }

    fn binding(self: *const TestCatalog) !pool_catalog_graph.AuthorityBinding {
        return .{
            .generation = self.root.generation,
            .data_root_digest = try pool_catalog.rootDigest(self.root),
            .topology = self.topology,
            .layout = self.layout,
        };
    }
};

test "thin hole mapping allocates physical extents and COW pages" {
    var previous = try TestCatalog.init(.thin);
    const previous_binding = try previous.binding();
    const previous_graph = previous.graph();
    var candidate = try mapExtent(
        previous_binding,
        previous_graph,
        &previous.geometry,
        @splat(9),
        2,
    );
    const current_binding = try candidate.authorityBinding(previous_binding);
    var graph_scratch: GraphScratch = .{};
    const current = try pool_catalog_graph.validateTransition(
        previous_binding,
        previous_graph,
        &previous.geometry,
        current_binding,
        candidate.graph(&graph_scratch),
        &previous.geometry,
    );

    try std.testing.expectEqual(@as(u64, 2), current.root.generation);
    try std.testing.expectEqual(@as(u64, 1), current.descriptors[0].allocated_extent_count);
    try std.testing.expectEqual(@as(u16, 1), current.extent_counts[0]);
    try std.testing.expectEqual(@as(u64, 2), current.extent_runs[0][0].logical_start);
    try std.testing.expectEqual(@as(u64, 0), current.extent_runs[0][0].physical_start);
    try std.testing.expectEqual(@as(u64, 1), current.free[0].physical_start);
    try std.testing.expectEqual(@as(u64, 3), current.free[0].extent_count);
    try std.testing.expectEqual(@as(u64, 2), candidate.initialization.logical_start);
}

test "thick reserved extent mapping preserves physical allocation" {
    var previous = try TestCatalog.init(.thick);
    const previous_binding = try previous.binding();
    const previous_graph = previous.graph();
    var candidate = try mapExtent(
        previous_binding,
        previous_graph,
        &previous.geometry,
        @splat(9),
        1,
    );
    const current_binding = try candidate.authorityBinding(previous_binding);
    var graph_scratch: GraphScratch = .{};
    const current = try pool_catalog_graph.validateTransition(
        previous_binding,
        previous_graph,
        &previous.geometry,
        current_binding,
        candidate.graph(&graph_scratch),
        &previous.geometry,
    );

    try std.testing.expectEqualSlices(u8, &previous.root.allocator_root.digest, &current.root.allocator_root.digest);
    try std.testing.expectEqual(@as(u64, 1), current.descriptors[0].allocated_extent_count);
    try std.testing.expectEqual(@as(u64, 3), current.descriptors[0].reserved_extent_count);
    try std.testing.expectEqual(@as(u16, 3), current.extent_counts[0]);
    try std.testing.expectEqual(pool_catalog.ExtentState.reserved_zero, current.extent_runs[0][0].state);
    try std.testing.expectEqual(pool_catalog.ExtentState.mapped, current.extent_runs[0][1].state);
    try std.testing.expectEqual(@as(u64, 1), current.extent_runs[0][1].physical_start);
    try std.testing.expectEqual(pool_catalog.ExtentState.reserved_zero, current.extent_runs[0][2].state);
}

test "metadata allocation consumes singleton intervals before splitting ranges" {
    var previous: [pool_catalog_page.max_metadata_interval_count]pool_catalog_page.MetadataInterval = undefined;
    for (&previous, 0..) |*interval, index| {
        interval.* = .{
            .page_start = 2 + index * 3,
            .page_count = if (index < 4) 1 else 2,
            .state = .free,
        };
    }
    var allocated: [4]u64 = undefined;
    var current: [pool_catalog_page.max_metadata_interval_count + 4]pool_catalog_page.MetadataInterval = undefined;
    const count = try allocateMetadataPages(&previous, 4, &allocated, &current);
    try std.testing.expectEqual(pool_catalog_page.max_metadata_interval_count - 4, count);
    try std.testing.expectEqualSlices(u64, &.{ 2, 5, 8, 11 }, &allocated);
}

test "replicated thin allocation uses a common physical ordinal" {
    const members = [_]pool_topology.Member{
        .{ .member_id = @splat(2), .slot = 1, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = @splat(3), .slot = 4, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = @splat(4), .slot = 7, .control_role = pool_topology.voter_role, .role_flags = 3 },
    };
    const topology = try pool_topology.Topology.init(@splat(1), 1, @splat(0), &members);
    const layout = try pool_layout.Layout.init(.replicated, 1, 1, 1024 * 1024);
    var catalog: pool_catalog_graph.ValidatedCatalog = undefined;
    catalog.free_count = 3;
    catalog.free[0] = .{ .member_slot = 1, .physical_start = 0, .extent_count = 2 };
    catalog.free[1] = .{ .member_slot = 4, .physical_start = 0, .extent_count = 2 };
    catalog.free[2] = .{ .member_slot = 7, .physical_start = 1, .extent_count = 1 };

    const run = try allocateThinExtent(&catalog, layout, topology, 5);
    try std.testing.expectEqual(@as(u64, 1), run.physical_start);
    try std.testing.expectEqualSlices(u16, &.{ 1, 4, 7 }, run.memberSlice());
}

test "replicated allocation uses a common interval end when the allocator page is full" {
    const members = [_]pool_topology.Member{
        .{ .member_id = @splat(2), .slot = 1, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = @splat(3), .slot = 4, .control_role = pool_topology.voter_role, .role_flags = 3 },
        .{ .member_id = @splat(4), .slot = 7, .control_role = pool_topology.voter_role, .role_flags = 3 },
    };
    const topology = try pool_topology.Topology.init(@splat(1), 1, @splat(0), &members);
    const layout = try pool_layout.Layout.init(.replicated, 1, 1, 1024 * 1024);
    var catalog: pool_catalog_graph.ValidatedCatalog = undefined;
    catalog.free_count = pool_catalog_page.max_physical_interval_count;
    catalog.free[0] = .{ .member_slot = 1, .physical_start = 0, .extent_count = 100 };
    catalog.free[1] = .{ .member_slot = 4, .physical_start = 10, .extent_count = 90 };
    catalog.free[2] = .{ .member_slot = 7, .physical_start = 20, .extent_count = 80 };
    for (catalog.free[3..catalog.free_count], 0..) |*interval, index| {
        interval.* = .{ .member_slot = @intCast(100 + index), .physical_start = 200, .extent_count = 1 };
    }

    const run = try allocateThinExtent(&catalog, layout, topology, 5);
    try std.testing.expectEqual(@as(u64, 99), run.physical_start);
}

test "mapping adjacent thin extents produces a canonical run" {
    const previous = [_]pool_catalog.ExtentRun{.{
        .logical_start = 0,
        .physical_start = 0,
        .extent_count = 1,
        .state = .mapped,
        .member_count = 1,
        .member_slots = .{ 1, 0, 0 },
    }};
    const mapped: pool_catalog.ExtentRun = .{
        .logical_start = 1,
        .physical_start = 1,
        .extent_count = 1,
        .state = .mapped,
        .member_count = 1,
        .member_slots = .{ 1, 0, 0 },
    };
    var current: [pool_catalog_page.max_extent_run_count]pool_catalog.ExtentRun = undefined;
    const count = try replaceLogicalExtent(&previous, mapped, &current);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u32, 2), current[0].extent_count);
}
