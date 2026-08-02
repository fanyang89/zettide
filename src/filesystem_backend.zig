pub const name_capacity = 256;

pub const AccessMode = enum {
    read_only,
    read_write,
};

pub const OpenOptions = struct {
    access: AccessMode,
    create: bool = false,
    exclusive: bool = false,
    truncate: bool = false,
    append: bool = false,
};

pub const DirectoryEntry = struct {
    kind: Kind,
    name_buffer: [name_capacity:0]u8,

    pub const Kind = enum {
        file,
        directory,
    };

    pub fn name(self: *const DirectoryEntry) [:0]const u8 {
        return std.mem.sliceTo(&self.name_buffer, 0);
    }
};

const std = @import("std");
