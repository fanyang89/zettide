const std = @import("std");

pub const Field = struct {
    name: [:0]const u8,
    type: type,
    is_comptime: bool,
    default_value_ptr: ?*const anyopaque,

    pub inline fn defaultValue(comptime self: Field) ?self.type {
        const pointer: *const self.type = @ptrCast(@alignCast(self.default_value_ptr orelse return null));
        return pointer.*;
    }
};

pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

pub fn enumFields(comptime T: type) [@typeInfo(T).@"enum".field_names.len]EnumField {
    const info = @typeInfo(T).@"enum";
    var result: [info.field_names.len]EnumField = undefined;
    inline for (info.field_names, info.field_values, 0..) |name, value, index| {
        result[index] = .{ .name = name, .value = value };
    }
    return result;
}

pub fn fields(comptime T: type) [fieldCount(T)]Field {
    const info = @typeInfo(T);
    const names = switch (info) {
        .@"struct" => |value| value.field_names,
        .@"union" => |value| value.field_names,
        else => @compileError("expected struct or union"),
    };
    const types = switch (info) {
        .@"struct" => |value| value.field_types,
        .@"union" => |value| value.field_types,
        else => unreachable,
    };
    var result: [names.len]Field = undefined;
    inline for (names, types, 0..) |name, FieldType, index| {
        result[index] = switch (info) {
            .@"struct" => |value| .{
                .name = name,
                .type = FieldType,
                .is_comptime = value.field_attrs[index].@"comptime",
                .default_value_ptr = value.field_attrs[index].default_value_ptr,
            },
            .@"union" => .{
                .name = name,
                .type = FieldType,
                .is_comptime = false,
                .default_value_ptr = null,
            },
            else => unreachable,
        };
    }
    return result;
}

fn fieldCount(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |value| value.field_names.len,
        .@"union" => |value| value.field_names.len,
        else => @compileError("expected struct or union"),
    };
}
