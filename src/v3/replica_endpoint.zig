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
        write_data: *const fn (*anyopaque, u64, []const u8) anyerror!void,
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

    pub fn writeData(self: ReplicaEndpoint, offset: u64, data: []const u8) anyerror!void {
        return self.vtable.write_data(self.context, offset, data);
    }

    pub fn writeMetadataDurable(self: ReplicaEndpoint, offset: u64, data: []const u8) anyerror!void {
        return self.vtable.write_metadata_durable(self.context, offset, data);
    }

    pub fn sync(self: ReplicaEndpoint) anyerror!void {
        return self.vtable.sync(self.context);
    }
};
