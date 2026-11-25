const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const Method = @import("Method.zig").Method;
const Field = @import("Field.zig").Field;
const Error = @import("error.zig").Error;

pub const Class = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn findMethod(self: Class, name: [:0]const u8, parameter_count: usize) Error!Method {
        if (self.runtime.cache.findMethod(self.pointer, name, parameter_count)) |pointer| {
            return .{ .runtime = self.runtime, .pointer = pointer };
        }
        const class_pointer = self.pointer orelse return error.ClassNotFound;
        if (parameter_count > std.math.maxInt(i32)) return error.InvalidParameterCount;
        const pointer = self.runtime.exports.class_get_method_from_name(class_pointer, name.ptr, @intCast(parameter_count)) orelse return error.MethodNotFound;
        try self.runtime.cache.putMethod(self.pointer, name, parameter_count, pointer);
        return .{ .runtime = self.runtime, .pointer = pointer };
    }

    pub fn findField(self: Class, name: [:0]const u8) Error!Field {
        if (self.runtime.cache.findField(self.pointer, name)) |pointer| {
            return .{
                .runtime = self.runtime,
                .pointer = pointer,
                .offset = self.runtime.exports.field_get_offset(pointer),
            };
        }
        const class_pointer = self.pointer orelse return error.ClassNotFound;
        const pointer = self.runtime.exports.class_get_field_from_name(class_pointer, name.ptr) orelse return error.FieldNotFound;
        try self.runtime.cache.putField(self.pointer, name, pointer);
        return .{
            .runtime = self.runtime,
            .pointer = pointer,
            .offset = self.runtime.exports.field_get_offset(pointer),
        };
    }
};
