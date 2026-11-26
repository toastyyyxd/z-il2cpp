const Runtime = @import("Runtime.zig").Runtime;
const convert = @import("convert.zig");
const platform = @import("platform.zig");
const Error = @import("error.zig").Error;

pub const header_size = platform.array_header_size;

pub const Array = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn isNull(self: Array) bool {
        return self.pointer == null;
    }

    pub fn length(self: Array) Error!usize {
        const pointer = self.pointer orelse return error.NullObject;
        return self.runtime.exports.array_length(pointer);
    }

    pub fn elementSize(self: Array) Error!usize {
        const pointer = self.pointer orelse return error.NullObject;
        const class_pointer = self.runtime.exports.object_get_class(pointer) orelse return error.ClassNotFound;
        const size = self.runtime.exports.array_element_size(class_pointer);
        if (size <= 0) return error.SizeMismatch;
        return @intCast(size);
    }

    pub fn data(self: Array) Error![*]u8 {
        const pointer = self.pointer orelse return error.NullObject;
        const bytes: [*]u8 = @ptrCast(pointer);
        return bytes + header_size;
    }

    pub fn get(self: Array, comptime ValueType: type, index: usize) Error!ValueType {
        const location = try self.locate(ValueType, index);
        return convert.readAt(ValueType, location);
    }

    pub fn set(self: Array, comptime ValueType: type, index: usize, value: ValueType) Error!void {
        const location = try self.locate(ValueType, index);
        convert.writeAt(ValueType, location, value);
    }

    fn locate(self: Array, comptime ValueType: type, index: usize) Error![*]u8 {
        const count = try self.length();
        if (index >= count) return error.IndexOutOfBounds;
        const size = try self.elementSize();
        if (size != @sizeOf(ValueType)) return error.SizeMismatch;
        const elements = try self.data();
        return elements + index * size;
    }
};
