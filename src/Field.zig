const Runtime = @import("Runtime.zig").Runtime;
const convert = @import("convert.zig");
const Error = @import("error.zig").Error;

pub const Field = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,
    offset: usize,
    is_static: bool,

    pub fn isStatic(self: Field) bool {
        return self.is_static;
    }

    pub fn name(self: Field) ?[*:0]const u8 {
        return self.runtime.exports.field_get_name(self.pointer);
    }

    pub fn typeName(self: Field) ?[*:0]const u8 {
        const pointer = self.runtime.exports.field_get_type(self.pointer) orelse return null;
        return self.runtime.exports.type_get_name(pointer);
    }

    pub fn readStatic(self: Field, comptime ValueType: type) Error!ValueType {
        var value: ValueType = undefined;
        self.runtime.exports.field_static_get_value(self.pointer, @ptrCast(&value));
        return value;
    }

    pub fn writeStatic(self: Field, value: anytype) Error!void {
        var copy = value;
        self.runtime.exports.field_static_set_value(self.pointer, @ptrCast(&copy));
    }

    pub fn read(self: Field, instance: ?*anyopaque, comptime ValueType: type) Error!ValueType {
        const base = instance orelse return error.NullInstance;
        const bytes: [*]u8 = @ptrCast(base);
        return convert.readAt(ValueType, bytes + self.offset);
    }

    pub fn write(self: Field, instance: ?*anyopaque, value: anytype) Error!void {
        const base = instance orelse return error.NullInstance;
        const bytes: [*]u8 = @ptrCast(base);
        convert.writeAt(@TypeOf(value), bytes + self.offset, value);
    }
};
