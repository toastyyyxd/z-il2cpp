const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const convert = @import("convert.zig");
const Error = @import("error.zig").Error;

pub const Method = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn invoke(self: Method, arguments: anytype, comptime ReturnType: type) Error!ReturnType {
        const ArgumentsType = @TypeOf(arguments);
        const argument_count = switch (@typeInfo(ArgumentsType)) {
            .@"struct" => |info| info.field_names.len,
            else => 0,
        };
        const method_pointer = self.pointer orelse return error.MethodNotFound;
        const expected = self.runtime.exports.method_get_param_count(method_pointer);
        if (argument_count != expected) return error.ArgumentCountMismatch;

        var storage: [argument_count][8]u8 align(8) = undefined;
        var pointers: [argument_count]?*anyopaque = undefined;
        inline for (0..argument_count) |index| {
            const value = arguments[index];
            const ValueType = @TypeOf(value);
            if (!isSupported(ValueType)) return error.ArgumentsNotSupported;
            if (@sizeOf(ValueType) > @sizeOf(@TypeOf(storage[0]))) return error.ArgumentsNotSupported;
            storage[index] = @splat(0);
            @memcpy(storage[index][0..@sizeOf(ValueType)], std.mem.asBytes(&value));
            pointers[index] = @ptrCast(&storage[index]);
        }

        var exception: ?*anyopaque = null;
        const params: ?[*]?*anyopaque = if (argument_count == 0) null else &pointers;
        const result = self.runtime.exports.runtime_invoke(method_pointer, null, params, &exception);
        if (exception != null) return error.ManagedException;
        if (ReturnType == void) return {};
        const boxed = result orelse return error.InvokeFailed;
        return convert.fromBoxed(ReturnType, boxed, self.runtime.exports.object_unbox);
    }

    fn isSupported(comptime ValueType: type) bool {
        return switch (@typeInfo(ValueType)) {
            .bool, .int, .float, .pointer, .@"enum" => true,
            else => false,
        };
    }
};
