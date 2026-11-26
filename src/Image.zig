const Runtime = @import("Runtime.zig").Runtime;
const Class = @import("Class.zig").Class;
const Error = @import("error.zig").Error;

pub const Image = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn name(self: Image) ?[*:0]const u8 {
        return self.runtime.exports.image_get_name(self.pointer);
    }

    pub fn classCount(self: Image) usize {
        return self.runtime.exports.image_get_class_count(self.pointer);
    }

    pub fn classAt(self: Image, index: usize) Error!Class {
        const pointer = self.runtime.exports.image_get_class(self.pointer, index) orelse return error.ClassNotFound;
        return .{ .runtime = self.runtime, .pointer = pointer };
    }
};
