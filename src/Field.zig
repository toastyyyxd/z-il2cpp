const Runtime = @import("Runtime.zig").Runtime;
const convert = @import("convert.zig");
const Error = @import("error.zig").Error;

pub const Field = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,
    offset: usize,

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
