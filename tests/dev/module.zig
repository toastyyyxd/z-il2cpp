const zil2cpp = @import("z_il2cpp");
const Runtime = zil2cpp.Runtime;
const Loader = zil2cpp.Loader;
const Error = zil2cpp.Error;

extern fn MH_Initialize() callconv(.winapi) c_int;
extern fn MH_Uninitialize() callconv(.winapi) c_int;
extern fn MH_CreateHook(target: ?*anyopaque, detour: ?*anyopaque, original: ?*?*anyopaque) callconv(.winapi) c_int;
extern fn MH_EnableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_DisableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_RemoveHook(target: ?*anyopaque) callconv(.winapi) c_int;

extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

var scratch: [8192]u8 align(16) = @splat(0);
var hook_count: u32 = 0;
var hook_offset: usize = 0;
var width_before: i32 = 0;
var width_after: i32 = 0;
var width_final: i32 = 0;
var original_width: ?*const fn () callconv(.c) i32 = null;

fn loader() Loader {
    return .{ .get_module_handle = GetModuleHandleW, .get_proc_address = GetProcAddress };
}

fn runtime() Error!Runtime {
    return Runtime.init(loader(), scratch[0..]);
}

fn detour() callconv(.c) i32 {
    hook_count +%= 1;
    const function = original_width orelse return -1;
    return function();
}

fn width(runtime_value: Runtime) i32 {
    const screen = runtime_value.findClass("UnityEngine", "Screen") catch return -100;
    const method = screen.findMethod("get_width", 0) catch return -101;
    return method.invoke(.{}, i32) catch return -102;
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
    };
}

fn tryOffset(runtime_value: Runtime, method_info: ?*anyopaque, offset: usize) bool {
    const bytes: [*]const u8 = @ptrCast(method_info.?);
    const candidate = @as(*align(1) const usize, @ptrCast(bytes + offset)).*;
    if (candidate == 0) return false;
    const target: *anyopaque = @ptrFromInt(candidate);
    if (MH_CreateHook(target, @ptrCast(@constCast(&detour)), @ptrCast(&original_width)) != 0) return false;
    if (MH_EnableHook(target) != 0) {
        _ = MH_RemoveHook(target);
        return false;
    }
    const attempt = width(runtime_value);
    if (hook_count > 0 and attempt == width_before) {
        hook_offset = offset;
        return true;
    }
    _ = MH_DisableHook(target);
    _ = MH_RemoveHook(target);
    return false;
}

export fn dev_selftest() callconv(.c) i32 {
    if (MH_Initialize() != 0) return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    width_before = width(runtime_value);
    if (width_before <= 0) return -2;
    const screen = runtime_value.findClass("UnityEngine", "Screen") catch return -3;
    const method = screen.findMethod("get_width", 0) catch return -4;
    const method_info = method.pointer orelse return -5;

    var installed = false;
    for ([_]usize{ 0, 8 }) |offset| {
        if (tryOffset(runtime_value, method_info, offset)) {
            installed = true;
            break;
        }
    }
    if (!installed) return -6;

    width_after = width(runtime_value);
    const target = blk: {
        const bytes: [*]const u8 = @ptrCast(method_info);
        const candidate = @as(*align(1) const usize, @ptrCast(bytes + hook_offset)).*;
        break :blk @as(*anyopaque, @ptrFromInt(candidate));
    };
    _ = MH_DisableHook(target);
    _ = MH_RemoveHook(target);
    width_final = width(runtime_value);
    _ = MH_Uninitialize();
    return 1;
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
    return hook_count;
}

export fn dev_offset() callconv(.c) usize {
    return hook_offset;
}
