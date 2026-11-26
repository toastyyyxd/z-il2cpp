const std = @import("std");
const zil2cpp = @import("z_il2cpp");
const frames = @import("frames");
const Hooks = zil2cpp.Hooks;
const Runtime = zil2cpp.Runtime;
const Loader = zil2cpp.Loader;
const Error = zil2cpp.Error;

extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

var scratch: [8192]u8 align(16) = @splat(0);

var width_calls: u32 = 0;
var width_before: i32 = 0;
var width_after: i32 = 0;
var width_final: i32 = 0;
var width_hook: ?Hooks.Hook(fn () callconv(.c) i32) = null;

var arg_calls: u32 = 0;
var arg_seen: f32 = 0;
var arg_before: f32 = 0;
var arg_after: f32 = 0;
var arg_final: f32 = 0;
var arg_hook: ?Hooks.Hook(fn (f32) callconv(.c) void) = null;

fn loader() Loader {
    return .{ .get_module_handle = GetModuleHandleW, .get_proc_address = GetProcAddress };
}

fn runtime() Error!Runtime {
    return Runtime.init(loader(), scratch[0..]);
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
        error.ImageNotFound => -24,
    };
}

fn widthDetour() callconv(.c) i32 {
    width_calls +%= 1;
    const hook = width_hook orelse return -1;
    return hook.original();
}

fn timeScaleDetour(value: f32) callconv(.c) void {
    arg_calls +%= 1;
    arg_seen = value;
    const hook = arg_hook orelse return;
    hook.original(value);
}

fn selftestWidth(runtime_value: Runtime) i32 {
    const screen = runtime_value.findClass("UnityEngine", "Screen") catch return -3;
    const method = screen.findMethod("get_width", 0) catch return -4;
    width_before = method.invoke(.{}, i32) catch return -5;
    if (width_before <= 0) return -5;
    width_hook = Hooks.hookMethod(fn () callconv(.c) i32, method, &widthDetour) catch return -6;
    width_after = method.invoke(.{}, i32) catch return -7;
    width_hook.?.detach();
    width_hook = null;
    width_final = method.invoke(.{}, i32) catch return -8;
    if (width_before != width_after or width_after != width_final) return -9;
    return 1;
}

fn selftestArguments(runtime_value: Runtime) i32 {
    const time = runtime_value.findClass("UnityEngine", "Time") catch return -10;
    const setter = time.findMethod("set_timeScale", 1) catch return -11;
    const getter = time.findMethod("get_timeScale", 0) catch return -12;
    arg_before = getter.invoke(.{}, f32) catch return -13;
    arg_hook = Hooks.hookMethod(fn (f32) callconv(.c) void, setter, &timeScaleDetour) catch return -14;
    setter.invoke(.{@as(f32, 0.5)}, void) catch return -15;
    arg_after = getter.invoke(.{}, f32) catch return -16;
    const seen = arg_seen;
    const calls = arg_calls;
    arg_hook.?.detach();
    arg_hook = null;
    setter.invoke(.{arg_before}, void) catch return -17;
    arg_final = getter.invoke(.{}, f32) catch return -18;
    if (calls != 1 or seen != 0.5 or arg_after != 0.5) return -19;
    return 1;
}

export fn dev_selftest_width() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestWidth(runtime_value);
}

export fn dev_selftest_args() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestArguments(runtime_value);
}

export fn dev_width_before() callconv(.c) i32 {
    return width_before;
}

export fn dev_width_after() callconv(.c) i32 {
    return width_after;
}

export fn dev_width_final() callconv(.c) i32 {
    return width_final;
}

export fn dev_count() callconv(.c) u32 {
    return width_calls;
}

export fn dev_arg_calls() callconv(.c) u32 {
    return arg_calls;
}

export fn dev_arg_seen() callconv(.c) f32 {
    return arg_seen;
}

export fn dev_arg_before() callconv(.c) f32 {
    return arg_before;
}

export fn dev_arg_after() callconv(.c) f32 {
    return arg_after;
}

export fn dev_arg_final() callconv(.c) f32 {
    return arg_final;
}

export fn dev_frame_install_limit(limit: u32) callconv(.c) i32 {
    if (frames.installedCount() != 0) return @intCast(frames.installedCount());
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    const installed = frames.install(runtime_value, limit);
    if (installed == 0) return -2;
    return @intCast(installed);
}

export fn dev_frame_install() callconv(.c) i32 {
    return dev_frame_install_limit(frames.limit);
}

export fn dev_frame_count() callconv(.c) u32 {
    return frames.count();
}

export fn dev_frame_slots() callconv(.c) u32 {
    return frames.installedCount();
}

export fn dev_frame_skip_original(enable: u32) callconv(.c) void {
    frames.skipOriginal(enable != 0);
}

export fn dev_frame_slot_count(index: u32) callconv(.c) u32 {
    return frames.slotCount(index);
}

export fn dev_frame_reset() callconv(.c) void {
    frames.reset();
}

export fn dev_frame_remove() callconv(.c) i32 {
    frames.remove();
    Hooks.deinit() catch return -1;
    return 1;
}
