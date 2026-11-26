const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const String = @import("String.zig").String;
const Error = @import("error.zig").Error;

pub const Exception = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn className(self: Exception) ?[*:0]const u8 {
        const class_pointer = self.runtime.exports.object_get_class(self.pointer) orelse return null;
        return self.runtime.exports.class_get_name(class_pointer);
    }

    pub fn message(self: Exception, buffer: []u8) Error![]const u8 {
        return self.readString("get_Message", buffer);
    }

    pub fn stackTrace(self: Exception, buffer: []u8) Error![]const u8 {
        return self.readString("get_StackTrace", buffer);
    }

    fn readString(self: Exception, method_name: [:0]const u8, buffer: []u8) Error![]const u8 {
        const exception_class = try self.runtime.findClass("System", "Exception");
        const method = try exception_class.findMethod(method_name, 0);
        const pointer = try method.invokeOn(self.pointer, .{}, ?*anyopaque);
        if (pointer == null) return buffer[0..0];
        const text = String{ .runtime = self.runtime, .pointer = pointer };
        return text.toUtf8(buffer);
    }
};
