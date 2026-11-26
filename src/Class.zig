const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const Method = @import("Method.zig").Method;
const Field = @import("Field.zig").Field;
const Array = @import("Array.zig").Array;
const Error = @import("error.zig").Error;

pub const Class = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn name(self: Class) ?[*:0]const u8 {
        return self.runtime.exports.class_get_name(self.pointer);
    }

    pub fn parent(self: Class) ?Class {
        const pointer = self.runtime.exports.class_get_parent(self.pointer) orelse return null;
        return .{ .runtime = self.runtime, .pointer = pointer };
    }

    pub fn isGeneric(self: Class) bool {
        return self.runtime.exports.class_is_generic(self.pointer);
    }

    pub fn isInflated(self: Class) bool {
        return self.runtime.exports.class_is_inflated(self.pointer);
    }

    pub fn derivesFromName(self: Class, wanted: [:0]const u8) bool {
        var current: ?Class = self;
        var depth: u32 = 0;
        while (current != null and depth < 64) : (depth += 1) {
            const current_name = current.?.name() orelse return false;
            if (std.mem.eql(u8, std.mem.span(current_name), wanted)) return true;
            current = current.?.parent();
        }
        return false;
    }

    pub fn findMethod(self: Class, method_name: [:0]const u8, parameter_count: usize) Error!Method {
        if (self.runtime.cache.findMethod(self.pointer, method_name, parameter_count)) |pointer| {
            return .{ .runtime = self.runtime, .pointer = pointer };
        }
        const class_pointer = self.pointer orelse return error.ClassNotFound;
        if (parameter_count > std.math.maxInt(i32)) return error.InvalidParameterCount;
        const pointer = self.runtime.exports.class_get_method_from_name(class_pointer, method_name.ptr, @intCast(parameter_count)) orelse return error.MethodNotFound;
        try self.runtime.cache.putMethod(self.pointer, method_name, parameter_count, pointer);
        return .{ .runtime = self.runtime, .pointer = pointer };
    }

    pub fn newArray(self: Class, length: usize) Error!Array {
        const class_pointer = self.pointer orelse return error.ClassNotFound;
        const pointer = self.runtime.exports.array_new(class_pointer, length) orelse return error.InvokeFailed;
        return .{ .runtime = self.runtime, .pointer = pointer };
    }

    pub fn methods(self: Class) MethodIterator {
        return .{ .runtime = self.runtime, .class_pointer = self.pointer };
    }

    pub const MethodIterator = struct {
        runtime: Runtime,
        class_pointer: ?*anyopaque,
        iterator: ?*anyopaque = null,

        pub fn next(self: *MethodIterator) ?Method {
            const pointer = self.runtime.exports.class_get_methods(self.class_pointer, &self.iterator) orelse return null;
            return .{ .runtime = self.runtime, .pointer = pointer };
        }
    };

    pub fn fields(self: Class) FieldIterator {
        return .{ .runtime = self.runtime, .class_pointer = self.pointer };
    }

    pub const FieldIterator = struct {
        runtime: Runtime,
        class_pointer: ?*anyopaque,
        iterator: ?*anyopaque = null,

        pub fn next(self: *FieldIterator) ?Field {
            const pointer = self.runtime.exports.class_get_fields(self.class_pointer, &self.iterator) orelse return null;
            return .{
                .runtime = self.runtime,
                .pointer = pointer,
                .offset = self.runtime.exports.field_get_offset(pointer),
                .is_static = (self.runtime.exports.field_get_flags(pointer) & 0x0010) != 0,
            };
        }
    };

    pub fn findField(self: Class, field_name: [:0]const u8) Error!Field {
        if (self.runtime.cache.findField(self.pointer, field_name)) |pointer| {
            return .{
                .runtime = self.runtime,
                .pointer = pointer,
                .offset = self.runtime.exports.field_get_offset(pointer),
                .is_static = (self.runtime.exports.field_get_flags(pointer) & 0x0010) != 0,
            };
        }
        const class_pointer = self.pointer orelse return error.ClassNotFound;
        const pointer = self.runtime.exports.class_get_field_from_name(class_pointer, field_name.ptr) orelse return error.FieldNotFound;
        try self.runtime.cache.putField(self.pointer, field_name, pointer);
        return .{
            .runtime = self.runtime,
            .pointer = pointer,
            .offset = self.runtime.exports.field_get_offset(pointer),
            .is_static = (self.runtime.exports.field_get_flags(pointer) & 0x0010) != 0,
        };
    }
};
