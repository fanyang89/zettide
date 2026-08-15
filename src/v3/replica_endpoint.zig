const storage_api = @import("storage.zig");

pub const ReplicaEndpoint = struct {
    context: *anyopaque,
    geometry: Geometry,
    vtable: *const VTable,

    pub const Geometry = struct {
        logical_capacity: u64,
        data_length: u64,
    };

    pub const VTable = struct {
        read_metadata: *const fn (*anyopaque, u64, []u8) anyerror!void,
        read_data: *const fn (*anyopaque, u64, []u8) anyerror!void,
        read_data_many: ?*const fn (*anyopaque, []const storage_api.Read, []storage_api.ReadResult) anyerror!void = null,
        submit_read_data_many: ?*const fn (
            *anyopaque,
            []const storage_api.Read,
            []storage_api.ReadResult,
            storage_api.AsyncReadCompletion,
        ) anyerror!storage_api.AsyncReadSubmit = null,
        write_data: *const fn (*anyopaque, u64, []const u8) anyerror!void,
        write_data_many: ?*const fn (*anyopaque, []const storage_api.Write) anyerror!void = null,
        write_metadata_durable: *const fn (*anyopaque, u64, []const u8) anyerror!void,
        sync: *const fn (*anyopaque) anyerror!void,
    };

    pub fn init(context: *anyopaque, geometry: Geometry, vtable: *const VTable) ReplicaEndpoint {
        return .{
            .context = context,
            .geometry = geometry,
            .vtable = vtable,
        };
    }

    pub fn readMetadata(self: ReplicaEndpoint, offset: u64, buffer: []u8) anyerror!void {
        return self.vtable.read_metadata(self.context, offset, buffer);
    }

    pub fn readData(self: ReplicaEndpoint, offset: u64, buffer: []u8) anyerror!void {
        return self.vtable.read_data(self.context, offset, buffer);
    }

    pub fn readDataMany(
        self: ReplicaEndpoint,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
    ) anyerror!void {
        if (reads.len != results.len) return error.InvalidReadBatch;
        if (self.vtable.read_data_many) |read_many|
            return read_many(self.context, reads, results);
        for (results) |*result| result.* = .{};
        for (reads, results) |read, *result| {
            self.readData(read.offset, read.buffer) catch |err| {
                result.failure = err;
                continue;
            };
            result.amount = read.buffer.len;
        }
    }

    pub fn submitReadDataMany(
        self: ReplicaEndpoint,
        reads: []const storage_api.Read,
        results: []storage_api.ReadResult,
        completion: storage_api.AsyncReadCompletion,
    ) anyerror!storage_api.AsyncReadSubmit {
        if (reads.len != results.len) return error.InvalidReadBatch;
        const submit = self.vtable.submit_read_data_many orelse return .unsupported;
        return submit(self.context, reads, results, completion);
    }

    pub fn writeData(self: ReplicaEndpoint, offset: u64, data: []const u8) anyerror!void {
        return self.vtable.write_data(self.context, offset, data);
    }

    pub fn writeDataMany(self: ReplicaEndpoint, writes: []const storage_api.Write) anyerror!void {
        if (self.vtable.write_data_many) |write_many|
            return write_many(self.context, writes);
        for (writes) |write| try self.writeData(write.offset, write.bytes);
    }

    pub fn writeMetadataDurable(self: ReplicaEndpoint, offset: u64, data: []const u8) anyerror!void {
        return self.vtable.write_metadata_durable(self.context, offset, data);
    }

    pub fn sync(self: ReplicaEndpoint) anyerror!void {
        return self.vtable.sync(self.context);
    }
};
