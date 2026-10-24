const std = @import("std");
const engine = @import("zettide_storage").v3;
const catalog = engine.pool_catalog;
const graph = engine.pool_catalog_graph;
const page = engine.pool_catalog_page;

pub const member_names = [_][]const u8{ "member-0", "member-1", "member-2" };

pub fn createSet(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, count: usize) !engine.pool_member_set.PoolMemberSet {
    if (count != 1 and count != 3) return error.UnsupportedPoolWidth;
    var storages: [member_names.len]engine.storage.Storage = undefined;
    var opened: usize = 0;
    errdefer engine.storage.closeAll(storages[0..opened], io) catch {};
    for (member_names[0..count], storages[0..count]) |name, *storage| {
        storage.* = try engine.storage.Storage.createFile(io, dir, name, 8 * 1024 * 1024);
        opened += 1;
    }
    opened = 0;
    const outcome = try engine.pool_provision.create(io, allocator, storages[0..count], .{
        .protection = if (count == 1) .unprotected else .replicated,
        .data_mode = .catalog,
        .chunk_size = 4096,
    });
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => |partial| return partial.cause,
    };
    defer provisioned.deinit();
    return provisioned.intoMemberSet();
}

pub fn reopenSet(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, count: usize, mode: engine.pool_member_set.OpenIntent) !engine.pool_member_set.PoolMemberSet {
    if (count != 1 and count != 3) return error.UnsupportedPoolWidth;
    var locations: [member_names.len]engine.pool_member_set.Location = undefined;
    for (member_names[0..count], locations[0..count]) |name, *location|
        location.* = .{ .parent = dir, .basename = name };
    return engine.pool_member_set.open(io, allocator, locations[0..count], mode);
}

/// Test-only initialization: one mapped extent followed by a thin hole. Commit
/// through the real journal so consumers exercise authenticated Catalog I/O.
pub fn publishMapped(io: std.Io, set: *engine.pool_member_set.PoolMemberSet) ![16]u8 {
    const authority = set.authority() orelse return error.MissingAuthority;
    if (authority.generation != 0) return error.CatalogAlreadyInitialized;
    const count = authority.topology.member_count;
    if (count != 1 and count != 3) return error.UnsupportedPoolWidth;
    const extent_size = authority.layout.chunk_size;
    var slots: [3]u16 = @splat(0);
    var free: [3]page.PhysicalInterval = undefined;
    for (authority.topology.members[0..count], 0..) |descriptor, index| {
        const member = (try set.dataMemberForRead(descriptor.slot)).member;
        slots[index] = descriptor.slot;
        if (index != 0 and slots[index - 1] >= slots[index]) return error.UnexpectedTopology;
        free[index] = .{
            .member_slot = descriptor.slot,
            .physical_start = 1,
            .extent_count = member.header().data.length / extent_size - 1,
        };
    }
    var header = try engine.catalog_volume_header.Header.init(io, @max(engine.catalog_volume_header.minimum_volume_size, 2 * @as(u64, extent_size)), "test-volume");
    header.extent_size = extent_size;
    header.state = .ready;
    const header_bytes = header.encode();
    const header_reference = try page.pageReference(6 * catalog.page_size, &header_bytes);
    const extent_bytes = try page.encodeExtentMap(1, header.uuid, &.{.{
        .logical_start = 0,
        .physical_start = 0,
        .extent_count = 1,
        .state = .mapped,
        .member_count = count,
        .member_slots = slots,
    }});
    const extent_reference = try page.pageReference(7 * catalog.page_size, &extent_bytes);
    const descriptor: catalog.VolumeDescriptor = .{
        .volume_id = header.uuid,
        .state = .ready,
        .provisioning = .thin,
        .created_ns = header.created_ns,
        .logical_size = header.logical_size,
        .header_page = header_reference,
        .extent_map_root = extent_reference,
        .allocated_extent_count = 1,
        .extent_size = extent_size,
        .name = try catalog.Name.init("test-volume"),
    };
    const volume_bytes = try page.encodeVolumeIndex(1, &.{descriptor});
    const name_bytes = try page.encodeNameIndex(1, &.{.{ .volume_id = header.uuid, .name = descriptor.name }});
    const physical_bytes = try page.encodePhysicalIntervals(.physical_allocator, 1, free[0..count]);
    const member = (try set.memberAt(0)) orelse return error.MemberUnavailable;
    const metadata_bytes = try page.encodeMetadataAllocator(1, &.{.{
        .page_start = 8,
        .page_count = @intCast(member.header().metadata.length / catalog.page_size - 8),
    }});
    const volume_reference = try page.pageReference(2 * catalog.page_size, &volume_bytes);
    const name_reference = try page.pageReference(3 * catalog.page_size, &name_bytes);
    const physical_reference = try page.pageReference(4 * catalog.page_size, &physical_bytes);
    const metadata_reference = try page.pageReference(5 * catalog.page_size, &metadata_bytes);
    const root: catalog.Root = .{
        .set_id = authority.topology.set_id,
        .generation = 1,
        .sequence = 1,
        .previous_root_digest = @splat(0),
        .volume_tree_root = volume_reference,
        .name_index_root = name_reference,
        .allocator_root = physical_reference,
        .metadata_allocator_root = metadata_reference,
        .volume_count = 1,
        .extent_size = extent_size,
    };
    const root_bytes = try catalog.encodeRoot(root);
    const images = [_]graph.PageImage{
        .{ .offset = volume_reference.offset, .bytes = &volume_bytes },
        .{ .offset = name_reference.offset, .bytes = &name_bytes },
        .{ .offset = physical_reference.offset, .bytes = &physical_bytes },
        .{ .offset = metadata_reference.offset, .bytes = &metadata_bytes },
        .{ .offset = header_reference.offset, .bytes = &header_bytes },
        .{ .offset = extent_reference.offset, .bytes = &extent_bytes },
    };
    var proposal: engine.control_record.Record = .{
        .kind = engine.control_record.generation_prepare_kind,
        .local_sequence = 1,
        .membership_epoch = authority.membership_epoch,
        .writer_term = @max(authority.writer_term, 1),
        .generation = 1,
        .set_id = authority.topology.set_id,
        .member_id = @splat(8),
        .mount_session_id = @splat(3),
        .transaction_id = @splat(4),
        .previous_record_digest = @splat(0),
        .previous_history_digest = authority.history_digest,
        .data_root_digest = try catalog.rootDigest(root),
        .topology_digest = try engine.pool_topology.digest(authority.topology),
        .layout_digest = try engine.pool_layout.digest(authority.layout),
        .payload = try engine.control_record.Payload.init("test Catalog"),
    };
    proposal.history_digest = try engine.control_record.historyDigest(proposal);
    var coordinator = try engine.pool_replicated_journal.open(io, set);
    defer coordinator.deinit();
    _ = try coordinator.commitCatalogGeneration(.{
        .prepare_proposal = proposal,
        .previous_graph = null,
        .current_graph = .{ .root_bytes = &root_bytes, .pages = &images },
        .data_initializations = &.{.{
            .volume_id = header.uuid,
            .logical_start = 0,
            .extent_count = 1,
            .contents = .zero,
        }},
    });
    return header.uuid;
}
