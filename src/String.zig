const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const Error = @import("error.zig").Error;

pub const String = struct {
    runtime: Runtime,
    pointer: ?*anyopaque,

    pub fn fromUtf8(runtime: Runtime, text: [:0]const u8) Error!String {
        const pointer = runtime.exports.string_new(text.ptr) orelse return error.StringConversionFailed;
        return .{ .runtime = runtime, .pointer = pointer };
    }

    pub fn length(self: String) Error!usize {
        const pointer = self.pointer orelse return error.NullObject;
        const units = self.runtime.exports.string_length(pointer);
        if (units < 0) return error.StringConversionFailed;
        return @intCast(units);
    }

    pub fn toUtf8(self: String, buffer: []u8) Error![]const u8 {
        const units = try self.length();
        const pointer = self.pointer orelse return error.NullObject;
        const chars = self.runtime.exports.string_chars(pointer) orelse return error.StringConversionFailed;
        if (buffer.len < units * 3) return error.InvalidBuffer;
        const written = std.unicode.utf16LeToUtf8(buffer, chars[0..units]) catch return error.StringConversionFailed;
        return buffer[0..written];
    }
};
