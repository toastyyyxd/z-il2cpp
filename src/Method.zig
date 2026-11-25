const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const convert = @import("convert.zig");
const Error = @import("error.zig").Error;

pub const Method = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn invoke(self: Method, arguments: anytype, comptime ReturnType: type) Error!ReturnType {
        const argument_count = switch (@typeInfo(@TypeOf(arguments))) {
            .@"struct" => |info| info.field_names.len,
            else => 0,
        };
        if (argument_count != 0) return error.ArgumentsNotSupported;
        const method_pointer = self.pointer orelse return error.MethodNotFound;
        var exception: ?*anyopaque = null;
        const result = self.runtime.exports.runtime_invoke(method_pointer, null, null, &exception) orelse return error.InvokeFailed;
        if (exception != null) return error.ManagedException;
        if (ReturnType == void) return {};
        return convert.fromBoxed(ReturnType, result, self.runtime.exports.object_unbox);
    }
};
