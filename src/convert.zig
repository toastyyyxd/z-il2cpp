const std = @import("std");
const Error = @import("error.zig").Error;

pub const UnboxFn = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

/// Wire format of one managed argument or return value.
pub const Kind = enum {
    boolean,
    i1,
    u1,
    i2,
    u2,
    i4,
    u4,
    i8,
    u8,
    r4,
    r8,
    reference,
    raw,
};

/// Maps an Il2CppTypeEnum value to a wire kind.
pub fn kindOf(coded: i32) Kind {
    return switch (coded) {
        0x02 => .boolean,
        0x03 => .u2, // System.Char is 16 bits
        0x04 => .i1,
        0x05 => .u1,
        0x06 => .i2,
        0x07 => .u2,
        0x08 => .i4,
        0x09 => .u4,
        0x0a => .i8,
        0x0b => .u8,
        0x0c => .r4,
        0x0d => .r8,
        0x18 => .i8, // native int
        0x19 => .u8, // native uint
        0x0e, 0x0f, 0x10, 0x12, 0x14, 0x15, 0x1b, 0x1c, 0x1d => .reference,
        else => .raw,
    };
}

pub fn fromBoxed(comptime T: type, boxed: ?*anyopaque, unbox: UnboxFn) Error!T {
    const raw = unbox(boxed) orelse return error.UnboxFailed;
    return readAt(T, @ptrCast(raw));
}

/// Reads a return value using the managed return type.
pub fn fromBoxedAs(comptime T: type, boxed: ?*anyopaque, unbox: UnboxFn, kind: Kind) Error!T {
    const raw: [*]u8 = @ptrCast(unbox(boxed) orelse return error.UnboxFailed);
    return switch (kind) {
        .reference, .raw => readAt(T, raw),
        .boolean => readNumber(T, .{ .integer = @intFromBool(readAt(bool, raw)) }),
        .i1 => readNumber(T, .{ .integer = readAt(i8, raw) }),
        .u1 => readNumber(T, .{ .integer = readAt(u8, raw) }),
        .i2 => readNumber(T, .{ .integer = readAt(i16, raw) }),
        .u2 => readNumber(T, .{ .integer = readAt(u16, raw) }),
        .i4 => readNumber(T, .{ .integer = readAt(i32, raw) }),
        .u4 => readNumber(T, .{ .integer = readAt(u32, raw) }),
        .i8 => readNumber(T, .{ .integer = readAt(i64, raw) }),
        .u8 => readNumber(T, .{ .integer = readAt(u64, raw) }),
        .r4 => readNumber(T, .{ .float = readAt(f32, raw) }),
        .r8 => readNumber(T, .{ .float = readAt(f64, raw) }),
    };
}

/// Writes one argument using the managed parameter type.
/// Returns the pointer to pass to runtime_invoke.
pub fn storeArgument(kind: Kind, value: anytype, slot: []u8) Error!?*anyopaque {
    const ValueType = @TypeOf(value);
    return switch (kind) {
        .reference => if (isReference(ValueType)) asReference(value) else error.ArgumentTypeMismatch,
        .raw => if (isReference(ValueType)) error.ArgumentTypeMismatch else storeRaw(value, slot),
        else => storeNumber(kind, value, slot),
    };
}

/// Writes one argument without managed type information.
pub fn storeUntyped(value: anytype, slot: []u8) Error!?*anyopaque {
    if (isReference(@TypeOf(value))) return asReference(value);
    return storeRaw(value, slot);
}

const Number = union(enum) {
    integer: i128,
    float: f64,
};

fn storeNumber(kind: Kind, value: anytype, slot: []u8) Error!?*anyopaque {
    if (isReference(@TypeOf(value))) return error.ArgumentTypeMismatch;
    @memset(slot, 0);
    const number = try numberOf(value);
    switch (kind) {
        .boolean => writeAt(bool, slot.ptr, truthy(number)),
        .i1 => try writeInteger(i8, number, slot),
        .u1 => try writeInteger(u8, number, slot),
        .i2 => try writeInteger(i16, number, slot),
        .u2 => try writeInteger(u16, number, slot),
        .i4 => try writeInteger(i32, number, slot),
        .u4 => try writeInteger(u32, number, slot),
        .i8 => try writeInteger(i64, number, slot),
        .u8 => try writeInteger(u64, number, slot),
        .r4 => try writeFloat(f32, number, slot),
        .r8 => try writeFloat(f64, number, slot),
        else => return error.ArgumentsNotSupported,
    }
    return @ptrCast(slot.ptr);
}

fn storeRaw(value: anytype, slot: []u8) Error!?*anyopaque {
    const ValueType = @TypeOf(value);
    if (@sizeOf(ValueType) > slot.len) return error.SizeMismatch;
    @memset(slot, 0);
    @memcpy(slot[0..@sizeOf(ValueType)], std.mem.asBytes(&value));
    return @ptrCast(slot.ptr);
}

fn numberOf(value: anytype) Error!Number {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => .{ .integer = @intFromBool(value) },
        .int => .{ .integer = @intCast(value) },
        .@"enum" => .{ .integer = @backingInt(value) },
        .float => .{ .float = @floatCast(value) },
        else => error.ArgumentsNotSupported,
    };
}

fn truthy(number: Number) bool {
    return switch (number) {
        .integer => |value| value != 0,
        .float => |value| value != 0,
    };
}

fn toInteger(number: Number) Error!i128 {
    return switch (number) {
        .integer => |value| value,
        .float => error.ArgumentTypeMismatch,
    };
}

fn writeInteger(comptime T: type, number: Number, slot: []u8) Error!void {
    const converted = std.math.cast(T, try toInteger(number)) orelse return error.ArgumentOutOfRange;
    writeAt(T, slot.ptr, converted);
}

fn writeFloat(comptime T: type, number: Number, slot: []u8) Error!void {
    writeAt(T, slot.ptr, try asFloat(T, number));
}

fn asFloat(comptime T: type, number: Number) Error!T {
    return switch (number) {
        .integer => |value| @floatFromInt(value),
        .float => |value| @floatCast(value),
    };
}

fn readNumber(comptime T: type, number: Number) Error!T {
    return switch (@typeInfo(T)) {
        .bool => truthy(number),
        .int => std.math.cast(T, try toInteger(number)) orelse return error.ArgumentOutOfRange,
        .@"enum" => |info| blk: {
            const value = std.math.cast(info.tag_type, try toInteger(number)) orelse
                return error.ArgumentOutOfRange;
            break :blk @fromBackingInt(@intCast(value));
        },
        .float => asFloat(T, number),
        else => error.ArgumentsNotSupported,
    };
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

pub fn isReference(comptime ValueType: type) bool {
    return switch (@typeInfo(ValueType)) {
        .pointer => true,
        .optional => |info| isReference(info.child),
        else => false,
    };
}

pub fn asReference(value: anytype) ?*anyopaque {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |inner| @ptrCast(inner) else null,
        .pointer => @ptrCast(value),
        else => null,
    };
}

test "struct read and write" {
    const Point = extern struct { x: i32, y: i32 };
    var buffer: [8]u8 = undefined;
    writeAt(Point, buffer[0..], .{ .x = 3, .y = -4 });
    const point = readAt(Point, buffer[0..]);
    try @import("std").testing.expectEqual(@as(i32, 3), point.x);
    try @import("std").testing.expectEqual(@as(i32, -4), point.y);
}

test "kind mapping" {
    try std.testing.expectEqual(Kind.boolean, kindOf(0x02));
    try std.testing.expectEqual(Kind.i4, kindOf(0x08));
    try std.testing.expectEqual(Kind.r4, kindOf(0x0c));
    try std.testing.expectEqual(Kind.reference, kindOf(0x12));
    try std.testing.expectEqual(Kind.raw, kindOf(0x11));
}

test "integer argument to float parameter" {
    var slot: [8]u8 = undefined;
    const pointer = try storeArgument(.r4, @as(i32, 18), slot[0..]);
    try std.testing.expectEqual(@as(f32, 18.0), readAt(f32, @ptrCast(pointer.?)));
}

test "float argument to integer parameter is rejected" {
    var slot: [8]u8 = undefined;
    try std.testing.expectError(error.ArgumentTypeMismatch, storeArgument(.i4, @as(f32, 1.5), slot[0..]));
}

test "widening integer parameter" {
    var slot: [8]u8 = undefined;
    const pointer = try storeArgument(.i8, @as(i32, -7), slot[0..]);
    try std.testing.expectEqual(@as(i64, -7), readAt(i64, @ptrCast(pointer.?)));
}

test "integer out of range" {
    var slot: [8]u8 = undefined;
    try std.testing.expectError(error.ArgumentOutOfRange, storeArgument(.u1, @as(i32, 300), slot[0..]));
}

test "pointer argument to reference parameter" {
    var slot: [8]u8 = undefined;
    var target: u32 = 0;
    const pointer = try storeArgument(.reference, @as(*anyopaque, @ptrCast(&target)), slot[0..]);
    try std.testing.expectEqual(@intFromPtr(&target), @intFromPtr(pointer.?));
}

test "integer argument to reference parameter is rejected" {
    var slot: [8]u8 = undefined;
    try std.testing.expectError(error.ArgumentTypeMismatch, storeArgument(.reference, @as(i32, 1), slot[0..]));
}
