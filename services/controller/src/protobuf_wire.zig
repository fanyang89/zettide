const std = @import("std");

pub const Error = error{InvalidWire};

pub const Field = struct {
    number: u32,
    wire_type: u3,
};

pub const Cursor = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn next(self: *Cursor) Error!?Field {
        if (self.position == self.bytes.len) return null;
        const key = try self.readVarint();
        const number = key >> 3;
        const wire_type = key & 0x07;
        if (number == 0 or number > 0x1fff_ffff or
            (wire_type != 0 and wire_type != 1 and wire_type != 2 and wire_type != 5))
        {
            return error.InvalidWire;
        }
        return .{ .number = @intCast(number), .wire_type = @intCast(wire_type) };
    }

    pub fn readVarint(self: *Cursor) Error!u64 {
        var result: u64 = 0;
        for (0..10) |index| {
            if (self.position == self.bytes.len) return error.InvalidWire;
            const byte = self.bytes[self.position];
            self.position += 1;
            if (index == 9 and byte > 1) return error.InvalidWire;
            result |= @as(u64, byte & 0x7f) << @intCast(index * 7);
            if (byte & 0x80 == 0) return result;
        }
        return error.InvalidWire;
    }

    pub fn readBytes(self: *Cursor, max_bytes: usize) Error![]const u8 {
        const encoded_length = try self.readVarint();
        const length = std.math.cast(usize, encoded_length) orelse return error.InvalidWire;
        if (length > max_bytes or length > self.bytes.len - self.position) return error.InvalidWire;
        const result = self.bytes[self.position..][0..length];
        self.position += length;
        return result;
    }

    pub fn skip(self: *Cursor, field: Field, max_bytes: usize) Error!void {
        switch (field.wire_type) {
            0 => _ = try self.readVarint(),
            1 => try self.skipFixed(8),
            2 => _ = try self.readBytes(max_bytes),
            5 => try self.skipFixed(4),
            else => unreachable,
        }
    }

    fn skipFixed(self: *Cursor, length: usize) Error!void {
        if (length > self.bytes.len - self.position) return error.InvalidWire;
        self.position += length;
    }
};

test "cursor rejects overflowing lengths" {
    const malformed = [_]u8{0x12} ++ @as([9]u8, @splat(0xff)) ++ [_]u8{0x01};
    var cursor = Cursor{ .bytes = &malformed };
    const field = (try cursor.next()).?;
    try std.testing.expectEqual(@as(u32, 2), field.number);
    try std.testing.expectError(error.InvalidWire, cursor.readBytes(1024));
}
