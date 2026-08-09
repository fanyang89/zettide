const std = @import("std");
const zettide = @import("zettide");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("signal.h");
    @cInclude("spdk_runtime.h");
});

const catalog_size = 64 * 1024 * 1024 * 1024;
const mapped_size = 1024 * 1024 * 1024;
const metadata_slack = 8 * 1024 * 1024;
const runtime_config =
    \\{"subsystems":[
    \\{"subsystem":"bdev","config":[
    \\{"method":"bdev_set_options","params":{"bdev_io_pool_size":16384,"bdev_io_cache_size":256}}]},
    \\{"subsystem":"nvmf","config":[
    \\{"method":"nvmf_create_transport","params":{"trtype":"TCP","max_queue_depth":256,"max_io_size":1048576}}]}]}
;

pub export fn zettide_spdk_catalog_nvmf_benchmark(
    ready_path_z: [*:0]const u8,
    member_path_z: [*:0]const u8,
    mode: c_int,
    expected_pool_id_z: ?[*:0]const u8,
) c_int {
    run(ready_path_z, member_path_z, mode, expected_pool_id_z) catch |err| {
        std.debug.print("Catalog NVMe-oF benchmark failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(
    ready_path_z: [*:0]const u8,
    member_path_z: [*:0]const u8,
    mode: c_int,
    expected_pool_id_z: ?[*:0]const u8,
) !void {
    const allocator = std.heap.c_allocator;
    const ready_path = std.mem.span(ready_path_z);
    const member_path = std.mem.span(member_path_z);
    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();
    var reactor_mask_buffer: [32]u8 = undefined;
    if (c.zettide_spdk_test_reactor_mask(&reactor_mask_buffer, reactor_mask_buffer.len) != 0)
        return error.ReactorMaskUnavailable;
    const reactor_mask = std.mem.sliceTo(&reactor_mask_buffer, 0);

    var signals: c.sigset_t = undefined;
    if (c.sigemptyset(&signals) != 0 or
        c.sigaddset(&signals, c.SIGINT) != 0 or
        c.sigaddset(&signals, c.SIGTERM) != 0 or
        c.pthread_sigmask(c.SIG_BLOCK, &signals, null) != 0)
        return error.SignalSetupFailed;

    if (mode == 2 or mode == 3 or mode == 4) {
        const expected_pool_id = expected_pool_id_z orelse return error.ExpectedPoolIdRequired;
        if (mode == 4) return serveReformatted(
            io,
            allocator,
            ready_path,
            member_path,
            std.mem.span(expected_pool_id),
            reactor_mask,
            &signals,
        );
        return serveExisting(
            io,
            allocator,
            ready_path,
            member_path,
            std.mem.span(expected_pool_id),
            reactor_mask,
            &signals,
            mode == 3,
        );
    }
    if (mode != 0 and mode != 1) return error.InvalidMode;
    const mapped = mode == 1;

    const parent_path = std.fs.path.dirname(member_path) orelse return error.MemberPathMustHaveParent;
    const basename = std.fs.path.basename(member_path);
    const parent = try std.Io.Dir.openDirAbsolute(io, parent_path, .{});
    defer parent.close(io);
    var storages = [_]zettide.v3.storage.Storage{
        try zettide.v3.storage.Storage.createFile(
            io,
            parent,
            basename,
            if (mapped) mapped_size + metadata_slack else metadata_slack,
        ),
    };
    const outcome = try zettide.v3.pool_provision.create(
        io,
        allocator,
        &storages,
        .{ .protection = .unprotected },
    );
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    var set = try provisioned.intoMemberSet();
    defer set.deinit();
    const volume_id = try publishCatalog(io, &set, mapped);

    try serve(io, allocator, ready_path, reactor_mask, &signals, &set, volume_id);
}

fn serveReformatted(
    io: std.Io,
    allocator: std.mem.Allocator,
    ready_path: []const u8,
    member_path: []const u8,
    expected_pool_id_text: []const u8,
    reactor_mask: []const u8,
    signals: *const c.sigset_t,
) !void {
    const expected_pool_id = try parsePoolId(expected_pool_id_text);
    {
        const opened = try zettide.v3.linux_block_device.openStorageOptions(
            io,
            allocator,
            member_path,
            false,
            true,
        );
        var storages = [_]zettide.v3.storage.Storage{opened.storage};
        var existing = try zettide.v3.pool_member_set.PoolMemberSet.openStorages(
            io,
            allocator,
            &storages,
            .read_only,
        );
        defer existing.deinit();
        const authority = existing.authority() orelse return error.MissingAuthority;
        if (!std.mem.eql(u8, &authority.topology.set_id, &expected_pool_id))
            return error.UnexpectedPoolId;
    }

    const opened = try zettide.v3.linux_block_device.openStorageOptions(
        io,
        allocator,
        member_path,
        true,
        true,
    );
    var storages = [_]zettide.v3.storage.Storage{opened.storage};
    const outcome = try zettide.v3.pool_provision.create(
        io,
        allocator,
        &storages,
        .{ .protection = .unprotected, .filesystem = .littlefs, .label = "NVMe benchmark" },
    );
    var provisioned = switch (outcome) {
        .complete => |value| value,
        .partial => return error.UnexpectedPartialCreation,
    };
    defer provisioned.deinit();
    var set = try provisioned.intoMemberSet();
    defer set.deinit();
    const authority = set.authority() orelse return error.MissingAuthority;
    std.debug.print("New Catalog Pool ID: ", .{});
    for (authority.topology.set_id) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
    const volume_id = try publishCatalog(io, &set, true);
    try serve(io, allocator, ready_path, reactor_mask, signals, &set, volume_id);
}

fn serveExisting(
    io: std.Io,
    allocator: std.mem.Allocator,
    ready_path: []const u8,
    member_path: []const u8,
    expected_pool_id_text: []const u8,
    reactor_mask: []const u8,
    signals: *const c.sigset_t,
    provision: bool,
) !void {
    const expected_pool_id = try parsePoolId(expected_pool_id_text);
    const opened = try zettide.v3.linux_block_device.openStorageOptions(
        io,
        allocator,
        member_path,
        provision,
        true,
    );
    var storages = [_]zettide.v3.storage.Storage{opened.storage};
    var set = try zettide.v3.pool_member_set.PoolMemberSet.openStorages(
        io,
        allocator,
        &storages,
        if (provision) .writable else .read_only,
    );
    defer set.deinit();
    const authority = set.authority() orelse return error.MissingAuthority;
    if (!std.mem.eql(u8, &authority.topology.set_id, &expected_pool_id))
        return error.UnexpectedPoolId;
    const volume_id = if (provision) provisioned: {
        const catalog = set.loadCatalog() catch |err| switch (err) {
            error.GenesisHasNoCatalogRoot => break :provisioned try publishCatalog(io, &set, true),
            else => return err,
        };
        for (catalog.descriptorSlice()) |descriptor| {
            if (std.mem.eql(u8, descriptor.name.slice(), "benchmark"))
                break :provisioned descriptor.volume_id;
        }
        return error.BenchmarkVolumeMissing;
    } else existing: {
        const catalog = try set.loadCatalog();
        var selected_index: ?usize = null;
        for (catalog.descriptorSlice(), 0..) |descriptor, index| {
            std.debug.print("Catalog volume name={s} allocated_extents={d} logical_size={d}\n", .{
                descriptor.name.slice(),
                descriptor.allocated_extent_count,
                descriptor.logical_size,
            });
            if (descriptor.allocated_extent_count == 0) continue;
            if (selected_index == null or descriptor.allocated_extent_count >
                catalog.descriptors[selected_index.?].allocated_extent_count) selected_index = index;
        }
        const selected = selected_index orelse return error.NoMappedCatalogVolume;
        break :existing catalog.descriptors[selected].volume_id;
    };
    try serve(
        io,
        allocator,
        ready_path,
        reactor_mask,
        signals,
        &set,
        volume_id,
    );
}

fn parsePoolId(text: []const u8) ![16]u8 {
    if (text.len != 32) return error.InvalidExpectedPoolId;
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return error.InvalidExpectedPoolId;
    return result;
}

fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    ready_path: []const u8,
    reactor_mask: []const u8,
    signals: *const c.sigset_t,
    set: *zettide.v3.pool_member_set.PoolMemberSet,
    volume_id: [16]u8,
) !void {
    var runtime = try zettide.spdk_runtime.Runtime.start(allocator, .{
        .name = "zettide_spdk_catalog_nvmf_benchmark",
        .reactor_mask = reactor_mask,
        .json_data = runtime_config,
        .mem_size_mb = 512,
        .no_pci = true,
        .no_huge = true,
        .disable_cpumask_locks = true,
    });
    defer runtime.deinit();
    var export_handle = try zettide.spdk_catalog_nvmf_export.CatalogNvmfExport.create(
        allocator,
        io,
        &runtime,
        set,
        volume_id,
        .{
            .bdev_name = "ZettideCatalogBenchmark0",
            .nqn = "nqn.2026-08.io.zettide:benchmark",
            .serial_number = "ZETTIDEBENCH000001",
            .model_number = "Zettide Catalog Benchmark",
            .traddr = "127.0.0.1",
            .trsvcid = "44220",
            .allow_any_host = true,
        },
    );
    defer export_handle.close() catch @panic("failed to close Catalog NVMe-oF export");

    const ready = try std.Io.Dir.createFileAbsolute(io, ready_path, .{ .exclusive = true });
    ready.close(io);
    var signal_number: c_int = undefined;
    if (c.sigwait(signals, &signal_number) != 0) return error.SignalWaitFailed;
}

fn publishCatalog(
    io: std.Io,
    set: *zettide.v3.pool_member_set.PoolMemberSet,
    mapped: bool,
) ![16]u8 {
    const catalog = zettide.v3.pool_catalog;
    const graph = zettide.v3.pool_catalog_graph;
    const page = zettide.v3.pool_catalog_page;
    const authority = set.authority() orelse return error.MissingAuthority;
    const member = (try set.memberAt(0)) orelse return error.MemberUnavailable;
    const extent_size = authority.layout.chunk_size;
    const extent_count = member.header().data.length / extent_size;

    var header = try zettide.container.Header.init(io, catalog_size, "benchmark");
    header.chunk_size = extent_size;
    header.state = .ready;
    const header_bytes = header.encode();
    const header_reference = try page.pageReference(6 * catalog.page_size, &header_bytes);
    const mapped_extent_count = mapped_size / @as(u64, extent_size);
    const extent_bytes = try page.encodeExtentMap(1, header.uuid, if (mapped) &.{.{
        .logical_start = 0,
        .physical_start = 0,
        .extent_count = @intCast(mapped_extent_count),
        .state = .mapped,
        .member_count = 1,
        .member_slots = .{ authority.topology.members[0].slot, 0, 0 },
    }} else &.{});
    const extent_reference = try page.pageReference(7 * catalog.page_size, &extent_bytes);
    const descriptor: catalog.VolumeDescriptor = .{
        .volume_id = header.uuid,
        .state = .ready,
        .provisioning = .thin,
        .created_ns = header.created_ns,
        .logical_size = header.logical_size,
        .header_page = header_reference,
        .extent_map_root = if (mapped) extent_reference else .{},
        .allocated_extent_count = if (mapped) mapped_extent_count else 0,
        .extent_size = extent_size,
        .name = try catalog.Name.init("benchmark"),
    };
    const volume_bytes = try page.encodeVolumeIndex(1, &.{descriptor});
    const name_bytes = try page.encodeNameIndex(1, &.{.{
        .volume_id = descriptor.volume_id,
        .name = descriptor.name,
    }});
    const physical_bytes = try page.encodePhysicalIntervals(
        .physical_allocator,
        1,
        &.{.{
            .member_slot = authority.topology.members[0].slot,
            .physical_start = if (mapped) mapped_extent_count else 0,
            .extent_count = extent_count - (if (mapped) mapped_extent_count else 0),
        }},
    );
    const metadata_page_count = member.header().metadata.length / catalog.page_size;
    const metadata_start: u64 = if (mapped) 8 else 7;
    const metadata_bytes = try page.encodeMetadataAllocator(1, &.{.{
        .page_start = metadata_start,
        .page_count = @intCast(metadata_page_count - metadata_start),
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
    var proposal: zettide.v3.control_record.Record = .{
        .kind = zettide.v3.control_record.generation_prepare_kind,
        .local_sequence = 99,
        .membership_epoch = authority.membership_epoch,
        .writer_term = @max(authority.writer_term, 1),
        .generation = 1,
        .set_id = authority.topology.set_id,
        .member_id = @splat(8),
        .mount_session_id = @splat(3),
        .transaction_id = @splat(4),
        .previous_record_digest = @splat(0x11),
        .previous_history_digest = @splat(0x22),
        .data_root_digest = try catalog.rootDigest(root),
        .topology_digest = try zettide.v3.pool_topology.digest(authority.topology),
        .layout_digest = try zettide.v3.pool_layout.digest(authority.layout),
        .payload = try zettide.v3.control_record.Payload.init("benchmark catalog"),
    };
    proposal.history_digest = try zettide.v3.control_record.historyDigest(proposal);

    var coordinator = try zettide.v3.pool_replicated_journal.open(io, set);
    defer coordinator.deinit();
    const initialization: graph.DataInitialization = .{
        .volume_id = descriptor.volume_id,
        .logical_start = 0,
        .extent_count = @intCast(mapped_extent_count),
        .contents = .zero,
    };
    _ = try coordinator.commitCatalogGeneration(.{
        .prepare_proposal = proposal,
        .previous_graph = null,
        .current_graph = .{
            .root_bytes = &root_bytes,
            .pages = images[0..if (mapped) images.len else images.len - 1],
        },
        .data_initializations = if (mapped) &.{initialization} else &.{},
    });
    coordinator.close();
    return descriptor.volume_id;
}
