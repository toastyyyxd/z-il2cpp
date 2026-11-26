const Error = @import("error.zig").Error;

pub const UnboxFn = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

pub fn fromBoxed(comptime T: type, boxed: ?*anyopaque, unbox: UnboxFn) Error!T {
    const raw = unbox(boxed) orelse return error.UnboxFailed;
    return readAt(T, @ptrCast(raw));
}

pub fn readAt(comptime T: type, address: [*]u8) T {
    if (T == bool) {
        const byte: *align(1) const u8 = @ptrCast(address);
        return byte.* != 0;
    }
    const pointer: *align(1) const T = @ptrCast(address);
    return pointer.*;
}

pub fn writeAt(comptime T: type, address: [*]u8, value: T) void {
    if (T == bool) {
        const byte: *align(1) u8 = @ptrCast(address);
        byte.* = @intFromBool(value);
        return;
    }
    const pointer: *align(1) T = @ptrCast(address);
    pointer.* = value;
}

test "struct read and write" {
    const Point = extern struct { x: i32, y: i32 };
    var buffer: [8]u8 = undefined;
    writeAt(Point, buffer[0..], .{ .x = 3, .y = -4 });
    const point = readAt(Point, buffer[0..]);
    try @import("std").testing.expectEqual(@as(i32, 3), point.x);
    try @import("std").testing.expectEqual(@as(i32, -4), point.y);
}
