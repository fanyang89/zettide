const std = @import("std");
const Io = std.Io;
const File = Io.File;
const container = @import("container.zig");
const block_device = @import("block_device.zig");
const file_io = @import("file_io.zig");
const metadata = @import("metadata.zig");
const object_format = @import("object_format.zig");
const object_store = @import("object_store.zig");
const pool_block_device = @import("v3/pool_block_device.zig");
const pool_member_set = @import("v3/pool_member_set.zig");
const ReplicaEndpoint = @import("v3/replica_endpoint.zig").ReplicaEndpoint;
const pool_provision = @import("v3/pool_provision.zig");
const storage_api = @import("v3/storage.zig");
const name_profile = @import("name_profile.zig");
pub const nfs_handle = @import("nfs_handle.zig");
const volume_crypto = @import("volume_crypto.zig");
pub const c = block_device.c;

pub const AccessTimePolicy = enum {
    relatime,
    noatime,
};

pub const MountOptions = struct {
    access_time: AccessTimePolicy = .relatime,
    journal_durability: block_device.Durability = .{ .writeback = .{} },
};

pub const PipelineMetrics = struct {
    logical_read_calls: u64,
    logical_read_bytes: u64,
    logical_read_elapsed_ns: u64,
    logical_read_max_ns: u64,
    logical_write_calls: u64,
    logical_write_bytes: u64,
    logical_write_elapsed_ns: u64,
    logical_write_max_ns: u64,
    journaled: bool,
    block_device: block_device.PipelineMetrics,
    member_count: usize = 0,
    members: [3]MemberTransportMetrics = @splat(.{}),
};

pub const MemberTransportMetrics = struct {
    kind: storage_api.TransportKind = .custom,
    stats: storage_api.TransportStats = .{},
};

pub const Volume = struct {
    const Backing = enum { file, pool };

    io: Io,
    file: File,
    header: container.Header,
    device: block_device.FileBlockDevice,
    config: c.struct_lfs_config,
    lfs: c.lfs_t,
    mounted: bool = false,
    closed: bool = false,
    invalidated: std.atomic.Value(bool) = .init(false),
    fallback_uid: u32 = 0,
    fallback_gid: u32 = 0,
    writable: bool = false,
    access_time_policy: AccessTimePolicy = .relatime,
    open_objects: std.AutoHashMap(object_format.ObjectId, OpenObject),
    link_counts: std.AutoHashMap(object_format.ObjectId, u64),
    directory_link_counts: std.AutoHashMap(object_format.ObjectId, u64),
    directory_index: std.AutoHashMap(object_format.ObjectId, DirectoryIndexEntry),
    root_directory_identity: ?object_format.ObjectId = null,
    object_pins: std.AutoHashMap(object_format.ObjectId, u64),
    chunk_cache: object_store.ChunkCache,
    chunk_version_index: object_store.ChunkVersionIndex,
    reservation_blocks: u64 = 0,
    object_transaction_mutex: Io.Mutex,
    view_lock: Io.RwLock,
    backing: Backing = .file,
    pool_set: ?pool_member_set.PoolMemberSet = null,
    pool_device: pool_block_device.PoolBlockDevice = undefined,
    crypto_context: ?*volume_crypto.Context = null,
    crypto_allocator: ?std.mem.Allocator = null,
    logical_write_calls: std.atomic.Value(u64) = .init(0),
    logical_write_bytes: std.atomic.Value(u64) = .init(0),
    logical_write_elapsed_ns: std.atomic.Value(u64) = .init(0),
    logical_write_max_ns: std.atomic.Value(u64) = .init(0),
    logical_read_calls: std.atomic.Value(u64) = .init(0),
    logical_read_bytes: std.atomic.Value(u64) = .init(0),
    logical_read_elapsed_ns: std.atomic.Value(u64) = .init(0),
    logical_read_max_ns: std.atomic.Value(u64) = .init(0),

    pub const RedoJournalOptions = struct {
        length: u64,
        max_transaction_blocks: u32,
    };

    pub const InitializeOptions = struct {
        name_profile: name_profile.Profile = .legacy_raw,
        encryption_credential: ?volume_crypto.Credential = null,
        redo_journal: ?RedoJournalOptions = null,
        file_io: file_io.Mode = .auto,
    };

    pub const OpenOptions = struct {
        encryption_credential: ?volume_crypto.Credential = null,
        file_io: file_io.Mode = .auto,
    };

    pub fn create(io: Io, path: []const u8, logical_size: u64, label: []const u8) !void {
        return createOptions(io, path, logical_size, label, .{});
    }

    pub fn createOptions(
        io: Io,
        path: []const u8,
        logical_size: u64,
        label: []const u8,
        options: InitializeOptions,
    ) !void {
        if (options.encryption_credential != null)
            return error.EncryptionNotSupportedForLegacyContainer;
        var header = try container.Header.initWithNameProfile(io, logical_size, label, options.name_profile);
        if (options.redo_journal) |journal|
            try header.enableRedoJournal(journal.length, journal.max_transaction_blocks);
        const file = try Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .exclusive = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        defer file.close(io);

        try file.setLength(io, try container.requiredFileSize(header));
        var backend = try file_io.init(std.heap.c_allocator, file, options.file_io);
        var owns_backend = true;
        defer if (owns_backend) backend.deinit();
        try container.writeWithFileIo(io, backend.borrow(), container.header_a_offset, header);
        try container.writeWithFileIo(io, backend.borrow(), container.header_b_offset, header);
        try backend.sync(io, .foreground, .full);

        var device = block_device.FileBlockDevice.initWithFileIo(io, &backend, header);
        owns_backend = false;
        defer device.deinit();
        if (header.isJournaled()) try device.enableRedo(std.heap.c_allocator, header);
        var config = device.configure(header);
        try device.beginTransaction();
        initializeFilesystem(io, &config) catch |err| {
            _ = device.abortTransaction() catch {};
            return err;
        };
        try device.commitTransaction();

        header.state = .ready;
        header.sequence += 1;
        try container.writeWithFileIo(io, device.file_io.borrow(), container.header_b_offset, header);
        try device.file_io.sync(io, .foreground, .full);
        header.sequence += 1;
        try container.writeWithFileIo(io, device.file_io.borrow(), container.header_a_offset, header);
        try device.file_io.sync(io, .foreground, .full);
    }

    pub fn initializePool(
        io: Io,
        provisioned: *pool_provision.ProvisionedPool,
        label: []const u8,
    ) !void {
        return initializePoolOptions(io, provisioned, label, .{});
    }

    pub fn initializePoolOptions(
        io: Io,
        provisioned: *pool_provision.ProvisionedPool,
        label: []const u8,
        options: InitializeOptions,
    ) !void {
        var member_pointers: [3]*@import("v3/member.zig").Member = undefined;
        if (provisioned.members.len > member_pointers.len) return error.UnsupportedPoolWidth;
        for (provisioned.members, 0..) |*member, index| member_pointers[index] = member;
        return initializePoolMembers(
            io,
            member_pointers[0..provisioned.members.len],
            provisioned.genesis.layout,
            label,
            options,
        );
    }

    pub fn initializePoolSet(io: Io, set: *pool_member_set.PoolMemberSet, label: []const u8) !void {
        return initializePoolSetOptions(io, set, label, .{});
    }

    pub fn initializePoolSetOptions(
        io: Io,
        set: *pool_member_set.PoolMemberSet,
        label: []const u8,
        options: InitializeOptions,
    ) !void {
        const authority = set.authority() orelse return error.MissingAuthority;
        if (set.controlWriteReady() == null or set.dataAccess() != .read_write)
            return error.PoolWriteUnavailable;
        var member_pointers: [3]*@import("v3/member.zig").Member = undefined;
        const member_count = try collectPoolMembers(set, &member_pointers);
        var replica_endpoints: [3]ReplicaEndpoint = undefined;
        var reader = try pool_block_device.PoolBlockDevice.initHeaderReader(
            io,
            makeReplicaEndpoints(member_pointers[0..member_count], &replica_endpoints),
            authority.layout,
        );
        if (!try reader.canInitializeVolume(std.heap.c_allocator)) return error.PoolVolumeNotEmpty;
        return initializePoolMembers(io, member_pointers[0..member_count], authority.layout, label, options);
    }

    fn initializePoolMembers(
        io: Io,
        members: []const *@import("v3/member.zig").Member,
        layout: @import("v3/pool_layout.zig").Layout,
        label: []const u8,
        options: InitializeOptions,
    ) !void {
        if (options.redo_journal != null) return error.RedoJournalRequiresFileBacking;
        if (options.file_io == .io_uring) return error.FileIoRequiresFileBacking;
        const capacity = members[0].header().logical_capacity;
        const maximum_size = @as(u64, std.math.maxInt(u32)) * container.default_block_size;
        const logical_size = @min(capacity, maximum_size) / container.default_block_size * container.default_block_size;
        var header = try container.Header.initWithNameProfile(io, logical_size, label, options.name_profile);
        var prepared_crypto: ?volume_crypto.Prepared = null;
        defer if (prepared_crypto) |*prepared| prepared.context.deinit();
        if (options.encryption_credential) |credential| {
            if (members.len != 1 or layout.kind != .unprotected)
                return error.EncryptionRequiresUnprotectedSingleMember;
            prepared_crypto = try volume_crypto.prepare(std.heap.c_allocator, io, credential);
            header.setEncryption(prepared_crypto.?.config);
        }
        for (members) |member| {
            header.read_size = @max(header.read_size, member.header().metadata_read_size);
            header.prog_size = @max(header.prog_size, member.header().metadata_program_size);
        }
        try header.validate();
        var replica_endpoints: [3]ReplicaEndpoint = undefined;
        var device = try pool_block_device.PoolBlockDevice.initCrypto(
            io,
            makeReplicaEndpoints(members, &replica_endpoints),
            layout,
            header,
            if (prepared_crypto) |*prepared| &prepared.context else null,
        );
        try device.writeHeaderDurable(container.header_a_offset, header);
        try device.writeHeaderDurable(container.header_b_offset, header);
        if (prepared_crypto != null) try device.initializeEncryptedData();
        var config = device.configure(header);
        try initializeFilesystem(io, &config);
        header.state = .ready;
        header.sequence += 1;
        try device.writeHeaderDurable(container.header_b_offset, header);
        header.sequence += 1;
        try device.writeHeaderDurable(container.header_a_offset, header);
    }

    pub fn openPool(
        io: Io,
        allocator: std.mem.Allocator,
        set_source: *pool_member_set.PoolMemberSet,
        writable: bool,
    ) !Volume {
        return openPoolOptions(io, allocator, set_source, writable, .{});
    }

    pub fn openPoolOptions(
        io: Io,
        allocator: std.mem.Allocator,
        set_source: *pool_member_set.PoolMemberSet,
        writable: bool,
        options: OpenOptions,
    ) !Volume {
        var result: Volume = undefined;
        try openPoolIntoOptions(&result, io, allocator, set_source, writable, options);
        return result;
    }

    pub fn openPoolInto(
        result: *Volume,
        io: Io,
        allocator: std.mem.Allocator,
        set_source: *pool_member_set.PoolMemberSet,
        writable: bool,
    ) !void {
        return openPoolIntoOptions(result, io, allocator, set_source, writable, .{});
    }

    pub fn openPoolIntoOptions(
        result: *Volume,
        io: Io,
        allocator: std.mem.Allocator,
        set_source: *pool_member_set.PoolMemberSet,
        writable: bool,
        options: OpenOptions,
    ) !void {
        if (options.file_io == .io_uring) return error.FileIoRequiresFileBacking;
        result.* = undefined;
        result.pool_set = set_source.*;
        set_source.* = .{};
        const set = &result.pool_set.?;
        errdefer {
            set.deinit();
            result.pool_set = null;
        }
        const authority = set.authority() orelse return error.MissingAuthority;
        if (set.dataAccess() == .unavailable or (writable and set.dataAccess() != .read_write))
            return error.PoolDataUnavailable;
        if (writable and set.controlWriteReady() == null) return error.PoolDataUnavailable;
        const header = try inspectPoolHeader(io, set);
        var member_pointers: [3]*@import("v3/member.zig").Member = undefined;
        const member_count = try collectPoolMembers(set, &member_pointers);
        var crypto_context: ?*volume_crypto.Context = null;
        errdefer if (crypto_context) |context| {
            context.deinit();
            allocator.destroy(context);
        };
        if (header.encryption) |encryption| {
            if (authority.layout.kind != .unprotected or member_count != 1)
                return error.UnsupportedEncryptedPool;
            const credential = options.encryption_credential orelse
                return error.EncryptionCredentialRequired;
            const context = try allocator.create(volume_crypto.Context);
            context.* = volume_crypto.Context.open(allocator, io, encryption, credential) catch |err| {
                allocator.destroy(context);
                return err;
            };
            crypto_context = context;
        } else if (options.encryption_credential != null) {
            return error.UnexpectedEncryptionCredential;
        }
        var replica_endpoints: [3]ReplicaEndpoint = undefined;
        var verifier = try pool_block_device.PoolBlockDevice.initCrypto(
            io,
            makeReplicaEndpoints(member_pointers[0..member_count], &replica_endpoints),
            authority.layout,
            header,
            crypto_context,
        );
        if (writable) try verifier.prepareWritableReplicas(allocator);

        result.io = io;
        result.file = undefined;
        result.header = header;
        result.device = undefined;
        result.config = undefined;
        result.lfs = std.mem.zeroes(c.lfs_t);
        result.mounted = false;
        result.closed = false;
        result.invalidated = .init(false);
        result.fallback_uid = 0;
        result.fallback_gid = 0;
        result.writable = writable;
        result.access_time_policy = .relatime;
        result.open_objects = std.AutoHashMap(object_format.ObjectId, OpenObject).init(std.heap.c_allocator);
        result.link_counts = std.AutoHashMap(object_format.ObjectId, u64).init(std.heap.c_allocator);
        result.directory_link_counts = std.AutoHashMap(object_format.ObjectId, u64).init(std.heap.c_allocator);
        result.directory_index = std.AutoHashMap(object_format.ObjectId, DirectoryIndexEntry).init(std.heap.c_allocator);
        result.root_directory_identity = null;
        result.object_pins = std.AutoHashMap(object_format.ObjectId, u64).init(std.heap.c_allocator);
        result.chunk_cache = .{};
        result.chunk_version_index = .init(std.heap.c_allocator);
        result.reservation_blocks = 0;
        result.object_transaction_mutex = .init;
        result.view_lock = .init;
        result.backing = .pool;
        result.pool_device = undefined;
        result.crypto_context = crypto_context;
        result.crypto_allocator = if (crypto_context != null) allocator else null;
        result.logical_write_calls = .init(0);
        result.logical_write_bytes = .init(0);
        result.logical_write_elapsed_ns = .init(0);
        result.logical_write_max_ns = .init(0);
        result.logical_read_calls = .init(0);
        result.logical_read_bytes = .init(0);
        result.logical_read_elapsed_ns = .init(0);
        result.logical_read_max_ns = .init(0);
    }

    pub fn inspectPoolHeader(io: Io, set: *pool_member_set.PoolMemberSet) !container.Header {
        const authority = set.authority() orelse return error.MissingAuthority;
        var member_pointers: [3]*@import("v3/member.zig").Member = undefined;
        const member_count = try collectPoolMembers(set, &member_pointers);
        var replica_endpoints: [3]ReplicaEndpoint = undefined;
        var reader = try pool_block_device.PoolBlockDevice.initHeaderReader(
            io,
            makeReplicaEndpoints(member_pointers[0..member_count], &replica_endpoints),
            authority.layout,
        );
        return reader.readHeader();
    }

    pub fn canInitializePool(io: Io, set: *pool_member_set.PoolMemberSet) !bool {
        const authority = set.authority() orelse return error.MissingAuthority;
        var member_pointers: [3]*@import("v3/member.zig").Member = undefined;
        const member_count = try collectPoolMembers(set, &member_pointers);
        var replica_endpoints: [3]ReplicaEndpoint = undefined;
        var reader = try pool_block_device.PoolBlockDevice.initHeaderReader(
            io,
            makeReplicaEndpoints(member_pointers[0..member_count], &replica_endpoints),
            authority.layout,
        );
        return reader.canInitializeVolume(std.heap.c_allocator);
    }

    pub fn open(io: Io, path: []const u8, writable: bool) !Volume {
        return openOptions(io, path, writable, .{});
    }

    pub fn openOptions(io: Io, path: []const u8, writable: bool, options: OpenOptions) !Volume {
        var result: Volume = undefined;
        try openIntoOptions(&result, io, path, writable, options);
        return result;
    }

    pub fn openInto(result: *Volume, io: Io, path: []const u8, writable: bool) !void {
        return openIntoOptions(result, io, path, writable, .{});
    }

    pub fn openIntoOptions(
        result: *Volume,
        io: Io,
        path: []const u8,
        writable: bool,
        options: OpenOptions,
    ) !void {
        const file = try Io.Dir.cwd().openFile(io, path, .{
            .mode = if (writable) .read_write else .read_only,
            .lock = if (writable) .exclusive else .shared,
            .lock_nonblocking = true,
        });
        errdefer file.close(io);
        var backend = try file_io.init(std.heap.c_allocator, file, options.file_io);
        var owns_backend = true;
        errdefer if (owns_backend) backend.deinit();
        const header = try container.readWithFileIo(file, io, backend.borrow());
        if (header.isEncrypted()) return error.EncryptionNotSupportedForLegacyContainer;
        if (options.encryption_credential != null) return error.UnexpectedEncryptionCredential;

        result.* = undefined;
        result.io = io;
        result.file = file;
        result.header = header;
        result.device = block_device.FileBlockDevice.initWithFileIo(io, &backend, header);
        owns_backend = false;
        errdefer result.device.deinit();
        if (header.isJournaled()) try result.device.enableRedo(std.heap.c_allocator, header);
        result.config = result.device.configure(header);
        result.lfs = std.mem.zeroes(c.lfs_t);
        result.mounted = false;
        result.closed = false;
        result.invalidated = .init(false);
        result.fallback_uid = 0;
        result.fallback_gid = 0;
        result.writable = writable;
        result.access_time_policy = .relatime;
        result.open_objects = std.AutoHashMap(object_format.ObjectId, OpenObject).init(std.heap.c_allocator);
        result.link_counts = std.AutoHashMap(object_format.ObjectId, u64).init(std.heap.c_allocator);
        result.directory_link_counts = std.AutoHashMap(object_format.ObjectId, u64).init(std.heap.c_allocator);
        result.directory_index = std.AutoHashMap(object_format.ObjectId, DirectoryIndexEntry).init(std.heap.c_allocator);
        result.root_directory_identity = null;
        result.object_pins = std.AutoHashMap(object_format.ObjectId, u64).init(std.heap.c_allocator);
        result.chunk_cache = .{};
        result.chunk_version_index = .init(std.heap.c_allocator);
        result.reservation_blocks = 0;
        result.object_transaction_mutex = .init;
        result.view_lock = .init;
        result.backing = .file;
        result.pool_set = null;
        result.pool_device = undefined;
        result.crypto_context = null;
        result.crypto_allocator = null;
        result.logical_write_calls = .init(0);
        result.logical_write_bytes = .init(0);
        result.logical_write_elapsed_ns = .init(0);
        result.logical_write_max_ns = .init(0);
        result.logical_read_calls = .init(0);
        result.logical_read_bytes = .init(0);
        result.logical_read_elapsed_ns = .init(0);
        result.logical_read_max_ns = .init(0);
    }

    pub fn setFallbackOwner(self: *Volume, uid: u32, gid: u32) void {
        self.view_lock.lockUncancelable(self.io);
        defer self.view_lock.unlock(self.io);
        self.fallback_uid = uid;
        self.fallback_gid = gid;
    }

    pub fn volumeUuid(self: *const Volume) [16]u8 {
        return self.header.uuid;
    }

    pub fn statIdentity(self: *Volume, handle: nfs_handle.Handle) !NodeInfo {
        const info = if (handle.kind == .directory)
            try self.statDirectoryIdentity(handle.identity)
        else
            try self.statObject(handle.identity);
        if (info.metadata.kind != handle.kind or !std.mem.eql(u8, &info.identity, &handle.identity))
            return error.FileNotFound;
        return info;
    }

    pub fn setMetadataIdentity(
        self: *Volume,
        handle: nfs_handle.Handle,
        value: metadata.Metadata,
    ) !NodeInfo {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        var mutation = try self.beginMutation();
        defer mutation.deinit();

        const info = if (handle.kind == .directory) value: {
            var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
            const path = try self.directoryPathUnlocked(handle.identity, &path_buffer);
            const current = try self.statUnlocked(path);
            if (current.metadata.kind != handle.kind or
                !std.mem.eql(u8, &current.identity, &handle.identity) or
                value.kind != handle.kind)
                return error.FileNotFound;
            var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
            const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
            try self.setDirectoryMetadataTranslated(translated, value.encode());
            var updated = current;
            updated.metadata = value;
            break :value updated;
        } else value: {
            const current = try self.statObjectUnlocked(handle.identity);
            if (current.metadata.kind != handle.kind or value.kind != handle.kind)
                return error.FileNotFound;
            try self.store().updateMetadata(handle.identity, value);
            self.updateOpenMetadata(handle.identity, value);
            var updated = current;
            updated.metadata = value;
            break :value updated;
        };
        try mutation.commit();
        return info;
    }

    pub fn mount(self: *Volume) !void {
        return self.mountOptions(.{});
    }

    pub fn mountOptions(self: *Volume, options: MountOptions) !void {
        if (self.closed) return error.VolumeClosed;
        if (self.mounted) return error.AlreadyMounted;
        self.access_time_policy = options.access_time;
        // Moving Volume after this call is invalid because littlefs retains these pointers.
        if (self.backing == .pool) {
            const authority = self.pool_set.?.authority() orelse return error.MissingAuthority;
            var member_pointers: [3]*@import("v3/member.zig").Member = undefined;
            const member_count = try collectPoolMembers(&self.pool_set.?, &member_pointers);
            var replica_endpoints: [3]ReplicaEndpoint = undefined;
            self.pool_device = try pool_block_device.PoolBlockDevice.initCrypto(
                self.io,
                makeReplicaEndpoints(member_pointers[0..member_count], &replica_endpoints),
                authority.layout,
                self.header,
                self.crypto_context,
            );
            self.config = self.pool_device.configure(self.header);
            self.config.context = &self.pool_device;
        } else {
            self.config.context = &self.device;
        }
        try checkLfs(c.lfs_mount(&self.lfs, &self.config));
        self.mounted = true;
        errdefer {
            _ = c.lfs_unmount(&self.lfs);
            if (self.backing == .file) self.device.finishWriteback() catch {};
            self.mounted = false;
        }
        if (self.backing == .file and self.writable and self.device.isJournaled())
            try self.device.setDurability(options.journal_durability);
        self.link_counts.clearRetainingCapacity();
        self.directory_link_counts.clearRetainingCapacity();
        self.directory_index.clearRetainingCapacity();
        self.root_directory_identity = null;
        self.object_pins.clearRetainingCapacity();
        try self.store().collectLinkCounts(&self.link_counts);
        var recovered_heads = std.AutoHashMap(object_format.ObjectId, object_format.ObjectHead).init(std.heap.c_allocator);
        defer recovered_heads.deinit();
        var recovery_mutation = if (self.writable) try self.beginMutation() else Mutation{};
        defer recovery_mutation.deinit();
        if (self.writable) try self.store().recoverOrphans(&self.link_counts, &recovered_heads);
        try self.rebuildDirectoryIndex();
        self.reservation_blocks = try self.collectReservationBlocks(if (self.writable) &recovered_heads else null);
        try recovery_mutation.commit();
    }

    pub fn close(self: *Volume) !void {
        if (self.closed) return;

        var first_error: ?anyerror = null;
        if (self.writable and self.mounted) {
            self.sync() catch |err| {
                first_error = err;
            };
        }
        if (self.mounted) {
            checkLfs(c.lfs_unmount(&self.lfs)) catch |err| {
                if (first_error == null) first_error = err;
            };
            self.mounted = false;
        }
        if (self.backing == .pool) {
            if (self.pool_set) |*set| set.close() catch |err| {
                if (!set.isClosed()) return err;
                if (first_error == null) first_error = err;
            };
            self.pool_set = null;
        } else {
            self.device.finishWriteback() catch |err| {
                if (first_error == null) first_error = err;
            };
            self.device.deinit();
            self.file.close(self.io);
        }
        self.open_objects.deinit();
        self.directory_index.deinit();
        self.directory_link_counts.deinit();
        self.object_pins.deinit();
        self.link_counts.deinit();
        self.chunk_cache.deinit(std.heap.c_allocator);
        self.chunk_version_index.deinit();
        if (self.crypto_context) |context| {
            context.deinit();
            self.crypto_allocator.?.destroy(context);
            self.crypto_context = null;
            self.crypto_allocator = null;
        }
        self.closed = true;

        if (first_error) |err| return err;
    }

    pub fn pipelineMetrics(self: *Volume) PipelineMetrics {
        var result: PipelineMetrics = .{
            .logical_read_calls = self.logical_read_calls.load(.acquire),
            .logical_read_bytes = self.logical_read_bytes.load(.acquire),
            .logical_read_elapsed_ns = self.logical_read_elapsed_ns.load(.acquire),
            .logical_read_max_ns = self.logical_read_max_ns.load(.acquire),
            .logical_write_calls = self.logical_write_calls.load(.acquire),
            .logical_write_bytes = self.logical_write_bytes.load(.acquire),
            .logical_write_elapsed_ns = self.logical_write_elapsed_ns.load(.acquire),
            .logical_write_max_ns = self.logical_write_max_ns.load(.acquire),
            .journaled = self.backing == .file and self.device.isJournaled(),
            .block_device = if (self.backing == .file)
                self.device.pipelineMetrics()
            else
                self.pool_device.pipelineMetrics(),
        };
        if (self.backing == .pool) {
            for (0..self.pool_set.?.suppliedCount()) |index| {
                const member = (self.pool_set.?.memberAt(index) catch null) orelse continue;
                result.members[result.member_count] = .{
                    .kind = member.transportKind(),
                    .stats = member.transportStats(),
                };
                result.member_count += 1;
            }
        }
        return result;
    }

    pub fn resetPipelineMetrics(self: *Volume) void {
        self.logical_read_calls.store(0, .release);
        self.logical_read_bytes.store(0, .release);
        self.logical_read_elapsed_ns.store(0, .release);
        self.logical_read_max_ns.store(0, .release);
        self.logical_write_calls.store(0, .release);
        self.logical_write_bytes.store(0, .release);
        self.logical_write_elapsed_ns.store(0, .release);
        self.logical_write_max_ns.store(0, .release);
        if (self.backing == .file) {
            self.device.resetPipelineMetrics();
            return;
        }
        self.pool_device.resetPipelineMetrics();
        for (0..self.pool_set.?.suppliedCount()) |index| {
            const member = (self.pool_set.?.memberAt(index) catch null) orelse continue;
            member.resetTransportStats();
        }
    }

    pub fn deinit(self: *Volume) void {
        self.close() catch {};
    }

    pub fn usedBlocks(self: *Volume) !u32 {
        var view = try self.beginView();
        defer view.deinit();
        return self.usedBlocksUnlocked();
    }

    fn usedBlocksUnlocked(self: *Volume) !u32 {
        const result = c.lfs_fs_size(&self.lfs);
        try checkLfs(result);
        return @intCast(result);
    }

    pub fn availableBlocks(self: *Volume) !u64 {
        var view = try self.beginView();
        defer view.deinit();
        const used = try self.usedBlocksUnlocked();
        const free = @as(u64, self.header.block_count) - used;
        return free -| self.reservation_blocks;
    }

    pub fn reservedCapacityBlocks(self: *Volume) !u64 {
        var view = try self.beginView();
        defer view.deinit();
        return self.reservation_blocks;
    }

    pub fn isWriteFrozen(self: *const Volume) bool {
        return if (self.backing == .pool)
            self.mounted and self.pool_device.isWriteFrozen()
        else
            self.device.isWriteFrozen();
    }

    fn syncBacking(self: *Volume) !void {
        if (self.backing == .pool) {
            if (!self.mounted) return error.VolumeNotMounted;
            return self.pool_device.sync();
        }
        return self.device.sync();
    }

    pub fn stat(self: *Volume, path: [*:0]const u8) !NodeInfo {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginStateMutation();
        defer mutation.deinit();
        const result = try self.statUnlocked(path);
        try mutation.commit();
        return result;
    }

    fn statUnlocked(self: *Volume, path: [*:0]const u8) !NodeInfo {
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        if (info.type == c.LFS_TYPE_DIR) {
            const stored_metadata = self.getDirectoryMetadataTranslated(translated) catch |err| switch (err) {
                error.AttributeNotFound => metadata.Metadata.init(
                    self.io,
                    .directory,
                    0o40755,
                    self.fallback_uid,
                    self.fallback_gid,
                ),
                else => return err,
            };
            const identity = try self.directoryIdentity(translated);
            const link_count = self.directory_link_counts.get(identity) orelse value: {
                const count = try self.directoryLinkCount(translated);
                try self.directory_link_counts.put(identity, count);
                break :value count;
            };
            return .{
                .size = 0,
                .allocated_bytes = 0,
                .metadata = stored_metadata,
                .object_id = null,
                .identity = identity,
                .nlink = link_count,
            };
        }
        const object_ref = try self.store().readRef(path);
        const head = try self.store().readHead(object_ref.object_id);
        return .{
            .size = head.logical_size,
            .allocated_bytes = head.allocated_bytes,
            .metadata = head.metadata,
            .object_id = object_ref.object_id,
            .identity = object_ref.object_id,
            .nlink = try self.linkCountUnlocked(object_ref.object_id),
        };
    }

    pub fn statFile(self: *Volume, handle: *FileHandle) !NodeInfo {
        var view = try self.beginView();
        defer view.deinit();
        const info = try self.statObjectUnlocked(handle.object_id);
        handle.metadata = info.metadata;
        return info;
    }

    pub fn statObject(self: *Volume, object_id: object_format.ObjectId) !NodeInfo {
        var view = try self.beginView();
        defer view.deinit();
        return self.statObjectUnlocked(object_id);
    }

    fn statObjectUnlocked(self: *Volume, object_id: object_format.ObjectId) !NodeInfo {
        const head = try self.store().readHead(object_id);
        return .{
            .size = head.logical_size,
            .allocated_bytes = head.allocated_bytes,
            .metadata = head.metadata,
            .object_id = object_id,
            .identity = object_id,
            .nlink = try self.linkCountUnlocked(object_id),
        };
    }

    pub fn linkCount(self: *const Volume, object_id: object_format.ObjectId) !u64 {
        const mutable: *Volume = @constCast(self);
        var view = try mutable.beginView();
        defer view.deinit();
        return self.linkCountUnlocked(object_id);
    }

    fn linkCountUnlocked(self: *const Volume, object_id: object_format.ObjectId) !u64 {
        return self.link_counts.get(object_id) orelse error.CorruptFilesystem;
    }

    pub fn pinObject(self: *Volume, object_id: object_format.ObjectId) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginStateMutation();
        defer mutation.deinit();
        if (!self.link_counts.contains(object_id)) return error.CorruptFilesystem;
        const entry = try self.object_pins.getOrPut(object_id);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* = std.math.add(u64, entry.value_ptr.*, 1) catch
            return error.TooManyReferences;
        try mutation.commit();
    }

    pub fn unpinObject(self: *Volume, object_id: object_format.ObjectId) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const count = self.object_pins.getPtr(object_id) orelse return error.InvalidArgument;
        if (count.* == 0) return error.InvalidArgument;
        count.* -= 1;
        if (count.* == 0) {
            _ = self.object_pins.remove(object_id);
            try self.reclaimObjectIfUnused(object_id);
        }
        try mutation.commit();
    }

    pub fn objectPinCount(self: *Volume, object_id: object_format.ObjectId) !u64 {
        var view = try self.beginView();
        defer view.deinit();
        return self.objectPinCountUnlocked(object_id);
    }

    fn objectPinCountUnlocked(self: *const Volume, object_id: object_format.ObjectId) u64 {
        return self.object_pins.get(object_id) orelse 0;
    }

    pub fn trackedObjectCount(self: *Volume) !usize {
        var view = try self.beginView();
        defer view.deinit();
        return self.link_counts.count();
    }

    pub fn rootDirectoryIdentity(self: *Volume) !object_format.ObjectId {
        var view = try self.beginView();
        defer view.deinit();
        return self.root_directory_identity orelse error.CorruptFilesystem;
    }

    pub fn parentDirectoryIdentity(
        self: *Volume,
        identity: object_format.ObjectId,
    ) !object_format.ObjectId {
        var view = try self.beginView();
        defer view.deinit();
        return (self.directory_index.get(identity) orelse return error.FileNotFound).parent;
    }

    pub fn statDirectoryIdentity(self: *Volume, identity: object_format.ObjectId) !NodeInfo {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginStateMutation();
        defer mutation.deinit();
        var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const path = try self.directoryPathUnlocked(identity, &path_buffer);
        const result = try self.statUnlocked(path);
        if (result.metadata.kind != .directory or !std.mem.eql(u8, &result.identity, &identity))
            return error.CorruptFilesystem;
        try mutation.commit();
        return result;
    }

    pub fn lookupAt(
        self: *Volume,
        parent_identity: object_format.ObjectId,
        name: []const u8,
    ) !NodeInfo {
        if (name.len == 0 or name.len >= directory_name_capacity or
            std.mem.indexOfScalar(u8, name, '/') != null or
            std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
            return error.InvalidArgument;
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginStateMutation();
        defer mutation.deinit();
        var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const path = try self.childPathUnlocked(parent_identity, name, &path_buffer);
        const result = try self.statUnlocked(path);
        try mutation.commit();
        return result;
    }

    pub fn setMetadata(self: *Volume, path: [*:0]const u8, value: metadata.Metadata) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        if (info.type != c.LFS_TYPE_DIR) {
            const object_ref = try self.store().readRef(path);
            try self.store().updateMetadata(object_ref.object_id, value);
            self.updateOpenMetadata(object_ref.object_id, value);
        } else {
            const bytes = value.encode();
            try self.setDirectoryMetadataTranslated(translated, bytes);
        }
        try mutation.commit();
    }

    pub fn getMetadata(self: *Volume, path: [*:0]const u8) !metadata.Metadata {
        var view = try self.beginView();
        defer view.deinit();
        return self.getMetadataUnlocked(path);
    }

    fn getMetadataUnlocked(self: *Volume, path: [*:0]const u8) !metadata.Metadata {
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        if (info.type != c.LFS_TYPE_DIR) {
            const object_ref = try self.store().readRef(path);
            return (try self.store().readHead(object_ref.object_id)).metadata;
        }
        return self.getDirectoryMetadataTranslated(translated);
    }

    fn getDirectoryMetadataTranslated(self: *Volume, translated: [*:0]const u8) !metadata.Metadata {
        var bytes: [metadata.encoded_size]u8 = undefined;
        const result = c.lfs_getattr(&self.lfs, translated, metadata.attribute_type, &bytes, bytes.len);
        if (result < 0) {
            try checkLfs(result);
            unreachable;
        }
        if (result != bytes.len) return error.InvalidMetadata;
        return metadata.Metadata.decode(&bytes);
    }

    fn setDirectoryMetadataTranslated(
        self: *Volume,
        translated: [*:0]const u8,
        bytes: [metadata.encoded_size]u8,
    ) !void {
        try checkLfs(c.lfs_setattr(&self.lfs, translated, metadata.attribute_type, &bytes, bytes.len));
    }

    pub fn makeDirectory(self: *Volume, path: [*:0]const u8, mode: u32, uid: u32, gid: u32) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        _ = try self.makeDirectoryUnlocked(path, mode, uid, gid);
    }

    pub fn makeDirectoryAt(
        self: *Volume,
        parent_identity: object_format.ObjectId,
        name: []const u8,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !NodeInfo {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        return self.makeDirectoryUnlocked(
            try self.childPathUnlocked(parent_identity, name, &path_buffer),
            mode,
            uid,
            gid,
        );
    }

    fn makeDirectoryUnlocked(self: *Volume, path: [*:0]const u8, mode: u32, uid: u32, gid: u32) !NodeInfo {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const inherited = try self.inheritCreateMetadata(path, mode, gid, true);
        try self.ensureGrowthCapacity();
        try self.directory_index.ensureUnusedCapacity(1);
        const parent_path = parentSlice(path);
        var parent_path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        @memcpy(parent_path_buffer[0..parent_path.len], parent_path);
        var parent_translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const parent_translated = try object_store.Store.translateUserPath(&parent_path_buffer, &parent_translated_buffer);
        const parent_identity = try self.directoryIdentity(parent_translated);
        const name = baseNameSlice(path);
        var identity: object_format.ObjectId = undefined;
        try self.io.randomSecure(&identity);
        if (self.directory_index.contains(identity)) return error.CorruptFilesystem;
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        try checkLfs(c.lfs_mkdir(&self.lfs, translated));
        errdefer _ = c.lfs_remove(&self.lfs, translated);
        try checkLfs(c.lfs_setattr(
            &self.lfs,
            translated,
            metadata.directory_identity_attribute_type,
            &identity,
            identity.len,
        ));
        const directory_metadata = metadata.Metadata.init(
            self.io,
            .directory,
            inherited.mode,
            uid,
            inherited.gid,
        );
        try self.setDirectoryMetadataTranslated(translated, directory_metadata.encode());
        try self.updateParentTimes(path);
        self.adjustCachedParentLinkCount(path, true);
        self.directory_index.putAssumeCapacityNoClobber(
            identity,
            try DirectoryIndexEntry.init(parent_identity, name),
        );
        errdefer _ = self.directory_index.remove(identity);
        try mutation.commit();
        return .{
            .size = 0,
            .allocated_bytes = 0,
            .metadata = directory_metadata,
            .object_id = null,
            .identity = identity,
            .nlink = 2,
        };
    }

    pub fn makeSymlink(self: *Volume, path: [*:0]const u8, target: []const u8, uid: u32, gid: u32) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        _ = try self.makeSymlinkUnlocked(path, target, uid, gid);
    }

    pub fn makeSymlinkAt(
        self: *Volume,
        parent_identity: object_format.ObjectId,
        name: []const u8,
        target: []const u8,
        uid: u32,
        gid: u32,
    ) !NodeInfo {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        return self.makeSymlinkUnlocked(
            try self.childPathUnlocked(parent_identity, name, &path_buffer),
            target,
            uid,
            gid,
        );
    }

    fn makeSymlinkUnlocked(
        self: *Volume,
        path: [*:0]const u8,
        target: []const u8,
        uid: u32,
        gid: u32,
    ) !NodeInfo {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const inherited = try self.inheritCreateMetadata(path, 0o120777, gid, false);
        const result = try self.createSpecial(path, target, .symlink, .symlink, inherited.mode, uid, inherited.gid);
        try mutation.commit();
        return result;
    }

    pub fn makeFifo(self: *Volume, path: [*:0]const u8, mode: u32, uid: u32, gid: u32) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const inherited = try self.inheritCreateMetadata(path, mode, gid, false);
        _ = try self.createSpecial(path, "", .fifo, .fifo, inherited.mode, uid, inherited.gid);
        try mutation.commit();
    }

    pub fn link(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !void {
        _ = try self.linkWithInfo(old_path, new_path);
    }

    pub fn linkWithInfo(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !NodeInfo {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const object_ref = self.store().readRef(old_path) catch |err| switch (err) {
            error.IsDirectory => return error.PermissionDenied,
            else => return err,
        };
        const result = try self.linkObjectRefUnlocked(object_ref, new_path);
        try mutation.commit();
        return result;
    }

    pub fn linkObjectAt(
        self: *Volume,
        object_id: object_format.ObjectId,
        parent_identity: object_format.ObjectId,
        name: []const u8,
    ) !NodeInfo {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const head = try self.store().readHead(object_id);
        const kind: object_format.RefKind = switch (head.metadata.kind) {
            .file => .file,
            .symlink => .symlink,
            .fifo => .fifo,
            .directory => return error.PermissionDenied,
        };
        var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const result = try self.linkObjectRefUnlocked(
            .{ .kind = kind, .object_id = object_id },
            try self.childPathUnlocked(parent_identity, name, &path_buffer),
        );
        try mutation.commit();
        return result;
    }

    fn linkObjectRefUnlocked(
        self: *Volume,
        object_ref: object_format.ObjectRef,
        new_path: [*:0]const u8,
    ) !NodeInfo {
        const count = self.link_counts.getPtr(object_ref.object_id) orelse
            return error.CorruptFilesystem;
        if (count.* == std.math.maxInt(u64)) return error.TooManyLinks;
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = try object_store.Store.translateUserPath(new_path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        const stat_result = c.lfs_stat(&self.lfs, translated, &info);
        if (stat_result >= 0) return error.PathAlreadyExists;
        if (stat_result != c.LFS_ERR_NOENT) try checkLfs(stat_result);
        try self.validateParentDirectory(new_path);
        try self.ensureGrowthCapacity();
        var head = try self.store().readHead(object_ref.object_id);
        head.metadata.ctime_ns = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        head = try self.store().updateMetadataWithHead(head, head.metadata);
        self.updateOpenMetadata(object_ref.object_id, head.metadata);
        try self.updateParentTimes(new_path);
        try self.store().publishRef(new_path, object_ref, true);
        count.* += 1;
        const result: NodeInfo = .{
            .size = head.logical_size,
            .allocated_bytes = head.allocated_bytes,
            .metadata = head.metadata,
            .object_id = object_ref.object_id,
            .identity = object_ref.object_id,
            .nlink = count.*,
        };
        return result;
    }

    pub fn remove(self: *Volume, path: [*:0]const u8) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.removeUnlocked(path);
    }

    pub fn removeAt(
        self: *Volume,
        parent_identity: object_format.ObjectId,
        name: []const u8,
    ) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        try self.removeUnlocked(try self.childPathUnlocked(parent_identity, name, &path_buffer));
    }

    fn removeUnlocked(self: *Volume, path: [*:0]const u8) !void {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = try object_store.Store.translateUserPath(path, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        const removed_directory_identity = if (info.type == c.LFS_TYPE_DIR)
            try self.directoryIdentity(translated)
        else
            null;
        const removed_object = if (info.type == c.LFS_TYPE_DIR) null else try self.store().readRef(path);
        if (info.type == c.LFS_TYPE_DIR and !try self.directoryIsEmpty(translated))
            return error.DirectoryNotEmpty;
        const object_count = if (removed_object) |object_ref|
            self.link_counts.getPtr(object_ref.object_id) orelse return error.CorruptFilesystem
        else
            null;
        if (object_count) |count| if (count.* == 0) return error.CorruptFilesystem;
        if (removed_object) |object_ref| {
            const retained = object_count.?.* > 1 or
                self.hasOpenObject(object_ref.object_id) or
                self.objectPinCountUnlocked(object_ref.object_id) != 0;
            if (retained) {
                var head = try self.store().readHead(object_ref.object_id);
                head.metadata.ctime_ns = @intCast(Io.Clock.real.now(self.io).nanoseconds);
                head = try self.store().updateMetadataWithHead(head, head.metadata);
                self.updateOpenMetadata(object_ref.object_id, head.metadata);
            }
        }
        try self.updateParentTimes(path);
        try checkLfs(c.lfs_remove(&self.lfs, translated));
        const removed_directory_entry = if (removed_directory_identity) |identity|
            self.directory_index.fetchRemove(identity) orelse return error.CorruptFilesystem
        else
            null;
        errdefer if (removed_directory_entry) |entry|
            self.directory_index.put(entry.key, entry.value) catch {};
        if (info.type == c.LFS_TYPE_DIR) self.adjustCachedParentLinkCount(path, false);
        if (removed_object) |object_ref| {
            object_count.?.* -= 1;
            self.reclaimObjectIfUnused(object_ref.object_id) catch {};
        }
        try mutation.commit();
    }

    pub fn rename(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !void {
        _ = try self.renameWithResult(old_path, new_path);
    }

    pub fn renameWithResult(self: *Volume, old_path: [*:0]const u8, new_path: [*:0]const u8) !RenameResult {
        return self.renameWithOptions(old_path, new_path, false);
    }

    pub fn renameWithResultNoReplace(
        self: *Volume,
        old_path: [*:0]const u8,
        new_path: [*:0]const u8,
    ) !RenameResult {
        return self.renameWithOptions(old_path, new_path, true);
    }

    fn renameWithOptions(
        self: *Volume,
        old_path: [*:0]const u8,
        new_path: [*:0]const u8,
        no_replace: bool,
    ) !RenameResult {
        if (std.mem.eql(u8, std.mem.span(old_path), std.mem.span(new_path))) return .same_object;
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        return self.renameWithOptionsUnlocked(old_path, new_path, no_replace);
    }

    pub fn renameAt(
        self: *Volume,
        old_parent_identity: object_format.ObjectId,
        old_name: []const u8,
        new_parent_identity: object_format.ObjectId,
        new_name: []const u8,
        no_replace: bool,
    ) !RenameResult {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var old_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        var new_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const old_path = try self.childPathUnlocked(old_parent_identity, old_name, &old_buffer);
        const new_path = try self.childPathUnlocked(new_parent_identity, new_name, &new_buffer);
        if (std.mem.eql(u8, std.mem.span(old_path), std.mem.span(new_path))) return .same_object;
        return self.renameWithOptionsUnlocked(old_path, new_path, no_replace);
    }

    fn renameWithOptionsUnlocked(
        self: *Volume,
        old_path: [*:0]const u8,
        new_path: [*:0]const u8,
        no_replace: bool,
    ) !RenameResult {
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        var old_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        var new_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const old_translated = try object_store.Store.translateUserPath(old_path, &old_buffer);
        const new_translated = try object_store.Store.translateUserPath(new_path, &new_buffer);
        var old_info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, old_translated, &old_info));
        var new_info: c.struct_lfs_info = undefined;
        const new_stat_result = c.lfs_stat(&self.lfs, new_translated, &new_info);
        const new_exists = new_stat_result >= 0;
        if (!new_exists and new_stat_result != c.LFS_ERR_NOENT) try checkLfs(new_stat_result);
        if (no_replace and new_exists) return error.PathAlreadyExists;
        if (new_exists) {
            if (old_info.type == c.LFS_TYPE_DIR and new_info.type != c.LFS_TYPE_DIR)
                return error.NotDirectory;
            if (old_info.type != c.LFS_TYPE_DIR and new_info.type == c.LFS_TYPE_DIR)
                return error.IsDirectory;
            if (new_info.type == c.LFS_TYPE_DIR and !try self.directoryIsEmpty(new_translated))
                return error.DirectoryNotEmpty;
        }
        if (old_info.type == c.LFS_TYPE_DIR) {
            const old_value = std.mem.span(old_path);
            const new_parent = parentSlice(new_path);
            if (std.mem.eql(u8, old_value, new_parent) or
                (new_parent.len > old_value.len and std.mem.startsWith(u8, new_parent, old_value) and
                    new_parent[old_value.len] == '/'))
                return error.InvalidArgument;
        }
        try self.validateParentDirectory(new_path);
        const source_directory_identity = if (old_info.type == c.LFS_TYPE_DIR)
            try self.directoryIdentity(old_translated)
        else
            null;
        const replaced_directory_identity = if (new_exists and new_info.type == c.LFS_TYPE_DIR)
            try self.directoryIdentity(new_translated)
        else
            null;
        const original_source_entry = if (source_directory_identity) |identity|
            self.directory_index.get(identity) orelse return error.CorruptFilesystem
        else
            null;
        var new_parent_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const new_parent_path = parentSlice(new_path);
        @memcpy(new_parent_buffer[0..new_parent_path.len], new_parent_path);
        var new_parent_translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const new_parent_translated = try object_store.Store.translateUserPath(
            &new_parent_buffer,
            &new_parent_translated_buffer,
        );
        const new_parent_identity = if (source_directory_identity != null)
            try self.directoryIdentity(new_parent_translated)
        else
            undefined;
        const replaced = self.store().readRef(new_path) catch |err| switch (err) {
            error.FileNotFound, error.IsDirectory => null,
            else => return err,
        };
        const source = self.store().readRef(old_path) catch |err| switch (err) {
            error.IsDirectory => null,
            else => return err,
        };
        if (source != null and replaced != null and
            std.mem.eql(u8, &source.?.object_id, &replaced.?.object_id))
            return .same_object;
        const replaced_count = if (replaced) |object_ref|
            self.link_counts.getPtr(object_ref.object_id) orelse return error.CorruptFilesystem
        else
            null;
        if (replaced_count) |count| if (count.* == 0) return error.CorruptFilesystem;
        const timestamp: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        if (replaced) |object_ref| {
            var head = try self.store().readHead(object_ref.object_id);
            head.metadata.ctime_ns = timestamp;
            head = try self.store().updateMetadataWithHead(head, head.metadata);
            self.updateOpenMetadata(object_ref.object_id, head.metadata);
        }
        if (source) |object_ref| {
            var head = try self.store().readHead(object_ref.object_id);
            head.metadata.ctime_ns = timestamp;
            head = try self.store().updateMetadataWithHead(head, head.metadata);
            self.updateOpenMetadata(object_ref.object_id, head.metadata);
        } else {
            var renamed_metadata = try self.getDirectoryMetadataTranslated(old_translated);
            renamed_metadata.ctime_ns = timestamp;
            try self.setDirectoryMetadataTranslated(old_translated, renamed_metadata.encode());
        }
        try self.updateParentTimes(old_path);
        if (!std.mem.eql(u8, parentSlice(old_path), parentSlice(new_path)))
            try self.updateParentTimes(new_path);
        try checkLfs(c.lfs_rename(&self.lfs, old_translated, new_translated));
        const removed_replaced_directory = if (replaced_directory_identity) |identity|
            self.directory_index.fetchRemove(identity) orelse return error.CorruptFilesystem
        else
            null;
        errdefer if (removed_replaced_directory) |entry|
            self.directory_index.put(entry.key, entry.value) catch {};
        if (source_directory_identity) |identity| {
            const entry = self.directory_index.getPtr(identity) orelse return error.CorruptFilesystem;
            entry.* = try DirectoryIndexEntry.init(new_parent_identity, baseNameSlice(new_path));
            errdefer entry.* = original_source_entry.?;
        }
        if (old_info.type == c.LFS_TYPE_DIR) {
            const same_parent = std.mem.eql(u8, parentSlice(old_path), parentSlice(new_path));
            if (!same_parent) self.adjustCachedParentLinkCount(old_path, false);
            if (!new_exists) {
                if (!same_parent) self.adjustCachedParentLinkCount(new_path, true);
            } else if (same_parent) {
                self.adjustCachedParentLinkCount(old_path, false);
            }
        }
        if (replaced) |object_ref| {
            replaced_count.?.* -= 1;
            self.reclaimObjectIfUnused(object_ref.object_id) catch {};
        }
        try mutation.commit();
        return .renamed;
    }

    pub fn openFile(self: *Volume, handle: *FileHandle, path: [*:0]const u8, flags: c_int, mode: u32, uid: u32, gid: u32) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.openFileUnlocked(handle, path, flags, mode, uid, gid);
    }

    pub fn openFileAt(
        self: *Volume,
        handle: *FileHandle,
        parent_identity: object_format.ObjectId,
        name: []const u8,
        flags: c_int,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        try self.openFileUnlocked(
            handle,
            try self.childPathUnlocked(parent_identity, name, &path_buffer),
            flags,
            mode,
            uid,
            gid,
        );
    }

    fn openFileUnlocked(
        self: *Volume,
        handle: *FileHandle,
        path: [*:0]const u8,
        flags: c_int,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !void {
        try self.ensureReadable();
        const existing_ref = self.store().readRef(path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing_ref != null and flags & c.LFS_O_CREAT != 0 and flags & c.LFS_O_EXCL != 0)
            return error.PathAlreadyExists;
        if (existing_ref == null and flags & c.LFS_O_CREAT == 0) return error.FileNotFound;
        const mutating = existing_ref == null or flags & c.LFS_O_TRUNC != 0;
        if (existing_ref != null and flags & c.LFS_O_TRUNC != 0) try self.ensureWritesAllowed();
        var mutation = if (mutating) try self.beginMutation() else Mutation{};
        defer mutation.deinit();

        const object_ref = existing_ref orelse value: {
            const inherited = try self.inheritCreateMetadata(path, mode, gid, false);
            try self.ensureGrowthCapacity();
            const created = try self.store().createObject(.file, metadata.Metadata.init(
                self.io,
                .file,
                inherited.mode,
                uid,
                inherited.gid,
            ));
            self.link_counts.put(created.object_id, 0) catch |err| {
                self.store().removeObject(created.object_id) catch {};
                return err;
            };
            self.store().publishRef(path, created, true) catch |err| {
                _ = self.link_counts.remove(created.object_id);
                self.store().removeObject(created.object_id) catch {};
                return err;
            };
            self.link_counts.getPtr(created.object_id).?.* = 1;
            self.updateParentTimes(path) catch {};
            break :value created;
        };
        try self.openObjectUnlocked(handle, object_ref.object_id, flags);
        try mutation.commit();
    }

    pub fn openObject(self: *Volume, handle: *FileHandle, object_id: object_format.ObjectId, flags: c_int) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        if (flags & c.LFS_O_TRUNC != 0) try self.ensureWritesAllowed();
        var mutation = if (flags & c.LFS_O_TRUNC != 0)
            try self.beginMutation()
        else
            try self.beginStateMutation();
        defer mutation.deinit();
        try self.openObjectUnlocked(handle, object_id, flags);
        try mutation.commit();
    }

    fn openObjectUnlocked(self: *Volume, handle: *FileHandle, object_id: object_format.ObjectId, flags: c_int) !void {
        try self.open_objects.ensureUnusedCapacity(1);
        const old_head = try self.store().readHead(object_id);
        const head = if (flags & c.LFS_O_TRUNC != 0) try self.store().truncate(object_id, 0) else old_head;
        if (flags & c.LFS_O_TRUNC != 0) try self.replaceReservation(old_head, head);
        if (flags & c.LFS_O_TRUNC != 0) self.updateOpenMetadata(object_id, head.metadata);
        handle.* = .{
            .object_id = object_id,
            .metadata = head.metadata,
            .original_metadata = head.metadata,
            .chunk_layout = null,
            .append = flags & c.LFS_O_APPEND != 0,
            .writable = flags & c.LFS_O_WRONLY != 0,
            .open = true,
            .previous = null,
            .next = null,
        };
        const entry = self.open_objects.getOrPutAssumeCapacity(object_id);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        handle.next = entry.value_ptr.first;
        if (handle.next) |next| next.previous = handle;
        entry.value_ptr.first = handle;
        entry.value_ptr.count += 1;
    }

    pub fn closeFile(self: *Volume, handle: *FileHandle) !void {
        if (!handle.open) return;
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        try self.unregisterFile(handle);
        handle.open = false;
        try self.reclaimObjectIfUnused(handle.object_id);
        try mutation.commit();
    }

    pub fn readFile(self: *Volume, handle: *FileHandle, buffer: []u8, offset: u64) !usize {
        const start = Io.Clock.awake.now(self.io).nanoseconds;
        var value_metadata: metadata.Metadata = undefined;
        const result = value: {
            var view = try self.beginView();
            defer view.deinit();
            const head = try self.store().readHead(handle.object_id);
            value_metadata = head.metadata;
            handle.metadata = head.metadata;
            if (offset >= head.logical_size or buffer.len == 0) break :value 0;
            const layout = handle.chunk_layout orelse try self.store().chunkLayout(handle.object_id);
            handle.chunk_layout = layout;
            break :value try self.store().readWithHeadLayout(head, layout, buffer, offset);
        };
        if (self.writable and self.access_time_policy == .relatime) {
            const timestamp: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
            self.updateAccessTimeFromMetadata(handle.object_id, value_metadata, timestamp) catch {};
        }
        const elapsed: u64 = @intCast(Io.Clock.awake.now(self.io).nanoseconds - start);
        _ = self.logical_read_calls.fetchAdd(1, .monotonic);
        _ = self.logical_read_bytes.fetchAdd(result, .monotonic);
        _ = self.logical_read_elapsed_ns.fetchAdd(elapsed, .monotonic);
        block_device.recordAtomicMax(&self.logical_read_max_ns, elapsed);
        return result;
    }

    pub fn writeFile(self: *Volume, handle: *FileHandle, data: []const u8, offset: u64) !usize {
        const start = Io.Clock.awake.now(self.io).nanoseconds;
        if (!handle.writable) return error.AccessDenied;
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const head = try self.store().readHead(handle.object_id);
        const effective_offset = if (handle.append) head.logical_size else offset;
        const end = std.math.add(u64, effective_offset, data.len) catch return error.FileTooLarge;
        if (end > object_format.max_file_size) return error.FileTooLarge;
        if (self.reservation_blocks != 0) {
            const footprint = try self.store().writeFootprintWithHead(head, effective_offset, data.len);
            try self.ensureWriteCapacity(footprint);
        }
        const result = try self.store().writeWithHead(head, data, effective_offset);
        try self.replaceReservation(head, result.head);
        self.updateOpenMetadata(handle.object_id, result.head.metadata);
        try mutation.commit();
        _ = self.logical_write_calls.fetchAdd(1, .monotonic);
        _ = self.logical_write_bytes.fetchAdd(result.amount, .monotonic);
        const elapsed: u64 = @intCast(Io.Clock.awake.now(self.io).nanoseconds - start);
        _ = self.logical_write_elapsed_ns.fetchAdd(elapsed, .monotonic);
        block_device.recordAtomicMax(&self.logical_write_max_ns, elapsed);
        return result.amount;
    }

    pub fn truncateFile(self: *Volume, handle: *FileHandle, size: u64) !void {
        if (!handle.writable) return error.AccessDenied;
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const old_head = try self.store().readHead(handle.object_id);
        const head = try self.store().truncate(handle.object_id, size);
        try self.replaceReservation(old_head, head);
        self.updateOpenMetadata(handle.object_id, head.metadata);
        try mutation.commit();
    }

    pub fn fallocateFile(self: *Volume, handle: *FileHandle, offset: u64, length: u64) !void {
        if (!handle.writable) return error.AccessDenied;
        if (length == 0) return error.InvalidArgument;
        const end = std.math.add(u64, offset, length) catch return error.FileTooLarge;
        if (end > object_format.max_file_size) return error.FileTooLarge;
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const old_head = try self.store().readHead(handle.object_id);
        const proposed = try self.store().reservationProposal(handle.object_id, offset, length);
        const old_blocks = try self.reservationBlocks(old_head);
        const new_blocks = try self.reservationBlocks(proposed);
        if (new_blocks > old_blocks) {
            const free = @as(u64, self.header.block_count) - try self.usedBlocksUnlocked();
            var needed = try addCapacity(self.reservation_blocks, new_blocks - old_blocks);
            needed = try addCapacity(needed, accounting_metadata_blocks);
            if (free < needed) return error.NoSpaceLeft;
        }
        const head = try self.store().reserve(handle.object_id, offset, length);
        try self.replaceReservation(old_head, head);
        self.updateOpenMetadata(handle.object_id, head.metadata);
        try mutation.commit();
    }

    pub fn syncFile(self: *Volume, handle: *FileHandle) !void {
        if (self.closed) return error.VolumeClosed;
        if (!self.writable) return;
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        self.syncBacking() catch return error.InputOutput;
        handle.original_metadata = handle.metadata;
    }

    pub fn sync(self: *Volume) !void {
        if (self.closed) return error.VolumeClosed;
        if (!self.writable) return;
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        self.syncBacking() catch return error.InputOutput;
    }

    pub fn persistMetadata(self: *Volume, handle: *FileHandle) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        try self.store().updateMetadata(handle.object_id, handle.metadata);
        self.updateOpenMetadata(handle.object_id, handle.metadata);
        handle.original_metadata = handle.metadata;
        try mutation.commit();
    }

    pub fn setObjectMetadata(self: *Volume, object_id: object_format.ObjectId, value: metadata.Metadata) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        try self.store().updateMetadata(object_id, value);
        self.updateOpenMetadata(object_id, value);
        try mutation.commit();
    }

    pub fn patchObjectMetadata(
        self: *Volume,
        object_id: object_format.ObjectId,
        patch: metadata.Patch,
    ) !object_format.ObjectHead {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        try self.ensureWritesAllowed();
        var mutation = try self.beginMutation();
        defer mutation.deinit();
        const head = try self.store().patchMetadata(object_id, patch);
        self.updateOpenMetadata(object_id, head.metadata);
        try mutation.commit();
        return head;
    }

    pub fn readObject(self: *Volume, object_id: object_format.ObjectId, buffer: []u8, offset: u64) !usize {
        var view = try self.beginView();
        defer view.deinit();
        return self.store().read(object_id, buffer, offset);
    }

    pub fn updateAccessTime(self: *Volume, object_id: object_format.ObjectId) !void {
        if (!self.writable or self.access_time_policy == .noatime) return;
        const value_metadata = value: {
            var view = try self.beginView();
            defer view.deinit();
            break :value (try self.store().readHead(object_id)).metadata;
        };
        const timestamp: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        try self.updateAccessTimeFromMetadata(object_id, value_metadata, timestamp);
    }

    pub fn accessTimeUpdateRequired(self: *const Volume, value: metadata.Metadata, now_ns: i64) bool {
        return self.writable and self.access_time_policy == .relatime and metadata.relatimeNeedsUpdate(value, now_ns);
    }

    fn updateAccessTimeFromMetadata(
        self: *Volume,
        object_id: object_format.ObjectId,
        value: metadata.Metadata,
        timestamp: i64,
    ) !void {
        if (!self.accessTimeUpdateRequired(value, timestamp)) return;
        _ = try self.patchObjectMetadata(object_id, .{
            .atime_ns = timestamp,
            .update_ctime = false,
        });
    }

    pub fn openDirectory(self: *Volume, handle: *DirectoryHandle, path: [*:0]const u8) !void {
        const info = try self.stat(path);
        var view = try self.beginView();
        defer view.deinit();
        if (info.metadata.kind != .directory) return error.NotDirectory;
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        try checkLfs(c.lfs_dir_open(
            &self.lfs,
            &handle.dir,
            try object_store.Store.translateUserPath(path, &translated_buffer),
        ));
        handle.open = true;
        handle.info = info;
    }

    pub fn openDirectoryIdentity(
        self: *Volume,
        handle: *DirectoryHandle,
        identity: object_format.ObjectId,
    ) !void {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginStateMutation();
        defer mutation.deinit();
        var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        const path = try self.directoryPathUnlocked(identity, &path_buffer);
        const info = try self.statUnlocked(path);
        if (info.metadata.kind != .directory or !std.mem.eql(u8, &info.identity, &identity))
            return error.CorruptFilesystem;
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        try checkLfs(c.lfs_dir_open(
            &self.lfs,
            &handle.dir,
            try object_store.Store.translateUserPath(path, &translated_buffer),
        ));
        handle.open = true;
        handle.info = info;
        try mutation.commit();
    }

    pub fn readDirectory(self: *Volume, handle: *DirectoryHandle, info: *c.struct_lfs_info) !bool {
        var view = try self.beginView();
        defer view.deinit();
        const result = c.lfs_dir_read(&self.lfs, &handle.dir, info);
        try checkLfs(result);
        return result > 0;
    }

    pub fn readDirectoryEntry(
        self: *Volume,
        handle: *DirectoryHandle,
        entry: *DirectoryEntry,
    ) !bool {
        try self.object_transaction_mutex.lock(self.io);
        defer self.object_transaction_mutex.unlock(self.io);
        var mutation = try self.beginStateMutation();
        defer mutation.deinit();
        while (true) {
            var raw: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(&self.lfs, &handle.dir, &raw);
            try checkLfs(result);
            if (result == 0) {
                try mutation.commit();
                return false;
            }
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&raw.name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
            const path = try self.childPathUnlocked(handle.info.identity, name, &path_buffer);
            const info = try self.statUnlocked(path);
            const offset = c.lfs_dir_tell(&self.lfs, &handle.dir);
            try checkLfs(offset);
            entry.* = .{ .name = @splat(0), .info = info, .next_cookie = @intCast(offset) };
            @memcpy(entry.name[0..name.len], name);
            try mutation.commit();
            return true;
        }
    }

    pub fn seekDirectory(self: *Volume, handle: *DirectoryHandle, offset: u32) !void {
        var view = try self.beginView();
        defer view.deinit();
        try checkLfs(c.lfs_dir_seek(&self.lfs, &handle.dir, offset));
    }

    pub fn tellDirectory(self: *Volume, handle: *DirectoryHandle) !u32 {
        var view = try self.beginView();
        defer view.deinit();
        const result = c.lfs_dir_tell(&self.lfs, &handle.dir);
        try checkLfs(result);
        return @intCast(result);
    }

    pub fn closeDirectory(self: *Volume, handle: *DirectoryHandle) !void {
        if (!handle.open) return;
        var view = try self.beginView();
        defer view.deinit();
        handle.open = false;
        try checkLfs(c.lfs_dir_close(&self.lfs, &handle.dir));
    }

    pub fn check(self: *Volume) !CheckResult {
        if (self.closed) return error.VolumeClosed;
        if (!self.mounted) return error.NotMounted;
        var view = try self.beginView();
        defer view.deinit();
        var context = CheckContext{};
        try checkLfs(c.lfs_fs_traverse(&self.lfs, traverseCallback, &context));
        return .{
            .used_blocks = context.count,
            .total_blocks = self.header.block_count,
        };
    }

    fn store(self: *Volume) object_store.Store {
        return .{
            .io = self.io,
            .lfs = &self.lfs,
            .cache = &self.chunk_cache,
            .version_index = &self.chunk_version_index,
        };
    }

    fn ensureWritesAllowed(self: *const Volume) !void {
        try self.ensureReadable();
        if (!self.writable) return error.ReadOnlyVolume;
        if (self.isWriteFrozen()) return error.VolumeFrozen;
    }

    fn ensureReadable(self: *const Volume) !void {
        if (self.invalidated.load(.acquire)) return error.VolumeRequiresReopen;
    }

    fn beginView(self: *Volume) !View {
        try self.view_lock.lockShared(self.io);
        errdefer self.view_lock.unlockShared(self.io);
        try self.ensureReadable();
        return .{ .volume = self };
    }

    fn beginMutation(self: *Volume) !Mutation {
        var mutation = try self.beginStateMutation();
        errdefer mutation.deinit();
        if (!self.writable or self.backing != .file or !self.device.isJournaled()) return mutation;
        self.device.beginTransaction() catch return error.InputOutput;
        mutation.device = &self.device;
        return mutation;
    }

    fn beginStateMutation(self: *Volume) !Mutation {
        try self.view_lock.lock(self.io);
        errdefer self.view_lock.unlock(self.io);
        try self.ensureReadable();
        return .{ .volume = self, .locked = true };
    }

    fn collectReservationBlocks(
        self: *Volume,
        recovered_heads: ?*const std.AutoHashMap(object_format.ObjectId, object_format.ObjectHead),
    ) !u64 {
        var total: u64 = 0;
        var iterator = self.link_counts.keyIterator();
        while (iterator.next()) |id| {
            const head = if (recovered_heads) |heads|
                heads.get(id.*) orelse return error.CorruptFilesystem
            else
                try self.store().readHead(id.*);
            try self.store().validateReservations(head);
            total = try addCapacity(total, try self.reservationBlocks(head));
        }
        return total;
    }

    // littlefs has no physical preallocation primitive. Reserve twice the data
    // blocks for CTZ/file overhead and enough payload for a complete COW copy.
    fn reservationBlocks(self: *const Volume, head: object_format.ObjectHead) !u64 {
        if (head.reservation_generation == 0) return 0;
        const additional_bytes = std.math.sub(
            u64,
            head.reservation_payload_bytes,
            head.reservation_existing_bytes,
        ) catch return error.CorruptFilesystem;
        const per_chunk_overhead = try std.math.mul(u64, head.reservation_chunk_count, 2);
        var blocks = try inflatedDataBlocks(additional_bytes, self.header.block_size);
        blocks = try addCapacity(blocks, per_chunk_overhead);
        blocks = try addCapacity(blocks, try inflatedDataBlocks(head.reservation_payload_bytes, self.header.block_size));
        blocks = try addCapacity(blocks, per_chunk_overhead);
        const sidecar_entries = std.math.mul(u64, head.reservation_interval_count, 16) catch
            return error.CorruptFilesystem;
        const sidecar_bytes = std.math.add(u64, sidecar_entries, 36) catch return error.CorruptFilesystem;
        blocks = try addCapacity(blocks, try inflatedDataBlocks(sidecar_bytes, self.header.block_size));
        blocks = try addCapacity(blocks, 2);
        return addCapacity(blocks, accounting_metadata_blocks);
    }

    fn ensureWriteCapacity(self: *Volume, footprint: object_store.WriteFootprint) !void {
        if (footprint.chunk_count == 0 or footprint.reserved or self.reservation_blocks == 0) return;
        var operation = try inflatedDataBlocks(footprint.payload_bytes, self.header.block_size);
        operation = try addCapacity(operation, try std.math.mul(u64, footprint.chunk_count, 2));
        operation = try addCapacity(operation, accounting_metadata_blocks);
        operation = try addCapacity(operation, self.reservation_blocks);
        const free = @as(u64, self.header.block_count) - try self.usedBlocksUnlocked();
        if (free < operation) return error.NoSpaceLeft;
    }

    fn ensureGrowthCapacity(self: *Volume) !void {
        if (self.reservation_blocks == 0) return;
        const protected = try addCapacity(self.reservation_blocks, accounting_metadata_blocks);
        const free = @as(u64, self.header.block_count) - try self.usedBlocksUnlocked();
        if (free < protected) return error.NoSpaceLeft;
    }

    fn replaceReservation(self: *Volume, old_head: object_format.ObjectHead, new_head: object_format.ObjectHead) !void {
        const old_blocks = try self.reservationBlocks(old_head);
        const new_blocks = try self.reservationBlocks(new_head);
        self.reservation_blocks = std.math.sub(u64, self.reservation_blocks, old_blocks) catch
            return error.CorruptFilesystem;
        self.reservation_blocks = addCapacity(self.reservation_blocks, new_blocks) catch |err| {
            self.reservation_blocks = try addCapacity(self.reservation_blocks, old_blocks);
            return err;
        };
    }

    fn updateOpenMetadata(self: *Volume, id: object_format.ObjectId, value: metadata.Metadata) void {
        const object = self.open_objects.get(id) orelse return;
        var current = object.first;
        while (current) |handle| : (current = handle.next) {
            handle.metadata = value;
        }
    }

    fn rebuildDirectoryIndex(self: *Volume) !void {
        self.directory_index.clearRetainingCapacity();
        self.root_directory_identity = null;
        const root = try self.directoryIdentityOptions(object_store.namespace_root, self.writable);
        try self.directory_index.put(root, try DirectoryIndexEntry.init(root, ""));
        self.root_directory_identity = root;
        try self.indexChildDirectories(object_store.namespace_root, root);
    }

    fn indexChildDirectories(
        self: *Volume,
        translated_parent: [*:0]const u8,
        parent_identity: object_format.ObjectId,
    ) !void {
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(&self.lfs, &directory, translated_parent));
        defer _ = c.lfs_dir_close(&self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(&self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return;
            if (info.type != c.LFS_TYPE_DIR) continue;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var path_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
            const path = try joinPathComponent(&path_buffer, translated_parent, name);
            const identity = try self.directoryIdentityOptions(path, self.writable);
            if (self.directory_index.contains(identity)) return error.CorruptFilesystem;
            try self.directory_index.put(identity, try DirectoryIndexEntry.init(parent_identity, name));
            try self.indexChildDirectories(path, identity);
        }
    }

    fn directoryPathUnlocked(
        self: *const Volume,
        identity: object_format.ObjectId,
        buffer: *[object_store.max_path_bytes:0]u8,
    ) ![*:0]const u8 {
        const root = self.root_directory_identity orelse return error.CorruptFilesystem;
        if (!self.directory_index.contains(identity)) return error.FileNotFound;
        buffer.* = @splat(0);
        if (std.mem.eql(u8, &identity, &root)) {
            buffer[0] = '/';
            return buffer;
        }

        var cursor: usize = buffer.len - 1;
        var current = identity;
        var remaining = self.directory_index.count();
        while (!std.mem.eql(u8, &current, &root)) {
            if (remaining == 0) return error.CorruptFilesystem;
            remaining -= 1;
            const entry = self.directory_index.get(current) orelse return error.FileNotFound;
            const name = entry.nameSlice();
            if (name.len == 0 or cursor < name.len + 1) return error.CorruptFilesystem;
            cursor -= name.len;
            @memcpy(buffer[cursor .. cursor + name.len], name);
            cursor -= 1;
            buffer[cursor] = '/';
            current = entry.parent;
        }
        const length = buffer.len - 1 - cursor;
        std.mem.copyForwards(u8, buffer[0..length], buffer[cursor .. cursor + length]);
        buffer[length] = 0;
        return buffer;
    }

    fn childPathUnlocked(
        self: *const Volume,
        parent_identity: object_format.ObjectId,
        name: []const u8,
        buffer: *[object_store.max_path_bytes:0]u8,
    ) ![*:0]const u8 {
        if (name.len == 0 or name.len >= directory_name_capacity or
            std.mem.indexOfScalar(u8, name, '/') != null or
            std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
            return error.InvalidArgument;
        var parent_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        return joinPathComponent(
            buffer,
            try self.directoryPathUnlocked(parent_identity, &parent_buffer),
            name,
        );
    }

    fn directoryIdentity(self: *Volume, translated: [*:0]const u8) !object_format.ObjectId {
        return self.directoryIdentityOptions(
            translated,
            self.writable and (self.backing != .file or !self.device.isJournaled()),
        );
    }

    fn directoryIdentityOptions(
        self: *Volume,
        translated: [*:0]const u8,
        persist_missing: bool,
    ) !object_format.ObjectId {
        var identity: object_format.ObjectId = undefined;
        const result = c.lfs_getattr(
            &self.lfs,
            translated,
            metadata.directory_identity_attribute_type,
            &identity,
            identity.len,
        );
        if (result >= 0) {
            if (result != identity.len) return error.InvalidMetadata;
            return identity;
        }
        if (result != c.LFS_ERR_NOATTR) {
            try checkLfs(result);
            unreachable;
        }

        if (persist_missing) {
            try self.io.randomSecure(&identity);
            const set_result = c.lfs_setattr(
                &self.lfs,
                translated,
                metadata.directory_identity_attribute_type,
                &identity,
                identity.len,
            );
            if (set_result >= 0) return identity;
            if (set_result != c.LFS_ERR_NOSPC) try checkLfs(set_result);
        }

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(std.mem.span(translated), &digest, .{});
        return digest[0..identity.len].*;
    }

    fn hasOpenObject(self: *Volume, id: object_format.ObjectId) bool {
        return self.open_objects.contains(id);
    }

    fn reclaimObjectIfUnused(self: *Volume, id: object_format.ObjectId) !void {
        const links = self.link_counts.get(id) orelse return error.CorruptFilesystem;
        if (links != 0 or self.hasOpenObject(id) or self.objectPinCountUnlocked(id) != 0) return;
        const head = try self.store().readHead(id);
        try self.store().removeObject(id);
        self.reservation_blocks = std.math.sub(u64, self.reservation_blocks, try self.reservationBlocks(head)) catch
            return error.CorruptFilesystem;
        _ = self.link_counts.remove(id);
    }

    fn unregisterFile(self: *Volume, target: *FileHandle) !void {
        const object = self.open_objects.getPtr(target.object_id) orelse return error.InvalidArgument;
        if (target.previous) |previous| {
            previous.next = target.next;
        } else if (object.first == target) {
            object.first = target.next;
        } else return error.InvalidArgument;
        if (target.next) |next| next.previous = target.previous;
        target.previous = null;
        target.next = null;
        object.count -= 1;
        if (object.count == 0) _ = self.open_objects.remove(target.object_id);
    }

    fn createSpecial(
        self: *Volume,
        path: [*:0]const u8,
        contents: []const u8,
        ref_kind: object_format.RefKind,
        kind: metadata.Kind,
        mode: u32,
        uid: u32,
        gid: u32,
    ) !NodeInfo {
        try self.ensureGrowthCapacity();
        const created = try self.store().createObject(ref_kind, metadata.Metadata.init(
            self.io,
            kind,
            mode,
            uid,
            gid,
        ));
        self.link_counts.put(created.object_id, 0) catch |err| {
            self.store().removeObject(created.object_id) catch {};
            return err;
        };
        errdefer {
            _ = self.link_counts.remove(created.object_id);
            self.store().removeObject(created.object_id) catch {};
        }
        const head = if (contents.len != 0)
            (try self.store().write(created.object_id, contents, 0)).head
        else
            try self.store().readHead(created.object_id);
        try self.store().publishRef(path, created, true);
        self.link_counts.getPtr(created.object_id).?.* = 1;
        self.updateParentTimes(path) catch {};
        return .{
            .size = head.logical_size,
            .allocated_bytes = head.allocated_bytes,
            .metadata = head.metadata,
            .object_id = created.object_id,
            .identity = created.object_id,
            .nlink = 1,
        };
    }

    fn inheritCreateMetadata(
        self: *Volume,
        path: [*:0]const u8,
        mode: u32,
        gid: u32,
        directory: bool,
    ) !struct { mode: u32, gid: u32 } {
        const parent = parentSlice(path);
        var buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        if (parent.len >= buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..parent.len], parent);
        const parent_metadata = try self.getMetadataUnlocked(&buffer);
        if (parent_metadata.mode & 0o2000 == 0) return .{ .mode = mode, .gid = gid };
        return .{
            .mode = if (directory) mode | 0o2000 else mode,
            .gid = parent_metadata.gid,
        };
    }

    fn directoryLinkCount(self: *Volume, translated: [*:0]const u8) !u64 {
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(&self.lfs, &directory, translated));
        defer _ = c.lfs_dir_close(&self.lfs, &directory);
        var count: u64 = 2;
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(&self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return count;
            if (info.type == c.LFS_TYPE_DIR) {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."))
                    count = std.math.add(u64, count, 1) catch return error.CorruptFilesystem;
            }
        }
    }

    fn adjustCachedParentLinkCount(self: *Volume, path: [*:0]const u8, increase: bool) void {
        const parent = parentSlice(path);
        var parent_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        if (parent.len >= parent_buffer.len) return;
        @memcpy(parent_buffer[0..parent.len], parent);
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = object_store.Store.translateUserPath(&parent_buffer, &translated_buffer) catch return;
        const identity = self.directoryIdentity(translated) catch return;
        const count = self.directory_link_counts.getPtr(identity) orelse return;
        if (increase) {
            count.* = std.math.add(u64, count.*, 1) catch {
                _ = self.directory_link_counts.remove(identity);
                return;
            };
        } else {
            count.* = std.math.sub(u64, count.*, 1) catch {
                _ = self.directory_link_counts.remove(identity);
                return;
            };
        }
    }

    fn directoryIsEmpty(self: *Volume, translated: [*:0]const u8) !bool {
        var directory: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t);
        try checkLfs(c.lfs_dir_open(&self.lfs, &directory, translated));
        defer _ = c.lfs_dir_close(&self.lfs, &directory);
        while (true) {
            var info: c.struct_lfs_info = undefined;
            const result = c.lfs_dir_read(&self.lfs, &directory, &info);
            try checkLfs(result);
            if (result == 0) return true;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) return false;
        }
    }

    fn validateParentDirectory(self: *Volume, path: [*:0]const u8) !void {
        const parent = parentSlice(path);
        var parent_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        @memcpy(parent_buffer[0..parent.len], parent);
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = try object_store.Store.translateUserPath(&parent_buffer, &translated_buffer);
        var info: c.struct_lfs_info = undefined;
        try checkLfs(c.lfs_stat(&self.lfs, translated, &info));
        if (info.type != c.LFS_TYPE_DIR) return error.NotDirectory;
    }

    fn updateParentTimes(self: *Volume, path: [*:0]const u8) !void {
        const parent = parentSlice(path);
        var parent_buffer: [object_store.max_path_bytes:0]u8 = @splat(0);
        if (parent.len >= parent_buffer.len) return error.NameTooLong;
        @memcpy(parent_buffer[0..parent.len], parent);
        var translated_buffer: [object_store.max_path_bytes:0]u8 = undefined;
        const translated = try object_store.Store.translateUserPath(&parent_buffer, &translated_buffer);
        var parent_metadata = self.getDirectoryMetadataTranslated(translated) catch |err| switch (err) {
            error.FileNotFound, error.AttributeNotFound => return,
            else => return err,
        };
        const timestamp: i64 = @intCast(Io.Clock.real.now(self.io).nanoseconds);
        parent_metadata.mtime_ns = timestamp;
        parent_metadata.ctime_ns = timestamp;
        try self.setDirectoryMetadataTranslated(translated, parent_metadata.encode());
    }

    const Mutation = struct {
        device: ?*block_device.FileBlockDevice = null,
        volume: ?*Volume = null,
        locked: bool = false,
        committed: bool = false,

        fn commit(self: *Mutation) !void {
            if (self.device) |device| device.commitTransaction() catch return error.InputOutput;
            self.committed = true;
        }

        fn deinit(self: *Mutation) void {
            if (!self.committed) if (self.device) |device| {
                const had_writes = device.abortTransaction() catch true;
                if (had_writes) self.volume.?.invalidated.store(true, .release);
            };
            if (self.locked) self.volume.?.view_lock.unlock(self.volume.?.io);
        }
    };

    const View = struct {
        volume: *Volume,

        fn deinit(self: View) void {
            self.volume.view_lock.unlockShared(self.volume.io);
        }
    };
};

fn initializeFilesystem(io: Io, config: *c.struct_lfs_config) !void {
    var lfs: c.lfs_t = std.mem.zeroes(c.lfs_t);
    try checkLfs(c.lfs_format(&lfs, config));
    try checkLfs(c.lfs_mount(&lfs, config));
    var mounted = true;
    defer if (mounted) {
        _ = c.lfs_unmount(&lfs);
    };
    const store: object_store.Store = .{ .io = io, .lfs = &lfs };
    try store.initialize();
    const owner = hostOwner();
    const root_metadata = metadata.Metadata.init(io, .directory, 0o40755, owner.uid, owner.gid);
    const root_bytes = root_metadata.encode();
    try checkLfs(c.lfs_setattr(
        &lfs,
        object_store.namespace_root,
        metadata.attribute_type,
        &root_bytes,
        root_bytes.len,
    ));
    var root_identity: object_format.ObjectId = undefined;
    try io.randomSecure(&root_identity);
    try checkLfs(c.lfs_setattr(
        &lfs,
        object_store.namespace_root,
        metadata.directory_identity_attribute_type,
        &root_identity,
        root_identity.len,
    ));
    try checkLfs(c.lfs_unmount(&lfs));
    mounted = false;
}

fn collectPoolMembers(
    set: *pool_member_set.PoolMemberSet,
    output: *[3]*@import("v3/member.zig").Member,
) !usize {
    const authority = set.authority() orelse return error.MissingAuthority;
    const required_count: usize = switch (authority.layout.kind) {
        .unprotected => 1,
        .replicated => 3,
        .erasure_coded => return error.ErasureCodingNotImplemented,
    };
    if (set.suppliedCount() != required_count) return error.UnsupportedPoolWidth;
    var count: usize = 0;
    for (0..set.suppliedCount()) |index| {
        switch (try set.statusAt(index)) {
            .authority, .active_voter => {},
            else => continue,
        }
        const member = try set.memberAt(index) orelse continue;
        if (count == output.len) return error.UnsupportedPoolWidth;
        output.*[count] = member;
        count += 1;
    }
    if (count != required_count) return error.UnsupportedPoolWidth;
    return count;
}

fn makeReplicaEndpoints(
    members: []const *@import("v3/member.zig").Member,
    output: *[3]ReplicaEndpoint,
) []const ReplicaEndpoint {
    for (members, 0..) |member, index| output[index] = member.asReplicaEndpoint();
    return output[0..members.len];
}

const accounting_metadata_blocks: u64 = 32;

const directory_name_capacity = 256;

const DirectoryIndexEntry = struct {
    parent: object_format.ObjectId,
    name: [directory_name_capacity:0]u8,

    fn init(parent: object_format.ObjectId, name: []const u8) !DirectoryIndexEntry {
        if (name.len >= directory_name_capacity) return error.NameTooLong;
        var result: DirectoryIndexEntry = .{ .parent = parent, .name = @splat(0) };
        @memcpy(result.name[0..name.len], name);
        return result;
    }

    fn nameSlice(self: *const DirectoryIndexEntry) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

fn joinPathComponent(
    buffer: *[object_store.max_path_bytes:0]u8,
    parent: [*:0]const u8,
    name: []const u8,
) ![*:0]const u8 {
    const parent_value = std.mem.span(parent);
    const separator: usize = if (parent_value.len == 1) 0 else 1;
    const length = std.math.add(usize, parent_value.len + separator, name.len) catch
        return error.NameTooLong;
    if (length >= buffer.len) return error.NameTooLong;
    buffer.* = @splat(0);
    @memcpy(buffer[0..parent_value.len], parent_value);
    var cursor = parent_value.len;
    if (separator != 0) {
        buffer[cursor] = '/';
        cursor += 1;
    }
    @memcpy(buffer[cursor .. cursor + name.len], name);
    return buffer;
}

fn inflatedDataBlocks(bytes: u64, block_size: u32) !u64 {
    const blocks = try std.math.divCeil(u64, bytes, block_size);
    return std.math.mul(u64, blocks, 2) catch error.FileTooLarge;
}

fn addCapacity(left: u64, right: u64) !u64 {
    return std.math.add(u64, left, right) catch error.FileTooLarge;
}

fn parentSlice(path: [*:0]const u8) []const u8 {
    const value = std.mem.span(path);
    if (value.len <= 1) return "/";
    const separator = std.mem.lastIndexOfScalar(u8, value, '/') orelse return "/";
    return if (separator == 0) "/" else value[0..separator];
}

fn baseNameSlice(path: [*:0]const u8) []const u8 {
    const value = std.mem.span(path);
    const separator = std.mem.lastIndexOfScalar(u8, value, '/') orelse return value;
    return value[separator + 1 ..];
}

fn hostOwner() struct { uid: u32, gid: u32 } {
    if (@import("builtin").os.tag != .linux) return .{ .uid = 0, .gid = 0 };
    return .{ .uid = @intCast(std.os.linux.getuid()), .gid = @intCast(std.os.linux.getgid()) };
}

pub const NodeInfo = struct {
    size: u64,
    allocated_bytes: u64,
    metadata: metadata.Metadata,
    object_id: ?object_format.ObjectId,
    identity: object_format.ObjectId,
    nlink: u64,
};

pub const RenameResult = enum {
    renamed,
    same_object,
};

pub const FileHandle = struct {
    object_id: object_format.ObjectId = @splat(0),
    metadata: metadata.Metadata = undefined,
    original_metadata: metadata.Metadata = undefined,
    chunk_layout: ?object_store.ChunkLayout = null,
    append: bool = false,
    writable: bool = false,
    open: bool = false,
    previous: ?*FileHandle = null,
    next: ?*FileHandle = null,
};

const OpenObject = struct {
    first: ?*FileHandle = null,
    count: usize = 0,
};

pub const DirectoryHandle = struct {
    dir: c.lfs_dir_t = std.mem.zeroes(c.lfs_dir_t),
    info: NodeInfo = undefined,
    open: bool = false,
};

pub const DirectoryEntry = struct {
    name: [directory_name_capacity:0]u8,
    info: NodeInfo,
    next_cookie: u32,

    pub fn nameSlice(self: *const DirectoryEntry) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

pub const CheckResult = struct {
    used_blocks: u32,
    total_blocks: u32,
};

const CheckContext = struct {
    count: u32 = 0,
};

fn traverseCallback(raw: ?*anyopaque, block: c.lfs_block_t) callconv(.c) c_int {
    _ = block;
    const context: *CheckContext = @ptrCast(@alignCast(raw.?));
    context.count += 1;
    return 0;
}

pub fn checkLfs(result: anytype) !void {
    if (result >= 0) return;
    return switch (result) {
        c.LFS_ERR_IO => error.InputOutput,
        c.LFS_ERR_CORRUPT => error.CorruptFilesystem,
        c.LFS_ERR_NOENT => error.FileNotFound,
        c.LFS_ERR_EXIST => error.PathAlreadyExists,
        c.LFS_ERR_NOTDIR => error.NotDirectory,
        c.LFS_ERR_ISDIR => error.IsDirectory,
        c.LFS_ERR_NOTEMPTY => error.DirectoryNotEmpty,
        c.LFS_ERR_FBIG => error.FileTooLarge,
        c.LFS_ERR_INVAL => error.InvalidArgument,
        c.LFS_ERR_NOSPC => error.NoSpaceLeft,
        c.LFS_ERR_NOMEM => error.OutOfMemory,
        c.LFS_ERR_NAMETOOLONG => error.NameTooLong,
        c.LFS_ERR_NOATTR => error.AttributeNotFound,
        else => error.LittleFsFailure,
    };
}

test "create, write, reopen, and check volume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/volume.ddv", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    try Volume.create(std.testing.io, path, 1024 * 1024, "Test");
    var volume = try Volume.open(std.testing.io, path, true);
    defer volume.deinit();
    try volume.mount();

    var file: FileHandle = undefined;
    try volume.openFile(&file, "/hello", c.LFS_O_CREAT | c.LFS_O_RDWR, 0o100644, 1000, 1000);
    try std.testing.expectEqual(@as(usize, 5), try volume.writeFile(&file, "hello", 0));
    const metrics = volume.pipelineMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics.logical_write_calls);
    try std.testing.expectEqual(@as(u64, 5), metrics.logical_write_bytes);
    try std.testing.expect(!metrics.journaled);
    try std.testing.expect(metrics.block_device.littlefs_program_bytes >= 5);
    try std.testing.expectEqual(
        metrics.block_device.littlefs_program_bytes,
        metrics.block_device.backing_write_bytes,
    );
    try std.testing.expectEqual(@as(usize, 5), try volume.writeFile(&file, "HELLO", 0));
    try volume.syncFile(&file);
    try volume.closeFile(&file);

    const info = try volume.stat("/hello");
    try std.testing.expectEqual(@as(u64, 5), info.size);
    try std.testing.expectEqual(metadata.Kind.file, info.metadata.kind);

    var reopened: FileHandle = undefined;
    try volume.openFile(&reopened, "/hello", c.LFS_O_RDONLY, 0, 0, 0);
    try std.testing.expectError(error.AccessDenied, volume.writeFile(&reopened, "x", 0));
    try std.testing.expectError(error.AccessDenied, volume.truncateFile(&reopened, 0));
    try std.testing.expectError(error.AccessDenied, volume.fallocateFile(&reopened, 0, 1));
    var buffer: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try volume.readFile(&reopened, &buffer, 0));
    try std.testing.expectEqualStrings("HELLO", &buffer);
    const read_metrics = volume.pipelineMetrics();
    try std.testing.expectEqual(@as(u64, 1), read_metrics.logical_read_calls);
    try std.testing.expectEqual(@as(u64, 5), read_metrics.logical_read_bytes);
    try std.testing.expect(read_metrics.logical_read_max_ns > 0);
    try volume.closeFile(&reopened);

    const result = try volume.check();
    try std.testing.expect(result.used_blocks >= 2);
}

test "ordinary writes rely on littlefs capacity without a full-volume preflight" {
    var volume: Volume = undefined;
    volume.reservation_blocks = 0;
    volume.header.block_count = 0;
    volume.header.block_size = container.default_block_size;

    try volume.ensureWriteCapacity(.{
        .payload_bytes = 1,
        .chunk_count = 1,
        .reserved = false,
    });
}
