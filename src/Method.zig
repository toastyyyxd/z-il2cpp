const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const convert = @import("convert.zig");
const Exception = @import("Exception.zig").Exception;
const platform = @import("platform.zig");
const Error = @import("error.zig").Error;

pub const Method = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn name(self: Method) ?[*:0]const u8 {
        return self.runtime.exports.method_get_name(self.pointer);
    }

    pub fn parameterCount(self: Method) usize {
        return self.runtime.exports.method_get_param_count(self.pointer);
    }

    pub fn isStatic(self: Method) bool {
        var iflags: u32 = 0;
        return (self.runtime.exports.method_get_flags(self.pointer, &iflags) & 0x0010) != 0;
    }

    pub fn isVirtual(self: Method) bool {
        var iflags: u32 = 0;
        return (self.runtime.exports.method_get_flags(self.pointer, &iflags) & 0x0040) != 0;
    }

    pub fn resolveVirtual(self: Method, instance: ?*anyopaque) Error!Method {
        const object = instance orelse return error.NullObject;
        const pointer = self.runtime.exports.object_get_virtual_method(object, self.pointer) orelse return error.MethodNotFound;
        return .{ .runtime = self.runtime, .pointer = pointer };
    }

    pub fn isGeneric(self: Method) bool {
        return self.runtime.exports.method_is_generic(self.pointer);
    }

    pub fn isInflated(self: Method) bool {
        return self.runtime.exports.method_is_inflated(self.pointer);
    }

    pub fn entryPoint(self: Method) Error!?*anyopaque {
        const info = self.pointer orelse return error.MethodNotFound;
        return codePointerAt(info, platform.method_entry_offset);
    }

    pub fn virtualEntryPoint(self: Method) Error!?*anyopaque {
        const info = self.pointer orelse return error.MethodNotFound;
        return codePointerAt(info, platform.method_virtual_entry_offset);
    }

    fn codePointerAt(info: *anyopaque, offset: usize) ?*anyopaque {
        const bytes: [*]const u8 = @ptrCast(info);
        const candidate = @as(*align(1) const usize, @ptrCast(bytes + offset)).*;
        if (candidate == 0) return null;
        return @ptrFromInt(candidate);
    }

    pub fn invoke(self: Method, arguments: anytype, comptime ReturnType: type) Error!ReturnType {
        return self.call(null, arguments, ReturnType);
    }

    pub fn invokeOn(self: Method, instance: ?*anyopaque, arguments: anytype, comptime ReturnType: type) Error!ReturnType {
        return self.call(instance, arguments, ReturnType);
    }

    pub fn Outcome(comptime ReturnType: type) type {
        return union(enum) {
            value: ReturnType,
            exception: Exception,
        };
    }

    pub fn invokeCatching(self: Method, arguments: anytype, comptime ReturnType: type) Error!Outcome(ReturnType) {
        return self.callCatching(null, arguments, ReturnType);
    }

    pub fn invokeOnCatching(self: Method, instance: ?*anyopaque, arguments: anytype, comptime ReturnType: type) Error!Outcome(ReturnType) {
        return self.callCatching(instance, arguments, ReturnType);
    }

    fn call(self: Method, instance: ?*anyopaque, arguments: anytype, comptime ReturnType: type) Error!ReturnType {
        const outcome = try self.callCatching(instance, arguments, ReturnType);
        return switch (outcome) {
            .value => |value| value,
            .exception => error.ManagedException,
        };
    }

    fn callCatching(self: Method, instance: ?*anyopaque, arguments: anytype, comptime ReturnType: type) Error!Outcome(ReturnType) {
        const ArgumentsType = @TypeOf(arguments);
        const argument_types: []const type = switch (@typeInfo(ArgumentsType)) {
            .@"struct" => |info| info.field_types,
            else => &.{},
        };
        const argument_count = argument_types.len;
        const method_pointer = self.pointer orelse return error.MethodNotFound;
        if (self.isGeneric()) return error.GenericMethodNotSupported;
        const expected = self.runtime.exports.method_get_param_count(method_pointer);
        if (argument_count != expected) return error.ArgumentCountMismatch;

        const Layout = comptime slotLayout(argument_types);
        var storage: [argument_count][Layout.stride]u8 align(Layout.alignment) = undefined;
        var pointers: [argument_count]?*anyopaque = undefined;
        inline for (0..argument_count) |index| {
            const value = arguments[index];
            const ValueType = @TypeOf(value);
            if (!isSupported(ValueType)) return error.ArgumentsNotSupported;
            @memset(storage[index][0..], 0);
            @memcpy(storage[index][0..@sizeOf(ValueType)], std.mem.asBytes(&value));
            pointers[index] = @ptrCast(&storage[index]);
        }

        var exception: ?*anyopaque = null;
        const params: ?[*]?*anyopaque = if (argument_count == 0) null else &pointers;
        const result = self.runtime.exports.runtime_invoke(method_pointer, instance, params, &exception);
        if (exception) |pointer| {
            return .{ .exception = .{ .runtime = self.runtime, .pointer = pointer } };
        }
        if (ReturnType == void) return .{ .value = {} };
        if (ReturnType == ?*anyopaque) return .{ .value = result };
        const boxed = result orelse return error.InvokeFailed;
        return .{ .value = try convert.fromBoxed(ReturnType, boxed, self.runtime.exports.object_unbox) };
    }

    const SlotLayout = struct {
        stride: usize,
        alignment: usize,
    };

    fn slotLayout(comptime types: []const type) SlotLayout {
        var size: usize = 8;
        var alignment: usize = 8;
        for (types) |ValueType| {
            size = @max(size, @sizeOf(ValueType));
            alignment = @max(alignment, @alignOf(ValueType));
        }
        const stride = (size + alignment - 1) & ~(alignment - 1);
        return .{ .stride = stride, .alignment = alignment };
    }

    fn isSupported(comptime ValueType: type) bool {
        return switch (@typeInfo(ValueType)) {
            .bool, .int, .float, .pointer, .@"enum" => true,
            .@"struct" => |info| info.layout == .@"extern",
            else => false,
        };
    }
};
