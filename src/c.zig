const std = @import("std");
const Runtime = @import("Runtime.zig").Runtime;
const ManagedString = @import("String.zig").String;
const Handle = @import("Handle.zig").Handle;
const Loader = @import("Loader.zig").Loader;
const Error = @import("error.zig").Error;

pub const abi_version: u32 = 1;
pub const init_magic: u32 = 0x324c315a;

const scratch_magic: u64 = 0x5343524154434831;

pub const State = extern struct {
    abi_version: u32,
    init_magic: u32,
    flags: u32,
    padding: u32,
    tick_count: u64,
    last_frame: u64,
    reserved: [4]u64,
};

comptime {
    if (@sizeOf(State) != 64) @compileError("State size changed");
    if (@alignOf(State) != 8) @compileError("State alignment changed");
}

export fn zil2cpp_abi() callconv(.c) u32 {
    return abi_version;
}

export fn zil2cpp_state_size() callconv(.c) u32 {
    return @sizeOf(State);
}

export fn zil2cpp_init(state: ?*State, magic: u32) callconv(.c) u32 {
    const s = state orelse return 0;
    s.abi_version = abi_version;
    s.init_magic = magic;
    s.flags = 0;
    s.padding = 0;
    s.tick_count = 0;
    s.last_frame = 0;
    s.reserved = .{ 0, 0, 0, 0 };
    return if (magic == init_magic) abi_version else 0;
}

export fn zil2cpp_runtime_init(state: ?*State, loader: ?*const Loader, scratch_pointer: ?[*]u8, scratch_length: usize) callconv(.c) i32 {
    const s = state orelse return errorCode(error.NotInitialized);
    const loader_value = loader orelse return errorCode(error.NotInitialized);
    const buffer = scratch_pointer orelse return errorCode(error.InvalidScratch);
    if (scratch_length < 1024) return errorCode(error.InvalidScratch);
    s.reserved[0] = @intFromPtr(loader_value);
    s.reserved[1] = @intFromPtr(buffer);
    s.reserved[2] = scratch_length;
    const slice = buffer[0..scratch_length];
    if (s.reserved[3] != scratch_magic) {
        @memset(slice, 0);
        s.reserved[3] = scratch_magic;
    }
    _ = Runtime.init(loader_value.*, slice) catch |err| return errorCode(err);
    return @intCast(abi_version);
}

export fn zil2cpp_tick(state: ?*State, frame: u64) callconv(.c) u64 {
    const s = state orelse return 0;
    s.tick_count +%= 1;
    s.last_frame = frame;
    return s.tick_count;
}

export fn zil2cpp_tick_count(state: ?*const State) callconv(.c) u64 {
    const s = state orelse return 0;
    return s.tick_count;
}

export fn zil2cpp_last_frame(state: ?*const State) callconv(.c) u64 {
    const s = state orelse return 0;
    return s.last_frame;
}

export fn zil2cpp_probe_screen_width(state: ?*State) callconv(.c) i32 {
    return probeStaticInt(state, "UnityEngine", "Screen", "get_width");
}

fn probeStaticInt(state: ?*State, namespace: [:0]const u8, class_name: [:0]const u8, method_name: [:0]const u8) i32 {
    const runtime = runtimeFromState(state) catch |err| return errorCode(err);
    const class = runtime.findClass(namespace, class_name) catch |err| return errorCode(err);
    const method = class.findMethod(method_name, 0) catch |err| return errorCode(err);
    return method.invoke(.{}, i32) catch |err| return errorCode(err);
}

fn runtimeFromState(state: ?*State) Error!Runtime {
    const s = state orelse return error.NotInitialized;
    if (s.reserved[3] != scratch_magic) return error.NotInitialized;
    const loader_pointer: *const Loader = @ptrFromInt(@as(usize, @intCast(s.reserved[0])));
    const scratch_pointer: [*]u8 = @ptrFromInt(@as(usize, @intCast(s.reserved[1])));
    const scratch_length: usize = @intCast(s.reserved[2]);
    if (scratch_length == 0) return error.InvalidScratch;
    return Runtime.init(loader_pointer.*, scratch_pointer[0..scratch_length]);
}

fn errorCode(err: Error) i32 {
    return switch (err) {
        error.NotInitialized => -1,
        error.InvalidScratch => -2,
        error.ModuleNotFound => -3,
        error.MissingExport => -4,
        error.NoDomain => -5,
        error.NoAssemblies => -6,
        error.ClassNotFound => -7,
        error.MethodNotFound => -8,
        error.FieldNotFound => -9,
        error.NullInstance => -10,
        error.InvokeFailed => -11,
        error.ManagedException => -12,
        error.UnboxFailed => -13,
        error.CacheFull => -14,
        error.ArgumentsNotSupported => -15,
        error.VirtualMethodNotSupported => -16,
        error.InvalidParameterCount => -17,
        error.ArgumentCountMismatch => -18,
        error.NullObject => -19,
        error.HandleFailed => -20,
        error.StringConversionFailed => -21,
        error.InvalidBuffer => -22,
        error.HookFailed => -23,
    };
}

test "state layout" {
    try @import("std").testing.expectEqual(@as(usize, 64), @sizeOf(State));
    try @import("std").testing.expectEqual(@as(usize, 32), @offsetOf(State, "reserved"));
}

test "init rejects bad magic" {
    var state = State{
        .abi_version = 0,
        .init_magic = 0,
        .flags = 0,
        .padding = 0,
        .tick_count = 0,
        .last_frame = 0,
        .reserved = .{ 0, 0, 0, 0 },
    };
    try @import("std").testing.expectEqual(@as(u32, 0), zil2cpp_init(&state, init_magic ^ 0xffff_ffff));
    try @import("std").testing.expectEqual(abi_version, zil2cpp_init(&state, init_magic));
}
